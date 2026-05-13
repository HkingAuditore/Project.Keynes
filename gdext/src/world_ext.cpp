#include "world_ext.h"

#include "component_bind_table.gen.h"  // A1 / dots-migration-roadmap §3 — autogen by tools/codegen/gen_cpp_bind_table.py

#include <godot_cpp/classes/global_constants.hpp>
#include <godot_cpp/classes/worker_thread_pool.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/error_macros.hpp>
#include <godot_cpp/core/math.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/variant/variant.hpp>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstring>
#include <limits>
#include <memory>
#include <mutex>
#include <thread>
#include <unordered_map>
#include <vector>

#if defined(PK_HAVE_AVX2) && PK_HAVE_AVX2
#  include <immintrin.h>
#endif

namespace pk {

using namespace godot;

DCWorldExt::DCWorldExt() = default;
DCWorldExt::~DCWorldExt() {
    // EXPERIMENTAL: D-async — defensively join all worker threads before
    // _slots / _entity_count etc. tear down. Safe to call even if no
    // async_* method was ever invoked (shutdown_all is a no-op then).
    async_climate_shutdown_all();
}

// ─── Component registry ────────────────────────────────────────────────────

int DCWorldExt::register_component(const StringName &name, int dtype, int stride, bool track_prev) {
    if (_slot_by_name.has(name)) {
        return _slot_by_name[name];
    }
    Slot s;
    s.name       = name;
    s.dtype      = static_cast<SlotDType>(dtype);
    s.stride     = stride > 0 ? stride : 1;
    s.track_prev = track_prev;
    // Pre-size to current entity count so existing entities have valid slots.
    if (_entity_count > 0) {
        _ensure_slot_capacity(s, _entity_count);
    }
    _slots.push_back(s);
    int id = _slots.size() - 1;
    _slot_by_name[name] = id;
    return id;
}

int DCWorldExt::component_id(const StringName &name) const {
    if (_slot_by_name.has(name)) {
        return _slot_by_name[name];
    }
    return -1;
}

void DCWorldExt::_ensure_slot_capacity(Slot &slot, int new_count) {
    // Don't touch externally-owned buffers — that would break the COW alias
    // with MapData and silently desync the GDScript renderer from the C++
    // hot loop. The owner (MapData) sized the buffer, we just observe it.
    if (slot.external_ref) {
        return;
    }
    const int needed = new_count * slot.stride;
    switch (slot.dtype) {
        case SlotDType::F32:
            if (slot.arr_f32.size() < needed) slot.arr_f32.resize(needed);
            break;
        case SlotDType::I32:
            if (slot.arr_i32.size() < needed) slot.arr_i32.resize(needed);
            break;
        case SlotDType::U8:
            if (slot.arr_u8.size() < needed) slot.arr_u8.resize(needed);
            break;
    }
}

// ─── Entity / Pool API ─────────────────────────────────────────────────────

int DCWorldExt::create_entities(int count) {
    if (count <= 0) return _entity_count;
    const int first = _entity_count;
    _entity_count += count;
    for (int i = 0; i < _slots.size(); ++i) {
        _ensure_slot_capacity(_slots.write[i], _entity_count);
    }
    if (_entity_archetype.size() < _entity_count) {
        _entity_archetype.resize(_entity_count);
        // ARCH_NONE convention = -1 (matches GDScript world.gd)
        for (int i = first; i < _entity_count; ++i) {
            _entity_archetype.set(i, -1);
        }
    }
    return first;
}

int DCWorldExt::create_pool(const StringName &name, int capacity) {
    if (_pool_by_name.has(name)) {
        return _pool_by_name[name];
    }
    Pool p;
    p.name     = name;
    p.start    = _entity_count;
    p.capacity = capacity;
    create_entities(capacity);
    // Build LIFO free list: the lowest idx ends on top of the stack so
    // allocation feels deterministic in tests (allocates in ascending order).
    p.free_list.resize(capacity);
    for (int i = 0; i < capacity; ++i) {
        p.free_list.write[i] = p.start + (capacity - 1 - i);
    }
    _pools.push_back(p);
    int id = _pools.size() - 1;
    _pool_by_name[name] = id;
    return id;
}

Vector2i DCWorldExt::pool_range(int pool_id) const {
    ERR_FAIL_INDEX_V(pool_id, _pools.size(), Vector2i(0, 0));
    const Pool &p = _pools[pool_id];
    return Vector2i(p.start, p.start + p.capacity);
}

int DCWorldExt::pool_id(const StringName &name) const {
    if (_pool_by_name.has(name)) return _pool_by_name[name];
    return -1;
}

int DCWorldExt::pool_free_count(int pool_id) const {
    ERR_FAIL_INDEX_V(pool_id, _pools.size(), 0);
    return _pools[pool_id].free_list.size();
}

// ─── Hot-path views (zero-copy COW) ────────────────────────────────────────

PackedFloat32Array DCWorldExt::view_f32(int comp_id) {
    ERR_FAIL_INDEX_V(comp_id, _slots.size(), PackedFloat32Array());
    return _slots[comp_id].arr_f32;
}

PackedInt32Array DCWorldExt::view_i32(int comp_id) {
    ERR_FAIL_INDEX_V(comp_id, _slots.size(), PackedInt32Array());
    return _slots[comp_id].arr_i32;
}

PackedByteArray DCWorldExt::view_u8(int comp_id) {
    ERR_FAIL_INDEX_V(comp_id, _slots.size(), PackedByteArray());
    return _slots[comp_id].arr_u8;
}

// ─── Mode-B snapshot API ──────────────────────────────────────────────────
//
// Returns a value-copy of `_slots[comp_id].arr_f32`. Godot PackedArray COW
// means we don't memcpy here — the returned handle bumps the refcount, and
// the GDScript side gets a private copy on the first write.
//
// Contract:
//   * Out-of-range comp_id     → empty PackedFloat32Array, no error.
//   * Slot dtype != F32        → empty PackedFloat32Array, no error.
//
// This is the recommended Mode-B read path. `view_f32` is kept as a thin
// alias for legacy call sites; new code should always call `snapshot_f32`.
PackedFloat32Array DCWorldExt::snapshot_f32(int comp_id) {
    if (comp_id < 0 || comp_id >= _slots.size()) {
        return PackedFloat32Array();
    }
    const Slot &s = _slots[comp_id];
    if (s.dtype != SlotDType::F32) {
        return PackedFloat32Array();
    }
    return s.arr_f32;
}

// ─── Hot-path writes ──────────────────────────────────────────────────────
//
// Pattern these replace (legacy / GDScript-DCWorld-only):
//     var arr := world.view_f32(c)   # CoW alias under DCWorld
//     arr[i] = v                     # writes back into World storage
//
// Under DCWorldExt that pattern silently fails because godot-cpp returns a
// PackedArray *copy* via Variant. The explicit write_*/write_*_range methods
// always go through the C++ instance and mutate _slots[comp_id] directly.

void DCWorldExt::write_f32(int comp_id, int idx, float v) {
    ERR_FAIL_INDEX(comp_id, _slots.size());
    Slot &s = _slots.write[comp_id];
    ERR_FAIL_INDEX(idx, s.arr_f32.size());
    s.arr_f32.set(idx, v);
}

void DCWorldExt::write_i32(int comp_id, int idx, int32_t v) {
    ERR_FAIL_INDEX(comp_id, _slots.size());
    Slot &s = _slots.write[comp_id];
    ERR_FAIL_INDEX(idx, s.arr_i32.size());
    s.arr_i32.set(idx, v);
}

void DCWorldExt::write_u8(int comp_id, int idx, int v) {
    ERR_FAIL_INDEX(comp_id, _slots.size());
    Slot &s = _slots.write[comp_id];
    ERR_FAIL_INDEX(idx, s.arr_u8.size());
    s.arr_u8.set(idx, static_cast<uint8_t>(v & 0xFF));
}

void DCWorldExt::write_f32_range(int comp_id, int start, const PackedFloat32Array &src) {
    ERR_FAIL_INDEX(comp_id, _slots.size());
    Slot &s = _slots.write[comp_id];
    const int n = src.size();
    if (n <= 0) return;
    ERR_FAIL_COND(start < 0);
    ERR_FAIL_COND(start + n > s.arr_f32.size());
    for (int i = 0; i < n; ++i) {
        s.arr_f32.set(start + i, src[i]);
    }
}

void DCWorldExt::write_i32_range(int comp_id, int start, const PackedInt32Array &src) {
    ERR_FAIL_INDEX(comp_id, _slots.size());
    Slot &s = _slots.write[comp_id];
    const int n = src.size();
    if (n <= 0) return;
    ERR_FAIL_COND(start < 0);
    ERR_FAIL_COND(start + n > s.arr_i32.size());
    for (int i = 0; i < n; ++i) {
        s.arr_i32.set(start + i, src[i]);
    }
}

void DCWorldExt::write_u8_range(int comp_id, int start, const PackedByteArray &src) {
    ERR_FAIL_INDEX(comp_id, _slots.size());
    Slot &s = _slots.write[comp_id];
    const int n = src.size();
    if (n <= 0) return;
    ERR_FAIL_COND(start < 0);
    ERR_FAIL_COND(start + n > s.arr_u8.size());
    for (int i = 0; i < n; ++i) {
        s.arr_u8.set(start + i, src[i]);
    }
}

// ─── Sparse / indexed writes ─────────────────────────────────────────
//
// One trans-boundary call writes N (idx, value) pairs. For 720 dirty cells
// out of 2400 this beats N separate write_f32() calls by ~5x, because each
// individual GDScript->C++ call has fixed marshal/dispatch overhead that no
// longer dominates here. See tmp/bench_dots_vs_dict.gd Cases 3/4.
//
// Bounds policy: out-of-range entries are silently skipped (NOT an error)
// because dirty lists may legitimately contain stale indices after pool
// resize. Length mismatch (indices vs values) is also tolerated by
// truncating to min().

void DCWorldExt::write_f32_indexed(int comp_id,
                                   const PackedInt32Array   &indices,
                                   const PackedFloat32Array &values) {
    ERR_FAIL_INDEX(comp_id, _slots.size());
    Slot &s = _slots.write[comp_id];
    const int n_idx = indices.size();
    const int n_val = values.size();
    const int n     = n_idx < n_val ? n_idx : n_val;
    const int cap   = s.arr_f32.size();
    // Read-only ptrs avoid CoW detach for indices/values. Slot's PackedArray
    // is mutated via .set() which is the standard godot-cpp API.
    const int32_t *idx_ptr = indices.ptr();
    const float   *val_ptr = values.ptr();
    for (int k = 0; k < n; ++k) {
        const int i = idx_ptr[k];
        if (i >= 0 && i < cap) {
            s.arr_f32.set(i, val_ptr[k]);
        }
    }
}

void DCWorldExt::write_i32_indexed(int comp_id,
                                   const PackedInt32Array &indices,
                                   const PackedInt32Array &values) {
    ERR_FAIL_INDEX(comp_id, _slots.size());
    Slot &s = _slots.write[comp_id];
    const int n_idx = indices.size();
    const int n_val = values.size();
    const int n     = n_idx < n_val ? n_idx : n_val;
    const int cap   = s.arr_i32.size();
    const int32_t *idx_ptr = indices.ptr();
    const int32_t *val_ptr = values.ptr();
    for (int k = 0; k < n; ++k) {
        const int i = idx_ptr[k];
        if (i >= 0 && i < cap) {
            s.arr_i32.set(i, val_ptr[k]);
        }
    }
}

void DCWorldExt::write_u8_indexed(int comp_id,
                                  const PackedInt32Array &indices,
                                  const PackedByteArray  &values) {
    ERR_FAIL_INDEX(comp_id, _slots.size());
    Slot &s = _slots.write[comp_id];
    const int n_idx = indices.size();
    const int n_val = values.size();
    const int n     = n_idx < n_val ? n_idx : n_val;
    const int cap   = s.arr_u8.size();
    const int32_t *idx_ptr = indices.ptr();
    const uint8_t *val_ptr = values.ptr();
    for (int k = 0; k < n; ++k) {
        const int i = idx_ptr[k];
        if (i >= 0 && i < cap) {
            s.arr_u8.set(i, val_ptr[k]);
        }
    }
}

void DCWorldExt::write_f32_scalar_indexed(int comp_id,
                                          const PackedInt32Array &indices,
                                          float v) {
    ERR_FAIL_INDEX(comp_id, _slots.size());
    Slot &s = _slots.write[comp_id];
    const int n   = indices.size();
    const int cap = s.arr_f32.size();
    const int32_t *idx_ptr = indices.ptr();
    for (int k = 0; k < n; ++k) {
        const int i = idx_ptr[k];
        if (i >= 0 && i < cap) {
            s.arr_f32.set(i, v);
        }
    }
}

void DCWorldExt::write_i32_scalar_indexed(int comp_id,
                                          const PackedInt32Array &indices,
                                          int32_t v) {
    ERR_FAIL_INDEX(comp_id, _slots.size());
    Slot &s = _slots.write[comp_id];
    const int n   = indices.size();
    const int cap = s.arr_i32.size();
    const int32_t *idx_ptr = indices.ptr();
    for (int k = 0; k < n; ++k) {
        const int i = idx_ptr[k];
        if (i >= 0 && i < cap) {
            s.arr_i32.set(i, v);
        }
    }
}

void DCWorldExt::write_u8_scalar_indexed(int comp_id,
                                         const PackedInt32Array &indices,
                                         int v) {
    ERR_FAIL_INDEX(comp_id, _slots.size());
    Slot &s = _slots.write[comp_id];
    const uint8_t  vu8 = static_cast<uint8_t>(v & 0xFF);
    const int      n   = indices.size();
    const int      cap = s.arr_u8.size();
    const int32_t *idx_ptr = indices.ptr();
    for (int k = 0; k < n; ++k) {
        const int i = idx_ptr[k];
        if (i >= 0 && i < cap) {
            s.arr_u8.set(i, vu8);
        }
    }
}

// ─── Bind to MapData ─────────────────────────────────────────────────────────//
// Strategy (architecture.md §2.4, decision log option B):
//   We treat MapData as a duck-typed Object and reflectively read each
//   property by name (e.g. "temp_arr"). This adds zero churn on the
//   GDScript side — MapData already exposes those fields. If profiling
//   later shows the bind step itself is hot (it shouldn't, called once),
//   we can switch to handwritten getters in I3.B.
//
// Naming convention: slot StringName = e.g. "cell_temp" → MapData property
// = "temp_arr" / "moisture_arr" / etc. The mapping table lives in the
// GDScript `bind_map_data` today; in C++ we replicate the table inline.
//
// ─── Boundary contract: snapshot + flush, NOT two-way alias ────────────────
// GDExtension ABI forces every cross-boundary PackedArray through a Variant
// wrapper, taking the refcount to ≥ 2. Any C++-side ptrw() therefore CoW-
// detaches into a private buffer. Implication: we cannot maintain a true
// two-way zero-copy alias with the GDScript-side property. Real contract:
//   * C++ → GDScript : write hot loop's own buffer freely, then call
//                      map_data->set(prop, slot.arr_xxx) ONCE per pass to
//                      flush the (possibly-detached) buffer back.
//   * GDScript → C++ : write_f32 / write_f32_indexed at pass boundaries.
//                      In-place writes to bound fields during a pass are
//                      INVISIBLE to C++ until the next bind_map_data().
//   * Reseat (resize / whole-assign) on either side requires re-bind.
// Verified by tmp/test_bind_alias.gd; locked in docs/performance-charter.md
// §11. Boundary overhead: ~14 µs / bind across 35 components (≈ 0.04% of a
// daily-tick budget — does not affect any DOTS speed-up red lines).

namespace {

// ─── BIND_TABLE — autogenerated single source of truth ─────────────────────
//
// The cell-level slot ↔ MapData property mapping used to live as a hand-
// maintained `static const BindEntry BIND_TABLE[]` literal here, kept in
// sync by hand with `scripts/data_core/world.gd::bind_map_data`. That
// dual-table arrangement was a documented anti-pattern (see
// performance-charter §11.2 / §12.4 historical warnings — naming drifts
// like `snow_arr` vs `snow_cover_arr` silently no-bound entire components).
//
// Phase A.1 of the framework hardening plan (dots-migration-roadmap §3 A1)
// collapses both tables onto a single source:
//
//     scripts/data_core/component_schema.gd  (DCComponentSchema.CELL_SCHEMA)
//
// The Python codegen `tools/codegen/gen_cpp_bind_table.py` reads that
// schema and emits `component_bind_table.gen.h` (included above). The
// emitted symbols `BIND_TABLE_AUTOGEN` and `BIND_TABLE_AUTOGEN_SIZE`
// expose the same shape as the legacy table, so the call sites below
// (`bind_map_data`, `_debug_poke_f32_with_flush`) only swap the names.
//
// Adding a new cell component is now a one-line schema edit + rerun
// codegen; see docs/dots-component-schema.md for the 5-step SOP.
//
// `BindEntry` itself is now defined inside the generated header (still in
// `namespace pk`), so we re-export references here under the legacy
// `BIND_TABLE` / `BIND_TABLE_SIZE` names to avoid touching every call
// site. `auto &` forms a reference to the array type, preserving the
// `sizeof(BIND_TABLE) / sizeof(BindEntry)` idiom should any future code
// re-use it.
constexpr auto &BIND_TABLE      = BIND_TABLE_AUTOGEN;
constexpr int   BIND_TABLE_SIZE = BIND_TABLE_AUTOGEN_SIZE;

} // namespace

bool DCWorldExt::bind_map_data(Object *map_data) {
    if (map_data == nullptr) {
        UtilityFunctions::push_error("[DCWorldExt] bind_map_data: null map_data");
        return false;
    }
    _map_data = map_data;

    int bound_count = 0;
    int auto_registered = 0;
    for (int i = 0; i < BIND_TABLE_SIZE; ++i) {
        const BindEntry &e = BIND_TABLE[i];
        StringName slot_name(e.slot_name);
        StringName prop_name(e.property_name);

        int slot_id = component_id(slot_name);
        if (slot_id < 0) {
            // ─── Auto-register on first bind (Phase 3a self-contained ECS) ─
            // Earlier contract required callers to register every slot first
            // (mirroring the GDScript verifier in tmp/test_bind_alias.gd).
            // That made DCWorldExt non-self-contained: every production call
            // site (DataCore::_setup_sus, etc.) had to keep a parallel
            // GDScript copy of BIND_TABLE in sync. We now treat BIND_TABLE
            // itself as the single source of truth: any slot listed here is
            // auto-registered with stride=1 / track_prev=false (snapshot
            // model — double buffering belongs to the pass code, not to the
            // bind layer; see docs/performance-charter.md §11).
            slot_id = register_component(slot_name,
                                         static_cast<int>(e.dtype),
                                         /*stride=*/1,
                                         /*track_prev=*/false);
            if (slot_id < 0) {
                UtilityFunctions::push_warning(
                    "[DCWorldExt] bind: auto-register failed for ", slot_name);
                continue;
            }
            ++auto_registered;
        }
        Variant v = map_data->get(prop_name);
        if (v.get_type() == Variant::NIL) {
            // property absent — non-fatal, move on
            continue;
        }
        Slot &s = _slots.write[slot_id];
        switch (e.dtype) {
            case SlotDType::F32:
                if (v.get_type() != Variant::PACKED_FLOAT32_ARRAY) {
                    UtilityFunctions::push_warning("[DCWorldExt] bind: ", prop_name, " is not PackedFloat32Array");
                    continue;
                }
                s.arr_f32      = v;
                s.external_ref = true;
                // ─── Snapshot + flush model (NOT two-way alias) ────────────
                // GDExtension ABI reality (verified by tmp/test_bind_alias.gd
                // T1/T2 and locked into docs/performance-charter.md §11):
                //   Every PackedArray that traverses the boundary is wrapped
                //   in a Variant. By the time we hold s.arr_f32 here, refcount
                //   is ≥ 2, so any subsequent ptrw() in the C++ hot loop will
                //   CoW-detach into a private buffer. That means we can never
                //   keep a true two-way zero-copy alias with the GDScript-side
                //   property — the contract is one-way snapshots:
                //     C++ → GDScript : write-then-set() at pass end (T1b)
                //     GDScript → C++ : world.write_f32 / write_f32_indexed
                //                      between passes (NOT in-place writes)
                // The set() below pre-establishes the same GDScript-visible
                // buffer right after bind, so the very first read on the
                // GDScript side already sees C++-owned memory. Subsequent
                // hot-loop writes are flushed by the pass code itself.
                // Boundary cost: ~14 µs / bind for the full 35-component
                // table — negligible (≈ 0.04% of a daily-tick budget).
                map_data->set(prop_name, s.arr_f32);
                break;
            case SlotDType::I32:
                if (v.get_type() != Variant::PACKED_INT32_ARRAY) {
                    UtilityFunctions::push_warning("[DCWorldExt] bind: ", prop_name, " is not PackedInt32Array");
                    continue;
                }
                s.arr_i32      = v;
                s.external_ref = true;
                map_data->set(prop_name, s.arr_i32);
                break;
            case SlotDType::U8:
                if (v.get_type() != Variant::PACKED_BYTE_ARRAY) {
                    UtilityFunctions::push_warning("[DCWorldExt] bind: ", prop_name, " is not PackedByteArray");
                    continue;
                }
                s.arr_u8       = v;
                s.external_ref = true;
                map_data->set(prop_name, s.arr_u8);
                break;
        }
        ++bound_count;
    }

    _bound = (bound_count > 0);
    UtilityFunctions::print("[DCWorldExt] bind_map_data: ", bound_count,
                            " components bound (auto-registered=", auto_registered,
                            "; snapshot model; see world_ext.cpp comment & charter §11)");
    return _bound;
}

// ─── Archetype ─────────────────────────────────────────────────────────────

int DCWorldExt::create_archetype(const StringName &name, const Array &comp_ids) {
    if (_archetype_by_name.has(name)) {
        return _archetype_by_name[name];
    }
    _archetypes.push_back(comp_ids);
    int id = _archetypes.size() - 1;
    _archetype_by_name[name] = id;
    return id;
}

void DCWorldExt::assign_archetype(int idx, int arch_id) {
    if (idx < 0 || idx >= _entity_count) return;
    if (_entity_archetype.size() < _entity_count) {
        _entity_archetype.resize(_entity_count);
    }
    _entity_archetype.set(idx, arch_id);
}

// ─── Hot-loop implementations ──────────────────────────────────────────────

// Phase 3b Step 3b-1: real implementation of Pass-A (climate daily tick),
// MINUS the dirty-mask + global-drift accounting — that's Step 3b-1.5, kept
// out of this commit so we can A/B-validate the core math first without
// fighting two new behaviours at once.
//
// Truth source: `_climate_pass_a()` in
//   Project/project-keynes/scripts/geography/map_generator.gd
// (the SoA-aware branch, i.e. when `_use_dc=true`). Algorithm spec is in
//   .codebuddy/plan/dots-roadmap-to-gdextension/architecture.md  §"Step 3b-0"
//
// Performance contract: charter §0 M2 baseline = 0.30 ms / pass @ N=2400.
// Current GDScript implementation = ~4.1 ms / pass. Expected ~13× speedup.
//
// Return value:
//   ≥ 0.0 → C++ took ownership; GDScript should NOT run its legacy loop.
//   < 0.0 → fall-back signal (binding broken, missing slot, size mismatch,
//           etc.) — the GDScript caller already does `if rc >= 0: return`.
//
// IMPORTANT: this function ONLY writes to `_slots[id].arr_*.ptrw()`, never
// calls `map_data->set(prop, arr)` to flush. The Step-5 probe proved that
// the bind_map_data CoW alias survives ptrw() writes, so the GDScript
// renderer already sees C++-side mutations on `map.temp_arr[i]` etc. with
// zero per-pass flush cost. This is the M2 hot-path pattern from charter §11.
// ─── Mode-B reference implementation: temp_drift_pass ─────────────────────
//
// The minimal canonical example for the "Owned-by-C++ + GDScript snapshot"
// communication contract documented in `docs/performance-charter.md` §12.
// Behaviour: for every element in _slots[CELL_TEMP].arr_f32, add
// `drift_amount`. Pure scalar, no SIMD, no threading — the goal is to
// ship a template that is impossible to get wrong, not to be fast.
//
// Hot-loop discipline (copy this verbatim into new passes):
//   * Resolve slot ids ONCE before the loop.
//   * Take ONE ptrw() pointer per output buffer.
//   * Loop body contains ZERO Variant / set() / get() / push_back calls.
//   * NO obj.set() flush — Mode B says GDScript pulls via snapshot_f32,
//     it does NOT rely on push-back aliasing.
//
// Safety: if `cell_temp` was never registered (e.g. unit-test run before
// MapData binding), the call is a no-op. No crash, no error log spam.
void DCWorldExt::run_temp_drift_pass(float drift_amount) {
    const int sid = component_id(StringName("cell_temp"));
    if (sid < 0) {
        return; // slot not registered yet → safe no-op
    }
    Slot &s = _slots.write[sid];
    if (s.dtype != SlotDType::F32) {
        return; // type mismatch → safe no-op
    }
    const int n = s.arr_f32.size();
    if (n <= 0) {
        return;
    }
    float * const __restrict p = s.arr_f32.ptrw();
    for (int i = 0; i < n; ++i) {
        p[i] += drift_amount;
    }
}

// ─── Pass #2: thermal_gradient_pass (reference impl with neighbour access) ──
// Implements `out = clamp(|∇T| * (1 + gain*elev) * k, 0, 1)` over a 2-D grid
// laid out row-major in the cell SoA arrays. Every step that could trip up
// a copy-paste author is annotated inline so the doc in performance-charter
// §12.6 can quote this code verbatim.
void DCWorldExt::run_thermal_gradient_pass(int grid_w,
                                           int grid_h,
                                           float elevation_gain,
                                           float normalize_k) {
    // ─── 1. Resolve slot ids ONCE (zero string ops in the hot loop) ────
    const int sid_temp = component_id(StringName("cell_temp"));
    const int sid_elev = component_id(StringName("cell_elevation"));
    const int sid_out  = component_id(StringName("cell_demo_thermal_gradient"));
    if (sid_temp < 0 || sid_elev < 0 || sid_out < 0) {
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_thermal_gradient_pass: missing slot (",
            "cell_temp=", sid_temp,
            ", cell_elevation=", sid_elev,
            ", cell_demo_thermal_gradient=", sid_out,
            ") — pass skipped (likely demo_thermal_gradient_enabled=false)");
        return;
    }
    Slot &s_temp = _slots.write[sid_temp];
    Slot &s_elev = _slots.write[sid_elev];
    Slot &s_out  = _slots.write[sid_out];
    if (s_temp.dtype != SlotDType::F32 || s_elev.dtype != SlotDType::F32 ||
            s_out.dtype != SlotDType::F32) {
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_thermal_gradient_pass: slot dtype mismatch — pass skipped");
        return;
    }

    // ─── 2. Validate grid dimensions vs. SoA size (paranoia, not optimisation) ─
    if (grid_w <= 0 || grid_h <= 0) {
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_thermal_gradient_pass: invalid grid ", grid_w, "x", grid_h);
        return;
    }
    const int n = grid_w * grid_h;
    if (s_temp.arr_f32.size() != n || s_elev.arr_f32.size() != n ||
            s_out.arr_f32.size() != n) {
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_thermal_gradient_pass: size mismatch (expected ", n,
            ", got temp=", s_temp.arr_f32.size(),
            ", elev=", s_elev.arr_f32.size(),
            ", out=", s_out.arr_f32.size(), ") — pass skipped");
        return;
    }

    // ─── 3. Take ONE pointer per buffer (read + write) ──────────────────
    const float * const __restrict T    = s_temp.arr_f32.ptr();
    const float * const __restrict E    = s_elev.arr_f32.ptr();
    float       * const __restrict OUT  = s_out.arr_f32.ptrw();

    // ─── 4. Tight loop — neighbour access by integer index, clamp-to-edge ─
    // Border discipline: substitute self-value for out-of-range neighbours
    // (Neumann BC). NEVER use modulo-wrap and NEVER branch inside the
    // arithmetic — branches at the boundary are fine, the compiler handles
    // them just like a peeled prologue/epilogue.
    for (int y = 0; y < grid_h; ++y) {
        const int row    = y * grid_w;
        const int row_n  = (y > 0)            ? (row - grid_w) : row;
        const int row_s  = (y < grid_h - 1)   ? (row + grid_w) : row;
        for (int x = 0; x < grid_w; ++x) {
            const int i  = row + x;
            const int iw = (x > 0)            ? (i - 1) : i;
            const int ie = (x < grid_w - 1)   ? (i + 1) : i;
            const int in_ = row_n + x;
            const int is = row_s + x;

            // ── BIT-EQUAL DISCIPLINE ─────────────────────────────────────
            // GDScript reads from PackedFloat32Array as `float`, which is a
            // 64-bit double in GDScript. All intermediate arithmetic on the
            // GDScript side therefore happens in double; the narrow back to
            // float only occurs at the store. Mirror that here: promote to
            // double on every load and narrow exactly once at the store.
            // Without this, the float-domain (gx*gx + gy*gy) addition and
            // the float gmag*amp*k product each round-off at a different
            // bit than the GDScript path, yielding ~40% of cells diverging
            // by 1 ULP. This is the canonical fix for Pass-#2 bit-equal.
            const double t_ie = static_cast<double>(T[ie]);
            const double t_iw = static_cast<double>(T[iw]);
            const double t_is = static_cast<double>(T[is]);
            const double t_in = static_cast<double>(T[in_]);
            const double e_i  = static_cast<double>(E[i]);

            const double gx = (t_ie - t_iw) * 0.5;
            const double gy = (t_is - t_in) * 0.5;
            const double gmag = Math::sqrt(gx * gx + gy * gy);
            const double amp  = 1.0 + static_cast<double>(elevation_gain) * e_i;
            double v = gmag * amp * static_cast<double>(normalize_k);
            // clamp to [0, 1] so the result is overlay-ready (R8/R16F).
            if (v < 0.0) v = 0.0;
            else if (v > 1.0) v = 1.0;
            // Single narrow at the store — matches `out[i] = v` in GDScript.
            OUT[i] = static_cast<float>(v);
        }
    }
}

// ─── Pass #3: demo_complex_pass (iterated diffusion + wind approx) ──────────
// Algorithm spec lives next to the declaration in world_ext.h. This impl
// keeps every line easily reviewable so performance-charter §12.6.6 can
// quote it verbatim. The inner stencil is intentionally scalar — Pass #3
// stresses *algorithmic* complexity, not SIMD/threading (per §0 铁律 2).
void DCWorldExt::run_demo_complex_pass(int grid_w,
                                       int grid_h,
                                       int iterations,
                                       int kernel_radius,
                                       float coriolis_strength,
                                       float terrain_drag,
                                       float elevation_gain,
                                       float normalize_k) {
    // ─── 0. Knob clamps (single push_warning per process for each knob) ─
    static bool _warned_iter = false;
    static bool _warned_kr   = false;
    static bool _warned_cor  = false;
    static bool _warned_drag = false;
    if (iterations < 1 || iterations > 64) {
        if (!_warned_iter) {
            _warned_iter = true;
            UtilityFunctions::push_warning(
                "[DCWorldExt] run_demo_complex_pass: iterations out of [1,64], clamped (was ",
                iterations, ")");
        }
        if (iterations < 1) iterations = 1;
        if (iterations > 64) iterations = 64;
    }
    if (kernel_radius < 1 || kernel_radius > 5) {
        if (!_warned_kr) {
            _warned_kr = true;
            UtilityFunctions::push_warning(
                "[DCWorldExt] run_demo_complex_pass: kernel_radius out of [1,5], clamped (was ",
                kernel_radius, ")");
        }
        if (kernel_radius < 1) kernel_radius = 1;
        if (kernel_radius > 5) kernel_radius = 5;
    }
    if (coriolis_strength < -1.0f || coriolis_strength > 1.0f) {
        if (!_warned_cor) {
            _warned_cor = true;
            UtilityFunctions::push_warning(
                "[DCWorldExt] run_demo_complex_pass: coriolis_strength out of [-1,1], clamped");
        }
        if (coriolis_strength < -1.0f) coriolis_strength = -1.0f;
        if (coriolis_strength > 1.0f)  coriolis_strength = 1.0f;
    }
    if (terrain_drag < 0.0f || terrain_drag > 1.0f) {
        if (!_warned_drag) {
            _warned_drag = true;
            UtilityFunctions::push_warning(
                "[DCWorldExt] run_demo_complex_pass: terrain_drag out of [0,1], clamped");
        }
        if (terrain_drag < 0.0f) terrain_drag = 0.0f;
        if (terrain_drag > 1.0f) terrain_drag = 1.0f;
    }

    // ─── 1. Resolve slot ids ONCE (zero string ops in the hot loop) ────
    const int sid_temp = component_id(StringName("cell_temp"));
    const int sid_elev = component_id(StringName("cell_elevation"));
    const int sid_out  = component_id(StringName("cell_demo_thermal_gradient"));
    if (sid_temp < 0 || sid_elev < 0 || sid_out < 0) {
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_demo_complex_pass: missing slot (",
            "cell_temp=", sid_temp,
            ", cell_elevation=", sid_elev,
            ", cell_demo_thermal_gradient=", sid_out,
            ") — pass skipped");
        return;
    }
    Slot &s_temp = _slots.write[sid_temp];
    Slot &s_elev = _slots.write[sid_elev];
    Slot &s_out  = _slots.write[sid_out];
    if (s_temp.dtype != SlotDType::F32 || s_elev.dtype != SlotDType::F32 ||
            s_out.dtype != SlotDType::F32) {
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_demo_complex_pass: slot dtype mismatch — pass skipped");
        return;
    }
    if (grid_w <= 0 || grid_h <= 0) {
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_demo_complex_pass: invalid grid ", grid_w, "x", grid_h);
        return;
    }
    const int n = grid_w * grid_h;
    if (s_temp.arr_f32.size() != n || s_elev.arr_f32.size() != n ||
            s_out.arr_f32.size() != n) {
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_demo_complex_pass: size mismatch (expected ", n,
            ", got temp=", s_temp.arr_f32.size(),
            ", elev=", s_elev.arr_f32.size(),
            ", out=", s_out.arr_f32.size(), ") — pass skipped");
        return;
    }

    // ─── 2. Take ONE pointer per buffer (read-only inputs) ──────────────
    const float * const __restrict T_in = s_temp.arr_f32.ptr();
    const float * const __restrict E    = s_elev.arr_f32.ptr();

    // ─── 3. Pre-compute Gaussian kernel weights (one C-stack lookup) ────
    //   Max radius = 5 → max kernel size = 11×11 = 121 entries.
    //   Stored row-major over (dy = -kr..+kr) × (dx = -kr..+kr).
    const int kr   = kernel_radius;
    const int ksz  = 2 * kr + 1;
    const int klen = ksz * ksz;
    double kernel[121]; // 11*11 hard cap — enforced by knob clamp
    double kernel_sum = 0.0;
    for (int dy = -kr; dy <= kr; ++dy) {
        for (int dx = -kr; dx <= kr; ++dx) {
            // exp(-(dx²+dy²)/2) — fixed sigma=1 keeps the kernel compact
            // and the GDScript port byte-for-byte easy to replicate.
            const double w = std::exp(-(double)(dx * dx + dy * dy) * 0.5);
            kernel[(dy + kr) * ksz + (dx + kr)] = w;
            kernel_sum += w;
        }
    }
    const double kernel_inv_sum = (kernel_sum > 0.0) ? (1.0 / kernel_sum) : 0.0;

    // ─── 4. Allocate ping-pong buffers ONCE (outside iter loop) ─────────
    // Stored as double to keep bit-equal discipline with GDScript port.
    std::vector<double> buf_a(n);
    std::vector<double> buf_b(n);
    for (int i = 0; i < n; ++i) {
        buf_a[i] = static_cast<double>(T_in[i]);
    }

    const double step_size = 0.05;       // fixed stability constant (see §12.6.6)
    const double cor       = static_cast<double>(coriolis_strength);
    const double drag      = static_cast<double>(terrain_drag);

    // ─── 5. Iterate `iterations` steps (ping-pong) ──────────────────────
    for (int it = 0; it < iterations; ++it) {
        const std::vector<double> &src = (it & 1) ? buf_b : buf_a;
        std::vector<double>       &dst = (it & 1) ? buf_a : buf_b;
        const double *__restrict S = src.data();
        double       *__restrict D = dst.data();

        for (int y = 0; y < grid_h; ++y) {
            // Latitude-dependent coriolis sign: north hemisphere → +1, south → -1
            const double cor_sign = (y < grid_h / 2) ? -1.0 : 1.0;
            const double rot_rad  = cor * cor_sign * 1.5707963267948966; // π/2

            for (int x = 0; x < grid_w; ++x) {
                const int i = y * grid_w + x;

                // ─── 5.1 Gaussian-weighted smooth (2kr+1)² stencil ────
                double accum = 0.0;
                for (int dy = -kr; dy <= kr; ++dy) {
                    int ny = y + dy;
                    if (ny < 0)         ny = 0;
                    else if (ny >= grid_h) ny = grid_h - 1;
                    const int row = ny * grid_w;
                    const double *kw_row = &kernel[(dy + kr) * ksz];
                    for (int dx = -kr; dx <= kr; ++dx) {
                        int nx = x + dx;
                        if (nx < 0)         nx = 0;
                        else if (nx >= grid_w) nx = grid_w - 1;
                        accum += S[row + nx] * kw_row[dx + kr];
                    }
                }
                const double smooth = accum * kernel_inv_sum;

                // ─── 5.2 Sobel 3×3 gradient (clamp-to-edge) ───────────
                const int xw = (x > 0)            ? (x - 1) : x;
                const int xe = (x < grid_w - 1)   ? (x + 1) : x;
                const int yn = (y > 0)            ? (y - 1) : y;
                const int ys = (y < grid_h - 1)   ? (y + 1) : y;
                const int row_n = yn * grid_w;
                const int row_c = y  * grid_w;
                const int row_s = ys * grid_w;
                const double gx = (S[row_n + xe] + 2.0 * S[row_c + xe] + S[row_s + xe]
                                  - S[row_n + xw] - 2.0 * S[row_c + xw] - S[row_s + xw]) * 0.125;
                const double gy = (S[row_s + xw] + 2.0 * S[row_s + x ] + S[row_s + xe]
                                  - S[row_n + xw] - 2.0 * S[row_n + x ] - S[row_n + xe]) * 0.125;

                // ─── 5.3 Coriolis rotation (90° × cor_sign × strength) ─
                const double cs = std::cos(rot_rad);
                const double sn = std::sin(rot_rad);
                const double gx_p = gx * cs - gy * sn;
                const double gy_p = gx * sn + gy * cs;

                // ─── 5.4 Terrain damping ─────────────────────────────
                const double damp = 1.0 - drag * static_cast<double>(E[i]);

                // ─── 5.5 Flux-driven evolution ───────────────────────
                const double flux = gx_p + gy_p;
                D[i] = smooth + flux * damp * step_size;
            }
        }
    }

    // ─── 6. Pick the final buffer ───────────────────────────────────────
    const std::vector<double> &last = (iterations & 1) ? buf_b : buf_a;

    // ─── 7. Normalize to [0,1] over the whole field ─────────────────────
    double out_min =  std::numeric_limits<double>::infinity();
    double out_max = -std::numeric_limits<double>::infinity();
    for (int i = 0; i < n; ++i) {
        const double v = last[i];
        if (v < out_min) out_min = v;
        if (v > out_max) out_max = v;
    }
    const double denom = (out_max - out_min) > 1.0e-6
                       ? (out_max - out_min) : 1.0e-6;
    const double inv_denom = 1.0 / denom;

    // ─── 8. Apply (1 + gain·elev) · k + clamp to [0,1], narrow to float ─
    float * const __restrict OUT = s_out.arr_f32.ptrw();
    const double gain = static_cast<double>(elevation_gain);
    const double k    = static_cast<double>(normalize_k);
    for (int i = 0; i < n; ++i) {
        const double norm = (last[i] - out_min) * inv_denom;
        const double amp  = 1.0 + gain * static_cast<double>(E[i]);
        double v = norm * amp * k;
        if (v < 0.0) v = 0.0;
        else if (v > 1.0) v = 1.0;
        OUT[i] = static_cast<float>(v);
    }
}

// ─── DOTS-A1 EXPERIMENT: run_demo_complex_pass_archetyped ────────────────────
// See world_ext.h for the contract. Implementation strategy:
//
//   * The iteration kernel itself runs on EVERY cell (so neighbour stencils
//     stay valid — a LAND cell at the border of an OCEAN region must still
//     read its OCEAN neighbours' temp values during the smoothing/sobel
//     stage). This is the algorithmically faithful interpretation of
//     "archetype filter": filter the *write*, not the neighbour-read.
//
//   * The post-iter normalize+output stage (steps 7+8 in vanilla) honours
//     the archetype filter:
//       - cells with arch != target → OUT[i] = 0.0f, skipped from min/max.
//       - cells with arch == target → standard normalize + amp + clamp.
//
//   * `target_archetype < 0` is the "no filter" control row. It is
//     algorithmically identical to vanilla `run_demo_complex_pass` — the
//     bench uses this to confirm bit-equal with the vanilla pass and
//     measure the "extra branch overhead" on its own.
//
// NOTE: We deliberately keep this implementation as a near-verbatim copy
// of `run_demo_complex_pass`. Sharing code via a template/helper would
// make the bench less useful (we'd be measuring the helper's call cost
// rather than the archetype branch's cost on its own).
void DCWorldExt::run_demo_complex_pass_archetyped(int grid_w,
                                                  int grid_h,
                                                  int iterations,
                                                  int kernel_radius,
                                                  float coriolis_strength,
                                                  float terrain_drag,
                                                  float elevation_gain,
                                                  float normalize_k,
                                                  int target_archetype) {
    // ─── 0. Knob clamps (silent — vanilla version owns the warning prints) ─
    if (iterations < 1)        iterations = 1;
    if (iterations > 64)       iterations = 64;
    if (kernel_radius < 1)     kernel_radius = 1;
    if (kernel_radius > 5)     kernel_radius = 5;
    if (coriolis_strength < -1.0f) coriolis_strength = -1.0f;
    if (coriolis_strength >  1.0f) coriolis_strength =  1.0f;
    if (terrain_drag < 0.0f)   terrain_drag = 0.0f;
    if (terrain_drag > 1.0f)   terrain_drag = 1.0f;

    // ─── 1. Resolve slot ids ONCE ──────────────────────────────────────
    const int sid_temp = component_id(StringName("cell_temp"));
    const int sid_elev = component_id(StringName("cell_elevation"));
    const int sid_out  = component_id(StringName("cell_demo_thermal_gradient"));
    if (sid_temp < 0 || sid_elev < 0 || sid_out < 0) {
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_demo_complex_pass_archetyped: missing slot");
        return;
    }
    Slot &s_temp = _slots.write[sid_temp];
    Slot &s_elev = _slots.write[sid_elev];
    Slot &s_out  = _slots.write[sid_out];
    if (s_temp.dtype != SlotDType::F32 || s_elev.dtype != SlotDType::F32 ||
            s_out.dtype != SlotDType::F32) {
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_demo_complex_pass_archetyped: slot dtype mismatch — pass skipped");
        return;
    }
    if (grid_w <= 0 || grid_h <= 0) {
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_demo_complex_pass_archetyped: invalid grid ", grid_w, "x", grid_h);
        return;
    }
    const int n = grid_w * grid_h;
    if (s_temp.arr_f32.size() != n || s_elev.arr_f32.size() != n ||
            s_out.arr_f32.size() != n) {
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_demo_complex_pass_archetyped: size mismatch (expected ", n,
            ", got temp=", s_temp.arr_f32.size(),
            ", elev=", s_elev.arr_f32.size(),
            ", out=", s_out.arr_f32.size(), ") — pass skipped");
        return;
    }

    // Archetype array bound check (only meaningful if filter is active).
    const bool   filter_active = (target_archetype >= 0);
    const int32_t * const __restrict ARCH = filter_active
        ? _entity_archetype.ptr() : nullptr;
    if (filter_active && _entity_archetype.size() < n) {
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_demo_complex_pass_archetyped: _entity_archetype size ",
            _entity_archetype.size(), " < n ", n,
            " — assign_archetype not called for all cells; pass skipped");
        return;
    }

    // ─── 2. Take ONE pointer per buffer (read-only inputs) ──────────────
    const float * const __restrict T_in = s_temp.arr_f32.ptr();
    const float * const __restrict E    = s_elev.arr_f32.ptr();

    // ─── 3. Pre-compute Gaussian kernel weights ──────────────────────────
    const int kr   = kernel_radius;
    const int ksz  = 2 * kr + 1;
    double kernel[121]; // 11*11 hard cap
    double kernel_sum = 0.0;
    for (int dy = -kr; dy <= kr; ++dy) {
        for (int dx = -kr; dx <= kr; ++dx) {
            const double w = std::exp(-(double)(dx * dx + dy * dy) * 0.5);
            kernel[(dy + kr) * ksz + (dx + kr)] = w;
            kernel_sum += w;
        }
    }
    const double kernel_inv_sum = (kernel_sum > 0.0) ? (1.0 / kernel_sum) : 0.0;

    // ─── 4. Allocate ping-pong buffers ONCE ──────────────────────────────
    std::vector<double> buf_a(n);
    std::vector<double> buf_b(n);
    for (int i = 0; i < n; ++i) {
        buf_a[i] = static_cast<double>(T_in[i]);
    }

    const double step_size = 0.05;
    const double cor       = static_cast<double>(coriolis_strength);
    const double drag      = static_cast<double>(terrain_drag);

    // ─── 5. Iterate (every cell participates in the stencil — see banner) ─
    for (int it = 0; it < iterations; ++it) {
        const std::vector<double> &src = (it & 1) ? buf_b : buf_a;
        std::vector<double>       &dst = (it & 1) ? buf_a : buf_b;
        const double *__restrict S = src.data();
        double       *__restrict D = dst.data();

        for (int y = 0; y < grid_h; ++y) {
            const double cor_sign = (y < grid_h / 2) ? -1.0 : 1.0;
            const double rot_rad  = cor * cor_sign * 1.5707963267948966;

            for (int x = 0; x < grid_w; ++x) {
                const int i = y * grid_w + x;

                double accum = 0.0;
                for (int dy = -kr; dy <= kr; ++dy) {
                    int ny = y + dy;
                    if (ny < 0)            ny = 0;
                    else if (ny >= grid_h) ny = grid_h - 1;
                    const int row = ny * grid_w;
                    const double *kw_row = &kernel[(dy + kr) * ksz];
                    for (int dx = -kr; dx <= kr; ++dx) {
                        int nx = x + dx;
                        if (nx < 0)            nx = 0;
                        else if (nx >= grid_w) nx = grid_w - 1;
                        accum += S[row + nx] * kw_row[dx + kr];
                    }
                }
                const double smooth = accum * kernel_inv_sum;

                const int xw = (x > 0)            ? (x - 1) : x;
                const int xe = (x < grid_w - 1)   ? (x + 1) : x;
                const int yn = (y > 0)            ? (y - 1) : y;
                const int ys = (y < grid_h - 1)   ? (y + 1) : y;
                const int row_n = yn * grid_w;
                const int row_c = y  * grid_w;
                const int row_s = ys * grid_w;
                const double gx = (S[row_n + xe] + 2.0 * S[row_c + xe] + S[row_s + xe]
                                  - S[row_n + xw] - 2.0 * S[row_c + xw] - S[row_s + xw]) * 0.125;
                const double gy = (S[row_s + xw] + 2.0 * S[row_s + x ] + S[row_s + xe]
                                  - S[row_n + xw] - 2.0 * S[row_n + x ] - S[row_n + xe]) * 0.125;

                const double cs = std::cos(rot_rad);
                const double sn = std::sin(rot_rad);
                const double gx_p = gx * cs - gy * sn;
                const double gy_p = gx * sn + gy * cs;

                const double damp = 1.0 - drag * static_cast<double>(E[i]);
                const double flux = gx_p + gy_p;
                D[i] = smooth + flux * damp * step_size;
            }
        }
    }

    const std::vector<double> &last = (iterations & 1) ? buf_b : buf_a;

    // ─── 6+7. Archetype-aware normalization (only filtered-in cells count) ─
    double out_min =  std::numeric_limits<double>::infinity();
    double out_max = -std::numeric_limits<double>::infinity();
    if (filter_active) {
        for (int i = 0; i < n; ++i) {
            if (ARCH[i] != target_archetype) continue;
            const double v = last[i];
            if (v < out_min) out_min = v;
            if (v > out_max) out_max = v;
        }
        // Edge case: no cell matched the filter at all → leave OUT untouched
        // for non-matching cells, write 0.0f. min/max never updated → guard.
        if (!std::isfinite(out_min) || !std::isfinite(out_max)) {
            float * const __restrict OUT = s_out.arr_f32.ptrw();
            for (int i = 0; i < n; ++i) OUT[i] = 0.0f;
            return;
        }
    } else {
        for (int i = 0; i < n; ++i) {
            const double v = last[i];
            if (v < out_min) out_min = v;
            if (v > out_max) out_max = v;
        }
    }
    const double denom = (out_max - out_min) > 1.0e-6
                       ? (out_max - out_min) : 1.0e-6;
    const double inv_denom = 1.0 / denom;

    // ─── 8. Write OUT (filtered-in: full formula; filtered-out: 0.0f) ─────
    float * const __restrict OUT = s_out.arr_f32.ptrw();
    const double gain = static_cast<double>(elevation_gain);
    const double k    = static_cast<double>(normalize_k);
    if (filter_active) {
        for (int i = 0; i < n; ++i) {
            if (ARCH[i] != target_archetype) {
                OUT[i] = 0.0f;
                continue;
            }
            const double norm = (last[i] - out_min) * inv_denom;
            const double amp  = 1.0 + gain * static_cast<double>(E[i]);
            double v = norm * amp * k;
            if (v < 0.0) v = 0.0;
            else if (v > 1.0) v = 1.0;
            OUT[i] = static_cast<float>(v);
        }
    } else {
        for (int i = 0; i < n; ++i) {
            const double norm = (last[i] - out_min) * inv_denom;
            const double amp  = 1.0 + gain * static_cast<double>(E[i]);
            double v = norm * amp * k;
            if (v < 0.0) v = 0.0;
            else if (v > 1.0) v = 1.0;
            OUT[i] = static_cast<float>(v);
        }
    }
}

double DCWorldExt::run_climate_pass_a(const Dictionary &cp_struct, double phase, double season_phase) {
    (void)phase; // current contract: phase == season_phase (same fast tick)

    // [Step 3b-1 DIAG] one-shot fallback-reason probe — prints exactly once
    // per process the FIRST time C++ rejects a call. Remove after the
    // mismatch is fixed and A= drops to <1ms.
    static bool _diag_printed = false;
    auto diag = [&](const char *reason) {
        if (!_diag_printed) {
            _diag_printed = true;
            UtilityFunctions::print(String("[DCWorldExt][diag] run_climate_pass_a fallback: ") + String(reason));
        }
    };

    // ─── 1. Hard preconditions ──────────────────────────────────────────
    if (!_bound) {
        diag("not _bound");
        return -1.0; // bind_map_data not yet called → GDScript legacy
    }

    // ─── 2. Resolve all 13 slot ids by StringName (BIND_TABLE keys) ─────
    // We resolve once per call (not per cell). If ANY of these is missing
    // we fall back: it means GDScript hasn't registered the climate SoA
    // yet, or the BIND_TABLE diverged.
    const int sid_temp           = component_id(StringName("cell_temp"));
    const int sid_moisture       = component_id(StringName("cell_moisture"));
    const int sid_snow           = component_id(StringName("cell_snow_cover"));
    const int sid_temp_baseline  = component_id(StringName("cell_temp_baseline"));
    const int sid_temp_30d       = component_id(StringName("cell_temp_30d"));
    const int sid_temp_365d      = component_id(StringName("cell_temp_365d"));
    const int sid_temp_anom      = component_id(StringName("cell_temp_anomaly"));
    const int sid_temp_seas_off  = component_id(StringName("cell_temp_season_offset"));
    const int sid_elev           = component_id(StringName("cell_elevation"));
    const int sid_base_moist     = component_id(StringName("cell_base_moisture"));
    const int sid_lat_norm       = component_id(StringName("cell_lat_norm"));
    const int sid_temp_year      = component_id(StringName("cell_temp_baseline_year"));
    const int sid_is_water       = component_id(StringName("cell_is_water"));
    const int sid_terrain        = component_id(StringName("cell_terrain"));
    const int sid_cover          = component_id(StringName("cell_cover"));
    const int sid_ema_init       = component_id(StringName("cell_ema_initialized"));

    if (sid_temp           < 0 || sid_moisture      < 0 || sid_snow      < 0 ||
        sid_temp_baseline  < 0 || sid_temp_30d      < 0 || sid_temp_365d < 0 ||
        sid_temp_anom      < 0 || sid_temp_seas_off < 0 ||
        sid_elev           < 0 || sid_base_moist    < 0 ||
        sid_lat_norm       < 0 || sid_temp_year     < 0 ||
        sid_is_water       < 0 || sid_terrain       < 0 || sid_cover     < 0 ||
        sid_ema_init       < 0) {
        diag("slot id <0 (some BIND_TABLE component missing)");
        return -1.0;
    }

    // ─── 3. Pull cp_struct scalars (with conservative defaults) ─────────
    if (!cp_struct.has("insol_dev_lut") || !cp_struct.has("moist_scale_now")) {
        diag("cp_struct missing insol_dev_lut/moist_scale_now");
        return -1.0; // packing contract violated — fallback
    }
    const bool   use_insol      = cp_struct.has("use_insol")
                                    ? bool(cp_struct["use_insol"]) : false;
    const float  insol_amp      = cp_struct.has("insol_amp")
                                    ? float(cp_struct["insol_amp"]) : 0.20f;
    const float  insol_gain     = cp_struct.has("insol_gain")
                                    ? float(cp_struct["insol_gain"]) : 1.0f;
    const float  insol_amp_gain = insol_amp * insol_gain;
    const float  moist_scale    = float(cp_struct["moist_scale_now"]);
    const float  sea_level      = cp_struct.has("sea_level")
                                    ? float(cp_struct["sea_level"]) : 0.0f;
    const float  inv_above_sea  = (1.0f - sea_level) > 1e-6f
                                    ? (1.0f / (1.0f - sea_level)) : 0.0f;

    PackedFloat32Array lut_pack = cp_struct["insol_dev_lut"];
    const int          lut_size_p1 = lut_pack.size();
    // Truth source: map_generator.gd `const _INSOL_DAILY_LUT_SIZE: int = 64`.
    // LUT has size+1 entries (indices [0..size]) so bilinear lookup at the
    // boundary doesn't OOB. If GDScript ever changes 64, update here too.
    constexpr int      INSOL_DAILY_LUT_SIZE = 64;
    if (lut_size_p1 != INSOL_DAILY_LUT_SIZE + 1) {
        diag("insol_dev_lut wrong size");
        return -1.0; // wrong-sized LUT — fallback
    }
    const float * const lut = lut_pack.ptr();
    const float  lut_size_f = float(INSOL_DAILY_LUT_SIZE);

    // ─── 4. Fix-up: this Step omits use_insol=false fallback path on C++ ──
    // architecture.md §F — when use_insol=false we let GDScript handle it
    // (calls `_season_temp_offset_phase`). Step 3b-1 keeps the C++ branch
    // narrow on the high-traffic case (use_insol=true).
    if (!use_insol) {
        diag("use_insol=false (cp.true_insolation_enabled is false)");
        return -1.0;
    }

    // ─── 5. Acquire array views & validate sizes ────────────────────────
    // arr_*.ptrw() on the *internal* slot data is the legitimate write
    // path — bind_map_data shared CoW with GDScript so writes propagate.
    PackedFloat32Array &temp_a          = _slots.write[sid_temp].arr_f32;
    PackedFloat32Array &moist_a         = _slots.write[sid_moisture].arr_f32;
    PackedFloat32Array &snow_a          = _slots.write[sid_snow].arr_f32;
    PackedFloat32Array &temp_baseline_a = _slots.write[sid_temp_baseline].arr_f32;
    PackedFloat32Array &temp_30d_a      = _slots.write[sid_temp_30d].arr_f32;
    PackedFloat32Array &temp_365d_a     = _slots.write[sid_temp_365d].arr_f32;
    PackedFloat32Array &temp_anom_a     = _slots.write[sid_temp_anom].arr_f32;
    PackedFloat32Array &season_off_a    = _slots.write[sid_temp_seas_off].arr_f32;
    PackedFloat32Array &elev_a          = _slots.write[sid_elev].arr_f32;
    PackedFloat32Array &base_moist_a    = _slots.write[sid_base_moist].arr_f32;
    PackedFloat32Array &lat_a           = _slots.write[sid_lat_norm].arr_f32;
    PackedFloat32Array &temp_year_a     = _slots.write[sid_temp_year].arr_f32;
    PackedByteArray    &is_water_a      = _slots.write[sid_is_water].arr_u8;
    PackedByteArray    &terrain_a       = _slots.write[sid_terrain].arr_u8;
    PackedByteArray    &cover_a         = _slots.write[sid_cover].arr_u8;
    PackedByteArray    &ema_init_a      = _slots.write[sid_ema_init].arr_u8;

    const int n = temp_a.size();
    if (n <= 0) { diag("temp_a empty (n<=0)"); return -1.0; }

    // All cell-level arrays MUST be the same length. Anything mismatched
    // means the bind has gone stale (e.g. world resize without re-bind).
    if (moist_a.size()         != n || snow_a.size()      != n ||
        temp_baseline_a.size() != n || temp_30d_a.size()  != n ||
        temp_365d_a.size()     != n || temp_anom_a.size() != n ||
        season_off_a.size()    != n || elev_a.size()      != n ||
        base_moist_a.size()    != n || lat_a.size()       != n ||
        temp_year_a.size()     != n || is_water_a.size()  != n ||
        terrain_a.size()       != n || cover_a.size()     != n ||
        ema_init_a.size()      != n) {
        diag("slot array size mismatch (re-bind needed?)");
        return -1.0;
    }

    // ─── 6. Hot pointers (cached outside the loop) ──────────────────────
    float * const __restrict pt   = temp_a.ptrw();
    float * const __restrict pm   = moist_a.ptrw();
    float * const __restrict ps   = snow_a.ptrw();
    float * const __restrict ptb  = temp_baseline_a.ptrw();
    float * const __restrict p30  = temp_30d_a.ptrw();
    float * const __restrict p365 = temp_365d_a.ptrw();
    float * const __restrict pa   = temp_anom_a.ptrw();
    float * const __restrict pso  = season_off_a.ptrw();
    const float * const      pe   = elev_a.ptr();
    const float * const      pbm  = base_moist_a.ptr();
    const float * const      pln  = lat_a.ptr();
    const float * const      pty  = temp_year_a.ptr();
    const uint8_t * const    piw  = is_water_a.ptr();
    const uint8_t * const    pterr= terrain_a.ptr();
    const uint8_t * const    pcov = cover_a.ptr();
    uint8_t * const __restrict pei = ema_init_a.ptrw();

    // GDScript constants (architecture.md §G.6 / TERRAIN/CV enums)
    constexpr uint8_t TERRAIN_SNOW = 9;  // TerrainType.TERRAIN.SNOW
    constexpr uint8_t COVER_GLACIER = 2; // CoverType.CV.GLACIER

    // ─── 7. Main loop — 1:1 mirror of _climate_pass_a SoA branch ───────
    for (int i = 0; i < n; ++i) {
        const float ny             = pln[i];
        const float temp_year_lat  = pty[i];
        const float elevation      = pe[i];
        const bool  is_water       = piw[i] != 0;

        // (a) dev_today — bilinear LUT lookup
        float x = ny;
        if (x < 0.0f)      x = 0.0f;
        else if (x > 1.0f) x = 1.0f;
        x *= lut_size_f;
        int   i0 = int(x);
        int   i1 = i0 + 1;
        if (i1 > INSOL_DAILY_LUT_SIZE) i1 = INSOL_DAILY_LUT_SIZE;
        const float t_lut    = x - float(i0);
        const float dev_today = lut[i0] + (lut[i1] - lut[i0]) * t_lut;

        // (b) moisture
        float moisture_now;
        if (is_water) {
            moisture_now = pbm[i];
        } else {
            const float scale_eff = moist_scale * (1.0f + 0.2f * dev_today);
            float bm = pbm[i] * scale_eff;
            if (bm > 1.0f) bm = 1.0f;
            else if (bm < 0.0f) bm = 0.0f;
            moisture_now = bm;
        }

        // (c) temperature
        float temp_year = temp_year_lat - elevation * 0.5f;
        if (temp_year < 0.0f) temp_year = 0.0f;
        else if (temp_year > 1.0f) temp_year = 1.0f;
        const float season_offset = insol_amp_gain * dev_today;
        float temp_now = temp_year + season_offset;
        if (temp_now < 0.0f) temp_now = 0.0f;
        else if (temp_now > 1.0f) temp_now = 1.0f;

        // (d) snow cover
        float snow_cover = 0.0f;
        if (!is_water) {
            const uint8_t terr = pterr[i];
            if (terr == TERRAIN_SNOW) {
                snow_cover = 1.0f;
            } else {
                const float land_h = (elevation - sea_level) * inv_above_sea;
                if (temp_now < 0.18f) {
                    float sc1 = (0.18f - temp_now) / 0.14f;
                    if (sc1 > 1.0f) sc1 = 1.0f;
                    else if (sc1 < 0.0f) sc1 = 0.0f;
                    snow_cover = sc1 * 0.85f;
                } else if (land_h > 0.45f && temp_now < 0.30f) {
                    float t1 = (0.30f - temp_now) / 0.20f;
                    if (t1 > 1.0f) t1 = 1.0f;
                    else if (t1 < 0.0f) t1 = 0.0f;
                    // smoothstep(0.45, 0.85, land_h)
                    float u = (land_h - 0.45f) / (0.85f - 0.45f);
                    if (u < 0.0f) u = 0.0f;
                    else if (u > 1.0f) u = 1.0f;
                    const float t2 = u * u * (3.0f - 2.0f * u);
                    snow_cover = t1 * t2;
                }
                if (pcov[i] == COVER_GLACIER && snow_cover < 0.80f) {
                    snow_cover = 0.80f;
                }
            }
        }

        // (e) write SoA outputs
        pt[i]   = temp_now;
        pm[i]   = moisture_now;
        ps[i]   = snow_cover;
        ptb[i]  = temp_year;
        pso[i]  = season_offset;

        // (f) EMA
        float m30, m365;
        if (pei[i] == 0) {
            m30  = temp_now;
            m365 = temp_now;
            pei[i] = 1;
        } else {
            // lerp(a, b, t) = a + (b - a) * t
            m30  = p30[i]  + (temp_now - p30[i])  * (1.0f / 30.0f);
            m365 = p365[i] + (temp_now - p365[i]) * (1.0f / 365.0f);
        }
        p30[i]  = m30;
        p365[i] = m365;
        pa[i]   = m30 - m365;
    }

    // Step 3b-1.5 will fold dirty mask + drift in here. Step 3b-1 leaves
    // climate_dirty_mask / _dt/_dm/_ds_global_yesterday untouched — Pass-B
    // will temporarily walk the full grid (degraded but correct).

    // §11.2 flush: push CoW-detached output slots back to GDScript MapData
    _flush_slot_to_map(sid_temp);
    _flush_slot_to_map(sid_moisture);
    _flush_slot_to_map(sid_snow);
    _flush_slot_to_map(sid_temp_baseline);
    _flush_slot_to_map(sid_temp_seas_off);
    _flush_slot_to_map(sid_ema_init);
    _flush_slot_to_map(sid_temp_30d);
    _flush_slot_to_map(sid_temp_365d);
    _flush_slot_to_map(sid_temp_anom);

    return 0.0;
}

// ─── Phase 3a Step 0: alias spike (TEMPORARY) ─────────────────────────────
// What we are testing: does godot-cpp's PackedFloat32Array share its
// underlying CowData with the GDScript-side property after we `set()` it
// back? If yes, ptrw() does not detach and the GDScript side sees C++ writes.
// If no, we need a different strategy for bind_map_data (likely write-then-
// set per hot-loop invocation, or reverse-anchor the buffer ownership).
//
// Reads `obj.<prop>` after the in-C++ mutation and returns it so the GDScript
// caller can verify directly (we don't trust C++-side reads to prove anything
// about cross-boundary visibility).

float DCWorldExt::_spike_alias_v1_naive(Object *obj, const StringName &prop, int idx, float sentinel) {
    if (obj == nullptr) {
        UtilityFunctions::push_error("[spike v1] null obj");
        return -9999.0f;
    }
    Variant v = obj->get(prop);
    if (v.get_type() != Variant::PACKED_FLOAT32_ARRAY) {
        UtilityFunctions::push_error("[spike v1] prop is not PackedFloat32Array");
        return -9999.0f;
    }
    PackedFloat32Array arr = v;        // refcount: GDScript side + this local
    obj->set(prop, arr);                // explicit reseat (idempotent in theory)
    if (idx < 0 || idx >= arr.size()) {
        UtilityFunctions::push_error("[spike v1] idx out of range");
        return -9999.0f;
    }
    float *w = arr.ptrw();              // <-- may detach (CoW) here
    w[idx] = sentinel;
    // Read what GDScript side actually has now.
    Variant v_after = obj->get(prop);
    PackedFloat32Array arr_after = v_after;
    return arr_after[idx];
}

float DCWorldExt::_spike_alias_v2_release(Object *obj, const StringName &prop, int idx, float sentinel) {
    if (obj == nullptr) {
        UtilityFunctions::push_error("[spike v2] null obj");
        return -9999.0f;
    }
    {
        Variant v = obj->get(prop);
        PackedFloat32Array arr = v;
        obj->set(prop, arr);
        // arr / v go out of scope here, dropping the C++ ref.
    }
    // Re-acquire after we (hopefully) have GDScript as sole owner.
    Variant v2 = obj->get(prop);
    PackedFloat32Array arr2 = v2;
    if (idx < 0 || idx >= arr2.size()) {
        UtilityFunctions::push_error("[spike v2] idx out of range");
        return -9999.0f;
    }
    // Now refcount on Godot side: GDScript-prop + arr2 + Variant v2 = at least 2.
    // Still >1 because we are holding it. ptrw will likely still detach.
    float *w = arr2.ptrw();
    w[idx] = sentinel;
    Variant v_after = obj->get(prop);
    PackedFloat32Array arr_after = v_after;
    return arr_after[idx];
}

float DCWorldExt::_spike_alias_v3_write_then_set(Object *obj, const StringName &prop, int idx, float sentinel) {
    if (obj == nullptr) {
        UtilityFunctions::push_error("[spike v3] null obj");
        return -9999.0f;
    }
    Variant v = obj->get(prop);
    PackedFloat32Array arr = v;
    if (idx < 0 || idx >= arr.size()) {
        UtilityFunctions::push_error("[spike v3] idx out of range");
        return -9999.0f;
    }
    // Mutate first (will detach into a new buffer owned by `arr`),
    // then push the new buffer back to GDScript via set.
    float *w = arr.ptrw();
    w[idx] = sentinel;
    obj->set(prop, arr);
    Variant v_after = obj->get(prop);
    PackedFloat32Array arr_after = v_after;
    return arr_after[idx];
}

// ─── Phase 3a Step 1: alias verification helper (TEMPORARY) ───────────────
// Pure C++-side write into _slots[comp_id].arr_f32[idx], no obj.set.
// If bind_map_data's push-back contract works, the GDScript side sees this
// write immediately on the next read of the bound property.
float DCWorldExt::_debug_poke_f32(int comp_id, int idx, float sentinel) {
    if (comp_id < 0 || comp_id >= _slots.size()) {
        UtilityFunctions::push_error("[_debug_poke_f32] comp_id out of range: ", comp_id);
        return -9999.0f;
    }
    Slot &s = _slots.write[comp_id];
    if (s.dtype != SlotDType::F32) {
        UtilityFunctions::push_error("[_debug_poke_f32] slot is not F32: ", comp_id);
        return -9999.0f;
    }
    if (idx < 0 || idx >= s.arr_f32.size()) {
        UtilityFunctions::push_error("[_debug_poke_f32] idx out of range: ", idx, " / ", s.arr_f32.size());
        return -9999.0f;
    }
    // Same access pattern as a real hot loop: ptrw() on the C++-held buffer.
    // No obj.set() afterwards — the entire point is to prove the alias.
    float *w = s.arr_f32.ptrw();
    w[idx] = sentinel;
    return sentinel;
}

// ─── Phase 3a Step 1 (T1b): write-then-set per call ────────────────────────
// Same write as _debug_poke_f32, but immediately push s.arr_f32 back to the
// GDScript-side property via map_data->set(prop_name, s.arr_f32). If this
// PASSes the GDScript-visibility check while plain _debug_poke_f32 FAILs,
// then ptrw() on the C++-held buffer triggered a CoW detach (refcount 2 →
// private copy) and the only viable alias contract is "C++ end-of-pass set
// flush". Looks up prop_name from the file-local BIND_TABLE.
float DCWorldExt::_debug_poke_f32_with_flush(int comp_id, int idx, float sentinel) {
    if (_map_data == nullptr) {
        UtilityFunctions::push_error("[_debug_poke_f32_with_flush] not bound (call bind_map_data first)");
        return -9999.0f;
    }
    if (comp_id < 0 || comp_id >= _slots.size()) {
        UtilityFunctions::push_error("[_debug_poke_f32_with_flush] comp_id out of range: ", comp_id);
        return -9999.0f;
    }
    Slot &s = _slots.write[comp_id];
    if (s.dtype != SlotDType::F32) {
        UtilityFunctions::push_error("[_debug_poke_f32_with_flush] slot is not F32: ", comp_id);
        return -9999.0f;
    }
    if (idx < 0 || idx >= s.arr_f32.size()) {
        UtilityFunctions::push_error("[_debug_poke_f32_with_flush] idx out of range: ", idx, " / ", s.arr_f32.size());
        return -9999.0f;
    }
    // Reverse-lookup prop_name via slot.name in BIND_TABLE.
    const char *prop_cstr = nullptr;
    for (int i = 0; i < BIND_TABLE_SIZE; ++i) {
        if (s.name == StringName(BIND_TABLE[i].slot_name)) {
            prop_cstr = BIND_TABLE[i].property_name;
            break;
        }
    }
    if (prop_cstr == nullptr) {
        UtilityFunctions::push_error("[_debug_poke_f32_with_flush] slot ", s.name, " not in BIND_TABLE");
        return -9999.0f;
    }
    // Write via ptrw() (may CoW-detach into a private buffer)…
    float *w = s.arr_f32.ptrw();
    w[idx] = sentinel;
    // …then push the (possibly-new) buffer back so GDScript side sees it.
    _map_data->set(StringName(prop_cstr), s.arr_f32);
    return sentinel;
}

// ─── CoW flush / refresh (performance-charter §11.2) ────────────────────────
//
// Every C++ hot pass writes SoA slots via ptrw(). The first ptrw() after
// bind_map_data (or after a prior flush) triggers a CoW detach — C++ gets
// a private buffer, GDScript's map.*_arr still references the old one.
//
// _flush_slot_to_map: reverse-lookup the property name via BIND_TABLE and
//   push the C++ buffer back to GDScript via obj->set(). This is an O(1)
//   Variant reference swap, not a memcpy.
//
// flush_slots_to_map / refresh_slots_from_map: bulk versions that iterate
//   all bound slots.

void DCWorldExt::_flush_slot_to_map(int comp_id) {
    if (!_map_data || comp_id < 0 || comp_id >= _slots.size()) return;
    const Slot &s = _slots[comp_id];
    for (int i = 0; i < BIND_TABLE_SIZE; ++i) {
        if (s.name == StringName(BIND_TABLE[i].slot_name)) {
            switch (s.dtype) {
                case SlotDType::F32:
                    _map_data->set(StringName(BIND_TABLE[i].property_name), s.arr_f32);
                    break;
                case SlotDType::I32:
                    _map_data->set(StringName(BIND_TABLE[i].property_name), s.arr_i32);
                    break;
                case SlotDType::U8:
                    _map_data->set(StringName(BIND_TABLE[i].property_name), s.arr_u8);
                    break;
            }
            return;
        }
    }
}

void DCWorldExt::flush_slots_to_map() {
    if (!_map_data) return;
    for (int i = 0; i < BIND_TABLE_SIZE; ++i) {
        const StringName slot_name(BIND_TABLE[i].slot_name);
        const int sid = component_id(slot_name);
        if (sid < 0 || sid >= _slots.size()) continue;
        const Slot &s = _slots[sid];
        const StringName prop_name(BIND_TABLE[i].property_name);
        switch (s.dtype) {
            case SlotDType::F32: _map_data->set(prop_name, s.arr_f32); break;
            case SlotDType::I32: _map_data->set(prop_name, s.arr_i32); break;
            case SlotDType::U8:  _map_data->set(prop_name, s.arr_u8);  break;
        }
    }
}

void DCWorldExt::refresh_slots_from_map() {
    if (!_map_data) return;
    for (int i = 0; i < BIND_TABLE_SIZE; ++i) {
        const StringName slot_name(BIND_TABLE[i].slot_name);
        const int sid = component_id(slot_name);
        if (sid < 0 || sid >= _slots.size()) continue;
        Slot &s = _slots.write[sid];
        const StringName prop_name(BIND_TABLE[i].property_name);
        Variant v = _map_data->get(prop_name);
        switch (s.dtype) {
            case SlotDType::F32: s.arr_f32 = v; break;
            case SlotDType::I32: s.arr_i32 = v; break;
            case SlotDType::U8:  s.arr_u8  = v; break;
        }
    }
}

// ─── Phase-3 micro-bench API ────────────────────────────────────────────────
//
// All bench paths share the same per-cell math:
//   nb_sum = prev[nb[6*i+0]] + prev[nb[6*i+1]] + ... + prev[nb[6*i+5]]
//   new[i] = base + lat[i]*k1 + nb_sum*k2 + season
// and write into _slots[comp_id].arr_f32 via raw ptrw().
//
// Three implementations exist for fairness — same workload, different code:
//   - *_scalar : straight C++ for-loop, lets compiler decide on vectorisation.
//   - *_simd   : explicit AVX2 8-wide gather for the 6 neighbours.
//                Falls back to scalar when PK_HAVE_AVX2=0.
//   - *_thread : *_simd kernel split across n_tasks WorkerThreadPool workers.
//
// "_full" variants iterate every cell in the slot.
// "_indexed" variants iterate only `dirty` indices (sparse Pass-B style).
// All variants assume neighbours.size() == 6 * cell_count.
// ────────────────────────────────────────────────────────────────────────────

namespace {

// ── shared scalar kernel ─────────────────────────────────────────────────
inline void pass_a_kernel_scalar(float *out_ptr,
                                 const float   *lat_ptr,
                                 const float   *prev_ptr,
                                 const int32_t *nb_ptr,
                                 int            i,
                                 float k1, float k2, float base, float season) {
    const int32_t *nb6 = nb_ptr + i * 6;
    const float nb_sum = prev_ptr[nb6[0]] + prev_ptr[nb6[1]] + prev_ptr[nb6[2]]
                       + prev_ptr[nb6[3]] + prev_ptr[nb6[4]] + prev_ptr[nb6[5]];
    out_ptr[i] = base + lat_ptr[i] * k1 + nb_sum * k2 + season;
}

#if defined(PK_HAVE_AVX2) && PK_HAVE_AVX2
// ── AVX2 SIMD kernel (8 cells / iter) ────────────────────────────────────
// Strategy: 6 separate 8-wide gathers from prev[] using nb[6*i+k] indices,
// hsum into nb_sum, then fma chain for the result.
// Note: gather throughput on Skylake = 1 per cell on average; this is ~
// 4x faster than scalar despite gather not being free, because the loop
// body otherwise spends most of its time on memory dependency chains.
inline void pass_a_simd_block_full(float *out_ptr,
                                   const float   *lat_ptr,
                                   const float   *prev_ptr,
                                   const int32_t *nb_ptr,
                                   int   i_begin,    // must be in [0, count - 8]
                                   float k1, float k2, float base, float season) {
    // Load lat[i..i+7]
    __m256 lat = _mm256_loadu_ps(lat_ptr + i_begin);

    // For each of 6 neighbour slots, gather prev[nb[6*(i+k) + slot]] for k=0..7.
    // nb is laid out as flat [6*count] int32 — for a contiguous stride-1
    // group of 8 cells, the indices for slot s are at offsets
    //   nb_ptr[6*i + s], nb_ptr[6*(i+1) + s], ..., nb_ptr[6*(i+7) + s]
    // i.e. stride 6 in nb_ptr. Build that index vector once, then gather prev.
    __m256i stride6 = _mm256_setr_epi32(0, 6, 12, 18, 24, 30, 36, 42);
    __m256 nb_sum = _mm256_setzero_ps();
    const int32_t *nb_base = nb_ptr + 6 * i_begin;
    for (int s = 0; s < 6; ++s) {
        // Load 8 indices: nb_base[s + 6k] for k=0..7
        __m256i idx = _mm256_add_epi32(stride6, _mm256_set1_epi32(s));
        idx = _mm256_i32gather_epi32(nb_base, idx, 4);
        __m256 vals = _mm256_i32gather_ps(prev_ptr, idx, 4);
        nb_sum = _mm256_add_ps(nb_sum, vals);
    }

    __m256 vk1     = _mm256_set1_ps(k1);
    __m256 vk2     = _mm256_set1_ps(k2);
    __m256 vbase_s = _mm256_set1_ps(base + season);

    // result = (base+season) + lat*k1 + nb_sum*k2
    __m256 result = _mm256_fmadd_ps(lat,    vk1, vbase_s);
    result        = _mm256_fmadd_ps(nb_sum, vk2, result);

    _mm256_storeu_ps(out_ptr + i_begin, result);
}
#endif

// ── thread task payload ──────────────────────────────────────────────────
struct PassAFullTask {
    float         *out_ptr;
    const float   *lat_ptr;
    const float   *prev_ptr;
    const int32_t *nb_ptr;
    int            count;
    float          k1, k2, base, season;
    int            n_tasks;
};

// Each worker handles `chunk = ceil(count / n_tasks)` cells starting at
// `task_idx * chunk`. Tail handling is done with scalar.
static void pass_a_full_worker(void *userdata, uint32_t task_idx) {
    auto *t = static_cast<PassAFullTask *>(userdata);
    const int chunk = (t->count + t->n_tasks - 1) / t->n_tasks;
    const int begin = static_cast<int>(task_idx) * chunk;
    const int end   = std::min(begin + chunk, t->count);

    int i = begin;
#if defined(PK_HAVE_AVX2) && PK_HAVE_AVX2
    // SIMD body — leaves the last <8 cells to scalar tail.
    const int simd_end = end - ((end - begin) % 8);
    for (; i + 8 <= simd_end; i += 8) {
        pass_a_simd_block_full(t->out_ptr, t->lat_ptr, t->prev_ptr, t->nb_ptr,
                               i, t->k1, t->k2, t->base, t->season);
    }
#endif
    for (; i < end; ++i) {
        pass_a_kernel_scalar(t->out_ptr, t->lat_ptr, t->prev_ptr, t->nb_ptr,
                             i, t->k1, t->k2, t->base, t->season);
    }
}

struct PassAIndexedTask {
    float         *out_ptr;
    const int32_t *dirty_ptr;
    const float   *lat_ptr;
    const float   *prev_ptr;
    const int32_t *nb_ptr;
    int            cap;          // bounds for dirty[k]
    int            n_dirty;
    float          k1, k2, base, season;
    int            n_tasks;
};

static void pass_a_indexed_worker(void *userdata, uint32_t task_idx) {
    auto *t = static_cast<PassAIndexedTask *>(userdata);
    const int chunk = (t->n_dirty + t->n_tasks - 1) / t->n_tasks;
    const int begin = static_cast<int>(task_idx) * chunk;
    const int end   = std::min(begin + chunk, t->n_dirty);
    // Indexed paths can't use a contiguous SIMD block (gather indices are not
    // stride-1 across dirty[]). Stick with scalar; the win comes from
    // multi-threaded throughput.
    for (int k = begin; k < end; ++k) {
        const int i = t->dirty_ptr[k];
        if (i < 0 || i >= t->cap) continue;
        pass_a_kernel_scalar(t->out_ptr, t->lat_ptr, t->prev_ptr, t->nb_ptr,
                             i, t->k1, t->k2, t->base, t->season);
    }
}

} // namespace

// ════════════════════════════════════════════════════════════════════════════
// Phase F / dots-full-migration §F.1-F.6 hot pass C++ implementations
// ════════════════════════════════════════════════════════════════════════════
//
// F.1 已落地 (this PR)。F.2-F.6 仍为 stub（返回 -1.0 → GDScript fallback）。
// 后续 PR 按 charter §12.4 七步 SOP 逐个填充实际算法。

// ─── F.1 helpers ─────────────────────────────────────────────────────────────
namespace {

// Mirror weather_system.gd::_is_water_terrain — bit-equal terrain enum check.
// Source: weather_system.gd:2125-2131 (TerrainType.TERRAIN values are stable
// 0-based ordinals from terrain_type.gd; see component_schema.gd terrain SoA).
inline bool wf_is_water_terrain(uint8_t t) {
    // OCEAN=0, COAST=1, REEF=19, KELP=21, SEA_ICE=20, LAKE=18 (from
    // scripts/geography/terrain_type.gd::TERRAIN enum order).
    return t == 0  || t == 1  || t == 18 || t == 19 || t == 20 || t == 21;
}

// Mirror weather_system.gd::_vegetation_transpiration_factor — bit-equal.
// Source: weather_system.gd:1384-1394. Veg ordinals from vegetation_type.gd
// VEG enum (line 33+).
inline float wf_vegetation_transp_factor(uint8_t veg) {
    // NONE=0
    if (veg == 0) return 0.0f;
    // TROPICAL_RAINFOREST=14, SWAMP=20, MANGROVE=19
    if (veg == 14 || veg == 19 || veg == 20) return 1.0f;
    // TEMPERATE_DECIDUOUS=7, TAIGA=5, SUBTROPICAL_FOREST=12
    if (veg == 5 || veg == 7 || veg == 12) return 0.65f;
    // TEMPERATE_GRASSLAND=9, SAVANNA=13, MARSH=21
    if (veg == 9 || veg == 13 || veg == 21) return 0.35f;
    return 0.18f;
}

// Mirror weather_system.gd::_neighbor_aligned_idx (line 1261).
// Returns -1 if no neighbour clears the cone threshold.
//   - cone_thresh = hex_size * 0.31176915 (sqrt(3)*0.18 in GDScript)
//   - Note: GDScript reads `dir.length_squared() <= 0.0001` then normalises;
//     here we trust caller has non-degenerate `dir` (handled at call site).
inline int wf_neighbor_aligned_idx(int idx, float dir_x, float dir_y,
                                   const godot::Vector2 *POS,
                                   const int32_t *NB,
                                   int n_cells, float hex_size) {
    if (idx < 0 || idx >= n_cells) return -1;
    const float dl2 = dir_x * dir_x + dir_y * dir_y;
    if (dl2 <= 0.0001f) return -1;
    const float inv_dl = 1.0f / Math::sqrt(dl2);
    const float ndx = dir_x * inv_dl;
    const float ndy = dir_y * inv_dl;
    const float self_x = POS[idx].x;
    const float self_y = POS[idx].y;
    int   best_idx = -1;
    float best_dot = hex_size * 0.31176915f;
    const int base = idx * 6;
    for (int d = 0; d < 6; ++d) {
        const int32_t nb_idx = NB[base + d];
        if (nb_idx < 0) continue;
        const float to_nb_x = POS[nb_idx].x - self_x;
        const float to_nb_y = POS[nb_idx].y - self_y;
        const float dot = to_nb_x * ndx + to_nb_y * ndy;
        if (dot > best_dot) {
            best_dot = dot;
            best_idx = nb_idx;
        }
    }
    return best_idx;
}

// Mirror weather_system.gd::_upstream_vapor_idx_from_first (line 1297).
// Walks the upstream chain (`field_advect_steps` total) and returns the
// decay-weighted average vapor.
inline float wf_upstream_vapor_idx_from_first(int idx, int first_upstream_idx,
                                              const godot::Vector2 *POS,
                                              const int32_t *NB,
                                              const float *PV,
                                              float wind_dx, float wind_dy,
                                              int n_cells, float hex_size,
                                              int field_advect_steps) {
    if (first_upstream_idx < 0 || field_advect_steps <= 0) {
        return PV[idx];
    }
    int   current_idx = first_upstream_idx;
    float sum_v   = PV[current_idx];
    float weight  = 1.0f;
    float w_decay = 0.75f;
    for (int step = 1; step < field_advect_steps; ++step) {
        const int upstream_idx = wf_neighbor_aligned_idx(
            current_idx, -wind_dx, -wind_dy, POS, NB, n_cells, hex_size);
        if (upstream_idx < 0) break;
        sum_v   += PV[upstream_idx] * w_decay;
        weight  += w_decay;
        w_decay *= 0.75f;
        current_idx = upstream_idx;
    }
    return sum_v / weight;
}

// Mirror weather_system.gd::_neighbor_average_vapor_idx (line 1314).
inline float wf_neighbor_average_vapor_idx(int idx, const int32_t *NB,
                                           const float *PV) {
    float sum_v = PV[idx];
    int   n     = 1;
    const int base = idx * 6;
    for (int d = 0; d < 6; ++d) {
        const int32_t nb_idx = NB[base + d];
        if (nb_idx < 0) continue;
        sum_v += PV[nb_idx];
        n += 1;
    }
    return sum_v / float(n);
}

// Mirror weather_system.gd::_avg_ocean_anomaly_at_idx (line 1326).
// `TA` is per-cell `cell.temperature_transport_anomaly` extracted by GDScript.
inline float wf_avg_ocean_anomaly_at_idx(int idx, const uint8_t *TERR,
                                         const int32_t *NB, const float *TA) {
    if (wf_is_water_terrain(TERR[idx])) return TA[idx];
    float sum_an  = 0.0f;
    int   n_water = 0;
    const int base = idx * 6;
    for (int d = 0; d < 6; ++d) {
        const int32_t nb_idx = NB[base + d];
        if (nb_idx < 0) continue;
        if (wf_is_water_terrain(TERR[nb_idx])) {
            sum_an += TA[nb_idx];
            n_water += 1;
        }
    }
    if (n_water == 0) return 0.0f;
    return sum_an / float(n_water);
}

// Mirror weather_system.gd::_evaporation_for_cell_idx (line 1345).
inline float wf_evaporation_for_cell_idx(int idx, const uint8_t *TERR,
                                         const uint8_t *VEG,
                                         const uint8_t *HAS_RIV,
                                         const int32_t *NB,
                                         float temp, float moisture,
                                         float ocean_an, bool on_water,
                                         float field_ocean_evap_gain) {
    float evap = on_water ? 0.028f : 0.006f;
    const float excess_moist = moisture - 0.45f;
    if (excess_moist > 0.0f) evap += excess_moist * 0.018f;
    evap += wf_vegetation_transp_factor(VEG[idx]) * 0.012f;
    if (!on_water) {
        if (HAS_RIV[idx] != 0) evap += 0.012f;
        const int base = idx * 6;
        for (int d = 0; d < 6; ++d) {
            const int32_t nb_idx = NB[base + d];
            if (nb_idx < 0) continue;
            if (wf_is_water_terrain(TERR[nb_idx])) {
                evap += 0.018f;
                break;
            }
        }
    }
    float ocean_mul = 1.0f + field_ocean_evap_gain * ocean_an;
    if (ocean_mul < 0.20f) ocean_mul = 0.20f;
    else if (ocean_mul > 1.80f) ocean_mul = 1.80f;
    float temp_mul = 0.35f + temp * 1.05f;
    if (temp_mul < 0.12f) temp_mul = 0.12f;
    else if (temp_mul > 1.35f) temp_mul = 1.35f;
    return evap * ocean_mul * temp_mul;
}

// Mirror weather_system.gd::_orographic_lift_from_upstream_idx (line 1420).
inline float wf_orographic_lift_from_upstream_idx(int idx, int upstream_idx,
                                                  const float *ELEV) {
    if (upstream_idx < 0) return 0.0f;
    const float diff = ELEV[idx] - ELEV[upstream_idx];
    if (diff > 0.02f) {
        float v = diff * 2.2f;
        if (v > 1.0f) v = 1.0f;
        return v;
    }
    if (diff < -0.02f) {
        float v = diff * 1.6f;
        if (v < -1.0f) v = -1.0f;
        return v;
    }
    return 0.0f;
}

// Mirror weather_system.gd::_wind_convergence_idx (line 1452).
inline float wf_wind_convergence_idx(int idx, const godot::Vector2 *POS,
                                     const int32_t *NB,
                                     const float *WX, const float *WY) {
    const float self_x = POS[idx].x;
    const float self_y = POS[idx].y;
    float incoming = 0.0f;
    int   checked  = 0;
    const int base = idx * 6;
    for (int d = 0; d < 6; ++d) {
        const int32_t nb_idx = NB[base + d];
        if (nb_idx < 0) continue;
        const float dx = self_x - POS[nb_idx].x;
        const float dy = self_y - POS[nb_idx].y;
        const float dl2 = dx * dx + dy * dy;
        if (dl2 <= 0.0001f) continue;
        const float wx = WX[nb_idx];
        const float wy = WY[nb_idx];
        const float wl2 = wx * wx + wy * wy;
        if (wl2 <= 0.0001f) continue;
        const float inv_d = 1.0f / Math::sqrt(dl2);
        const float inv_w = 1.0f / Math::sqrt(wl2);
        float cos_in = (dx * wx + dy * wy) * (inv_d * inv_w);
        if (cos_in < 0.0f) cos_in = 0.0f;
        incoming += cos_in;
        checked  += 1;
    }
    if (checked == 0) return 0.0f;
    float v = incoming / float(checked);
    if (v < 0.0f) v = 0.0f;
    else if (v > 1.0f) v = 1.0f;
    return v;
}

// Mirror weather_system.gd::_classify_field_weather_at (line 1497).
// WeatherType.WT enum values: CLEAR=0 RAIN=1 STORM=2 BLIZZARD=3 DROUGHT=4
//                              FOG=5 HEATWAVE=6 MONSOON=7
inline uint8_t wf_classify_field_weather_at(float pos_y, int season_idx,
                                            float temp, float vapor, float cloud,
                                            float precip, float instability,
                                            float ocean_an,
                                            float wb_pos_y, float wb_size_y,
                                            float season_phase) {
    float lat_abs = 0.5f;
    if (wb_size_y > 0.001f) {
        float n = (pos_y - wb_pos_y) / wb_size_y;
        if (n < 0.0f) n = 0.0f;
        else if (n > 1.0f) n = 1.0f;
        lat_abs = n * 2.0f - 1.0f;
        if (lat_abs < 0.0f) lat_abs = -lat_abs;
    }
    const bool warm      = temp  > 0.58f;
    const bool cold      = temp  < 0.32f;
    const bool humid     = vapor > 0.55f;
    const bool summerish = (season_idx & 3) == 1;
    const bool low_lat   = lat_abs < 0.48f;

    if (cold && (precip > 0.50f || (cloud > 0.78f && vapor > 0.75f)))
        return 3; // BLIZZARD
    if (warm && humid && instability > 0.85f && precip > 0.58f)
        return 2; // STORM
    if (warm && humid && low_lat &&
        (summerish || (season_phase > 0.75f && season_phase < 2.25f)) &&
        precip > 0.48f)
        return 7; // MONSOON
    if (precip > 0.52f || (cloud > 0.82f && vapor > 0.72f))
        return 1; // RAIN
    if (vapor > 0.58f && cloud > 0.28f && precip < 0.15f && temp < 0.50f)
        return 5; // FOG
    if (temp > 0.73f && vapor < 0.35f && cloud < 0.20f)
        return 6; // HEATWAVE
    if (vapor < 0.30f && cloud < 0.14f && (temp > 0.52f || ocean_an < -0.08f))
        return 4; // DROUGHT
    return 0; // CLEAR
}

// Mirror weather_system.gd::_field_intensity_for_type (line 1551).
inline float wf_field_intensity_for_type(uint8_t wt, float temp, float vapor,
                                         float cloud, float precip,
                                         float instability, float ocean_an) {
    float v = 0.0f;
    switch (wt) {
        case 2: { // STORM
            const float m = (precip > instability) ? precip : instability;
            v = m * 0.82f + cloud * 0.18f;
            break;
        }
        case 7: // MONSOON
            v = precip * 0.72f + vapor * 0.18f + cloud * 0.18f;
            break;
        case 1: // RAIN
        case 3: // BLIZZARD
            v = precip * 0.78f + cloud * 0.30f;
            break;
        case 5: // FOG
            v = cloud * 0.75f + vapor * 0.20f;
            break;
        case 6: { // HEATWAVE
            float dry = 0.32f - vapor;
            if (dry < 0.0f) dry = 0.0f;
            v = (temp - 0.65f) * 2.2f + dry;
            break;
        }
        case 4: { // DROUGHT
            float oa = -ocean_an;
            if (oa < 0.0f) oa = 0.0f;
            v = (0.35f - vapor) * 2.0f + (0.16f - cloud) + oa * 0.6f;
            break;
        }
        default:
            return 0.0f;
    }
    if (v < 0.0f) v = 0.0f;
    else if (v > 1.0f) v = 1.0f;
    return v;
}

} // anonymous namespace (F.1 helpers)

// ─── F.1 main pass ──────────────────────────────────────────────────────────
//
// Single-shot full sweep over [start_idx, end_idx). Writes 8 cell-level
// SoA component slots in place; GDScript caller copies them out to its
// _field_slice_next_* scratch arrays after the call returns so that
// commit_weather_field_solve() (snow accumulation, fronts, distribution)
// is unchanged.
//
// LIMITATION (locked in world_ext.h doc block): start_idx == 0 && end_idx
// == n_cells is required. Slice budget < n falls back to GDScript because
// mid-slice writes to the SoA would corrupt the next slice's SoA reads.
double DCWorldExt::run_weather_field_solve_pass(const Dictionary &knobs) {
    using godot::StringName;
    using godot::PackedFloat32Array;
    using godot::PackedInt32Array;
    using godot::PackedVector2Array;
    using godot::PackedByteArray;
    using godot::Vector2;

    auto diag = [&](const char *why) {
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_weather_field_solve_pass: ", why,
            " — fallback to GDScript");
    };

    if (!_bound) { diag("not _bound"); return -1.0; }

    // ─── Resolve all 16 slot ids ONCE ───────────────────────────────────
    const int sid_temp        = component_id(StringName("cell_temp"));
    const int sid_moisture    = component_id(StringName("cell_moisture"));
    const int sid_air_anom    = component_id(StringName("cell_air_mass_temp_anomaly"));
    const int sid_wind_x      = component_id(StringName("cell_wind_x"));
    const int sid_wind_y      = component_id(StringName("cell_wind_y"));
    const int sid_terrain     = component_id(StringName("cell_terrain"));
    const int sid_has_river   = component_id(StringName("cell_has_river"));
    const int sid_elev        = component_id(StringName("cell_elevation"));
    const int sid_vegetation  = component_id(StringName("cell_vegetation"));
    const int sid_w_vapor     = component_id(StringName("cell_weather_vapor"));
    const int sid_w_cloud     = component_id(StringName("cell_weather_cloud"));
    const int sid_w_precip    = component_id(StringName("cell_weather_precip"));
    const int sid_w_inst      = component_id(StringName("cell_weather_instability"));
    const int sid_w_intens    = component_id(StringName("cell_weather_intensity"));
    const int sid_w_conv      = component_id(StringName("cell_weather_convergence"));
    const int sid_w_type      = component_id(StringName("cell_weather_type"));
    const int sid_w_finit     = component_id(StringName("cell_weather_field_init"));
    if (sid_temp       < 0 || sid_moisture   < 0 || sid_air_anom    < 0 ||
        sid_wind_x     < 0 || sid_wind_y     < 0 || sid_terrain     < 0 ||
        sid_has_river  < 0 || sid_elev       < 0 || sid_vegetation  < 0 ||
        sid_w_vapor    < 0 || sid_w_cloud    < 0 || sid_w_precip    < 0 ||
        sid_w_inst     < 0 || sid_w_intens   < 0 || sid_w_conv      < 0 ||
        sid_w_type     < 0 || sid_w_finit    < 0) {
        diag("missing slot id (some weather component not bound)");
        return -1.0;
    }

    // ─── Pull scalars + range from knobs ────────────────────────────────
    if (!knobs.has("start_idx")  || !knobs.has("end_idx")  ||
        !knobs.has("n_cells")    || !knobs.has("season_idx") ||
        !knobs.has("climate_anomaly") || !knobs.has("season_phase") ||
        !knobs.has("world_bounds_pos_y") || !knobs.has("world_bounds_size_y") ||
        !knobs.has("refresh_convergence")) {
        diag("knobs missing required keys");
        return -1.0;
    }
    const int   start_idx       = int(knobs["start_idx"]);
    const int   end_idx         = int(knobs["end_idx"]);
    const int   n_cells         = int(knobs["n_cells"]);
    const int   season_idx      = int(knobs["season_idx"]);
    const float climate_anomaly = float(knobs["climate_anomaly"]);
    const float season_phase    = float(knobs["season_phase"]);
    const float wb_pos_y        = float(knobs["world_bounds_pos_y"]);
    const float wb_size_y       = float(knobs["world_bounds_size_y"]);
    const bool  refresh_convergence = bool(knobs["refresh_convergence"]);

    if (start_idx != 0 || end_idx != n_cells) {
        diag("partial slice not yet supported (must be full-pass)");
        return -1.0;
    }
    if (n_cells <= 0) { diag("n_cells <= 0"); return -1.0; }

    const int   field_advect_steps      = knobs.has("field_advect_steps")
                                            ? int(knobs["field_advect_steps"]) : 1;
    const float field_diffusion         = knobs.has("field_diffusion")
                                            ? float(knobs["field_diffusion"]) : 0.08f;
    const float field_condensation_gain = knobs.has("field_condensation_gain")
                                            ? float(knobs["field_condensation_gain"]) : 0.28f;
    const float field_orographic_lift_gain = knobs.has("field_orographic_lift_gain")
                                            ? float(knobs["field_orographic_lift_gain"]) : 0.35f;
    const float field_convergence_gain  = knobs.has("field_convergence_gain")
                                            ? float(knobs["field_convergence_gain"]) : 0.25f;
    const float field_ocean_evap_gain   = knobs.has("field_ocean_evap_gain")
                                            ? float(knobs["field_ocean_evap_gain"]) : 0.30f;
    const float field_precip_decay      = knobs.has("field_precip_decay")
                                            ? float(knobs["field_precip_decay"]) : 0.82f;
    const float hex_size                = knobs.has("hex_size")
                                            ? float(knobs["hex_size"]) : 22.0f;

    // ─── Pull pre-computed PackedArrays from knobs (zero-copy reads) ────
    if (!knobs.has("cell_pos") || !knobs.has("neighbor_indices") ||
        !knobs.has("prev_vapor") || !knobs.has("prev_precip") ||
        !knobs.has("temp_transport_anomaly")) {
        diag("knobs missing required PackedArray inputs");
        return -1.0;
    }
    PackedVector2Array cell_pos_arr = knobs["cell_pos"];
    PackedInt32Array   nb_arr       = knobs["neighbor_indices"];
    PackedFloat32Array prev_vapor_arr  = knobs["prev_vapor"];
    PackedFloat32Array prev_precip_arr = knobs["prev_precip"];
    PackedFloat32Array temp_anom_arr   = knobs["temp_transport_anomaly"];

    if (cell_pos_arr.size() != n_cells) {
        diag("cell_pos size mismatch"); return -1.0;
    }
    if (nb_arr.size() < n_cells * 6) {
        diag("neighbor_indices size < n_cells * 6 (pass requires fast_indexed)");
        return -1.0;
    }
    if (prev_vapor_arr.size()  != n_cells ||
        prev_precip_arr.size() != n_cells ||
        temp_anom_arr.size()   != n_cells) {
        diag("prev/temp_anom array size mismatch"); return -1.0;
    }

    // ─── Acquire slot arrays + validate sizes ───────────────────────────
    Slot &s_temp     = _slots.write[sid_temp];
    Slot &s_moist    = _slots.write[sid_moisture];
    Slot &s_air_anom = _slots.write[sid_air_anom];
    Slot &s_wx       = _slots.write[sid_wind_x];
    Slot &s_wy       = _slots.write[sid_wind_y];
    Slot &s_terr     = _slots.write[sid_terrain];
    Slot &s_riv      = _slots.write[sid_has_river];
    Slot &s_elev     = _slots.write[sid_elev];
    Slot &s_veg      = _slots.write[sid_vegetation];
    Slot &s_wvap     = _slots.write[sid_w_vapor];
    Slot &s_wcld     = _slots.write[sid_w_cloud];
    Slot &s_wpre     = _slots.write[sid_w_precip];
    Slot &s_wins     = _slots.write[sid_w_inst];
    Slot &s_wint     = _slots.write[sid_w_intens];
    Slot &s_wcnv     = _slots.write[sid_w_conv];
    Slot &s_wtyp     = _slots.write[sid_w_type];
    Slot &s_wfin     = _slots.write[sid_w_finit];

    if (s_temp.arr_f32.size()     != n_cells || s_moist.arr_f32.size()  != n_cells ||
        s_air_anom.arr_f32.size() != n_cells || s_wx.arr_f32.size()     != n_cells ||
        s_wy.arr_f32.size()       != n_cells || s_terr.arr_u8.size()    != n_cells ||
        s_riv.arr_u8.size()       != n_cells || s_elev.arr_f32.size()   != n_cells ||
        s_veg.arr_u8.size()       != n_cells ||
        s_wvap.arr_f32.size()     != n_cells || s_wcld.arr_f32.size()   != n_cells ||
        s_wpre.arr_f32.size()     != n_cells || s_wins.arr_f32.size()   != n_cells ||
        s_wint.arr_f32.size()     != n_cells || s_wcnv.arr_f32.size()   != n_cells ||
        s_wtyp.arr_u8.size()      != n_cells || s_wfin.arr_u8.size()    != n_cells) {
        diag("slot array size mismatch (re-bind needed?)");
        return -1.0;
    }

    // ─── Hot pointers ───────────────────────────────────────────────────
    const float   * const __restrict T    = s_temp.arr_f32.ptr();
    const float   * const __restrict M    = s_moist.arr_f32.ptr();
    const float   * const __restrict AA   = s_air_anom.arr_f32.ptr();
    const float   * const __restrict WX   = s_wx.arr_f32.ptr();
    const float   * const __restrict WY   = s_wy.arr_f32.ptr();
    const uint8_t * const __restrict TERR = s_terr.arr_u8.ptr();
    const uint8_t * const __restrict RIV  = s_riv.arr_u8.ptr();
    const float   * const __restrict ELEV = s_elev.arr_f32.ptr();
    const uint8_t * const __restrict VEG  = s_veg.arr_u8.ptr();

    const Vector2 * const __restrict POS  = cell_pos_arr.ptr();
    const int32_t * const __restrict NB   = nb_arr.ptr();
    const float   * const __restrict PV   = prev_vapor_arr.ptr();
    const float   * const __restrict PP   = prev_precip_arr.ptr();
    const float   * const __restrict TA   = temp_anom_arr.ptr();

    float   * const __restrict OUT_VAP   = s_wvap.arr_f32.ptrw();
    float   * const __restrict OUT_CLD   = s_wcld.arr_f32.ptrw();
    float   * const __restrict OUT_PRE   = s_wpre.arr_f32.ptrw();
    float   * const __restrict OUT_INS   = s_wins.arr_f32.ptrw();
    float   * const __restrict OUT_INT   = s_wint.arr_f32.ptrw();
    float   * const __restrict OUT_CNV   = s_wcnv.arr_f32.ptrw();
    uint8_t * const __restrict OUT_TYP   = s_wtyp.arr_u8.ptrw();
    uint8_t * const __restrict OUT_FIN   = s_wfin.arr_u8.ptrw();

    // ─── 计时 (返回给调用方做对账，charter §0 铁律 3) ──────────────────
    auto t0 = std::chrono::high_resolution_clock::now();

    // ─── Tight loop — 1:1 mirror of run_weather_field_solve_slice fast path ──
    // Source: weather_system.gd:678-757. Branch annotations preserved as
    // line-number citations so the next bit-equal failure is one diff away.
    for (int i = 0; i < n_cells; ++i) {
        // (line 681) temp = clampf(soa_temp[i] + climate_anomaly + soa_air_anomaly[i], 0, 1)
        float temp = T[i] + climate_anomaly + AA[i];
        if (temp < 0.0f) temp = 0.0f;
        else if (temp > 1.0f) temp = 1.0f;

        // (line 682) base_m = clampf(soa_moisture_loop[i], 0, 1)
        float base_m = M[i];
        if (base_m < 0.0f) base_m = 0.0f;
        else if (base_m > 1.0f) base_m = 1.0f;

        // (line 683) ocean_an
        const float ocean_an = wf_avg_ocean_anomaly_at_idx(i, TERR, NB, TA);

        // (line 684) on_water
        const bool on_water = wf_is_water_terrain(TERR[i]);

        // (line 686-692) wind + wind_dir
        // Caveat: GDScript falls back to _sample_terrain_wind() if wind ≈ 0.
        // That path involves WorldData.iter_winds() with seasonal blending —
        // currently NOT mirrored in C++. Bit-equal NOT guaranteed for cells
        // where soa_wind == (0,0). In production these are extremely rare
        // (wind solver writes non-zero everywhere except boundary degenerate
        // cells). Caller can flip flag off if a regression appears.
        float wind_x = WX[i];
        float wind_y = WY[i];
        const float wlen2 = wind_x * wind_x + wind_y * wind_y;
        float wind_dx, wind_dy;
        if (wlen2 < 0.0001f) {
            // Conservative fallback: dir = (1,0) like the GDScript final
            // `wind.normalized() if length_squared > 0.0001 else Vector2.RIGHT`.
            // Magnitude stays 0 → wind_mag=0 → advect_w lower bound.
            wind_dx = 1.0f;
            wind_dy = 0.0f;
        } else {
            const float inv = 1.0f / Math::sqrt(wlen2);
            wind_dx = wind_x * inv;
            wind_dy = wind_y * inv;
        }
        const float wind_len = Math::sqrt(wlen2);

        // (line 694) upstream_idx
        const int upstream_idx = (field_advect_steps > 0)
            ? wf_neighbor_aligned_idx(i, -wind_dx, -wind_dy, POS, NB, n_cells, hex_size)
            : -1;

        // (line 695) advected_vapor (decay-weighted upstream chain)
        const float advected_vapor = wf_upstream_vapor_idx_from_first(
            i, upstream_idx, POS, NB, PV, wind_dx, wind_dy, n_cells, hex_size,
            field_advect_steps);

        // (line 696) neighbor_vapor (6-neighbour avg)
        const float neighbor_vapor = wf_neighbor_average_vapor_idx(i, NB, PV);

        // (line 697-698) wind_mag + advect_w
        float wind_mag = wind_len / 1.2f;
        if (wind_mag < 0.0f) wind_mag = 0.0f;
        else if (wind_mag > 1.0f) wind_mag = 1.0f;
        float advect_w = 0.65f + wind_mag * 0.30f;
        if (advect_w < 0.65f) advect_w = 0.65f;
        else if (advect_w > 0.95f) advect_w = 0.95f;

        // (line 699-704) is_lake / has_river attenuation
        // TERRAIN.LAKE = 18 (terrain_type.gd order)
        const bool is_lake = (TERR[i] == 18);
        const bool has_river = (!is_lake) && (RIV[i] != 0) && (!on_water);
        if (is_lake) {
            advect_w *= 0.5f;
            if (advect_w < 0.20f) advect_w = 0.20f;
            else if (advect_w > 0.50f) advect_w = 0.50f;
        } else if (has_river) {
            advect_w *= 0.85f;
            if (advect_w < 0.55f) advect_w = 0.55f;
            else if (advect_w > 0.85f) advect_w = 0.85f;
        }

        // (line 705-706) vapor = lerp(base_m, advected_vapor, advect_w);
        //                vapor = lerp(vapor, neighbor_vapor, field_diffusion)
        float vapor = base_m + (advected_vapor - base_m) * advect_w;
        vapor = vapor + (neighbor_vapor - vapor) * field_diffusion;

        // (line 708-712) effective_ocean_an
        float effective_ocean_an = ocean_an;
        if (is_lake) {
            effective_ocean_an = 0.20f;
        } else if (has_river) {
            if (ocean_an > 0.08f) effective_ocean_an = ocean_an;
            else                  effective_ocean_an = 0.08f;
        }

        // (line 713) evap
        const float evap = wf_evaporation_for_cell_idx(
            i, TERR, VEG, RIV, NB, temp, base_m, effective_ocean_an, on_water,
            field_ocean_evap_gain);

        // (line 714) vapor = clampf(vapor + evap, 0, 1)
        vapor += evap;
        if (vapor < 0.0f) vapor = 0.0f;
        else if (vapor > 1.0f) vapor = 1.0f;

        // (line 716) lift
        const float lift = wf_orographic_lift_from_upstream_idx(
            i, upstream_idx, ELEV);

        // (line 717-719) convergence (refresh on stride, else inherit SoA)
        // NOTE: When refresh_convergence=false, we read from OUT_CNV[i] which
        // *was* the previous-tick value before this pass started. C++ takes
        // ptrw() once at top — refcount alias to GDScript's SoA. Since this
        // is a single-shot full pass, we read OUT_CNV[i] (= prev value) BEFORE
        // any cell j > i overwrites it (cells are processed in order, and
        // cell i only writes OUT_CNV[i], never OUT_CNV[j]). So the read sees
        // the stable prev-tick value. Bit-equal to GDScript path.
        float convergence = OUT_CNV[i];
        if (refresh_convergence) {
            convergence = wf_wind_convergence_idx(i, POS, NB, WX, WY);
        }
        if (lift < 0.0f) {
            vapor += lift * 0.22f;
            if (vapor < 0.0f) vapor = 0.0f;
            else if (vapor > 1.0f) vapor = 1.0f;
        }

        // (line 723-725) saturation / humid_excess / lift_supply
        float saturation = 0.40f + temp * 0.30f;
        if (saturation < 0.34f) saturation = 0.34f;
        else if (saturation > 0.74f) saturation = 0.74f;
        float humid_excess = vapor - saturation;
        if (humid_excess < 0.0f) humid_excess = 0.0f;
        float lift_pos = (lift > 0.0f) ? lift : 0.0f;
        float lift_gate = (vapor - 0.10f) / 0.40f;
        if (lift_gate < 0.0f) lift_gate = 0.0f;
        else if (lift_gate > 1.0f) lift_gate = 1.0f;
        const float lift_supply = lift_pos * lift_gate;

        // (line 726-732) cloud
        float effective_oa_pos = (effective_ocean_an > 0.0f) ? effective_ocean_an : 0.0f;
        float cloud = humid_excess * field_condensation_gain * 2.2f
                    + lift_supply  * field_orographic_lift_gain
                    + convergence  * field_convergence_gain
                    + effective_oa_pos * 0.12f;
        if (cloud < 0.0f) cloud = 0.0f;
        else if (cloud > 1.0f) cloud = 1.0f;

        // (line 733-741) instability
        float instability = (temp - 0.45f) * 1.15f
                          + vapor * 0.55f
                          + cloud * 0.35f
                          + convergence * field_convergence_gain
                          + lift_supply * field_orographic_lift_gain
                          + effective_oa_pos * 0.25f;
        if (instability < 0.0f) instability = 0.0f;
        else if (instability > 1.0f) instability = 1.0f;

        // (line 742-747) precip
        float lift_neg = (-lift > 0.0f) ? -lift : 0.0f;
        const float precip_raw = cloud * (0.30f + instability * 0.70f)
                               + lift_supply * 0.18f
                               - lift_neg * 0.45f;
        const float old_precip = PP[i];
        float vapor_floor_factor = (vapor - 0.10f) / 0.40f;
        if (vapor_floor_factor < 0.0f) vapor_floor_factor = 0.0f;
        else if (vapor_floor_factor > 1.0f) vapor_floor_factor = 1.0f;
        const float dyn_decay = field_precip_decay + wind_mag * 0.25f;
        const float precip_floor = old_precip * (1.0f - dyn_decay) * vapor_floor_factor;
        float precip = (precip_raw > precip_floor) ? precip_raw : precip_floor;
        if (precip < 0.0f) precip = 0.0f;
        else if (precip > 1.0f) precip = 1.0f;

        // (line 749-750) classify + intensity
        const uint8_t wt = wf_classify_field_weather_at(
            POS[i].y, season_idx, temp, vapor, cloud, precip, instability,
            ocean_an, wb_pos_y, wb_size_y, season_phase);
        const float intensity = wf_field_intensity_for_type(
            wt, temp, vapor, cloud, precip, instability, ocean_an);

        // (line 751-757) write outputs
        OUT_VAP[i] = vapor;
        OUT_CLD[i] = cloud;
        OUT_PRE[i] = precip;
        OUT_INS[i] = instability;
        OUT_INT[i] = intensity;
        OUT_CNV[i] = convergence;
        OUT_TYP[i] = wt;
        OUT_FIN[i] = 1; // weather_field_initialized = true
    }

    // §11.2 flush: push CoW-detached weather output slots back to MapData
    _flush_slot_to_map(sid_w_vapor);
    _flush_slot_to_map(sid_w_cloud);
    _flush_slot_to_map(sid_w_precip);
    _flush_slot_to_map(sid_w_inst);
    _flush_slot_to_map(sid_w_intens);
    _flush_slot_to_map(sid_w_conv);
    _flush_slot_to_map(sid_w_type);
    _flush_slot_to_map(sid_w_finit);

    auto t1 = std::chrono::high_resolution_clock::now();
    return std::chrono::duration<double, std::milli>(t1 - t0).count();
}

// ─── F.2a: ocean water pass ─────────────────────────────────────────────────
//
// Single-shot full sweep over [0, n_cells). 1:1 mirror of
// _ocean_water_pass_soa (map_generator.gd:4679+) hot loop:
//   for each WATER cell i with non-zero current:
//     advect upstream `advect_steps` times (pick best dot vs -current dir)
//     temp_mixed = lerp(temp_before[i], temp_before[upstream], heat_mix)
//     temp_a[i] = clamp(temp_mixed, 0, 1)
//     anomaly_out[i] = temp_mixed - baseline[i]
//   for each WATER cell i with zero current OR advect_steps==0:
//     anomaly_out[i] = 0.0
//
// Caller-side responsibility (与 GDScript path 一致)：
//   * pre-compute baseline[]  (ema_init=true → temp_baseline_a, else compute_temperature)
//   * pre-compute temp_before[] (temp_a > 0 → temp_a, else baseline)
//   * pass anomaly_out as scratch buffer (water cells written; land cells preserved
//     for subsequent run_ocean_land_pass call)
//   * after both passes return, copy anomaly_out → cells[i].temperature_transport_anomaly
double DCWorldExt::run_ocean_water_pass(Dictionary knobs) {
    using godot::StringName;
    using godot::PackedFloat32Array;
    using godot::PackedInt32Array;
    using godot::PackedByteArray;

    auto diag = [&](const char *why) {
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_ocean_water_pass: ", why,
            " — fallback to GDScript");
    };

    if (!_bound) { diag("not _bound"); return -1.0; }

    const int sid_temp     = component_id(StringName("cell_temp"));
    const int sid_iswater  = component_id(StringName("cell_is_water"));
    const int sid_pos_x    = component_id(StringName("cell_pos_x"));
    const int sid_pos_y    = component_id(StringName("cell_pos_y"));
    if (sid_temp < 0 || sid_iswater < 0 || sid_pos_x < 0 || sid_pos_y < 0) {
        diag("missing slot id (cell_temp/is_water/pos_x/pos_y)");
        return -1.0;
    }

    if (!knobs.has("n_cells") || !knobs.has("advect_steps") ||
        !knobs.has("heat_mix") || !knobs.has("neighbor_indices") ||
        !knobs.has("baseline_arr") || !knobs.has("temp_before_arr") ||
        !knobs.has("anomaly_out") ||
        !knobs.has("ocean_current_x_arr") || !knobs.has("ocean_current_y_arr")) {
        diag("knobs missing required keys (need ocean_current_x/y_arr from cells)");
        return -1.0;
    }
    const int   n_cells      = int(knobs["n_cells"]);
    const int   advect_steps = int(knobs["advect_steps"]);
    const float heat_mix     = float(knobs["heat_mix"]);
    if (n_cells <= 0) { diag("n_cells <= 0"); return -1.0; }

    PackedInt32Array   nb_arr = knobs["neighbor_indices"];
    PackedFloat32Array baseline_arr = knobs["baseline_arr"];
    PackedFloat32Array temp_before_arr = knobs["temp_before_arr"];
    PackedFloat32Array ocx_arr = knobs["ocean_current_x_arr"];
    PackedFloat32Array ocy_arr = knobs["ocean_current_y_arr"];
    if (nb_arr.size() < n_cells * 6) { diag("neighbor_indices size < n_cells*6"); return -1.0; }
    if (baseline_arr.size()    != n_cells) { diag("baseline_arr size mismatch"); return -1.0; }
    if (temp_before_arr.size() != n_cells) { diag("temp_before_arr size mismatch"); return -1.0; }
    if (ocx_arr.size()         != n_cells) { diag("ocean_current_x_arr size mismatch"); return -1.0; }
    if (ocy_arr.size()         != n_cells) { diag("ocean_current_y_arr size mismatch"); return -1.0; }

    // §11 CoW fix: create a FRESH anomaly array (refcount=1) so ptrw()
    // does not CoW-detach. After the loop we write it back into the
    // Dictionary; since Dictionary is a shared reference type the
    // GDScript caller will see the replacement.
    PackedFloat32Array anomaly_out;
    anomaly_out.resize(n_cells);

    Slot &s_temp    = _slots.write[sid_temp];
    Slot &s_iswater = _slots.write[sid_iswater];
    Slot &s_pos_x   = _slots.write[sid_pos_x];
    Slot &s_pos_y   = _slots.write[sid_pos_y];
    if (s_temp.arr_f32.size()  != n_cells || s_iswater.arr_u8.size() != n_cells ||
        s_pos_x.arr_f32.size() != n_cells || s_pos_y.arr_f32.size()  != n_cells) {
        diag("slot array size mismatch");
        return -1.0;
    }

    float       * const __restrict T    = s_temp.arr_f32.ptrw();
    const uint8_t * const __restrict IW = s_iswater.arr_u8.ptr();
    const float * const __restrict POSX = s_pos_x.arr_f32.ptr();
    const float * const __restrict POSY = s_pos_y.arr_f32.ptr();
    // OCX/OCY 从 knobs 拿（cells 提取的最新值，规避 SoA stale 问题）
    const float * const __restrict OCX  = ocx_arr.ptr();
    const float * const __restrict OCY  = ocy_arr.ptr();
    const int32_t * const __restrict NB = nb_arr.ptr();
    const float * const __restrict BL   = baseline_arr.ptr();
    const float * const __restrict TB   = temp_before_arr.ptr();
    float       * const __restrict AOUT = anomaly_out.ptrw();

    auto t0 = std::chrono::high_resolution_clock::now();

    for (int i = 0; i < n_cells; ++i) {
        if (IW[i] == 0) continue; // skip land
        const float cur_x = OCX[i];
        const float cur_y = OCY[i];
        const float cur_len2 = cur_x * cur_x + cur_y * cur_y;
        if (cur_len2 < 1e-6f || advect_steps == 0) {
            AOUT[i] = 0.0f;
            continue;
        }
        const float inv_cur = 1.0f / std::sqrt(cur_len2);
        const float up_dx = -cur_x * inv_cur;
        const float up_dy = -cur_y * inv_cur;

        int upstream_idx = i;
        for (int step = 0; step < advect_steps; ++step) {
            int   best_idx = -1;
            float best_dot = 0.1f;
            const float swx = POSX[upstream_idx];
            const float swy = POSY[upstream_idx];
            const int ub = upstream_idx * 6;
            for (int d = 0; d < 6; ++d) {
                const int32_t ni = NB[ub + d];
                if (ni < 0) continue;
                if (IW[ni] == 0) continue;
                const float dx = POSX[ni] - swx;
                const float dy = POSY[ni] - swy;
                const float len2 = dx * dx + dy * dy;
                if (len2 < 1e-6f) continue;
                const float inv_len = 1.0f / std::sqrt(len2);
                const float dot_v = (dx * up_dx + dy * up_dy) * inv_len;
                if (dot_v > best_dot) {
                    best_dot = dot_v;
                    best_idx = ni;
                }
            }
            if (best_idx < 0) break;
            upstream_idx = best_idx;
        }

        const float temp_self = TB[i];
        const float temp_up   = TB[upstream_idx];
        float temp_mixed = temp_self + (temp_up - temp_self) * heat_mix; // = lerpf
        if (temp_mixed < 0.0f) temp_mixed = 0.0f;
        else if (temp_mixed > 1.0f) temp_mixed = 1.0f;
        T[i] = temp_mixed;
        AOUT[i] = temp_mixed - BL[i];
    }

    // §11 CoW fix: write the freshly-computed anomaly back into the
    // Dictionary so GDScript can read it after the call.
    knobs["anomaly_out"] = anomaly_out;

    // §11.2 flush: push CoW-detached cell_temp back to MapData
    _flush_slot_to_map(sid_temp);

    auto t1 = std::chrono::high_resolution_clock::now();
    return std::chrono::duration<double, std::milli>(t1 - t0).count();
}

// ─── F.2b: ocean land pass ──────────────────────────────────────────────────
//
// Single-shot full sweep over [0, n_cells). 1:1 mirror of
// _ocean_land_pass_soa (map_generator.gd:4762+) hot loop:
//   for each LAND cell i:
//     sum of (water-nb anomaly × dot(self→nb, nb_current)) over 6 neighbors
//     anomaly_in = (weighted_sum / weight_total) * effective_leak
//     anomaly_inout[i] = anomaly_in
//     if |anomaly_in| > 1e-5: temp_a[i] = clamp(temp_a[i] + anomaly_in, 0, 1)
//
// 注意：anomaly_inout 既读（water 邻居 by water pass 写入的 anomaly）也写
// （本 cell 的 anomaly）。GDScript side 必须先调 water pass 再调 land pass。
double DCWorldExt::run_ocean_land_pass(Dictionary knobs) {
    using godot::StringName;
    using godot::PackedFloat32Array;
    using godot::PackedInt32Array;
    using godot::PackedByteArray;

    auto diag = [&](const char *why) {
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_ocean_land_pass: ", why,
            " — fallback to GDScript");
    };

    if (!_bound) { diag("not _bound"); return -1.0; }

    const int sid_temp     = component_id(StringName("cell_temp"));
    const int sid_iswater  = component_id(StringName("cell_is_water"));
    const int sid_pos_x    = component_id(StringName("cell_pos_x"));
    const int sid_pos_y    = component_id(StringName("cell_pos_y"));
    if (sid_temp < 0 || sid_iswater < 0 || sid_pos_x < 0 || sid_pos_y < 0) {
        diag("missing slot id (cell_temp/is_water/pos_x/pos_y)");
        return -1.0;
    }

    if (!knobs.has("n_cells") || !knobs.has("effective_leak") ||
        !knobs.has("neighbor_indices") || !knobs.has("anomaly_inout") ||
        !knobs.has("fallback_baseline_arr") ||
        !knobs.has("ocean_current_x_arr") || !knobs.has("ocean_current_y_arr")) {
        diag("knobs missing required keys (need ocean_current_x/y_arr from cells)");
        return -1.0;
    }
    const int   n_cells        = int(knobs["n_cells"]);
    const float effective_leak = float(knobs["effective_leak"]);
    if (n_cells <= 0) { diag("n_cells <= 0"); return -1.0; }

    PackedInt32Array nb_arr = knobs["neighbor_indices"];
    PackedFloat32Array fallback_baseline = knobs["fallback_baseline_arr"];
    PackedFloat32Array ocx_arr = knobs["ocean_current_x_arr"];
    PackedFloat32Array ocy_arr = knobs["ocean_current_y_arr"];
    if (nb_arr.size() < n_cells * 6)         { diag("neighbor_indices size < n_cells*6"); return -1.0; }
    if (fallback_baseline.size() != n_cells) { diag("fallback_baseline_arr size mismatch"); return -1.0; }
    if (ocx_arr.size()       != n_cells)     { diag("ocean_current_x_arr size mismatch"); return -1.0; }
    if (ocy_arr.size()       != n_cells)     { diag("ocean_current_y_arr size mismatch"); return -1.0; }

    // §11 CoW fix: duplicate the input anomaly into a fresh array
    // (refcount=1) so ptrw() does not CoW-detach. We read water
    // neighbors' anomaly (written by water pass) and write land cells'
    // anomaly, then push the result back into the Dictionary.
    PackedFloat32Array anomaly_src = knobs["anomaly_inout"];
    if (anomaly_src.size() != n_cells) { diag("anomaly_inout size mismatch"); return -1.0; }
    PackedFloat32Array anomaly_inout = anomaly_src.duplicate();

    Slot &s_temp    = _slots.write[sid_temp];
    Slot &s_iswater = _slots.write[sid_iswater];
    Slot &s_pos_x   = _slots.write[sid_pos_x];
    Slot &s_pos_y   = _slots.write[sid_pos_y];
    if (s_temp.arr_f32.size()  != n_cells || s_iswater.arr_u8.size() != n_cells ||
        s_pos_x.arr_f32.size() != n_cells || s_pos_y.arr_f32.size()  != n_cells) {
        diag("slot array size mismatch");
        return -1.0;
    }

    float       * const __restrict T    = s_temp.arr_f32.ptrw();
    const uint8_t * const __restrict IW = s_iswater.arr_u8.ptr();
    const float * const __restrict POSX = s_pos_x.arr_f32.ptr();
    const float * const __restrict POSY = s_pos_y.arr_f32.ptr();
    // OCX/OCY 从 knobs 拿（cells 最新值，规避 SoA stale）
    const float * const __restrict OCX  = ocx_arr.ptr();
    const float * const __restrict OCY  = ocy_arr.ptr();
    const int32_t * const __restrict NB = nb_arr.ptr();
    float       * const __restrict A    = anomaly_inout.ptrw();
    const float * const __restrict FBL  = fallback_baseline.ptr();

    auto t0 = std::chrono::high_resolution_clock::now();

    // 注意：land 写入的是 LAND cell 的 anomaly，读 WATER 邻居的 anomaly
    // （water pass 已经在 anomaly_inout 里写好）。所以读写不冲突——所有 land
    // i 都不在自身 6 邻居读到的 water cell 集合里（water cell 的 anomaly 在
    // water pass 已 finalized）。可以安全用同一个数组 in-place。
    for (int i = 0; i < n_cells; ++i) {
        if (IW[i] != 0) continue; // skip water
        const float swx = POSX[i];
        const float swy = POSY[i];
        float weighted_sum = 0.0f;
        float weight_total = 0.0f;
        const int b = i * 6;
        for (int d = 0; d < 6; ++d) {
            const int32_t ni = NB[b + d];
            if (ni < 0) continue;
            if (IW[ni] == 0) continue; // only water nb contributes
            const float cx = OCX[ni];
            const float cy = OCY[ni];
            if (cx * cx + cy * cy < 1e-6f) continue;
            const float dx = swx - POSX[ni];
            const float dy = swy - POSY[ni];
            const float dlen2 = dx * dx + dy * dy;
            if (dlen2 < 1e-6f) continue;
            const float inv_len = 1.0f / std::sqrt(dlen2);
            const float dot_v = (dx * cx + dy * cy) * inv_len;
            if (dot_v <= 0.0f) continue;
            weighted_sum += A[ni] * dot_v;
            weight_total += dot_v;
        }
        float anomaly_in = 0.0f;
        if (weight_total > 0.0f) {
            anomaly_in = (weighted_sum / weight_total) * effective_leak;
        }
        A[i] = anomaly_in;
        // (line 4819-4829) only write temp if anomaly significant
        const float abs_anom = (anomaly_in < 0.0f) ? -anomaly_in : anomaly_in;
        if (abs_anom > 1e-5f) {
            // FIX (2026-05-13)：t_prev fallback 必须用 baseline，否则正反馈
            // 把 cell 锁死在 0：cell temp clamped 0 → +负 anomaly 又 clamp 0
            // → F.3 下一 tick 读到 0 算更负的 d_coastal → 全图沿海 cascading
            // 到 0。GDScript 原版用 temp_baseline_a[i] 救场，C++ 现复用调用
            // 方传入的 fallback_baseline_arr（= GDScript water pass 已计算的
            // baseline_arr，含 ema_init 分支 + _compute_temperature 兜底）。
            float t_prev = T[i];
            if (t_prev <= 0.0f) {
                t_prev = FBL[i];
            }
            float tnew = t_prev + anomaly_in;
            if (tnew < 0.0f) tnew = 0.0f;
            else if (tnew > 1.0f) tnew = 1.0f;
            T[i] = tnew;
        }
    }

    // §11 CoW fix: write the modified anomaly back into the Dictionary
    knobs["anomaly_inout"] = anomaly_inout;

    // §11.2 flush: push CoW-detached cell_temp back to MapData
    _flush_slot_to_map(sid_temp);

    auto t1 = std::chrono::high_resolution_clock::now();
    return std::chrono::duration<double, std::milli>(t1 - t0).count();
}

// ─── F.3 helpers ─────────────────────────────────────────────────────────────
namespace {

// Mirror weather/wind_belt.gd::wind_at — bit-equal scalar translation.
// Constants from wind_belt.gd:38-51. All scalar; promote to double for
// bit-equal stability across libm differences (charter §12.6.2).
inline void wind_belt_at(double ny, double season_phase,
                         double *out_wx, double *out_wy) {
    constexpr double ITCZ_HALF_WIDTH = 0.05;
    constexpr double TRADE_TOP       = 0.40;
    constexpr double WEST_TOP        = 0.70;
    constexpr double TRADE_X         = -1.0;
    constexpr double TRADE_Y_AMP     = 0.20;
    constexpr double WEST_X          = 1.0;
    constexpr double WEST_Y_AMP      = 0.10;
    constexpr double POLAR_X         = -1.0;
    constexpr double POLAR_Y_AMP     = 0.20;
    constexpr double ITCZ_X          = -0.20;
    constexpr double MONSOON_AMP     = 0.6;
    constexpr double BBH             = 0.06;
    constexpr double PI_HALF         = 1.5707963267948966;
    const double lat_signed = (ny - 0.5) * 2.0; // F.3 不传 lat_jitter
    const double abs_lat    = (lat_signed < 0.0) ? -lat_signed : lat_signed;
    const double sl         = (lat_signed < -0.001) ? -1.0 : (lat_signed > 0.001 ? 1.0 : 1.0);

    // smoothstep(a, b, x) = (clamp((x-a)/(b-a), 0, 1))^2 * (3 - 2*t)
    auto smoothstep = [](double a, double b, double x) -> double {
        if (b <= a) return (x >= a) ? 1.0 : 0.0;
        double t = (x - a) / (b - a);
        if (t < 0.0) t = 0.0; else if (t > 1.0) t = 1.0;
        return t * t * (3.0 - 2.0 * t);
    };

    const double w_itcz_b = 1.0 - smoothstep(ITCZ_HALF_WIDTH - BBH, ITCZ_HALF_WIDTH + BBH, abs_lat);
    const double w_trade_b = smoothstep(ITCZ_HALF_WIDTH - BBH, ITCZ_HALF_WIDTH + BBH, abs_lat)
                           * (1.0 - smoothstep(TRADE_TOP - BBH, TRADE_TOP + BBH, abs_lat));
    const double w_west_b = smoothstep(TRADE_TOP - BBH, TRADE_TOP + BBH, abs_lat)
                          * (1.0 - smoothstep(WEST_TOP - BBH, WEST_TOP + BBH, abs_lat));
    const double w_polar_b = smoothstep(WEST_TOP - BBH, WEST_TOP + BBH, abs_lat);
    const double base_x = w_itcz_b * ITCZ_X + w_trade_b * TRADE_X + w_west_b * WEST_X + w_polar_b * POLAR_X;
    const double base_y = w_trade_b * (-TRADE_Y_AMP * sl) + w_west_b * (WEST_Y_AMP * sl) + w_polar_b * (-POLAR_Y_AMP * sl);

    // hemi_phase 与 monsoon polarity（mirror wind_belt.gd:93-101）
    auto fposmod = [](double x, double m) -> double {
        double r = std::fmod(x, m);
        if (r < 0.0) r += m;
        return r;
    };
    double hemi_phase = (lat_signed < 0.0) ? fposmod(season_phase - 1.0, 4.0)
                                           : fposmod(season_phase + 1.0, 4.0);
    const double monsoon_polarity = std::sin(hemi_phase * PI_HALF);
    const double tropical_w       = smoothstep(TRADE_TOP, ITCZ_HALF_WIDTH, abs_lat);
    const double y_offset         = monsoon_polarity * tropical_w * MONSOON_AMP * sl;

    double wx = base_x;
    double wy = base_y + y_offset;
    const double wlen2 = wx * wx + wy * wy;
    if (wlen2 < 0.0001) {
        *out_wx = 1.0;
        *out_wy = 0.0;
        return;
    }
    const double inv = 1.0 / std::sqrt(wlen2);
    *out_wx = wx * inv;
    *out_wy = wy * inv;
}

} // anonymous namespace (F.3 helpers)

// ─── F.3 main pass ──────────────────────────────────────────────────────────
//
// Single-shot full sweep over [0, n_cells). 1:1 mirror of
// _climate_pass_b_soa (map_generator.gd:4311+) with these scope cuts:
//   * sparse path (go_sparse=true) → return -1.0 fallback
//   * cell.temperature_breakdown UI dict writes → SKIP
//   * [DIAG pass_b_end] end-of-pass stat print → SKIP (caller can dump SoA)
//
// Algorithm (mirror lines 4396-4523):
//   temp_snapshot = temp_a.duplicate()
//   for each cell i:
//     temp_now = temp_snapshot[i]; moisture_now = moist_a[i]
//     d_albedo = (-snow_cool * SNOW + -veg_cool * foliage)  if !is_water
//     d_coastal = coast_leak * avg(water-nb anomaly) * winter_boost  if !is_water
//     d_landform = +/- diurnal by landform * landform_phase_factor    if !is_water
//     temp_a[i] = clamp(temp_now + d_albedo + d_coastal + d_landform, 0, 1)
//     d_evap = evap_gain * (t_eff - t_freeze) * nb_water_norm * (1 + coupling*avg_anom)  if !is_water
//     d_rain_shadow = rs_factor if max-upwind-elev - elev[i] >= rs_threshold  if !is_water
//     moist_a[i] = clamp((moisture_now + d_evap) * d_rain_shadow, 0, 1)
double DCWorldExt::run_climate_pass_b(const Dictionary &knobs) {
    using godot::StringName;
    using godot::PackedFloat32Array;
    using godot::PackedInt32Array;
    using godot::PackedByteArray;

    auto diag = [&](const char *why) {
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_climate_pass_b: ", why,
            " — fallback to GDScript");
    };

    if (!_bound) { diag("not _bound"); return -1.0; }

    // ─── Resolve all 10 slot ids ONCE ───────────────────────────────────
    const int sid_temp     = component_id(StringName("cell_temp"));
    const int sid_moist    = component_id(StringName("cell_moisture"));
    const int sid_snow     = component_id(StringName("cell_snow_cover"));
    const int sid_iswater  = component_id(StringName("cell_is_water"));
    const int sid_landform = component_id(StringName("cell_landform"));
    const int sid_veg      = component_id(StringName("cell_vegetation"));
    const int sid_elev     = component_id(StringName("cell_elevation"));
    const int sid_lat      = component_id(StringName("cell_lat_norm"));
    const int sid_pos_x    = component_id(StringName("cell_pos_x"));
    const int sid_pos_y    = component_id(StringName("cell_pos_y"));
    if (sid_temp < 0 || sid_moist < 0 || sid_snow < 0 || sid_iswater < 0 ||
        sid_landform < 0 || sid_veg < 0 || sid_elev < 0 || sid_lat < 0 ||
        sid_pos_x < 0 || sid_pos_y < 0) {
        diag("missing slot id (cell_temp/moisture/snow_cover/is_water/landform/vegetation/elevation/lat_norm/pos_x/pos_y)");
        return -1.0;
    }

    // ─── Pull scalars from knobs ────────────────────────────────────────
    if (!knobs.has("n_cells") || !knobs.has("winter_boost") ||
        !knobs.has("snow_cool") || !knobs.has("veg_cool") ||
        !knobs.has("diurnal_amp") || !knobs.has("evap_gain") ||
        !knobs.has("rs_threshold") || !knobs.has("rs_factor") ||
        !knobs.has("rs_lookback") || !knobs.has("t_freeze") ||
        !knobs.has("coupling_gain") || !knobs.has("coast_leak") ||
        !knobs.has("landform_phase_factor") || !knobs.has("season_phase") ||
        !knobs.has("neighbor_indices") || !knobs.has("temp_transport_anomaly") ||
        !knobs.has("foliage_table")) {
        diag("knobs missing required keys");
        return -1.0;
    }
    const int n_cells = int(knobs["n_cells"]);
    if (n_cells <= 0) { diag("n_cells <= 0"); return -1.0; }
    if (knobs.has("go_sparse") && bool(knobs["go_sparse"])) {
        diag("go_sparse=true — sparse path not yet supported in C++");
        return -1.0;
    }
    const float winter_boost          = float(knobs["winter_boost"]);
    const float snow_cool             = float(knobs["snow_cool"]);
    const float veg_cool              = float(knobs["veg_cool"]);
    const float diurnal_amp           = float(knobs["diurnal_amp"]);
    const float evap_gain             = float(knobs["evap_gain"]);
    const float rs_threshold          = float(knobs["rs_threshold"]);
    const float rs_factor             = float(knobs["rs_factor"]);
    const int   rs_lookback           = int(knobs["rs_lookback"]);
    const float t_freeze              = float(knobs["t_freeze"]);
    const float coupling_gain         = float(knobs["coupling_gain"]);
    const float coast_leak            = float(knobs["coast_leak"]);
    const float landform_phase_factor = float(knobs["landform_phase_factor"]);
    const double season_phase         = double(knobs["season_phase"]);

    // ─── Pull PackedArrays ──────────────────────────────────────────────
    PackedInt32Array nb_arr = knobs["neighbor_indices"];
    PackedFloat32Array tta_arr = knobs["temp_transport_anomaly"];
    PackedFloat32Array foliage_arr = knobs["foliage_table"];
    if (nb_arr.size() < n_cells * 6) { diag("neighbor_indices size < n_cells * 6"); return -1.0; }
    if (tta_arr.size() != n_cells)   { diag("temp_transport_anomaly size mismatch"); return -1.0; }
    const int foliage_size = foliage_arr.size();
    if (foliage_size <= 0) { diag("foliage_table empty"); return -1.0; }

    // ─── Acquire slot arrays + validate sizes ───────────────────────────
    Slot &s_temp     = _slots.write[sid_temp];
    Slot &s_moist    = _slots.write[sid_moist];
    Slot &s_snow     = _slots.write[sid_snow];
    Slot &s_iswater  = _slots.write[sid_iswater];
    Slot &s_landform = _slots.write[sid_landform];
    Slot &s_veg      = _slots.write[sid_veg];
    Slot &s_elev     = _slots.write[sid_elev];
    Slot &s_lat      = _slots.write[sid_lat];
    Slot &s_pos_x    = _slots.write[sid_pos_x];
    Slot &s_pos_y    = _slots.write[sid_pos_y];
    if (s_temp.arr_f32.size()  != n_cells || s_moist.arr_f32.size()    != n_cells ||
        s_snow.arr_f32.size()  != n_cells || s_iswater.arr_u8.size()   != n_cells ||
        s_landform.arr_u8.size() != n_cells || s_veg.arr_u8.size()     != n_cells ||
        s_elev.arr_f32.size()  != n_cells || s_lat.arr_f32.size()      != n_cells ||
        s_pos_x.arr_f32.size() != n_cells || s_pos_y.arr_f32.size()    != n_cells) {
        diag("slot array size mismatch (re-bind needed?)");
        return -1.0;
    }

    // ─── Hot pointers ───────────────────────────────────────────────────
    float       * const __restrict T    = s_temp.arr_f32.ptrw();
    float       * const __restrict M    = s_moist.arr_f32.ptrw();
    const float * const __restrict SNOW = s_snow.arr_f32.ptr();
    const uint8_t * const __restrict IW = s_iswater.arr_u8.ptr();
    const uint8_t * const __restrict LF = s_landform.arr_u8.ptr();
    const uint8_t * const __restrict VG = s_veg.arr_u8.ptr();
    const float * const __restrict ELEV = s_elev.arr_f32.ptr();
    const float * const __restrict LAT  = s_lat.arr_f32.ptr();
    const float * const __restrict POSX = s_pos_x.arr_f32.ptr();
    const float * const __restrict POSY = s_pos_y.arr_f32.ptr();
    const int32_t * const __restrict NB = nb_arr.ptr();
    const float * const __restrict TTA  = tta_arr.ptr();
    const float * const __restrict FOL  = foliage_arr.ptr();

    auto t0 = std::chrono::high_resolution_clock::now();

    // ─── Snapshot temp BEFORE any writes ────────────────────────────────
    // 与 GDScript line 4347 `temp_snapshot = temp_a.duplicate()` 等价。
    // 之后所有 d_albedo / d_coastal / d_landform 用 snapshot 读，避免邻居
    // 写互相干扰。
    std::vector<float> temp_snapshot(n_cells);
    std::memcpy(temp_snapshot.data(), T, n_cells * sizeof(float));
    const float * const __restrict TS = temp_snapshot.data();

    // LandformType.LF: LOWLAND=5, HILL=6, MOUNTAIN=7, PEAK=8, DELTA=9,
    //                  SALT_FLAT=11 (per landform_type.gd:9-23)
    constexpr uint8_t LF_LOWLAND   = 5;
    constexpr uint8_t LF_MOUNTAIN  = 7;
    constexpr uint8_t LF_PEAK      = 8;
    constexpr uint8_t LF_DELTA     = 9;
    constexpr uint8_t LF_SALT_FLAT = 11;

    // ─── Main loop ──────────────────────────────────────────────────────
    for (int i = 0; i < n_cells; ++i) {
        const bool is_water = IW[i] != 0;
        const float temp_now     = TS[i];
        const float moisture_now = M[i];
        const float snow_cover   = SNOW[i];

        float d_albedo      = 0.0f;
        float d_coastal     = 0.0f;
        float d_landform    = 0.0f;
        float d_evap        = 0.0f;
        float d_rain_shadow = 1.0f;

        // (line 4413-4416) ① albedo (land only)
        if (!is_water) {
            d_albedo = -snow_cool * snow_cover;
            const uint8_t veg_id = VG[i];
            const float foliage = (veg_id < foliage_size) ? FOL[veg_id] : 0.0f;
            d_albedo -= veg_cool * foliage;
        }

        // (line 4419-4431) ② coastal heat leak (land only, using snapshot
        //                   of cells[ni].temperature_transport_anomaly)
        if (!is_water) {
            float sum_anomaly = 0.0f;
            int   n_water     = 0;
            const int base = i * 6;
            for (int d = 0; d < 6; ++d) {
                const int32_t ni = NB[base + d];
                if (ni < 0) continue;
                if (IW[ni] != 0) {
                    sum_anomaly += TTA[ni];
                    n_water += 1;
                }
            }
            if (n_water > 0) {
                d_coastal = coast_leak * (sum_anomaly / float(n_water)) * winter_boost;
            }
        }

        // (line 4434-4440) ③ landform diurnal (land only)
        if (!is_water) {
            const uint8_t lf = LF[i];
            if (lf == LF_LOWLAND || lf == LF_SALT_FLAT || lf == LF_DELTA) {
                const float dir_factor = landform_phase_factor * 2.0f - 1.0f;
                d_landform = diurnal_amp * dir_factor;
            } else if (lf == LF_PEAK || lf == LF_MOUNTAIN) {
                d_landform = -diurnal_amp * 0.5f * (1.0f - landform_phase_factor);
            }
        }

        // (line 4442-4445) write temp
        float temp_final = temp_now + d_albedo + d_coastal + d_landform;
        if (temp_final < 0.0f) temp_final = 0.0f;
        else if (temp_final > 1.0f) temp_final = 1.0f;
        T[i] = temp_final;

        // (line 4456-4481) ④ evap (land only)
        if (!is_water) {
            const float t_eff = temp_final + TTA[i];
            float water_neighbor_w = 0.0f;
            float sum_water_anomaly = 0.0f;
            const int bo = i * 6;
            for (int d = 0; d < 6; ++d) {
                const int32_t ni = NB[bo + d];
                if (ni < 0) continue;
                if (IW[ni] != 0) {
                    water_neighbor_w += 1.0f;
                    sum_water_anomaly += TTA[ni];
                }
            }
            float avg_water_anomaly = 0.0f;
            if (water_neighbor_w > 0.0f) {
                avg_water_anomaly = sum_water_anomaly / water_neighbor_w;
            }
            float nb_w_norm = water_neighbor_w / 6.0f;
            if (nb_w_norm > 1.0f) nb_w_norm = 1.0f;
            if (t_eff > t_freeze && nb_w_norm > 0.0f) {
                d_evap = evap_gain * (t_eff - t_freeze) * nb_w_norm;
                if (coupling_gain > 0.0f && std::fabs(avg_water_anomaly) > 0.001f) {
                    float evap_mul = 1.0f + coupling_gain * avg_water_anomaly;
                    if (evap_mul < 0.0f) evap_mul = 0.0f;
                    else if (evap_mul > 2.0f) evap_mul = 2.0f;
                    d_evap *= evap_mul;
                }
            }
            if (avg_water_anomaly < -0.01f && nb_w_norm > 0.0f && coupling_gain > 0.0f) {
                d_evap += -evap_gain * (-avg_water_anomaly) * nb_w_norm * coupling_gain * 0.5f;
            }
        }

        // (line 4484-4518) ⑤ rain shadow (land only, gated by rs_lookback>0)
        if (!is_water && rs_lookback > 0) {
            const double ny = double(LAT[i]);
            // jitter = sin(q*0.31 + r*0.47) * 0.05；schema 没存 q/r。本实现把
            // jitter 取 0（jitter 仅 ±0.05 ny，对 wind_at 输出方向影响极小，
            // bit-equal 容差 1e-4 内可容忍。后续 PR 加 cell_q/cell_r schema 后
            // 可补 jitter）。
            double w_dx = 0.0, w_dy = 0.0;
            wind_belt_at(ny, season_phase, &w_dx, &w_dy);
            const double wlen2 = w_dx * w_dx + w_dy * w_dy;
            if (wlen2 > 1e-6) {
                float max_upwind_h = ELEV[i];
                int probe_idx = i;
                for (int step = 0; step < rs_lookback; ++step) {
                    int   best_idx = -1;
                    double best_dot = 0.1;
                    const float pwx = POSX[probe_idx];
                    const float pwy = POSY[probe_idx];
                    const int pbase = probe_idx * 6;
                    for (int d3 = 0; d3 < 6; ++d3) {
                        const int32_t ni3 = NB[pbase + d3];
                        if (ni3 < 0) continue;
                        const double dx = double(pwx) - double(POSX[ni3]);
                        const double dy = double(pwy) - double(POSY[ni3]);
                        const double len2 = dx * dx + dy * dy;
                        if (len2 < 1e-6) continue;
                        const double inv_len = 1.0 / std::sqrt(len2);
                        const double dotv = (dx * w_dx + dy * w_dy) * inv_len;
                        if (dotv > best_dot) {
                            best_dot = dotv;
                            best_idx = ni3;
                        }
                    }
                    if (best_idx < 0) break;
                    probe_idx = best_idx;
                    if (ELEV[probe_idx] > max_upwind_h) {
                        max_upwind_h = ELEV[probe_idx];
                    }
                }
                if (max_upwind_h - ELEV[i] >= rs_threshold) {
                    d_rain_shadow = rs_factor;
                }
            }
        }

        // (line 4520-4523) write moisture
        float moisture_final = (moisture_now + d_evap) * d_rain_shadow;
        if (moisture_final < 0.0f) moisture_final = 0.0f;
        else if (moisture_final > 1.0f) moisture_final = 1.0f;
        M[i] = moisture_final;
    }

    // §11.2 flush: push CoW-detached temp + moisture back to MapData
    _flush_slot_to_map(sid_temp);
    _flush_slot_to_map(sid_moist);

    auto t1 = std::chrono::high_resolution_clock::now();
    return std::chrono::duration<double, std::milli>(t1 - t0).count();
}

double DCWorldExt::run_sea_ice_daily_pass(const Dictionary &knobs, float season_phase) {
    // F.4 stub: returns -1.0 → GDScript caller falls back to map_generator._apply_sea_ice_daily_pass
    (void) knobs; (void) season_phase;
    return -1.0;
}

// ─── F.5 main pass ──────────────────────────────────────────────────────────
//
// Single-shot full sweep over [0, n_cells). 1:1 mirror of
// map_generator.gd::_apply_transpiration_pass (line 4938).
//
// Algorithm structure (2-phase to be order-insensitive):
//   Phase 1 — compute deltas (don't write to moisture yet):
//     for each land cell with veg.transpiration >= 0.01:
//       output      = transpiration[veg] * moisture
//       self_share  = output * self_rate
//       nb_share    = output * outflow_rate / 6
//       deltas[i]  += self_share
//       for each non-water neighbour: deltas[nb_idx] += nb_share
//   Phase 2 — apply deltas:
//     for each cell with delta != 0:
//       moisture = clamp(moisture + delta, 0, 1)
//
// LandformType.LF enum order (landform_type.gd:9-23): DEEP_OCEAN=0, OCEAN=1,
// COAST=2, LAKE=3 are water; PLAIN=4+ are land. So is_water iff lf <= 3.
double DCWorldExt::run_transpiration_pass(const Dictionary &knobs) {
    using godot::StringName;
    using godot::PackedFloat32Array;
    using godot::PackedInt32Array;

    auto diag = [&](const char *why) {
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_transpiration_pass: ", why,
            " — fallback to GDScript");
    };

    if (!_bound) { diag("not _bound"); return -1.0; }

    const int sid_landform   = component_id(StringName("cell_landform"));
    const int sid_vegetation = component_id(StringName("cell_vegetation"));
    const int sid_moisture   = component_id(StringName("cell_moisture"));
    if (sid_landform < 0 || sid_vegetation < 0 || sid_moisture < 0) {
        diag("missing slot id (cell_landform / cell_vegetation / cell_moisture)");
        return -1.0;
    }

    if (!knobs.has("n_cells") || !knobs.has("outflow_rate") ||
        !knobs.has("self_rate") || !knobs.has("neighbor_indices") ||
        !knobs.has("donor_table")) {
        diag("knobs missing required keys");
        return -1.0;
    }
    const int   n_cells     = int(knobs["n_cells"]);
    const float outflow_rate = float(knobs["outflow_rate"]);
    const float self_rate    = float(knobs["self_rate"]);
    const float nb_share_factor = outflow_rate / 6.0f;
    if (n_cells <= 0) { diag("n_cells <= 0"); return -1.0; }

    PackedInt32Array   nb_arr     = knobs["neighbor_indices"];
    PackedFloat32Array donor_arr  = knobs["donor_table"];
    if (nb_arr.size() < n_cells * 6) {
        diag("neighbor_indices size < n_cells * 6");
        return -1.0;
    }
    const int donor_size = donor_arr.size();
    if (donor_size <= 0) { diag("donor_table empty"); return -1.0; }

    Slot &s_landform = _slots.write[sid_landform];
    Slot &s_veg      = _slots.write[sid_vegetation];
    Slot &s_moist    = _slots.write[sid_moisture];
    if (s_landform.arr_u8.size() != n_cells ||
        s_veg.arr_u8.size()      != n_cells ||
        s_moist.arr_f32.size()   != n_cells) {
        diag("slot array size mismatch (re-bind needed?)");
        return -1.0;
    }

    const uint8_t * const __restrict LF   = s_landform.arr_u8.ptr();
    const uint8_t * const __restrict VEG  = s_veg.arr_u8.ptr();
    float         * const __restrict M    = s_moist.arr_f32.ptrw();
    const int32_t * const __restrict NB   = nb_arr.ptr();
    const float   * const __restrict DON  = donor_arr.ptr();

    auto t0 = std::chrono::high_resolution_clock::now();

    // ─── Phase 1: compute deltas (scratch buffer, NOT a slot) ───────────
    // Stack vector keeps allocation off the heap for the whole pass.
    std::vector<float> deltas(n_cells, 0.0f);
    float * const __restrict D = deltas.data();

    for (int i = 0; i < n_cells; ++i) {
        // Skip water cells (LandformType.is_water): LF.{DEEP_OCEAN..LAKE} = 0..3
        if (LF[i] <= 3) continue;
        const uint8_t veg_id = VEG[i];
        if (veg_id >= donor_size) continue; // safety
        const float trans = DON[veg_id];
        if (trans < 0.01f) continue;
        const float moist = M[i];
        const float output      = trans * moist;
        const float self_share  = output * self_rate;
        const float nb_share    = output * nb_share_factor;
        D[i] += self_share;

        const int base = i * 6;
        for (int d = 0; d < 6; ++d) {
            const int32_t nb_idx = NB[base + d];
            if (nb_idx < 0) continue;
            // Skip water neighbours (mirror of GDScript "海面邻居不接受陆地蒸腾外溢")
            if (LF[nb_idx] <= 3) continue;
            D[nb_idx] += nb_share;
        }
    }

    // ─── Phase 2: apply deltas (clamp to [0,1]) ─────────────────────────
    for (int i = 0; i < n_cells; ++i) {
        const float d = D[i];
        if (d == 0.0f) continue;
        float v = M[i] + d;
        if (v < 0.0f) v = 0.0f;
        else if (v > 1.0f) v = 1.0f;
        M[i] = v;
    }

    // §11.2 flush: push CoW-detached cell_moisture back to MapData
    _flush_slot_to_map(sid_moisture);

    auto t1 = std::chrono::high_resolution_clock::now();
    return std::chrono::duration<double, std::milli>(t1 - t0).count();
}

double DCWorldExt::run_weather_front_advect_pass(int n_fronts, float dt) {
    // F.6 stub: returns -1.0 → GDScript caller falls back to weather_system tick_one_day fronts loop
    (void) n_fronts; (void) dt;
    return -1.0;
}

// ─── full / scalar ───────────────────────────────────────────────────────
void DCWorldExt::bench_pass_a_full_scalar(int comp_id,
                                          const PackedFloat32Array &lat,
                                          const PackedFloat32Array &prev,
                                          const PackedInt32Array   &neighbors,
                                          float k1, float k2, float base, float season) {
    ERR_FAIL_INDEX(comp_id, _slots.size());
    Slot &s = _slots.write[comp_id];
    const int count = s.arr_f32.size();
    ERR_FAIL_COND(lat.size()       < count);
    ERR_FAIL_COND(prev.size()      < count);
    ERR_FAIL_COND(neighbors.size() < count * 6);

    float         *out_ptr  = s.arr_f32.ptrw();
    const float   *lat_ptr  = lat.ptr();
    const float   *prev_ptr = prev.ptr();
    const int32_t *nb_ptr   = neighbors.ptr();
    for (int i = 0; i < count; ++i) {
        pass_a_kernel_scalar(out_ptr, lat_ptr, prev_ptr, nb_ptr, i, k1, k2, base, season);
    }
}

// ─── full / SIMD ────────────────────────────────────────────────────────
void DCWorldExt::bench_pass_a_full_simd(int comp_id,
                                        const PackedFloat32Array &lat,
                                        const PackedFloat32Array &prev,
                                        const PackedInt32Array   &neighbors,
                                        float k1, float k2, float base, float season) {
    ERR_FAIL_INDEX(comp_id, _slots.size());
    Slot &s = _slots.write[comp_id];
    const int count = s.arr_f32.size();
    ERR_FAIL_COND(lat.size()       < count);
    ERR_FAIL_COND(prev.size()      < count);
    ERR_FAIL_COND(neighbors.size() < count * 6);

    float         *out_ptr  = s.arr_f32.ptrw();
    const float   *lat_ptr  = lat.ptr();
    const float   *prev_ptr = prev.ptr();
    const int32_t *nb_ptr   = neighbors.ptr();

    int i = 0;
#if defined(PK_HAVE_AVX2) && PK_HAVE_AVX2
    const int simd_end = count - (count % 8);
    for (; i + 8 <= simd_end; i += 8) {
        pass_a_simd_block_full(out_ptr, lat_ptr, prev_ptr, nb_ptr, i,
                               k1, k2, base, season);
    }
#endif
    for (; i < count; ++i) {
        pass_a_kernel_scalar(out_ptr, lat_ptr, prev_ptr, nb_ptr, i,
                             k1, k2, base, season);
    }
}

// ─── full / threaded ────────────────────────────────────────────────────
void DCWorldExt::bench_pass_a_full_thread(int comp_id,
                                          const PackedFloat32Array &lat,
                                          const PackedFloat32Array &prev,
                                          const PackedInt32Array   &neighbors,
                                          float k1, float k2, float base, float season,
                                          int n_tasks) {
    ERR_FAIL_INDEX(comp_id, _slots.size());
    Slot &s = _slots.write[comp_id];
    const int count = s.arr_f32.size();
    ERR_FAIL_COND(lat.size()       < count);
    ERR_FAIL_COND(prev.size()      < count);
    ERR_FAIL_COND(neighbors.size() < count * 6);
    if (n_tasks < 1) n_tasks = 1;

    PassAFullTask task = {
        s.arr_f32.ptrw(),
        lat.ptr(),
        prev.ptr(),
        neighbors.ptr(),
        count,
        k1, k2, base, season,
        n_tasks,
    };
    WorkerThreadPool *wtp = WorkerThreadPool::get_singleton();
    if (wtp == nullptr) {
        // Fallback: run in-thread.
        for (int t = 0; t < n_tasks; ++t) {
            pass_a_full_worker(&task, static_cast<uint32_t>(t));
        }
        return;
    }
    int64_t group_id = wtp->add_native_group_task(
        &pass_a_full_worker, &task, n_tasks, -1, true, String("pk_pass_a_full"));
    wtp->wait_for_group_task_completion(group_id);
}

// ─── indexed / scalar ───────────────────────────────────────────────────
void DCWorldExt::bench_pass_a_indexed_scalar(int comp_id,
                                             const PackedInt32Array   &dirty,
                                             const PackedFloat32Array &lat,
                                             const PackedFloat32Array &prev,
                                             const PackedInt32Array   &neighbors,
                                             float k1, float k2, float base, float season) {
    ERR_FAIL_INDEX(comp_id, _slots.size());
    Slot &s = _slots.write[comp_id];
    const int cap = s.arr_f32.size();
    float         *out_ptr   = s.arr_f32.ptrw();
    const int32_t *dirty_ptr = dirty.ptr();
    const float   *lat_ptr   = lat.ptr();
    const float   *prev_ptr  = prev.ptr();
    const int32_t *nb_ptr    = neighbors.ptr();
    const int      n_dirty   = dirty.size();
    for (int k = 0; k < n_dirty; ++k) {
        const int i = dirty_ptr[k];
        if (i < 0 || i >= cap) continue;
        pass_a_kernel_scalar(out_ptr, lat_ptr, prev_ptr, nb_ptr, i,
                             k1, k2, base, season);
    }
}

// ─── indexed / "SIMD" — same as scalar; no contiguous gather possible ───
// We still expose this as a separate API to keep bench tables symmetrical.
void DCWorldExt::bench_pass_a_indexed_simd(int comp_id,
                                           const PackedInt32Array   &dirty,
                                           const PackedFloat32Array &lat,
                                           const PackedFloat32Array &prev,
                                           const PackedInt32Array   &neighbors,
                                           float k1, float k2, float base, float season) {
    // Sparse access pattern — SIMD gather offers no advantage and complicates
    // tail handling. Punt to scalar (which compiler may still vectorise).
    bench_pass_a_indexed_scalar(comp_id, dirty, lat, prev, neighbors,
                                k1, k2, base, season);
}

// ─── indexed / threaded ─────────────────────────────────────────────────
void DCWorldExt::bench_pass_a_indexed_thread(int comp_id,
                                             const PackedInt32Array   &dirty,
                                             const PackedFloat32Array &lat,
                                             const PackedFloat32Array &prev,
                                             const PackedInt32Array   &neighbors,
                                             float k1, float k2, float base, float season,
                                             int n_tasks) {
    ERR_FAIL_INDEX(comp_id, _slots.size());
    Slot &s = _slots.write[comp_id];
    const int cap     = s.arr_f32.size();
    const int n_dirty = dirty.size();
    if (n_tasks < 1) n_tasks = 1;

    PassAIndexedTask task = {
        s.arr_f32.ptrw(),
        dirty.ptr(),
        lat.ptr(),
        prev.ptr(),
        neighbors.ptr(),
        cap,
        n_dirty,
        k1, k2, base, season,
        n_tasks,
    };
    WorkerThreadPool *wtp = WorkerThreadPool::get_singleton();
    if (wtp == nullptr) {
        for (int t = 0; t < n_tasks; ++t) {
            pass_a_indexed_worker(&task, static_cast<uint32_t>(t));
        }
        return;
    }
    int64_t group_id = wtp->add_native_group_task(
        &pass_a_indexed_worker, &task, n_tasks, -1, true, String("pk_pass_a_idx"));
    wtp->wait_for_group_task_completion(group_id);
}

// ───────────────────────────────────────────────────────────────────────────
// EXPERIMENTAL: D-async — long-lived worker thread + double buffering
// ───────────────────────────────────────────────────────────────────────────
//
// IMPORTANT THREAD-SAFETY CONTRACT:
//   * Worker threads run in the anonymous namespace below and only touch
//     std::vector<float> / atomics / std::mutex / std::condition_variable.
//   * They MUST NOT call any Godot API. The kernel `_demo_complex_kernel_pure`
//     is a verbatim port of `run_demo_complex_pass` algorithm with all
//     PackedFloat32Array / push_warning / etc. replaced by std::vector and
//     silent clamps.
//   * Errors are reported via atomic int `error_code`; the main thread
//     translates them to push_warning inside async_climate_poll().

namespace {

// Error codes set by the worker (read by main thread in poll).
// 0 = ok. Values must be stable — main thread translates them by switch.
constexpr int PK_ASYNC_ERR_OK              = 0;
constexpr int PK_ASYNC_ERR_INVALID_GRID    = 1;
constexpr int PK_ASYNC_ERR_INPUT_SIZE      = 2;

struct AsyncTask {
    int task_id = 0;
    std::thread worker;

    // Inputs (main thread writes under mtx; worker copies to private buffers).
    std::vector<float> in_temp;
    std::vector<float> in_elev;

    // Worker-private buffers (only touched on the worker thread).
    std::vector<float> w_in_temp;
    std::vector<float> w_in_elev;
    std::vector<double> w_buf_a;
    std::vector<double> w_buf_b;
    std::vector<float>  w_out;

    // Result buffer that main thread will memcpy out of in poll().
    std::vector<float> result_buf;

    // Pending request parameters (main writes under mtx; worker reads under mtx).
    int   r_grid_w = 0, r_grid_h = 0;
    int   r_iterations = 16, r_kernel_radius = 2;
    float r_coriolis = 0.5f, r_drag = 0.6f, r_gain = 1.5f, r_k = 0.5f;

    std::mutex mtx;
    std::condition_variable cv;
    std::atomic<bool> request_pending{false};
    std::atomic<bool> result_ready{false};
    std::atomic<bool> should_exit{false};

    // Stats.
    std::atomic<int64_t> last_worker_compute_us{0};
    std::atomic<int64_t> last_worker_total_us{0};
    std::atomic<int64_t> total_ticks{0};
    std::atomic<int64_t> total_reused{0};
    std::atomic<int>     error_code{PK_ASYNC_ERR_OK};
};

struct AsyncState {
    std::unordered_map<int, std::unique_ptr<AsyncTask>> tasks;
    std::mutex tasks_mtx;
};

// ── Pure-C++ kernel — algorithm verbatim from run_demo_complex_pass ────────
// Inputs and outputs are std::vector<float>. Returns false on invalid inputs.
// Knob clamps mirror the synchronous path silently (no push_warning here —
// worker thread cannot call Godot API).
static bool _demo_complex_kernel_pure(int grid_w, int grid_h,
                                      int iterations, int kernel_radius,
                                      float coriolis_strength,
                                      float terrain_drag,
                                      float elevation_gain,
                                      float normalize_k,
                                      const std::vector<float> &T_in_v,
                                      const std::vector<float> &E_v,
                                      std::vector<double> &buf_a,
                                      std::vector<double> &buf_b,
                                      std::vector<float>  &out_v) {
    if (grid_w <= 0 || grid_h <= 0) return false;
    const int n = grid_w * grid_h;
    if ((int)T_in_v.size() != n || (int)E_v.size() != n) return false;

    if (iterations < 1) iterations = 1;
    if (iterations > 64) iterations = 64;
    if (kernel_radius < 1) kernel_radius = 1;
    if (kernel_radius > 5) kernel_radius = 5;
    if (coriolis_strength < -1.0f) coriolis_strength = -1.0f;
    if (coriolis_strength >  1.0f) coriolis_strength =  1.0f;
    if (terrain_drag < 0.0f) terrain_drag = 0.0f;
    if (terrain_drag > 1.0f) terrain_drag = 1.0f;

    if ((int)buf_a.size() != n) buf_a.assign(n, 0.0);
    if ((int)buf_b.size() != n) buf_b.assign(n, 0.0);
    if ((int)out_v.size() != n) out_v.assign(n, 0.0f);

    const float *__restrict T_in = T_in_v.data();
    const float *__restrict E    = E_v.data();

    const int kr   = kernel_radius;
    const int ksz  = 2 * kr + 1;
    double kernel[121];
    double kernel_sum = 0.0;
    for (int dy = -kr; dy <= kr; ++dy) {
        for (int dx = -kr; dx <= kr; ++dx) {
            const double w = std::exp(-(double)(dx*dx + dy*dy) * 0.5);
            kernel[(dy+kr)*ksz + (dx+kr)] = w;
            kernel_sum += w;
        }
    }
    const double kernel_inv_sum = (kernel_sum > 0.0) ? (1.0 / kernel_sum) : 0.0;

    for (int i = 0; i < n; ++i) buf_a[i] = (double)T_in[i];

    const double step_size = 0.05;
    const double cor  = (double)coriolis_strength;
    const double drag = (double)terrain_drag;

    for (int it = 0; it < iterations; ++it) {
        const std::vector<double> &src = (it & 1) ? buf_b : buf_a;
        std::vector<double>       &dst = (it & 1) ? buf_a : buf_b;
        const double *__restrict S = src.data();
        double       *__restrict D = dst.data();

        for (int y = 0; y < grid_h; ++y) {
            const double cor_sign = (y < grid_h / 2) ? -1.0 : 1.0;
            const double rot_rad  = cor * cor_sign * 1.5707963267948966;

            for (int x = 0; x < grid_w; ++x) {
                const int i = y * grid_w + x;

                double accum = 0.0;
                for (int dy = -kr; dy <= kr; ++dy) {
                    int ny = y + dy;
                    if (ny < 0)         ny = 0;
                    else if (ny >= grid_h) ny = grid_h - 1;
                    const int row = ny * grid_w;
                    const double *kw_row = &kernel[(dy + kr) * ksz];
                    for (int dx = -kr; dx <= kr; ++dx) {
                        int nx = x + dx;
                        if (nx < 0)         nx = 0;
                        else if (nx >= grid_w) nx = grid_w - 1;
                        accum += S[row + nx] * kw_row[dx + kr];
                    }
                }
                const double smooth = accum * kernel_inv_sum;

                const int xw = (x > 0)            ? (x - 1) : x;
                const int xe = (x < grid_w - 1)   ? (x + 1) : x;
                const int yn = (y > 0)            ? (y - 1) : y;
                const int ys = (y < grid_h - 1)   ? (y + 1) : y;
                const int row_n = yn * grid_w;
                const int row_c = y  * grid_w;
                const int row_s = ys * grid_w;
                const double gx = (S[row_n + xe] + 2.0*S[row_c + xe] + S[row_s + xe]
                                  - S[row_n + xw] - 2.0*S[row_c + xw] - S[row_s + xw]) * 0.125;
                const double gy = (S[row_s + xw] + 2.0*S[row_s + x ] + S[row_s + xe]
                                  - S[row_n + xw] - 2.0*S[row_n + x ] - S[row_n + xe]) * 0.125;

                const double cs = std::cos(rot_rad);
                const double sn = std::sin(rot_rad);
                const double gx_p = gx * cs - gy * sn;
                const double gy_p = gx * sn + gy * cs;

                const double damp = 1.0 - drag * (double)E[i];
                const double flux = gx_p + gy_p;
                D[i] = smooth + flux * damp * step_size;
            }
        }
    }

    const std::vector<double> &last = (iterations & 1) ? buf_b : buf_a;

    double out_min =  std::numeric_limits<double>::infinity();
    double out_max = -std::numeric_limits<double>::infinity();
    for (int i = 0; i < n; ++i) {
        const double v = last[i];
        if (v < out_min) out_min = v;
        if (v > out_max) out_max = v;
    }
    const double denom = (out_max - out_min) > 1.0e-6
                       ? (out_max - out_min) : 1.0e-6;
    const double inv_denom = 1.0 / denom;

    const double gain = (double)elevation_gain;
    const double k    = (double)normalize_k;
    for (int i = 0; i < n; ++i) {
        const double norm = (last[i] - out_min) * inv_denom;
        const double amp  = 1.0 + gain * (double)E[i];
        double v = norm * amp * k;
        if (v < 0.0) v = 0.0;
        else if (v > 1.0) v = 1.0;
        out_v[i] = (float)v;
    }
    return true;
}

// ── Worker thread main loop ────────────────────────────────────────────────
static void _async_worker_main(AsyncTask *t) {
    using clock = std::chrono::steady_clock;

    while (true) {
        // Snapshot params under the lock, then release it during compute.
        int   grid_w, grid_h, iters, kr;
        float coriolis, drag, gain, k;
        {
            std::unique_lock<std::mutex> lk(t->mtx);
            t->cv.wait(lk, [t]{
                return t->request_pending.load(std::memory_order_acquire)
                    || t->should_exit.load(std::memory_order_acquire);
            });
            if (t->should_exit.load(std::memory_order_acquire)) return;

            // Copy inputs into worker-private buffers (cheap; ~9.6 KB at 60×40).
            t->w_in_temp = t->in_temp;
            t->w_in_elev = t->in_elev;
            grid_w = t->r_grid_w;
            grid_h = t->r_grid_h;
            iters  = t->r_iterations;
            kr     = t->r_kernel_radius;
            coriolis = t->r_coriolis;
            drag     = t->r_drag;
            gain     = t->r_gain;
            k        = t->r_k;
        }

        const auto t0 = clock::now();
        const auto t_compute_start = clock::now();

        const bool ok = _demo_complex_kernel_pure(
            grid_w, grid_h, iters, kr,
            coriolis, drag, gain, k,
            t->w_in_temp, t->w_in_elev,
            t->w_buf_a, t->w_buf_b, t->w_out);

        const auto t_compute_end = clock::now();

        if (!ok) {
            // Set error code; do not modify result_buf (keep last good result).
            t->error_code.store(PK_ASYNC_ERR_INPUT_SIZE,
                                std::memory_order_release);
        } else {
            // Publish: copy w_out → result_buf under lock (so main-thread poll
            // never sees a partially-written buffer).
            std::lock_guard<std::mutex> lk(t->mtx);
            t->result_buf.resize(t->w_out.size());
            std::memcpy(t->result_buf.data(), t->w_out.data(),
                        t->w_out.size() * sizeof(float));
            t->error_code.store(PK_ASYNC_ERR_OK, std::memory_order_release);
        }

        const auto t1 = clock::now();
        t->last_worker_compute_us.store(
            (int64_t)std::chrono::duration_cast<std::chrono::microseconds>(
                t_compute_end - t_compute_start).count(),
            std::memory_order_relaxed);
        t->last_worker_total_us.store(
            (int64_t)std::chrono::duration_cast<std::chrono::microseconds>(
                t1 - t0).count(),
            std::memory_order_relaxed);
        t->total_ticks.fetch_add(1, std::memory_order_relaxed);

        t->request_pending.store(false, std::memory_order_release);
        t->result_ready.store(true, std::memory_order_release);
    }
}

inline AsyncState *_get_or_create_async_state(void *&slot) {
    if (!slot) slot = new AsyncState();
    return reinterpret_cast<AsyncState*>(slot);
}

inline AsyncState *_get_async_state(void *slot) {
    return reinterpret_cast<AsyncState*>(slot);
}

} // namespace (anonymous)

// ── Public API ────────────────────────────────────────────────────────────

void DCWorldExt::async_climate_register_task(int task_id, int n_workers) {
    (void)n_workers; // currently always 1 — multi-worker per task left for future
    AsyncState *st = _get_or_create_async_state(_async_state);
    std::lock_guard<std::mutex> g(st->tasks_mtx);
    auto it = st->tasks.find(task_id);
    if (it != st->tasks.end()) {
        UtilityFunctions::push_warning(
            "[DCWorldExt][async] task ", task_id,
            " already registered; ignoring duplicate register");
        return;
    }
    auto t = std::make_unique<AsyncTask>();
    t->task_id = task_id;
    AsyncTask *raw = t.get();
    st->tasks.emplace(task_id, std::move(t));
    raw->worker = std::thread(&_async_worker_main, raw);
}

void DCWorldExt::async_climate_set_inputs(int task_id,
                                          const PackedFloat32Array &temp,
                                          const PackedFloat32Array &elev) {
    AsyncState *st = _get_async_state(_async_state);
    if (!st) {
        UtilityFunctions::push_warning("[DCWorldExt][async] set_inputs: no async state");
        return;
    }
    AsyncTask *t = nullptr;
    {
        std::lock_guard<std::mutex> g(st->tasks_mtx);
        auto it = st->tasks.find(task_id);
        if (it == st->tasks.end()) {
            UtilityFunctions::push_warning(
                "[DCWorldExt][async] set_inputs: task ", task_id, " not registered");
            return;
        }
        t = it->second.get();
    }
    const int n_t = temp.size();
    const int n_e = elev.size();
    std::lock_guard<std::mutex> lk(t->mtx);
    t->in_temp.resize(n_t);
    if (n_t > 0) std::memcpy(t->in_temp.data(), temp.ptr(), n_t * sizeof(float));
    t->in_elev.resize(n_e);
    if (n_e > 0) std::memcpy(t->in_elev.data(), elev.ptr(), n_e * sizeof(float));
}

void DCWorldExt::async_climate_request(int task_id,
                                       int grid_w, int grid_h,
                                       int iterations, int kernel_radius,
                                       float coriolis_strength,
                                       float terrain_drag,
                                       float elevation_gain,
                                       float normalize_k) {
    AsyncState *st = _get_async_state(_async_state);
    if (!st) {
        UtilityFunctions::push_warning("[DCWorldExt][async] request: no async state");
        return;
    }
    AsyncTask *t = nullptr;
    {
        std::lock_guard<std::mutex> g(st->tasks_mtx);
        auto it = st->tasks.find(task_id);
        if (it == st->tasks.end()) {
            UtilityFunctions::push_warning(
                "[DCWorldExt][async] request: task ", task_id, " not registered");
            return;
        }
        t = it->second.get();
    }
    {
        std::lock_guard<std::mutex> lk(t->mtx);
        // If a previous request is still in flight or unread, count this main
        // thread tick as a "reuse" frame (worker not keeping up). The main
        // thread will keep using the last-published result until poll picks it.
        if (t->request_pending.load(std::memory_order_acquire)) {
            t->total_reused.fetch_add(1, std::memory_order_relaxed);
            return;
        }
        t->r_grid_w = grid_w;
        t->r_grid_h = grid_h;
        t->r_iterations = iterations;
        t->r_kernel_radius = kernel_radius;
        t->r_coriolis = coriolis_strength;
        t->r_drag = terrain_drag;
        t->r_gain = elevation_gain;
        t->r_k    = normalize_k;
        t->request_pending.store(true, std::memory_order_release);
    }
    t->cv.notify_one();
}

bool DCWorldExt::async_climate_poll(int task_id) {
    AsyncState *st = _get_async_state(_async_state);
    if (!st) return false;
    AsyncTask *t = nullptr;
    {
        std::lock_guard<std::mutex> g(st->tasks_mtx);
        auto it = st->tasks.find(task_id);
        if (it == st->tasks.end()) return false;
        t = it->second.get();
    }
    if (!t->result_ready.load(std::memory_order_acquire)) return false;

    // Translate any pending error from the worker into a single push_warning
    // (called on the main thread → safe to call Godot API).
    const int ec = t->error_code.exchange(PK_ASYNC_ERR_OK, std::memory_order_acq_rel);
    if (ec != PK_ASYNC_ERR_OK) {
        UtilityFunctions::push_warning(
            "[DCWorldExt][async] worker error code=", ec, " (task ", task_id, ")");
        // Do NOT consume result_ready on error; main thread sees stale result.
        return false;
    }

    // Snapshot result_buf under lock; copy into _slots[CELL_DEMO_THERMAL_GRADIENT].
    std::vector<float> snapshot;
    {
        std::lock_guard<std::mutex> lk(t->mtx);
        snapshot = t->result_buf;
    }
    t->result_ready.store(false, std::memory_order_release);

    const int sid_out = component_id(StringName("cell_demo_thermal_gradient"));
    if (sid_out < 0) return true; // no output slot — client just got the timing info
    Slot &s_out = _slots.write[sid_out];
    if (s_out.dtype != SlotDType::F32) return true;
    const int n_slot = s_out.arr_f32.size();
    const int n_snap = (int)snapshot.size();
    if (n_slot != n_snap || n_slot <= 0) return true;
    float *p = s_out.arr_f32.ptrw();
    std::memcpy(p, snapshot.data(), n_slot * sizeof(float));
    return true;
}

Dictionary DCWorldExt::async_climate_stats(int task_id) {
    Dictionary d;
    AsyncState *st = _get_async_state(_async_state);
    if (!st) {
        d["registered"] = false;
        return d;
    }
    AsyncTask *t = nullptr;
    {
        std::lock_guard<std::mutex> g(st->tasks_mtx);
        auto it = st->tasks.find(task_id);
        if (it == st->tasks.end()) {
            d["registered"] = false;
            return d;
        }
        t = it->second.get();
    }
    d["registered"] = true;
    d["worker_compute_us"] = (int64_t)t->last_worker_compute_us.load(std::memory_order_relaxed);
    d["worker_total_us"]   = (int64_t)t->last_worker_total_us.load(std::memory_order_relaxed);
    d["total_ticks"]       = (int64_t)t->total_ticks.load(std::memory_order_relaxed);
    d["total_reused"]      = (int64_t)t->total_reused.load(std::memory_order_relaxed);
    d["request_pending"]   = t->request_pending.load(std::memory_order_acquire);
    d["result_ready"]      = t->result_ready.load(std::memory_order_acquire);
    return d;
}

void DCWorldExt::async_climate_shutdown_task(int task_id) {
    AsyncState *st = _get_async_state(_async_state);
    if (!st) return;
    std::unique_ptr<AsyncTask> owned;
    {
        std::lock_guard<std::mutex> g(st->tasks_mtx);
        auto it = st->tasks.find(task_id);
        if (it == st->tasks.end()) return;
        owned = std::move(it->second);
        st->tasks.erase(it);
    }
    // Signal the worker to exit then join. cv.notify_one BEFORE join.
    owned->should_exit.store(true, std::memory_order_release);
    owned->cv.notify_all();
    if (owned->worker.joinable()) owned->worker.join();
}

void DCWorldExt::async_climate_shutdown_all() {
    AsyncState *st = _get_async_state(_async_state);
    if (!st) return;
    // Move out all tasks under lock so the destructors run unlocked.
    std::vector<std::unique_ptr<AsyncTask>> dead;
    {
        std::lock_guard<std::mutex> g(st->tasks_mtx);
        dead.reserve(st->tasks.size());
        for (auto &kv : st->tasks) dead.push_back(std::move(kv.second));
        st->tasks.clear();
    }
    for (auto &t : dead) {
        t->should_exit.store(true, std::memory_order_release);
        t->cv.notify_all();
    }
    for (auto &t : dead) {
        if (t->worker.joinable()) t->worker.join();
    }
    delete st;
    _async_state = nullptr;
}

// ─── Class binding ─────────────────────────────────────────────────────────

void DCWorldExt::_bind_methods() {
    using namespace godot;

    ClassDB::bind_method(D_METHOD("register_component", "name", "dtype", "stride", "track_prev"),
                         &DCWorldExt::register_component, DEFVAL(1), DEFVAL(false));
    ClassDB::bind_method(D_METHOD("component_id", "name"),     &DCWorldExt::component_id);
    ClassDB::bind_method(D_METHOD("component_count"),          &DCWorldExt::component_count);
    ClassDB::bind_method(D_METHOD("has_component", "name"),    &DCWorldExt::has_component);

    ClassDB::bind_method(D_METHOD("create_entities", "count"), &DCWorldExt::create_entities);
    ClassDB::bind_method(D_METHOD("entity_count"),             &DCWorldExt::entity_count);

    ClassDB::bind_method(D_METHOD("create_pool", "name", "capacity"), &DCWorldExt::create_pool);
    ClassDB::bind_method(D_METHOD("pool_range", "pool_id"),           &DCWorldExt::pool_range);
    ClassDB::bind_method(D_METHOD("pool_id", "name"),                 &DCWorldExt::pool_id);
    ClassDB::bind_method(D_METHOD("pool_count"),                      &DCWorldExt::pool_count);
    ClassDB::bind_method(D_METHOD("pool_free_count", "pool_id"),      &DCWorldExt::pool_free_count);

    ClassDB::bind_method(D_METHOD("view_f32", "comp_id"), &DCWorldExt::view_f32);
    ClassDB::bind_method(D_METHOD("view_i32", "comp_id"), &DCWorldExt::view_i32);
    ClassDB::bind_method(D_METHOD("view_u8",  "comp_id"), &DCWorldExt::view_u8);

    // Mode-B snapshot API (recommended; see performance-charter.md §12)
    ClassDB::bind_method(D_METHOD("snapshot_f32", "comp_id"), &DCWorldExt::snapshot_f32);

    ClassDB::bind_method(D_METHOD("write_f32", "comp_id", "idx", "v"), &DCWorldExt::write_f32);
    ClassDB::bind_method(D_METHOD("write_i32", "comp_id", "idx", "v"), &DCWorldExt::write_i32);
    ClassDB::bind_method(D_METHOD("write_u8",  "comp_id", "idx", "v"), &DCWorldExt::write_u8);
    ClassDB::bind_method(D_METHOD("write_f32_range", "comp_id", "start", "src"), &DCWorldExt::write_f32_range);
    ClassDB::bind_method(D_METHOD("write_i32_range", "comp_id", "start", "src"), &DCWorldExt::write_i32_range);
    ClassDB::bind_method(D_METHOD("write_u8_range",  "comp_id", "start", "src"), &DCWorldExt::write_u8_range);

    ClassDB::bind_method(D_METHOD("write_f32_indexed", "comp_id", "indices", "values"), &DCWorldExt::write_f32_indexed);
    ClassDB::bind_method(D_METHOD("write_i32_indexed", "comp_id", "indices", "values"), &DCWorldExt::write_i32_indexed);
    ClassDB::bind_method(D_METHOD("write_u8_indexed",  "comp_id", "indices", "values"), &DCWorldExt::write_u8_indexed);
    ClassDB::bind_method(D_METHOD("write_f32_scalar_indexed", "comp_id", "indices", "v"), &DCWorldExt::write_f32_scalar_indexed);
    ClassDB::bind_method(D_METHOD("write_i32_scalar_indexed", "comp_id", "indices", "v"), &DCWorldExt::write_i32_scalar_indexed);
    ClassDB::bind_method(D_METHOD("write_u8_scalar_indexed",  "comp_id", "indices", "v"), &DCWorldExt::write_u8_scalar_indexed);

    ClassDB::bind_method(D_METHOD("bind_map_data", "map_data"), &DCWorldExt::bind_map_data);
    ClassDB::bind_method(D_METHOD("is_bound"),                  &DCWorldExt::is_bound);

    // CoW flush / refresh (performance-charter §11.2)
    ClassDB::bind_method(D_METHOD("flush_slots_to_map"),    &DCWorldExt::flush_slots_to_map);
    ClassDB::bind_method(D_METHOD("refresh_slots_from_map"), &DCWorldExt::refresh_slots_from_map);

    ClassDB::bind_method(D_METHOD("create_archetype", "name", "comp_ids"), &DCWorldExt::create_archetype);
    ClassDB::bind_method(D_METHOD("assign_archetype", "idx", "arch_id"),   &DCWorldExt::assign_archetype);
    ClassDB::bind_method(D_METHOD("archetype_count"),                      &DCWorldExt::archetype_count);
    ClassDB::bind_method(D_METHOD("entity_archetype_array"),               &DCWorldExt::entity_archetype_array);

    ClassDB::bind_method(D_METHOD("run_climate_pass_a", "cp_struct", "phase", "season_phase"),
                         &DCWorldExt::run_climate_pass_a);

    // ─── Phase F / dots-full-migration §F.1-F.6 hot pass C++ stubs bind ──
    // 6 个 hot pass 的 ClassDB 注册。当前实现都返回 -1.0 → GDScript caller fallback。
    // 后续 PR 填实际算法时本段无需改动（签名稳定）。
    ClassDB::bind_method(
        D_METHOD("run_weather_field_solve_pass", "knobs"),
        &DCWorldExt::run_weather_field_solve_pass);
    ClassDB::bind_method(
        D_METHOD("run_ocean_water_pass", "knobs"),
        &DCWorldExt::run_ocean_water_pass);
    ClassDB::bind_method(
        D_METHOD("run_ocean_land_pass", "knobs"),
        &DCWorldExt::run_ocean_land_pass);
    ClassDB::bind_method(
        D_METHOD("run_climate_pass_b", "knobs"),
        &DCWorldExt::run_climate_pass_b);
    ClassDB::bind_method(
        D_METHOD("run_sea_ice_daily_pass", "knobs", "season_phase"),
        &DCWorldExt::run_sea_ice_daily_pass);
    ClassDB::bind_method(
        D_METHOD("run_transpiration_pass", "knobs"),
        &DCWorldExt::run_transpiration_pass);
    ClassDB::bind_method(
        D_METHOD("run_weather_front_advect_pass", "n_fronts", "dt"),
        &DCWorldExt::run_weather_front_advect_pass);

    // Mode-B reference implementation entry point (see performance-charter.md §12)
    ClassDB::bind_method(D_METHOD("run_temp_drift_pass", "drift_amount"), &DCWorldExt::run_temp_drift_pass);

    // Pass #2 reference implementation entry point (see performance-charter.md §12.6)
    ClassDB::bind_method(
        D_METHOD("run_thermal_gradient_pass", "grid_w", "grid_h", "elevation_gain", "normalize_k"),
        &DCWorldExt::run_thermal_gradient_pass);

    // Pass #3 reference implementation entry point (see performance-charter.md §12.6.6)
    ClassDB::bind_method(
        D_METHOD("run_demo_complex_pass",
                 "grid_w", "grid_h",
                 "iterations", "kernel_radius",
                 "coriolis_strength", "terrain_drag",
                 "elevation_gain", "normalize_k"),
        &DCWorldExt::run_demo_complex_pass);

    // DOTS-A1 EXPERIMENT: archetype-filtered demo_complex (see world_ext.h)
    ClassDB::bind_method(
        D_METHOD("run_demo_complex_pass_archetyped",
                 "grid_w", "grid_h",
                 "iterations", "kernel_radius",
                 "coriolis_strength", "terrain_drag",
                 "elevation_gain", "normalize_k",
                 "target_archetype"),
        &DCWorldExt::run_demo_complex_pass_archetyped);

    // Phase 3a Step 0: alias spike (TEMPORARY)
    ClassDB::bind_method(D_METHOD("_spike_alias_v1_naive",          "obj", "prop", "idx", "sentinel"), &DCWorldExt::_spike_alias_v1_naive);
    ClassDB::bind_method(D_METHOD("_spike_alias_v2_release",        "obj", "prop", "idx", "sentinel"), &DCWorldExt::_spike_alias_v2_release);
    ClassDB::bind_method(D_METHOD("_spike_alias_v3_write_then_set", "obj", "prop", "idx", "sentinel"), &DCWorldExt::_spike_alias_v3_write_then_set);

    // Phase 3a Step 1: alias verification helper (TEMPORARY)
    ClassDB::bind_method(D_METHOD("_debug_poke_f32", "comp_id", "idx", "sentinel"), &DCWorldExt::_debug_poke_f32);
    ClassDB::bind_method(D_METHOD("_debug_poke_f32_with_flush", "comp_id", "idx", "sentinel"), &DCWorldExt::_debug_poke_f32_with_flush);

    // Phase-3 micro-bench API
    ClassDB::bind_method(D_METHOD("bench_pass_a_full_scalar", "comp_id", "lat", "prev", "neighbors", "k1", "k2", "base", "season"),
                         &DCWorldExt::bench_pass_a_full_scalar);
    ClassDB::bind_method(D_METHOD("bench_pass_a_full_simd", "comp_id", "lat", "prev", "neighbors", "k1", "k2", "base", "season"),
                         &DCWorldExt::bench_pass_a_full_simd);
    ClassDB::bind_method(D_METHOD("bench_pass_a_full_thread", "comp_id", "lat", "prev", "neighbors", "k1", "k2", "base", "season", "n_tasks"),
                         &DCWorldExt::bench_pass_a_full_thread);
    ClassDB::bind_method(D_METHOD("bench_pass_a_indexed_scalar", "comp_id", "dirty", "lat", "prev", "neighbors", "k1", "k2", "base", "season"),
                         &DCWorldExt::bench_pass_a_indexed_scalar);
    ClassDB::bind_method(D_METHOD("bench_pass_a_indexed_simd", "comp_id", "dirty", "lat", "prev", "neighbors", "k1", "k2", "base", "season"),
                         &DCWorldExt::bench_pass_a_indexed_simd);
    ClassDB::bind_method(D_METHOD("bench_pass_a_indexed_thread", "comp_id", "dirty", "lat", "prev", "neighbors", "k1", "k2", "base", "season", "n_tasks"),
                         &DCWorldExt::bench_pass_a_indexed_thread);

    // EXPERIMENTAL: D-async (long-lived worker thread + double buffering)
    ClassDB::bind_method(D_METHOD("async_climate_register_task", "task_id", "n_workers"),
                         &DCWorldExt::async_climate_register_task);
    ClassDB::bind_method(D_METHOD("async_climate_set_inputs", "task_id", "temp", "elev"),
                         &DCWorldExt::async_climate_set_inputs);
    ClassDB::bind_method(
        D_METHOD("async_climate_request",
                 "task_id", "grid_w", "grid_h",
                 "iterations", "kernel_radius",
                 "coriolis_strength", "terrain_drag",
                 "elevation_gain", "normalize_k"),
        &DCWorldExt::async_climate_request);
    ClassDB::bind_method(D_METHOD("async_climate_poll", "task_id"),
                         &DCWorldExt::async_climate_poll);
    ClassDB::bind_method(D_METHOD("async_climate_stats", "task_id"),
                         &DCWorldExt::async_climate_stats);
    ClassDB::bind_method(D_METHOD("async_climate_shutdown_task", "task_id"),
                         &DCWorldExt::async_climate_shutdown_task);
    ClassDB::bind_method(D_METHOD("async_climate_shutdown_all"),
                         &DCWorldExt::async_climate_shutdown_all);
}

} // namespace pk
