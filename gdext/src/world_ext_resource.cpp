// world_ext_resource.cpp — Natural resources daily pass (economy.resources).
//
// run_natural_resource_pass: per-cell, per-resource 生成/衰减演化。固定公式模板 +
// 每资源系数（由 GDScript ResourceProfileRegistry.build_pass_knobs 组装），结合
// cell_temp / cell_moisture 计算每 tick reserve 变化，写回各资源 reserve slot 并
// flush 到 MapData。可再生 / 不可再生 仅由系数区分（见 resource_profile.gd 模板）。
//
// 数值积分采用半隐式（IMEX）：生成/衰减拆成常数生产项 P 与线性损失率 L（损失隐式）
//   ⇒ reserve' = (reserve + P) / (1 + L)。L≥0 ⇒ 无条件稳定（不过冲/不横跳）。
// 因 L、inv_denom = 1/(1+L) 及 P 的各项系数都是「每资源常数」，可代数化简为
//   P = C0 + C1*tn + C2*m，   reserve' = (reserve + P) * inv_denom
//   C0 = gen_base + gen_self - decay_base, C1 = gen_temp - decay_temp, C2 = gen_moisture - decay_moisture
// per-cell 除法被提到资源外，内层只剩 clamp + 两个 FMA + 一个乘 —— 既适合多核分块，
// 也适合 AVX2 向量化。
//
// 性能路径（与 pass_a / ocean / weather 同范式）：
//   - 多核：pk::parallel_for_range_with_emit 按 cell 分块（WorkerThreadPool），
//           total_delta 走 thread-local DeltaEmit 串行 reduce；单线程 fallback bit-equal。
//   - SIMD：PK_HAVE_AVX2 时内层 8 cell/iter（loadu/fmadd/min/max + land_gate blendv），
//           尾段与非 AVX2 构建走同一标量 helper，保证 lane/tail/标量三者数值一致。
//
// 与 run_runtime_hydrology_pass 同契约：Dictionary 返回，published_to_slot 标识是否
// 成功发布；失败返回 fallback_reason，GDScript 走同模板 fallback。

#include "world_ext.h"
#include "world_ext_internal.h"  // dc_clampf + Slot + 通用 includes（namespace pk 内）
#include "parallel_dispatcher.h" // Phase C.3 — parallel_for_range(_with_emit)

#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <cfloat>
#include <chrono>

#if defined(PK_HAVE_AVX2) && PK_HAVE_AVX2
#  include <immintrin.h>
#endif

namespace pk {

using namespace godot;

namespace {

// total_delta 的 thread-local 累加器（parallel_for_range_with_emit reduce 契约）。
struct DeltaEmit {
    double sum = 0.0;
    void merge_into(DeltaEmit &dst) const { dst.sum += sum; }
};

// 单 cell 半隐式更新（化简形式）。SIMD 尾段 + 非 AVX2 构建共用，保证三路一致。
// 返回新 reserve；调用方负责 land_gate（水面格保持原值）与 delta 累加。
inline float natres_step_scalar(float t_val, float m_val, float reserve,
                                float lo, float inv_span,
                                float c0, float c1, float c2,
                                float inv_denom, float cap_upper) {
    const float tn = dc_clampf((t_val - lo) * inv_span, 0.0f, 1.0f);
    const float p = c0 + c1 * tn + c2 * m_val;
    float v = (reserve + p) * inv_denom;
    if (v > cap_upper) v = cap_upper;
    if (v < 0.0f) v = 0.0f;
    return v;
}

#if defined(PK_HAVE_AVX2) && PK_HAVE_AVX2
// 8-lane 水平求和（与 world_ext_demo.cpp 的 hsum 同实现）。
inline float natres_hsum256(__m256 v) {
    __m128 lo = _mm256_castps256_ps128(v);
    __m128 hi = _mm256_extractf128_ps(v, 1);
    lo = _mm_add_ps(lo, hi);
    __m128 sh = _mm_movehl_ps(lo, lo);
    lo = _mm_add_ps(lo, sh);
    sh = _mm_shuffle_ps(lo, lo, 0x1);
    lo = _mm_add_ss(lo, sh);
    return _mm_cvtss_f32(lo);
}

// AVX2 块：处理 [i, i+8) 8 个 cell，结果写回 R，delta 累加进 vacc。
inline void natres_simd_block(float *__restrict R, const float *__restrict T,
                              const float *__restrict M, const uint8_t *__restrict WATER,
                              bool land_gate, int i,
                              __m256 vlo, __m256 vinv_span,
                              __m256 vc0, __m256 vc1, __m256 vc2,
                              __m256 vinv_denom, __m256 vcap_upper,
                              const __m256 vzero, const __m256 vone,
                              __m256 &vacc) {
    const __m256 vt = _mm256_loadu_ps(T + i);
    const __m256 vm = _mm256_loadu_ps(M + i);
    const __m256 vr = _mm256_loadu_ps(R + i);

    __m256 tn = _mm256_mul_ps(_mm256_sub_ps(vt, vlo), vinv_span);
    tn = _mm256_min_ps(_mm256_max_ps(tn, vzero), vone);

    __m256 p = _mm256_fmadd_ps(vc1, tn, vc0);  // C1*tn + C0
    p = _mm256_fmadd_ps(vc2, vm, p);           // C2*m  + (C1*tn+C0)

    __m256 v = _mm256_mul_ps(_mm256_add_ps(vr, p), vinv_denom);
    v = _mm256_min_ps(v, vcap_upper);
    v = _mm256_max_ps(v, vzero);

    if (land_gate) {
        // 水面格保持原值：land_mask = (WATER==0) → 取 v，否则取原 reserve。
        const __m128i w8 = _mm_loadl_epi64(reinterpret_cast<const __m128i *>(WATER + i));
        const __m256i w32 = _mm256_cvtepu8_epi32(w8);
        const __m256i land_i = _mm256_cmpeq_epi32(w32, _mm256_setzero_si256());
        const __m256 land_mask = _mm256_castsi256_ps(land_i);
        v = _mm256_blendv_ps(vr, v, land_mask);
    }

    vacc = _mm256_add_ps(vacc, _mm256_sub_ps(v, vr));
    _mm256_storeu_ps(R + i, v);
}
#endif  // PK_HAVE_AVX2

} // namespace

Dictionary DCWorldExt::run_natural_resource_pass(const Dictionary &knobs) {
    using godot::PackedFloat32Array;
    using godot::PackedStringArray;
    using godot::StringName;

    Dictionary out;
    const auto t0 = std::chrono::high_resolution_clock::now();
    auto fail = [&](const char *why) -> Dictionary {
        const auto t1 = std::chrono::high_resolution_clock::now();
        out["done"] = true;
        out["path"] = "gdext";
        out["fallback_reason"] = why;
        out["published_to_slot"] = false;
        out["published_slots"] = PackedStringArray();
        out["resource_count"] = 0;
        out["n_cells"] = 0;
        out["total_delta"] = 0.0;
        out["native_ms"] = std::chrono::duration<double, std::milli>(t1 - t0).count();
        out["compute_ms"] = 0.0;
        return out;
    };

    if (!_bound) return fail("world_ext_not_bound");

    // ─── Climate input slots（热循环外解析）─────────────────────────────
    const int sid_temp = component_id(StringName("cell_temp"));
    const int sid_moist = component_id(StringName("cell_moisture"));
    const int sid_water = component_id(StringName("cell_is_water"));  // 可缺失（-1）
    if (sid_temp < 0 || sid_moist < 0) return fail("missing_climate_slot");

    const int n_cells = knobs.has("n_cells") ? int(knobs["n_cells"]) : int(_entity_archetype.size());
    if (n_cells <= 0) return fail("empty_world");

    const int resource_count = knobs.has("resource_count") ? int(knobs["resource_count"]) : 0;
    if (resource_count <= 0) return fail("no_resources");

    if (!knobs.has("reserve_slots") || !knobs.has("capacity") || !knobs.has("land_only") ||
        !knobs.has("temp_lo") || !knobs.has("temp_hi") ||
        !knobs.has("gen_base") || !knobs.has("gen_temp") || !knobs.has("gen_moisture") || !knobs.has("gen_self") ||
        !knobs.has("decay_base") || !knobs.has("decay_temp") || !knobs.has("decay_moisture") || !knobs.has("decay_self")) {
        return fail("knobs_missing_keys");
    }

    PackedStringArray reserve_slots = knobs["reserve_slots"];
    PackedFloat32Array capacity = knobs["capacity"];
    PackedFloat32Array land_only = knobs["land_only"];
    PackedFloat32Array temp_lo = knobs["temp_lo"];
    PackedFloat32Array temp_hi = knobs["temp_hi"];
    PackedFloat32Array gen_base = knobs["gen_base"];
    PackedFloat32Array gen_temp = knobs["gen_temp"];
    PackedFloat32Array gen_moisture = knobs["gen_moisture"];
    PackedFloat32Array gen_self = knobs["gen_self"];
    PackedFloat32Array decay_base = knobs["decay_base"];
    PackedFloat32Array decay_temp = knobs["decay_temp"];
    PackedFloat32Array decay_moisture = knobs["decay_moisture"];
    PackedFloat32Array decay_self = knobs["decay_self"];

    if (reserve_slots.size() < resource_count || capacity.size() < resource_count ||
        land_only.size() < resource_count || temp_lo.size() < resource_count || temp_hi.size() < resource_count ||
        gen_base.size() < resource_count || gen_temp.size() < resource_count ||
        gen_moisture.size() < resource_count || gen_self.size() < resource_count ||
        decay_base.size() < resource_count || decay_temp.size() < resource_count ||
        decay_moisture.size() < resource_count || decay_self.size() < resource_count) {
        return fail("knob_array_size_mismatch");
    }

    auto slot_ok_f32 = [&](int sid) -> bool { return int(_slots.write[sid].arr_f32.size()) >= n_cells; };
    if (!slot_ok_f32(sid_temp) || !slot_ok_f32(sid_moist)) return fail("climate_slot_size_mismatch");

    const float * const __restrict T = _slots.write[sid_temp].arr_f32.ptr();
    const float * const __restrict M = _slots.write[sid_moist].arr_f32.ptr();
    const bool have_water = (sid_water >= 0 && int(_slots.write[sid_water].arr_u8.size()) >= n_cells);
    const uint8_t * const __restrict WATER = have_water ? _slots.write[sid_water].arr_u8.ptr() : nullptr;

    // Benchmark-only 旁路开关（默认 false，生产路径完全不变）：
    //   bench_force_scalar=true → 跳过 AVX2 SIMD 块，仅走标量（隔离 SIMD 收益）；
    //   bench_force_seq=true    → 强制单线程 n_tasks=1（隔离多核收益）。
    const bool force_scalar = knobs.has("bench_force_scalar") && bool(knobs["bench_force_scalar"]);
    const bool force_seq = knobs.has("bench_force_seq") && bool(knobs["bench_force_seq"]);
    const int n_tasks_hint = force_seq ? 1 : 0;

    const auto t_setup = std::chrono::high_resolution_clock::now();

    PackedStringArray published_slots;
    int published_count = 0;
    DeltaEmit delta_acc;  // total_delta 跨资源累加（reduce 目标）

    for (int r = 0; r < resource_count; ++r) {
        const int sid = component_id(StringName(reserve_slots[r]));
        if (sid < 0 || !slot_ok_f32(sid)) {
            // schema 缺失或尺寸不符：跳过该资源，但不整体失败（其余资源仍可发布）。
            continue;
        }

        float * const __restrict R = _slots.write[sid].arr_f32.ptrw();

        const float cap = capacity[r];
        const float lo = temp_lo[r];
        const float hi = temp_hi[r];
        const float inv_span = (hi > lo) ? (1.0f / (hi - lo)) : 0.0f;
        const bool land_gate = land_only[r] >= 0.5f && have_water;
        const float gb = gen_base[r], gt = gen_temp[r], gm = gen_moisture[r], gs = gen_self[r];
        const float db = decay_base[r], dt = decay_temp[r], dm = decay_moisture[r], ds = decay_self[r];

        // ── 代数化简：把半隐式公式收成 P = C0 + C1*tn + C2*m, v = (reserve+P)*inv_denom ──
        const float c0 = gb + gs - db;
        const float c1 = gt - dt;
        const float c2 = gm - dm;
        float L = (cap > 0.0f) ? ((gs + ds) / cap) : 0.0f;
        if (L < 0.0f) L = 0.0f;  // 负自系数（误配）兜底，保持无条件稳定
        const float inv_denom = 1.0f / (1.0f + L);
        const float cap_upper = (cap > 0.0f) ? cap : FLT_MAX;

#if defined(PK_HAVE_AVX2) && PK_HAVE_AVX2
        const __m256 vlo = _mm256_set1_ps(lo);
        const __m256 vinv_span = _mm256_set1_ps(inv_span);
        const __m256 vc0 = _mm256_set1_ps(c0);
        const __m256 vc1 = _mm256_set1_ps(c1);
        const __m256 vc2 = _mm256_set1_ps(c2);
        const __m256 vinv_denom = _mm256_set1_ps(inv_denom);
        const __m256 vcap_upper = _mm256_set1_ps(cap_upper);
        const __m256 vzero = _mm256_setzero_ps();
        const __m256 vone = _mm256_set1_ps(1.0f);
#endif

        // 多核：按 cell 分块；total_delta 走 thread-local DeltaEmit 串行 reduce。
        auto run_range = [&](int begin, int end, DeltaEmit &local) {
            double seg = 0.0;
            int i = begin;
#if defined(PK_HAVE_AVX2) && PK_HAVE_AVX2
            if (!force_scalar) {
                __m256 vacc = _mm256_setzero_ps();
                const int simd_end = end - ((end - begin) % 8);
                for (; i + 8 <= simd_end; i += 8) {
                    natres_simd_block(R, T, M, WATER, land_gate, i,
                                      vlo, vinv_span, vc0, vc1, vc2, vinv_denom, vcap_upper,
                                      vzero, vone, vacc);
                }
                seg += double(natres_hsum256(vacc));
            }
#endif
            for (; i < end; ++i) {  // 标量尾段（AVX2）/ 全量（非 AVX2 构建）
                if (land_gate && WATER[i] != 0) continue;  // 水面格保持原值，delta 0
                const float reserve = R[i];
                const float v = natres_step_scalar(T[i], M[i], reserve, lo, inv_span,
                                                   c0, c1, c2, inv_denom, cap_upper);
                seg += double(v - reserve);
                R[i] = v;
            }
            local.sum += seg;
        };

        pk::parallel_for_range_with_emit<DeltaEmit>("pk_natural_resource", n_cells,
                                                    n_tasks_hint, /*seq_threshold=*/256,
                                                    delta_acc, run_range);

        _flush_slot_to_map(sid);
        published_slots.append(reserve_slots[r]);
        ++published_count;
    }

    const auto t1 = std::chrono::high_resolution_clock::now();
    out["done"] = true;
    out["path"] = "gdext";
    out["published_to_slot"] = published_count > 0;
    out["published_slots"] = published_slots;
    out["resource_count"] = published_count;
    out["n_cells"] = n_cells;
    out["total_delta"] = delta_acc.sum;
    out["native_ms"] = std::chrono::duration<double, std::milli>(t1 - t0).count();
    out["compute_ms"] = std::chrono::duration<double, std::milli>(t1 - t_setup).count();
    if (published_count == 0) out["fallback_reason"] = "no_publishable_resource";
    return out;
}

} // namespace pk
