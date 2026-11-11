# 大文件拆分方案

日期：2026-11-11。状态：**方案已定稿，尚未开始实现**。本文只写目标和顺序；每批完成后在文末“进展”一节追加事实和证据。

依据：两份只读调研（GDScript 12 个超过 2500 行的文件、C++ 24 个超过 3000 行的文件）。调研里的行数和越界消减数是估计值，实际以每批完成后的护栏输出为准。

## 目的

让智能体按模块找到并修改代码，不必一次读上万行。拆分不改行为：脚本可见的方法名、信号、属性不变；C++ 对外 API 与 ABI 不变；存档格式、每日顺序、哈希、黄金五链结果不变。

## 统一规则

1. **GDScript**：公开方法和信号留在原文件做薄转发；职责搬到 `RefCounted` 协作者（参照提交 `5cade83e`）。纯转换用静态工具类。不用 `extends` 链。
2. **C++**：同一个类的成员定义分到多个 `.cpp`，不抽新运行时类。匿名命名空间里被多处使用的工具搬到一个 `*_internal.h`。静态注册表、互斥锁、异步状态结构只能有一个定义。
3. **状态只有一个所有者**：cursor、generation、pending 标记、缓存不能在原文件和协作者里各存一份。
4. **新文件放进它所属模块的目录**（以 `tools/ci/world_ext_binding_modules.json` 的 `script_dirs` 为准），这样跨模块原生引用才会真的减少。不为了清零计数而制造循环 `preload`。
5. **新增 `world_ext_*.cpp` 必须登记到 `world_ext_binding_modules.json`**；新增 C++ 文件名保持模块前缀，让 `check_cpp_deps.py` 归类正确。
6. **不做的拆法**：不建第二个组合根或调度器；不按 opcode 或单个 pass 一文件；不把超长函数原样搬到另一个同样长的文件。
7. 新文件目标 ≤ 2000 行，原文件目标 ≤ 1700 行。

## 每批验收

- 架构护栏：`check_size_ratchet.py`、`check_cpp_deps.py`、`check_module_api.py`、`world_ext_bindings.py`、`check_world_ext_bindings.py`、`check_script_native_access.py`、`test_architecture_guards.py`。
- GDScript 批：`godot --headless --editor --quit` 无解析错误；该批列出的测试；黄金五链 3 次。
- C++ 批：debug 与 release 构建；方法 dump 与拆分前逐字节一致；该批列出的测试；黄金五链 3 次（跨编译单元后内联可能变化，哈希是唯一证据）。
- 一个阶段的最后一批再跑默认回归 `run_regression_checks.py`。
- 基线只收紧，不放宽。`size_baseline.json`、`script_native_access_baseline.json` 由验收人在批末更新，实现者不手改。

## 顺序

同一时间只有一个实现任务改仓库（构建产物和黄金链共用同一份动态库）。每批实现后做一次只读自检，再验收提交。

### 第一波

| 序 | 文件 | 批次 |
|---|---|---|
| G1 | `geography/map_generator.gd`（约 22500 行） | 6 批，见下 |
| C1 | `runtime_climate_passes.cpp`（5615 行） | 3 批：cyclone 与 hydrology → weather → round 与 stage B |
| G2 | `rendering/map_baker.gd`（8504 行） | 4 批：encoder → terrain/climate/weather → dynamic atlas 与洋流/物理环流 → 收尾 |

`map_generator.gd` 的 6 批（必须串行）：

1. 生成结果校验与装配 → `geography/map_generation/terrain_gen.gd`、`native_generation_bridge.gd`。
2. 已有的 climate、ocean、sea ice、transpiration pass 协作者接收函数体（`simulation/climate/pass_a.gd`、`pass_b.gd`，`simulation/ocean/*`，`simulation/sea_ice/daily_pass.gd`，`simulation/biology/transpiration_pass.gd`）。
3. native daily bundle 构造与 runtime climate capture → `simulation/climate/native_daily_bundle_builder.gd`、`native_daily_publish.gd`、`runtime_climate_capture.gd`。
4. 季节刷新、天气反馈、资源初始化 → `simulation/climate/season_refresh_coordinator.gd`、`weather/weather_feedback.gd`、`economy/map_resource_initializer.gd`。
5. 保存、停止、worker 控制与规则初始化 → `game/map_runtime_bridge.gd`、`game/map_rules_initializer.gd`、`country/map_country_initializer.gd`。
6. 清理已搬走的内部状态，原文件只留入口、信号、组合顺序和薄转发。

这 6 批同时完成 `world-ext-binding-split.md` 阶段 2 的跨模块迁移：该文件的跨模块原生引用预计从约 270 个降到 60–95 个，剩余的改走模块 facade。

### 第二波

| 序 | 文件 | 说明 |
|---|---|---|
| C2 | `world_ext_simulation_host.cpp` | diagnostics → control → capture → worker |
| C3 | `effect_runtime.cpp` | registry 与 catalog → instance 与 transaction → dispatch 与 persistence |
| C4 | `ideology_runtime.cpp` | 在 C3 之后；catalog 与 offers → effect projection → persistence |
| G3 | `weather_system.gd`、`hex_renderer.gd`、`shrub_layer.gd`、`cell_inspector_view_model.gd` | 互不碰同一文件；`hex_renderer.gd` 在 G2 之后 |
| G4 | `climate_daily_system.gd`、`world_runtime_host.gd` | 在 G1 之后 |

### 第三波

| 序 | 文件 | 说明 |
|---|---|---|
| C5 | `world_ext_climate.cpp` | 在 C1 之后；async 状态只留一个定义 |
| C6 | `economy_runtime_building_investment.cpp` | 先把约 3200 行的 `run_endogenous_building_investment` 提炼成 plan / preflight / commit / metrics 私有成员，再分文件；这一步需要单独细化方案 |
| C7 | `country_runtime.cpp` | 风险最高（保存、哈希、peer）；hash 与 persistence 与 tax → queries 与 economy assets → research 与 peer → commands |
| G5 | `main.gd`、`player_controller.gd`、`game_ui_manager.gd`、`ideology_workspace.gd` | |
| C8 | 其余 16 个 3000–4000 行的 C++ 文件 | 按需，改到哪个拆哪个 |

### `world_ext.h`

不作为普通文件拆分。它跟随 `world-ext-binding-split.md` 阶段 3（sidecar），顺序是 bake_encoders → annual → military → modifier/trigger/effect/ideology，Core、Runtime、Climate 的状态长期留在 `DCWorldExt`。只把声明分到多个头再由 `world_ext.h` 全部 include 不减少重编译，不做。

## 进展

（尚无）
