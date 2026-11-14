#include "runtime_climate_passes.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <vector>

namespace pk {
namespace pk_async_climate {

// ─── albedo（stage 8）─────────────────────────────────────────────────
//
// 从 DCWorldExt::run_albedo_pass 的主循环逐字搬来（原 lambda run_range）。水格跳过，
// 陆格按 vegetation 查反照率、雪/冰川抬底，再把 (reference - alb) * gain 叠到温度上并
// clamp 到 [0,1]。零邻居、零状态，是 stage 8..13 里唯一能原样搬迁的一段。
void albedo_apply_pure(const ClimateAlbedoKnobs &knobs,
                       const uint8_t *is_water,
                       const uint8_t *vegetation,
                       const uint8_t *cover,
                       const float *albedo_table,
                       int albedo_size,
                       float *temp,
                       int n_cells) {
    if (!knobs.ran || n_cells <= 0 || albedo_size <= 0) return;
    if (is_water == nullptr || vegetation == nullptr || cover == nullptr ||
        albedo_table == nullptr || temp == nullptr) {
        return;
    }
    for (int i = 0; i < n_cells; ++i) {
        if (is_water[i] != 0) continue;                     // skip water cells
        const uint8_t veg_id = vegetation[i];
        float alb = (veg_id < albedo_size) ? albedo_table[veg_id] : 0.0f;
        const uint8_t cover_id = cover[i];
        if (cover_id == knobs.cover_snow_id ||
            cover_id == knobs.cover_glacier_id) {
            if (alb < knobs.snow_cover_albedo) alb = knobs.snow_cover_albedo;
        }
        const float dt = (knobs.reference_albedo - alb) * knobs.temp_gain;
        float v = temp[i] + dt;
        if (v < 0.0f) v = 0.0f;
        else if (v > 1.0f) v = 1.0f;
        temp[i] = v;
    }
}


// ─── climate_feedback（stage 10）───────────────────────────────────────
//
// 从 DCWorldExt::run_climate_feedback_pass 的 run_range lambda 逐字搬来。生产侧原有
// 三份逐字副本（run_climate_feedback_pass / _thread / run_stage_b_pass ③ 段），全部
// 转发到这里。
//
// 两段独立的作用：① 海洋 TTA 经海岸格漂移进 base_moisture（年尺度，每日 clamp）；
// ② 天气强度按类型折成 precip，累加进 soil_moisture / base_moisture / VGP。
// ② 段以 wi < 0.01 提前 continue，所以 ① 段必须排在它前面 —— 顺序是行为的一部分。
void climate_feedback_apply_pure(const ClimateFeedbackKnobs &knobs,
                                 const uint8_t *is_water,
                                 const uint8_t *weather_type,
                                 const float *weather_intensity,
                                 const uint8_t *weather_field_init,
                                 const int32_t *neighbor_indices,
                                 const float *temp_transport_anomaly,
                                 float *base_moisture,
                                 float *soil_moisture,
                                 float *veg_growth_pressure,
                                 int begin,
                                 int end) {
    if (!knobs.ran || begin >= end) return;
    if (is_water == nullptr || weather_type == nullptr ||
        weather_intensity == nullptr || weather_field_init == nullptr ||
        neighbor_indices == nullptr || temp_transport_anomaly == nullptr ||
        base_moisture == nullptr || soil_moisture == nullptr) {
        return;
    }
    const float soil_gain = knobs.soil_gain;
    const float veg_gain = knobs.veg_gain;
    const float scale = knobs.scale;
    const float per_day_clamp = knobs.per_day_clamp;
    const float ocean_drift_gain = knobs.ocean_drift_gain;
    const float base_m_gain = knobs.base_moisture_gain;
    const bool write_vgp =
        knobs.write_weather_veg_pressure && veg_growth_pressure != nullptr;

    for (int i = begin; i < end; ++i) {
        if (is_water[i] != 0) continue;                        // skip water cells

        // ① ocean → base_moisture drift（年尺度，每日 |Δ| ≤ per_day_clamp）
        if (ocean_drift_gain > 0.0f) {
            float sum_an = 0.0f;
            int   n_water = 0;
            const int base = i * 6;
            for (int d = 0; d < 6; ++d) {
                const int32_t ni = neighbor_indices[base + d];
                if (ni < 0) continue;
                if (is_water[ni] != 0) {
                    sum_an += temp_transport_anomaly[ni];
                    n_water += 1;
                }
            }
            if (n_water > 0) {
                const float avg_an = sum_an / float(n_water);
                if (std::fabs(avg_an) > 0.005f) {
                    float coastal_ratio = float(n_water) / 6.0f;
                    if (coastal_ratio > 1.0f) coastal_ratio = 1.0f;
                    float d_base = ocean_drift_gain * avg_an * coastal_ratio * scale;
                    if (d_base < -per_day_clamp) d_base = -per_day_clamp;
                    else if (d_base > per_day_clamp) d_base = per_day_clamp;
                    float bm = base_moisture[i] + d_base;
                    if (bm < 0.0f) bm = 0.0f;
                    else if (bm > 1.0f) bm = 1.0f;
                    base_moisture[i] = bm;
                }
            }
        }

        // ② weather → soil / vegetation_growth_pressure 累加（小权重）
        const bool init = weather_field_init[i] != 0;
        const int   wt = init ? int(weather_type[i]) : -1;   // -1 = uninit (== CLEAR)
        const float wi = init ? weather_intensity[i] : 0.0f;
        if (wi < 0.01f) continue;

        float precip = 0.0f;
        if      (wt == knobs.wt_rain_id)     precip = wi;
        else if (wt == knobs.wt_storm_id)    precip = wi * 0.8f;
        else if (wt == knobs.wt_monsoon_id)  precip = wi * 1.2f;
        else if (wt == knobs.wt_blizzard_id) precip = wi * 0.3f;
        else if (wt == knobs.wt_drought_id)  precip = -wi * 0.6f;
        else if (wt == knobs.wt_heatwave_id) precip = -wi * 0.4f;
        // else: precip = 0.0 (CLEAR / FOG / etc.)

        // soil_moisture (clamp -0.5..0.5)
        float d_soil = soil_gain * precip * scale;
        if (d_soil < -per_day_clamp) d_soil = -per_day_clamp;
        else if (d_soil > per_day_clamp) d_soil = per_day_clamp;
        float soil = soil_moisture[i] + d_soil;
        if (soil < -0.5f) soil = -0.5f;
        else if (soil > 0.5f) soil = 0.5f;
        soil_moisture[i] = soil;

        // 让天气流动(2026-06-21)：weather → base_moisture 直接反馈。
        if (base_m_gain > 0.0f) {
            float d_bm = base_m_gain * precip * scale;
            if (d_bm < -per_day_clamp) d_bm = -per_day_clamp;
            else if (d_bm > per_day_clamp) d_bm = per_day_clamp;
            float bmw = base_moisture[i] + d_bm;
            if (bmw < 0.0f) bmw = 0.0f;
            else if (bmw > 1.0f) bmw = 1.0f;
            base_moisture[i] = bmw;
        }

        if (write_vgp) {
            // vegetation_growth_pressure (clamp -0.5..0.5)
            float d_veg = veg_gain * precip * scale;
            if (d_veg < -per_day_clamp) d_veg = -per_day_clamp;
            else if (d_veg > per_day_clamp) d_veg = per_day_clamp;
            float vg_v = veg_growth_pressure[i] + d_veg;
            if (vg_v < -0.5f) vg_v = -0.5f;
            else if (vg_v > 0.5f) vg_v = 0.5f;
            veg_growth_pressure[i] = vg_v;
        }
    }
}


// ─── vegetation_dynamics pure kernel（stage 9）─────────────────────────────
//
// S3 搬迁体：原位是 world_ext_climate.cpp 的三份逐字副本
// （run_vegetation_dynamics_pass / _thread / run_stage_b_pass ② 段）。逐字搬迁，
// 无算法改动。stress_enabled 分支合并了两处差异：
//   - 独立 pass 的退化条件 `target < low || (severe && target < high)`
//   - stage_b 的 `((stress && stress_max>0.65) || severe) && target < high`
//     后接 `else if (degrade && target < low)`
// 在 stress_enabled=false 时两者等价（stress_days == streak_days），所以一份实现
// 覆盖两条路径。

static inline float vegdyn_clamp01(float v) {
    if (v < 0.0f) return 0.0f;
    if (v > 1.0f) return 1.0f;
    return v;
}

static inline float vegdyn_compat_climate(
        int vg,
        float temp,
        float plant_water,
        int n_veg,
        const VegetationDynamicsTables &t) {
    if (vg < 0 || vg >= n_veg) return -1.0f;
    return pk_vegetation_climate_score_for_type(
        uint8_t(vg), temp, plant_water,
        t.ideal_temp[vg], t.ideal_moist[vg], t.temp_tol[vg], t.moist_tol[vg]);
}

static inline float vegdyn_compat_of(
        int vg,
        float temp,
        float plant_water,
        int n_veg,
        const VegetationDynamicsTables &t,
        uint8_t terrain,
        uint8_t landform) {
    const float climate = vegdyn_compat_climate(vg, temp, plant_water, n_veg, t);
    if (climate < 0.0f) return climate;
    return climate * pk_vegetation_terrain_weight(terrain, landform, uint8_t(vg), plant_water);
}

static inline uint8_t vegdyn_best_transition(
        uint8_t current,
        float temp,
        float plant_water,
        int n_veg,
        const VegetationDynamicsTables &t,
        uint8_t terrain,
        uint8_t landform,
        float &best_score) {
    uint8_t best = current;
    best_score = -1.0f;
    if (current >= n_veg) return best;
    for (int candidate = 1; candidate < n_veg; ++candidate) {
        if (candidate == current || !pk_vegetation_candidate_allowed(terrain, uint8_t(candidate))) continue;
        const float score = vegdyn_compat_of(
            candidate, temp, plant_water, n_veg, t, terrain, landform);
        if (score > best_score) {
            best = uint8_t(candidate);
            best_score = score;
        }
    }
    return best;
}

static inline float vegdyn_weather_stress(
        uint8_t v_id,
        int wt,
        float wi,
        int n_veg,
        int n_wt,
        int wt_pen_size,
        const VegetationDynamicsTables &t,
        float weather_penalty_scale) {
    const float base_pen = (wt >= 0 && wt < wt_pen_size) ? t.weather_penalty[wt] : 0.0f;
    float resist = 0.0f;
    if (v_id < n_veg && wt >= 0 && wt < n_wt) {
        resist = t.resistance[int(v_id) * n_wt + wt];
    }
    return base_pen * weather_penalty_scale * (wi > 0.0f ? wi : 0.0f) * (1.0f - resist);
}

void vegetation_dynamics_apply_pure(const VegetationDynamicsKnobs &knobs,
                                    const VegetationDynamicsTables &t,
                                    const VegetationDynamicsLanes &io,
                                    int begin,
                                    int end,
                                    VegetationDynamicsEmit &emit) {
    if (!knobs.ran || begin >= end) return;
    if (knobs.n_veg <= 0 || knobs.n_wt <= 0) return;
    if (t.ideal_temp == nullptr || t.ideal_moist == nullptr ||
        t.temp_tol == nullptr || t.moist_tol == nullptr ||
        t.weather_penalty == nullptr || t.resistance == nullptr ||
        t.next_up == nullptr) {
        return;
    }
    if (io.is_water == nullptr || io.terrain == nullptr || io.landform == nullptr ||
        io.vegetation == nullptr || io.temp_30d == nullptr || io.moisture == nullptr ||
        io.water_balance_30d == nullptr || io.weather_type == nullptr ||
        io.weather_intensity == nullptr || io.weather_field_init == nullptr ||
        io.plant_available_water == nullptr || io.vitality == nullptr ||
        io.low_streak == nullptr || io.high_streak == nullptr) {
        return;
    }
    const bool stress = knobs.stress_enabled;
    if (stress && (io.heat_stress == nullptr || io.drought_stress == nullptr ||
                   io.cold_stress == nullptr || io.regen_score == nullptr)) {
        return;
    }

    const int   n_veg = knobs.n_veg;
    const int   n_wt = knobs.n_wt;
    const int   wt_pen_size = knobs.wt_pen_size;
    const float scale = knobs.scale;
    const int   streak_days = knobs.streak_days;
    const float rate = knobs.vitality_change_rate;
    const float harshness = knobs.compat_harshness;
    const float low_thresh = knobs.low_threshold;
    const float high_thresh = knobs.high_threshold;
    const int   degrade_days = knobs.succession_degrade_days;
    const int   upgrade_days = knobs.succession_upgrade_days;
    const int   wt_clear_id = knobs.wt_clear_id;
    const uint8_t veg_none_id = knobs.veg_none_id;
    const float weather_penalty_scale = knobs.weather_penalty_scale;
    const float low_vitality_damping_threshold = knobs.low_vitality_damping_threshold;
    const int   succession_cooldown_days = knobs.succession_cooldown_days;
    const float stress_blend = knobs.stress_blend;

    for (int i = begin; i < end; ++i) {
        const uint8_t v_id = io.vegetation[i];
        const float soil_now = io.soil_moisture != nullptr ? io.soil_moisture[i] : 0.0f;
        const float plant_water = io.is_water[i] != 0 ? 0.0f : pk_plant_available_water(
            io.moisture[i], io.water_balance_30d[i], soil_now,
            knobs.plant_water_balance_weight, knobs.plant_soil_buffer_weight,
            knobs.plant_drought_penalty);
        io.plant_available_water[i] = plant_water;
        if (io.is_water[i] != 0 || v_id == veg_none_id) {
            io.vitality[i] = 0.0f;
            io.low_streak[i] = 0;
            io.high_streak[i] = 0;
            if (io.vegetation_growth_pressure != nullptr) io.vegetation_growth_pressure[i] = 0.0f;
            if (stress) {
                io.heat_stress[i] = 0.0f;
                io.drought_stress[i] = 0.0f;
                io.cold_stress[i] = 0.0f;
                io.regen_score[i] = 0.0f;
            }
            continue;
        }
        const uint8_t terrain = io.terrain[i];
        const uint8_t landform = io.landform[i];
        const float temp = io.temp_30d[i];
        const float compat = vegdyn_compat_of(v_id, temp, plant_water, n_veg, t, terrain, landform);

        int wt = wt_clear_id;
        float wi = 0.0f;
        const bool wt_init = io.weather_field_init[i] != 0;
        if (wt_init) {
            wt = int(io.weather_type[i]);
            wi = io.weather_intensity[i];
        }
        const float weather_stress = vegdyn_weather_stress(
            v_id, wt, wi, n_veg, n_wt, wt_pen_size, t, weather_penalty_scale);

        float stress_max = 0.0f;
        float regen_score = 0.0f;
        if (stress) {
            float heat_input = 0.0f;
            float cold_input = 0.0f;
            float drought_input = 0.0f;
            if (v_id < n_veg) {
                const float temp_tol = std::max(t.temp_tol[v_id], 0.05f);
                const float moist_tol = std::max(t.moist_tol[v_id], 0.05f);
                heat_input = vegdyn_clamp01((temp - (t.ideal_temp[v_id] + temp_tol)) / temp_tol);
                cold_input = vegdyn_clamp01(((t.ideal_temp[v_id] - temp_tol) - temp) / temp_tol);
                const float water_deficit = vegdyn_clamp01(((t.ideal_moist[v_id] - moist_tol) - plant_water) / moist_tol);
                drought_input = water_deficit;
                if (wt_init && wt == knobs.wt_drought_id) {
                    drought_input = std::max(drought_input, water_deficit * vegdyn_clamp01(wi));
                }
            }
            if (wt_init) {
                const float wi_clamped = vegdyn_clamp01(wi);
                if (wt == knobs.wt_heatwave_id) {
                    heat_input = std::max(heat_input, wi_clamped);
                } else if (wt == knobs.wt_blizzard_id) {
                    cold_input = std::max(cold_input, wi_clamped);
                }
            }
            const float regen_input = vegdyn_clamp01(compat * (1.0f - weather_stress) * (0.5f + 0.5f * plant_water));
            const float heat = io.heat_stress[i] + (heat_input - io.heat_stress[i]) * stress_blend;
            const float drought = io.drought_stress[i] + (drought_input - io.drought_stress[i]) * stress_blend;
            const float cold = io.cold_stress[i] + (cold_input - io.cold_stress[i]) * stress_blend;
            const float regen = io.regen_score[i] + (regen_input - io.regen_score[i]) * stress_blend;
            io.heat_stress[i] = heat;
            io.drought_stress[i] = drought;
            io.cold_stress[i] = cold;
            io.regen_score[i] = regen;
            stress_max = std::max(heat, std::max(drought, cold));
            regen_score = regen;
        }

        float water_pressure = io.water_balance_30d[i] * 0.18f + soil_now * 0.10f;
        if (water_pressure < -0.12f) water_pressure = -0.12f;
        else if (water_pressure > 0.12f) water_pressure = 0.12f;
        const float target = stress
            ? vegdyn_clamp01(compat + water_pressure - weather_stress - stress_max * 0.25f + regen_score * 0.10f)
            : vegdyn_clamp01(compat + water_pressure - weather_stress);
        const float prev_vit = io.vitality[i];
        float dv = (target - prev_vit) * rate;
        if (dv < 0.0f) {
            dv *= harshness;
            if (low_vitality_damping_threshold > 0.0f && prev_vit < low_vitality_damping_threshold) {
                float damping = prev_vit / low_vitality_damping_threshold;
                if (damping < 0.25f) damping = 0.25f;
                else if (damping > 1.0f) damping = 1.0f;
                dv *= damping;
            }
        }
        if (io.vegetation_growth_pressure != nullptr) {
            io.vegetation_growth_pressure[i] = target - prev_vit;
        }

        const float vit = vegdyn_clamp01(prev_vit + dv * scale);
        io.vitality[i] = vit;

        int ls = io.low_streak[i];
        int hs = io.high_streak[i];
        if (ls < 0 || hs < 0) {
            ls += streak_days; if (ls > 0) ls = 0;
            hs += streak_days; if (hs > 0) hs = 0;
            io.low_streak[i] = ls;
            io.high_streak[i] = hs;
            continue;
        }

        const uint8_t nxt_up_for_streak = (v_id < n_veg) ? t.next_up[v_id] : v_id;
        const float nxt_up_score_for_streak = (nxt_up_for_streak != v_id &&
                                               pk_vegetation_candidate_allowed(terrain, nxt_up_for_streak))
            ? vegdyn_compat_of(nxt_up_for_streak, temp, plant_water, n_veg, t, terrain, landform)
            : -1.0f;
        const bool upgrade_candidate =
            nxt_up_for_streak != v_id &&
            nxt_up_score_for_streak >= compat + knobs.succession_min_compat_gain &&
            nxt_up_score_for_streak >= high_thresh;
        float best_transition_score = -1.0f;
        const uint8_t best_transition = vegdyn_best_transition(
            v_id, temp, plant_water, n_veg, t, terrain, landform, best_transition_score);
        const bool degrade_candidate = best_transition != v_id &&
            best_transition_score >= compat + knobs.succession_min_compat_gain;
        const bool severe_biome_mismatch = pk_vegetation_needs_biome_reconcile(terrain, v_id);
        if (degrade_candidate &&
            ((stress && stress_max > 0.65f) || severe_biome_mismatch) &&
            target < high_thresh) {
            const int stress_days = std::max(streak_days, int(std::round(float(streak_days) * stress_max)));
            ls += stress_days;
            hs = 0;
        } else if (degrade_candidate && target < low_thresh) {
            ls += streak_days;
            hs = 0;
        } else if (upgrade_candidate && vit > low_thresh && target > low_thresh) {
            hs += streak_days;
            ls = 0;
        } else {
            ls -= streak_days; if (ls < 0) ls = 0;
            hs -= streak_days; if (hs < 0) hs = 0;
        }

        bool fired = false;
        if (ls >= degrade_days) {
            if (degrade_candidate) {
                emit.indices.push_back(i);
                emit.to_veg.push_back(best_transition);
                const int cooldown = succession_cooldown_days > 0 ? -succession_cooldown_days : 0;
                ls = cooldown;
                hs = cooldown;
                fired = true;
            } else {
                // 没有下家：把 ls 清零防止反复触发（与 GDScript 一致）
                ls = 0;
            }
        }
        if (!fired && hs >= upgrade_days) {
            const uint8_t nxt = (v_id < n_veg) ? t.next_up[v_id] : v_id;
            const float nxt_sc = (nxt != v_id && pk_vegetation_candidate_allowed(terrain, nxt))
                ? vegdyn_compat_of(nxt, temp, plant_water, n_veg, t, terrain, landform) : -1.0f;
            if (nxt != v_id && nxt_sc >= compat + knobs.succession_min_compat_gain) {
                emit.indices.push_back(i);
                emit.to_veg.push_back(nxt);
                const int cooldown = succession_cooldown_days > 0 ? -succession_cooldown_days : 0;
                ls = cooldown;
                hs = cooldown;
            } else {
                hs = 0;
            }
        }
        io.low_streak[i] = ls;
        io.high_streak[i] = hs;
    }
}

} // namespace pk_async_climate
} // namespace pk
