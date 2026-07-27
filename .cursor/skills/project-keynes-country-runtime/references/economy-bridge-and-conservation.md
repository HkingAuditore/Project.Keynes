# Economy bridge and conservation

## Narrow native bridge

`NativeEconomyRuntime` holds a non-owning pointer to `NativeCountryRuntime`. Never route hot economy
queries through GDScript. Technology gates resolve `cell -> frozen country slot -> technology bit`;
unowned cells have no technology.

At every economy sample day freeze:

- cell-to-country slots;
- country generations;
- country technology words;
- country generation/state hash.

Territory and technology commits during the cycle apply only to the next cycle.

## Transfers

Cash transfers move existing value between one country and one cohort. Goods transfers move existing
stock between one country treasury and the merchant market of a specified cell. Cap by available
balance/stock. These APIs do not tax, pay, mint, burn, or infer ownership changes.

Keep debug mint/burn/add/remove economy commands explicit and distinct from country income.

## Audit

At committed boundaries require exact zero errors:

- total money = all cohort funds + all country cash;
- total goods = all market stock + all country goods;
- population remains separately conserved;
- production, consumption, building use, explicit mint/burn, and external stock delta remain ledger
  legs rather than disappearing into treasury changes.

Country assets must participate in the economy state hash, event legs, and cash-flow source. Worker
and scalar paths must produce the same state hash and `0/0/0` audit.

## Ownership changes

Territory transfer does not move cohorts, buildings, merchants, or market stock. A running economy
cycle settles against the frozen country snapshot even if live ownership changes. Before beginning a
new cycle, block while any due country command has not committed.

If the country bridge is unavailable or invalid, disable dependent economy behavior with a precise
reason. Never fall back to per-cell technology or an economy-owned global treasury.
