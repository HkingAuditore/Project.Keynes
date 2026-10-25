# Ideology Content, UI, and Verification

## Contents

1. Production catalog
2. Authoring SOP
3. UI and PlayerController
4. Tests and verifier
5. Performance diagnosis
6. Documents to keep in sync

## 1. Production catalog

Default resources:

- Generator (single source of truth):
  `Project/project-keynes/tools/ideology/generate_ideology_catalog.py`
- `Project/project-keynes/data/ideologies/default_ideology_catalog.tres`
- UniqueSource Country modifiers in `data/modifiers/default_modifier_catalog.tres`
- Shared Effect templates consumed by `EffectDomainCatalog` / `EffectCatalog`

30 cards in 6 schools of 5 (agrarian 农本, commerce 商贸, learning 学识,
mobilization 动员, industry 工造, harmony 调和). The four original roads
(`idea.collective_stewardship`, `idea.free_exchange`, `idea.scholar_office`,
`idea.civic_muster`) remain. Each card: rarity 1..3 (weights 120/60/20), 3
levels (thresholds 0/4.0/12.0, magnitudes `65536/104858/144179`), its own
`ideology.<key>` definition, optional era technology and cost terms.
Exclusion groups: `economic_order`, `labor_order`, `land_order`.

Synergies: 6 named cross-school pairs (计划仓廪, 特许开拓, 海商账簿, 工役营造,
工业科学, 河渠公社 → `ideology.synergy.*`) and 12 school resonances
(`ideology.resonance.<school>.<2|4>`). Learning tier 4 raises
`country.ideology.point_gain_factor`. The generator also pins
`CRITICAL_FLOORS` (critical-class floors) for selected cards.

Profile: 2/1 base slots growing to 6/3 through `capacity_unlocks`, 0 starting
points, draw cost 6.0 then +20% per draw (geometric), reroll 50% of the paid draw, point weights
0.02/resident, 0.25/building, 0.002/money of daily trade, cap 2.0 per period.

`IdeologyCatalog.catalog_view()` joins Modifier presenter lines into
`level_effect_lines`, `required_technology_names`, and synergy tooltips, and
exposes `capacity_unlock_technology_names`, so the panel never reads Modifier
stores.

Do not restore a shared `country.economic_mobilization` stub. Changing
definition keys or term values changes Modifier and Effect catalog hashes;
existing PKCM/PKEF saves fail closed on purpose.

## 2. Authoring SOP

When adding or retuning an ideology:

0. Edit `generate_ideology_catalog.py` and regenerate; do not hand-edit the
   generated `.tres` rows.
1. Author `IdeologyDefinition` with stable `idea.*` ID, 1–64 monotonic Q16
   levels, acquisition flags, slot costs, optional `exclusion_group`, and
   sparse `IdeologyClassStance` rows whose `class_id` exists in the economy
   profession-class catalog.
2. Author UniqueSource Country Modifier definitions that reuse existing
   country/economy stats. Never mint cash, goods, or population.
3. Attach reversible `EffectCommand` persistent rows (`target_resolver=1`,
   Modifier apply). Put one-shots only in `on_enter_effects`.
4. If two or more roads interact, add `IdeologySynergyDefinition` with matching
   array lengths, location masks in `{2,4,6}`, and reversible synergy effects.
5. Keep worst-case `persistent*2 + on_enter + affected synergy effects` at or
   below `IdeologyProfile.max_transition_commands`.
6. Compile through `IdeologyCatalog.compile_native_catalog()` against current
   country and economy catalogs. Unknown technology/signal/class keys must fail
   here, not at runtime.
7. Update `ideology_content_test.gd` presenter expectations and any Modifier
   catalog tests that pin the UniqueSource terms.
8. Update `docs/cpp-dots-runtime/native-ideology-runtime.md` production table
   and this skill when display names or magnitudes change.

Draw requirements may be `TECHNOLOGY`, `RESEARCH_SIGNAL`, or `GATE`. Gates are
runtime bits flipped by `SET_IDEOLOGY_GATE`; they are not Country technology.

## 3. UI and PlayerController

Player opcodes enter only through `PlayerController`:

- `ideology.offer`
- `ideology.reroll`
- `ideology.choose`
- `ideology.equip`
- `ideology.unequip`
- `ideology.promote`

`IdeologyFacade` packs producer/sequence batches, drains receipts, and emits
`command_settled` for producer 1. GM/discover/grant/gate helpers exist on the
facade for tests; do not wire them as unmarked player cheats in release UI.

Draw flow (`PlayerController`): preview eligibility first (no time advance
when ineligible) → submit → remember clock running/speed → lock other player
commands except ideology choice and era reward → run 1x → pause on the new
`offer_active` generation and emit `ideology_offer_ready`. Choose and reroll
reuse the flow, then restore the clock. Rejection or a 3-day timeout
(`IDEOLOGY_DRAW_TIMEOUT_DAYS`) unlocks with a message. The state is saved in
`player_view`; `ideology_draw_state_changed(phase, detail)` drives the UI.
Equip/unequip/promote remain next-day with a pending stamp.

`IdeologyWorkspace` is Facade-only. It rebuilds rows when the compact native
snapshot or support/explain signature changes. Layout: point scroll (points,
next cost, last gain, ledger popup with source breakdown, multipliers and a
32-strip history), offer stage (3 `IdeologyCard`s, reroll, dismiss), deck
table (ideology niches, lacquer spirit niches, locked niches naming the
required technology, resonance bar with 6 emblems and tier pips, red threads
for active named synergies, dashed preview during drag), and a collection grid
with school tabs and sort. Drag into a niche equips, drag out unequips, drag
onto a spirit niche promotes after confirmation; buttons and focus navigation
remain. Motion: unroll shader, 120 ms staggered drop + flip, rare gloss,
legendary ink and seal, stamp punch + 4px shake on choose, fold and fly to the
collection, torn-paper reroll; a reduce-motion toggle disables it. Art lives in
`assets/ui/ideology_v1/` (see its README). It must:

- Show catalog slot capacities for `materialized=false` countries instead of
  `0/0` gauges.
- Show `level_effect_lines` on offer cards and collection rows.
- Confirm national-spirit promotion as irreversible.
- Call `explain_ideologies()` once per revision, never per row.
- Keep no second writable ideology model in UI nodes.

`CountryViewModel` owns the ideology section cache and
`ideology_support_revision`. Inspector merge must not copy a global
country×ideology matrix into GDScript.

## 4. Tests and verifier

Required focused fixtures:

| Fixture | What it proves |
|---|---|
| `tests/ideology_runtime_test.gd` | Discover/offer/equip ACK, promotion slot release, PKID/PKEF binding audit, late Effect attach, native-only transactions |
| `tests/ideology_opinion_synergy_test.gd` | Committed class snapshot, directional/critical floors, exclusion, reverse-CSR synergy in one transaction |
| `tests/ideology_content_test.gd` | 30 cards / 6 schools / 3 levels / rarities, 18 synergy rows (2/4 resonances), thresholds, start=0, cost curve, slot unlocks, modifier keys, presenter lines |
| `tests/ideology_draw_flow_test.gd` | Pause/step-one-day draw, offer-ready signal, clock restore, reject/timeout unlock, player_view restore |
| `tests/player_country_ui_smoke_test.gd` | Fresh session: 0 points, draw disabled, niches present |
| `tests/ideology_progression_test.gd` | Zero start, baseline-only first observation, preview gate, technology slot capacity, cost curve and cap, reroll cost, school resonance at 2 cards |
| `tests/runtime_ideology_save_roundtrip_test.gd` | IDP2 roundtrip and transactional rejection |
| `tests/ideology_runtime_stress_test.gd` | 512 countries × 12 active, zero dormant/sparse scans, continuation p95, no GDScript fallback poll |
| `tests/ideology_workspace_screenshot_qa.gd` | Rendered (no `--headless`) real-session worker path: grant → draw → present → choose; PNGs at 1280x720 / 1920x1080 in `res://tmp/ideology_workspace_qa/`. Run it several times: a flaky "points stay 0 / offer never presented" means the worker opinion hand-off or snapshot generation cursor regressed |

Run from the repository root:

```powershell
& .\.codex\skills\project-keynes-ideology-runtime\scripts\verify_ideology_runtime.ps1 -Build -Godot
```

Also run affected `effect_runtime_test.gd`, `modifier_runtime_test.gd`,
Trigger ideology-command fixtures, and `player_country_ui_smoke_test.gd` when
those boundaries move. Report unrelated pre-existing suite failures separately.

## 5. Performance diagnosis

Inspect `get_ideology_report()` / headless CSV `bd_ideology_*` before changing
cadence:

1. `last_slice_ms` then `transition_poll_ms`, `command_apply_ms`,
   `active_progress_ms`.
2. `active_visits`, `pending_transition_visits`, `commands_applied`.
3. Quiescent counters: `sparse_idea_scan_count`, `dormant_scan_count`,
   `command_queue_resorts`, `command_queue_shift_steps`.
4. Structural-only counters: `class_snapshot_reads`, `support_evaluations`,
   `synergy_candidates_visited`.
5. Effect ACK: native claimed transactions, overflow, GDScript poll count
   (must stay 0 for ideology).
6. Economy COMMIT: `bd_class_opinion_*`. `last_cells_scanned` equals stable
   market-cell count; a COMMIT must not run a second ideology cohort scan.

Gates (same machine, same debug DLL, fixed seed):

- 64 countries × 12 active: ideology p95 ≤ 0.35 ms
- 512-country continuation slice: p95 ≤ 0.42 ms, no native call > 1 ms
- 6400-cell class-opinion median < 1 ms

`IdeologyRuntimeSystem.slice_budget_ms` is 0.35. Do not raise it to hide a
full discovered-idea scan.

## 6. Documents to keep in sync

Update in the same change when the contract moves:

- `docs/cpp-dots-runtime/native-ideology-runtime.md`
- `docs/cpp-dots-runtime/native-effect-runtime.md` (external binding / PKID audit)
- `docs/cpp-dots-runtime/native-modifier-runtime.md` (ideology UniqueSource keys)
- `docs/cpp-dots-runtime/gdscript-cpp-data-bridge.md`
- `docs/cpp-dots-runtime/scheduling-and-job-graph.md`
- `docs/cpp-dots-runtime/runtime-authority-matrix.md`
- `docs/cpp-dots-runtime/game-flow-start-save.md`
- `docs/cpp-dots-runtime/performance-diagnostics-playbook.md`
- `docs/cpp-dots-runtime/index.md`
- `references/system-map.md`
- this skill and its references

Intentional non-goals until separately designed: ideology diplomacy, AI
adoption policy, per-cell ideology, ideology as a conserved ledger, player
drafting of Modifier formulas at runtime, and GDScript evaluation in the
daily graph.

UI text stays minimal: numbers on the point scroll (points / cost, last gain), short button labels (抽取 · X, 重抽 · X), hint line hidden unless blocked, detail only in tooltips. A paid draw floats a -X on the scroll.

## Production text audit (2026-10-25)

The current pool has 113 published cards / 339 levels, 280 managed programs,
and 40 visible synergies. Twenty-one holdouts remain outside the pool.

- Edit `Project/project-keynes/tools/ideology/generate_ideology_catalog.py`.
  Production summaries come from `player_program_summary()` using executable
  selectors, conditions, command stats, ramps, and live Good/Need names.
  `Prog.summary` remains an author note/diagnostic field for production rows.
- Run `validate_player_text()` before writing resources; an unknown program or
  rewrite shape must fail generation, never fall back to an invented promise.
- `housing` is the household-plan category 居住维护; describe its modifier as 居住维护消费需求. `lumber` means 木材 (`logs` is 原木).
  `cell.depleted` currently reads maximum market-good shortage, not deposits.
- Do not restore `CARD_FACE_PROGRAM_OVERRIDES`, strip target caps, or truncate
  visible effect lines to six. Bonus, cost, rule, and one-shot lines all matter.
- Hidden self-synergy `note` strings describe actual selector rewrites; render
  them with their ideology-slot restriction. They do not mutate tile tags.
- Export details, all levels and synergies with `tools/ideology/export_card_faces.gd`.
  Run `tests/ideology/ideology_card_face_semantics_test.gd` and
  `python -m unittest discover -s tools/ideology -p test_ideology_player_text.py`.
- Text-only edits must preserve every executable field in the generated ideology,
  Effect and Modifier catalogs. No native build/schema/save migration is needed.
