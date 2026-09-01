#include "world_ext.h"

#include "component_bind_table.gen.h"  // A1 / dots-migration-roadmap §3 — autogen by tools/codegen/gen_cpp_bind_table.py
#include "system_schedule.h"           // Phase C.1 — 静态 DAG 调度图
#include "parallel_dispatcher.h"       // Phase C.3a — 并行分发 helper（统一 5 个手写 _thread）
#include "economy_runtime.h"           // Independent ECONOMY_GRAPH authority
#include "economy_csv_recorder.h"      // Debug-only committed CSV writer
#include "country_runtime.h"           // Independent COUNTRY_GRAPH authority
#include "modifier_runtime.h"          // Shared four-domain Modifier authority
#include "trigger_runtime.h"           // Generic event-to-effect trigger authority
#include "effect_runtime.h"            // Generic effect plan/transaction authority
#include "ideology_runtime.h"          // Country-scoped ideology authority

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

// Defined in world_ext_bio.cpp where the opaque slice state is complete.
void destroy_bio_occupancy_slice_state(void *state);
void destroy_bio_native_config_state(void *state);
void destroy_vision_research_state(void *state);

using namespace godot;


DCWorldExt::DCWorldExt() = default;
DCWorldExt::~DCWorldExt() {
    if (_ideology_runtime != nullptr) {
        delete static_cast<NativeIdeologyRuntime *>(_ideology_runtime);
        _ideology_runtime = nullptr;
    }
    if (_trigger_runtime != nullptr) {
        delete static_cast<TriggerRuntime *>(_trigger_runtime);
        _trigger_runtime = nullptr;
    }
    if (_effect_runtime != nullptr) {
        delete static_cast<EffectRuntime *>(_effect_runtime);
        _effect_runtime = nullptr;
    }
    if (_modifier_runtime != nullptr) {
        delete static_cast<ModifierRuntime *>(_modifier_runtime);
        _modifier_runtime = nullptr;
    }
    if (_economy_csv_recorder != nullptr) {
        delete static_cast<EconomyCsvRecorder *>(_economy_csv_recorder);
        _economy_csv_recorder = nullptr;
    }
    if (_economy_runtime != nullptr) {
        delete static_cast<NativeEconomyRuntime *>(_economy_runtime);
        _economy_runtime = nullptr;
    }
    if (_country_runtime != nullptr) {
        delete static_cast<NativeCountryRuntime *>(_country_runtime);
        _country_runtime = nullptr;
    }
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
    if (_bio_occupancy_slice_state != nullptr) {
        destroy_bio_occupancy_slice_state(_bio_occupancy_slice_state);
        _bio_occupancy_slice_state = nullptr;
    }
    if (_bio_native_config_state != nullptr) {
        destroy_bio_native_config_state(_bio_native_config_state);
        _bio_native_config_state = nullptr;
    }
    if (_vision_research_state != nullptr) {
        destroy_vision_research_state(_vision_research_state);
        _vision_research_state = nullptr;
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
    _native_daily_visual_commit_pending = false;
    _pending_mark_dirty_all = false;
    _pending_visual_dirty_mask = PackedByteArray();
    _pending_visual_dirty_count = 0;
    _pending_visual_dirty_dense = false;
    _economy_resource_slot_resident.clear();
    // A newly bound MapData may have a different restored canal mask even
    // when the DCWorldExt object itself is reused. Force one sparse topology
    // compilation before the next hydrology pass.
    _canal_hydrology_compiled_generation = std::numeric_limits<uint64_t>::max();
    _canal_hydrology_compiled_cell_count = -1;
    _canal_hydrology_cells.clear();
    _canal_hydrology_source_kind.clear();
    _canal_hydrology_strength.clear();
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
    _native_daily_slice_active = false;
    _native_daily_visual_commit_pending = false;
    _pending_mark_dirty_all = false;
    _pending_visual_dirty_mask = PackedByteArray();
    _pending_visual_dirty_count = 0;
    _pending_visual_dirty_dense = false;
    _economy_resource_slot_resident.clear();
    _native_fronts_snapshot.clear();
    _native_dirty_report.clear();
    _native_runtime_config.clear();
    _phys_wind_coast_valid = false;
    _phys_wind_coast_last_hit = false;
    _phys_monsoon_thermal.clear();
    _enso_cache_valid = false;
    _enso_cache_last_hit = false;
    _enso_basin_id.clear();
    _enso_eastness.clear();
    _enso_prev_forcing.clear();
    _enso_members.clear();
    _enso_basins.clear();
    _enso_states.clear();
    _enso_wind_sum.clear();
    _enso_wind_count.clear();
    _cyclone_perturbations.clear();
    _cyclone_force_tag.clear();
    _cyclone_visit_tag.clear();
    _cyclone_force_x.clear();
    _cyclone_force_y.clear();
    _cyclone_force_lift.clear();
    _cyclone_force_generation = 0;
    _cyclone_next_stable_id = 1;
    _cyclone_last_touched_cells = 0;
    _cyclone_total_genesis = 0;
    _cyclone_total_decay = 0;
    _climate_modes_pending_restore.clear();

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
    // seam-advection-fix：环绕周期常驻。GDScript 直接给 wrap_period_x；缺省时用
    // map_width·√3 重算；都拿不到则留 0 → 平流内核退化为裸差分（旧行为，接缝伪影
    // 仍在，但不改变既有调用方语义）。
    //
    // 单位是 size=1.0 的单位六边形空间，**不含 hex_size**：内核比较的是 cell_pos_x
    // slot，而它由 map_data.gd 用 cube_to_world(q, r, 1.0) 填充，列距恰为 √3/2。
    double cfg_wrap_period_x = double(knobs.get("wrap_period_x", 0.0));
    if (!(cfg_wrap_period_x > 0.0)) {
        const int cfg_map_width = int(knobs.get("map_width", 0));
        if (cfg_map_width > 0) {
            cfg_wrap_period_x = double(cfg_map_width) * 1.7320508075688772;
        }
    }
    _native_wrap_period_x = (cfg_wrap_period_x > 0.0) ? cfg_wrap_period_x : 0.0;
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
    out["wrap_period_x"] = _native_wrap_period_x;
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

static bool pk_slot_affects_visual_dirty(const godot::StringName &slot_name) {
    const godot::String s(slot_name);
    return s.begins_with("cell_temp") ||
           s.begins_with("cell_moisture") ||
           s.begins_with("cell_base_moisture") ||
           s.begins_with("cell_snow") ||
           s.begins_with("cell_sea_ice") ||
           s.begins_with("cell_terrain") ||
           s.begins_with("cell_landform") ||
           s.begins_with("cell_vegetation") ||
           s.begins_with("cell_cover") ||
           s == godot::String("cell_canal_edge_mask") ||
           s.begins_with("cell_weather") ||
           s.begins_with("cell_ocean_thermal") ||
           s.begins_with("cell_local_thermal") ||
           s == godot::String("cell_thermal_energy");
}

void DCWorldExt::bind_dirty_world(godot::Object *dirty_world) {
    _dirty_world = dirty_world;
}

static int pk_visual_dirty_dense_threshold(int cell_count) {
    if (cell_count <= 0) return 0;
    const int ratio_threshold = (cell_count + 3) / 4;
    return std::min(cell_count, std::max(64, ratio_threshold));
}

int DCWorldExt::_bind_index_for_slot(int comp_id) {
    if (comp_id < 0 || comp_id >= _slots.size()) return -1;
    if (int(_slot_bind_index_cache.size()) <= comp_id)
        _slot_bind_index_cache.resize(size_t(_slots.size()), int16_t{-2});
    int16_t &cached = _slot_bind_index_cache[size_t(comp_id)];
    if (cached != -2) return int(cached);
    const StringName &slot_name = _slots[comp_id].name;
    cached = -1;
    for (int i = 0; i < BIND_TABLE_SIZE; ++i) {
        if (slot_name == StringName(BIND_TABLE[i].slot_name)) {
            cached = int16_t(i);
            break;
        }
    }
    return int(cached);
}

bool DCWorldExt::_slot_is_visual_dirty(int comp_id) {
    if (comp_id < 0 || comp_id >= _slots.size()) return false;
    if (int(_slot_visual_dirty_cache.size()) <= comp_id)
        _slot_visual_dirty_cache.resize(size_t(_slots.size()), uint8_t{0});
    uint8_t &cached = _slot_visual_dirty_cache[size_t(comp_id)];
    if (cached == 0)
        cached = pk_slot_affects_visual_dirty(_slots[comp_id].name) ? uint8_t{2} : uint8_t{1};
    return cached == 2;
}

void DCWorldExt::_flush_slot_to_map(int comp_id) {
    if (!_map_data || comp_id < 0 || comp_id >= _slots.size()) return;
    const Slot &s = _slots[comp_id];
    {
        const int bind_index = _bind_index_for_slot(comp_id);
        if (bind_index >= 0) {
            const int i = bind_index;
            const StringName prop_name(BIND_TABLE[i].property_name);
            const bool visual_slot = _slot_is_visual_dirty(comp_id);
            // 非视觉 slot 不做 diff，previous 也就无人消费。它是一次
            // Object::get + Variant 构造 + PackedArray 引用计数往返。
            const Variant previous = visual_slot ? _map_data->get(prop_name) : Variant();
            bool any_visual_dirty = false;
            int cell_limit = _native_world_cell_count;
            if (cell_limit <= 0) {
                switch (s.dtype) {
                    case SlotDType::F32: cell_limit = s.arr_f32.size(); break;
                    case SlotDType::I32: cell_limit = s.arr_i32.size(); break;
                    case SlotDType::U8:  cell_limit = s.arr_u8.size(); break;
                }
            }
            if (visual_slot && cell_limit > 0 &&
                    _pending_visual_dirty_mask.size() != cell_limit) {
                _pending_visual_dirty_mask.resize(cell_limit);
            }
            auto mark_changed = [&](int idx) {
                if (!visual_slot || _pending_visual_dirty_dense ||
                        idx < 0 || idx >= cell_limit) return;
                if (_pending_visual_dirty_mask[idx] != 0) {
                    any_visual_dirty = true;
                    return;
                }
                _pending_visual_dirty_mask.set(idx, uint8_t(1));
                ++_pending_visual_dirty_count;
                any_visual_dirty = true;
                const int dense_threshold = pk_visual_dirty_dense_threshold(cell_limit);
                if (dense_threshold > 0 && _pending_visual_dirty_count >= dense_threshold) {
                    _pending_visual_dirty_dense = true;
                }
            };
            switch (s.dtype) {
                case SlotDType::F32: {
                    if (visual_slot && previous.get_type() == Variant::PACKED_FLOAT32_ARRAY) {
                        const PackedFloat32Array old_values = previous;
                        const int n = std::min(cell_limit,
                                std::min(int(old_values.size()), int(s.arr_f32.size())));
                        for (int idx = 0; idx < n && !_pending_visual_dirty_dense; ++idx) {
                            if (old_values[idx] != s.arr_f32[idx]) mark_changed(idx);
                        }
                        for (int idx = n; idx < cell_limit && !_pending_visual_dirty_dense; ++idx) mark_changed(idx);
                    } else if (visual_slot) {
                        for (int idx = 0; idx < cell_limit && !_pending_visual_dirty_dense; ++idx) mark_changed(idx);
                    }
                    _map_data->set(prop_name, s.arr_f32);
                    break;
                }
                case SlotDType::I32: {
                    if (visual_slot && previous.get_type() == Variant::PACKED_INT32_ARRAY) {
                        const PackedInt32Array old_values = previous;
                        const int n = std::min(cell_limit,
                                std::min(int(old_values.size()), int(s.arr_i32.size())));
                        for (int idx = 0; idx < n && !_pending_visual_dirty_dense; ++idx) {
                            if (old_values[idx] != s.arr_i32[idx]) mark_changed(idx);
                        }
                        for (int idx = n; idx < cell_limit && !_pending_visual_dirty_dense; ++idx) mark_changed(idx);
                    } else if (visual_slot) {
                        for (int idx = 0; idx < cell_limit && !_pending_visual_dirty_dense; ++idx) mark_changed(idx);
                    }
                    _map_data->set(prop_name, s.arr_i32);
                    break;
                }
                case SlotDType::U8: {
                    if (visual_slot && previous.get_type() == Variant::PACKED_BYTE_ARRAY) {
                        const PackedByteArray old_values = previous;
                        const int n = std::min(cell_limit,
                                std::min(int(old_values.size()), int(s.arr_u8.size())));
                        for (int idx = 0; idx < n && !_pending_visual_dirty_dense; ++idx) {
                            if (old_values[idx] != s.arr_u8[idx]) mark_changed(idx);
                        }
                        for (int idx = n; idx < cell_limit && !_pending_visual_dirty_dense; ++idx) mark_changed(idx);
                    } else if (visual_slot) {
                        for (int idx = 0; idx < cell_limit && !_pending_visual_dirty_dense; ++idx) mark_changed(idx);
                    }
                    _map_data->set(prop_name, s.arr_u8);
                    break;
                }
            }
            if (any_visual_dirty || _pending_visual_dirty_dense) {
                _pending_mark_dirty_all = true;
                _native_dirty_report["flush_dirty_reason"] =
                        String("visual_slot_diff:") + String(s.name);
                _native_dirty_report["flush_dirty_slot"] = String(s.name);
                _native_dirty_report["flush_dirty_all_pending"] = true;
            } else if (!visual_slot) {
                _native_dirty_report["flush_dirty_filtered_count"] =
                        int(_native_dirty_report.get("flush_dirty_filtered_count", 0)) + 1;
                _native_dirty_report["flush_dirty_last_filtered_slot"] = String(s.name);
            }
            return;
        }
    }
}

void DCWorldExt::flush_pending_mark_dirty_all() {
    if (_pending_mark_dirty_all && _dirty_world) {
        if (_pending_visual_dirty_dense) {
            _dirty_world->call(StringName("mark_dirty_all"));
        } else if (_pending_visual_dirty_count > 0) {
            PackedInt32Array dirty_indices;
            dirty_indices.resize(_pending_visual_dirty_count);
            int write = 0;
            for (int i = 0; i < _pending_visual_dirty_mask.size(); ++i) {
                if (_pending_visual_dirty_mask[i] != 0) dirty_indices.set(write++, i);
            }
            if (_dirty_world->has_method(StringName("mark_dirty_indexed"))) {
                _dirty_world->call(StringName("mark_dirty_indexed"), dirty_indices);
            } else {
                _dirty_world->call(StringName("mark_dirty_all"));
            }
        }
        _native_dirty_report["flush_dirty_indexed_count"] =
                _pending_visual_dirty_dense ? 0 : _pending_visual_dirty_count;
        _native_dirty_report["flush_dirty_observed_count"] = _pending_visual_dirty_count;
        _native_dirty_report["flush_dirty_dense_fallback"] = _pending_visual_dirty_dense;
        _native_dirty_report["flush_dirty_dense_threshold"] =
                pk_visual_dirty_dense_threshold(_pending_visual_dirty_mask.size());
        _native_dirty_report["flush_dirty_all_emitted"] = true;
    }
    _pending_mark_dirty_all = false;
    _pending_visual_dirty_mask = PackedByteArray();
    _pending_visual_dirty_count = 0;
    _pending_visual_dirty_dense = false;
    _native_dirty_report["flush_dirty_all_pending"] = false;
}

void DCWorldExt::flush_slots_to_map() {
    if (!_map_data) return;
    for (int i = 0; i < BIND_TABLE_SIZE; ++i) {
        const StringName slot_name(BIND_TABLE[i].slot_name);
        const int sid = component_id(slot_name);
        if (sid < 0 || sid >= _slots.size()) continue;
        _flush_slot_to_map(sid);
    }
    _economy_resource_slot_resident.clear();
    flush_pending_mark_dirty_all();
}

void DCWorldExt::flush_slots_to_map_keys(const PackedStringArray &slot_names) {
    if (!_map_data) return;
    for (int i = 0; i < slot_names.size(); ++i) {
        const int sid = component_id(StringName(slot_names[i]));
        if (sid >= 0) {
            _flush_slot_to_map(sid);
            if (sid < static_cast<int>(_economy_resource_slot_resident.size()))
                _economy_resource_slot_resident[static_cast<size_t>(sid)] = 0;
        }
    }
}

void DCWorldExt::refresh_slots_from_map() {
    if (!_map_data) return;
    for (int i = 0; i < BIND_TABLE_SIZE; ++i) {
        const StringName slot_name(BIND_TABLE[i].slot_name);
        // Preserve the in-flight native moisture value while visible MapData
        // remains frozen at the previous completed round.
        if (_native_daily_visual_commit_pending &&
            slot_name == StringName("cell_moisture")) {
            continue;
        }
        const int sid = component_id(slot_name);
        if (sid < 0 || sid >= _slots.size()) continue;
        if (sid < static_cast<int>(_economy_resource_slot_resident.size()) &&
            _economy_resource_slot_resident[static_cast<size_t>(sid)] != 0) {
            continue;
        }
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

bool DCWorldExt::is_native_daily_visual_commit_pending() const {
    return _native_daily_visual_commit_pending;
}

void DCWorldExt::complete_native_daily_visual_commit() {
    _native_daily_visual_commit_pending = false;
}

void DCWorldExt::complete_native_daily_moisture_commit() {
    complete_native_daily_visual_commit();
}

void DCWorldExt::refresh_slots_from_map_keys(const PackedStringArray &slot_names) {
    if (!_map_data) return;
    for (int k = 0; k < slot_names.size(); ++k) {
        const StringName requested(slot_names[k]);
        if (_native_daily_visual_commit_pending &&
            requested == StringName("cell_moisture")) {
            continue;
        }
        const int sid = component_id(requested);
        if (sid < 0 || sid >= _slots.size()) continue;
        if (sid < static_cast<int>(_economy_resource_slot_resident.size()) &&
            _economy_resource_slot_resident[static_cast<size_t>(sid)] != 0) {
            continue;
        }
        const int bind_index = _bind_index_for_slot(sid);
        if (bind_index < 0) continue;
        Slot &s = _slots.write[sid];
        Variant v = _map_data->get(StringName(BIND_TABLE[bind_index].property_name));
        switch (s.dtype) {
            case SlotDType::F32: s.arr_f32 = v; break;
            case SlotDType::I32: s.arr_i32 = v; break;
            case SlotDType::U8:  s.arr_u8  = v; break;
        }
    }
}

} // namespace pk
