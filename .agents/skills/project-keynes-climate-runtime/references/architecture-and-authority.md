# 气候运行时架构与权威

## 目录

- 分层
- 权威判定
- 生产调度
- Native daily 图
- 数据桥与发布
- 系统边界表
- 源码阅读地图
- 架构变更检查表

## 分层

```text
WorldClock.day_changed
  -> MapGenerator.sus_tick_daily / bundle & boundary orchestration
  -> DCSystemScheduler
  -> SusSchedulerExt budget / policy / skip / stats
  -> DCSystem or retained SusJob shell
  -> DCWorldExt SoA slots + native pass / native daily continuation
  -> pass report / graph report / finalizer / visual intents
  -> DCWorld / MapData / CSV / WeatherFront / LUT / atlas / renderer
```

- `ClimateProfile` 和具体 `.tres` 决定 feature gate、cadence、budget、物理 knob 与 owner gate。
- `DCWorld` 是 GDScript DataCore mirror；`DCWorldExt` 是 C++ slot/SoA compute world。
- `MapData` 是大量 GDScript、debug、CSV、baker 和 renderer 的可见 SoA mirror。
- `SusSchedulerExt` 负责调度，不拥有气候业务状态。
- `MapGenerator` 负责生命周期、bundle、fallback、finalizer 和 Godot 边界，不应重新承接全图数学 hot loop。

## 权威判定

逐项判断，不用单一“native=true”概括：

| 维度 | 证明 |
| --- | --- |
| Formula authority | 哪个实现决定数值公式；其他实现是否只是 SAME_SOURCE fallback。 |
| Slot authority | 哪个 pass 写 C++ slot；slot 是否是 schema 单一字段。 |
| Stage authority | 谁持有 round active、cursor、phase lock、reset/abort。 |
| Tick authority | 谁决定本 logical day/round 执行哪些节点和何时提交。 |
| Visible authority | MapData、CSV、renderer 是否看到同一提交态。 |
| Object authority | WeatherFront、ImageTexture、RID、MultiMesh 等 Godot 对象由谁管理。 |
| Fallback authority | native 失败后谁推进状态，是否仍属 production path。 |

只有 native 同时拥有 state、slot、tick/cursor、graph report 和发布契约时，才称 DOTS-authoritative。`published_to_slot=true` 只证明具体 pass 的 slot publish，不证明 front/LUT/GPU 可见。

## 生产调度

`MapGenerator._setup_sus()` 使用 `DCSystemScheduler`。当前重要形态：

1. 注册 `season_refresh`、`ocean_currents` 和保留边界 `natural_resource_daily`。
2. 生产 profile 满足 native daily ACTIVE readiness 时，注册 `native_daily_sim` 并 early-return，不再注册 legacy daily climate/weather/sea-ice production jobs。
3. ACTIVE 不可用时，注册 `refresh_climate_daily`、可选 `sea_ice_daily`、`weather_refresh` 及视觉 jobs。
4. `natural_resource_daily` 处于 native/legacy 分叉之外；它消费已发布 climate slots。

`frame_budget_ms` 只决定是否启动下一个 slice，不能抢占已进入的 C++ pass。`slice_budget_ms` 只提供协作式让出。`must_run` 不应用来隐藏长节点。

生产 `earth_like.tres` 当前采用：

- `native_daily_sim_mode=ACTIVE`
- stride 10、commit lag budget 10
- spread across ticks + coarse yield
- split weather
- node range for ocean water/land
- ocean thread variant
- sliced/native finalizer publish
- climate/weather/ocean/season active owner gates
- legacy daily production retired
- runtime hydrology enabled
- physical cell slicing enabled

移动复杂 profile 使用 stride/lag 20、单 slice/tick、split weather、owner gates、legacy retirement 和 hydrology，但未显式启用桌面 profile 的全部 node-range/thread/native-finalizer overrides。每次以资源文件为准。

## Native daily 图

`gdext/src/system_schedule.cpp` 的当前表是唯一顺序事实：

1. `climate_pass_a`
2. `climate_pass_b`
3. `ocean_water`
4. `ocean_land`
5. `wind_air`
6. `wind_surface`
7. `sea_ice`
8. `transpiration`
9. `albedo`
10. `vegetation_dynamics`
11. `climate_feedback`
12. `stage_b`
13. `weather`
14. `runtime_hydrology`
15. `stage_b_after_hydrology`

表按 bundle key 跳过不存在的节点，不是每轮无条件跑完 15 项。

关键顺序理由：

- Pass-B 读取 round-start TTA，必须在当天 ocean 更新之前运行，防止当天新 TTA 即刻反馈进当天湿度。
- `wind_surface` 汇总 baseline、ocean、air 和 local anomaly 后发布 `cell_temp`。
- sea ice 必须读取 wind-surface 后的有效温度。
- weather 读取当轮 climate/wind 可见状态。
- hydrology 读取当天有效 precip，并在 stage-b 读取 soil/WB30 前完成。
- hydrology 开启时用 `stage_b_after_hydrology`，不能同时跑普通 `stage_b`。

split weather 可把 monolithic `weather` 交易拆为 field、commit、distribute、summary、cyclone、weather-stage-b 子节点；报告必须保留聚合字段并指出 `weather_split_skipped_monolithic=true`。

native daily continuation：

- `run_native_daily_slice()` 持有 graph continuation、node cursor 和 round accumulator。
- 中间 slice 的 `published_slots` / `visual_dirty_intents` 为空是正常的。
- 完成 slice 才发布 graph-level report，并进入 GDScript/native finalizer 与 Godot boundary apply。
- `native_daily_sample_day`、commit day、age、lag budget 和 over-budget 共同定义有界降频契约。

## 数据桥与发布

GDScript→C++：

- round start 或明确 GDScript 写入后调用 refresh。
- 少量输入使用 `refresh_slots_from_map_keys()`。
- 连续 native 节点直接消费前一节点更新的 slot。
- static/profile 配置优先常驻 native runtime config；bundle 只带 tick delta 和必要对象边界输入。

C++→GDScript：

- `_flush_slot_to_map()` 使 `MapData` 可见。
- `snapshot_*` 用于 debug/A-B/save 型 pull。
- `published_to_slot=true` 让 caller 跳过重复 copy。
- `defer_visible_publish=true` 只延迟可见镜像，不移动 slot authority；round finalizer 必须完成原子可见提交。

图级发布：

- `published_slots`：本轮声明的 slot family。
- `visual_dirty_intents`：请求 GDScript/Godot 刷新，不等于已经上传。
- `authority_blockers`：阻止 simulation graph complete 的 authority/fallback 项。
- `retained_boundaries`：明确保留的 object/visual/debug 边界，不应被误算为 blocker。
- `graph_coverage_state=complete` 不要求消灭 WeatherFront 或 ImageTexture。

CoW 规则：

- 不假设传入 PackedArray 被 C++ 原地修改后 GDScript 自动看到。
- 返回 PackedArray buffer 时必须接收返回值。
- `bind_map_data()` 后某侧重新赋值/写时，不保证另一侧引用仍同步。

## 系统边界表

| 系统 | 当前主要 owner | 保留边界 |
| --- | --- | --- |
| Climate daily | native graph/pass + finalizer；legacy `ClimateDailySystem` 保留 fallback/debug | reset/abort、MapData/dirty/diagnostics |
| Weather | native field/commit transaction 已可 ACTIVE；GDScript保留 facade | WeatherFront object、LUT/ImageTexture、repair/probe |
| Runtime hydrology | native graph/pass | legacy staged A/B entry、视觉河宽消费 |
| Physical ocean | C++ SLP/wind/PSI/current slots；native facade 镜像 stage state | raster、texture commit、Godot buffer |
| Sea ice | native pass/graph fraction | terrain facade sync、visual dirty/upload |
| Vegetation dynamics | C++ vitality/stress/succession candidate | GDScript 写 candidate 到 vegetation/base facade 并刷新 scatter |
| Season refresh | active owner gate 可声明 native state | atlas queue、detail scatter、Godot upload |
| Climate visuals | simulation slots 只读输入 | LUT/atlas encoding与GPU upload仍为 Godot 边界 |

## 源码阅读地图

- `gdext/src/world_ext_climate.cpp`：Pass-A/B、ocean heat、sea ice、transpiration、hydrology、albedo、vegetation、feedback、stage-b、async/native climate round。
- `gdext/src/world_ext_weather.cpp`：weather field solve、commit、wind-air/surface、distribute、front summary、combined transaction。
- `gdext/src/world_ext_daily_sim.cpp`：slice graph、bundle patch、owner snapshot、report、published slots、visual intents。
- `gdext/src/system_schedule.cpp`：节点顺序与 dispatch。
- `gdext/src/world_ext_physical.cpp`：SLP、wind field、PSI、upwelling、physical solve。
- `map_generator.gd`：生产注册、bundle、profile gate、finalizer、readiness、fallback、visible apply。
- `climate_daily_system.gd`：legacy/async round shell、diagnostics、boundary intents。
- `weather_refresh_job.gd`：staged/merged weather、front/LUT/hydrology边界。
- `ocean_currents_job.gd`：physical/visual 双状态机。

## 架构变更检查表

- 更新 `component_schema.gd` 后运行 codegen 并提交生成 header。
- 更新 bind method；新 DLL 能被 `has_method()`/能力探针识别。
- 更新 GDScript wrapper、native bundle builder、async input、fallback 和 report。
- 更新 `SCHEDULE_GRAPH` 与 graph-order tests。
- 更新 authority matrix、bridge、scheduling、computation、diagnostics 文档。
- 保留 fallback 直到 A/B/soak；删除时更新 deletion inventory。
- 证明可见消费者看到完成态，而不是半轮 slot 或旧 MapData。
