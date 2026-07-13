# Market Algorithms and Numeric Contracts

## Contents

1. Numeric ABI
2. Frozen-period model
3. Need and variant demand
4. Budget and bundle clearing
5. Merchant settlement and satisfaction
6. EMA and price
7. Conservation and failure

## 1. Numeric ABI

- Population: integer i64 persons.
- Money: i64, 10,000 subunits per currency.
- Goods: i64, 1,000 subunits per good unit.
- Price: i32 money scale per complete good unit.
- Ratios/satisfaction: Q16; rates/residual ABI: Q32.

Use signed saturating add/sub/mul and `mul_div_sat` with a 128-bit intermediate. MSVC uses
`_umul128/_udiv128`; Clang/GCC uses unsigned `__int128`. Truncate toward zero and count saturation.
Never depend on signed overflow or platform floating-point math for authority state.

Use versioned integer `pow_q16` for wealth/price elasticity and 17-point Q16 linear environment
curves. Float is allowed only for timing/UI.

## 2. Frozen-period model

The authority model is `frozen_sample_adaptive_price_v2`.

At sample day, freeze population, funds, price, stock, profession/ethnicity/plan, and four environment
signals. Calculate the whole N-day period from that state. The production default is N=5. Setting
`market_cycle_days=0` selects scale-driven automatic N.

This is an approximation, not N sequential daily integrations. Keep its state invisible until
the period deadline. Commands arriving after sample day apply next period.

## 3. Need and variant demand

For each cohort/need, conceptually calculate:

```text
wealth_pc       = funds / population
wealth_ratio    = wealth_pc / wealth_reference
wealth_factor   = clamp(pow_q16(wealth_ratio, elasticity), min, max)
period_need     = population * base_qty_per_person * N
period_need    *= wealth_factor * ethnicity_need_factor * sample_day_environment_factor
```

Precompute market-invariant variant price/environment scores once per market, not once per cohort.
For a variant, sum component price into one bundle unit price, apply reference-price elasticity,
base preference, and preference environment curve. Split need quantity among variants with stable
prefix shares.

Variants under one need are substitutes. Components under one variant are complements forming an
indivisible proportional bundle.

## 4. Budget and bundle clearing

Order needs by priority and constrain funded quantity by remaining cohort funds. Keep money rounding
deterministic.

For each component good, allocate shortage with cumulative prefix quotients:

```text
allocation_i = floor(prefix_i * available / total)
             - floor(prefix_(i-1) * available / total)
```

The minimum component capacity determines filled bundle units. If primary inventory is abundant,
use the fused abundant path and avoid component-reference CSR construction. Only inventory shortage
may trigger one same-period substitution fallback; budget-only unmet demand must not re-enter fallback.

## 5. Merchant settlement and satisfaction

For actual trades:

```text
buyer funds -= actual cost
buyer epoch_expense += actual cost
stock -= actual component quantity
merchant funds += population-weighted revenue share
merchant epoch_income += revenue share
```

Distribute merchant revenue once per market, not per order. Compute total and worst-need satisfaction
in one linear pass over need states; do not scan all need states once per cohort.

Merchants also submit household demand. Total cohort money does not change from purchases.

## 6. EMA and Price V3

Normalize period demand and net income to daily values before EMA:

```text
daily_demand = period_demand / N
demand_alpha = min(1, configured_daily_alpha * N)
daily_net    = period_net_income / N
income_alpha = min(1, N / 8)
```

Household demand remains market-major. Building input demand, offered supply, and production-cost
anchors live in a sorted sparse `(cell, good)` signal store built from actual building input/output
edges. Update those signals only after production so they feed the next frozen cycle.

Price pressure combines excess demand, target-inventory gap, shortage, a confidence-weighted soft
cost anchor, and inactive-default-price reversion. Divide the combined pressure by the configured
demand price elasticity before applying the good-specific adjustment rate. Monetary-issue goods do
not use retail cost anchors. Clamp to per-day max rise/fall, multiply the frozen daily change by N,
apply one linear price update, then clamp absolute min/max. This avoids N feedback loops and dense
building-by-good storage while making production costs and business demand economically visible.

## Domestic trade planning and settlement

Keep one cell equal to one local market. Build a separate trade topology from frozen six-neighbor
indices, positive terrain enter costs, and frozen country ownership. Every vertex on a v1 route must
belong to the same non-neutral country. Do not materialize all-pairs distances or a dense
market-by-good trade matrix.

Scan market-major pairs with a round-robin deterministic work budget and retain only sparse surplus
and deficit signals. For a selected surplus source, run bounded integer multi-target Dijkstra and
stop after K profitable deficits or the expansion cap. Route distance is good-independent and may be
cached under fixed memory limits. Rank candidates stably by profit per capacity work, total profit,
route cost, source, destination, and good.

Capacity work is `quantity * transport_load_per_unit_q16 * route_cost`. Clip on source stock,
destination merchant funds, per-country merchant-population capacity, and order limits. Dispatch
removes source stock and destination merchant cash immediately into cargo/cash escrow. Settle due
orders before household clearing; deliver cargo once and pay the snapshotted source merchants, with
local merchant rebinding and auditable cash retry when handles are invalid. Trade code never writes
prices directly.

## 7. Conservation and failure

Audit every committed period:

```text
closing_population = opening_population + explicit_population_delta
closing_money      = opening_money + explicit_mint - explicit_burn
closing_stock      = opening_stock + explicit_stock_delta - consumed_goods
```

For PKEC v11, closing holdings include in-transit cargo in goods and cash escrow in money. An order
moving value between stores must not appear as a mint/burn or goods source/sink.

Require all three errors to equal zero. Saturation is reportable but not silently ignored. Preflight
catalog, market shape, merchant index, environment day, command handles, and capacities before
mutation. Enter fatal state on an internal invariant break; do not copy 10M cohorts for rollback.
## Building transactions

Run building production outside `household_market`, after the household stage and at the frozen
deadline. Owner input purchases transfer money directly to local merchant cohorts. Producer output
offers sort by local retail price descending and use each good's configured merchant buy factor;
merchant positive funds cap the purchased quantity and the remainder is discarded. Track
construction/input sinks and accepted output separately in the goods audit. Role-level adaptive
base wages use local living-cost and contract-wage anchors. Aggregate obligations by owner, suspend
production after a shortfall, and settle post-sale excess-profit bonuses without minting money.

At epoch begin, compute each owner-lot's frozen expected producer revenue, input replacement cost,
full wage obligation, and target-margin gap for diagnostics and post-sale profit sharing. Keep
planned utilization at Q16 one: losses do not scale employee demand or output capacity. Actual
capacity is constrained only by staffing, owner funds, inputs, and resources.
