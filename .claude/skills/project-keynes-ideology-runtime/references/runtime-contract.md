# Project.Keynes Ideology Runtime Contract

## Contents

1. Authority and source map
2. Catalog compilation
3. Commands and daily graph
4. Support, exclusion, and synergy
5. Effect and Modifier boundary
6. Public API and persistence

## 1. Authority and source map

| Concern | Authority |
|---|---|
| Collection, understanding, levels, slots, offers, gates, synergies, command queue | `NativeIdeologyRuntime` |
| Country handle validity, technology bits, research signals | `NativeCountryRuntime` |
| Committed country×class population/funds/owner-employed snapshot | `NativeEconomyRuntime` |
| Transactions, durable external bindings, ACK cursors | `EffectRuntime` |
| UniqueSource Country Modifier instances | `ModifierRuntime` |
| Typed `IDEOLOGY_COMMAND` ingress after Trigger idempotency | `TriggerRuntime` → ideology queue |
| Stable-ID compile and command packing | `IdeologyCatalog`, `IdeologyFacade` |
| Player writes | `PlayerController` |
| Presentation | `country_view_model.gd`, `IdeologyWorkspace` |

Production order:

```text
trigger_runtime (80)
  -> ideology_runtime (82)
  -> effect_runtime (85)
  -> modifier_daily (90)
  -> gameplay_effect (95)
  -> country_daily (255)
  -> economy_daily (260)
```

Ideology never writes Country, Economy, Modifier, Trigger, DataCore, or a
conserved ledger. Economy COMMIT publishes the next class-opinion revision, so
same-day ideology commands consume the previous committed snapshot.

Primary files:

- `gdext/src/ideology_runtime.{h,cpp}`
- `gdext/src/world_ext_ideology.cpp`
- `gdext/src/effect_runtime.{h,cpp}` (`enqueue_external_effect_batch_pod`,
  `retire_external_binding_pod`, PKEF v10 bindings)
- `gdext/src/economy_runtime.h` (`CountryClassOpinionSnapshot`)
- `gdext/src/trigger_runtime.cpp` (`IDEOLOGY_COMMAND = 15`)
- `Project/project-keynes/scripts/ideology/`
- `docs/cpp-dots-runtime/native-ideology-runtime.md`

`configure_effects()` reattaches an already-created ideology authority. Production
startup configures Country/Ideology before Effect; tests may configure either
order. Both must preserve the transaction contract.

## 2. Catalog compilation

`IdeologyCatalog.compile_native_catalog(country_catalog, economy_catalog)`
resolves strings before native configure:

- Sorted ideology IDs, acquisition flags, rarity weights, slot costs, national-
  spirit minimum level, and per-direction support thresholds.
- Level CSR: understanding threshold, daily understanding, persistent Effect
  templates, on-enter Effect templates.
- Requirement CSR: technology, research-signal, and gate dense IDs.
- Sorted political-class IDs from the economy profession-class catalog; sparse
  directional class-stance CSR plus optional critical-class floors.
- Sorted exclusion-group IDs.
- Sorted synergies, requirement rows (`ideology_id`, `minimum_level`,
  `location_mask`), synergy Effect templates, and reverse
  `ideology_id -> synergy_ids` CSR.

Compile-time rejects include duplicate IDs, unknown technology/signal/class
keys, more than 64 levels, non-monotonic thresholds, persistent/synergy rows
that are not reversible Modifier apply (`action=1`, `domain∈[0,3]`,
`opcode=1`, `target_resolver=1`), on-enter templates outside the registered
native adapter shapes, and a worst-case transition command count above
`max_transition_commands`.

`IdeologyProfile` supplies slot capacities (default 6 ideology / 3 spirit),
locked three-card offers, offer cost, starting points, slice limits, and
class-influence weights (`opinion_owner_influence_weight`,
`opinion_funds_per_influence`).

Location masks on synergies: bit 1 accepts equipped ideology, bit 2 accepts
national spirit. Zero or bits outside `{1,2}` fail validation.

## 3. Commands and daily graph

Opcodes:

| Code | Name | Notes |
|---:|---|---|
| 1 | `DISCOVER_IDEOLOGY` | Requires `DISCOVER` acquisition; marks known, stays inactive |
| 2 | `GRANT_IDEOLOGY_POINTS` | Saturating Q16 add; value must be ≥ 0 |
| 3 | `OPEN_IDEOLOGY_OFFER` | Costs `offer_cost_q16`; draws 3 unique weighted cards |
| 4 | `CHOOSE_IDEOLOGY_OFFER` | Rejects stale generation |
| 5 | `EQUIP_IDEOLOGY` | Adopt support + exclusion + ideology slot; ACK-gated |
| 6 | `UNEQUIP_IDEOLOGY` | Repeal support; ACK-gated remove |
| 7 | `PROMOTE_NATIONAL_SPIRIT` | Requires equipped + min level + promote support + spirit slot; irreversible |
| 8 | `ADD_UNDERSTANDING` | Inactive ideas reconcile locally; active ideas may start a level transition |
| 9 | `SET_IDEOLOGY_GATE` | Dense gate bit |

Offer pool: unknown ideas with `DRAW` acquisition whose technology, signal, and
gate requirements currently hold. Fewer than three eligible cards fails with
`ideology_offer_pool_insufficient`. RNG is `splitmix64` seeded from
`handle ^ (catalog_hash + golden-ratio constant)`.

The first command that materializes a country row endows
`starting_points_q16`. An unmaterialized snapshot still reports catalog slot
capacities, offer cost, and starting points with `materialized=false`.

Daily slice order:

1. Poll pending Effect ACKs (`PendingTransitionRef`), bounded by
   `max_transition_polls_per_slice`.
2. Drain due commands from a head cursor. Submit merges a sorted staging batch
   behind that cursor; it must not re-sort history or `erase` from vector head.
3. Visit ideology-ID-sorted `active_state_indices` only. Add that level's
   `daily_understanding_q16` and start the next level transition when the
   threshold is crossed. Growth during an in-flight transition uses the
   previous level.

`done=false` keeps a same-day continuation. Unfinished work must not silently
move to the next calendar day. `ideology_runtime` raises `ideology_day_barrier`
while `!done`. Trigger/Ideology `should_run` must not starve an in-flight
economy epoch; country barrier stays up only for the hard Effect→Modifier
ACK chain during economy catchup.

Receipts are `PENDING` while the producing command's Effect transaction is in
flight, then `SETTLED` or `REJECTED`. Producer/sequence high-water marks make
resubmits idempotent. Settled UI receipt history is not persisted.

## 4. Support, exclusion, and synergy

Class influence per committed snapshot row:

```text
influence = population
          + owner_employed * opinion_owner_influence_weight
          + funds / opinion_funds_per_influence
```

Support:

```text
support_q16 = clamp(Σ(influence_c × stance_c[dir]) / Σ(influence), -1, 1)
allowed = available
        && support_q16 >= threshold_q16
        && blocking_class < 0
```

`blocking_class` is the first authored critical floor (`critical_min_q16 >=
-65536`) whose class has no influence or whose stance is below that floor.
Empty `class_stances` skip the snapshot and allow the command. Snapshot
`class_hash` / `class_count` must match the compiled political-class catalog;
otherwise the gate reports `ideology_class_opinion_unavailable`.

Exclusion groups are mutually exclusive among currently equipped or promoted
ideas. Equip fails when another active idea shares the group.

Synergy activation visits only reverse-CSR candidates after a structural
change. Requirements join on dense ideology ID, minimum level, and location
mask. Active synergy bits are country-local and rebuilt after restore. A
country with synergies rejects a second overlapping structural command with
`ideology_country_transition_pending` so one idea's rollback cannot desync
another idea's synergy batch.

Normalized class influence is cached per country and committed opinion
revision. `class_snapshot_reads` and `support_evaluations` must not grow on a
quiescent daily path. `synergy_candidates_visited` must equal reverse-CSR
candidates, not the synergy catalog size.

## 5. Effect and Modifier boundary

Ideology persistent rows are reversible Modifier commands. A level, equip,
unequip, or inactive-to-spirit transition:

1. Retains previous location/level/generation/binding/synergy bits.
2. Updates displayed intent and slot caches.
3. Syncs or advances the durable `ExternalSourceBinding` before emit.
4. Emits remove/apply/on-enter/synergy commands into a bounded scratch buffer.
5. Submits one atomic `enqueue_external_effect_batch_pod()` transaction.
6. Stores the transaction ID and waits for ACK.

Promotion from equipped ideology to national spirit sets
`remove_previous_persistent=false` and `apply_current_persistent=false`: the
persistent Effect identity continues, ideology slot cost is released, and
on-enter one-shots are not replayed.

Native-owned ideology transactions never enter
`EffectFacade.poll_transactions()`. ACK is observed through
`transaction_status_pod()`. `REJECTED` remains queryable so ideology can roll
back instead of treating an unknown ID as success.

Binding identity is stable per country + ideology + active form (ideology vs
national spirit). Level replacement keeps that identity and advances
generation/signature/program hash. A rejected replacement retires the failed
generation and reactivates the previous binding before clearing the
transition.

Do not register cash, goods, population, or another conserved ledger as an
ideology Modifier stat. Do not write Modifier stores from ideology C++.

## 6. Public API and persistence

Bridge methods live on `DCWorldExt`: `configure_ideologies`,
`submit_ideology_commands`, `poll_ideology_receipts`, `run_ideology_daily`,
`ideology_should_run`, `get_ideology_snapshot`, `explain_ideology`,
`explain_ideologies`, `get_ideology_report`, `capture_ideology_state`,
`restore_ideology_state`, `clear_ideology_state`.

`get_ideology_snapshot()` always returns the same column set, including
`ideology_slots_capacity`, `national_spirit_slots_capacity`, `offer_cost_q16`,
`starting_points_q16`, `materialized`, packed idea columns, offer state,
transition pending bits, binding verification, and transaction IDs.

`explain_ideologies()` returns packed support, threshold, blocker,
class-contribution, eligibility, and hypothetical synergy columns for all
visible ideas in one native call. UI reuses that batch while support revision
and structural snapshot signature are unchanged. Do not call `explain_ideology`
once per row from the panel.

PKID magic is `0x44494b50` (`PKID`). Current writer/reader is schema v3.
Schema v1 restores only when every idea is inactive. A save without PKID
migrates to empty ideology state. A present PKID must match catalog hash and
payload; truncation and unknown pending transactions fail closed.

Persist:

- known/gate bitsets, sparse idea rows, entered-level bits
- points, offer, RNG, draw sequence
- producer high-water marks (v3)
- queued commands from the head cursor
- pending Effect transaction IDs
- durable binding id/generation/signature/program hash
- in-flight transition previous-state and changed synergy bits

Do not persist:

- `active_state_indices`, pending-transition index, slot-used caches
- normalized class influence or the Economy opinion snapshot
- settled UI receipts, reports, or continuation cursors

Restore order is PKTR → PKEF → PKID. After restore, rebuild derived indices and
verify every active idea against PKEF v10 `ExternalSourceBinding`. Every PKID
pending transition ID must still be a pending PKEF transaction with the matching
country/ideology source; PKEF may not contain an extra pending ideology
transaction omitted by PKID.

## 7. Derived cell layer (permanent cell cards)

Permanent, stateless cell effects do **not** create per-cell Effect instances. They
contribute to a read-only derived layer inside `ModifierRuntime`. This section is the
contract; the reasoning lives in `docs/plans/ideology-review/22-*` and the evidence in
`artifacts/ideology-cell-layer/`.

### Backend decision (I01: one program, one backend)

`cell_program_eligibility.h` is the ONLY place that decides. `decide_cell_program_backend()`
answers `DerivedCell` or a named reason (`not_cell_domain` / `unsupported_selector` /
`not_permanent` / `non_constant_value_mode` / `stacked` / `unresolved_definition`).

The production path and the legacy plane both call it; there is no second rule. Measured
coverage: **265 of 265** in-scope programs (kinds 12/14/15/16) go derived, and 23 stay on
the instance path for a stated reason (16 non-cell domains + 7 unsupported selectors).

There is **no rollout switch**. Supported selectors go derived, full stop.

### Rebuild is resumable

A full materialise of 6400 cells exceeded the 1 ms slice budget, so it is split:

```cpp
bool step_derived_rebuild(int64_t day, std::string &error);  // false = needs another slice
bool derived_rebuild_pending() const;
int  drain_derived_cell_layer(int64_t day);                  // drive to completion now
```

The unit of work is a **contribution**. State lives in `DerivedCellMaterializeJob`
(`folded` / `touched_stats` / report counters / `_index` cursor) and survives across calls.
`done()` is `_started && _index >= _total` — not `_index >= _total`, which is true before
the first step.

Collection and folding are **separate steps**: collecting 6400 cells alone costs 0.68 ms,
so folding in the same step pushed the first slice to 1.03 ms.

### Ownership scope for fan-outs (kinds 14/15/16)

Bits 12..13 of `param0`, uniform across the three kinds, decoded by
`selector_ownership.h`:

| value | meaning |
|---|---|
| `OWN = 0` (**default**) | own territory only |
| `FOREIGN = 1` | foreign only |
| `ANY = 2` | no filter (pre-change behaviour) |

An **unknown value falls back to `ANY`, not `OWN`.** Silently narrowing a card whose intent
is unclear makes its target set vanish, and an empty target set is indistinguishable from
"nothing matched".

Measured impact of the new default on the 6x5 fixture: **51.7 % of a radius-2 ring at a
border is foreign** (worst single ring 14 of 18). All 74 shipped cards (5x kind 14,
66x kind 16) author no scope bits, so they all land on `OWN`.

### Where the value comes from

`effective_value` merges the derived contribution into the SAME add/factor sum, before the
single final clamp:

```
add += slot->sum_add;
factor = zero_factor_count > 0 ? 0.0 : factor * slot->product_nonzero;
value  = clamp((base + add) * factor, min, max);
```

The derived lookup is keyed by **`group_handle`, which is the CELL**; `entity_handle` is 0.
Do not add a `group_handle != 0` guard — that is how cell 0 silently lost every card's
effect (measured: cell 0 value 1.0 while cell 1 was 1.05).

For a metric ramp the magnitude comes from the **program's own instruction stream**, via
`evaluate_program_magnitude_for_metrics()`. `metric * term.value` is only correct for a
stream that is exactly `EMIT metric` at unit scale, and no shipped ramp card is.

### Observability

| bridge | content |
|---|---|
| `get_derived_cell_layer_report()` | `layer_generation` / `cell_count` / `stat_count` / `stat_ids` / `sample_day` / `epoch_id` |
| `get_effective_stat_value(stat_key, cell, entity, base)` | merged value + `derived_add` / `derived_factor` / `derived_zero_factor_count` / `derived_contributors` / `derived_present` |
| `get_derived_materialize_report()` | seen / derived / skipped_legacy / cells_visited / rows_emitted / truncated |
| `get_derived_multi_country_report()` | `multi_country_cells` / `max_contributors` / `countries` |

`get_effective_stat_value` calls the same `effective_value` the hot path calls — it reports
what the game would see, not a re-derivation.

### Idle must not look like work

Identical content must not install and must not bump a version (I13); otherwise every idle
day invalidates every cache keyed on the layer generation. Verified by
`tests/ideology/ideology_b5_idle_test.gd` (30 idle days, generation frozen) — with a
negative control that first PROVES a content change does bump it.

Note `cell_layer_rebuild_steps` is **per-run, not cumulative**; use `layer_generation` or
`sample_day` to reason about "did work happen".

### Known gap

There is **no >32-cell production sample**: a freshly generated world gives
`countries=3 widest=1 above_old_cap=0`. The mechanism is verified on synthetic
400/1600/6400-cell territories only. Producing a real sample needs territory expansion
gameplay first.
