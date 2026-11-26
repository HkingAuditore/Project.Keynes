#include "runtime_climate_passes.h"
#include "parallel_dispatcher.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <vector>

namespace pk {
namespace pk_async_climate {

void weather_commit_pure(const WeatherCommitKnobs &knobs,
                         const WeatherCommitLanes &lanes,
                         WeatherCommitStats &stats) {
    stats = WeatherCommitStats{};
    if (knobs.n_cells <= 0) return;
    if (lanes.next_vapor == nullptr || lanes.next_cloud == nullptr ||
        lanes.next_precip == nullptr || lanes.next_instability == nullptr ||
        lanes.next_intensity == nullptr || lanes.next_convergence == nullptr ||
        lanes.next_type == nullptr || lanes.prev_vapor == nullptr ||
        lanes.neighbor_indices == nullptr) {
        return;
    }
    if (lanes.intensity == nullptr || lanes.cloud == nullptr ||
        lanes.precip == nullptr || lanes.vapor == nullptr ||
        lanes.convergence == nullptr || lanes.instability == nullptr ||
        lanes.type == nullptr || lanes.field_init == nullptr ||
        lanes.dirty == nullptr) {
        return;
    }
    // ── 前言：把 knobs/lanes 摊回生产里的局部名，计算体得以原样保留 ──
    const int n_cells = knobs.n_cells;
    const bool refresh_convergence = knobs.refresh_convergence;
    const bool weather_transition_enabled = knobs.weather_transition_enabled;
    const float transition_rate = knobs.transition_rate;
    const float transition_dt_days = knobs.transition_dt_days;

    const int32_t * const __restrict NB = lanes.neighbor_indices;
    const float * const __restrict PREV_VAP = lanes.prev_vapor;
    const float * const __restrict NEXT_VAP = lanes.next_vapor;
    const float * const __restrict NEXT_CLD = lanes.next_cloud;
    const float * const __restrict NEXT_CW = lanes.next_cloud_water;
    const float * const __restrict NEXT_PRE = lanes.next_precip;
    const float * const __restrict NEXT_INS = lanes.next_instability;
    const float * const __restrict NEXT_INT = lanes.next_intensity;
    const float * const __restrict NEXT_CNV = lanes.next_convergence;
    const int32_t * const __restrict NEXT_TYP = lanes.next_type;

    float * const __restrict W_INT = lanes.intensity;
    float * const __restrict W_CLD = lanes.cloud;
    float * const __restrict W_CW = lanes.cloud_water;
    float * const __restrict W_PRE = lanes.precip;
    uint8_t * const __restrict W_TYP = lanes.type;
    uint8_t * const __restrict W_PREV = lanes.prev_type;
    uint8_t * const __restrict W_TARGET = lanes.target_type;
    float * const __restrict W_ALPHA = lanes.transition_alpha;
    float * const __restrict W_VAP = lanes.vapor;
    float * const __restrict W_CNV = lanes.convergence;
    float * const __restrict W_INS = lanes.instability;
    uint8_t * const __restrict W_FIN = lanes.field_init;
    uint8_t * const __restrict W_DIRTY = lanes.dirty;

    // LUT 是纯输出；生产总会给一块 lut_slots*4 的 buffer，worker 可以不要。
    uint8_t * const __restrict WX = lanes.lut;
    auto q01_byte_commit = [](float v) -> uint8_t {
        if (v <= 0.0f) return uint8_t(0);
        if (v >= 1.0f) return uint8_t(255);
        return uint8_t(std::clamp(int(std::round(double(v) * 255.0)), 0, 255));
    };

    for (int i = 0; i < n_cells; ++i) {
        W_DIRTY[i] = 0;
    }

    int dirty_count = 0;
    int convergence_dirty_count = 0;
    float * const __restrict CONV_DELTA =
        refresh_convergence ? lanes.convergence_deltas : nullptr;
    double water_budget_error_acc = 0.0;
    constexpr float CHANGE_EPS = 0.002f;

    for (int i = 0; i < n_cells; ++i) {
        const float v_vapor = NEXT_VAP[i];
        const float v_cloud = NEXT_CLD[i];
        const float v_cloud_water =
            (NEXT_CW != nullptr) ? NEXT_CW[i] : (v_cloud * 0.5f);
        const float v_precip = NEXT_PRE[i];
        const float v_instability = NEXT_INS[i];
        const float v_intensity = NEXT_INT[i];
        const float v_convergence = NEXT_CNV[i];
        const uint8_t v_type = static_cast<uint8_t>(NEXT_TYP[i] & 0xFF);
        if (refresh_convergence) {
            const float conv_delta = std::fabs(W_CNV[i] - v_convergence);
            if (conv_delta > 0.0005f && CONV_DELTA != nullptr) {
                CONV_DELTA[convergence_dirty_count++] = conv_delta;
            }
        }

        const float prev_budget_cloud_water = (W_CW != nullptr) ? W_CW[i] : 0.0f;
        water_budget_error_acc += std::fabs(
            double(v_vapor + v_cloud_water + v_precip) -
            double(PREV_VAP[i] + prev_budget_cloud_water));

        uint8_t display_type = v_type;
        uint8_t prev_type = v_type;
        uint8_t target_type = v_type;
        float alpha = 1.0f;
        if (weather_transition_enabled && W_PREV != nullptr && W_TARGET != nullptr && W_ALPHA != nullptr) {
            const uint8_t current_display = W_TYP[i];
            prev_type = W_PREV[i];
            target_type = W_TARGET[i];
            alpha = W_ALPHA[i];
            if (alpha < 0.0f) alpha = 0.0f;
            else if (alpha > 1.0f) alpha = 1.0f;
            if (target_type != v_type) {
                prev_type = current_display;
                target_type = v_type;
                alpha = transition_rate * transition_dt_days; // [dt-aware] 当前求解即计入
                if (alpha > 1.0f) alpha = 1.0f;
            } else if (prev_type == target_type || current_display == target_type) {
                prev_type = target_type;
                alpha = 0.0f;
            } else {
                alpha += transition_rate * transition_dt_days;
                if (alpha > 1.0f) alpha = 1.0f;
            }
            display_type = (alpha >= 1.0f) ? target_type : prev_type;
            if (alpha >= 1.0f) {
                prev_type = target_type;
                alpha = 0.0f;
            }
        }

        bool weather_changed = false;
        weather_changed = weather_changed || (std::fabs(W_VAP[i] - v_vapor) > CHANGE_EPS);
        weather_changed = weather_changed || (std::fabs(W_CLD[i] - v_cloud) > CHANGE_EPS);
        if (W_CW != nullptr) {
            weather_changed = weather_changed || (std::fabs(W_CW[i] - v_cloud_water) > CHANGE_EPS);
        }
        weather_changed = weather_changed || (std::fabs(W_PRE[i] - v_precip) > CHANGE_EPS);
        weather_changed = weather_changed || (W_TYP[i] != display_type);

        if (weather_changed) {
            if (W_DIRTY[i] == 0) {
                W_DIRTY[i] = 1;
                ++dirty_count;
            }
            const int nb_base = i * 6;
            for (int d = 0; d < 6; ++d) {
                const int32_t nb_i = NB[nb_base + d];
                if (nb_i >= 0 && nb_i < n_cells && W_DIRTY[nb_i] == 0) {
                    W_DIRTY[nb_i] = 1;
                    ++dirty_count;
                }
            }
        }

        W_INT[i] = v_intensity;
        W_CLD[i] = v_cloud;
        if (W_CW != nullptr) {
            W_CW[i] = v_cloud_water;
        }
        W_PRE[i] = v_precip;
        W_TYP[i] = display_type;
        if (WX != nullptr) {
            const int w4 = i * 4;
            WX[w4] = display_type;
            WX[w4 + 1] = q01_byte_commit(v_intensity);
            WX[w4 + 2] = q01_byte_commit(v_cloud);
            WX[w4 + 3] = q01_byte_commit(v_vapor);
        }
        if (W_PREV != nullptr) {

            W_PREV[i] = prev_type;
        }
        if (W_TARGET != nullptr) {
            W_TARGET[i] = target_type;
        }
        if (W_ALPHA != nullptr) {
            W_ALPHA[i] = alpha;
        }
        W_VAP[i] = v_vapor;
        W_CNV[i] = v_convergence;
        W_INS[i] = v_instability;
        W_FIN[i] = 1;
    }

    stats.dirty_count = dirty_count;
    stats.convergence_dirty_count = convergence_dirty_count;
    stats.water_budget_error_sum = water_budget_error_acc;
}

// weather distribute。计算体从 DCWorldExt::run_weather_distribute_pass 原样搬来，
// 连那几个局部 lambda 一起 —— 它们本来就不碰 Godot，跟着走比重写一遍安全。
void weather_distribute_pure(const WeatherDistributeKnobs &k,
                             const WeatherDistributeLanes &lanes,
                             const WeatherDistributeState &state,
                             WeatherDistributeEmit &emit) {
    const int n_cells = k.n_cells;
    if (n_cells <= 0) return;
    if (lanes.temp == nullptr || lanes.moisture == nullptr ||
        lanes.snow_cover == nullptr || lanes.snowpack == nullptr ||
        lanes.water_balance_30d == nullptr || lanes.soil_moisture == nullptr ||
        lanes.cover == nullptr || lanes.heat == nullptr ||
        lanes.elevation == nullptr || lanes.landform == nullptr ||
        lanes.terrain == nullptr || lanes.weather_intensity == nullptr ||
        lanes.weather_precip == nullptr || lanes.weather_type == nullptr ||
        lanes.weather_field_init == nullptr ||
        state.accumulated_snow_days == nullptr ||
        state.pre_snow_cover == nullptr) {
        return;
    }

    const float snow_min_intensity = k.snow_min_intensity;
    const float snow_freeze_t = k.snow_freeze_t;
    const float snow_melt_t = k.snow_melt_t;
    const float snow_intensity_snow = k.snow_intensity_snow;
    const int   snow_accum_days_req = k.snow_accum_days_req;
    const float flood_heavy_int = k.flood_heavy_int;
    const float flood_heavy_pre = k.flood_heavy_pre;
    const float flood_low_int = k.flood_low_int;
    const float flood_low_elev = k.flood_low_elev;
    const float flood_low_moist = k.flood_low_moist;
    const int   wt_clear = k.wt_clear;
    const int   cv_snow = k.cv_snow;
    const int   cv_none = k.cv_none;
    const int   cv_flooding = k.cv_flooding;
    const float snowpack_accum_gain = k.snowpack_accum_gain;
    const float snowpack_melt_temp_gain = k.snowpack_melt_temp_gain;
    const float snowpack_melt_sun_gain = k.snowpack_melt_sun_gain;
    const float snowpack_cover_low = k.snowpack_cover_low;
    const float snowpack_cover_full = k.snowpack_cover_full;
    // 与生产同式：span/band 的下限保护在这里做，不在调用方。
    const float snowpack_cover_span = (snowpack_cover_full - snowpack_cover_low) > 0.001f
        ? (snowpack_cover_full - snowpack_cover_low) : 0.001f;
    const float snowline_temp_threshold = k.snowline_temp_threshold;
    const float snowline_band_safe = k.snowline_band > 0.001f ? k.snowline_band : 0.001f;
    const float weather_temp_anomaly_cap = k.weather_temp_anomaly_cap;
    const bool  direct_moisture_enabled = k.direct_moisture_enabled;

    float * const __restrict T = lanes.temp;
    float * const __restrict M = lanes.moisture;
    float * const __restrict SC = lanes.snow_cover;
    float * const __restrict SP = lanes.snowpack;
    float * const __restrict WB = lanes.water_balance_30d;
    float * const __restrict SOIL = lanes.soil_moisture;
    uint8_t * const __restrict CV = lanes.cover;
    const uint8_t * const __restrict LF = lanes.landform;
    const uint8_t * const __restrict TERR = lanes.terrain;
    const float * const __restrict EL = lanes.elevation;
    const float * const __restrict HEAT = lanes.heat;
    const float * const __restrict WI = lanes.weather_intensity;
    const float * const __restrict WP = lanes.weather_precip;
    const uint8_t * const __restrict WT_ = lanes.weather_type;
    const uint8_t * const __restrict WFI = lanes.weather_field_init;
    int32_t * const __restrict ACC = state.accumulated_snow_days;
    int32_t * const __restrict PRE = state.pre_snow_cover;
    const float * const __restrict TD = k.temp_delta;
    const float * const __restrict MD = k.moist_delta;
    const uint8_t * const __restrict CFS = k.can_form_snow;
    const uint8_t * const __restrict CFF = k.can_form_flood;

    auto clamp01 = [](float v) -> float {
        if (v < 0.0f) return 0.0f;
        if (v > 1.0f) return 1.0f;
        return v;
    };
    auto clampf = [](float v, float lo, float hi) -> float {
        return v < lo ? lo : (v > hi ? hi : v);
    };
    auto smoothstep_local = [&](float a, float b, float x) -> float {
        if (b <= a) return x >= b ? 1.0f : 0.0f;
        float t = (x - a) / (b - a);
        if (t < 0.0f) t = 0.0f; else if (t > 1.0f) t = 1.0f;
        return t * t * (3.0f - 2.0f * t);
    };
    constexpr uint8_t COVER_GLACIER = 2;

    auto snow_summer_melt_bonus = [&](float heat_input, float elevation) -> float {
        const float sun = smoothstep_local(0.55f, 0.90f, clampf(heat_input, 0.0f, 1.0f));
        const float high_elev = smoothstep_local(0.62f, 0.95f, clampf(elevation, 0.0f, 1.0f));
        return sun * (1.0f - high_elev * 0.60f) * 0.045f;
    };

    auto snowline_floor_for_cell = [&](float temp_now, float heat_input, float elevation,
                                       float snowline_temp_threshold,
                                       float snowline_band_safe) -> float {
        if (snowline_temp_threshold <= 0.0f) return 0.0f;
        const float sun = smoothstep_local(0.45f, 0.85f, clampf(heat_input, 0.0f, 1.0f));
        const float high_elev = smoothstep_local(0.60f, 0.95f, clampf(elevation, 0.0f, 1.0f));
        const float summer_drop = sun * (0.14f + (0.045f - 0.14f) * high_elev);
        const float elev_bonus = clampf((elevation - 0.30f) * 0.10f, 0.0f, 0.08f);
        const float effective_threshold = snowline_temp_threshold + elev_bonus - summer_drop;
        const float raw_floor = clampf((effective_threshold - temp_now) / snowline_band_safe, 0.0f, 1.0f);
        // Stage4(2026-06-23): 雪线 floor 只为深冻区自动铺白；雪线边缘交给 snowpack-from-snowfall。
        // 镜像 weather_system.gd _snowline_floor_for_cell。
        return smoothstep_local(0.30f, 0.80f, raw_floor);
    };

    // LandformType.is_water：DEEP_OCEAN(0) / OCEAN(1) / COAST(2) / LAKE(3) → true
    auto is_water_lf = [](uint8_t lf) -> bool {
        return lf <= 3;
    };
    auto is_water_terrain = [](uint8_t t) -> bool {
        return t == 0  ||  // OCEAN
               t == 1  ||  // COAST
               t == 18 ||  // LAKE
               t == 19 ||  // REEF
               t == 20 ||  // SEA_ICE
               t == 21;    // KELP
    };

    // ─── 主循环（1:1 复刻 _distribute_weather_field_to_cells + _apply_snow_accumulation）─
    std::vector<int32_t> &changed_cells = emit.changed_cells;
    bool cover_dirty = false;
    for (int i = 0; i < n_cells; ++i) {
        const bool field_init = WFI[i] != 0;
        const int  wt        = field_init ? int(WT_[i]) : wt_clear;
        const float intensity = field_init ? WI[i] : 0.0f;
        const float raw_precip = field_init ? WP[i] : 0.0f;
        const float precip = (field_init && wf_is_precip_weather_type(uint8_t(wt))) ? raw_precip : 0.0f;

        // CLEAR / 低强度退化分支
        if (wt == wt_clear || intensity <= snow_min_intensity) {
            const bool water_lf = is_water_lf(LF[i]) || is_water_terrain(TERR[i]);
            if (!water_lf && (ACC[i] > 0 || CV[i] == cv_snow)) {
                // _apply_snow_accumulation(cell, wt, cell.temperature, 0.0)
                // intensity = 0 ⇒ snowing 永假；只有融化 / 升级判定可能触发。
                // 2026-05-18 雪线修正：melt_t 加 elev 偏移（高山难融，平原易融）。
                //   与 GDScript SNOW_ELEV_NEUTRAL=0.30 / MELT_GAIN=0.30 / MAX_OFF=0.10 SAME_SOURCE。
                const float elev_delta_c = EL[i] - 0.30f;
                float melt_off_c = elev_delta_c * 0.30f;
                if (melt_off_c >  0.10f) melt_off_c =  0.10f;
                else if (melt_off_c < -0.10f) melt_off_c = -0.10f;
                const float melt_t_local = snow_melt_t + melt_off_c;
                const float temp_now = T[i];
                if (temp_now > melt_t_local) {
                    int new_acc = ACC[i] - 1;
                    if (new_acc < 0) new_acc = 0;
                    ACC[i] = new_acc;
                }
                // 升级 / 融化（与下方主分支同算法）
                if (ACC[i] >= snow_accum_days_req && CV[i] != cv_snow && CV[i] != COVER_GLACIER) {
                    PRE[i] = int(CV[i]);
                    CV[i] = uint8_t(cv_snow);
                    changed_cells.push_back(i);
                    cover_dirty = true;
                } else if (ACC[i] <= 0 && CV[i] == cv_snow) {
                    int restored = (PRE[i] >= 0) ? PRE[i] : cv_none;
                    CV[i] = uint8_t(restored);
                    PRE[i] = -1;
                    changed_cells.push_back(i);
                    cover_dirty = true;
                }
            }
            float sp = SP[i];
            float wb = WB[i];
            float soil = SOIL[i];
            float sc = 0.0f;
            if (water_lf) {
                SP[i] = 0.0f;
                WB[i] = wb + (0.0f - wb) * (1.0f / 30.0f);
                SC[i] = 0.0f;
            } else {
                const float elev_delta = EL[i] - 0.30f;
                float melt_off = elev_delta * 0.30f;
                if (melt_off > 0.10f) melt_off = 0.10f;
                else if (melt_off < -0.10f) melt_off = -0.10f;
                const float melt_t_local = snow_melt_t + melt_off;
                float freeze_off = elev_delta * 0.20f;
                if (freeze_off > 0.06f) freeze_off = 0.06f;
                else if (freeze_off < -0.06f) freeze_off = -0.06f;
                const float freeze_t_local = snow_freeze_t + freeze_off;
                const bool cold_precip = (T[i] < freeze_t_local) && (precip > 0.002f);
                float snow_accum = cold_precip ? precip * snowpack_accum_gain * 0.75f : 0.0f;
                if (cold_precip) {
                    snow_accum += (intensity < 0.15f ? intensity : 0.15f) * 0.006f;
                }
                const float melt = ((T[i] - melt_t_local) > 0.0f ? (T[i] - melt_t_local) : 0.0f) * snowpack_melt_temp_gain
                    + HEAT[i] * snowpack_melt_sun_gain
                    + snow_summer_melt_bonus(HEAT[i], EL[i]);
                sp = clampf(sp + snow_accum - melt, 0.0f, 1.0f);
                if (CV[i] == COVER_GLACIER && sp < 0.80f) sp = 0.80f;
                const float evap_proxy = clampf((0.01f + ((M[i] - 0.45f) > 0.0f ? (M[i] - 0.45f) : 0.0f) * 0.03f)
                    * (0.35f + T[i] * 1.05f) * 0.65f, 0.0f, 1.0f);
                const float runoff = ((M[i] - 0.82f) > 0.0f ? (M[i] - 0.82f) : 0.0f) * 0.25f
                    + ((EL[i] - 0.70f) > 0.0f ? (EL[i] - 0.70f) : 0.0f) * precip * 0.06f;
                const float daily_balance = clampf(precip - evap_proxy - runoff, -1.0f, 1.0f);
                wb = wb + (daily_balance - wb) * (1.0f / 30.0f);
                // climate-loop-closure Phase 3.1：土壤水每日衰减(×0.97)，停雨后排干。
                soil = clampf(soil * 0.97f + daily_balance * 0.08f, -0.5f, 0.5f);
                if (direct_moisture_enabled) {
                    M[i] = clamp01(M[i] + precip * 0.35f
                        + ((daily_balance > 0.0f) ? daily_balance * 0.04f : 0.0f));
                }
                // climate-loop-closure Phase 2.1/2.2：物理雪线 floor（仅陆地）。
                float snow_floor_c = 0.0f;
                if (snowline_temp_threshold > 0.0f) {
                    snow_floor_c = snowline_floor_for_cell(T[i], HEAT[i], EL[i], snowline_temp_threshold, snowline_band_safe);
                    if (snow_floor_c * snowpack_cover_full > sp) sp = snow_floor_c * snowpack_cover_full;
                }
                float u = (sp - snowpack_cover_low) / snowpack_cover_span;
                if (u < 0.0f) u = 0.0f; else if (u > 1.0f) u = 1.0f;
                sc = u * u * (3.0f - 2.0f * u);
                if (snow_floor_c > sc) sc = snow_floor_c;
                if (CV[i] == COVER_GLACIER && sc < 0.80f) sc = 0.80f;
                SP[i] = sp;
                WB[i] = wb;
                SOIL[i] = soil;
                SC[i] = sc;
            }
            continue;
        }

        const float td_v = (wt >= 0 && wt < 8) ? TD[wt] : 0.0f;
        const float md_v = (wt >= 0 && wt < 8) ? MD[wt] : 0.0f;
        const float moist_now = direct_moisture_enabled
            ? clamp01(M[i] + md_v * intensity + precip * 0.35f)
            : M[i];
        float temp_delta = td_v * intensity;
        if (temp_delta > weather_temp_anomaly_cap) temp_delta = weather_temp_anomaly_cap;
        else if (temp_delta < -weather_temp_anomaly_cap) temp_delta = -weather_temp_anomaly_cap;
        const float temp_now  = clamp01(T[i] + temp_delta);
        M[i] = moist_now;
        T[i] = temp_now;

        float sp_now = SP[i];
        const float prev_sp = sp_now;
        float wb_now = WB[i];
        float soil_now = SOIL[i];
        const bool water_lf_weather = is_water_lf(LF[i]) || is_water_terrain(TERR[i]);
        if (water_lf_weather) {
            sp_now = 0.0f;
            wb_now = wb_now + (0.0f - wb_now) * (1.0f / 30.0f);
        } else {
            const float elev_delta_sp = EL[i] - 0.30f;
            float freeze_off_sp = elev_delta_sp * 0.20f;
            if (freeze_off_sp > 0.06f) freeze_off_sp = 0.06f;
            else if (freeze_off_sp < -0.06f) freeze_off_sp = -0.06f;
            float melt_off_sp = elev_delta_sp * 0.30f;
            if (melt_off_sp > 0.10f) melt_off_sp = 0.10f;
            else if (melt_off_sp < -0.10f) melt_off_sp = -0.10f;
            const float freeze_t_sp = snow_freeze_t + freeze_off_sp;
            const float melt_t_sp = snow_melt_t + melt_off_sp;
            const bool can_snow_sp = (wt >= 0 && wt < 8) && (CFS[wt] != 0);
            const bool precip_can_snow_sp = (wt != wt_clear) && (wt != 4) && (wt != 6);
            const bool snowing_sp = (can_snow_sp || precip_can_snow_sp) && (temp_now < freeze_t_sp) && (precip > 0.0f);
            float snow_accum = snowing_sp ? (precip * snowpack_accum_gain + intensity * 0.015f) : 0.0f;
            const float warm_rain_melt = (temp_now > melt_t_sp) ? precip * 0.03f : 0.0f;
            const float melt = ((temp_now - melt_t_sp) > 0.0f ? (temp_now - melt_t_sp) : 0.0f) * snowpack_melt_temp_gain
                + HEAT[i] * snowpack_melt_sun_gain
                + snow_summer_melt_bonus(HEAT[i], EL[i])
                + warm_rain_melt;
            sp_now = clampf(sp_now + snow_accum - melt, 0.0f, 1.0f);
            if (CV[i] == COVER_GLACIER && sp_now < 0.80f) sp_now = 0.80f;
            const float meltwater = (prev_sp - sp_now) > 0.0f ? (prev_sp - sp_now) : 0.0f;
            const float runoff = ((moist_now - 0.82f) > 0.0f ? (moist_now - 0.82f) : 0.0f) * 0.25f
                + ((EL[i] - 0.70f) > 0.0f ? (EL[i] - 0.70f) : 0.0f) * precip * 0.06f;
            const float evap_proxy = clampf((0.01f + ((moist_now - 0.45f) > 0.0f ? (moist_now - 0.45f) : 0.0f) * 0.03f)
                * (0.35f + temp_now * 1.05f) * 0.65f, 0.0f, 1.0f);
            const float daily_balance = clampf(precip * 1.15f + meltwater * 0.65f - evap_proxy - runoff, -1.0f, 1.0f);
            wb_now = wb_now + (daily_balance - wb_now) * (1.0f / 30.0f);
            // climate-loop-closure Phase 3.1：土壤水每日衰减(×0.97)，停雨后排干。
            soil_now = clampf(soil_now * 0.97f + daily_balance * 0.08f, -0.5f, 0.5f);
        }
        // climate-loop-closure Phase 2.1/2.2：物理雪线 floor（仅陆地）。
        float snow_floor_w = 0.0f;
        if (snowline_temp_threshold > 0.0f && !water_lf_weather) {
            snow_floor_w = snowline_floor_for_cell(temp_now, HEAT[i], EL[i], snowline_temp_threshold, snowline_band_safe);
            if (snow_floor_w * snowpack_cover_full > sp_now) sp_now = snow_floor_w * snowpack_cover_full;
        }
        float u_sp = (sp_now - snowpack_cover_low) / snowpack_cover_span;
        if (u_sp < 0.0f) u_sp = 0.0f; else if (u_sp > 1.0f) u_sp = 1.0f;
        float snow_cover_now = u_sp * u_sp * (3.0f - 2.0f * u_sp);
        if (snow_floor_w > snow_cover_now) snow_cover_now = snow_floor_w;
        if (CV[i] == COVER_GLACIER && snow_cover_now < 0.80f) snow_cover_now = 0.80f;
        SP[i] = sp_now;
        SC[i] = snow_cover_now;
        WB[i] = wb_now;
        SOIL[i] = soil_now;

        if (!water_lf_weather) {
            // 雪：累积式 _apply_snow_accumulation(cell, wt, temp_now, intensity)
            // 2026-05-18 雪线修正：freeze_t / melt_t 随 elev 偏移（与 GDScript SAME_SOURCE）。
            //   neutral=0.30；freeze_gain=0.20，max_off=±0.06；melt_gain=0.30，max_off=±0.10。
            const float elev_delta_m = EL[i] - 0.30f;
            float freeze_off_m = elev_delta_m * 0.20f;
            if (freeze_off_m >  0.06f) freeze_off_m =  0.06f;
            else if (freeze_off_m < -0.06f) freeze_off_m = -0.06f;
            float melt_off_m = elev_delta_m * 0.30f;
            if (melt_off_m >  0.10f) melt_off_m =  0.10f;
            else if (melt_off_m < -0.10f) melt_off_m = -0.10f;
            const float freeze_t_local = snow_freeze_t + freeze_off_m;
            const float melt_t_local   = snow_melt_t   + melt_off_m;
            const bool can_snow = (wt >= 0 && wt < 8) && (CFS[wt] != 0);
            const bool snowing  = can_snow && (temp_now < freeze_t_local) && (intensity > snow_intensity_snow);
            if (snowing) {
                ACC[i] += 1;
            } else if (temp_now > melt_t_local) {
                int new_acc = ACC[i] - 1;
                if (new_acc < 0) new_acc = 0;
                ACC[i] = new_acc;
            }
            if (ACC[i] >= snow_accum_days_req && CV[i] != cv_snow && CV[i] != COVER_GLACIER) {
                PRE[i] = int(CV[i]);
                CV[i] = uint8_t(cv_snow);
                changed_cells.push_back(i);
                cover_dirty = true;
            } else if (ACC[i] <= 0 && CV[i] == cv_snow) {
                int restored = (PRE[i] >= 0) ? PRE[i] : cv_none;
                CV[i] = uint8_t(restored);
                PRE[i] = -1;
                changed_cells.push_back(i);
                cover_dirty = true;
            }

            // 洪涝
            const bool can_flood = (wt >= 0 && wt < 8) && (CFF[wt] != 0);
            if (CV[i] != cv_snow && can_flood) {
                const bool heavy_flood   = (intensity > flood_heavy_int) && (precip > flood_heavy_pre);
                const bool lowland_flood = (intensity > flood_low_int) && (EL[i] < flood_low_elev) && (moist_now > flood_low_moist);
                if ((heavy_flood || lowland_flood) && CV[i] != cv_flooding) {
                    CV[i] = uint8_t(cv_flooding);
                    changed_cells.push_back(i);
                    cover_dirty = true;
                }
            }
            // Stage8 退水(不受 can_flood 门限制→DROUGHT/CLEAR 也能退)：修"洪泛与旱灾共存"。镜像 weather_system.gd。
            if (CV[i] == cv_flooding && moist_now < 0.50f && precip < 0.04f) {
                CV[i] = uint8_t(cv_none);
                changed_cells.push_back(i);
                cover_dirty = true;
            }
        }
    }

    emit.cover_dirty = cover_dirty;
}

} // namespace pk_async_climate
} // namespace pk
