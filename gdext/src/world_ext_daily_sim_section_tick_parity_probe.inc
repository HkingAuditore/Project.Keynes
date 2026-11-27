    if (bool(tick_knobs.get("probe", false))) {
        bool has_bundle = false;
        bool has_pass = false;
        Array pass_keys;
        Array required_keys;
        Array missing_pass_keys;
        Dictionary bundle;
        Variant required_v = tick_knobs.get("required_pass_keys", Array());
        if (required_v.get_type() == Variant::ARRAY) {
            required_keys = required_v;
        }
        if (tick_knobs.has("native_daily_bundle") &&
            Variant(tick_knobs["native_daily_bundle"]).get_type() == Variant::DICTIONARY) {
            bundle = tick_knobs["native_daily_bundle"];
            has_bundle = !bundle.is_empty();
            auto record_pass = [&](const char *key) {
                if (bundle.has(key)) {
                    has_pass = true;
                    pass_keys.append(String(key));
                }
            };
            record_pass("climate_pass_a_struct");
            record_pass("ocean_water_knobs");
            record_pass("ocean_land_knobs");
            record_pass("climate_pass_b_knobs");
            record_pass("wind_air_knobs");
            record_pass("wind_surface_knobs");
            record_pass("sea_ice_knobs");
            record_pass("transpiration_knobs");
            record_pass("albedo_knobs");
            record_pass("vegetation_dynamics_knobs");
            record_pass("climate_feedback_knobs");
            record_pass("stage_b_knobs");
            record_pass("weather_knobs");
            record_pass("runtime_hydrology_knobs");
            record_pass("stage_b_after_hydrology_knobs");
            for (int i = 0; i < required_keys.size(); ++i) {
                const String key = String(required_keys[i]);
                if (!bundle.has(key)) {
                    missing_pass_keys.append(key);
                }
            }
        }
        const bool has_required_passes = missing_pass_keys.is_empty();
        const bool authoritative_ready = has_bundle && has_pass && has_required_passes;
        out["rc"] = authoritative_ready ? 0 : -1;
        out["path"] = String("gdext_native_daily_probe");
        out["fail_stage"] = authoritative_ready
            ? String()
            : (!has_bundle ? String("native_daily_bundle_missing")
                           : (!has_pass ? String("native_daily_bundle_no_passes")
                                        : String("native_daily_bundle_missing_required_passes")));
        out["fallback_reason"] = authoritative_ready ? Variant() : Variant(out["fail_stage"]);
        out["configured"] = true;
        out["cell_count"] = _native_world_cell_count;
        out["pass_keys"] = pass_keys;
        out["required_pass_keys"] = required_keys;
        out["missing_pass_keys"] = missing_pass_keys;
        out["authoritative_ready"] = authoritative_ready;
        out["total_ms"] = 0.0;
        out["native_ms"] = 0.0;
        out["compute_ms"] = 0.0;
        out["refresh_ms"] = 0.0;
        out["flush_ms"] = 0.0;
        out["published_slots"] = Array();
        out["visual_dirty_intents"] = Array();
        out["dirty_cells"] = 0;
        Dictionary state;
        state["tick_owner"] = String("DCWorldExt.native_daily_graph");
        String climate_round_state_owner = String("gdscript_retained");
        if (bundle.has("climate_round_state_snapshot")) {
            Dictionary climate_round_state = bundle["climate_round_state_snapshot"];
            state["climate_round_state"] = climate_round_state;
            if (climate_round_state.has("native_probe_state")) {
                Dictionary native_probe_state = climate_round_state["native_probe_state"];
                const bool climate_round_ready = bool(native_probe_state.get("climate_round_authority_ready", false));
                if (climate_round_ready &&
                    (bool(native_probe_state.get("simulation_authority", false)) ||
                     bool(bundle.get("climate_round_active_owner_requested", false)))) {
                    climate_round_state_owner = String("native_active");
                } else if (climate_round_ready) {
                    climate_round_state_owner = String("native_ready");
                }
            }
        }
        state["climate_round_state_owner"] = climate_round_state_owner;
        Dictionary weather_readiness = bundle.has("weather_native_daily_readiness")
            ? Dictionary(bundle["weather_native_daily_readiness"])
            : Dictionary();
        const bool weather_native_ready = bool(weather_readiness.get("ready", false));
        const bool weather_active_requested = bool(bundle.get("weather_transaction_active_owner_requested", false));
        state["weather_transaction_state_owner"] =
            (weather_native_ready && weather_active_requested)
                ? String("native_active")
                : (weather_native_ready ? String("native_ready") : String("gdscript_retained"));
        Dictionary ocean_physical_state;
        if (bundle.has("ocean_physical_state_snapshot")) {
            ocean_physical_state = Dictionary(bundle["ocean_physical_state_snapshot"]);
            state["ocean_physical_state"] = ocean_physical_state;
        }
        state["ocean_physical_state_owner"] =
            ocean_physical_state.has("owner")
                ? String(ocean_physical_state.get("owner", "gdscript_retained"))
                : String("gdscript_retained");
        Dictionary season_refresh_state;
        if (bundle.has("season_refresh_state_snapshot")) {
            season_refresh_state = Dictionary(bundle["season_refresh_state_snapshot"]);
            state["season_refresh_state"] = season_refresh_state;
        }
        state["season_refresh_state_owner"] =
            season_refresh_state.has("owner")
                ? String(season_refresh_state.get("owner", "gdscript_retained"))
                : String("gdscript_retained");
        state["visual_upload_state_owner"] = String("godot_retained");
        state["fallback_owner"] =
            bool(bundle.get("legacy_sus_fallback_enabled", true))
                ? String("gdscript_legacy_sus")
                : String("explicit_failure_only");
        Array authority_blockers;
        authority_blockers.append(String("weather_transaction_state_gdscript"));
        authority_blockers.append(String("ocean_physical_state_gdscript"));
        authority_blockers.append(String("season_refresh_state_gdscript"));
        if (!bundle.has("runtime_hydrology_knobs")) {
            authority_blockers.append(String("runtime_hydrology"));
        }
        if (!bundle.has("sea_ice_knobs")) {
            authority_blockers.append(String("sea_ice"));
        }
        if (bool(bundle.get("legacy_sus_fallback_enabled", true))) {
            authority_blockers.append(String("legacy_sus_fallback_enabled"));
        }
        Array retained_boundaries = native_daily_collect_retained_boundaries(bundle);
        Dictionary authority_report;
        Dictionary weather_authority;
        weather_authority["owner"] = state["weather_transaction_state_owner"];
        weather_authority["phase"] =
            (weather_native_ready && weather_active_requested)
                ? String("native_active_visible_publish")
                : (weather_native_ready ? String("native_ready_visible_publish") : String("probe_bundle_only"));
        weather_authority["readiness"] = weather_readiness;
        weather_authority["visible_publish_ready"] = weather_native_ready;
        weather_authority["active_owner_requested"] = weather_active_requested;
        weather_authority["simulation_authority"] = weather_native_ready && weather_active_requested;
        weather_authority["front_snapshot_ready"] = bool(weather_readiness.get("has_result_apply", false));
        weather_authority["weather_lut_intent_ready"] = bool(weather_readiness.get("has_weather_lut_publish", false));
        weather_authority["publish_slots_expected"] =
            weather_native_ready
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
                ? Array::make(String("probe_does_not_execute_pass"))
                : Array::make(String("weather_publish_not_executed_in_probe"),
                              String(weather_readiness.get("reason", "not_ready")));
        authority_report["weather_transaction"] = weather_authority;
        Dictionary hydrology_authority;
        hydrology_authority["owner"] =
            bundle.has("runtime_hydrology_knobs") ? String("native_probe") : String("gdscript_retained");
        hydrology_authority["phase"] =
            bundle.has("runtime_hydrology_knobs") ? String("probe_bundle_node_present") : String("legacy_weather_chain");
        hydrology_authority["simulation_authority"] = false;
        hydrology_authority["published_slots_expected"] =
            bundle.has("runtime_hydrology_knobs")
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
            bundle.has("runtime_hydrology_knobs")
                ? Array::make(String("probe_does_not_execute_pass"))
                : Array::make(String("runtime_hydrology_knobs_missing"));
        authority_report["runtime_hydrology"] = hydrology_authority;
        Dictionary sea_ice_authority;
        sea_ice_authority["owner"] =
            bundle.has("sea_ice_knobs") ? String("native_probe") : String("gdscript_retained");
        sea_ice_authority["phase"] =
            bundle.has("sea_ice_knobs") ? String("probe_bundle_node_present") : String("legacy_climate_or_sea_ice_job");
        sea_ice_authority["simulation_authority"] = false;
        sea_ice_authority["published_slots_expected"] =
            bundle.has("sea_ice_knobs")
                ? Array::make(String("cell_sea_ice_frac"),
                              String("cell_temp"),
                              String("cell_moisture"))
                : Array();
        sea_ice_authority["blockers"] =
            bundle.has("sea_ice_knobs")
                ? Array::make(String("probe_does_not_execute_pass"))
                : Array::make(String("sea_ice_knobs_missing"));
        sea_ice_authority["retained_boundaries"] =
            bundle.has("sea_ice_knobs")
                ? Array::make(String("terrain_flip_visibility_gdscript"),
                              String("sea_ice_visual_upload_godot"))
                : Array();
        authority_report["sea_ice"] = sea_ice_authority;
        Dictionary ocean_authority;
        ocean_authority["owner"] = state["ocean_physical_state_owner"];
        ocean_authority["phase"] =
            String(state["ocean_physical_state_owner"]) == String("native_ready_probe")
                ? String("native_ready_probe")
                : String("gdscript_stage_machine");
        ocean_authority["state"] = ocean_physical_state;
        ocean_authority["native_owned_output_slots"] =
            ocean_physical_state.get("native_owned_output_slots", Array());
        ocean_authority["blockers"] =
            Array::make(String("probe_does_not_execute_pass"),
                        String("ocean_physical_owner_not_active"));
        ocean_authority["retained_boundaries"] =
            ocean_physical_state.get("remaining_gdscript_authority",
                Array::make(String("visual_raster_boundary_godot"),
                            String("texture_commit_boundary_godot")));
        authority_report["ocean_physical"] = ocean_authority;
        Dictionary season_authority;
        season_authority["owner"] = state["season_refresh_state_owner"];
        season_authority["phase"] =
            String(state["season_refresh_state_owner"]) == String("native_ready_probe")
                ? String("native_ready_cadence_probe")
                : String("gdscript_cadence");
        season_authority["state"] = season_refresh_state;
        season_authority["simulation_slot_dirty_intents"] =
            season_refresh_state.get("simulation_slot_dirty_intents", Array());
        season_authority["visual_dirty_intents"] =
            season_refresh_state.get("visual_dirty_intents", Array());
        season_authority["blockers"] =
            Array::make(String("probe_does_not_execute_pass"),
                        String("season_refresh_owner_not_active"));
        season_authority["retained_boundaries"] =
            season_refresh_state.get("visual_dirty_intents",
                Array::make(String("atlas_queue_godot"),
                            String("detail_scatter_godot")));
        authority_report["season_refresh"] = season_authority;
        Dictionary visual_authority;
        visual_authority["owner"] = state["visual_upload_state_owner"];
        visual_authority["phase"] = String("godot_upload_boundary");
        visual_authority["blockers"] = Array();
        visual_authority["retained_boundaries"] = Array::make(String("image_texture_upload_godot"));
        authority_report["visual_upload"] = visual_authority;
        Dictionary fallback_authority;
        const bool legacy_fallback_enabled = bool(bundle.get("legacy_sus_fallback_enabled", true));
        fallback_authority["owner"] = state["fallback_owner"];
        fallback_authority["phase"] =
            legacy_fallback_enabled ? String("probe_fallback_retained") : String("fallback_test_only");
        fallback_authority["blockers"] =
            legacy_fallback_enabled ? Array::make(String("legacy_sus_fallback_enabled")) : Array();
        authority_report["fallback"] = fallback_authority;
        state["authority_report"] = authority_report;
        state["authority_blockers"] = authority_blockers;
        state["retained_boundaries"] = retained_boundaries;
        state["retained_godot_boundaries"] = retained_boundaries;
        state["retained_boundary_policy"] = String("explicit_godot_presentation_boundary");
        state["graph_coverage_state"] = String("probe_partial");
        out["native_state_snapshot"] = state;
        out["authority_blockers"] = authority_blockers;
        out["retained_boundaries"] = retained_boundaries;
        out["retained_godot_boundaries"] = retained_boundaries;
        out["retained_boundary_policy"] = state["retained_boundary_policy"];
        out["graph_coverage_state"] = String("probe_partial");
        out["boundary_contract"] = bundle.get("native_daily_boundary_contract", Dictionary());
        Dictionary boundary_contract = out["boundary_contract"];
        out["bundle_key_count"] = int(boundary_contract.get("bundle_key_count", bundle.size()));
        out["tick_delta_key_count"] = Array(boundary_contract.get("tick_delta_keys", Array())).size();
        out["runtime_config_report"] = _native_runtime_config.duplicate(true);
        out["native_daily_active_default_ready"] = false;
        out["active_default_blockers"] = out["authority_blockers"];
        out["fallback_mode"] = String("legacy_sus_retained_until_active_default_validation");
        return out;
    }
