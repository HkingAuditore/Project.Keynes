# Runtime Deletion Inventory

本文是 runtime 架构清理的删除台账。后续删除、隔离或保留 fallback 时先更新这里，再改代码。

## Deletion Classes

| Class | Meaning | Rule |
| --- | --- | --- |
| Immediate delete | Production/test 不可达，且无 fallback/debug 价值。 | 直接删除并用 `rg` 验证无调用点。 |
| Delete after migration | 仍有调用点，但已有等价新路径。 | 先迁调用点，再删旧文件/旧函数。 |
| Isolate | 仍用于 A/B、probe 或 stale DLL 保护，但不应在主路径散落。 | 移到明确 legacy/probe/compat 入口。 |
| Keep for now | 仍是 production authority 或 Godot visible boundary。 | 只能文档化，不删除。 |

## Current Batch

| Country/Economy/Bio performance diagnostics | Keep for now | Implemented 2026-08 | LIGHT/FULL、pending queue、section snapshot、Bio staging 和 continuation telemetry 均为 transient compatibility/rollback surface；不得删除 FULL、PROBE 或 one-shot fallback。 | 对应 native report、facade bridge 与 `PerfRecorder` 字段 | ACTIVE/LIGHT、PROBE/FULL、UI smoke、hash parity 和 headless soak 均通过后再评估进一步删除。 |

| File / Symbol | Class | Status | Evidence | Replacement / Owner | Validation |
| --- | --- | --- | --- | --- | --- |
| `Project/project-keynes/scripts/simulation/sus/jobs/refresh_climate_daily_job.gd` | Immediate delete | Deleted | No production preload remained after `_setup_sus()` was made DCSystem-only. | `simulation/systems/climate_daily_system.gd` | `rg "RefreshClimateDailyJob|refresh_climate_daily_job.gd"` should only show historical docs or none in current runtime docs. |
| `Project/project-keynes/scripts/simulation/sus/jobs/season_refresh_job.gd` | Immediate delete | Deleted | `MapGenerator` now registers `SeasonRefreshSystem` directly; no production preload. | `simulation/systems/season_refresh_system.gd` | `rg "SeasonRefreshJob|season_refresh_job.gd"` should only show historical docs or none in current runtime docs. |
| `Project/project-keynes/scripts/simulation/sus/jobs/enum_atlas_upload_job.gd` | Immediate delete | Deleted | Production registration uses `EnumAtlasUploadSystem`; no remaining preload or test call site for the legacy SusJob shell. | `simulation/systems/enum_atlas_upload_system.gd` | `rg "EnumAtlasUploadJob|enum_atlas_upload_job.gd" Project/project-keynes/scripts docs/cpp-dots-runtime references/system-map.md` should only show historical references. |
| `Project/project-keynes/scripts/simulation/sus/jobs/sea_ice_atlas_upload_job.gd` | Immediate delete | Deleted | `sea_ice_tex` upload is retired; `MapGenerator` only emits a disabled compatibility report. | shader/dyn atlas sea-ice visual path | `rg "SeaIceAtlasUploadJob|sea_ice_atlas_upload_job.gd" Project/project-keynes/scripts docs/cpp-dots-runtime references/system-map.md` should only show historical references. |
| `Project/project-keynes/scripts/simulation/systems/sea_ice_atlas_upload_system.gd` | Immediate delete | Deleted | No production registration; the system preload was removed from `MapGenerator`. | disabled sea-ice atlas report + `DynamicVisualAtlasUploadSystem` retained visual boundary | `rg "SeaIceAtlasUploadSystem|sea_ice_atlas_upload_system.gd" Project/project-keynes/scripts docs/cpp-dots-runtime references/system-map.md` should only show historical references. |
| `_use_dc_system_scheduler` flag / branch tree in `map_generator.gd` | Immediate delete | Deleted from production entry | Code already set it to true unconditionally; else branches were unreachable. | `DCSystemScheduler.register_system()` single path | `rg "_use_dc_system_scheduler"` should not find production code. |
| `NativeDailySimJob` full-run ACTIVE shortcut | Immediate delete | Deleted from hot path | Plan requires `run_native_daily_slice()` as only ACTIVE hot path. | `run_native_daily_slice_from_job()` | `native_daily_sim` report path should be `gdext_native_daily_slice` in ACTIVE. |
| `cell.goods_*_(qty|price)` schema / `MapData.goods_*` / `CELL_GOODS_*` | Immediate delete after MarketStore migration | Deleted | `MarketStore` is configured/bootstraped before `economy_daily` registration；focused native test replaces old slot schema test. | `NativeEconomyRuntime::MarketStore` + committed market snapshot | `rg "cell\.goods_|goods_fur_qty_arr|CELL_GOODS"` only finds retirement tests/docs；generated bind table has no goods rows. |
| Economy-owned `_treasury_cash`, per-cell technology bitset, and economy technology grant command | Immediate delete after country authority migration | Deleted | Country identity, treasury and technology must have exactly one native owner. | `NativeCountryRuntime`, frozen native country bridge, PKCN v2 + PKEC v20 | `rg "_treasury_cash|_cell_technology_bits|COMMAND_GRANT_TECHNOLOGY" gdext/src/economy_runtime.*` returns no result; PKEC v2-v9 returns the precise legacy-countryless error. |
| Ad-hoc climate/country/building/gameplay buff or factor paths | Delete after migration | Inventory active; no additional path deleted in this change | Modifier runtime now owns lifecycle, stack, explain and save, but existing domain-specific multipliers may still encode non-buff baseline policy. | `ModifierRuntime` + domain frozen consumers | Before deleting any factor, prove it is a temporary modifier rather than base/profile policy, migrate producer/source identity, run no-modifier parity and update this row to list exact removed symbols. |

## Isolated Or Pending

| File / Symbol | Class | Current Decision | Why Not Delete Yet | Retirement Condition |
| --- | --- | --- | --- | --- |
| `[EMPDBG]` / `owner_debug_line` in `economy_runtime_building_employment.cpp` | Immediate delete | **Deleted 2026-09-18** | Temporary employment mobility diagnostics polluted production logs. | `rg "EMPDBG\|owner_debug_line" gdext/src` returns no matches. |
| `[RECONDBG]` print in `economy_runtime_building_employment.cpp` | Immediate delete | **Deleted 2026-09-18** | Reconstruction diagnostic printed on cell0 early days. | `rg "RECONDBG" gdext/src` returns no matches. |
| Docs hardcoding production mask `0xB7E` / `0xA7E` | Immediate delete after migration | **Updated 2026-09-18** to `0xFFF` in current-status docs (`scheduling-and-job-graph.md`, `runtime-authority-matrix.md`, `authority-migration.md`, and related runtime docs). Prose contradictions (Economy outside ACTIVE while claiming `0xFFF`) corrected. | Stale mask text contradicted `implemented_domain_mask() == 0xFFF`. | `rg "0xB7E\|0xA7E" docs/cpp-dots-runtime` only finds historical notes inside `修复方案.md` if any. |
| PKEC runtime fallback / default decode path | Delete after migration | Inventory active; keep explicit compatibility decoder until ECP2-only soak closes. Listed for #21 cleanup after soak. | Save/restore still needs a precise legacy rejection or migration path for older bundles. | ECP2-only coordinator + 60/730/3650 soak green; `rg "PKEC\|pkec" gdext/src` shows only intentional compatibility rejection. |
| `run_native_daily_tick_from_job()` | Isolate | Keep as debug/full-run helper only. | Probe/debug still use full graph to validate readiness and stale DLL behavior. | Dedicated debug/probe bridge owns all call sites; no ACTIVE registration can reach it. |
| `run_native_sim_tick_from_job()` | Isolate | Keep as SHADOW/A-B/hash diff helper. | Needed for native-vs-legacy comparisons. | A/B runner has a separate explicit entry and production `NativeDailySimJob` no longer checks it first. |
| `EconomyDailySystem.tick()` / `_continue_economy_inflight()` legacy SUS path | Isolate | ACTIVE no longer reaches the Economy GDScript wrapper; `should_run()` is policy-gated and continuation uses `advance_runtime_pulse()` after native same-day barriers. | OFF/SHADOW, save boundary and compatibility DLLs still need the wrapper and its event/receipt bridge. | Remove only after independent A/B hash, save/restore, event/receipt and 1000-day soak prove the graph boundary complete. |
| `WeatherDCSystem._inner` / `get_inner()` | Delete after migration | Keep wrapper. | Weather stage/front state is complex and still GDScript-retained. | Inline `WeatherRefreshJob` state into `WeatherDCSystem`, prove front count, commit cadence, weather LUT publish, CSV visible fields. |
| `OceanCurrentsSystem._inner` / `get_inner()` | Delete after migration | Keep wrapper. | Physical/visual state split and texture commit are still in `OceanCurrentsJob`. | Inline job state into system, prove SLP/wind/current p95, physical/visual separation, texture commit behavior. |
| Weather visible publish repair/fallback paths | Keep for now | Keep boundary fallback. | Native weather authority is blocked until visible publish/front/LUT readiness is proven. | `weather_native_daily_available()` returns true from real readiness, and 30+ tick soak shows nonzero visible fields and stable fronts. |
| Legacy daily production registrations (`refresh_climate_daily` / `sea_ice_daily` / `weather_refresh`) | Isolate after migration | Guarded by `native_daily_legacy_daily_production_retired=false` until soak. | `native_daily_sim` owns the ACTIVE slice hot path and splits `authority_blockers` from `retained_boundaries`; legacy production fallback remains a simulation blocker until explicitly retired. | Set `native_daily_legacy_daily_production_retired=true` only after SHADOW/A-B/ACTIVE soak passes with `graph_coverage_state=complete`, empty `authority_blockers`, hydrology on/off parity, visible weather/front/LUT verification, sea-ice terrain flip verification, ocean/season owner gates active, and updated deletion evidence. |
| `run_hydrology_discharge_pass_native()` legacy weather-stage facade | Isolate | Keep as legacy/A-B/test-only entry. | The native daily graph calls `DCWorldExt::run_runtime_hydrology_pass` directly through `runtime_hydrology_knobs`; native report upgrades hydrology to `native_active_verified` after slot publish. Legacy facade is still useful for parity comparison and stale DLL fallback. | Retire only after native daily hydrology soak covers `soil_moisture`, `water_balance_30d`, `river_discharge*`, stage-b input/output, and weather visible publish with runtime hydrology enabled. |
| Visual atlas / LUT GDScript upload | Keep for now | Keep Godot boundary. | `ImageTexture` upload and GPU resource lifetime are Godot-side. | Only delete if a real native Godot object API replaces it, not just because C++ encodes bytes. |
| Legacy global static GPU textures under tiled mode | Keep for now | Required by Compatibility, probe and whole-world fallback. | Tiled renderer is new and Android/8 MP soak is not complete; global CPU height/CSR remains authoritative regardless. | Consider releasing only duplicate GPU atlases after cross-platform shader, fallback, memory and screenshot gates pass; never delete CPU baseline or per-cell LUT. |

## Static Checks

Use these checks after cleanup batches:

```powershell
rg -n "_use_dc_system_scheduler|RefreshClimateDailyJobScript|SeasonRefreshJobScript|register_job\\(" Project/project-keynes/scripts/geography/map_generator.gd
rg -n "run_native_sim_tick_from_job|run_native_daily_tick_from_job" Project/project-keynes/scripts/simulation/sus/jobs/native_daily_sim_job.gd Project/project-keynes/scripts/geography/map_generator.gd
rg -n "refresh_climate_daily_job\\.gd|season_refresh_job\\.gd|RefreshClimateDailyJob|SeasonRefreshJob" Project/project-keynes/scripts docs/cpp-dots-runtime references/system-map.md
rg -n "enum_atlas_upload_job\\.gd|sea_ice_atlas_upload_job\\.gd|sea_ice_atlas_upload_system\\.gd|EnumAtlasUploadJob|SeaIceAtlasUpload(Job|System)" Project/project-keynes/scripts docs/cpp-dots-runtime references/system-map.md
rg -n "EMPDBG|owner_debug_line|RECONDBG" gdext/src
rg -n "0xB7E|0xA7E" docs/cpp-dots-runtime
```

## tmp/ experimental artifacts (classify first; do not delete yet)

Working-tree `tmp/` experiment logs and sandboxes remain classified-only until formal evidence is migrated. Do not mass-delete:

- `tmp/building-after-plan-stage*.log` (EMPDBG historical evidence)
- `tmp/wage-debug.log`
- `tmp/codex_colonization_test_*` sandboxes

Record → migrate formal diagnostics → then clean.

## 2026-10-17 家族首都补建入口移除

`NativeEconomyRuntime::repair_forced_capital_founder` 及 FAMILY_COMMIT 日常调用已删除。
原0..30天兼容逻辑只以当地是否仍有家族判断是否补建，会在首都原族迁出或消亡后绕过玩家扶持
再造 Starter。正式 bootstrap 的 v3 创始声明与 v2 forced_named_cells + gathering_ground
兼容仍保留；后续普通家族走正常里程碑／玩家选择。分家另走同一待决队列。参见
[家族运行时](notable-family-runtime.md) 的 v56 说明。此删除依据玩家明确要求修正静默立族。

## 2026-10-17 母族后续迁入身份

按玩家明确规则删除 `reunite_split_family_branches` 及其日常调用和声明：独立后的 A1
不吸收后来从 A 迁入的成员，乙地允许 A 与 A1 同时存在。`_family_split_parents` 继续
作为亲缘元数据保存，避免改变 v56 存档布局；不参与迁移归属。回归覆盖旧实现失败、
新实现同格共存与存读档通过，证据在 artifacts/runtime/family-arrival-identity-20261017。

## 2026-10-28 理念 v1 逐格效果平面（plan 22 §15.7）

| File / Symbol | Class | Status | Evidence | Replacement / Owner | Validation |
| --- | --- | --- | --- | --- | --- |
| `NativeIdeologyRuntime::build_cell_program_table` (+ `CellProgramTable` / `CellProgramEntry` 的读者) | Immediate delete | **Deleted**（169 行）| 生产不可达：唯一生产者 `publish_ideology_cell_programs` 的 GDScript 调用者只有一个测试；且其开关注释自述 "Off by default because the v1 table is not yet safe to apply (stale generation, double application with the per-cell instances…)"。实测 `get_ideology_cell_program_summary().cell_plane_builds == 0`。 | `DerivedCellFront` + `step_derived_rebuild` + `get_effective_stat_value` | 全回归 21/22（`mechanism_matrix` 为基线既有 1129/3）；内核 93/0 |
| `NativeEconomyRuntime::set_ideology_cell_programs` + `_ideology_cell_programs` + `_epoch_city_output_ideology_generation` | Immediate delete | **Deleted**（13 行 + 成员）| 唯一写入点是上面那个不可达的桥。 | 派生层经 `effective_value` 直接参与同一 CSR | `city_good_output_factor_q16` 读者不变，回归见上 |
| `refresh_city_output_modifier_factors` 内的平面合并段 | Immediate delete | **Deleted**（74 行）| 段首条件 `!_ideology_cell_programs.entries.empty()` 恒假。 | 派生层在 `effective_value` 里合并，不需要第二个 CSR 来源 | 同上 |
| `publish_ideology_cell_programs` / `set_ideology_cell_program_entry_for_test` / `get_ideology_cell_program_summary` / `set_ideology_cell_plane_enabled`（4 个 ClassDB 桥）| Immediate delete | **Deleted**（62 行 + 绑定）| 无生产调用者；`_probe_card_cell_plane.gd` 是唯一专用消费者，一并删除。 | 上表三个新桥（`get_derived_cell_layer_report` / `get_effective_stat_value` / `get_derived_multi_country_report`）| `rg "publish_ideology_cell_programs\|get_ideology_cell_program_summary"` 只剩历史文档 |
| `ideology_effect_metric_publish_test.gd` 的 `_test_cell_program_table` / `_test_column_units` | Delete after migration | **Deleted**（114 行 / 21 条断言）| 它们注入平面 entry 并读平面 summary。**覆盖已迁移**：ADD vs MULTIPLY 与负幅度加法折叠在内核 `derived_layer_rebuild_test.cpp` 的 A / N 组；逐格值在 B7。 | 内核单测 + `ideology_b7_wide_territory_test.gd` | 268/0 且无 SCRIPT ERROR（删桥未删函数时是 289/0 + `Nonexistent function` 报错，断言其实早已不执行）|

**删除的顺序与理由。** 先补可观测性（`get_effective_stat_value`），再把唯一覆盖迁到内核，
最后才删平面。反过来做会丢断言而无法察觉：GDScript 函数抛错后测试只会**停止递增 check 计数**，
仍然报 0 failures。

**保留但已无包含者。** `ideology_cell_program.h` 仍存在，未删除；无任何 `.h`/`.cpp` include 它。
