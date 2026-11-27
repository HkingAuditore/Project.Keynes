    if (!_native_daily_slice_active) {
        if (!tick_knobs.has("native_daily_bundle")) {
            return finish_with_failure(String("native_daily_bundle"), String("missing native_daily_bundle"));
        }
        Dictionary bundle = as_dict(tick_knobs.get("native_daily_bundle", Dictionary()));
        if (bundle.is_empty()) {
            return finish_with_failure(String("native_daily_bundle"), String("empty native_daily_bundle"));
        }
        const uint32_t deferred_bits = native_daily_deferred_node_bits(bundle);
        if (native_daily_next_present_node(bundle, 0, deferred_bits) < 0) {
            return finish_with_failure(String("native_daily_bundle"), String("no pass knobs in native_daily_bundle"));
        }

        ++_native_daily_tick_count;
        ++_native_daily_slice_round_id;
        _native_daily_slice_node_index = 0;
        _native_daily_slice_cell_cursor = 0;
        _native_daily_slice_range_node_index = -1;
        _native_daily_slice_cell_budget = 0;
        _native_daily_slice_range_node_bits = 0u;
        if (tick_knobs.has("native_daily_node_range_cells")) {
            _native_daily_slice_cell_budget = std::max(0, int(tick_knobs["native_daily_node_range_cells"]));
        }
        if (_native_daily_slice_cell_budget > 0 && tick_knobs.has("native_daily_node_range_nodes")) {
            _native_daily_slice_range_node_bits =
                native_daily_parse_range_node_bits(tick_knobs["native_daily_node_range_nodes"]);
        }
        // Node batching (bit-equal perf): GDScript injects a fresh JIT knob patch only
        // before the nodes listed in `native_daily_slice_yield_nodes` (the temp-dependent
        // passes). C++ may therefore run consecutive non-yield nodes within a single call,
        // cutting GDScript<->C++ round-trips. Absent the key, fall back to yielding before
        // every node (legacy one-node-per-call behavior).
        _native_daily_slice_yield_bits = 0xFFFFFFFFu;
        if (tick_knobs.has("native_daily_slice_yield_nodes")) {
            PackedInt32Array yield_nodes = tick_knobs["native_daily_slice_yield_nodes"];
            _native_daily_slice_yield_bits = 0u;
            for (int i = 0; i < yield_nodes.size(); ++i) {
                const int idx = yield_nodes[i];
                if (idx >= 0 && idx < 32) {
                    _native_daily_slice_yield_bits |= (1u << idx);
                }
            }
        }
        _native_daily_slice_yield_bits |= deferred_bits;
        _native_daily_slice_elapsed_accum_ms = 0.0;
        _native_daily_slice_any_pass_ran = false;
        // Shallow-copy tick_knobs (we only read scalars: day_index / season_phase) and
        // drop the embedded bundle ref — the bundle is owned separately below. This avoids
        // tick_knobs.duplicate(true) deep-copying the bundle a SECOND time (it is also
        // reachable as tick_knobs["native_daily_bundle"]).
        _native_daily_slice_tick_knobs = tick_knobs.duplicate(false);
        _native_daily_slice_tick_knobs.erase("native_daily_bundle");
        // Structure-deep, leaf-shared copy (see native_daily_cow_structural_copy): owns the
        // dict tree for safe key mutation, shares the per-cell Packed arrays via CoW.
        _native_daily_slice_bundle = native_daily_cow_structural_copy(bundle);
        _native_daily_slice_bundle_pass_keys = native_daily_collect_bundle_pass_keys(_native_daily_slice_bundle);
        _native_daily_slice_retained_authority =
            native_daily_collect_retained_gdscript_authority(_native_daily_slice_bundle);
        _native_daily_slice_state_snapshot =
            native_daily_collect_state_snapshot(_native_daily_slice_bundle, _native_daily_slice_retained_authority);

        _native_dirty_report = Dictionary();
        _native_dirty_report["last_day_index"] = int(_native_daily_slice_tick_knobs.get("day_index", 0));
        _native_dirty_report["last_season_phase"] =
            double(_native_daily_slice_tick_knobs.get("season_phase", 0.0));
        _native_dirty_report["atlas_dirty"] = false;
        _native_dirty_report["enum_atlas_dirty"] = false;
        _native_dirty_report["sea_ice_atlas_dirty"] = false;
        _native_dirty_report["sea_ice_terrain_flip_count"] = 0;
        _native_dirty_report["dirty_cell_count"] = 0;

        _native_daily_slice_breakdown = Dictionary();
        _native_daily_slice_breakdown["native_context_ms"] = 0.0;
        _native_daily_slice_breakdown["season_ms"] = 0.0;
        _native_daily_slice_breakdown["climate_ms"] = 0.0;
        _native_daily_slice_breakdown["weather_ms"] = 0.0;
        _native_daily_slice_breakdown["hydrology_ms"] = 0.0;
        _native_daily_slice_breakdown["ocean_ms"] = 0.0;
        _native_daily_slice_breakdown["stage_b_ms"] = 0.0;
        _native_daily_slice_breakdown["render_prepare_ms"] = 0.0;
        _native_daily_slice_breakdown["path"] = String("gdext_native_daily_slice");
        _native_daily_slice_breakdown["fallback_reason"] = String();
        _native_daily_slice_breakdown["bundle_pass_keys"] = _native_daily_slice_bundle_pass_keys;
        _native_daily_slice_breakdown["retained_gdscript_authority"] = _native_daily_slice_retained_authority;
        _native_daily_slice_breakdown["native_state_snapshot"] = _native_daily_slice_state_snapshot;
        _native_daily_slice_breakdown["round_id"] = _native_daily_slice_round_id;
        // Seeded here as well as at the authority gate below, so a continuation
        // call that returns before reaching the gate still reports the state
        // rather than dropping the key and reading as "not suppressed".
        _native_daily_slice_breakdown["climate_authority_suppressed"] =
            climate_main_thread_suppressed();

        const auto t_context0 = std::chrono::high_resolution_clock::now();
        if (bool(_native_daily_slice_bundle.get("refresh_slots_from_map", true))) {
            PackedStringArray refresh_keys =
                _native_daily_slice_bundle.get("refresh_slot_keys", PackedStringArray());
            if (refresh_keys.size() > 0) {
                refresh_slots_from_map_keys(refresh_keys);
            } else {
                refresh_slots_from_map();
            }
        }
        // The initial refresh imports the last committed MapData state. Protect
        // moisture from unrelated bulk refreshes and prevent visual consumers from
        // observing any in-flight climate/ecology slot until the deferred finalizer.
        _native_daily_slice_active = true;
        _native_daily_visual_commit_pending = true;
        const auto t_context1 = std::chrono::high_resolution_clock::now();
        _native_daily_slice_breakdown["native_context_ms"] =
            std::chrono::duration<double, std::milli>(t_context1 - t_context0).count();
    }

    if (tick_knobs.has("native_daily_bundle_patch")) {
        Dictionary patch = as_dict(tick_knobs.get("native_daily_bundle_patch", Dictionary()));
        if (!patch.is_empty()) {
            Array keys = patch.keys();
            for (int i = 0; i < keys.size(); ++i) {
                Variant k = keys[i];
                _native_daily_slice_bundle[k] = patch[k];
            }
            _native_daily_slice_bundle_pass_keys =
                native_daily_collect_bundle_pass_keys(_native_daily_slice_bundle);
            _native_daily_slice_breakdown["bundle_pass_keys"] = _native_daily_slice_bundle_pass_keys;
            _native_daily_slice_breakdown["jit_patch_key_count"] =
                int(_native_daily_slice_breakdown.get("jit_patch_key_count", 0)) + keys.size();
        }
    }

    Dictionary breakdown = _native_daily_slice_breakdown;
    auto node_name_string = [](const char *name) -> String {
        if (std::strcmp(name, "climate_pass_a") == 0) return String("climate_pass_a");
        if (std::strcmp(name, "ocean_water") == 0) return String("ocean_water");
        if (std::strcmp(name, "ocean_land") == 0) return String("ocean_land");
        if (std::strcmp(name, "climate_pass_b") == 0) return String("climate_pass_b");
        if (std::strcmp(name, "wind_air") == 0) return String("wind_air");
        if (std::strcmp(name, "wind_surface") == 0) return String("wind_surface");
        if (std::strcmp(name, "sea_ice") == 0) return String("sea_ice");
        if (std::strcmp(name, "transpiration") == 0) return String("transpiration");
        if (std::strcmp(name, "albedo") == 0) return String("albedo");
        if (std::strcmp(name, "vegetation_dynamics") == 0) return String("vegetation_dynamics");
        if (std::strcmp(name, "climate_feedback") == 0) return String("climate_feedback");
        if (std::strcmp(name, "stage_b") == 0) return String("stage_b");
        if (std::strcmp(name, "weather") == 0) return String("weather");
        if (std::strcmp(name, "weather_field") == 0) return String("weather_field");
        if (std::strcmp(name, "weather_commit") == 0) return String("weather_commit");
        if (std::strcmp(name, "weather_distribute") == 0) return String("weather_distribute");
        if (std::strcmp(name, "weather_summary") == 0) return String("weather_summary");
        if (std::strcmp(name, "weather_cyclone") == 0) return String("weather_cyclone");
        if (std::strcmp(name, "weather_stage_b") == 0) return String("weather_stage_b");
        if (std::strcmp(name, "runtime_hydrology") == 0) return String("runtime_hydrology");
        if (std::strcmp(name, "stage_b_after_hydrology") == 0) return String("stage_b_after_hydrology");
        return String("unknown");
    };
    auto node_key_string = [](const char *key) -> String {
        if (std::strcmp(key, "climate_pass_a_struct") == 0) return String("climate_pass_a_struct");
        if (std::strcmp(key, "ocean_water_knobs") == 0) return String("ocean_water_knobs");
        if (std::strcmp(key, "ocean_land_knobs") == 0) return String("ocean_land_knobs");
        if (std::strcmp(key, "climate_pass_b_knobs") == 0) return String("climate_pass_b_knobs");
        if (std::strcmp(key, "wind_air_knobs") == 0) return String("wind_air_knobs");
        if (std::strcmp(key, "wind_surface_knobs") == 0) return String("wind_surface_knobs");
        if (std::strcmp(key, "sea_ice_knobs") == 0) return String("sea_ice_knobs");
        if (std::strcmp(key, "transpiration_knobs") == 0) return String("transpiration_knobs");
        if (std::strcmp(key, "albedo_knobs") == 0) return String("albedo_knobs");
        if (std::strcmp(key, "vegetation_dynamics_knobs") == 0) return String("vegetation_dynamics_knobs");
        if (std::strcmp(key, "climate_feedback_knobs") == 0) return String("climate_feedback_knobs");
        if (std::strcmp(key, "stage_b_knobs") == 0) return String("stage_b_knobs");
        if (std::strcmp(key, "weather_knobs") == 0) return String("weather_knobs");
        if (std::strcmp(key, "runtime_hydrology_knobs") == 0) return String("runtime_hydrology_knobs");
        if (std::strcmp(key, "stage_b_after_hydrology_knobs") == 0) return String("stage_b_after_hydrology_knobs");
        return String("unknown");
    };
    auto weather_split_enabled = [&]() -> bool {
        return bool(_native_daily_slice_bundle.get("native_daily_split_weather_node_enabled", false));
    };
    auto add_weather_timing = [&](const char *field, const double ms) {
        breakdown[field] = ms;
        const double weather_ms = double(breakdown.get("weather_ms", 0.0)) + ms;
        breakdown["weather_ms"] = weather_ms;
        breakdown["weather_tick_ms"] = weather_ms;
    };
    auto record_stage_b_diag = [&](const Dictionary &stage_b_knobs) {
        const int call_index = int(stage_b_knobs.get("stage_b_call_index", -1));
        breakdown["stage_b_call_index"] = call_index;
        breakdown["albedo_ran"] = bool(stage_b_knobs.get("run_albedo", false));
        breakdown["veg_dyn_ran"] = bool(stage_b_knobs.get("run_veg_dyn", false));
        breakdown["feedback_ran"] = bool(stage_b_knobs.get("run_feedback", false));
        breakdown["stage_b_combined_done"] = true;
        breakdown["stage_b_ext_ok"] = true;
        breakdown["stage_b_total_runs"] = call_index >= 0 ? call_index + 1 : 0;
    };
