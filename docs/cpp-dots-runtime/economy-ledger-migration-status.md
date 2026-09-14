# Economy Ledger Migration Status

As of 2026-09-14 (Phase-2.4.4.4), production still executes
`NativeEconomyRuntime::worker_run_compact_slice` by default.
`RuntimeEconomyOwnedState` is an independent POD-owned committed mirror, not the
production formula or ledger authority. Host imports it only after a complete
legacy economy epoch; in-progress slices never cross this boundary.
`economy_pod_active_ready` may be true after ABI9 capture; Host may accept
`POD_ACTIVE` (opt-in `economy_auto_pod_active`) but `economy_production_writer`
defaults to / remains effective `compact_slice`. StageOps readiness checklist is
complete (`0xF`). Requesting `stage_ops` remains fail-closed as
`economy_production_writer_stage_ops_soak_pending` unless
`economy_stage_ops_soak_experiment=true` or a latched
`economy_stage_ops_soak_parity_ok` (default false).

## Phase-1 landed

- `EconomyExecutionMode` (`ACTIVE_ONLY` default / `ACTIVE_WITH_PARITY` /
  `LEGACY_ONLY`) on Host + `EconomyProfile` / `WorldRuntimeHost` config.
  Production keeps SHADOW StageOps at zero
  (`economy_shadow_stage_invocations=0`); parity mode publishes compact-slice
  stage refs under worker ECONOMY ownership and runs
  `execute_economy_worker_stage` (mutate=false) after a completed epoch.
- `begin_or_reuse_economy_input_epoch` + `EconomyInputGeneration` reuse path
  (report fields `input_capture_reused` / `count`).
- `BuildingOutputFactorKey` + per-group `BuildingFactorCacheEntry` with
  `building_factor_cache_hit_ratio_q16` diagnostics.
- Market/labor/input-reserve dirty-cell rebuild with diagnostics
  `market_signal_cells_rebuilt`, `labor_signal_cells_rebuilt`,
  `input_reserve_groups_rebuilt`, `full_rebuild_reason`. Structure merge marks
  only released/new cells dirty; configure/save restore force full rebuild.
  After market-signal CSR remap, clean cells keep remapped reserve lanes and
  only dirty cells recompute group contributions.
- Bridge publish contract: incomplete slices force `published_to_slot=false`;
  resource MapData mirror and CSV capture remain committed-epoch-only;
  runtime-graph keeps the last economy report until `done`/`fatal`;
  `EconomyDailySystem` skips natural-resource catchup when the runtime graph
  owns the day.
- Soak gate: `runtime_economy_authority_soak_test.gd` defaults to 60 days
  (`PK_ECONOMY_SOAK_DAYS`) and asserts conservation fields when present.
- Release benchmark matrix: `tools/runtime/Invoke-EconomyPhase1Bench.ps1`
  (smoke 30×20 / standard 60×40 / hotloop 96×64 / large 150×100).
  `verify_economy_runtime.ps1 -Godot` includes soak/pod/parity;
  `-Phase1Gate` also runs the bench matrix (`-BenchMatrix smoke|standard|full`).

## Phase-2.1 landed (Ledger Mirror v2 / ECP ABI5)

- `RuntimeEconomyLedgerState` extended with `cohort_generation`,
  `market_last_shortage_q16`, `market_cell_to_market`.
- Capture / import / export / hash / `valid()` all-or-nothing for extended columns.
- ECP1 encode writes **ABI5** when extended columns are present; restore accepts
  ABI 1–5. ABI4 remains readable with empty extended columns.
- Report fields: `economy_pod_mirror_feature_mask`,
  `economy_pod_committed_ledger_abi`, `economy_pod_active_ready`.
- `switch_economy_authority(POD_ACTIVE)` still refused via
  `pod_active_ready()` (required mask includes building/trade/family/resource/
  cursor features not yet mirrored).

## Phase-2.2 landed (diagnostics + BUILDING_COMMIT mutate)

- ABI6 ledger columns: `cohort_reserved`, `cohort_reservation_owner`,
  `cohort_needs_satisfaction`, `cohort_composite_satisfaction`,
  `cohort_owner_employed`, `cohort_employee_employed`.
- Mirror mask now sets `RESERVATIONS` + `POPULATION_DIAGNOSTICS` when ABI6
  columns are present (`ECONOMY_POD_MIRROR_PHASE22`).
- `NativeEconomyRuntime::run_building_commit_slice` drives the existing
  BUILDING_COMMIT phase machine; StageOps `mutate=true` no longer no-ops that
  stage. Production ACTIVE still attaches `mutate=false` and uses compact-slice.

## Phase-2.3.1 landed (building + trade-escrow opaque mirror / ECP ABI7)

- `RuntimeEconomyBuildingCommittedBlock` + `RuntimeEconomyTradeEscrowCommittedBlock`
  on ledger and owned state: metadata + PKEC-shaped opaque `payload` blobs.
- Legacy `capture_committed_ledger_state` fills both blocks all-or-nothing.
- ECP1 encode writes **ABI7** when both blocks are captured; restore accepts
  ABI 1–7. ABI6 remains writable when building/trade are absent.
- Mirror mask sets `BUILDING` + `TRADE_ESCROW` (`ECONOMY_POD_MIRROR_PHASE23`).
- Payloads are committed mirrors only — not unpacked into live POD SoA writers.
- `POD_ACTIVE` still refused: family / resource / epoch-cursor features missing.

## Phase-2.3.2 landed (family opaque mirror / ECP ABI8)

- `RuntimeEconomyFamilyCommittedBlock` on ledger and owned state: catalog hashes,
  counts, and PKEC-shaped opaque payload covering family records, membership,
  ownership, persons, person needs, traits, influences, trait commands, and
  expeditions (route/cargo/kit/missing nested).
- Legacy `capture_committed_ledger_state` fills family after building/trade.
- ECP1 encode writes **ABI8** when family is captured (requires ABI7 pair);
  restore accepts ABI 1–8. ABI7 remains writable when family is absent.
- Mirror mask sets `FAMILY` (`ECONOMY_POD_MIRROR_PHASE232`).
- `POD_ACTIVE` still refused: resource / epoch-cursor features missing.

## Phase-2.3.3 landed (resource + epoch-cursor / ECP ABI9)

- `RuntimeEconomyResourceCommittedBlock`: catalog/environment hashes, context day,
  policy ints, opaque dense `_resource_snapshot` + `_cell_resource_gen`.
- `RuntimeEconomyEpochCursorCommittedBlock`: day/epoch ids, idle stage markers,
  graph completed mask, idle payload marker (mid-epoch resume deferred).
- Capture fills both all-or-nothing after family; ECP1 writes **ABI9**.
- Mirror mask reaches `ECONOMY_POD_MIRROR_PHASE233` == `REQUIRED_FOR_ACTIVE`.
- `pod_active_ready()` can be true; Host may accept `switch_economy_authority(
  POD_ACTIVE)` but production ACTIVE path still uses compact-slice until P2.4.

## Phase-2.4.1 landed (opt-in arming / observability)

- Config / report: `economy_stage_ops_mutate`, `economy_auto_pod_active`,
  `economy_production_writer` (always `compact_slice` in this slice).
- `economy_stage_ops_mutate=true` arms StageOps mutate for handoff experiments;
  `ACTIVE_WITH_PARITY` coerces mutate back to false so the SHADOW probe cannot
  double-write beside compact-slice.
- `economy_auto_pod_active=true` promotes authority to `POD_ACTIVE` after a
  complete ledger capture when `pod_active_ready()`. Default remains false.
- Production ACTIVE day loop is unchanged: still
  `attach_economy_production_runtime` + `worker_run_compact_slice`.

## Phase-2.4.2 landed (writer flag + fail-closed gates)

- Config: `economy_production_writer` = `compact_slice` (default) | `stage_ops`.
- Report: `economy_production_writer` / `_requested` / `_effective` (effective is
  always `compact_slice` in this slice).
- Fail-closed start refusals:
  - `stage_ops` + `ACTIVE_WITH_PARITY` → `economy_production_writer_parity_conflict`
  - `stage_ops` without mutate → `economy_production_writer_requires_mutate`
  - otherwise `stage_ops` → `economy_production_writer_stage_ops_not_ready`
- ACTIVE day loop asserts effective writer is `COMPACT_SLICE`; StageOps is never
  invoked as the production writer yet.

## Phase-2.4.3.1 landed (BUILDING_COMMIT shared phase driver)

- Extracted `advance_building_commit_chunk` from the compact-slice BUILDING_COMMIT
  7-phase machine; production `run_slice_internal` calls the same driver with
  budget/chunk yield policy.
- `run_building_commit_slice` (StageOps mutate) drains that driver until leaving
  `BUILDING_COMMIT` — **no** `run_slice_compact` re-entry (no FISCAL/FAMILY
  overshoot inside one BUILDING_COMMIT advance).
- `economy_production_writer=stage_ops` remains fail-closed (`not_ready`).

## Phase-2.4.3.2 landed (FISCAL bridge after BUILDING_COMMIT StageOps)

- `run_fiscal_settlement_drain`: StageOps-only drain of `advance_fiscal_settlement`
  until settled, then `_stage = FAMILY_COMMIT` (graph has no FISCAL stage).
- Called from `run_building_commit_slice` after BUILDING phase drain succeeds.
- Peer pending (`fiscal_settlement_peer_pending`) is **fail-closed** (compact
  yields; StageOps cannot park mid-graph-stage).
- `run_family_commit_slice` refuses `_stage == FISCAL_SETTLEMENT` with
  `family_commit_fiscal_unsettled`.
- `economy_production_writer=stage_ops` remains fail-closed.

## Phase-2.4.3.3 landed (FAMILY/PERSON/PUBLISH StageOps drain)

- `run_family_commit_drain` / `run_person_commit_drain` /
  `run_aggregate_publish_drain`: StageOps mutate drains until stage exit
  (compact path still uses single `*_slice` calls with budget yield).
- `economy_graph_stage_dispatch` routes FAMILY/PERSON/AGGREGATE_PUBLISH to
  these drains.
- Fail-closed stage guards: `person_commit_prior_incomplete`,
  `aggregate_publish_prior_incomplete`.
- `economy_production_writer=stage_ops` remains fail-closed until bounded Host
  day-loop handoff (P2.4.4).

## Phase-2.4.4.1 landed (epoch-open prelude + readiness checklist)

- `run_epoch_open_prelude_drain`: StageOps epoch-open prelude covering country
  asset peer, fiscal reservation continuation, trade planner, and `start_epoch`
  (same leaf helpers as compact idle-open; `pending_input` / idle-day parks).
- SHADOW mutate path calls prelude before `plan_epoch` when mutate is armed.
- Report / refuse: `economy_stage_ops_readiness_mask` (PRELUDE|COMMIT_DRAINS =
  `0x3`), `economy_stage_ops_prelude_ready`, refuse also returns
  `economy_stage_ops_readiness_missing` (`0xC` = bounded kernels | host loop).
- `economy_production_writer=stage_ops` remains fail-closed.

## Phase-2.4.4.2 landed (Host StageOps day-loop API)

- `NativeSimulationHost::worker_run_stage_ops_slice`: prelude → plan_epoch →
  one graph `advance_stage` per pulse → `commit_epoch`, with Host 64-slice
  budget and `pending_input` park (mirrors compact Host loop shape).
- ACTIVE ECONOMY branch calls StageOps day loop when effective writer is
  `STAGE_OPS` (start still refuses enablement).
- Readiness mask now `0xB` (PRELUDE|COMMIT_DRAINS|HOST_LOOP); missing `0x4`
  (`BOUNDED_KERNELS`) still blocks `stage_ops` writer.

## Phase-2.4.4.3 landed (bounded mid-graph StageOps drains)

- `run_building_employment_drain` / `run_building_production_drain` /
  `run_household_market_drain`: StageOps mutate completes each mid-graph stage
  via cursor + slice caps (no unbounded all-cell for-loop; no
  `run_slice_compact` re-entry).
- `advance_household_market_chunk`: shared HOUSEHOLD phase driver; compact
  calls it with yield enabled, StageOps drain calls with yield disabled.
- `economy_graph_stage_dispatch` routes EMPLOYMENT / PRODUCTION / HOUSEHOLD to
  these drains (retires incomplete household boundary kernel path).
- Readiness mask `0xF` (PRELUDE|COMMIT_DRAINS|BOUNDED_KERNELS|HOST_LOOP);
  `economy_stage_ops_readiness_missing=0`.
- `economy_production_writer=stage_ops` still refused:
  `economy_production_writer_stage_ops_soak_pending`.

## Phase-2.4.4.4 landed (early/late drains + soak experiment latch)

- `run_ledger_apply_drain` / `run_government_research_drain` /
  `run_structural_commit_drain`: StageOps mutate completes these stages in one
  Host `advance_stage` pulse (cursor + slice caps; research peer pending is
  fail-closed).
- Config / report: `economy_stage_ops_soak_experiment`,
  `economy_stage_ops_soak_parity_ok` (default false).
- `economy_production_writer=stage_ops` is allowed only when soak experiment or
  soak_parity_ok is armed; effective writer then becomes `stage_ops`. Default
  path still refuses with `soak_pending`.
- Dual-path compact↔StageOps multi-day `state_hash` soak that latches
  `soak_parity_ok` remains open before default writer handoff.

## Still open before production POD_ACTIVE

`RuntimeEconomyLedgerState` currently carries committed cohort
active/cell/slot/signature/population/funds/income/expense columns plus market
stock/price/demand EMA. The cell and slot columns preserve the exact page index,
allocated/free page identity, and stable per-cell page chain. Import validates
that every slot is sequential, every active byte is 0 or 1, every page has one
uniform cell, and no active cohort occupies a free page. Restore builds a
temporary `RuntimeEconomyOwnedState` and swaps it into the authority only after
shape, topology, and ledger-hash validation succeeds.

`RuntimeEconomyMarketStore` defines the live market columns outside
`NativeEconomyRuntime`, including shortage ratios, cell-to-market mapping and
sparse price ceilings. `NativeEconomyRuntime::MarketStore` is a type alias and
the existing runtime still owns the production instance. Likewise,
`RuntimeEconomyPopulationStore` owns the complete population column layout and
page/slot/reservation/handle operations in Godot-free source files, while the
legacy runtime still owns the production instance through an alias. These type
extractions add no second writer.

The committed feature mask for `pod_active_ready` is complete after Phase-2.3.3
(ECP ABI5–ABI9). Opaque blobs are still not unpacked into live POD SoA writers.
Phase-2.4.1 only arms StageOps mutate / auto-`POD_ACTIVE` behind flags;
StageOps is still not the production day loop. Production therefore remains on
legacy compact-slice until a later Phase-2.4 handoff.
Its hash covers the mirrored ledger columns and metadata only; it is not the
full PKEC state hash. Capture and import still perform full column copies at
each completed generation, so no performance improvement is claimed for this
migration step.

ECP1 ABI4 serializes the committed mirror after the ABI3 authority mode and ABI2
business summaries. The ledger block carries its own source hash, ledger hash,
generation and committed day rather than borrowing the graph snapshot counters.
ABI1 has no business summaries, ABI2 adds summaries, and ABI3 adds authority
mode. Restoring ABI1-3 explicitly clears any pre-existing ABI4 ledger and owned
state. Any failed ABI4 restore leaves the prior committed snapshot, summaries,
receipts, owned state and exported ledger unchanged.

The existing `submit_economy_commands` facade remains enabled. POD command
admission and terminal receipts are migration scaffolding; the worker ownership
flag alone cannot disable the legacy ingress before a complete replacement is
connected.

Validation completed on 2026-09-14 (Phase-1 closeout):

- debug GDExtension build;
- `runtime_economy_pod_test.gd` / `runtime_economy_parity_test.gd`;
- `runtime_economy_authority_soak_test.gd` (default 60 days);
- `economy_cadence_runtime_test.gd`: PASS, including PKEC/PKCN roundtrip;
- `goods_storage_schema_test.gd`: 226 checks, 0 failures;
- release bench matrix via `Invoke-EconomyPhase1Bench.ps1`.

Phase-1 production-path de-dupe is complete. Phase-2.1–2.3.3 thickened the
committed ledger mirror (ECP ABI5–ABI9) through `pod_active_ready` feature
completeness, and wired BUILDING_COMMIT StageOps mutate. Phase-2.4.1–2.4.4.2 add
opt-in StageOps mutate arming, auto-`POD_ACTIVE`, fail-closed `stage_ops`
writer gate, commit-stage drains, epoch-open prelude, and Host StageOps day-loop
API, Phase-2.4.4.3 adds bounded mid-graph drains (`0xF`), and Phase-2.4.4.4
adds LEDGER/RESEARCH/STRUCTURAL drains plus an opt-in soak experiment latch.
Remaining work before default production handoff: latch
`economy_stage_ops_soak_parity_ok` via dual-path soak, then enable StageOps as
default effective writer, disable legacy ingress, and allow default
`POD_ACTIVE`.
