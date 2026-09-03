---
name: project-keynes-tax-runtime
description: Guide Project.Keynes native taxation and fiscal-settlement work across country tax policy, profession/good/building overrides, tax Modifier stats, income/consumption/business tax events, treasury-capped subsidies, tax-aware purchase/employment/investment behavior, tariff placeholders, PKCN/PKEC migration, country economy UI, determinism, conservation, and performance. Use when changing tax rates or commands, fiscal escrow, tax bases/cashflows, subsidy fulfillment, country/economy/modifier runtime integration, tax save schemas, tax-facing UI/tests, or diagnosing taxes that do not collect, subsidize, persist, or affect decisions correctly.
---

# Project.Keynes Tax Runtime

Treat taxation as an integration across existing runtimes, not as an independent simulation:

- `NativeCountryRuntime` owns policy, country Modifier entity, and cash treasury.
- `NativeEconomyRuntime` owns frozen effective rates, taxable events, fiscal escrow, settlement,
  behavioral predictions, audit, and fiscal history.
- GDScript validates stable IDs, packs commands, schedules existing systems, and renders UI.

Also use `project-keynes-country-runtime`, `project-keynes-economy-runtime`,
`project-keynes-modifier-runtime`, `project-keynes-runtime-architecture`,
`cpp-dots-runtime-development`, and `project-keynes-game-flow-runtime` when their boundaries change.
Use `project-keynes-headless-perf` for the required 50-day production-path benchmark.

## Ground before editing

Read the current source first:

- Policy/storage/commands/save: `gdext/src/country_runtime.{h,cpp}`.
- Events/escrow/behavior/save: `gdext/src/economy_runtime.{h,cpp}`.
- Modifier stat catalog/query: `gdext/src/modifier_runtime.*` and
  `Project/project-keynes/scripts/modifier/modifier_catalog.gd`.
- Bindings/facades: `world_ext*.{h,cpp}`, `country_facade.gd`.
- UI/view model: `country_view_model.gd`, `economy_workspace.gd`.
- Primary repository document: `docs/cpp-dots-runtime/tax-fiscal-runtime.md`.

Read [runtime-contract.md](references/runtime-contract.md) for formulas, dense layouts, fiscal
ordering, behavior, persistence, UI, tests, or performance work. Treat current source and the
repository document as final truth; update this skill when either contract changes.

## Classify the requested change

State which boundaries change before coding:

1. Country policy/default/override or command boundary.
2. Modifier stat catalog or effective-rate freeze.
3. Tax base, withholding, subsidy, or cashflow classification.
4. Fiscal escrow allocation, territory ownership, or research-procurement priority.
5. Purchase, employment, owner mobility, lifecycle, or investment prediction.
6. Facade/query/UI.
7. PKCN/PKEC/PKSV persistence or migration.
8. Foreign-trade tariff activation.

Do not infer a tariff event from domestic trade. Activate tariffs only after foreign settlement
identifies the domestic importer/exporter and the relevant domestic merchant buy/sell price.

## Preserve hard invariants

- Keep rates as deterministic integer basis points in `[-100000,10000]` for percent mode;
  absolute mode uses signed currency in `[-1e9,1e9]`. Negative means subsidy.
- Resolve stable IDs before commands enter native code. Workers use dense IDs and frozen arrays.
- Keep Modifier targets country handles. Do not add composite country-item entities.
- Generate tax stat keys from the same sorted economy catalog used by policy arrays.
- Quantize Modifier-effective rates half away from zero, then clamp. Modifier overlays apply
  only to percent-mode slots; absolute slots freeze policy values as-is.
- Percent: `mul_div_sat(base, abs(rate_bp), 10000)`. Absolute income/business:
  `|X| * count * epoch_days` in `settle_absolute_daily_taxes_for_cell`. Absolute
  transaction/tariff: `|X| * qty` at settlement.
- Withhold positive percent tax at the source. Absolute daily levies saturating-collect from
  cohort/owner cash at assessment (unmet assessed amounts are recorded, never minted).
- Exclude transfers, minting, capital principal, tax subsidies, and losses from income tax bases.
- Deduct positive business tax from owner operating income; never tax a business subsidy again.
- Tax household consumption only, not building inputs, government procurement, or domestic
  merchant relocation.
- Keep subsidies treasury-capped. First consumption/business negative-rate batch with no history
  pays zero; a negative income lane may seed its first reservation from the current frozen
  minimum-living request. Family purchase discounts share that same subsidy/escrow lane; they are
  not a separate tax account.
- Reserve subsidy cash before research procurement; collect current positive taxes only for the
  next batch.
- Keep one worker per cell/lane with no shared treasury writes, locks, atomics, Godot calls,
  strings, Variant, or per-transaction heap allocation.
- Return unused escrow and clear it at fiscal commit. Include escrow in money conservation.
- Keep domestic tariff event count and amount zero until foreign trade exists.
- Preserve zero-tax fast paths. Default `0%` / absolute `0` must not add per-order or per-building tax work.
- Preserve population, money, and goods audit errors at exactly zero.

## Implement in the required order

1. Extend sorted catalog IDs and validate policy/stat shapes.
2. Add or update country policy storage and atomic daily commands.
3. Add Modifier stat definitions and dense batch queries.
4. Freeze country×item effective rates once per economy epoch.
5. Define exact bases, withholding point, cashflow sources, and saturation behavior.
6. Update fiscal reservation and commit without introducing shared worker writes.
7. Route both actual settlement and predictive behavior through consistent tax helpers.
8. Update facade snapshots, UI, persistence, state hash, and explicit legacy migration.
9. Update the primary repository document, system map, runtime matrix, module docs, and this skill.
10. Run focused tests, debug/release builds, editor parse, and the 50-day benchmark.

## Keep actual and predicted behavior consistent

- Purchases use tax/subsidy-adjusted order prices.
- Employee choices use profession-specific after-tax retention without changing zero-tax ordering.
- Owner mobility uses expected after-tax operating income.
- Investment gates use after-tax revenue, margin, payback, and owner income improvement.
- Negative taxes enter predictions only at the fulfillment ratio supported by the previous request
  or the income lane's current minimum-living reservation weight and current reserved budget.
  Never value an unfunded subsidy as guaranteed.
- Realized building lifecycle margin uses actual after-business-tax producer receipts.

When a formula changes, search both settlement and prediction paths. A tax that changes cash but
not purchase/employment/investment value is incomplete unless explicitly documented.

## Persistence rules

- Restore country state before economy state.
- Persist stable policy/Modifier identity, sparse overrides, fiscal history, and deterministic hash.
- Never persist process-local stat IDs or ephemeral fiscal escrow.
- Accept catalog changes only through an explicit versioned migration that validates legacy stat
  keys, definition versions, and normalized term payloads.
- Reject general catalog mismatches; do not weaken hash validation to make a migration pass.

## Verify

At minimum run:

- `tests/country_runtime_test.gd`
- `tests/modifier_runtime_test.gd`
- `tests/economy_rolling_runtime_test.gd`
- `tests/economy_trade_runtime_test.gd`
- relevant building/goods/technology/save suites
- `tests/player_country_ui_smoke_test.gd`
- Godot headless editor parse
- debug and release GDExtension builds
- 50-day `project-keynes-headless-perf` benchmark

Verify:

- all five default/override lanes and `±100%`;
- income, consumption, and business bases and cashflows;
- consumption/business first-batch delay, immediate funded income-floor reservation,
  proportional allocation, unused return, nonnegative treasury;
- worker/scalar, continuation, save/restore, and replay hash equality;
- tariff configuration round-trip with zero domestic events;
- UI unlock-filtered card grid with localized profile display names and catalog icons,
  input-to-override plus reset-to-default, pending state, inspector SpinBox drafts
  retained across live patches, merged import/export tariff cards,
  filtering, node/scroll reuse;
- zero strings/Godot/shared treasury writes/transaction allocations in worker hot paths.

Do not claim the 3% median / 5% p95 gate without a same-machine comparable baseline. Report
unrelated pre-existing suite failures separately from tax regressions.

## Report completion

Include:

- Authority and affected runtime boundaries.
- Tax bases, cash directions, subsidy fulfillment, and behavioral effects.
- Schema/migration and UI changes.
- Conservation, determinism, save, test, build, and benchmark evidence.
- Any performance gate or unrelated repository suite that remains unpassed.
