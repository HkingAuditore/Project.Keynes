#include "world_ext.h"
// Cell-program backend decision (plan 22 §4.5): header-only, no Godot
// types, so the catalog-compile pass and the pure-kernel test can both
// consume one algorithm instead of re-deriving eligibility.
#include "cell_program_eligibility.h"

#include "component_bind_table.gen.h"  // A1 / dots-migration-roadmap §3 — autogen by tools/codegen/gen_cpp_bind_table.py
#include "map_overlay_input_publication.h"
#include "resource_visual_publication.h"
#include "system_schedule.h"           // Phase C.1 — 静态 DAG 调度图
#include "parallel_dispatcher.h"       // Phase C.3a — 并行分发 helper（统一 5 个手写 _thread）
#include "economy_runtime.h"           // Independent ECONOMY_GRAPH authority
#include "economy_csv_recorder.h"      // Debug-only committed CSV writer
#include "country_runtime.h"           // Independent COUNTRY_GRAPH authority
#include "modifier_runtime.h"          // Shared four-domain Modifier authority
#include "trigger_runtime.h"           // Generic event-to-effect trigger authority
#include "effect_runtime.h"            // Generic effect plan/transaction authority
#include "effect_instance_forwarder.h" // M2a: single declarative Effect write path
#include "ideology_runtime.h"          // Country-scoped ideology authority

// MSVC 默认不定义 M_PI；必须在引入 <cmath> 之前打开 _USE_MATH_DEFINES。
// 双保险：仍未定义时手动兜底，避免某些编译器/PCH 顺序问题。
#ifndef _USE_MATH_DEFINES
#define _USE_MATH_DEFINES
#endif

#include <godot_cpp/classes/global_constants.hpp>
#include <godot_cpp/classes/fast_noise_lite.hpp>          // native world-gen 复刻：与 GDScript _init_noise 同一引擎噪声
#include <godot_cpp/classes/random_number_generator.hpp>  // native world-gen 复刻：与 GDScript _rng 同一引擎 PCG
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
#include "native_simulation_host.h"
#include "country_ai_runtime.h"
#include "military_core.h"  // dtor: delete the opaque pk::MilitaryCore handle

namespace pk {

// Defined in world_ext_bio.cpp where the opaque slice state is complete.
void destroy_bio_occupancy_slice_state(void *state);
void destroy_bio_native_config_state(void *state);
void destroy_season_round_state(void *state);

using namespace godot;


DCWorldExt::DCWorldExt() = default;

Dictionary DCWorldExt::configure_country(const Dictionary &catalog,
                                        const Dictionary &profile,
                                        int cell_count, int64_t seed) {
    // Reconfiguration starts a new world; an executor restart uses capture.
    if (_runtime_host && !_runtime_host->execution_has_stopped()) {
        Dictionary rejected;
        rejected["ok"] = false;
        rejected["code"] = "country_configure_requires_stopped_runtime";
        return rejected;
    }
    // Validate into a private candidate before discarding any old world state.
    auto candidate = std::make_unique<NativeCountryRuntime>();
    Dictionary configured = candidate->configure(catalog, profile, cell_count, seed);
    if (!static_cast<bool>(configured.get("ok", false))) return configured;
    auto *economy = static_cast<NativeEconomyRuntime *>(_economy_runtime);
    if (_runtime_host && _runtime_host->has_started_once()) {
        std::string rebuild_error;
        auto next = _runtime_host->make_new_world_host(rebuild_error);
        if (!next) {
            configured["ok"] = false;
            configured["code"] = "runtime_world_catalog_rebuild_failed";
            configured["reason"] = String(rebuild_error.c_str());
            return configured;
        }
        // Detach the borrowed OwnedState before destroying its old Host.
        if (economy != nullptr) economy->unbind_formula_owned_state();
        // Facades observe world-local generations too. Their instances and
        // cursors must match the fresh authorities, even when catalogs are reused.
        if (_modifier_runtime != nullptr)
            static_cast<ModifierRuntime *>(_modifier_runtime)->reset_runtime_state(cell_count);
        if (_effect_runtime != nullptr)
            static_cast<EffectRuntime *>(_effect_runtime)->clear_state();
        if (_trigger_runtime != nullptr)
            static_cast<TriggerRuntime *>(_trigger_runtime)->clear_state();
        if (_ideology_runtime != nullptr)
            static_cast<NativeIdeologyRuntime *>(_ideology_runtime)->clear_state();
        _ideology_opinion_published_revision = 0;
        _runtime_host = std::move(next);
        clear_runtime_map_lut_frame();
        if (_effect_forwarder)
            _effect_forwarder->attach(static_cast<EffectRuntime *>(_effect_runtime), _runtime_host.get());
        attach_country_ai_to_host();
        _climate_physics_committed.reset();
        _climate_physics_capture_ready = false;
        _climate_writeback_applied_generation = 0;
        _climate_writeback_applied_day = -1;
        if (economy != nullptr) economy->set_sync_writes_forbidden(false);
    }
    delete static_cast<NativeCountryRuntime *>(_country_query_runtime);
    _country_query_runtime = nullptr;
    _country_query_snapshot.reset();
    if (_country_runtime == nullptr) _country_runtime = candidate.release();
    else {
        // Retain the object's monotonic session epoch: old peer replies must
        // never match a newly configured world on this same API object.
        configured = static_cast<NativeCountryRuntime *>(_country_runtime)->configure(
            catalog, profile, cell_count, seed);
    }
    auto *country = static_cast<NativeCountryRuntime *>(_country_runtime);
    country->set_sync_store_writes_forbidden(false);
    country->attach_simulation_host(_runtime_host.get());
    if (economy != nullptr) {
        economy->attach_country_runtime(country);
        economy->attach_simulation_host(_runtime_host.get());
        country->attach_economy_runtime(economy);
    }
    if (_modifier_runtime != nullptr)
        static_cast<ModifierRuntime *>(_modifier_runtime)->attach_country_runtime(country);
    if (_effect_runtime != nullptr) {
        auto *effect = static_cast<EffectRuntime *>(_effect_runtime);
        effect->attach_country_runtime(country);
        country->attach_effect_runtime(effect);
    }
    country->attach_effect_forwarder(_effect_forwarder.get());
    country->attach_modifier_runtime(static_cast<ModifierRuntime *>(_modifier_runtime));
    return configured;
}

DCWorldExt::~DCWorldExt() {
    if (_runtime_host) {
        _runtime_host->request_stop();
        _runtime_host->join_for_destruction();
        _runtime_host.reset();
    }
    if (_country_ai_runtime != nullptr) {
        delete static_cast<CountryAiRuntime *>(_country_ai_runtime);
        _country_ai_runtime = nullptr;
    }
    _military.reset();
    if (_ideology_runtime != nullptr) {
        delete static_cast<NativeIdeologyRuntime *>(_ideology_runtime);
        _ideology_runtime = nullptr;
    }
    if (_trigger_runtime != nullptr) {
        delete static_cast<TriggerRuntime *>(_trigger_runtime);
        _trigger_runtime = nullptr;
    }
    if (_effect_runtime != nullptr) {
        // Drop the forwarder first: it holds a borrowed EffectRuntime pointer.
        _effect_forwarder.reset();
        delete static_cast<EffectRuntime *>(_effect_runtime);
        _effect_runtime = nullptr;
    }
    if (_economy_modifier_view != nullptr) {
        delete static_cast<ModifierRuntime *>(_economy_modifier_view);
        _economy_modifier_view = nullptr;
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
    if (_country_query_runtime != nullptr) {
        delete static_cast<NativeCountryRuntime *>(_country_query_runtime);
        _country_query_runtime = nullptr;
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
        destroy_season_round_state(_season_round);
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




#include "world_ext_section_map_binding.inc"
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
#include "world_ext_section_dirty_slot_publication.inc"

} // namespace pk
