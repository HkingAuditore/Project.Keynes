---
name: hex-map-seamless-fusion-v3
overview: 通过「地形邻居混合」重写六边形边缘（让相邻地形在共享边两侧真正咬合渗透、消除拼图感），并全面重构河流系统（河岸湿土带、沿链流量递增的动态宽度、地形感知配色、扇形羽化入海口）。
todos:
  - id: review-architecture
    content: 使用 [skill:civ-grounded-development] 复核 hex_renderer / shader / MapData 架构，锁定改造边界与数据契约
    status: completed
  - id: refactor-terrain-mesh-attrs
    content: 重构 _rebuild_terrain_mesh：新增 _collect_corner_neighbors，打包 3 邻居 tid 与权重到 ARRAY_CUSTOM0/1
    status: completed
    dependencies:
      - review-architecture
  - id: refactor-terrain-shader
    content: 改写 hex_terrain.gdshader：读取 CUSTOM 通道，fragment 内按权重+噪声扰动混合 3 地形基色与纹理
    status: completed
    dependencies:
      - refactor-terrain-mesh-attrs
  - id: weaken-edge-overlay
    content: 弱化 hex_edge_overlay.gdshader 参数与 _append_edge_overlay 的 jitter/宽度，使其退为装饰溢出层
    status: completed
    dependencies:
      - refactor-terrain-shader
  - id: river-trace-and-tint
    content: 扩展 _trace_river_chain 输出 cumulative_flow 与逐点 terrain_tint，新增 _terrain_tint_for 查表
    status: completed
    dependencies:
      - review-architecture
  - id: river-bank-and-body
    content: 新增 _add_river_bank 与 _add_river_body_mesh（quad-strip），实现湿土带与沿流向动态河宽
    status: completed
    dependencies:
      - river-trace-and-tint
  - id: river-mouth-fan
    content: 用 _add_river_mouth_fan 扇形 mesh 替换 _add_river_mouth_v3 梯形堆叠，颜色径向羽化溶入海水
    status: completed
    dependencies:
      - river-bank-and-body
  - id: integration-and-perf
    content: 使用 [subagent:code-explorer] 校验顶点属性与 corner 邻居顺序，运行 60x40 地图复核生成≤20ms、视觉融合与玩法数据零回退
    status: completed
    dependencies:
      - refactor-terrain-shader
      - weaken-edge-overlay
      - river-mouth-fan
---

## 产品概述

对 Godot 4 六边形地图 2D 预览的渲染进行写实融合改造，消除可见的六边形拼图轮廓，让地形块之间在边界处大范围互相咬合与色彩渗透；同时重构河流与河口系统，让河流"长在"地面上而不是浮在上面。

## 核心特性

1. **六边形边界不可见**：跨格地形在共享边 ~30% 宽度范围内按"邻居地形场 + 噪声扰动"渐变混合，菱形直边被有机轮廓取代；当前过强的 edge overlay 弱化为装饰溢出。
2. **河岸湿土带**：在河流两侧生成宽度 3.5–4.5x 河宽的羽化"湿土/淤泥"色带，覆盖河道下方的 hex 接缝；色带颜色吸收经过地形的均值并加棕黑色调。
3. **动态河宽**：河流宽度沿链累计（上游细、下游粗），接近入海口时最宽；替换原统一粗线的 Line2D 堆叠。
4. **扇形羽化入海口**：废弃梯形多边形堆叠，改用 ~18 段扇面 mesh，每顶点颜色从河水色渐变到海水色，边缘 alpha 0，扇边缘做噪声扰动。
5. **地形感知河色**：按每段流经地形（沙漠偏黄 / 森林偏深 / 雪地偏浅 / 平原中性）调整河水 tint，避免全图一种蓝。
6. **性能与玩法零回退**：60x40=2400 格生成仍 ≤20ms，shader 60fps；terrain / has_river / elevation / move_cost 等数据字段不变。

## 技术栈

- **引擎**：Godot 4.x，GDScript + `canvas_item` shader
- **渲染管线**：`MeshInstance2D` + `ArrayMesh`（PRIMITIVE_TRIANGLES）+ `ShaderMaterial`，保持现有节点层级
- **纯程序化**：继续不引入外部贴图资源
- **兼容性**：严格不改动 HexCell / MapData / MapGenerator / TerrainType 等玩法数据结构

## 实现策略：邻居地形场 + 河流分层重构

### 1) 边界融合：从 "edge-overlay 细带" 迁移到 "地形 shader 内邻居混合"

- 重新设计 `_rebuild_terrain_mesh()` 的顶点属性：每个三角形由 1 个中心顶点 + 2 个角顶点构成；
- 中心顶点：`neighbor_ids = (self, self, self)`，`weights = (1, 0, 0)`
- 角顶点：该 corner 由当前格和其两侧共享该 corner 的邻居格共享，`neighbor_ids = (self, nb_left, nb_right)`，`weights = (1/3, 1/3, 1/3)`
- 通过 `ARRAY_CUSTOM0`（vec4）携带 `(tid_self, tid_nb_l, tid_nb_r, w_self)`；`ARRAY_CUSTOM1` 携带 `(w_nb_l, w_nb_r, elev_nb_mix, _pad)`
- Fragment 插值后得到连续的"邻居地形场"；shader 对 3 个 tid 各算一次 `terrain_base_color + 该地形纹理`，按权重混合；在格外圈 `hex_metric > 0.55` 的区域，用 `domain_warp + fbm` 扰动权重 → 边界轮廓碎裂 + 颜色渗透。
- 复用现有 `fbm / value_noise / ridged / voronoi_f1`；保留现有 `river_prox / elevation / coastal / seed` 打包约定（仍放在 COLOR 通道）。

### 2) Edge Overlay 层：大幅弱化为装饰溢出

- 保留节点结构（z=4）以便快速回退，但把 `dissolve_amount` 从 0.72 降到 0.35、`bleed_strength` 从 0.75 降到 0.30、overlay 宽度因子从 0.30 降到 0.10，整体 alpha 乘 0.5；
- Renderer 侧 `_append_edge_overlay` 的 `segments` 保留 11，但 `n_jitter` 幅度收敛，不再抢戏。

### 3) 河流系统重构（z_index 新层序）

```
TerrainMesh(0) → RiverShadow(1) → RiverBank(1.5, NEW) → TerrainDetail(2)
→ RiverBody(3) → RiverHighlight(3.5) → EdgeOverlay(4, 弱化)
```

- `_trace_river_chain` 追加 `cumulative_flow`（沿链 0→1）与 `terrain_tints`（逐点地形 tint）
- `_add_river_bank`（NEW）：沿 smooth_points 生成 quad-strip Mesh，宽度 = base_width * lerp(3.2, 4.6, flow)，顶点色 = `bank_color(terrain_tint)`，中心 alpha 0.55 → 两侧 alpha 0；此层用独立 `MeshInstance2D`，shader `canvas_item` blend_mix
- 动态河宽：放弃 Line2D 的 `width_curve`，改用自建 quad-strip（与 bank 同骨架），每点宽度 = base_width * lerp(0.55, 1.35, flow)；保留 3 层（outer/core/highlight）但都走 mesh
- 地形感知配色：每点 `river_tint = lerp(river_color, terrain_tint, 0.25)`，顶点色插值→天然沿流向过渡
- 入海口扇形：检测到 water_neighbor 后，用 18 段扇面（开角 ~110°）在 `mouth_pos` 向 `mouth_dir` 扩张 2.5x hex_size；扇顶点色 = `lerp(river_tint, water_tint, t)`，径向 alpha 中心 0.45→边缘 0；半径带 `noise(angle)*0.25` 扰动打碎轮廓

### 4) 性能与稳定性

- 顶点数量：2400 格 × 7 verts ≈ 16800，扩展 2 个 vec4 CUSTOM 通道 → 增加约 16800 × 32 bytes ≈ 0.5MB，可接受
- 河流 quad-strip：10 条河 × 平均 60 points × 4 verts = 2400 verts，远低于原 Line2D 的像素开销
- shader 每片元计算 3 次地形色 + 3 次地形纹理 → 成本 ~3x，但因 2D canvas fragment 调用少（无 overdraw 的前提下 1920x1080 约 200 万片元），在现代 GPU 上 60fps 无压力
- 保留原 `_compute_river_proximity` 与 shader 内河流湿润区逻辑，配合 bank 层双重覆盖接缝

## 执行要点（Implementation Notes）

- **接口不破**：HexCell / MapData / TerrainType 完全只读；新增逻辑全部封装在 `hex_renderer.gd` 与两个 shader 内
- **浮点打包约定**：严格沿用 `COLOR.a > 0.9 = river marker` 规则，新属性全部走 CUSTOM 通道，避免潜在回退冲突
- **日志**：复用 `push_warning`，错误仅在 shader/资源加载失败处输出，不在 per-cell 循环打日志
- **可回退**：renderer 顶部新增 `@export var use_neighbor_blend: bool = true` 开关；关闭时回退到 v3 单格着色，便于 A/B 对比与紧急关停
- **z_index 新层**：`_bank_inst` 单独 `MeshInstance2D`，位于 `_river_shadow_root` 之下，`z_index=1` 中间插入，避免破坏 TerrainDetail(2) 的现有视觉

## 架构与目录

```
Project/project-keynes/
├── scripts/rendering/
│   └── hex_renderer.gd              # [MODIFY] 核心重构
│       - _rebuild_terrain_mesh: 扩展顶点属性 (CUSTOM0/1 携带 3 邻居 tid + 权重)
│       - _collect_corner_neighbors: [NEW] 计算每个 corner 两侧共享邻居
│       - _rebuild_edge_overlay: 保留但参数弱化
│       - _rebuild_rivers: 重构为 trace→bank→body→highlight→mouth 五阶段
│       - _add_river_bank: [NEW] quad-strip mesh，沿链加宽
│       - _add_river_body_mesh: [NEW] 替代 Line2D 堆叠，支持逐点宽度与颜色
│       - _add_river_mouth_fan: [NEW] 扇面 mesh，替代梯形 Polygon2D
│       - _terrain_tint_for: [NEW] 按 terrain 返回河色 tint
│       - _ready: 追加 _bank_inst / _body_inst / _highlight_inst / _mouth_root
│       - use_neighbor_blend 开关 @export
│
├── shaders/
│   ├── hex_terrain.gdshader         # [MODIFY] 邻居地形场混合
│   │   - 读取 CUSTOM0/1，fragment 内对 3 个 tid 各算一次 base_color+texture
│   │   - hex_metric>0.55 区域用 fbm 扰动权重，实现边界 dissolve
│   │   - 保留现有各地形纹理函数与河流湿润区逻辑
│   │   - 新增 uniform: blend_edge_start=0.55, blend_edge_end=1.05, blend_noise_amp=0.35
│   └── hex_edge_overlay.gdshader    # [MODIFY] 弱化为装饰层
│       - dissolve_amount default 0.72 → 0.35
│       - bleed_strength default 0.75 → 0.30
│       - 整体 alpha 输出乘 0.5
│
└── scripts/ (只读，不修改)
    ├── hex_cell.gd / map_data.gd / hex_utils.gd / terrain_type.gd / main.gd
```

## 关键数据结构（顶点属性契约扩展）

```
ARRAY_VERTEX : vec2 (pos)
ARRAY_TEX_UV : vec2 (local coord, 同 v3)
ARRAY_COLOR  : vec4 (terrain_id/15, elevation, coastal, packed_seed)    [同 v3, 不破坏]
ARRAY_CUSTOM0: vec4 (tid_self_n, tid_nb_l_n, tid_nb_r_n, w_self)         [NEW]
ARRAY_CUSTOM1: vec4 (w_nb_l, w_nb_r, elev_blend, reserved)               [NEW]
// corner 顶点: w_self=0.34, w_nb_l=0.33, w_nb_r=0.33
// center 顶点: w_self=1.0, w_nb_l=0, w_nb_r=0
// 无邻居时用 tid_self 填充并权重清零
```

## Agent Extensions

### Skill

- **civ-grounded-development**
- Purpose: 在实施前强制通读 renderer / shader / MapData / HexCell / TerrainType 现有架构，确认复用既有接口（get_neighbors / terrain_name / TERRAIN 枚举）而非新建字段；在改造 shader 前核对玩法数据读写链路，避免触碰 move_cost / passable_* 等机制字段
- Expected outcome: 改造范围锁定在 hex_renderer.gd + 两个 shader，玩法数据零改动，新增顶点属性只走 CUSTOM 通道，风格符合项目既有"CPU 构网格 + shader 程序化着色"模式

### SubAgent

- **code-explorer**
- Purpose: 在实施阶段按需跨文件验证 `HexUtils.cube_neighbor` 方向顺序、`edge_pairs` 与 corner 邻居对应关系、以及 Godot 4 `ARRAY_CUSTOM0` 格式声明（`Mesh.ARRAY_CUSTOM_RGBA_FLOAT`）
- Expected outcome: 顶点属性打包正确，corner 三邻居采集逻辑与现有六边形朝向一致，不出现 shader 接收到错位 tid