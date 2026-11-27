    out["last_completed_price_min_tick_hits"] = _last_completed_perf.price_min_tick_hits;
    out["last_completed_price_glut_cost_damp_hits"] = _last_completed_perf.price_glut_cost_damp_hits;
    out["last_completed_small_payment_roundups"] = _last_completed_perf.small_payment_roundups;
    out["last_completed_price_ms"] = _last_completed_perf.price_ms;
    out["last_completed_perf_valid"] = _last_completed_perf.valid;
    out["last_completed_epoch_id"] = _last_completed_perf.epoch_id;
    out["last_completed_sample_day"] = _last_completed_perf.sample_day;
    out["last_completed_continuation_slices"] =
        _last_completed_perf.continuation_slices;
    out["last_completed_market_worker_tasks_max"] =
        _last_completed_perf.market_worker_tasks_max;
    out["last_completed_market_worker_task_sum"] =
        _last_completed_perf.market_worker_task_sum;
    out["last_completed_market_worker_dispatches"] =
        _last_completed_perf.market_worker_dispatches;
    out["last_completed_market_worker_parallel_dispatches"] =
        _last_completed_perf.market_worker_parallel_dispatches;
    out["last_completed_building_production_worker_tasks_max"] =
        _last_completed_perf.production_worker_tasks_max;
    out["last_completed_building_production_worker_task_sum"] =
        _last_completed_perf.production_worker_task_sum;
    out["last_completed_building_production_worker_dispatches"] =
        _last_completed_perf.production_worker_dispatches;
    out["last_completed_building_production_worker_parallel_dispatches"] =
        _last_completed_perf.production_worker_parallel_dispatches;
    out["last_completed_building_production_worker_weight_total"] =
        _last_completed_perf.production_worker_weight_total;
    out["last_completed_building_production_worker_task_weight_min"] =
        _last_completed_perf.production_worker_task_weight_min;
    out["last_completed_building_production_worker_task_weight_max"] =
        _last_completed_perf.production_worker_task_weight_max;
    out["last_completed_building_production_worker_imbalance_q16_max"] =
        _last_completed_perf.production_worker_imbalance_q16_max;
    out["last_completed_building_production_worker_cpu_ms"] =
        _last_completed_perf.production_worker_cpu_ms;
    out["last_completed_audit_worker_tasks_max"] =
        _last_completed_perf.audit_worker_tasks_max;
    out["last_completed_audit_worker_dispatches"] =
        _last_completed_perf.audit_worker_dispatches;
    out["last_completed_audit_worker_cpu_ms"] =
        _last_completed_perf.audit_worker_cpu_ms;
    out["last_completed_building_plan_worker_tasks_max"] =
        _last_completed_perf.building_plan_worker_tasks_max;
    out["last_completed_building_plan_worker_parallel_dispatches"] =
        _last_completed_perf.building_plan_worker_parallel_dispatches;
    out["last_completed_building_plan_worker_cpu_ms"] =
        _last_completed_perf.building_plan_worker_cpu_ms;
    out["last_completed_opening_audit_fast_paths"] =
        _last_completed_perf.opening_audit_fast_paths;
    out["last_completed_opening_audit_full_verifications"] =
        _last_completed_perf.opening_audit_full_verifications;
    out["last_completed_closing_audit_fast_paths"] =
        _last_completed_perf.closing_audit_fast_paths;
    out["last_completed_closing_audit_full_verifications"] =
        _last_completed_perf.closing_audit_full_verifications;
    out["last_completed_closing_audit_mismatches"] =
        _last_completed_perf.closing_audit_mismatches;
    out["last_completed_closing_audit_mismatch_ledger"] =
        _last_completed_perf.closing_audit_mismatch_ledger.c_str();
    out["last_completed_closing_audit_mismatch_lane"] =
        _last_completed_perf.closing_audit_mismatch_lane;
    out["last_completed_closing_audit_population_touched_lanes"] =
        _last_completed_perf.closing_audit_population_touched_lanes;
    out["last_completed_closing_audit_market_touched_lanes"] =
        _last_completed_perf.closing_audit_market_touched_lanes;
    out["last_completed_closing_audit_population_full_scan_entries"] =
        _last_completed_perf.closing_audit_population_full_scan_entries;
    out["last_completed_closing_audit_market_full_scan_entries"] =
        _last_completed_perf.closing_audit_market_full_scan_entries;
    out["last_completed_investment_scheduled_review_cells"] =
        _last_completed_perf.investment_scheduled_review_cells;
    out["last_completed_investment_review_cells"] =
        _last_completed_perf.investment_review_cells;
    out["last_completed_investment_type_evaluations"] =
        _last_completed_perf.investment_type_evaluations;
    out["last_completed_investment_market_signal_rejections"] =
        _last_completed_perf.investment_market_signal_rejections;
    out["last_completed_investment_ethnicity_evaluations"] =
        _last_completed_perf.investment_ethnicity_evaluations;
    out["last_completed_investment_sparse_considered_types"] =
        _last_completed_perf.investment_sparse_considered_types;
    out["last_completed_investment_sparse_selected_types"] =
        _last_completed_perf.investment_sparse_selected_types;
    out["last_completed_investment_sparse_skipped_types"] =
        _last_completed_perf.investment_sparse_skipped_types;
    out["last_completed_investment_sparse_mismatches"] =
        _last_completed_perf.investment_sparse_mismatches;
    out["last_completed_investment_sparse_dense_fallbacks"] =
        _last_completed_perf.investment_sparse_dense_fallbacks;
    out["last_completed_investment_displacement_type_evaluations"] =
        _last_completed_perf.investment_displacement_type_evaluations;
    out["last_completed_building_investment_displacement_starts"] =
        _last_completed_perf.building_investment_displacement_starts;
    out["last_completed_approximation_decisions"] =
        _last_completed_perf.approximation_decisions;
    out["last_completed_approximation_exact_probes"] =
        _last_completed_perf.approximation_exact_probes;
    out["last_completed_approximation_certificate_failures"] =
        _last_completed_perf.approximation_certificate_failures;
    out["last_completed_approximation_exact_fallbacks"] =
        _last_completed_perf.approximation_exact_fallbacks;
    out["last_completed_approximation_frontier_candidates"] =
        _last_completed_perf.approximation_frontier_candidates;
    out["last_completed_approximation_frontier_pruned"] =
        _last_completed_perf.approximation_frontier_pruned;
    out["last_completed_approximation_max_observed_regret_q16"] =
        _last_completed_perf.approximation_max_observed_regret_q16;
    out["last_completed_approximation_probe_violations"] =
        _last_completed_perf.approximation_probe_violations;
    out["last_completed_approximation_probe_max_spend_error_q16"] =
        _last_completed_perf.approximation_probe_max_spend_error_q16;
    out["last_completed_approximation_probe_max_demand_error_q16"] =
        _last_completed_perf.approximation_probe_max_demand_error_q16;
    out["last_completed_approximation_cooldown_epochs_left"] =
        _last_completed_perf.approximation_cooldown_epochs_left;
    out["last_completed_high_speed_batch_multiplier"] =
        _last_completed_perf.high_speed_batch_multiplier;
    out["last_completed_high_speed_market_dispatches_saved"] =
        _last_completed_perf.high_speed_market_dispatches_saved;
    out["last_completed_high_speed_production_dispatches_saved"] =
        _last_completed_perf.high_speed_production_dispatches_saved;
    out["last_completed_budgeted_building_commit_phase_fusions"] =
        _last_completed_perf.budgeted_building_commit_phase_fusions;
    out["last_completed_budgeted_publish_phase_fusions"] =
        _last_completed_perf.budgeted_publish_phase_fusions;
    out["last_completed_building_plan_ms"] =
        _last_completed_perf.building_plan_ms;
    out["last_completed_building_plan_evaluate_ms"] =
        _last_completed_perf.building_plan_evaluate_ms;
    out["last_completed_building_plan_reserve_ms"] =
        _last_completed_perf.building_plan_reserve_ms;
    out["last_completed_building_employment_ms"] =
        _last_completed_perf.building_employment_ms;
    out["last_completed_building_production_ms"] =
        _last_completed_perf.building_production_ms;
    out["last_completed_building_production_worker_ms"] =
        _last_completed_perf.building_production_worker_ms;
    out["last_completed_building_production_merge_ms"] =
        _last_completed_perf.building_production_merge_ms;
    out["last_completed_household_market_worker_ms"] =
        _last_completed_perf.household_market_worker_ms;
    out["last_completed_household_market_prepare_ms"] =
        _last_completed_perf.household_market_prepare_ms;
    out["last_completed_household_market_merge_ms"] =
        _last_completed_perf.household_market_merge_ms;
    out["last_completed_household_market_merge_aggregate_ms"] =
        _last_completed_perf.household_market_merge_aggregate_ms;
    out["last_completed_household_market_merge_trade_ms"] =
        _last_completed_perf.household_market_merge_trade_ms;
    out["last_completed_prepare_reuse_count"] =
        _last_completed_perf.prepare_reuse_count;
    out["last_completed_workset_cells_planned"] =
        _last_completed_perf.workset_cells_planned;
    out["last_completed_workset_cells_executed"] =
        _last_completed_perf.workset_cells_executed;
    out["last_completed_duplicate_range_count"] =
        _last_completed_perf.duplicate_range_count;
    out["last_completed_building_investment_ms"] =
        _last_completed_perf.building_investment_ms;
    out["last_completed_investment_evaluate_ms"] =
        _last_completed_perf.investment_evaluate_ms;
    out["last_completed_investment_allocate_ms"] =
        _last_completed_perf.investment_allocate_ms;
    out["last_completed_investment_prepare_lanes_ms"] =
        _last_completed_perf.investment_prepare_lanes_ms;
    out["last_completed_investment_prepare_pending_ms"] =
        _last_completed_perf.investment_prepare_pending_ms;
    out["last_completed_investment_prepare_groups_ms"] =
        _last_completed_perf.investment_prepare_groups_ms;
    out["last_completed_startup_demand_prepare_ms"] =
        _last_completed_perf.startup_demand_prepare_ms;
    out["last_completed_startup_demand_seed_count"] =
        _last_completed_perf.startup_demand_seed_count;
    out["last_completed_startup_demand_touched_lanes"] =
        _last_completed_perf.startup_demand_touched_lanes;
    out["last_completed_startup_demand_catalog_edges"] =
        _last_completed_perf.startup_demand_catalog_edges;
    out["last_completed_startup_demand_cycle_skips"] =
        _last_completed_perf.startup_demand_cycle_skips;
    out["last_completed_startup_demand_remote_lanes"] =
        _last_completed_perf.startup_demand_remote_lanes;
    out["last_completed_startup_demand_matched_review_cells"] =
        _last_completed_perf.startup_demand_matched_review_cells;
    out["last_completed_startup_demand_buildings_started"] =
        _last_completed_perf.startup_demand_buildings_started;
    out["last_completed_startup_demand_scratch_bytes"] =
        _last_completed_perf.startup_demand_scratch_bytes;
    out["last_completed_finalize_construction_ms"] =
        _last_completed_perf.finalize_construction_ms;
    out["last_completed_finalize_reconcile_ms"] =
        _last_completed_perf.finalize_reconcile_ms;
    out["last_completed_building_factor_refresh_ms"] =
        _last_completed_perf.building_factor_refresh_ms;
    out["last_completed_building_role_storage_ms"] =
        _last_completed_perf.building_role_storage_ms;
    out["last_completed_building_factor_cache_hits"] =
        _last_completed_perf.building_factor_cache_hits;
    out["last_completed_building_factor_cache_misses"] =
        _last_completed_perf.building_factor_cache_misses;
    out["last_completed_building_factor_miss_modver"] =
        _last_completed_perf.building_factor_miss_modver;
    out["last_completed_building_factor_miss_country"] =
        _last_completed_perf.building_factor_miss_country;
    out["last_completed_building_factor_miss_sector"] =
        _last_completed_perf.building_factor_miss_sector;
    out["last_completed_building_factor_miss_research"] =
        _last_completed_perf.building_factor_miss_research;
    out["last_completed_building_factor_miss_identity"] =
        _last_completed_perf.building_factor_miss_identity;
    out["last_completed_aggregate_publish_ms"] =
        _last_completed_perf.aggregate_publish_ms;
    out["last_completed_aggregate_audit_ms"] =
        _last_completed_perf.aggregate_audit_ms;
    out["last_completed_market_result_allocation_growth_count"] =
        _last_completed_perf.market_result_allocation_growth_count;
    out["last_completed_market_result_allocation_growth_bytes"] =
        _last_completed_perf.market_result_allocation_growth_bytes;
    out["last_completed_production_result_allocation_growth_count"] =
        _last_completed_perf.production_result_allocation_growth_count;
    out["last_completed_production_result_allocation_growth_bytes"] =
        _last_completed_perf.production_result_allocation_growth_bytes;
    out["last_completed_building_structure_count_only_updates"] =
        _last_completed_perf.building_structure_count_only_updates;
    out["last_completed_building_structure_new_groups"] =
        _last_completed_perf.building_structure_new_groups;
    out["last_completed_building_structure_removed_groups"] =
        _last_completed_perf.building_structure_removed_groups;
    out["last_completed_building_structure_topology_rebuilds"] =
        _last_completed_perf.building_structure_topology_rebuilds;
    out["last_completed_building_structure_role_span_reuses"] =
        _last_completed_perf.building_structure_role_span_reuses;
    out["last_completed_building_structure_role_span_appends"] =
        _last_completed_perf.building_structure_role_span_appends;
    out["last_completed_building_structure_group_merge_ms"] =
        _last_completed_perf.building_structure_group_merge_ms;
    out["last_completed_building_structure_market_cache_ms"] =
        _last_completed_perf.building_structure_market_cache_ms;
    out["last_completed_building_structure_labor_cache_ms"] =
        _last_completed_perf.building_structure_labor_cache_ms;
    out["due_cells"] = _rolling_due_cells;
    out["processed_due_cells"] = _rolling_processed_cells;
    out["deferred_cells"] = _rolling_deferred_cells;
    out["settlement_watermark"] = _settlement_watermark;
    out["newest_state_day"] = _settlement_newest_day;
    out["max_state_age_days"] = _settlement_max_age_days;
    out["rolling_deadline_violations"] = _rolling_deadline_violations;
    out["worker_enabled"] = _worker_enabled;
    out["worker_market_threshold"] = _worker_market_threshold;
    out["markets_per_slice"] = _cells_per_slice;
    out["building_cells_per_slice"] = _building_cells_per_slice;
    out["building_groups_per_slice"] = _building_groups_per_slice;
    out["auto_slice_by_scale"] = _auto_slice_by_scale;
