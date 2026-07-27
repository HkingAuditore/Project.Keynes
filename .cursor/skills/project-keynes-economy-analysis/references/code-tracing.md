# Code-Tracing Guide

## Contents

1. Current source map
2. Field-to-formula workflow
3. Search routes by domain
4. Catalog and ID mapping
5. Cadence and visibility
6. Evidence standard

## 1. Current source map

Start from current files rather than historical report line numbers:

- CSV schema, row capture, derived recorder fields, encoding:
  `gdext/src/economy_csv_recorder.{h,cpp}`.
- Native population, market, trade, buildings, demography, audit, report:
  `gdext/src/economy_runtime.{h,cpp}`.
- DataCore environment/resource bridge and recorder bindings:
  `gdext/src/world_ext_economy.cpp`, `gdext/src/world_ext*.cpp`, `gdext/src/world_ext.h`.
- Economy orchestration and cadence:
  `Project/project-keynes/scripts/simulation/systems/economy_daily_system.gd`, economy profile, and
  WorldClock/MapGenerator continuation.
- Recorder control and filename label:
  `Project/project-keynes/scripts/ui/economy_data_recorder.gd`.
- Catalog compilation and facade:
  `Project/project-keynes/scripts/economy/`.
- Content inputs:
  `Project/project-keynes/data/economy/`, `Project/project-keynes/data/goods/`, and related resource
  profiles.
- Architecture contract:
  `.codex/skills/project-keynes-economy-runtime/references/` and
  `docs/cpp-dots-runtime/native-economy-runtime.md`.

## 2. Field-to-formula workflow

For each decisive CSV field:

1. Find the exact header token.
2. Find its row member in `economy_csv_recorder.h`.
3. Find the capture assignment in `EconomyCsvRecorder::fill_batch` or a derived recorder helper.
4. Identify whether it copies authority state, a committed report counter, a selected-cell derived
   value, or a pending bridge value.
5. Trace the source member into the runtime mutation/reset sites.
6. Trace formula parameters into economy profile or content resources.
7. Confirm stage, frozen sample day, commit day, and recorder visibility boundary.
8. Cite the current symbol and line where the meaning is established.

Useful generic searches:

```powershell
rg -n 'field_name|"field_name"' gdext/src Project/project-keynes/scripts docs/cpp-dots-runtime
rg -n 'reset_.*metric|publish_epoch|aggregate_publish|fill_batch|HEADERS' gdext/src/economy_*
rg -n 'market_cycle_days|sample_day|commit_day|wait_commit|economy_day_barrier' `
  gdext/src Project/project-keynes/scripts
```

Do not assume a header suffix or recorder filename version fully describes the schema. Compare the
actual CSV header with `HEADERS` and any appended schema suffix in current recorder code.

## 3. Search routes by domain

### Conservation and money creation

Search for `population_error`, `money_error`, `goods_error`, `opening_totals`, `explicit_mint`,
`explicit_burn`, `producer_support_money_issued`, `bullion_money_issued`, construction/input sinks,
supported/discarded output, cargo escrow, and cash escrow. Verify which exceptions are explicit and
which holdings enter closing totals.

### Market and price

Search for `last_shortage_q16`, `demand_ema`, `business_demand_ema`, `offered_supply_ema`,
`realized_withdrawal_ema`, `merchant_inventory_target`, `production_input_reserve`,
`price_pressure`, `cost_anchor`, price adjustment caps, and inactive-price reversion. Trace whether
the recorder field is frozen, current, or derived after commit.

### Merchant liquidity and trade

Search for `merchant_cash`, procurement budget/opportunity/allocated/spent, effective buy factor,
credit exposure/draw/repay/bad debt, trade source/destination signals, candidate rejection counters,
dispatch, escrow, settlement, signal age, and response deadlines. Check runtime mode (`OFF`, `PROBE`,
or `ACTIVE`) before calling zero orders a failure.

### Buildings and investment

Search for building employment/production/commit stages, owner requirements and openings, funded
capacity, planned utilization, output settlement, wages, viability cost, severe-loss state,
recovery/liquidation, investment review, portfolio arbitration, rejection enums, and owner mobility.
Trace the matching `BuildingProfile` inputs, outputs, roles, resources, conditions, wage policy, and
construction requirements.

### Cohorts and demography

Search for signature compilation, household demand/clearing, survival requirement, producer-retained
food, livelihood/cash coverage, needs satisfaction, worst need, birth/death rates, starvation
threshold, demography residual, structural ECB, and cohort merge. Confirm population weighting and
whether an observed profession disappears because of death, migration, signature change, or merge.

### Natural resources

Trace resource slot IDs from recorder control through `world_ext_economy.cpp`, capture of opening and
committed reserve, pending native building delta, DataCore application/flush, and natural daily
change. Determine whether positive/negative and artificial generation/extraction columns partition
one net change or describe separate paths before summing them.

## 4. Catalog and ID mapping

Stable string IDs are authoritative for interpretation. Dense IDs are compiled from sorted stable
IDs, not directory enumeration. Rebuild mappings from current catalog resources and verify compiler
filters/aliases. Keep these separate:

- `signature_id`: profession, ethnicity, and consumption plan combination;
- `profession_id`, `ethnicity_id`, `worst_need_id`, `type_id`: dense catalog indices;
- `good_id`, `resource_id`: current recorder rows may already publish stable strings;
- `handle`: generation plus slot identity, not a stable longitudinal group key.

Trace building-good and need-good relationships through compiled catalog CSR or the originating
profiles. Do not infer a production or substitution link from similar names.

## 5. Cadence and visibility

The recorder consumes committed visibility. Confirm current graph order and whether a metric is:

- frozen at epoch begin;
- changed by employment/production before household clearing;
- updated during household clearing;
- held in `wait_commit`;
- applied in building commit or aggregate publish;
- deferred as a pending resource/command value;
- generated by soft trade planning outside the hard commit path.

`done=false` before deadline can be normal. `commit_due && !done` indicates deadline catchup. Price,
EMA, trade, investment, and demography correlations must use their actual current cadences.

## 6. Evidence standard

For a root-cause claim, provide:

- raw CSV rows or a reproducible aggregate;
- scope, units, and stock/flow classification;
- event timing and a plausible lag;
- exact current source symbol and profile/content inputs;
- the stage and authority owner;
- a competing explanation;
- a focused test, probe, or rerun that can distinguish them.

If code and docs disagree, report the drift and trust verified current behavior. If the recorder field
cannot be traced to authority state, classify it as an instrumentation question rather than using it
as proof of an economy bug.
