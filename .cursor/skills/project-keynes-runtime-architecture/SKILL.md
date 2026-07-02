---
name: project-keynes-runtime-architecture
description: Explains and enforces the current Project.Keynes runtime architecture, scheduler model, DOTS authority boundaries, GDScript/C++ data bridge, native daily graph, and documentation-sync rules. Use when changing runtime systems, simulation mechanisms, scheduling, DataCore slots, GDExtension passes, native daily ACTIVE/SHADOW behavior, MapGenerator orchestration, or when adding/removing/refactoring architecture.
---

# Project.Keynes Runtime Architecture

Use this skill before changing Project.Keynes runtime simulation, scheduling, DOTS/DataCore architecture, GDExtension C++ passes, GDScript/C++ data flow, native daily graph behavior, fallback retirement, or documentation about those areas.

## Non-Negotiable Rule

If a change adds, removes, renames, migrates, or materially changes any mechanism, architecture boundary, scheduler behavior, pass contract, report field, fallback path, data owner, slot publish path, or module responsibility, update the relevant documentation in the same change.

Do not leave current runtime truth only in chat, temporary notes, test logs, or code comments.

Minimum docs to consider:

- `Project.Keynes/docs/cpp-dots-runtime/index.md`
- `Project.Keynes/docs/cpp-dots-runtime/architecture-overview.md`
- `Project.Keynes/docs/cpp-dots-runtime/runtime-authority-matrix.md`
- `Project.Keynes/docs/cpp-dots-runtime/runtime-deletion-inventory.md`
- `Project.Keynes/docs/cpp-dots-runtime/gdscript-cpp-data-bridge.md`
- `Project.Keynes/docs/cpp-dots-runtime/scheduling-and-job-graph.md`
- `Project.Keynes/docs/cpp-dots-runtime/computation-pipelines.md`
- `Project.Keynes/docs/cpp-dots-runtime/performance-diagnostics-playbook.md`
- `Project.Keynes/references/system-map.md`

## Mandatory Grounding

Before implementation, read the current code path and current docs. Do not proceed from roadmap memory.

For runtime architecture work, inspect:

- `Project.Keynes/references/system-map.md`
- `Project.Keynes/docs/cpp-dots-runtime/runtime-authority-matrix.md`
- `Project.Keynes/docs/cpp-dots-runtime/runtime-deletion-inventory.md`
- `Project.Keynes/docs/cpp-dots-runtime/architecture-overview.md`
- `Project.Keynes/docs/cpp-dots-runtime/gdscript-cpp-data-bridge.md`
- `Project.Keynes/docs/cpp-dots-runtime/scheduling-and-job-graph.md`
- `Project.Keynes/docs/cpp-dots-runtime/computation-pipelines.md`
- `Project.Keynes/Project/project-keynes/scripts/geography/map_generator.gd`
- `Project.Keynes/Project/project-keynes/scripts/data_core/dc_system_scheduler.gd`
- `Project.Keynes/Project/project-keynes/scripts/simulation/sus/sus_scheduler.gd`
- `Project.Keynes/Project/project-keynes/scripts/simulation/sus/jobs/*.gd`
- `Project.Keynes/Project/project-keynes/scripts/simulation/systems/*.gd`
- `Project.Keynes/gdext/src/world_ext*.cpp`
- `Project.Keynes/gdext/src/world_ext.h`
- `Project.Keynes/gdext/src/world_ext_bind_methods.cpp`
- `Project.Keynes/gdext/src/system_schedule.cpp`
- `Project.Keynes/gdext/src/system_schedule.h`
- `Project.Keynes/gdext/src/sus_scheduler_ext.cpp`

## Current Layering

Current runtime is a layered hybrid, not full native DOTS:

```text
WorldClock / main.gd
  -> MapGenerator orchestration
  -> DCSystemScheduler
  -> SusSchedulerExt budget / skip / stats
  -> DCSystem or retained SusJob state machines
  -> DCWorldExt C++ slots and pass kernels
  -> report / flush / visual intent
  -> MapData, debug, CSV, renderer, Godot uploads
```

Layer responsibilities:

- `MapGenerator`: host facade, world/map ownership, generate/load lifecycle, public runtime APIs, bridge delegation, weather/native daily/ocean helper facade, and a few local runtime helper functions for scheduler registration/native daily availability/disabled visual reports.
- `scripts/simulation/bootstrap/*`: not a current production layer. A previous extraction attempt was removed because new bootstrap preloads caused Godot script-resolution failures; do not recreate this layer without validating Godot parse/headless startup.
- `DCSystemScheduler`: production scheduler facade. It registers `DCSystem` instances, builds topology from declared reads/writes, and delegates execution/stats to SUS.
- `SusSchedulerExt`: C++ scheduler shell for priority, policy, frame budget, skip accounting, and log windows. It is not business authority.
- `DCWorld`: GDScript DataCore world, component slots, dirty mask, and `MapData` mirror binding.
- `DCWorldExt`: C++ DataCore world, SoA slots, C++ pass kernels, native daily graph state, refresh/flush/snapshot APIs.
- GDScript/Godot: UI/debug, `ImageTexture`, WeatherFront objects, GPU upload, renderer objects, CSV sampling, and fallback orchestration.

## DOTS Authority Definitions

Do not equate C++ acceleration with DOTS authority.

- C++ acceleration: GDScript chooses a native pass, builds knobs, calls C++, consumes the result, and may still own state and fallback.
- Slot authority: C++ writes the relevant DataCore slot and publishes it through flush/snapshot/report.
- Stage-state authority: native owns `_round_active`, cursor, phase lock, reset/abort lifecycle, and progress.
- Tick authority: native graph decides what advances for a simulation tick or continuation slice.
- Visible authority: the consumer layer can observe the output through `MapData`, CSV/debug, renderer data, or Godot upload.
- Full DOTS authority: native graph owns state, reads/writes slots, advances the tick, publishes a graph-level report, and GDScript only observes or performs Godot object/upload boundaries.

For every change, answer: which authority is moving?

- Formula/hot-loop only
- Slot ownership
- Stage state machine
- Tick scheduling
- Publish/visibility contract
- Object facade ownership
- Fallback/default path

## Scheduler Model

Production registration is `DCSystemScheduler` only. Legacy `_use_dc_system_scheduler=false` and old alias jobs have been removed from the production path.

Current important scheduler facts:

- `WorldClock.day_changed` drives one `MapGenerator.sus_tick_daily()` call.
- `DCSystemScheduler.register_system()` is the production registration surface.
- `SusSchedulerExt` applies policy, priority, dependency, frame-budget, skip, and stats behavior.
- `frame_budget_ms` decides whether another slice starts; it cannot preempt a native pass already running.
- `slice_budget_ms` is cooperative and job-local.
- `must_run=true` is only for simulation work that cannot safely freeze; do not use it to hide poor cadence or overly long native calls.
- `use_job_should_run=true` is for stateful eligibility that cannot be represented by a policy descriptor.

Native daily ACTIVE:

- `NativeDailySimJob` production hot path must call `MapGenerator.run_native_daily_slice_from_job()`.
- `DCWorldExt::run_native_daily_slice()` owns the native graph continuation cursor and returns `done=false` across slices.
- `run_native_daily_tick_from_job()` is debug/full-run helper only.
- `run_native_sim_tick_from_job()` is SHADOW/A-B/hash diff helper only.

## Native Daily Graph

`gdext/src/system_schedule.cpp` defines `SCHEDULE_GRAPH`. Current graph order is:

1. `climate_pass_a`
2. `ocean_water`
3. `ocean_land`
4. `climate_pass_b`
5. `wind_air`
6. `wind_surface`
7. `sea_ice`
8. `transpiration`
9. `albedo`
10. `vegetation_dynamics`
11. `climate_feedback`
12. `stage_b`
13. `weather`

Important boundaries:

- `runtime_hydrology` is not currently a `SCHEDULE_GRAPH` node. Treat it as a graph coverage blocker until it is added to the graph or explicitly removed from ACTIVE completion semantics.
- `stage_b` currently appears before `weather` in the native graph to match the native if-chain. Do not change stage-b/weather/hydrology order without A/B proof.
- Visual uploads are not native graph nodes. C++ may emit `visual_dirty_intents`; GDScript/Godot still owns `ImageTexture` and renderer object lifetimes.
- `graph_coverage_state=partial` is expected while GDScript/Godot/fallback boundaries remain.

## GDScript/C++ Data Transfer Contract

Assume no reliable mutable zero-copy between GDScript and C++ after writes. Godot `PackedArray` is Copy-on-Write.

GDScript to C++:

- Use `DCWorldExt.refresh_slots_from_map()` when C++ must see GDScript/MapData writes since the last refresh.
- Prefer one refresh at graph/round boundaries, not one per native node, unless a GDScript stage wrote data in between.
- Full or persistent cell state must go through `component_schema.gd` and `component_bind_table.gen.h`.

C++ to GDScript:

- C++ pass writes C++ slots first.
- If GDScript, `MapData`, renderer, CSV/debug, or fallback must observe the output, flush or snapshot explicitly.
- Use `_flush_slot_to_map()` / `flush_slots_to_map()` for `MapData` visibility.
- Use `snapshot_f32/i32/u8` for explicit pull-style debug/A-B reads.
- Return `published_to_slot=true` when a pass has written/published output so GDScript callers can skip duplicate unpack/copy.

Graph-level publish:

- `published_slots` is a native daily graph-level family report.
- Scheduler-level `published_to_slot` on `native_daily_sim` means the graph report declared at least one published slot family.
- It does not replace pass-level `published_to_slot` or visible MapData/render verification.
- `visual_dirty_intents` means GDScript/Godot should upload or refresh visuals; it does not mean GPU upload is complete.

## Main Functional Modules

Runtime simulation:

- `season_refresh`: `SeasonRefreshSystem`; slow variables, terrain/landform/vegetation/cover/moisture refresh, atlas/detail intents.
- `refresh_climate_daily`: `ClimateDailySystem`; pass A/B, ocean water/land, wind air/surface, sea ice, transpiration.
- `native_daily_sim`: `NativeDailySimJob` + `run_native_daily_slice`; partial ACTIVE native graph continuation.
- `weather_refresh`: `WeatherDCSystem` wrapper around retained `WeatherRefreshJob`; weather fields, fronts, visible publish, weather LUT.
- `ocean_currents`: `OceanCurrentsSystem` wrapper around retained `OceanCurrentsJob`; SLP, wind, PSI, ocean currents, upwelling, visual raster/commit.
- `sea_ice_daily`: `SeaIceDailySystem` / climate sea-ice stage; native pass acceleration plus terrain/visual boundary.
- `native_environment_runtime`: thin SHADOW/probe job unless a concrete system is promoted.

Visual and upload:

- `enum_atlas_upload`: `EnumAtlasUploadSystem`, C++ patch helpers plus GDScript GPU upload.
- `dynamic_visual_atlas_upload`: `DynamicVisualAtlasUploadSystem`, LUT/atlas stride and catch-up.
- Weather LUT upload remains tied to weather commit/native visual intents.
- Godot `ImageTexture`, renderer, WeatherFront objects, MultiMesh/detail scatter remain GDScript/Godot boundaries.

Generation and bake:

- Native world generation base/post-base is C++ authoritative for generated SoA result packages.
- GDScript still assembles `MapData` / `HexCell` and performs Godot texture/object operations.
- Native generation publish writes initial runtime slots and flushes/rebinds as needed.

## Deletion And Fallback Rules

Use `Project.Keynes/docs/cpp-dots-runtime/runtime-deletion-inventory.md` before deleting runtime code.

Deletion classes:

- Immediate delete: production/test unreachable and no fallback/debug value.
- Delete after migration: call sites remain but an equivalent new path exists.
- Isolate: still useful for A/B, probe, stale DLL, or debug, but must not be scattered in production hot paths.
- Keep for now: production authority, Godot visible boundary, or unvalidated fallback.

Do not retire fallback before PROBE/A-B and soak evidence. A fallback can be moved or isolated before it is deleted.

## Documentation Sync Rules

Update docs in the same change when any of these change:

- Scheduler registration order, policy, priority, `must_run`, `use_job_should_run`, dependency, skip reason, or report field.
- Data owner, slot writer, `component_schema.gd`, `component_bind_table.gen.h`, refresh/flush/snapshot behavior.
- Native pass input/output, report shape, `published_to_slot`, `fallback_reason`, `path`, `fail_stage`, timing fields.
- Native daily graph nodes, graph order, coverage blockers, `authority_report`, `published_slots`, `visual_dirty_intents`.
- Fallback/default path, ACTIVE/SHADOW/PROBE gate, readiness condition, or deletion/retirement status.
- Godot visual boundary, atlas/LUT upload, weather front object behavior, renderer-visible publish.
- Any rename or deletion of job/system/module files.

If code and docs disagree, fix both before reporting completion.

## Verification

Prefer this order:

1. Static `rg` checks for old symbols, method names, report fields, bindings, and docs references.
2. `git diff --check`.
3. Build GDExtension debug/release if C++ changed.
4. Run focused Godot/headless tests if Godot CLI is available.
5. For authority changes, run PROBE/A-B and inspect slot snapshots, `MapData`, CSV/debug, renderer/LUT.
6. Inspect 30+ tick logs for `avg/p95/max`, `largest`, fallback count, `frame_budget_exhausted`, `published_to_slot`, and native breakdown fields.

If runtime validation cannot be run, explicitly report the validation gap.

## Reporting Back

When completing runtime architecture work, report:

- Which authority moved and which stayed in GDScript/Godot.
- Which modules/files changed.
- Which docs were updated.
- Whether fallback remains and how it reports.
- What static/build/runtime validation was run.
- Any remaining blockers from `runtime-authority-matrix.md` or `runtime-deletion-inventory.md`.
