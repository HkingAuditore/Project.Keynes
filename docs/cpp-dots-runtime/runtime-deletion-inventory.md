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
| `run_native_daily_tick_from_job()` | Isolate | Keep as debug/full-run helper only. | Probe/debug still use full graph to validate readiness and stale DLL behavior. | Dedicated debug/probe bridge owns all call sites; no ACTIVE registration can reach it. |
| `run_native_sim_tick_from_job()` | Isolate | Keep as SHADOW/A-B/hash diff helper. | Needed for native-vs-legacy comparisons. | A/B runner has a separate explicit entry and production `NativeDailySimJob` no longer checks it first. |
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
```
