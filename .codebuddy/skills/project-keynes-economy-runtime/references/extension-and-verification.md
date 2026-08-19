# Extension and Verification SOP

## Contents

1. Content extension
2. Native behavior and schema changes
3. Required tests
4. Build and benchmark
5. Documentation sync

## 1. Content extension

### Add a good

Add a `GoodProfile` resource under `data/goods/`. Configure stable ID, display data, default/min/max
price, demand EMA alpha, target inventory days, inventory/shortage weights, daily price rise/fall,
`trade_enabled`, and positive `transport_load_per_unit_q16`. Force cycle-flow goods non-tradable.
Reference it from need variant components. Do not edit MapData, component schema, or bind table.

### Add a profession

Add `ProfessionProfile`, stable ID, display data, and default consumption plan. Preserve a resolvable
`merchant` profession for every ethnicity used by bootstrap.

### Add an ethnicity

Add `EthnicityProfile` and sparse need modifiers. Catalog compilation creates profession × ethnicity
signatures. Provide explicit aliases for renamed stable IDs.

### Add a need, substitute, or complement

Add/edit `NeedProfile` and `ConsumptionPlanProfile`. Keep at most 16 needs per plan, four variants per
need, and four components per variant. Variants are substitutes; components inside a variant form a
complement bundle.

### Add an environment effect

Add a 17-sample `EnvironmentDemandCurveProfile` for temperature, moisture, snow, or weather. Attach
it to need quantity or variant preference. Do not read Godot environment objects in the hot loop.

## 2. Native behavior and schema changes

For a new numeric behavior, version the approximation/catalog contract, keep integer deterministic
math, and add scalar golden cases plus worker equivalence. New formula behavior requires a rebuilt
GDExtension; third-party runtime DLL formulas are unsupported.

For a new lane/matrix/save field:

1. Define ownership and scale.
2. Update allocation, release, reset, memory accounting, state hash, save encoding, restore decoding,
   validation, and report/query exposure.
3. Bump PKEC schema when the byte layout changes.
4. Write truncation, missing ID, scale, and round-trip tests.

For a new command, update submit preflight, epoch preflight, apply/ECB ordering, conservation deltas,
save pending-command encoding, and stale-handle tests.

## 3. Required tests

Run `tests/goods_storage_schema_test.gd` and `tests/economy_cadence_runtime_test.gd`.
Preserve coverage for:

- opening one-cell N=1, P near 5, I > P, and locked N∈[1,5] / P∈[5,15] / I∈[10,30]
- injected timing, mid-cycle lock hold, no missed cells, v39 save/restore
- merchant repair and population/fund conservation
- buyer-to-merchant transfers and no anonymous market cash
- stock consumption, EMA, price, environment substitution
- stream save/restore hash
- N-day committed isolation and deadline catchup
- N-day versus N=1 error evidence
- worker/scalar exact state hash
- domestic topology/country boundaries, ETA alignment, profit/stock/cash/capacity clipping,
  multi-good order CSR, seller rebinding, exact escrow conservation, and mid-transit save/restore

Also run schema migration, world serialization, and DCSystem regression tests after bridge/scheduler
changes.

## 4. Build and benchmark

From `gdext/` on Windows:

```powershell
& "$env:APPDATA\Python\Python314\Scripts\scons.exe" platform=windows target=template_debug dev_build=no -j8
& "$env:APPDATA\Python\Python314\Scripts\scons.exe" platform=windows target=template_release dev_build=no -j8
```

Close Godot before linking loaded DLLs. Run focused tests with Godot 4.6.2 headless.

The benchmark script must run against template_release. Current production
locks N in 1–5; do not treat historical `--desktop` auto N=50/334 figures as
the default path:

```text
res://tests/economy_runtime_bench.gd
res://tests/economy_runtime_bench.gd -- --desktop
```

Restore `dots_ext.gdextension` to the debug DLL afterward. Record cadence, sample count, avg/p95/max,
worker tasks, memory, state hash, and stage breakdown. Do not compare release figures with a debug DLL.

## 5. Documentation sync

Update as applicable:

- `native-economy-runtime.md`: authority, data, benchmark, status.
- `domestic-trade-runtime.md`: topology, planner, orders, escrow, query, report, and non-goals.
- `economy-fixed-point-ledger-formulas.md`: numeric/clearing/price behavior.
- `economy-graph-scheduling.md`: stages, cadence, barriers, approximation.
- `economy-save-migration-sop.md`: byte schema and migration.
- `runtime-authority-matrix.md`: ACTIVE/PROBE/default and blockers.
- `scheduling-and-job-graph.md`, `computation-pipelines.md`, bridge and diagnostics docs.
- `scripts/economy/MODULE.md`, `references/system-map.md`, performance charter.

Run `git diff --check` and use `rg` to ensure retired per-cell goods fields or stale default-cadence
claims remain only in explicit migration/history text.
## Add a building

Add a sorted-ID `BuildingProfile` under `data/economy/buildings/`. Validate owner profession, role
columns, construction/input/output goods, referenced natural resources, postfix construction
condition stack, native behavior version, and a positive fixed/adaptive reference wage for employee-bearing roles. Building/save changes require
PKEC v3 round-trip, employment conservation, merchant cash-cap/discard, resource delta, scalar hash,
deadline, and large sparse-world performance tests.
