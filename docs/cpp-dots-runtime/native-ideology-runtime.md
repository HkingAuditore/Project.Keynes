# Native Ideology Runtime

`NativeIdeologyRuntime` is the country-scoped authority for ideology collection,
understanding, levels, ideology slots, national-spirit slots, deterministic
three-card offers, gates, and queued ideology commands. It intentionally does
not own Country technology/signals, Effect transactions, Modifier instances,
economy state, or a Godot UI mirror.

## Production worker authority (G8)

G8 promoted the worker mirror to production. When the session grants
`IDEOLOGY` (`0x010`, part of `implemented_domain_mask() == 0xFFF`), the Host
stage is the **sole Ideology writer**:

- `submit_ideology_commands` only queues POD commands; it no longer stages the
  same batch in the legacy queue first, and returns `path=IDEOLOGY_WORKER`.
- `run_ideology_daily` returns a suppressed ok and `ideology_should_run` is
  false, so neither the native runtime graph nor `IdeologyRuntimeSystem`
  evaluates on the main thread.
- The worker publishes an immutable snapshot into `RuntimeIdeologySnapshotRing`;
  the main thread applies it with `apply_runtime_ideology_snapshot` →
  `NativeIdeologyRuntime::apply_pod_snapshot`, so UI, `explain`, receipts and
  `PKID` keep reading one runtime. The apply is non-blocking and generation
  gated, so intermediate generations may be skipped.
- Transition intents address `EFFECT`. The POD catalog (ABI 3) carries the
  per-level and per-synergy Modifier template rows (definition key hash,
  magnitude, reversible flag). When IDEOLOGY and MODIFIER are both granted in
  ACTIVE mode, `stage_ideology_modifier_commands` turns each transition into one
  atomic Modifier POD batch: every row is resolved first, and one unresolved
  definition rejects the whole batch with zero submission. After the Modifier
  stage `settle_ideology_modifier_acks` derives the `EFFECT`-tagged ACK from the
  real batch result (`OK` only when the batch committed; a failed Modifier day
  resubmits next day; a rejected batch rolls the ideology state back through the
  existing contract). The old auto-`OK` `ack_ideology_intents_in_worker` bridge
  is gone. Without the Modifier grant the main-thread
  `poll_ideology_worker_intent` / `submit_ideology_worker_ack` pump remains the
  protocol path.
- The worker freezes `country.ideology.point_gain_factor` from the last
  committed Modifier snapshot into the opinion input; Ideology never reads a
  live Modifier value.
- Opinion hand-off: the worker stage cannot plan without a published Economy
  class-opinion snapshot. `DCWorldExt` remembers the last published revision
  and republishes whenever Economy's committed revision differs, both before
  the budgeted runtime-graph loop and in `apply_runtime_ideology_snapshot`
  (under the economy boundary lock). A publish placed only inside the graph
  loop starves when the Economy capture consumes the pulse budget, leaving the
  stage parked on `ideology_opinion_snapshot_missing` for the whole session.
- Generation cursor: each worker lifetime numbers snapshots from 1.
  `start_runtime_worker` calls `reset_pod_snapshot_cursor()` and
  `WorldRuntimeHost` resets `_ideology_worker_snapshot_generation`, otherwise a
  restarted worker's snapshots are rejected as
  `ideology_pod_snapshot_generation_regression`.

## Worker shadow authority (G2-G7)

The section below describes the SHADOW diagnostic stage, which is retained for
parity work when the authority switch is off.

`RuntimeIdeologyPodAuthority` is the worker-only numeric mirror used by
`NativeSimulationHost` in `SHADOW`. Its catalog contains immutable CSR/array
definitions for levels, Country technology/research requirements, class stance
gates, exclusions, capacities, and reverse-CSR synergy candidates. The worker
does not retain Godot objects, strings, runtime pointers, or writable UI state.

The nine legacy operations are replayed through a copy-on-write plan with
stable command ordering, producer high-water idempotency, bounded cursors, and
same-day continuation. Country input is the captured technology/discovery/
pending-technology/research-signal snapshot. Opinion input is the previously
committed Economy class-opinion snapshot; revision, class hash, lane shape, and
Country handle/generation are fail-closed checks on every plan.

Effect-dependent changes emit typed `RuntimeDomainIntent` records marked
`DEFERRED | REQUIRES_ACK`. The worker never synthesizes an ACK and does not
publish final location, level, slot, ACTIVE, or synergy state until a real
Effect `OK` ACK is matched to the stable transition identity, target generation,
and effective day. The mirror is bootstrapped and published at worker start
when its immutable Country and Economy inputs are available, then is not fed
back into the synchronous `NativeIdeologyRuntime`.

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
school id / rarity / level labels, rarity draw weights,
requirement CSR columns, effect templates, directional class-stance CSR,
exclusion groups, synergy requirement rows, and the
`ideology_id -> affected synergy_ids` reverse CSR. A school resonance is a
synergy whose requirement rows list every card of that school and whose
`min_count` is 2 or 4 (named synergies use `min_count == requirement_count`),
so the same reverse CSR only visits the resonances of the school touched by a
mutation. Adoption, repeal, and
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
through `IdeologyFacade`. `get_ideology_snapshot()` always returns the same
column set, including per-country `ideology_slots_capacity` /
`national_spirit_slots_capacity` (plus `*_capacity_max`), `next_offer_cost_q16`,
`reroll_cost_q16`, `draw_sequence`, `point_ledger_*`, `point_baseline_ready`,
`lifetime_points_q16`, `point_history_q16` (32-entry ring), `active_synergy_ids`,
and `capacity_unlock_*` rows (technology key, deltas, owned). A country that has
not yet received an ideology command is `materialized=false`; the catalog now
starts every country at 0 points. `preview_ideology_offer_eligibility(handle)`
is a read-only native query returning `can_draw`, current cost, eligible pool
size and a reason code, used by `PlayerController` before it advances time.
`explain_ideologies()`
returns packed support, threshold, blocker, class-contribution, eligibility, and
hypothetical synergy columns for all visible ideas in one native call. Static
catalog metadata is separate and UI reuses live explain data while support
revision and structural snapshot signature are unchanged.

## Content (default catalog)

The default catalog is generated by
`Project/project-keynes/tools/ideology/generate_ideology_catalog.py`, which
writes both `data/ideologies/default_ideology_catalog.tres` and the ideology
rows of `data/modifiers/default_modifier_catalog.tres`. Edit the generator, not
the `.tres` files.

- 30 cards, 6 schools × 5: 农本 (agrarian), 商贸 (commerce), 学识 (learning),
  动员 (mobilization), 工造 (industry), 调和 (harmony). Every card has its own
  UniqueSource Country definition `ideology.<key>` built from existing country
  stats; some cards carry a cost term (consumption, construction cost, resource
  use).
- Rarity common/rare/legendary with draw weights 120/60/20. Legendary and some
  rare cards require an era technology. Exclusion groups: `economic_order`,
  `labor_order`, `land_order`.
- Three levels: understanding thresholds 0 / 4.0 / 12.0, daily understanding
  0.125 / 0.0625 / 0. Each level replaces the same definition at Q16 magnitude
  `65536` / `104858` / `144179` (1.0x / 1.6x / 2.2x).
- 12 resonances `ideology.resonance.<school>.<2|4>` and 6 named cross-school
  synergies `ideology.synergy.*` (计划仓廪, 特许开拓, 海商账簿, 工役营造, 工业科学,
  河渠公社). Learning tier 4 raises `country.ideology.point_gain_factor`.
- Slots start at 2 ideology / 1 national spirit. `capacity_unlocks` (technology
  key + deltas) add ideology slots at Kingdom, Imperial, Enlightenment and
  Industrial era technologies (max 6) and spirit slots at Imperial and Electric
  (max 3). Capacity is cached per country from Country technology facts and is
  rebuilt after restore.

## Points, offers and reroll

Ideology points accrue only from growth. Economy's committed class-opinion
snapshot carries four extra per-country lanes collected in the existing
`publish_country_development_facts` scan: population, installed buildings,
period trade base value and period length (days). When the opinion revision
advances, Ideology settles each country once (O(countries), no idea scan):

```
raw  = max(0, Δpopulation) × w_pop + max(0, Δbuildings) × w_build
     + trade_value / period_days × w_trade
gain = min(cap, raw × opinion_factor × point_gain_factor)
```

`opinion_factor = 0.5 + influence-weighted satisfaction`, clamped to
[0.5, 1.5]. Weights and cap live in the profile (`point_*_weight_q16`,
`point_gain_cap_q16`; default 0.02/resident, 0.25/building, 0.002/money of
daily trade, cap 2.0 per period). The first observation only establishes the
per-country baseline and yields nothing. The last source breakdown and a 32-gain
history ring are kept per country for the UI ledger. Main (`NativeIdeologyRuntime`)
and worker (`RuntimeIdeologyPodAuthority`) implement the same integer formula;
`copy_opinion_snapshot` copies the new lanes.

Every draw is paid. The first draw costs 6.0 and each later draw costs 20% more than the previous one (`offer_cost_growth_percent = 120`, Q16 rounded per step by the shared `runtime_ideology_offer_cost_q16` helper; `offer_cost_max_q16` is only a saturation guard). `REROLL_IDEOLOGY_OFFER`
(opcode 10) replaces the active offer for 50% of the cost paid for that offer, is
unlimited, and uses the same offer RNG stream.

## Player draw flow

`PlayerController` first calls `preview_offer_eligibility`; an ineligible draw
reports the reason without advancing time. Otherwise it submits the command,
records whether the clock was running and at what speed, locks player commands
other than ideology choice and era reward, runs at 1x, and pauses as soon as a
new `offer_active` generation appears (`ideology_offer_ready`). Choose and
reroll use the same single-step flow; afterwards the previous clock state is
restored. A rejected command or no settlement within 3 days unlocks, restores
the clock and reports `ideology_draw_timeout`. The draw state is saved in
`player_view`. Equip, unequip and promote stay next-day and the UI marks them
as pending.

`共同体治理` and `自由交换` remain exclusive via `economic_order`.
`IdeologyCatalog.catalog_view()` joins those modifier terms into
player-facing `level_effect_lines`; the ideology panel must show them on
three-card offers, slot rows and collection cards. The panel is a two-column
board: the left column lists one compact row per equipped idea plus a single
collapsed drop row for the remaining capacity, with the next technology
milestone as a caption instead of an empty alcove; the right column scrolls the
owned collection beside it. A three-card offer opens in a centred tray over a
scrim and is selected with one left click. Changing authored ideology
modifier keys or term values changes the Modifier and Effect catalog
hashes; existing PKCM/PKEF saves fail closed.

## Save and restore

The worker mirror has an independent `IDP2` section and ABI. It is restored
only after worker stop and catalog/bootstrap validation; checksum, catalog hash,
state hash, shape, and version failures reject the complete worker state. The
legacy composite diagnostic `PDP3` and synchronous `PKID` remain separate;
absence of `IDP2` bootstraps default worker state and never derives it from
`PKID`.

`PKID v4` persists known/gate bitsets, sparse authoritative idea state,
entered-level bits, points, offer and RNG state, draw count, point baselines,
the last ledger breakdown and 32-entry history, producer high-water marks,
queued commands, and pending Effect transaction IDs, plus each active idea's
durable Effect binding ID/generation, level/location, template signature and
program hash. Active/pending indices, slot caches, normalized class influence,
technology-driven slot capacity, and the Economy opinion snapshot are derived
and rebuilt after restore. `IDP2` mirrors the same new fields. PKID v3 and IDP1
are rejected (fail-closed); the catalog hash change also rejects older PKCM and
PKEF saves. Settled
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

Development work should follow the `project-keynes-ideology-runtime` Skill in
`.codex/skills/project-keynes-ideology-runtime/`. That Skill is the agent
workflow; this document remains the current-state contract.

## Verification

Run `tests/ideology_runtime_test.gd`,
`tests/ideology_opinion_synergy_test.gd`,
`tests/ideology_runtime_stress_test.gd`, and
`tests/ideology_content_test.gd`, `tests/ideology_progression_test.gd`, `tests/ideology_draw_flow_test.gd`, and
`tests/player_country_ui_smoke_test.gd` plus Trigger/PlayerController fixtures and
`git diff --check`. Headless CSV exposes ideology phase timings and deterministic
work counters, Effect ACK state, and class-opinion scan rows/time. The target
gates are 64 countries × 12 active at ideology p95 ≤ 0.35 ms, each 512-country
continuation slice p95 ≤ 0.42 ms with no native call above 1 ms, and a 6400-cell
class-opinion median below 1 ms. Timing claims require same-machine, same debug
DLL, fixed-seed evidence.

`tests/ideology_workspace_screenshot_qa.gd` (rendered, without `--headless`)
drives a real session through the worker path: grant, draw, present, choose,
and writes 1280x720 / 1920x1080 PNGs to `res://tmp/ideology_workspace_qa/`.
