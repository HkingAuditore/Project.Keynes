# 格子场（cell field）推广到天气云与战争迷雾

> 状态：**待实施**（2026-11-18 起草）。
> 上游：`terrain-hex-mesh-implementation-plan.md`（总方案，下称「总方案」）、`terrain-cell-field-contract.md`（契约）、`terrain-cell-field-web-plan.md`（Web 解禁）。
> 本文覆盖总方案 P5 中「迷雾、天气改用同一个场函数」的部分，把它拆成可以单独推进的阶段。军事、国界等其余图层不在本文范围内。

---

## 0. 一页结论

- **根因和地形相同**：`weather_overlay.gdshader` 和 `fog_of_war.gdshader` 都从 `map_index_atlas` 用 NEAREST 读格子编号（类别量），格界只能落在 texel 边上。移动档还在 texel 空间做 Bayer 选格，近景时出现孤立方块和锯齿边（截图里的样子）。
- **天气几乎全是连续量**：降水强度、云量、水汽、风都直接用**原始重心权重 `w_raw`** 做三格插值，不锐化，也不需要 `fwidth`。天气类型是类别量，处理方法是**先查出每格的颜色、透明度，再按权重混合结果**，不去混合类型 ID。
- **迷雾是「类别 + 柔边」**：知识度 k 用**锐化后的权重**混合，带宽比地形宽，再叠一层可平铺的低频扭曲。迷雾有两条硬约束：
  1. 地形早退（`fog_hidden`）的像素，迷雾必须完全不透明。这条要由迷雾 shader **在自己内部复算同一判定式**来保证，不能靠 `VisionSolver` 的两环 blur 留安全边。
  2. 已可见格子的格心必须是清的：扭曲幅度 + 半带宽 ≤ 格子内切圆半径。
- **两份 shader 共享一个无 uniform 依赖的场函数核心**。现在的 `hex_cell_field.gdshaderinc` 依赖 `uniforms.gdshaderinc`，而天气和迷雾都不 include 它，所以要把纯数学部分拆成 `hex_cell_core.gdshaderinc`。地形侧编译结果不变。
- **开关策略不同**：
  - 天气不影响任何别的 program，可以**单独开关，从第一版起 Web 也能开**。sampler 从约 8 个降到 2~5 个。
  - 迷雾和地形的早退判定绑在一起，必须**和地形用同一个准入函数**（`_cell_field_active`）。所以在 Web 上，迷雾跟着 Web 解禁方案 W6 一起开。

---

## 1. 现状

### 1.1 天气云（`weather_overlay.gdshader`，`sample_field_weather` 第 605 行起）

| 位置 | 做法 | 问题 |
|---|---|---|
| :609 | `wx_decode_cell_index(uv)`：`map_index` NEAREST → `cell.index` | 格界在 texel 上呈台阶 |
| :611–612 | 副格来自 `edge_neighbor`，权重来自 `edge_distance` | 在主副格角色互换的 texel 上，双线性插值混合了两套参照系 |
| :615–621 | `PK_MOBILE_ANY` 下用 texel 空间的 Bayer 阈值选一格 | 近景一个 texel 有十几像素，出现**孤立方块**；不随缩放淡出 |
| :660–698 | 桌面档：「中心 + 6 邻」环形采样平滑 | 6 次 `map_index` + 6～12 次 LUT 读取，结果仍以中心格为准 |
| :709–710 | 类型颜色、透明度只取中心格 | 雨区和晴区之间色调硬切 |
| :717–718 | 风向只取中心 / 副格 | 云的平流方向在格界处剪切 |

sampler：`weather_lut`、`weather_lut_prev`、`wind_lut`、`wind_lut_prev`、`enum_lut`，再加上 `visual_tile_sampling` 里的 `map_index` / `edge_neighbor` / `edge_distance`（非 tiled 时合在 `terrain_surface_tex` 中），**约 8 个**。

### 1.2 战争迷雾（`fog_of_war.gdshader`，fragment 第 569 行起）

- 先按 `edge_warp` 做可平铺梯度噪声扭曲（:583–589），再在扭曲后的位置用 `map_index` NEAREST 取格子（:592）。
- `PK_MOBILE_ANY && !PK_FOG_RUNTIME` 时用 Bayer 选格（:596–614），否则主副格双采样 mix（:616–626）。
- k 取自 `enum_lut.a`。它的真源是 `VisionSolver` 的 `fog_k_arr = 0.5·blur(explored) + 0.5·blur(visible)`，**blur 两环**。注释说明这样做的目的，是给「噪声扭曲最多位移 1 格」和「地形早退」之间留安全边界（`vision_solver.gd:46`）。
- 绘制在 1/2 分辨率的 SubViewport 里，再线性上采样（`fog_of_war_layer.gd:52`）。z_index = 12，盖在天气（4）之上。

### 1.3 与地形的耦合

地形在 `PK_CELL_FIELD` 下的早退条件（`world_map.gdshader:815`）：

```glsl
fog_hidden = fog_early_out_enabled && fog_k(主导格) <= fog_early_out_k && field_edge_gap >= PK_FIELD_BAND_MAX;
```

早退像素直接写入 `fog_unexplored_color`。如果这些像素上迷雾的 alpha 小于 1，玩家就会透过迷雾看到一块纯色。今天之所以看不出来，是因为两环 blur 的安全边足够宽。但这个保证是**隐式**的：它建立在「扭曲幅度 ≤ 1 格」的注释上，没有任何测试守着。

### 1.4 顺带说明

- 雨幕 `weather_cell_curtain.gdshader` 是每格一个 MultiMesh 实例，实例里直接带 `cell_id`，用六边形羽化。它不读 `map_index`，**不产生方块**，所以列为可选项（§3.8）。
- 云影 `cloud_shadow_field.gdshader` 同样用 `map_index` + `weather_lut`，问题相同，放在 O6。
- 天气、迷雾、雨幕三处 `hex_world_diameter` 的 uniform 默认值各不相同（38 / 未知 / 44）。运行期都由 `2 × hex_size` 推送覆盖，所以今天没出问题，但新代码**不得依赖默认值**（§3.2）。

---

## 2. 原则

| 量 | 性质 | 权重 | 扭曲 |
|---|---|---|---|
| 降水强度、云量、水汽 | 连续 | `w_raw` | 天气低频扭曲（自由调） |
| 风向 / 风速 | 连续（向量） | `w_raw` | 同上 |
| 天气类型 → 颜色、透明度、光照 tint | 类别 → 先查表再混合 | `w_raw` | 同上 |
| 知识度 k（迷雾显示） | 类别（三态）+ 柔边 | 锐化后的 `w`，带宽 `fog_field_band` | 迷雾低频扭曲（有上限，§3.6） |
| 迷雾强制不透明判定 | 类别，必须与地形逐像素一致 | 地形同一套场（地形扭曲场 + `PK_FIELD_BAND_MAX`） | 地形扭曲场 |
| 天气的迷雾门控（`fog_vis`） | 跟随迷雾显示 | 与迷雾显示同一个函数 | 与迷雾显示相同 |

和总方案的原则一致：**插值权重，不插值 ID；烘焙连续量，不烘焙类别量**。

**为什么天气也要扭曲**：纯 `w_raw` 插值时，一个下雨格被晴天包围，雨区是一顶以格心为顶点的「软六边形帐篷」（覆盖 6 个对偶三角形），轮廓仍带六边形感；对偶三角形的边上，过渡斜率会突变，大片均匀色调里可能看出淡淡的折痕。查表前给坐标加一层低频扭曲（约 0.3–0.5 格），帐篷会变成不规则团块，折痕也被打散。

---

## 3. 设计

### 3.1 拆出无 uniform 依赖的核心：`hex_cell_core.gdshaderinc`

`hex_cell_field.gdshaderinc` 现在直接读 `hex_size`、`world_origin`、`wrap_*`、`cell_table_size`、`terrain_warp_*`，这些来自 `uniforms.gdshaderinc`。天气和迷雾各自声明了自己的 `world_origin` / `world_size` / `wrap_*`，不能 include 整个 uniforms（会重复声明，而且会带进一大串无关 uniform）。

拆分方式：

```glsl
// hex_cell_core.gdshaderinc —— 纯函数，零 uniform、零 sampler
struct PkHexTri { ivec2 c[3]; vec3 w_raw; };          // c 为 offset 坐标（已回绕、未做南北 clamp）
struct PkHexGrid { float hex_size; int map_w; int map_h; float wrap_period_x; float wrap_origin_x; };

PkHexTri pk_hex_tri(vec2 p_wrapped, PkHexGrid g);      // floor/fract + step/mix，无分支
int      pk_hex_tri_dom(PkHexTri t);                   // 平局次序 0 > 1 > 2（与 CPU 镜像同序）
float    pk_hex_tri_gap(PkHexTri t);                   // 到最近格界的 gap，|∇gap| = 2/hex_size
vec3     pk_hex_sharpen(vec3 w_raw, float band);       // 与地形同一公式
float    pk_hex_aa_band(vec2 world_pos_unwrapped, float hex_size, float px);  // 契约 §9.1 的 AA
int      pk_posmod(int a, int m);
ivec2    pk_axial_to_offset_wrapped(ivec2 qr, int map_w);
```

- `hex_cell_field.gdshaderinc` 改为 include 这个核心，用 uniform 组装 `PkHexGrid` 后调用。**地形侧的编译结果要保持逐像素一致**：契约 §6 现有的 parity、shader variant 测试和截图 diff = 0 一起守着。
- 核心文件不声明任何 uniform，这一点由一条测试断言（grep `^uniform` 命中 0 次）。
- `hex_cell_field.gdshaderinc` 在契约里标着「lead 独占」，拆分这一步（O0）必须由 lead 来做，或者事先协调好。

### 3.2 坐标契约（两份新 shader 都要遵守）

1. **`v_world` 是未回绕的世界坐标**。天气是 `(MODEL_MATRIX * vec4(VERTEX, 0, 1)).xy`，迷雾是 `VERTEX`。两者都要先过 `wrap_world_pos` 再进 `pk_hex_tri`；AA 一律对未回绕的 `v_world` 求 `fwidth`（契约 §9.1 的回绕接缝问题）。
2. **新增 uniform `hex_size`、`map_dims`（vec2），由宿主推送 `host.hex_size` 和地图尺寸**。不从 `hex_world_diameter` 反推，也不信默认值。契约 §9.3「世界坐标 uniform 不得硬编码」的断言要扩展到这两个材质。
3. **扭曲必须沿 x 方向周期可平铺**，周期等于 `wrap_period_x`。迷雾现成的 `fog_tileable_scale` + `cloud_grad_noise_tiled` 已经满足，把它提到共享 include 里（`pk_soft_warp_tiled(wp, freq, amp)`），天气也用这一份。不可平铺的扭曲会让回绕接缝两侧取到不同的格子。
4. **迷雾在半分辨率 SubViewport 里渲染**，`fwidth(v_world)` 拿到的是半分辨率像素对应的世界跨度，所以 AA 带天然宽 2 倍，再经线性上采样。这是可以接受的，§3.6 的保守余量已经把它算进去了。

### 3.3 天气数据：`weather_table`（offset 空间）

现有的 `weather_lut` / `wind_lut` 按 `cell.index` 排列。场函数给出的是 offset 坐标，有两种对接方式：

| | A：间接表（cell_table 加一层 offset→index） | **B：重排成 offset 空间的 `weather_table`（采用）** |
|---|---|---|
| 每像素读取 | 3 次 index + 后续每张表 3 次，是**依赖读**，延迟串行 | 每张表 3 次，没有依赖读 |
| CPU 侧 | 不改 | 发布时按 `offset_to_index` 重排（地形 `cell_table` 实测 1.58 ms / 2400 格） |
| sampler | `cell_table` + 4 张 LUT = 5 | `weather_table` + `cell_table`（迷雾门控）= 2 |
| 云影、雨幕 | 不受影响 | 继续用旧 LUT，直到 O6 迁移 |

**`weather_table`**：`Texture2DArray`，RGBA8，`map_w × map_h`，`filter_nearest`，无 mip，**不加 `source_color`**。

| layer | 内容 | 写入时机 |
|---|---|---|
| 0 / 1 | 天气 A / B（R=type，G=intensity，B=cloud，A=vapor，与 `weather_lut` 同布局） | 天气提交时**只写旧的那一层**，再翻转 `weather_cur_layer` |
| 2 / 3 | 风 A / B（与 `wind_lut` 同编码） | 与天气同步翻转 |

- **双缓冲靠层号，不拷贝数据**。今天 `_publish_weather_lut_bytes` 每次提交都上传两张整图（prev 和 cur）；改成「`update_layer` 只写一层 + 翻转一个 int uniform」。如果某个平台上 `update_layer` 不是单层更新（Web 计划 W0 会验证），就整张重建：60×40×4 层×4B ≈ 38 KB，可以忽略。
- 风场字节目前由云影场上传（`set_wind_luts` 只拿到 `Texture2D`）。O1 要在上游拿到原始字节，和天气在同一个提交点一起重排写入。**这一点需要在 O1 开工前确认**：风场的生成方是谁、是否与天气同一节拍。
- 地图上下 padding 行：type 写 `WT_CLEAR`，其余写 0；读取时南北越界的格子先 clamp，再按权重参与混合（与地形的 padding 处理同口径）。

### 3.4 天气 overlay 的采样流程

```glsl
FrontField sample_field_weather(vec2 world_pos /* 未回绕 */) {
	vec2 wp = wrap_world_pos(world_pos);
	vec2 p  = wrap_world_pos(wp + pk_soft_warp_tiled(wp, weather_warp_freq, weather_warp_amp * hex_size));
	PkHexTri t = pk_hex_tri(p, grid());
	vec3 w = t.w_raw;

	// 固定 3 次（展开写，不用循环）
	vec4 c0 = wx_fetch(t.c[0], cur_layer), c1 = …, c2 = …;
	if (weather_lerp < 0.999) {             // 条件只依赖 uniform → 整屏走向一致，各平台都真正跳过
		vec4 p0 = wx_fetch(t.c[0], prev_layer), …;
		c0.gba = mix(p0.gba, c0.gba, weather_lerp); …
	}
	vec3 gba = w.x * c0.gba + w.y * c1.gba + w.z * c2.gba;   // intensity / cloud / vapor

	// 类型：先查表，再混结果
	vec4 prof = w.x * wx_profile(c0.r) + w.y * wx_profile(c1.r) + w.z * wx_profile(c2.r);
	int  wt_dom = wx_type(t, c0, c1, c2);   // argmax(w_i)，只给仍需要整数类型的下游用（§3.5）

	vec2 wind = w.x * wx_wind(t.c[0]) + …;  // 风同样 w_raw 混合，prev 同上
	float fog_vis = pk_fog_visibility(world_pos);   // 与迷雾显示同一函数（§3.7）
	…
}
```

- 现在的 `wx_decode_cell_index`、`wx_decode_edge_secondary`、`wx_edge_secondary_weight`、`wx_mobile_dither_uv_threshold`、桌面 6 邻环采样（:660–698）**整段删除**。
- 用 `Σ w_i · value_i` 替换「中心 + 6 邻平均」，得到的是对偶三角网上的分段线性场，跨格处处连续。
- 不需要 `fwidth`：`w_raw` 本身就是连续的，没有硬边需要 AA。天气侧唯一的硬边来自迷雾门控，而那一项由 §3.7 的共享函数处理。

### 3.5 天气类型怎么处理

| 下游 | 今天 | 改为 |
|---|---|---|
| `best.color` / `best.alpha`（profile 色、透明度） | 中心格 | `Σ w_i · profile[type_i]` |
| `best.precip` | 中心格 intensity | `Σ w_i · intensity_i` |
| `compute_cloud_lighting(…, w.type, …)` | 中心格 type | O2 先读 `compute_cloud_lighting` 函数体：**如果只用 type 选 tint**，就把 tint 也改成先查表再按 w 混合，彻底不传 int；**如果有按 type 分支的逻辑**，传 `wt_dom`，并在验收里专门检查交界处有没有跳变 |
| `best.edge`（vapor） | 中心格 | `Σ w_i · vapor_i` |

雨雪交界处会出现两者混合的一条带，物理上就是雨夹雪，这是想要的效果。

### 3.6 迷雾显示：锐化权重 + 有上限的扭曲

```glsl
vec2  wp = wrap_world_pos(v_world);
vec2  p  = wrap_world_pos(wp + pk_soft_warp_tiled(wp, fog_warp_freq, fog_warp_amp * hex_size));
PkHexTri t = pk_hex_tri(p, grid());
float aa = pk_hex_aa_band(v_world, hex_size, 1.0);
vec3  w  = pk_hex_sharpen(t.w_raw, max(fog_field_band, aa));
float k  = w.x * fog_k(t.c[0]) + w.y * fog_k(t.c[1]) + w.z * fog_k(t.c[2]);   // 3 次 aux.R
// 后续 thick / presence / 分层云海逻辑不变
```

**约束 1：带宽**。`fog_field_band < √3/2`（与地形同一条硬约束，否则沿着穿过格心的线出现接缝）。建议默认值 0.6，比地形宽，让迷雾边更柔和。

**约束 2：可见格格心必须是清的**。|∇gap| = 2/s，格心处 gap = √3。扭曲把采样点从格心最多推开 `A`（世界单位）后，到格界的距离 ≥ (√3/2)·s − A，对应 gap ≥ √3 − 2A/s。要让这一点仍然是纯主导格（gap ≥ band），需要：

```
A ≤ (√3/2 − band/2) · s
```

band = 0.6 时，A ≤ 0.566 s。**今天的 `edge_warp = 0.55` 对应单轴最大位移 0.55 × 2s = 1.1 s**，可以把一个可见格子的格心推进隔壁未探索格。实际是否出现过要看噪声分布，但这个保证并不存在。新代码把扭曲改成按长度 clamp：`warp = clamp_length(raw, A_max)`，`A_max` 由上式从 band 算出来，不另设参数。这是**视觉行为的变化**：迷雾边的「张牙舞爪」幅度会变小，O3 需要美术确认。

**约束 3：地形早退像素必须完全不透明（强制）**。迷雾 shader 内部复算地形的判定：

```glsl
// 与 world_map.gdshader:815 同一个式子，同一张地形扭曲场，同一个 PK_FIELD_BAND_MAX
PkHexTri tt = pk_hex_tri(wrap_world_pos(wp + pk_boundary_warp_world(wp)), grid());
bool terrain_hidden = fog_early_out_enabled
		&& fog_k(tt.c[pk_hex_tri_dom(tt)]) <= fog_early_out_k
		&& pk_hex_tri_gap(tt) >= PK_FIELD_BAND_MAX - fog_hidden_margin;
alpha = terrain_hidden ? 1.0 : alpha;
```

- `fog_hidden_margin` = 2 个**屏幕**像素对应的 gap（= 4/s · 世界每屏幕像素）。用来吸收半分辨率加线性上采样在边缘造成的 1 个半分辨率像素的 alpha 衰减。迷雾判为不透明的区域会比地形早退区域略大一圈，方向是安全的。
- 代价：地形扭曲场 1 次采样 + 1 次 aux 读取。迷雾 shader 需要绑定 `terrain_surface_tex`（layer6）或 tiled 的 `visual_warp_tiles`。sampler 增减见 §3.9。
- 有了这一条，「blur 两环保证安全边」就不再是正确性的前提。`VisionSolver.BLUR_ITERATIONS` 改不改是另一个视觉问题，见 §8-1。

### 3.7 天气的迷雾门控和迷雾显示共用一个函数

`pk_fog_visibility(world_pos)` = §3.6 的 k 计算 → `smoothstep(0.5, 1.0, k)`，放在共享 include 里，天气和迷雾都调用它。天气不需要「强制不透明」那一段，因为天气在迷雾之下（z 4 < 12），被盖住的部分本来就看不见。

这样做的目的：「已探索但不可见」的格子里，天气云消失的边界和迷雾薄纱的边界是**同一条线**。今天两边各自取样、各自过渡，边界会错开。

天气 overlay 因此要绑定 `cell_table`（读 aux.R），但**不需要**绑定地形扭曲场：迷雾显示用的是自己的可平铺噪声扭曲，纯 ALU。

### 3.8 雨幕（可选，O5）

今天的六边形羽化在相邻实例的重叠区，强度对不上。改法是用「帐篷基函数」做单位分解：

- 每个实例的强度乘以**该格在当前位置的 `w_raw`**（即以格心为顶点的帐篷）。所有格子的帐篷加起来处处等于 1，雨幕无缝拼接，每格的雨量精确等于该格数据。
- 实例 quad 要扩大到覆盖 6 个邻居格心（半径 √3·s）。片元里用 `pk_hex_tri` 求出当前点的三格，**只有当本实例的 offset 是其中之一时**才取对应的 w（三元选择，不分支）。
- 雨区 overdraw 约变成 3 倍。LOW 档保留现在的羽化。
- 天气 overlay 改完后，如果雨幕的格界仍然明显，再做这一步。

### 3.9 采样与 sampler 账（按分支全部展平的最坏情况）

**天气 overlay**（每像素）：

| | 今天 桌面 | 今天 移动 | 新方案 |
|---|---|---|---|
| map_index（含 6 邻环） | 1 + 6 | 1 | 0 |
| edge_neighbor + edge_distance | 2 | 2 | 0 |
| weather（cur / prev） | 2–8 / 2–8 | 1 / 1 | 3 / 3 |
| wind（cur / prev） | 2 / 2 | 1 / 1 | 3 / 3 |
| enum_lut（迷雾门控） | 2 | 1 | aux 3 |
| **合计** | **≈ 21–33** | **≈ 8** | **15** |
| sampler | ≈ 8 | ≈ 8 | **2**（`weather_table` + `cell_table`） |

- 移动端从 8 次增加到 15 次，但新增的全是两张 ≤ 40 KB 小表的 `texelFetch`（无过滤，全部命中 L1）；删掉的是 3 次大纹理采样和 Bayer 计算。天气 overlay 的主要开销本来就在云噪声的 fbm 上，这些读取占比很小。O2 用 GPU 计数器实测。
- **如果实测移动端超标**（判据见 §6），备选是把 `w_raw` 插值后的天气场在每次提交时用一次 GPU pass 烘成连续纹理（每格约 4–8 texel，线性采样），之后每像素只读 2–4 次。天气场是连续量，双线性采样不会出台阶，符合「烘连续量」的原则。代价是多一个 SubViewport pass 和一帧延迟，所以不作为首选。

**迷雾**（每像素）：

| | 今天 | 新方案 |
|---|---|---|
| map_index + edge_neighbor + edge_distance | 3 | 0 |
| enum_lut | 1–2 | — |
| aux.R（显示 3 + 判定 1） | — | 4 |
| 地形扭曲场 | — | 1 |
| **合计** | **4–5** | **5** |
| sampler | ≈ 4 | **2**（`cell_table` + 地形扭曲场来源） |

**分支约束**（总方案 §3.9）：三格读取全部展开、固定次数；`weather_lerp < 0.999`、`has_wind_prev`、`fog_mask_enabled` 这类**只依赖 uniform 的条件**可以保留，因为整屏走向一致，在手机和 Web 上都真正跳过。逐像素条件一律用 `step` / `mix` / 三元选择。

---

## 4. 开关与平台

| | 天气 | 迷雾 |
|---|---|---|
| 开关 | 新增 `weather_cell_field_enabled`（项目设置 + 导出变量，同 `terrain_cell_field_enabled` 的惯例），**独立于地形** | **不新增开关**，直接用 `RendererShaderWater._cell_field_active()` 的结果 |
| 理由 | 天气和地形之间没有逐像素不变量；画面只在天气 overlay 内部变化 | 迷雾的强制不透明判定必须和地形的早退判定**来自同一条路径**。地形走旧路径时，迷雾也必须走旧路径，否则 §3.6 约束 3 判的是一个不存在的条件 |
| Web | sampler 减少，编译更轻（`PK_WEB_WEATHER_MIN` 删掉了 map_index 和边界逻辑）。**第一版就可以在 Web 上开** | 跟随 Web 解禁方案 W6 |
| 移动 | 第一版可开，O2 实测 | 跟随地形（移动已在 v1 准入范围内） |
| 关闭时 | 前缀逐字节不变，截图 diff = 0 | 同左 |

前提：`cell_table` 和地形扭曲场（layer6 / `visual_warp_tiles`）在地形开关关闭时**也要照常生成**。天气在 Web 上要读 `cell_table`，而 Web 上地形目前走旧路径。O1 要确认 `cell_lut_baker` 发布 `cell_table` 与开关无关；如果有关，就改成无条件生成（体积约 38 KB，成本可以忽略）。

---

## 5. 阶段

| 阶段 | 内容 | 判据 |
|---|---|---|
| **O0 核心拆分** | 拆出 `hex_cell_core.gdshaderinc`；`hex_cell_field` 改为包装层；`pk_soft_warp_tiled` 提进共享 include | 地形 parity 44/0、shader variant 全绿；`PK_CELL_FIELD` 开启时截图 diff = 0；核心文件 `^uniform` 命中 0 |
| **O1 天气数据** | `weather_table`（4 层、层号双缓冲）；风场字节的上游来源；`cell_table` 无条件生成；新增 `weather_table_layout_test`（逐字节对照 `weather_lut` 重排结果、翻转后 prev 等于上一次 cur） | 测试全绿；旧路径画面不变 |
| **O2 天气 overlay** | §3.4、§3.5；删除 map_index / Bayer / 6 邻环；`PK_WEB_WEATHER_MIN` 同步改写；`hex_size` / `map_dims` 推送 | 任意缩放无方块；雨晴交界色调连续；移动端 overlay pass ≤ 现在的 1.15 倍；Web 首次编译 ≤ 现在的 1.0 倍 |
| **O3 迷雾** | §3.6、§3.7；扭曲按长度 clamp；强制不透明判定；删除 Bayer 和 edge 路径 | 美术确认迷雾边的形态；§6 的不变量探针 0 违例 |
| **O4 GPU 回读探针** | 扩展 `cell_field_gpu_parity_probe`：天气 / 迷雾材质的 debug 输出（dom offset、Σw、terrain_hidden）在 CPU 侧逐点比对 | 开窗口运行，0 不一致 |
| **O5 雨幕（可选）** | §3.8 帐篷单位分解 | O2 之后格界仍明显时才做 |
| **O6 云影** | `cloud_shadow_field.gdshader` 迁到 `weather_table` + `w_raw`；之后 `weather_lut` / `wind_lut` 的 index 空间版本只剩雨幕在用 | 云影无方块；与天气云的位置一致 |

依赖关系：O0 → O1 → O2；O3 依赖 O0，与 O1/O2 并行；O4 在 O2、O3 之后；O5、O6 独立。

---

## 6. 验收

| 项 | 标准 |
|---|---|
| 方块 | zoom 1 / 3 / 6 下，天气云、迷雾边都没有纹素台阶和孤立方块（移动档重点看） |
| 连续性 | 天气场跨格无断层；回绕接缝两侧天气、迷雾的形状连续，无亮线 |
| 迷雾不变量 1 | GPU 探针：所有 `terrain_hidden` 像素迷雾 alpha = 1（读回 ≥ 254/255） |
| 迷雾不变量 2 | 所有已可见格（k = 1）的格心像素，迷雾 alpha < 0.02 |
| 门控一致 | 「已探索未可见」区域，天气云消失的位置与迷雾薄纱边界的偏差 ≤ 2 屏幕像素 |
| 关闭还原 | 两个开关关闭时前缀逐字节不变，截图 diff = 0 |
| 性能 | 天气 overlay pass：移动 ≤ 1.15 倍，桌面 ≤ 1.0 倍；迷雾 pass ≤ 1.05 倍。超标时启用 §3.9 的备选（天气场 GPU 烘焙） |
| Web | 天气 overlay 首次编译 ≤ 现在；sampler 数用等值断言（Web 解禁方案 §3.3 的普查扩展到这两个材质） |

---

## 7. 风险

| 风险 | 后果 | 对策 |
|---|---|---|
| 拆核心时改变了地形的编译结果 | 地形画面细微变化，或 parity 失败 | O0 单独提交，截图 diff = 0 才能合入 |
| 迷雾扭曲 clamp 后边缘变「乖」 | 美术不满意 | 用更高频的二级细节噪声补形态（只影响 alpha 纹理，不影响 k 的取样位置）；clamp 本身不能放宽 |
| 移动端天气 overlay 15 次读取超预算 | 掉帧 | O2 实测；超标就走天气场 GPU 烘焙备选 |
| 风场与天气不在同一节拍更新 | 两者的双缓冲层号错位，风向闪跳 | O1 开工前确认上游；不同节拍就各自维护层号 |
| `cell_table` 只在地形开关开启时生成 | Web 上天气读到空表 | §4 前提，O1 确认并改成无条件生成 |
| 天气类型在光照中按 int 分支 | 交界处光照跳变 | §3.5：先读函数体，能改成查表混合就不传 int |
| 迷雾半分辨率边缘的 alpha 衰减 | 早退区边缘露出一圈纯色 | `fog_hidden_margin`（§3.6）；不变量探针用全分辨率读回 |

---

## 8. 未决问题

1. **`VisionSolver` 的两环 blur 还要不要**：§3.6 约束 3 落地后，blur 不再承担正确性。但它也决定了 k 的柔化程度，而且地形的灰化读的是主导格的 k。现在场插值本身就会产生过渡，blur 叠上去可能**双重柔化**，迷雾边过宽。O3 视觉验收时对比 `BLUR_ITERATIONS = 2 / 1 / 0`，再决定是否调整。
2. **天气扭曲参数**：频率和幅度（建议 0.3–0.5 格）需要在 O2 里看效果定，和云噪声的尺度可能要联调。
3. **雨幕要不要做**：取决于 O2 之后雨幕和云的格界是否还对不上。
4. **云影和天气云的扭曲是否共用**：O6 时如果两者扭曲不同，云和它的影子会在形状上错开。倾向于共用同一份天气扭曲参数。

---

## 9. 否决的方案

| 方案 | 否决理由 |
|---|---|
| 只把 Bayer 选格改成近景淡出（和地形旧路径一样） | 只是遮住症状。类别量进纹理这个根因还在，桌面档的边界仍有 texel 台阶 |
| 天气也用锐化权重 | 天气数据本来就是连续的，锐化会人为造出硬边，还要多付 AA 的代价 |
| 天气保留 index 空间 LUT，加一层 offset→index 间接表 | 每张表都要先做一次依赖读，延迟串行；sampler 也省得更少（5 vs 2）。只在「不想动 CPU 发布」时才有意义，而重排的成本已经实测很低 |
| 迷雾靠 blur 安全边保证不透明，不复算判定式 | 这个保证建立在「扭曲 ≤ 1 格」的注释上，没有测试守着；扭曲、带宽、blur 任何一个参数变化都可能让它悄悄失效 |
| 迷雾也用 `w_raw` 插值 k | 过渡宽到整个三角形，玩家难以看出哪一格已探索；而且格心之外几乎没有纯色区，约束 2 无法满足 |

---

## 10. 实施记录（2026-11-18）

> 本轮落地 **O0–O3 + O2↔O3 接口收口**。**O4（天气侧 GPU 回读探针）、O5（雨幕）、O6（云影）未做**，
> 理由见 §10.3。

### 10.1 落地内容

| 阶段 | 结果 |
|---|---|
| **O0 核心拆分** | 新增 `hex_cell_core.gdshaderinc`（**零 uniform / 零 sampler**）与 `cell_field_overlays.gdshaderinc`（零 uniform 胶水）；`hex_cell_field.gdshaderinc` 退化为包装层，`HexCellField` 与全部公开函数签名不变。**地形编译结果逐 token 不变**（6 种前缀对照：default / `PK_LAND_ONLY` 完全相同；4 个 PK 前缀的差异全部落在场函数 include 的变化窗口内，窗口外逐字相同），GPU parity 仍 100% |
| **O1 天气数据** | `weather_table`（`Texture2DArray` 4 层：天气 A/B + 风 A/B，offset 空间），层号双缓冲、`update_layer` 只写 `1-cur`、**不拷贝**；重排复用 `DCCellTableCodec.reorder_to_offset`；发布挂在 `_publish_weather_lut_bytes` 的既有提交点。**两个前提确认**：`cell_table` 与地形扭曲场都与地形开关无关、无条件生成 |
| **O2 天气 overlay** | 连续量按 `w_raw` 三格插值；类型**先查 profile 再按权重混结果**；`compute_cloud_lighting` 的 `int wt` 经查证是死参数、直接删除；删 `map_index`/`edge_*`/Bayer/6 邻环。**sampler 8 → 2**。新增独立开关 `weather_cell_field_enabled`（默认 false） |
| **O3 迷雾** | k 走锐化权重三格混合（`fog_field_band` 默认 0.6）；扭曲按长度 clamp、`A_max = (√3/2 − band/2)·hex_size`；**强制不透明**由迷雾自己复算地形早退判定（同一 `PK_FIELD_BAND_MAX`、同一张地形扭曲场、`fog_hidden_margin` 吸收半分辨率上采样）。**不新增开关**，跟随 `_cell_field_active()` |
| **O2↔O3 接口** | `fog_field_band` / `fog_warp_freq` / `fog_warp_amp` 收敛到 `fog_of_war_layer.gd` 单一真源；天气的迷雾门控改用**迷雾的**扭曲（含同一个 `A_max` clamp）构造 k 的三角形 —— 否则云的消失边界与薄纱边界仍分家 |

### 10.2 验证（关键数字）

- `terrain_shader_variant_test` **368 / 0**；`hex_cell_field_parity_test` 44 / 0；`cell_field_gpu_parity_probe` vulkan **19 / 0**。
- `weather_overlay_field_test`（新）**162 / 0**：sampler 8 → 2（等值 + 名单 + 类型）、9 条符号双向断言、`weather_table` 无 `source_color`、`compute_cloud_lighting` 不含 type 参数。
- `weather_table_layout_test`（新）headless **82 / 0**（1 skipped）；真后端 **85 / 0**：逐字节对照重排结果、翻转后 prev 层仍是上一次 cur。
- `fog_cell_field_test`（新）headless **128 / 0**（不变量 SKIPPED）；**vulkan 141 / 0**：
  - 不变量 1：`terrain_hidden` 13955 / 76800 像素，最小 alpha **255/255**，违例 **0**（关掉早退的对照组有 4283 个 <254 ⇒ 非恒真）；
  - 不变量 2：k=1 世界全屏 alpha>0.02 的像素 **0.0000%**，格心采样 56 个全清。
- 关闭还原：两份 shader 在 `PK_CELL_FIELD` 未定义时**逐字节不变**（迷雾侧做了「HEAD 版 vs 当前版展开后 1129 行完全相同」的直接比对）。
- Web 预热：fog 条目改由 `fog_prefix_active()` 给字节，三态（开 / 关 / boot-fail）各一条**逐字节等于运行期**的断言，并做了变异验证（退回旧行为立刻红）。

### 10.3 开关状态（2026-11-18 收尾）

天气的独立开关 **已打开**（用户要求）：

| 位置 | 值 |
|---|---|
| `project.godot` 的 `[project_keynes]` | `rendering/map_tiles/weather_cell_field_enabled=true`（与 `terrain_cell_field_enabled=true` 并列） |
| `WeatherLayer.cell_field_setting_enabled()` 的 fallback | **`true`** |
| `WeatherLayer.weather_cell_field_enabled` 的 export 初值 | **`true`** |

回退：① GM/inspector 关 export；② 项目设置改 `false`（前缀逐字节还原）。**迷雾没有独立开关**，
跟随 `_cell_field_active()`（= 地形开关 + boot 自检），所以现在也一起生效。

同步更新了 `weather_overlay_field_test.gd` 的「出货默认关」断言（export 默认值、以及把 legacy
形态断言改成**先显式把项目设置置 false 再建 layer**，跑完还原），162 → **164 断言**。

### 10.4 未做与已知偏差

1. **O4 只做了迷雾那一半**：不变量 1/2 已有真后端实测，但天气的 `dom offset` / `Σw` / `terrain_hidden`
   逐点 CPU 比对还没接进 `cell_field_gpu_parity_probe`。
2. **O5 雨幕、O6 云影未做**（O5 本方案即列为可选；O6 是后续项）。
3. **移动/Web 的性能与视觉判据未实测**：§6 的「overlay pass 移动 ≤1.15× / 桌面 ≤1.0×」「任意缩放无方块」
   「雨晴交界色调连续」「迷雾边形态」都需要开窗口跑真机矩阵。本轮只在桌面 Vulkan 验过
   （本机 `--rendering-driver opengl3` 在 03:31 之后出现 `Unable to initialize video driver`，
   适配器枚举成 Intel UHD 770；**没有为绕过它改任何断言**）。
4. **有意的视觉变化（需美术确认）**：① 迷雾边扭曲幅度约减半（`A_max = 0.566·hex_size` vs 旧
   `1.1·hex_size`）；② 天气低雾的「山地权重」在 PK 路径统一成桌面档（移动/Web 旧的二值近似会在
   普通陆地上多一点低雾）；③ ~~迷雾 padding 语义改为与地形一致（k=1 视作全知）~~ ——
   **已回退，见 §10.5**。
5. **`VisionSolver.BLUR_ITERATIONS` 未动**：场插值 + 两环 blur 可能双重柔化，需视觉验收时对比 2/1/0。
6. **`weather_table_valid=false` 时 PK 路径整层无云**（旧路径只是少风向）；而 `weather_table_commit_plan`
   依赖风场字节 ⇒ 风场上游断供会让天气整体消失。这比 §7 预估的更硬，W5 应复核。
7. **发现但未修（超出范围，建议单独开票）**：`web_shader_warmup.gd` 的 **weather_overlay 条目仍是错的** ——
   预热写 `PK_WEB_WEATHER_MIN + TIER_PREFIX`（含 `PK_WEB_TEXTURE_BUDGET`、缺 `PK_WEATHER_*` 档宏），
   而运行期 `weather_layer.gd::_load_overlay_shader()` 的第一段是 `PK_WEATHER_LOW/MID/HIGH` 且从不加
   budget 宏 ⇒ Web 上天气 overlay 首次绘制仍会真编一次。修它要先定「web 运行期预热哪一档 quality」，
   属设计决策。

### 10.5 上线后修复：迷雾把上下 padding 的冰漏出来了（2026-11-18）

**用户截图报告**：世界上下各出现一条蓝色冰带（迷雾在那一圈变透明）。

**根因**：O3 把 padding 的 k 按地形侧「全知 k=1」写。但两侧的 k **语义相反**：

| 侧 | 表达式 | 语义 |
|---|---|---|
| 地形 `world_map.gdshader` | `field_fog = mix(1.0, aux.r, in_bounds(dom))` | **早退判定**：padding 不早退、照常渲染 |
| 迷雾 `fog_of_war.gdshader` | `fog_cell_k` 的 `mix(?, k, inside)` | **显示不透明度**：k 越大地图越透 |

写得「与地形一致」反而错了 —— 渲染出来的 padding（极地海冰）必须被迷雾**盖住**。

**修复**（两处，各一行）：
- `fog_of_war.gdshader::fog_cell_k()`：`mix(1.0, k, inside)` → **`mix(0.0, k, inside)`**；
- `weather_overlay.gdshader::wx_fetch_fog_k()`：`mix(B_SEA_ICE/255, v.r, inside)` → **`mix(0.0, v.r, inside)`**
  （原来是把一个 **biome 常量**混进 **知识度** 通道的笔误，与迷雾侧的 k 也对不上）。

**回归守**（`fog_cell_field_test.gd` 新增「不变量 3」，128 → 151 断言）：
- 合成一张 `map_h = 4`、内部 k 全 1 的 `cell_table`，探针世界矩形 `y ∈ [-80, +160]`
  **同时跨过南北两条边**；
- A：padding 带 **16320** 像素（北 11200 / 南 5120）alpha **≥ 254/255，违例 0**；
- B（防空转）：内部 32 个格心 alpha **< 0.02**，证明 A 不是「整屏不透明」作弊；
- C：padding 带南北各非空；
- 附加：padding 行的**显示用 k == 0**（钉住语义本身，不只是 alpha）；
- **变异验证**：把 `mix(0.0,…)` 改回 `mix(1.0,…)` ⇒ A 立刻红（16320/16320 违例，最小 alpha 0/255），
  改回后 `git diff` 与修复版逐字节相同。
- 判据细节：padding 带的边界不能按 `world_y < 0` 取 —— 六边形竖直半高 = `hex_size`，row 0 的格体
  延伸到 `y = -22`；实测按字面公式会假红 7844 个像素。正确做法是两端各内缩约束 2 的
  `A_max = (√3/2 − band/2)·hex_size = 12.45 wu`（显示侧 k 是在被扭曲过的采样点上算的）。
