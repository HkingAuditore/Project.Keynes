
            // ── B8 P2：物理环流 prepass 的标量 ────────────────────────────────
            // 由 MapBaker::runtime_physics_knobs() 投影出的 profile 常量；worker 用
            // 自己的 lane，因此这里只要标量。缺 slp/wind 任一子字典就不置 ready，
            // 并把第一个缺席的键名留给诊断（worker 不跑物理，不静默算错）。
            // 注意：这张 dict 在这个作用域里重新取一次（上面那份 stage_knobs 在更内层
            // 的作用域里）。capture 每帧一次，成本可忽略。
            const Dictionary stage_knobs_phys =
                inputs.has("climate_stage_knobs") &&
                inputs["climate_stage_knobs"].get_type() == Variant::DICTIONARY
                    ? Dictionary(inputs["climate_stage_knobs"]) : Dictionary();
            if (stage_knobs_phys.has("physics_knobs") &&
                stage_knobs_phys["physics_knobs"].get_type() == Variant::DICTIONARY) {
                const Dictionary phys = stage_knobs_phys["physics_knobs"];
                const bool has_slp = phys.has("slp") &&
                    phys["slp"].get_type() == Variant::DICTIONARY;
                const bool has_wind = phys.has("wind") &&
                    phys["wind"].get_type() == Variant::DICTIONARY;
                if (has_slp && has_wind && phys.has("psi") && phys.has("upwelling") &&
                    phys["psi"].get_type() == Variant::DICTIONARY &&
                    phys["upwelling"].get_type() == Variant::DICTIONARY) {
                    const Dictionary slp = phys["slp"];
                    const Dictionary wind = phys["wind"];
                    const Dictionary psi = phys["psi"];
                    const Dictionary up = phys["upwelling"];
                    std::string phys_error;
                    auto bad = [&](const char *key) { if (phys_error.empty()) phys_error = key; };
                    auto pf = [&](const Dictionary &dict, const char *key, double fallback) -> double {
                        if (!dict.has(key)) { bad(key); return fallback; }
                        const Variant v = dict[key];
                        if ((v.get_type() != Variant::FLOAT && v.get_type() != Variant::INT) ||
                            !std::isfinite(double(v))) { bad(key); return fallback; }
                        return double(v);
                    };
                    auto pi = [&](const Dictionary &dict, const char *key, int fallback) -> int {
                        if (!dict.has(key)) { bad(key); return fallback; }
                        const Variant v = dict[key];
                        if (v.get_type() != Variant::INT || int64_t(v) < INT32_MIN || int64_t(v) > INT32_MAX) {
                            bad(key); return fallback;
                        }
                        return int(v);
                    };
                    auto pb = [&](const Dictionary &dict, const char *key, bool fallback) -> bool {
                        if (!dict.has(key) || dict[key].get_type() != Variant::BOOL) { bad(key); return fallback; }
                        return bool(dict[key]);
                    };
                    auto &pk_k = snapshot.climate_physics_knobs;
                    pk_k.slp_lat_amp = pf(slp, "slp_lat_amp", pk_k.slp_lat_amp);
                    pk_k.slp_land_amp = pf(slp, "slp_land_amp", pk_k.slp_land_amp);
                    pk_k.slp_water_damp = pf(slp, "slp_water_damp", pk_k.slp_water_damp);
                    pk_k.slp_interior_boost =
                        pf(slp, "slp_interior_boost", pk_k.slp_interior_boost);
                    pk_k.slp_coast_damp = pf(slp, "slp_coast_damp", pk_k.slp_coast_damp);
                    pk_k.slp_thermal_weight =
                        pf(slp, "wind_thermal_slp_weight", pk_k.slp_thermal_weight);
                    pk_k.slp_ice_high_weight =
                        pf(slp, "slp_ice_high_weight", pk_k.slp_ice_high_weight);
                    pk_k.slp_snow_high_weight =
                        pf(slp, "slp_snow_high_weight", pk_k.slp_snow_high_weight);
                    pk_k.slp_moist_low_weight =
                        pf(slp, "slp_moist_low_weight", pk_k.slp_moist_low_weight);
                    pk_k.slp_response_rate =
                        pf(slp, "slp_response_rate", pk_k.slp_response_rate);
                    pk_k.slp_synoptic_amp =
                        pf(slp, "slp_synoptic_amp", pk_k.slp_synoptic_amp);
                    pk_k.slp_target_p95 =
                        pf(slp, "slp_target_p95", pk_k.slp_target_p95);
                    pk_k.slp_mobile_low_count =
                        pi(slp, "slp_mobile_low_count", pk_k.slp_mobile_low_count);
                    pk_k.slp_mobile_low_amp =
                        pf(slp, "slp_mobile_low_amp", pk_k.slp_mobile_low_amp);
                    pk_k.slp_mobile_low_sigma =
                        pf(slp, "slp_mobile_low_sigma", pk_k.slp_mobile_low_sigma);
                    pk_k.slp_mobile_low_period_days = pf(
                        slp, "slp_mobile_low_period_days",
                        pk_k.slp_mobile_low_period_days);
                    pk_k.slp_smooth_passes =
                        pi(slp, "smooth_passes", pk_k.slp_smooth_passes);
                    pk_k.slp_recenter =
                        pb(slp, "slp_recenter", pk_k.slp_recenter != 0) ? 1 : 0;
                    pk_k.wind_response_rate =
                        pf(wind, "wind_response_rate", pk_k.wind_response_rate);
                    pk_k.wind_max_turn_deg_per_day = pf(
                        wind, "wind_max_turn_deg_per_day",
                        pk_k.wind_max_turn_deg_per_day);
                    pk_k.wind_min_flux_for_dir_update = pf(
                        wind, "wind_min_flux_for_dir_update",
                        pk_k.wind_min_flux_for_dir_update);
                    pk_k.wind_synoptic_amp =
                        pf(wind, "wind_synoptic_amp", pk_k.wind_synoptic_amp);
                    pk_k.wind_synoptic_period_days = pf(
                        wind, "wind_synoptic_period_days",
                        pk_k.wind_synoptic_period_days);
                    pk_k.wind_terrain_aware =
                        pi(wind, "terrain_aware", pk_k.wind_terrain_aware);
                    pk_k.wind_belt_only_debug = pb(
                        wind, "wind_belt_only_debug",
                        pk_k.wind_belt_only_debug != 0) ? 1 : 0;
                    pk_k.wind_momentum_advect_w = pf(
                        wind, "wind_momentum_advect_w", pk_k.wind_momentum_advect_w);
                    pk_k.wind_momentum_diffuse_w_daily = pf(
                        wind, "wind_momentum_diffuse_w_daily",
                        pk_k.wind_momentum_diffuse_w_daily);
                    pk_k.wind_traj_table_enabled = pb(
                        wind, "wind_traj_table_enabled",
                        pk_k.wind_traj_table_enabled != 0) ? 1 : 0;
                    pk_k.wind_traj_pos_scale = pf(
                        wind, "wind_traj_pos_scale", pk_k.wind_traj_pos_scale);
                    pk_k.wind_traj_dt_days = pf(
                        wind, "wind_traj_dt_days", pk_k.wind_traj_dt_days);
                    pk_k.wind_traj_weather_share = pb(
                        wind, "wind_traj_weather_share",
                        pk_k.wind_traj_weather_share != 0) ? 1 : 0;
                    pk_k.wind_div_damp_alpha = pf(
                        wind, "wind_div_damp_alpha", pk_k.wind_div_damp_alpha);
                    pk_k.thermal_monsoon_enabled = pb(
                        wind, "thermal_monsoon_enabled",
                        pk_k.thermal_monsoon_enabled != 0) ? 1 : 0;
                    pk_k.thermal_monsoon_lat_limit = pf(
                        wind, "thermal_monsoon_lat_limit",
                        pk_k.thermal_monsoon_lat_limit);
                    pk_k.thermal_monsoon_deadband = pf(
                        wind, "thermal_monsoon_deadband",
                        pk_k.thermal_monsoon_deadband);
                    pk_k.thermal_monsoon_full_contrast = pf(
                        wind, "thermal_monsoon_full_contrast",
                        pk_k.thermal_monsoon_full_contrast);
                    pk_k.thermal_monsoon_gain = pf(
                        wind, "thermal_monsoon_gain", pk_k.thermal_monsoon_gain);
                    pk_k.thermal_monsoon_breeze_floor = pf(
                        wind, "thermal_monsoon_breeze_floor",
                        pk_k.thermal_monsoon_breeze_floor);
                    pk_k.days_per_year =
                        pi(slp, "days_per_year", pk_k.days_per_year);
                    pk_k.axial_tilt_deg =
                        pf(slp, "axial_tilt_deg", pk_k.axial_tilt_deg);
                    pk_k.insolation_daylen_amp = pf(
                        slp, "insolation_daylen_amp", pk_k.insolation_daylen_amp);
                    pk_k.lat_lut_bins =
                        pi(slp, "slp_lat_lut_bins", pk_k.lat_lut_bins);
                    pk_k.land_lf_mountain =
                        pi(wind, "land_lf_mountain", pk_k.land_lf_mountain);
                    pk_k.land_lf_peak =
                        pi(wind, "land_lf_peak", pk_k.land_lf_peak);
                    pk_k.land_lf_hill =
                        pi(wind, "land_lf_hill", pk_k.land_lf_hill);
                    pk_k.enabled = pb(phys, "enabled", false);
                    pk_k.daily_split = pb(phys, "daily_split", false);
                    pk_k.daily_period_days = pi(phys, "daily_period_days", 1);
                    pk_k.ocean_period_days = pi(phys, "ocean_period_days", 30);
                    pk_k.world_seed = pi(phys, "world_seed", 0);
                    pk_k.wrap_origin_x = pf(slp, "wrap_origin_x", 0.0);
                    pk_k.wrap_period_x = pf(slp, "wrap_period_x", 0.0);
                    if (!phys.has("water_terrain_ids") || phys["water_terrain_ids"].get_type() != Variant::PACKED_BYTE_ARRAY) {
                        bad("water_terrain_ids");
                    } else {
                        const PackedByteArray ids = phys["water_terrain_ids"];
                        if (ids.size() != 4) bad("water_terrain_ids");
                        else {
                            pk_k.water_id_count = 4;
                            std::copy_n(ids.ptr(), 4, pk_k.water_terrain_ids.begin());
                        }
                    }
                    auto &p = pk_k.psi;
                    p.total_iters = pi(psi, "psi_total_iters", p.total_iters);
                    p.omega = pf(psi, "psi_sor_omega", p.omega);
                    p.r_base = pf(psi, "psi_r_base", p.r_base);
                    p.beta_floor = pf(psi, "psi_beta_floor", p.beta_floor);
                    p.source_scale = pf(psi, "psi_source_scale", p.source_scale);
                    p.oc_scale = pf(psi, "ocean_current_scale", p.oc_scale);
                    p.oc_max_mag = pf(psi, "ocean_current_max_magnitude", p.oc_max_mag);
                    p.thermohaline_weight = pf(psi, "thermohaline_weight", p.thermohaline_weight);
                    p.upwelling_highlat_abs = pf(psi, "upwelling_highlat_abs", p.upwelling_highlat_abs);
                    p.cold_sink_temp = pf(psi, "cold_sink_temp", p.cold_sink_temp);
                    p.response_rate = pf(psi, "ocean_current_response_rate", p.response_rate);
                    p.thermal_current_weight = pf(psi, "ocean_thermal_current_weight", p.thermal_current_weight);
                    p.density_cold_weight = pf(psi, "ocean_density_cold_weight", p.density_cold_weight);
                    p.density_ice_weight = pf(psi, "ocean_density_ice_weight", p.density_ice_weight);
                    p.depth_curl_damp = pf(psi, "ocean_depth_curl_damp", p.depth_curl_damp);
                    p.sea_level = pf(psi, "sea_level", p.sea_level);
                    p.depth_ref = pf(psi, "ocean_depth_ref", p.depth_ref);
                    p.topo_steer_w = pf(psi, "ocean_topo_steer_w", p.topo_steer_w);
                    pk_k.psi_warm_start = pb(psi, "psi_warm_start", true);
                    String mode;
                    if (!psi.has("psi_early_exit_mode") || psi["psi_early_exit_mode"].get_type() != Variant::STRING)
                        bad("psi_early_exit_mode");
                    else mode = psi["psi_early_exit_mode"];
                    p.early_exit = mode == "balanced" || mode == "perf";
                    if (!p.early_exit && mode != "off") bad("psi_early_exit_mode");
                    p.min_iters = mode == "balanced" ? 8 : (mode == "perf" ? 6 : p.total_iters);
                    p.residual_epsilon = mode == "balanced" ? 0.00035f : (mode == "perf" ? 0.00075f : 0.0f);
                    if (p.early_exit && !pk_k.psi_warm_start) p.min_iters += 4;
                    p.min_iters = std::max(1, std::min(p.total_iters, p.min_iters));
                    p.check_every = 2;
                    pk_k.upwelling.ekman_gain = pf(up, "upwelling_ekman_gain", 0.6);
                    pk_k.upwelling.cold_sink_gain = pf(up, "upwelling_cold_sink_gain", 0.15);
                    pk_k.upwelling.highlat_abs = pf(up, "upwelling_highlat_abs", 0.75);
                    pk_k.upwelling.cold_sink_temp = pf(up, "cold_sink_temp", -0.05);
                    std::string bounds_error;
                    if (!pk_k.validate(bounds_error) && phys_error.empty()) phys_error = bounds_error;
                    pk_k.ready = phys_error.empty() ? 1 : 0;
                    std::snprintf(pk_k.missing_key, sizeof(pk_k.missing_key), "%s", phys_error.c_str());
                } else {
                    std::snprintf(
                        snapshot.climate_physics_knobs.missing_key,
                        sizeof(snapshot.climate_physics_knobs.missing_key),
                        "%s", has_slp ? "physics_knobs.wind" : "physics_knobs.slp");
                }
            } else {
                std::snprintf(
                    snapshot.climate_physics_knobs.missing_key,
                    sizeof(snapshot.climate_physics_knobs.missing_key),
                    "physics_knobs");
            }
