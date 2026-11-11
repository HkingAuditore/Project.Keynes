# Economy bridge and conservation

Cell-tax addendum: the immutable epoch snapshot carries transient cell→policy
mapping plus canonical sparse policy rows directly to native Economy. Economy
compiles only used `(country_handle, policy_id)` pairs. Policy IDs never enter
PKCN or deterministic state hashes, and workers never dereference Country objects.

## Narrow native bridge

`NativeEconomyRuntime` holds a non-owning pointer to `NativeCountryRuntime`. Never route hot economy
queries through GDScript. Technology gates resolve `cell -> frozen country slot -> technology bit`;
unowned cells have no technology.

At every economy sample day freeze:

- cell-to-country slots;
- country generations;
- country technology words;
- country tax defaults/overrides resolved to dense profession/good/building arrays;
- sparse cell tax policy mapping and canonical policy rows;
- country generation/state hash.

Territory, technology, and tax-policy commits during the cycle apply only to the next cycle.

## Transfers

Fiscal RETURN/COLLECT/RESERVE terminal consumption on the Economy worker must
also call `finish_worker_country_asset()` before audit, so the Country side and
immutable cash snapshot are current. Route by actual Country worker grant even
if the compatibility sync-write flag has not caught up; `total_cash()` uses that
same grant. Completed cell lanes fold unused subsidy plus withheld tax into
country escrow once at `commit_fiscal()`, before any Country transfer.

Under Host worker ownership, cohort cash transfers can complete the existing
asset protocol on that same worker thread after Country's daily stage. Preserve
target slot and handle, preflight both balances, journal peer application, commit
through CountryCore, then publish the Country read view before returning to
structural cohort reclamation. Never dispatch this synchronous worker boundary
from the main thread or while a Country plan is open. `total_cash()` uses the
immutable Host snapshot under worker authority so closing audits see the transfer.

General cash transfers move existing value between one country and one cohort. Goods transfers move
existing stock between one country treasury and the merchant market of a specified cell. Cap by
available balance/stock. These generic APIs do not infer taxes or ownership changes. Tax settlement
uses explicit country fiscal reserve/return/collect operations through the dedicated tax contract.

Keep debug mint/burn/add/remove economy commands explicit and distinct from country income.

## Audit

At committed boundaries require exact zero errors:

- total money = all cohort funds + all country cash + trade escrow + fiscal escrow;
- total goods = all market stock + all country goods;
- population remains separately conserved;
- production, consumption, building use, explicit mint/burn, and external stock delta remain ledger
  legs rather than disappearing into treasury changes.

Country assets, tax policy version, fiscal history, and escrow-relevant state must participate in the
economy state hash or committed fiscal summary as defined by the tax contract. Worker and scalar
paths must produce the same state hash and `0/0/0` audit.

## Ownership changes

Territory transfer does not move cohorts, buildings, merchants, or market stock. A running economy
cycle settles against the frozen country snapshot even if live ownership changes. Before beginning a
new cycle, block while any due country command has not committed. Generation-safe territory changes
invalidate prior cell subsidy weights that belong to the old country handle.

If the country bridge is unavailable or invalid, disable dependent economy behavior with a precise
reason. Never fall back to per-cell technology or an economy-owned global treasury.
