---
name: project-keynes-ideology-runtime
description: Guide Project.Keynes native ideology-system development and review across IdeologyCatalog compilation, NativeIdeologyRuntime collection/slots/offers/understanding/levels, class-opinion support gates, exclusion groups, synergies, ACK-gated Effect/Modifier transitions, PKID v3 persistence, IdeologyFacade/PlayerController/UI, and verification. Use whenever the user mentions 理念, ideology, national spirit, 民族精神, three-card offer, 三选一抽卡, ideology slots, class opinion, 阶层民意, ideology synergy, PKID, ideology_runtime, ideology workspace, or wants to add/change/debug an ideology, its UniqueSource Country modifiers, or the ideology panel.
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
- `Project/project-keynes/data/ideologies/default_ideology_catalog.tres`
- `Project/project-keynes/scripts/ui/components/ideology_workspace.gd`
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
  Do not scan the synergy catalog.
- Keep daily work on pending ACK refs, ideology-ID-sorted `active_state_indices`,
  and a head-cursor command merge. Quiescent evidence is
  `sparse_idea_scan_count=0`, `dormant_scan_count=0`,
  `command_queue_resorts=0`, `command_queue_shift_steps=0`.
- Cap levels at 64 because entered confirmation is a packed bitset.
- Resolve stable IDs in `IdeologyCatalog` / `IdeologyFacade`. Native hot loops
  use dense IDs, Q16, bitsets, and bounded scratch. No Dictionary, String,
  Variant, Godot Object, or unbounded output in evaluation.
- Persist PKID v3 authoritative idea state, points, offer/RNG, producer
  high-water, queued commands, pending Effect transaction IDs, and durable
  binding identity. Rebuild derived indices, slot caches, and class-influence
  after restore. Settled UI receipts are not saved.
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

The default catalog authors four roads and two synergies. Do not collapse them
onto a shared `country.economic_mobilization` stub:

| Road / synergy | Equipped (level 1) | Mastered (level 2) |
| --- | --- | --- |
| 共同体治理 `idea.collective_stewardship` | agriculture output +6%; drought loss −8% | double |
| 自由交换 `idea.free_exchange` | domestic trade capacity +8%; trade speed +6% | double |
| 学识官署 `idea.scholar_office` | knowledge output +6%; science research +8% | double |
| 公民动员 `idea.civic_muster` | national construction time −6%; economy-wide output +3% | double |
| 计划仓廪 `synergy.planned_granaries` | drought loss −10%; agriculture output +4% | — |
| 特许开拓 `synergy.chartered_frontier` | domestic trade capacity +5%; construction time −4% | — |

`共同体治理` and `自由交换` remain exclusive through `economic_order`.
Equipping applies Q16 magnitude `65536`; understanding the second level
replaces the same definition at `131072`. The ideology panel must show
`level_effect_lines` on three-card offers and collection rows.

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
