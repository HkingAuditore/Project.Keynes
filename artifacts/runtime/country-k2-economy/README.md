K2-B Country/Economy transaction evidence

Updated 2026-09-09.

Implemented operation paths:
- treasury_spend: reservation, peer prepared/applied ACK, commit decision, per-good conservation.
- fiscal_reserve: partial prepared quantity bounded by unreserved cash.
- fiscal_return and fiscal_collect: credit-side commit with overflow and directional conservation.
- cash_to_cohort: Country cash reservation and debit after peer prepare.
- cash_from_cohort: credit-side cash commit with overflow protection.
- good_to_market: Country goods reservation and debit after peer prepare.
- good_from_market: credit-side goods commit with overflow protection.
- research_purchase: all-or-nothing Country cash debit plus technology-points
  credit and purchased-total accounting after peer prepare.

Construction and canal treasury material/cash deductions now call
`coordinate_country_treasury_spend()`, which owns the Country multi-good
reservation/commit, market stock debit, living-merchant prefix distribution,
and peer-applied ACK. The construction/canal callers retain only project
creation and domain metrics; they no longer apply market or merchant side
effects a second time. The coordinator still runs inside the synchronous
Economy stage, so it is not yet the persistent Host outbox/inbox path.

Government research procurement now uses the Economy-owned
`coordinate_country_research_purchase()` coordinator. It freezes the stable
candidate order, preserves budgets/remaining demand/cursor across Economy
slices, validates living merchants and market stock before Country commit, then
applies market stock and merchant credits before the Country peer-applied ACK.
The procurement stage remains open until both the purchase pass and the
unfilled-demand ceiling pass finish. This is a real production-path peer-side
coordinator, but it is still not the persistent `NativeSimulationHost` Country
stage required for ACTIVE authority.

Save barrier:
- begin_save rejects in-flight asset transactions with country_save_economy_asset_transaction_pending.
- Economy fiscal reserve continuation rejects begin_economy_save and begin_economy_restore until
  the per-country reserve cursor reaches its terminal state; report fields include cursor/count/day,
  last requested/reserved quantity and the pending epoch-begin flag.
- Prepare rejection releases reservations.
- Peer apply rejection becomes FAULTED and never COMPLETED.

Authority remains SYNC. implemented_domain_mask remains 0x802.

Continuation evidence:
- economy_fiscal_reservation_continuation_test.gd: 40 checks, 0 failures.
- economy_cadence_runtime_test.gd: PASS with current PKEC schema 51.

Regression note:
- `canal_runtime_test.gd`: 28 checks, 0 failures.
- `treasury_construction_runtime_test.gd`: 2 grouped-material planner
  assertions failed; the test's Country bridge assertions passed. This remains
  an open construction planner issue and is not treated as K2-B green evidence.
