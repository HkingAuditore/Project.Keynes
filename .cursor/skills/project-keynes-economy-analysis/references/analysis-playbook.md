# Economy Analysis Playbook

## Contents

1. Data contract and units
2. Integrity and time windows
3. Market and merchant analysis
4. Resource analysis
5. Building analysis
6. Cohort and distribution analysis
7. Cross-domain diagnosis
8. Correlation protocol
9. Severity and reporting

## 1. Data contract and units

Treat one recorder family as five related tables, not one flat dataset:

| Table | Normal grain | Scope | Typical semantics |
| --- | --- | --- | --- |
| `summary` | committed epoch | global | world totals, epoch flows, audits, trade/building counters |
| `cohorts` | epoch, sampled cell, cohort | sampled/local | population, money, income, needs, employment |
| `market` | epoch, sampled cell, good | sampled/local | stock, price, demand/supply EMA, reserve, trade, merchant state |
| `buildings` | epoch, sampled cell, group/candidate | sampled/local | capacity, staffing, production, viability, lifecycle, investment |
| `resources` | epoch, sampled cell, resource | sampled/local | reserve, natural and artificial changes, yield/life diagnostics |

Check the current numeric ABI before converting:

- population is integer persons;
- money is normally i64 with 10,000 subunits per currency;
- goods are normally i64 with 1,000 subunits per good unit;
- price is money-scale value per complete good unit;
- Q16 uses 65,536 as 1.0, but coverage and margin diagnostics may legitimately exceed 1.0;
- resource recorder values are floats derived from fixed resource slots and may not use goods scale.

Never add heterogeneous goods or natural resources and label the result a physical total. Such sums
are useful only as recorder workload or activity indices.

## 2. Integrity and time windows

Validate:

- exact headers and schema fingerprints;
- one summary row per captured `epoch_row_id`;
- detail epoch IDs are a subset of summary epoch IDs;
- expected primary-key uniqueness at each table grain;
- day monotonicity and gaps;
- consistent sampled cell IDs and cube coordinates;
- malformed CSV width, blank entity IDs, and missing files;
- first and last rows are committed visibility boundaries rather than active partial stages.

Classify each field before aggregating:

- **stock/state**: population, funds, stock, reserve, price, building count, debt outstanding;
- **epoch flow**: births, deaths, income, expense, output, sold, discarded, wages, orders dispatched;
- **EMA**: demand, supply, withdrawal, trade import/export;
- **diagnostic ratio**: Q16 shortage, coverage, margin, utilization, liquidity;
- **pending**: resource or command values not yet applied to authority state.

Use at least first/last, an early and late window, and event-onset windows. The default 180-day
window is descriptive, not universal; shorten it for short runs and align it to cycle or review
cadence when possible.

## 3. Market and merchant analysis

For each active good, calculate:

- stock and `household_available_stock` separately;
- demand, business demand, offered supply, and realized withdrawal EMAs;
- shortage prevalence, severe-shortage duration, and stockout duration;
- `production_input_reserve`, inventory target, procurement shortfall, and unfunded demand;
- price first/last, extrema, log change, pressure sign, and cost-anchor relationship;
- trade eligibility, signal age, attempts, rejection reason, relief pressure, imports, and exports.

Interpret common patterns:

- Demand and shortage with zero stock points to production/import failure.
- Positive stock with zero household-available stock points to production reserve or export safety
  stock, not aggregate scarcity.
- High offered supply plus low withdrawal and high discard points to weak final demand or a
  settlement/liquidity bottleneck.
- Desired demand far above funded demand points to owner/merchant finance before physical capacity.
- Persistent shortage plus no attempts requires tracing trade signal generation and mode.
- Price movement that appears inconsistent with shortage must be decomposed into demand pressure,
  inventory gap, cost anchor, inactive reversion, adjustment cap, and frozen-cycle lag.

Merchant cash/economic-asset/liquidity fields repeat on each good row. Deduplicate once per
`(epoch_row_id, cell_idx)` before totals or correlations. Compare merchant and nonmerchant population,
funds per capita, income, expenses, and wealth share; aggregate merchant money is not a market cash
account in the runtime ownership model.

## 4. Resource analysis

For each resource, report:

- opening, minimum, and final reserve;
- absolute and percentage depletion where opening reserve is positive;
- natural positive/negative/net change;
- artificial generation/extraction, split into applied and pending;
- latest and minimum projected life plus safe yield;
- first critical day and whether extraction or natural loss leads it.

Do not assume `natural_negative_change` and `artificial_extraction_applied` are independent sinks.
Trace their recorder assignments and resource-slot update path before adding them. Pending change is
next-boundary evidence and must not be treated as already reflected in committed reserve.

Connect a resource only to buildings whose current profile declares that natural-resource edge.
Then compare resource consumption/output with building capacity and market supply. A depleted unused
resource and a depleted binding input are different balance problems.

## 5. Building analysis

Separate three row classes before aggregation:

- actual groups: `group_index >= 0` and not construction/candidate;
- pending construction rows;
- candidate-only investment rows, commonly `group_index == -1`.

For actual groups or stable building type, analyze:

- physical `owner_capacity`, active `owner_required`, planned owner equivalent, filled owners, and
  openings as distinct quantities;
- employee required/filled and wage suspension;
- funded/purchase-intent/planned utilization;
- input, output, sold, retained, supported, and discarded dispositions;
- revenue, input cost, base wages, bonuses, full operating cost, livelihood requirement, margin,
  and income gap;
- operating-state transitions, loss/recovery cycles, debt/delinquency, restart, and liquidation;
- investment score, capital/payback, demand driver, and rejection reason.

Use quantity-weighted utilization and margin when aggregating groups. Do not average group ratios
equally when group sizes differ. A profitable historical lifetime can still end suspended; inspect
late windows and transition onset rather than relying on all-run totals.

Dense `type_id` is compiled from sorted stable building IDs. Rebuild the mapping from current
catalog resources for every analysis. Directory order is not identity.

## 6. Cohort and distribution analysis

Analyze by signature first, then aggregate by profession, ethnicity, merchant status, and selected
combinations. Report:

- population and population change;
- funds per capita, not funds alone;
- epoch and EMA net income per capita;
- cash-expense and livelihood coverage;
- population-weighted satisfaction and worst-need persistence;
- owner, employee, and unemployed counts/rates;
- first low-coverage, low-satisfaction, unemployment, and population-loss days.

Keep wealth outside cohort identity. Handles may change after structural operations; use the stable
signature/cell grain for long-run comparison. Report merchant versus nonmerchant wealth and income
shares and, when useful, a population-weighted inequality measure. Explain whether inequality comes
from prices, employment, ownership, transfers, producer support, bullion issuance, or demographic
selection rather than treating it as one generic concentration statistic.

## 7. Cross-domain diagnosis

Test concrete causal chains in both directions:

```text
resource reserve -> building resource/input constraint -> utilization/output
  -> market stock/shortage/price -> cohort coverage/satisfaction -> births/deaths

merchant cash/credit -> funded procurement -> accepted output/inventory
  -> producer revenue/wages -> owner/worker funds -> household demand

market demand/shortage -> price and investment signal -> construction/owner mobility
  -> capacity/employment -> future supply and trade relief
```

Require matching entities and timing. `wild_game` cannot explain `fish` without an explicit
substitution/need path; a global unemployment series cannot prove the cause of one selected cell.

Use conservation as the first gate. If an audit is nonzero, prioritize the accounting path. If all
audits are zero, continue into allocation, access, viability, distribution, and approximation.

## 8. Correlation protocol

For every reported coefficient state:

- the two series and their scopes;
- stock/flow/EMA classification;
- transform (`level`, `first_difference`, rate, log, or normalized);
- sample count and missing-day handling;
- driver-to-outcome lag in simulation days;
- Pearson and rank correlation when practical;
- expected mechanism and matching source path.

Use at least 30 aligned samples. Prefer more for slow reviews or serially correlated data. Start
with first differences to reduce shared trends. Test lags that correspond to the configured market
cycle, EMA response, trade planning/settlement, 30-day capital review, and demography update.

Reject or downgrade a correlation when:

- it exists only in levels;
- it combines global summary with one local cell without qualification;
- one field is algebraically derived from the other;
- repeated market-wide fields were counted once per good;
- both respond to day, population, or a third shortage;
- the alleged outcome starts before the driver;
- code has no path connecting the entities.

Correlation ranks investigation targets. It does not establish a runtime defect or a balance fix.

## 9. Severity and reporting

- **P0**: nonzero conservation, malformed/incomplete recording, impossible authority state,
  deterministic/replay violation, or fatal invariant.
- **P1**: persistent survival shortage, demographic collapse, systemic unemployment, trade or
  investment mechanism not responding, binding reserve/liquidity deadlock, or widespread lifecycle
  failure.
- **P2**: local imbalance, slow response, inequality, excess inventory/discard, volatile price,
  marginal building viability, or instrumentation gap.

For each finding give evidence, onset, magnitude, persistence, scope, code/content path, confidence,
alternative explanations, and the smallest falsifying rerun or test.
