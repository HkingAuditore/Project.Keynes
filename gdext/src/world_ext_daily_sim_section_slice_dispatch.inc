    auto exec_slice_node = [&](const NativeDailySliceNode &node) -> bool {
        if (std::strcmp(node.name, "climate_pass_a") == 0) {
            Dictionary cp_struct = as_dict(_native_daily_slice_bundle["climate_pass_a_struct"]);
            // Range metadata is injected into the pass knob dictionary below.
            // Keep visible publish deferred for every native-daily slice; the
            // graph-level finalizer owns the single commit boundary.
            cp_struct["defer_visible_publish"] = true;
            const double phase = double(_native_daily_slice_tick_knobs.get("season_phase", 0.0));
            const double season_phase = double(_native_daily_slice_tick_knobs.get("season_phase", phase));
            // [climate-mt 2026-07] 多核：pass_a 纯 cell-local，_thread 与 scalar 逐位等价
            //   （bench 实测 49k~110k ~4-5x；compute-bound，随核近线性）。n_tasks=0=自适应。
            const double ms = run_climate_pass_a_thread(cp_struct, phase, season_phase, 0);
            if (ms < 0.0) return false;
            breakdown["pass_a_ms"] = ms;
            breakdown["climate_ms"] = double(breakdown.get("climate_ms", 0.0)) + ms;
            return true;
        }
        if (std::strcmp(node.name, "ocean_water") == 0) {
            Dictionary water_knobs = as_dict(_native_daily_slice_bundle["ocean_water_knobs"]);
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
            if (ms < 0.0) return false;
            _native_daily_slice_bundle["ocean_water_knobs"] = water_knobs;
            if (water_knobs.has("anomaly_out") && _native_daily_slice_bundle.has("ocean_land_knobs")) {
                Dictionary land_knobs = as_dict(_native_daily_slice_bundle["ocean_land_knobs"]);
                land_knobs["anomaly_inout"] = water_knobs["anomaly_out"];
                _native_daily_slice_bundle["ocean_land_knobs"] = land_knobs;
            }
            breakdown["ocean_water_ms"] = ms;
            breakdown["ocean_water_variant"] = variant;
            breakdown["ocean_water_thread_tasks"] = thread_tasks;
            breakdown["ocean_ms"] = double(breakdown.get("ocean_ms", 0.0)) + ms;
            return true;
        }
        if (std::strcmp(node.name, "ocean_land") == 0) {
            Dictionary land_knobs = as_dict(_native_daily_slice_bundle["ocean_land_knobs"]);
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
            if (ms < 0.0) return false;
            _native_daily_slice_bundle["ocean_land_knobs"] = land_knobs;
            breakdown["ocean_land_ms"] = ms;
            breakdown["ocean_land_variant"] = variant;
            breakdown["ocean_land_thread_tasks"] = thread_tasks;
            breakdown["ocean_ms"] = double(breakdown.get("ocean_ms", 0.0)) + ms;
            return true;
        }
        if (std::strcmp(node.name, "climate_pass_b") == 0) {
            // [climate-mt 2026-07] 多核：pass_b 写 own-cell（LANOM/M），邻居只读
            //   round-start 快照（TTA/IW）+ 预拍 temp_snapshot → 逐位等价于 scalar
            //   （_simd land 路径已在 legacy 路径生产验证）。n_tasks=0=自适应。
            Dictionary pass_b_knobs = as_dict(_native_daily_slice_bundle["climate_pass_b_knobs"]);
            pass_b_knobs["defer_visible_publish"] = true;
            const double ms = run_climate_pass_b_thread(pass_b_knobs, 0);
            if (ms < 0.0) return false;
            breakdown["pass_b_ms"] = ms;
            breakdown["climate_ms"] = double(breakdown.get("climate_ms", 0.0)) + ms;
            return true;
        }
        if (std::strcmp(node.name, "wind_air") == 0) {
            Dictionary wind_knobs = as_dict(_native_daily_slice_bundle["wind_air_knobs"]);
            const double ms = run_wind_air_mass_pass(wind_knobs);
            if (ms < 0.0) return false;
            _native_daily_slice_bundle["wind_air_knobs"] = wind_knobs;
            breakdown["wind_air_ms"] = ms;
            breakdown["wind_ms"] = double(breakdown.get("wind_ms", 0.0)) + ms;
            breakdown["climate_ms"] = double(breakdown.get("climate_ms", 0.0)) + ms;
            return true;
        }
        if (std::strcmp(node.name, "wind_surface") == 0) {
            Dictionary wind_knobs = as_dict(_native_daily_slice_bundle["wind_surface_knobs"]);
            const double ms = run_wind_surface_pass(wind_knobs);
            if (ms < 0.0) return false;
            _native_daily_slice_bundle["wind_surface_knobs"] = wind_knobs;
            breakdown["wind_surface_ms"] = ms;
            breakdown["wind_ms"] = double(breakdown.get("wind_ms", 0.0)) + ms;
            breakdown["climate_ms"] = double(breakdown.get("climate_ms", 0.0)) + ms;
            return true;
        }
        if (std::strcmp(node.name, "sea_ice") == 0) {
            const float phase = float(_native_daily_slice_tick_knobs.get("season_phase", 0.0));
            Dictionary sea_ice_knobs = as_dict(_native_daily_slice_bundle["sea_ice_knobs"]);
            const double ms = run_sea_ice_daily_pass(sea_ice_knobs, phase);
            if (ms < 0.0) return false;
            breakdown["sea_ice_ms"] = ms;
            breakdown["sea_ice_dt_days"] = double(sea_ice_knobs.get("dt_days", 1.0));
            breakdown["climate_ms"] = double(breakdown.get("climate_ms", 0.0)) + ms;
            return true;
        }
        if (std::strcmp(node.name, "transpiration") == 0) {
            Dictionary transpiration_knobs = as_dict(_native_daily_slice_bundle["transpiration_knobs"]);
            transpiration_knobs["defer_visible_publish"] = true;
            const double ms = run_transpiration_pass(transpiration_knobs);
            if (ms < 0.0) return false;
            breakdown["transp_ms"] = ms;
            breakdown["climate_ms"] = double(breakdown.get("climate_ms", 0.0)) + ms;
            return true;
        }
        if (std::strcmp(node.name, "stage_b") == 0 ||
            std::strcmp(node.name, "stage_b_after_hydrology") == 0) {
            const char *key = std::strcmp(node.name, "stage_b_after_hydrology") == 0
                ? "stage_b_after_hydrology_knobs"
                : "stage_b_knobs";
            Dictionary stage_b_knobs = as_dict(_native_daily_slice_bundle[key]);
            // stage_b_knobs 为空（run_albedo/veg_dyn/feedback 全 false 的 stride tick）
            // 时跳过，不算失败 —— 与 run_stage_b_pass 内部 early return 语义一致。
            if (stage_b_knobs.is_empty()) {
                return true;
            }
            const double ms = run_stage_b_pass(stage_b_knobs);
            if (ms < 0.0) return false;
            breakdown["stage_b_ms"] = double(breakdown.get("stage_b_ms", 0.0)) + ms;
            breakdown["albedo_ms"] = stage_b_knobs.get("albedo_ms", breakdown.get("albedo_ms", 0.0));
            breakdown["veg_dyn_ms"] = stage_b_knobs.get("veg_dyn_ms", breakdown.get("veg_dyn_ms", 0.0));
            breakdown["feedback_ms"] = stage_b_knobs.get("feedback_ms", breakdown.get("feedback_ms", 0.0));
            record_stage_b_diag(stage_b_knobs);
            if (stage_b_knobs.has("succession_indices")) {
                breakdown["succession_indices"] = stage_b_knobs["succession_indices"];
                breakdown["succession_to_veg"] = stage_b_knobs["succession_to_veg"];
                breakdown["stat_succession_count"] = stage_b_knobs.get("stat_succession_count", 0);
            }
            return true;
        }
        if (std::strcmp(node.name, "albedo") == 0) {
            if (_native_daily_slice_bundle.has("stage_b_knobs") ||
                _native_daily_slice_bundle.has("stage_b_after_hydrology_knobs")) {
                return true;
            }
            const double ms = run_albedo_pass(as_dict(_native_daily_slice_bundle["albedo_knobs"]));
            if (ms < 0.0) return false;
            breakdown["albedo_ms"] = ms;
            breakdown["stage_b_ms"] = double(breakdown.get("stage_b_ms", 0.0)) + ms;
            return true;
        }
        if (std::strcmp(node.name, "vegetation_dynamics") == 0) {
            if (_native_daily_slice_bundle.has("stage_b_knobs") ||
                _native_daily_slice_bundle.has("stage_b_after_hydrology_knobs")) {
                return true;
            }
            const double ms = run_vegetation_dynamics_pass(as_dict(_native_daily_slice_bundle["vegetation_dynamics_knobs"]));
            if (ms < 0.0) return false;
            breakdown["veg_dyn_ms"] = ms;
            breakdown["stage_b_ms"] = double(breakdown.get("stage_b_ms", 0.0)) + ms;
            return true;
        }
        if (std::strcmp(node.name, "climate_feedback") == 0) {
            if (_native_daily_slice_bundle.has("stage_b_knobs") ||
                _native_daily_slice_bundle.has("stage_b_after_hydrology_knobs")) {
                return true;
            }
            const double ms = run_climate_feedback_pass(as_dict(_native_daily_slice_bundle["climate_feedback_knobs"]));
            if (ms < 0.0) return false;
            breakdown["feedback_ms"] = ms;
            breakdown["stage_b_ms"] = double(breakdown.get("stage_b_ms", 0.0)) + ms;
            return true;
        }
        if (std::strcmp(node.name, "weather") == 0) {
            if (weather_split_enabled()) {
                breakdown["weather_split_enabled"] = true;
                breakdown["weather_split_skipped_monolithic"] = true;
                breakdown["weather_ms"] = double(breakdown.get("weather_ms", 0.0));
                breakdown["weather_tick_ms"] = double(breakdown.get("weather_tick_ms", breakdown.get("weather_ms", 0.0)));
                return true;
            }
            breakdown["weather_split_enabled"] = false;
            breakdown["weather_split_skipped_monolithic"] = false;
            Dictionary weather_knobs = as_dict(_native_daily_slice_bundle["weather_knobs"]);
            weather_knobs["defer_visible_publish"] = true;
            weather_knobs.erase("moisture_read_arr");
            Dictionary weather = run_weather_refresh_daily_pass(weather_knobs);
            if (int(weather.get("rc", -1)) != 0) {
                breakdown["__weather_fail_stage_dyn"] = weather.get("fail_stage", "unknown");
                return false;
            }
            breakdown["weather_ms"] = double(weather.get("total_ms", 0.0));
            Array keys = weather.keys();
            for (int i = 0; i < keys.size(); ++i) {
                Variant k = keys[i];
                breakdown[k] = weather[k];
            }
            if (weather.has("fronts")) {
                _native_fronts_snapshot = weather["fronts"];
            }
            return true;
        }
        if (std::strcmp(node.name, "weather_field") == 0) {
            if (!weather_split_enabled()) return true;
            Dictionary weather_knobs = as_dict(_native_daily_slice_bundle["weather_knobs"]);
            weather_knobs.erase("moisture_read_arr");
            const double field_ms = run_weather_field_solve_pass(weather_knobs);
            if (field_ms < 0.0) {
                breakdown["__weather_fail_stage_dyn"] = String("field_solve");
                return false;
            }
            breakdown["advance_ms"] = field_ms;
            add_weather_timing("weather_field_ms", field_ms);
            return true;
        }
        if (std::strcmp(node.name, "weather_commit") == 0) {
            if (!weather_split_enabled()) return true;
            Dictionary weather_knobs = as_dict(_native_daily_slice_bundle["weather_knobs"]);
            if (weather_knobs.has("out_vapor") && weather_knobs.has("out_cloud") &&
                weather_knobs.has("out_precip") && weather_knobs.has("out_instability") &&
                weather_knobs.has("out_intensity") && weather_knobs.has("out_convergence") &&
                weather_knobs.has("out_type")) {
                Dictionary commit = run_weather_field_commit_pass(weather_knobs);
                const double commit_ms = double(commit.get("elapsed_ms", -1.0));
                if (commit_ms < 0.0) {
                    breakdown["__weather_fail_stage_dyn"] = String("field_commit");
                    return false;
                }
                breakdown["field_commit_total_ms"] = commit_ms;
                breakdown["field_commit_loop_ms"] = double(commit.get("commit_loop_ms", commit_ms));
                breakdown["field_commit_path"] = commit.get("path", String("gdext_commit"));
                breakdown["field_commit_publish_verified"] = true;
                breakdown["field_commit_publish_repaired"] = false;
                breakdown["field_commit_init_count"] = int(weather_knobs.get("n_cells", 0));
                breakdown["field_commit_publish_reason"] = String("ok_native_combined_commit");
                breakdown["weather_dirty_count"] = int(commit.get("weather_dirty_count", 0));
                breakdown["water_budget_error"] = double(commit.get("water_budget_error", 0.0));
                breakdown["active_weather_ratio"] = double(commit.get("active_weather_ratio", 0.0));
                breakdown["weather_convergence_dirty_count"] = int(commit.get("weather_convergence_dirty_count", 0));
                breakdown["weather_convergence_deltas"] = commit.get("weather_convergence_deltas", PackedFloat32Array());
                breakdown["convergence_published"] = bool(commit.get("convergence_published", false));
                breakdown["weather_lut"] = commit.get("weather_lut", PackedByteArray());
                breakdown["weather_lut_changed"] = bool(commit.get("weather_lut_changed", false));
                breakdown["weather_lut_dirty_count"] = int(commit.get("weather_lut_dirty_count", 0));
                breakdown["weather_lut_full_rebuild"] = bool(commit.get("weather_lut_full_rebuild", false));
                add_weather_timing("weather_commit_ms", commit_ms);
            } else {
                breakdown["field_commit_path"] = String("direct_solve_publish");
                breakdown["field_commit_publish_verified"] = true;
                breakdown["field_commit_publish_repaired"] = false;
                breakdown["field_commit_init_count"] = int(weather_knobs.get("n_cells", 0));
                breakdown["field_commit_publish_reason"] = String("ok_direct_solve_publish");
                add_weather_timing("weather_commit_ms", 0.0);
            }
            return true;
        }
        if (std::strcmp(node.name, "weather_distribute") == 0) {
            if (!weather_split_enabled()) return true;
            Dictionary weather_knobs = as_dict(_native_daily_slice_bundle["weather_knobs"]);
            weather_knobs["defer_visible_publish"] = true;
            const Dictionary r_dist = run_weather_distribute_pass(weather_knobs);
            const double dist_ms = double(r_dist.get("elapsed_ms", -1.0));
            if (dist_ms < 0.0) {
                breakdown["__weather_fail_stage_dyn"] = String("distribute");
                return false;
            }
            breakdown["distribute_ms"] = dist_ms;
            breakdown["cover_dirty"] = r_dist.get("cover_dirty", false);
            add_weather_timing("weather_distribute_ms", dist_ms);
            return true;
        }
        if (std::strcmp(node.name, "weather_summary") == 0) {
            if (!weather_split_enabled()) return true;
            Dictionary weather_knobs = as_dict(_native_daily_slice_bundle["weather_knobs"]);
            const Dictionary r_summary = run_weather_summary_fronts_pass(weather_knobs);
            const double summary_ms = double(r_summary.get("elapsed_ms", -1.0));
            if (summary_ms < 0.0) {
                breakdown["__weather_fail_stage_dyn"] = String("summary");
                return false;
            }
            const Array fronts_arr = r_summary.get("fronts", Array());
            breakdown["summary_ms"] = summary_ms;
            breakdown["fronts_count"] = fronts_arr.size();
            breakdown["fronts"] = fronts_arr;
            int cold_front_count = 0;
            int warm_front_count = 0;
            for (int i = 0; i < fronts_arr.size(); ++i) {
                const Variant v = fronts_arr[i];
                if (v.get_type() != Variant::DICTIONARY) continue;
                const Dictionary fd = v;
                const int diag_kind = int(fd.get("front_diagnostic_kind", 0));
                if (diag_kind == 1) {
                    ++cold_front_count;
                } else if (diag_kind == 2) {
                    ++warm_front_count;
                }
            }
            breakdown["weather_cold_front_count"] = cold_front_count;
            breakdown["weather_warm_front_count"] = warm_front_count;
            _native_fronts_snapshot = fronts_arr;
            _native_daily_slice_bundle["weather_fronts"] = fronts_arr;
            add_weather_timing("weather_summary_ms", summary_ms);
            return true;
        }
        if (std::strcmp(node.name, "weather_cyclone") == 0) {
            if (!weather_split_enabled()) return true;
            Dictionary weather_knobs = as_dict(_native_daily_slice_bundle["weather_knobs"]);
            Array fronts_arr;
            if (_native_daily_slice_bundle.has("weather_fronts") &&
                _native_daily_slice_bundle["weather_fronts"].get_type() == Variant::ARRAY) {
                fronts_arr = _native_daily_slice_bundle["weather_fronts"];
            }
            Dictionary cyclone_knobs = weather_knobs;
            const double cyclone_ms = cyclone_wake_step(cyclone_knobs, fronts_arr);
            breakdown["cyclone_ms"] = cyclone_ms;
            breakdown["cyclone_phase1_decay_ms"] = cyclone_knobs.get("cyclone_phase1_decay_ms", 0.0);
            breakdown["cyclone_phase2_inject_ms"] = cyclone_knobs.get("cyclone_phase2_inject_ms", 0.0);
            breakdown["cyclone_n_decayed"] = cyclone_knobs.get("cyclone_n_decayed", 0);
            breakdown["cyclone_n_evicted"] = cyclone_knobs.get("cyclone_n_evicted", 0);
            breakdown["cyclone_n_replaced"] = cyclone_knobs.get("cyclone_n_replaced", 0);
            breakdown["cyclone_n_injected"] = cyclone_knobs.get("cyclone_n_injected", 0);
            breakdown["cyclone_pool_size"] = int(_cyclone_perturbations.size());
            add_weather_timing("weather_cyclone_ms", cyclone_ms);
            return true;
        }
        if (std::strcmp(node.name, "weather_stage_b") == 0) {
            if (!weather_split_enabled()) return true;
            Dictionary weather_knobs = as_dict(_native_daily_slice_bundle["weather_knobs"]);
            if (!bool(weather_knobs.get("native_daily_weather_stage_b_embedded", false))) {
                breakdown["weather_stage_b_ms"] = 0.0;
                return true;
            }
            Dictionary stage_b_knobs = weather_knobs;
            const double stage_b_ms = run_stage_b_pass(stage_b_knobs);
            if (stage_b_ms < 0.0) {
                breakdown["__weather_fail_stage_dyn"] = String("stage_b");
                return false;
            }
            breakdown["weather_stage_b_ms"] = stage_b_ms;
            breakdown["stage_b_ms"] = double(breakdown.get("stage_b_ms", 0.0)) + stage_b_ms;
            breakdown["albedo_ms"] = stage_b_knobs.get("albedo_ms", breakdown.get("albedo_ms", 0.0));
            breakdown["veg_dyn_ms"] = stage_b_knobs.get("veg_dyn_ms", breakdown.get("veg_dyn_ms", 0.0));
            breakdown["feedback_ms"] = stage_b_knobs.get("feedback_ms", breakdown.get("feedback_ms", 0.0));
            record_stage_b_diag(stage_b_knobs);
            if (stage_b_knobs.has("succession_indices")) {
                breakdown["succession_indices"] = stage_b_knobs["succession_indices"];
                breakdown["succession_to_veg"] = stage_b_knobs["succession_to_veg"];
                breakdown["stat_succession_count"] = stage_b_knobs.get("stat_succession_count", 0);
            }
            add_weather_timing("weather_stage_b_ms", stage_b_ms);
            return true;
        }
        if (std::strcmp(node.name, "runtime_hydrology") == 0) {
            Dictionary hydro = run_runtime_hydrology_pass(as_dict(_native_daily_slice_bundle["runtime_hydrology_knobs"]));
            const String fallback_reason = String(hydro.get("fallback_reason", ""));
            if (!fallback_reason.is_empty() || !bool(hydro.get("published_to_slot", false))) {
                breakdown["__hydrology_fail_reason"] =
                    fallback_reason.is_empty() ? String("hydrology did not publish slots") : fallback_reason;
                return false;
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
            return true;
        }
        return false;
    };
