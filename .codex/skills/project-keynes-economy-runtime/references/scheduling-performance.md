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

1. `epoch_begin`: preflight, freeze the sample-day view, and compute building revenue/cost diagnostics.
2. `ledger_apply`: consume commands due at the sample day.
3. `household_market`: process one cohort-budgeted market range per simulation day.
4. `structural_commit`: stable-sort and apply ECB work.
5. `wait_commit`: keep completed internal state hidden until `sample_day + N - 1`.
6. `aggregate_publish`: publish summaries, market rows, audits, and report.

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
market_cycle_days = 5
market_max_cycle_days = 365
market_target_cohorts_per_slice = 0
worker_market_threshold = 64
```

`market_cycle_days=0` enables automatic cycle selection. With target 0, effective cohort budgets are:

- up to 500k active cohorts: 4k per slice
- up to 2M: 12k per slice
- above 2M: 30k per slice

Automatic N is `ceil(active_cohorts / target)`, clamped to max-cycle days. Fixed N=5 may miss its
deadline at the 10M extreme and then performs bounded same-day catchup. Use auto mode for extreme
fast-forward performance; use short fixed N for higher simulation fidelity.

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

Worker stage milliseconds are task CPU totals. Slice `elapsed_ms` is wall time.

## 5. Performance evidence

Windows, Godot 4.6.2, template_release, explicit auto cadence:

| Profile | N | Samples | avg | p95 | max | Runtime memory |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 10k cells / 200k cohorts / 100 goods / 16 needs | 50 | 2500 | 1.883ms | 2.766ms | 3.126ms | 101.0MB |
| 100k cells / 10M cohorts / 200 goods / 16 needs | 334 | 668 | 5.542ms | 6.333ms | 9.394ms | 1680.6MB |

These figures do not describe default fixed N=5. Label benchmark cadence explicitly.

## 6. Approximation evidence

Standard fixed scenario versus N=1 daily reference:

| N | Consumption error | Spending error |
| ---: | ---: | ---: |
| 10 | 14.43% | 19.72% |
| 20 | 29.05% | 41.26% |
| 50 | 56.86% | 94.53% |
| 100 | 15.17% | 25.16% |
| 334 | 63.42% | 3.99% |

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
- Persistent zero utilization: inspect expected revenue, operating cost, target margin, supply
  elasticity, and frozen producer settlement price before changing employment rules.
- `save_requires_committed_boundary`: expected during any active or wait-commit stage.
## Building stages

PKEC v3 adds `building_employment` before wait-commit and `building_production`/
`building_commit` after the deadline. Empty building worlds skip them. Nonempty worlds use sorted
cell CSR and visit only active building cells; never scan all groups once per cell. The usual
deadline barrier applies if these stages miss commit.

Price V3 signal updates occur after both utility and normal production phases. Price calculation in
the current epoch reads only the previous committed signal EMA, preserving the frozen-cycle contract
and preventing scheduler-order feedback.
