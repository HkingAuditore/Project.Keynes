#include "world_ext.h"

#include "component_bind_table.gen.h"  // A1 / dots-migration-roadmap §3 — autogen by tools/codegen/gen_cpp_bind_table.py
#include "system_schedule.h"           // Phase C.1 — 静态 DAG 调度图
#include "parallel_dispatcher.h"       // Phase C.3a — 并行分发 helper（统一 5 个手写 _thread）

// MSVC 默认不定义 M_PI；必须在引入 <cmath> 之前打开 _USE_MATH_DEFINES。
// 双保险：仍未定义时手动兜底，避免某些编译器/PCH 顺序问题。
#ifndef _USE_MATH_DEFINES
#define _USE_MATH_DEFINES
#endif

#include <godot_cpp/classes/global_constants.hpp>
#include <godot_cpp/classes/fast_noise_lite.hpp>          // native world-gen 复刻：与 GDScript _init_noise 同一引擎噪声
#include <godot_cpp/classes/random_number_generator.hpp>  // native world-gen 复刻：与 GDScript _rng 同一引擎 PCG
#include <godot_cpp/classes/worker_thread_pool.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/error_macros.hpp>
#include <godot_cpp/core/math.hpp>
#include <godot_cpp/variant/char_string.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/variant/variant.hpp>

#include <algorithm>
#include <atomic>
#include <charconv>
#include <chrono>
#include <cmath>
#include <cstdio>
#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif
#include <condition_variable>
#include <cstring>
#include <limits>
#include <memory>
#include <mutex>
#include <functional>
#include <queue>
#include <string>
#include <thread>
#include <unordered_map>
#include <utility>
#include <vector>

#if defined(PK_HAVE_AVX2) && PK_HAVE_AVX2
#  include <immintrin.h>
#endif


#include "world_ext_internal.h"

namespace pk {

using namespace godot;


DCWorldExt::DCWorldExt() = default;
DCWorldExt::~DCWorldExt() {
    // EXPERIMENTAL: D-async — defensively join all worker threads before
    // _slots / _entity_count etc. tear down. Safe to call even if no
    // async_* method was ever invoked (shutdown_all is a no-op then).
    async_climate_shutdown_all();

    // Async Climate Round（plan §async-stage-1）：同 demo async，dtor 兜底
    // 调一次 shutdown 让 worker 安全 join。无 async round 时是 no-op。
    async_climate_round_shutdown();

    // Weather summary opaque state（plan/weather-hotpath-cpp）：lazy alloc 在
    // run_weather_summary_fronts_pass / snapshot 处；析构时直接 delete。
    // 实际类型 pk::WeatherSummaryState 在本 .cpp 文件下方定义于 pk 命名空间；
    // void* → cast → delete 走 std::vector 析构，无 OS 句柄需要释放。
    if (_summary_state != nullptr) {
        delete static_cast<WeatherSummaryState *>(_summary_state);
        _summary_state = nullptr;
    }
    if (_summary_state_snapshot != nullptr) {
        delete static_cast<WeatherSummaryState *>(_summary_state_snapshot);
        _summary_state_snapshot = nullptr;
    }

    // Atlas pipeline opaque state（plan/atlas-pipeline-cpp）：lazy alloc 在
    // run_atlas_pipeline_step 首次调用；析构走 PackedArray RAII，无 OS 句柄。
    if (_atlas_state != nullptr) {
        delete static_cast<AtlasPipelineState *>(_atlas_state);
        _atlas_state = nullptr;
    }

    // Season refresh round opaque state（Phase B+ 2026-05-21）：lazy alloc 在
    // start_season_round；析构走 PackedArray RAII（input_knobs / soil_moisture_arr /
    // veg_growth_pressure_arr 的 CoW refcount），无 OS 句柄。
    if (_season_round != nullptr) {
        delete static_cast<SeasonRoundState *>(_season_round);
        _season_round = nullptr;
    }
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

// B3b：snapshot_i32 / snapshot_u8 —— 与 snapshot_f32 1:1 镜像，给植被动力学
// streak（I32）以及后续 save/overlay/baker 路径（U8）补齐 Mode-B 只读快照。
PackedInt32Array DCWorldExt::snapshot_i32(int comp_id) {
    if (comp_id < 0 || comp_id >= _slots.size()) {
        return PackedInt32Array();
    }
    const Slot &s = _slots[comp_id];
    if (s.dtype != SlotDType::I32) {
        return PackedInt32Array();
    }
    return s.arr_i32;
}

PackedByteArray DCWorldExt::snapshot_u8(int comp_id) {
    if (comp_id < 0 || comp_id >= _slots.size()) {
        return PackedByteArray();
    }
    const Slot &s = _slots[comp_id];
    if (s.dtype != SlotDType::U8) {
        return PackedByteArray();
    }
    return s.arr_u8;
}

// ─── Mode-B per-cell read API（plan/3b-single-read-source）──────────────────
// HexCell facade 21 个 hot getter 的 read 源。直接读 _slots[comp_id].arr_*.ptr()
// 配整数索引；不分配、不装箱、不 CoW。每次调用 ~0.5-1μs（DCWorldExt 跨界开销主导，
// 内部读操作 < 10ns）。
//
// dtype 兼容性：F32 slot 同时接受 DT_F32 / DT_VEC2_F32 / DT_VEC3_F32（前两者
// 都把 arr_f32 作为底层 buffer——VEC2 cid 由调用方按 idx*2 / idx*2+1 索引）。
// 与 view_f32 / snapshot_f32 的 dtype 检查策略保持一致。
float DCWorldExt::read_f32(int comp_id, int idx) const {
    if (comp_id < 0 || comp_id >= _slots.size()) return 0.0f;
    const Slot &s = _slots[comp_id];
    if (s.dtype != SlotDType::F32) return 0.0f;
    if (idx < 0 || idx >= s.arr_f32.size()) return 0.0f;
    return s.arr_f32.ptr()[idx];
}

int32_t DCWorldExt::read_i32(int comp_id, int idx) const {
    if (comp_id < 0 || comp_id >= _slots.size()) return 0;
    const Slot &s = _slots[comp_id];
    if (s.dtype != SlotDType::I32) return 0;
    if (idx < 0 || idx >= s.arr_i32.size()) return 0;
    return s.arr_i32.ptr()[idx];
}

int DCWorldExt::read_u8(int comp_id, int idx) const {
    if (comp_id < 0 || comp_id >= _slots.size()) return 0;
    const Slot &s = _slots[comp_id];
    if (s.dtype != SlotDType::U8) return 0;
    if (idx < 0 || idx >= s.arr_u8.size()) return 0;
    return static_cast<int>(s.arr_u8.ptr()[idx]);
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

Dictionary DCWorldExt::configure_native_world(const Dictionary &knobs) {
    Dictionary out;
    _native_world_configured = false;
    _native_world_cell_count = 0;
    _native_daily_tick_count = 0;
    _native_fronts_snapshot.clear();
    _native_dirty_report.clear();
    _native_runtime_config.clear();

    if (!_bound || _map_data == nullptr) {
        out["rc"] = -1;
        out["reason"] = String("not_bound");
        return out;
    }

    _native_world_cell_count = int(knobs.get("cell_count", _entity_count));
    if (_native_world_cell_count <= 0) {
        _native_world_cell_count = _entity_count;
    }
    _native_daily_perf_target_ms = double(knobs.get("native_daily_perf_target_ms", 1.0));
    _native_world_configured = true;
    _native_runtime_config = knobs.duplicate(true);
    Array resident_keys;
    Array knob_keys = knobs.keys();
    for (int i = 0; i < knob_keys.size(); ++i) {
        resident_keys.append(knob_keys[i]);
    }
    _native_runtime_config["resident_config_keys"] = resident_keys;
    _native_runtime_config["resident_config_key_count"] = resident_keys.size();
    _native_runtime_config["configured_at_tick"] = _native_daily_tick_count;

    _native_dirty_report["atlas_dirty"] = false;
    _native_dirty_report["enum_atlas_dirty"] = false;
    _native_dirty_report["sea_ice_atlas_dirty"] = false;
    _native_dirty_report["dirty_cell_count"] = 0;
    _native_dirty_report["configured_cell_count"] = _native_world_cell_count;

    out["rc"] = 0;
    out["reason"] = String("configured");
    out["cell_count"] = _native_world_cell_count;
    out["component_count"] = component_count();
    out["entity_count"] = entity_count();
    out["native_daily_perf_target_ms"] = _native_daily_perf_target_ms;
    out["resident_config_keys"] = resident_keys;
    out["resident_config_key_count"] = resident_keys.size();
    return out;
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

void DCWorldExt::bind_dirty_world(godot::Object *dirty_world) {
    // sea-ice-snow-visual-fix-2026-06：从 GDScript 接收 DCWorld 句柄。
    // 之后 _flush_slot_to_map 末尾会 call("mark_dirty_all") 把 atlas pipeline
    // 的 dirty mask 信号补齐——C++ pass 用 _map_data->set() 直写 MapData，
    // 绕过 GDScript write_* 上的自动 _dirty_mark_*，atlas 4 通道因此跳过编码。
    _dirty_world = dirty_world;
}

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
            // sea-ice-snow-visual-fix-2026-06：通知 DCWorld 全 cell 脏，
            // 让 atlas pipeline `read_and_clear_dirty_mask` 在下个 stride 拿到信号。
            // 若 _dirty_world 未注入或 dirty_mask 关闭，mark_dirty_all 是 no-op。
            // v3 验证完成（2026-06-13）：dirty 路径正常工作，mark_dirty_all 每个 climate
            // pass 都被触发。诊断 print 已移除。
            // dirty-mark-batch-2026-06：原先每 flush 立即跨边界 call mark_dirty_all，
            // pass_a 16 slot flush = 16 次跨界开销 ~1.6-4.8ms。改为仅置 pending 标志，
            // 由 climate_daily_system 在 round 末尾调 flush_pending_mark_dirty_all()
            // 合并为 1 次跨界 call。atlas pipeline 在下个 stride 仍能拿到 dirty 信号。
            _pending_mark_dirty_all = true;
            return;
        }
    }
}

void DCWorldExt::flush_pending_mark_dirty_all() {
    // 主线程调用：把累积的 mark_dirty_all 合并 emit 一次。多次调用幂等。
    if (_pending_mark_dirty_all && _dirty_world) {
        _dirty_world->call(StringName("mark_dirty_all"));
    }
    _pending_mark_dirty_all = false;
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
    // sea-ice-snow-visual-fix-2026-06：批量 flush 末尾一次 mark dirty。
    // dirty-mark-batch-2026-06：本路径立即 emit 并清 pending，避免后续 round 末尾
    // 的 flush_pending_mark_dirty_all() 重复发布。
    if (_dirty_world) {
        _dirty_world->call(StringName("mark_dirty_all"));
    }
    _pending_mark_dirty_all = false;
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

void DCWorldExt::refresh_slots_from_map_keys(const PackedStringArray &slot_names) {
    if (!_map_data) return;
    for (int k = 0; k < slot_names.size(); ++k) {
        const StringName requested(slot_names[k]);
        const int sid = component_id(requested);
        if (sid < 0 || sid >= _slots.size()) continue;
        Slot &s = _slots.write[sid];
        for (int i = 0; i < BIND_TABLE_SIZE; ++i) {
            if (requested != StringName(BIND_TABLE[i].slot_name)) continue;
            Variant v = _map_data->get(StringName(BIND_TABLE[i].property_name));
            switch (s.dtype) {
                case SlotDType::F32: s.arr_f32 = v; break;
                case SlotDType::I32: s.arr_i32 = v; break;
                case SlotDType::U8:  s.arr_u8  = v; break;
            }
            break;
        }
    }
}

} // namespace pk
