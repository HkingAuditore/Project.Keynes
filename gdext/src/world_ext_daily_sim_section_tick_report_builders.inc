    auto finish_with_failure = [&](const char *stage, const String &reason) -> Dictionary {
        const auto t_fail = std::chrono::high_resolution_clock::now();
        const double total_ms = std::chrono::duration<double, std::milli>(t_fail - t0).count();
        out["rc"] = -1;
        out["path"] = String("gdext_native_daily");
        out["fail_stage"] = String(stage);
        out["reason"] = reason;
        out["fallback_reason"] = reason;
        out["total_ms"] = total_ms;
        out["native_ms"] = total_ms;
        out["compute_ms"] = double(breakdown.get("climate_ms", 0.0)) +
                            double(breakdown.get("ocean_ms", 0.0)) +
                            double(breakdown.get("weather_ms", 0.0)) +
                            double(breakdown.get("hydrology_ms", 0.0)) +
                            double(breakdown.get("stage_b_ms", 0.0));
        out["refresh_ms"] = double(breakdown.get("native_context_ms", 0.0));
        out["flush_ms"] = double(breakdown.get("render_prepare_ms", 0.0));
        out["published_slots"] = Array();
        out["visual_dirty_intents"] = Array();
        out["dirty_cells"] = int(_native_dirty_report.get("dirty_cell_count", 0));
        out["native_state_snapshot"] = breakdown.get("native_state_snapshot", Dictionary());
        breakdown["fallback_reason"] = reason;
        breakdown["native_ms"] = total_ms;
        breakdown["compute_ms"] = out["compute_ms"];
        breakdown["refresh_ms"] = out["refresh_ms"];
        breakdown["flush_ms"] = out["flush_ms"];
        out["breakdown"] = breakdown;
        out["dirty_flags"] = _native_dirty_report.duplicate();
        out["fronts_changed"] = false;
        out["fronts"] = _native_fronts_snapshot;
        out["tick_count"] = _native_daily_tick_count;
        return out;
    };

    auto as_dict = [](const Variant &v) -> Dictionary {
        if (v.get_type() == Variant::DICTIONARY) {
            return v;
        }
        return Dictionary();
    };

    auto copy_dict_into = [](Dictionary &dst, const Dictionary &src) {
        Array keys = src.keys();
        for (int i = 0; i < keys.size(); ++i) {
            Variant k = keys[i];
            dst[k] = src[k];
        }
    };

    auto append_unique = [](Array &arr, const String &value) {
        for (int i = 0; i < arr.size(); ++i) {
            if (String(arr[i]) == value) {
                return;
            }
        }
        arr.append(value);
    };

    auto collect_bundle_pass_keys = [&](const Dictionary &bundle_dict) -> Array {
        Array keys;
        auto record_key = [&](const char *key) {
            if (bundle_dict.has(key)) {
                keys.append(String(key));
            }
        };
        record_key("climate_pass_a_struct");
        record_key("ocean_water_knobs");
        record_key("ocean_land_knobs");
        record_key("climate_pass_b_knobs");
        record_key("wind_air_knobs");
        record_key("wind_surface_knobs");
        record_key("sea_ice_knobs");
        record_key("transpiration_knobs");
        record_key("albedo_knobs");
        record_key("vegetation_dynamics_knobs");
        record_key("climate_feedback_knobs");
        record_key("stage_b_knobs");
        record_key("weather_knobs");
        record_key("runtime_hydrology_knobs");
        record_key("stage_b_after_hydrology_knobs");
        return keys;
    };

    auto collect_published_slots = [&](const Dictionary &bundle_dict) -> Array {
        Array slots;
        if (bundle_dict.has("climate_pass_a_struct") || bundle_dict.has("climate_pass_b_knobs") ||
            bundle_dict.has("ocean_water_knobs") || bundle_dict.has("ocean_land_knobs") ||
            bundle_dict.has("wind_air_knobs") || bundle_dict.has("wind_surface_knobs") ||
            bundle_dict.has("sea_ice_knobs") || bundle_dict.has("transpiration_knobs")) {
            append_unique(slots, String("cell_temp"));
            append_unique(slots, String("cell_moisture"));
            append_unique(slots, String("cell_snow_cover"));
            append_unique(slots, String("cell_sea_ice_frac"));
            append_unique(slots, String("cell_air_mass_temp_anomaly"));
            append_unique(slots, String("cell_ocean_thermal_anomaly"));
            append_unique(slots, String("cell_local_thermal_anomaly"));
        }
        if (bundle_dict.has("stage_b_knobs") || bundle_dict.has("stage_b_after_hydrology_knobs") ||
            bundle_dict.has("albedo_knobs") ||
            bundle_dict.has("vegetation_dynamics_knobs") || bundle_dict.has("climate_feedback_knobs")) {
            append_unique(slots, String("cell_cover"));
            append_unique(slots, String("cell_vegetation"));
            append_unique(slots, String("cell_vegetation_vitality"));
        }
        if (bundle_dict.has("weather_knobs")) {
            append_unique(slots, String("cell_weather_type"));
            append_unique(slots, String("cell_weather_intensity"));
            append_unique(slots, String("cell_weather_cloud"));
            append_unique(slots, String("cell_weather_precip"));
            append_unique(slots, String("cell_weather_field_init"));
            append_unique(slots, String("cell_weather_transition_alpha"));
        }
        if (bundle_dict.has("runtime_hydrology_knobs")) {
            append_unique(slots, String("cell_moisture"));
            append_unique(slots, String("cell_soil_moisture"));
            append_unique(slots, String("cell_water_balance_30d"));
            append_unique(slots, String("cell_river_discharge"));
            append_unique(slots, String("cell_river_discharge_30d"));
            append_unique(slots, String("cell_river_storage"));
            append_unique(slots, String("cell_groundwater_storage"));
            append_unique(slots, String("cell_surface_runoff"));
        }
        return slots;
    };

    auto collect_retained_gdscript_authority = [&](const Dictionary &bundle_dict) -> Array {
        Array retained;
        if (!bundle_dict.has("wind_air_knobs")) {
            retained.append(String("wind_air"));
        }
        if (!bundle_dict.has("wind_surface_knobs")) {
            retained.append(String("wind_surface"));
        }
        if (bool(bundle_dict.get("runtime_hydrology_requested", false)) &&
            !bundle_dict.has("runtime_hydrology_knobs")) {
            retained.append(String("runtime_hydrology"));
        }
        if (!bundle_dict.has("sea_ice_knobs")) {
            retained.append(String("sea_ice"));
        }
        return retained;
    };

    auto collect_visual_dirty_intents = [&](const Dictionary &bundle_dict,
                                            const Dictionary &breakdown_dict) -> Array {
        Array intents;
        if (bool(_native_dirty_report.get("atlas_dirty", false))) {
            append_unique(intents, String("atlas"));
        }
        if (bool(_native_dirty_report.get("enum_atlas_dirty", false))) {
            append_unique(intents, String("enum_atlas"));
        }
        if (bool(_native_dirty_report.get("sea_ice_atlas_dirty", false))) {
            append_unique(intents, String("sea_ice_atlas"));
        }
        if (bundle_dict.has("weather_knobs") &&
            (bool(breakdown_dict.get("weather_lut_changed", false)) ||
             breakdown_dict.has("weather_lut"))) {
            append_unique(intents, String("weather_lut"));
        }
        if (breakdown_dict.has("succession_indices") ||
            int(breakdown_dict.get("stat_succession_count", 0)) > 0) {
            append_unique(intents, String("detail_scatter"));
        }
        return intents;
    };

    auto collect_native_state_snapshot = [&](const Dictionary &bundle_dict) -> Dictionary {
        Dictionary state;
        state["tick_owner"] = String("DCWorldExt.native_daily_graph");
        String climate_round_state_owner = String("gdscript_retained");
        Dictionary climate_native_probe_state;
        if (bundle_dict.has("climate_round_state_snapshot")) {
            Dictionary climate_round_state = as_dict(bundle_dict["climate_round_state_snapshot"]);
            state["climate_round_state"] = climate_round_state;
            if (climate_round_state.has("native_probe_state")) {
                Dictionary native_probe_state = as_dict(climate_round_state["native_probe_state"]);
                climate_native_probe_state = native_probe_state;
                const bool climate_round_ready = bool(native_probe_state.get("climate_round_authority_ready", false));
                if (climate_round_ready &&
                    (bool(native_probe_state.get("simulation_authority", false)) ||
                     bool(bundle_dict.get("climate_round_active_owner_requested", false)))) {
                    climate_round_state_owner = String("native_active");
                } else if (climate_round_ready) {
                    climate_round_state_owner = String("native_ready");
                }
            }
        }
        state["climate_round_state_owner"] = climate_round_state_owner;
        Dictionary weather_readiness = as_dict(bundle_dict.get("weather_native_daily_readiness", Dictionary()));
        const bool weather_native_ready = bool(weather_readiness.get("ready", false));
        const bool weather_active_requested = bool(bundle_dict.get("weather_transaction_active_owner_requested", false));
        state["weather_transaction_state_owner"] =
            (weather_native_ready && weather_active_requested)
                ? String("native_active")
                : (weather_native_ready
                ? String("native_ready")
                : (bundle_dict.has("weather_knobs")
                       ? String("native_transaction_with_gdscript_apply")
                       : String("gdscript_retained")));
        Dictionary ocean_physical_state = as_dict(bundle_dict.get("ocean_physical_state_snapshot", Dictionary()));
        if (!ocean_physical_state.is_empty()) {
            state["ocean_physical_state"] = ocean_physical_state;
        }
        state["ocean_physical_state_owner"] =
            ocean_physical_state.has("owner")
                ? String(ocean_physical_state.get("owner", "gdscript_retained"))
                : String("gdscript_retained");
        Dictionary season_refresh_state = as_dict(bundle_dict.get("season_refresh_state_snapshot", Dictionary()));
        if (!season_refresh_state.is_empty()) {
            state["season_refresh_state"] = season_refresh_state;
        }
        Dictionary season_cadence_policy = as_dict(bundle_dict.get("season_cadence_policy", Dictionary()));
        if (!season_cadence_policy.is_empty()) {
            state["season_cadence_policy"] = season_cadence_policy;
        }
        state["season_refresh_state_owner"] =
            season_refresh_state.has("owner")
                ? String(season_refresh_state.get("owner", "gdscript_retained"))
                : String("gdscript_retained");
        state["visual_upload_state_owner"] = String("godot_retained");
        state["fallback_owner"] =
            bool(bundle_dict.get("legacy_sus_fallback_enabled", true))
                ? String("gdscript_legacy_sus")
                : String("explicit_failure_only");
        Array authority_blockers = collect_retained_gdscript_authority(bundle_dict);
        if (climate_round_state_owner != String("native_active")) {
            append_unique(authority_blockers, String("climate_round"));
        }
        if (bundle_dict.has("weather_knobs") &&
            String(state["weather_transaction_state_owner"]) != String("native_active")) {
            append_unique(authority_blockers, String("weather_transaction"));
        }
        if (String(state["ocean_physical_state_owner"]) != String("native_active")) {
            append_unique(authority_blockers, String("ocean_currents_physical_state"));
        }
        if (String(state["season_refresh_state_owner"]) != String("native_active")) {
            append_unique(authority_blockers, String("season_refresh"));
        }
        if (bool(bundle_dict.get("legacy_sus_fallback_enabled", true))) {
            append_unique(authority_blockers, String("legacy_sus_fallback_enabled"));
        }
        Array retained_boundaries = native_daily_collect_retained_boundaries(bundle_dict);
        Dictionary authority_report;
        Dictionary climate_authority;
        climate_authority["owner"] = climate_round_state_owner;
        climate_authority["phase"] =
            climate_round_state_owner == String("native_active")
                ? String("active_owner_gate")
                : (climate_round_state_owner == String("native_ready")
                       ? String("native_ready_probe")
                       : String("gdscript_state_machine"));
        climate_authority["simulation_authority"] = climate_round_state_owner == String("native_active");
        climate_authority["remaining_gdscript_authority"] =
            climate_native_probe_state.get("remaining_gdscript_authority", Array());
        authority_report["climate_round"] = climate_authority;
        Dictionary weather_authority;
        weather_authority["owner"] = state["weather_transaction_state_owner"];
        weather_authority["phase"] =
            (weather_native_ready && weather_active_requested)
                ? String("native_active_visible_publish")
                : (weather_native_ready
                ? String("native_ready_visible_publish")
                : (bundle_dict.has("weather_knobs")
                       ? String("native_transaction_with_gdscript_apply")
                       : String("gdscript_retained")));
        weather_authority["readiness"] = weather_readiness;
        weather_authority["visible_publish_ready"] = weather_native_ready;
        weather_authority["active_owner_requested"] = weather_active_requested;
        weather_authority["simulation_authority"] = weather_native_ready && weather_active_requested;
        weather_authority["front_snapshot_ready"] = bool(weather_readiness.get("has_result_apply", false));
        weather_authority["weather_lut_intent_ready"] = bool(weather_readiness.get("has_weather_lut_publish", false));
        weather_authority["publish_slots_expected"] =
            weather_native_ready || bundle_dict.has("weather_knobs")
                ? Array::make(String("cell_weather_type"),
                              String("cell_weather_intensity"),
                              String("cell_weather_cloud"),
                              String("cell_weather_precip"),
                              String("cell_weather_field_init"),
                              String("cell_weather_transition_alpha"))
                : Array();
        weather_authority["retained_boundaries"] =
            Array::make(String("front_objects_gdscript"),
                        String("weather_lut_upload_godot_boundary"));
        weather_authority["blockers"] =
            weather_native_ready
                ? Array()
                : Array::make(String("weather_transaction_state_gdscript"),
                              String(weather_readiness.get("reason", "not_ready")));
        authority_report["weather_transaction"] = weather_authority;
        Dictionary hydrology_authority;
        hydrology_authority["owner"] =
            bundle_dict.has("runtime_hydrology_knobs") ? String("native_active") : String("gdscript_retained");
        hydrology_authority["phase"] =
            bundle_dict.has("runtime_hydrology_knobs") ? String("native_graph_node") : String("legacy_weather_chain");
        hydrology_authority["simulation_authority"] = bundle_dict.has("runtime_hydrology_knobs");
        hydrology_authority["published_slots_expected"] =
            bundle_dict.has("runtime_hydrology_knobs")
                ? Array::make(String("cell_moisture"),
                              String("cell_soil_moisture"),
                              String("cell_water_balance_30d"),
                              String("cell_river_discharge"),
                              String("cell_river_discharge_30d"),
                              String("cell_river_storage"),
                              String("cell_groundwater_storage"),
                              String("cell_surface_runoff"))
                : Array();
        hydrology_authority["blockers"] =
            bundle_dict.has("runtime_hydrology_knobs")
                ? Array()
                : Array::make(String("runtime_hydrology_knobs_missing"));
        authority_report["runtime_hydrology"] = hydrology_authority;
        Dictionary sea_ice_authority;
        sea_ice_authority["owner"] =
            bundle_dict.has("sea_ice_knobs") ? String("native_active") : String("gdscript_retained");
        sea_ice_authority["phase"] =
            bundle_dict.has("sea_ice_knobs") ? String("native_graph_node") : String("legacy_climate_or_sea_ice_job");
        sea_ice_authority["simulation_authority"] = bundle_dict.has("sea_ice_knobs");
        sea_ice_authority["published_slots_expected"] =
            bundle_dict.has("sea_ice_knobs")
                ? Array::make(String("cell_sea_ice_frac"),
                              String("cell_temp"),
                              String("cell_moisture"))
                : Array();
        sea_ice_authority["blockers"] =
            bundle_dict.has("sea_ice_knobs")
                ? Array()
                : Array::make(String("sea_ice_knobs_missing"));
        sea_ice_authority["retained_boundaries"] =
            bundle_dict.has("sea_ice_knobs")
                ? Array::make(String("terrain_flip_visibility_gdscript"),
                              String("sea_ice_visual_upload_godot"))
                : Array();
        authority_report["sea_ice"] = sea_ice_authority;
        Dictionary ocean_authority;
        ocean_authority["owner"] = state["ocean_physical_state_owner"];
        ocean_authority["phase"] =
            String(state["ocean_physical_state_owner"]) == String("native_active")
                ? String("native_active_lifecycle")
                : (String(state["ocean_physical_state_owner"]) == String("native_ready") ||
                   String(state["ocean_physical_state_owner"]) == String("native_ready_probe")
                       ? String("native_ready_probe")
                       : String("gdscript_stage_machine"));
        ocean_authority["state"] = ocean_physical_state;
        ocean_authority["simulation_authority"] =
            String(state["ocean_physical_state_owner"]) == String("native_active");
        ocean_authority["native_owned_output_slots"] =
            ocean_physical_state.get("native_owned_output_slots", Array());
        ocean_authority["blockers"] =
            String(state["ocean_physical_state_owner"]) == String("native_active")
                ? Array()
                : Array::make(String("ocean_physical_owner_not_active"));
        ocean_authority["retained_boundaries"] =
            ocean_physical_state.get("remaining_gdscript_authority",
                Array::make(String("visual_raster_boundary_godot"),
                            String("texture_commit_boundary_godot")));
        authority_report["ocean_physical"] = ocean_authority;
        Dictionary season_authority;
        season_authority["owner"] = state["season_refresh_state_owner"];
        season_authority["phase"] =
            String(state["season_refresh_state_owner"]) == String("native_active")
                ? String("native_active_cadence")
                : (String(state["season_refresh_state_owner"]) == String("native_ready") ||
                   String(state["season_refresh_state_owner"]) == String("native_ready_probe")
                       ? String("native_ready_cadence_probe")
                       : String("gdscript_cadence"));
        season_authority["state"] = season_refresh_state;
        season_authority["simulation_authority"] =
            String(state["season_refresh_state_owner"]) == String("native_active");
        season_authority["simulation_slot_dirty_intents"] =
            season_refresh_state.get("simulation_slot_dirty_intents", Array());
        season_authority["visual_dirty_intents"] =
            season_refresh_state.get("visual_dirty_intents", Array());
        season_authority["cadence_policy"] = season_cadence_policy;
        season_authority["cadence_policy_owner"] =
            season_cadence_policy.has("owner")
                ? season_cadence_policy.get("owner", String("gdscript_retained"))
                : Variant(String("gdscript_retained"));
        season_authority["cadence_policy_state"] =
            season_cadence_policy.has("policy_state")
                ? season_cadence_policy.get("policy_state", String("gdscript_retained"))
                : Variant(String("gdscript_retained"));
        season_authority["blockers"] =
            String(state["season_refresh_state_owner"]) == String("native_active")
                ? Array()
                : Array::make(String("season_refresh_owner_not_active"));
        season_authority["retained_boundaries"] =
            season_refresh_state.get("visual_dirty_intents",
                Array::make(String("atlas_queue_godot"),
                            String("detail_scatter_godot")));
        authority_report["season_refresh"] = season_authority;
        Dictionary visual_authority;
        visual_authority["owner"] = state["visual_upload_state_owner"];
        visual_authority["phase"] = String("godot_upload_boundary");
        visual_authority["blockers"] = Array::make(String("image_texture_upload_godot"));
        authority_report["visual_upload"] = visual_authority;
        Dictionary fallback_authority;
        const bool legacy_fallback_enabled = bool(bundle_dict.get("legacy_sus_fallback_enabled", true));
        fallback_authority["owner"] =
            legacy_fallback_enabled ? String(state["fallback_owner"]) : String("explicit_failure_only");
        fallback_authority["phase"] =
            legacy_fallback_enabled ? String("fallback_retained") : String("fallback_test_only");
        fallback_authority["blockers"] =
            legacy_fallback_enabled ? Array::make(String("legacy_sus_fallback_enabled")) : Array();
        authority_report["fallback"] = fallback_authority;
        state["authority_report"] = authority_report;
        state["authority_blockers"] = authority_blockers;
        state["retained_boundaries"] = retained_boundaries;
        state["retained_godot_boundaries"] = retained_boundaries;
        state["retained_boundary_policy"] = String("explicit_godot_presentation_boundary");
        state["graph_coverage_state"] =
            authority_blockers.is_empty() ? String("complete") : String("partial");
        return state;
    };
