    _native_daily_slice_elapsed_accum_ms += slice_ms;

    const double compute_ms = compute_ms_from_breakdown(breakdown);
    const Array published_slots = done
        ? native_daily_collect_published_slots(_native_daily_slice_bundle)
        : Array();
    const Array visual_dirty_intents = done
        ? native_daily_collect_visual_dirty_intents(_native_daily_slice_bundle, breakdown, _native_dirty_report)
        : Array();
    double progress_ratio = done
        ? 1.0
        : (NATIVE_DAILY_SLICE_GRAPH_SIZE > 0
               ? double(_native_daily_slice_node_index) / double(NATIVE_DAILY_SLICE_GRAPH_SIZE)
               : 1.0);
    if (!done && bool(breakdown.get("node_range_active", false)) && NATIVE_DAILY_SLICE_GRAPH_SIZE > 0) {
        const int cell_end = int(breakdown.get("node_cell_cursor_end", 0));
        const int cell_count = std::max(1, int(breakdown.get("node_cell_count", 1)));
        const double node_frac = std::max(0.0, std::min(1.0, double(cell_end) / double(cell_count)));
        progress_ratio =
            (double(_native_daily_slice_node_index) + node_frac) / double(NATIVE_DAILY_SLICE_GRAPH_SIZE);
    }

    breakdown["total_ms"] = slice_ms;
    breakdown["native_ms"] = slice_ms;
    breakdown["round_native_ms"] = _native_daily_slice_elapsed_accum_ms;
    breakdown["compute_ms"] = compute_ms;
    breakdown["refresh_ms"] = double(breakdown.get("native_context_ms", 0.0));
    breakdown["flush_ms"] = double(breakdown.get("render_prepare_ms", 0.0));
    breakdown["published_slots"] = published_slots;
    breakdown["dirty_cells"] = int(_native_dirty_report.get("dirty_cell_count", 0));
    breakdown["visual_dirty_intents"] = visual_dirty_intents;
    breakdown["native_state_snapshot"] = _native_daily_slice_state_snapshot;
    Dictionary authority_report = _native_daily_slice_state_snapshot.get("authority_report", Dictionary());
    if (done && bool(breakdown.get("hydrology_published_to_slot", false)) &&
        authority_report.has("runtime_hydrology")) {
        Dictionary hydrology_authority = authority_report["runtime_hydrology"];
        hydrology_authority["phase"] = String("native_active_verified");
        hydrology_authority["verified_publish"] = true;
        hydrology_authority["simulation_authority"] = true;
        hydrology_authority["blockers"] = Array();
        authority_report["runtime_hydrology"] = hydrology_authority;
    }
    if (done && _native_daily_slice_bundle.has("sea_ice_knobs") &&
        authority_report.has("sea_ice")) {
        Dictionary sea_ice_authority = authority_report["sea_ice"];
        sea_ice_authority["phase"] = String("native_active_verified");
        sea_ice_authority["verified_publish"] = true;
        sea_ice_authority["simulation_authority"] = true;
        sea_ice_authority["blockers"] = Array();
        authority_report["sea_ice"] = sea_ice_authority;
    }
    if (done && _native_daily_slice_bundle.has("weather_knobs") &&
        authority_report.has("weather_transaction")) {
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
    breakdown["authority_report"] = authority_report;
    breakdown["authority_blockers"] = _native_daily_slice_state_snapshot.get("authority_blockers", Array());
    breakdown["retained_boundaries"] = _native_daily_slice_state_snapshot.get("retained_boundaries", Array());
    breakdown["retained_godot_boundaries"] = _native_daily_slice_state_snapshot.get("retained_godot_boundaries", Array());
    breakdown["retained_boundary_policy"] =
        _native_daily_slice_state_snapshot.get("retained_boundary_policy", String());
    breakdown["graph_coverage_complete"] = Array(breakdown["authority_blockers"]).is_empty();
    breakdown["graph_coverage_state"] =
        _native_daily_slice_state_snapshot.get("graph_coverage_state", String("partial"));
    breakdown["boundary_contract"] =
        _native_daily_slice_bundle.get("native_daily_boundary_contract", Dictionary());
    Dictionary boundary_contract = breakdown["boundary_contract"];
    breakdown["bundle_key_count"] =
        int(boundary_contract.get("bundle_key_count", _native_daily_slice_bundle.size()));
    breakdown["tick_delta_key_count"] =
        Array(boundary_contract.get("tick_delta_keys", Array())).size();
    // perf(Tier1): runtime_config_report 此前在 breakdown 与 out 各做一次独立深拷贝（同源、
    // 仅诊断只读）。改为本片单次深拷贝后共享同一 Variant，省掉每片第 2 次递归深拷贝。
    Dictionary runtime_config_report = _native_runtime_config.duplicate(true);
    breakdown["runtime_config_report"] = runtime_config_report;
    breakdown["climate_modes"] = get_climate_modes_report();
    const bool active_default_ready =
        done &&
        String(breakdown["graph_coverage_state"]) == String("complete") &&
        Array(breakdown["authority_blockers"]).is_empty() &&
        bool(_native_daily_slice_bundle.get("native_daily_legacy_daily_production_retired", false));
    breakdown["native_daily_active_default_ready"] = active_default_ready;
    breakdown["active_default_blockers"] = breakdown["authority_blockers"];
    breakdown["fallback_mode"] =
        active_default_ready ? String("explicit_failure_only") : String("legacy_sus_retained_until_active_default_validation");
    PackedFloat32Array temperature_transport_anomaly_out;
    if (_native_daily_slice_bundle.has("ocean_land_knobs")) {
        Dictionary land_knobs = as_dict(_native_daily_slice_bundle["ocean_land_knobs"]);
        if (land_knobs.has("anomaly_inout")) {
            temperature_transport_anomaly_out = land_knobs["anomaly_inout"];
        }
    }
    breakdown["done"] = done;
    breakdown["progress_ratio"] = progress_ratio;
    if (done) {
        breakdown["stage_name"] = String("native_daily_complete");
        breakdown["substage"] = String("round_complete");
    }
    _native_daily_slice_breakdown = breakdown;

    out["rc"] = 0;
    out["path"] = String("gdext_native_daily_slice");
    out["fail_stage"] = String();
    out["fallback_reason"] = String();
    out["done"] = done;
    out["progress_ratio"] = progress_ratio;
    out["stage_name"] = breakdown.get("stage_name", String("native_daily_slice"));
    out["substage"] = breakdown.get("substage", String());
    out["cursor_start"] = breakdown.get("cursor_start", _native_daily_slice_node_index);
    out["cursor_end"] = breakdown.get("cursor_end", _native_daily_slice_node_index);
    out["node_index"] = _native_daily_slice_node_index;
    out["next_node_index"] = done ? -1 : next_index;
    out["node_range_enabled"] = breakdown.get("node_range_enabled", false);
    out["node_range_active"] = breakdown.get("node_range_active", false);
    out["node_range_done"] = breakdown.get("node_range_done", true);
    out["node_range_budget"] = breakdown.get("node_range_budget", _native_daily_slice_cell_budget);
    out["node_range_node"] = breakdown.get("node_range_node", String());
    out["node_cell_cursor_start"] = breakdown.get("node_cell_cursor_start", -1);
    out["node_cell_cursor_end"] = breakdown.get("node_cell_cursor_end", -1);
    out["node_cell_count"] = breakdown.get("node_cell_count", 0);
    out["node_cell_processed"] = breakdown.get("node_cell_processed", 0);
    out["round_id"] = _native_daily_slice_round_id;
    out["total_ms"] = slice_ms;
    out["native_ms"] = slice_ms;
    out["round_native_ms"] = _native_daily_slice_elapsed_accum_ms;
    out["compute_ms"] = compute_ms;
    out["refresh_ms"] = double(breakdown.get("native_context_ms", 0.0));
    out["flush_ms"] = double(breakdown.get("render_prepare_ms", 0.0));
    out["published_slots"] = published_slots;
    out["dirty_cells"] = int(_native_dirty_report.get("dirty_cell_count", 0));
    out["visual_dirty_intents"] = visual_dirty_intents;
    out["retained_gdscript_authority"] = _native_daily_slice_retained_authority;
    out["native_state_snapshot"] = _native_daily_slice_state_snapshot;
    out["authority_report"] = authority_report;
    out["authority_blockers"] = _native_daily_slice_state_snapshot.get("authority_blockers", Array());
    out["retained_boundaries"] = _native_daily_slice_state_snapshot.get("retained_boundaries", Array());
    out["retained_godot_boundaries"] = _native_daily_slice_state_snapshot.get("retained_godot_boundaries", Array());
    out["retained_boundary_policy"] =
        _native_daily_slice_state_snapshot.get("retained_boundary_policy", String());
    out["graph_coverage_complete"] = Array(out["authority_blockers"]).is_empty();
    out["graph_coverage_state"] =
        _native_daily_slice_state_snapshot.get("graph_coverage_state", String("partial"));
    out["boundary_contract"] = _native_daily_slice_bundle.get("native_daily_boundary_contract", Dictionary());
    out["bundle_key_count"] = breakdown["bundle_key_count"];
    out["tick_delta_key_count"] = breakdown["tick_delta_key_count"];
    out["climate_modes"] = breakdown["climate_modes"];
    out["runtime_config_report"] = runtime_config_report;  // perf(Tier1): 共享上面的单次深拷贝
    out["native_daily_active_default_ready"] = active_default_ready;
    out["active_default_blockers"] = out["authority_blockers"];
    out["fallback_mode"] = breakdown["fallback_mode"];
    if (temperature_transport_anomaly_out.size() > 0) {
        out["temperature_transport_anomaly_out"] = temperature_transport_anomaly_out;
    }
    out["breakdown"] = breakdown;
    out["dirty_flags"] = _native_dirty_report.duplicate();
    out["fronts_changed"] = done &&
        (bool(breakdown.get("weather_lut_changed", false)) ||
         int(breakdown.get("fronts_count", 0)) > 0);
    out["fronts"] = _native_fronts_snapshot;
    out["tick_count"] = _native_daily_tick_count;
    // perf(Tier1): _native_daily_report 仅由 get_native_daily_report() 消费，而后者读时还会再做
    // duplicate(true)；生产 native_daily_last_result() 走 GDScript 成员、不读此项，shadow 测试也走
    // run_native_sim_tick 入口而非本切片路径。故此处改浅拷贝：免去每片对 breakdown/native_state_
    // snapshot/authority_report/runtime_config/fronts 整棵树的递归深拷贝；顶层 dict 与返回的 out
    // 隔离（不被上层 GDScript 顶层增键污染），嵌套只读共享、读路径再深拷贝保证隔离。
    _native_daily_report = out.duplicate(false);

    if (done) {
        _native_daily_slice_active = false;
        _native_daily_slice_cell_cursor = 0;
        _native_daily_slice_range_node_index = -1;
    }

    return out;
