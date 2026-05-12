#include "world_ext.h"

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

// Map of (slot StringName) → (MapData property StringName).
// Add new entries here when a new component is mirrored in MapData.
struct BindEntry {
    const char *slot_name;
    const char *property_name;
    SlotDType   dtype;
};

// NOTE: kept *small* on purpose — only the components that MapData actually
// owns. weather-front-level slots are NOT in this table; those are filled
// from C++/GDScript directly via the registry, not from MapData.
//
// ─── Phase 3a Step 2.0 ─────────────────────────────────────────────────────
// This table is a 1:1 mirror of the GDScript-side authoritative registration
// in DCWorld._bind_register_and_attach[_u8] (see scripts/data_core/world.gd
// lines 598-637). Whenever a new cell-level component is added on the
// GDScript side, mirror it here in the same order.
//
// Naming gotchas (caught during Step 2.0 audit):
//   * cell_snow_cover    -> snow_cover_arr     (NOT snow_arr — the GDScript
//                                               side renamed this and we
//                                               were silently no-binding it)
//   * cell_climate_dirty -> climate_dirty_mask (NOT climate_dirty_arr — same
//                                               reason)
//   * cell_sea_ice_frac  -> sea_ice_frac_arr   (component name has _frac
//                                               suffix; old "cell_sea_ice"
//                                               entry didn't match anything)
//   * cell_pos_x / cell_pos_y / cell_lat_norm map to cell_pos_x_arr /
//     cell_pos_y_arr / cell_lat_norm_arr (note the *cell_* prefix on the
//     MapData property — different from temp_arr / moisture_arr which have
//     no prefix).
//
// dtype rule (must match GDScript side _bind_register_and_attach[_u8]):
//   F32  → PackedFloat32Array
//   U8   → PackedByteArray  (any field that goes through _u8 helper)
//   I32  → currently NONE on the cell side (all enum-like fields use U8;
//          we keep the enum value here for future weather/front needs)
static const BindEntry BIND_TABLE[] = {
    // ─── Climate F32 (mirrors world.gd lines 598-618) ────────────────────
    {"cell_temp",                  "temp_arr",                  SlotDType::F32},
    {"cell_temp_baseline",         "temp_baseline_arr",         SlotDType::F32},
    {"cell_temp_30d",              "temp_30d_arr",              SlotDType::F32},
    {"cell_temp_365d",             "temp_365d_arr",             SlotDType::F32},
    {"cell_temp_anomaly",          "temp_anomaly_arr",          SlotDType::F32},
    {"cell_moisture",              "moisture_arr",              SlotDType::F32},
    {"cell_snow_cover",            "snow_cover_arr",            SlotDType::F32},
    {"cell_sea_ice_frac",          "sea_ice_frac_arr",          SlotDType::F32},
    {"cell_weather_intensity",     "weather_intensity_arr",     SlotDType::F32},
    {"cell_weather_cloud",         "weather_cloud_arr",         SlotDType::F32},
    {"cell_weather_precip",        "weather_precip_arr",        SlotDType::F32},
    {"cell_elevation",             "elevation_arr",             SlotDType::F32},
    {"cell_base_moisture",         "base_moisture_arr",         SlotDType::F32},
    {"cell_ocean_current_x",       "ocean_current_x_arr",       SlotDType::F32},
    {"cell_ocean_current_y",       "ocean_current_y_arr",       SlotDType::F32},
    {"cell_wind_x",                "wind_x_arr",                SlotDType::F32},
    {"cell_wind_y",                "wind_y_arr",                SlotDType::F32},
    {"cell_pos_x",                 "cell_pos_x_arr",            SlotDType::F32},
    {"cell_pos_y",                 "cell_pos_y_arr",            SlotDType::F32},
    {"cell_lat_norm",              "cell_lat_norm_arr",         SlotDType::F32},
    {"cell_temp_baseline_year",    "temp_baseline_year_arr",    SlotDType::F32},
    // ─── Climate U8 (mirrors world.gd lines 619-626) ─────────────────────
    {"cell_terrain",               "terrain_arr",               SlotDType::U8},
    {"cell_landform",              "landform_arr",              SlotDType::U8},
    {"cell_vegetation",            "vegetation_arr",            SlotDType::U8},
    {"cell_cover",                 "cover_arr",                 SlotDType::U8},
    {"cell_weather_type",          "weather_type_arr",          SlotDType::U8},
    {"cell_is_water",              "is_water_arr",              SlotDType::U8},
    {"cell_climate_dirty",         "climate_dirty_mask",        SlotDType::U8},
    {"cell_weather_dirty",         "weather_dirty_mask",        SlotDType::U8},
    // ─── Weather extras (mirrors world.gd lines 632-637) ─────────────────
    {"cell_weather_vapor",         "weather_vapor_arr",         SlotDType::F32},
    {"cell_weather_convergence",   "weather_convergence_arr",   SlotDType::F32},
    {"cell_weather_instability",   "weather_instability_arr",   SlotDType::F32},
    {"cell_weather_field_init",    "weather_field_init_arr",    SlotDType::U8},
    {"cell_air_mass_temp_anomaly", "air_mass_temp_anomaly_arr", SlotDType::F32},
    {"cell_has_river",             "has_river_arr",             SlotDType::U8},
    // ─── Phase 3a Step 2.1.a: Pass-A SoA fields (mirrors component_ids.gd) ──
    {"cell_ema_initialized",       "ema_initialized_arr",       SlotDType::U8},
    {"cell_temp_season_offset",    "temp_season_offset_arr",    SlotDType::F32},
    // ─── Reference-impl Pass #2: thermal_gradient_pass (demo-only) ──────
    // The MapData property `demo_thermal_gradient_arr` is only resized to N
    // when ClimateProfile.demo_thermal_gradient_enabled == true; otherwise
    // GDScript-side leaves it as size=0. The BIND_TABLE entry is harmless
    // either way: bind_map_data() above gracefully skips slots whose
    // property is NIL or empty (PackedFloat32Array of size 0 still binds,
    // and the pass itself bails out on size mismatch with grid_w*grid_h).
    {"cell_demo_thermal_gradient", "demo_thermal_gradient_arr", SlotDType::F32},
};

constexpr int BIND_TABLE_SIZE = sizeof(BIND_TABLE) / sizeof(BindEntry);

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

    ClassDB::bind_method(D_METHOD("create_archetype", "name", "comp_ids"), &DCWorldExt::create_archetype);
    ClassDB::bind_method(D_METHOD("assign_archetype", "idx", "arch_id"),   &DCWorldExt::assign_archetype);
    ClassDB::bind_method(D_METHOD("archetype_count"),                      &DCWorldExt::archetype_count);
    ClassDB::bind_method(D_METHOD("entity_archetype_array"),               &DCWorldExt::entity_archetype_array);

    ClassDB::bind_method(D_METHOD("run_climate_pass_a", "cp_struct", "phase", "season_phase"),
                         &DCWorldExt::run_climate_pass_a);

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
