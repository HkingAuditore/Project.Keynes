#include "runtime_climate_passes.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <vector>

namespace pk {
namespace pk_async_climate {

// ─── stage 11 WEATHER：ψ 整步推进 ───────────────────────────────────────────
//
// 这里是 ψ 推进的唯一实现。搬过来之前生产热路径里内联了一份、
// DCWorldExt::run_synoptic_advance_pass 里另有一份，两份的 damp / diffuse 默认值
// 不同，且只有内联版带斜压振幅饱和与阈值清零 —— 也就是说"提取出的内核该等价于
// 哪一份"没有答案。以内联版为准合成一份，因为跑在生产热路径上的是它。
void synoptic_advance_pure(int n_cells,
                           const int32_t *neighbor_indices,
                           const float *pos_x,
                           const float *pos_y,
                           const float *wind_x,
                           const float *wind_y,
                           const float *temp_norm,
                           const SynopticAdvanceKnobs &knobs,
                           std::vector<float> &psi,
                           std::vector<float> &psi_prev) {
    if (n_cells <= 0 || neighbor_indices == nullptr || pos_x == nullptr ||
        pos_y == nullptr || wind_x == nullptr || wind_y == nullptr ||
        temp_norm == nullptr) {
        return;
    }
    if (psi.size() != (size_t)n_cells) psi.assign((size_t)n_cells, 0.0f);
    psi_prev = psi;                                     // 整步快照（脱离切片）
    float * const __restrict PSI_W = psi.data();
    const float * const __restrict PSI_R = psi_prev.data();
    const int32_t * const __restrict NB = neighbor_indices;
    const float * const __restrict WX = wind_x;
    const float * const __restrict WY = wind_y;
    const float * const __restrict TR = temp_norm;

    int adv_cells = knobs.adv_cells;
    if (adv_cells < 0) adv_cells = 0;
    else if (adv_cells > 16) adv_cells = 16;

    for (int p = 0; p < n_cells; ++p) {
        const int pb = p * 6;
        // 平滑引导流：风邻域平均（去地转风小尺度切变→平移连贯，不打散）
        float gx = WX[p], gy = WY[p];
        int gn = 1;
        for (int d = 0; d < 6; ++d) {
            const int nb = NB[pb + d];
            if (nb < 0) continue;
            gx += WX[nb]; gy += WY[nb]; ++gn;
        }
        gx /= float(gn); gy /= float(gn);
        // 半拉格朗日真平移：沿 -引导流走 adv_cells 格取 departure 的 ψ_prev
        int dep = p;
        for (int s = 0; s < adv_cells; ++s) {
            const int up = wf_neighbor_aligned_idx_xy(
                dep, -gx, -gy, pos_x, pos_y, NB, n_cells,
                knobs.cell_pos_scale, knobs.wrap_width_x);
            if (up < 0 || up >= n_cells) break;
            dep = up;
        }
        float ps = PSI_R[dep];
        // 斜压门：邻域温度梯度
        float tmn = TR[p], tmx = TR[p];
        for (int d = 0; d < 6; ++d) {
            const int nb = NB[pb + d];
            if (nb < 0) continue;
            const float tv = TR[nb];
            if (tv < tmn) tmn = tv;
            if (tv > tmx) tmx = tv;
        }
        const float g = wf_smoothstep(0.04f, 0.16f, tmx - tmn);
        const float aps0 = ps < 0.0f ? -ps : ps;
        // 斜压增长随振幅饱和→有界，不会全场饱和
        ps *= (1.0f + knobs.baroclinic * g * (1.0f - aps0));
        const float sr = knobs.seed_rate * (0.30f + 0.70f * g);
        if (wf_hash01(p, knobs.tick) < sr)
            ps += knobs.seed_amp * (wf_hash01(p + 50021, knobs.tick) - 0.5f) * 2.0f;
        ps += (wf_neighbor_average_vapor_idx(p, NB, PSI_R) - ps) * knobs.diffuse;
        ps *= knobs.damp;
        if (ps > 1.0f) ps = 1.0f; else if (ps < -1.0f) ps = -1.0f;
        // 阈值清零→防低值 ψ 经扩散/平流铺满全场，保稀疏移动涡旋
        if (ps < 0.05f && ps > -0.05f) ps = 0.0f;
        PSI_W[p] = ps;
    }
}

// ─── stage 11 WEATHER：field solve 主循环（纯内核）──────────────────────────
//
// 循环体是从 DCWorldExt::run_weather_field_solve_pass 原样搬过来的，只把原先解析
// 到 DCWorldExt 成员或 Dictionary 查找的名字换成结构体字段（见
// tools/runtime/extract_weather_kernel.py 里的替换表）。数值语句一行未改。
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
            float river_forcing_proxy = convergence * 0.65f;
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
                const float up_forcing_proxy = dc_clampf(PREV_CNV[upstream_idx] * 0.65f, 0.0f, 1.0f);
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
        const float frontal_convergence = wf_smoothstep(0.14f, 0.46f, convergence);
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
        float strat_drive = lift_pos * 0.90f + convergence * 0.60f + frontogenesis * 0.80f
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
        const float convergence_forcing = convergence * 0.65f;
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

        // 降水：autoconversion 消耗 cloud_water。动力(辐合/抬升/不稳定)触发主导，地形弱增强；
        // 背景 base_frac 很小 → 无动力区降水压到 wet 阈值以下 → 只有移动天气系统处成雨 → 雨随系统移动。
        float trig = field_autoconversion * (field_precip_base_frac
                        + lift_pos * field_lift_precip_gain
                        + convergence * field_conv_precip_gain
                        + frontogenesis * 0.85f
                        + instability * 0.30f);
        trig *= (1.0f + lift_pos * field_oro_precip_gain);
        trig += convective * field_thermal_conv_precip;   // 对流雨高效成雨，旁路 autoconv 瓶颈(内陆 cw 少)
        trig += ocean_convective * 0.95f;
        trig += stratiform * 0.80f;   // Stage11 层状降水高效成雨(冷/高/水区,旁路 autoconv)→修 #4湖/#5a雪/#6山
        trig += cyclone_lift * 0.75f;
        trig += psi_lift * 1.50f;     // 方案③+ 1.10→1.50 ψ 致雨主驱动(降水成片随 ψ 平移,盖过静止 lift)
        trig += oro_elev * 0.18f * wf_smoothstep(0.02f, 0.10f, cloud_water);  // 弱化固定地形转化，保留迎风坡但不锁死雨核
        trig *= psi_supp;             // Stage14 ψ<0 压低降水→移动晴空
        if (trig < 0.0f) trig = 0.0f;
        else if (trig > 0.95f) trig = 0.95f;
        float precip_target = cloud_water * trig;
        precip_target *= omega_precip_mult;   // Stage1 omega: ITCZ/风暴轴增雨 + 副热带下沉抑雨(纬向廓线)
        // Stage9 #5 ψ 耦合：ψ<0(高压)强抑雨→湿季间断；ψ>0(低压)增雨——基础弱(syn_enh，热带也仅此)，
        // 斜压带额外强增(syn_front_enh×gate)→冷季锋面雨。这样热带不堆暴雨、中纬冷季出现雨热不同期降水。
        if (PSI != nullptr) {
            float syn_enh_eff = syn_enh + syn_front_enh * baroclinic_gate;
            float syn_mult = 1.0f + (psi < 0.0f ? psi * syn_supp : psi * syn_enh_eff);
            if (syn_mult < 0.0f) syn_mult = 0.0f;
            precip_target *= syn_mult;
        }
        // Stage6e 对流抑制记忆(双稳)：读累积抑制(本 tick 起始)，硬阈压制移到最终降水处(EMA 之后)。
        const float inhib_old = (INHIB != nullptr) ? INHIB[i] : 0.0f;
        if (lift < 0.0f) {
            float shadow = (-lift) * field_rain_shadow_drying;
            if (shadow > 0.85f) shadow = 0.85f;
            precip_target *= (1.0f - shadow);
        }
        if (has_river && river_recycle_lock > 0.0f) {
            const float river_relief = river_recycle_lock
                * (1.0f - wf_smoothstep(0.22f, 0.50f, dynamic_forcing));
            if (river_relief > 0.0f) {
                const float cloud_relief = cloud_water * 0.22f * river_relief;
                cloud_water -= cloud_relief;
                vapor += cloud_relief * 0.60f;
                precip_target *= (1.0f - 0.48f * river_relief);
            }
        }
        // 水面对流抑制(保留动力门控：辐合/锋生/暖流异常 释放降水；instability 仅极端深对流安全阀)。
        float ocean_drive = 0.0f;
        if (on_water) {
            float drv_an = ocean_an / 0.16f;
            if (drv_an < 0.0f) drv_an = 0.0f; else if (drv_an > 1.0f) drv_an = 1.0f;
            float drv_in = (instability - 0.52f) / 0.30f;
            if (drv_in < 0.0f) drv_in = 0.0f; else if (drv_in > 1.0f) drv_in = 1.0f;
            float drv_cv = (convergence - 0.38f) / 0.16f;
            if (drv_cv < 0.0f) drv_cv = 0.0f; else if (drv_cv > 1.0f) drv_cv = 1.0f;
            float drv_fr = frontogenesis / 0.16f;
            if (drv_fr < 0.0f) drv_fr = 0.0f; else if (drv_fr > 1.0f) drv_fr = 1.0f;
            float drv_mn = coastal_monsoon_flux / 0.18f;
            if (drv_mn < 0.0f) drv_mn = 0.0f; else if (drv_mn > 1.0f) drv_mn = 1.0f;
            float drv_hc = wf_smoothstep(0.47f, 0.69f, relative_humidity)
                * wf_smoothstep(0.040f, 0.105f, cloud_water)
                * wf_smoothstep(0.54f, 0.74f, temp);
            // Stage14e 湖泊不再额外压低 humid-convective 驱动(原 ×0.60 致湖面少雨绕湖)；湖泊像小内海正常对流。
            drv_hc *= 0.68f;
            ocean_drive = drv_an;
            if (drv_in > ocean_drive) ocean_drive = drv_in;
            if (drv_cv > ocean_drive) ocean_drive = drv_cv;
            if (drv_fr > ocean_drive) ocean_drive = drv_fr;
            if (drv_mn > ocean_drive) ocean_drive = drv_mn;
            if (drv_hc > ocean_drive) ocean_drive = drv_hc;
            if (omega_ascent > ocean_drive) ocean_drive = omega_ascent;   // ITCZ/风暴轴释放海面抑制
            float precip_suppression = field_ocean_precip_suppression;
            if (is_lake && precip_suppression > 0.10f) precip_suppression = 0.10f;  // Stage14e 湖泊几乎不抑制(像内陆水体能下雨)→不再绕湖(原0.35仍压制)
            if (!is_lake && precip_suppression > 0.78f) precip_suppression = 0.78f;
            const float ocean_lo = 1.0f - precip_suppression;
            precip_target *= ocean_lo + (1.0f - ocean_lo) * ocean_drive;
            const float marine_relief = post_rain_subsidence
                * (1.0f - wf_smoothstep(0.30f, 0.58f, ocean_drive));
            precip_target *= (1.0f - marine_relief * 0.72f);
        }
        if (precip_target > cloud_water) precip_target = cloud_water;   // 降水不超过现有云水
        if (precip_target < 0.0f) precip_target = 0.0f;
        cloud_water -= precip_target;
        if (cloud_water < 0.0f) cloud_water = 0.0f;
        const float precip_cloud_reserve = precip_target * (0.18f + dynamic_forcing * 0.18f);
        cloud_water += precip_cloud_reserve;
        if (cloud_water > 1.0f) cloud_water = 1.0f;
        const float quiet_core = 1.0f - wf_smoothstep(0.12f, 0.50f, dynamic_forcing);
        if (on_water && !is_lake && ocean_drive < 0.34f) {   // Stage14e 湖泊不刮云水(marine_scour 是海洋机制,会让小湖云存不住→绕湖)
            float marine_scour = cloud_water * (0.036f + (0.34f - ocean_drive) * 0.18f)
                               * (1.0f + post_rain_subsidence * 1.60f);
            if (marine_scour < 0.0f) marine_scour = 0.0f;
            if (marine_scour > cloud_water) marine_scour = cloud_water;
            cloud_water -= marine_scour;
            vapor += marine_scour * 0.55f;
        }

        // 干空气云水再蒸发回 vapor（湿团边缘消散 → 闭合水量收支）。
        float reevap = cloud_water * field_cloud_reevap * (1.0f - relative_humidity)
                     * (1.0f + post_rain_subsidence * 1.75f + quiet_core * 0.75f);
        if (reevap < 0.0f) reevap = 0.0f;
        if (reevap > cloud_water) reevap = cloud_water;
        cloud_water -= reevap;
        vapor += reevap;
        if (on_water) {
            vapor *= (1.0f - post_rain_subsidence
                * (1.0f - wf_smoothstep(0.28f, 0.58f, ocean_drive)) * 0.045f);
        }

        // 降水稳定性(地形阻尼 + 极端 soft cap) + EMA 时间惯性(保留)。
        precip_target = wf_apply_precip_stability(
            TERR[i], precip_target,
            field_wet_terrain_precip_damping,
            field_lake_precip_damping,
            field_extreme_precip_soft_cap,
            field_extreme_precip_softness);
        // Stage10 不应期(inhib≥1)作用于 target(EMA 前)→降水随惯性平滑衰减到近零，不再瞬间砍断(去时间跳变)。镜像 field_solver.gd。
        if (inhib_old >= 1.0f) {
            precip_target *= (1.0f - INHIB_STRENGTH);
        }
        float precip = PP[i] + (precip_target - PP[i]) * field_precip_inertia;
        if (precip_target < PP[i] && dynamic_forcing < 0.20f) {
            precip = precip + (precip_target - precip) * (post_rain_subsidence * 0.55f);
        }
        // Stage10b 空间平滑(非对称)：强填洞(precip<邻域→去棋盘洞+扩雨到干邻格，降永晴)、弱削峰(×0.30→保超级单体暴雨)。镜像 field_solver.gd。
        if (field_precip_spatial_smooth > 0.0f) {
            const float nbr_precip = wf_neighbor_average_vapor_idx(i, NB, PP);
            const float k = (nbr_precip > precip) ? field_precip_spatial_smooth
                                                  : field_precip_spatial_smooth * 0.30f;
            precip += (nbr_precip - precip) * k;
        }
        const float effective_precip_floor = on_water ? 0.014f : 0.018f;
        if (precip < 0.003f) precip = 0.0f;
        const float provisional_cloud = dc_clampf(cloud_water * 1.10f + condensation * 0.25f, 0.0f, 1.0f);
        const float temp_anom_i = (TANO != nullptr) ? TANO[i] : 0.0f;
        const float snow_cover_cls = (SNOWR != nullptr) ? SNOWR[i] : 0.0f;
        uint8_t pre_wt = wf_classify_field_weather_at(
            temp, vapor, provisional_cloud, cloud_water, precip, instability,
            ocean_an, wind_len, temp_anom_i,
            std::max(onshore_moist_flux, coastal_monsoon_flux),
            cold_precip_as_blizzard, snow_classification_margin, on_water, snow_cover_cls);
        const bool quiet_non_precip = !wf_is_precip_weather_type(pre_wt) && quiet_core > 0.0f;
        if ((precip < 0.003f || quiet_non_precip) && quiet_core > 0.0f) {
            float clear_cap = 0.065f + dynamic_forcing * 0.12f;
            if (on_water && ocean_drive < 0.20f) {
                const float ocean_cap = 0.070f + ocean_drive * 0.18f;
                if (ocean_cap < clear_cap) clear_cap = ocean_cap;
            }
            if (cloud_water > clear_cap) {
                const float excess_cloud_water = (cloud_water - clear_cap) * quiet_core;
                cloud_water -= excess_cloud_water;
                vapor += excess_cloud_water * 0.75f;
            }
        }
        if (quiet_non_precip && precip < effective_precip_floor) {
            vapor += precip * 0.65f;
            precip = 0.0f;
        }
        if (vapor < 0.0f) vapor = 0.0f;
        else if (vapor > 1.0f) vapor = 1.0f;   // 写回夹 [0,1]：下游(分类/可视/植被)按归一化消费
        float vapor_after_precip = vapor;
        const float rain_core = wf_smoothstep(0.025f, 0.095f, precip);
        const float front_core = wf_smoothstep(0.08f, 0.55f, frontogenesis);
        float cloud_floor = rain_core * (0.14f + rain_core * 0.22f);
        const float front_cloud_floor = front_core * 0.30f;
        if (front_cloud_floor > cloud_floor) cloud_floor = front_cloud_floor;
        if (convective > 0.0f) {
            const float convective_cloud_floor = 0.06f + convective * 0.18f;
            if (convective_cloud_floor > cloud_floor) cloud_floor = convective_cloud_floor;
        }
        if (ocean_convective > 0.0f) {
            const float ocean_cloud_floor = 0.10f + ocean_convective * 0.16f;
            if (ocean_cloud_floor > cloud_floor) cloud_floor = ocean_cloud_floor;
        }
        if (quiet_non_precip) {
            const float fair_humid = wf_smoothstep(0.34f, 0.56f, relative_humidity);
            const float fair_cloud_floor = fair_humid * quiet_core * (0.050f + fair_humid * 0.070f);
            if (fair_cloud_floor > cloud_floor) cloud_floor = fair_cloud_floor;
        }
        float cloud = cloud_water * 1.10f + condensation * 0.25f;
        if (cloud < cloud_floor) cloud = cloud_floor;
        // Stage15 云量时间 EMA(减 shader 闪烁)：cloud 混入瞬时 condensation/cloud_floor(无时间惯性)→在渲染阈值
        // 附近抖动闪烁。用上帧云量做 EMA 平滑(cloud_water 本身已平滑,只需压住瞬时项的抖)。
        const float prev_cloud = PREV_CLOUD[i];
        cloud = prev_cloud + (cloud - prev_cloud) * field_cloud_inertia;
        if (cloud < 0.0f) cloud = 0.0f;
        else if (cloud > 1.0f) cloud = 1.0f;

        // classify + intensity
        uint8_t wt = wf_classify_field_weather_at(
            temp, vapor, cloud, cloud_water, precip, instability,
            ocean_an, wind_len, temp_anom_i,
            std::max(onshore_moist_flux, coastal_monsoon_flux),
            cold_precip_as_blizzard, snow_classification_margin, on_water, snow_cover_cls);
        if (cyclone_lift >= 0.58f && on_water) {
            wt = cyclone_storm_type_id;
        }
        if (!wf_is_precip_weather_type(wt) && precip > 0.0f) {
            vapor += precip * 0.65f;
            if (vapor > 1.0f) vapor = 1.0f;
            vapor_after_precip = vapor;
            precip = 0.0f;
        } else if (precip > 0.0f) {
            // Stage6 放电：实际降水抽干本格水汽→自发停雨/消散+随上风水汽移动+海面自生成。镜像 field_solver.gd。
            // Stage6b：持续降水(PP[i])放电翻倍→砍"连下一周"长尾，不动新生短雨段。
            const float discharge_amp = 1.0f + DISCHARGE_SUSTAIN * wf_smoothstep(0.04f, 0.10f, PP[i]);
            vapor_after_precip -= precip * VAPOR_DISCHARGE * discharge_amp;
            if (vapor_after_precip < 0.0f) vapor_after_precip = 0.0f;
        }
        // Stage6g 更新对流抑制(按时长两段)：充能期连续降水累加→满进不应期；不应期衰减→落回清零重启。镜像 field_solver.gd。
        if (INHIB != nullptr) {
            float ni;
            if (inhib_old >= 1.0f) {
                ni = inhib_old - INHIB_REFRAC;
                if (ni < 1.0f) ni = 0.0f;
            } else if (precip > INHIB_WET) {
                ni = inhib_old + INHIB_CHARGE;
                if (ni >= 1.0f) ni = 2.0f;
            } else {
                ni = inhib_old * INHIB_LEAK;
            }
            INHIB[i] = ni;
        }
        float intensity = wf_field_intensity_for_type(
            wt, temp, vapor, cloud, precip, instability, ocean_an);
        if (refresh_convergence && apply_convergence_boost) {
            wf_apply_frontal_convergence_boost_idx(
                i, TR, AA, NB, climate_anomaly, convergence,
                temp, vapor, ocean_an,
                cloud, precip, instability, wt, intensity);
        }

        uint8_t display_wt = wt;
        if (weather_transition_enabled && OUT_PREV_TYP != nullptr && OUT_TARGET_TYP != nullptr && OUT_ALPHA != nullptr) {
            const uint8_t current_display = OUT_TYP[i];
            uint8_t prev_type = OUT_PREV_TYP[i];
            uint8_t target_type = OUT_TARGET_TYP[i];
            float alpha = OUT_ALPHA[i];
            if (alpha < 0.0f) alpha = 0.0f;
            else if (alpha > 1.0f) alpha = 1.0f;
            if (target_type != wt) {
                prev_type = current_display;
                target_type = wt;
                alpha = weather_transition_alpha_rate * weather_transition_dt_days; // [dt-aware] 当前求解即计入
                if (alpha > 1.0f) alpha = 1.0f;
            } else if (prev_type == target_type || current_display == target_type) {
                prev_type = target_type;
                alpha = 0.0f;
            } else {
                alpha += weather_transition_alpha_rate * weather_transition_dt_days;
                if (alpha > 1.0f) alpha = 1.0f;
            }
            display_wt = (alpha >= 1.0f) ? target_type : prev_type;
            if (alpha >= 1.0f) {
                prev_type = target_type;
                alpha = 0.0f;
            }
            OUT_PREV_TYP[i] = prev_type;
            OUT_TARGET_TYP[i] = target_type;
            OUT_ALPHA[i] = alpha;
        }

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


// 邻域几何缓存：self->nb 的 wrapped delta 与 1/sqrt(dl2)。原来内联在 solve pass 里，
// 与主循环的 wf_wrapped_delta / sqrt 同序同式，所以缓存命中与否 bit-equal。
void weather_field_geometry_cache_pure(int n_cells,
                                       const int32_t *neighbor_indices,
                                       const float *pos_x,
                                       const float *pos_y,
                                       float wrap_width_x,
                                       float *geom_dx,
                                       float *geom_dy,
                                       float *geom_invd) {
    if (n_cells <= 0 || neighbor_indices == nullptr || pos_x == nullptr ||
        pos_y == nullptr || geom_dx == nullptr || geom_dy == nullptr ||
        geom_invd == nullptr) {
        return;
    }
    for (int p = 0; p < n_cells; ++p) {
        const int b = p * 6;
        const float sx = pos_x[p];
        const float sy = pos_y[p];
        for (int d = 0; d < 6; ++d) {
            const int32_t nb_idx = neighbor_indices[b + d];
            if (nb_idx < 0) {
                geom_dx[b + d] = 0.0f;
                geom_dy[b + d] = 0.0f;
                geom_invd[b + d] = 0.0f;
                continue;
            }
            float dx = 0.0f, dy = 0.0f;
            wf_wrapped_delta(sx, sy, pos_x[nb_idx], pos_y[nb_idx],
                             wrap_width_x, dx, dy);
            geom_dx[b + d] = dx;
            geom_dy[b + d] = dy;
            const float dl2 = dx * dx + dy * dy;
            geom_invd[b + d] = (dl2 > 0.0001f) ? (1.0f / std::sqrt(dl2)) : 0.0f;
        }
    }
}

} // namespace pk_async_climate
} // namespace pk
