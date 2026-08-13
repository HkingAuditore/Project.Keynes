---
name: cpp-dots-runtime-development
description: Use when working on Project.Keynes C++/DOTS runtime systems, including DataCore, DCWorld/DCWorldExt, SUS/DCSystem scheduling, GDScript to C++ migration, native pass development, performance log diagnosis, and simulation hot-loop optimization.
---

# Project.Keynes C++/DOTS Runtime Development

Use this skill for any Project.Keynes task that touches runtime simulation, DataCore/DOTS, GDExtension C++ kernels, scheduler behavior, climate/weather/ocean/sea-ice/transpiration systems, atlas dirty/update paths, or performance logs such as `[SUS-cpp]`, `[fast tick WARN]`, `path=gdscript`, `path=gdext`, `published_to_slot`, and `frame_budget_exhausted`.

This skill is project-local and should be used together with `civ-grounded-development` when both are available. `civ-grounded-development` provides the broad read-first repository workflow; this skill adds the C++/DOTS-specific contracts and review checklist.

## Source Of Truth

For sparse per-entity policy features, keep authority storage canonical and
interned, compile only combinations used by the frozen epoch, and restrict worker
hot loops to POD arrays, integer indices, masks, and bounded slices.

Before changing code, read the relevant current-runtime docs:

- `docs/cpp-dots-runtime/index.md`
- `docs/cpp-dots-runtime/architecture-overview.md`
- `docs/cpp-dots-runtime/gdscript-cpp-data-bridge.md`
- `docs/cpp-dots-runtime/scheduling-and-job-graph.md`
- `docs/cpp-dots-runtime/computation-pipelines.md`
- `docs/cpp-dots-runtime/performance-diagnostics-playbook.md`

Use these as current architecture references. Historical validation docs such as `docs/dots-f1-validation.md` through `docs/dots-f6-validation.md`, `docs/dots-master-execution-handbook.md`, and `docs/performance-charter.md` are still valuable, but they may describe plans or historical acceptance details rather than the current runtime shape.

## Mandatory Grounding Pass

Never start a C++/DOTS runtime change from memory. First inspect the actual code paths involved.

For scheduler or runtime job work, inspect:

- `Project/project-keynes/scripts/geography/map_generator.gd`
- `Project/project-keynes/scripts/data_core/dc_system_scheduler.gd`
- `Project/project-keynes/scripts/simulation/sus/sus_scheduler.gd`
- `Project/project-keynes/scripts/simulation/sus/jobs/*.gd`
- `Project/project-keynes/scripts/simulation/systems/*.gd`
- `gdext/src/sus_scheduler_ext.cpp`
- `gdext/src/system_schedule.cpp`

For DataCore or bridge work, inspect:

- `Project/project-keynes/scripts/data_core/world.gd`
- `Project/project-keynes/scripts/data_core/component_schema.gd`
- `Project/project-keynes/scripts/data_core/component_ids.gd`
- `Project/project-keynes/scripts/geography/map_data.gd`
- `Project/project-keynes/scripts/geography/hex_cell.gd`
- `gdext/src/component_bind_table.gen.h`
- `gdext/src/world_ext.h`
- `gdext/src/world_ext.cpp`

For computation pass work, inspect the GDScript wrapper, the corresponding C++ `run_*_pass`, the scheduler job that invokes it, and the log formatting site in `main.gd` if performance output is involved.

For country/economy authority work, inspect `gdext/src/country_runtime.{h,cpp}`,
`world_ext_country.cpp`, `country_facade.gd`, `country_daily_system.gd`, and the frozen country bridge
in `economy_runtime.cpp`. Country identity, territory, technology, cash, and goods treasury are native
country authority; only `cell.country_slot` is mirrored to DataCore. Never restore economy-owned
per-cell technology or a global treasury.

Use `rg` first. Useful searches:

```powershell
rg -n "run_<name>_pass|published_to_slot|fallback_reason|refresh_slots_from_map|write_f32_indexed" Project\project-keynes gdext\src docs\cpp-dots-runtime
rg -n "frame_budget|slice_budget|must_run|depends_on|progress_ratio|largest_slice|skipped" Project\project-keynes\scripts gdext\src\sus_scheduler_ext.cpp
rg -n "path=|gdext|gdscript|native_ms|compute_ms|flush|sync|fallback" Project\project-keynes\scripts gdext\src
```

## Architecture Rules

Keep the runtime layering explicit:

- GDScript is the orchestration layer: feature gates, method probes, knobs construction, stage state machines, fallback, UI/debug, and Godot object operations.
- `DCWorld` is the GDScript DataCore world: component slots, `bind_map_data()`, `write_*`, dirty mask, and GDScript-side views.
- `DCWorldExt` is the C++ compute world: slot/SoA buffers, C++ pass kernels, native snapshots, slot refresh/flush, and GDExtension bindings.
- `NativeCountryRuntime` is a native peer authority: country SoA, territory CSR, nationwide
  technology, treasury, PKCN, and the narrow frozen bridge consumed by `NativeEconomyRuntime`.
- `SusSchedulerExt` is the C++ scheduler mirror: frame budget, depends, skip accounting, job stats, and budget-window logs.
- Rendering/GPU uploads remain Godot-side unless there is an explicit native object API; do not confuse fast CPU patch generation with texture upload cost.

Do not hide this boundary. A C++ pass is not complete just because it computes quickly; it must also publish its result to the layer that consumes it.

## GDScript / C++ Data Contract

Assume there is no reliable two-way mutable zero-copy buffer between GDScript and C++.

GDScript to C++:

- Use `DCWorld.write_f32`, `write_i32`, `write_u8` only for low-volume writes or facade compatibility.
- Use `write_*_indexed` for sparse hot-path writes.
- Use `write_*_dense` or `write_*_range` for full/contiguous buffers.
- Call `DCWorldExt.refresh_slots_from_map()` before a C++ pass if the pass depends on GDScript-side writes since the last refresh.
- Avoid repeated refresh calls inside a multi-stage native round; prefer one refresh at the round boundary when the stage chain can share C++ slots.

C++ to GDScript:

- C++ pass writes to slots.
- If GDScript, `MapData`, render code, or a later GDScript fallback must see the result, flush or snapshot explicitly.
- Prefer `_flush_slot_to_map()` / `flush_slots_to_map()` when the output belongs to `MapData`.
- Use `snapshot_f32`, `snapshot_i32`, or `snapshot_u8` for explicit pull-style reads.
- Return `published_to_slot=true` when the C++ result has been written/published so GDScript callers can skip duplicate unpack/copy.

Never assume `bind_map_data()` alone keeps both sides synchronized after C++ writes with `ptrw()` or after GDScript mutates a PackedArray.

## C++ Pass Implementation Checklist

When adding or modifying a native pass:

1. Identify the authoritative GDScript implementation or current fallback.
2. List every input and output field, including temporary arrays and dirty masks.
3. Check `component_schema.gd` for every field that should become a slot.
4. If a field is missing from schema, either add it through the schema/codegen workflow or document why it remains a temporary PackedArray knob.
5. In C++, resolve component IDs once outside the hot loop.
6. In C++, parse Dictionary knobs outside the hot loop.
7. In the hot loop, use only scalar locals and raw array pointers. Do not call Godot Object get/set, do not allocate, do not resize PackedArrays, and do not do string lookups.
8. Write outputs to C++ slots where possible.
9. Flush or snapshot only at the pass boundary.
10. Return a structured report with `path`, native timing, `published_to_slot` when applicable, and `fallback_reason` on failure.
11. Keep the GDScript fallback path until A/B or soak validation proves parity.

Do not introduce SIMD or WorkerThreadPool by default. For the current 2400-cell scale, scalar C++ tight loops are usually the best tradeoff. Add SIMD/threading only when the measured scalar C++ pass remains too slow and the data layout is suitable.

## Scheduler Development Checklist

When changing scheduler behavior or a `run_slice()` job:

1. Identify whether the job is simulation authority, visual upload, debug, or optional maintenance.
2. Keep `must_run=true` only for work that cannot safely freeze.
3. Keep upload/visual jobs budgeted unless starvation causes user-visible stale state that cannot be solved with dirty/stride changes.
4. Ensure `run_slice()` returns `done`, `elapsed_ms`, `progress_ratio`, `stage_name`, `substage`, and `path` where meaningful.
5. Preserve `depends_on` only for hard data dependencies. Avoid dependency chains that freeze weather/ocean/visual updates for many ticks.
6. Make stage names stable because `SusSchedulerExt` uses them in `largest` reporting.
7. If a job can run native or fallback paths, put the selected path and fallback reason into the returned report, not just into `print()`.
8. After changing budget or stage behavior, inspect `[SUS-cpp] last N ticks` and `budget last N ticks`.

Remember that `frame_budget_ms` gates whether another slice starts; it cannot preempt an already-running native pass. Long single native calls still show up as `max` or `largest`.

## Performance Log Diagnosis

Use this order:

1. Read the whole `[fast tick WARN]` block, not just one line.
2. Find `sus_window largest=job/stage/substage path=...`.
3. Check the current per-job breakdown below it.
4. Check `[SUS-cpp] last N ticks` for sustained avg/p95/max.
5. Check `skipped[...]` to distinguish slow work from budget starvation.
6. Check native breakdown fields: `native`, `compute`, `apply`, `flush`, `refresh`, `sync`, `write`, `mark`.
7. Check `published_to_slot`.
8. If path is GDScript, find `fallback_reason`, method probe, or stale DLL warning.
9. If C++ compute is low but wall time is high, inspect sync/flush/dirty/upload, not the math kernel.
10. Only after this consider algorithm changes.

Important interpretations:

- `path=data_core` is not the same as `path=gdscript`; DataCore can still call C++ sub-passes.
- `largest=... path=gdscript` may be a windowed old spike; verify against the current tick breakdown.
- `psi_path=gdscript` before the PSI stage executes can be a default value, not a failure.
- `published_to_slot=true` means the native slot publication path worked and duplicate GDScript copy should usually be skipped.
- Texture `upload` time is Godot/GPU cost, not C++ compute cost.

## Documentation Maintenance

Whenever a C++/DOTS runtime change alters behavior or debugging expectations, update the project docs in the same PR:

- Update `docs/cpp-dots-runtime/computation-pipelines.md` when pass ownership, inputs, outputs, fallback, or C++ status changes.
- Update `docs/cpp-dots-runtime/gdscript-cpp-data-bridge.md` when bridge API, publish/flush/snapshot behavior, schema ownership, or CoW assumptions change.
- Update `docs/cpp-dots-runtime/scheduling-and-job-graph.md` when job registration, budget policy, depends, stage naming, skip reasons, or scheduler reports change.
- Update `docs/cpp-dots-runtime/performance-diagnostics-playbook.md` when logs gain/lose fields or when a new common diagnosis pattern is discovered.

Do not bury current runtime truth only in handoff notes, chat logs, or one-off validation docs.

## Verification

For code changes, prefer this progression:

1. Static `rg` checks for method names, binding names, schema names, and call sites.
2. Build GDExtension if C++ changed.
3. Run focused bench or in-editor reproduction for the modified pass.
4. Compare native and fallback outputs using existing SAME_SOURCE / A-B tooling where available.
5. Inspect 30 tick SUS logs for avg/p95/max, `largest`, fallback counts, and skipped reasons.
6. For scheduler or frame-budget changes, inspect at least one longer budget window.
7. Use `git diff --check` before finishing.

For docs-only changes, verify links and symbol references with `rg`, and run `git diff --check`.

## Common Failure Modes

- Method exists in source but not in loaded DLL: rebuild GDExtension and restart Godot.
- `has_method()` false: check `ClassDB::bind_method`.
- C++ pass returns fallback with missing slot: check `component_schema.gd`, generated `component_bind_table.gen.h`, and `bind_map_data()`.
- C++ compute is fast but wall time is high: check `refresh_slots_from_map`, `_flush_slot_to_map`, snapshot, dirty mark, and texture upload.
- Atlas upload keeps taking time after simulation is native: check dirty mask value-diff and GPU upload path.
- Weather/ocean freezes: check `depends_on`, `must_run`, `frame_budget_exhausted`, and whether a visual job is consuming too much budget.
- C++ output correct but GDScript sees stale data: check publish/flush/snapshot and whether caller honors `published_to_slot`.

## Response Expectations

When reporting back on C++/DOTS work:

- State which path is authoritative now: C++ slot, DataCore GDScript, or fallback.
- Mention any changed C++ methods and GDScript wrappers.
- Mention whether schema or bind table changed.
- Summarize performance evidence using `avg/p95/max`, `largest`, fallback count, and native breakdown when available.
- Explicitly say if tests/builds were not run.
