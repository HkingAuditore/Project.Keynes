# Native Ideology Runtime

`NativeIdeologyRuntime` is the country-scoped authority for ideology collection,
understanding, levels, ideology slots, national-spirit slots, deterministic
three-card offers, gates, and queued ideology commands. It intentionally does
not own Country technology/signals, Effect transactions, Modifier instances,
economy state, or a Godot UI mirror.

## Authority and order

The production chain is `trigger_runtime` (80) -> `ideology_runtime` (82) ->
`effect_runtime` (85) -> `modifier_daily` (90) -> `gameplay_effect` (95) ->
`country_daily` (255) -> `economy_daily` (260). Trigger can hand a typed `IDEOLOGY_COMMAND` directly to
the ideology queue after its own event/idempotency checks. Country exposes only
frozen technology and research-signal facts for draw eligibility.

The daily hot path iterates each country's `active_ideologies` list only.
Discovered but inactive ideas never receive passive understanding, and normal
daily work reports `dormant_scan_count=0`. Offer filtering runs only when a
player asks for an offer; it uses the per-country SplitMix64 state and draws
three weighted candidates without replacement.

## Effect boundary

Ideology persistent rows are reversible Modifier commands. The runtime emits
old-tier removes and new-tier applies through `EffectRuntime`, never directly
to `ModifierRuntime`. A level, equip, unequip, or inactive-to-spirit transition
stores only the resulting Effect transaction IDs. It remains pending until all
referenced transactions ACK; a rejection restores the retained prior ideology
state. Therefore a level cannot mark its one-shot `entered_levels` bit before
the Effect ACK, and a tier replacement cannot leave the old persistent tier
stacked with the new one.

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
requirement CSR columns, effect-template columns, and profile capacities.
Definitions are limited to 64 levels because entry confirmation is a packed
64-bit set. Persistent rows must be reversible Modifier operations; `on_enter`
rows retain the six standard Effect action categories and are resolved by the
Effect command-template catalog.

GDScript calls only `IdeologyFacade` (`request_offer`, `choose_offer`, `equip`,
`unequip`, `promote`, `snapshot`, `explain_ideology`). Country-panel UI reads a
Facade snapshot and disables an idea while its transition is pending; it never
stores or mutates authority state itself.

## Save and restore

`PKID v2` persists known/gate bitsets, sparse idea state, entered-level bits,
slots, points, offer and RNG state, queued commands, and pending Effect
transaction IDs, plus the active idea's durable Effect binding ID/generation,
level/location, template signature and program hash. It is restored after `PKTR`
and `PKEF`. A save without PKID
migrates to empty ideology state; a present PKID must match its catalog hash and
payload/schema exactly. Every active idea must resolve its exact PKEF v5 external
binding after restore; missing binding, generation/level/location mismatch,
template/program-hash mismatch, or an unknown pending transaction fails closed.
The pending audit is bidirectional: every PKID transition ID must still be a
pending PKEF transaction with the matching country/ideology source, and PKEF may
not contain an additional pending ideology transaction omitted by PKID.
An old PKEF v4 with an active PKID is therefore rejected rather than repaired by
replaying effects. `configure_effects()` also reattaches an already-created
ideology authority, which preserves the transaction contract during production
startup where Country/Ideology are configured before Effect.

## Verification

Run `tests/ideology_runtime_test.gd`, catalog rejection fixtures, Trigger
handoff coverage, and `git diff --check`. For performance, establish a same
machine no-ideology baseline before a 50-day headless run and a 30+ ACTIVE-tick
window. Report ideology/Effect/Modifier timings, active visits, candidate count,
pending transactions, POD memory, overflow, and `dormant_scan_count`; do not
claim a percentage or millisecond regression before those measurements.
