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
    NativeParallelExecutor::instance().run_group(
        static_cast<uint32_t>(n_tasks), &pass_a_full_worker, &task);
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
    NativeParallelExecutor::instance().run_group(
        static_cast<uint32_t>(n_tasks), &pass_a_indexed_worker, &task);
}

} // namespace pk
