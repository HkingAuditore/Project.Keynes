K2-B Country/Economy transaction evidence

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

Construction and canal treasury material/cash deductions now call the same
`treasury_spend` compatibility adapter, so they receive the shared Country-side
reservation, commit, conservation audit, and transaction history. They still
use synthetic peer completion in the synchronous Economy caller and are not
the real cross-domain coordinator.

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
- Prepare rejection releases reservations.
- Peer apply rejection becomes FAULTED and never COMPLETED.

Authority remains SYNC. implemented_domain_mask remains 0x802.

Regression note:
- `canal_runtime_test.gd`: 28 checks, 0 failures.
- `treasury_construction_runtime_test.gd`: 2 grouped-material planner
  assertions failed; the test's Country bridge assertions passed. This remains
  an open construction planner issue and is not treated as K2-B green evidence.
