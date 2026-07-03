# Project.Keynes System Map

本文是 Project.Keynes 的开发读码地图。目标不是替代 `docs/` 下的详细设计文档，而是给后续功能、修 bug、性能诊断和 DOTS/C++ 迁移提供一份“先读这里，再进具体模块”的导航。

## 快速读码顺序

通用入口先按这个顺序读：

1. `Project/project-keynes/project.godot`
2. `Project/project-keynes/scenes/world_setup.tscn`
3. `Project/project-keynes/scripts/ui/world_setup.gd`
4. `Project/project-keynes/scenes/main.tscn`
5. `Project/project-keynes/scripts/main.gd`
6. `Project/project-keynes/scripts/geography/map_generator.gd`
7. `Project/project-keynes/scripts/geography/map_data.gd`
8. `Project/project-keynes/scripts/data_core/component_schema.gd`
9. `Project/project-keynes/scripts/data_core/world.gd`
10. `Project/project-keynes/scripts/data_core/dc_system_scheduler.gd`
11. `docs/cpp-dots-runtime/index.md`

按任务类型加读：

- 地图生成和地形水文：读 `docs/terrain-generation-current.md`、`gdext/src/world_ext_generate.cpp`、`Project/project-keynes/scripts/geography/map_config.gd`、`Project/project-keynes/scripts/data/climate_profile.gd`。
- C++/DOTS 运行时：读 `docs/cpp-dots-runtime/architecture-overview.md`、`docs/cpp-dots-runtime/gdscript-cpp-data-bridge.md`、`docs/cpp-dots-runtime/scheduling-and-job-graph.md`、`gdext/src/world_ext*.cpp`、`gdext/src/sus_scheduler_ext.cpp`、`gdext/src/system_schedule.cpp`。
- 气候/天气/海洋：读 `Project/project-keynes/scripts/simulation/systems/climate_daily_system.gd`、`Project/project-keynes/scripts/weather/weather_system.gd`、`Project/project-keynes/scripts/weather/field_solver.gd`、`Project/project-keynes/scripts/simulation/sus/jobs/ocean_currents_job.gd`、`docs/cpp-dots-runtime/computation-pipelines.md`。
- 渲染和视觉：读 `Project/project-keynes/scripts/rendering/map_baker.gd`、`Project/project-keynes/scripts/rendering/hex_renderer.gd`、`Project/project-keynes/scripts/rendering/weather_layer.gd`、`Project/project-keynes/scripts/rendering/shrub_layer.gd`、`Project/project-keynes/shaders/world_map.gdshader`。
- 调试、记录和验收：读 `Project/project-keynes/scripts/ui/debug_console.gd`、`Project/project-keynes/scripts/ui/tile_data_recorder.gd`、`Project/project-keynes/scripts/ui/perf_recorder.gd`、`docs/cpp-dots-runtime/performance-diagnostics-playbook.md`、`Project/project-keynes/tests/*.gd`。

## 运行入口

Godot 项目根是 `Project/project-keynes`。`project.godot` 的主场景是 `res://scenes/world_setup.tscn`，它只挂 `scripts/ui/world_setup.gd`，负责地图尺寸、seed、海平面、大陆数量和若干友好化 climate 控件。点击生成后进入 `res://scenes/main.tscn`，并通过 meta/settings 把 setup 配置交给 `main.gd`。

`main.gd` 是当前主场景协调者，仍然很大。它负责：

- 初始化 UI、相机、DebugConsole、InfoPanel、PerfMiniHUD、TODProfile。
- 创建 `MapGenerator` 并调用 `generate()`。
- 把 `MapData` 和 `WorldData` 注入 `HexRenderer`、WeatherLayer、overlay、info panel。
- 连接 `WorldClock` 的 day/season/year/visual phase 信号。
- 在 day tick 中调用 `MapGenerator.sus_tick_daily()`，并把 fronts、weather LUT、overlay、性能日志推回 UI/渲染层。

当前拆分方向已经写在 `main.gd` 文件头：`bootstrap/dots_bootstrap.gd`、`bootstrap/sus_systems_bootstrap.gd`、`bootstrap/visual_bootstrap.gd`、`ui/info_panel_controller.gd` 等是目的地，其中部分仍是薄壳或占位。改入口逻辑时先确认实际代码是否已经迁出，不要只看目标骨架。

## 顶层数据流

```text
world_setup.tscn
  -> world_setup.gd builds config/meta
  -> main.tscn/main.gd
  -> MapGenerator.generate(cfg, hex_size)
  -> DCWorldExt native world generation base/post-base
  -> MapData + HexCell assembly
  -> MapBaker.bake_world() produces WorldData buffers/textures
  -> MapData._build_indices() + init_soa_from_bake()
  -> DCWorld.bind_map_data(map)
  -> DCWorldExt.bind_map_data(map)
  -> MapGenerator._setup_sus()
  -> WorldClock.day_changed
  -> MapGenerator.sus_tick_daily()
  -> DCSystemScheduler / SUS / SusSchedulerExt
  -> DCSystem or SusJob run_slice()
  -> GDScript wrapper chooses native pass or fallback
  -> DCWorldExt run_* pass writes slots / returns report
  -> flush, snapshot, atlas update, UI/debug/render consume
```

核心边界：

- `MapData` 是每 cell 玩法状态和 SoA 镜像。
- `HexCell` 是兼容旧 `cell.temperature = v` 写法的 facade。
- `WorldData` 是视觉层高分辨率 buffer 和 Godot `ImageTexture` 容器。
- `DCWorld` 是 GDScript DataCore world，管理 component slots、dirty mask、write API。
- `DCWorldExt` 是 C++ GDExtension world，管理 C++ slot/SoA、native pass、event bus 和部分 native daily graph。
- `SusSchedulerExt` 是 C++ scheduler mirror，负责 frame budget、depends、skip 和统计窗口。

## 地图生成

当前初始地形生成已经走 C++ 权威路径。`MapGenerator.generate()` 仍负责流程编排，但真正的 base/post-base 生成在 GDExtension：

- `gdext/src/world_ext_generate.cpp` 和相关 `world_ext*.cpp` 提供 `run_native_world_generate_base_pass()`、`run_native_world_generate_post_base_pass()`、`run_native_world_generate_full_pass()`。
- `MapGenerator._generate_cells_native_base()` 调 native base/post-base，`_assemble_native_generation_map()` 装配 `MapData` / `HexCell`。
- GDScript 旧 `_generate_cells` fallback 已删除。native 失败时 `generate()` 直接中止，不应静默降级。

生成期主要步骤：

1. `MapConfig.make()` 和 `ClimateProfile` 决定宽高、sea level、continent、river、lake、orographic、vegetation、special landform 等参数。
2. C++ base pass 生成 cube 坐标、海拔、湿度、温度、初始 terrain、三轴、湖泊种子等 per-cell arrays。
3. C++ post-base pass 做湖泊连通、水文、河流、雨影、生态反馈、特殊地貌、reef/kelp 等。
4. GDScript 装配 `MapData` 和 `HexCell`，执行海冰 bootstrap、轴同步、cell index 构建。
5. `MapBaker.bake_world()` 烘焙视觉 buffer 和 textures。
6. `MapData.init_soa_from_bake()` 构建运行期 SoA。
7. `_setup_sus()` 进入运行期 DataCore 和调度注册。

`docs/terrain-generation-current.md` 是当前地形生成的高价值文档，改生成算法前先读它。

## 数据模型

`MapData` 同时保留：

- `_cells: Dictionary`，cube 坐标到 `HexCell`。
- `_cell_array`、`_cell_index`、`_neighbor_indices`，用于 hot path 的稳定索引和六邻表。
- 大量 PackedArray SoA 字段，例如 `temp_arr`、`moisture_arr`、`weather_precip_arr`、`terrain_arr`、`ocean_current_x_arr`、`vegetation_vitality_arr`、`river_discharge_arr`。
- `climate_dirty_mask` 和 `weather_dirty_mask`，给 atlas upload、debug 和增量路径消费。

`component_schema.gd` 是 cell component 的单一源。新增持久 cell 字段时按它的 SOP：

1. 在 `component_ids.gd` 加 `CELL_*`。
2. 在 `map_data.gd` 加 PackedArray 字段并在分配/镜像路径处理。
3. 在 `component_schema.gd` 追加 schema 行。
4. 跑 `tools/codegen/gen_cpp_bind_table.py` 更新 `gdext/src/component_bind_table.gen.h`。
5. rebuild GDExtension。

不要绕过 schema 在 C++ 或 GDScript 中私自维护一套持久 cell 状态。临时视觉 buffer、GPU LUT、CSV 字节编码和 debug-only payload 不一定进 schema，但必须有清楚边界。

## GDScript/C++ Bridge

`DCWorld.bind_map_data()` 从 `DCComponentSchema.CELL_SCHEMA` 自动注册并 attach `MapData` arrays。`DCWorldExt.bind_map_data()` 通过 `component_bind_table.gen.h` 注册 C++ slot。两边都依赖 `map_field`、dtype 和 size 正确。

关键公理：

- Godot `PackedArray` 是 Copy-on-Write，不要假设 bind 后永远双向共享。
- GDScript 写入后，C++ 要看见通常需要 `DCWorldExt.refresh_slots_from_map()`。
- C++ 写 slot 后，GDScript、MapData、渲染或 fallback 要看见通常需要 `_flush_slot_to_map()`、`flush_slots_to_map()` 或 `snapshot_*()`。
- C++ pass 成功发布输出时应返回 `published_to_slot=true`，调用侧据此跳过重复 unpack/copy。
- `path=gdscript`、`fallback_reason`、`published_to_slot`、`compute_ms`、`flush_ms`、`refresh_ms` 是排障核心字段。

新增 native pass 的默认形态：

1. GDScript wrapper 做 feature gate、`has_method()`、knobs 构造和 fallback。
2. C++ pass 循环外解析 component id 和 knobs。
3. hot loop 只用 raw array pointer/scalar locals。
4. 输出优先写 C++ slot。
5. 需要 GDScript 可见时显式 flush 或 snapshot。
6. 返回结构化 Dictionary report。

## 调度与每日 tick

`WorldClock` 是日级模拟的权威 tick 源。`WorldClock._process()` 采用 best-effort 吞吐模型：倍速是目标天/秒，每帧最多推进有限天数，并用 `sim_frame_budget_ms` 和 `max_sim_days_per_frame` 防止高倍速死亡螺旋。

每日链路：

```text
WorldClock.day_changed(day_idx)
  -> main.gd._on_day_changed(...)
  -> MapGenerator.sus_tick_daily(world_clock, day_idx, season_phase)
  -> SusTickContext.make(...)
  -> DCSystemScheduler.tick(ctx)
  -> internal SUS / SusSchedulerExt
  -> job.run_slice(ctx)
```

当前 `_setup_sus()` 恒走 `DCSystemScheduler` 路径，并用 DCSystem wrappers 注册生产系统。legacy `SusScheduler` / `SusJob` 仍保留同形语义和部分兼容壳。

主要 runtime jobs/systems：

- `season_refresh`：慢变量批量刷新，植被/生态/terrain/cover/雪盖等低频重判。
- `refresh_climate_daily`：日气候 round，推进温度、湿度、雪包、海冰、风温、蒸腾等。
- `natural_resource_daily`：自然资源每日生成/衰减，per-cell 储量按「固定公式模板 + 每资源系数」结合 temp/moisture 演化；reads cell.temp/moisture → 拓扑排在气候之后。数据驱动配置 `ResourceProfile`（`scripts/data/resource_profile.gd` + `data/resources/*.tres`）+ `ResourceProfileRegistry`；计算权威在 C++ `run_natural_resource_pass`（`gdext/src/world_ext_resource.cpp`），GDScript fallback 同模板。详见 `docs/cpp-dots-runtime/computation-pipelines.md` "Natural resources" 节。
- `sea_ice_daily`：独立海冰日更新，可按 profile gate 注册。
- `ocean_currents`：SLP、wind、PSI、upwelling、ocean current、视觉 raster/commit。
- `weather_refresh`：天气 field begin/solve/summary/hydrology/commit/stage-b。
- `enum_atlas_upload`：terrain/biome/cover/vegetation 视觉 enum atlas 增量上传。
- `dynamic_visual_atlas_upload`：dynamic/ecology/smooth/ice LUT 或 atlas 刷新。
- `native_daily_sim`：native daily graph/probe/active 路径，仍受 gate 控制，不能默认视为所有系统的权威。

调度字段要稳定：

- `id` 用于 stats、depends 和日志。
- `stage_name` / `substage` 用于 `largest` 定位。
- `path` 表示本 slice 的实际执行路径。
- `progress_ratio` 表示 round/stage 进度。
- `must_run=true` 只给不能冻结的物理/气候工作，不能滥用。
- `frame_budget_ms` 控制是否继续启动下一个 slice，不能抢占已经进入的 C++ pass。

## 气候、海洋、天气

`ClimateDailySystem` 是日气候核心系统；旧 `RefreshClimateDailyJob` 兼容壳已删除。当前 round 顺序包含：

1. `pass_a`
2. `pass_b`
3. `ocean_water`
4. `ocean_land`
5. `wind_air`
6. `wind_surface`
7. `sea_ice`
8. `transp`

这些段由 GDScript 状态机调度，许多 hot loop 已在 `DCWorldExt` 中有 C++ pass。继续迁移时要区分“C++ 加速”和“DOTS 权威”：调用 C++ pass 不等于 native graph 拥有 tick/state/publish 全部权威。

native daily 图的 `pass_a` / `pass_b` 现接入多核 `_thread` 变体（2026-07，`pk::parallel_for_range` 自适应，与 scalar 逐位等价；49k–110k cell 实测 ~4.7–5.6x）。两 pass 经 bench 确认 compute-bound，故未做手写 SIMD / 融合 / SFC（数据驱动 no-go，详见 `docs/cpp-dots-runtime/computation-pipelines.md` 与 `scheduling-and-job-graph.md`）。

`OceanCurrentsJob` 把物理求解和视觉 raster 分离。模拟权威是 per-cell SLP、wind、PSI、ocean current、upwelling 等 SoA/slot；vector atlas、wind field buffer 和 pixel commit 是视觉产物，可以滞后或切片。

`WeatherSystem` 仍是天气编排和配置中心。已拆出的 `weather/field_solver.gd` 承担天气场 slice hot loop，`weather/front_advect.gd` 承担 front 推进和 cyclone wake。`weather_system.gd` 仍负责 ClimateProfile 同步、C++ knobs、native/fallback 选择、distribute、summary、legacy fronts、查询 API。

天气公式有双份镜像纪律：`field_solver.gd` 的 GDScript fallback 和 `world_ext.cpp` / `world_ext_weather.cpp` 的 C++ pass 必须同步修改，并用 verify/A-B 模式对账。

## 渲染与视觉

`MapBaker` 把 per-hex `MapData` 烘成高分辨率 `WorldData`。它负责 height/terrain/moisture/river SDF、物理环流初始场、water depth/normal、enum/dynamic/ecology/weather atlas 等。当前文件仍然很大，`rendering/bakers/*.gd` 里有部分目的地骨架。

`WorldData` 保存 CPU buffer 和 GPU `ImageTexture`：

- 静态/生成期：`height_tex`、`terrain_horizon_tex`、`enum_atlas_tex`、`flow_tex`、`water_depth_tex`、`terrain_normal_tex`。
- 运行期动态：`weather_field_tex`、`dynamic_cell_atlas_tex`、`ecology_visual_atlas_tex`、`dyn_lut_tex`、`eco_lut_tex`、`weather_lut_tex`。
- 间接寻址：`enum_atlas_tex` 的 G/B 保存 `cell.index`，per-cell LUT 把每日更新从 pixel fan-out 降到 `n_cells` texel。

`HexRenderer` 是主地图渲染节点，使用 full-screen quad 和 `world_map.gdshader`。它接收 `WorldData`、visual quality、TOD、水面、天气、detail layers 等开关。`WeatherLayer` 渲染天气 overlay，`ShrubLayer` 和 detail scatter 负责 MultiMesh/PCG 点缀。

原则：

- GPU texture upload 和 Godot object/MultiMesh 操作仍在 GDScript/Godot 侧。
- C++ 可以生成 byte buffer、patch、CSR fan-out 和 instance buffer，但不应假装已经绕过 Godot upload 成本。
- 视觉 LUT/atlas 多数不是 DataCore slot，除非是持久模拟状态，不要强行进 schema。

## C++ 运行时文件地图

`gdext/src/world_ext.h` 和 `world_ext_bind_methods.cpp` 是 GDExtension API 面。常见实现分布：

- `world_ext.cpp`：核心 `DCWorldExt`、slot、bind、bridge、部分通用 pass。
- `world_ext_generate.cpp`：native world generation base/post-base/full。
- `world_ext_climate.cpp`：climate pass A/B、ocean water/land、wind/thermal 相关 pass。
- `world_ext_weather.cpp`：weather field solve/commit/distribute/summary/refresh daily。
- `world_ext_physical.cpp`：SLP、wind field、PSI、physical circulation、raster 等。
- `world_ext_atlas.cpp`：dynamic/ecology/ice/overlay/cell LUT/atlas pipeline。
- `world_ext_bake.cpp`：生成期 texture/buffer encoders 和 bake-time geometry fields。
- `world_ext_detail.cpp`：vegetation/detail scatter instance encoding。
- `world_ext_events.cpp`：gameplay event bus。
- `sus_scheduler_ext.cpp`：C++ SUS scheduler mirror。
- `system_schedule.cpp`：更深 native system graph / daily graph 尝试。
- `knobs_struct.*`、`environment_runtime.*`、`parallel_dispatcher.h`：knobs、环境 runtime、并发辅助。

新增 C++ binding 后先检查 `ClassDB::bind_method` 是否存在，再检查 GDScript wrapper 是否用 `has_method()` 和 report 字段正确处理 stale DLL。

## UI 与工具

主要 UI：

- `world_setup.gd`：生成前参数界面。
- `main.gd`：TopBar、时间、速度、overlay、快捷键、splash、状态推送。
- `info_panel_controller.gd`：右侧地块信息面板。
- `debug_console.gd`：overlay、模拟开关、视觉开关、诊断动作、Telemetry。
- `perf_mini_hud.gd`：常驻小型性能 HUD。

记录与诊断：

- `perf_recorder.gd`：fast tick / SUS 运行期性能记录。
- `tile_data_recorder.gd`：tile CSV 诊断，C++ 可用 `encode_tile_csv_rows()` 加速行编码。
- `tools/dots_soak_dump.gd`、`tools/dots_soak_ab_runner.gd`：DOTS soak/A-B 相关工具。

性能日志优先读：

- `[fast tick WARN]` 的完整块。
- `[SUS-cpp] last N ticks` 和 `budget last N ticks`。
- `largest=job/stage/substage path=...`。
- 单 job breakdown 中的 `native`、`compute`、`flush`、`refresh`、`sync`、`published_to_slot`、`fallback_reason`。

## 测试与验证入口

现有 `Project/project-keynes/tests/*.gd` 多数是 `SceneTree` 脚本，用于公式、schema、dirty mask、world serialization、native generation parity、weather field、baker encoder parity、native daily shadow 等验证。

高价值测试文件：

- `native_generation_equivalence_test.gd`
- `weather_field_solver_test.gd`
- `bake_encoder_cpp_parity_test.gd`
- `native_daily_shadow_test.gd`
- `schema_migration_test.gd`
- `world_write_indexed_test.gd`
- `dirty_mask_test.gd`
- `environment_runtime_smoke_test.gd`
- `tile_data_recorder_test.gd`

文档-only 改动至少做静态检查：用 `rg` 确认文档提到的关键文件和 symbol 仍存在，并运行 `git diff --check`。C++/DOTS 改动按 `docs/cpp-dots-runtime/performance-diagnostics-playbook.md` 和项目技能里的顺序，先静态确认 binding/schema，再 build GDExtension，再做 focused Godot/headless 或 in-editor reproduction。

## 变更边界规则

- 优先扩展现有模块，不新建平行系统。
- 持久 cell 状态走 `MapData` + `component_schema.gd` + codegen + `DCWorld`/`DCWorldExt`。
- 低频 UI、Godot object、texture upload、MultiMesh 生命周期留在 GDScript/Godot 侧。
- C++ hot loop 内禁止 Variant/Object property/string lookup，knobs 和 slot id 都在循环外解析。
- runtime report 必须可诊断，不要只返回一个总耗时。
- 修改天气、气候、海洋公式时同步 C++ 和 GDScript fallback/verify 路径。
- 修改调度时保持 `stage_name`、`substage`、`path`、skip reason 稳定，避免破坏性能诊断。
- 修改 bridge/publish 行为时同步更新 `docs/cpp-dots-runtime/gdscript-cpp-data-bridge.md`。
- 修改 job graph/budget/report 时同步更新 `docs/cpp-dots-runtime/scheduling-and-job-graph.md` 和 `performance-diagnostics-playbook.md`。

## 当前非目标

仓库当前核心是地理生成、气候、天气、海洋、渲染和 DOTS/C++ 运行时。尚未看到稳定的生产/消费/价格/工资/税收/贸易等经济系统入口。后续如果加入经济玩法，应先定义 component schema、tick cadence、UI/debug 和持久化边界，不要把经济状态混入现有 climate/weather/visual buffer。
