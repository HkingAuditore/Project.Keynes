---
name: project-keynes-ideology-runtime
description: Guide Project.Keynes native ideology-system development and review across IdeologyCatalog compilation and the generated 30-card/6-school catalog, NativeIdeologyRuntime and the worker RuntimeIdeologyPodAuthority (collection/slots/offers/reroll/understanding/levels/increment-based points), class-opinion support gates, exclusion groups, named synergies and school resonances, technology slot unlocks, ACK-gated Effect/Modifier transitions, PKID v4 and IDP2 persistence, IdeologyFacade/PlayerController pause-and-step draw flow, the papercut ideology workspace, and verification. Use whenever the user mentions 理念, 理念点, ideology, national spirit, 民族精神, three-card offer, 三选一抽卡, 重抽, 流派共鸣, ideology slots, class opinion, 阶层民意, ideology synergy, PKID, IDP2, ideology_runtime, ideology workspace, or wants to add/change/debug an ideology, its UniqueSource Country modifiers, or the ideology panel.
---

# Project.Keynes Ideology Runtime

Treat ideology as a country-scoped authority that never writes another domain
store. `NativeIdeologyRuntime` owns collection, understanding, levels, slots,
offers, gates, synergies, and queued commands. Country owns technology and
research signals. Economy publishes committed class-opinion facts. Effect owns
transactions and durable external bindings. Modifier owns UniqueSource Country
instances. Trigger may hand a typed command into the ideology queue. GDScript
compiles catalogs, packs commands, schedules the existing job, and renders UI.

Also load `cpp-dots-runtime-development`, `project-keynes-runtime-architecture`,
`project-keynes-effect-runtime`, `project-keynes-modifier-runtime`,
`project-keynes-country-runtime`, and `project-keynes-economy-runtime` when the
change crosses those owners. Load `project-keynes-trigger-runtime`,
`project-keynes-player-controller`, or `project-keynes-ui-art-direction` for
Trigger handoff, player writes, or panel work.

## Ground before editing

Read `docs/cpp-dots-runtime/native-ideology-runtime.md` first. Then read only
the bundled reference that matches the task:

- Authority, catalog IR, commands, support, Effect binding, PKID:
  [runtime-contract.md](references/runtime-contract.md)
- Authored catalog, UI, tests, performance, extension SOP:
  [content-ui-and-verification.md](references/content-ui-and-verification.md)

Inspect current source before editing:

- `gdext/src/ideology_runtime.{h,cpp}`
- `gdext/src/world_ext_ideology.cpp`, `world_ext.h`, `world_ext_bind_methods.cpp`
- `Project/project-keynes/scripts/ideology/`
- `Project/project-keynes/scripts/simulation/systems/ideology_runtime_system.gd`
- `gdext/src/runtime_ideology_pod.{h,cpp}` and the ideology bridge in
  `native_simulation_host.cpp` (`stage_ideology_modifier_commands`,
  `settle_ideology_modifier_acks`) for the production worker path
- `Project/project-keynes/tools/ideology/generate_ideology_catalog.py` (source
  of `default_ideology_catalog.tres` and the ideology rows of
  `default_modifier_catalog.tres`; edit the generator, not the `.tres`)
- `Project/project-keynes/scripts/ui/components/ideology_workspace.gd`
  plus `ideology_card.gd`, `ideology_slot_niche.gd`, `ideology_point_scroll.gd`,
  `ideology_art.gd`, and `assets/ui/ideology_v1/`
- `Project/project-keynes/scripts/ui/country_view_model.gd`
- `Project/project-keynes/scripts/game/player_controller.gd`
- `Project/project-keynes/tests/ideology_*.gd`

Treat current C++ and the repository document as final truth. Do not infer the
contract from chat, a roadmap, or a previous ideology prototype.

## Classify the requested change

State which boundary changes before coding:

1. Catalog/content only (`IdeologyDefinition`, stances, synergies, UniqueSource
   Country modifiers, Effect templates).
2. Native command, slot, offer, understanding, or daily-graph behavior.
3. Class-opinion snapshot, support formula, exclusion, or synergy CSR.
4. Effect batch/binding/ACK or Modifier definition keys.
5. Facade, PlayerController, snapshot/explain, or ideology panel.
6. PKID/PKEF restore, producer high-water, or PKSV provider order.
7. Scheduling, slice budgets, or performance counters.

Do not invent a parallel GDScript ideology simulation, a DataCore opinion slot,
or a second Modifier writer for equipped ideas.

## Preserve hard invariants

- Keep C++ as the sole mutable owner of country idea state. GDScript never
  mirrors a writable collection.
- Keep ideology effects as reversible UniqueSource Country Modifier commands
  unless the level's `on_enter` template is an explicit one-shot. Persistent and
  synergy rows must fail catalog compile when they are not reversible Modifier
  apply/remove pairs.
- Emit old-tier removes, new-tier applies, one-shots, and synergy
  add/remove as one `enqueue_external_effect_batch_pod()` transaction. Any
  invalid command yields zero submission. Displayed location/level is intent
  until the aggregate ACK; rejection rolls back retained ideology and synergy
  state and reactivates the previous binding.
- Keep national-spirit promotion irreversible and slot-only: preserve the
  existing persistent Effect identity, release ideology capacity, and never
  replay one-shots.
- Keep the durable Effect binding identity stable per
  `country + ideology + active form`. Level replacement advances generation and
  signature without inventing a new identity.
- Read Economy's committed `CountryClassOpinionSnapshot` only for structural
  commands and explain. Same-day ideology commands use the previous COMMIT
  revision. Do not scan class opinion on the quiescent daily path.
- Compute support as
  `Σ(class_influence × directional_stance) / Σ(class_influence)`. Absent stance
  rows contribute zero. Optional critical-class floors (`>= -65536`) block even
  when the weighted average passes. Empty stances bypass the gate.
- Visit only reverse-CSR synergy candidates after equip/unequip/level/promotion.
  Do not scan the synergy catalog. School resonances are synergies whose rows
  list the whole school with `min_count` 2 or 4.
- Ideology points accrue only from growth deltas (population, installed
  buildings, trade value per day) carried on the committed class-opinion
  snapshot, scaled by the opinion factor `[0.5,1.5]` and the frozen
  `country.ideology.point_gain_factor`, capped per period. First observation
  only sets the baseline. Settle once per country per opinion revision; never
  scan ideas for points. Main and worker paths must use the same integer
  formula.
- The worker path must apply real Modifiers: one atomic Modifier POD batch per
  transition, ACK derived from the committed batch result. Never reintroduce a
  synthesized `OK` ACK.
- Keep daily work on pending ACK refs, ideology-ID-sorted `active_state_indices`,
  and a head-cursor command merge. Quiescent evidence is
  `sparse_idea_scan_count=0`, `dormant_scan_count=0`,
  `command_queue_resorts=0`, `command_queue_shift_steps=0`.
- Cap levels at 64 because entered confirmation is a packed bitset.
- Resolve stable IDs in `IdeologyCatalog` / `IdeologyFacade`. Native hot loops
  use dense IDs, Q16, bitsets, and bounded scratch. No Dictionary, String,
  Variant, Godot Object, or unbounded output in evaluation.
- Persist PKID v4 (and the worker `IDP2` mirror) authoritative idea state,
  points, offer/RNG, draw count, point baselines, ledger and 32-entry history,
  producer high-water, queued commands, pending Effect transaction IDs, and
  durable binding identity. Rebuild derived indices, slot caches,
  technology-driven capacity, and class-influence after restore. Settled UI
  receipts are not saved. PKID v3 / IDP1 fail closed.
- Restore PKTR then PKEF then PKID. A present PKID must match catalog hash and
  payload exactly. Every active idea must resolve its PKEF v10 external binding;
  pending ideology transactions are audited both ways. Never repair a missing
  binding by replaying effects.
- Changing authored ideology Modifier keys or term values changes Modifier and
  Effect catalog hashes; existing PKCM/PKEF saves fail closed.

## Implement in the required order

1. Extend or validate the Resource catalog and UniqueSource Country Modifier
   definitions. Compile dense IR before mutating runtime state.
2. Keep Effect templates inside the shared Effect catalog. Persistent ideology
   and synergy rows target resolver 1 (country handle) only.
3. Add native storage, commands, and daily-graph work with slice limits and
   same-day continuation.
4. Route every persistent consequence through one Effect batch and wait for ACK.
5. Freeze class-opinion reads at the committed Economy snapshot. Do not sample
   live cohort arrays from ideology.
6. Update facade snapshots, `explain_ideologies()` packed columns, and
   `catalog_view()` presentation lines together.
7. Route player writes through `PlayerController` producer/sequence commands.
   Keep `IdeologyWorkspace` Facade-only and rebuild rows only when the compact
   native snapshot or support revision changes.
8. Update PKID/PKEF identity, focused tests, repository documents, and this
   skill in the same change.
9. Run the bundled verifier. Add `-Build` and `-Godot` before claiming
   completion.

## Current production content

The default catalog is generated by
`tools/ideology/generate_ideology_catalog.py`:

- 30 cards, 6 schools × 5 (农本 agrarian, 商贸 commerce, 学识 learning, 动员
  mobilization, 工造 industry, 调和 harmony); each card owns a UniqueSource
  Country definition `ideology.<key>`. Never collapse them onto a shared stub.
- Rarity common/rare/legendary, weights 120/60/20; legendary and some rare
  cards need era technology. Exclusion groups `economic_order`, `labor_order`,
  `land_order`. Some cards carry a cost term.
- 3 levels: thresholds 0 / 4.0 / 12.0, daily understanding 0.125 / 0.0625 / 0,
  magnitudes `65536` / `104858` / `144179`.
- 6 named synergies `ideology.synergy.*` and 12 resonances
  `ideology.resonance.<school>.<2|4>`.
- Slots 2 ideology / 1 spirit, growing via `capacity_unlocks` to 6 / 3.
- Points start at 0. Every draw is paid: 6.0 first, then x1.2 per draw (`offer_cost_growth_percent`); reroll
  (`REROLL_IDEOLOGY_OFFER = 10`, `ideology.reroll`) costs 50% of the cost paid for the active offer.

The ideology panel must show `level_effect_lines` on offer cards and the
collection. Player draws pause the clock, step one day at 1x until the new
offer appears, and restore the clock after choose/reroll; failures or a 3-day
timeout unlock and report.

## Verify

From the repository root:

```powershell
& .\.codex\skills\project-keynes-ideology-runtime\scripts\verify_ideology_runtime.ps1
```

Add `-Build` for debug/release GDExtension builds and `-Godot` for focused
headless fixtures. At minimum run:

- `tests/ideology_runtime_test.gd`
- `tests/ideology_opinion_synergy_test.gd`
- `tests/ideology_content_test.gd`
- `tests/ideology_progression_test.gd` (points, cost curve, reroll, slots, resonance)
- `tests/ideology_draw_flow_test.gd` and `tests/player_country_ui_smoke_test.gd`
  when PlayerController, the facade, or the workspace changes
- `tests/runtime_ideology_save_roundtrip_test.gd` and
  `tests/runtime_domain_pod_test.gd` when the worker POD or IDP2 changes
- `tests/ideology_runtime_stress_test.gd` when the hot path, slice budget, or
  512-country continuation changes
- affected Trigger/PlayerController/Modifier/Effect/save fixtures
- `git diff --check`

Do not claim the 64-country × 12-active ideology p95 ≤ 0.35 ms, 512-country
continuation p95 ≤ 0.42 ms, native call ≤ 1 ms, or 6400-cell class-opinion
median < 1 ms gates without same-machine, same debug DLL, fixed-seed evidence.

## Report completion

Include:

- Native versus GDScript authority after the change.
- Command, slot, support, synergy, and Effect/ACK semantics that changed.
- PKID/PKEF compatibility and whether existing saves fail closed.
- UI snapshot/explain/catalog-view behavior.
- Test, build, and (if claimed) performance evidence.
- Remaining blockers and intentional non-goals (diplomacy, AI ideology policy,
  per-cell ideology, conserved-ledger writes).
