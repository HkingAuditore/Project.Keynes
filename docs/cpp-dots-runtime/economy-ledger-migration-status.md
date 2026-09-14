# Economy Ledger Migration Status

The production worker still executes NativeEconomyRuntime compact slices.
RuntimeEconomyLedgerState is a migration mirror, not an authoritative store.
It contains cohort active/signature/population/funds/income/expense columns and
market stock/price/demand EMA. Host captures new completed generations only.
The mirror is worker-owned and is not a concurrently readable UI snapshot.

RuntimeEconomyMarketStore now defines the live market columns outside
NativeEconomyRuntime, including shortage ratios, cell-to-market mapping and
sparse price ceilings. NativeEconomyRuntime::MarketStore is a type alias and
the existing runtime still owns the instance. This extraction adds no copy or
second writer and preserves PKEC field order. Moving instance ownership to the
worker remains a separate, uncompleted migration step.

RuntimeEconomyPopulationStore now owns the complete population column layout
and page/slot/reservation/handle operations in Godot-free source files.
NativeEconomyRuntime::PopulationStore is an alias; the runtime still owns the
live instance. Static assertions preserve page size, Q16 unit and satisfaction
dimension count. POD self-test exercises reservation, signature uniqueness,
handle invalidation and page reuse across cells using the extracted store.
No population columns or storage algorithms were removed during extraction.

The mirror does not contain cohort handles/page topology, building state,
employment, transaction journals, trade escrow, or resource state. It cannot
restore the simulation or justify switching production to POD_ACTIVE.
Its hash covers its columns and metadata only; it is not the full state hash.
Capture adds a full column copy and hash at each captured generation, so no
performance improvement is claimed for this migration step.

ECP1 ABI3 adds authority mode after receipt count and before business summaries.
ABI1 has no business summaries; ABI2 has summaries but no authority mode.
The ledger mirror is not serialized in ECP1. Full simulation persistence remains
in PKEC. The mode field is metadata and does not perform an authority handoff.

The existing submit_economy_commands facade remains enabled for command admission.
The worker ownership flag alone cannot disable it before a complete replacement
ingress is connected. ECP restore validates declared payload and receipt sizes
before replacing terminal receipts. POD self-test covers ABI1/2 fixtures derived
from the wire layout, ABI3 roundtrip, and rejection without state mutation.

Validation: debug GDExtension build and runtime_economy_pod_test (8 checks).
Full production parity, save compatibility fixtures, release benchmarks, and
long-running conservation tests remain required before production handoff.
