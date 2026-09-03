# Project.Keynes System Map

Source-file ownership and decomposition rules live in
[`docs/architecture/module-boundaries.md`](../docs/architecture/module-boundaries.md).

## Formal game entry (2026-07)

`project.godot` starts `scenes/main_menu.tscn`. The product flow is
`MainMenu -> GameFlowService -> player_game.tscn -> WorldRuntimeHost ->
MapGenerator`; `world_setup.tscn` is a development tool only. New games use
`NewGameConfig v3`, deterministic multi-country `StartLocationPolicy`, PKCN
`country.player` plus `country.foreign.NNN`, and the aggregated
`StarterSettlementBootstrap`. Complete saves are
coordinated by `GameSaveCoordinator` and stored by `SaveRepository` as PKSV v1.
Read [`game-flow-start-save.md`](../docs/cpp-dots-runtime/game-flow-start-save.md)
before changing session routing, player bootstrap, save boundaries, or restore
order.

2026-07 性能优化只改变 transient cache、审计策略和 bridge payload，不改变
系统拓扑；实现契约见
[`runtime-performance-optimization-2026-07.md`](../docs/cpp-dots-runtime/runtime-performance-optimization-2026-07.md)。

2026-08 性能治理继续保持同一 authority：Country/Economy/Bio native runtime
拥有模拟状态，GDScript 只负责 facade、事件 dirty flags、section UI cache 和
Godot 对象。Country ACTIVE 默认 LIGHT report；`get_country_ui_snapshot` 按域
读取，研究使用 pending queue。Bio 先走 deterministic full-coverage staging，
只有完整提交后才写 occupancy slot/事件；任何 sliced-pass 能力不足都必须显式
记录 `path/fallback_reason/fail_stage/published_to_slot` 并回滚 one-shot。生产
sliced Bio 每次固定 2048 cells，`bio_occupancy_day_barrier` 在最终 publish 前冻结
语义日；native daily 未完成时使用 `native_daily_day_barrier`，continuation pulse
按 native daily -> Bio -> Country/Economy 顺序续接。

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
- 理念：读 `docs/cpp-dots-runtime/native-ideology-runtime.md`、`gdext/src/ideology_runtime.*`、`Project/project-keynes/scripts/ideology/`、`Project/project-keynes/scripts/ui/components/ideology_workspace.gd`，以及仓库 Skill `project-keynes-ideology-runtime`。理念状态由独立 native runtime 持有；Economy 只发布 committed 国家×阶层事实，Effect 只提交原子后果批，PlayerController 只提交命令，均不接管理念收藏、槽位、民意规则、联动或理解度。
- 气候/天气/海洋：读 `Project/project-keynes/scripts/simulation/systems/climate_daily_system.gd`、`Project/project-keynes/scripts/weather/weather_system.gd`、`Project/project-keynes/scripts/weather/field_solver.gd`、`Project/project-keynes/scripts/simulation/sus/jobs/ocean_currents_job.gd`、`docs/cpp-dots-runtime/computation-pipelines.md`。
- 渲染和视觉：读 `Project/project-keynes/scripts/rendering/map_baker.gd`、`Project/project-keynes/scripts/rendering/hex_renderer.gd`、`Project/project-keynes/scripts/rendering/weather_layer.gd`、`Project/project-keynes/scripts/rendering/shrub_layer.gd`、`Project/project-keynes/shaders/world_map.gdshader`。
- 视野迷雾与国界：读 `docs/cpp-dots-runtime/vision-fog-and-borders.md`、`Project/project-keynes/scripts/geography/vision_solver.gd`、`Project/project-keynes/scripts/rendering/fog_of_war_layer.gd`、`Project/project-keynes/scripts/rendering/country_border_layer.gd`。
- 调试、记录和验收：读 `Project/project-keynes/scripts/ui/debug_console.gd`、`Project/project-keynes/scripts/ui/tile_data_recorder.gd`、`Project/project-keynes/scripts/ui/perf_recorder.gd`、`docs/cpp-dots-runtime/performance-diagnostics-playbook.md`、`Project/project-keynes/tests/*.gd`。
- 阶层、市场、财政、建筑、就业、投资、资源、显赫家族与重要人物：读 `gdext/src/economy_runtime.{h,cpp}`、`gdext/src/economy_runtime_storage.cpp`、`gdext/src/economy_runtime_math.cpp`、`gdext/src/economy_runtime_fiscal.cpp`、`gdext/src/economy_runtime_building_storage.cpp`、`gdext/src/economy_runtime_building_employment.cpp`、`gdext/src/economy_runtime_building_resources.cpp`、`gdext/src/economy_runtime_building_production.cpp`、`gdext/src/economy_runtime_building_investment.cpp`、`gdext/src/economy_runtime_building_construction.cpp`、`gdext/src/economy_runtime_building_commit.cpp`、`gdext/src/economy_runtime_market.cpp`、`Project/project-keynes/scripts/economy/`、`Project/project-keynes/scripts/simulation/systems/economy_daily_system.gd`、`docs/cpp-dots-runtime/native-economy-runtime.md`、`docs/cpp-dots-runtime/tax-fiscal-runtime.md`、`docs/cpp-dots-runtime/notable-family-runtime.md` 和 `docs/cpp-dots-runtime/notable-person-runtime.md`。拆分依赖矩阵见 `docs/architecture/economy-runtime-split.md`。

## 运行入口

Godot 项目根是 `Project/project-keynes`。`project.godot` 的主场景是 `res://scenes/main_menu.tscn`（见上文「Formal game entry」），正式流程经 `GameFlowService` 进入 `res://scenes/player_game.tscn`，由 `scripts/game/player_game.gd` / `scripts/game/world_runtime_host.gd` 承接。`res://scenes/world_setup.tscn`（`scripts/ui/world_setup.gd`，地图尺寸/seed/海平面/大陆数量等友好化控件）降级为开发工具入口，`res://scenes/main.tscn` 保留旧 debug/runtime lab。

`player_game.gd` 是面向玩家的轻量场景生命周期装配层。正式玩家交互由唯一的 `PlayerController` 统一编排：它负责地图点击、选中态、镜头输入转发、时间控制和正式玩家命令网关。地图手势走 `_unhandled_input`（仅文本编辑拦截）；普通 Control 焦点只挡住 `handle_input()` 直接分发，HUD overlay/顶栏按钮使用 `FOCUS_NONE`，避免点图层后锁死镜头。`WorldRuntimeHost`、`MapGenerator`、`DCWorldExt` 与 scheduler 仍然拥有地图、DataCore、SUS 和 native daily 权威。玩家场景复用 `PerfMiniHUD` 和 `DebugConsole` 的 `PLAYER_GM` 模式：顶栏按钮、反引号或 F1 打开总览/选中对象/指令/开关/记录五页管理面板，F4 切换 FPS HUD；入口只在 editor 或 debug/dev 构建创建，release 不创建面板并禁用快捷键。性能 CSV、地块 CSV 与只读经济 epoch CSV 分别由既有 `PerfRecorder`、`TileDataRecorder` 和 `EconomyDataRecorder` 生成。玩家场景挂载独立 `DataOverlayLayer`，但只使用静态 cell-index atlas + 动态 per-cell RGBA8 LUT；soak/A-B 与旧 `LEGACY_DEBUG_LAB` 的全图 overlay/迁移实验开关仍只在 debug 入口。

`WorldRuntimeHost` 是 GM 的稳定运行时边界：`get_gm_capabilities()` 描述白名单命令、数据页和开关，`get_gm_snapshot(section, context)` 返回带 revision 的有界快照，`execute_gm_command(id, args)` 返回结构化排队/错误结果，`set_gm_toggle(id, enabled)` 设置后再读回实际状态。`GMPanelViewModel` 只负责 `<command_id> key=value` 解析、补全、验证和固定行模型；UI 不直接写 `MapData`、DataCore SoA 或 native 对象。除时间暂停/速度外，国家与经济写操作默认排到下一游戏日，使用会话内单调 sequence 并复用 `CountryFacade` / `EconomyFacade` 的原生命令预检与冻结周期提交规则；显示货币按 `×10000`、商品按 `×1000` 转成定点整数。

GM 的 `visual.fog_of_war` 开关复用 `WorldRuntimeHost.set_fog_of_war_enabled()`：它回读正式对局上下文门控后的实际状态，并通过既有 `VisionSolver -> enum_lut.a -> HexRenderer/Inspector` 链刷新，不直接改写国家 runtime。

GM 的 `simulation.click_claim_territory` 是会话级操作模式。启用后，`PlayerController -> WorldRuntimeHost.set_selected_cell()` 仍先完成正常选中，再由 host 使用缓存的玩家国家 handle 包装既有 `country.transfer_territory`，按下一游戏日与单调 sequence 提交；水域、重复排队和已归属格在 GDScript 边界快速返回，其余领土约束继续由 `CountryFacade` / native 批次预检负责。正式研究命令从 `PlayerController.request_command()` 进入，GM 命令仍是独立入口。

`main.gd` 是当前 debug 主场景协调者，仍然很大。它负责：

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
  -> player_game.tscn/player_game.gd
  -> WorldRuntimeHost.generate_world()
  -> await MapGenerator.generate(cfg, hex_size)
  -> DCWorldExt native world generation base/post-base
  -> DCTerrainGenerator.assemble_native_result()
  -> MapData + HexCell assembly
  -> MapBaker.bake_world() produces WorldData buffers/textures
  -> DCClimateBaker.bake_latitude_buffer() validates native latitude field
  -> MapData._build_indices() + init_soa_from_bake()
  -> DCWorld.bind_map_data(map)
  -> DCWorldExt.bind_map_data(map)
  -> MapGenerator._setup_sus()
  -> WorldClock.day_changed
  -> PlayerController
  -> WorldRuntimeHost.run_daily_tick()
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
- 玩家与 debug 入口必须 `await MapGenerator.generate()`。生成仍在 Godot 主线程执行，因为 `MapData`/`HexCell` 装配、`ImageTexture` 和 DataCore/Godot 对象生命周期不能粗暴迁入 worker；`MapGenerator` 与 `MapBaker` 在大陆、几何、物理、图集编码和模拟装配边界协作式 `await process_frame`，让加载 UI、窗口事件和动画持续推进。直接调用但不 `await` 会在首个让帧点提前返回，是不受支持的调用方式。

生成期主要步骤：

1. `MapConfig.make()` 和 `ClimateProfile` 决定宽高、sea level、continent、river、lake、orographic、vegetation、special landform 等参数。
2. C++ base pass 生成 cube 坐标、海拔、湿度、温度、初始 terrain、三轴、湖泊种子等 per-cell arrays。
3. C++ post-base pass 做湖泊连通、水文、河流、雨影、生态反馈、特殊地貌、reef/kelp 等。
4. GDScript 装配 `MapData` 和 `HexCell`，执行海冰 bootstrap、轴同步、cell index 构建。
5. `MapBaker.bake_world()` 烘焙视觉 buffer 和 textures。
6. `MapData.init_soa_from_bake()` 构建运行期 SoA。
7. `_setup_sus()` 进入运行期 DataCore 和调度注册。

`MapBaker` 同时维护可选的视觉 Tile 路径：全局 geometry/CSR 仍是权威基线，
`run_bake_visual_tile_layer_pass` 只生成高分静态 `Texture2DArray` 字节，
`VisualTileHorizonBaker` 用 GPU compute 生成分块 horizon。Compatibility 或静态失败回退
原单图；Tile 预算不进入 HexCell、DataCore、仿真或存档。详见
`docs/cpp-dots-runtime/visual-tile-rendering.md`。

`docs/terrain-generation-current.md` 是当前地形生成的高价值文档，改生成算法前先读它。

## 数据模型

`MapData` 同时保留：

- `_cells: Dictionary`，cube 坐标到 `HexCell`。
- `_cell_array`、`_cell_index`、`_neighbor_indices`，用于 hot path 的稳定索引和六邻表。
- 大量 PackedArray SoA 字段，例如 `temp_arr`、`moisture_arr`、`weather_precip_arr`、`terrain_arr`、`ocean_current_x_arr`、`vegetation_vitality_arr`、`river_discharge_arr`。
- `climate_dirty_mask` 和 `weather_dirty_mask`，给 atlas upload、debug 和增量路径消费。
- 视野三件套：`visible_arr`、`explored_arr`（两者是 `owner="vision"` 的 schema 组件）和派生的 `fog_k_arr`（不进 schema，只喂 `enum_lut.a`）。

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
- `natural_resource_daily`：31 种自然资源/农业容量按 habitat mask（陆地/海洋水格/淡水水格或河流）门控，并结合 temp/moisture 演化；`cell_temp` 与所有 `ResourceProfile.temp_lo/temp_hi` 统一为 `[0,1]`，禁止混用摄氏范围。所有数量型储量/自然增减统一乘省级地块面积倍率 `100×`，分布形状和无量纲增长/衰减率不变。普通资源使用线性 IMEX，野生动物/林木/鱼群使用适生度承载量、密度增长、迁入恢复和仅作用于原始适生度最低 25% 的急性压力死亡模型。海鱼可分布在沿海陆格和海洋水格，初始化在物理环流 flush 后读取温度、海域类型、洋流、上升流、河口营养和连续噪声，按适生度形成非均匀斑块；每格只保存本格储量。淡水鱼储量属于湖泊水格及湖岸陆格。external delta 一次性应用，`dt_days` 仅推进自然项。所有建筑资源边仍严格为 `local`，只读取并扣减建筑本格储量，不存在邻域采集。初始矿产由资源局部斑块、同族地质省和矿带共同生成；关键资源可按原始适宜度排名配置最低全球矿点覆盖。
- 植被演替：C++ stage-b 计算 vitality/streak 并返回 succession candidates；GDScript 边界负责把 candidate 写回 `HexCell + MapData + cell_vegetation/cell_base_vegetation` 权威槽位并触发 atlas/scatter dirty。generation 与 runtime 共用 biome envelope soft prior；严重跨 biome 错配会在 high-threshold 适配区间开始累计 degradation streak。native cadence 的演替日数按 stage-b stride 与 native daily stride 的乘积累计。
- 物资与阶层已进入独立原生经济域：`GoodProfileRegistry` 编译 stable goods，
  `PopulationStore`/`MarketStore` 保存状态，`economy_daily` 推进 `ECONOMY_GRAPH`。
  它们不属于 cell schema；自然资源仍由 `natural_resource_daily` 推进，生产供货走命令账本。
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

## Climate modes (monsoon, ENSO, cyclones)

Read the climate-mode section in `docs/cpp-dots-runtime/computation-pipelines.md`
first, then inspect `gdext/src/world_ext_physical.cpp`,
`gdext/src/world_ext_climate.cpp`, `gdext/src/world_ext_weather.cpp`, and
`Project/project-keynes/scripts/data/climate_profile.gd`. `DCWorldExt` owns the
mode state and transient caches; no new DataCore cell slot is required. Weather
visuals continue through the existing WeatherFront/LUT boundary.

## 渲染与视觉

`MapBaker` 把 per-hex `MapData` 烘成高分辨率 `WorldData`。它负责 bake_world 编排、物理环流初始场、water depth/normal、enum/dynamic/ecology/weather atlas 等；height/biome/moisture fallback、river SDF、erosion 请求和 terrain detail raster 由 `DCTerrainBaker` 承担，无状态几何 helper 集中在 `rendering/bakers/terrain_geometry_utils.gd`。当前文件仍然很大，`rendering/bakers/*.gd` 里有部分目的地骨架。

`WorldData` 保存 CPU buffer 和 GPU `ImageTexture`：

- 静态/生成期：`height_tex`、`terrain_horizon_tex`、`enum_atlas_tex`、`flow_tex`、`water_depth_tex`、`terrain_normal_tex`；另有两个非纹理的静态视野场 `cell_view_height` / `cell_view_block`（`PackedByteArray`，`bake_world` 由地形派生，供 `VisionSolver` 只读）。
- 可选高分静态视觉：`visual_tiles` 持有 height/normal/map-index/flow/water/detail/edge/horizon
  九个无 mip `Texture2DArray` 和 `VisualTileLayout`；它是视觉缓存，不替代前一行的 CPU 基线。
- 运行期动态：`weather_field_tex`、`dynamic_cell_atlas_tex`、`ecology_visual_atlas_tex`、`enum_lut_tex`、`dyn_lut_tex`、`eco_lut_tex`、`weather_lut_tex`。
- 间接寻址：`enum_atlas_tex` 的 G/B 保存 `cell.index`，per-cell LUT 把每日更新从 pixel fan-out 降到 `n_cells` texel。`enum_lut_tex` 是 **RGBA8**：R/G/B = biome/veg/cover，**A = 迷雾知识度 `fog_k`**。
- 玩家信息遮罩：`DataOverlayLayer` 位于基础地图/植被上方、选择高亮下方；`data_overlay.gdshader` 从 `enum_atlas_tex.GB` 解码 cell ID，再以 NEAREST 读取玩家 `overlay_lut`。世界拓扑不变时只上传 `lut_dims.x * lut_dims.y * 4` 字节，不创建地图分辨率动态纹理。

完整 z 序（`top_level` 的 `Node2D` 挂在 `WorldRoot` 下）：`WorldQuad` 0、`WeatherLayer` 4、`DataOverlayLayer` 5、`CountryBorderLayer` 6、`CellHighlight` 10、`FogOfWarLayer` 12。迷雾在最上层，未探索区要连天气云、国界线和选中框一起盖住。

`world_map.gdshader` 读 `enum_lut.a` 对已探索但不可见的区域做去饱和灰化（零新增 texture sample），并在 `fog_early_out_enabled` 时对完全未探索像素跳过整条地形管线（默认关，须 GPU A/B 实测；且只在迷雾最低质量档放行，因为早退要求迷雾层输出常量色）。terrain-index bake 的 RG8 邻格索引 + R8 距离场是通用视觉边界数据：桌面地表把随 zoom 调整的 8×8 Bayer DitherUV 覆盖混入连续距离场，远景使用较强稳定颗粒，近景则把 Dither 完全淡出，只保留连续距离场；三套 Dither consumer 都把 Bayer 原始 rank 从 `[0,1]` 压缩到 `[0.18,0.82]`，保持边界处 50% 覆盖率，同时避免极低 rank 在宽距离场里拉成单 texel 长刺。视觉 cell 的 biome/vegetation/cover 选择使用同一淡出权重，避免完整陆地材质管线在近景留下放大的 Dither 块，动态温湿度、活力、雪量和 landform 仍由主格驱动。桌面迷雾/天气仍连续混合。海洋在所有平台都以距离场权重驱动 DitherUV 的水域主/副视觉 cell 选择，并继续叠加桌面既有的连续水体 biome weights，不执行第二次完整水体管线；Dither 只替换 biome/cover，海冰浓度、温度和洋流仍由硬主格驱动。移动端陆地 Dither 保留到更近的缩放范围，但也会在最大近景前完全淡出；移动端迷雾和天气仍在主/副视觉 cell 间择一，以恢复低成本远景过渡。所有 Dither 都不改变硬主 cell 权威状态，且禁止跨水陆域选择；缺纹理时均硬回退。`weather_cell_curtain.gdshader` 仍按主格可见性屏蔽实时降水。契约见 `docs/cpp-dots-runtime/vision-fog-and-borders.md`。

`fog_of_war.gdshader` 使用分层 2.5D 云海：同一连续密度场派生低层 deck、中层 body 与高层 top，低层保证未探索区完全遮挡，中高层提供云团轮廓。法线拆为低强度的 1/2、1 倍频宽缓 `broad_grad` 与小振幅的 2、4 倍频锐利 `detail_grad`，禁止把三条层级阈值导数叠成尖脊；域扭曲保持低幅，避免液体大理石流线。deck/body/top 使用不同的直射、天光和多重散射权重后从下往上合成，体积不依赖强法线。自阴影沿主光方向积分前方云体质量，不再把单一高度场画成巨型峡谷。光照仍消费 `earth_daylight`，但高空云使用比地表更宽的昼夜过渡，并把日光/月光分别着色后平滑相加；晨昏区削弱方向性阴影并增加金黄散射，避免日月方向翻转形成硬线。深夜进一步把质量阴影压到弱厚度提示、把月光直射改为低方向性并让天空 SH 只读取 `broad_grad`，主要可读性由冷灰环境光与多重散射承担。各频段除保留不同方向的 UV 平流外，还让可平铺噪声的晶格梯度以不同速率和方向随 `_world_time` 旋转，使 FBM 本身持续生成、消散与重组；`FogOfWarLayer` 与天气层同步游戏倍速。所有频段按屏幕足迹做 **LOD 截断**，东西向使用可平铺噪声。质量分 q0..q3 四档，有效档 = min(编译期 tier 上限, 运行时 `visual_quality` 映射)。

`CountryBorderLayer` 的 ribbon 是**内缩梯形**：凸多边形向内偏移时边要变短（六边形每端 `d·tan30°`），外侧顶点落在 hex 角上，相邻两条在角点顶点重合。写成向外延伸会让每条边越过角点、相邻两条交叉成 X。顶点 UV 存世界单位（沿边距离 / 垂距），保证梯形两个三角形里插值精确。屏幕线宽随 zoom 次线性增长而非恒定。

`HexRenderer` 是主地图渲染节点，使用 full-screen quad 和 `world_map.gdshader`。它接收 `WorldData`、visual quality、TOD、水面、天气、detail layers 等开关。`WeatherLayer` 渲染天气 overlay，`ShrubLayer` 和 detail scatter 负责 MultiMesh/PCG 点缀。相机缩放只调整既有 MultiMesh 的可见前缀：profile 原配置数量是远景基准，构建时额外预生成受既有全局预算约束的近景实例，越近逐步放出更多树木、灌木、草和碎石；每个 chunk 的实例按 cell 稳定分层（先让所有活跃格各保留一个样本，再放第二层与近景增量），避免连续 buffer 前缀裁掉整格，东西环绕副本与源实例保持同一层级。候选散布半径设有跨格下限，使连续世界噪声不会被源 cell 轮廓裁成蜂窝斑块。缩放过程不重建、不重新随机散布，也不压低远景基准层的 Shader alpha。

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
- `player_game.gd`：玩家主场景装配层，负责 runtime/UI/controller wiring、基础玩家热键，以及 F1/反引号 GM 面板与 F4 性能 HUD 入口；Escape 先关闭 GM，再处理地图子菜单与暂停菜单。
- `game_ui_manager.gd`：玩家 UI 装配与场景状态，连接 `PlayerTopBar`、`WorldLoadingOverlay`、`InspectorPanel`、`PLAYER_GM` 面板、FPS HUD、safe area 和控制信号；不直接承担逐字段渲染。左侧 GM 面板在宽屏目标宽度 560px，在 800px 视口按右侧 460px Inspector 剩余空间收缩，二者可同时使用。
- `ui/components/country_action_bar.gd` / `country_panel.gd` / `ui/country_view_model.gd`：底部国家事务入口与全屏 section shell。玩家国家固定由 `gameplay_start_report().cell` 解析，模型经 `CountryFacade.cell_summary()`、`research_snapshot()` 与只读 `treasury_snapshot()` 读取已提交状态；`CountryPanel` 自身只有 section 标题条与内容区，不再叠加国家档案 header、摘要卡或 section tab，section 切换只由底栏驱动。经济 section 使用 `economy_workspace.gd` 展示国家现金与全部非零国库物资，每日只修补可见值；政治/军事/外交暂用 `section_placeholder_screen.gd`，不创建任何状态或命令。`IconBadge` 继续以 Font Awesome 为默认族，并为国家事务集中提供 Lucide 导航图标与 Tabler 摘要图标。
- `ui/technology_tree_layout.gd` / `ui/components/technology_workspace.gd` / `technology_available_view.gd` / `technology_tree_view.gd` / `research_toast.gd` / `research_weight_dial.gd` / `procurement_budget_slider.gd` / `technology_detail_card.gd` / `technology_queue_row.gd`：全屏科技界面。打开时只建拓扑与 soft-edge 索引，完整全图 bake 按需延迟；默认中央是「可研究」清单，科技树/总览按需展开；树视图单 `Control` 自绘聚焦窗口，按「已揭示 ∪ 直接未知后继」裁剪迷雾并把可平移范围限制在可见集包围盒内，永远 1:1 绘制、滚轮只平移不缩放；四大领域同图四条垂直泳道、列宽随中央画布均分且不横向溢出，左右研究管理/科技详情常驻列；聚焦布局按依赖深度分层，同领域兄弟在泳道内叠放，每个可见时代带显示时代里程碑关隘；已揭示详情显示路线标签、研究阻塞、证据数/首次日/来源格，未知节点不读取语义；研究进入待生效时 HUD `ResearchToast` 提示；权重盘与采购滑块拖动即预览、松手即通过 `PlayerController.request_command()` 提交，界面无任何提交按钮，工作区不持有 CountryFacade/玩家句柄/命令序列；日 tick 只修补状态数组与可见文本。
- `ui/components/map_overlay_toolbar.gd` / `ui/overlay_legend.gd`：左侧纯图标双列信息菜单与非交互图例。资源按钮来自 `ResourceProfileRegistry`，按钮无可见文字，名称和说明通过 Tooltip/图例呈现。图例停靠右下角，Inspector 打开时自动左移避让；连续资源使用固定 profile 参考值与低值扩展的高色差色带，海拔使用同时改变色相和亮度的高对比科学色带。
- `ui/components/player_top_bar.gd` / `world_loading_overlay.gd` / `inspector_panel.gd`：正式局内顶栏、生成档案遮罩和右侧地块档案。地理页在已探索/可见格读取本格 CSR 的 `Kind.BIO` 目击（玉米、小麦等），用徽章展示中文名，不与可采集储量混列；自然资源页读取选中 cell 的权威 reserve；“本格存在”与“当前建筑可开采”是两个状态，不能因没有 extractor 而隐藏库存。人口页显示上次提交周期的人均收支与稀疏来源；市场使用可展开紧凑账簿行；建筑详情按岗位/生产/财务分组。所有列表在 460px Inspector 内无横向溢出，跨日采样只更新值并保留标签、展开与滚动状态。
- `world_runtime_host.gd`：玩家场景的地图 runtime facade，封装 `MapGenerator.generate()`、renderer/camera 绑定和每日 `sus_tick_daily()` 桥接。
- `player_controller.gd`：正式玩家输入、选中态、时间控制、镜头转发和玩家命令网关；不拥有模拟状态。`construction.build` 从选中玩家领土地块进入 `EconomyFacade`，报价只读当前页，实际结算由原生经济边界按国库物资→本格市场→国库现金原子处理，并以 sequence 对应的瞬态 receipt 回传。
- `main.gd`：debug TopBar、时间、速度、overlay、快捷键、splash、状态推送。
- `info_panel_controller.gd`：右侧地块信息面板。
- `debug_console.gd`：默认 `LEGACY_DEBUG_LAB` 保留 overlay、模拟开关、迁移实验与 Telemetry；正式玩家场景显式选择 `PLAYER_GM`，只展示白名单运营能力。GM 可见时只以 2Hz 刷新当前页并更新缓存控件，隐藏时停止计时器，不在日 tick 重建节点树。
- `perf_mini_hud.gd`：常驻小型性能 HUD。

记录与诊断：

- `perf_recorder.gd`：fast tick / SUS 运行期性能记录。
- `tile_data_recorder.gd`：tile CSV 诊断，C++ 可用 `encode_tile_csv_rows()` 加速行编码。
- `economy_data_recorder.gd`：经济 CSV v3 的薄控制面；可在开始时锁定“全图”或“当前选中地块”。`DCWorldExt` 在成功 commit 且资源 delta 已回写后，把五表 POD 快照交给原生 `EconomyCsvRecorder` 双缓冲，后台线程负责 CSV 编码和写盘。v3 记录企业停产/采购意图/利润率、实际出库/库存目标/采购缺口和商人采购预算。单地块模式保留全局 summary，其余四表按显式 `cell_indices` 过滤；该 recorder 只读 committed 状态，不进入经济权威、PKEC 或 state hash。
- `world_runtime_host.gd`：玩家场景的诊断数据源；记录 SUS、renderer sync、选中面板 UI patch 和 recorder 墙钟，并向上述 HUD/录制器提供与 debug `main.gd` 同形的只读 getter。
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

## 经济运行时

`MapGenerator._setup_sus()` 在环境 native/legacy 分叉前配置 `EconomyFacade`，默认以空的
数据驱动人口 packet bootstrap 本地市场，并注册 `EconomyDailySystem`。世界设置可显式
启用仅供开发的确定性测试经济 fixture；默认关闭。fixture 先生成当前科技最高可用档的资源适配
建筑 owner-lot，再从 catalog owner/employee 岗位容量派生 cohort，初始库存与就业保持为零。状态实现位于
`DCWorldExt` 组合持有的 `NativeEconomyRuntime`：PopulationCohort pages、商人共同
所有的 MarketStore、FamilyStore、NotablePersonStore 与成员/建筑所有权/人物需求稀疏边、企业停产/采购意图/实际出库、
need/bundle 清算、国内贸易拓扑/订单/托管、账本、滚动五相 continuation、closing audit 和
PKEC v44 存档全部在 C++。生产 cadence
固定为 `cell_id % 5 == day % 5`；每个到期 bucket 通过有界 same-day continuation 完整提交，
贸易规划仍是不会阻塞本地结算的软工作。closing audit 默认 INCREMENTAL：首触 shadow delta
每日权威提交，并在首日、restore/异常边界及每 25 日完整复核；mismatch 在发布前阻断并关闭
本 session fast path，FULL/PROBE 保留为回滚与验证路径。投资 review prepare
只生成当前 rolling/review phase 的升序正人口 cell 列表，相关 scratch 不进存档/hash。
Inspector 的人口/市场/家族/人物页只查询选中 cell 的 committed 或切片间完整 snapshot；
人口页的预计单位/人/日由 C++ 复用正式需求内核生成 cohort-major CSR，不保存全局
cohort×good 矩阵。

当前内容目录为 135 goods、356 buildings、20 needs、11 plans。居民消费由同一 native
`Need -> variant -> component` CSR 处理；八项主食替代覆盖所有计划。Good/阶层财富弹性、
储蓄门槛和价格弹性均在 catalog 冷路径预计算，热循环使用定点 LUT。`startup_demand_runtime_mode`
为 `OFF/ACTIVE`：ACTIVE 只在投资 review batch 传播瞬态上游预期，使用 touched `(cell, good)`
max/stamp、同国可达 remote lane 和现有投资门槛；预期值不进入 EMA、价格、贸易、PKEC 或 hash。

显赫家族只表示具有可见经济影响的少数人口，匿名多数仍是 cohort 的隐含子集。`cash_claim` 是
cohort funds 内的守恒归属，建筑估值不进入货币账本；建筑组继续按
`(cell,type,owner_signature)` 聚合，家族用稳定 building handle 上的 `owned_count` 表示产业。
家族产业的 owner 岗只允许本地、同 owner signature 的成员填充，职业人口/业主/雇员统计由
`FAMILY_COMMIT` 派生。GDScript 只编译姓氏与策略并提供分页查询，不拥有家族写路径。
正式开局的 `StarterSettlementBootstrap v3` 仅声明每个首都的创始建筑目标；原生 economy
bootstrap 守恒创建一个两人采集者家族、归属一栋采集营地并晋升一名具名业主代表，随后重建同一套
家族/人物 CSR。该开局例外不修改普通地块的乡村/100 人内生形成门槛。
原生层还以“强制命名首都 + 真实采集营地”为 v2 packet 兼容识别，并在第 0..30 天的
`FAMILY_COMMIT` 对仍为空的正式首都作一次幂等修复；这使正式数据保证不依赖脚本热重载状态。

重要人物是 family membership 内的稀疏 overlay，不增加人口、钱包或市场订单。姓名、职业、岗位和
聚合建筑可双向追溯；人物财产、消费需求、满足度和税款来自 cohort 已实现结算的守恒归因，并在
`PERSON_COMMIT` 统一提交。GDScript 只补显示名和稳定目录 ID。

国内贸易软规划以 neighbor、terrain LUT 映射后的 passable/enter-cost 和冻结国界作为唯一失效语义；
玩家开局国的跨格贸易另受 sample 日冻结的 `visible_arr` 约束（`fog_solved` 之前不生效）。
原始 terrain ID 的季节性重分类不重置 scan。CSV v8 summary 发布 scan/route cursor、规范化拓扑哈希、
计划重置计数和最近原因，供长时间经济切片检查规划活性。

旧 `cell.goods_*` / `MapData.goods_*` 已删除；新增 good 是 `.tres` 数据操作。自然资源
`cell.res_*` 仍是 cell schema，未来生产系统通过经济 command 入库，不直接修改市场。

## 当前非目标

Market V2 清算本身不包含生产建筑、就业、工资或运输；这些行为由同一 C++ 权威中、居民清算前的
BUILDING_GRAPH 与国内 Trade V1 阶段承担。所得税、消费税和营业税已经进入原生结算；
负所得税在结构变更前按 cohort 汇总，以冻结生存篮子生活成本作为最低税基；正所得税仍只对
实际所得源头扣缴。
进口/出口关税具备政策、Modifier、存档和 UI 占位，但当前国内贸易事件与金额恒为零。
跨国贸易结算、外交和政治系统仍是非目标，不能另建平行 GDScript 经济状态。
## Building / employment / production

`BuildingProfile + GoodProfile producer factor → EconomyCatalog → DCWorldExt economy bridge →
NativeEconomyRuntime BUILDING_GRAPH → EconomyFacade/Inspector`。自然资源输入来自 DataCore reserve
sample，提交为 extra_change delta；建筑和就业本体不进入 MapData/schema。

跨时代经济目录为 31 registered resources / 135 goods / 356 production-method buildings / 45 professions / 20 needs / 11 plans。
`BuildingProfile.building_kind` 强制 collector/industrial 边界，`tech.*` `technology_tags` 由
国家科技 bitset 在冻结周期内执行。
两个自给升级族各有 gathering/pottery/guild/steam 四档；BUILD 拒绝已被高档替代的旧档，已有
建筑继续生产。快照公开 family、tier、最高已解锁档与当前可建状态。
BUILDING_GRAPH 内部 utility prepass 先生产 `electricity` cycle-flow，普通生产和居民
`home_energy` utility 同周期消费并在边界清零。`gold`/`silver` producer offer 按固定目录面值进入显式 mint
审计，是唯一生产性货币输入；merchant 只可拥有单一产出并严格匹配真实金/银矿藏的 collector，
后期档允许雇员和工具输入。
PKEC v8 的 employee-role 自适应工资在 active-cell employment slice 内计算：基础与岗位生活
成本形成硬下限，本地合同工资 EMA 提供岗位均薪锚；owner 在生产出售后按可用资金比例支付，
最终欠薪不追溯取消生产；owner-lot 超额利润按 25% 形成奖金。LaborMarketStore 为 native 稀疏 CSR，不进入
DataCore 或 MapData。
# Country runtime module map

- Native authority: `gdext/src/country_runtime.{h,cpp}`.
- DCWorldExt API/publication: `gdext/src/world_ext_country.cpp`, `world_ext.h`,
  `world_ext_bind_methods.cpp`.
- Resource/configuration and stable-ID boundary: `scripts/data/country_profile.gd`,
  `scripts/country/country_facade.gd`, `data/country/default_country.tres`.
- Scheduler: `scripts/simulation/systems/country_daily_system.gd`, registered by `map_generator.gd`
  as `country_daily` priority 255 before `economy_daily` 260.
- DataCore mirror: `cell.country_slot` / `MapData.country_slot_arr` only.
- Economy consumer: narrow native bridge in `economy_runtime.{h,cpp}`; frozen country epoch,
  country/cohort cash transfer, country/market goods transfer, and combined conservation.
- Persistence: PKCN v11 first, then PKEF v10 and PKEC v37 with matching schema/generation/hash；PKTR v5 preserves Trigger accumulation；旧默认 v11 ACTIVE
  因商人策略从 25%/1 日改为 12.5%/30 日分档库存基线而明确拒绝，ACTIVE 同时拒绝 v11 PROBE 和 v10。生产者收购系数现为 good-specific 硬上限（默认 95%），短缺只影响采购量/优先级；国内贸易复用同一 12.5% 营运底线，并以目的地冻结余额统一完成预检与扣款。新增商人流动性指标只进入 report、选中格快照和 Economy CSV v19，不进入 PKEC v16 或 hash。
- Player-facing read path: selected cell → `CountryFacade.cell_summary()` →
  `CellInspectorViewModel`; country commits rebuild selected summary, daily ticks live-patch values.
- Visual/vision hook: `country_committed` → `WorldRuntimeHost.refresh_country_visuals()` →
  `VisionSolver` re-solve → `enum_lut.a` rebake → `CountryBorderLayer` rebuild.
  Native runtime-graph 按 country generation 转发时必须先消费原生 country
  event stream；不得用 pulse 最后 report 中可能被后续 slice 覆盖的
  `changed_cells=0` 提前跳过。Facade 从 create/transfer/claim 事件归一化
  territory dirty，保持 `country_committed` 为唯一视觉/视野广播。
  Exploration progress persists as PKSV `pkfg` (after PKCN); the Inspector gates
  tabs by `VisionSolver.fog_state()`. See
  [`vision-fog-and-borders.md`](../docs/cpp-dots-runtime/vision-fog-and-borders.md).

## Economy v18 portfolio investment

Runtime investment uses the native `endogenous_owner_portfolio_v8` path. Every
10-day cell review selects at most four unique building types, derives an
aggregate entrepreneur count from disposable-income improvement, and fills at
most 25 percent of the persistent marginal-output gap. Population, capital,
credit, construction stock, and same-good gap budgets are shared across the
portfolio; each type produces one aggregate BUILD command and no per-person or
per-building loop. Multi-type portfolios cap one type at 50 percent of new
owner slots. Before scoring, unused installed capacity and pending construction
are deducted from the output deficit. Established types may grow at most 10
percent per review and absent types seed at one building; entry into the
merchant profession requires at least 50 percent projected disposable-income
improvement. Recovery liquidation remains aggregate and retires at most 25
percent of confirmed excess capacity per review. Only realized settled losses
advance suspension; execution blockage remains active/idle. The test fixture
creates one merchant post per populated cell and protects only the final local
merchant from profession change. Policy restore originated in PKEC v18; current
debug recording is Economy CSV v22.

## Plant water, ecological signals, and production climate

- `cell.plant_available_water` is a climate-owned F32 DataCore/MapData slot.
  Land cells combine base humidity, 30-day water balance, and positive soil
  storage into `[0,1]`; water cells publish zero. Native scalar/thread/combined
  paths and the retained GDScript fallback share the formula.
- Natural resources select their climate columns explicitly. Fertile soil,
  timber, and wild game use 30-day temperature plus plant water; fish use
  30-day temperature plus ambient moisture; geological resources keep current
  temperature and ambient moisture. Arable, paddy, plantation, and pasture land
  remain static carrying stocks.
- `ProductionClimateProfile` is catalog configuration. `NativeEconomyRuntime`
  freezes due-cell 30-day temperature/plant water, applies the Q16 capacity
  after labor/input/capital/resource limits, and publishes building diagnostics.
  No new scheduler stage or GDScript economy authority is introduced.
- Current persistence/debug are PKEC v28 and Economy CSV v22. PKEC v28 retains
  production-climate/fiscal/notable-family authority and adds important-person records and needs;
  its reader supports explicit v26 empty-person and v25 empty-family migrations plus v23/v22 paths.

## Climate moisture round visibility

- Authority: `DCWorldExt` `cell_moisture` slot.
- Writers: climate Pass-A/Pass-B and transpiration; weather direct moisture is
  disabled by default and hydrology reaches climate moisture through Pass-A.
- Response: Pass-A uses the existing dt-aware moisture target relaxation at
  `0.24/day` (`~0.936` over the default 10-day native round). Large
  completed-round changes are intentional; intermediate-slice visibility is not.
- Hydrology response is sign-aware: positive soil/water-balance anomalies use
  `1.82 / 1.04`, while negative anomalies use `2.21 / 1.30`. This deepens
  emergent drought minima without changing wet-side gains or adding a seasonal curve.
- Native daily visibility: intermediate slices stay slot-only; `done=true`
  snapshots `cell_moisture` into the exact round `MapData` and reports
  `moisture_committed`, `moisture_commit_path`,
  `moisture_commit_slot_size`, and `moisture_commit_flush_ms`.
- Cross-slice bridge rule: after the round-start import, bulk and keyed MapData
  refreshes preserve `cell_moisture` until the wrapper finalizer completes the
  visible commit; this includes `natural_resource_daily` input refreshes.
  Failure releases protection without publishing partial state.
- Legacy/standalone visibility: existing immediate pass flushes remain.

## Prosperity / settlement naming

- Authority: native economy `SettlementStore`; committed population is the only
  input.
- Commit: `aggregate_publish/COMMIT` consumes deduplicated changed cells.
- Bridge: selected-cell summary plus full settlement snapshot / bounded deltas.
- Persistence: current PKEC v28 retains the fixed generations and sparse stable-ID names introduced
  by PKEC v24.
- Formal opening-country cells carry a native forced-name bit, so every
  20-person capital is named while its prosperity tier remains population-only.
- Visible boundary: Godot pooled label layer; no economic mirror or fallback.
- Settlement lifecycle implementation: `gdext/src/economy_runtime_settlements.cpp`
  owns committed population lookup, prosperity hysteresis, stable name
  assignment/release, initialization/update and bounded settlement row fields.
  `NativeEconomyRuntime::SettlementStore` remains the sole mutable owner, and
  aggregate publish/COMMIT ordering remains in the runtime orchestration path.

- TriggerRuntime: `gdext/src/trigger_runtime.{h,cpp}`, `world_ext_trigger.cpp`,
  `scripts/trigger/trigger_facade.gd`, `trigger_daily_system.gd`; PKTR provider in
  `game_save_coordinator.gd`.
- EffectRuntime: `gdext/src/effect_runtime.{h,cpp}`, `world_ext_effect.cpp`,
  `scripts/effect/`, `effect_runtime_system.gd`; PKEF provider in
  `game_save_coordinator.gd`. It owns packed effect programs, instances,
  frozen snapshots, plans, transactions, durable external bindings and ACK
  cursors. Native adapters stage Country/Economy POD commands and journal
  `PUBLISH_EVENT`; domain owners retain every authoritative mutation.

- Economy trade implementation: `gdext/src/economy_runtime_trade.cpp`; the root
  `economy_runtime.cpp` retains only trade stage orchestration and cross-stage
  aggregation. Merchant procurement capability helpers remain in the building/
  production boundary.
- Economy persistence: `gdext/src/economy_runtime_persistence.cpp` owns lifecycle
  and committed-boundary validation;
  `gdext/src/economy_runtime_persistence_write.cpp` owns ordered PKEC v34 encoding,
  including family expeditions, frozen route/payload CSR and Effect bindings;
  `gdext/src/economy_runtime_persistence_read.cpp` owns validated decoding.
  `economy_runtime_persistence_codec.h` is the sole section-number contract, and
  `economy_runtime_binary_codec.h` is shared with root event archive encoding.
- Economy bounded query facade:
  `gdext/src/economy_runtime_queries_population.cpp` owns settlement/population
  snapshots, while `gdext/src/economy_runtime_queries_market_building.cpp` owns
  market, satisfaction, fiscal, building, family, notable-person and per-cell
  trade-order facade methods. Both operate on the sole `NativeEconomyRuntime`
  owner and do not advance scheduler stages.
- Shared economy Godot variant decoding:
  `gdext/src/economy_runtime_variant_helpers.h`; extracted catalog/profile/
  configuration/query code and retained root event code use the same stateless
  helper implementation.
- Economy catalog/profile/configuration split:
  `gdext/src/economy_runtime_catalog.cpp` owns stable-ID catalog compilation,
  `gdext/src/economy_runtime_profile.cpp` owns formula registration and profile
  decoding, and `gdext/src/economy_runtime_configuration.cpp` owns
  configure/bootstrap/command submission. The root retains epoch/stage, worker,
  publish and event/report orchestration; native authority and public APIs are
  unchanged.
- Economy event/report split: `gdext/src/economy_runtime_events.cpp` owns
  committed trace/cashflow/gameplay facts, event schema/filter/query/ack/report
  and PKEJ archive streaming. The aggregate-publish stage remains root-owned,
  and trace hashing remains shared with root-only deterministic identity work.
- Economy epoch lifecycle split: `gdext/src/economy_runtime_epoch.cpp` owns
  epoch preflight, frozen country/workset setup, transient epoch initialization,
  opening audit lanes and completed performance snapshots. The root
  `economy_runtime.cpp` retains ongoing stage dispatch, outer cursors, worker
  scheduling and stage order.
- Economy publish split: `gdext/src/economy_runtime_publish.cpp` owns
  publish-phase-local cursors, closing population/money/goods audits,
  settlement watermark and trade diagnostics, resource-delta readiness and the
  ordered `aggregate_publish/COMMIT` handoff. The root remains the only owner
  of aggregate-publish stage entry, slice/yield boundaries and next-stage
  selection; `_epoch_active`, `_last_committed_day` and
  `capture_completed_perf_snapshot()` keep their existing authority/contract.
- Economy result-container split: `gdext/src/economy_runtime_results.cpp`
  owns `MarketResult`/`ProductionResult` reset and capacity accounting plus
  worker TLS sink definitions. The root remains the sole owner of worker
  dispatch, result merge order, stage transitions and conservation checks.
- Economy diagnostics split: `gdext/src/economy_runtime_diagnostics.cpp`
  owns read-only stage progress, memory accounting, household slice breakdown
  and compact/full reports. The report schema and scheduler-visible fields are
  unchanged; `economy_runtime.cpp` still owns all stage mutations and worker
  execution.
