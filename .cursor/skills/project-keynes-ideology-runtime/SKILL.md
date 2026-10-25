---
name: project-keynes-ideology-runtime
description: Guide Project.Keynes native ideology-system development and review: IdeologyCatalog compilation (cards, synergies, route tags 体系, target selectors and DNF tag predicates, declarative effect programs), NativeIdeologyRuntime (collection, slots, offers with pity/refine/ban, era decay, understanding, levels, gates, synergies, runtime magnitude overrides 卡改卡), class-opinion support gates, exclusion groups, ACK-gated Effect/Modifier transitions, PKID schema 7 persistence, IdeologyFacade/PlayerController/UI, and verification. Use whenever the user mentions 理念, ideology, 民族精神, national spirit, 三选一抽卡, 抽卡保底, 精进, 封存, ideology slots, 阶层民意, class opinion, ideology synergy, 体系羁绊, route_tag, 地块级理念, 目标标签, 选择器, 卡改卡, override, PKID, ideology_runtime, ideology workspace, or wants to add/change/debug an ideology card, its cell-level effect, its synergy, or the ideology panel.
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
- **Build traps, GDScript silent aborts, storage ordering, and the architecture
  facts that are easy to get wrong:**
  [pitfalls-and-build.md](references/pitfalls-and-build.md) — read this before
  the first rebuild, not after the third.

For current status start at §35 of `docs/plans/ideology-build-redesign.md`.
§24–§32 are records written at the time; most of their "还没做的" items have since
been done, so do not quote them as state.

Inspect current source before editing:

- `gdext/src/ideology_runtime.{h,cpp}`
- `gdext/src/world_ext_ideology.cpp`, `world_ext.h`, `world_ext_bind_methods.cpp`
- `Project/project-keynes/scripts/ideology/`
- `Project/project-keynes/scripts/simulation/systems/ideology_runtime_system.gd`
- `Project/project-keynes/data/ideologies/default_ideology_catalog.tres`
- `Project/project-keynes/scripts/ui/components/ideology_workspace.gd`
- `Project/project-keynes/scripts/ui/country_view_model.gd`
- `Project/project-keynes/scripts/game/player_controller.gd`
- `Project/project-keynes/tests/ideology/` (per-domain layout, see tests/README.md)

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
- Persist PKID schema 7 authoritative idea state, points, offer/RNG, producer
  high-water, queued commands, pending Effect transaction IDs, and durable
  binding identity. Rebuild derived indices, slot caches, and class-influence
  after restore. Settled UI receipts are not saved.
- Restore PKTR then PKEF then PKID. A present PKID must match catalog hash and
  payload exactly. Every active idea must resolve its PKEF v10 external binding;
  pending ideology transactions are audited both ways. Never repair a missing
  binding by replaying effects.
- Changing authored ideology Modifier keys or term values changes Modifier and
  Effect catalog hashes; existing PKCM/PKEF saves fail closed.
- **A field must be read exactly where it was written**, and size/range checks
  must follow the read. Fixed-layout rows stay fixed length (capacity + count),
  never variable. Versions in play: PKID **7**, IDP2 pod ABI **5**, PKEF **12**,
  Modifier **3** — all fail-closed.

### Invariants added by the infrastructure layers

- **The ideology worker POD does no instance reconciliation** (`activation` is
  absent from `runtime_ideology_pod.cpp`). Per-instance payload changes stay on
  the main thread and need no POD catalogue/ABI/parity work.
- **Three mirrors of the selector ceiling** must move together:
  `EffectRuntime::SELECTOR_MAX_KIND`, `RuntimeEffectPodAuthority::MAX_SELECTOR_KIND`,
  `effect_catalog.gd:POD_MAX_SELECTOR_KIND`. One card past the ceiling fails the
  whole POD catalogue and drops the EFFECT bit, which takes the twelve-domain
  authority graph with it.
- **`effect_instance_id()` stays a pure function**; the layer index participates
  only when non-zero, otherwise every existing save's instance ids change.
- **Draw weight is computed once, in the shared kernel**, and the pity guarantee
  is a pool partition, never a re-roll — a re-roll advances the RNG a variable
  number of times and desynchronises the two authorities.
- **Two budgets, not one**: `max_effect_instances` counts declared rows across
  the catalog; `max_concurrent_instances` counts live instances
  (slots × widest level × per-program fan-out, stacks included). They fail
  independently.
- **A synergy may rewrite another program's magnitude** via `overrides` →
  `magnitude_scale_for`: product over *active* synergies, clamped once at the
  end to [0.25×, 4×], delivered as the optional `magnitude_scales` column.
- **Generated stat-key families** need a matching row in
  `scripts/modifier/stat_key_families.gd`; `tests/effect/stat_key_family_test.gd`
  is the only thing that notices a missing one.

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

`data/ideologies/default_ideology_catalog.tres` is **generated** by
`tools/ideology/generate_ideology_catalog.py` and currently holds **85 cards**
(plus synergies and school resonances). Never hand-edit the `.tres`; change the
generator and re-run it.

The four original roads still exist and remain exclusive through
`economic_order` — `idea.collective_stewardship` (共同体治理),
`idea.free_exchange` (自由交换), `idea.scholar_office` (学识官署),
`idea.civic_muster` (公民动员) — with the two original synergies
`synergy.planned_granaries` and `synergy.chartered_frontier`. They are no longer
the whole catalog, so do not reason about balance from them alone.

**What the 85 cards do and do not do (2026-10-21):**

- **12 cards are managed-program cards** (§39): 公共卫生、城市卫生、屯垦、三圃轮作、煤田开发、
  标准化、自由交换、反垄断、轮伐、生态均衡、计算网络、常平仓. They carry `route_tag`, a
  `target_selector_kind`, and a `definition_key` that names a program in
  `default_ideology_effects.tres`.
- **9 more are X1 spillover cards** (§40): 冶铁、打制石器、蚕桑、轧棉、农业化学、石化、
  共同体治理、电气化、汽车社会. They use `SEL_TAG_SOURCE_R1/R2` (14/15): the tag selects the
  **source** cells among the country's own territory, each source contributes its ring, the
  union is sorted, deduped and capped.
- **5 C-level cards use metric conditions** (§41): 狩猎传统、行会特许、家内纺织、乡约自治、
  垦荒令. They are the first production cards with `conditions` at all — the tag picks the
  population, the condition narrows it per target cell.
- **2 more are X7 country-count cards** (§42): 盐铁专营、半导体. They gate on
  `country.extractive_cell_count` / `country.chained_cell_count` — per-country tag counts built
  once per epoch from the tag bitset.
- **2 more are X7b cards** (§43): 白银流入、特许航路. Per-good counts are just extra tag
  slots (`cell.produces.<good>`); the distinct-specialized-goods count is its own lazily built
  per-country bitset.
- **55 cards** are still national Modifier rows only (30 of 85 are program cards).
- **13 route bonds** (§44): `ROUTE_BONDS` in the generator emits 8 tier-1 (2 cards) and 5
  tier-2 (4 cards) synergies that expand members by `route_tag`. Tier 2 only exists where the
  route has >= 4 member cards; a taller tier is rejected by `IdeologyCatalog` at compile time.

Metric rows 63..67 are X7b: four per-good counts (`country.{silver,salt,iron_ore,coal}_cell_count`,
which are only extra slots in the same table) plus `country.distinct_specialized_good_count`.
The latter needs its own per-cell sample pass; it keeps a separate valid flag and must be
invalidated together with the tag bits.

Metric rows 56..62 are X7 per-country tag counts (`country.*_cell_count`). Their slot order MUST
match `kCountryTagCountSlots` in `economy_runtime_family_buff.cpp`; the mechanism-matrix test pins
both lists by index. A swapped row does not error — it silently publishes "mining cell count" as
"chained cell count".

Metric rows 51..55 are X3/X2/X11: `cell.dominant_profession_id`,
`cell.dominant_profession_share_q16`, `cell.profession_count`,
`cell.neighbor_population_q16`, `country.income_tax_burden_bp`. Ids are append-only;
`ideology_mechanism_matrix_test` pins 51..55 by index because a reorder would silently
repoint every condition.

Selector rules that are easy to get wrong:

- `OWN_TERRITORY(12)` = the tagged cells themselves (SELF). `TAG_ANY_CELL(13)` = the **whole
  grid**, not the country — do not use it for national content.
- `TAG_SOURCE_R1/R2(14/15)` = per-source rings. `param[1]` is the source tag, `param[0]` the
  union cap. Source tag 0 is rejected on purpose.
- Source cells can only be filtered by **tags**. A metric condition is evaluated on the
  *target* cell, not the source.
- Union, not per-source stacking: "each cell eats at most 3 sources / +30%" is not expressible.
- Every ring selector needs a neighbour graph. A headless fixture without
  `bind_map_data()` + one economy slice has **no neighbours**, so every ring is empty and the
  test passes vacuously.

**Authoring a card program** (generator is still the only source of truth):

1. Keep the card's `terms` cost-only. Benefits go into `LEVEL_ROWS`.
2. `LEVEL_ROWS[card]` is exactly three levels; each level is a list of `prog(...)` rows.
   One level may hold several programs when it targets several tag populations.
3. Program keys must be `<card>_l<n>` (suffix allowed). The compiler drops the second program
   with a duplicate key, and the card silently keeps one level's numbers.
4. `definition_key` in the card row must be the **bare** program key; the compiler adds
   `ideology.effect.`. Writing the prefixed form makes the row look like a legacy Modifier row.
5. Cell commands must name an `ideology.city.*` definition; the gain/cut twin is chosen by the
   sign of `Cmd.value` and the magnitude is the effect itself (`cell(5)` → +5%).
6. Every program needs a `summary`; it is the card-face line.
7. **Linear magnitude is authoring, not engine work** (§45): pass
   `ramp=Ramp("country.<count>_cell_count", per=0.01, cap=15)` and the generator emits
   `CONST per → READ_METRIC → CONST cap → MIN → MUL_Q16 → EMIT`, so the command value is
   `per * min(metric, cap)`. `READ_METRIC` ids are unioned into the metric mask by
   `family_effect_metadata_pod`, so a ramp needs no condition to be published.
   `Ramp` requires exactly one command per program.
8. Assert amplitude through `list_modifiers(...).magnitude_q16`. `evaluate_modifier_stat`
   returns a bare double and wants the modifier's own entity handle — passing 0 silently
   returns the base, which reads exactly like "the ramp did not apply".

## Verify

Tests are grouped by domain under `Project/project-keynes/tests/`. Invoke one at a
time; a batch of long fixtures can exceed a shell timeout and be killed mid-run,
which reads like a failure.

```bash
godot --headless --path Project/project-keynes \
  -s tests/ideology/ideology_runtime_test.gd
```

Core set for any ideology change:

- `tests/ideology/ideology_runtime_test.gd`
- `tests/ideology/ideology_opinion_synergy_test.gd`
- `tests/ideology/ideology_content_test.gd`
- `tests/ideology/ideology_effect_instance_test.gd`
- `tests/ideology/ideology_effect_override_test.gd`
- `tests/runtime/runtime_ideology_save_roundtrip_test.gd` when PKID changes
- `tests/runtime/runtime_modifier_pod_test.gd` when Modifier or aggregation changes
- `tests/ideology/ideology_runtime_stress_test.gd` when the hot path, slice
  budget, or 512-country continuation changes
- `tests/runtime/runtime_worker_source_scan_test.gd` after touching any file on
  its purity list (`native_simulation_host.cpp` and friends must stay `godot::`-free)
- affected Trigger/PlayerController/Modifier/Effect/save fixtures
- `git diff --check`

Build with scons directly (`gdext/rebuild.bat` hangs — see
`references/pitfalls-and-build.md`). **A build counts as successful only when
stdout contains `scons: done building targets.`**; the background task status is
always `failed` because the sandbox blocks `reg.exe`.

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
- Remaining blockers and intentional non-goals. As of the infrastructure
  round: diplomacy and AI ideology policy remain out of scope, and ideology still
  never writes a conserved ledger. Per-cell ideology is **implemented at the
  mechanism level** but has **no production card** using it, and the §22 first
  gate is unlit. X5 "card rewrites another card" is implemented only for
  **effect magnitude**; range/threshold/cap/condition forms are not.

## Production point balance (2026-10-25)

The generator profile uses Q16 point weights 33 / 410 / 3 (population /
buildings / trade), no daily gain ceiling (cap 0 disables clipping on both
native paths), first paid draw cost 7864320 (120 points), +20% per later draw,
and 75% reroll cost (90 points on the first offer).
Retune the generator and regenerate resources; these values change the PKID
catalog hash, so old saves fail closed. UI reads native costs and ledgers.
