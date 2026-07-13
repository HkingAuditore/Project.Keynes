# Economy Runtime Architecture and Data

## Contents

1. Authority and layering
2. Population storage
3. Signature and catalog storage
4. Market storage and ownership
5. Commands and public API
6. Save and visibility
7. Source map

## 1. Authority and layering

`DCWorldExt` composition-owns `NativeEconomyRuntime`. The runtime owns every mutable cohort,
market, accounting, stage/cursor, command, audit, and save state. It does not use `DCWorldExt::_slots`
for economic storage.

```text
WorldClock / EconomyDailySystem
  -> DCWorldExt coarse API
  -> NativeEconomyRuntime / ECONOMY_GRAPH
  -> PopulationStore + MarketStore + catalog CSR
  -> committed summaries / reports / save stream
  -> EconomyFacade / Inspector / persistence I/O
```

DataCore contributes only the sample-day environment columns: temperature, moisture, snow cover,
and weather intensity. `world_ext_economy.cpp` reads raw F32 slot pointers once and quantizes them
to Q16. No per-cell cross-language calls occur.

## 2. Population storage

`PopulationStore` is a 64-lane page/chunk SoA. Each cell owns a page chain; allocation and reclaim
touch only affected cells.

Per lane:

- `active:u8`, `signature_id:u32`, `generation:u32`.
- `population:i64`, `funds:i64`.
- `epoch_income:i64`, `epoch_expense:i64`, `income_ema:i64`.
- `needs_satisfaction:u16`, `worst_need_id:u16`, `flags:u16`.
- `demography_residual:i64` reserved by the structural ABI; Market V2 does not run demography.

Use `(generation << 32) | slot_index` as the external handle. Increment generation on release and
validate every handle at submit/preflight/apply. Never persist a UI pointer to a cohort Object.

Keep one active cohort for each `(cell, signature)`. Merge duplicate bootstrap rows and structural
destinations. Wealth is `funds/population`; do not add it to signature identity.

`flags` reserves a parity bit for lazy cycle accounting. On first ledger/market touch in a new cycle,
zero income/expense and update parity. Do not replace this with an O(total cohorts) cycle-start scan.

## 3. Signature and catalog storage

A signature currently resolves profession, ethnicity, and consumption plan. Cohort lanes store only
the dense signature index. Extend signature schema/version before adding religion, legal status,
employer, or other identity dimensions.

Catalog resources compile stable string IDs into sorted dense tables and CSR columns:

```text
profession × ethnicity -> signature
plan_need_offsets       -> Need[]
need_variant_offsets    -> VariantChoice[]
variant_component_offsets -> NeedComponent[]
```

Do not use directory order as persistent identity. The catalog hash covers canonical IDs and
parameters. Add explicit migration aliases for missing or renamed IDs.

## 4. Market storage and ownership

Market V2 fixes `market_count == cell_count` and `cell_to_market[cell] == cell`.

Market-major matrices:

```text
stock[market, good]             i64
price[market, good]             i32
demand_ema[market, good]        i64
last_shortage_q16[market, good] u16
```

Building-derived price inputs use a separate sparse, sorted `MarketSignalStore` keyed by
`(cell, good)` and containing `business_demand_ema`, `offered_supply_ema`, and `cost_anchor_price`.
Its key set is the union of current building input/output edges. Rebuild it only when building role
storage changes, preserving values for stable keys; do not add these columns to the dense market
matrix or DataCore.

All merchant cohorts in the cell jointly own stock. The market has no cash account. Allocate sales
revenue among merchants by merchant population with stable prefix quotients. Merchants consume like
other cohorts.

For a populated cell without a merchant, convert one person from the largest nonmerchant cohort,
inherit ethnicity, and transfer proportional funds. Rebuild merchant CSR only after real structural
changes; normal cycles must reuse it.

## 5. Commands and public API

Parallel PackedArray command columns contain opcode, effective day, sequence, target handle, two
i32 parameters, and two i64 quantities. Supported opcodes:

1. country treasury to cohort transfer (country handle supplied or resolved from cohort cell)
2. explicit mint to cohort
3. explicit burn from cohort
4. add local stock
5. remove stock/loss
6. adjust population
7. migrate population
8. change signature
9. cohort to country treasury transfer
10. country goods treasury to a specified cell market
11. specified cell market goods to country treasury

Commands submitted during a frozen cycle wait for the next sample day. Report maximum command
latency as the cycle length.

Coarse public API:

- configure/bootstrap/submit commands/should run/run slice/report/reset
- lightweight population cell summary for the Inspector header
- population and market cell snapshots
- begin/read/end save
- begin/feed/end restore
- fixed-math probe and deterministic state hash

Do not add per-cohort setters.

The Inspector opens with `get_population_cell_summary(cell)`, which returns only aggregate population,
funds, income/expense, cohort count, and satisfaction. Full population, market, building, and natural
resource detail is queried lazily for the visible tab. `get_population_cell_snapshot(cell)` also emits
a cold-path cohort-major CSR demand preview:

```text
demand_good_offsets       cohort_count + 1
demand_good_indices       indices into demand_good_stable_ids
demand_per_capita_daily   GOODS_SCALE units/person/day
```

The preview reuses the native wealth/environment/substitute/complement demand kernel with
`dt_days=1`. `DCWorldExt` supplies the selected cell's current environment slots; the runtime uses
committed population/funds/prices and never stores a global cohort-by-good matrix. Preview-local
saturation is reported but does not mutate runtime metrics or the deterministic state hash.

## 6. Save and visibility

PKEC schema v11 streams 4–16MB chunks: header, pages, market rows, cell/environment rows, pending
commands, buildings, construction, audit history, sparse market/labor signals, trade orders,
trade-flow EMA, end. Save only at a
committed boundary. The header stores numeric scales, catalog identity, cycle length, committed day,
environment identity, matching PKCN schema/generation/hash, submit sequence, trade next ID/resolved
configuration, and section counts. Restore PKCN v1 first. PKEC v10 migrates to empty trade state and
rebuilds topology; PKEC v2-v9 return `legacy_countryless_economy_save_unsupported`; do not
synthesize a global treasury or per-cell technology during restore.

During `household_market`, `structural_commit`, or `wait_commit`, save and gameplay systems must not
observe internal mutation. The selected-cell Inspector is the bounded exception: synchronous native
queries between slices return complete current population, market, and building arrays with
`snapshot_source=live_slice` and `committed=false`. At a boundary they return
`snapshot_source=committed`. Queries are read-only, never expose a global live matrix, and never show
a normal "details pending" UI state.

The optional world-setup test bootstrap is OFF by default. When explicitly enabled it gives every
passable settlement a distribution center, places collectors only where local resource reserves can
support their recipes, and distributes each industrial type across a bounded deterministic subset
of cells while preferring local upstream outputs. It derives profession cohorts only from the
resulting local owner/employee job capacity, then fills thirty days of stock. This is a development
fixture, not a production historical population provider.

## 7. Source map

- Native types/graph/math/save: `gdext/src/economy_runtime.{h,cpp}`
- Environment capture/API forwarding: `gdext/src/world_ext_economy.cpp`
- GDExtension binding: `world_ext.h`, `world_ext_bind_methods.cpp`
- Catalog/facade: `scripts/economy/economy_catalog.gd`, `economy_facade.gd`
- Profiles: `scripts/data/{economy,good,need,profession,ethnicity,consumption_plan,environment_demand_curve}_profile.gd`
- Content: `data/economy/`, `data/goods/`
- UI: `scripts/ui/cell_inspector_view_model.gd`
- Focused tests: `tests/goods_storage_schema_test.gd`, `economy_runtime_bench.gd`
- Trade tests: `tests/economy_trade_runtime_test.gd`

### Inspector settlement cashflow

In `SELECTIVE` mode the player Inspector owns a separate single-cell trace target through
`set_economy_inspector_trace_cell(cell)`. It is unioned with, and never overwrites, the debug trace
filter. The next committed batch stores sparse per-cohort cashflow sources for that cell. Population
snapshots expose the committed period metadata plus CSR source indices and income/expense amounts.
This cache is bounded by event retention, excluded from PKEC save and the economy state hash, and
reports `settlement_detail_pending` until the first traced commit.
## Building authority (PKEC v3)

`NativeEconomyRuntime` also owns sparse building owner-lots, pending construction, committed role
fills, and per-cohort owner/employee employment counts. Keep `(cell, signature)` cohort identity;
ownership stores the sponsor's stable signature identity rather than adding employer to signatures.
Buildings stay outside MapData/HexCell/component slots. The bridge only samples geographic/resource
slots and publishes resource extraction through `extra_change`.

PKEC v8 extends owner-lot/role state with adaptive contract wages, living-cost and local-wage
anchors, base/bonus settlement and wage suspension. These fields, v7 building economics, and sparse
market/labor signals are authoritative deterministic state in save round-trip and hashing.
