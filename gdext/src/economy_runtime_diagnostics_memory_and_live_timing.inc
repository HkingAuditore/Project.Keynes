    int64_t settlement_memory = 0;
    settlement_memory += static_cast<int64_t>(
        _settlements.tier.capacity() * sizeof(uint8_t) +
        _settlements.name_active.capacity() * sizeof(uint8_t) +
        _settlements.name_forced.capacity() * sizeof(uint8_t) +
        _settlements.prosperity_generation.capacity() * sizeof(uint32_t) +
        _settlements.name_roll_generation.capacity() * sizeof(uint32_t) +
        _settlements.prefix.capacity() * sizeof(int32_t) +
        _settlements.root.capacity() * sizeof(int32_t) +
        _settlements.suffix.capacity() * sizeof(int32_t) +
        _settlements.disambiguator.capacity() * sizeof(uint32_t));
    for (const auto &entry : _settlements.active_names)
        settlement_memory += static_cast<int64_t>(
            sizeof(entry) + entry.first.capacity());
    for (const auto &revision : _settlements.revisions)
        settlement_memory += static_cast<int64_t>(
            sizeof(revision) + revision.changes.capacity() *
                sizeof(SettlementChange));
    out["settlement_memory_bytes"] = settlement_memory;
    out["publish_ms"] = _publish_ms;
    out["publish_commit_cells_ms"] = _publish_commit_cells_ms;
    out["publish_commit_prepare_ms"] = _publish_commit_prepare_ms;
    out["publish_commit_finalize_ms"] = _publish_commit_finalize_ms;
    const CountryClassOpinionSnapshot &class_opinion =
        country_class_opinion_snapshot();
    out["class_opinion_revision"] =
        static_cast<int64_t>(class_opinion.revision);
    // P3-B: readers that found the epoch tag snapshot unbuilt. The snapshot is now
    // built at commit, so this must stay 0 on any world that has committed once; a
    // non-zero value means a reader is running before the first commit (or the
    // rebuild was skipped), which used to be invisible.
    out["tag_snapshot_miss_count"] = last_tag_snapshot_miss_count();
    // M4: the number that decides whether "per-tag changed words" is worth
    // building. A full rebuild that costs microseconds makes an incremental
    // update pure overhead.
    out["tag_snapshot_build_ms"] = last_tag_snapshot_build_ms();
    out["tag_snapshot_build_count"] = tag_snapshot_build_count();
    // `cells x tags` is the cost of this rebuild. Splitting declared from ACTIVE shows
    // how much of the sweep was spent on tags that cannot match.
    out["tag_declared_tags"] = tag_declared_tag_count();
    out["tag_active_tags"] = tag_active_tag_count();
    out["tag_consumed_tags"] = tag_consumed_tag_count();
    out["tag_snapshot_sampled_cells"] =
        _tag_snapshot_sampled_cells.load(std::memory_order_relaxed);
    out["tag_snapshot_requested_metrics"] =
        _tag_snapshot_requested_metrics.load(std::memory_order_relaxed);
    out["tag_catalog_metrics"] =
        _tag_catalog_metrics.load(std::memory_order_relaxed);
    // R-3b (item 4): every `tag_snapshot()` load in the epoch. A tag selector that
    // loads once per SCAN keeps this proportional to the number of scans; the pre-fix
    // shape called it once per CELL, so a 6400-cell country cost 6400 loads per query.
    out["tag_snapshot_loads"] = tag_snapshot_loads();
    // R-3b: proof that an epoch nobody reads costs nothing. `tag_snapshot_builds`
    // rises only when a consumer declared tags or metric 67; `tag_snapshot_skips`
    // rises once per epoch where both halves were skipped. A world whose catalog
    // declares neither must show builds == 0 and skips == committed epochs.
    out["tag_snapshot_builds"] = static_cast<int64_t>(tag_snapshot_builds());
    out["tag_snapshot_skips"] = static_cast<int64_t>(tag_snapshot_skips());
    out["geo_flags_rebuilds"] = static_cast<int64_t>(geo_flags_rebuilds());
    out["family_cell_metric_rebuilds"] =
        static_cast<int64_t>(family_cell_metric_rebuilds());
    out["family_country_metric_rebuilds"] =
        static_cast<int64_t>(family_country_metric_rebuilds());
    out["class_metric_rebuilds"] = static_cast<int64_t>(class_metric_rebuilds());
    out["technology_metric_rebuilds"] =
        static_cast<int64_t>(technology_metric_rebuilds());
    out["technology_metric_source_hash"] =
        static_cast<int64_t>(technology_metric_source_hash());
    out["neighbor_distinct_goods_rebuilds"] =
        static_cast<int64_t>(_neighbor_distinct_goods_rebuilds.load(
            std::memory_order_relaxed));
    out["neighbor_distinct_goods_source_hash"] =
        static_cast<int64_t>(neighbor_distinct_goods_source_hash());
    out["technology_metric_domain_mask_count"] =
        static_cast<int64_t>(_technology_domain_masks.size());
    out["technology_metric_domain_count"] =
        static_cast<int64_t>(_technology_domain_ids.size());
    out["technology_metric_input_override"] =
        _technology_metric_input_override_enabled;
    PackedInt32Array technology_domain_ids;
    for (const int32_t domain : _technology_domain_ids)
        technology_domain_ids.append(domain);
    out["technology_metric_domain_ids"] = technology_domain_ids;
    PackedInt64Array technology_domain_masks;
    for (const uint64_t mask : _technology_domain_masks)
        technology_domain_masks.append(static_cast<int64_t>(mask));
    out["technology_metric_domain_masks"] = technology_domain_masks;
    out["class_metric_source_revision"] =
        static_cast<int64_t>(_class_metric_source_revision);
    out["class_metric_source_content_hash"] =
        static_cast<int64_t>(_class_metric_source_content_hash);
    out["class_metric_source_epoch_day"] = _class_metric_source_epoch_day;
    out["class_metric_country_count"] =
        static_cast<int64_t>(_epoch_country_weighted_satisfaction_q16.size());
    PackedInt64Array class_metric_satisfaction;
    PackedInt64Array class_metric_weighted_satisfaction;
    PackedInt64Array class_metric_farmer_satisfaction;
    for (const int64_t value : _epoch_country_class_satisfaction_q16)
        class_metric_satisfaction.append(value);
    for (const int64_t value : _epoch_country_weighted_satisfaction_q16)
        class_metric_weighted_satisfaction.append(value);
    for (const int64_t value : _epoch_country_farmer_satisfaction_q16)
        class_metric_farmer_satisfaction.append(value);
    out["class_metric_satisfaction_q16"] = class_metric_satisfaction;
    out["class_metric_weighted_satisfaction_q16"] =
        class_metric_weighted_satisfaction;
    out["class_metric_farmer_satisfaction_q16"] =
        class_metric_farmer_satisfaction;
    out["tag_snapshot_needed"] = tag_snapshot_needed();
    out["tag_bits_needed"] = tag_bits_needed();
    out["specialized_good_count_needed"] = specialized_good_count_needed();
    // Must stay 0: a non-zero value means `set_target_tags` ran outside the config
    // phase without the boundary lock (see the log line it also emits).
    out["tag_snapshot_concurrent_writes"] =
        static_cast<int64_t>(tag_snapshot_concurrent_writes());
    out["class_opinion_class_hash"] =
        static_cast<int64_t>(class_opinion.class_hash);
    out["class_opinion_country_count"] = class_opinion.country_count;
    out["class_opinion_class_count"] = class_opinion.class_count;
    out["class_opinion_cells"] =
        static_cast<int64_t>(_class_opinion_cells_scanned);
    out["class_opinion_slots_scanned"] =
        static_cast<int64_t>(_class_opinion_slots_scanned);
    out["class_opinion_zero_population_rows"] =
        static_cast<int64_t>(_class_opinion_zero_population_rows);
    out["class_opinion_last_cells_scanned"] =
        static_cast<int64_t>(_last_class_opinion_cells_scanned);
    out["class_opinion_last_slots_scanned"] =
        static_cast<int64_t>(_last_class_opinion_slots_scanned);
    out["class_opinion_last_zero_population_rows"] =
        static_cast<int64_t>(_last_class_opinion_zero_population_rows);
    out["class_opinion_ms"] = _class_opinion_ms;
    Dictionary publish_breakdown_ms;
    Dictionary publish_breakdown_work;
    Dictionary publish_cumulative_breakdown_ms;
    Dictionary publish_cumulative_breakdown_work;
    for (size_t phase = 0; phase < static_cast<size_t>(PublishPhase::COUNT); ++phase) {
        const std::string key = std::string("aggregate_publish.") +
            publish_phase_name(static_cast<PublishPhase>(phase));
        publish_breakdown_ms[key.c_str()] = _publish_slice_phase_ms[phase];
        publish_breakdown_work[key.c_str()] = _publish_slice_phase_work[phase];
        publish_cumulative_breakdown_ms[key.c_str()] = _publish_phase_ms[phase];
        publish_cumulative_breakdown_work[key.c_str()] = _publish_phase_work[phase];
    }
    publish_breakdown_ms["aggregate_publish.class_opinion"] =
        _class_opinion_ms;
    publish_breakdown_work["aggregate_publish.class_opinion"] =
        static_cast<int64_t>(_last_class_opinion_slots_scanned);
    const size_t trade_init_phase = static_cast<size_t>(PublishPhase::TRADE_INIT);
    if (_publish_slice_phase_ms[trade_init_phase] > 0.0 &&
        _executed_substage.rfind("trade_init.", 0) == 0) {
        const std::string detailed_key = std::string("aggregate_publish.") +
            _executed_substage;
        publish_breakdown_ms[detailed_key.c_str()] =
            _publish_slice_phase_ms[trade_init_phase];
        publish_breakdown_work[detailed_key.c_str()] =
            _publish_slice_phase_work[trade_init_phase];
        publish_breakdown_ms["aggregate_publish.trade_init"] = 0.0;
        publish_breakdown_work["aggregate_publish.trade_init"] = 0;
    }
    publish_breakdown_ms["aggregate_publish.commit_cells"] =
        _publish_commit_cells_slice_ms;
    publish_breakdown_ms["aggregate_publish.commit_prepare"] =
        _publish_commit_prepare_slice_ms;
    publish_breakdown_ms["aggregate_publish.commit_finalize"] =
        _publish_commit_finalize_slice_ms;
    publish_breakdown_work["aggregate_publish.commit_cells"] =
        _publish_slice_phase_work[static_cast<size_t>(PublishPhase::COMMIT)];
    publish_breakdown_work["aggregate_publish.commit_prepare"] =
        _publish_commit_prepare_slice_ms > 0.0 ? 1 : 0;
    publish_breakdown_work["aggregate_publish.commit_finalize"] =
        _publish_commit_finalize_slice_ms > 0.0 ? 1 : 0;
    out["publish_breakdown_ms"] = publish_breakdown_ms;
    out["publish_breakdown_work"] = publish_breakdown_work;
    out["publish_cumulative_breakdown_ms"] = publish_cumulative_breakdown_ms;
    out["publish_cumulative_breakdown_work"] = publish_cumulative_breakdown_work;
    out["household_market_breakdown_ms"] =
        household_slice_breakdown_ms();
    out["household_market_breakdown_work"] =
        household_slice_breakdown_work();
    static constexpr const char *BUILDING_COMMIT_PHASE_NAMES[
        BUILDING_COMMIT_PHASE_COUNT] = {
        "review_prepare", "special_reset", "recovery_review",
        "construction_commit", "investment_prepare", "investment",
        "finalize",
    };
    Dictionary building_commit_breakdown_ms;
    Dictionary building_commit_breakdown_work;
    for (size_t phase = 0; phase < BUILDING_COMMIT_PHASE_COUNT; ++phase) {
        const std::string key = std::string("building_commit.") +
            BUILDING_COMMIT_PHASE_NAMES[phase];
        building_commit_breakdown_ms[key.c_str()] =
            _building_commit_slice_phase_ms[phase];
        building_commit_breakdown_work[key.c_str()] =
            _building_commit_slice_phase_work[phase];
    }
    out["building_commit_breakdown_ms"] = building_commit_breakdown_ms;
    out["building_commit_breakdown_work"] = building_commit_breakdown_work;
    out["building_employment_ms"] = _employment_ms;
    out["building_production_ms"] = _production_ms;
    out["building_production_merge_ms"] = _production_merge_ms;
    out["building_production_worker_ms"] = _production_worker_ms;
    out["household_market_worker_ms"] = _market_worker_ms;
    out["household_market_prepare_ms"] = _household_market_prepare_ms;
    out["household_market_merge_ms"] = _market_merge_ms;
    out["household_market_merge_aggregate_ms"] = _market_merge_aggregate_ms;
    out["household_market_merge_trade_ms"] = _market_merge_trade_ms;
    write_workset_probe_report(out);
    out["economy_live_cells"] = static_cast<int32_t>(_economy_live_cells.size());
    out["market_result_allocation_growth_count"] =
        _market_result_allocation_growth_count;
    out["market_result_allocation_growth_bytes"] =
        _market_result_allocation_growth_bytes;
    out["production_result_allocation_growth_count"] =
        _production_result_allocation_growth_count;
    out["production_result_allocation_growth_bytes"] =
        _production_result_allocation_growth_bytes;
    out["building_plan_ms"] = _building_plan_ms;
    out["building_plan_evaluate_ms"] = _building_plan_evaluate_ms;
    out["building_plan_reserve_ms"] = _building_plan_reserve_ms;
    out["building_structure_count_only_updates"] =
        _building_structure_count_only_updates;
    out["building_structure_new_groups"] = _building_structure_new_groups;
    out["building_structure_removed_groups"] =
        _building_structure_removed_groups;
    out["building_structure_topology_rebuilds"] =
        _building_structure_topology_rebuilds;
    out["building_structure_role_span_reuses"] =
        _building_structure_role_span_reuses;
    out["building_structure_role_span_appends"] =
        _building_structure_role_span_appends;
    out["building_structure_group_merge_ms"] =
        _building_structure_group_merge_ms;
    out["building_structure_market_cache_ms"] =
        _building_structure_market_cache_ms;
    out["building_structure_labor_cache_ms"] =
        _building_structure_labor_cache_ms;
    out["market_signal_lookup_mode"] =
        _market_signals.dense_index.empty() ? "csr" : "dense";
    out["market_signal_lookup_entries"] = static_cast<int64_t>(
        _market_signals.dense_index.size());
    out["pending_construction_index_entries"] = static_cast<int64_t>(
        _pending_construction_cell_indices.size());
    out["building_investment_ms"] = _investment_ms;
    out["investment_evaluate_ms"] = _investment_evaluate_ms;
    out["investment_allocate_ms"] = _investment_allocate_ms;
    out["working_capital_scale_error_bound_q16"] =
        _working_capital_scale_error_bound_q16;
    out["market_signal_ms"] = _market_signal_ms;
    out["market_signal_insert_ms"] = _market_signal_insert_ms;
    out["market_signal_flush_ms"] = _market_signal_flush_ms;
    out["market_signal_insert_count"] = _market_signal_insert_count;
    out["wage_plan_ms"] = _wage_plan_ms;
    out["labor_signal_ms"] = _labor_signal_ms;
    out["trade_plan_ms"] = _trade_plan_ms;
    const double trade_plan_accounted_ms = _trade_plan_scan_body_ms +
        _trade_plan_scan_finalize_ms + _trade_plan_route_prepare_ms +
        _trade_plan_route_expand_ms + _trade_plan_route_finalize_ms;
    Dictionary trade_plan_breakdown_ms;
    trade_plan_breakdown_ms["trade_planning.scan_body"] = _trade_plan_scan_body_ms;
    trade_plan_breakdown_ms["trade_planning.scan_finalize"] =
        _trade_plan_scan_finalize_ms;
    trade_plan_breakdown_ms["trade_planning.route_prepare"] =
        _trade_plan_route_prepare_ms;
    trade_plan_breakdown_ms["trade_planning.route_expand"] =
        _trade_plan_route_expand_ms;
    trade_plan_breakdown_ms["trade_planning.route_finalize"] =
        _trade_plan_route_finalize_ms;
    trade_plan_breakdown_ms["trade_planning.other"] =
        std::max(0.0, _trade_plan_ms - trade_plan_accounted_ms);
    out["trade_plan_breakdown_ms"] = trade_plan_breakdown_ms;
    Dictionary trade_plan_breakdown_work;
    trade_plan_breakdown_work["trade_planning.scan_pairs"] =
        _trade_plan_scan_pairs_slice;
    trade_plan_breakdown_work["trade_planning.route_sources_prepared"] =
        _trade_plan_route_sources_prepared_slice;
    trade_plan_breakdown_work["trade_planning.route_expansions"] =
        _trade_plan_route_expansions_slice;
    trade_plan_breakdown_work["trade_planning.candidates_finalized"] =
        _trade_plan_candidates_finalized_slice;
    out["trade_plan_breakdown_work"] = trade_plan_breakdown_work;
    const char *trade_plan_substage = "";
    double trade_plan_substage_ms = 0.0;
    auto choose_trade_plan_substage = [&](const char *name, double value) {
        if (value > trade_plan_substage_ms) {
            trade_plan_substage = name;
            trade_plan_substage_ms = value;
        }
    };
    choose_trade_plan_substage("scan_body", _trade_plan_scan_body_ms);
    choose_trade_plan_substage("scan_finalize", _trade_plan_scan_finalize_ms);
    choose_trade_plan_substage("route_prepare", _trade_plan_route_prepare_ms);
    choose_trade_plan_substage("route_expand", _trade_plan_route_expand_ms);
    choose_trade_plan_substage("route_finalize", _trade_plan_route_finalize_ms);
    choose_trade_plan_substage("other",
        std::max(0.0, _trade_plan_ms - trade_plan_accounted_ms));
    out["trade_plan_substage"] = trade_plan_substage;
    if (_executed_substage.empty() && _executed_stage == Stage::TRADE_PLANNING)
        out["executed_substage"] = trade_plan_substage;
    out["trade_settle_ms"] = _trade_settle_ms;
    out["trade_dispatch_ms"] = _trade_dispatch_ms;
    out["epoch_begin_ms"] = _epoch_begin_ms;
    out["epoch_begin_reset_ms"] = _epoch_begin_reset_ms;
    out["epoch_begin_country_ms"] = _epoch_begin_country_ms;
    out["epoch_begin_city_factor_ms"] = _epoch_begin_city_factor_ms;
    // Shard diagnostics (plan §14.3). `city_factor_shard_cursor` >= 0 means the
    // reader yielded mid-work-set and another slice is required; a test that
    // only sees a total millisecond figure cannot tell "finished in one slice"
    // from "gave up after 64 cells".
    out["city_factor_shard_cursor"] = _city_factor_shard_cursor;
    out["city_factor_shard_cells"] = CITY_FACTOR_SHARD_CELLS;
    out["city_factor_work_cells"] = _city_factor_work_cells;
    // Cells ACTUALLY processed by the last pass. `city_factor_work_cells` above
    // only moves when collect runs, so on a version-gate short-circuit it keeps
    // reporting the previous pass's size -- which is how a "2000 cells in
    // 0.003 ms" reading appeared (M2-10). Comparing the two distinguishes
    // "finished the work set" from "skipped it".
    out["city_factor_cells_processed"] = _city_factor_cells_processed;
    out["city_factor_collected_cells"] = _city_factor_collected_cells;
    // The number §14.3 needs: total time and total work for the WHOLE build,
    // summed over every shard call. `epoch_begin_city_factor_ms` above measures a
    // single call, which for a multi-shard build is the small remainder -- that is
    // why a 2000-cell work set read as "16 cells, 0.002 ms" (M2-11).
    out["city_factor_epoch_ms"] = _city_factor_epoch_ms;
    out["city_factor_epoch_slices"] = _city_factor_epoch_slices;
    out["city_factor_epoch_cells"] = _city_factor_epoch_cells;
    out["epoch_begin_building_factor_ms"] = _epoch_begin_building_factor_ms;
    static constexpr const char *SCAN_STAGE_NAMES[SCAN_STAGE_SLOTS] = {
        "idle", "epoch_begin", "ledger_apply", "household_market",
        "structural_commit", "wait_commit", "building_employment",
        "building_production", "building_commit", "aggregate_publish",
        "fatal", "trade_settle", "trade_dispatch", "trade_planning",
        "building_plan", "government_research_procurement", "family_commit",
        "person_commit",
    };
    for (size_t i = 0; i < SCAN_STAGE_SLOTS; ++i)
        out[(std::string("scan_steps_stage_") + SCAN_STAGE_NAMES[i]).c_str()] =
            _scan_steps_by_stage[i];
    out["scan_steps_find_building_group"] = _scan_steps_find_building_group;
    out["scan_steps_find_signature"] = _scan_steps_find_signature;
    out["scan_steps_membership_fallback"] = _scan_steps_membership_fallback;
    out["scan_steps_person_linear"] = _scan_steps_person_linear;
    out["scan_steps_family_linear"] = _scan_steps_family_linear;
    out["scan_calls_find_building_group"] = _scan_calls_find_building_group;
    out["scan_calls_find_signature"] = _scan_calls_find_signature;
    out["scan_calls_membership_fallback"] = _scan_calls_membership_fallback;
    out["family_commit_normalize_ms"] = _family_commit_normalize_ms;
    out["family_commit_attribution_ms"] = _family_commit_attribution_ms;
    out["family_commit_form_ms"] = _family_commit_form_ms;
    out["family_commit_index_ms"] = _family_commit_index_ms;
    out["family_commit_lifecycle_ms"] = _family_commit_lifecycle_ms;
    out["family_commit_influence_ms"] = _family_commit_influence_ms;
    out["rebuild_family_membership_ms"] = _rebuild_family_membership_ms;
    out["rebuild_family_ownership_ms"] = _rebuild_family_ownership_ms;
    out["rebuild_family_csr_ms"] = _rebuild_family_csr_ms;
    out["rebuild_family_cellindex_ms"] = _rebuild_family_cellindex_ms;
    out["rebuild_person_needs_ms"] = _rebuild_person_needs_ms;
    out["rebuild_person_count_ms"] = _rebuild_person_count_ms;
    out["rebuild_person_fill_ms"] = _rebuild_person_fill_ms;
    out["rebuild_person_sort_ms"] = _rebuild_person_sort_ms;
    out["rebuild_person_needoffsets_ms"] = _rebuild_person_needoffsets_ms;
    out["person_retire_call_ms"] = _person_retire_call_ms;
    out["person_retire_calls"] = _person_retire_calls;
    out["person_commit_retire_ms"] = _person_commit_retire_ms;
    out["person_commit_index_ms"] = _person_commit_index_ms;
    out["person_commit_bind_jobs_ms"] = _person_commit_bind_jobs_ms;
    out["person_commit_claims_ms"] = _person_commit_claims_ms;
    out["person_commit_equity_ms"] = _person_commit_equity_ms;
    out["person_commit_promote_ms"] = _person_commit_promote_ms;
    out["epoch_begin_workset_ms"] = _epoch_begin_workset_ms;
    out["epoch_begin_resource_lane_ms"] = _epoch_begin_resource_lane_ms;
    out["epoch_begin_fiscal_ms"] = _epoch_begin_fiscal_ms;
    out["epoch_begin_construction_csr_ms"] = _epoch_begin_construction_csr_ms;
    out["epoch_begin_recovery_apply_ms"] = _epoch_begin_recovery_apply_ms;
    out["epoch_begin_vector_init_ms"] = _epoch_begin_vector_init_ms;
    out["epoch_begin_audit_lane_ms"] = _epoch_begin_audit_lane_ms;
    out["epoch_begin_commands_ms"] = _epoch_begin_commands_ms;
    out["epoch_preflight_ms"] = _epoch_preflight_ms;
    out["prepare_ms"] = _prepare_ms;
    out["audit_ms"] = _audit_ms;
    out["watermark_ms"] = _watermark_ms;
    out["event_summary_ms"] = _event_summary_ms;
    out["event_detail_ms"] = _event_detail_ms;
    out["event_publish_ms"] = _event_publish_ms;
    out["event_stream_hash"] = static_cast<int64_t>(_event_stream_hash.get());
    out["economy_event_newest_id"] = _next_event_id.get() - 1;
    out["economy_event_last_batch_count"] = _committed_event_batches.empty() ? 0 :
        static_cast<int64_t>(_committed_event_batches.back().events.size());
    out["economy_trace_memory_bytes"] = trace_memory_bytes();
    out["economy_trace_detail_truncated"] = _trace_detail_truncated;
    out["worker_tasks"] = _worker_tasks;
    out["high_speed_batching_enabled"] = _high_speed_batching_enabled;
    out["high_speed_batch_multiplier"] = _active_batch_multiplier;
     out["high_speed_market_dispatches_saved"] =
        _high_speed_market_dispatches_saved;
    out["high_speed_production_dispatches_saved"] =
        _high_speed_production_dispatches_saved;
    out["building_production_worker_tasks"] = _production_worker_tasks;
    out["market_worker_tasks_max"] = _market_worker_tasks_max;
    out["market_worker_task_sum"] = _market_worker_task_sum;
    out["market_worker_dispatches"] = _market_worker_dispatches;
    out["market_worker_parallel_dispatches"] =
        _market_worker_parallel_dispatches;
    out["building_production_worker_tasks_max"] =
        _production_worker_tasks_max;
    out["building_production_worker_task_sum"] =
        _production_worker_task_sum;
    out["building_production_worker_dispatches"] =
        _production_worker_dispatches;
    out["building_production_worker_parallel_dispatches"] =
        _production_worker_parallel_dispatches;
    out["building_production_worker_weight_total"] =
        _production_worker_weight_total;
    out["building_production_worker_task_weight_min"] =
        _production_worker_task_weight_min;
    out["building_production_worker_task_weight_max"] =
        _production_worker_task_weight_max;
    out["building_production_worker_imbalance_q16_max"] =
        _production_worker_imbalance_q16_max;
    out["building_production_worker_cpu_ms"] =
        _production_worker_cpu_ms;
    out["audit_worker_tasks_max"] = _audit_worker_tasks_max;
    out["audit_worker_dispatches"] = _audit_worker_dispatches;
    out["audit_worker_cpu_ms"] = _audit_worker_cpu_ms;
    out["building_plan_worker_tasks_max"] =
        _building_plan_worker_tasks_max;
    out["building_plan_worker_parallel_dispatches"] =
        _building_plan_worker_parallel_dispatches;
    out["building_plan_worker_cpu_ms"] =
        _building_plan_worker_cpu_ms;
    out["opening_audit_fast_paths"] = _opening_audit_fast_paths;
    out["opening_audit_full_verifications"] =
        _opening_audit_full_verifications;
    out["closing_audit_mode"] = _closing_audit_mode == 0 ? "FULL" :
        (_closing_audit_mode == 1 ? "PROBE" : "INCREMENTAL");
