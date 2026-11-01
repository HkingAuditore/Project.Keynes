# 陆地/水面 双 program + 双 mesh 实施计划（Lead 下发）

> **状态：2026-11-02 已完成（未 commit）。** task-1（`split-program`）与 task-2（`coverage-mesh`）均已完成；Lead 独立复跑 4 套 headless 测试全绿（616/58/25/108 checks，0 failures），sampler 预算未变。最终验收清单与残余风险见评估文档 §8。

- 日期：2026-11-01
- 背景与评估：`docs/plans/terrain-land-water-split-assessment.md`（v3，先读它）
- 目标：**全平台（PC / Web / 移动）** 把主地形拆成
  1. **两个 shader program**：陆地 program（不含 `water_pipeline.gdshaderinc`）与水面 program；
  2. **两张保守覆盖 mesh**：陆地 mesh / 水面 mesh，纯区域只光栅化自己的 program；混合 block（海岸）两边覆盖、shader 内逐像素 `is_water` 互补 discard。
- 关键约束：**画面必须与今天逐像素一致**（分类逻辑与颜色管线不变，只改覆盖/程序划分）；**不使用 Alpha Clip Dither**；不做 profile（目标全平台，先按架构落地，性能由用户真机验收）。
- 工作树现状：HEAD `999fff4e7` + 大量 2026-11-01 未提交改动。**不许 commit、不许 stash、不许格式化无关文件**。

## 1. 文件所有权（写作用域，严禁跨界）

| 流 | 负责人 | 允许写的文件 |
|---|---|---|
| A：program 拆分 + renderer 集成 | teammate `split-program` | `shaders/world_map.gdshader`、`shaders/world_water_web.gdshader`、`scripts/rendering/hex_renderer.gd`、`scripts/rendering/web_shader_warmup.gd`、`tests/world/terrain_shader_variant_test.gd`、`tests/world/web_water_pass_node_test.gd`（可新增同目录测试）、`shaders/SHADER_DEV_GUIDE.md`、`docs/web-export.md` |
| B：覆盖 mesh 模块 | teammate `coverage-mesh` | 新增 `scripts/rendering/terrain_coverage_mesh.gd`、新增 `tests/rendering/terrain_coverage_mesh_test.gd`（只这两个） |
| 集成审查 + 评估文档 | Lead | `docs/plans/terrain-land-water-split-assessment.md`、`docs/plans/terrain-split-implementation-plan.md` |

`hex_renderer.gd` **只由 A 写**。B 不碰 renderer；A 按下面 §3 的 API 约定先接好调用点（模块不存在时自动回退整张 quad）。

## 2. 架构决策（已定，勿擅自改）

### 2.1 两个 program 的选取

- **陆地 program** = `world_map.gdshader` + 新宏 `PK_LAND_ONLY`：
  - 不 include `water_pipeline.gdshaderinc`；**必须保留 `water.gdshaderinc`**（河面法线 `sample_water_normal`，见 `land_pipeline.gdshaderinc:181-190` 的压平分支——不要把 `PK_LAND_ONLY` 加进那个 `#if`）。
  - 兼容别名：在 `world_map.gdshader` 顶部把既有 `PK_WEB_LAND_ONLY` 归一到 `PK_LAND_ONLY`（`#if defined(PK_WEB_LAND_ONLY) && !defined(PK_LAND_ONLY) #define PK_LAND_ONLY #endif`），保证 Web 现有前缀/行为逐字不变。
  - tiled 桌面：**保留 `VT_USE_WATER_DEPTH`**，否则 `PK_TERRAIN_STATIC_BAKED` 失效、海岸软权重退回 8-fetch 邻域（`visual_tile_sampling.gdshaderinc:133`、`shore_common.gdshaderinc:46-57`）。
- **水面 program**：
  - Web LOW/MID（`_world_map_web_min_active()`）：现有 `world_water_web.gdshader` + `WATER_PASS_PREFIX` **完全不动**（前缀字节契约）。
  - Web HIGH：现有 `world_map.gdshader` + `WATER_WEB_HIGH_PREFIX` **不动**。
  - PC / 移动：`world_map.gdshader` + `PK_WATER_ONLY`，前缀 = `[MAP_VISUAL_TILED] + [MOBILE_QUALITY_*] + "#define PK_WATER_ONLY\n"`；Compatibility 变体额外带 `PK_WEB_TEXTURE_BUDGET`（与陆地变体同一套规则）。
  - 新增的 Web/测试所依赖的现有前缀常量不许改字节。
- **拆分启用规则**（运行时开关，默认全开）：
  - 启用：`_split_passes_enabled`（新 @export，默认 true）且 `terrain_surface_debug_view == 0` 且 非（Compatibility && tiled）。即：Web（非 tiled）走现有拆分；PC Vulkan/Mobile（含 tiled）走新拆分；桌面 GLES3 tiled 诊断路径回退单 program。
  - 关闭/失败时：完全回退今天的单 program + 单 quad（`_shader_mat`），保证可一键回滚。
- **水面 program 编译失败自检**：沿用现有 `variant.get_shader_uniform_list().is_empty()` 检测；失败则整条拆分回退单 program（不要只回退一半）。

### 2.2 fog / debug / 光照

- **每个 program 只画自己的像素（含迷雾色）**：陆地 program 对 water 像素 discard（fog_hidden 时画 `fog_unexplored_color`）；水面 program 对 land 像素 discard，fog_hidden 时也画同一个 `fog_unexplored_color`（而不是 discard）。原因：分 mesh 后，纯水 block 不由陆地 mesh 覆盖，Web 上 Fog 层可能被裁掉，必须由水面 program 自己补迷雾色。颜色/参数与陆地 program 同源（同一 uniform 值），web 视觉不变（本来 pass1 已画同色，重复画同色幂等）。
- `terrain_surface_debug_view != 0`：**回退单 program + 整张 quad**（debug 13/14/16/17 等必须全屏覆盖；gi_debug_view 只在陆地管线里，水面 program 复现不了）。
- 水面 pass 的 uniform 全量推送：扩展现有 `_apply_water_uniforms` 到 PC/移动（参考 Web HIGH 的"从主材质整表拷贝 + 补绑 noise/water_depth"逻辑），fog/羊皮纸/光照/wrap/cell LUT 全部与陆地材质同值（water 与 land 必须逐项对齐，否则拆 pass 后色差）。

### 2.3 覆盖 mesh 契约（B 实现，A 调用）

```gdscript
class_name TerrainCoverageMesh
extends RefCounted

const DEFAULT_BLOCK_WORLD := 16.0  # world 单位；桌面 derived 1024 时 ≈7 texel

# 返回：
# {ok: bool, reason: String,
#  land_mesh: ArrayMesh, water_mesh: ArrayMesh,
#  stats: {build_ms, blocks_x, blocks_y, block_world,
#          land_blocks, water_blocks, mixed_blocks,
#          land_tris, water_tris, wrap_copies, margin_blocks}}
static func build(world: WorldData, world_bounds: Rect2,
		wrap_period_x: float, block_world: float = DEFAULT_BLOCK_WORLD) -> Dictionary
```

要求：

  - 世界矩形/ wrap 规则必须与 `hex_renderer._build_world_quad_mesh()` 完全一致：`p=world_bounds.position`、`s=world_bounds.size`；`wrap_period_x>0` 时 `p.x=0, s.x=wrap_period_x`，并在 −P / 0 / +P 复制 3 份（同一个 ArrayMesh）。
  - 分类源 = CPU 逐像素水掩码，必须与 shader 内 `is_water` 同源：`world.pixel_to_cell_lookup[i]`（per-pixel cell）→ 该 cell 的静态 biome（即 `enum_lut.r` 的来源；以 `map_baker` 的 enum atlas 编码为准核对）→ `MapData.is_water_lut()`；`pixel_to_cell_lookup[i] == null` 的 block 归 water（地图外 padding 在 shader 里是 `B_SEA_ICE` 水面管线）。
  - **保守覆盖**：block 内只要出现该类像素就进该类 mesh；随后两个 mesh 各自向 8 邻域外扩 1 block（吸收 CPU 掩码与 tiled bake 的边界差异）；边界 block 的 quad 要裁剪到世界矩形内，不能画出地图边界。
  - 顶点布局 = 每个 block 一个 quad（2 三角形），世界坐标顶点（canvas_item 里 `MODEL_MATRIX * VERTEX`，与现 quad 一致）；一条 ArrayMesh 一个 surface 即可；不新增材质、不新增 sampler。
  - 构建必须是一次性的：`set_map`/`_rebuild` 时由 A 调用，运行期不重建（陆地/水面分类在运行期不变；海冰翻转两侧都是水）。构建时间目标 <150 ms（60×40 图），超了就在报告里给数字并说明优化点（可降采样/并行，但先保证正确）。
  - 失败（掩码数据缺失等）→ `ok=false` + reason，A 回退整张 quad。

## 3. A 的 renderer 接线（按此实现）

1. 新开关：`@export var split_land_water_passes: bool = true`、`@export var terrain_coverage_mesh_enabled: bool = true`（远程 inspector 可 A/B）。
2. `_split_active()`：开关 && debug==0 && 非（compatibility && tiled）；`_sync_water_quad()` 的判定统一走它（Web 现有 active 条件作为它的子集，别破坏 web 路径）。
3. `_rebuild/_rebuild_cooperative`：拆分激活时，
   - `terrain_coverage_mesh_enabled` 且模块存在 → `TerrainCoverageMesh.build(...)`，成功则 `_world_quad.mesh = land_mesh`、`_water_quad.mesh = water_mesh`；
   - 否则两张共享整张 quad（保底可运行）；
   - 失败/未启用 → 单 quad + 单 program（今天的行为）。
4. 陆地材质变体前缀：现有逻辑 + 拆分时 `PK_LAND_ONLY`；水面材质新建路径按 §2.1；Web 现有路径字节不变。
5. 材质编译失败/材质为 null 时安全回退单 program；`toggle_world_shader_disabled()`（F9）两片一起关；hot reload（`_poll_shader_hot_reload`）要同时处理两片；`set_mobile_quality_tier` 换档时要重建两片变体；`set_map`/`set_map_cooperative` 路径都要走统一入口。
6. `_water_quad` 树序仍钉在 `_world_quad` 之后、z_index 0（植被 z=1 之上不能盖）。

## 4. 已知陷阱（两条流都要看）

1. `VT_USE_WATER_DEPTH` 从 tiled 陆地 program 掉 → `PK_TERRAIN_STATIC_BAKED` 静默失效。
2. 不要把 `PK_LAND_ONLY` 加进 `land_pipeline.gdshaderinc:181-190` 的压平条件。
3. Web 前缀常量/预热清单是字节契约；`terrain_shader_variant_test` 会断言 prefix 拼接与 sampler 名单——新增桌面变体要**加**断言，不要改 Web 断言。
4. 水面 pass 的 fog 行为改成"画 fog 色"后，web 现有测试断言（compact water 函数无 `if` 等）可能需要按测试本意调整，改动要说明理由。
5. 两个 mesh 与主 quad 的顶点世界坐标必须逐位一致（否则 LUT 采错 cell）；wrap 三份拷贝不可漏。
6. 拆分激活时不能再依赖 pass1 覆盖水面像素的迷雾/占位色。
7. Debug 视图必须回退整 quad；否则诊断画面出现空洞。
8. 水面 program 的 sampler 预算：Web 现有 8/7/5 不许变；PC/移动 32+ 无压力，但不要无谓新增。

## 5. 验收（两个 teammate 都必须自测）

- 静态/headless（Godot console exe：`F:\Developent\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64_console.exe`，cwd=`Project/project-keynes`）：
  - `--headless -s res://tests/world/terrain_shader_variant_test.gd` 全绿（含新增桌面拆分变体断言）；Web sampler dump 不变。
  - 新增/扩展的节点测试能验证：桌面/移动拆分时两片材质存在、shader 变体非空、开关关闭/失败时回退单 program。
  - B 的模块测试：合成/真实小地图上 land∪water 覆盖全部 block，无 gap；mixed block 两边都有；wrap 3 份；build_ms 打印。
- `git diff --check` 干净；`git status` 只包含自己写作用域内的文件（+ 用户已有改动）。
- 不 commit；报告 diff 统计、headless 结果、残余风险、用户真机验收清单。

## 6. 协作方式

- 两条流并行；A 第一版接线必须容忍 B 模块尚不存在（`ResourceLoader.exists`/`load` 动态调用，失败回退整 quad）。
- B 完成后由 Lead 转告 A；A 复核接线；B 复核 A 的调用点；任何契约变更先经 Lead 同意。
- 报告统一格式：`改了哪些文件 / 验证命令与结果 / 已知风险 / 需要对方或用户做什么`。
- 不要修改对方的写作用域；不要动 `docs/plans/` 里 Lead 的文档（除非明确指派）。
