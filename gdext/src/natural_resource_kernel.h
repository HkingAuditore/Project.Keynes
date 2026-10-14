#pragma once

// Natural resource per-cell kernel shared by the main-thread
// DCWorldExt::run_natural_resource_pass and the worker-owned economy reserve
// lanes. Bodies must stay identical between the two callers: the worker path
// is only reproducible against the main-thread pass if both evaluate the same
// float expressions in the same order.

#include "runtime_climate_pass_math.h"

#include <algorithm>
#include <cmath>
#include <cstdint>

namespace pk {

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

inline uint8_t natres_habitat_bit(int habitat_mode) {
    return habitat_mode == 2 ? uint8_t{2} :
           (habitat_mode == 3 ? uint8_t{4} :
            (habitat_mode == 4 ? uint8_t{8} :
             (habitat_mode == 5 ? uint8_t{2 | 8} : uint8_t{0})));
}

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

inline void natres_apply_one_cell(const NatResRuntime &rr, int i, int dt_days,
                                  bool have_habitat, const uint8_t *HABITAT,
                                  bool have_water, const uint8_t *WATER,
                                  double &seg) {
    if (rr.habitat_bit != 0 &&
        (!have_habitat || (HABITAT[i] & rr.habitat_bit) == 0)) {
        if (rr.R[i] != 0.0f) {
            seg -= double(rr.R[i]);
            rr.R[i] = 0.0f;
        }
        if (rr.use_extra) rr.X[i] = 0.0f;
        return;
    }
    if (rr.land_gate && have_water && WATER != nullptr && WATER[i] != 0) {
        if (rr.R[i] != 0.0f) {
            seg -= double(rr.R[i]);
            rr.R[i] = 0.0f;
        }
        if (rr.use_extra) rr.X[i] = 0.0f;
        return;
    }
    const float reserve = rr.R[i];
    const float extra_change = rr.use_extra ? rr.X[i] : 0.0f;
    float v = reserve;
    if (!rr.has_natural_dynamics && rr.use_extra) {
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
    rr.R[i] = v;
}

// Fills the per-resource constants of rr exactly as run_natural_resource_pass
// derives them from its knobs. Slot pointers, regen factors and land_gate are
// left to the caller.
inline void natres_init_constants(NatResRuntime &rr,
                                  float lo, float hi,
                                  float gb, float gt, float gm, float gs,
                                  float db, float dt, float dm, float ds,
                                  float temp_opt, float temp_tol,
                                  float moisture_opt, float moisture_tol,
                                  float fit_weight, float stress,
                                  float ecology_capacity, float ecology_growth_rate,
                                  float ecology_immigration,
                                  float ecology_stress_mortality_rate) {
    const float inv_span = (hi > lo) ? (1.0f / (hi - lo)) : 0.0f;
    const bool use_ecology = ecology_capacity > 0.0f;
    float L = ds;
    if (L < 0.0f) L = 0.0f;
    rr.lo = lo;
    rr.inv_span = inv_span;
    rr.c0 = gb + gs - db;
    rr.c1 = gt - dt;
    rr.c2 = gm - dm;
    rr.inv_denom = 1.0f / (1.0f + L);
    rr.use_climate_fit = fit_weight != 0.0f || stress != 0.0f || use_ecology;
    rr.gb = gb;
    rr.gt = gt;
    rr.gm = gm;
    rr.gs = gs;
    rr.db = db;
    rr.dt = dt;
    rr.dm = dm;
    rr.ds = ds;
    rr.climate_temp_opt = temp_opt;
    rr.climate_temp_tol = temp_tol;
    rr.climate_moisture_opt = moisture_opt;
    rr.climate_moisture_tol = moisture_tol;
    rr.runtime_fit_weight = fit_weight;
    rr.decay_stress = stress;
    rr.ecology_capacity = ecology_capacity;
    rr.ecology_growth_rate = ecology_growth_rate;
    rr.ecology_immigration = ecology_immigration;
    rr.ecology_stress_mortality_rate = ecology_stress_mortality_rate;
    rr.use_ecology = use_ecology;
    rr.has_natural_dynamics = gb != 0.0f || gt != 0.0f || gm != 0.0f || gs != 0.0f ||
        db != 0.0f || dt != 0.0f || dm != 0.0f || ds != 0.0f || stress != 0.0f ||
        use_ecology;
}

} // namespace pk
