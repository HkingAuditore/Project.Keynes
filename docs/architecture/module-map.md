# 模块地图

改一个模块前先在本页找到它的文件、门、存档段、测试和 skill，再读对应文件；不用通读其他模块。
本页的路径由 `tools/ci/check_module_map.py` 检查是否存在，文件改名或搬迁时同步改这里。
规则见 [module-boundaries.md](module-boundaries.md)，改法见 [development-guide.md](development-guide.md)。

## 按任务找入口

| 要做的事 | 先读 | 必跑 |
|---|---|---|
| 改某个模块内部的公式或行为 | 下表中该模块的所有者文件和 skill | 静态护栏；改了 C++ 再检查重复运行一致；不改行为时与改前临时候选对照 |
| 让模块 A 用模块 B 的新能力 | [development-guide.md](development-guide.md) 的“改一个模块”，`gdext/src/<B>_api.h` | `tools/ci/check_module_api.py`、`tools/ci/check_cpp_deps.py` |
| 新增跨模块读取或请求 | [development-guide.md](development-guide.md) 的“跨域读取与请求” | `tools/ci/check_committed_views.py`、`tools/ci/check_resolve_apply.py`、`tools/ci/check_cross_domain_inventory.py` |
| 新增或修改存档字段 | [development-guide.md](development-guide.md) 的“存档”，[current-state.md](current-state.md) 的“存档” | `tools/ci/check_save_contracts.py`、`tools/ci/check_replay_matrix.py` |
| 改每日顺序或阶段函数 | [development-guide.md](development-guide.md) 的“改每日模块”，`gdext/src/native_simulation_host.cpp` | `tools/ci/check_module_contracts.py`、重复运行一致与改前临时候选对照 |
| 加环境开关或故障点 | `gdext/src/runtime_switch_registry.h` | `tools/ci/check_runtime_switches.py` |
| 改地形、天气、光照、时代、军事界面等具体功能 | [feature-guides.md](feature-guides.md) 的对应小节 | 该小节列出的测试 |
| 拆分超限文件 | [development-guide.md](development-guide.md) 的“机械搬迁与拆分”，[source-module-splits.md](source-module-splits.md) | `tools/ci/check_size_ratchet.py`、`tools/ci/check_cpp_deps.py` |
| 新增脚本接口 | `tools/ci/world_ext_binding_modules.json`（按定义文件确定模块）、`gdext/src/world_ext_bind_*.cpp`（每模块一个绑定文件）、`gdext/src/world_ext.h`（按模块分段声明）；入口 `gdext/src/world_ext_bind_methods.cpp` 只调用各模块 | `tools/ci/world_ext_bindings.py`、`tools/ci/check_world_ext_bindings.py`；Godot 方法列表比较 |
| 检查或迁移脚本直接访问原生绑定 | `tools/ci/world_ext_binding_modules.json` 的 `script_dirs`、[feature-guides.md](feature-guides.md) 的“脚本原生访问边界”、`tools/ci/script_native_access_baseline.json` | `tools/ci/check_script_native_access.py --report`、`tools/ci/test_architecture_guards.py` |
| 改 skill | `skills/` 下的源文件，见 [分发说明](../ai-skills.md) | `tools/ci/check_skill_mirrors.py`、`tools/ci/check_module_map.py` |

全部静态护栏的命令和回归、黄金、回放的用法在 [development-guide.md](development-guide.md) 的“护栏与检查”。PR 上由 `.github/workflows/runtime-checks.yml` 的 `architecture-guards` 自动运行静态护栏。

## 每日域模块

原生文件都在 `gdext/src/`，脚本和测试都在 `Project/project-keynes/` 下。阶段函数统一是 `gdext/src/native_simulation_stage_<域>.cpp`。

| 模块 | 所有者文件 | 别人怎样调用它 | 宿主与绑定层（组合根） | 存档段 | 脚本入口 | 测试 | skill |
|---|---|---|---|---|---|---|---|
| Climate | `gdext/src/runtime_climate_*` | 无接口头（目标未实现） | `gdext/src/native_simulation_host_climate.cpp`、`gdext/src/world_ext_climate.cpp` | CLM2 | `Project/project-keynes/scripts/simulation/systems/climate_daily_system.gd`（保留入口、调度游标与状态所有权；异步轮、finalizer、诊断与地形同步在 `scripts/simulation/climate/climate_daily_runtime.gd`）、`Project/project-keynes/scripts/weather`、`Project/project-keynes/scripts/geography/map_generator.gd`（保留入口、游标与状态所有权）以及 `scripts/simulation/climate/{pass_a,pass_b}.gd`、`scripts/simulation/climate/{native_daily_bundle_builder,native_daily_publish,runtime_climate_capture,season_refresh_coordinator}.gd`、`scripts/simulation/ocean/{water_pass,land_pass}.gd`、`scripts/simulation/sea_ice/daily_pass.gd`、`scripts/simulation/biology/transpiration_pass.gd`（native dispatch、daily bundle、结果发布、runtime capture、季节刷新编排与切片实现） | `gdext/tests/climate_parity_test.cpp`、`tools/ci/check_committed_replay.py`、`Project/project-keynes/tests/runtime` 与 `tests/world` 的 climate 用例 | project-keynes-climate-runtime |
| Country | `gdext/src/country_*`、`gdext/src/runtime_country_pod.*` | `gdext/src/country_api.h`；它调用宿主走 `gdext/src/country_host_port.h` | `gdext/src/native_simulation_host_country_*.cpp`、`gdext/src/world_ext_country*.cpp`（命令入队与生效日归 `world_ext_country_commands.cpp`） | PKCN | `Project/project-keynes/scripts/country/country_facade.gd` | `Project/project-keynes/tests/country` | project-keynes-country-runtime、project-keynes-tax-runtime |
| Trigger | `gdext/src/trigger_runtime.*`、`gdext/src/runtime_trigger_*` | 无接口头（目标未实现） | `gdext/src/native_simulation_host_trigger*.cpp`、`gdext/src/world_ext_trigger.cpp` | PKTR | `Project/project-keynes/scripts/trigger/trigger_facade.gd` | `Project/project-keynes/tests/trigger` | project-keynes-trigger-runtime |
| Ideology | `gdext/src/ideology_*`、`gdext/src/runtime_ideology_*`（`ideology_runtime.cpp`、`ideology_runtime_annual.cpp`、`ideology_runtime_catalog.cpp`、`ideology_runtime_commands.cpp`、`ideology_runtime_daily.cpp`、`ideology_runtime_effects.cpp`、`ideology_runtime_effects_derived.cpp`、`ideology_runtime_offers.cpp`、`ideology_runtime_persistence.cpp`、`ideology_runtime_queries.cpp`、`ideology_runtime_state.cpp` 及 internal/common include） | 无接口头；意见输入经 `gdext/src/ideology_opinion_bridge.h` | `gdext/src/native_simulation_host_ideology.cpp`、`gdext/src/world_ext_ideology.cpp` | PKID | `Project/project-keynes/scripts/ideology/ideology_facade.gd` | `Project/project-keynes/tests/ideology` | project-keynes-ideology-runtime |
| Effect | `gdext/src/effect_*`、`gdext/src/runtime_effect_*`（`effect_runtime.cpp`、`effect_runtime_catalog.cpp`、`effect_runtime_configuration.cpp`、`effect_runtime_dispatch.cpp`、`effect_runtime_instances.cpp`、`effect_runtime_lifecycle.cpp`、`effect_runtime_modifier.cpp`、`effect_runtime_persistence.cpp`、`effect_runtime_programs.cpp` 及 internal header） | 无接口头（目标未实现） | `gdext/src/native_simulation_host_effect.cpp`、`gdext/src/world_ext_effect.cpp` | PKEF | `Project/project-keynes/scripts/effect/effect_facade.gd` | `Project/project-keynes/tests/effect` | project-keynes-effect-runtime |
| Modifier | `gdext/src/modifier_*`、`gdext/src/runtime_modifier_*` | `gdext/src/modifier_api.h` | `gdext/src/native_simulation_host_modifier.cpp`、`gdext/src/world_ext_modifier.cpp` | PKCM、PKGP | `Project/project-keynes/scripts/modifier/modifier_facade.gd` | `Project/project-keynes/tests/runtime` 下的 modifier 用例 | project-keynes-modifier-runtime |
| Economy（含家庭、人物、建筑） | `gdext/src/economy_*`、`gdext/src/runtime_economy_*`、`gdext/src/trade_visual_cache.*` | `gdext/src/economy_api.h`；它调用宿主走 `gdext/src/economy_host_port.h` | `gdext/src/native_simulation_host_economy.cpp`、`gdext/src/world_ext_economy*.cpp` | ECP2、PKEC | `Project/project-keynes/scripts/economy/economy_facade.gd`、`Project/project-keynes/scripts/economy/economy_catalog.gd` | `Project/project-keynes/tests/economy`、`Project/project-keynes/tests/family`、`Project/project-keynes/tests/building` | project-keynes-economy-runtime、project-keynes-family-runtime |
| Events | `gdext/src/runtime_events_authority.*` | 无接口头；Trigger 经已提交视图读取 | `gdext/src/world_ext_events.cpp` | PKSR 内的 events_bytes | `Project/project-keynes/scripts/narrative` | `Project/project-keynes/tests/game` 下的 narrative 用例 | — |

C1 的 `runtime_climate_passes.cpp` 定义按职责分到 `gdext/src/runtime_climate_passes_cyclone.cpp`、`gdext/src/runtime_climate_passes_hydrology.cpp`、`gdext/src/runtime_climate_passes_weather.cpp` 和 `gdext/src/runtime_climate_passes_stage_b.cpp`；声明仍集中在 `gdext/src/runtime_climate_passes.h`，round 编排和其余 pass 留在原文件。

C2 的 `world_ext_simulation_host.cpp` 按职责分到 `gdext/src/world_ext_simulation_host_self_tests.cpp`、`gdext/src/world_ext_simulation_host_climate.cpp` 和 `gdext/src/world_ext_simulation_host_save.cpp`；跨文件的 `runtime_state_name` 放在 `gdext/src/world_ext_simulation_host_internal.h`，worker 控制、时钟与命令提交仍由原文件持有。

C5 的 `world_ext_climate.cpp` 按职责分到 `gdext/src/world_ext_climate_async.cpp`（异步 round 与唯一状态）、`gdext/src/world_ext_climate_ocean.cpp`（ocean water/land 与 sea ice）和 `gdext/src/world_ext_climate_surface.cpp`（transpiration、runtime hydrology、albedo、vegetation dynamics、climate feedback、stage B）；Pass-A、ENSO、Pass-B 和不确定归属的内容仍由原文件持有。

C6 的 `economy_runtime_building_investment.cpp` 按职责分到 `gdext/src/economy_runtime_building_investment_startup.cpp`（startup demand、startup producer 与材料准备）、`gdext/src/economy_runtime_building_investment_candidates.cpp`（单格候选评估）、`gdext/src/economy_runtime_building_investment_portfolio.cpp`（portfolio 资金可行性、分配、预检与提交）；跨文件的 `BuildingInvestmentCellContext` 和共享无状态计时 helper 放在 `gdext/src/economy_runtime_building_investment_internal.h`，职业人口 `thread_local` 访问函数与 Context 构造函数保留在原文件以维持单一定义，原文件还保留 epoch 准备、单格 prepare、外层编排和未明确归属的 scratch helper。

Economy 冻结输入的内部协作者：`gdext/src/economy_runtime_country_cache.cpp` 负责科技可用性、领土索引与拓扑 hash 的精确输入缓存及相关诊断，私有状态片段为 `gdext/src/economy_runtime_internal_country_cache.h`；`gdext/src/economy_runtime_family_effect_inputs.cpp` 负责领土查询、标签快照、地理/家族/科技等效果指标准备与输入声明，仍属于同一个 `NativeEconomyRuntime`；`gdext/src/economy_runtime_persistence_header.cpp` 负责保存头的目录/世界身份校验与候选列初始化，分段记录解码仍在 persistence_read；`gdext/src/economy_runtime_restore_scratch.cpp` 负责安装读档候选前的运行时暂存清理与缓存失效，读档事务编排仍在 persistence。测试声明归 `gdext/src/economy_runtime_test_access.h`，缓存与固定建筑目录用例归 `gdext/src/economy_runtime_country_cache_tests.cpp`、`gdext/src/economy_runtime_building_metrics_tests.cpp`、`gdext/src/economy_runtime_producer_continuation_tests.cpp`，与 `gdext/src/economy_runtime_effect_selector_tests.cpp` 一起由 `Project/project-keynes/tests/ideology/ideology_target_selector_test.gd` 进入。输入、诊断与验证契约见 [feature-guides.md](feature-guides.md) 的“经济冻结输入与标签采样”。

INPUT_CAPTURE、GAMEPLAY_EFFECT、VISUAL、COMMIT 四个域由宿主自己实现，没有独立业务模块；它们的写入者见 [current-state.md](current-state.md) 的“十二域”。每个域的 cadence、读写集合和存档段的机检登记在 `tools/ci/runtime_module_contracts.json` 与 `tools/ci/cpp_save_section_contracts.json`。

## 十二域以外

| 模块 | 所有者文件 | 别人怎样调用它 | 绑定层 | 存档段 | 脚本入口 | 测试 | skill |
|---|---|---|---|---|---|---|---|
| Military（主线程） | `gdext/src/military_*` | `gdext/src/military_bridge.h` | `gdext/src/world_ext_military.cpp`、`gdext/src/world_ext_economy_military.cpp`、`gdext/src/world_ext_military_cell_stats.cpp` | PKMI2 等，见 [module-boundaries.md](module-boundaries.md) 的“请求与提交” | `Project/project-keynes/scripts/military/military_facade.gd` | `gdext/tests/military_core_selftest_main.cpp`、`Project/project-keynes/tests/runtime` 下的 military 用例 | — |
| 科技 | 目录归 `Project/project-keynes/scripts/economy/technology_catalog.gd`，研究状态归 Country | 经 Country 命令 | — | 随 PKCN | `Project/project-keynes/scripts/technology`、`Project/project-keynes/scripts/research` | `Project/project-keynes/tests/technology` | project-keynes-technology-runtime、project-keynes-technology-tree-design |
| 会话、存读档、玩家输入 | `Project/project-keynes/scripts/game` | `Project/project-keynes/scripts/game/world_runtime_host.gd` 的公开入口：放行已到期的日期，`runtime_publication_reader.gd` 控制读取间隔，日推进、生成、GM、展示和 Climate authority 分别委派到 `world_runtime_daily_adapter*.gd`、`world_runtime_generation_adapter.gd`、`world_runtime_gm_adapter*.gd`、`world_runtime_presentation.gd`、`world_runtime_climate.gd` | — | PKSV 整档，由 `Project/project-keynes/scripts/game/game_save_coordinator.gd` 协调 | `Project/project-keynes/scripts/game/player_controller.gd`（玩家会话公开入口；军事、时代/理念、选择和叙事职责在 `scripts/game/player_controller/{military,progression,selection,narrative}.gd`） | `Project/project-keynes/tests/game` | project-keynes-game-flow-runtime、project-keynes-player-controller |
| 地图生成与烘焙 | `gdext/src/world_ext_generate*.cpp`、`gdext/src/world_ext_bake*.cpp`、`gdext/src/world_ext_cell_luts.cpp`（逐格 LUT 与弹射色字节编码；共享量化在 `world_ext_internal_cell_luts.h`） | 生成与显示期请求，不拥有每日模拟状态 | 同左 | 地图输入随整档 | `Project/project-keynes/scripts/geography/map_generator.gd`（请求与检查：`geography/map_generation/native_generation_bridge.gd`；装配与基线：`geography/map_generation/terrain_gen.gd`；季节刷新编排：`scripts/simulation/climate/season_refresh_coordinator.gd`；自然资源初始分布与储量：`scripts/simulation/economy/map_resource_initializer.gd`；保存/停止/worker：`scripts/game/map_runtime_bridge.gd`；规则目录：`scripts/game/map_rules_initializer.gd`；国家与起始国家：`scripts/country/map_country_initializer.gd`）、`Project/project-keynes/scripts/rendering/map_baker.gd` 与 `rendering/bakers/{atlas_encoders,cell_lut_baker,climate_baker,dynamic_atlas_baker,ocean_current_baker,physical_circulation_baker,terrain_baker,terrain_index_baker,weather_baker}.gd` | `Project/project-keynes/tests/world` | map-generation-pipeline |
| 显示与界面 | `Project/project-keynes/scripts/rendering`、`Project/project-keynes/scripts/ui` | 只读已发布结果 | — | 无 | `Project/project-keynes/scripts/ui/game_ui_manager.gd`（场景组装和公开转发；国家卷宗、时代和覆盖层职责在 `scripts/ui/game_ui/{country_routes,era_progression,overlays}.gd`）；理念工作区宿主为 `ui/components/ideology_workspace.gd`，显示构造和模型刷新在 `ui/components/ideology_workspace_presentation.gd`；地块检查器宿主为 `ui/cell_inspector_view_model.gd`，按分区委派到 `ui/cell_inspector/{object_dossiers,military,overview,population_market,construction,geography}.gd`；地图出图和点击依据分别在 `rendering/player_map_viewport.gd`、`rendering/map_drawn_frame.gd`；地图渲染宿主为 `rendering/hex_renderer.gd`，其职责协作者在 `rendering/renderer_*.gd`；植被宿主为 `rendering/shrub_layer.gd`，其职责协作者在 `rendering/shrub/*.gd` | `Project/project-keynes/tests/rendering`、`Project/project-keynes/tests/ui` | project-keynes-ui-art-direction、building-visual-pcg、vegetation-visual-pcg |

Military 的 `military_core.cpp` 保留目录、生命周期、每日编排和哈希；同类成员按职责放到
`military_core_store.cpp`（国家/部队/lots/事件/查询）、`military_core_personnel.cpp`
（征召、训练、补员、收据和士气）、`military_core_commands.cpp`（提交、命令应用及编成）和
`military_core_payroll.cpp`（按实际付款对象结算）。`military_core_supply_index.cpp` 负责按需
计算周边采购范围，`military_core_engagement_index.cpp` 负责交战到部队的反向索引；均为派生
状态，不进入 PKMI v7。`military_core_selftest.cpp` 调用同族 `*_selftest.inc` 用例；
`gdext/tests/military_core_perf_trace.cpp` 提供可用于改前/改后的同源码逐日状态和意图对照入口。
`military_core_store.cpp` 同时负责驻军位置链的保存校验和采购候选格枚举；
`military_core_front_selftest.inc` 覆盖战线反向位置与旧档链兼容，
`military_core_market_reuse_selftest.inc` 覆盖每日临时市场复用、步骤额度隔离和生命周期清理。
`military_core_flight_sums.h` 是采购内部的在途数量查询表，只依赖标准 C++ 值类型；
`military_core_flight_selftest.inc` 对照原求和路径并检查碰撞、负值、溢出边界及调用间清理。

气候每日 Pass-A、Pass-B、ocean water/land、sea ice 和 transpiration 现在由各自 simulation 协作者承载 native dispatch 与切片实现；`map_generator.gd` 只保留公开入口、协作者组合，以及游标、缓存、统计和 slot/MapData 状态所有权。入口仍负责 `has_method`/签名探测、knob 打包、发布与失败处理；native 不可用或返回失败时用 `push_error` 保留上一份字段并返回失败。SHADOW、PROBE、A/B 和诊断入口继续保留，但不再计算一份 GDScript 热循环。

气候封包摘要归 `gdext/src/runtime_climate_input_hash.cpp`，宿主在发布不可变输入时计算，Climate 内核和日输入记录共用这个定义。

天气场的一日输入在 `gdext/src/runtime_climate_weather_input.h`。物理场的只读交付、校验和存档编解码在 `gdext/src/runtime_climate_physics_state.cpp`。

军事、自然资源恢复、视野等表外推进者的线程与交接见 [current-state.md](current-state.md) 的“十二域以外的推进”，登记在 `tools/ci/runtime_advancers.json`。

经济冷配置的共同实现位于 `scripts/economy/economy_facade_configuration.gd`，显示目录准备位于 `scripts/economy/economy_facade_display.gd`。
异步资源请求的完成回收归 `scripts/game/loading_resource_request.gd`，取消世界不会阻塞等待解析。
加载期规则目录由 `Project/project-keynes/scripts/game/loading_catalog_context.gd` 统一管理
本次请求的工作预算与不可变编译产物；Economy/Modifier/Effect 编译器提供同步与协作入口。
建筑编译步骤归 `scripts/economy/economy_building_catalog_compile_steps.gd`，承载力列归
`scripts/economy/economy_carrying_catalog_compiler.gd`，固定属性表归
`scripts/modifier/modifier_catalog_stat_tables.gd` 与 `scripts/effect/effect_metric_keys.gd`。
验收入口为 `Project/project-keynes/tests/world/loading_catalog_cooperative_test.gd` 与
`tests/world/cooperative_world_generation_test.gd`；专项契约见 feature-guides 的加载期目录准备。

建筑内容精简决策在 `Project/project-keynes/tools/technology_tree/building_distinction_review.json`；
差异化、删除引用和发展成就主体的回归为
`Project/project-keynes/tests/building/building_distinction_test.gd`。
目录增删还须检查 `Project/project-keynes/scripts/research/development_achievement_catalog.gd`、
科技的完整门槛及生产许可，并重烘 `Project/project-keynes/tools/prebake_loading_catalogs.gd`。

## 读不动的大文件

下列文件远超行数上限，不要整读；用符号搜索定位后只读相关函数。完整清单是 `tools/ci/size_baseline.json`。

- `gdext/src/country_runtime.cpp`（以及 `country_runtime_persistence.cpp`、`country_runtime_queries.cpp`、`country_runtime_economy_assets.cpp`、`country_runtime_research.cpp`、`country_runtime_peer.cpp`、`country_runtime_commands.cpp`、`country_runtime_internal.h`）、`gdext/src/effect_runtime.cpp` 及其 catalog/configuration/dispatch/instances/lifecycle/modifier/persistence/programs 协作者、`gdext/src/ideology_runtime.cpp` 及其 catalog/commands/daily/effects/effects_derived/offers/persistence/queries/state 协作者、`gdext/src/world_ext_climate.cpp`、`gdext/src/world_ext_climate_async.cpp`
- `Project/project-keynes/scripts/geography/map_generator.gd`、`Project/project-keynes/scripts/rendering/map_baker.gd`、`Project/project-keynes/scripts/rendering/bakers/`、`Project/project-keynes/scripts/weather/native_bridge.gd`、`Project/project-keynes/scripts/ui/cell_inspector/construction.gd`

经济黄金诊断的字段散列由 `gdext/src/economy_golden.cpp` 统一实现：持每日边界锁后，经 `economy_api` 读取当前公式所有者的完整人口/市场列，未接管前不读部分镜像；纯 POD 场景沿用自己的状态。诊断读取不提交或修改模拟，字段顺序及日戳不变；覆盖用例为 `gdext/src/economy_golden_tests.cpp`。
国家脚本命令的值打包归 `scripts/country/country_command_batch.gd`，CountryFacade 仍持有配置和提交入口；GM 日期与回执组装归 `world_runtime_gm_commands.gd`。

高负载一致性入口为 `tools/ci/check_runtime_load_consistency.py`：正式周期用 `tests/runtime/runtime_load_daily_test.gd`，命令与存档用 `tests/runtime/committed_view_replay_test.gd`；检查器反例见 `tools/ci/test_runtime_load_consistency.py`。帧时钟过载恢复检查为 `tests/runtime/runtime_clock_overload_recovery_test.gd`。范围与设计方向见 `docs/plans/high-load-consistency.md`，实际验证见 feature-status。

Climate ACTIVE 慢层刷新日期归 `scripts/simulation/systems/season_refresh_system.gd`，由 `scripts/simulation/climate/runtime_climate_capture.gd` 在输入采集前调用；继续边界复用 CLM2 和 `scripts/game/world_runtime_climate_restore.gd` 的已有日期。`tests/world/season_refresh_consumer_test.gd` 使用真实日期发布及植被输入构建检查同日抑制、提前输入和跨调用完成；`tests/world/season_refresh_schedule_test.gd` 覆盖冷重建、重复或遗漏调度观察及刷新前后的继续日期。
资源视觉入口：`Project/project-keynes/scripts/rendering/resource_visual_layer.gd` 持有工作队列/预算/记忆；同目录 `resource_visual_geometry.gd`、`resource_visual_materials.gd`、`resource_visual_work_queue.gd` 分别处理实例、材质、变化调度。变化由 `MapData.resource_visual_inputs_changed` 接入，原生数组发布映射在 `gdext/src/resource_visual_publication.h`。验证见 `tests/economy/resource_visual_update_test.gd` 和 `resource_visual_perf_test.gd`。`MapData` 只读查询归 `Project/project-keynes/scripts/geography/map_data_queries.gd`，生物占领诊断汇总归 `Project/project-keynes/scripts/geography/map_generation/bio_occupancy_summary.gd`；物种出现保底（生成期逐级放宽播种输入）归同目录 `bio_occupancy_guarantee.gd`，契约见 [feature-guides.md](feature-guides.md) 的“物种出现保底”。
`gdext/src/resource_visual_builder.h`、`gdext/src/resource_visual_builder.cpp` 注册独立的 `NativeResourceVisualBuilder` 纯计算类，
经 `rendering/resource_visual_native_slice.gd` 接入单个同步片段；首次区域输入准备归
`rendering/resource_visual_chunk_inputs.gd`。像素对象表与数值列的发布归 `WorldData`，三处
terrain baker 调用共用发布接口；这些数据仅供显示，不拥有模拟状态，也不增加存档字段。

陆水覆盖形状由 `rendering/terrain_coverage_mesh.gd` 构建。整屏及局部浓雾裁剪由
`rendering/renderer_fog_culling.gd` 在绘制前判断，读取随迷雾贴图发布的
`WorldData` 遮挡索引，`rendering/terrain_fog_mesh.gd` 合并保留区域并更新绘制命令。
细节层同帧裁剪归 `rendering/fog_detail_culling.gd`，实例批次的绘制边界由现有上传入口
经 `rendering/fog_draw_bounds.gd` 记录。验证入口为 `tests/rendering/terrain_draw_coverage_test.gd`
和 `tests/rendering/detail_fog_culling_test.gd`。

天气风场纹理由 `Project/project-keynes/scripts/rendering/weather_wind_source.gd` 按天气发布更新，
由 `cloud_shadow_field.gd` 持有并将同一份纹理提供给云影和天气云；关闭云影只停止绘制。
云影向地表、水面和细节层的材质绑定归 `renderer_lighting_bindings.gd`；水面入口只转发，
仍使用当前纹理和绑定到渲染宿主的回调，不保存世界或跨帧状态。
回归入口：`tests/rendering/cloud_weather_quality_test.gd`。手机执行方式与逐日对照见
`Project/project-keynes/tests/runtime/mobile_runtime_worker_test.gd`。

海拔和风向专题图的刷新由 `scripts/game/world_runtime_overlay.gd` 管理。
`gdext/src/map_overlay_input_publication.cpp` 登记已安装的显示列和内容标记，供到期时核对。
贴图生成与统计归 `scripts/rendering/data_overlay_baker.gd`，定向用例见
`tests/world/map_overlay_cell_lut_test.gd`。

玩家画质预设与自定义选项保存在 `scripts/game/game_settings_service.gd`，档位解析在
`scripts/game/graphics_quality_settings.gd`。主菜单和暂停菜单共用
`scenes/ui/graphics_quality_options.tscn`。应用到地图和显示层的入口在
`scripts/rendering/renderer_graphics_settings.gd`，陆地和水面绘制尺寸归同目录的
`terrain_render_scale.gd`。测试入口见[电脑和手机画质设置](feature-guides.md#电脑和手机画质设置)。

水面波纹、迷雾梯度和天气新旧值的数值纹理共用 `rendering/render_data_table.gd`。更新入口依次在 `renderer_shader_water.gd`、`fog_of_war_layer.gd`、`weather_layer.gd`。水波表的周期和待画区域由 `rendering/water_ripple_lattice.gd` 持有。地面读取、植被与建筑的着色入口见 [地图绘制中的共享计算](feature-guides.md#地图绘制中的共享计算)，数据校验见 `tests/rendering/render_data_tables_test.gd`。

迷雾连续遮罩与天气视野门控共用 `shaders/include/cell_field_overlays.gdshaderinc` 的权重函数；
真实 GPU 遮罩、混合视野格心与可选前后耗时对照见 `Project/project-keynes/tests/rendering/fog_continuous_mask_test.gd`。

提交前整理的脚本职责位置见 [源文件职责拆分](source-module-splits.md) 的“移动端 PR 提交前的长度与依赖修复”。
原生开拓的存储、查询、人口载荷分别在 `gdext/src/economy_runtime_colonization_store.cpp`、
`gdext/src/economy_runtime_colonization_queries.cpp`、`gdext/src/economy_runtime_colonization_payload.cpp`，
共同无状态工具在 `gdext/src/economy_runtime_colonization_internal.h`。
人物列与需求记录声明在 `gdext/src/runtime_economy_person_store.h`，家族专用声明仍在
`gdext/src/runtime_economy_family_side_tables.h`；两者仍由 `gdext/src/runtime_economy_state.h` 组合拥有。
交易收付款、到货与发运在 `gdext/src/economy_runtime_trade_settlement.cpp`；家族/人物存档解码在
`gdext/src/economy_runtime_persistence_lineage.cpp`；金额内联实现在 `gdext/src/economy_runtime_internal_arithmetic.h`。
