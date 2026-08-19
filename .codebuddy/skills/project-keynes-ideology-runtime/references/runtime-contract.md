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
