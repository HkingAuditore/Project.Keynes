---
name: building-visual-pcg
description: Use when implementing, tuning, debugging, or reviewing Project.Keynes building visuals driven by authoritative economy, technology era, visibility intelligence, terrain, and weather data. Covers top-down house readability, procedural building compounds, C++ numeric baking, 2D MultiMesh/shader rendering, fog memory, snow/shadows, and performance validation.
---

# Building Visual PCG

Use this project-local skill for the visual representation of economic buildings on the
strategic map. The layer is a read-only consumer of native economy, country technology,
vision, terrain, climate, and weather state. It must make a cell read as a settlement and
make a single building read as a house before adding decorative detail.

This is a top-down 2D/2.5D system: CanvasItem shaders and 2D MultiMesh instances provide
roof planes, walls, foundations, small facilities, contact AO, snow, and analytical false
shadows. It is not a 3D building simulation and it is not a collection of one node per
building.

## Grounding Pass

Before changing behavior, read the current implementation and its contract:

- `Project/project-keynes/scripts/rendering/building_visual_layer.gd`
- `Project/project-keynes/scripts/rendering/building_visual_intel_cache.gd`
- `Project/project-keynes/shaders/building_compound.gdshader`
- `Project/project-keynes/shaders/building_macro.gdshader`
- `Project/project-keynes/shaders/building_shadow.gdshader`
- `Project/project-keynes/shaders/building_ground_decal.gdshader`
- `gdext/src/world_ext_building_visual.cpp`
- `gdext/src/world_ext_economy.cpp`, `gdext/src/world_ext_country.cpp`
- `gdext/src/economy_runtime.{h,cpp}` and `gdext/src/country_runtime.{h,cpp}`
- `Project/project-keynes/scripts/economy/economy_catalog.gd`
- `Project/project-keynes/scripts/economy/technology_catalog.gd`
- `Project/project-keynes/scripts/geography/vision_solver.gd`
- `Project/project-keynes/scripts/game/world_runtime_host.gd`
- `Project/project-keynes/tests/building_visual_*_test.gd`
- `docs/cpp-dots-runtime/building-visual-runtime.md`

Search for these symbols before inventing an API: `get_building_visual_snapshot`,
`consume_building_visual_dirty_cells`, `consume_country_visual_era_dirty_slots`,
`bake_building_visual_chunk`, `BuildingVisualIntelCache`, `current_visual_era`,
`TechnologyCatalog`, `MultiMeshInstance2D`, `INSTANCE_CUSTOM`, `snow_cover`, and
`weather_lut`.

Read only the references needed for the task:

- [art-direction.md](references/art-direction.md) for house silhouette, fixed orientation,
  archetypes, era language, and the boundary between style slots and unique assets.
- [runtime-contract.md](references/runtime-contract.md) for native authority, CSR snapshots,
  country eras, fog intelligence, PKFG v2, and update ordering.
- [performance.md](references/performance.md) for the C++ baker, buffers, chunks, budgets,
  shader cost, diagnostics, and validation gates.

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
- Production uses `DCWorldExt::bake_building_visual_chunk`. Keep
  `allow_gdscript_baker_fallback = false` by default. Enable the GDScript baker only in an
  explicit compatibility test or stale-DLL investigation; never silently fall back in play.
- Keep C++ and fallback numeric algorithms equivalent and deterministic. Stable input order,
  stable hashing, fixed layout version, fixed orientation, and fixed float packing are part of
  the visual contract.
- One authoritative building (`total == 1`) produces exactly one compound at the cell center.
  Buildings do not randomly rotate. The foundation is always at the lower side of the glyph.
  Larger counts use logarithmic visual compounds, not one sprite per economic building.
- Share superset meshes, materials, and shader variants. Do not create a node, material, or
  MultiMesh for every building type, era, or cell.
- Weather, snow, fog, sunlight, terrain normal, and horizon are shader inputs. They must not
  rewrite instance transforms or rebuild buffers every day or every frame.
- Keep roads out of layout decisions until an authoritative road mask exists. River and water
  exclusion are valid because those masks/SDFs are available.
- Preserve economy state hashes, PKEC content, save authority, and deterministic scalar/native
  behavior when changing only visual code.

## Implementation Workflow

1. State the authority boundary, input columns, output buffer, cadence, failure mode, and
   quality/platform profile before editing.
2. Audit the full authored building catalog and era milestone catalog. Record unresolved
   archetypes as errors; do not repair them with heuristics.
3. Update the native snapshot/intelligence path first when the task changes data visibility.
   Validate CSR shape and apply snapshots atomically before touching cached rows.
4. Build a pure numeric chunk input, bake it in C++, and validate generation before uploading
   a result. Discard stale worker results instead of uploading them.
5. Upload at most the profile's allowed chunk budget. Use resident management and visible
   instance prefixes for LOD; do not rebuild unchanged chunks on camera movement.
6. Validate the visual result at overhead zoom before adding texture detail. A clear roof ridge,
   wall mass, lower foundation, door/windows, and category facility must survive low zoom.
7. Run focused tests, native debug/release builds, parser/shader checks, performance fixtures,
   and `git diff --check` for changed files. Report measured results and remaining limitations.

## Review Questions

When reviewing a change, check in this order:

1. Can a player immediately identify a house, its ground contact, and its main category?
2. Does the visible result use only data the player is allowed to know?
3. Does an era change come from a completed technology milestone and affect proportions or
   modules, rather than only recoloring the same marker?
4. Are geometry, shadows, decals, and vegetation still deterministic and spatially coherent?
5. Does the change preserve the native path, sparse memory model, draw-call budget, and the
   no-per-frame-instance-update rule?

For detailed decisions and measured baselines, use the linked references rather than copying
the full implementation into every feature task.
