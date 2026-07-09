---
name: project-keynes-dots-deepening
description: Guides robust Project.Keynes DOTS deepening work: native daily graph, DataCore authority migration, C++/SoA system graph rollout, GDScript state-machine migration, PROBE/A-B validation, publish/flush contracts, and fallback retirement. Use when implementing or reviewing deeper DOTS adoption beyond simple C++ pass migration.
---

# Project.Keynes DOTS Deepening

Use this skill when the user asks to deepen DOTS, migrate runtime authority to native daily simulation, move GDScript stage state into `DCWorldExt`, change `native_daily_sim_mode`, alter `run_native_daily_tick`, change `system_schedule.cpp`, or decide whether a subsystem is truly DOTS-authoritative.

This skill complements `cpp-dots-runtime-development`. That skill covers native pass contracts; this one covers safe authority migration.

## Core Principle

Do not equate C++ acceleration with DOTS authority.

- C++ acceleration: GDScript chooses a native pass and consumes its result.
- DOTS authority: native graph owns system state, reads/writes slots, advances the tick, publishes a graph-level report, and GDScript only observes or uploads.

The desired end state is: `DCWorldExt native graph` advances the simulation day. GDScript starts the tick, reads reports, updates UI/debug, and performs Godot object or texture operations.

## Mandatory Grounding

Before implementation, read the current code path being changed. Never proceed from roadmap memory.

For native daily / system graph work, inspect:

- `Project.Keynes/docs/plans/dots-deepening-roadmap.md`
- `Project.Keynes/docs/cpp-dots-runtime/architecture-overview.md`
- `Project.Keynes/docs/cpp-dots-runtime/gdscript-cpp-data-bridge.md`
- `Project.Keynes/docs/cpp-dots-runtime/scheduling-and-job-graph.md`
- `Project.Keynes/docs/cpp-dots-runtime/computation-pipelines.md`
- `Project.Keynes/Project/project-keynes/scripts/geography/map_generator.gd`
- `Project.Keynes/Project/project-keynes/scripts/data_core/dc_system_scheduler.gd`
- `Project.Keynes/Project/project-keynes/scripts/simulation/sus/sus_scheduler.gd`
- `Project.Keynes/gdext/src/world_ext.cpp`
- `Project.Keynes/gdext/src/world_ext_bind_methods.cpp`
- `Project.Keynes/gdext/src/system_schedule.cpp`
- `Project.Keynes/gdext/src/sus_scheduler_ext.cpp`

For authority boundaries, also inspect the relevant GDScript job/system:

- climate: `Project.Keynes/Project/project-keynes/scripts/simulation/systems/climate_daily_system.gd`
- weather: `Project.Keynes/Project/project-keynes/scripts/simulation/sus/jobs/weather_refresh_job.gd`, `Project.Keynes/Project/project-keynes/scripts/weather/weather_system.gd`, `Project.Keynes/Project/project-keynes/scripts/weather/field_solver.gd`
- ocean: `Project.Keynes/Project/project-keynes/scripts/simulation/sus/jobs/ocean_currents_job.gd`, `Project.Keynes/Project/project-keynes/scripts/rendering/map_baker.gd`
- DataCore/schema: `Project.Keynes/Project/project-keynes/scripts/data_core/component_schema.gd`, `Project.Keynes/gdext/src/component_bind_table.gen.h`

## First Question

For every proposed change, answer this before coding:

Which authority is being moved?

- Formula/hot-loop only
- Slot ownership
- Stage state machine
- Tick scheduling
- Publish/visibility contract
- Object facade ownership
- Fallback/default path

If the change only moves math into C++, call it C++ acceleration, not DOTS deepening.

## Existing Lessons To Reuse

The project already has solved patterns. Reuse them instead of inventing parallel mechanisms.

- Use `component_schema.gd` and `component_bind_table.gen.h` as the schema bridge.
- Use `refresh_slots_from_map()` only at graph/tick boundaries or after GDScript writes that native must read.
- Use `_flush_slot_to_map()` / `flush_slots_to_map()` only when GDScript, render, fallback, CSV, or debug must observe native output.
- Use `published_to_slot=true` to prevent duplicate GDScript unpack/copy.
- Use `fallback_reason`, `fail_stage`, `path`, and native breakdown fields in reports.
- Use SAME_SOURCE / A-B / PROBE before making a native path authoritative.
- Treat GPU upload, `ImageTexture`, and Godot object lifetimes as GDScript-side unless there is an explicit native object API.

Known strong precedents:

- Native world generation is already C++ authoritative.
- Climate temperature hot passes are deeply C++/SoA.
- Weather has substantial C++ compute, but its default native daily authority is blocked until visible publish/front/LUT contracts are proven.
- `SusSchedulerExt` owns scheduler shell behavior, while job bodies may still call back to GDScript.

## Scientific Rollout Discipline

Use a staged rollout. Do not jump directly to ACTIVE authority.

1. Baseline current SUS path.
   - Capture current report fields and key SoA outputs.
   - Identify existing `path`, fallback count, publish status, and dirty behavior.

2. Implement native graph or native state in PROBE mode.
   - Native code runs and reports.
   - It does not publish authoritative outputs unless explicitly scoped.
   - Compare against the existing SUS/GDScript-authoritative path.

3. Validate publish/visibility separately.
   - Check `MapData` arrays.
   - Check slot snapshots.
   - Check render-visible LUT or atlas intent.
   - Check CSV/debug consumers.

4. Enable partial ACTIVE only after PROBE parity.
   - Start with one system boundary or one graph node family.
   - Preserve clear fallback and fail-stage reporting.

5. Retire fallback only after soak.
   - Fallback count must be zero or explained.
   - Reports must identify any fallback immediately.

## Native Daily Graph Checklist

When changing `run_native_daily_tick`, `run_native_sim_tick`, or `system_schedule.cpp`:

- Define graph nodes with stable names.
- Declare every node's read/write slot set or system mask.
- Keep inter-node data in C++ slots, not GDScript bundles, when possible.
- Avoid per-node flush unless a later GDScript consumer is in the same tick.
- Return a graph-level report with:
  - `path`
  - `fail_stage`
  - `fallback_reason`
  - `native_ms`
  - `compute_ms`
  - `refresh_ms`
  - `flush_ms`
  - `published_slots`
  - `dirty_cells`
  - `fronts_changed`
  - `visual_dirty_intents`
- Keep node names stable because logs, CSV, and diagnostics depend on them.

## State Machine Migration Checklist

When migrating GDScript state such as `_round_active`, `_pass_cursor`, `_round_stage`, `_phys_stage`, or front snapshots:

- Identify the current owner and every mutation site.
- List reset paths: regenerate, profile change, fallback, abort, save/load, and editor restart.
- Define the native state struct and its lifecycle.
- Add a report snapshot for debug.
- Keep GDScript wrappers thin: call native, translate report, avoid duplicating state.
- Avoid half-authority where both GDScript and C++ mutate the same cursor/token.

## Weather-Specific Gate

Do not make native daily weather authoritative until all are true:

- `weather_native_daily_available()` reflects real readiness, not a hard-coded block.
- `run_weather_refresh_daily_pass` publishes visible `weather_*_arr` fields.
- `weather_field_init_arr` is nonzero when a weather field is expected.
- Front snapshots are available from native state and can rebuild UI/render objects.
- Weather LUT publication is represented as native report intent plus GDScript upload.
- CSV/debug fields can distinguish clear weather from missing publish.

## Climate/Temperature-Specific Gate

Temperature math is already deeply native. For further DOTS work, focus on authority:

- Move climate round state and phase lock into native state.
- Keep `cell_temp`, baseline, thermal, ocean/local/air-mass anomaly slots as the authority.
- Validate `wind_surface` final composition and publish visibility.
- Do not create parallel temperature arrays or duplicate anomaly channels.

## Anti-Patterns

- Calling a C++ pass from GDScript and declaring the system DOTS-authoritative.
- Adding new arrays outside `component_schema.gd` for persistent simulation state.
- Flushing every node in a native graph because a wrapper used to need it.
- Keeping `_round_active` in GDScript while native also advances the same round.
- Treating `path=data_core` as proof of native compute or treating old `largest path=gdscript` as current failure without checking current breakdown.
- Retiring fallback before PROBE/A-B and soak evidence.
- Using `must_run=true` as a substitute for proper cadence, phase, or graph scheduling.

## Verification

Prefer this sequence:

1. Static `rg` checks for method names, schema fields, bindings, call sites, and report keys.
2. Build GDExtension if C++ changed.
3. Run focused PROBE/A-B parity for the changed graph or state.
4. Inspect reports for `path`, `fail_stage`, fallback count, publish status, and native breakdown.
5. Inspect 30+ tick `[SUS-cpp]` / native daily windows.
6. Verify visible outputs: `MapData`, slot snapshots, CSV/debug, and render/LUT if relevant.
7. Only then consider ACTIVE default changes.

## Reporting Back

When reporting DOTS deepening work, state:

- Which authority moved.
- Which authority still remains in GDScript.
- Whether the change is PROBE, partial ACTIVE, or default ACTIVE.
- Which slots are read/written and which outputs are published.
- Whether fallback remains and how it reports failures.
- What parity, build, and runtime evidence was collected.
