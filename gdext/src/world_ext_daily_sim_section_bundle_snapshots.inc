static Variant native_daily_cow_structural_copy(const Variant &v) {
    switch (v.get_type()) {
        case Variant::DICTIONARY: {
            Dictionary src = v;
            Dictionary out;
            Array keys = src.keys();
            for (int i = 0; i < keys.size(); ++i) {
                const Variant &k = keys[i];
                out[k] = native_daily_cow_structural_copy(src[k]);
            }
            return out;
        }
        case Variant::ARRAY: {
            Array src = v;
            Array out;
            out.resize(src.size());
            for (int i = 0; i < src.size(); ++i) {
                out[i] = native_daily_cow_structural_copy(src[i]);
            }
            return out;
        }
        default:
            // Scalars + Packed*Array leaves: share (PackedArray is CoW; C++ never writes
            // these buffers in place, so no fork happens on the hot path).
            return v;
    }
}

static void native_daily_append_unique(Array &arr, const String &value) {
    for (int i = 0; i < arr.size(); ++i) {
        if (String(arr[i]) == value) {
            return;
        }
    }
    arr.append(value);
}

static Array native_daily_collect_bundle_pass_keys(const Dictionary &bundle_dict) {
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
}

// Pass-A runs with defer_visible_publish=true on every native-daily slice, so its
// slot family reaches MapData only through this round-completion commit. Moisture
// is excluded on purpose: it has its own visual-transaction bridge in
// MapGenerator._native_daily_commit_moisture. The ocean/local anomaly slots are
// excluded too — pass_b and the ocean nodes flush them, and the GDScript ocean
// cache aliases those arrays across rounds.
static const char *const NATIVE_DAILY_PASS_A_DEFERRED_SLOTS[] = {
    "cell_temp_baseline",
    "cell_temp_season_offset",
    "cell_ema_initialized",
    "cell_temp_30d",
    "cell_temp_365d",
    "cell_temp_anomaly",
    "cell_insolation_now",
    "cell_insolation_dev",
    "cell_day_length",
    "cell_heat_input",
    "cell_thermal_energy",
    "cell_snowpack",
};
constexpr int NATIVE_DAILY_PASS_A_DEFERRED_SLOT_COUNT =
    int(sizeof(NATIVE_DAILY_PASS_A_DEFERRED_SLOTS) /
        sizeof(NATIVE_DAILY_PASS_A_DEFERRED_SLOTS[0]));

static Array native_daily_collect_published_slots(const Dictionary &bundle_dict) {
    Array slots;
    if (bundle_dict.has("climate_pass_a_struct") || bundle_dict.has("climate_pass_b_knobs") ||
        bundle_dict.has("ocean_water_knobs") || bundle_dict.has("ocean_land_knobs") ||
        bundle_dict.has("wind_air_knobs") || bundle_dict.has("wind_surface_knobs") ||
        bundle_dict.has("sea_ice_knobs") || bundle_dict.has("transpiration_knobs")) {
        native_daily_append_unique(slots, String("cell_temp"));
        native_daily_append_unique(slots, String("cell_moisture"));
        native_daily_append_unique(slots, String("cell_snow_cover"));
        native_daily_append_unique(slots, String("cell_sea_ice_frac"));
        native_daily_append_unique(slots, String("cell_air_mass_temp_anomaly"));
        native_daily_append_unique(slots, String("cell_ocean_thermal_anomaly"));
        native_daily_append_unique(slots, String("cell_local_thermal_anomaly"));
    }
    if (bundle_dict.has("climate_pass_a_struct")) {
        for (int i = 0; i < NATIVE_DAILY_PASS_A_DEFERRED_SLOT_COUNT; ++i) {
            native_daily_append_unique(slots, String(NATIVE_DAILY_PASS_A_DEFERRED_SLOTS[i]));
        }
    }
    if (bundle_dict.has("stage_b_knobs") || bundle_dict.has("stage_b_after_hydrology_knobs") ||
        bundle_dict.has("albedo_knobs") ||
        bundle_dict.has("vegetation_dynamics_knobs") || bundle_dict.has("climate_feedback_knobs")) {
        native_daily_append_unique(slots, String("cell_cover"));
        native_daily_append_unique(slots, String("cell_vegetation"));
        native_daily_append_unique(slots, String("cell_vegetation_vitality"));
    }
    if (bundle_dict.has("weather_knobs")) {
        native_daily_append_unique(slots, String("cell_weather_type"));
        native_daily_append_unique(slots, String("cell_weather_intensity"));
        native_daily_append_unique(slots, String("cell_weather_cloud"));
        native_daily_append_unique(slots, String("cell_weather_precip"));
        native_daily_append_unique(slots, String("cell_weather_field_init"));
        native_daily_append_unique(slots, String("cell_weather_transition_alpha"));
    }
    if (bundle_dict.has("runtime_hydrology_knobs")) {
        native_daily_append_unique(slots, String("cell_moisture"));
        native_daily_append_unique(slots, String("cell_soil_moisture"));
        native_daily_append_unique(slots, String("cell_water_balance_30d"));
        native_daily_append_unique(slots, String("cell_river_discharge"));
        native_daily_append_unique(slots, String("cell_river_discharge_30d"));
        native_daily_append_unique(slots, String("cell_river_storage"));
        native_daily_append_unique(slots, String("cell_groundwater_storage"));
        native_daily_append_unique(slots, String("cell_surface_runoff"));
    }
    return slots;
}

static Array native_daily_collect_retained_gdscript_authority(const Dictionary &bundle_dict) {
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
}

static Array native_daily_collect_retained_boundaries(const Dictionary &bundle_dict) {
    Array retained;
    native_daily_append_unique(retained, String("visual_uploads"));
    native_daily_append_unique(retained, String("csv_debug_sampling"));
    if (bundle_dict.has("weather_knobs")) {
        native_daily_append_unique(retained, String("weather_front_objects_gdscript"));
        native_daily_append_unique(retained, String("weather_lut_upload_godot"));
    }
    if (bundle_dict.has("sea_ice_knobs")) {
        native_daily_append_unique(retained, String("sea_ice_terrain_flip_visibility_gdscript"));
        native_daily_append_unique(retained, String("sea_ice_visual_upload_godot"));
    }
    if (bundle_dict.has("ocean_physical_state_snapshot")) {
        native_daily_append_unique(retained, String("ocean_visual_raster_godot"));
        native_daily_append_unique(retained, String("ocean_texture_commit_godot"));
    }
    if (bundle_dict.has("season_refresh_state_snapshot")) {
        native_daily_append_unique(retained, String("season_atlas_queue_godot"));
        native_daily_append_unique(retained, String("detail_scatter_godot"));
    }
    return retained;
}

static Array native_daily_collect_visual_dirty_intents(const Dictionary &bundle_dict,
                                                       const Dictionary &breakdown_dict,
                                                       const Dictionary &dirty_report) {
    Array intents;
    if (bool(dirty_report.get("atlas_dirty", false))) {
        native_daily_append_unique(intents, String("atlas"));
    }
    if (bool(dirty_report.get("enum_atlas_dirty", false))) {
        native_daily_append_unique(intents, String("enum_atlas"));
    }
    if (bool(dirty_report.get("sea_ice_atlas_dirty", false))) {
        native_daily_append_unique(intents, String("sea_ice_atlas"));
    }
    if (bundle_dict.has("weather_knobs") &&
        (bool(breakdown_dict.get("weather_lut_changed", false)) ||
         breakdown_dict.has("weather_lut"))) {
        native_daily_append_unique(intents, String("weather_lut"));
    }
    if (breakdown_dict.has("succession_indices") ||
        int(breakdown_dict.get("stat_succession_count", 0)) > 0) {
        native_daily_append_unique(intents, String("detail_scatter"));
    }
    return intents;
}

static Dictionary native_daily_collect_state_snapshot(const Dictionary &bundle_dict,
                                                      const Array &retained_authority) {
    Dictionary state;
    state["tick_owner"] = String("DCWorldExt.native_daily_graph");
    state["round_state_owner"] = String("native_active");
    state["continuation_owner"] = String("DCWorldExt.native_daily_slice");
    state["visual_upload_state_owner"] = String("godot_retained");
    state["fallback_owner"] =
        bool(bundle_dict.get("legacy_sus_fallback_enabled", true))
            ? String("gdscript_legacy_sus")
            : String("explicit_failure_only");

    Dictionary climate_round_state;
    if (bundle_dict.get("climate_round_state_snapshot", Dictionary()).get_type() == Variant::DICTIONARY) {
        climate_round_state = Dictionary(bundle_dict.get("climate_round_state_snapshot", Dictionary()));
        state["climate_round_state"] = climate_round_state;
    }
    state["climate_round_state_owner"] =
        climate_round_state.has("owner")
            ? String(climate_round_state.get("owner", "gdscript_retained"))
            : String("gdscript_retained");

    Dictionary ocean_physical_state;
    if (bundle_dict.get("ocean_physical_state_snapshot", Dictionary()).get_type() == Variant::DICTIONARY) {
        ocean_physical_state = Dictionary(bundle_dict.get("ocean_physical_state_snapshot", Dictionary()));
        state["ocean_physical_state"] = ocean_physical_state;
    }
    state["ocean_physical_state_owner"] =
        ocean_physical_state.has("owner")
            ? String(ocean_physical_state.get("owner", "gdscript_retained"))
            : String("gdscript_retained");

    Dictionary season_refresh_state;
    if (bundle_dict.get("season_refresh_state_snapshot", Dictionary()).get_type() == Variant::DICTIONARY) {
        season_refresh_state = Dictionary(bundle_dict.get("season_refresh_state_snapshot", Dictionary()));
        state["season_refresh_state"] = season_refresh_state;
    }
    state["season_refresh_state_owner"] =
        season_refresh_state.has("owner")
            ? String(season_refresh_state.get("owner", "gdscript_retained"))
            : String("gdscript_retained");

    Dictionary season_cadence_policy;
    if (bundle_dict.get("season_cadence_policy", Dictionary()).get_type() == Variant::DICTIONARY) {
        season_cadence_policy = Dictionary(bundle_dict.get("season_cadence_policy", Dictionary()));
        state["season_cadence_policy"] = season_cadence_policy;
    }

    Dictionary weather_readiness;
    if (bundle_dict.get("weather_native_daily_readiness", Dictionary()).get_type() == Variant::DICTIONARY) {
        weather_readiness = Dictionary(bundle_dict.get("weather_native_daily_readiness", Dictionary()));
    }
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

    Dictionary authority_report;
    Dictionary graph_authority;
    graph_authority["owner"] = String("native_active");
    graph_authority["phase"] = String("native_continuation");
    graph_authority["simulation_authority"] = true;
    graph_authority["state_owner"] = String("DCWorldExt");
    authority_report["native_daily_graph"] = graph_authority;

    Dictionary climate_authority;
    climate_authority["owner"] = state["climate_round_state_owner"];
    climate_authority["phase"] =
        String(state["climate_round_state_owner"]) == String("native_active")
            ? String("active_owner_gate")
            : (String(state["climate_round_state_owner"]) == String("native_ready")
                   ? String("native_ready_probe")
                   : String("gdscript_state_machine"));
    climate_authority["simulation_authority"] =
        String(state["climate_round_state_owner"]) == String("native_active");
    climate_authority["state"] = climate_round_state;
    climate_authority["remaining_gdscript_authority"] =
        climate_round_state.get("remaining_gdscript_authority", Array());
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
    visual_authority["owner"] = String("godot_retained");
    visual_authority["phase"] = String("godot_upload_boundary");
    visual_authority["blockers"] = Array();
    visual_authority["retained_boundaries"] = Array::make(String("image_texture_upload_godot"));
    authority_report["visual_upload"] = visual_authority;

    Dictionary fallback_authority;
    const bool legacy_fallback_enabled = bool(bundle_dict.get("legacy_sus_fallback_enabled", true));
    fallback_authority["owner"] =
        legacy_fallback_enabled ? String("gdscript_legacy_sus") : String("explicit_failure_only");
    fallback_authority["phase"] =
        legacy_fallback_enabled ? String("fallback_retained") : String("fallback_test_only");
    fallback_authority["blockers"] =
        legacy_fallback_enabled ? Array::make(String("legacy_sus_fallback_enabled")) : Array();
    authority_report["fallback"] = fallback_authority;

    Array authority_blockers = retained_authority.duplicate();
    if (String(state.get("climate_round_state_owner", "gdscript_retained")) != String("native_active")) {
        native_daily_append_unique(authority_blockers, String("climate_round"));
    }
    if (bundle_dict.has("weather_knobs") &&
        String(state.get("weather_transaction_state_owner", "gdscript_retained")) != String("native_active")) {
        native_daily_append_unique(authority_blockers, String("weather_transaction"));
    }
    if (String(state.get("ocean_physical_state_owner", "gdscript_retained")) != String("native_active")) {
        native_daily_append_unique(authority_blockers, String("ocean_currents_physical_state"));
    }
    if (String(state.get("season_refresh_state_owner", "gdscript_retained")) != String("native_active")) {
        native_daily_append_unique(authority_blockers, String("season_refresh"));
    }
    if (bool(bundle_dict.get("legacy_sus_fallback_enabled", true))) {
        native_daily_append_unique(authority_blockers, String("legacy_sus_fallback_enabled"));
    }
    Array retained_boundaries = native_daily_collect_retained_boundaries(bundle_dict);
    state["authority_report"] = authority_report;
    state["authority_blockers"] = authority_blockers;
    state["retained_boundaries"] = retained_boundaries;
    state["retained_godot_boundaries"] = retained_boundaries;
    state["retained_boundary_policy"] = String("explicit_godot_presentation_boundary");
    state["graph_coverage_state"] = authority_blockers.is_empty() ? String("complete") : String("partial");
    return state;
}
