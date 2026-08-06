# Module Boundaries

This document is the source of truth for source-file decomposition. It is a
maintenance rule, not a proposal for a second runtime architecture.

## Ownership

| Area | Stable facade | Implementation owners | Must not own |
| --- | --- | --- | --- |
| World generation | `scripts/geography/map_generator.gd` | `geography/map_generation/*` | daily simulation or texture encoding |
| Visual baking | `scripts/rendering/map_baker.gd` | `rendering/bakers/*` | map gameplay state or scheduler registration |
| Daily simulation | `MapGenerator` scheduler facade | `simulation/{climate,ocean,sea_ice,biology}/*` | Godot texture/object lifetime |
| Diagnostics | `DCDiagnosticsBus` | domain systems recording reports | simulation authority or slot writes |
| DataCore bridge | `DCWorld` / `DCWorldExt` | slot and pass implementation units | UI policy |
| Economy | `NativeEconomyRuntime` public API | economy domain translation units | per-cell gameplay mirrors in GDScript |

The economy decomposition contract and migration order live in
[`economy-runtime-split.md`](economy-runtime-split.md). It is the required
dependency matrix before changing `economy_runtime.cpp` or `.h`.

## Dependency direction

Facades may assemble and call domain modules. Domain modules may depend on
explicit context objects, schemas, math functions, and narrow capability
interfaces. A leaf module must not call back into a facade's private fields.
Godot upload and object lifetime remain at the rendering boundary. Native code
may publish slots and reports, but may not create Godot rendering objects.

## File-size policy

These are review thresholds, not permission to split unrelated code:

- Facades/orchestrators: target 300 lines, hard review threshold 600.
- GDScript domain modules: target 500 lines, hard review threshold 800.
- GDScript algorithm leaves: hard review threshold 1,200.
- C++ implementation units: target 1,200 lines, hard review threshold 2,000.
- Public headers and binding units: hard review threshold 1,000.

Generated code, shader sources, test fixtures, and data assets are excluded.
An existing over-limit file may only increase through a documented exception;
every extraction must reduce the recorded baseline.

## Migration rules

1. Preserve public class names, scene paths, bound method names, scheduler IDs,
   slot IDs, report keys, and save ordering.
2. Move one cohesive function cluster at a time. Delete the old implementation
   in the same change; do not leave a permanent forwarding duplicate.
3. Every mutable state field has one owner. Consumers receive a snapshot or a
   narrow command/report API.
4. New modules use explicit `preload`/constructor injection in GDScript and
   private headers plus stable public declarations in C++.
5. Update the affected authority, bridge, scheduling, computation, and deletion
   documents in the same change.

## Verification gate

Each extraction must pass static symbol/call-site searches, `git diff --check`,
the relevant GDExtension build, and focused Godot tests. Runtime authority
changes additionally require native/fallback A-B or shadow evidence and a
30-tick diagnostic window.

## Current extraction status

- `DCTerrainGenerator.assemble_native_result()` owns native generation result
  validation and `MapData`/`HexCell` assembly. `MapGenerator` owns only the
  native pass request, generation lifecycle, and public facade.
- `DCClimateBaker.bake_latitude_buffer()` owns the native latitude-field call,
  result validation, and zero-filled failure contract. `MapBaker` owns stage
  progress and bake ordering.
- `DCTerrainBaker.bake_river_sdf()` owns native river-SDF request construction,
  result validation, and the zero-filled failure contract. C++ owns river
  topology tracing and all geometry computation; `MapBaker` only orders the
  stage and publishes `world.flow_buffer`.
- `DCTerrainBaker.bake_hydraulic_erosion()` owns the native erosion request,
  explicit knobs, and result validation. C++ owns droplet computation; the
  caller only replaces `world.height_buffer` with the validated output.
- `DCTerrainBaker.bake_height_biome_moisture()` owns the legacy GDScript
  ground-truth pixel loop and buffer/CSR assembly. It receives noise objects,
  constants, and delegates stateless geometry to
  `DCTerrainGeometryUtils`; the fused native geometry path remains authoritative
  whenever available.
- `DCTerrainGeometryUtils` owns wrapped-cell lookup, cylindrical noise seam
  handling, cube conversion/rounding, raster sextants, barycentric weights, and
  the hypsometric curve. It has no `MapBaker` or `WorldData` state.
- `DCTerrainBaker.rebake_terrain_detail_texture()` owns terrain-detail raster
  generation and R8 encoding. `MapBaker` retains only `WorldData` texture
  assignment and call ordering.
- `DCTerrainIndexBaker` owns native terrain-index request packing, result
  validation, CSR/object-side reverse-index reconstruction, and terrain-edge
  texture encoding. `MapBaker` retains fused geometry ordering and lifecycle.
- `NativeEconomyRuntime` remains the sole economy authority. Storage
  implementations are extracted to `gdext/src/economy_runtime_storage.cpp`,
  while fixed-point arithmetic and pure formula kernels live in
  `gdext/src/economy_runtime_math.cpp`. Frozen tax lookup, fiscal attribution,
  budget/escrow settlement and country transfer commit live in
  `gdext/src/economy_runtime_fiscal.cpp`; the root runtime retains the frozen
  country snapshot capture, registration, stage orchestration, event/report
  handling and cross-module invariants.
- Building graph storage/index helpers are extracted to
  `gdext/src/economy_runtime_building_storage.cpp`; employment, production and
  investment leaves are split into dedicated translation units while the root
  retains stage orchestration.
- Employment aggregate replacement, population-change reconciliation, cell
  wage preparation, labor signal updates and the employment worker leaf are
  extracted to `gdext/src/economy_runtime_building_employment.cpp`; the root
  retains only stage entry/cursor and aggregate accounting.
- Resource access, generation-stamped lanes, consumption and renewable
  harvest limits are extracted to
  `gdext/src/economy_runtime_building_resources.cpp`; production remains the
  only caller of this capability boundary.
- Production climate-capacity evaluation, group preparation, production worker
  and result merge are extracted to
  `gdext/src/economy_runtime_building_production.cpp`; the root retains stage
  entry and worker scheduling.
- Investment scratch/review/evaluation is extracted to
  `gdext/src/economy_runtime_building_investment.cpp`; endogenous investment
  remains native-authoritative and the root retains ordered stage entry.
- Build/demolish command mutation and pending-construction prechecks are
  extracted to `gdext/src/economy_runtime_building_construction.cpp`;
  ordered construction commit lives in
  `gdext/src/economy_runtime_building_commit.cpp`.
- Household demand, market clearing and market result finalization are extracted
  to `gdext/src/economy_runtime_market.cpp`; root stage cursors and result
  aggregation remain the only market orchestration boundary.
- Domestic-trade topology, route cache/planner, signal diagnostics, flow EMA,
  order settlement/dispatch and transit/escrow queries are extracted to
  `gdext/src/economy_runtime_trade.cpp`; trade stage entry, cursor movement,
  cross-stage aggregation and public API remain in the root facade.
- Merchant procurement quota and active-good refresh remain building/production
  capability helpers; they are intentionally not duplicated in the trade module.
- Save/restore lifecycle and committed-boundary validation live in
  `gdext/src/economy_runtime_persistence.cpp`; ordered PKEC encoding lives in
  `gdext/src/economy_runtime_persistence_write.cpp`, and validated section decoding
  lives in `gdext/src/economy_runtime_persistence_read.cpp`.
- `gdext/src/economy_runtime_persistence_codec.h` is the single PKEC magic and
  section-number contract. `gdext/src/economy_runtime_binary_codec.h` owns the
  shared stateless little-endian/string/ID-table helpers; root event archive code
  and PKEC code must not duplicate them.
- Settlement/population query formatting is extracted to
  `gdext/src/economy_runtime_queries_population.cpp`. Market, satisfaction,
  fiscal, building, family, notable-person and per-cell trade-order facade methods
  are extracted to `gdext/src/economy_runtime_queries_market_building.cpp`.
  Neither query unit owns stage cursors or mutable economy state.
- Stateless Godot variant decoding shared by the root and extracted query facade
  lives in `gdext/src/economy_runtime_variant_helpers.h`; helper implementations
  must not be copied into individual translation units.
- Stable-ID and compiled metadata validation live in
  `gdext/src/economy_runtime_catalog.cpp`; built-in formula registration and
  runtime/satisfaction profile decoding live in
  `gdext/src/economy_runtime_profile.cpp`.
- `gdext/src/economy_runtime_configuration.cpp` owns the public
  `configure()`, `bootstrap()` and `submit_commands()` implementations. It
  has no scheduler-stage authority and writes the same sole
  `NativeEconomyRuntime` state as before extraction.
- `gdext/src/economy_runtime_events.cpp` owns committed trace/event batches,
  cashflow detail, bounded event facade calls and PKEJ archive chunks. The root
  alone advances stage and outer cursors; publish-phase-local cursors live in
  `economy_runtime_publish.cpp`. Events never become a scheduler or
  economy-state authority.
- `gdext/src/economy_runtime_epoch.cpp` owns epoch preflight, frozen
  country/workset setup, transient vector initialization, opening audit-lane
  registration and completed performance snapshots. The root keeps ongoing
  run_slice stage selection, outer cursor advancement, worker dispatch and
  transitions.
- `gdext/src/economy_runtime_publish.cpp` owns publish-phase-local reset,
  closing audits, watermark/trade diagnostics and the ordered COMMIT handoff.
  The root alone enters the aggregate-publish stage, controls slice/yield
  boundaries and selects the next stage; this TU never becomes a second
  scheduler or state owner.
- `gdext/src/economy_runtime_results.cpp` owns only
  `MarketResult`/`ProductionResult` reset, capacity accounting and the
  thread-local worker sink definitions. Result aggregation and worker
  scheduling remain root-owned, so this file cannot create a second authority.
- `gdext/src/economy_runtime_diagnostics.cpp` owns read-only progress, memory,
  slice-breakdown and compact/full report construction. It may call const
  runtime helpers but may not mutate Stage/cursors, dispatch workers, commit
  state, append events or change report keys.
- `gdext/src/economy_runtime_settlements.cpp` owns committed population lookup,
  prosperity hysteresis, stable settlement name assignment/release,
  initialization/update and settlement row/field formatting. It uses the same
  `NativeEconomyRuntime::SettlementStore`; publish/COMMIT ordering, forced-name
  behavior and query fields remain owned by the existing runtime contracts.
- The former production implementations were removed from their facades; no
  production forwarding duplicate remains. A legacy native mirror is isolated
  in `MapBaker` for stale-DLL/A-B diagnostics only. Native C++ authority,
  DataCore binding, and Godot texture ownership are unchanged.
