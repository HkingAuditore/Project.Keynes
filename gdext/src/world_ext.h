#pragma once

// DCWorldExt — C++ mirror of `scripts/data_core/world.gd` (DCWorld).
//
// I3.A scope (this file): "zero-acceleration wrapper".
// Goal: instantiate via ClassDB("DCWorldExt"), bind to MapData, expose
// `view_f32 / view_i32 / view_u8`, support pools + archetypes — i.e. fulfil
// the same interface that GDScript-side hot loops already call. *No* hot loop
// is reimplemented in C++ yet; the run_xxx entry points belong to I3.B/C.
//
// The point of I3.A is to prove the bridging path:
//   1. world_factory.gd can ClassDB.instantiate("DCWorldExt") under
//      use_gdext_world=true.
//   2. bind_map_data shares the same PackedFloat32Array buffers as MapData
//      (zero-copy COW alias).
//   3. The existing GDScript hot loops still run, reading `world.view_f32(c)`,
//      and produce identical numerical output (= "zero-acceleration").
// Once that holds, I3.B can replace one sub-pass at a time with a C++
// implementation behind `use_gdext_climate`.

#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/templates/hash_map.hpp>
#include <godot_cpp/templates/vector.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/vector2i.hpp>

#include "components/slot.h"

namespace pk {

class DCWorldExt : public godot::RefCounted {
    GDCLASS(DCWorldExt, godot::RefCounted);

public:
    DCWorldExt();
    ~DCWorldExt() override;

    // ─── Component registry ──────────────────────────────────────────────
    int register_component(const godot::StringName &name, int dtype, int stride = 1, bool track_prev = false);
    int component_id(const godot::StringName &name) const;
    int component_count() const { return _slots.size(); }
    bool has_component(const godot::StringName &name) const { return _slot_by_name.has(name); }

    // ─── Entity / Pool API (mirrors I2.A in GDScript) ────────────────────
    int  create_entities(int count);                 // grow _entity_count, returns first new idx
    int  entity_count() const { return _entity_count; }

    int           create_pool(const godot::StringName &name, int capacity);
    godot::Vector2i pool_range(int pool_id) const;
    int           pool_id(const godot::StringName &name) const;
    int           pool_count() const { return _pools.size(); }
    int           pool_free_count(int pool_id) const;

    // ─── Hot-path data views (READ-ONLY snapshot under DCWorldExt) ───────
    // Under GDExtension the returned PackedArray is a CoW *copy*, not an
    // alias to internal storage. Mutating it does NOT write back. For
    // writes, use write_f32 / write_i32 / write_u8 below.
    //
    // NOTE on naming: `view_f32` is the LEGACY name from the I3.A "zero-
    // acceleration alias" era, when we believed the returned PackedArray
    // could double as a writable view through bind_map_data CoW. The
    // climate Pass-A "all-blue bug" (2026-05-12) proved that contract
    // unreliable across pass boundaries. Under the current "Mode B" charter
    // (data Owned-by-C++, GDScript pulls read-only snapshots) callers
    // SHOULD use `snapshot_f32` instead — same return shape, but the name
    // documents the contract truthfully. `view_f32` remains as a thin
    // alias to keep older call sites compiling.
    godot::PackedFloat32Array view_f32(int comp_id);
    godot::PackedInt32Array   view_i32(int comp_id);
    godot::PackedByteArray    view_u8(int comp_id);

    // ─── Mode-B snapshot API (recommended) ──────────────────────────────
    // Returns a value-copy (Godot PackedArray COW) of `_slots[comp_id].arr_f32`.
    // The caller is free to mutate the returned array — those mutations
    // never propagate back into `_slots[]`. Use this whenever GDScript
    // needs to read the latest C++-side numerical state (UI, baker,
    // diagnostics, MapData refresh via flush_to_mapdata).
    //
    // On invalid `comp_id` or non-F32 slot: returns an empty array, no error.
    godot::PackedFloat32Array snapshot_f32(int comp_id);

    // ─── Hot-path writes (replaces `view_xxx(c)[i] = v` pattern) ─────────
    // Single-element writes; bounds-checked, no-op on invalid args.
    void write_f32(int comp_id, int idx, float v);
    void write_i32(int comp_id, int idx, int32_t v);
    void write_u8 (int comp_id, int idx, int v); // accept int from GDScript; clamp to 0..255
    // Bulk writes; copy `src[0..src.size())` into `arr[start..start+src.size())`.
    void write_f32_range(int comp_id, int start, const godot::PackedFloat32Array &src);
    void write_i32_range(int comp_id, int start, const godot::PackedInt32Array   &src);
    void write_u8_range (int comp_id, int start, const godot::PackedByteArray    &src);

    // Sparse / indexed writes; for each k in [0, indices.size()), do
    //   arr[indices[k]] = values[k]
    // Designed for Pass-B / dirty-only systems where the dirty cell list is
    // smaller than the full pool but is *not* contiguous. One trans-boundary
    // call replaces N single-cell write_xxx() calls — on a 2400-cell, 30%-
    // dirty workload this is the difference between ~15ms and ~3ms (see
    // tmp/bench_dots_vs_dict.gd, Case 3/4).
    void write_f32_indexed(int comp_id, const godot::PackedInt32Array &indices, const godot::PackedFloat32Array &values);
    void write_i32_indexed(int comp_id, const godot::PackedInt32Array &indices, const godot::PackedInt32Array   &values);
    void write_u8_indexed (int comp_id, const godot::PackedInt32Array &indices, const godot::PackedByteArray    &values);

    // Scalar variant: all dirty cells get the same value (e.g. clear flag).
    // Saves the caller from materialising a values array of constants.
    void write_f32_scalar_indexed(int comp_id, const godot::PackedInt32Array &indices, float v);
    void write_i32_scalar_indexed(int comp_id, const godot::PackedInt32Array &indices, int32_t v);
    void write_u8_scalar_indexed (int comp_id, const godot::PackedInt32Array &indices, int v);

    // ─── Bind to MapData (GDScript instance) ─────────────────────────────
    // Reflectively reads the GDScript `MapData` properties (e.g. `temp_arr`)
    // and assigns them into the matching slots. Buffers are shared via COW —
    // no copy. Returns false on any property mismatch / type mismatch.
    bool bind_map_data(godot::Object *map_data);
    bool is_bound() const { return _bound; }

    // ─── Archetype system (mirrors I2.B in GDScript) ─────────────────────
    int  create_archetype(const godot::StringName &name, const godot::Array &comp_ids);
    void assign_archetype(int idx, int arch_id);
    int  archetype_count() const { return _archetypes.size(); }
    godot::PackedInt32Array entity_archetype_array() const { return _entity_archetype; }

    // ─── Hot-loop entry points (stubs; filled in I3.B/C) ─────────────────
    // Returning -1.0 indicates "not implemented yet, fall back to GDScript".
    // GDScript-side caller checks `< 0` and routes to the legacy path.
    double run_climate_pass_a(const godot::Dictionary &cp_struct, double phase, double season_phase);

    // ─── Mode-B reference implementation: temp_drift_pass ────────────────
    // The minimal "hello world" pass that validates the full Owned-by-C++
    // communication contract end-to-end. Adds `drift_amount` to every
    // element of `_slots[CELL_TEMP].arr_f32` via a tight ptrw() loop with
    // ZERO Variant operations and ZERO obj.set() flushes.
    //
    // This is NOT a game feature. It exists so:
    //   1. We have a reference C++ writer to copy-paste from.
    //   2. We can bit-precisely cross-check against a GDScript replica
    //      (addition is exact, no FP drift).
    //   3. `docs/performance-charter.md` §12 documents this exact code as
    //      the canonical Mode-B template.
    //
    // Safety: if the slot id (looked up by StringName "cell_temp") is not
    // registered, the call is a no-op (no crash, no error spam).
    void run_temp_drift_pass(float drift_amount);

    // ─── Mode-B reference implementation: thermal_gradient_pass (Pass #2) ─
    // Pass #2 stresses the four real-business complexities that Pass #1
    // intentionally skipped:
    //   1. multi-input SoA  : reads BOTH cell_temp AND cell_elevation
    //   2. neighbour access : 4-neighbour central difference (clamp-to-edge)
    //   3. write new comp   : writes to cell_demo_thermal_gradient
    //   4. overlay surfaceable: result lives on a real component slot, so
    //                          the GDScript-side baker can sample it through
    //                          snapshot_f32() and feed it to the data overlay.
    //
    // Per-cell formula (mirrors performance-charter §12.6 spec):
    //   grad_x = (T_east - T_west) * 0.5    (clamp-to-edge at borders)
    //   grad_y = (T_south - T_north) * 0.5  (clamp-to-edge at borders)
    //   amp    = 1 + elevation_gain * cell_elevation[i]
    //   out    = clamp(sqrt(grad_x*grad_x + grad_y*grad_y) * amp * normalize_k, 0, 1)
    //
    // Hot-loop discipline (copy verbatim into new "with-neighbour" passes):
    //   * Resolve all slot ids ONCE before the loop.
    //   * Take ONE ptr() per read buffer + ONE ptrw() per write buffer.
    //   * Inner loop accesses neighbours by integer index ONLY (no Variant,
    //     no view_f32() per cell, no map->get() per cell).
    //   * Borders use "self-substitute" (Tn := T at y==0 etc.) instead of
    //     conditional branches — avoids both OOB and modulo-wrap artefacts.
    //
    // Safety: if any of the three slots is not registered or sizes do not
    // match grid_w * grid_h, the call is a no-op + a single push_warning.
    // No crash, no exception, no half-written buffer.
    void run_thermal_gradient_pass(int grid_w,
                                   int grid_h,
                                   float elevation_gain,
                                   float normalize_k);

    // ─── Mode-B reference implementation: demo_complex_pass (Pass #3) ─────
    // Pass #3 keeps every piece of Pass #2's communication scaffolding
    // (component slot, overlay mode, climate switch, baker, tick hook,
    // performance-charter §12.6 entry) and ONLY upgrades the kernel from
    // a one-shot 4-neighbour gradient to an iterated anisotropic-diffusion
    // + multi-scale wind approximation. The point is to push real ops/cell
    // up two orders of magnitude (~10 → ~2400 at default knobs) so the
    // user can both (a) see richer overlay patterns and (b) probe how far
    // C++ single-threaded can scale before climate Pass-A is revisited.
    //
    // Per-step formula (mirrors performance-charter §12.6.6 spec):
    //   for it in 0..iterations-1:
    //     smooth[i] = sum(src[nb] * gauss_weight[dx,dy]) / sum(gauss_weight)
    //     gx, gy   = sobel_3x3(src, x, y)                      (clamp-to-edge)
    //     rotate (gx, gy) by 90° * coriolis_strength * sgn(y - h/2)
    //     damp     = 1 - terrain_drag * cell_elevation[i]
    //     dst[i]   = smooth[i] + (gx' + gy') * damp * 0.05      (step constant)
    //   normalize last buffer to [0,1] then apply (1+gain*elev)*k + clamp.
    //
    // Knob clamps (silently corrected, single push_warning per process):
    //   iterations   ∈ [1, 64]   (default 16)
    //   kernel_radius∈ [1, 5]    (default 2  → 5×5 neighbourhood)
    //   coriolis     ∈ [-1, 1]   (default 0.5)
    //   terrain_drag ∈ [0, 1]    (default 0.6)
    //   elevation_gain / normalize_k: passed through unchanged from Pass #2.
    //
    // Hot-loop discipline (verbatim from §12.6 template):
    //   * Resolve all slot ids ONCE before the iteration loop.
    //   * Pre-compute the (2r+1)² Gaussian kernel ONCE on the C-stack array.
    //   * Two std::vector<float> ping-pong buffers, allocated ONCE per call.
    //   * Inner loop: only ptr/ptrw + integer index + table lookup. NO
    //     Variant, NO obj.set, NO map->get per cell.
    //   * Borders use clamp-to-edge (Neumann BC) — same as Pass #2.
    //
    // BIT-EQUAL DISCIPLINE: every intermediate runs in double on the C++
    // side and is only narrowed back to float at the FINAL store, mirroring
    // GDScript's implicit-double arithmetic in PackedFloat32Array.
    //
    // Safety: same as Pass #2 — missing slot / dtype mismatch / size
    // mismatch all yield no-op + push_warning. No crash, no half-written
    // buffer.
    void run_demo_complex_pass(int grid_w,
                               int grid_h,
                               int iterations,
                               int kernel_radius,
                               float coriolis_strength,
                               float terrain_drag,
                               float elevation_gain,
                               float normalize_k);

    // ─── DOTS-A1 EXPERIMENT: archetype-filtered demo_complex_pass ─────────
    // Identical algorithm to `run_demo_complex_pass` (same kernel, same
    // bit-equal contract), with ONE additional discipline: cells whose
    // `_entity_archetype[i]` does not equal `target_archetype` are SKIPPED
    // — their output slot is set to 0.0f and they do not contribute to the
    // post-iter normalization min/max either.
    //
    // Special semantics for `target_archetype`:
    //   ≥ 0  : only cells with _entity_archetype[i] == target_archetype run.
    //   < 0  : "no filter" — every cell runs (= equivalent to vanilla
    //          `run_demo_complex_pass`, used as the bit-equal control row).
    //
    // Why a separate function (not an extra param to the vanilla pass):
    //   * Vanilla `run_demo_complex_pass` is the canonical Mode-B template
    //     reference quoted verbatim in performance-charter §12.6.6 — we do
    //     not want to perturb its hot-loop layout.
    //   * The archetype branch adds a load+compare per cell; keeping it in
    //     a sibling function makes the cost obvious in the bench numbers.
    //
    // Safety: same as vanilla — missing slot / dtype mismatch / size
    // mismatch all yield no-op + push_warning. If `_entity_archetype.size()`
    // is smaller than the cell count and `target_archetype >= 0`, the call
    // is a no-op + push_warning (defensive: archetype assignment hasn't
    // happened yet).
    void run_demo_complex_pass_archetyped(int grid_w,
                                          int grid_h,
                                          int iterations,
                                          int kernel_radius,
                                          float coriolis_strength,
                                          float terrain_drag,
                                          float elevation_gain,
                                          float normalize_k,
                                          int target_archetype);

    // ─── Phase 3a Step 0: alias spike (TEMPORARY — to be removed) ─────────
    // Three variants probe whether `obj.set(prop, arr)` followed by
    // `arr.ptrw()[i] = v` keeps the buffer aliased between obj.<prop> and
    // the C++-side `arr` reference. Real result drives the bind_map_data
    // strategy in Step 1. See plan/dots-roadmap-to-gdextension.
    //
    // All three return the value seen by the GDScript side AFTER the C++
    // mutation, so the caller can simply compare against the sentinel.
    //   v1 : naive   — get, set, ptrw-write
    //   v2 : release — get, set, drop local ref, re-get, ptrw-write
    //   v3 : write-then-set — get, ptrw-write, set
    float _spike_alias_v1_naive          (godot::Object *obj, const godot::StringName &prop, int idx, float sentinel);
    float _spike_alias_v2_release        (godot::Object *obj, const godot::StringName &prop, int idx, float sentinel);
    float _spike_alias_v3_write_then_set (godot::Object *obj, const godot::StringName &prop, int idx, float sentinel);

    // ─── Phase 3a Step 1: alias verification helper (TEMPORARY) ──────────
    // Writes `sentinel` into _slots[comp_id].arr_f32[idx] via ptrw() — the
    // same path that hot loops will use. The companion test reads back via
    // GDScript-side `map.<prop>[idx]` to confirm the alias survives a pure
    // C++ mutation (no obj.set call after the write). If the test PASSes,
    // the bind_map_data push-back contract is correct: GDScript and C++
    // share the buffer, no per-write set needed.
    // Removed once Step 1 validation is signed off (along with the spike).
    float _debug_poke_f32(int comp_id, int idx, float sentinel);

    // T1b: same as _debug_poke_f32, but performs map_data->set(prop_name,
    // s.arr_f32) immediately after the ptrw() write to push the (possibly
    // detached) buffer back to the GDScript side. Probes whether
    // "write-then-set per pass" is the correct alias contract — if T1b
    // PASSes while T1 FAILs, then bind_map_data's one-time push-back is
    // insufficient and every C++ hot pass must re-set on exit.
    // Looks up comp_id → property_name via the BIND_TABLE.
    float _debug_poke_f32_with_flush(int comp_id, int idx, float sentinel);

    // ─── Phase-3 micro-bench API ────────────────────────────────────────
    // These are NOT production paths; they exist solely so tmp/bench_*.gd
    // can compare three optimisation strategies head-to-head:
    //   B-scalar : C++ tight loop, ptrw(), naive scalar code (compiler may
    //              auto-vectorise depending on flags / loop shape).
    //   B-simd   : C++ tight loop with explicit AVX2/SSE2 intrinsics.
    //   C-thread : same as B-simd but split across WorkerThreadPool workers.
    //
    // Workload model (mimics climate Pass-A's per-cell math):
    //   new[i] = base + lat[i]*k1 + (sum of 6 nb of prev[i])*k2 + season
    //
    // Inputs are passed explicitly (not via bind_map_data) so the bench can
    // run standalone without a real MapData. Returns the bench-internal
    // elapsed milliseconds (whatever the inside loop took, excluding the
    // GDScript dispatch overhead) — caller still wraps in get_ticks_usec
    // for a true end-to-end measurement.
    void bench_pass_a_full_scalar(int comp_id,
                                  const godot::PackedFloat32Array &lat,
                                  const godot::PackedFloat32Array &prev,
                                  const godot::PackedInt32Array   &neighbors,
                                  float k1, float k2, float base, float season);
    void bench_pass_a_full_simd  (int comp_id,
                                  const godot::PackedFloat32Array &lat,
                                  const godot::PackedFloat32Array &prev,
                                  const godot::PackedInt32Array   &neighbors,
                                  float k1, float k2, float base, float season);
    void bench_pass_a_full_thread(int comp_id,
                                  const godot::PackedFloat32Array &lat,
                                  const godot::PackedFloat32Array &prev,
                                  const godot::PackedInt32Array   &neighbors,
                                  float k1, float k2, float base, float season,
                                  int n_tasks);

    void bench_pass_a_indexed_scalar(int comp_id,
                                     const godot::PackedInt32Array   &dirty,
                                     const godot::PackedFloat32Array &lat,
                                     const godot::PackedFloat32Array &prev,
                                     const godot::PackedInt32Array   &neighbors,
                                     float k1, float k2, float base, float season);
    void bench_pass_a_indexed_simd  (int comp_id,
                                     const godot::PackedInt32Array   &dirty,
                                     const godot::PackedFloat32Array &lat,
                                     const godot::PackedFloat32Array &prev,
                                     const godot::PackedInt32Array   &neighbors,
                                     float k1, float k2, float base, float season);
    void bench_pass_a_indexed_thread(int comp_id,
                                     const godot::PackedInt32Array   &dirty,
                                     const godot::PackedFloat32Array &lat,
                                     const godot::PackedFloat32Array &prev,
                                     const godot::PackedInt32Array   &neighbors,
                                     float k1, float k2, float base, float season,
                                     int n_tasks);

    // ───────────────────────────────────────────────────────────────────
    // EXPERIMENTAL: D-async — long-lived worker thread + double buffering
    // ───────────────────────────────────────────────────────────────────
    // Goal: probe whether a "request → background compute → poll" pattern
    // gives the main thread sub-50µs dispatch cost while keeping the
    // demo_complex algorithm bit-equivalent to the synchronous path.
    //
    // Contract (CRITICAL — read before touching any of these methods):
    //   1. Worker threads NEVER call any Godot API (no Variant, no
    //      push_warning, no Object::get/set). They only read/write their
    //      own std::vector<float> buffers.
    //   2. Inputs (temp / elev) are SNAPSHOT-COPIED into worker-private
    //      buffers in `async_climate_set_inputs` — caller-side mutation
    //      after the call cannot race with the worker.
    //   3. Outputs land in a worker-private std::vector<float>; the main
    //      thread copies them into _slots[CELL_DEMO_THERMAL_GRADIENT] only
    //      inside `async_climate_poll()` (which returns true on success).
    //   4. `async_climate_shutdown_*` joins the worker(s); ~DCWorldExt
    //      calls shutdown_all() defensively.
    //   5. NEVER share an AsyncTask across DCWorldExt instances.
    //
    // Output slot: re-uses "cell_demo_thermal_gradient" so existing data
    // overlay machinery / GDScript snapshot code keeps working unchanged.
    //
    // See `.codebuddy/plan/cpp-async-experiment/requirements.md` for the
    // experiment design and 7-criteria success matrix.
    void async_climate_register_task(int task_id, int n_workers);
    void async_climate_set_inputs(int task_id,
                                  const godot::PackedFloat32Array &temp,
                                  const godot::PackedFloat32Array &elev);
    void async_climate_request(int task_id,
                               int grid_w, int grid_h,
                               int iterations, int kernel_radius,
                               float coriolis_strength,
                               float terrain_drag,
                               float elevation_gain,
                               float normalize_k);
    bool async_climate_poll(int task_id);
    godot::Dictionary async_climate_stats(int task_id);
    void async_climate_shutdown_task(int task_id);
    void async_climate_shutdown_all();

protected:
    static void _bind_methods();

private:
    // ---- registry ----
    godot::Vector<Slot>                       _slots;
    godot::HashMap<godot::StringName, int>    _slot_by_name;

    // ---- entity / pool ----
    int                                       _entity_count = 0;

    struct Pool {
        godot::StringName name;
        int               start    = 0;
        int               capacity = 0;
        // free-list (LIFO stack of indices within [start, start+capacity)).
        // empty = pool fully allocated. Initialised in create_pool().
        godot::Vector<int> free_list;
    };
    godot::Vector<Pool>                       _pools;
    godot::HashMap<godot::StringName, int>    _pool_by_name;

    // ---- bind state ----
    godot::Object                            *_map_data = nullptr; // weak (GDScript holds strong ref)
    bool                                      _bound    = false;

    // ---- archetype ----
    godot::Vector<godot::Array>               _archetypes;          // each entry = comp_ids
    godot::HashMap<godot::StringName, int>    _archetype_by_name;
    godot::PackedInt32Array                   _entity_archetype;    // index by entity idx

    // ---- EXPERIMENTAL: D-async opaque state (defined in .cpp) ----------
    // Holds the std::unordered_map<int, AsyncTask> and a global mutex.
    // Allocated lazily on first async_* call; freed in shutdown_all().
    void                                     *_async_state = nullptr;

    // ---- helpers ----
    void _ensure_slot_capacity(Slot &slot, int new_count);
};

} // namespace pk
