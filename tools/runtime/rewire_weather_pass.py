# Rewires DCWorldExt::run_weather_field_solve_pass onto the shared stage 11 kernel.
#
# Replaces the inline geometry-cache build and the whole hot loop (lambdas +
# dispatch) with knob/lane/state assembly plus calls into
# pk_async_climate::weather_field_solve_pure. Run once; it asserts on the exact
# lines it expects so a second run fails loudly instead of duplicating text.
import io

P = 'gdext/src/world_ext_weather.cpp'

GEOM = '''    if (start_idx == 0) {
        const size_t need = (size_t)n_cells * 6;
        if (_wf_nb_dx.size() != need) {
            _wf_nb_dx.assign(need, 0.0f);
            _wf_nb_dy.assign(need, 0.0f);
            _wf_nb_invd.assign(need, 0.0f);
        }
        pk_async_climate::weather_field_geometry_cache_pure(
            n_cells, NB, _wf_pos_x.data(), _wf_pos_y.data(),
            weather_wrap_width_x, _wf_nb_dx.data(), _wf_nb_dy.data(),
            _wf_nb_invd.data());
        _wf_nb_geom_n = n_cells;
        _wf_nb_geom_wrap = weather_wrap_width_x;
    }'''

CALL = '''    // \u2500\u2500\u2500 stage 11 \u7684\u6570\u503c\u6838\u5fc3\u5df2\u62bd\u6210\u5171\u4eab\u7eaf\u5185\u6838 \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
    // pk_async_climate::weather_field_solve_pure\u3002\u8fd9\u91cc\u53ea\u505a Godot \u4fa7\u7684\u88c5\u914d\uff1a
    // \u628a Dictionary knob \u6536\u6210 POD \u7ed3\u6784\u4f53\u3001\u628a slot/PackedArray \u6536\u6210\u88f8\u6307\u9488 lane\u3001
    // \u628a DCWorldExt \u4e0a\u90a3\u4e03\u7ec4\u8df3 tick \u72b6\u6001\u6536\u6210 state\u3002\u5faa\u73af\u4f53\u4e00\u884c\u6570\u503c\u90fd\u4e0d\u5728\u8fd9\u91cc\u4e86\uff0c
    // \u6240\u4ee5 worker \u8dd1\u7684\u548c\u751f\u4ea7\u8dd1\u7684\u662f\u540c\u4e00\u4efd\u4ee3\u7801\u3002
    const int32_t *TRAJ_IDX = nullptr;
    const float   *TRAJ_W   = nullptr;
    if (_phys_wind_traj_valid && _phys_wind_traj_consume_enabled
            && int(_phys_wind_traj_idx.size()) == n_cells * 3) {
        if (pk_wind_state_fp(n_cells, WX, WY, WSPD) == _phys_wind_traj_fp) {
            TRAJ_IDX = _phys_wind_traj_idx.data();
            TRAJ_W   = _phys_wind_traj_w.data();
        } else {
            ++_phys_wind_traj_stale_count;
        }
    }

    pk_async_climate::WeatherFieldKnobs wfk;
    wfk.n_cells = n_cells;
    wfk.climate_anomaly = climate_anomaly;
    wfk.refresh_convergence = refresh_convergence;
    wfk.apply_convergence_boost = apply_convergence_boost;
    wfk.use_next_outputs = use_next_outputs;
    wfk.field_advect_steps = field_advect_steps;
    wfk.field_diffusion = field_diffusion;
    wfk.field_ocean_evap_gain = field_ocean_evap_gain;
    wfk.field_precip_inertia = field_precip_inertia;
    wfk.field_precip_spatial_smooth = field_precip_spatial_smooth;
    wfk.field_cloud_inertia = field_cloud_inertia;
    wfk.field_wet_terrain_precip_damping = field_wet_terrain_precip_damping;
    wfk.field_lake_precip_damping = field_lake_precip_damping;
    wfk.field_lake_evap_scale = field_lake_evap_scale;
    wfk.field_extreme_precip_soft_cap = field_extreme_precip_soft_cap;
    wfk.field_extreme_precip_softness = field_extreme_precip_softness;
    wfk.field_land_evapotranspiration_gain = field_land_evapotranspiration_gain;
    wfk.field_ocean_precip_suppression = field_ocean_precip_suppression;
    wfk.field_frontogenesis_gain = field_frontogenesis_gain;
    wfk.field_rain_shadow_drying = field_rain_shadow_drying;
    wfk.field_advect_vapor = field_advect_vapor;
    wfk.field_advect_cloud = field_advect_cloud;
    wfk.field_rh_condense = field_rh_condense;
    wfk.field_static_cond_w = field_static_cond_w;
    wfk.field_condense_rate = field_condense_rate;
    wfk.field_lift_cond_gain = field_lift_cond_gain;
    wfk.field_conv_cond_gain = field_conv_cond_gain;
    wfk.field_thermal_conv_cond = field_thermal_conv_cond;
    wfk.field_thermal_conv_precip = field_thermal_conv_precip;
    wfk.field_autoconversion = field_autoconversion;
    wfk.field_precip_base_frac = field_precip_base_frac;
    wfk.field_lift_precip_gain = field_lift_precip_gain;
    wfk.field_conv_precip_gain = field_conv_precip_gain;
    wfk.field_oro_precip_gain = field_oro_precip_gain;
    wfk.field_stratiform_gain = field_stratiform_gain;
    wfk.field_cool_season_vapor_floor = field_cool_season_vapor_floor;
    wfk.field_cloud_reevap = field_cloud_reevap;
    wfk.weather_cell_pos_scale = weather_cell_pos_scale;
    wfk.weather_wrap_width_x = weather_wrap_width_x;
    wfk.cold_precip_as_blizzard = cold_precip_as_blizzard;
    wfk.snow_classification_margin = snow_classification_margin;
    wfk.weather_lat_te_norm = weather_lat_te_norm;
    wfk.omega_ascent_gain = OMEGA_ASCENT_GAIN;
    wfk.world_bounds_pos_y = wb_pos_y;
    wfk.world_bounds_size_y = wb_size_y;
    wfk.syn_supp = syn_supp;
    wfk.syn_enh = syn_enh;
    wfk.syn_front_force = syn_front_force;
    wfk.syn_front_enh = syn_front_enh;
    wfk.syn_base_lift = syn_base_lift;
    wfk.weather_transition_enabled = weather_transition_enabled;
    wfk.weather_transition_alpha_rate = weather_transition_alpha_rate;
    wfk.weather_transition_dt_days = weather_transition_dt_days;
    // \u8fd9\u4e24\u4e2a\u539f\u6765\u5728\u6bcf cell \u7684\u5faa\u73af\u4f53\u91cc\u5404\u67e5\u4e00\u6b21 Dictionary\u3002
    wfk.thermal_monsoon_enabled = bool(knobs.get("thermal_monsoon_enabled",
        _native_runtime_config.get("thermal_monsoon_enabled", false)));
    wfk.cyclone_storm_type_id = uint8_t(
        std::clamp(int(knobs.get("cyclone_storm_type_id", 2)), 0, 255));

    pk_async_climate::WeatherFieldLanes wfl;
    wfl.temp_read = TR;
    wfl.moisture_read = MR;
    wfl.air_anomaly = AA;
    wfl.wind_x = WX;
    wfl.wind_y = WY;
    wfl.wind_speed = WSPD;
    wfl.terrain = TERR;
    wfl.has_river = RIV;
    wfl.river_q30 = RQ30;
    wfl.elevation = ELEV;
    wfl.vegetation = VEG;
    wfl.soil_moisture = SOIL;
    wfl.vitality = VITA;
    wfl.sea_ice = SICE;
    wfl.pos_x = _wf_pos_x.data();
    wfl.pos_y = _wf_pos_y.data();
    wfl.temp_anomaly = TANO;
    wfl.snow_cover = SNOWR;
    wfl.neighbor_indices = NB;
    wfl.prev_vapor = PV;
    wfl.prev_precip = PP;
    wfl.prev_cloud_water = PCW;
    wfl.temp_transport_anomaly = TA;
    wfl.prev_convergence = PREV_CNV;
    wfl.prev_cloud = PREV_CLOUD;
    wfl.out_vapor = OUT_VAP;
    wfl.out_cloud = OUT_CLD;
    wfl.out_cloud_water = OUT_CW;
    wfl.out_precip = OUT_PRE;
    wfl.out_instability = OUT_INS;
    wfl.out_intensity = OUT_INT;
    wfl.out_convergence = OUT_CNV;
    wfl.out_type_u8 = OUT_TYP;
    wfl.out_type_i32 = OUT_TYP_I32;
    wfl.out_prev_type = OUT_PREV_TYP;
    wfl.out_target_type = OUT_TARGET_TYP;
    wfl.out_alpha = OUT_ALPHA;
    wfl.out_field_init = OUT_FIN;

    pk_async_climate::WeatherFieldState wfs;
    wfs.conv_inhib = INHIB;
    wfs.psi = PSI;
    wfs.cyclone_tag = _cyclone_force_tag.empty() ? nullptr : _cyclone_force_tag.data();
    wfs.cyclone_tag_count = int(_cyclone_force_tag.size());
    wfs.cyclone_generation = _cyclone_force_generation;
    wfs.cyclone_lift = _cyclone_force_lift.empty() ? nullptr : _cyclone_force_lift.data();
    wfs.cyclone_x = _cyclone_force_x.empty() ? nullptr : _cyclone_force_x.data();
    wfs.cyclone_y = _cyclone_force_y.empty() ? nullptr : _cyclone_force_y.data();
    wfs.monsoon_thermal = _phys_monsoon_thermal.empty()
        ? nullptr : _phys_monsoon_thermal.data();
    wfs.monsoon_thermal_count = int(_phys_monsoon_thermal.size());
    wfs.traj_idx = TRAJ_IDX;
    wfs.traj_w = TRAJ_W;
    wfs.geom_dx = GEOM_DX;
    wfs.geom_dy = GEOM_DY;
    wfs.geom_invd = GEOM_INVD;

    if (use_next_outputs && (end_idx - start_idx) >= 256) {
        // staged \u8def\u5f84\u5e76\u884c\uff08native daily\uff09\u3002\u533a\u95f4 [start_idx, end_idx) \u2192 0-based n + \u504f\u79fb\u3002
        pk::parallel_for_range("pk_weather_field", end_idx - start_idx,
            [&](int b, int e) {
                pk_async_climate::weather_field_solve_pure(
                    wfk, wfl, wfs, start_idx + b, start_idx + e);
            });
    } else {
        pk_async_climate::weather_field_solve_pure(
            wfk, wfl, wfs, start_idx, end_idx);
    }'''


def main():
    lines = io.open(P, encoding='utf-8').read().split('\n')
    assert lines[755].strip() == 'if (start_idx == 0) {', lines[755]
    assert lines[786].strip() == '}', lines[786]
    assert lines[788].strip().startswith('(_wf_nb_geom_n == n_cells'), lines[788]
    assert lines[807].strip() == '}', lines[807]
    assert lines[1537].strip().startswith('}; // run_weather_cell_range'), lines[1537]
    assert lines[1545].strip() == '}', lines[1545]
    out = (lines[:755] + GEOM.split('\n') + lines[787:808]
           + CALL.split('\n') + lines[1546:])
    io.open(P, 'w', encoding='utf-8', newline='').write('\n'.join(out))
    print('rewired; %s now %d lines' % (P, len(out)))


main()
