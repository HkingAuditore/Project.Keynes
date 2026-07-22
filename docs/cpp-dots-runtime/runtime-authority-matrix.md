# Runtime Authority Matrix

本文记录当前日级 runtime 的权威边界。它区分“C++ 加速”“slot 写入”“tick/state authority”“visible publish”和“Godot object boundary”，避免把可运行 native pass 误判成完整 DOTS authority。

| System | Stage / Cursor Owner | Slot Writer | Publish Path | Fallback Owner | ACTIVE Eligibility | Known Blockers |
| --- | --- | --- | --- | --- | --- | --- |
| `season_refresh` | `SeasonRefreshSystem` 持有 period counter、round stage、stage cursor；B+ round 可由 `DCWorldExt` probe。 | GDScript helper 与 B+ C++ pass 写 terrain/landform/vegetation/cover/moisture/weather dirty slots。 | `MapData` mutation、dirty mask、enum atlas/detail scatter intents。 | `SeasonRefreshSystem` 12-stage path；B+ 失败回退同 system。 | 默认 GDScript retained；`native_season_refresh_active_owner_enabled=true` 且 B+ state 可证明时，report 可升为 `native_active`。 | Atlas queue、detail scatter 和 Godot upload 是 retained boundaries；只有 owner 未 active 才阻塞 simulation complete。 |
| `refresh_climate_daily` | `ClimateDailySystem` 持有 `_round_active`、`_pass_cursor`、phase lock；native daily report 镜像 climate state。 | 多个 `DCWorldExt` climate/ocean/wind/sea-ice/transpiration pass 写 slot；GDScript system 仍持 round state。 | Pass 级 `_flush_slot_to_map()` / `published_to_slot`，尾部 debug/CSV/visual intents。 | `ClimateDailySystem` sliced path；旧 `RefreshClimateDailyJob` 已删除。 | Partial native-ready / guarded ACTIVE owner flags；默认仍保留 GDScript round shell。 | Reset/abort/debug boundary、visible publish 与 sync sliced fallback 尚未完全退休。 |
| `native_daily_sim` | `DCWorldExt::run_native_daily_slice()` 持有 graph continuation、node cursor、round accumulator；GDScript 只保留 SUS shell 与 bundle boundary。 | `SCHEDULE_GRAPH` 节点调用 C++ pass 写 slots。 | Graph report `published_slots`、`visual_dirty_intents`、`authority_report`、`authority_blockers`、`retained_boundaries`；必要时 flush 到 `MapData`。 | 普通 ACTIVE 不再回 full-run；`run_native_daily_tick()` 只作 debug/probe，`run_native_sim_tick()` 作 SHADOW/A-B。 | `run_native_daily_slice` 是唯一 ACTIVE hot path；`graph_coverage_state=complete` 只由 simulation authority blockers 决定；`native_daily_legacy_daily_production_retired=true` 才允许 fallback/test-only handoff。 | Climate/weather/ocean/season owner gates 与 legacy fallback 未退休时仍阻塞；Godot/visual boundaries 只进 `retained_boundaries`。 |
| `country_daily` | `NativeCountryRuntime` 持有国家 SoA、handle generation、领土 CSR、国家科技 bitset、现金/物资国库、命令游标与 state hash。 | 只把 `cell.country_slot` 发布到 DataCore/MapData；名称、科技、国库和 CSR 保持 native。 | 原子 `command_preflight → command_apply → aggregate_publish`；国家事件与粗粒度 snapshot；PKCN v1。 | PROBE/OFF 只作验证门；OFF 时依赖国家的经济禁用，不恢复旧状态。 | 默认 **ACTIVE**；priority 255、`must_run=false`、`use_job_should_run=true`，无到期命令零 slice。 | v1 不含灭国、科技撤销、税收、外交、战争或 AI；活跃国家至少一格，水域无主。 |
| `economy_daily` | `NativeEconomyRuntime` 持有滚动五相结算、stage/cursor、PopulationStore、MarketStore、稀疏 MarketSignalStore/LaborMarketStore、BUILDING_GRAPH、企业三态与聚合商人债务、国内 TradeTopology/Plan/Order/Flow stores、need/bundle 清算和 ECB；国家科技与国库由 `NativeCountryRuntime` 提供。 | 独立 native vectors；due-cell sample 冻结 `cell → country`、国家 generation/hash 与科技 bitset，并粗粒度捕获六邻贸易拓扑；仅资源净 delta 写回 extra-change slots，不增加经济 DataCore slot。 | 每个 due bucket 通过有界 continuation 隔离半成品；既有 building plan/employment/production/household/commit 阶段内完成融资、偿债、实物收入、恢复和清算；发布 summaries、snapshots、审计与仅接受新档的 PKEC v16 stream。选中 cell 的逐投资候选诊断为有界 transient cold data，不进存档/hash。 | 无大规模 GDScript fallback；国家桥无效时 disabled，不恢复逐格科技或全局国库。 | 本地市场、商人信用和国内贸易默认 **ACTIVE / 每 cell 固定 5 日**；PROBE 信用只报告候选与额度，不改变资金、债务、建筑或就业。 | Price V4 使用成本/默认价锚定的加法积分；税、跨国贸易/关税/外交仍不在本图。 |
| `weather_refresh` | `WeatherDCSystem` wrapper 内的 `WeatherRefreshJob` 持有 field stage/front state；`WeatherSystem` 持业务 facade。 | `DCWorldExt` weather field/distribute/summary/stage-b pass 与 GDScript fallback 写 weather slots。 | Weather commit flush、front apply、weather LUT upload intent/Godot upload。 | `WeatherRefreshJob` staged path；merged native 受 readiness gate。 | `weather_native_daily_readiness_report()` 证明 visible publish/front/LUT 后为 `native_ready`；`native_weather_transaction_active_owner_enabled=true` 后为 `native_active`，执行后可升 `native_active_verified`。 | WeatherFront Godot objects、front rebuild、ImageTexture/LUT upload、CSV visible fields 是 retained boundaries；publish readiness 未达成才是 blocker。 |
| `runtime_hydrology` | Legacy path 由 `WeatherRefreshJob` stage 3 持有；native daily path 由 `SCHEDULE_GRAPH` 的 `runtime_hydrology` node 持有单日执行点。 | `DCWorldExt::run_runtime_hydrology_pass` 写 `soil_moisture`、`water_balance_30d`、`river_discharge*`、`river_storage`、`groundwater_storage`、`surface_runoff` slots。 | Pass 内 `_flush_slot_to_map()`；native daily graph report 宣告 hydrology published slots。 | Legacy staged path 保留为 fallback/A-B。 | `runtime_hydrology_enabled=true` 时需要 native bundle 同时包含 `weather_knobs` 与 `runtime_hydrology_knobs`；stage-b 通过 `stage_b_after_hydrology_knobs` 在 hydrology 后运行；publish 成功后 phase 为 `native_active_verified`。 | 缺 `runtime_hydrology_knobs` 才是 blocker；legacy facade 仅作 A/B/test/fallback 入口。 |
| `ocean_currents` | `OceanCurrentsSystem` wrapper 内的 `OceanCurrentsJob` 持 physical/visual round state；native facade mirrors physical state. | `DCWorldExt` SLP/wind/PSI/upwelling/raster pass 写 slots 或 visual buffers。 | SLP/wind/current/upwelling slot flush；visual raster + texture commit 留在 Godot side。 | `OceanCurrentsJob` physical/visual staged path。 | `native_ocean_physical_active_owner_enabled=true` 且 snapshot owner 为 `native_active` 后，physical state 不再阻塞 simulation complete。 | Visual raster/texture commit、overlay upload、Godot buffers 是 retained boundaries；wrapper `_inner` 未 inline。 |
| `sea_ice_daily` | `SeaIceDailySystem` / climate round sea-ice stage；native daily report 另有 `authority_report.sea_ice`。 | `DCWorldExt::run_sea_ice_daily_pass` 写 sea-ice/terrain-related slots。 | Slot flush + dynamic visual LUT/atlas dirty intent；native daily graph report 宣告 `cell_sea_ice_frac` 等 published slots。 | Sea-ice helper fallback retained where ext unavailable. | Native daily graph 中 `sea_ice_knobs` 存在时可报告 native graph owner；native round 完成后 phase 可升为 `native_active_verified`。 | Terrain flip visibility、visual LUT/Godot upload 是 retained boundaries，不再阻塞 simulation authority。 |
| `enum_atlas_upload` | `EnumAtlasUploadSystem` owns dirty patch cadence. | C++ encoder may produce patch bytes; DataCore slots are read-only inputs. | GDScript `ImageTexture` / atlas upload. | GDScript fan-out/upload fallback. | Not simulation authority; visual boundary only. | GPU upload and texture lifetime remain Godot-side. |
| `dynamic_visual_atlas_upload` | `DynamicVisualAtlasUploadSystem` owns LUT/atlas stride and catch-up. | C++ LUT/patch encoders read slots and return byte buffers. | GDScript Image/ImageTexture update; weather LUT is published by weather commit path. | GDScript encoder fallback. | Not simulation authority; optional visual job. | GPU upload, dirty queue, renderer interpolation. |
| `native_environment_runtime` | `NativeEnvironmentRuntimeSystem` thin scheduler job; native runtime owns internal shadow/probe state. | `EnvironmentRuntime` / `DCWorldExt` where available. | Report-only unless a specific pass publishes slots. | Skip/hard fail when native runtime unavailable. | SHADOW/probe thin job unless a concrete owner gate promotes it. | Needs per-system publish contract before authority. |
| Native world generation / bake | Awaited `MapGenerator.generate()` orchestrates cooperatively on the Godot main thread; `DCWorldExt` owns base/post-base generation data. | Native generation result package and generation publish pass write initial SoA/slots. | GDScript assembles `MapData`/`HexCell`; publish pass flushes initial runtime slots; `MapGenerator`/`MapBaker` yield frames only at stage boundaries. | Old full GDScript generation fallback is retired; failures abort generation or use scoped post-base fallback only where documented. | Native generation is C++ authoritative for base/post-base generation; cooperative yielding does not transfer authority. | Godot object assembly, `HexCell` facade, texture bake/upload remain GDScript/Godot; one native pass is still non-preemptible. |

## Economy Authority

经济域当前仍为 C++ `NativeEconomyRuntime` ACTIVE authority：136-good MarketStore、182 类稀疏
owner-lot、两组四档升级族、Price V3 稀疏企业信号、自适应工资/奖金、真实金银锚定发行和电力 utility prepass 都在
ECONOMY_GRAPH/BUILDING_GRAPH 内完成。GDScript 只编译 profile/technology tags、桥接 30 个注册自然
资源 slots、提交命令和查询选中 cell；不存在 GDScript 货币、价格、生产或贸易 fallback。
国家身份、领土、科技和国库由 `NativeCountryRuntime` 单一权威持有；经济周期冻结国家映射与科技，
现金/商品审计包含国家资产及贸易托管。持久格式为 PKCN v1 + PKEC v12，必须先恢复 PKCN；
兼容 v11 ACTIVE 可迁移，ACTIVE 配置拒绝 v11 PROBE/v10，v2-v9 明确返回
`legacy_countryless_economy_save_unsupported`。

## Scheduling Policy Boundary

`ClimateProfile.sim_stagger_*` controls when each job is eligible to start a new slice/round. It is interpreted centrally in `DCSystemScheduler.configure_job_from_profile()` / `apply_job_schedule()` and does not transfer authority between GDScript, C++, DataCore, or Godot object boundaries.

Default full-platform buckets are: ocean/native environment phase 0, climate/native daily phase 1 with climate stride 2, dynamic visual phase 2, weather + enum atlas phase 4, and sea ice phase 6 under `sim_stagger_bucket_stride=8`. A job skipped by `policy_gated` is simply outside its bucket. Authority is still determined by the owner/state/publish columns above.

## Native Daily Owner Gate Order

Legacy daily production paths are retired only in this order:

1. `climate_round`：native owns round cursor/phase/pass progress; GDScript keeps reset/abort/debug and MapData/Godot boundary intents.
2. `sea_ice`：native graph owns sea-ice fraction computation; GDScript keeps terrain flip visibility and sea-ice visual upload until soak proves them.
3. `weather_transaction` / `runtime_hydrology`：native graph owns weather transaction and hydrology route before stage-b; GDScript keeps WeatherFront objects, front apply, weather LUT upload, and fallback A/B.
4. `ocean_physical`：native may own physical stage cursor and output slots; pixel raster, texture commit, overlays, and Godot buffers remain retained.
5. `season_refresh`：native may report cadence and slot dirty intents last; period policy, atlas queue, detail scatter, and Godot uploads remain retained boundaries.

## Current Ownership Diagram

```mermaid
flowchart TD
  worldClock["WorldClock day_changed"] --> mapGenerator["MapGenerator orchestration"]
  mapGenerator --> dcScheduler["DCSystemScheduler"]
  dcScheduler --> susExt["SusSchedulerExt budget and stats"]
  susExt --> gdSystems["DCSystem wrappers and retained state machines"]
  gdSystems --> dcWorldExt["DCWorldExt slots and native passes"]
  dcWorldExt --> reports["NativeDailyReport / pass reports"]
  reports --> godotBoundary["MapData / debug / renderer / Godot uploads"]
```

## Rules

- A system is DOTS-authoritative only when native owns state, writes slots, advances tick/cursor, and publishes a graph-level report.
- A pass returning `published_to_slot=true` proves slot publication for that pass, not visible renderer upload.
- Godot object lifetimes, `ImageTexture`, front objects, UI/debug, and CSV sampling remain explicit GDScript/Godot boundaries until a dedicated native object API exists.
## Economy v14 authority clarification

`NativeEconomyRuntime` remains the only mutable owner of cohorts, funds, market
inventory/prices, buildings, construction, employment, production, investment,
trade orders, escrow, and resource extraction deltas. `EconomyProfile` and
`EconomyCatalog` only compile configuration and fixed columns. CSV, Inspector,
and GDScript facades are read-only consumers. Desired/funded demand arrays,
owner allocation worklists, investment candidates, and trade response clocks are
native transient diagnostics and are not parallel gameplay state.

## Economy v15 authority override (current)

`NativeEconomyRuntime` is stage, tick, state, and publish authority for rolling
local settlement. GDScript only captures coarse environment/resource inputs,
submits commands, schedules the native call, and reads committed snapshots.
Production cadence is fixed at five days per cell, staggered by stable phase;
workload-auto cadence and the global epoch commit barrier are no longer ACTIVE
paths. Daily trade arrival and escrow settlement remain native cross-cell
transactions outside worker-local market writes.

Production worker ranges do not create a second authority. They execute inside
`NativeEconomyRuntime` and own only disjoint cell partitions under the current
`market_id == cell_id` contract. Global diagnostics, retained output, event
stream, and cashflow ledger publication remain a stable native main-thread
merge. If that ownership proof, the workload threshold, or WorkerThreadPool is
unavailable, the same native body runs scalar; GDScript never becomes the
fallback simulation owner. Plan, sparse market-signal observation, indexed
investment evaluation, and investment commit continuation are likewise native
transient work. None adds a DataCore slot, public bridge method, scheduler stage,
PKEC field, cadence rule, or state-hash input.
