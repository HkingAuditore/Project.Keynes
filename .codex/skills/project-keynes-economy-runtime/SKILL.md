---
name: project-keynes-economy-runtime
description: Guides Project.Keynes native economy runtime development and review, covering PopulationCohort, merchant-owned MarketStore, need/variant/component consumption, frozen settlement cycles, EconomyDailySystem scheduling, fixed-point conservation, save schema, performance/approximation diagnosis, and content expansion. Use when modifying gdext/src/economy_runtime.*, world_ext_economy.cpp, economy profiles/catalog/facade, goods/needs/professions/ethnicities, economy scheduling/UI/save/tests, or investigating economy correctness, latency, memory, and replay behavior.
---

# Project.Keynes Economy Runtime

Use this skill together with `cpp-dots-runtime-development` and
`project-keynes-runtime-architecture` when they are available. Treat the current source as the
final truth; use these references to avoid rediscovering invariants and to detect source/document
drift.

## Ground the task

Read the files relevant to the requested change before editing:

- Native state and algorithms: `gdext/src/economy_runtime.{h,cpp}`.
- DataCore environment bridge: `gdext/src/world_ext_economy.cpp`.
- GDExtension API binding: `gdext/src/world_ext.h`, `world_ext_bind_methods.cpp`.
- Catalog/facade: `Project/project-keynes/scripts/economy/`.
- Scheduler shell: `scripts/simulation/systems/economy_daily_system.gd`.
- Clock continuation: `scripts/geography/map_generator.gd`, `world_clock.gd`.
- Profiles/content: `scripts/data/*profile.gd`, `data/economy/`, `data/goods/`.
- Tests: `tests/goods_storage_schema_test.gd`, `tests/economy_runtime_bench.gd`.

Read bundled references by task:

- Read [architecture-and-data.md](references/architecture-and-data.md) for authority, SoA,
  handles, catalog, commands, public API, save/restore, or UI queries.
- Read [market-algorithms.md](references/market-algorithms.md) for demand, wealth, environment,
  substitutes, complements, merchants, clearing, price, rounding, or conservation.
- Read [scheduling-performance.md](references/scheduling-performance.md) for frozen cycles,
  default five-day cadence, deadline catchup, ACTIVE/PROBE, reports, latency, memory, or error.
- Read [extension-and-verification.md](references/extension-and-verification.md) before adding a
  good, profession, ethnicity, need, curve, command, native behavior, save field, or benchmark.

## Classify authority before coding

State which boundary changes:

1. Catalog/content only.
2. Native formula or market hot loop.
3. Population/market state layout or handle ABI.
4. Epoch stage/cursor and tick scheduling.
5. Committed publish, UI query, or save schema.
6. ACTIVE/PROBE/default/fallback policy.

Keep C++ as the sole mutable owner of cohort and market state. Keep GDScript limited to resource
compilation, command packing, scheduler/clock shell, selected-cell queries, UI, and file I/O.
Never add a parallel GDScript economy implementation.

## Preserve hard invariants

- Keep one aggregate cohort per `(cell, signature)`; keep wealth outside identity.
- Keep a merchant on every populated cell; conserve population and proportional funds when repairing.
- Treat local merchant cohorts as joint inventory owners; transfer buyer money directly to merchants.
- Keep one cell equal to one local market until an explicit market-topology migration is designed.
- Keep goods/cohorts out of `MapData`, `HexCell`, DataCore component slots, and Godot Objects.
- Keep hot loops free of Dictionary, Callable, Object access, string lookup, allocation, and exceptions.
- Keep money, goods, population, ratios, rates, and rounding deterministic and saturating.
- Keep population, money, and goods audit error exactly zero.
- Keep in-flight state invisible to gameplay writers and save. Selected-cell inspector queries may
  read the latest slice-complete native state, must report `snapshot_source`, and must stay bounded;
  never copy or publish a global cohort-by-good live snapshot.
- Keep production, employment, wages, tax, trade, politics, and natural demography outside Market V2.

## Follow the implementation workflow

1. Inspect the current source path and relevant reference.
2. Define input/output columns, ownership, cadence, rounding, failure behavior, and report fields.
3. Preflight all failure-prone work before mutating a cycle.
4. Implement native data-oriented work with stable market/cohort order.
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

- Preserve sample-day frozen population/funds/price/stock/environment semantics.
- Multiply period demand by N and normalize demand/income EMA inputs back to daily values.
- Keep `wait_commit` until `sample_day + N - 1`.
- Allow normal day progression before the deadline.
- Raise `economy_day_barrier` only when `commit_due && !done`, then catch up on real-frame pulses.
- Publish `market_cycle_days`, deadline, command latency, approximation model, and error evidence.
- Compare against N=1 reference; never infer accuracy only from conservation.

## Diagnose performance in the right order

1. Inspect slice `elapsed_ms`, then stage CPU totals.
2. Compare processed cohorts/needs/variants/components and worker task count.
3. Check the selected cycle and cohort budget.
4. Look for cycle-boundary full scans. Do not restore global income/expense clearing or unconditional
   merchant CSR rebuild.
5. Distinguish normal `wait_commit` from missed-deadline catchup.
6. Check saturation, audit errors, fatal reason, price-cap hits, and pending command latency.
7. Change cadence only with an accompanying reference-error table.

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
- Changed state/API/schema/cadence/defaults.
- Correctness, deterministic hash, save, scheduling, and approximation evidence.
- Release avg/p95/max and memory when performance can change.
- Whether default five-day mode or explicit auto cadence was benchmarked.
- Remaining blockers and intentionally excluded systems.
