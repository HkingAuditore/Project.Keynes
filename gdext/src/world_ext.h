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
    godot::PackedFloat32Array view_f32(int comp_id);
    godot::PackedInt32Array   view_i32(int comp_id);
    godot::PackedByteArray    view_u8(int comp_id);

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

    // ---- helpers ----
    void _ensure_slot_capacity(Slot &slot, int new_count);
};

} // namespace pk
