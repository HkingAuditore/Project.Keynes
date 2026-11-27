#include "runtime_climate_passes.h"
#include "parallel_dispatcher.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <vector>

namespace pk {
namespace pk_async_climate {
void weather_field_solve_pure(const WeatherFieldKnobs &knobs,
                              const WeatherFieldLanes &lanes,
                              const WeatherFieldState &state,
                              int begin,
                              int end) {
    const int n_cells = knobs.n_cells;
    if (n_cells <= 0 || begin < 0 || end > n_cells || end <= begin) return;

    // 原循环体里的自由名字，逐个绑回结构体。名字保持不变，循环体才能原样搬。
    const float climate_anomaly = knobs.climate_anomaly;
    const bool  refresh_convergence = knobs.refresh_convergence;
    const bool  apply_convergence_boost = knobs.apply_convergence_boost;
    const bool  use_next_outputs = knobs.use_next_outputs;
    const int   field_advect_steps = knobs.field_advect_steps;
    const float field_diffusion = knobs.field_diffusion;
    const float field_ocean_evap_gain = knobs.field_ocean_evap_gain;
    const float field_precip_inertia = knobs.field_precip_inertia;
    const float field_precip_spatial_smooth = knobs.field_precip_spatial_smooth;
    const float field_cloud_inertia = knobs.field_cloud_inertia;
    const float field_wet_terrain_precip_damping = knobs.field_wet_terrain_precip_damping;
    const float field_lake_precip_damping = knobs.field_lake_precip_damping;
    const float field_lake_evap_scale = knobs.field_lake_evap_scale;
    const float field_extreme_precip_soft_cap = knobs.field_extreme_precip_soft_cap;
    const float field_extreme_precip_softness = knobs.field_extreme_precip_softness;
    const float field_land_evapotranspiration_gain = knobs.field_land_evapotranspiration_gain;
    const float field_ocean_precip_suppression = knobs.field_ocean_precip_suppression;
    const float field_frontogenesis_gain = knobs.field_frontogenesis_gain;
    const float field_rain_shadow_drying = knobs.field_rain_shadow_drying;
    const float field_advect_vapor = knobs.field_advect_vapor;
    const float field_advect_cloud = knobs.field_advect_cloud;
    const float field_rh_condense = knobs.field_rh_condense;
    const float field_static_cond_w = knobs.field_static_cond_w;
    const float field_condense_rate = knobs.field_condense_rate;
    const float field_lift_cond_gain = knobs.field_lift_cond_gain;
    const float field_conv_cond_gain = knobs.field_conv_cond_gain;
    const float field_thermal_conv_cond = knobs.field_thermal_conv_cond;
    const float field_thermal_conv_precip = knobs.field_thermal_conv_precip;
    const float field_autoconversion = knobs.field_autoconversion;
    const float field_precip_base_frac = knobs.field_precip_base_frac;
    const float field_lift_precip_gain = knobs.field_lift_precip_gain;
    const float field_conv_precip_gain = knobs.field_conv_precip_gain;
    const float field_oro_precip_gain = knobs.field_oro_precip_gain;
    const float field_stratiform_gain = knobs.field_stratiform_gain;
    const float field_cool_season_vapor_floor = knobs.field_cool_season_vapor_floor;
    const float field_cloud_reevap = knobs.field_cloud_reevap;
    const float weather_cell_pos_scale = knobs.weather_cell_pos_scale;
    const float weather_wrap_width_x = knobs.weather_wrap_width_x;
    const bool  cold_precip_as_blizzard = knobs.cold_precip_as_blizzard;
    const float snow_classification_margin = knobs.snow_classification_margin;
    const float weather_lat_te_norm = knobs.weather_lat_te_norm;
    const float OMEGA_ASCENT_GAIN = knobs.omega_ascent_gain;
    const float wb_pos_y = knobs.world_bounds_pos_y;
    const float wb_size_y = knobs.world_bounds_size_y;
    const float syn_supp = knobs.syn_supp;
    const float syn_enh = knobs.syn_enh;
    const float syn_front_force = knobs.syn_front_force;
    const float syn_front_enh = knobs.syn_front_enh;
    const float syn_base_lift = knobs.syn_base_lift;
    const bool  weather_transition_enabled = knobs.weather_transition_enabled;
    const float weather_transition_alpha_rate = knobs.weather_transition_alpha_rate;
    const float weather_transition_dt_days = knobs.weather_transition_dt_days;
    const bool  thermal_monsoon_enabled = knobs.thermal_monsoon_enabled;
    const uint8_t cyclone_storm_type_id = knobs.cyclone_storm_type_id;

    // 循环体内的编译期常量（原本是 pass 函数体里的 constexpr）。
    constexpr float OMEGA_DESCENT_GAIN = 0.70f;
    constexpr float OMEGA_DESCENT_COND = 0.45f;
    constexpr float VAPOR_DISCHARGE = 0.70f;
    constexpr float DISCHARGE_SUSTAIN = 0.65f;
    constexpr float INHIB_CHARGE = 0.26f;
    constexpr float INHIB_REFRAC = 0.18f;
    constexpr float INHIB_LEAK = 0.88f;
    constexpr float INHIB_STRENGTH = 0.92f;
    constexpr float INHIB_WET = 0.02f;

    const float   * const __restrict TR   = lanes.temp_read;
    const float   * const __restrict MR   = lanes.moisture_read;
    const float   * const __restrict AA   = lanes.air_anomaly;
    const float   * const __restrict WX   = lanes.wind_x;
    const float   * const __restrict WY   = lanes.wind_y;
    const float   * const __restrict WSPD = lanes.wind_speed;
    const uint8_t * const __restrict TERR = lanes.terrain;
    const uint8_t * const __restrict RIV  = lanes.has_river;
    const float   * const __restrict RQ30 = lanes.river_q30;
    const float   * const __restrict ELEV = lanes.elevation;
    const uint8_t * const __restrict VEG  = lanes.vegetation;
    const float   * const __restrict SOIL = lanes.soil_moisture;
    const float   * const __restrict VITA = lanes.vitality;
    const float   * const __restrict SICE = lanes.sea_ice;
    const float   * const __restrict POSX = lanes.pos_x;
    const float   * const __restrict POSY = lanes.pos_y;
    const float   * const __restrict TANO = lanes.temp_anomaly;
    const float   * const __restrict SNOWR = lanes.snow_cover;
    const int32_t * const __restrict NB   = lanes.neighbor_indices;
    const float   * const __restrict PV   = lanes.prev_vapor;
    const float   * const __restrict PP   = lanes.prev_precip;
    const float   * const __restrict PCW  = lanes.prev_cloud_water;
    const float   * const __restrict TA   = lanes.temp_transport_anomaly;
    const float   * const __restrict PREV_CNV = lanes.prev_convergence;
    const float   * const __restrict PREV_CLOUD = lanes.prev_cloud;

    float   * const __restrict OUT_VAP = lanes.out_vapor;
    float   * const __restrict OUT_CLD = lanes.out_cloud;
    float   * const __restrict OUT_CW  = lanes.out_cloud_water;
    float   * const __restrict OUT_PRE = lanes.out_precip;
    float   * const __restrict OUT_INS = lanes.out_instability;
    float   * const __restrict OUT_INT = lanes.out_intensity;
    float   * const __restrict OUT_CNV = lanes.out_convergence;
    uint8_t * const __restrict OUT_TYP = lanes.out_type_u8;
    int32_t * const __restrict OUT_TYP_I32 = lanes.out_type_i32;
    uint8_t * const __restrict OUT_PREV_TYP = lanes.out_prev_type;
    uint8_t * const __restrict OUT_TARGET_TYP = lanes.out_target_type;
    float   * const __restrict OUT_ALPHA = lanes.out_alpha;
    uint8_t * const __restrict OUT_FIN = lanes.out_field_init;
    float   * const __restrict INHIB = state.conv_inhib;

    const float * const __restrict PSI = state.psi;
    const uint32_t * const __restrict CYC_TAG = state.cyclone_tag;
    const uint32_t cyclone_generation = state.cyclone_generation;
    const float * const __restrict CYC_LIFT = state.cyclone_lift;
    const float * const __restrict CYC_X = state.cyclone_x;
    const float * const __restrict CYC_Y = state.cyclone_y;
    const float * const __restrict MONS = state.monsoon_thermal;
    const int32_t * const __restrict TRAJ_IDX = state.traj_idx;
    const float   * const __restrict TRAJ_W = state.traj_w;
    const bool use_geom_cache = state.geom_dx != nullptr &&
        state.geom_dy != nullptr && state.geom_invd != nullptr;
    const float * const __restrict GEOM_DX   = state.geom_dx;
    const float * const __restrict GEOM_DY   = state.geom_dy;
    const float * const __restrict GEOM_INVD = state.geom_invd;

    if (TR == nullptr || MR == nullptr || AA == nullptr || WX == nullptr ||
        WY == nullptr || WSPD == nullptr || TERR == nullptr || RIV == nullptr ||
        ELEV == nullptr || VEG == nullptr || POSX == nullptr || POSY == nullptr ||
        NB == nullptr || PV == nullptr || PP == nullptr || TA == nullptr ||
        PREV_CNV == nullptr || PREV_CLOUD == nullptr || OUT_VAP == nullptr ||
        OUT_CLD == nullptr || OUT_PRE == nullptr || OUT_INS == nullptr ||
        OUT_INT == nullptr || OUT_CNV == nullptr) {
        return;
    }
    // direct 路径写 uint8 类型 + field_init，staged 路径写 int32 类型。少哪一边都
    // 意味着调用方接错了 buffer，静默跑完会把这一天的 weather_type 丢掉。
    if (use_next_outputs ? (OUT_TYP_I32 == nullptr)
                         : (OUT_TYP == nullptr || OUT_FIN == nullptr)) {
        return;
    }

    auto wx_traj_sample = [&](int idx, const float *FIELD) -> float {
        const int t3 = idx * 3;
        return TRAJ_W[t3] * FIELD[TRAJ_IDX[t3]]
             + TRAJ_W[t3 + 1] * FIELD[TRAJ_IDX[t3 + 1]]
             + TRAJ_W[t3 + 2] * FIELD[TRAJ_IDX[t3 + 2]];
    };
    auto wx_aligned = [&](int idx, float dx, float dy) -> int {
        return use_geom_cache
            ? wf_neighbor_aligned_idx_cached(idx, dx, dy, NB, GEOM_DX, GEOM_DY,
                                             n_cells, weather_cell_pos_scale)
            : wf_neighbor_aligned_idx_xy(idx, dx, dy, POSX, POSY, NB, n_cells,
                                         weather_cell_pos_scale, weather_wrap_width_x);
    };
    auto wx_upstream_avg = [&](int idx, int first_up, const float *FIELD,
                               float wdx, float wdy) -> float {
        return use_geom_cache
            ? wf_upstream_vapor_idx_from_first_cached(
                  idx, first_up, NB, GEOM_DX, GEOM_DY, FIELD, wdx, wdy, n_cells,
                  weather_cell_pos_scale, field_advect_steps)
            : wf_upstream_vapor_idx_from_first_xy(
                  idx, first_up, POSX, POSY, NB, FIELD, wdx, wdy, n_cells,
                  weather_cell_pos_scale, weather_wrap_width_x, field_advect_steps);
    };
    // W9：口径只剩一种（有符号净流入），开关与 legacy 分支已退役。
    auto wx_convergence = [&](int idx) -> float {
        return use_geom_cache
            ? wf_wind_convergence_idx_cached(idx, NB, GEOM_DX, GEOM_DY, GEOM_INVD,
                                             WX, WY, WSPD)
            : wf_wind_convergence_idx_xy(idx, POSX, POSY, NB, WX, WY, WSPD,
                                         weather_wrap_width_x);
    };

    auto surface_vapor_source = [&](int src_idx, float src_temp, float src_base_m,
                                     float src_wind_mag, float src_ocean_an,
                                     bool src_on_water, bool src_is_lake,
                                     bool src_has_river, float src_river_q,
                                     float src_river_source_scale) -> float {
        // [climate-zone-fix P3] 冷季地板抬高低温端蒸发；floor=0 时与原 smoothstep 逐位一致。
        float temp_evap = wf_smoothstep(0.10f, 0.78f, src_temp);
        if (temp_evap < field_cool_season_vapor_floor) temp_evap = field_cool_season_vapor_floor;
        const float wind_evap = 0.70f + src_wind_mag * 0.55f;
        float wet_bonus = 0.0f;
        switch (TERR[src_idx]) {
            case 10: // SWAMP
            case 11: // JUNGLE
            case 22: // DELTA
                wet_bonus = 0.010f;
                break;
            case 18: // LAKE
                wet_bonus = 0.016f;
                break;
            default:
                wet_bonus = 0.0f;
                break;
        }
        if (src_on_water) {
            const float sea_ice = (SICE != nullptr) ? dc_clampf(SICE[src_idx], 0.0f, 1.0f) : 0.0f;
            float src = (0.018f + temp_evap * 0.052f) * field_ocean_evap_gain * wind_evap;
            src *= dc_clampf(1.0f + src_ocean_an * 0.55f, 0.55f, 1.45f);
            src *= (1.0f - sea_ice * 0.92f);
            if (src_is_lake) src *= field_lake_evap_scale;
            return (src > 0.0f) ? src : 0.0f;
        }
        const float soil_norm = (SOIL != nullptr)
            ? dc_clampf(0.5f + SOIL[src_idx], 0.0f, 1.0f)
            : dc_clampf(src_base_m, 0.0f, 1.0f);
        const float vitality = (VITA != nullptr) ? dc_clampf(VITA[src_idx], 0.0f, 1.0f) : 0.7f;
        const float veg_flux = wf_vegetation_transp_factor(VEG[src_idx]) * (0.45f + vitality * 0.65f);
        float src = (0.005f + src_base_m * 0.010f + soil_norm * 0.020f + veg_flux * 0.016f + wet_bonus)
            * field_land_evapotranspiration_gain * temp_evap * (0.85f + src_wind_mag * 0.25f);
        if (src_has_river) {
            const float river_scale = dc_clampf(src_river_source_scale, 0.0f, 1.0f);
            const float river_extra = (0.010f + src_river_q * 0.020f)
                * field_land_evapotranspiration_gain * temp_evap;
            src += river_extra * river_scale;
        }
        return (src > 0.0f) ? src : 0.0f;
    };

    const int rb = begin;
    const int re = end;
    for (int i = rb; i < re; ++i) {
        float temp = TR[i] + climate_anomaly + AA[i];
        if (temp < 0.0f) temp = 0.0f;
        else if (temp > 1.0f) temp = 1.0f;

        float base_m = MR[i];
        if (base_m < 0.0f) base_m = 0.0f;
        else if (base_m > 1.0f) base_m = 1.0f;
        float vapor_capacity = 0.18f + 0.82f * temp - 0.18f * ELEV[i];
        if (vapor_capacity < 0.14f) vapor_capacity = 0.14f;
        else if (vapor_capacity > 1.0f) vapor_capacity = 1.0f;

        const bool on_water = wf_is_water_terrain(TERR[i]);
        // ── perf P3: 融合 3 个 6-邻域 gather 为一次遍历（逐 d 顺序与原版一致→bit-equal）──
        //   ① ocean_an     = wf_avg_ocean_anomaly_at_idx(i, TERR, NB, TA)
        //   ② neighbor_vapor= wf_neighbor_average_vapor_idx(i, NB, PV)
        //   ③ temp_min/max  = 邻域温度极值（原下方 temp gradient 循环）
        float ocean_an;
        float neighbor_vapor;
        float temp_min = temp;
        float temp_max = temp;
        {
            const int fb = i * 6;
            float vap_sum = PV[i];
            int   vap_n   = 1;
            float oa_sum  = 0.0f;
            int   oa_n    = 0;
            for (int d = 0; d < 6; ++d) {
                const int32_t nb_idx = NB[fb + d];
                if (nb_idx < 0) continue;
                vap_sum += PV[nb_idx];                // ② vapor 邻域均值（含 self）
                vap_n   += 1;
                float nb_temp = TR[nb_idx] + climate_anomaly + AA[nb_idx];  // ③ 温度梯度极值
                if (nb_temp < 0.0f) nb_temp = 0.0f;
                else if (nb_temp > 1.0f) nb_temp = 1.0f;
                if (nb_temp < temp_min) temp_min = nb_temp;
                if (nb_temp > temp_max) temp_max = nb_temp;
                if (!on_water && wf_is_water_terrain(TERR[nb_idx])) {       // ① 陆格→水邻居 TA 均值
                    oa_sum += TA[nb_idx];
                    oa_n   += 1;
                }
            }
            neighbor_vapor = vap_sum / float(vap_n);
            ocean_an = on_water ? TA[i] : ((oa_n == 0) ? 0.0f : (oa_sum / float(oa_n)));
        }
        const float local_sea_ice = (on_water && SICE != nullptr) ? dc_clampf(SICE[i], 0.0f, 1.0f) : 0.0f;

        float wind_x = WX[i];
        float wind_y = WY[i];
        const bool cyclone_forced = i < state.cyclone_tag_count &&
            CYC_TAG[static_cast<size_t>(i)] == cyclone_generation;
        const float cyclone_lift = cyclone_forced
            ? CYC_LIFT[static_cast<size_t>(i)] : 0.0f;
        if (cyclone_forced) {
            wind_x += CYC_X[static_cast<size_t>(i)];
            wind_y += CYC_Y[static_cast<size_t>(i)];
        }
        const float wlen2 = wind_x * wind_x + wind_y * wind_y;
        float wind_dx, wind_dy;
        if (wlen2 < 0.0001f) {
            // Conservative fallback: dir = (1,0) like the GDScript final
            // `wind.normalized() if length_squared > 0.0001 else Vector2.RIGHT`.
            // Magnitude stays 0 → wind_mag=0 → advect_w lower bound.
            wind_dx = 1.0f;
            wind_dy = 0.0f;
        } else {
            const float inv = 1.0f / std::sqrt(wlen2);
            wind_dx = wind_x * inv;
            wind_dy = wind_y * inv;
        }
        const float wind_len = wf_wind_speed_norm(wind_x, wind_y, WSPD[i]);

        const int upstream_idx = (field_advect_steps > 0)
            ? wx_aligned(i, -wind_dx, -wind_dy)
            : -1;

        // NS 化 Phase 2:轨迹表命中 → 真半拉格朗日三点插值(1 次表查 + 3 点 lerp,
        // 替代 3×6 邻居探测的 hopping,回溯长度含风速×dt 语义);未命中 → 旧路径。
        const float advected_vapor = (TRAJ_IDX != nullptr)
            ? wx_traj_sample(i, PV)
            : wx_upstream_avg(i, upstream_idx, PV, wind_dx, wind_dy);

        // neighbor_vapor 已在上方 P3 融合 gather 中算出。

        float wind_mag = wind_len / 1.2f;
        if (wind_mag < 0.0f) wind_mag = 0.0f;
        else if (wind_mag > 1.0f) wind_mag = 1.0f;

        const float lift = wf_orographic_lift_from_upstream_idx(
            i, upstream_idx, ELEV);
        float convergence = PREV_CNV[i];
        if (refresh_convergence) {
            convergence = wx_convergence(i);
        }

        float advect_w = 0.65f + wind_mag * 0.30f;
        if (advect_w < 0.65f) advect_w = 0.65f;
        else if (advect_w > 0.95f) advect_w = 0.95f;

        const bool is_lake = (TERR[i] == 18);
        const bool has_river = (!is_lake) && (RIV[i] != 0) && (!on_water);
        const float river_flow_feedback = has_river
            ? dc_clampf((RQ30 != nullptr ? RQ30[i] : 0.0f), 0.0f, 1.0f)
            : 0.0f;
        float river_recycle_lock = 0.0f;
        if (has_river) {
            // W3 重标定：0.65 → 0.76，保持「旧 p90(0.537) 处贡献不变」：0.65*0.537/0.458 ≈ 0.76
            float river_forcing_proxy = convergence * 0.76f;
            const float lift_forcing = (lift > 0.0f) ? lift * 0.80f : 0.0f;
            if (lift_forcing > river_forcing_proxy) river_forcing_proxy = lift_forcing;
            river_recycle_lock = wf_smoothstep(0.035f, 0.12f, PP[i])
                * (1.0f - wf_smoothstep(0.16f, 0.44f, river_forcing_proxy))
                * (0.35f + river_flow_feedback * 0.65f);
            river_recycle_lock = dc_clampf(river_recycle_lock, 0.0f, 1.0f);
        }
        const float river_source_scale = 1.0f - river_recycle_lock * 0.72f;
        const float river_evap_floor = has_river
            ? std::max(0.08f, river_flow_feedback * 0.22f) * (1.0f - river_recycle_lock * 0.65f)
            : 0.0f;
        if (is_lake) {
            advect_w *= 0.5f;
            if (advect_w < 0.20f) advect_w = 0.20f;
            else if (advect_w > 0.50f) advect_w = 0.50f;
        } else if (has_river) {
            advect_w *= (0.88f - river_flow_feedback * 0.10f);
            if (advect_w < 0.55f) advect_w = 0.55f;
            else if (advect_w > 0.85f) advect_w = 0.85f;
        }

        float effective_ocean_an = ocean_an;
        if (is_lake) {
            effective_ocean_an = 0.20f;
        } else if (has_river) {
            if (ocean_an > river_evap_floor) effective_ocean_an = ocean_an;
            else                             effective_ocean_an = river_evap_floor;
        }

        const float source_local = surface_vapor_source(
            i, temp, base_m, wind_mag, effective_ocean_an, on_water, is_lake,
            has_river, river_flow_feedback, river_source_scale);
        float source_upwind = source_local;
        bool upstream_on_water = false;
        if (upstream_idx >= 0 && upstream_idx < n_cells) {
            float up_temp = TR[upstream_idx] + climate_anomaly + AA[upstream_idx];
            if (up_temp < 0.0f) up_temp = 0.0f;
            else if (up_temp > 1.0f) up_temp = 1.0f;
            float up_base_m = MR[upstream_idx];
            if (up_base_m < 0.0f) up_base_m = 0.0f;
            else if (up_base_m > 1.0f) up_base_m = 1.0f;
            const bool up_on_water = wf_is_water_terrain(TERR[upstream_idx]);
            upstream_on_water = up_on_water;
            const bool up_is_lake = (TERR[upstream_idx] == 18);
            const bool up_has_river = (!up_is_lake) && (RIV[upstream_idx] != 0) && (!up_on_water);
            const float up_river_q = up_has_river
                ? dc_clampf((RQ30 != nullptr ? RQ30[upstream_idx] : 0.0f), 0.0f, 1.0f)
                : 0.0f;
            float up_river_recycle_lock = 0.0f;
            if (up_has_river) {
                const float up_forcing_proxy = dc_clampf(PREV_CNV[upstream_idx] * 0.76f, 0.0f, 1.0f);
                up_river_recycle_lock = wf_smoothstep(0.035f, 0.12f, PP[upstream_idx])
                    * (1.0f - wf_smoothstep(0.16f, 0.44f, up_forcing_proxy))
                    * (0.35f + up_river_q * 0.65f);
                up_river_recycle_lock = dc_clampf(up_river_recycle_lock, 0.0f, 1.0f);
            }
            const float up_river_source_scale = 1.0f - up_river_recycle_lock * 0.72f;
            const float up_ocean_an = up_on_water ? TA[upstream_idx] : effective_ocean_an;
            source_upwind = surface_vapor_source(
                upstream_idx, up_temp, up_base_m, wind_mag, up_ocean_an,
                up_on_water, up_is_lake, up_has_river, up_river_q, up_river_source_scale);
        }

        // 平流式湿团：vapor 去 base_m 锚定 → 本地与上风加权平流(强度随风速) + 邻域扩散 + 蒸发源。
        // 允许短暂过饱和(不夹 cap 上限)，由后续凝结消耗 → 随风移动的湿团。镜像 field_solver.gd。
        // 方案③ vapor 全预报化:平流主导(floor 0.55→0.75,低风也强输送)→水汽主要由上风决定=连续方程平流项,
        // 蒸发只是注入、降水/凝结是汇,水汽随风成河(atmospheric river)→ψ 在水汽河上移动沿途有水可榨成雨。
        float adv_w_v = field_advect_vapor * (0.75f + 0.25f * wind_mag);
        if (adv_w_v > 0.99f) adv_w_v = 0.99f;
        float vapor = PV[i] + (advected_vapor - PV[i]) * adv_w_v;
        vapor = vapor + (neighbor_vapor - vapor) * field_diffusion;
        vapor += source_local + source_upwind * wind_mag * 0.25f;
        // Stage14c ψ>0 气旋水汽辐合抽吸：向邻域较湿处靠拢(把周围湿气卷入移动涡旋)→突破"水汽静止锚定"，
        // 让降水能随 ψ 平移。仅邻域更湿时抽(不凭空造汽,有界≤邻域均值)，避免破坏水量平衡致全局过湿。
        const float psi_now = (PSI != nullptr) ? PSI[i] : 0.0f;
        if (psi_now > 0.0f && neighbor_vapor > vapor) {
            vapor += (neighbor_vapor - vapor) * psi_now * 0.78f;   // Stage14e 0.55→0.78 更强抽吸→湿气更跟 ψ→移动更明显
        }
        if (vapor < 0.0f) vapor = 0.0f;
        (void)advect_w;

        // (背风焚风干燥已移入下方凝结/降水的 lift<0 抑制，避免对 vapor 重复扣减)

        // temp_min/temp_max 已在上方 P3 融合 gather 中算出。
        const float temp_gradient = temp_max - temp_min;
        // 斜压门(温度梯度大=锋面/中纬冷季)；Stage9 #5 用于把 ψ 致雨限定在斜压带(锋面雨)。
        const float baroclinic_gate = wf_smoothstep(0.04f, 0.16f, temp_gradient);
        // Stage13「让天气移动」：ψ 的演化已抽到独立全场 pass run_synoptic_advance_pass(每轮一次、
        // 不切片、半拉格朗日平移)。本 solve 循环只【读】ψ 当前值做耦合 → ψ 移动 → 云/雨成片随风平移。
        const float psi = (PSI != nullptr) ? PSI[i] : 0.0f;
        float relative_humidity = vapor / ((vapor_capacity > 0.001f) ? vapor_capacity : 0.001f);
        if (relative_humidity < 0.0f) relative_humidity = 0.0f;
        // W3：net 口径 p50=0.016 / p90=0.458；旧 (0.14,0.46) 是按 p50=0.376 的假基线标的，
        // 新场下 p50 处必须闭合、p90 处全开 ⇒ (p50, p90)。
        const float frontal_convergence = wf_smoothstep(0.02f, 0.46f, convergence);
        const float humidity_front_gate = wf_smoothstep(0.25f, 0.78f, relative_humidity);  // Stage2: 0.38→0.25 冷湿锋面成雨
        float frontogenesis = frontal_convergence * wf_smoothstep(0.04f, 0.16f, temp_gradient)
                            * humidity_front_gate * field_frontogenesis_gain;
        if (frontogenesis < 0.0f) frontogenesis = 0.0f;
        else if (frontogenesis > 1.0f) frontogenesis = 1.0f;
        const float lift_pos = (lift > 0.0f) ? lift : 0.0f;

        // Stage11 层状降水(stratiform)：对流(temp>0.48 暖门)挡死的冷/高/水区水汽充足却无触发——补一支不需浮力
        // 的层状成雨：湿度 + 弱动力抬升(地形/辐合/锋面/海面层云·lake-effect),温度越低权重越高(与对流互补,
        // 不在暖区重复加雨)。海面项=海洋层云/冷湖效应(修#4湖/冷海·实测水汽0.204最足却几乎不降)。
        const float strat_cool = 1.0f - wf_smoothstep(0.40f, 0.62f, temp);       // 暖→0(交给对流) 冷→1
        const float oro_elev = wf_smoothstep(0.45f, 0.82f, ELEV[i]);             // 高地形(山地)抬升强度,供 stratiform + trig 复用
        const float strat_humid = wf_smoothstep(0.32f, 0.62f, relative_humidity); // Stage14f 0.42→0.32 中湿(山地/冷区 rh~0.39)也成层状雨
        float strat_drive = lift_pos * 0.90f + convergence * 0.70f + frontogenesis * 0.80f
                          + oro_elev * 0.35f;                                     // 弱化静态山地云源，避免固定山地永雨
        if (on_water) strat_drive += (0.22f + wind_mag * 0.30f) * (1.0f - local_sea_ice * 0.92f);
        if (strat_drive > 1.0f) strat_drive = 1.0f;
        float stratiform = strat_humid * strat_cool * strat_drive * field_stratiform_gain;
        if (stratiform < 0.0f) stratiform = 0.0f;
        else if (stratiform > 1.0f) stratiform = 1.0f;

        // 热力对流(大陆夏季雷暴/对流雨)：地表加热(高温)+本地水汽 → 浮力抬升凝结+高效降水。修复内陆
        // rh 永远<<静力阈(实测~0.15<<0.55)、lift/辐合皆缺 → 蒸散/平流来的 vapor 凝不成云的死结
        // (用户洞察:内陆本地蒸发应能成雨)。仅陆地(海洋有独立对流抑制)。季节自限:冬温<0.45 不触发;
        // 降水耗 vapor→rh 降→对流减弱→不永雨,呈"晴-积累-雷暴"间歇。rh*4.2 门控干空气(rh<0.05)不虚假对流。
        // 2026-06-22 雨云化根因修复：陆地 rh 中位仅0.18(>0.55 仅2.7% → 静力凝结 sup 基本为0=死)，
        // 成云降水 76% 靠本项热力对流。rh*5.0 门控把干空气(rh0.18)硬拉成半饱和 → 温暖陆地处处冒弱对流
        // → 产云水后平流扩散 → 遍地雾+小雨、无晴无强雨。convective 实测双峰(p50=0,p75=0.39)：在谷底
        // 0.28 硬截断 → 砍遍地弱对流(仅损失6.5%降水)使其转晴/多云，保留强对流核 → 明显降水突显、拉开
        // "晴↔强降水"对比。(GDScript field_solver 镜像同值)
        float conv_raw = wf_smoothstep(0.48f, 0.74f, temp) * dc_clampf(relative_humidity * 2.6f, 0.0f, 1.0f);
        const float convective = (on_water || conv_raw < 0.42f) ? 0.0f : conv_raw;
        float ocean_convective = 0.0f;
        if (on_water) {
            ocean_convective = wf_smoothstep(0.10f, 0.22f, ocean_an)
                * wf_smoothstep(0.58f, 0.78f, temp)
                * dc_clampf(relative_humidity, 0.0f, 1.0f);
            const float open_water = 1.0f - local_sea_ice * 0.92f;
            const float warm_humid_marine = wf_smoothstep(0.54f, 0.74f, temp)
                * wf_smoothstep(0.47f, 0.69f, relative_humidity)
                * dc_clampf(open_water, 0.0f, 1.0f);
            const float marine_convective_seed = warm_humid_marine * (0.20f + wind_mag * 0.36f);
            if (marine_convective_seed > ocean_convective) ocean_convective = marine_convective_seed;
            if (ocean_convective > 1.0f) ocean_convective = 1.0f;
        }
        float onshore_moist_flux = 0.0f;
        float coastal_monsoon_flux = 0.0f;
        if (!on_water && upstream_idx >= 0 && upstream_on_water) {
            onshore_moist_flux = wind_mag * dc_clampf(relative_humidity, 0.0f, 1.0f)
                               * wf_smoothstep(0.54f, 0.75f, temp);
            coastal_monsoon_flux = onshore_moist_flux;
        } else if (on_water && upstream_idx >= 0) {
            const int downwind_idx = wx_aligned(i, wind_dx, wind_dy);
            bool near_land = false;
            if (downwind_idx >= 0 && downwind_idx < n_cells) {
                near_land = !wf_is_water_terrain(TERR[downwind_idx]);
            }
            if (near_land) {
                coastal_monsoon_flux = wind_mag * dc_clampf(relative_humidity, 0.0f, 1.0f)
                                     * wf_smoothstep(0.56f, 0.76f, temp) * 0.75f;
            }
        }
        if (thermal_monsoon_enabled &&
            i < state.monsoon_thermal_count) {
            coastal_monsoon_flux *= std::max(
                0.0f, MONS[static_cast<size_t>(i)]);
        }
        float dynamic_forcing = frontogenesis;
        const float convergence_forcing = convergence * 0.76f;
        if (convergence_forcing > dynamic_forcing) dynamic_forcing = convergence_forcing;
        if (convective > dynamic_forcing) dynamic_forcing = convective;
        if (ocean_convective > dynamic_forcing) dynamic_forcing = ocean_convective;
        if (coastal_monsoon_flux > dynamic_forcing) dynamic_forcing = coastal_monsoon_flux;
        if (cyclone_lift > dynamic_forcing) dynamic_forcing = cyclone_lift;
        if (stratiform > dynamic_forcing) dynamic_forcing = stratiform;  // Stage11 冷区层状降水
        // Stage12「让天气移动」: ψ>0(气旋/低压)在所有纬度加抬升(base)+斜压带额外强化(锋面)→移动的雨系统;
        // ψ 随流场平流→雨带跟着移动。Stage9 的纯斜压门控改为 base + 斜压 bonus(热带也吃 base,接受适度热带变率)。
        // Stage14「激进推 ψ 主导」: ψ>0(低压)强抬升成降水主驱动；ψ<0(高压)下沉【压低静止 lift】→连静止
        // 强迫的降水也压住 → 移动的晴空带。这样降水/晴空都跟 ψ 平移(天气成片移动)。代价:过湿+扰动雨热。
        if (psi > 0.0f) {
            dynamic_forcing += psi * (syn_base_lift + syn_front_force * baroclinic_gate);
        } else {
            dynamic_forcing *= (1.0f + psi * 0.85f);   // psi<0 → ×<1 压低静止抬升
            if (dynamic_forcing < 0.0f) dynamic_forcing = 0.0f;
        }
        // Stage6: post-rain 抑制留 45% 残余(辐合带雨团下完也进入不应期)。镜像 field_solver.gd。
        float post_rain_subsidence = wf_smoothstep(0.035f, 0.11f, PP[i])
            * (1.0f - 0.55f * wf_smoothstep(0.18f, 0.55f, dynamic_forcing));

        // climate-realism Stage1: Hadley/Ferrel omega (镜像 field_solver.gd)
        // dlat = 本格纬度距「热赤道」度数; ITCZ/风暴轴上升带增雨, 副热带下沉带抑制凝结+降水→晴干。
        float omega_ny = (wb_size_y > 0.001f)
            ? dc_clampf((POSY[i] - wb_pos_y) / wb_size_y, 0.0f, 1.0f) : 0.5f;
        float omega_adlat = (omega_ny - weather_lat_te_norm) * 180.0f;
        if (omega_adlat < 0.0f) omega_adlat = -omega_adlat;
        const float omega_itcz = 1.0f - wf_smoothstep(8.0f, 16.0f, omega_adlat);
        const float omega_storm = wf_smoothstep(40.0f, 48.0f, omega_adlat)
            * (1.0f - wf_smoothstep(62.0f, 70.0f, omega_adlat));
        float omega_ascent = (omega_itcz > omega_storm) ? omega_itcz : omega_storm;
        const float omega_descent = wf_smoothstep(14.0f, 22.0f, omega_adlat)
            * (1.0f - wf_smoothstep(34.0f, 42.0f, omega_adlat));
        const float omega_precip_mult = (1.0f + omega_ascent * OMEGA_ASCENT_GAIN)
            * (1.0f - omega_descent * OMEGA_DESCENT_GAIN);

        // 凝结 vapor→cloud_water：动力(抬升/辐合)主导 + 静力过饱和(rh 超阈) + 热力对流。
        float sup = relative_humidity - field_rh_condense;
        if (sup < 0.0f) sup = 0.0f;
        // Stage14「ψ 主导降水」：ψ 直接进【凝结/降水生成】(像 convective/stratiform 旁路 autoconv)，让移动的
        // ψ 涡旋成为降水主源→云雨成片随 ψ 平移。之前 base_lift 误加进 dynamic_forcing(不驱动 cond/trig)→无效。
        const float psi_lift = (psi > 0.0f) ? psi * (syn_base_lift + syn_front_force * baroclinic_gate) : 0.0f;
        const float psi_supp = (psi < 0.0f) ? (1.0f + psi * 0.50f) : 1.0f;  // ψ<0(高压)压低凝结+降水→移动晴空(Stage14c 0.80→0.50 收温和,防压太干)
        float cond_force = sup * field_static_cond_w + lift_pos * field_lift_cond_gain
                         + convergence * field_conv_cond_gain + frontogenesis * 1.35f
                         + convective * field_thermal_conv_cond
                         + ocean_convective * 0.90f
                         + stratiform * 0.75f
                         + cyclone_lift * 1.10f
                         + psi_lift * 1.20f;     // 方案③+ 0.90→1.20 ψ 致凝结(移动涡旋成云,主导)
        if (cond_force < 0.0f) cond_force = 0.0f;
        else if (cond_force > 1.0f) cond_force = 1.0f;
        cond_force *= psi_supp;                  // Stage14 ψ<0 压低凝结
        cond_force *= (1.0f - post_rain_subsidence * 0.45f);
        cond_force *= (1.0f - omega_descent * OMEGA_DESCENT_COND);   // 副热带下沉抑制凝结
        float condensation = vapor * cond_force * field_condense_rate;
        if (lift < 0.0f) {                       // 背风下沉(焚风)抑制凝结
            float foehn = 1.0f + lift * field_rain_shadow_drying;
            if (foehn < 0.0f) foehn = 0.0f;
            condensation *= foehn;
        }
        if (condensation > vapor * 0.92f) condensation = vapor * 0.92f;
        if (condensation < 0.0f) condensation = 0.0f;
        vapor -= condensation;

        // cloud_water 随风平流(搬运湿团) + 凝结加入 + 邻域扩散。复用 vapor 平流 helper(传 PCW)。
        float cloud_water = (PCW != nullptr) ? PCW[i] : 0.0f;
        if (PCW != nullptr && upstream_idx >= 0 && upstream_idx < n_cells) {
            // NS 化 Phase 2:与 vapor 同一张轨迹表(湿团整体随风输运)。
            const float cw_upwind = (TRAJ_IDX != nullptr)
                ? wx_traj_sample(i, PCW)
                : wx_upstream_avg(i, upstream_idx, PCW, wind_dx, wind_dy);
            const float cw_neighbor = wf_neighbor_average_vapor_idx(i, NB, PCW);
            float adv_w_c = field_advect_cloud * (0.55f + 0.45f * wind_mag);
            if (adv_w_c > 0.98f) adv_w_c = 0.98f;
            cloud_water = cloud_water + (cw_upwind - cloud_water) * adv_w_c;
            cloud_water = cloud_water + (cw_neighbor - cloud_water) * field_diffusion;
        }
        cloud_water += condensation;
        if (cloud_water < 0.0f) cloud_water = 0.0f;
        else if (cloud_water > 1.0f) cloud_water = 1.0f;

        float instability = (temp - 0.48f) * 0.80f
                          + relative_humidity * 0.30f
                          + convergence * 0.55f
                          + lift_pos * 1.20f
                          + frontogenesis * 0.55f
                          + ocean_convective * 0.35f;
        instability += cyclone_lift * 0.45f;
        if (instability < 0.0f) instability = 0.0f;
        else if (instability > 1.0f) instability = 1.0f;

#include "runtime_climate_passes_weather_precipitation.inc"

        // (line 751-757) write outputs
        OUT_VAP[i] = vapor_after_precip;
        OUT_CLD[i] = cloud;
        if (OUT_CW != nullptr) {
            OUT_CW[i] = cloud_water;
        }
        OUT_PRE[i] = precip;
        OUT_INS[i] = instability;
        OUT_INT[i] = intensity;
        OUT_CNV[i] = convergence;
        if (use_next_outputs) {
            OUT_TYP_I32[i] = int32_t(wt);
        } else {
            OUT_TYP[i] = display_wt;
            OUT_FIN[i] = 1; // weather_field_initialized = true
        }
    }
}
} // namespace pk_async_climate
} // namespace pk
