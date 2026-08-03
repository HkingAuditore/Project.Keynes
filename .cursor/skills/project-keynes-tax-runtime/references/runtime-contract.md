# Project.Keynes Tax and Fiscal Runtime Contract

## Contents

1. Authority and source map
2. Policy and Modifier layout
3. Tax bases and cash direction
4. Fiscal escrow and parallel settlement
5. Behavioral value
6. Tariff boundary
7. Public API and persistence
8. UI contract
9. Verification and performance

## 1. Authority and source map

Taxation is not a separate runtime.

| Concern | Authority |
|---|---|
| Default rates, sparse overrides, policy version | `NativeCountryRuntime` |
| Country cash treasury | `NativeCountryRuntime` |
| Country tax Modifier entity | `ModifierRuntime` using country handle |
| Frozen effective rates | `NativeEconomyRuntime` |
| Taxable events and source withholding | `NativeEconomyRuntime` |
| Fiscal escrow, subsidy history, fiscal totals | `NativeEconomyRuntime` |
| Stable-ID validation and command packing | `CountryFacade` |
| Player presentation | country view model and economy workspace |

Primary files:

- `gdext/src/country_runtime.{h,cpp}`
- `gdext/src/economy_runtime.{h,cpp}`
- `gdext/src/modifier_runtime.{h,cpp}`
- `gdext/src/world_ext_country.cpp`
- `gdext/src/world_ext_economy.cpp`
- `Project/project-keynes/scripts/country/country_facade.gd`
- `Project/project-keynes/scripts/modifier/modifier_catalog.gd`
- `Project/project-keynes/scripts/ui/country_view_model.gd`
- `Project/project-keynes/scripts/ui/components/economy_workspace.gd`
- `docs/cpp-dots-runtime/tax-fiscal-runtime.md`

## 2. Policy and Modifier layout

Stable `TaxKind` order:

| Dense kind | Stable name | Item lane |
|---:|---|---|
| 0 | income | profession |
| 1 | consumption | good |
| 2 | business | building type |
| 3 | import | good |
| 4 | export | good |

Each country stores one integer default per kind and a dense override vector using an inheritance
sentinel. Save/query surfaces retain sparse override semantics. Clearing an override immediately
inherits the current default.

Commands:

- `SET_TAX_DEFAULT`
- `SET_TAX_OVERRIDE`
- `CLEAR_TAX_OVERRIDE`

Command columns include `tax_kinds`, `tax_item_indices`, and `tax_rate_percent`. The facade validates
stable IDs and converts them to dense IDs before submission. `CountryDailySystem` commits commands
at the effective day before the economy freezes the next epoch.

Stat keys:

```text
country.tax.income.<profession>.rate_pct
country.tax.consumption.<good>.rate_pct
country.tax.business.<building>.rate_pct
country.tax.import.<good>.rate_pct
country.tax.export.<good>.rate_pct
```

The country policy and Modifier catalogs must use the same sorted profession/good/building IDs.
Reject duplicate keys and shape/hash mismatches. The economy resolves stat IDs outside workers,
batch-queries each country once per epoch, rounds half away from zero, clamps to `[-100,100]`, and
stores contiguous `int8` arrays.

Generate an active-tax bitmask from the frozen arrays. When a kind is entirely zero, preserve the
original settlement/prediction fast path and skip unnecessary fiscal drafts.

## 3. Tax bases and cash direction

Unified formula:

```text
amount = floor(base * abs(rate_percent) / 100)
```

Use saturating `int64` fixed-point helpers. Positive rates transfer payer cash to the cell's country
treasury. Negative rates transfer treasury-funded fiscal escrow to the recipient.

### Income tax

- Employee wage: tax the full wage share and withhold before crediting funds.
- Building owner: tax positive operating receipts minus actual inputs, actual wages, and positive
  business tax.
- Merchant: tax positive household-sales share minus operating expense.
- Clamp each batch base to zero. Do not carry losses.
- Exclude transfers, minting, construction investment, capital principal, producer support, tax
  subsidies, and business subsidies.

### Consumption tax

- Apply only to household cohort orders.
- Positive tax increases the order's budget quote.
- Merchant revenue remains the component base transaction price.
- Negative tax reduces the quoted price only from locally reserved subsidy budget.
- Allocate quote discounts and actual subsidy use in stable order.
- Do not tax building inputs, construction, government research procurement, or domestic trade.

### Business tax

- Base is the actual producer payment received from merchants in the production batch.
- Aggregate all outputs belonging to the building group.
- Positive tax is withheld from the producer receipt.
- Negative tax is paid to the owner and excluded from income tax.
- Positive business tax is deductible from owner operating income tax.

Cashflow sources must distinguish income/consumption/business tax, their three subsidies, fiscal
reserve/return, and existing non-tax sources. Taxes and subsidies are transfers, never minting.

## 4. Fiscal escrow and parallel settlement

Fiscal lanes are stable `(cell, active tax kind)` entries for income, consumption, and business.
Tariff lanes remain inactive until foreign trade exists.

At the start of each rolling bucket:

1. Match the prior lane history to a generation-safe country handle.
2. Sum the previous subsidy requests per country.
3. Reserve `min(country cash, previous request)` before research procurement.
4. Allocate the reserved cash proportionally by previous request.
5. Resolve integer remainders by stable tax-kind then cell prefix order.

Workers read their lane budget and mutate only their own lane request/remaining/paid entries.
Do not let workers write country treasury or shared fiscal totals.

At fiscal commit:

1. Aggregate bases, assessed tax, collected tax, requests, reserved amount, paid amount, and unmet
   amount by country and kind.
2. Return unused escrow.
3. Deposit positive tax collected this batch.
4. Replace previous request weights with current request weights.
5. Clear escrow before the save boundary.

Current positive tax is available only to the next subsidy batch. This avoids circular funding.
First negative-rate batch without history pays zero and establishes the next weight. Territory
transfer invalidates history whose generation-safe country handle no longer matches.

Money audits include trade and fiscal escrow. Country treasury must never become negative.

## 5. Behavioral value

Settlement and prediction must share the same effective frozen rates.

### Purchase

Use the tax-adjusted household quote for budgeting and quantity. A positive consumption tax reduces
affordable quantity. A funded negative rate increases it by lowering the quote.

### Employment

Keep survival-output and shortage priorities ahead of personal tax preference. Compare groups by
profession-specific after-tax/gross wage retention when income tax is active. When all income rates
are zero, omit this key so the historical hiring order remains exact.

### Owner mobility

Compute expected owner cash:

```text
operating = expected producer receipt - input cost - wage cost
business_transfer = expected business tax or funded subsidy
income_base = max(0, operating - max(0, business_transfer))
income_transfer = expected income tax or funded subsidy
owner_cash = max(0, operating - business_transfer - income_transfer)
```

Add in-kind livelihood only after cash transfers. Compare per owner job per day.

### Investment

Apply expected business transfer to projected cash revenue. Apply income transfer to positive
owner operating income after positive business tax. Use after-tax economic revenue for:

- owner livelihood gate;
- target operating margin;
- daily profit;
- payback;
- projected owner income;
- entrepreneur income-improvement decision.

Use the realized signed business transfer in the building lifecycle margin so tax can affect
suspension, recovery, and later labor priority.

### Expected subsidy

Do not use nominal negative rates as guaranteed income. For a negative rate:

```text
nominal = floor(base * abs(rate) / 100)
expected_paid = min(nominal, floor(nominal * lane_budget / previous_request))
```

If previous request or lane budget is zero, expected subsidy is zero.

## 6. Tariff boundary

Import and export tax defaults, good overrides, Modifier stats, commands, queries, persistence, and
UI exist now. Domestic trade must report zero tariff events and amounts.

Future foreign trade integration must define:

- domestic importer and exporter;
- transaction country ownership at settlement;
- import base from the domestic merchant buy price;
- export base from the domestic merchant sell price;
- withholding/subsidy recipient and escrow lane.

Do not guess foreign status from route distance or a current domestic country boundary.

## 7. Public API and persistence

Facade API:

- `set_tax_default(handle, kind, rate_percent, effective_day, sequence)`
- `set_tax_override(handle, kind, item_id, rate_percent, effective_day, sequence)`
- `clear_tax_override(handle, kind, item_id, effective_day, sequence)`
- `tax_policy_snapshot(handle)`
- `fiscal_snapshot(handle)`

Policy snapshots expose defaults, sparse overrides, policy version, catalog hash, base rates, and
Modifier-effective rates. Fiscal snapshots expose bases, assessed/collected tax, requested/reserved/
paid/unmet subsidy, fulfillment, cumulative values, and inactive tariff state.

Current schemas:

- PKCN v4: tax policy, policy version, country Modifier persistence.
- PKEC v23: previous subsidy requests, generation-safe country history, fiscal cumulative values,
  and deterministic hash.

PKCN v3/PKEC v22 migrate explicitly to zero rates and empty fiscal history. Modifier catalog
extension during this migration must validate every old stable stat key, definition version, and
normalized term payload. All other catalog hash mismatches remain errors.

Restore PKCN before PKEC. Save only at a committed boundary with zero fiscal escrow.

## 8. UI contract

Keep taxes inside the existing country Economy workspace. Pages:

- Treasury
- Income
- Consumption
- Business
- Import
- Export

Show treasury, last tax collected, subsidy paid, and fulfillment summary cards. Each tax page shows
default rate, search/filter, overrides-only mode, base rate, effective rate, and pending state.

Submit one command only when a SpinBox/input is confirmed, not for every key or drag frame. Display
next-day pending state until both the effective day and a newer policy version are observed. Import
and export remain editable with a foreign-trade-not-connected message.

Cache rows and update visible values in place. Do not rebuild the node tree or reset scroll position
on daily refresh. Keep the workspace usable at 1280×720.

## 9. Verification and performance

Focused correctness:

- Five kinds, default/override inheritance, clear override, illegal ID/rate rejection, `±100%`.
- Integer floor and Modifier rounding/clamp.
- Employee wage and owner/merchant net income bases.
- Consumption quote versus merchant base receipt.
- Business actual receipt base and income deduction.
- Tax/subsidy exclusion from recursive income.

Fiscal:

- Nonnegative treasury.
- First-batch delay and next-batch proportional fulfillment.
- Stable remainder order.
- Unused return and research priority.
- Territory-transfer history invalidation.
- Exact money/goods/population conservation.

Determinism/save:

- Worker/scalar equality.
- Slice budget and continuation equality.
- PKCN/PKEC round trip and restored replay hash.
- Tariff configuration round trip with zero domestic events.

UI:

- Default and item rows.
- Immediate confirmed command and next-day pending state.
- Override clear/filter.
- Tariff placeholder.
- Cached node and scroll stability.

Performance:

- Build debug and release.
- Run 50 days using `project-keynes-headless-perf`.
- Compare same map, seed, scale, speed, audit mode, worker mode, DLL type, and machine state.
- Require median daily-graph regression no more than 3% and p95 no more than 5%.
- Inspect zero-tax default and a representative active-tax/subsidy scenario.
- Reject strings, Godot calls, shared treasury writes, and per-transaction allocations in workers.
