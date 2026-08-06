# Economy Runtime Split Matrix

Status: E9f completed. Storage, fiscal, building, household-market, domestic-trade,
persistence, bounded domain-query, catalog, profile, configuration, committed
event/report, epoch-lifecycle, publish/commit, result-container, read-only
diagnostics and settlement lifecycle implementations are extracted.
The root retains stage dispatch/cursors, worker dispatch, result aggregation,
stage transition and cross-module invariants. No authority, public API or
save-schema change.

This document is the migration contract for splitting the native economy
runtime. It describes file boundaries, not new simulation behavior.

## Current Monolith

| File | Approx. size | Current responsibility |
| --- | ---: | --- |
| `gdext/src/economy_runtime.cpp` | ~11,102 lines | Native state, stage dispatch/cursors, worker dispatch, stage transitions and cross-module invariants |
| `gdext/src/economy_runtime_epoch.cpp` | ~912 lines | Epoch preflight, frozen country/workset setup, transient initialization, opening audit lanes and completed performance snapshot |
| `gdext/src/economy_runtime_publish.cpp` | ~525 lines | Publish phase cursor state, closing audits, watermark/trade diagnostics and ordered COMMIT handoff |
| `gdext/src/economy_runtime_results.cpp` | ~159 lines | Market/production result reset and capacity accounting plus worker TLS result sinks |
| `gdext/src/economy_runtime_diagnostics.cpp` | ~1,775 lines | Read-only stage progress, memory accounting, slice breakdown and compact/full runtime report formatting |
| `gdext/src/economy_runtime_settlements.cpp` | ~320 lines | Committed population totals, prosperity hysteresis, stable settlement naming, settlement updates and bounded settlement row construction |
| `gdext/src/economy_runtime_catalog.cpp` | ~1,571 lines | Stable-ID catalog decoding and validation for family traits, goods, needs, signatures, families, people, settlements and buildings |
| `gdext/src/economy_runtime_profile.cpp` | ~410 lines | Built-in formula registration plus runtime and satisfaction profile decoding |
| `gdext/src/economy_runtime_configuration.cpp` | ~936 lines | Public configure/bootstrap/command submission facade over the sole native runtime owner |
| `gdext/src/economy_runtime_events.cpp` | ~712 lines | Committed trace/cashflow/gameplay facts, event schema/query/ack/report and PKEJ archive streaming |
| `gdext/src/economy_runtime_persistence.cpp` | ~912 lines | Save/restore lifecycle, committed-boundary validation and public stream coordination |
| `gdext/src/economy_runtime_persistence_write.cpp` | ~802 lines | Ordered PKEC v30 section encoding and bounded chunk writer |
| `gdext/src/economy_runtime_persistence_read.cpp` | ~1,595 lines | PKEC v30 section decoding, record validation and restore staging |
| `gdext/src/economy_runtime_persistence_codec.h` | ~60 lines | Single PKEC magic/section-number contract and save-chunk envelope helper |
| `gdext/src/economy_runtime_binary_codec.h` | ~60 lines | Shared stateless little-endian/string/ID-table binary helpers used by PKEC and event archive code |
| `gdext/src/economy_runtime_queries_population.cpp` | ~466 lines | Settlement delta/snapshot and bounded population cell summary/snapshot formatting |
| `gdext/src/economy_runtime_queries_market_building.cpp` | ~1,912 lines | Bounded market, satisfaction, fiscal, building, family, notable-person and trade-order facade methods; no scheduler cursor ownership |
| `gdext/src/economy_runtime_variant_helpers.h` | ~87 lines | Shared stateless Godot `Dictionary`/packed-array UTF-8 and numeric decoding helpers used by configuration, catalog, queries and retained root event code |
| `gdext/src/economy_runtime.h` | 3,619 lines | Public facade, all private stores/records, stage state, configuration and persistence types |
| `scripts/economy/economy_facade.gd` | 1,067 lines | Commands, selected-cell queries, inspector formatting, save/event facade |
| `scripts/economy/economy_catalog.gd` | 1,184 lines | Resource loading, stable IDs, catalog compilation and validation |
| `scripts/simulation/systems/economy_daily_system.gd` | 286 lines | Scheduler shell, cadence/deadline and report forwarding |

## Non-Negotiable Authority

- `NativeEconomyRuntime` remains the sole mutable owner of cohorts, markets,
  buildings, construction, employment, trade orders, escrow and fiscal event
  state.
- `NativeCountryRuntime` remains the owner of country identity, technology,
  cash and goods treasury. Economy consumes a frozen country snapshot per
  epoch and sends explicit fiscal/trade transfers through the existing bridge.
- GDScript remains resource compilation, command packing, scheduler/clock
  shell, bounded selected-cell queries, UI formatting and file I/O.
- `MapData` and DataCore provide frozen geography/resource inputs only. They do
  not gain population, market, building or global treasury state.
- The public `NativeEconomyRuntime` API and save schema stay stable during the
  first extraction waves.

## State and Stage Ownership

| Boundary | State owner | Reads | Writes | Cadence |
| --- | --- | --- | --- | --- |
| Storage and handles | `PopulationStore`, `FamilyStore`, `NotablePersonStore`, `MarketStore` | commands, catalog | cohort/merchant/family/person slots, inventory, cash | command boundary and epoch stages |
| Environment/country snapshot | `NativeEconomyRuntime` epoch snapshot | DataCore arrays, `NativeCountryRuntime` | frozen environment, technology, tax and modifier inputs | epoch start |
| Fiscal settlement | `NativeEconomyRuntime` fiscal lanes | country snapshot, taxable event drafts | escrow, assessed/collected/paid/unmet totals | building/household stages, epoch commit |
| Building graph | native building state in `NativeEconomyRuntime` | catalog, resources, market offers, owner cohorts | construction, role fills, production, wages, resource deltas | building employment/production/commit stages |
| Household market | native market/cohort state | frozen prices/environment, needs and variants | purchases, consumption, wealth, satisfaction | household market stage |
| Domestic trade | native trade topology/plans/orders | frozen terrain CSR, market signals, merchant stock/cash | routes, orders, cargo escrow, cash escrow, EMA | trade planning/execution slices |
| Publish and inspector | `NativeEconomyRuntime` publish cursors | completed epoch state | bounded summaries, events, diagnostics | aggregate publish stage |
| Save/restore | `SaveState` / `RestoreState` inside runtime | complete committed native state | chunk buffers and restored state | explicit save boundary |

## Proposed Translation Units

These are implementation targets, not parallel authorities:

1. `economy_runtime_storage.{h,cpp}`
   Population, family, notable-person, market storage, handles, merchant
   invariant and incremental audit shadow.
2. `economy_runtime_math.{h,cpp}`
   Saturating fixed-point helpers, formula registration and pure formula
   kernels. No runtime state or Godot objects.
3. `economy_runtime_catalog.cpp`
   Stable-ID tables, catalog validation and compiled family/building/good/
   profession metadata.
4. `economy_runtime_profile.cpp`
   Built-in formula registration and runtime/satisfaction profile decoding.
5. `economy_runtime_configuration.cpp`
   Public configure/bootstrap/command submission facade; no stage ownership.
6. `economy_runtime_fiscal.{h,cpp}`
   Frozen tax inputs, fiscal budgets, taxable events, escrow, subsidies and
   country transfer calls.
7. `economy_runtime_buildings.{h,cpp}`
   Sparse building groups, construction, employment, production, resources,
   wages and investment review.
8. `economy_runtime_market.{h,cpp}`
   Demand basis, needs/variants/components, price formation, clearing,
   consumption, satisfaction and social pressure.
9. `economy_runtime_trade.{h,cpp}`
   Topology capture, route cache, candidates, plans, orders, cargo/cash escrow
   and flow EMA.
10. `economy_runtime_persistence*.{h,cpp}`
   Save/restore lifecycle, ordered writer, validated reader, shared PKEC section
   contract and binary helpers. Event archive remains with the event/report facade.
11. `economy_runtime_queries_*.cpp`
   Bounded read/query formatting and query-adjacent command validation. These
   methods use the same `NativeEconomyRuntime` owner and never own scheduler
   stage transitions.
12. `economy_runtime_events.cpp`
   Committed trace/event lifecycle, bounded event query/report and PKEJ archive
   streaming. It never advances stages or cursors.
13. `economy_runtime_epoch.cpp`
   Epoch preflight, frozen country snapshot/workset setup, due-command
   prevalidation, transient epoch vectors, opening audit lanes and completed
   performance snapshot capture. It does not dispatch ongoing slices.
14. `economy_runtime.cpp`
   Ongoing epoch stage transitions, cursors, worker scheduling, publish
   coordination, event/report handling and cross-module invariants.

Stage transitions, bindings and public declarations remain in the root facade.
Public method implementations may move to cohesive translation units after the
leaf contracts are stable; names, signatures and binding surface remain unchanged.

## Current Extraction Status

- `economy_runtime_storage.cpp` owns the extracted population, family,
  notable-person and market storage method implementations. Layouts, handles,
  allocation order and `NativeEconomyRuntime` ownership are unchanged.
- `economy_runtime_math.cpp` owns saturating arithmetic, fixed-point power and
  the two built-in pure formula kernels. The root file retains registration and
  calls only; it has no duplicate math implementation.
- `economy_runtime_fiscal.cpp` owns frozen tax-rate lookup, fiscal attribution,
  budget reservation, tax/subsidy application, escrow accounting, prediction,
  and country transfer commit. `capture_country_epoch()` remains the explicit
  root-owned frozen country snapshot boundary; country treasury authority is
  unchanged.
- `economy_runtime_building_storage.cpp` owns building-group lookup, role-span
  allocation/release, sparse group ordering, cell offsets and review buckets.
  It retains the existing `NativeEconomyRuntime` storage owner and calls back
  only through root-owned state and narrow sibling methods.
- `economy_runtime_building_employment.cpp` owns employment metric replacement,
  population-change reconciliation, cell wage preparation, labor signal updates
  and `run_building_employment_cell()`. The root retains only employment stage
  cursor/dispatch and aggregate result accounting.
- `economy_runtime_building_resources.cpp` owns resource access-cell queries,
  generation-stamped resource lanes, consumption, renewable classification and
  safe-harvest limits. Production still invokes these methods through the same
  `NativeEconomyRuntime` owner.
- `economy_runtime_building_production.cpp` owns production climate-capacity
  evaluation, per-group climate preparation, the production worker leaf and
  `ProductionResult` aggregation/trace sink merge. The root still owns the
  production stage entry and worker scheduling.
- `economy_runtime_building_investment.cpp` owns investment scratch lanes,
  review-cell preparation, sparse signal evaluation and
  `run_endogenous_building_investment()`. The root retains the ordered commit
  stage entry and cursor.
- `economy_runtime_building_construction.cpp` owns build/demolish command
  mutation and pending-construction prechecks.
- `economy_runtime_building_commit.cpp` owns `commit_ready_construction()`;
  it performs the ordered construction commit but never advances the scheduler
  cursor.
- `economy_runtime_market.cpp` owns demand-basis construction, household demand
  helpers, the market clearing worker `process_market_cell()` and
  `finalize_market_result()`. The root retains household-market phase cursors,
  worker dispatch, `MarketResult` aggregation, structural-command handoff and
  publish ordering.
- `economy_runtime_trade.cpp` owns trade-topology capture, trade price/relief
  helpers, route-cache lookup, resumable route planning, signal clocks and
  diagnostics, flow EMA, seller credit, arrival buckets, order settlement,
  candidate dispatch, transit and escrow queries. The root retains only trade
  stage entry/cursor orchestration and cross-stage aggregation.
- `economy_runtime_persistence.cpp` owns `begin_save()`, `end_save()`,
  `begin_restore()`, `feed_restore_chunk()` and `end_restore()` lifecycle and
  committed-boundary validation.
- `economy_runtime_persistence_write.cpp` owns `read_save_chunk()` and preserves
  the exact PKEC v30 section order and bounded chunk budgets.
- `economy_runtime_persistence_read.cpp` owns `decode_restore_chunk()` and all
  record-level restore validation. `economy_runtime_persistence_codec.h` is the
  single PKEC magic/section-number source; `economy_runtime_binary_codec.h` is
  the single little-endian/string/ID-table helper implementation shared with
  root event archive encoding.
- `economy_runtime_queries_population.cpp` owns settlement snapshot/delta and
  bounded population cell summary/snapshot formatting.
- `economy_runtime_queries_market_building.cpp` owns bounded market,
  satisfaction, fiscal, building, family, notable-person and per-cell trade-order
  facade methods. It does not advance epoch/stage cursors or own mutable state.
- `economy_runtime_variant_helpers.h` is the single shared implementation of
  stateless UTF-8, `Dictionary` numeric and packed-array decoding used by the
  extracted catalog/configuration/profile/query code and retained root event code.
- `economy_runtime_catalog.cpp` owns family-trait, base economy, family,
  person, settlement and building catalog compilation. Catalog hashes, stable
  ordering and validation rules are unchanged.
- `economy_runtime_profile.cpp` owns built-in formula registration and runtime/
  satisfaction profile decoding. Numeric defaults and the production five-day
  cadence remain unchanged.
- `economy_runtime_configuration.cpp` owns `configure()`, `bootstrap()` and
  `submit_commands()`. It mutates the same sole `NativeEconomyRuntime` owner;
  public signatures, command preflight, bootstrap ordering and country/modifier
  bridges are unchanged.
- `economy_runtime_events.cpp` owns trace/cashflow staging, committed event
  batches, gameplay-fact publication, event schema/filter/query/ack/report and
  PKEJ archive streaming. The root continues to decide when the aggregate
  publish stage invokes these methods; event ordering and archive bytes are
  unchanged.
- `economy_runtime_epoch.cpp` owns `clear_epoch_metrics()`,
  `capture_completed_perf_snapshot()` and `start_epoch()`. It performs
  failure-prone preflight before mutation, freezes the country/workset and
  initializes epoch scratch/audit lanes. The root retains `run_slice` stage
  selection, outer cursor advancement, worker dispatch and stage transitions.
- `economy_runtime_publish.cpp` owns `reset_publish_state()` and
  `publish_epoch_slice()`. It owns publish-phase-local cursors, closing
  conservation audits, settlement watermark/trade diagnostics, resource-delta
  readiness and the ordered COMMIT handoff. The root still decides when the
  aggregate-publish stage runs, when a slice yields, and how the next stage is
  selected.
- `economy_runtime_results.cpp` owns `MarketResult` /
  `ProductionResult` reset and capacity accounting plus the three thread-local
  worker result sinks. It does not own result merging, stage cursors, worker
  dispatch or any mutable economy store; those remain in the root scheduler
  path.
- `economy_runtime_diagnostics.cpp` owns `stage_progress_q16()`,
  `memory_bytes()`, household slice breakdown dictionaries,
  `compact_report()` and `report()`. It is a read-only formatter: report
  keys and values are unchanged, while Stage mutation, worker dispatch,
  conservation and failure handling remain root-owned.
- `economy_runtime_settlements.cpp` owns committed-cell population totals,
  prosperity tier calculation, stable settlement name assignment/release,
  settlement initialization/update and settlement row/field formatting. The
  `SettlementStore` remains owned by `NativeEconomyRuntime`; aggregate publish
  and COMMIT ordering, forced-name behavior, hysteresis and query fields remain
  unchanged.

## Dependency Direction

```text
catalog + math
      -> storage
      -> fiscal snapshot
      -> buildings -> market -> trade
      -> publish / persistence / inspector
```

- `storage` may not call scheduler, UI, save I/O or `MapData`.
- `math` may not read runtime state or allocate Godot containers in hot loops.
- `buildings` may call market offer helpers and fiscal event adapters, but may
  not advance the epoch cursor.
- `market` may consume building outputs committed for the current frozen cycle,
  but may not mutate building graph structure.
- `trade` consumes frozen topology and market signals; it owns orders/escrow,
  not country treasury. Building-side merchant procurement capability helpers
  remain with the building/production boundary.
- `persistence` serializes committed state through explicit accessors; it does
  not reach into unrelated module internals.
- Only the root facade advances `Stage` and outer epoch deadlines. Publish
  phase cursors are owned by `economy_runtime_publish.cpp`; the root remains
  responsible for entering/leaving `AGGREGATE_PUBLISH` and selecting the next
  stage.
- The events facade records or exposes committed-boundary information only; it
  does not schedule work, mutate market/building topology or write save state.

## Extraction Order and Gates

### E2: storage

Move method implementations without changing layouts, handles, ordering or
audit values. Gate with `goods_storage_schema_test`, population conservation,
merchant invariant and state-hash equality.

### E3: math/catalog/snapshot

Completed for fixed-point math and built-in pure formulas. The pure kernels live
in `gdext/src/economy_runtime_math.cpp`; E9a later moved formula registration
and profile/catalog decoding to their dedicated units. Explicit country snapshot
capture remains with root orchestration.

### E4: fiscal

Completed. Fiscal lane implementations now live in
`gdext/src/economy_runtime_fiscal.cpp` after the existing explicit
  `capture_country_epoch()` snapshot boundary. The root retains scheduler stage
  transitions and PKEC persistence; `fiscal_snapshot()` now lives in the bounded
  query facade. The Windows native build and economy runtime
verification pass with no duplicate fiscal method definitions.

### E5: buildings

Completed across dedicated storage, employment, resources, production,
investment, construction and commit translation units. The root retains stage
entry/cursors, worker scheduling and cross-stage result aggregation.

### E6: market

Completed in `gdext/src/economy_runtime_market.cpp`; household phase cursors,
worker dispatch and result aggregation remain in the root; ordered publish is
implemented by the publish translation unit.

### E7: trade

Completed in `gdext/src/economy_runtime_trade.cpp`; the root retains trade stage
entry/cursor orchestration and cross-stage aggregation.

### E8: persistence/facade

E8a moved save/restore lifecycle wrappers. E8b moved bounded population and
market/building/family inspector facade methods. E8c moved the ordered PKEC v30
writer and validated reader into separate under-threshold translation units,
with one shared section-number contract and binary helper implementation. Bindings,
state ownership, section order, schema acceptance and restore validation are unchanged.

### E9a: catalog/profile/configuration facade

Completed. Catalog compilation lives in `economy_runtime_catalog.cpp`, formula
registration and profile decoding live in `economy_runtime_profile.cpp`, and
`configure()`/`bootstrap()`/`submit_commands()` live in
`economy_runtime_configuration.cpp`. All three implementation units are below
the 2,000-line review threshold. Debug/release builds, bundled economy
verification, strict module boundaries, goods schema, rolling save/restore and
trade save/restore tests pass. The modern catalog compiles, while its existing
content-policy assertions remain an unrelated data-content failure.

### E9b1: committed event/report/archive facade

Completed. `economy_runtime_events.cpp` now owns social-pressure fact staging,
trace lifecycle and cashflows, committed event queries, acknowledgements and
reports, plus PKEJ archive chunks. `trace_hash_mix()` stays in the root because
the same deterministic mixer also serves family/person stable-ID generation.
Debug/release builds, strict module boundaries, bundled verification, event
archive/schema coverage in `goods_storage_schema_test`, rolling save/restore and
trade save/restore pass. Stage order, event order, public bindings, PKEC and
five-day cadence are unchanged.

### E9b2: epoch lifecycle

Completed. `economy_runtime_epoch.cpp` owns epoch metric reset,
completed-performance snapshot capture and epoch preflight/start. The root keeps
stage dispatch, outer cursors, worker scheduling and cross-stage transitions.

### E9c: publish/commit coordination

Completed. `economy_runtime_publish.cpp` owns publish-phase reset and the
resumable publish implementation: closing audits, watermark/trade diagnostics,
resource-delta readiness and ordered COMMIT. The root remains the sole owner of
aggregate-publish stage entry, slice/yield boundaries and next-stage selection.
Debug/release builds, strict module boundaries, bundled economy verification,
goods schema, rolling save/restore and trade save/restore all pass.

### E9d: result containers and worker sinks

Completed. `economy_runtime_results.cpp` owns the result-container lifecycle
and TLS sink definitions used by worker slices. Aggregation order, worker
dispatch, stage boundaries, hashes and conservation semantics remain unchanged.

### E9e: runtime diagnostics and reports

Completed. `economy_runtime_diagnostics.cpp` owns stage-progress calculation,
memory/capacity accounting and compact/full Dictionary report construction. It
does not mutate the runtime or advance a continuation. Public report fields,
timing breakdown keys and scheduler-visible semantics are unchanged.

### E9f: settlement identity lifecycle

Completed. `economy_runtime_settlements.cpp` owns committed population lookup,
prosperity tier transitions, stable name assignment/release, initialization,
changed-cell updates and settlement row construction. `NativeEconomyRuntime`
remains the sole `SettlementStore` owner; the root retains stage/publish
coordination and aggregate `COMMIT` ordering.

## Required Validation Per Wave

1. Static symbol/call-site search and `git diff --check`.
2. Debug/release GDExtension build when C++ changes.
3. Focused economy correctness tests and the relevant benchmark.
4. Scalar/worker deterministic state-hash comparison.
5. Population, money and goods audit error exactly zero.
6. Default `market_cycle_days=5` evidence; do not substitute auto cadence.
7. Save/restore and event schema evidence when persistence-facing code moves.
8. Update `docs/cpp-dots-runtime/computation-pipelines.md`, economy docs and
   `references/system-map.md` whenever authority, stage, report or schema
   contracts change.

## Explicit Non-Goals

- No second GDScript economy simulation.
- No move of economy state into `MapData`, HexCell or DataCore slots.
- No change to market topology, tax semantics, cadence defaults or save schema
  as part of a file split.
- No deletion of fallback/probe paths until A/B or soak evidence closes them.
