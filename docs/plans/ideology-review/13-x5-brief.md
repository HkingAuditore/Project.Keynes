# 13 - X5 brief: per-country program rewrites (reviewer, 2026-10-23)

Roadmap slot: after R-7 (12-r7-brief A-G), i.e. 11 §3 "R-6 X5".
Worker path only. Parity frozen. No balance work. Line numbers checked 19:50.

## 0. What is blocked and what it actually needs

Single-blocker X5 cards (reachability matrix, `ideology-build-redesign.md:3592-3599`):

| card | design rule (§ line) | primitive needed |
|---|---|---|
| antibiotics | "大邑" conditions use settlement threshold P1 (:175) | tag swap `cell.metropolis -> cell.settlement` on every program |
| vertical_farm | metropolis counts as agriculture pillar (:592) | tag widen `cell.sector.agriculture -> sector.agriculture OR metropolis` |
| desalination | coast counts as delta/floodplain (:290) | tag widen `cell.landform.delta / cell.terrain.floodplain -> ... OR coast` |
| space_mining | any ore satisfies every ore condition (:596) | tag widen `cell.produces.<ore> -> any ore` |
| autonomous_logistics | thoroughfare range +1 (:241) | selector kind `R1 -> R2` on route `thoroughfare` |
| green_revolution | neighbour-count range to 2 rings, ring 2 at 50% (:158) | needs X1-b ring weights - defer |
| e_commerce | out-of-range markets at 50% (:576) | conditional extra program - defer |
| encyclopedia | strength +5% per distinct school (:253) | X7 ideology-side count -> magnitude - defer |

So one primitive - **"while condition C holds for this country, rewrite the
selector of every program matching M"** - unlocks 5 of the 8 now, and most of the
synergy-table X5 rows (`:307-332`, `:648-661`: threshold -N, range +1, "counts as").

## 1. What already exists (reuse, do not rebuild)

- Synergies as the per-country condition carrier: `synergy_requirements_met`
  (`ideology_runtime.cpp:1131`), bits in `country.active_synergy_bits`, copied from
  the worker pod on every snapshot (`:756`); worker apply marks refresh dirty (`:923`).
- Override rows: `IdeologySynergyDefinition.overrides` (gd `:40`), compiled into
  `synergy_override_offsets/programs/scales` (`ideology_catalog.gd:418-433`), read at
  `ideology_runtime.cpp:262-267,501-547`; program -> rows index
  `_synergy_override_index`; lookup `magnitude_scale_for` (`:2623`).
- Signature already mixes `active_synergy_bits` when overrides exist (`:2096`), so a
  synergy flip re-reconciles the card on the next refresh pass.
- Selector resolve in one place: `resolve_effect_targets` (`:1496-1580`) reads
  `metadata.target_selector_kind` and `target_selector_param[0..1]`.
- Tag table names are available natively: `TargetTagTable::names` (`target_tag.h:70`).
- Tag AND composition at compile time: `TargetTagDictionary.intersection`
  (`target_tag_dictionary.gd:314`), appended into `tag_list`
  (`effect_domain_catalog.gd:441-470`).

Only `MAGNITUDE_SCALE` is accepted today (`ideology_synergy_definition.gd:87`), and the
override target is a single program key.

## 2. Design

### 2.1 Override row (catalog data, no save field)

```
ProgramRewrite {
  match_kind:  PROGRAM | TAG | ROUTE      // which programs it applies to
  match_value: program key | tag name | route id
  field:       MAGNITUDE_SCALE | TAG | SELECTOR_KIND | SELECTOR_CAP
  value:       int (scale q16, kind, cap) | tag name (for TAG)
}
```

- `match_kind=TAG`: every managed program whose resolved selector tag id equals the
  tag. This is what "所有大邑条件" means.
- `match_kind=ROUTE`: every program of a card whose `route` is the value
  (`CARD_META[...].route`). This is "所有通衢理念".
- `field=TAG`, value = a tag name or a union expression `a|b|c`. Union tags are
  compiled like intersections: add `TargetTagDictionary.union(names, tags)` that
  concatenates the clause groups (clause = OR) and renumbers clauses; append to
  `tag_list` exactly like `_apply_selector_tags` does (ids only append).
- Ancestry: extend `IdeologyEffectParameter` with the new fields; keep
  `MAGNITUDE_SCALE` rows working unchanged.

### 2.2 Condition = a synergy (including "this card is equipped")

Cards like antibiotics rewrite others by themselves. Generator emits a **hidden
self-synergy** per card level: `required_ideology_ids=[card]`,
`minimum_levels=[L]`, `location_masks=[2]` (equipped; spirit = 4). Add
`hidden: bool` to `IdeologySynergyDefinition` so it never shows in the resonance UI
(`ideology_workspace.gd:839`) or the card's "联动" line (`ideology_catalog.gd:741`).
Named two-card synergies (`NAMED_SYNERGIES`) carry rewrites the same way.

Conflict rule (L3 activates L1/L2 self-synergies too): for TAG/KIND/CAP the active row
with the highest `(minimum_level, synergy id)` wins per (program, field); scales keep
multiplying as today.

### 2.3 Native

1. Columns: `synergy_override_kinds`, `..._match_kinds`, `..._match_values`
   (strings), `..._values` (int), `..._tag_names` (strings). Same offsets array.
2. Resolve tag names to ids **once** at configure / `set_target_tags` time via
   `TargetTagTable::names`; unknown name -> configure fails
   (`ideology_synergy_override_tag_unknown`), never silently matches nothing.
3. Build at configure: `program_hash -> [row]` for PROGRAM, `tag_id -> [row]` for
   TAG. **ROUTE is NOT resolved natively** (reviewer-verified 2026-10-23: native
   has no per-ideology route column; routes exist only in GDScript
   `ideology_catalog.gd:389-397` `route_index`, used to expand route synergies).
   Therefore `match_kind=ROUTE` is expanded in `ideology_catalog.gd` at compile
   time into one PROGRAM row per program of every card in `route_index[route]`
   (same pattern as `_expand_route_synergy_members`). Native only ever sees
   PROGRAM and TAG rows; unknown route -> compile fails
   `ideology_synergy_override_route_unknown`.
4. New `effective_selector(country, ideology_id, program, metadata) -> metadata copy`
   applied at the top of `resolve_effect_targets`, before line 1501. Scale keeps its
   own path (`magnitude_scale_for`).
5. Signature: change the guard at `:2096` from `_synergy_override_scales.empty()` to
   "any override rows". No other dirtying needed (worker flip -> `apply_pod_snapshot`
   -> dirty -> signature differs).
6. Instance ids already mix `target_handle`, so a widened tag simply adds/retires
   instances through the normal reconcile; no id change for untouched targets.

Worker: nothing in the pod. Rewrites are resolved where instances are resolved
(main-side `NativeIdeologyRuntime`, driven by `step_ideology_instance_refresh` in
worker mode). Catalog hash changes; old saves fail closed. No PKID / ABI bump.

Limitation to record in 02: Effect program `conds` (metric thresholds inside the
program) are shared templates and are NOT rewritten. Content that needs a
threshold change must express the threshold as a tag (2.4).

### 2.4 Threshold variants without new GDScript per card

"繁市阈值 T 降低 25%" / "大邑阈值降低 20%": add a parametric tag name
`<scale_tag>@<pct>` handled in `TargetTagDictionary` for the scale atoms only
(`cell.frontier/settlement/metropolis/market`): rows of the atom with
`threshold_q16 * pct / 100`. A rewrite then names `cell.metropolis@80`. Compiled on
demand like intersections, so the dictionary stays generic and new cards stay
generator-only.

### 2.5 Generator

- `Rewrite(match_tag=..., tag=...)`, `Rewrite(match_route=..., kind=SEL_TAG_SOURCE_R2)`,
  `Rewrite(match_program=..., scale=1.5)`; per-level list `LEVEL_REWRITES[card]`.
- Emit self-synergies for cards with rewrites; emit rewrites on named synergies.
- Lints (hard fail): match tag not used by any published program; route unknown;
  KIND rewrite outside 14<->15 / 6<->7; CAP > 32; TAG rewrite on a non-tag selector;
  a rewrite whose only matches are staged cards.
- Add `X5` to `AVAILABLE_CAPABILITIES` after the worker test passes.
- Content (C later, but R writes the 5 cards here to prove the path): antibiotics,
  vertical_farm, desalination, space_mining, autonomous_logistics (L1 range part;
  T-threshold L2 via 2.4).

## 3. Worker test (`tests/ideology/ideology_x5_rewrite_worker_test.gd`, 0xFFF)

One card pair per process, cell reads per 12 §F notes
(`evaluate_modifier_stat(2, 0, cell, stat, 1.0)`):

1. Equip `urban_sanitation` (metropolis cells). Pick a settlement-but-not-metropolis
   cell from the map -> stays 1.0.
2. Equip `antibiotics` -> that cell reads `1 + value`; instance report
   `target_handles` now contains it.
3. Unequip `antibiotics` -> back to 1.0, instance retired.
4. Save roundtrip with both equipped -> same value after restart.
5. KIND rewrite: `autonomous_logistics` + a thoroughfare R1 card -> a ring-2 cell
   gains the effect, removed on unequip.

Accept: N/0 twice, 0 SCRIPT ERROR, no event 1000; generator tail shows
`cards_published` +5 and the audit's "缺 1 项" X5 rows drop by 5.

## 4. Report format

Same as 12: files:lines, raw last test line, DLL timestamp, generator tail,
event-log check; unfinished items as "not done + blocker".
