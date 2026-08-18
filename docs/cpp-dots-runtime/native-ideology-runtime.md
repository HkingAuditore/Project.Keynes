# Native Ideology Runtime

`NativeIdeologyRuntime` is the country-scoped authority for ideology collection,
understanding, levels, ideology slots, national-spirit slots, deterministic
three-card offers, gates, and queued ideology commands. It intentionally does
not own Country technology/signals, Effect transactions, Modifier instances,
economy state, or a Godot UI mirror.

## Authority and order

The production chain is `trigger_runtime` (80) -> `ideology_runtime` (82) ->
`effect_runtime` (85) -> `modifier_daily` (90) -> `gameplay_effect` (95) ->
`country_daily` (255) -> `economy_daily` (260). Trigger can hand a typed
`IDEOLOGY_COMMAND` directly to the ideology queue after its own
event/idempotency checks. Country exposes frozen technology and research-signal
facts for draw eligibility. Economy publishes a double-buffered committed
`CountryClassOpinionSnapshot`; ideology reads that POD view only for structural
commands and explain queries.

The daily hot path never scans sparse discovered state. Pending ACK work uses
`PendingTransitionRef`; passive progress uses ideology-ID-sorted
`active_state_indices`. Slot totals and active bitsets are maintained at each
location mutation. Command intake linearly merges sorted staging rows behind a
head cursor, so submit does not re-sort history and drain does not erase from
the vector head. Transition polls, commands, and active visits each have fixed
slice limits and same-day continuation cursors. Quiescent evidence is
`sparse_idea_scan_count=0`, `dormant_scan_count=0`,
`command_queue_resorts=0`, and `command_queue_shift_steps=0`.

## Effect boundary

Ideology persistent rows are reversible Modifier commands. Old-tier removes,
new-tier applies, one-shots, and synergy additions/removals are preflighted as
one `enqueue_external_effect_batch_pod()` transaction. Every command retains
its external effect/source identity, but the transition performs one reserve,
one plan, and one aggregate ACK. Any invalid command produces zero submission.
A level, equip, unequip, or inactive-to-spirit transition stores the aggregate
transaction ID and remains pending until it ACKs; rejection restores retained
ideology and synergy state.

Active ideology -> national spirit is slot-only: it preserves the tier source
identity and its already-active persistent effect, releases ideology capacity,
and never replays one-shot effects. National spirits are irreversible.
The durable external binding identity is stable per country + ideology + active
form (ideology or national spirit); level replacement advances the binding
generation/signature without inventing a new identity. A rejected replacement
retires the failed generation and reactivates the previous binding before the
transition is cleared.

## Catalog and facade

`IdeologyCatalog` compiles stable Resource keys to dense ideology/level rows,
requirement CSR columns, effect templates, directional class-stance CSR,
exclusion groups, synergy requirement rows, and the
`ideology_id -> affected synergy_ids` reverse CSR. Adoption, repeal, and
promotion have independent support thresholds and optional critical-class
floors. Runtime support is
`Σ(class_influence × directional_stance) / Σ(class_influence)`; absent stance
rows contribute zero. Influence normalization caches per country and committed
opinion revision. Synergy reconciliation visits only reverse-CSR candidates
after equip/unequip/level/promotion and joins the main Effect batch.
Definitions remain limited to 64 levels because entry confirmation is a packed
64-bit set.

Player writes enter through `PlayerController`, with producer/sequence
high-water idempotency and bounded per-command receipts. GDScript reads only
through `IdeologyFacade`. `explain_ideologies()` returns packed support,
threshold, blocker, class-contribution, eligibility, and hypothetical synergy
columns for all visible ideas in one native call. Static catalog metadata is
separate and UI reuses live explain data while support revision and structural
snapshot signature are unchanged.

## Save and restore

`PKID v3` persists known/gate bitsets, sparse authoritative idea state,
entered-level bits, points, offer and RNG state, producer high-water marks,
queued commands, and pending Effect transaction IDs, plus each active idea's
durable Effect binding ID/generation, level/location, template signature and
program hash. Active/pending indices, slot caches, normalized class influence,
and the Economy opinion snapshot are derived and rebuilt after restore. Settled
UI receipt history is not persisted. PKID is restored after `PKTR` and `PKEF`.
A save without PKID
migrates to empty ideology state; a present PKID must match its catalog hash and
payload/schema exactly. Every active idea must resolve its exact PKEF v10 external
binding after restore; missing binding, generation/level/location mismatch,
template/program-hash mismatch, or an unknown pending transaction fails closed.
The pending audit is bidirectional: every PKID transition ID must still be a
pending PKEF transaction with the matching country/ideology source, and PKEF may
not contain an additional pending ideology transaction omitted by PKID.
An older PKEF without the required binding/command identity is rejected rather
than repaired by replaying effects. `configure_effects()` also reattaches an already-created
ideology authority, which preserves the transaction contract during production
startup where Country/Ideology are configured before Effect.

## Verification

Run `tests/ideology_runtime_test.gd`,
`tests/ideology_runtime_stress_test.gd`, and
`tests/ideology_content_test.gd` plus Trigger/PlayerController fixtures and
`git diff --check`. Headless CSV exposes ideology phase timings and deterministic
work counters, Effect ACK state, and class-opinion scan rows/time. The target
gates are 64 countries × 12 active at ideology p95 ≤ 0.35 ms, each 512-country
continuation slice p95 ≤ 0.42 ms with no native call above 1 ms, and a 6400-cell
class-opinion median below 1 ms. Timing claims require same-machine, same debug
DLL, fixed-seed evidence.
