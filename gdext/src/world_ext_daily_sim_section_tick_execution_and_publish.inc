    if (use_system_schedule) {
        const char* fail_stage = nullptr;
        const int rc = pk::dispatch_system_schedule(
            this, bundle, tick_knobs, breakdown, any_pass_ran, fail_stage);
        if (rc != 0) {
            // 与原 11 段 if-chain 的 finish_with_failure 第二参对齐：除 weather
            // 段外都是 "pass returned fallback"；weather 段从 breakdown 暂存
            // 字段读出真实 fail_stage 名作为 reason。
            String reason;
            if (fail_stage != nullptr && String(fail_stage) == String("weather")) {
                reason = String(breakdown.get("__weather_fail_stage_dyn", "unknown"));
                breakdown.erase("__weather_fail_stage_dyn");
            } else if (fail_stage != nullptr && String(fail_stage) == String("runtime_hydrology")) {
                reason = String(breakdown.get("__hydrology_fail_reason", "pass returned fallback"));
                breakdown.erase("__hydrology_fail_reason");
            } else {
                reason = String("pass returned fallback");
            }
            return finish_with_failure(fail_stage != nullptr ? fail_stage : "system_schedule",
                                       reason);
        }
    } else {


        Dictionary cp_struct = as_dict(bundle["climate_pass_a_struct"]);
        const double phase = double(tick_knobs.get("season_phase", 0.0));
        const double season_phase = double(tick_knobs.get("season_phase", phase));
        // [climate-mt 2026-07] legacy if-chain（use_system_schedule=false 兜底，现已死路）
        //   亦切多核 _thread，保持与 slice / system_schedule 三路 dispatch bit-equal。
        const double ms = run_climate_pass_a_thread(cp_struct, phase, season_phase, 0);
        if (ms < 0.0) return finish_with_failure("climate_pass_a", "pass returned fallback");
        breakdown["pass_a_ms"] = ms;
        breakdown["climate_ms"] = double(breakdown.get("climate_ms", 0.0)) + ms;
        any_pass_ran = true;

    if (bundle.has("climate_pass_b_knobs")) {
        const double ms = run_climate_pass_b_thread(as_dict(bundle["climate_pass_b_knobs"]), 0);
        if (ms < 0.0) return finish_with_failure("climate_pass_b", "pass returned fallback");
        breakdown["pass_b_ms"] = ms;
        breakdown["climate_ms"] = double(breakdown.get("climate_ms", 0.0)) + ms;
        any_pass_ran = true;
    }

    if (bundle.has("ocean_water_knobs")) {
        Dictionary water_knobs = as_dict(bundle["ocean_water_knobs"]);
        const bool use_thread = bool(water_knobs.get("native_daily_thread_variant_enabled", false));
        const int thread_tasks = int(water_knobs.get("native_daily_thread_tasks", 0));
        double ms = use_thread
            ? run_ocean_water_pass_thread(water_knobs, thread_tasks)
            : run_ocean_water_pass(water_knobs);
        String variant = use_thread ? String("thread") : String("scalar");
        if (ms < 0.0 && use_thread) {
            ms = run_ocean_water_pass(water_knobs);
            variant = String("thread_fallback_scalar");
        }
        if (ms < 0.0) return finish_with_failure("ocean_water", "pass returned fallback");
        bundle["ocean_water_knobs"] = water_knobs;
        if (water_knobs.has("anomaly_out") && bundle.has("ocean_land_knobs")) {
            Dictionary land_knobs = as_dict(bundle["ocean_land_knobs"]);
            land_knobs["anomaly_inout"] = water_knobs["anomaly_out"];
            bundle["ocean_land_knobs"] = land_knobs;
        }
        breakdown["ocean_water_ms"] = ms;
        breakdown["ocean_water_variant"] = variant;
        breakdown["ocean_water_thread_tasks"] = thread_tasks;
        breakdown["ocean_ms"] = double(breakdown.get("ocean_ms", 0.0)) + ms;
        any_pass_ran = true;
    }

    if (bundle.has("ocean_land_knobs")) {
        Dictionary land_knobs = as_dict(bundle["ocean_land_knobs"]);
        const bool use_thread = bool(land_knobs.get("native_daily_thread_variant_enabled", false));
        const int thread_tasks = int(land_knobs.get("native_daily_thread_tasks", 0));
        double ms = use_thread
            ? run_ocean_land_pass_thread(land_knobs, thread_tasks)
            : run_ocean_land_pass(land_knobs);
        String variant = use_thread ? String("thread") : String("scalar");
        if (ms < 0.0 && use_thread) {
            ms = run_ocean_land_pass(land_knobs);
            variant = String("thread_fallback_scalar");
        }
        if (ms < 0.0) return finish_with_failure("ocean_land", "pass returned fallback");
        bundle["ocean_land_knobs"] = land_knobs;
        breakdown["ocean_land_ms"] = ms;
        breakdown["ocean_land_variant"] = variant;
        breakdown["ocean_land_thread_tasks"] = thread_tasks;
        breakdown["ocean_ms"] = double(breakdown.get("ocean_ms", 0.0)) + ms;
        any_pass_ran = true;
    }

    if (bundle.has("wind_air_knobs")) {
        const double ms = run_wind_air_mass_pass(as_dict(bundle["wind_air_knobs"]));
        if (ms < 0.0) return finish_with_failure("wind_air", "pass returned fallback");
        breakdown["wind_air_ms"] = ms;
        breakdown["wind_ms"] = double(breakdown.get("wind_ms", 0.0)) + ms;
        breakdown["climate_ms"] = double(breakdown.get("climate_ms", 0.0)) + ms;
        any_pass_ran = true;
    }

    if (bundle.has("wind_surface_knobs")) {
        const double ms = run_wind_surface_pass(as_dict(bundle["wind_surface_knobs"]));
        if (ms < 0.0) return finish_with_failure("wind_surface", "pass returned fallback");
        breakdown["wind_surface_ms"] = ms;
        breakdown["wind_ms"] = double(breakdown.get("wind_ms", 0.0)) + ms;
        breakdown["climate_ms"] = double(breakdown.get("climate_ms", 0.0)) + ms;
        any_pass_ran = true;
    }

    if (bundle.has("sea_ice_knobs")) {
        const float phase = float(tick_knobs.get("season_phase", 0.0));
        Dictionary sea_ice_knobs = as_dict(bundle["sea_ice_knobs"]);
        const double ms = run_sea_ice_daily_pass(sea_ice_knobs, phase);
        if (ms < 0.0) return finish_with_failure("sea_ice", "pass returned fallback");
        breakdown["sea_ice_ms"] = ms;
        breakdown["sea_ice_dt_days"] = double(sea_ice_knobs.get("dt_days", 1.0));
        breakdown["climate_ms"] = double(breakdown.get("climate_ms", 0.0)) + ms;
        any_pass_ran = true;
    }

    if (bundle.has("transpiration_knobs")) {
        const double ms = run_transpiration_pass(as_dict(bundle["transpiration_knobs"]));
        if (ms < 0.0) return finish_with_failure("transpiration", "pass returned fallback");
        breakdown["transp_ms"] = ms;
        breakdown["climate_ms"] = double(breakdown.get("climate_ms", 0.0)) + ms;
        any_pass_ran = true;
    }

    if (bundle.has("albedo_knobs") && !bundle.has("stage_b_knobs")) {
        const double ms = run_albedo_pass(as_dict(bundle["albedo_knobs"]));
        if (ms < 0.0) return finish_with_failure("albedo", "pass returned fallback");
        breakdown["albedo_ms"] = ms;
        breakdown["stage_b_ms"] = double(breakdown.get("stage_b_ms", 0.0)) + ms;
        any_pass_ran = true;
    }

    if (bundle.has("vegetation_dynamics_knobs") && !bundle.has("stage_b_knobs")) {
        const double ms = run_vegetation_dynamics_pass(as_dict(bundle["vegetation_dynamics_knobs"]));
        if (ms < 0.0) return finish_with_failure("vegetation_dynamics", "pass returned fallback");
        breakdown["veg_dyn_ms"] = ms;
        breakdown["stage_b_ms"] = double(breakdown.get("stage_b_ms", 0.0)) + ms;
        any_pass_ran = true;
    }

    if (bundle.has("climate_feedback_knobs") && !bundle.has("stage_b_knobs")) {
        const double ms = run_climate_feedback_pass(as_dict(bundle["climate_feedback_knobs"]));
        if (ms < 0.0) return finish_with_failure("climate_feedback", "pass returned fallback");
        breakdown["feedback_ms"] = ms;
        breakdown["stage_b_ms"] = double(breakdown.get("stage_b_ms", 0.0)) + ms;
        any_pass_ran = true;
    }

    if (bundle.has("stage_b_knobs")) {
        Dictionary stage_b_knobs = as_dict(bundle["stage_b_knobs"]);
        const double ms = run_stage_b_pass(stage_b_knobs);
        if (ms < 0.0) return finish_with_failure("stage_b", "pass returned fallback");
        breakdown["stage_b_ms"] = double(breakdown.get("stage_b_ms", 0.0)) + ms;
        breakdown["albedo_ms"] = stage_b_knobs.get("albedo_ms", breakdown.get("albedo_ms", 0.0));
        breakdown["veg_dyn_ms"] = stage_b_knobs.get("veg_dyn_ms", breakdown.get("veg_dyn_ms", 0.0));
        breakdown["feedback_ms"] = stage_b_knobs.get("feedback_ms", breakdown.get("feedback_ms", 0.0));
        const int stage_b_call_index = int(stage_b_knobs.get("stage_b_call_index", -1));
        breakdown["stage_b_call_index"] = stage_b_call_index;
        breakdown["albedo_ran"] = bool(stage_b_knobs.get("run_albedo", false));
        breakdown["veg_dyn_ran"] = bool(stage_b_knobs.get("run_veg_dyn", false));
        breakdown["feedback_ran"] = bool(stage_b_knobs.get("run_feedback", false));
        breakdown["stage_b_combined_done"] = true;
        breakdown["stage_b_ext_ok"] = true;
        breakdown["stage_b_total_runs"] = stage_b_call_index >= 0 ? stage_b_call_index + 1 : 0;
        if (stage_b_knobs.has("succession_indices")) {
            breakdown["succession_indices"] = stage_b_knobs["succession_indices"];
            breakdown["succession_to_veg"] = stage_b_knobs["succession_to_veg"];
            breakdown["stat_succession_count"] = stage_b_knobs.get("stat_succession_count", 0);
        }
        any_pass_ran = true;
    }

    if (bundle.has("weather_knobs")) {
        Dictionary weather = run_weather_refresh_daily_pass(as_dict(bundle["weather_knobs"]));
        if (int(weather.get("rc", -1)) != 0) {
            return finish_with_failure("weather", String(weather.get("fail_stage", "unknown")));
        }
        breakdown["weather_ms"] = double(weather.get("total_ms", 0.0));
        copy_dict_into(breakdown, weather);
        if (weather.has("fronts")) {
            _native_fronts_snapshot = weather["fronts"];
        }
        any_pass_ran = true;
    }

    if (bundle.has("runtime_hydrology_knobs")) {
        Dictionary hydro = run_runtime_hydrology_pass(as_dict(bundle["runtime_hydrology_knobs"]));
        const String fallback_reason = String(hydro.get("fallback_reason", ""));
        if (!fallback_reason.is_empty() || !bool(hydro.get("published_to_slot", false))) {
            return finish_with_failure(
                "runtime_hydrology",
                fallback_reason.is_empty() ? String("hydrology did not publish slots") : fallback_reason);
        }
        const double native_ms = double(hydro.get("native_ms", 0.0));
        breakdown["hydrology_ms"] = native_ms;
        breakdown["runtime_hydrology_ms"] = native_ms;
        breakdown["hydrology_native_ms"] = native_ms;
        breakdown["hydrology_compute_ms"] = double(hydro.get("compute_ms", 0.0));
        breakdown["hydrology_flush_ms"] = double(hydro.get("flush_ms", 0.0));
        breakdown["hydrology_visible_publish_deferred"] =
            bool(hydro.get("visible_publish_deferred", false));
        breakdown["hydrology_dt_days"] = double(hydro.get("dt_days", 1.0));
        breakdown["hydrology_water_budget_error"] = double(hydro.get("water_budget_error", 0.0));
        breakdown["hydrology_river_discharge_p95"] = double(hydro.get("river_discharge_p95", 0.0));
        breakdown["hydrology_river_discharge_max"] = double(hydro.get("river_discharge_max", 0.0));
        breakdown["hydrology_riparian_neighbor_touches"] = int(hydro.get("riparian_neighbor_touches", 0));
        breakdown["hydrology_river_moisture_floor_touches"] = int(hydro.get("river_moisture_floor_touches", 0));
        breakdown["hydrology_riparian_moisture_floor_touches"] = int(hydro.get("riparian_moisture_floor_touches", 0));
        breakdown["hydrology_moisture_response_alpha"] = double(hydro.get("moisture_response_alpha", 0.0));
        breakdown["hydrology_river_moisture_max_delta"] = double(hydro.get("river_moisture_max_delta", 0.0));
        breakdown["hydrology_riparian_moisture_max_delta"] = double(hydro.get("riparian_moisture_max_delta", 0.0));
        breakdown["hydrology_flood_count"] = int(hydro.get("flood_count", hydro.get("flood_candidate_count", 0)));
        breakdown["hydrology_published_to_slot"] = true;
        any_pass_ran = true;
    }

    if (bundle.has("stage_b_after_hydrology_knobs")) {
        Dictionary stage_b_knobs = as_dict(bundle["stage_b_after_hydrology_knobs"]);
        const double ms = run_stage_b_pass(stage_b_knobs);
        if (ms < 0.0) return finish_with_failure("stage_b", "pass returned fallback");
        breakdown["stage_b_ms"] = double(breakdown.get("stage_b_ms", 0.0)) + ms;
        breakdown["albedo_ms"] = stage_b_knobs.get("albedo_ms", breakdown.get("albedo_ms", 0.0));
        breakdown["veg_dyn_ms"] = stage_b_knobs.get("veg_dyn_ms", breakdown.get("veg_dyn_ms", 0.0));
        breakdown["feedback_ms"] = stage_b_knobs.get("feedback_ms", breakdown.get("feedback_ms", 0.0));
        const int stage_b_call_index = int(stage_b_knobs.get("stage_b_call_index", -1));
        breakdown["stage_b_call_index"] = stage_b_call_index;
        breakdown["albedo_ran"] = bool(stage_b_knobs.get("run_albedo", false));
        breakdown["veg_dyn_ran"] = bool(stage_b_knobs.get("run_veg_dyn", false));
        breakdown["feedback_ran"] = bool(stage_b_knobs.get("run_feedback", false));
        breakdown["stage_b_combined_done"] = true;
        breakdown["stage_b_ext_ok"] = true;
        breakdown["stage_b_total_runs"] = stage_b_call_index >= 0 ? stage_b_call_index + 1 : 0;
        if (stage_b_knobs.has("succession_indices")) {
            breakdown["succession_indices"] = stage_b_knobs["succession_indices"];
            breakdown["succession_to_veg"] = stage_b_knobs["succession_to_veg"];
            breakdown["stat_succession_count"] = stage_b_knobs.get("stat_succession_count", 0);
        }
        any_pass_ran = true;
    }
    } // ─── Phase C.1：use_system_schedule=false 的 else 分支结束 ──────────

    if (!any_pass_ran) {
        return finish_with_failure("native_daily_bundle", "no pass knobs in native_daily_bundle");
    }

    // A Climate-suppressed tick computed nothing, so the slots still hold
    // yesterday's values. Flushing them would overwrite the snapshot the ACTIVE
    // worker fed back into MapData with a one-day-old copy.
    const bool climate_suppressed =
        bool(breakdown.get("climate_authority_suppressed", false));
    if (!climate_suppressed && bool(bundle.get("flush_slots_to_map", true))) {
        const auto t_flush0 = std::chrono::high_resolution_clock::now();
        flush_slots_to_map();
        const auto t_flush1 = std::chrono::high_resolution_clock::now();
        breakdown["render_prepare_ms"] = std::chrono::duration<double, std::milli>(
            t_flush1 - t_flush0).count();
    }

    const auto t1 = std::chrono::high_resolution_clock::now();
    const double total_ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
    const double refresh_ms = double(breakdown.get("native_context_ms", 0.0));
    const double flush_ms = double(breakdown.get("render_prepare_ms", 0.0));
    const double compute_ms = double(breakdown.get("climate_ms", 0.0)) +
                              double(breakdown.get("ocean_ms", 0.0)) +
                              double(breakdown.get("weather_ms", 0.0)) +
                              double(breakdown.get("hydrology_ms", 0.0)) +
                              double(breakdown.get("stage_b_ms", 0.0));
    const Array published_slots = collect_published_slots(bundle);
    const Array visual_dirty_intents = collect_visual_dirty_intents(bundle, breakdown);
    Dictionary authority_report = native_state_snapshot.get("authority_report", Dictionary());
    if (bool(breakdown.get("hydrology_published_to_slot", false)) &&
        authority_report.has("runtime_hydrology")) {
        Dictionary hydrology_authority = authority_report["runtime_hydrology"];
        hydrology_authority["phase"] = String("native_active_verified");
        hydrology_authority["verified_publish"] = true;
        hydrology_authority["simulation_authority"] = true;
        hydrology_authority["blockers"] = Array();
        authority_report["runtime_hydrology"] = hydrology_authority;
    }
    if (bundle.has("sea_ice_knobs") && authority_report.has("sea_ice")) {
        Dictionary sea_ice_authority = authority_report["sea_ice"];
        sea_ice_authority["phase"] = String("native_active_verified");
        sea_ice_authority["verified_publish"] = true;
        sea_ice_authority["simulation_authority"] = true;
        sea_ice_authority["blockers"] = Array();
        authority_report["sea_ice"] = sea_ice_authority;
    }
    if (bundle.has("weather_knobs") && authority_report.has("weather_transaction")) {
        Dictionary weather_authority = authority_report["weather_transaction"];
        const bool weather_publish_verified = bool(breakdown.get("field_commit_publish_verified", false));
        const bool weather_fronts_changed =
            bool(breakdown.get("weather_lut_changed", false)) ||
            int(breakdown.get("fronts_count", 0)) > 0;
        weather_authority["visible_publish_verified"] = weather_publish_verified;
        weather_authority["fronts_changed"] = weather_fronts_changed;
        if (weather_publish_verified &&
            String(weather_authority.get("owner", "")) == String("native_active")) {
            weather_authority["phase"] = String("native_active_verified");
            weather_authority["simulation_authority"] = true;
            weather_authority["blockers"] = Array();
        }
        authority_report["weather_transaction"] = weather_authority;
    }
    out["rc"] = 0;
    out["path"] = String("gdext_native_daily");
    out["fail_stage"] = String();
    out["fallback_reason"] = String();
    out["total_ms"] = total_ms;
    out["native_ms"] = total_ms;
    out["compute_ms"] = compute_ms;
    out["refresh_ms"] = refresh_ms;
    out["flush_ms"] = flush_ms;
    out["published_slots"] = published_slots;
    out["dirty_cells"] = int(_native_dirty_report.get("dirty_cell_count", 0));
    out["visual_dirty_intents"] = visual_dirty_intents;
    out["retained_gdscript_authority"] = retained_gdscript_authority;
    out["native_state_snapshot"] = native_state_snapshot;
    out["authority_report"] = authority_report;
    out["authority_blockers"] = native_state_snapshot.get("authority_blockers", Array());
    out["retained_boundaries"] = native_state_snapshot.get("retained_boundaries", Array());
    out["retained_godot_boundaries"] = native_state_snapshot.get("retained_godot_boundaries", Array());
    out["retained_boundary_policy"] = native_state_snapshot.get("retained_boundary_policy", String());
    out["graph_coverage_complete"] = Array(out["authority_blockers"]).is_empty();
    out["graph_coverage_state"] = native_state_snapshot.get("graph_coverage_state", String("partial"));
    out["boundary_contract"] = bundle.get("native_daily_boundary_contract", Dictionary());
    Dictionary boundary_contract = out["boundary_contract"];
    out["bundle_key_count"] = int(boundary_contract.get("bundle_key_count", bundle.size()));
    out["tick_delta_key_count"] = Array(boundary_contract.get("tick_delta_keys", Array())).size();
    out["runtime_config_report"] = _native_runtime_config.duplicate(true);
    out["climate_modes"] = get_climate_modes_report();
    const bool active_default_ready =
        String(out["graph_coverage_state"]) == String("complete") &&
        Array(out["authority_blockers"]).is_empty();
    out["native_daily_active_default_ready"] = active_default_ready;
    out["active_default_blockers"] = out["authority_blockers"];
    out["fallback_mode"] =
        active_default_ready ? String("explicit_failure_only") : String("legacy_sus_retained_until_active_default_validation");
    PackedFloat32Array temperature_transport_anomaly_out;
    if (bundle.has("ocean_land_knobs")) {
        Dictionary land_knobs = as_dict(bundle["ocean_land_knobs"]);
        if (land_knobs.has("anomaly_inout")) {
            temperature_transport_anomaly_out = land_knobs["anomaly_inout"];
        }
    }
    breakdown["total_ms"] = total_ms;
    breakdown["native_ms"] = total_ms;
    breakdown["compute_ms"] = compute_ms;
    breakdown["refresh_ms"] = refresh_ms;
    breakdown["flush_ms"] = flush_ms;
    breakdown["published_slots"] = published_slots;
    breakdown["dirty_cells"] = int(_native_dirty_report.get("dirty_cell_count", 0));
    breakdown["visual_dirty_intents"] = visual_dirty_intents;
    breakdown["native_state_snapshot"] = native_state_snapshot;
    breakdown["authority_report"] = authority_report;
    breakdown["authority_blockers"] = native_state_snapshot.get("authority_blockers", Array());
    breakdown["retained_boundaries"] = native_state_snapshot.get("retained_boundaries", Array());
    breakdown["retained_godot_boundaries"] = native_state_snapshot.get("retained_godot_boundaries", Array());
    breakdown["retained_boundary_policy"] = native_state_snapshot.get("retained_boundary_policy", String());
    breakdown["graph_coverage_complete"] = Array(breakdown["authority_blockers"]).is_empty();
    breakdown["graph_coverage_state"] = native_state_snapshot.get("graph_coverage_state", String("partial"));
    breakdown["boundary_contract"] = bundle.get("native_daily_boundary_contract", Dictionary());
    breakdown["bundle_key_count"] = out["bundle_key_count"];
    breakdown["tick_delta_key_count"] = out["tick_delta_key_count"];
    breakdown["runtime_config_report"] = out["runtime_config_report"];
    breakdown["climate_modes"] = out["climate_modes"];
    breakdown["native_daily_active_default_ready"] = out["native_daily_active_default_ready"];
    breakdown["active_default_blockers"] = out["active_default_blockers"];
    breakdown["fallback_mode"] = out["fallback_mode"];
    if (temperature_transport_anomaly_out.size() > 0) {
        out["temperature_transport_anomaly_out"] = temperature_transport_anomaly_out;
    }
    out["breakdown"] = breakdown;
    out["dirty_flags"] = _native_dirty_report.duplicate();
    out["fronts_changed"] =
        bool(breakdown.get("weather_lut_changed", false)) ||
        int(breakdown.get("fronts_count", 0)) > 0;
    out["fronts"] = _native_fronts_snapshot;
    out["tick_count"] = _native_daily_tick_count;
    return out;
