# Transplants the stage 11 WEATHER hot loop out of DCWorldExt into a pure kernel.
#
# The body is moved as literal text and only the names that used to resolve to
# DCWorldExt members or Godot Dictionary lookups are rewritten. Anything that
# rewrites an expression rather than a name is listed explicitly below, so the
# diff can be read as "these N substitutions, nothing else" — which is the only
# practical way to argue a 640-line numeric loop came out bit-identical.
import io
import re
import sys

SRC = 'gdext/src/world_ext_weather.cpp'
DST = 'gdext/src/runtime_climate_passes.cpp'

BODY_BEGIN = '    for (int i = rb; i < re; ++i) {'
BODY_END_MARKER = '    }; // run_weather_cell_range'

# (pattern, replacement, expected_count). Order matters.
SUBS = [
    # DCWorldExt members → WeatherFieldState lanes.
    (r'i < int\(_cyclone_force_tag\.size\(\)\)', 'i < state.cyclone_tag_count', 1),
    (r'_cyclone_force_tag\[', 'CYC_TAG[', 1),
    (r'_cyclone_force_generation', 'cyclone_generation', 1),
    (r'_cyclone_force_lift\[', 'CYC_LIFT[', 1),
    (r'_cyclone_force_x\[', 'CYC_X[', 1),
    (r'_cyclone_force_y\[', 'CYC_Y[', 1),
    (r'i < int\(_phys_monsoon_thermal\.size\(\)\)', 'i < state.monsoon_thermal_count', 1),
    (r'_phys_monsoon_thermal\[', 'MONS[', 1),
    # The two per-cell Dictionary lookups become knob fields.
    (r'if \(bool\(knobs\.get\("thermal_monsoon_enabled",\s*\n'
     r'\s*_native_runtime_config\.get\("thermal_monsoon_enabled", false\)\)\) &&\n'
     r'(\s*)i < state\.monsoon_thermal_count\) \{',
     r'if (thermal_monsoon_enabled &&\n\1i < state.monsoon_thermal_count) {', 1),
    (r'wt = uint8_t\(std::clamp\(int\(knobs\.get\("cyclone_storm_type_id", 2\)\), 0, 255\)\);',
     'wt = cyclone_storm_type_id;', 1),
    # Interleaved Vector2 positions → POD lane. Only the omega latitude reads it.
    (r'POS\[i\]\.y', 'POSY[i]', 1),
    (r'Math::sqrt', 'std::sqrt', 1),
    # field_vapor_relax_rate is a caller-contract knob the advective path stopped
    # reading; the void cast has nothing to silence once it is not a local.
    (r'\s*\(void\)field_vapor_relax_rate;', '', 1),
]

PROLOGUE = '''
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
'''

EPILOGUE = '''}

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
'''


def main():
    src = io.open(SRC, encoding='utf-8').read()
    lines = src.split('\n')
    try:
        b = lines.index(BODY_BEGIN)
        e = lines.index(BODY_END_MARKER)
    except ValueError as exc:
        sys.exit('body markers not found: %s' % exc)
    # lines[e - 1] is the for loop's own closing brace; keep it and drop only the
    # lambda closer on line e.
    body = '\n'.join(lines[b:e])
    for pattern, repl, expect in SUBS:
        body, count = re.subn(pattern, repl, body)
        if count != expect:
            sys.exit('substitution %r matched %d times, expected %d'
                     % (pattern, count, expect))
    for leftover in ('knobs.get', '_cyclone_force', '_phys_monsoon',
                     '_native_runtime_config', 'POS[', 'Math::'):
        if leftover in body:
            sys.exit('leftover reference to %r in transplanted body' % leftover)

    dst = io.open(DST, encoding='utf-8').read()
    tail = '\n} // namespace pk_async_climate\n} // namespace pk\n'
    if not dst.endswith(tail):
        sys.exit('unexpected tail in %s' % DST)
    kernel = PROLOGUE + body + '\n' + EPILOGUE
    dst = dst[:-len(tail)] + kernel + tail
    io.open(DST, 'w', encoding='utf-8', newline='').write(dst)
    print('transplanted %d body lines into %s' % (len(body.split('\n')), DST))


main()
