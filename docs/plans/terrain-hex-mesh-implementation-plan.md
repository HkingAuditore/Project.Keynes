# 地形格界解析化（hex cell field）实施计划

> **状态：方案设计，未开工。** 本文只定架构与验收口径，不改任何代码。
> 日期：2026-11-17（同日重构：原「逐格 hex mesh」方案作废，决策记录见附录 A）
> 代码根：`Project/project-keynes/`（下文路径均相对它；C++ 在仓库根 `gdext/src/`）
> 前置阅读：`docs/plans/terrain-land-water-split-assessment.md`（逐像素账、两 program 拆分的由来）
> 效果示意：`Project.Keynes/tmp/hex_boundary_compare.html`（WebGL2 三栏对比：现状 / hex mesh / 本方案，本地文件不入库）
> 文件名沿用旧名以免断链；内容已与 hex mesh 无关。

## 0. 一页结论

| 维度 | 结论 |
|---|---|
| 做什么 | 像素「属于哪几格、各占多少」不再从逐像素索引图读，而是在 PS 里由**世界坐标 + 一张连续扭曲场**解析算出（对偶三角 + 重心权重） |
| 几何 | **不换**。陆地 / 水面继续用现有覆盖 mesh；网格不承载格界 |
| 陆地与水面 | **同期切换**，共用同一个场函数 `hex_cell_field.gdshaderinc` |
| 主要收益 | ① 格界与缩放无关，任意 zoom 无纹素台阶；② 格界保持今天的弯曲形状；③ 三格角点连续 3-way 过渡；④ 删掉 DitherUV、`compute_lake_shore_proxy` 与多处 `map_index` 环采样；⑤ 桌面 / 移动湖岸宽度一致 |
| 主要代价 | 陆地 SETUP 采样基本持平（全是小表 `texelFetch`），水面大幅下降；新增一层烘焙纹理与一张 per-cell 表 |
| 回退 | 一个 define（`PK_CELL_FIELD`）+ 一个导出开关；关闭时与今日逐像素一致 |

### 路线图

| 版本 | 内容 |
|---|---|
| **v1** | 场函数 + 数据（P0–P1）→ 陆地与水面 SETUP 同时切换（P2）→ 水面邻域采样重写（P3）→ 打磨与平台档位（P4） |
| **v1.1** | 其余图层（迷雾、国界、天气、军事、植被影子等）改用同一场函数，视觉格界全局一致（P5） |
| **v1.2** | 默认开启，退役旧数据通道（P6） |
| **v3** | Z 高度：对偶三角网承载高度，着色仍走场函数（§9，独立立项） |

## 1. 目标与非目标

### 1.1 目标（v1 必须达成）

1. 地形与水面的格界在任意 zoom 下连续，无索引图纹素台阶，无 Bayer 网点。
2. 格界形状保持今天的「侵蚀弯曲」观感（同一扭曲场），不退化成直线六边形。
3. 三格交汇处为连续 3-way 过渡，无楔形色差、无硬三叉点。
4. 渲染认定的主导格与 CPU 的 `cube_round(p + warp)` **逐点一致**（自动化测试守）。
5. 陆地 program 不再采 `map_index_atlas` / `enum_lut` / `dyn_lut` / `edge_distance.R` / `edge_neighbor.RG`；水面 program 额外删除 `compute_lake_shore_proxy` 与 `shore_common` 的 `map_index` 环采样。
6. 保留 land/water 双 program、quality 档位、Web 降级、热重载、debug 视图的全部行为。

### 1.2 非目标

- 不换几何、不做 LOD、不做 chunk。
- 不做真 3D（§9）。
- v1 不改迷雾 / 国界 / 天气等其它图层（v1.1 再做；期间它们与地形格界最多差 1 纹素，与今天相同）。
- 不改选格逻辑：`HexUtils.world_to_cube` 仍用未扭曲坐标（与今天一致，见 §8.1）。

## 2. 为什么做

### 2.1 根因：类别量被烘进了纹理

| 项 | 数值 |
|---|---|
| 世界宽（60×40 图，hex_size 22） | ≈ 2393 wu（`wrap_period_x` = 2286.31） |
| 索引图宽（桌面 `HM_MAX_DIM_DESKTOP`） | 1024 texel ⇒ 1 texel = **2.34 wu** |
| `Camera2D.zoom_max` = 6 时 1 texel | **≈ 14 屏幕像素** |
| 移动端索引图 512 | 1 texel = 4.7 wu ⇒ ≈ 28 px |

近景方块由两件事叠加：

1. **主 cell id 是 NEAREST 读出的类别量**，格界只能落在纹素边上。`edge_distance` 虽是双线性，但每个纹素存的是「到**自己的主 cell** 边界」的距离；在主 / 副角色互换的那一列纹素上，双线性等于把两套参照系的距离混在一起，静态颜色在这里断开。
2. **`terrain_land_dither_zoom_strength()` 在 hex_px > 45 时归零**（`terrain_surface_detail.gdshaderinc:193`）。近景下植被 / 覆盖 / 地貌这些按 biome 门控的阶段退回硬主 id，直接画出纹素台阶。

两件事是同一个根：**格子编号这种不能插值的量进了空间纹理**。调参、加分辨率都只能推迟问题，不能消除。

### 2.2 本方案的原则

> **烘焙连续量，不烘焙类别量。** 归属由解析函数给出；纹理里只放能插值的东西（扭曲向量、高程、噪声）。

格界 = 「两格权重相等」的等值线 { p : f(p + warp(p)) = 0 }。f 解析、warp 连续 ⇒ 等值线连续，放大多少倍都不会出现台阶。per-cell 属性表按整数格坐标 `texelFetch`，是查表，与像素位置无关。

### 2.3 水面不能晚做

水面今天的格间过渡问题与陆地同源，且采样更多：

| 位置 | 内容 | 本方案 |
|---|---|---|
| `water_pipeline.gdshaderinc:148` `compute_lake_shore_proxy` | 3×3 + 半径 2/3 环，8 + 4（+4，quality≥2）次 `map_index` | **删除**，解析岸距（§3.7） |
| `shore_common.gdshaderinc:72` | 邻域 `map_index` 判类别 | 改读场函数的三格类别 |
| `water.gdshaderinc:548` | `map_index` 判类别 | 同上 |
| `water_pipeline.gdshaderinc:906` / `shore_common:167` | `visual_sample_water_depth`（逐格常量扇出成逐像素纹理） | 改为三格水深按连续权重插值 |
| `terrain_surface_tex` layer5 | 次生水格 RG + 水深 B | 不再需要 |

另有一个隐性不一致：`compute_lake_shore_proxy` 的探测半径以**纹素**为单位（`o * tx`，`o` ≤ 3）⇒ 桌面最多探 7 wu、移动端 14 wu，**同一份代码湖岸晕染宽度差一倍**。解析版与分辨率无关。

## 3. 架构决策

### 3.1 场函数：扭曲 → 对偶三角 → 重心权重

pointy-top、odd-r，与 `HexUtils.world_to_cube` 同口径。以三个两两相邻格的中心为顶点的三角形（六边形 Voronoi 的 Delaunay 对偶）里：

- 每个像素恰好落在一个对偶三角形内，由分数 axial 坐标 `floor` 定位，`fract` 直接给出重心坐标；
- 三角形内任意点的最近格中心必在这三个顶点之中 ⇒ **argmax(重心) ≡ cube_round**，与 CPU 归属逐点一致；
- 「w_A = w_B」那条线正好是六边形的边，三格交点就是三角形重心。

新增 `shaders/include/hex_cell_field.gdshaderinc`（叶子模块，仅依赖 `uniforms` 与 `visual_tile_sampling`）：

```glsl
struct HexCellField {
	ivec2 c0; ivec2 c1; ivec2 c2;   // offset 坐标 (col, row)，col 已 posmod；row 越界 = padding
	vec3 w_raw;                      // 扭曲坐标上的重心坐标（连续量用，§3.3）
	vec3 w;                          // 锐化后权重，Σ=1（类别量用，§3.3）
	vec3 gap;                        // 与主导格的中心距差，normalized_hex_center_gap 口径
	int dom;                         // argmax(w_raw)，== CPU cube_round(p + warp)
};

HexCellField pk_hex_cell_field(vec2 wp_wrapped, float band_gap) {
	HexCellField f;
	vec2 p = wp_wrapped + pk_boundary_warp(wp_wrapped);              // §3.5
	vec2 a = vec2((0.57735027 * p.x - p.y / 3.0) / hex_size,
			(2.0 / 3.0 * p.y) / hex_size);                             // 分数 axial
	vec2 b = floor(a);
	vec2 t = a - b;
	ivec2 o = ivec2(b);
	// 上 / 下三角用 step 选择，不写 if（§3.9）
	float up = step(1.0, t.x + t.y);
	int u = int(up);
	ivec2 q0 = o + ivec2(u, u);            // (0,0) 或 (1,1)
	ivec2 q1 = o + ivec2(1 - u, u);        // (1,0) 或 (0,1)
	ivec2 q2 = o + ivec2(u, 1 - u);        // (0,1) 或 (1,0)
	f.w_raw = mix(vec3(1.0 - t.x - t.y, t.x, t.y),
			vec3(t.x + t.y - 1.0, 1.0 - t.x, 1.0 - t.y), up);
	f.c0 = pk_axial_to_offset(q0);  // col = q + (r - (r & 1)) / 2，再 pk_posmod(map_w)
	f.c1 = pk_axial_to_offset(q1);
	f.c2 = pk_axial_to_offset(q2);
	float wm = max(f.w_raw.x, max(f.w_raw.y, f.w_raw.z));
	f.gap = (wm - f.w_raw) * 1.7320508;
	// AA 下限用连续量的导数：fwidth(a) 跨三角形连续，gap 本身在第三格处会跳变
	float aa = length(fwidth(a)) * 1.7320508 * terrain_edge_screen_width_px();
	float band = clamp(max(band_gap, aa), 1e-4, PK_FIELD_BAND_MAX);
	vec3 k = 1.0 - smoothstep(vec3(0.0), vec3(band), f.gap);
	f.w = k / max(k.x + k.y + k.z, 1e-5);
	f.dom = (f.w_raw.x >= f.w_raw.y && f.w_raw.x >= f.w_raw.z) ? 0
			: ((f.w_raw.y >= f.w_raw.z) ? 1 : 2);
	return f;
}
```

约束：

- **横向回绕**：`wrap_period_x = map_w · √3 · s`，同一 r 下 q 平移 map_w ⇔ offset col 平移 map_w，所以只需对 col `posmod`，**不能在 axial 空间取模**。输入先过现有 `wrap_world_pos()`，保证浮点量级小。
- **负数整除 / 取模**：GLSL ES 3.00 对负操作数的 `%` 结果未定义，`/` 的取整方向在旧驱动上也不可靠；q 可能为负。`pk_posmod(a, m) = a - m * int(floor(float(a) / float(m)))`，`(r - (r & 1)) / 2` 只在 r ≥ 0（已过南北边界判定）后求值。
- **南北边界**：row 越界的格视为 padding，类别按 `B_SEA_ICE`（与今天 `cid < 0` 的表现一致），不查表。
- **平局**：`dom` 的比较次序固定（0 > 1 > 2），CPU 镜像必须用同一次序（§4.4 的一致性测试依赖它）。

### 3.2 带宽上限：gap < √3/2

对偶三角形切换时，第三格在两三角形共享边上的 gap ≥ 0.5·√3 ≈ 0.866。若带宽超过它，第三格会在共享边一侧有权重、另一侧突然消失，**沿穿过格中心的那些线出现接缝**。

- `PK_FIELD_BAND_MAX = 0.86`（gap 单位）。换算到世界单位：沿中心连线 gap = 2d/s ⇒ 最大单侧带宽 ≈ 0.43 hex ≈ 9.5 wu。
- 现有 `terrain_ecotone_width = 0.84` 与 C++ `edge_distance_units = "normalized_hex_center_gap"` **同一单位**，可直接沿用。但现有噪声扩宽 `base_width * (1 + |terrain_ecotone_noise|)` 最高到 0.98（`terrain_surface_detail.gdshaderinc:246`），必须 clamp 到 0.86。

### 3.3 两种权重：类别用锐化，连续用原始

| 量 | 权重 | 理由 |
|---|---|---|
| 类别量：biome / veg / cover / landform / 水体类别 / fog_k | `w`（锐化） | 边界清楚、弯曲；格内大部分面积只有主格 |
| 连续物理量：温度 / 湿度 / 雪盖 / 活力 / 海冰比例 / 水深 | `w_raw`（不锐化） | 整个对偶三角形线性过渡，与 C++ 高程烘焙的重心插值（`world_ext_bake.cpp:1558`）同口径 |

- 连续量同样在扭曲坐标 p' 上求值，所以雪线、冰缘这类「连续场的阈值等值线」也是弯的，不会沿三角形边走成折线。
- `vegetation_vitality` / 雪盖今天是按格硬切 + dither，改后格界处不再有直线台阶——这是本方案对动态视觉的净收益。
- LOW 档位可以把连续量也降为 `w`（只读主格那一个 texel），见 §3.8 的预算。

### 3.4 per-cell 属性表：一张 offset 空间的 `sampler2DArray`

新增 `cell_table`（`Texture2DArray`，RGBA8，尺寸 = map_w × map_h，每格 1 texel，`texelFetch` 读取）：

| layer | R | G | B | A | 更新频率 |
|---|---|---|---|---|---|
| 0 class | biome（= `enum_lut.r` 同一枚举） | vegetation | cover | landform | 生成期 / 地形改变时 |
| 1 state | 与 `dyn_lut` 同字节：temp | wet | snow | vitality / sea_ice | 每日（随 `dyn_lut_changed`） |
| 2 aux | fog_k | water_depth（8bit，与今天 layer5.B 同精度） | flags（预留：临陆 6 方向等） | 预留 | 探索变化时 |

- **为什么另做一张而不复用 LUT**：`cell.index` 是 `_cells` 字典的插入顺序（`map_data.gd:385`），不是 offset 序，shader 无法由坐标推出。现成的 `offset_to_index`（`terrain_index_baker.gd::build_cell_inputs`）就是重排表，发布 LUT 时按它把同一份字节重排一次即可，不增加任何数据源。
- **采样槽**：一个 sampler 替换陆地 program 里的 `map_index_atlas` + `enum_lut` + `dyn_lut` 三个，**净省 2 槽**（GLES3 材质 sampler ≤ 8 的约束见 `uniforms.gdshaderinc`；Web 陆地 program 今天正好 8 槽）。
- **体积**：60×40×4B×3 ≈ 29 KB；100×64 ≈ 77 KB。全部命中缓存。
- **P0 必验**：`Texture2DArray.update_layer()` 在 GLES3 / WebGL2 上单层更新是否成立、是否触发整张重传。若不成立，退回三张独立 `Texture2D`（槽数与今天相同，不更差）。

### 3.5 扭曲场：C++ 顺手输出，进现有打包数组

`run_bake_terrain_index_pass` 第 1 步（`world_ext_bake.cpp:1484-1490`）已经逐像素算出双频扭曲：

```cpp
const double warp_x = cyl(NW_LO, wx_base, wy_base);
const double warp_y = cyl(NW_LO, wx_base + 31.7, wy_base - 17.3, 1.0, 31.7);
const double hi_x = cyl(NW_HI, ...) * WARP_HIGH_AMP_RATIO;
const double hi_y = cyl(NW_HI, ...) * WARP_HIGH_AMP_RATIO;
```

- 新增输出 `boundary_warp_buffer`（RG8）：`v = clamp((warp + hi) / PK_WARP_RANGE, -1, 1)`，`byte = round((v * 0.5 + 0.5) * 255)`，`PK_WARP_RANGE = 1.6`。报告里输出被 clamp 的像素数（应为 0）。shader 解码后乘 `hex_size * WARP_AMP`（0.4）。
- 量化误差 ≈ 0.1 wu，zoom 6 下 < 1 px。双线性插值保证连续。
- **扭曲值与 CPU 高程 / 海滩坡烘焙逐位同源**（同一个 buffer），所以山影海岸、海滩坡与颜色边界不会错开。这是选「烘一张扭曲场」而不是「PS 里现算噪声」的决定性理由：PS 现算需要把 FastNoiseLite 移植进 shader 或反向移植，两套浮点实现必然有亚像素差。
- **载体**：
  - 非 tiled 路径：`terrain_surface_tex` 新增 **layer6**（RG = warp，BA 预留），`terrain_surface_layer_count` 6 → 7，新增 `terrain_warp_layer_bound`；**不新增 sampler**。
  - 桌面 tiled 路径：在 `world_ext_bake_visual_tiles.cpp` / `visual_tile_set.gd` 新增 warp tile kind，占用 `visual_map_index_tiles` 让出的槽位，槽数持平。
- 回绕：`cyl()` 已在经线接缝两侧做 seam 平均，烘出的场跨接缝连续；采样 uv 走现有 `visual_static_wrap_uv`。

### 3.6 门控阶段与纹样：在锚点上选格

植被 / 覆盖 / 地貌着色这类「只能按一种 biome 画」的阶段，今天靠 DitherUV 在主 / 副之间二选一。改为：

```glsl
// 每格一份世界锚定噪声；频率按 pk_px_per_world_unit() 上限截断，避免远景闪烁
int visual_biome = argmax_i( w_i + PK_GATE_NOISE_AMP * (n(wp, cell_i) - 0.5) );
```

- 近景得到一条自然的碎边，远景（噪声被截断）退化为 argmax(w)，即弯曲的硬边。
- **静态材质只采前两名**：底色（`biome_hue_modulate` 的色调，纯 ALU）做完整 3-way；`terrain_material_tex` 的 albedo detail / 法线 / 粗糙度只对权重前两名的 biome 采样，第三名的权重并入第二名。角点处细节纹理是 2-way，色调仍是 3-way，肉眼看不出差别；采样数与今天相同。LOW 档只采 `visual_biome` 一份。
- **离散纹样元素在锚点上选格**：程序化树点、斜线等元素先算出自己的锚点（圆点中心、线段中点），在锚点处调用一次 `pk_hex_cell_field(anchor).dom` 决定画不画。否则元素会在格界上被切掉半个（对比页右栏可见此瑕疵）。锚点调用只需扭曲场 1 次采样 + 纯 ALU。
- DitherUV 相关函数（`terrain_mobile_dither_uv_threshold` / `terrain_hybrid_static_weight` / `terrain_land_dither_zoom_strength` / `terrain_dither_subpixel_fade`）在 `PK_CELL_FIELD` 下整段编译掉。

### 3.7 水陆：两 program 同一判定，岸距解析

**判定**：`is_water = terrain_static_biome_is_water(class[dom])`。陆地与水面 program 调用同一个函数、读同一份数据，海岸线就是 dom 在水 / 陆之间切换的那条弯曲等值线。

**防海岸出洞**：两 program 分别编译，编译器对同一表达式的融合优化可能不同，恰好落在等值线上的像素有可能两边都 discard。规则：**画在下层的那个 program 放宽 ε**（在 gap < ε 的岸带内也绘制），上层 program 严格判定。宁可重叠，不许出洞。P2 先核对 `_world_quad` / `_water_quad` 的实际绘制顺序再定哪边放宽。

**颜色不跨水陆**：沿用今天的拓扑约定（`terrain_surface_detail.gdshaderinc:336`）——陆地 program 只在陆地格之间混合（水格 k 置 0 后重新归一），水面 program 只在水格之间混合；海陆过渡交给 shore 管线。

**岸距解析**：对偶三角形之外的任何格，到三角形内任一点的 gap 都 ≥ √3/2。所以 **gap ≤ 0.86（≈ 9.5 wu）以内的岸线晕染，只看这三格就是精确的**：

```glsl
float shore_gap = 1e3;   // 到最近陆地格的 gap；三格都是水时视为 ≥ 0.86
for i in 0..2: if (!is_water(class_i)) shore_gap = min(shore_gap, f.gap[i]);
```

- `compute_lake_shore_proxy` 整函数删除；`shore_frac`（今天来自 `edge_distance.BA` 的 8 邻域水 / 湖占比）改为 Σ `w_raw`（水格 / 湖格）。
- 晕染宽度统一按世界单位给，桌面与移动不再差一倍。若美术要求宽于 9.5 wu 的晕染，再在 aux 层 flags 里带「6 方向临陆」位做第二圈，P3 视需要再做。

### 3.8 采样预算（按「分支全部展平」的最坏情况记账）

**预算口径是最坏情况，不是平均情况。** 移动 GPU 的动态分支按 warp 生效（Mali Valhall 16、Apple 32、Adreno 64–128 线程）：同一 warp 内走向不一就两边都执行；编译器也可能直接展平分支（WebGL2 在 Windows 上经 ANGLE → FXC，对含隐式求导采样的分支尤其如此）。远景时过渡带占格面积的一大半，几乎每个 warp 都发散。所以下表**不允许出现「格内 1 / 带内 3」这种依赖分支的计数**，每一项都是无条件执行的固定次数。

| | 今天（展平后，按源码估计） | 本方案 MID/HIGH | 本方案 LOW |
|---|---|---|---|
| noise_tex | 1 + ecotone 宽度噪声 1 | 1 | 1 |
| height | 1 | 1 | 1 |
| edge_distance | 1 | 0（crease 并入 layer6.BA 前 +1） | 0 |
| warp（layer6） | — | 1 | 1 |
| map_index | 1 | — | — |
| 类别 | enum 1 + 次生 edge_neighbor 1 + 次生 enum 1 | class **3** | class **3** |
| 动态 | dyn 1 | state **3**（连续量用 `w_raw`） | state **1**（主导格） |
| fog / 水深 | 搭 enum.a | aux **1**（主导格；水面 program 为 3，因水深要插值） | aux 1 |
| 静态材质（`terrain_material_tex`，大纹理过滤） | 2（主 + 次生） | **2**（前两名，§3.6） | **1** |
| **合计（陆地 program）** | **≈ 11** | **≈ 12** | **≈ 8** |

- 「今天」一栏是把 `world_map.gdshader:380-490` 与 `compute_terrain_static_material` 里 `if` 内的采样全部计入、并假设编译器合并同 uv 的 `edge_neighbor` 后的估计；P0 用 GPU 计数器实测校准。
- 本方案最坏情况与今天基本持平（+1），且新增的是 ≤ 80 KB 小表的 `texelFetch`（无过滤、全命中 L1），删掉的是大纹理过滤采样与 Bayer 计算。分支只作为额外收益（warp 一致时省掉的那部分），不进预算。
- 「只读主导格」的项不需要分支：先用 ALU 选出 `c[dom]` 的坐标，再做 1 次 `texelFetch`。
- `edge_distance.G`（沟谷 crease）是连续量，**保留**；crease 若仍需读取，edge_distance 那一次采样还在（表中按「已并入 layer6.BA」记 0，并入前实际 +1）。layer4 的 R / BA 不再被读取，P6 再决定是否收缩该层。
- 水面 program 净减：`compute_lake_shore_proxy` 8–16、`shore_common` 邻域 `map_index`、`water.gdshaderinc` 邻域、`water_depth` 1、次生水格 1–2。目标 ≤ 现状的 60%，P3 以实测为准。

### 3.9 不依赖发散分支的实现约束

格界带内的像素在屏幕上是细长条带，远景时几乎覆盖全部 warp，任何「只在带内才做」的分支都不能指望省下成本。约束如下，P2 代码评审按此逐条检查：

1. **场函数无分支**：三角选择用 `step` + `mix`（§3.1），`argmax` 用比较 + 三元选择，三格循环手写展开。
2. **固定采样次数**：每个质量档的采样次数是常数（§3.8），不出现「权重 > 0 才采」的 `if`。权重为 0 的项照采照乘，结果不变。
3. **隐式求导采样不进非一致控制流**：GLSL 规定非一致控制流里 `texture()` 的隐式导数未定义，FXC 遇到会强制展平或报 X3570。所有过滤采样（材质、扭曲场、噪声）提到顶层，或在顶层算好 `dFdx/dFdy` 后用 `textureGrad`。今天 `compute_terrain_static_material` 在 `if (edge_w > 0.0001)` 里采次生材质，属于同类隐患，本方案顺带消除。`texelFetch` 不涉及导数，可以放在任何位置。
4. **保留的分支只限大片一致区域**：未探索早退（`fog_hidden`）、水 / 陆 discard、质量档 define。这些区域在屏幕上是大块连续面积，发散 warp 只在边缘 O(周长)，与今天相同。
5. **精度**：分数 axial 坐标最大约 60–100，`fract` 需要 highp。Godot 4 的 GLES3 / Vulkan 路径默认 32 位 float，P0 探针在 Mali / Adreno 真机上核对 `floor/fract` 结果与 CPU 镜像一致（不一致即说明被降成了 mediump）。
6. **编译时间**：Web 首编以 `warmup_shader` 遥测为准（§6 ≤ 1.2×）。场函数是一段短 ALU，不含循环；若 FXC 出现悬崖，优先怀疑第 3 条被违反。

### 3.10 shader 组织与回退

- 不新开 shader 文件。`PK_CELL_FIELD` 作为 define 前缀，走 `renderer_shader_water.gd` 现有的变体拼装（与 `PK_LAND_ONLY` / `PK_WATER_ONLY` 同一机制）。
- 关闭时预处理器剔除全部新代码 ⇒ **与今日逐像素一致**（截图 diff = 0 是验收项）。
- `world_water_web.gdshader`（Web LOW/MID 独立精简水面）的迁移并入 Web 解禁方案 W3（`terrain-cell-field-web-plan.md`）。
- `hex_terrain.gdshader` 是旧方案遗留，本方案落地后删除（P6）。

## 4. 接口与接入点

### 4.1 C++（`gdext/src/world_ext_bake.cpp`）

- `run_bake_terrain_index_pass` 输出新增：`boundary_warp_buffer`（PackedByteArray，W×H×2）、`boundary_warp_range`（= `PK_WARP_RANGE`）、`boundary_warp_clamped`（int）。
- `world_ext_bake_visual_tiles.cpp`：tiled bundle 新增 warp kind。
- 重编按项目惯例的 scons 命令；成功判据只有 `scons: done building targets.`。

### 4.2 GDScript

| 文件 | 改动 |
|---|---|
| `scripts/rendering/bakers/terrain_index_baker.gd` | 接收 warp buffer，交给 surface 打包 |
| `scripts/rendering/bakers/surface_baker.gd` / `visual_tile_layout.gd` / `visual_tile_set.gd` | layer6 打包；tiled warp kind |
| `scripts/rendering/bakers/cell_lut_baker.gd` | 发布 `enum_lut` / `dyn_lut` 时按 `offset_to_index` 重排，写 `cell_table` 的 layer0/1；fog 变化写 layer2 |
| `scripts/geography/world_data.gd` | 持有 `cell_table_tex`、`boundary_warp` 元数据 |
| `scripts/rendering/renderer_material_publish.gd` / `renderer_lighting_bindings.gd` | 推 `cell_table`、`map_dims`、`terrain_warp_layer_bound` |
| `scripts/rendering/renderer_shader_water.gd` | `PK_CELL_FIELD` 前缀；开关 `terrain_cell_field_enabled`（v1 默认关） |
| `scripts/rendering/web_shader_warmup.gd` | 登记新变体，否则 Web 首次进图卡编译 |
| `scripts/geography/hex_cell_field.gd`（新） | 场函数的 CPU 镜像（`dom_at(wp, warp)`、`weights_at`），只给测试与 debug 用 |

### 4.3 shader

| 文件 | 改动 |
|---|---|
| `shaders/include/hex_cell_field.gdshaderinc`（新） | §3.1 场函数、`pk_boundary_warp`、`pk_axial_to_offset`、`pk_cell_class/state/aux` 查表 helper |
| `shaders/include/visual_tile_sampling.gdshaderinc` | `visual_sample_boundary_warp`（非 tiled 读 layer6；tiled 读 warp tiles） |
| `shaders/world_map.gdshader` | `#ifdef PK_CELL_FIELD` 下的新 SETUP（§5 P2） |
| `shaders/include/terrain_surface_detail.gdshaderinc` | `compute_terrain_static_material` 3-way 版本；DitherUV 编译掉 |
| `shaders/include/water_pipeline.gdshaderinc` / `water.gdshaderinc` / `shore_common.gdshaderinc` | 输入来源换成场函数（公式不改，只换来源）；删 `compute_lake_shore_proxy` |

### 4.4 测试

| 测试 | 断言 |
|---|---|
| `tests/world/hex_cell_field_parity_test.gd`（新） | 随机撒 10 万点：`HexCellField.dom_at` == `cube_round(p + warp)`（CPU 镜像对 C++ 结果），100% 一致；纹素中心处 dom == 烘焙 `map_index` 的 cell id，≥ 99.9%（差异只允许出现在 gap < 1 纹素处） |
| 同上 | gap 镜像 vs `edge_distance.R`：在 gap < 0.86 范围内绝对误差 < 0.02 |
| `tests/world/cell_table_layout_test.gd`（新） | layer0/1/2 每个 texel 与 `cells_by_index[o2i[...]]` 的字段逐字节一致；回绕列正确 |
| `tests/world/terrain_shader_variant_test.gd`（扩展） | `PK_CELL_FIELD` 变体源码不含 `visual_sample_map_index` / `enum_lut` / `dyn_lut` / `decode_edge_secondary_index` / `compute_lake_shore_proxy`；`get_shader_uniform_list()` 不含这些 sampler |
| `tests/world/terrain_index_edge_bake_test.gd`（扩展） | warp buffer 尺寸、clamp 数为 0、跨经线接缝连续 |
| GPU 一致性探针 `tools/cell_field_gpu_probe.gd`（新） | 离屏渲染 debug 视图「dom 与 map_index 是否一致」，统计不一致像素只出现在格界 1 纹素带内 |

## 5. 阶段计划

| 阶段 | 内容 | 量级 | 完成判据 |
|---|---|---|---|
| **P0** 数据 | C++ 输出 warp buffer；layer6 / tiled warp；`cell_table` 三层；CPU 镜像 `hex_cell_field.gd`。**平台验证**：canvas_item 里 `sampler2DArray` 的 `texelFetch(ivec3)`、`Texture2DArray.update_layer` 在 d3d12 / Vulkan / GLES3 / WebGL2 四端可用 | M | §4.4 的 parity / layout / edge_bake 测试全绿；四端探针场景取值正确 |
| **P1** 场函数 + 对照视图 | `hex_cell_field.gdshaderinc`；`terrain_surface_debug_view` 新增：dom 一致性、三格权重 RGB、gap 差值、warp 可视化。画面本身不变 | M | GPU 探针：不一致像素只在格界 1 纹素带内 |
| **P2** 陆地 + 水面 SETUP 同时切换 | `PK_CELL_FIELD` SETUP：类别 / 状态 / fog 改查 `cell_table`；静态材质 3-way；门控阶段噪声选格；`is_water` 两 program 同一判定 + 下层放宽 ε；fog 早退改为「三格均未探索」 | L | zoom 0.25–6 全档：陆地与水面无纹素台阶、无网点；海岸无洞；开关关闭 diff = 0 |
| **P3** 水面邻域重写 | 删 `compute_lake_shore_proxy`；`shore_common` / `water.gdshaderinc` 邻域改场函数；水深 / 海冰改 `w_raw` 插值；`shore_frac` 改解析 | M | 水面采样 ≤ 现状 60%；桌面 / 移动湖岸晕染宽度差 < 5% |
| **P4** 打磨与平台 | 纹样锚点选格；`PK_FIELD_BAND_MAX` 与 ecotone 噪声配平；移动 / Web 档位（LOW 连续量降为 `w`）；`world_water_web.gdshader` 迁移；warmup 登记；pck 体积核对 | M | Web 首编 ≤ 现有 program 1.2×；体积 < +1 MB；角点无楔形 |
| **P5**（v1.1） 其余图层 | 迷雾、国界、天气、军事斜纹、数据叠加、格边叠加、植被影子 / impostor、资源地表、建筑宏观、云影场（今天都读 `map_index` / `edge_*`）逐个改用场函数（天气、迷雾、云影已拆出单独方案 `terrain-cell-field-overlays-plan.md` O0–O6） | M–L | 迷雾边与地形边重合（截图叠加差 < 1 px） |
| **P6**（v1.2） 收尾 | 默认开启（Web / Compatibility 的解禁不等 P6，单独走 `terrain-cell-field-web-plan.md` W0–W6）；删 DitherUV、layer5、layer4.R/BA 的生产与消费（确认 P5 后无读者）；删 `hex_terrain.gdshader`；更新 `SHADER_DEV_GUIDE.md` | S | §6 全部达标；无旧通道读者（grep 断言） |

## 6. 验收标准

| 项 | 判据 |
|---|---|
| 无台阶 | zoom 6、桌面与移动纹素两档截图：陆地与水面格界无纹素台阶、无 Bayer 网点 |
| 形状 | 与现状同位置截图叠加：格界位置偏差 ≤ 1 纹素（同一扭曲场） |
| 归属一致 | CPU parity 100%；GPU 探针不一致像素只在格界 1 纹素内 |
| 角点 | 三格交汇处连续过渡；无楔形、无硬三叉 |
| 接缝 | 带宽拉到 `PK_FIELD_BAND_MAX` 时，沿对偶边（穿过格中心的线）无接缝 |
| 海岸 | 任意 zoom 海岸无洞（像素级检测：两 program 都 discard 的像素数 = 0） |
| 采样 | 陆地 SETUP 符合 §3.8；水面 ≤ 现状 60%（源码断言 + `get_shader_uniform_list()`） |
| 湖岸一致 | 桌面 / 移动晕染宽度差 < 5%（今天是 2 倍） |
| 性能 | 桌面 / 移动帧时间不劣于现状（同场景、同镜头 A/B） |
| Web 首编 | ≤ 现有 `world_map` program 的 1.2×（`warmup_shader` 遥测） |
| 体积 | 不新增独立贴图文件；pck 变化 < 1 MB |
| 回退 | 开关关闭时与今日逐像素一致（截图 diff = 0） |
| 回归 | `terrain_coverage_mesh_test` / `land_water_split_node_test` / `terrain_shader_variant_test` / `terrain_index_edge_bake_test` / 新增测试全绿 |

## 7. 风险

| 风险 | 影响 | 缓解 |
|---|---|---|
| `Texture2DArray.update_layer` 在 GLES3 / WebGL2 上不可用或整张重传 | 每日更新成本上升 | P0 先验；不行就拆三张 `Texture2D`（槽数与今天持平） |
| 移动端 warp 纹素 4.7 wu，高频分量（波长 ≈ 12 wu）只有 ~2.6 纹素 / 周期 | 双线性下格界出现 C0 连续但有折角的分段 | P1 在 zoom 6 实拍；若可见，HIGH 档改 B 样条双三次（4 次双线性 tap 实现），或 warp 层单独提高分辨率 |
| 两 program 编译差异导致海岸像素两边都 discard | 1 px 洞 | 下层 program 放宽 ε，只允许重叠（§3.7）；验收含「双 discard 像素数 = 0」 |
| 带宽超过 √3/2 | 穿过格中心的接缝 | `PK_FIELD_BAND_MAX` clamp + 验收项 |
| 迷雾 / 国界等图层 P5 前仍读 `map_index` | 这些图层的边与地形边最多差 1 纹素 | 与今天移动端 fog dither 的错位同量级；P5 消除 |
| 水深 8bit 在 `w_raw` 插值后出现色阶 | 深浅水过渡有台阶 | aux 层改 RG16，或水深占 layer2 的 GA 两字节；P3 实测决定 |
| 连续量 3 次 state 读取在低端 GPU 上的成本 | 帧时间 | LOW 档降为 `w`（只读主格）；P4 实测 |
| 移动 / Web 上分支被展平或 warp 发散 | 按平均情况设计的「省采样」全部落空 | 预算按最坏情况记账（§3.8），实现遵守 §3.9；P0 在 Mali、Adreno 真机与 Windows Chrome（ANGLE/D3D11）上各测一次帧时间与首编时间 |
| 非一致控制流里的隐式求导采样 | 带边缘出现 mip 断层；FXC 强制展平、编译时间悬崖 | §3.9 第 3 条：过滤采样提到顶层或用 `textureGrad` |
| GLSL ES 负数 `%` / `/` 未定义 | 地图西缘列号错乱（只在部分驱动上） | `pk_posmod` 用 floor 实现（§3.1） |
| 片元精度被降为 mediump | `fract(axial)` 抖动，格界在远离原点处锯齿 | §3.9 第 5 条，P0 真机探针 |
| CPU 镜像与 C++ 平局次序不一致 | parity 测试误报 | 次序写死在 §3.1，C++、GDScript、shader 三处同一注释锚点 |

## 8. 未决问题

1. **选格是否也吃扭曲**：今天 `HexUtils.world_to_cube` 用未扭曲坐标，视觉格界与逻辑格界最多差约 0.6 hex（对比页「叠加 CPU 逻辑格界」可见）。本方案不改变这一点；若要「点哪格就是哪格」，CPU 侧可用同一 warp buffer 先扭曲再 `cube_round`。属玩法决策，不阻塞 v1。
2. **植被散布的归属**：`scripts/rendering/shrub/scatter.gd` 等 CPU 散布按什么判格，是否要改用 `HexCellField.dom_at` 以与地表纹样一致。P4 排查。
3. **`PK_GATE_NOISE_AMP` 与噪声频率**：近景碎边的「碎度」需要一次实机配平。
4. **layer4 是否收缩**：P6 后 layer4 只剩 G（crease），可以并入 layer6 的 BA，`terrain_surface_tex` 回到 6 层。

## 9. 后续：Z 高度（v3，不在本计划内）

真 3D 时几何必须承载高度，但网格**仍不承载格界**：

- 拓扑用**对偶三角网**：顶点放在 cell 中心，按需细分。cell 高度落在顶点上，相邻三格天然共享一个三角形，不存在角点归属问题。不要用「中心 + 6 角」的 fan：它的角点是三格交点，归属天然有歧义。
- 着色仍用场函数从 XZ 坐标解析，网格细分密度与格界质量互不影响。
- 需要同时改：`MeshInstance3D` + spatial shader + `Camera3D`（透视俯角）+ 所有依赖 `z_index` 的图层排序 + 建筑 / 植被的深度关系。独立立项。

## 附录 A：为什么放弃逐格 hex mesh（决策记录）

原方案（同名文件的旧版本，见 git 历史）用「每格 fan：1 中心 + 6 角，7V/6T」承载格界，格属性放 `CUSTOM0/1` 与 `varying flat`。评审结论：

1. **v1 只能是直边**。格界由几何决定，弯曲需要细分边界（原 §9.1，L 级），并被列为水面的硬前置。本方案第一版就有弯曲边界。
2. **沿边 2-way 混合的公式不闭合**。`w_nb = blend_profile(s) * edge_falloff(d)` 在格界上等于 0.5·profile(s)，只有 profile = 1 时两侧取值相同，渐变段出现「半接缝」。修正版（带宽随 s 收窄）能闭合，但角点仍硬。
3. **角点归零强化了六边形感**。每个角都是硬三叉点；人眼识别六边形靠角，不靠边。
4. **`varying flat` 的取值顶点跨后端不同**：D3D12 / Vulkan 取首顶点，GLES3 / WebGL2 取末顶点且不可改。7V/6T 共享顶点在 Web 上会拿到隔壁三角形的邻居。
5. **dyn 取主导格**会在格界出现雪线 / 海冰的直线台阶（dyn 是逐格常量，不连续）。
6. **顶点预算**：「60×40 ≤ 5 万（含 wrap 3×）」只在只算陆地格时成立；全图 2400 × 7 × 3 = 50,400。

关键认识：在**规则**六边形格子上，光栅化器的重心插值与 PS 里 `floor/fract` 解析出的重心坐标是同一组数；而 PS 还能先做非线性的扭曲，硬件插值做不到。网格只有在格子不规则（Voronoi 省份、球面 Goldberg）或需要承载高度时才不可替代。

原方案的工程纪律原样保留在本方案里：变体并行、单开关回退、逐像素 A/B、源码 + uniform 双重断言、warmup 登记、平台验证放 P0。

## 附录 B：与 USG（天工编辑器）的对照

| 维度 | USG（天工） | 本方案 |
|---|---|---|
| 网格 | 4×4 grid per tile，32×32 grid per chunk | 不变（现有覆盖 mesh） |
| 格属性载体 | 顶点存 LayerId（→ 纹理数组） | offset 空间 `cell_table`，按坐标 `texelFetch` |
| 混合权重 | 三色染色 + UV3 插值出 (b0, b1, b2) | 扭曲坐标上解析的对偶三角重心，锐化后 3-way |
| 冲突处理 | BFS 染色 + 顶点复制 | 不存在：归属由坐标推出，不经过顶点 |
| 有机边界 | 由模块化地形模型决定 | 烘焙扭曲场（与 CPU 高程烘焙同源） |
| 水面 | 与地表共用网格与材质分流 | 与陆地共用场函数，两 program 同一判定 |

参考文档（iWiki）：`p/4016913499` 地形网格生成系统、`p/4009237915` 地表混合细节、`p/4007105712` 天工地形功能。
