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
| 改 skill | `.agents/skills` 下的权威副本，再 `tools/ci/check_skill_mirrors.py --sync <skill>` | `tools/ci/check_skill_mirrors.py` |

全部静态护栏的命令和回归、黄金、回放的用法在 [development-guide.md](development-guide.md) 的“护栏与检查”。PR 上由 `.github/workflows/runtime-checks.yml` 的 `architecture-guards` 自动运行静态护栏。

## 每日域模块

原生文件都在 `gdext/src/`，脚本和测试都在 `Project/project-keynes/` 下。阶段函数统一是 `gdext/src/native_simulation_stage_<域>.cpp`。

| 模块 | 所有者文件 | 别人怎样调用它 | 宿主与绑定层（组合根） | 存档段 | 脚本入口 | 测试 | skill |
|---|---|---|---|---|---|---|---|
| Climate | `gdext/src/runtime_climate_*` | 无接口头（目标未实现） | `gdext/src/native_simulation_host_climate.cpp`、`gdext/src/world_ext_climate.cpp` | CLM2 | `Project/project-keynes/scripts/simulation/systems/climate_daily_system.gd`（保留入口、调度游标与状态所有权；异步轮、finalizer、诊断与地形同步在 `scripts/simulation/climate/climate_daily_runtime.gd`）、`Project/project-keynes/scripts/weather`、`Project/project-keynes/scripts/geography/map_generator.gd`（保留入口、游标与状态所有权）以及 `scripts/simulation/climate/{pass_a,pass_b}.gd`、`scripts/simulation/climate/{native_daily_bundle_builder,native_daily_publish,runtime_climate_capture,season_refresh_coordinator}.gd`、`scripts/simulation/ocean/{water_pass,land_pass}.gd`、`scripts/simulation/sea_ice/daily_pass.gd`、`scripts/simulation/biology/transpiration_pass.gd`（native dispatch、daily bundle、结果发布、runtime capture、季节刷新编排与切片实现） | `gdext/tests/climate_parity_test.cpp`、`tools/ci/check_committed_replay.py`、`Project/project-keynes/tests/runtime` 与 `tests/world` 的 climate 用例 | project-keynes-climate-runtime |
| Country | `gdext/src/country_*`、`gdext/src/runtime_country_pod.*` | `gdext/src/country_api.h`；它调用宿主走 `gdext/src/country_host_port.h` | `gdext/src/native_simulation_host_country_*.cpp`、`gdext/src/world_ext_country*.cpp` | PKCN | `Project/project-keynes/scripts/country/country_facade.gd` | `Project/project-keynes/tests/country` | project-keynes-country-runtime、project-keynes-tax-runtime |
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

INPUT_CAPTURE、GAMEPLAY_EFFECT、VISUAL、COMMIT 四个域由宿主自己实现，没有独立业务模块；它们的写入者见 [current-state.md](current-state.md) 的“十二域”。每个域的 cadence、读写集合和存档段的机检登记在 `tools/ci/runtime_module_contracts.json` 与 `tools/ci/cpp_save_section_contracts.json`。

## 十二域以外

| 模块 | 所有者文件 | 别人怎样调用它 | 绑定层 | 存档段 | 脚本入口 | 测试 | skill |
|---|---|---|---|---|---|---|---|
| Military（主线程） | `gdext/src/military_*` | `gdext/src/military_bridge.h` | `gdext/src/world_ext_military.cpp`、`gdext/src/world_ext_economy_military.cpp`、`gdext/src/world_ext_military_cell_stats.cpp` | PKMI2 等，见 [module-boundaries.md](module-boundaries.md) 的“请求与提交” | `Project/project-keynes/scripts/military/military_facade.gd` | `gdext/tests/military_core_selftest_main.cpp`、`Project/project-keynes/tests/runtime` 下的 military 用例 | — |
| 科技 | 目录归 `Project/project-keynes/scripts/economy/technology_catalog.gd`，研究状态归 Country | 经 Country 命令 | — | 随 PKCN | `Project/project-keynes/scripts/technology`、`Project/project-keynes/scripts/research` | `Project/project-keynes/tests/technology` | project-keynes-technology-runtime、project-keynes-technology-tree-design |
| 会话、存读档、玩家输入 | `Project/project-keynes/scripts/game` | `Project/project-keynes/scripts/game/world_runtime_host.gd` 的公开入口；日推进、生成、GM、展示和 Climate authority 分别委派到 `world_runtime_daily_adapter*.gd`、`world_runtime_generation_adapter.gd`、`world_runtime_gm_adapter*.gd`、`world_runtime_presentation.gd`、`world_runtime_climate.gd` | — | PKSV 整档，由 `Project/project-keynes/scripts/game/game_save_coordinator.gd` 协调 | `Project/project-keynes/scripts/game/player_controller.gd`（玩家会话公开入口；军事、时代/理念、选择和叙事职责在 `scripts/game/player_controller/{military,progression,selection,narrative}.gd`） | `Project/project-keynes/tests/game` | project-keynes-game-flow-runtime、project-keynes-player-controller |
| 地图生成与烘焙 | `gdext/src/world_ext_generate*.cpp`、`gdext/src/world_ext_bake*.cpp` | 生成期请求，不进每日表 | 同左 | 地图输入随整档 | `Project/project-keynes/scripts/geography/map_generator.gd`（请求与检查：`geography/map_generation/native_generation_bridge.gd`；装配与基线：`geography/map_generation/terrain_gen.gd`；季节刷新编排：`scripts/simulation/climate/season_refresh_coordinator.gd`；自然资源初始分布与储量：`scripts/simulation/economy/map_resource_initializer.gd`；保存/停止/worker：`scripts/game/map_runtime_bridge.gd`；规则目录：`scripts/game/map_rules_initializer.gd`；国家与起始国家：`scripts/country/map_country_initializer.gd`）、`Project/project-keynes/scripts/rendering/map_baker.gd` 与 `rendering/bakers/{atlas_encoders,climate_baker,dynamic_atlas_baker,ocean_current_baker,physical_circulation_baker,terrain_baker,terrain_index_baker,weather_baker}.gd` | `Project/project-keynes/tests/world` | map-generation-pipeline |
| 显示与界面 | `Project/project-keynes/scripts/rendering`、`Project/project-keynes/scripts/ui` | 只读已发布结果 | — | 无 | `Project/project-keynes/scripts/ui/game_ui_manager.gd`（场景组装和公开转发；国家卷宗、时代和覆盖层职责在 `scripts/ui/game_ui/{country_routes,era_progression,overlays}.gd`）；理念工作区宿主为 `ui/components/ideology_workspace.gd`，显示构造和模型刷新在 `ui/components/ideology_workspace_presentation.gd`；地块检查器宿主为 `ui/cell_inspector_view_model.gd`，按分区委派到 `ui/cell_inspector/{object_dossiers,military,overview,population_market,construction,geography}.gd`；地图渲染宿主为 `rendering/hex_renderer.gd`，其职责协作者在 `rendering/renderer_*.gd`；植被宿主为 `rendering/shrub_layer.gd`，其职责协作者在 `rendering/shrub/*.gd` | `Project/project-keynes/tests/rendering`、`Project/project-keynes/tests/ui` | project-keynes-ui-art-direction、building-visual-pcg、vegetation-visual-pcg |

气候每日 Pass-A、Pass-B、ocean water/land、sea ice 和 transpiration 现在由各自 simulation 协作者承载 native dispatch 与切片实现；`map_generator.gd` 只保留公开入口、协作者组合，以及游标、缓存、统计和 slot/MapData 状态所有权。入口仍负责 `has_method`/签名探测、knob 打包、发布与失败处理；native 不可用或返回失败时用 `push_error` 保留上一份字段并返回失败。SHADOW、PROBE、A/B 和诊断入口继续保留，但不再计算一份 GDScript 热循环。

军事、自然资源恢复、视野等表外推进者的线程与交接见 [current-state.md](current-state.md) 的“十二域以外的推进”，登记在 `tools/ci/runtime_advancers.json`。

## 读不动的大文件

下列文件远超行数上限，不要整读；用符号搜索定位后只读相关函数。完整清单是 `tools/ci/size_baseline.json`。

- `gdext/src/country_runtime.cpp`（以及 `country_runtime_persistence.cpp`、`country_runtime_queries.cpp`、`country_runtime_economy_assets.cpp`、`country_runtime_research.cpp`、`country_runtime_peer.cpp`、`country_runtime_commands.cpp`、`country_runtime_internal.h`）、`gdext/src/effect_runtime.cpp` 及其 catalog/configuration/dispatch/instances/lifecycle/modifier/persistence/programs 协作者、`gdext/src/ideology_runtime.cpp` 及其 catalog/commands/daily/effects/effects_derived/offers/persistence/queries/state 协作者、`gdext/src/world_ext_climate.cpp`、`gdext/src/world_ext_climate_async.cpp`
- `Project/project-keynes/scripts/geography/map_generator.gd`、`Project/project-keynes/scripts/rendering/map_baker.gd`、`Project/project-keynes/scripts/rendering/bakers/`、`Project/project-keynes/scripts/weather/native_bridge.gd`、`Project/project-keynes/scripts/ui/cell_inspector/construction.gd`
