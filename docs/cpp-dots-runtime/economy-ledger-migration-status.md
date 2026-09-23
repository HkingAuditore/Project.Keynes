# Economy Ledger Migration Status

> 2026-09-19 correction: the terminal-closeout description below records the
> intended/previous default. Player config now enables automatic POD_ACTIVE again.
> Worker boundary switching and immutable Economy day inputs are implemented.
> A 90-second explicit-enable soak reports `stage_ops`, `owned_state`, one switch,
> zero worker faults and 44.98 committed days/second (strict 49 gate still fails).
> Default-config repeat: 36.25 days/second, max gap 1073.629ms, zero faults;
> throughput is not yet stable and both strict gates fail on that repeat.
> See [the design audit](authority-design-audit-20260919.md); 50x is not passed.

As of 2026-09-15 (**A+Y Terminal Closeout landed**), production default writer
is `economy_production_writer=stage_ops` and `economy_auto_pod_active=true`.
Under `POD_ACTIVE`, opcodes 1–23 mutate `RuntimeEconomyOwnedState` first
(heavy opcodes delegate then mirror). Host binds NER stores to OwnedState
(`economy_formula_backing=owned_state`). Building groups and pending
construction are sole on `RuntimeEconomyBuildingStore` with no AoS scratch
(N2 / N8); trade/family live tables are owned by `RuntimeEconomyOwnedState`
(`live_trade_orders` / `live_families`) when bound; resource stock lanes plus
the epoch harvest scratch live on `owned.resources` (N5 / N9); and bound
 day-end publishes the committed mirror from OwnedState in place instead of
 re-importing it (N10). ECP2 is now the typed capture/restore boundary for
 Economy authority; PKEC v52 remains a compatibility decoder/writer until the
 production cutover gate and long soak are closed. ECP1 ABI9 remains a
 committed mirror only.

## ECP2 / mid-epoch（working path landed）

- **Landed:** `runtime_economy_ecp2.{h,cpp}` wire (ABI 1, schema 52, marker
  `ECP2`); typed envelope + PKEC section→`ECP2_DOMAIN_*` opaque remapping
  (HEADER chunks preserved under envelope); Resource dense stock as
  `ECP2_DOMAIN_RESOURCE`; `capture_ecp2_authority` / `apply_ecp2_authority`;
  PodAuthority `encode_ecp2` / `restore_ecp2`; PKSR
  `RUNTIME_SAVE_SECTION_ECONOMY_ECP2`; Host dual-write
  (`economy_ecp2_dual_write`, default true); restore prefers ECP2 when CORE
  domains present; E10 cutover flag `economy_ecp2_authority` (default false →
  skip ECP1 when FULL_AUTHORITY); mid-epoch
  `economy_ecp2_mid_epoch_save` (default false) + `ECP2_DOMAIN_EPOCH_RESUME`
  with stage/cursors/trade-plan/peer-wait apply; self_test covers envelope,
  opaque domain, HEADER chunk, resume roundtrip.
- **M2 implementation:** ECP2 now carries a canonical independent `OwnedState` SoA
  block (`OSOA` v1) for population/market/building/trade/family/resource typed
  lanes. Capture requires a valid block; restore rejects missing, duplicate,
  malformed, or hash-tampered blocks before mutating live state. Mid-epoch
  capture includes the typed resume cursor and the fixture verifies restore to
  a later commit. Debug and release builds both pass the focused Economy
  cadence/POD/parity tests. PKEC v52 remains an explicitly retained
  compatibility decoder and writer during the migration window.
- **M2 release gates still open:** switch the public save coordinator to ECP2
  only, complete the 60/730/3650-day mid-epoch soak and daily hash continuity,
  then remove the compatibility writer. These gates are deliberately separate
  from the typed ECP2 implementation and are not claimed as complete here.

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
  Host `advance_stage` pulse (cursor + slice caps).
- **2026-09-22 correction:** `run_government_research_drain` now drains the
  already-sealed research purchase continuation through its durable phases
  before returning the StageOps stage result. The compact path may still yield
  between phases, but StageOps must not convert that normal continuation into
  `government_research_peer_pending`/`fatal`; the prior behavior left the
  production epoch frozen at the next day boundary.
- Config / report: `economy_stage_ops_soak_experiment`,
  `economy_stage_ops_soak_parity_ok` (default false).
- `economy_production_writer=stage_ops` is allowed only when soak experiment or
  soak_parity_ok is armed; effective writer then becomes `stage_ops`. Default
  path still refuses with `soak_pending`.
- Dual-path compact↔StageOps multi-day `state_hash` soak that latches
  `soak_parity_ok` remains open before default writer handoff.

## Still open (out of Terminal Closeout scope)

Explicitly **not** in A+Y Terminal Closeout:

- **ECP2** replacing PKEC as the full-authority save.
- **Mid-epoch resume** blob on the epoch-cursor store.

## A+Y Terminal Closeout — gap inventory (N0)

Frozen checklist for sole-writer completion beyond pop/market. Tick IDs as stages land.

### GAP-B1 Building (NER AoS vs Owned SoA)

**AoS-only columns** (must enter `RuntimeEconomyBuildingStore` or explicit sidecar):
`employee_fill_begin` (live uses `role_begin`), `last_input_selection_begin`,
`last_maintenance_cost`, `sample_unit_input_cost`, `sample_unit_maintenance_cost`,
`recovery_cooldown_cycles` (capture historically wrote `recovery_cooldown_compat=0`),
`modifier_handle`, `output_factor_q16`. Pending lived in `_pending_construction`
(closed by N8: the store's `pending_*` columns are now sole);
role fills in `_building_employee_*` parallel vectors.

**Hot write sites**: `prepare_building_economic_plan_body`;
`run_building_production_cell` / `prepare_group_climate_capacity`;
`run_building_employment_cell` / `prepare_cell_wages` / reconcile;
`commit_ready_construction`; `apply_demolish_command`; `review_recovery_building_group`;
`finalize_household_building_cell`; `run_building_commit_slice`;
`refresh_building_modifier_factors`; investment/storage rebuild.

**Declared helpers** (were header-only): `sync_owned_building_store`,
`apply_owned_building_store`, `fill_ledger_building_from_store`.

### GAP-T1–T3 Trade

- Live authority: `trade_orders_store()` (settle/dispatch). Superseded by N3+N4:
  the live table now lives on `RuntimeEconomyOwnedState::live_trade_orders`
  while bound; `_trade_orders_local` is only the unbound fallback.
- Owned: `RuntimeEconomyTradeEscrowStore` mirror from capture; **no** arrival buckets.
- Arrival buckets: derived cache on NER only (`rebuild_trade_arrival_buckets`).
- Dispatch does not mutate `view.trade_orders`.

### GAP-F1–F2 Family

- Live authority: `families_store()` + persons/membership/ownership/influences.
  Superseded by N3+N4 (family identity table) and the family side-table move
  below: persons, membership/ownership edges, expeditions, influences, traits
  and person needs now live on `RuntimeEconomyOwnedState` while bound. Only the
  derived CSR rebuild caches over those rows stay on NER.
- Owned flat `RuntimeEconomyFamilyStore` is capture/ECP projection.
- Command path may push flags/purchase_factor into NER; commit/buff write NER.

### GAP-R1–R3 Resource (N5 + N9 landed)

- Live stock lanes: `resource_stock_lanes()` → `_resource_snapshot` when unbound,
  `OwnedState.resources.stock` when `bind_resource_store` is active.
- Epoch shadow columns (remaining / harvest / deltas / lane generation) moved to
  `OwnedState.resources` in N9 and are reached through accessors that mirror
  `resource_stock_lanes()`; the NER locals are the unbound fallback only.
- Owned `RuntimeEconomyResourceStore` is the ECP/capture projection via
  `sync_owned_resource_store` / `flush_formula_owned_domain_mirrors`.

### GAP-D1–D2 / C1–C2 / CAP1 Dispatch & capture

- `EconomySoAView` store pointers often dead (dispatch uses `runtime_hook` only).
- `bind_formula_owned_state` initially moved only pop/market.
- Heavy commands: NER apply + `capture_owned_mirror_stores`.
- Day-end Host still called `NER::capture_committed_ledger_state` → POD import
  (closed by N10: bound day-end publishes the Owned mirror in place).

Migration order: N1 building SoA+bind → N2 hotpath → N3 trade → N4 family →
N5 resource+identity export → N6 dispatch cleanup → N7 gates/docs →
N8 pending SoA → N9 resource epoch scratch → N10 Owned identity export.

### N1 landed (building SoA + bind + sync/apply)

- `buildings_store()` aliases `RuntimeEconomyOwnedState::buildings` when
  `formula_owned_bound()`; otherwise `_buildings_soa_local`.
- `sync_owned_building_store` / `apply_owned_building_store` /
  `fill_ledger_building_from_store` implemented (AoS scratch ↔ Owned SoA).
- `bind_formula_owned_state` seeds Owned building columns from live AoS at bind.

### N2 landed (building group SoA is sole storage — `_buildings` deleted)

**Authority model:** `std::vector<BuildingGroup> _buildings` **no longer exists**.
`buildings_store()` (OwnedState::buildings when `formula_owned_bound()`, else
`_buildings_soa_local`) is the single live storage for every group column. The
`BuildingGroup` struct survives only as a POD used for temporary row copies
(persistence load, structural append, synthetic quote rows).

**Access shape** (`economy_runtime.h`):

- `PK_BUILDING_GROUP_COLUMNS(X)` is the single field↔column mapping macro.
- `BuildingGroupRefT<Const>` is a reference proxy that binds one row's columns;
  `BuildingGroupRef` / `BuildingGroupConstRef` are the mutable/const aliases.
  `g.count`, `g.cell`, `g.employee_fill_begin`, … keep working as lvalues, so
  hot loops read and write SoA directly with no AoS row in between.
- `building_count()`, `building_at(i)`, `append_building_group(const BuildingGroup&)`,
  `write_building_group(i, const BuildingGroup&)`, `building_group_copy(i)`,
  `permute_building_group_columns(order)`, `clear_building_groups()`,
  `reserve_building_groups(n)` are the only structural entry points.
- `employee_fill_begin` is now a first-class store column (wire-loaded rows
  reset it to `-1` so `rebuild_building_role_storage` re-allocates the span).

**Role CSR safety:** role lanes stay in the sparse `_building_employee_*`
vectors, keyed by `employee_fill_begin` / `last_input_selection_begin`.
`rebuild_building_role_storage` now permutes the group columns *first*, then
allocates spans for new rows through their final index, so packed role data is
never assigned over sparse lanes without begins. `refresh_building_store_role_lanes()`
repacks `store.role_*` for export/capture only.

**Dispatch:** the materialize→drain→sync AoS sandwich is gone from
`economy_graph_stage_dispatch.cpp` (`materialize_buildings_if_formula_bound` /
`sync_buildings_if_formula_bound` removed). Drains mutate SoA in place.
`apply_owned_building_store` and `assert_buildings_soa_matches_scratch` are
deleted; `sync_owned_building_store` only refreshes the packed role/pending
projections and copies when the destination is a foreign store.

**GAP-B tick:**

| ID | N2 status |
|----|-----------|
| GAP-B1 AoS-only columns in store | **Done** — every `BuildingGroup` field is a store column |
| GAP-B1 hot write sites | **Done** — drains write `buildings_store()` through `building_at()` |
| GAP-B1 declared helpers | **Done** — `apply_*` removed; `sync_*`/`fill_ledger_building_from_store` remain |
| GAP-D1 dispatch materialize/sync | **Done** — sandwich removed entirely |
| GAP-D2 capture path | **Done** — capture reads `buildings_store()` (no AoS source) |

### N3 landed (trade escrow sole live store)

- `trade_orders_store()` accessor exposes the sole live `TradeOrderStore`;
  settle/dispatch never mutates `EconomySoAView::trade_orders` pointers.
- `flush_formula_owned_domain_mirrors` / `sync_owned_trade_escrow_store` pack
  live escrow into `RuntimeEconomyOwnedState::trade_orders` at stage boundaries
  and day-end capture.
- Arrival buckets are derived cache only (`rebuild_trade_arrival_buckets`) —
  no second live CSR.
- ECP `RuntimeEconomyTradeEscrowStore` is the committed/projection mirror.

### N4 landed (family store projection)

- `families_store()` accessor exposes the sole live `FamilyStore`
  (persons/membership/ownership/influences followed it onto Owned later; see
  the family side-table section below).
- Flat `RuntimeEconomyFamilyStore` on OwnedState is the ECP projection filled
  via `sync_owned_family_store` / `flush_formula_owned_domain_mirrors`; command
  commit paths may push flags/purchase_factor into the live table, then flush
  mirrors Owned for capture.
- No second live family SoA under `POD_ACTIVE`.

### N3+N4 completion (live tables owned by `RuntimeEconomyOwnedState`)

- `TradeOrderStore` / `FamilyStore` are no longer nested in
  `NativeEconomyRuntime`. They are freestanding `pk::EconomyTradeOrderStore` /
  `pk::EconomyFamilyStore` in `runtime_economy_live_tables.h/.cpp`; the nested
  names survive as `using` aliases so existing call sites are unchanged.
- `RuntimeEconomyOwnedState` owns the live instances as `live_trade_orders` /
  `live_families`. The flat `trade_orders` / `families` fields stay as the ECP
  wire projections.
- `trade_orders_store()` / `families_store()` are inline accessors that return
  the OwnedState instance when `_formula_owned != nullptr`, else the NER-local
  fallback `_trade_orders_local` / `_families_local` — identical to the
  `population_store()` / `market_store()` pattern.
- `bind_formula_owned_state` moves both live tables into OwnedState *before*
  packing the ECP projections, so `sync_owned_trade_escrow_store` /
  `sync_owned_family_store` already read the new home.
  `unbind_formula_owned_state` moves them back and clears the OwnedState copies.
- Arrival buckets travel with the live `TradeOrderStore` and remain a derived
  cache excluded from wire/hash authority.
- At N3+N4 only the family identity table moved. The family side tables
  followed later (see below).

### Family side tables on Owned (code tag `A+Y N5`)

Follow-up to N3+N4, applying the exact `live_families` pattern to the rest of
the notable-family data. Note the `A+Y N5` tag in the source comments collides
with the resource phase also called N5; the two are unrelated.

- `NotablePersonStore`, `PersonNeedState`, `FamilyMembershipEdge`,
  `FamilyBuildingOwnership`, `FamilyTraitRoll`, `FamilyCellInfluenceStore`,
  `FamilyExpeditionStore` and the expedition payload/cargo/kit structs are no
  longer nested in `NativeEconomyRuntime`. They are freestanding `pk::Economy*`
  types in `runtime_economy_family_side_tables.h`; the nested names survive as
  `using` aliases so call sites are unchanged.
- `RuntimeEconomyOwnedState` owns the live instances as `live_persons`,
  `live_memberships`, `live_ownerships`, `live_expeditions` (+ the route/
  payload/person-handle/cargo/kit/missing-good CSR vectors), `live_influences`,
  `live_traits` and `live_person_needs`.
- `persons_store()`, `family_memberships()`, `family_ownerships()`,
  `family_expeditions_store()`, `family_expedition_*()`, `family_influences()`,
  `family_trait_rolls()` and `person_needs()` return the OwnedState instance
  when `_formula_owned != nullptr`, else the `_*_local` fallback.
- `bind_formula_owned_state` moves all of them into OwnedState in the same bind
  as `live_families`, before the ECP projections are packed, so
  `sync_owned_family_store` already reads the new home.
  `unbind_formula_owned_state` moves them back and clears the Owned copies.
- Derived CSR rebuild caches (`_family_member_offsets`,
  `_person_family_offsets`, `_person_need_offsets`, `_family_cell_offsets`,
  `_family_expedition_target_index`, `_family_expedition_due_heap`) stay
  NER-local: they are recomputed from the authoritative rows at
  FAMILY_COMMIT / PERSON_COMMIT and after a structural restore, so they carry
  no authority and survive bind/unbind unchanged.
- The flat `RuntimeEconomyFamilyStore` remains the wire-facing ECP projection.

### N5 landed (resource sole stock lanes)

- Mutable `resource_stock_lanes()` / const overload: returns
  `_resource_store_alias->stock` when bound, else `_resource_snapshot`.
- `bind_formula_owned_state`: moves live `_resource_snapshot` into
  `owned.resources.stock` (sets `resource_count`/`cell_count`/`cell_generation`),
  then `bind_resource_store(&owned.resources)`; local snapshot empty while bound.
- `unbind_formula_owned_state`: moves `owned.resources.stock` back into
  `_resource_snapshot` and clears the alias.
- Hot-path reads in `available_resource_amount`, `ensure_resource_lane`,
  `consume_resource_amount`, `carrying_resource_stock`, epoch lane resize,
  publish abundance, colonization identity export, and `sync_owned_resource_store`
  use `resource_stock_lanes()` — no second live stock vector under bind.
- Host calls `flush_formula_owned_domain_mirrors()` before day-end
  `capture_committed_ledger_state` when formula-bound (resource identity
  export). Superseded by N10: the bound day-end now flushes and then
  republishes the Owned mirror instead of capturing through NER.

## Phase-3 landed (OwnedState-first opcodes 1–23)

- `is_owned_core_opcode` covers COMMAND opcodes 1–23 under `POD_ACTIVE`.
- Light opcodes mutate OwnedState SoA first (pop/market/building units/family
  flags/purchase factor/structural queue); heavy opcodes (build/expedition/
  canal/family ledger gifts) delegate via `pull_owned_command_result` then
  mirror stores back into OwnedState.
- Host executor never takes a NER-only success path under `POD_ACTIVE`.
- Post-command path verifies ledger hash/shape (`economy_pod_command_verify_count`);
  under `formula_owned_bound()` mismatch **faults** (no silent recapture);
  legacy unbound path may still recapture (`economy_pod_command_recapture_count`).

## Phase-4 landed (layout unify — pop/market sole instance + mirrors)

- Population/market: same SoA type; under `POD_ACTIVE` a single instance lives
  in `RuntimeEconomyOwnedState` (see Phase-5 bind).
- Building: Owned SoA sole storage, no AoS scratch (N1–N2). Trade/family: live
  tables on Owned when bound (`live_trade_orders` / `live_families`) plus Owned
  flat ECP projections (N3–N4). Resource: stock lanes on Owned when bound (N5).
  Trade arrival buckets remain derived.

## Phase-5 landed (kernels bind OwnedState)

- `NativeEconomyRuntime::bind_formula_owned_state` aliases
  `population_store()` / `market_store()` / `buildings_store()` /
  `resource_stock_lanes()` to OwnedState; seeds trade/family projections.
- Host `switch_economy_authority(POD_ACTIVE)` binds after `pod_active_ready()`.
- `EconomySoAView` exposes population/market/building/trade/family/resource
  pointers plus `owned_state`.
- Report field `economy_formula_backing` = `owned_state` | `ner_local`.

## Phase-6 landed (PKEC from OwnedState)

- Persistence encode/decode paths use `population_store()` / `market_store()`,
  which under bind are OwnedState columns (no second pop/market SoA).
- PKEC v52 remains the full-authority save; ECP1 ABI9 stays committed mirror.
- Command pull is identity for core columns when formula-bound.

### N6 landed (dispatch SoAView + recapture cleanup)

- `economy_dispatch_mutate_stage(EconomySoAView &view, …)`; bound mutate requires
  `view.population` / `market` / `buildings` non-null.
- Host: formula-bound command hash mismatch → fault, not silent import.
- `pull_owned_*` same_instance skips pop/market dual memcpy.

### N7 landed (gates / docs freeze)

- Builds: `scons` `template_debug` + `template_release`.
- Conservation suite (Terminal Closeout hard gate):
  - `runtime_economy_pod_test` 8/0
  - `runtime_economy_parity_test` 26/0
  - `runtime_economy_stage_ops_soak_parity_test` 370/0
  - `runtime_economy_authority_soak_test` with `PK_ECONOMY_SOAK_DAYS=60`
- Docs frozen: `economy-ledger-migration-status.md`,
  `economy-save-migration-sop.md`, `native-economy-runtime.md`.
- Full `verify_economy_runtime.ps1 -Godot` also runs `building_runtime_test.gd`,
  which has **pre-existing assertion drift** (same ~40+ FAILs since 2026-08-29 /
  worse on 2026-09-14 HEAD before Terminal Closeout). Not treated as A+Y
  Terminal regression; conservation soak/parity/pod remain the merge gate.
- **Still open only (product scope)**: ECP2, mid-epoch resume.
- Residual engineering debt at N7: `_pending_construction` remained AoS;
  building group AoS scratch was already retired (N2). Closed by N8–N10 below.

### N8 landed (pending construction sole on building SoA)

- `buildings_store().pending_*` is the sole pending-construction storage.
  `std::vector<PendingConstruction> _pending_construction` is deleted and
  `refresh_building_store_pending_lanes()` is gone — there is no projection
  step left, so the store columns are identity, not a mirror.
- `PendingConstruction` survives only as a POD for temporaries: build-command
  staging, PKEC load rows, and construction-completion receipts.
- `PK_PENDING_CONSTRUCTION_COLUMNS` maps every historical field to its column
  and drives `PendingConstructionRefT` (row view, mirrors `BuildingGroupRefT`)
  plus `PendingConstructionLaneT` (indexable range). Call sites keep their
  shape: `for (const auto pending : pending_construction())`.
- Storage helpers in `economy_runtime_building_storage.cpp`:
  `append_pending_construction`, `clear_pending_construction`,
  `reserve_pending_construction`, `pending_construction_copy`,
  `pending_construction_memory_bytes`, and `erase_ready_pending_construction`
  (single in-place stable compaction of all ten columns, replacing the old
  `remove_if` over the AoS in BUILDING_COMMIT).
- `_pending_construction_cell_offsets` / `_cell_indices` CSR is rebuilt from
  `buildings_store().pending_cell` in `economy_runtime_epoch.cpp`.
- `sync_owned_building_store` no longer copies pending: only the packed role
  CSR still needs repacking, and only a foreign destination gets a copy.

### N9 landed (resource epoch scratch on Owned resource store)

- `RuntimeEconomyResourceStore` gains `remaining`, `harvest_remaining`,
  `deltas`, and `lane_generation`, resized and cleared together with `stock`.
- The scratch lanes are deliberately absent from the ABI9 wire,
  `wire_content_hash()`, and `shape_valid()`;
  `fill_ledger_resource_from_store` copies only `resource_count`/`cell_count`/
  `stock`/`cell_generation`, so epoch harvest state is never published into the
  committed mirror.
- `resource_remaining_lanes()` / `resource_harvest_remaining_lanes()` /
  `resource_delta_lanes()` / `resource_lane_generation_lanes()` mirror
  `resource_stock_lanes()`: the bound store's column when
  `bind_resource_store` is active, the NER local otherwise.
- `bind_formula_owned_state` moves all four locals into `owned.resources`
  alongside `stock`; `unbind_formula_owned_state` moves them back. There is no
  second live copy of the epoch harvest bookkeeping under bind.

### N10 landed (day-end Owned identity export)

- When formula-bound, POD `state()` **is** the OwnedState the production
  runtime writes through, so `import_committed_ledger` (which replaces
  `_state`) would break the bind. Day-end and command-verify must not use it.
- New `RuntimeEconomyPodAuthority::publish_owned_committed_mirror(generation,
  committed_day, error)`: requires `state_initialized()`, stamps
  `_state.state_generation` (max) and `_state.committed_day`, exports the
  ledger from the live `_state`, then `capture_committed_ledger_state`. It
  never replaces `_state`, so live pop/market/building storage is untouched.
- Host day-end ledger sync (`native_simulation_host.cpp`): bound path calls
  `flush_formula_owned_domain_mirrors()` then
  `publish_owned_committed_mirror(committed_generation(), current_day())`.
  Unbound path keeps the old NER capture → `import_committed_ledger`.
- `flush_formula_owned_domain_mirrors` now also refreshes the Owned building
  and epoch-cursor committed blocks (`fill_ledger_building_from_store`,
  `fill_ledger_epoch_cursor`), so the republished snapshot is not stale.
- Command-verify path: when bound, flush + republish instead of a NER capture
  compared against itself; `economy_pod_command_verify_count` still advances.
  Unbound keeps export-vs-export comparison.

### N8–N10 gates

- Builds: `scons` `template_debug` + `template_release`, zero errors.
- Conservation suite (all green, `PK_ECONOMY_SOAK_DAYS=60`):
  - `runtime_economy_pod_test` 8/0
  - `runtime_economy_parity_test` 26/0
  - `runtime_economy_stage_ops_soak_parity_test` 370/0
  - `runtime_economy_authority_soak_test` 12/0 at 60 days

## Phase-7 landed (gates / freeze)

- Default production: StageOps writer + auto `POD_ACTIVE` + OwnedState formula
  backing (`economy_formula_backing=owned_state`).
- Soak/parity/pod/`stage_ops` soak remain conservation gates.
- Future optional work only: ECP2, mid-epoch resume.

---

## Historical: open notes before A+Y (superseded)

Committed mirror opaque→SoA unpack is complete (Phase-2.5.x). StageOps is the
default production day writer (Phase-2.4.5). Phase-2.6.1 defaults
`economy_auto_pod_active=true` so authority mode promotes to `POD_ACTIVE` after
the first complete capture when `pod_active_ready()`. Phase-2.6.2 keeps POD
OwnedState aligned after command mutations via post-commit recapture and
refuses silent Committed-without-mutate under `POD_ACTIVE`.

`RuntimeEconomyLedgerState` carries committed cohort
active/cell/slot/signature/population/funds/income/expense columns plus market
stock/price/demand EMA, plus ABI5–ABI9 extensions. Import validates page
topology and ledger hash before swapping into the authority.

`RuntimeEconomyMarketStore` / `RuntimeEconomyPopulationStore` define live column
layouts; under `POD_ACTIVE` they are the sole formula backing via bind.

Legacy `submit_economy_commands` is refuse-closed under the StageOps writer;
POD command admission (opcodes 1..23) + `commit_pending_commands` is the
command ingress. Under `POD_ACTIVE`, opcodes 1–23 apply OwnedState-first then
`pull_owned_command_result`.

## Phase-2.6.3 landed (OwnedState-first core opcodes)

- `RuntimeEconomyPodAuthority::try_apply_owned_core_command` mutates owned
  population funds/income/expense and market stock for opcodes 2–5.
- Host `EconomyPodCommandExecutor` under `POD_ACTIVE` prefers that path when
  owned state is initialized, then
  `NativeEconomyRuntime::pull_owned_core_columns` (plus explicit mint/burn/stock
  audit counters).
- Self-test covers mint/burn/add-stock on OwnedState.

## Phase-2.6.2 landed (command→POD recapture)

- `commit_pending_commands` returns mutation count (executor-applied commits).
- Under `POD_ACTIVE`, missing executor → `RejectedAtExecution`
  (`economy_pod_active_executor_required`); no silent fake-commit.
- Host ACTIVE day loop: after command drain, if mutations > 0 and epoch is
  idle, recapture NER → POD ledger (`economy_pod_command_recapture_failed` on
  failure) and bump `economy_pod_command_recapture_count`.
- Closes the stale-mirror window where commands applied after day-end capture.

## Phase-2.6.1 landed (default auto POD_ACTIVE)

- Default `economy_auto_pod_active=true` on Host start / `WorldRuntimeHost`
  (opt out with `false`).
- After a complete committed ledger capture with `pod_active_ready()`, Host
  promotes authority to `POD_ACTIVE`.
- Production day loop remains StageOps → `NativeEconomyRuntime`; POD_ACTIVE is
  the ECP/command authority mode, not a second formula owner.
- Parity test expects the new default flag.

Validation completed on 2026-09-14 (Phase-1 closeout):

- debug GDExtension build;
- `runtime_economy_pod_test.gd` / `runtime_economy_parity_test.gd`;
- `runtime_economy_authority_soak_test.gd` (default 60 days);
- `economy_cadence_runtime_test.gd`: PASS, including PKEC/PKCN roundtrip;
- `goods_storage_schema_test.gd`: 226 checks, 0 failures;
- release bench matrix via `Invoke-EconomyPhase1Bench.ps1`.

Phase-1 production-path de-dupe is complete. Phase-2.1–2.3.3 thickened the
committed ledger mirror (ECP ABI5–ABI9). Phase-2.4.5 landed StageOps production
handoff. Phase-2.5.x unpacked all committed opaque blobs to live SoA.
Phase-2.6.1 defaults auto `POD_ACTIVE` promotion.

## Phase-2.4.5 landed (StageOps production handoff)

- Dual-path soak: `runtime_economy_stage_ops_soak_parity_test.gd` compares
  `run_economy_slice` vs `run_economy_stage_ops_day` state hashes (default 5d,
  `PK_ECONOMY_SOAK_DAYS` up to 60) and latches `economy_stage_ops_soak_parity_ok`.
- `run_economy_stage_ops_day` captures same-day inputs then drains prelude + all
  graph stages; fiscal reservation/settlement continue multi-country in-drain
  (peer wait only when `pending_request_id != 0`).
- Default `start_runtime_worker`: `economy_production_writer=stage_ops`,
  `economy_stage_ops_mutate=true`, `economy_stage_ops_soak_parity_ok=true`.
- `ACTIVE_WITH_PARITY` coerces writer to `compact_slice` unless stage_ops was
  requested explicitly (explicit combo still `parity_conflict`).
- Legacy `submit_economy_commands` refused with `economy_legacy_ingress_disabled`
  when StageOps writer is effective (WorldExt + NativeEconomyRuntime).
- `WorldRuntimeHost` ACTIVE path sets stage_ops writer unless parity mode.

## Phase-2.5.1 landed (resource opaque → live SoA)

- New `RuntimeEconomyResourceStore`: dense `stock` (resource×cell int64) +
  `cell_generation` (per-cell uint32).
- `RuntimeEconomyResourceCommittedBlock` holds typed `store` instead of opaque
  `payload`; `content_hash` remains the ABI9 wire-byte FNV for compatibility.
- Capture fills typed columns from `_resource_snapshot` / `_cell_resource_gen`.
- Import populates `OwnedState.resources` live SoA view from the block.
- ECP ABI9 encode/restore pack/unpack the same wire layout (old saves load).
- `NativeEconomyRuntime::ResourceStore` alias added; production hot loops still
  use existing `_resource_snapshot` vectors (no second writer).
- Remaining opaque blobs: building, trade-escrow, family, epoch-cursor.

## Phase-2.5.2 landed (building opaque → live SoA)

- New `RuntimeEconomyBuildingStore`: group SoA + CSR role lanes + pending SoA.
- `RuntimeEconomyBuildingCommittedBlock` holds typed `store`; ABI7 wire pack/
  unpack preserves historical layout and `content_hash`.
- Capture fills store from the live group columns / employee role lanes / pending.
- Import populates `OwnedState.buildings` live view.
- Remaining opaque: trade-escrow, family, epoch-cursor.

## Phase-2.5.3 landed (trade-escrow opaque → live SoA)

- New `RuntimeEconomyTradeEscrowStore`: order SoA + CSR line/seller lanes
  (matches production `TradeOrderStore` wire columns; arrival buckets stay
  derived and out of the committed mirror).
- `RuntimeEconomyTradeEscrowCommittedBlock` holds typed `store`; ABI7 wire
  pack/unpack preserves historical per-order nested layout and `content_hash`.
- Capture fills store from `trade_orders_store()` columns.
- Import populates the `OwnedState.trade_orders` ECP projection.
- Remaining opaque: family, epoch-cursor.

## Phase-2.5.4 landed (epoch-cursor opaque → live SoA)

- `RuntimeEconomyEpochCursorStore` holds the committed-day idle marker
  (currently a single `uint8_t`); mid-epoch resume blobs remain future work.
- `RuntimeEconomyEpochCursorCommittedBlock` holds typed `store`; ABI9 wire
  pack/unpack preserves the historical one-byte idle payload and `content_hash`.
- Import populates `OwnedState.epoch_cursors` live view.

## Phase-2.5.5 landed (family opaque → live SoA)

- New `RuntimeEconomyFamilyStore`: family/person/influence/expedition slot SoA
  plus membership/ownership/need/trait/command tables and expedition CSR
  (route/payload/cargo/kit/missing + nested payload person handles).
- `RuntimeEconomyFamilyCommittedBlock` holds typed `store`; ABI8 wire pack/
  unpack preserves historical nested layout and `content_hash`.
- Capture fills store from `families_store()` / `_persons` / memberships /
  ownerships / needs / traits / influences / trait commands / expeditions.
- Import populates the `OwnedState.families` ECP projection.
- **Committed-ledger opaque→SoA unpack is complete** for the current ABI9
  mirror surface. Production formula authority remains
  `NativeEconomyRuntime` via StageOps; Phase-2.6.1 defaults auto `POD_ACTIVE`
  authority-mode promotion (not a second formula owner).
