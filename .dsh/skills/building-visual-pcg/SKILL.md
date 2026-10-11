---
name: building-visual-pcg
description: Use when implementing, tuning, debugging, or reviewing Project.Keynes building visuals driven by authoritative economy, technology era, visibility intelligence, terrain, and weather data. Covers industry visual families, population-driven housing, wealth and rich/poor districts, C++ settlement planning, true top-down procedural roofs and facades, cast shadows and ground decals, 2D MultiMesh/shader rendering, eras and seasonal snow, fog memory, the art harness, and performance validation.
---

# Building Visual PCG

Use this project-local skill for the visual representation of economic buildings on the
strategic map. The layer is a read-only consumer of native economy, country technology,
vision, terrain, climate, and weather state. It must make a cell read as a settlement and
make a single building read as a house before adding decorative detail.

This is a true top-down 2.5D system: the C++ planner plans a settlement per cell (plaza,
streets, frontage lots, houses, villas, shanties, fields) and emits one instance per building
volume plus one per ground feature. Population (settlement tier) sets the housing skeleton,
the scale-weighted mix of 22 visual families sets land use with log compression, and the
living level plus rich/poor share buckets set material quality and districts. CanvasItem shaders draw procedural roofs with one parallax step and
an analytically intersected facade sliver, build sun-driven shadow hulls in the vertex stage
(no ray marching), and paint era-specific ground, all lit by the shared earth
daylight model with seasonal snow. There are no external art assets, no 3D meshes, and no
node per building.

## Grounding Pass

Before changing behavior, read the current implementation and its contract:

- `Project/project-keynes/scripts/rendering/building_visual_layer.gd`
- `Project/project-keynes/scripts/rendering/building_visual_intel_cache.gd`
- `Project/project-keynes/scripts/rendering/building_visual_family_table.gd` and
  `Project/project-keynes/data/rendering/building_visual_families.tres` (family rules,
  construction-good build grades)
- `Project/project-keynes/shaders/building_compound.gdshader`
- `Project/project-keynes/shaders/building_macro.gdshader`
- `Project/project-keynes/shaders/building_shadow.gdshader`
- `Project/project-keynes/shaders/building_ground_decal.gdshader`
- `Project/project-keynes/shaders/include/building_form.gdshaderinc` (instance ABI, form /
  material / ground ids, roof height fields)
- `gdext/src/world_ext_building_visual.cpp` (planner, encoder, `NativeBuildingVisualCache`)
  and `gdext/src/building_visual_cache.h`
- `gdext/src/world_ext_economy.cpp`, `gdext/src/world_ext_country.cpp`
- `gdext/src/economy_runtime.{h,cpp}`, `economy_runtime_events.cpp`
  (`publish_social_pressure_facts`, hysteretic social bands), `economy_runtime_read_view.cpp`
  and `gdext/src/country_runtime.{h,cpp}`
- `Project/project-keynes/scripts/economy/economy_catalog.gd`
- `Project/project-keynes/scripts/economy/technology_catalog.gd`
- `Project/project-keynes/scripts/geography/vision_solver.gd`
- `Project/project-keynes/scripts/game/world_runtime_host.gd`
- `Project/project-keynes/tests/building_visual_*_test.gd`
- `docs/cpp-dots-runtime/building-visual-runtime.md`

Search for these symbols before inventing an API: `get_building_visual_snapshot`,
`consume_building_visual_dirty_cells`, `consume_country_visual_era_dirty_slots`,
`NativeBuildingVisualCache`, `plan_cells`, `BuildingVisualIntelCache`, `current_visual_era`,
`TechnologyCatalog`, `BuildingVisualFamilyTable`, `type_to_family`, `settlement_tiers`,
`living_levels`, `rich_buckets`, `poor_buckets`, `mark_building_visual_cell`,
`MultiMeshInstance2D`, `INSTANCE_CUSTOM`, `snow_cover`, and `weather_lut`.

Read only the references needed for the task:

- [art-direction.md](references/art-direction.md) for settlement readability, visual
  families, population and wealth language, era language, and weather cues.
- [runtime-contract.md](references/runtime-contract.md) for native authority, CSR snapshots
  and social band columns, country eras, fog intelligence, PKFG v3, and update ordering.
- [performance.md](references/performance.md) for the background cache, buffers, chunks,
  budgets, shader cost, diagnostics, and validation gates.

## Non-negotiable Rules

- Treat C++ native runtime state as the sole authority for building counts, ownership,
  technology completion, and committed timing. GDScript may schedule, compile resources,
  upload buffers, update nodes, and run compatibility tests; it must not duplicate simulation.
- Derive era only from completed era milestones in the existing `TechnologyCatalog`. Do not
  infer era or category from filenames, English IDs, years, output goods, or guessed history.
- Use the submitted building visual CSR. Never scan `_buildings` during rendering, create a
  `cell x building_type` dense matrix, or publish a partial building slice.
- Use `BuildingVisualIntelCache` for player knowledge. Hidden foreign construction, foreign
  era changes, real-time snow, and real-time rain must not enter remembered geometry or PKFG.
- `plan_cells` in `world_ext_building_visual.cpp` is the only geometry implementation. At
  runtime it runs per cell on the `NativeBuildingVisualCache` worker thread;
  `DCWorldExt::bake_building_visual_chunk` is its synchronous wrapper for tests and tools.
  There is no GDScript baker; a missing class or failed configure disables near geometry
  (fail-closed, one diagnostic) and leaves the Macro layer running. Do not reintroduce a
  script fallback.
- Visual work must stay far below simulation cost. Layout never runs on the main thread in
  the game, and only cells whose input changed are replanned. The main thread only submits
  changed rows and uploads assembled chunks; never loop over all known cells per frame or
  per camera move.
- Layout is deterministic: stable input order, stable hashing on `cell/family-or-slot-kind/
  rank/layout_seed`, sequential placement, and fixed float packing are part of the contract.
- Industry lots follow a log ladder of the scale-weighted building total split by
  `weight^0.75`; not every type must appear, but a bigger industry never gets fewer or
  smaller lots. Housing follows the settlement tier, not the building count; villas and
  shanties follow the rich/poor buckets. Buildings stay inside their own hex.
- Social bands (living level, rich/poor share) are presentation-only, hysteretic, and
  computed natively in the existing social-pressure scan. They mark only their cell dirty,
  never persist in PKEC, and never enter the state hash. Do not compute them in GDScript.
- Visual families, scale, and build grade are derived from catalog data by the family table
  (tag, sector/kind, climate, resource, keyword). Keep zero fallback types; add a rule or a
  `visual.family.<id>` tag instead of guessing from filenames in code.
- Settlement streets are visual-only plaza/frontage roads inside the cell. They are not a
  transport network and must not feed simulation. River and water exclusion use the existing
  flow SDF.
- Keep the instance ABI in `building_form.gdshaderinc` and the C++ encoder in sync; any new
  form, material, or ground kind needs both sides and the art harness.
- Share one quad mesh and one material per pass. Do not create a node, material, or
  MultiMesh for every building type, era, or cell.
- Weather, snow, fog, sunlight, and day/night are shader inputs. They must not rewrite
  instance transforms or rebuild buffers every day or every frame.
- Preserve economy state hashes, PKEC content, save authority, and deterministic scalar/native
  behavior when changing only visual code.

## Implementation Workflow

1. State the authority boundary, input columns, output buffer, cadence, failure mode, and
   quality/platform profile before editing.
2. Audit the full authored building catalog and era milestone catalog. Record unresolved
   archetypes as errors; do not repair them with heuristics.
3. Update the native snapshot/intelligence path first when the task changes data visibility.
   Validate CSR shape and apply snapshots atomically before touching cached rows.
4. Submit only changed cells to the cache; the worker discards results whose cell
   generation moved on while it planned. Never hand the worker Godot objects.
5. Upload ready chunks within the per-frame budget. Use resident management and the
   `lod_fraction` rank cutoff for LOD; do not replan or rebuild chunks on camera movement.
6. Validate the visual result with `tests/_tmp_building_art_harness.tscn` (all 11 eras × 6
   local economies with tier and wealth bands, snow row, night/dusk, `detail` close-ups,
   `wealth` sweep) before and after tuning. Read the screenshots; do not tune blind.
7. Rebuild debug and release DLLs after C++ edits, run focused tests, the native stress
   fixture, and `git diff --check` for changed files. Report measured results and limitations.

## Review Questions

When reviewing a change, check in this order:

1. Does the cell read as a settlement of its era (plaza, streets, roofs, fields), can a
   player tell its dominant industry, rough size, and wealth apart from a neighbour's?
2. Does the visible result use only data the player is allowed to know?
3. Does an era change come from a completed technology milestone and affect proportions or
   modules, rather than only recoloring the same marker?
4. Are geometry, shadows, decals, and vegetation still deterministic and spatially coherent?
5. Does the change preserve the native path, sparse memory model, draw-call budget, and the
   no-per-frame-instance-update rule?

For detailed decisions and measured baselines, use the linked references rather than copying
the full implementation into every feature task.
