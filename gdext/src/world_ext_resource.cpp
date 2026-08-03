// world_ext_resource.cpp — Natural resources daily pass (economy.resources).
//
// run_natural_resource_pass: per-cell, per-resource 生成/衰减演化。固定公式模板 +
// 每资源系数（由 GDScript ResourceProfileRegistry.build_pass_knobs 组装），结合
// cell_temp / cell_moisture 计算每 tick reserve 变化，写回各资源 reserve slot 并
// flush 到 MapData。可再生 / 不可再生 仅由系数区分（见 resource_profile.gd 模板）。
// 系数全 0 的静态资源（如矿物储量）在每日 pass 中恒等不变，直接跳过全图 loop/flush。
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
//   - 多核：先预筛动态资源，再用一次 pk::parallel_for_range_with_emit 按 cell
//           分块；每个 task 内循环全部动态资源，避免"每资源一次 WTP dispatch"的
//           小图固定开销。total_delta 走 thread-local DeltaEmit 串行 reduce。
//   - SIMD：PK_HAVE_AVX2 时内层 8 cell/iter（loadu/fmadd/min/max + land_gate blendv），
//           尾段与非 AVX2 构建走同一标量 helper，保证 lane/tail/标量三者数值一致。
//
// 与 run_runtime_hydrology_pass 同契约：Dictionary 返回，published_to_slot 标识是否
// 成功发布；失败返回 fallback_reason，GDScript 走同模板 fallback。

#include "world_ext.h"
#include "world_ext_internal.h"  // dc_clampf + Slot + 通用 includes（namespace pk 内）
#include "parallel_dispatcher.h" // Phase C.3 — parallel_for_range(_with_emit)
#include "modifier_runtime.h"

#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <cfloat>
#include <chrono>
#include <cmath>
#include <vector>

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

struct NatResRuntime {
    int sid = -1;
    int sid_extra = -1;
    int resource_index = -1;
    float *R = nullptr;
    float *X = nullptr;
    const float *temperature = nullptr;
    const float *moisture = nullptr;
    float lo = 0.0f;
    float inv_span = 0.0f;
    bool land_gate = false;
    uint8_t habitat_bit = 0;
    bool use_extra = false;
    float c0 = 0.0f;
    float c1 = 0.0f;
    float c2 = 0.0f;
    float inv_denom = 1.0f;
    bool use_climate_fit = false;
    float gb = 0.0f;
    float gt = 0.0f;
    float gm = 0.0f;
    float gs = 0.0f;
    float db = 0.0f;
    float dt = 0.0f;
    float dm = 0.0f;
    float ds = 0.0f;
    float climate_temp_opt = 0.5f;
    float climate_temp_tol = 1.0f;
    float climate_moisture_opt = 0.5f;
    float climate_moisture_tol = 1.0f;
    float runtime_fit_weight = 0.0f;
    float decay_stress = 0.0f;
    float ecology_capacity = 0.0f;
    float ecology_growth_rate = 0.0f;
    float ecology_immigration = 0.0f;
    float ecology_stress_mortality_rate = 0.0f;
    bool use_ecology = false;
    bool has_natural_dynamics = false;
    const float *regen_factors = nullptr;
    bool has_regen_modifier = false;
};

// 单 cell 半隐式更新（化简形式）。SIMD 尾段 + 非 AVX2 构建共用，保证三路一致。
// 返回新 reserve；调用方负责 land_gate（水面格保持原值）与 delta 累加。
inline float natres_step_scalar(float t_val, float m_val, float reserve,
                                float lo, float inv_span,
                                float c0, float c1, float c2,
                                float inv_denom) {
    const float tn = dc_clampf((t_val - lo) * inv_span, 0.0f, 1.0f);
    const float p = c0 + c1 * tn + c2 * m_val;
    float v = (reserve + p) * inv_denom;
    if (v < 0.0f) v = 0.0f;
    return v;
}

inline float natres_step_scalar_dt(float t_val, float m_val, float reserve,
                                   float lo, float inv_span,
                                   float c0, float c1, float c2,
                                   float inv_denom, float extra_change,
                                   int dt_days) {
    const float reserve_after_external = std::max(0.0f, reserve + extra_change);
    if (dt_days <= 1) {
        const float tn = dc_clampf((t_val - lo) * inv_span, 0.0f, 1.0f);
        const float p = c0 + c1 * tn + c2 * m_val;
        float v = (reserve_after_external + p) * inv_denom;
        if (v < 0.0f) v = 0.0f;
        return v;
    }
    const float tn = dc_clampf((t_val - lo) * inv_span, 0.0f, 1.0f);
    const float p = c0 + c1 * tn + c2 * m_val;
    float v = reserve_after_external;
    if (std::fabs(1.0f - inv_denom) < 1e-6f) {
        v = reserve_after_external + p * float(dt_days);
    } else {
        const float a_pow = std::pow(inv_denom, float(dt_days));
        const float b = p * inv_denom;
        v = a_pow * reserve_after_external + b * (1.0f - a_pow) / (1.0f - inv_denom);
    }
    if (v < 0.0f) v = 0.0f;
    return v;
}

inline float natres_fit_factor(float tn, float m_val,
                               float temp_opt, float temp_tol,
                               float moisture_opt, float moisture_tol) {
    const float safe_temp_tol = std::max(temp_tol, 0.0001f);
    const float safe_moisture_tol = std::max(moisture_tol, 0.0001f);
    const float temp_fit = 1.0f - dc_clampf(std::fabs(tn - temp_opt) / safe_temp_tol, 0.0f, 1.0f);
    const float moisture_fit = 1.0f - dc_clampf(std::fabs(m_val - moisture_opt) / safe_moisture_tol, 0.0f, 1.0f);
    return temp_fit * moisture_fit;
}

inline float natres_step_scalar_fit_dt(float t_val, float m_val, float reserve,
                                       float extra_change,
                                       const NatResRuntime &rr, int dt_days) {
    const float tn = dc_clampf((t_val - rr.lo) * rr.inv_span, 0.0f, 1.0f);
    const float climate_fit = natres_fit_factor(tn, m_val,
                                                rr.climate_temp_opt, rr.climate_temp_tol,
                                                rr.climate_moisture_opt, rr.climate_moisture_tol);
    const float fit_w = dc_clampf(rr.runtime_fit_weight, 0.0f, 1.0f);
    const float runtime_fit = 1.0f + (climate_fit - 1.0f) * fit_w;
    const float gen_self_eff = rr.gs * runtime_fit;
    const float gen_climate = rr.gb + rr.gt * tn + rr.gm * m_val;
    const float decay_climate = rr.db + rr.dt * tn + rr.dm * m_val;
    const float p = gen_climate + gen_self_eff - decay_climate - rr.decay_stress * (1.0f - runtime_fit);
    float L = rr.ds;
    if (L < 0.0f) L = 0.0f;
    const float inv_denom = 1.0f / (1.0f + L);
    const float reserve_after_external = std::max(0.0f, reserve + extra_change);
    float v = reserve_after_external;
    if (dt_days <= 1) {
        v = (reserve_after_external + p) * inv_denom;
    } else if (std::fabs(1.0f - inv_denom) < 1e-6f) {
        v = reserve_after_external + p * float(dt_days);
    } else {
        const float a_pow = std::pow(inv_denom, float(dt_days));
        const float b = p * inv_denom;
        v = a_pow * reserve_after_external + b * (1.0f - a_pow) / (1.0f - inv_denom);
    }
    if (v < 0.0f) v = 0.0f;
    return v;
}

inline float natres_step_scalar_ecology_dt(float t_val, float m_val, float reserve,
                                           float extra_change,
                                           const NatResRuntime &rr, int dt_days) {
    const float tn = dc_clampf((t_val - rr.lo) * rr.inv_span, 0.0f, 1.0f);
    const float climate_fit = natres_fit_factor(tn, m_val,
                                                rr.climate_temp_opt, rr.climate_temp_tol,
                                                rr.climate_moisture_opt, rr.climate_moisture_tol);
    const float fit_w = dc_clampf(rr.runtime_fit_weight, 0.0f, 1.0f);
    const float runtime_fit = 1.0f + (climate_fit - 1.0f) * fit_w;
    const float capacity = std::max(0.0f, rr.ecology_capacity * runtime_fit);
    const float growth_factor = 1.0f + std::max(0.0f, rr.ecology_growth_rate) * runtime_fit;
    const float immigration = std::max(0.0f, rr.ecology_immigration) * runtime_fit;
    // Carrying capacity already represents ordinary habitat degradation. Applying
    // stress mortality to every point below perfect fit double-counted that penalty
    // and made otherwise viable populations converge toward the immigration floor.
    // Reserve explicit mortality for the acutely unsuitable bottom quarter only.
    constexpr float ACUTE_STRESS_FIT_THRESHOLD = 0.25f;
    const float acute_stress = dc_clampf(
        (ACUTE_STRESS_FIT_THRESHOLD - climate_fit) / ACUTE_STRESS_FIT_THRESHOLD,
        0.0f, 1.0f);
    const float stress_denom = 1.0f + std::max(0.0f, rr.ecology_stress_mortality_rate) *
                                      acute_stress;
    float v = std::max(0.0f, reserve + extra_change);
    for (int day = 0; day < std::max(1, dt_days); ++day) {
        const float seeded = v + immigration;
        if (capacity <= 1e-6f) {
            v = 0.0f;
            continue;
        }
        const float density_denom = 1.0f +
            (growth_factor - 1.0f) * seeded / capacity;
        v = density_denom > 0.0f ? growth_factor * seeded / density_denom : 0.0f;
        v = std::max(0.0f, v / stress_denom);
    }
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
                              __m256 vinv_denom,
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

Dictionary DCWorldExt::get_natural_resource_regen_factors(
        const PackedStringArray &resource_ids, int32_t n_cells) {
    Dictionary out;
    auto fail = [&](const char *reason) -> Dictionary {
        out["ok"] = false;
        out["reason"] = reason;
        out["factors"] = PackedFloat32Array();
        out["snapshot_version"] = int64_t{0};
        out["resource_count"] = resource_ids.size();
        out["n_cells"] = n_cells;
        out["active_factor_count"] = 0;
        out["cache_rebuilt"] = false;
        return out;
    };

    if (n_cells <= 0) return fail("natural_resource_modifier_cell_count_invalid");
    if (resource_ids.is_empty()) return fail("natural_resource_modifier_ids_empty");
    const int64_t factor_count = int64_t(resource_ids.size()) * int64_t(n_cells);
    if (factor_count <= 0 || factor_count > std::numeric_limits<int32_t>::max())
        return fail("natural_resource_modifier_factor_count_invalid");

    constexpr uint64_t FNV_OFFSET = 1469598103934665603ULL;
    constexpr uint64_t FNV_PRIME = 1099511628211ULL;
    uint64_t ids_hash = FNV_OFFSET;
    std::vector<std::string> stable_ids;
    stable_ids.reserve(static_cast<size_t>(resource_ids.size()));
    for (int32_t index = 0; index < resource_ids.size(); ++index) {
        const std::string stable_id = String(resource_ids[index]).utf8().get_data();
        if (stable_id.empty()) return fail("natural_resource_modifier_id_empty");
        if (std::find(stable_ids.begin(), stable_ids.end(), stable_id) != stable_ids.end())
            return fail("natural_resource_modifier_id_duplicate");
        stable_ids.push_back(stable_id);
        for (const unsigned char byte : stable_id) {
            ids_hash ^= uint64_t(byte);
            ids_hash *= FNV_PRIME;
        }
        ids_hash ^= 0;
        ids_hash *= FNV_PRIME;
    }

    const ModifierRuntime *modifier =
        static_cast<const ModifierRuntime *>(_modifier_runtime);
    const bool modifier_ready = modifier != nullptr && modifier->configured();
    const uint64_t snapshot_version = modifier_ready
        ? modifier->domain_snapshot_version(ModifierRuntime::ECONOMY) : 0;
    const uint64_t catalog_hash = modifier_ready ? modifier->catalog_hash() : 0;
    const bool rebuild =
        _natural_resource_modifier_version != snapshot_version ||
        _natural_resource_modifier_catalog_hash != catalog_hash ||
        _natural_resource_modifier_ids_hash != ids_hash ||
        _natural_resource_modifier_cells != n_cells ||
        _natural_resource_regen_factors.size() != factor_count;

    if (rebuild) {
        _natural_resource_regen_factors.resize(factor_count);
        float * const factors = _natural_resource_regen_factors.ptrw();
        _natural_resource_modifier_active_factor_count = 0;
        const int32_t generic_stat = modifier_ready
            ? modifier->stat_id_for_key("economy.city.resource.regen_factor") : -1;
        for (int32_t resource = 0; resource < resource_ids.size(); ++resource) {
            const int32_t resource_stat = modifier_ready
                ? modifier->stat_id_for_key("economy.city.resource." +
                    stable_ids[resource] + ".regen_factor") : -1;
            const int64_t row = int64_t(resource) * int64_t(n_cells);
            for (int32_t cell = 0; cell < n_cells; ++cell) {
                double factor = 1.0;
                if (modifier_ready && generic_stat >= 0) {
                    factor = modifier->effective_value(
                        ModifierRuntime::ECONOMY, generic_stat, 0,
                        static_cast<uint64_t>(cell), 1.0);
                }
                if (modifier_ready && resource_stat >= 0) {
                    factor = modifier->effective_value(
                        ModifierRuntime::ECONOMY, resource_stat, 0,
                        static_cast<uint64_t>(cell), factor);
                }
                if (!std::isfinite(factor)) factor = 1.0;
                factors[row + cell] = static_cast<float>(factor);
                if (std::fabs(factor - 1.0) > 1e-7)
                    ++_natural_resource_modifier_active_factor_count;
            }
        }
        _natural_resource_modifier_version = snapshot_version;
        _natural_resource_modifier_catalog_hash = catalog_hash;
        _natural_resource_modifier_ids_hash = ids_hash;
        _natural_resource_modifier_cells = n_cells;
    }

    out["ok"] = true;
    out["reason"] = "";
    out["factors"] = _natural_resource_regen_factors;
    out["snapshot_version"] = static_cast<int64_t>(snapshot_version);
    out["catalog_hash"] = static_cast<int64_t>(catalog_hash);
    out["resource_count"] = resource_ids.size();
    out["n_cells"] = n_cells;
    out["active_factor_count"] = _natural_resource_modifier_active_factor_count;
    out["cache_rebuilt"] = rebuild;
    return out;
}

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
        out["setup_ms"] = out["native_ms"];
        out["loop_ms"] = 0.0;
        out["flush_ms"] = 0.0;
        out["skipped_static_resources"] = 0;
        return out;
    };

    if (!_bound) return fail("world_ext_not_bound");

    // ─── Climate input slots（热循环外解析）─────────────────────────────
    const int sid_temp = component_id(StringName("cell_temp"));
    const int sid_temp_30d = component_id(StringName("cell_temp_30d"));
    const int sid_moist = component_id(StringName("cell_moisture"));
    const int sid_plant_water = component_id(StringName("cell_plant_available_water"));
    const int sid_water = component_id(StringName("cell_is_water"));  // 可缺失（-1）
    const int sid_habitat = component_id(StringName(
        knobs.has("habitat_mask_slot") ? String(knobs["habitat_mask_slot"]) :
        String("cell_resource_habitat_mask")));
    if (sid_temp < 0 || sid_temp_30d < 0 || sid_moist < 0 || sid_plant_water < 0)
        return fail("missing_climate_slot");

    const int n_cells = knobs.has("n_cells") ? int(knobs["n_cells"]) : int(_entity_archetype.size());
    if (n_cells <= 0) return fail("empty_world");

    const int resource_count = knobs.has("resource_count") ? int(knobs["resource_count"]) : 0;
    if (resource_count <= 0) return fail("no_resources");
    const int dt_days = std::max(1, std::min(30, knobs.has("dt_days") ? int(knobs["dt_days"]) : 1));
    PackedFloat32Array regen_factors = knobs.has("regen_factors")
        ? PackedFloat32Array(knobs["regen_factors"]) : PackedFloat32Array();
    const int64_t expected_regen_factor_count = int64_t(resource_count) * int64_t(n_cells);
    if (!regen_factors.is_empty() && regen_factors.size() != expected_regen_factor_count)
        return fail("regen_factor_array_size_mismatch");
    const float * const regen_factor_data = regen_factors.is_empty()
        ? nullptr : regen_factors.ptr();
    int32_t active_regen_factor_count = 0;
    for (int64_t index = 0; index < regen_factors.size(); ++index) {
        const float factor = regen_factor_data[index];
        if (!std::isfinite(factor) || factor < 0.0f)
            return fail("regen_factor_array_value_invalid");
        if (std::fabs(factor - 1.0f) > 1e-7f) ++active_regen_factor_count;
    }

    if (!knobs.has("reserve_slots") || !knobs.has("extra_change_slots") || !knobs.has("habitat_modes") ||
        !knobs.has("temp_lo") || !knobs.has("temp_hi") ||
        !knobs.has("temperature_signals") || !knobs.has("moisture_signals") ||
        !knobs.has("gen_base") || !knobs.has("gen_temp") || !knobs.has("gen_moisture") || !knobs.has("gen_self") ||
        !knobs.has("decay_base") || !knobs.has("decay_temp") || !knobs.has("decay_moisture") || !knobs.has("decay_self") ||
        !knobs.has("climate_temp_opt") || !knobs.has("climate_temp_tol") ||
        !knobs.has("climate_moisture_opt") || !knobs.has("climate_moisture_tol") ||
        !knobs.has("runtime_climate_fit_weight") || !knobs.has("decay_stress") ||
        !knobs.has("ecology_capacity") || !knobs.has("ecology_growth_rate") ||
        !knobs.has("ecology_immigration") || !knobs.has("ecology_stress_mortality_rate")) {
        return fail("knobs_missing_keys");
    }

    PackedStringArray reserve_slots = knobs["reserve_slots"];
    PackedStringArray extra_change_slots = knobs["extra_change_slots"];
    PackedInt32Array habitat_modes = knobs["habitat_modes"];
    PackedFloat32Array temp_lo = knobs["temp_lo"];
    PackedFloat32Array temp_hi = knobs["temp_hi"];
    PackedInt32Array temperature_signals = knobs["temperature_signals"];
    PackedInt32Array moisture_signals = knobs["moisture_signals"];
    PackedFloat32Array gen_base = knobs["gen_base"];
    PackedFloat32Array gen_temp = knobs["gen_temp"];
    PackedFloat32Array gen_moisture = knobs["gen_moisture"];
    PackedFloat32Array gen_self = knobs["gen_self"];
    PackedFloat32Array decay_base = knobs["decay_base"];
    PackedFloat32Array decay_temp = knobs["decay_temp"];
    PackedFloat32Array decay_moisture = knobs["decay_moisture"];
    PackedFloat32Array decay_self = knobs["decay_self"];
    PackedFloat32Array climate_temp_opt = knobs["climate_temp_opt"];
    PackedFloat32Array climate_temp_tol = knobs["climate_temp_tol"];
    PackedFloat32Array climate_moisture_opt = knobs["climate_moisture_opt"];
    PackedFloat32Array climate_moisture_tol = knobs["climate_moisture_tol"];
    PackedFloat32Array runtime_climate_fit_weight = knobs["runtime_climate_fit_weight"];
    PackedFloat32Array decay_stress = knobs["decay_stress"];
    PackedFloat32Array ecology_capacity = knobs["ecology_capacity"];
    PackedFloat32Array ecology_growth_rate = knobs["ecology_growth_rate"];
    PackedFloat32Array ecology_immigration = knobs["ecology_immigration"];
    PackedFloat32Array ecology_stress_mortality_rate = knobs["ecology_stress_mortality_rate"];

    if (reserve_slots.size() < resource_count || extra_change_slots.size() < resource_count ||
        habitat_modes.size() < resource_count || temp_lo.size() < resource_count || temp_hi.size() < resource_count ||
        temperature_signals.size() < resource_count || moisture_signals.size() < resource_count ||
        gen_base.size() < resource_count || gen_temp.size() < resource_count ||
        gen_moisture.size() < resource_count || gen_self.size() < resource_count ||
        decay_base.size() < resource_count || decay_temp.size() < resource_count ||
        decay_moisture.size() < resource_count || decay_self.size() < resource_count ||
        climate_temp_opt.size() < resource_count || climate_temp_tol.size() < resource_count ||
        climate_moisture_opt.size() < resource_count || climate_moisture_tol.size() < resource_count ||
        runtime_climate_fit_weight.size() < resource_count || decay_stress.size() < resource_count ||
        ecology_capacity.size() < resource_count || ecology_growth_rate.size() < resource_count ||
        ecology_immigration.size() < resource_count ||
        ecology_stress_mortality_rate.size() < resource_count) {
        return fail("knob_array_size_mismatch");
    }

    auto slot_ok_f32 = [&](int sid) -> bool { return int(_slots.write[sid].arr_f32.size()) >= n_cells; };
    if (!slot_ok_f32(sid_temp) || !slot_ok_f32(sid_temp_30d) ||
        !slot_ok_f32(sid_moist) || !slot_ok_f32(sid_plant_water))
        return fail("climate_slot_size_mismatch");

    const float * const __restrict T = _slots.write[sid_temp].arr_f32.ptr();
    const float * const __restrict T30 = _slots.write[sid_temp_30d].arr_f32.ptr();
    const float * const __restrict M = _slots.write[sid_moist].arr_f32.ptr();
    const float * const __restrict PLANT_WATER = _slots.write[sid_plant_water].arr_f32.ptr();
    const bool have_water = (sid_water >= 0 && int(_slots.write[sid_water].arr_u8.size()) >= n_cells);
    const uint8_t * const __restrict WATER = have_water ? _slots.write[sid_water].arr_u8.ptr() : nullptr;
    const bool have_habitat = (sid_habitat >= 0 &&
        int(_slots.write[sid_habitat].arr_u8.size()) >= n_cells);
    const uint8_t * const __restrict HABITAT =
        have_habitat ? _slots.write[sid_habitat].arr_u8.ptr() : nullptr;

    // Benchmark-only 旁路开关（默认 false，生产路径完全不变）：
    //   bench_force_scalar=true → 跳过 AVX2 SIMD 块，仅走标量（隔离 SIMD 收益）；
    //   bench_force_seq=true    → 强制单线程 n_tasks=1（隔离多核收益）。
    const bool force_scalar = knobs.has("bench_force_scalar") && bool(knobs["bench_force_scalar"]);
    const bool force_seq = knobs.has("bench_force_seq") && bool(knobs["bench_force_seq"]);
    const int n_tasks_hint = force_seq ? 1 : 0;

    const auto t_setup = std::chrono::high_resolution_clock::now();

    PackedStringArray published_slots;
    int published_count = 0;
    int skipped_static_resources = 0;
    double loop_ms = 0.0;
    double flush_ms = 0.0;
    DeltaEmit delta_acc;  // total_delta 跨资源累加（reduce 目标）
    std::vector<NatResRuntime> dynamic_resources;
    dynamic_resources.reserve(static_cast<size_t>(resource_count));
    constexpr int NATRES_PARALLEL_SEQ_THRESHOLD = 100000;
    bool mt_candidate = false;

    for (int r = 0; r < resource_count; ++r) {
        const int sid = component_id(StringName(reserve_slots[r]));
        const int sid_extra = component_id(StringName(extra_change_slots[r]));
        if (sid < 0 || sid_extra < 0 || !slot_ok_f32(sid) || !slot_ok_f32(sid_extra)) {
            // schema 缺失或尺寸不符：跳过该资源，但不整体失败（其余资源仍可发布）。
            continue;
        }

        const float lo = temp_lo[r];
        const float hi = temp_hi[r];
        const float inv_span = (hi > lo) ? (1.0f / (hi - lo)) : 0.0f;
        const int habitat_mode = habitat_modes[r];
        if (habitat_mode < 0 || habitat_mode > 5) continue;
        const bool land_gate = habitat_mode == 1 && have_water;
        const uint8_t habitat_bit = habitat_mode == 2 ? uint8_t{2} :
                                    (habitat_mode == 3 ? uint8_t{4} :
                                     (habitat_mode == 4 ? uint8_t{8} :
                                      (habitat_mode == 5 ? uint8_t{2 | 8} : uint8_t{0})));
        const float gb = gen_base[r], gt = gen_temp[r], gm = gen_moisture[r], gs = gen_self[r];
        const float db = decay_base[r], dt = decay_temp[r], dm = decay_moisture[r], ds = decay_self[r];
        const float stress = decay_stress[r];
        const bool use_ecology = ecology_capacity[r] > 0.0f;
        float * const X = _slots.write[sid_extra].arr_f32.ptrw();
        bool has_extra_change = false;
        for (int i = 0; i < n_cells; ++i) {
            if (X[i] != 0.0f) {
                has_extra_change = true;
                break;
            }
        }
        const bool has_natural_dynamics = gb != 0.0f || gt != 0.0f || gm != 0.0f || gs != 0.0f ||
                db != 0.0f || dt != 0.0f || dm != 0.0f || ds != 0.0f || stress != 0.0f ||
                use_ecology;
        if (!has_natural_dynamics && !has_extra_change) {
            ++skipped_static_resources;
            continue;
        }

        // ── 代数化简：把无适宜度/无 extra 的公式收成 P = C0 + C1*tn + C2*m ──
        float L = ds;
        if (L < 0.0f) L = 0.0f;  // 负自系数（误配）兜底，保持无条件稳定
        NatResRuntime rr;
        rr.sid = sid;
        rr.sid_extra = sid_extra;
        rr.resource_index = r;
        rr.R = _slots.write[sid].arr_f32.ptrw();
        rr.X = X;
        rr.temperature = temperature_signals[r] == 1 ? T30 : T;
        rr.moisture = moisture_signals[r] == 1 ? PLANT_WATER : M;
        rr.lo = lo;
        rr.inv_span = inv_span;
        rr.land_gate = land_gate;
        rr.habitat_bit = habitat_bit;
        rr.use_extra = has_extra_change;
        rr.c0 = gb + gs - db;
        rr.c1 = gt - dt;
        rr.c2 = gm - dm;
        rr.inv_denom = 1.0f / (1.0f + L);
        rr.use_climate_fit = runtime_climate_fit_weight[r] != 0.0f || stress != 0.0f ||
                             use_ecology;
        rr.gb = gb;
        rr.gt = gt;
        rr.gm = gm;
        rr.gs = gs;
        rr.db = db;
        rr.dt = dt;
        rr.dm = dm;
        rr.ds = ds;
        rr.climate_temp_opt = climate_temp_opt[r];
        rr.climate_temp_tol = climate_temp_tol[r];
        rr.climate_moisture_opt = climate_moisture_opt[r];
        rr.climate_moisture_tol = climate_moisture_tol[r];
        rr.runtime_fit_weight = runtime_climate_fit_weight[r];
        rr.decay_stress = stress;
        rr.ecology_capacity = ecology_capacity[r];
        rr.ecology_growth_rate = ecology_growth_rate[r];
        rr.ecology_immigration = ecology_immigration[r];
        rr.ecology_stress_mortality_rate = ecology_stress_mortality_rate[r];
        rr.use_ecology = use_ecology;
        rr.has_natural_dynamics = has_natural_dynamics;
        rr.regen_factors = regen_factor_data == nullptr
            ? nullptr : regen_factor_data + int64_t(r) * int64_t(n_cells);
        if (rr.regen_factors != nullptr) {
            for (int32_t cell = 0; cell < n_cells; ++cell) {
                if (std::fabs(rr.regen_factors[cell] - 1.0f) > 1e-7f) {
                    rr.has_regen_modifier = true;
                    break;
                }
            }
        }
        dynamic_resources.push_back(rr);
    }

    if (!dynamic_resources.empty()) {
        mt_candidate = !force_seq
                && n_cells >= NATRES_PARALLEL_SEQ_THRESHOLD
                && pk::parallel_default_n_tasks(n_cells) > 1;
        // 多核：只 dispatch 一次，按 cell range 分块；task 内循环所有动态资源。
        // 旧实现每个资源各 dispatch 一次，2400 cell × 9 resource 会产生 9 轮
        // WorkerThreadPool 固定开销。融合后仍按资源内 8-cell SIMD，结果数组一致。
        auto run_range = [&](int begin, int end, DeltaEmit &local) {
            double seg = 0.0;
            for (const NatResRuntime &rr : dynamic_resources) {
                float * const __restrict R = rr.R;
                int i = begin;
#if defined(PK_HAVE_AVX2) && PK_HAVE_AVX2
                if (!force_scalar && dt_days <= 1 && !rr.use_climate_fit &&
                    !rr.use_extra && rr.habitat_bit == 0 && !rr.has_regen_modifier) {
                    const __m256 vlo = _mm256_set1_ps(rr.lo);
                    const __m256 vinv_span = _mm256_set1_ps(rr.inv_span);
                    const __m256 vc0 = _mm256_set1_ps(rr.c0);
                    const __m256 vc1 = _mm256_set1_ps(rr.c1);
                    const __m256 vc2 = _mm256_set1_ps(rr.c2);
                    const __m256 vinv_denom = _mm256_set1_ps(rr.inv_denom);
                    const __m256 vzero = _mm256_setzero_ps();
                    const __m256 vone = _mm256_set1_ps(1.0f);
                    __m256 vacc = _mm256_setzero_ps();
                    const int simd_end = end - ((end - begin) % 8);
                    for (; i + 8 <= simd_end; i += 8) {
                        natres_simd_block(R, rr.temperature, rr.moisture, WATER, rr.land_gate, i,
                                          vlo, vinv_span, vc0, vc1, vc2,
                                          vinv_denom, vzero, vone, vacc);
                    }
                    seg += double(natres_hsum256(vacc));
                }
#endif
                for (; i < end; ++i) {  // 标量尾段（AVX2）/ 全量（非 AVX2 构建）
                    if (rr.habitat_bit != 0 &&
                        (!have_habitat || (HABITAT[i] & rr.habitat_bit) == 0)) {
                        if (R[i] != 0.0f) {
                            seg -= double(R[i]);
                            R[i] = 0.0f;
                        }
                        if (rr.use_extra) rr.X[i] = 0.0f;
                        continue;
                    }
                    if (rr.land_gate && WATER[i] != 0) {
                        if (R[i] != 0.0f) {
                            seg -= double(R[i]);
                            R[i] = 0.0f;
                        }
                        if (rr.use_extra) rr.X[i] = 0.0f;
                        continue;
                    }
                    const float reserve = R[i];
                    const float extra_change = rr.use_extra ? rr.X[i] : 0.0f;
                    float v = reserve;
                    if (!rr.has_natural_dynamics && rr.use_extra) {
                        // Province-scale deposits can exceed float32's unit precision. Preserve
                        // the unrepresentable extraction remainder in the existing extra slot so
                        // repeated small mine deltas eventually reduce the authoritative reserve.
                        const double exact = std::max(
                            0.0, static_cast<double>(reserve) +
                                 static_cast<double>(extra_change));
                        v = static_cast<float>(exact);
                        rr.X[i] = exact > 0.0
                            ? static_cast<float>(exact - static_cast<double>(v))
                            : 0.0f;
                    } else {
                        const float reserve_after_external =
                            std::max(0.0f, reserve + extra_change);
                        v = rr.use_ecology
                                ? natres_step_scalar_ecology_dt(
                                    rr.temperature[i], rr.moisture[i], reserve, extra_change, rr, dt_days)
                                : (rr.use_climate_fit
                                    ? natres_step_scalar_fit_dt(
                                        rr.temperature[i], rr.moisture[i], reserve, extra_change, rr, dt_days)
                                    : natres_step_scalar_dt(rr.temperature[i], rr.moisture[i], reserve,
                                                           rr.lo, rr.inv_span,
                                                           rr.c0, rr.c1, rr.c2,
                                                           rr.inv_denom, extra_change,
                                                           dt_days));
                        if (rr.has_regen_modifier && v > reserve_after_external) {
                            v = reserve_after_external +
                                (v - reserve_after_external) * rr.regen_factors[i];
                        }
                        if (rr.use_extra) rr.X[i] = 0.0f;
                    }
                    seg += double(v - reserve);
                    R[i] = v;
                }
            }
            local.sum += seg;
        };

        const auto t_loop0 = std::chrono::high_resolution_clock::now();
        // 2400-cell mobile maps are too small for WTP to win even after fusion:
        // SIMD+1T beats SIMD+MT because dispatch/wait dominates the math. Keep
        // the same fused body, but let only larger maps cross into WTP.
        pk::parallel_for_range_with_emit<DeltaEmit>("pk_natural_resource_fused", n_cells,
                                                    n_tasks_hint, NATRES_PARALLEL_SEQ_THRESHOLD,
                                                    delta_acc, run_range);
        const auto t_loop1 = std::chrono::high_resolution_clock::now();
        loop_ms = std::chrono::duration<double, std::milli>(t_loop1 - t_loop0).count();

        for (const NatResRuntime &rr : dynamic_resources) {
            const auto t_flush0 = std::chrono::high_resolution_clock::now();
            _flush_slot_to_map(rr.sid);
            if (rr.use_extra) _flush_slot_to_map(rr.sid_extra);
            const auto t_flush1 = std::chrono::high_resolution_clock::now();
            flush_ms += std::chrono::duration<double, std::milli>(t_flush1 - t_flush0).count();
            published_slots.append(reserve_slots[rr.resource_index]);
            if (rr.use_extra) published_slots.append(extra_change_slots[rr.resource_index]);
            ++published_count;
        }
    }

    const auto t1 = std::chrono::high_resolution_clock::now();
    out["done"] = true;
    out["path"] = "gdext";
    const bool all_static = skipped_static_resources >= resource_count;
    out["published_to_slot"] = published_count > 0 || all_static;
    out["published_slots"] = published_slots;
    out["resource_count"] = resource_count;
    out["published_resource_count"] = published_count;
    out["input_resource_count"] = resource_count;
    out["n_cells"] = n_cells;
    out["dt_days"] = dt_days;
    out["total_delta"] = delta_acc.sum;
    out["native_ms"] = std::chrono::duration<double, std::milli>(t1 - t0).count();
    out["compute_ms"] = std::chrono::duration<double, std::milli>(t1 - t_setup).count();
    out["setup_ms"] = std::chrono::duration<double, std::milli>(t_setup - t0).count();
    out["loop_ms"] = loop_ms;
    out["flush_ms"] = flush_ms;
    out["loop_layout"] = mt_candidate ? "cell_range_fused_mt" : (dt_days > 1 ? "cell_range_fused_seq_dt" : "cell_range_fused_seq");
    out["loop_dispatches"] = mt_candidate ? 1 : 0;
    out["skipped_static_resources"] = skipped_static_resources;
    out["regen_modifier_snapshot_version"] = knobs.has("regen_modifier_snapshot_version")
        ? int64_t(knobs["regen_modifier_snapshot_version"]) : int64_t{0};
    out["active_regen_factor_count"] = active_regen_factor_count;
    if (published_count == 0 && !all_static) out["fallback_reason"] = "no_publishable_resource";
    return out;
}

} // namespace pk
