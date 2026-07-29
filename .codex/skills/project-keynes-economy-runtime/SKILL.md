---
name: project-keynes-economy-runtime
description: Guides Project.Keynes native economy runtime development and review, covering PopulationCohort, merchant-owned MarketStore, domestic trade topology/planning/orders, need/variant/component consumption, sparse building construction/employment/production, tax-aware settlement and behavior, frozen settlement cycles, EconomyDailySystem scheduling, fixed-point conservation, save schema, performance/approximation diagnosis, and content expansion. Use when modifying gdext/src/economy_runtime.*, world_ext_economy.cpp, economy profiles/catalog/facade, goods/needs/professions/ethnicities/buildings, taxation events or predictions, terrain trade movement, economy scheduling/UI/save/tests, or investigating economy correctness, latency, memory, and replay behavior.
---

# Project.Keynes Economy Runtime

Use this skill together with `cpp-dots-runtime-development` and
`project-keynes-runtime-architecture` when they are available. Treat the current source as the
final truth; use these references to avoid rediscovering invariants and to detect source/document
drift.

Also load `project-keynes-tax-runtime` for tax policy, fiscal escrow, tax bases, subsidies,
tax-aware purchase/employment/investment behavior, tariff placeholders, or PKCN/PKEC tax migration.

## Ground the task

Read the files relevant to the requested change before editing:

- Native population, market, and building state/algorithms: `gdext/src/economy_runtime.{h,cpp}`.
- Country technology/treasury bridge: `gdext/src/country_runtime.{h,cpp}` and `world_ext_country.cpp`.
- DataCore environment/resource bridge: `gdext/src/world_ext_economy.cpp`.
- GDExtension API binding: `gdext/src/world_ext.h`, `world_ext_bind_methods.cpp`.
- Catalog/facade: `Project/project-keynes/scripts/economy/`.
- Scheduler shell: `scripts/simulation/systems/economy_daily_system.gd`.
- Clock continuation: `scripts/geography/map_generator.gd`, `world_clock.gd`.
- Profiles/content: `scripts/data/*profile.gd`, `data/economy/`, `data/economy/buildings/`,
  `data/goods/`.
- Tests: `tests/goods_storage_schema_test.gd`, `tests/economy_runtime_bench.gd`,
  `tests/building_runtime_test.gd`, `tests/building_runtime_bench.gd`, and economy bootstrap/map
  generation tests when building-first population changes.

Read bundled references by task:

- Read [architecture-and-data.md](references/architecture-and-data.md) for authority, SoA,
  handles, catalog, commands, public API, save/restore, building owner-lots, or UI queries.
- Read [market-algorithms.md](references/market-algorithms.md) for demand, wealth, environment,
  substitutes, complements, merchants, clearing, price, domestic trade candidates/orders,
  building transactions/wages, rounding, or conservation.
- Read [scheduling-performance.md](references/scheduling-performance.md) for frozen cycles,
  building stages, default five-day cadence, deadline catchup, ACTIVE/PROBE, reports, latency,
  memory, or error.
- Read [extension-and-verification.md](references/extension-and-verification.md) before adding a
  good, profession, ethnicity, need, building, curve, command, native behavior, save field, or
  benchmark.

## Classify authority before coding

State which boundary changes:

1. Catalog/content only, including `BuildingProfile` resources.
2. Native household-market or building formula/hot loop.
3. Population/market/building state layout or handle ABI.
4. Epoch stage/cursor, building graph, and tick scheduling.
5. Committed publish, UI query, or save schema.
6. ACTIVE/PROBE/default/fallback policy.

Keep C++ as the sole mutable owner of cohort, market, building, construction, and employment state.
Keep GDScript limited to resource compilation, command packing, scheduler/clock shell, selected-cell
queries, UI, and file I/O. Never add a parallel GDScript economy or building simulation.

## Preserve hard invariants

- Keep one aggregate cohort per `(cell, signature)`; keep wealth outside identity.
- Keep a merchant on every populated cell; conserve population and proportional funds when repairing.
- Treat local merchant cohorts as joint inventory owners; transfer buyer money directly to merchants.
- Keep one cell equal to one local market until an explicit market-topology migration is designed.
- Keep domestic transport as movement between those local markets. Trade topology, sparse planning,
  route caches, in-flight orders, cargo escrow, cash escrow, and trade EMA remain native economy
  state; MapData only supplies frozen neighbors/terrain LUT input.
- Keep goods/cohorts/buildings out of `MapData`, `HexCell`, DataCore component slots, and Godot
  Objects. DataCore may expose only sampled geographic/resource inputs and resource deltas.
- Keep country identity, technology, cash, and goods treasury in `NativeCountryRuntime`; economy
  freezes the native country snapshot at sample day. Never restore per-cell technology or a global
  economy treasury. Tax policy and cash treasury remain country-owned; taxable events, frozen
  rates, fiscal escrow, and fiscal history remain economy-owned.
- Keep sparse building groups in stable `(cell, type, owner signature)` order. Store the sponsor's
  stable cohort signature as owner identity; do not add employer or building identity to cohort
  signatures.
- Keep hot loops free of Dictionary, Callable, Object access, string lookup, allocation, and exceptions.
- Keep money, goods, population, ratios, rates, and rounding deterministic and saturating.
- Keep population, money, and goods audit error exactly zero.
- Account for construction/input sinks, accepted output, supported output, discarded output,
  resource extraction, wages paid, and wages unpaid explicitly. Never mint owner, employee, or
  merchant funds except the versioned bullion and one-fifth-retail producer-support issuance paths;
  both exceptions must increment explicit money mint and publish their own diagnostics.
- Keep partially computed market/building/planning state invisible to gameplay writers and save.
  Authoritative dispatched trade orders and escrow are the explicit PKEC v11 exception. Selected-cell
  inspector queries may read the latest slice-complete native state, must report `snapshot_source`,
  and must stay bounded; never copy or publish a global cohort-by-good or order matrix.
- Keep generic production, employment, wages, and transport outside household Market V2. The native
  building graph, domestic trade graph, and dedicated tax/fiscal settlement are explicit staged
  exceptions. Keep cross-country trade execution, active tariffs, politics, and unrelated country
  systems outside this runtime until their own authority contracts are designed.

## Preserve the building graph contract

- Compile sorted building IDs, owner/employee roles, construction/input/output goods, natural
  resources, postfix construction conditions, behavior ID/version, and valid role-level wage policies before
  mutating runtime state.
- Run `building_employment` and `building_production` before `household_market`, then hold completed
  internal state in `wait_commit` until the frozen deadline; run `building_commit` immediately before
  publish. Empty building worlds must skip the first two stages without changing results.
- Buy construction and production inputs from local merchant cohorts. Sort producer offers by local
  retail price descending, apply the configured merchant buy factor, and cap normal purchases by
  merchant cash. Put remaining storable output into merchant inventory through the audited
  one-fifth-retail producer-support issuance path; only non-storable remainder is discarded.
- Buy inputs and produce/sell output before wage transfer. Then cap wage transfer by post-sale owner
  cash and pay only committed local employees. Report paid and unpaid wages separately without
  changing total money; arrears do not retroactively cancel current production.
- Use sorted cell CSR and visit active building cells/groups only. Never scan all building groups
  once per cell or materialize Godot objects in the native graph.
- Keep pending construction, committed building groups, role fills, per-cohort employment, building
  catalog hash, and resource deltas inside save/hash/restore contracts where applicable.

## Follow the implementation workflow

1. Inspect the current source path and relevant reference.
2. Define input/output columns, ownership, cadence, rounding, failure behavior, and report fields.
3. Preflight all failure-prone work before mutating a cycle.
4. Implement native data-oriented work with stable market/cohort/building order.
5. Preserve worker/scalar state-hash equality.
6. Update catalog/resources and GDScript wrappers only at coarse boundaries.
7. Update every affected runtime document in the same change.
8. Run focused correctness, approximation, scheduling, save, build, and performance validation.
9. Report authority, cadence, error, avg/p95/max, memory, fallback, and remaining non-goals.

## Treat cadence as a gameplay/performance contract

Use `market_cycle_days=5` as the production default. Use `0` only when explicitly selecting
cohort-budget auto cadence. Do not present the N=50/N=334 automatic performance figures as the
default five-day behavior.

When changing cadence or approximation:

- Preserve sample-day frozen price/environment/technology/resource semantics. Under
  `production_income_consumption_v10`, only in-epoch building sale and income distribution may change
  funds/stock before household clearing; mid-cycle gameplay writes must remain deferred.
- Freeze building ownership, role fills, construction readiness, geographic/resource context, and
  production inputs for the same cycle boundary; do not let mid-cycle gameplay writes leak into it.
- Multiply period demand by N and normalize demand/income EMA inputs back to daily values.
- Keep `wait_commit` until `sample_day + N - 1`.
- Allow normal day progression before the deadline.
- Raise `economy_day_barrier` only when `commit_due && !done`, then catch up on real-frame pulses.
- Publish `market_cycle_days`, deadline, command latency, approximation model, and error evidence.
- Compare against N=1 reference; never infer accuracy only from conservation.

## Diagnose performance in the right order

1. Inspect slice `elapsed_ms`, then stage CPU totals.
2. Compare processed cohorts/needs/variants/components and worker task count.
3. Compare active building cells/groups and construction/input/output/resource edges when a building
   stage is involved; empty worlds should show no building-stage work.
4. Check the selected cycle and cohort budget.
5. Look for cycle-boundary full scans. Do not restore global income/expense clearing, unconditional
   merchant CSR rebuild, or per-cell scans over all building groups.
6. Distinguish normal `wait_commit` from missed-deadline catchup.
7. Check saturation, audit errors, fatal reason, price-cap hits, discarded output, unpaid wages,
   resource deltas, and pending command latency.
8. Change cadence only with an accompanying reference-error table.

## Verify

Run the bundled static checker from the repository root:

```powershell
& .\.codex\skills\project-keynes-economy-runtime\scripts\verify_economy_runtime.ps1
```

Add `-Godot` for focused headless tests and `-Build` for debug/release GDExtension builds. Read
[extension-and-verification.md](references/extension-and-verification.md) for release benchmark
commands and required documentation updates.

## Report completion

Include:

- Native versus GDScript authority after the change.
- Changed population/market/building state, API, schema, cadence, and defaults.
- Correctness, conservation, deterministic scalar/worker hash, save, scheduling, and approximation
  evidence. For building changes, include construction, employment, merchant cash-cap/discard,
  wages, resource delta, and sparse-world evidence.
- Release avg/p95/max and memory when performance can change.
- Whether default five-day mode or explicit auto cadence was benchmarked.
- Remaining blockers and intentionally excluded systems.
