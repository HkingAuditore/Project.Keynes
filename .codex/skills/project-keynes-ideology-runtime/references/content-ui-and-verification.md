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

- `Project/project-keynes/data/ideologies/default_ideology_catalog.tres`
- UniqueSource Country modifiers in `data/modifiers/default_modifier_catalog.tres`
- Shared Effect templates consumed by `EffectDomainCatalog` / `EffectCatalog`

Four roads, one exclusion group, two synergies:

| Stable ID | Display | Modifier key | Notes |
|---|---|---|---|
| `idea.collective_stewardship` | 共同体治理 | `ideology.collective_stewardship` | Exclusive `economic_order` |
| `idea.free_exchange` | 自由交换 | `ideology.free_exchange` | Exclusive `economic_order` |
| `idea.scholar_office` | 学识官署 | `ideology.scholar_office` | Forms 计划仓廪 with stewardship |
| `idea.civic_muster` | 公民动员 | `ideology.civic_muster` | Forms 特许开拓 with free exchange |
| `synergy.planned_granaries` | 计划仓廪 | `ideology.synergy.*` | Both members equipped or promoted |
| `synergy.chartered_frontier` | 特许开拓 | `ideology.synergy.*` | Both members equipped or promoted |

Level 1 applies Q16 `65536`. Level 2 replaces the same definition at `131072`.
Synergies add a third UniqueSource while both requirements remain satisfied.
`IdeologyCatalog.catalog_view()` joins Modifier presenter lines into
`level_effect_lines` and synergy tooltips so the panel never reads Modifier
stores.

Do not restore a shared `country.economic_mobilization` stub. Changing
definition keys or term values changes Modifier and Effect catalog hashes;
existing PKCM/PKEF saves fail closed on purpose.

## 2. Authoring SOP

When adding or retuning an ideology:

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
- `ideology.choose`
- `ideology.equip`
- `ideology.unequip`
- `ideology.promote`

`IdeologyFacade` packs producer/sequence batches, drains receipts, and emits
`command_settled` for producer 1. GM/discover/grant/gate helpers exist on the
facade for tests; do not wire them as unmarked player cheats in release UI.

`IdeologyWorkspace` is Facade-only. It rebuilds rows when the compact native
snapshot or support/explain signature changes. It must:

- Show catalog slot capacities and starting-point preview for
  `materialized=false` countries instead of `0/0` gauges.
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
| `tests/ideology_content_test.gd` | Four unique modifier keys, presenter lines, empty-cabinet UI, offer effect text |
| `tests/ideology_runtime_stress_test.gd` | 512 countries × 12 active, zero dormant/sparse scans, continuation p95, no GDScript fallback poll |

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
