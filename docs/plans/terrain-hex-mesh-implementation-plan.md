# 六边形地形网格（hex mesh）实施计划

> **状态：方案设计，未开工。** 本文只定架构与验收口径，不改任何代码。
> 日期：2026-11-17
> 代码根：`Project/project-keynes/`（下文路径均相对它）
> 前置阅读：`docs/plans/terrain-land-water-split-assessment.md`（现状的逐像素账、两 program 拆分的由来）

## 0. 一页结论

| 维度 | 结论 |
|---|---|
| 做什么 | 用**逐格生成的六边形网格**替换"一张世界矩形 quad + 逐像素索引图"的地形几何；格属性从顶点来，格界由几何决定 |
| 第一版不做什么 | 不做 Z 高度、不做有机弯曲边界、不做 3-way 角点混合、不动水面 program、不做 LOD |
| 主要收益 | ① 格界精度与缩放无关（消除 14px 点阵）；② SETUP 采样 6 → 3~4；③ 彻底不需要 Bayer dither |
| 主要代价 | 顶点数随格数增长；边界从"弯曲"退化为"直边"；多一份 shader 要维护 |
| 回退 | 单开关回退到今天的 quad 路径，逐像素一致 |

### 路线图

| 版本 | 内容 | 前置 |
|---|---|---|
| **v1** | 陆地几何 + SETUP 换顶点属性 | — |
| **v1.5** | 水面 mesh（§10） | §9.1 类别边界细分 |
| **v2** | 3-way 角点混合（§9.2）/ 采样合并（§9.5）/ Web 水面路径 | v1.5 |
| **v3** | Z 高度（真 3D，换渲染后端与相机） | — |

第 3 节起除特别标注外，均指 v1。

## 1. 目标与非目标

### 1.1 目标（v1 必须达成）

1. 地形的格界由几何边界决定，任意 zoom 下都是连续过渡，不再出现索引图分辨率的量化点阵。
2. 陆地 program 的 SETUP 不再采 `map_index_atlas` 与 `enum_lut` 的静态部分；格界距离由格内局部坐标解析算出，不采 `edge_distance`。
3. 保留现有 land/water 双 program、quality 档位、Web 降级、热重载、debug 视图的全部行为。
4. 生成器输出的数据模型预留 Z 高度（v1 恒为 0），换 3D 时只改渲染后端，不改生成器。

### 1.2 非目标（v1 明确不做）

- 真 3D 地形（`MeshInstance3D` + `Camera3D` + 透视俯角）。
- 有机/侵蚀弯曲的格界（v1 不做；它是 v1.5 水面的硬前置，见 §9.1）。
- 3-way 角点混合（v2 做，见 §9.2）。
- 水面几何的替换（v1 水面继续吃现有覆盖 mesh 与索引图，见 §3.6）。
- LOD / chunk 流式加载。

## 2. 为什么做：三条量化依据

### 2.1 边界精度被索引图分辨率锁死

| 项 | 数值 |
|---|---|
| 世界宽（60×40 图，hex_size 22） | ≈ 2393 wu（`wrap_period_x` = 2286.31） |
| 索引图宽（桌面 `HM_MAX_DIM_DESKTOP`） | 1024 texel |
| 1 texel 覆盖 | **2.34 wu** |
| `Camera2D.zoom_max` = 6 时 1 texel | **≈ 14 屏幕像素** |
| 移动端索引图 512 | 1 texel = 4.7 wu → 放大后 ≈ 28 px |

`map_index_atlas` 是 NEAREST 采样，且烘焙期在索引层做了 Bayer dither 来软化离散硬边。**dither 的点距就是 texel 尺寸**——所以放大后必然看到 14px 的点阵，这是架构上限，不是参数问题。

### 2.2 SETUP 的采样预算

`world_map.gdshader` 的 fragment SETUP 无条件 6 次采样（`world_map.gdshader:326-381`）：

| 采样 | 内容 | v1 处置 |
|---|---|---|
| `noise_tex` | 每像素细节噪声 | 保留 |
| `height_tex` | 高程 + 河道 SDF + 运河 SDF | **保留**（亚格细节） |
| `edge_distance` | 到格界距离 | **删除**，由顶点局部坐标解析算 |
| `map_index_atlas` | biome + cell id + landform | **删除**，格属性在顶点 |
| `dyn_lut` | 温度/湿度/活力/雪/海冰 | 保留（每日变） |
| `enum_lut` | biome/veg/cover + `fog_k` | **静态部分删除**；`fog_k` 另留（见 §8.1） |

陆地管线总量约 19–25 次（`material 1 + surface 2 + micro 1 + shore 8 + horizon 4 + GI 3 + 条件 fbm`），所以 **SETUP 这一刀是 3/6，不是总量的一半**。真正的采样大头是 shore 的 8 tap——它要等顶点携带邻居数据之后才能省（v1 顺手做掉一部分，见 §3.4）。

### 2.3 渲染器不需要"语义归属"

选格、寻路、模拟走的是 CPU 侧的 `HexUtils.world_to_cube`，与渲染无关。渲染里的 cell id 只是**查表的键**：颜色可以自由混合，只有"取 `dyn_lut` 里某一格温度/雪线"这类操作需要一个离散的下标。v1 用主导权重取一格即可（dyn 值本身连续，看不出接缝）。

## 3. 架构决策

### 3.1 拓扑：每格 fan，角点按格复制

```
每格：1 个中心顶点 + 6 个角点 = 7 顶点 / 6 三角形
角点不跨格共享（同一世界位置在 3 个格各存一份）
```

- 每个 fan 三角形 `(中心, 角 i, 角 i+1)` 恰有**一条**格界边 ⇒ 每个三角形恰好对应一个邻居。这是选 fan 而不是"内环 + 边带"的理由：邻居 id 可以用 `varying flat` 逐三角形传，不需要内环。
- 角点按格复制后，格内数据（terrain/veg/cover/landform）天然无歧义；跨格歧义只发生在**邻居数据**上，而邻居是逐三角形唯一的。
- **角点坐标必须由全局 lattice 生成**：以 `(q, r, 方向索引)` 为键算角点位置，保证相邻三格算出的同一角点比特一致，否则共享边会出现发丝裂缝。

### 3.2 归属：几何即归属（v1 不做 discard）

现有 hex 覆盖是"世界 quad + 逐像素判定"；改成逐格 fan 后，fan 恰好铺满本格六边形，相邻格只共享边界线、不重叠。因此：

- **v1 不需要 `cube_round` 判定，也不需要 `discard`**。旧 `hex_terrain.gdshader` 之所以要 `world_to_cube + cube_round + discard`，是因为它每像素做了 domain warp，导致 fan 互相侵入；v1 不做 warp（见 §9.1），这一步可以整段省掉。
- 副作用：每个格子的 fan 只画自己的面积，画面由几何保证，天然免疫 SIMT 发散。

### 3.3 混合：沿边 2-way，权重在角点归零

对 fan 三角形 `(中心, 角 i, 角 i+1)`，其格界边是 `角 i → 角 i+1`，对边邻居 `N`：

```
w_nb = blend_profile(s) * edge_falloff(d)
  s = 沿边参数 [0,1]        —— 两端为 0，中点最大
  d = 到格界边的距离（由 v_local 解析算）
  w_self = 1 - w_nb
```

- `blend_profile` 两端归零是**必需**的：角点处三条边带若各自按 0.5 混合，会得到三种不同的值（A↔B、A↔C），在角上形成楔形色差。归零后角点恒为"本格纯色"，三格在角上各自画自己，只剩一个像素的三叉点，无楔形。
- 两侧一致性：A 侧在边界上算 `mix(A,B,0.5)`，B 侧算 `mix(B,A,0.5)` —— 同一个值，所以接缝两端颜色一致，不需要共享顶点。
- 带宽用**世界单位**（或 hex 比例），沿用现有 `terrain_ecotone_width` 的量级（0.84），并由 `fwidth` 做屏幕空间下限，避免缩小时变成亚像素硬边。

### 3.4 顶点属性布局（v1 提案）

canvas_item 每顶点可用：`UV`(vec2)、`COLOR`(vec4, 8bit)、`CUSTOM0/1`(各 vec4, float)。

| 通道 | 内容 | 插值 |
|---|---|---|
| `UV` | 格内归一化局部坐标（中心=0，角点≈1） | 线性（用于 SDF / 细节 / 风蚀） |
| `CUSTOM0` | `(cell_index, nb_cell_index, w_self_bias, seed)` | `.xy` 用 `flat`，`.zw` 线性 |
| `CUSTOM1` | `(terrain_self, terrain_nb, vegetation, cover)` | `.y` 用 `flat`，其余线性 |
| `COLOR` | `(landform, water_depth, flavour, reserved)`，8bit | 线性 |

- `cell_index` 是 `HexCell.index`（与 `cell_lut_uv()` 同一套编号），用于查 `dyn_lut`。
- `landform` / `water_depth` 的 8bit 量化在视觉上可接受；**高程不放 COLOR**（`height_tex` 的 16bit RG 已经够，且空间细节在纹理里）。
- 邻居只带 `terrain` 与 `cell_index` 两项：颜色混合需要前者，查动态状态需要后者。`vegetation`/`cover` 只影响本格，不参与跨界混合。
- v1 顺带收益：shader 里原本 8 次 `sample_shore_neighborhood` 的邻域查询，可以用顶点上的 `water_depth` + `nb_cell_index` 部分替代（能替代多少视 `shore_common.gdshaderinc` 的公式而定，作为 P4 的可选项）。

**待验证**：Godot 4.6 的 canvas_item + `ArrayMesh` 需要给 `ARRAY_CUSTOM0/1` 指定 `ARRAY_CUSTOM_RGBA_FLOAT` 格式位；本工程目前没有任何 `ARRAY_CUSTOM` 用法（已 grep 确认），旧 `hex_terrain` 用过但生成代码已删。**这是最高风险项，P0 先做最小验证。**

### 3.5 shader 组织

- 新增 `shaders/world_map_hex.gdshader`：`#include` 复用现有管线（`height` / `hillshade_tod` / `land_pipeline` / `water` / `global_adjustments` 等），只重写 **SETUP** 这一段。
- 现有 `world_map.gdshader` **一行不改**，作为回退路径与 A/B 对照。理由：它是最贵的 shader，改注释都会触发重编；且两条路径并存期间必须能逐像素对比。
- 分叉风险由测试守：新增 `tests/world/hex_mesh_shader_contract_test.gd` 断言两份 shader 的 include 集合一致、管线入口（`render_land_pipeline` / `render_water_pipeline`）签名一致。

### 3.6 v1 的替换边界

| 对象 | v1 处置 |
|---|---|
| 陆地 program 的几何 | 换成 hex mesh |
| 陆地 program 的 SETUP | 换成本文 §3.4 的顶点属性 |
| 水面 program（所有平台） | **v1 不动**：继续用现有覆盖 mesh / 整张 quad + `map_index_atlas`；v1.5 换 mesh（§10） |
| `map_index_atlas` / `enum_lut` / `edge_distance` 纹理 | **v1 不删**（水面与其它图层仍在用），只是陆地 program 不再采 |
| `terrain_coverage_mesh.gd` | 保留；hex 模式下陆地覆盖 mesh 不再生成 |

这样 v1 的收益是"陆地画质 + 陆地采样"，而水面、建筑、植被、迷雾全部零改动。

### 3.7 Z 高度的预留方式

canvas_item 的 `VERTEX` 是 vec2，**v1 的渲染路径在物理上不可能有真 Z**。预留只能做在数据模型上：

- 生成器输出 `PackedVector3Array`（v1 的 z 恒为 0），装配 2D mesh 时取 `.xy`。
- 生成器 API 接受可选的 `height_provider: Callable`（`(cell) -> float`），v1 传 `null`。
- 顶点属性布局预留 `COLOR.a`（reserved）与一个未用的 `CUSTOM` 通道，v2 用来放坡度/法线而非高度。

将来换 3D 需要同时改：`MeshInstance3D` + spatial shader + `Camera3D`（透视俯角）+ 所有依赖 `z_index` 的图层排序 + 建筑/植被的深度关系。**这是独立阶段，不在本计划内。**

## 4. 接口与接入点

### 4.1 生成器

新增 `scripts/rendering/terrain_hex_mesh.gd`（`class_name TerrainHexMesh`，`RefCounted`，与 `terrain_coverage_mesh.gd` 同构）：

```gdscript
static func build(
        map: MapData,
        world: WorldData,
        profile: Dictionary,                     # PROFILE_LAND / PROFILE_WATER，见 §10.3
        hex_size: float,
        wrap_period_x: float,
        height_provider: Callable = Callable()   # v1 传空；v3 传高度场
) -> Dictionary
# → { ok, reason, mesh, stats }
#   stats: { build_ms, cells, vertices, triangles, wrap_copies,
#            corner_dupes, blend_band_wu }
```

约束：

- **`profile` 从 P1 就要有**，哪怕 v1 只有 `PROFILE_LAND`。属性布局是 v1.5 水面复用这套生成器的唯一接口，事后再加要返工（见 §10.3）。
- 失败返回 `ok=false` + `reason`，不抛异常（与 `TerrainCoverageMesh.build` 一致）。
- `wrap_period_x > 0` 时同一份几何在 −P / 0 / +P 各放一份，**进同一个 mesh**（与 `renderer_map_assets.gd:5` 的既有约定一致）。
- 三角形计数自检：`triangles == cells * 6 * wrap_copies`，不符即 `ok=false`。

### 4.2 接入点

- 唯一几何真源仍是 `RendererTerrainHorizon._apply_world_quad_geometry()`（`renderer_terrain_horizon.gd:662`）。hex 模式在这里分支：生成 hex mesh → 赋给 `_world_quad.mesh`；水面 quad 继续走 `_water_quad_mesh()`。
- 新开关：`@export var terrain_hex_mesh_enabled := false`（v1 默认关，验收后改默认）、`@export var terrain_hex_blend_band_wu := 8.0`。
- 回退条件（任一命中即回退整张 quad）：模块缺失 / `ok=false` / debug 视图非 0 / 水面 miss / Web 低画质档（待定，见 §8.3）。

### 4.3 uniform 与推流

- hex 材质复用 `world_map_material.tres` 的 uniform 集减掉 `map_index_atlas` / `enum_lut` / `edge_distance` / `terrain_edge_*`，新增 `blend_band_wu`。
- 所有世界 uniform 的推送仍走 `_push_world_uniform()`，与水面材质镜像的逻辑不变。
- Web：新 program 必须登记进 `scripts/rendering/web_shader_warmup.gd` 的 plan 列表，否则首次进图会卡在编译。

## 5. 阶段计划

| 阶段 | 内容 | 工作量级 | 完成判据 |
|---|---|---|---|
| **P0** | 最小验证：`ArrayMesh` + `ARRAY_CUSTOM0/1` + `MeshInstance2D` + `varying flat` 在 mobile 后端（d3d12）与 Web（GLES3）都能取到值 | S | 一个画三角的 probe 场景，CUSTOM 值能原样到 PS；两份后端都过 |
| **P1** | `TerrainHexMesh.build()` + 单测：顶点/三角形计数、角点比特一致、wrap 三份、格属性覆盖 | M | `tests/rendering/terrain_hex_mesh_test.gd` 全绿 |
| **P2** | `world_map_hex.gdshader` 的 SETUP + 采样断言 | M | 源码断言：无 `map_index`/`enum_lut`/`edge_distance` 采样；`terrain_shader_variant_test` 扩展通过 |
| **P3** | renderer 接入 + 开关 + 回退 + uniform 推流 | S | 开关切换不崩、可逐像素 A/B |
| **P4** | 混合带打磨：`blend_profile` / `fwidth` 下限 / 纸感细节对齐；可选：用顶点邻居数据削 shore tap | M | zoom 0.25–6 全档截图无点阵、无楔形；采样数达标 |
| **P5** | Web/移动档位 + warmup 登记 + pck 体积核对 | S | 首编不超现有 program 1.2×；体积无新增 |
| **P6** | 验收、文档、默认开关翻转 | S | §6 全部达标 |

**v1.5（水面，前置 §9.1）**：

| 阶段 | 内容 | 工作量级 | 完成判据 |
|---|---|---|---|
| **W0** | 类别边界细分（§9.1），先在陆地侧验收 | L | zoom 6 下海岸不再是直边；顶点数在预算内 |
| **W1** | `PROFILE_WATER` + 水格生成 + 单测 | M | 水格数 / 与陆地共享角点比特一致 / `land_mask` 正确 |
| **W2** | 水面 SETUP 重写：整段删掉 `compute_lake_shore_proxy` 与 3×3 高度环 | M | §10.6 的采样与湖岸一致性达标 |
| **W3** | 岸线 / 冰缘视觉配平 | M | 全 zoom 档无点阵、海岸无六边形锯齿 |
| **W4** | Web 档位 + warmup + 验收 | S | 首编、体积、回退全部达标 |

## 6. 验收标准

| 项 | 判据 |
|---|---|
| 边界精度 | zoom 6 截图：格界无 14px 点阵；与索引图路径对比，边界带宽度差 < 10% |
| 数据一致性 | 格内部像素（距格界 > 1 hex）的 biome / veg / cover 与索引图路径一致率 ≥ 99.9% |
| SETUP 采样 | 陆地 program 从 6 降到 ≤ 4（以 shader 源码 + `get_shader_uniform_list()` 双重断言） |
| 角点 | zoom 6 下每个角点无楔形色差；三叉点允许 1px 硬接 |
| 顶点预算 | 60×40：≤ 5 万（含 wrap 3×）；100×64：≤ 20 万 |
| Web 首编 | ≤ 现有 `world_map` program 的 1.2×（`warmup_shader` 遥测） |
| 体积 | 不新增贴图；pck 变化 < 1MB |
| 回退 | 开关关闭时与今日逐像素一致（截图 diff = 0） |
| 回归 | `terrain_coverage_mesh_test` / `land_water_split_node_test` / `terrain_shader_variant_test` / `hex_mesh_*` 全绿 |

## 7. 风险

| 风险 | 影响 | 缓解 |
|---|---|---|
| canvas_item 的 `CUSTOM0/1` 在移动/Web 后端行为未知 | 阻塞整个方案 | P0 先验，不通过则退回"全部塞 COLOR（8bit）+ UV 复用"的降级布局 |
| **直边边界视觉退化**：现在索引图的边界是烘焙期侵蚀场弯曲的，v1 是直边 | 高 zoom 下"六边形感"变强，可能比 dither 更难看；**水面更严重**（湖泊会变成六边形坑） | 靠混合带宽 + 纸感噪声遮；根治靠 §9.1 类别边界细分（v1.5 的前置）。**这是 v1 最需要玩家验收的一项** |
| 角点归零导致的"角上偏硬" | 低 zoom 下格与格之间对比过强 | 角点归零只影响角点邻域；可调 `blend_profile` 的归零宽度 |
| 顶点数 × wrap 3 份 | 100×64 图 20 万顶点、上百 MB 带宽 | v1 只做单 mesh 不分块；若超预算再上 chunk（Godot 无 65535 上限，不是硬约束） |
| 两份 shader 的 SETUP 漂移 | 静默色差 | `hex_mesh_shader_contract_test` 守 include 与签名 |
| 水面仍吃索引图 | v1 只兑现一半收益，且两套几何并存 | 明确接受；v1.5 换水面（§10），但它把 §9.1 从"可选"变成"必做" |
| 水面与陆地的海岸接缝 | 发丝裂缝 / 1px 亮边 | 两者必须共用同一套**角点 lattice**（§3.1 的约束对水同样成立）；跨海陆的顶点位置逐位相同 |

## 8. 未决问题

1. **`fog_k` 放哪**：它随探索变化（动态），放顶点要频繁重传。建议 v1 仍走 LUT，但可以并进 `dyn_lut` 的空闲通道或单独一张 R8，避免多一次采样。需要先确认 `dyn_lut` 四个通道的实际占用。
2. **`blend_band_wu` 的默认值**：现有 `terrain_ecotone_width = 0.84`（单位待确认是 hex 还是归一化），hex 版按世界单位给更直观，需要一次实机配平。
3. **Web 低画质是否走 hex**：顶点处理在低端 WebGL 上是开销。建议 Web 低档继续走现有索引图路径，只在中高档启用 hex。
4. **是否保留 `map_index` 的 debug 视图**：`terrain_surface_debug_view` 里有几个视图直接展示索引图，hex 模式下需要新的可视化或回退。

## 9. 后续（不在 v1）

### 9.1 类别边界细分（v1.5 的前置，不是可选项）

把格界从"直边"变成"侵蚀弯曲边"，但**只对两侧类别不同的边做**：

- 深海、大平原内部的边两侧同类，粗着画看不出——不细分。
- 海岸、湖岸、冰缘、礁缘、生物群系边界才细分。
- 成本从 `O(所有边)` 降到 `O(类别边界)`：若边界边占全部边的 1/4，N=8 段时顶点数是 fan 的 3~4 倍，而不是 8 倍。

实现要点：

1. 生成期先判每条边的两侧类别（与 `is_water_render_lut` / `enum_lut.R` 同源）。
2. 每条需要细分的边插 N 个点，位移量由 warp 场给出。**必须与烘焙 `edge_neighbor` / `edge_distance` 使用同一个场**，否则新边界与次生格数据错位，混合带会跟到错误的邻居上。
3. 位移后的每个边界顶点仍要能反查"属于哪两格"——保留 `(self, nb)` 对，`varying flat` 的用法不变。
4. 位移幅度受 `terrain_ecotone_width` 约束：几何弯过去的距离不能超过混合带，否则会出现"几何弯了、颜色没跟上"的错位。

**未决**：warp 场目前是 per-pixel 烘进索引图的，取出来做几何位移需要它变成一张可采样场，或在生成期用同一噪声 + 同一 seed 重算。后者的风险是两套实现的浮点差异会让边界与次生格数据出现亚像素错位，需要一次 A/B 校验（同一批像素的 warp 输出，CPU vs 烘焙）。

### 9.2 3-way 角点混合

参考 USG（天工）的做法：三色染色保证每三角形三顶点可区分 + 顶点复制破解拓扑冲突 + 重心坐标天然作权重。对本项目的意义是消除角点的硬三叉点。**前提是 §9.1 已做**（直边的角点问题很小，不值得引入染色复杂度）。

### 9.3 Z 高度

见 §3.7。生成器已经输出 Vector3，届时只需换渲染后端与相机体系。

### 9.4 水面换 mesh

已展开为 v1.5 的正式方案，见 **§10**。

### 9.5 采样合并

把 `dyn_lut` + `fog_k` + `enum_lut` 的残余动态位合并成一张 `state_lut`，SETUP 从 4 降到 3。

## 10. 水面 mesh（v1.5）

### 10.1 为什么水面的 ROI 比陆地高

`water_pipeline.gdshaderinc` 的开销几乎全部是"查邻居格"：

| 位置 | 采样数 | 内容 | mesh 后 |
|---|---|---|---|
| `compute_lake_shore_proxy`（:148-212） | 8 + 4（+4，quality≥2） | 3×3 与半径 2/3 的环，全采 `map_index` 判"附近有无非湖格" | **0**：改用 `v_local` 到边距离 + 顶点 `land_mask` |
| 3×3 高度环（:262-267） | 9 | 数深水像素 | **0**：改用邻居水深 |
| 其他 `visual_sample_map_index` | 3 | 类别判定 | **0**：类别在顶点 |
| `visual_sample_water_depth` | 1 | 水深 | **0**：逐格常量进顶点 |
| `sample_shore_neighborhood` | 8 | 岸线 | 视公式，大部分可用顶点邻居类别/水深替代 |
| **合计** | **~31–35 / ~50** | | 目标 ~20 |

顺带修掉一个隐性不一致：`compute_lake_shore_proxy` 的探测半径是 **texel 单位**（`o * tx`，`o` 最大 3）。桌面 1 texel = 2.34 wu ⇒ 最多探 7 wu；移动端 1 texel = 4.7 wu ⇒ 探 14 wu。**同一份代码在不同平台的湖岸晕染宽度差一倍**。mesh 版用解析距离，与分辨率无关。

### 10.2 数据分类

| 类别 | 字段 | 载体 |
|---|---|---|
| 类别量 | 水体 biome（海/湖/礁/海带/海冰）、是否临陆、跨边邻居类别 | 顶点 |
| 逐格常量 | `cell.water_depth` | 顶点（现状是扇出成逐像素纹理，见 `world_data.gd:46`） |
| 连续场 | `ocean_current_flow_tex`、波浪、焦散、泡沫 | 纹理（保持） |
| 动态逐格 | `sea_ice_frac`、温度 | LUT（每日变） |
| 非格数据 | 河流 / 运河 SDF（`height_tex.B/A`） | 纹理（保持，删不掉） |

水深进顶点后是"相邻格水深插值"，比现在的硬台阶更平滑——这是净收益，不是妥协。

### 10.3 属性 profile（生成器参数化）

```gdscript
const PROFILE_LAND := {
    "custom0": ["cell_index", "nb_cell_index", "w_bias", "seed"],
    "custom1": ["terrain", "nb_terrain", "vegetation", "cover"],
    "color":   ["landform", "water_depth", "flavour", "reserved"],
}
const PROFILE_WATER := {
    "custom0": ["cell_index", "nb_cell_index", "w_bias", "seed"],
    "custom1": ["water_class", "nb_water_class", "land_mask", "ice_flags"],
    "color":   ["depth8", "temperature8", "flow_seed", "reserved"],
}
```

- `land_mask`：6 bit，标记 6 个方向是否临陆 ⇒ 岸线判定一次算完，不再打环。
- `ice_flags`：bit0 湖 / bit1 礁 / bit2 海带 / bit3 海冰候选。
- **`depth8` 的精度风险**：水深直接驱动水体颜色，8bit 会有台阶。两种选择：(a) 水深占 `CUSTOM` 的 float 位；(b) 保留 `water_depth_tex` 只给水面 program 用。**W1 实测决定**，倾向 (a) 并把 `flow_seed` 挪走。

### 10.4 海岸线的取舍

水面 mesh 的边界就是海岸线，两个后果必须正视：

- **海岸从"自然弯线"变成六边形直边**，高 zoom 下是明显退步。
- **湖泊会变成六边形坑**，比陆地更刺眼——湖是玩家会盯着看的孤立形状。

因此 **§9.1 类别边界细分是 v1.5 的硬前置**，不是"以后再说的优化"。深海内部的边不受影响（两侧同类，不细分），细分成本只跟海岸线长度成正比。

### 10.5 实现要点

- 只生成水格：判据与覆盖 mesh 相同（`MapData.is_water_render_lut()`），边界自然落在海岸。
- 岸线：`distance_to_edge`（`v_local` 解析）+ `land_mask` 决定哪侧是陆。`shore_common.gdshaderinc` 的公式**不改**，只换输入来源（纹理采样 → 顶点 + 解析距离）。
- 海冰：`sea_ice_frac` 仍在 LUT，但**冰缘位置由几何决定**，所以冰缘不再有 dither 点阵。
- `PK_WATER_ONLY` 的 program 结构不变；`world_water_web.gdshader` 保持现状（Web LOW/MID 的独立精简程序，最后一批换）。
- **与陆地共享角点 lattice**：跨海陆的同一世界位置必须逐位相同，否则海岸会出现发丝缝或 1px 亮边。

### 10.6 验收（v1.5）

| 项 | 判据 |
|---|---|
| 采样 | 水面 program ≤ 25（现状 ~50）；`compute_lake_shore_proxy` 整函数删除 |
| 湖岸一致性 | 桌面与移动的湖岸晕染宽度差 < 5%（现在是 2 倍） |
| 海岸 | zoom 6 下海岸无六边形锯齿；湖泊不呈明显六边形 |
| 冰缘 | 海冰边界无 dither 点阵 |
| 顶点 | 60×40 约 1000 水格 × 7 × wrap 3 ≈ 2.1 万，可忽略 |
| 回退 | 开关关闭时与今日逐像素一致 |

### 10.7 不做什么

- 不删 `height_tex`（河流 / 运河在 B/A 通道）。
- 不改 `world_water_web.gdshader`（最后一批）。
- 不做"同类格合并成大多边形"：深度与洋流逐格不同，合并即丢数据。

## 附录 A：与 USG（天工编辑器）的对照

| 维度 | USG（天工） | 本项目 v1 |
|---|---|---|
| 网格 | 4×4 grid per tile，32×32 grid per chunk | 1 hex per cell，fan 7V/6T |
| 格属性载体 | 顶点存 LayerId（→ 纹理数组） | 顶点存 `cell.index` + terrain/veg/cover |
| 混合权重 | 三色染色 + UV3 插值出 `(b0,b1,b2)` | 沿边 profile × 到边距离，`varying flat` 传邻居 |
| 冲突处理 | BFS 染色 + 顶点复制 | 角点按格复制 + 权重归零 |
| 材质分流 | 非混合三角形 / 混合三角形两套材质 | v1 不做；v2 可借（按"是否跨格"分 mesh + 材质） |
| 分块 | 必需（Unity 65535 顶点上限） | 不需要（Godot 32 位索引） |
| 有机边界 | 边界由模块化地形模型本身决定 | v1 无；v1.5 前置（§9.1 只细分类别边界） |
| 水面 | 与地表共用同一套网格与材质分流 | v1 不动；v1.5 换（§10），属性 profile 不同 |

参考文档（iWiki）：`p/4016913499` 地形网格生成系统、`p/4009237915` 地表混合细节、`p/4007105712` 天工地形功能。
