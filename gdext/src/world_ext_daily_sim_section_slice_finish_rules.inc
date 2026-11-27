    // Climate authority gate for the sliced production path.
    //
    // Every node in NATIVE_DAILY_SLICE_GRAPH writes a Climate-domain slot, so a
    // promoted Climate domain suppresses the whole graph rather than a subset.
    // Pushing the cursor to the end rather than returning early keeps the slice
    // state machine on its normal path: next_present_node then reports -1, the
    // round is reported done, and the per-round bookkeeping below (progress,
    // published slots, authority report) runs exactly as it does for a real
    // round. Returning early instead would leave the cursor mid-graph and the
    // next tick would resume a round nobody is computing.
    //
    // any_pass_ran is forced true because the caller treats false as "the
    // bundle had no pass knobs" and fails the tick.
    const bool climate_suppressed = climate_main_thread_suppressed();
    // Written unconditionally. The diagnostics bus *merges* breakdowns rather
    // than replacing them, so a key only set while suppressed would survive
    // revocation and report the main thread as still suppressed after it had
    // resumed.
    breakdown["climate_authority_suppressed"] = climate_suppressed;
    if (climate_suppressed) {
        _native_daily_slice_node_index = NATIVE_DAILY_SLICE_GRAPH_SIZE;
        _native_daily_slice_any_pass_ran = true;
        _native_daily_slice_breakdown = breakdown;
    }
    const uint32_t deferred_bits_active = native_daily_deferred_node_bits(_native_daily_slice_bundle);
    int node_index = native_daily_next_present_node(_native_daily_slice_bundle,
                                                    _native_daily_slice_node_index,
                                                    deferred_bits_active);
    if (node_index < 0) {
        if (!_native_daily_slice_any_pass_ran) {
            return finish_with_failure(String("native_daily_bundle"), String("no pass knobs in native_daily_bundle"));
        }
    } else {
        // Batch consecutive present nodes in this single call, stopping right before any
        // node GDScript must JIT-patch (a yield node) or when the round is complete.
        // Bit-equal with one-node-per-call: non-yield nodes receive an empty patch in
        // either scheme, so the bundle state they read is identical.
        const int batch_start_index = node_index;
        while (node_index >= 0) {
            const NativeDailySliceNode &node = NATIVE_DAILY_SLICE_GRAPH[node_index];
            // Reset per-slice range diagnostics before each node. The breakdown dict
            // accumulates across a round, so without this non-range nodes can inherit
            // the previous range node's cursor and make CSV attribution misleading.
            breakdown["node_range_enabled"] = false;
            breakdown["node_range_active"] = false;
            breakdown["node_range_done"] = true;
            breakdown["node_range_budget"] = _native_daily_slice_cell_budget;
            breakdown["node_range_node"] = String();
            breakdown["node_cell_cursor_start"] = -1;
            breakdown["node_cell_cursor_end"] = -1;
            breakdown["node_cell_count"] = 0;
            breakdown["node_cell_processed"] = 0;
            if (!_native_daily_slice_bundle.has(node.bundle_key)) {
                const String node_name = node_name_string(node.name);
                const String node_key = node_key_string(node.bundle_key);
                breakdown["stage_name"] = node_name;
                breakdown["substage"] = node_key;
                breakdown["cursor_start"] = node_index;
                breakdown["cursor_end"] = node_index;
                breakdown["deferred_wait_node"] = node_name;
                breakdown["deferred_wait_key"] = node_key;
                _native_daily_slice_node_index = node_index;
                _native_daily_slice_breakdown = breakdown;
                break;
            }
            bool range_active = false;
            bool range_done = true;
            int range_start = 0;
            int range_end = 0;
            int range_count = 0;
            if (_native_daily_slice_cell_budget > 0 &&
                node_index < 32 &&
                ((_native_daily_slice_range_node_bits >> node_index) & 1u) &&
                native_daily_node_has_builtin_range(node.name)) {
                Dictionary range_knobs = as_dict(_native_daily_slice_bundle[node.bundle_key]);
                range_count = int(range_knobs.get("n_cells", _native_world_cell_count));
                if (range_count > 0) {
                    if (_native_daily_slice_range_node_index != node_index) {
                        _native_daily_slice_range_node_index = node_index;
                        _native_daily_slice_cell_cursor = 0;
                    }
                    range_start = std::max(0, std::min(_native_daily_slice_cell_cursor, range_count));
                    range_end = std::min(range_count, range_start + _native_daily_slice_cell_budget);
                    if (range_end > range_start) {
                        range_done = range_end >= range_count;
                        range_active = true;
                        range_knobs["start_idx"] = range_start;
                        range_knobs["end_idx"] = range_end;
                        range_knobs["defer_flush"] = !range_done;
                        range_knobs["flush_on_end"] = range_done;
                        _native_daily_slice_bundle[node.bundle_key] = range_knobs;
                    }
                }
            }
            const bool ok = exec_slice_node(node);
            if (!ok) {
                _native_daily_slice_breakdown = breakdown;
                String reason;
                const String fail_stage = node_name_string(node.fail_stage);
                if (fail_stage == String("weather") ||
                    fail_stage == String("weather_field") ||
                    fail_stage == String("weather_commit") ||
                    fail_stage == String("weather_distribute") ||
                    fail_stage == String("weather_summary") ||
                    fail_stage == String("weather_cyclone") ||
                    fail_stage == String("weather_stage_b")) {
                    reason = String(breakdown.get("__weather_fail_stage_dyn", "unknown"));
                    breakdown.erase("__weather_fail_stage_dyn");
                } else if (fail_stage == String("runtime_hydrology")) {
                    reason = String(breakdown.get("__hydrology_fail_reason", "pass returned fallback"));
                    breakdown.erase("__hydrology_fail_reason");
                } else {
                    reason = String("pass returned fallback");
                }
                // [DEBUG] 临时诊断：确认哪个节点失败
                // godot::UtilityFunctions::print("[native_daily/FAIL] node=", node_name_string(node.name),
                //     " fail_stage=", fail_stage, " reason=", reason);
                _native_daily_slice_node_index = node_index;
                return finish_with_failure(fail_stage, reason);
            }
            _native_daily_slice_any_pass_ran = true;
            if (range_active) {
                const String node_name = node_name_string(node.name);
                const String node_key = node_key_string(node.bundle_key);
                breakdown["stage_name"] = node_name;
                breakdown["substage"] = node_key;
                breakdown["cursor_start"] = node_index;
                breakdown["cursor_end"] = node_index;
                breakdown["node_range_enabled"] = true;
                breakdown["node_range_active"] = !range_done;
                breakdown["node_range_done"] = range_done;
                breakdown["node_range_budget"] = _native_daily_slice_cell_budget;
                breakdown["node_range_node"] = node_name;
                breakdown["node_cell_cursor_start"] = range_start;
                breakdown["node_cell_cursor_end"] = range_end;
                breakdown["node_cell_count"] = range_count;
                breakdown["node_cell_processed"] = range_end - range_start;
                Dictionary node_report;
                node_report["name"] = node_name;
                node_report["bundle_key"] = node_key;
                node_report["read_mask"] = int64_t(node.read_mask);
                node_report["write_mask"] = int64_t(node.write_mask);
                breakdown["node_report"] = node_report;
                if (!range_done) {
                    _native_daily_slice_cell_cursor = range_end;
                    _native_daily_slice_node_index = node_index;
                    _native_daily_slice_breakdown = breakdown;
                    break;
                }
                _native_daily_slice_cell_cursor = 0;
                _native_daily_slice_range_node_index = -1;
            }
            _native_daily_slice_node_index = node_index + 1;
            const String node_name = node_name_string(node.name);
            const String node_key = node_key_string(node.bundle_key);
            breakdown["last_completed_node"] = node_name;
            breakdown["stage_name"] = node_name;
            breakdown["substage"] = node_key;
            breakdown["cursor_start"] = batch_start_index;
            breakdown["cursor_end"] = node_index + 1;
            breakdown["processed_nodes"] = int(breakdown.get("processed_nodes", 0)) + 1;
            Dictionary node_report;
            node_report["name"] = node_name;
            node_report["bundle_key"] = node_key;
            node_report["read_mask"] = int64_t(node.read_mask);
            node_report["write_mask"] = int64_t(node.write_mask);
            breakdown["node_report"] = node_report;
            _native_daily_slice_breakdown = breakdown;

            const int next = native_daily_next_present_node(_native_daily_slice_bundle,
                                                            _native_daily_slice_node_index,
                                                            deferred_bits_active);
            if (next < 0) {
                break;  // round complete
            }
            if (next < 32 && ((_native_daily_slice_yield_bits >> next) & 1u)) {
                break;  // GDScript must inject a JIT patch before this node
            }
            node_index = next;  // safe to keep running within this call
        }
    }

    const int next_index = native_daily_next_present_node(_native_daily_slice_bundle,
                                                          _native_daily_slice_node_index,
                                                          deferred_bits_active);
    const bool done = next_index < 0;
    // Both flush branches are skipped while Climate is suppressed: the slots
    // still hold the day authority was granted, and either one would overwrite
    // the snapshot the worker fed back into MapData with that stale copy.
    if (done && !climate_suppressed &&
        bool(_native_daily_slice_bundle.get("flush_slots_to_map", true))) {
        const auto t_flush0 = std::chrono::high_resolution_clock::now();
        flush_slots_to_map();
        const auto t_flush1 = std::chrono::high_resolution_clock::now();
        breakdown["render_prepare_ms"] =
            std::chrono::duration<double, std::milli>(t_flush1 - t_flush0).count();
        _native_daily_slice_breakdown = breakdown;
    } else if (done && !climate_suppressed &&
               _native_daily_slice_bundle.has("climate_pass_a_struct")) {
        // Production skips the bulk flush (flush_slots_to_map=false) because each
        // native pass publishes its own slots. Pass-A cannot: it runs deferred, so
        // without this commit its whole slot family — insolation, day length,
        // season offset, runtime baseline, the temperature EMAs and thermal energy —
        // stays frozen at the last non-deferred call and every MapData consumer
        // (sea-ice solar gate, ocean baseline, economy/vegetation sampling, UI)
        // keeps reading day-0 values.
        const auto t_publish0 = std::chrono::high_resolution_clock::now();
        int published = 0;
        for (int i = 0; i < NATIVE_DAILY_PASS_A_DEFERRED_SLOT_COUNT; ++i) {
            const int sid = component_id(StringName(NATIVE_DAILY_PASS_A_DEFERRED_SLOTS[i]));
            if (sid < 0 || sid >= _slots.size()) continue;
            _flush_slot_to_map(sid);
            ++published;
        }
        const auto t_publish1 = std::chrono::high_resolution_clock::now();
        const double publish_ms =
            std::chrono::duration<double, std::milli>(t_publish1 - t_publish0).count();
        breakdown["pass_a_deferred_publish_ms"] = publish_ms;
        breakdown["pass_a_deferred_publish_slots"] = published;
        breakdown["render_prepare_ms"] =
            double(breakdown.get("render_prepare_ms", 0.0)) + publish_ms;
        _native_daily_slice_breakdown = breakdown;
    }

    const auto t1 = std::chrono::high_resolution_clock::now();
    const double slice_ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
