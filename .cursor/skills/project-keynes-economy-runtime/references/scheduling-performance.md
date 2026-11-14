# Scheduling, Approximation, and Performance

## Contents

1. Economy graph
2. SUS and WorldClock
3. Profile controls
4. Report contract
5. Performance evidence
6. Approximation evidence
7. Diagnosis

## 1. Economy graph

Stages are stable diagnostic ABI:

1. `trade_planning`: after the previous publish, consume deterministic scan/route work units; soft task only.
2. `epoch_begin`: preflight, freeze the sample-day view, and compute building revenue/cost diagnostics.
3. `trade_settle`: deliver due cargo and retry unclaimed seller escrow.
4. `ledger_apply`: consume commands due at the sample day.
5. `trade_dispatch`: in ACTIVE, validate and escrow the completed candidate batch; PROBE only reports.
6. `building_employment`: fill sparse owner/employee roles from population alive at epoch start.
7. `building_production`: buy inputs, produce/sell output, and distribute post-sale income.
8. `household_market`: process one cohort-budgeted market range per simulation day against current
   epoch income and post-production stock.
9. `structural_commit`: stable-sort and apply ECB work.
10. `wait_commit`: keep completed internal state hidden until `sample_day + N - 1`.
11. `building_commit`: commit ready construction, then run the locked plan
    cycle (P in 5–15) and the longer investment cycle (I in 10–30, I > P)
    before publication and rebuild sparse
    employment ranges when structure or population changes.
12. `aggregate_publish`: publish summaries, market rows, audits, trade EMA, and report.

Do not publish half-computed market rows. Do not run market work inside the environmental
`SCHEDULE_GRAPH`.

## 2. SUS and WorldClock

`EconomyDailySystem` uses id `economy_daily`, priority 260, `must_run=false`,
`max_slices_per_tick=1`, `use_job_should_run=true`, starvation threshold 2, and declares reads for
temperature, moisture, snow, and weather intensity.

An active frozen period is expected to span days. Do not raise backpressure merely because
`done=false`.

- Before deadline: allow normal WorldClock progression.
- At deadline with unfinished work: report `commit_due=true` and request `economy_day_barrier`.
- During barrier: stop new simulation days but emit `simulation_backpressure_pulse` every real frame.
- Continue the same system/day through `DCSystemScheduler.continue_system` until commit.
- Release both economy backpressure sources on commit/reset.

## 3. Profile controls

Current production defaults:

```text
market_runtime_mode = ACTIVE
market_cycle_days = 5   # maximum market interval; native locks N in 1–5
market_min_cycle_days = 1
market_max_cycle_days = 5
building_plan_days = 5–15        # locked P, not shared with investment
investment_review_days = 10–30   # locked I, must be longer than P
economy_cadence_target_ms = 8
worker_market_threshold = 64
trade_runtime_mode = PROBE
```

`market_cycle_days=0` is ignored (treated as 5). It does not restore 50/334
auto-fast-forward. N, P, and I are chosen at their own cycle boundaries from live
economy cells (population > 0, or a building, or pending construction) plus
previous-cycle machine timing. Cadence milliseconds are accumulated only when
`aggregate_publish` COMMIT finishes the day. The daily workset is live cells ∩
the market bucket; empty wilderness is not settled.
Tests inject fixed cycle milliseconds, or set
`economy_cadence_force_market_days` / `economy_cadence_force_plan_days`
(`economy_cadence_force_slow_days` is a plan alias) /
`economy_cadence_force_investment_days` (0 keeps
automatic locking) when a small fixture must reproduce a historical 5/10/30
bucket. Those force keys are test-only and never part of production profiles.
Forcing plan without forcing investment still yields I > P.

Trade planning limits are deterministic work units. Never use measured wall time
to decide how far the simulation advances. An unfinished trade planning slice
never raises a WorldClock barrier.

## 4. Report contract

Preserve general stage/progress/cursor/work fields and at least:

- processed cells/cohorts/needs/variants/components/commands
- formula/clear/fallback/merchant-settle/price/ledger/structure/publish ms
- building plan/production and sparse market-signal ms, edge/update counts
- worker tasks, memory, cohort/market/good count
- population/money/goods error, saturation, fatal reason
- sample/current/commit/deadline day, age, days until commit, due/over-budget
- cycle length, target cohorts, max cycle, approximation version/model
- period transaction flag, maximum command latency
- environment day/hash, merchant count/repairs, price-cap hits, continuation slices
- trade topology generation, scan progress, route expansions/cache hits, candidates/rejections,
  capacity utilization, in-flight cargo, cash escrow, settlement lag, and trade-stage milliseconds

Worker stage milliseconds are task CPU totals. Slice `elapsed_ms` is wall time.

## 5. Performance evidence

Windows, Godot 4.6.2, template_release, historical explicit auto cadence
(N=50/334). These figures are not the current production lock (N in 1–5):

| Profile | N | Samples | avg | p95 | max | Runtime memory |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 10k cells / 200k cohorts / 100 goods / 16 needs | 50 | 2500 | 1.883ms | 2.766ms | 3.126ms | 101.0MB |
| 100k cells / 10M cohorts / 200 goods / 16 needs | 334 | 668 | 5.542ms | 6.333ms | 9.394ms | 1680.6MB |

These figures do not describe the current locked N∈[1,5] production path. Label benchmark cadence explicitly.

## 6. Approximation evidence

Standard fixed scenario versus N=1 daily reference:

| N | Consumption error | Spending error |
| ---: | ---: | ---: |
| 10 | 4.12% | 1.78% |
| 20 | 7.56% | 4.39% |
| 50 | 17.21% | 12.25% |
| 100 | 31.28% | 26.10% |
| 334 | 57.82% | 96.33% |

This table is scenario evidence, not a global or monotonic bound. Conservation does not measure
behavioral approximation error.

## 7. Diagnosis

- `wait_commit` before deadline: normal isolation.
- `commit_due && !done`: workload missed fixed-cycle deadline; expect hard barrier catchup.
- Long first/last slice: check for restored O(total cohorts) accounting clear or unconditional merchant rebuild.
- Worker tasks 1: range may be under threshold, WTP unavailable, or tail slice.
- High formula time: inspect cohort/need volume and repeated market-invariant work.
- High clear time: confirm abundant fused path and avoid fallback for budget-only unmet demand.
- High approximation error with zero audits: shorten N or improve the versioned approximation model.
- High market-signal time: compare sparse edge count with actual building input/output roles; a
  `market_count × good_count` scan or per-building duplicate keys is a regression.
- `due_cells` near `cell_count / N` on a mostly empty map: the live workset leaked empty
  wilderness back into `epoch_begin`.
- `cadence_market_ms_per_knife` an order of magnitude above `last_completed_*` market-side
  milliseconds: COMMIT-only cadence accumulation regressed to per-slice notes.
- Persistent zero utilization: inspect expected revenue, operating cost, target margin, supply
  elasticity, and frozen producer settlement price before changing employment rules.
- `save_requires_committed_boundary`: expected during any active or wait-commit stage.
- Incomplete `trade_planning` with no barrier: normal soft work; inspect deterministic work caps before
  increasing cadence.
- Excess route expansions or low cache hits: inspect sparse signal quality, K, topology generation
  churn, and route-cache cap; do not add an all-pairs distance table.
## Building stages

PKEC v3 adds `building_employment` and `building_production` before household clearing, with
`building_commit` after wait-commit. Empty building worlds skip the first two. Nonempty worlds use sorted
cell CSR and visit only active building cells; never scan all groups once per cell. The usual
deadline barrier applies if these stages miss commit.

Price V3 signal updates occur after both utility and normal production phases. Price calculation in
the current epoch reads only the previous committed signal EMA, preserving the frozen-cycle contract
and preventing scheduler-order feedback.

Endogenous construction uses completed-period profit and demand signals, but
starts at most one industrial building per cell when the locked investment cycle I
is due and the cell is also in that day's market workset. It reuses BUILD
material/payment/event ledgers and reports candidates, owner mobility, starts, and funds/material
blocks. PKEC v39 persists locked N/P/I and cycle starts.
