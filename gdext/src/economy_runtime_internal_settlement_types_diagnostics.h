// Settlement, worker, investment and publish diagnostics.

    std::vector<int64_t> _merchant_procurement_paid_by_cell;
    std::vector<int64_t> _merchant_procurement_retail_by_cell;
    std::vector<int64_t> _merchant_procurement_factor_weighted_cash_by_cell;
    std::vector<int64_t> _merchant_trade_purchase_by_cell;
    std::vector<int64_t> _merchant_trade_sale_by_cell;
    std::vector<int64_t> _merchant_credit_drawn_by_cell;
    // [market] Merchant household retail share of the most recently settled
    // day, net of income tax. Market-keyed, not cell-keyed: `process_market_cell`
    // distributes one market's household spend across that market's living
    // merchants, so the pool a merchant post can claim belongs to the market.
    // Merchant population is captured in the same settlement pass so the
    // projection never rescans cohorts. Both reset with the other epoch
    // metrics and are not persisted -- the same contract as the
    // `_merchant_procurement_*_by_cell` family above.
    std::vector<int64_t> _merchant_household_retail_by_market;
    std::vector<int64_t> _market_merchant_population;
    // Design knob: the share of household retail attributable to merchant
    // *posts*. The rest is itinerant trade a post count must not claim.
    // Free entry would otherwise split the whole market pool down to the
    // living floor and multiply merchant population by ~10x.
    int32_t _merchant_service_post_share_q16 = Q16_ONE / 3;
    int64_t _production_input_reserved = 0;
    int64_t _production_input_reserve_shortfall = 0;
    int64_t _construction_material_reserved = 0;
    int64_t _maintenance_goods_consumed = 0;
    int64_t _maintenance_unmet = 0;
    int64_t _maintenance_unpaid_value = 0;
    int64_t _labor_signal_updates = 0;
    int64_t _building_resource_generated = 0;
    int64_t _building_resource_consumed = 0;
    int64_t _building_resource_limited_groups = 0;
    int64_t _unprofitable_building_groups = 0;
    int64_t _zero_utilization_building_groups = 0;
    int64_t _utilization_sum_q16 = 0;
    int64_t _market_signal_updates = 0;
    int64_t _trade_route_expansions = 0;
    int64_t _trade_route_cache_hits = 0;
    int64_t _trade_route_cache_misses = 0;
    int64_t _trade_candidates_generated = 0;
    int64_t _trade_candidates_accepted = 0;
    int64_t _trade_rejected_profit = 0;
    int64_t _trade_rejected_no_spread = 0;
    int64_t _trade_rejected_margin = 0;
    int64_t _trade_quantity_profit_clips = 0;
    int64_t _trade_relief_candidates = 0;
    int64_t _trade_rejected_capacity = 0;
    int64_t _trade_rejected_stock = 0;
    int64_t _trade_rejected_cash = 0;
    int64_t _trade_rejected_route = 0;
    int64_t _trade_rejected_vision = 0;
    int64_t _trade_rejected_order_cap = 0;
    int64_t _trade_orders_dispatched = 0;
    int64_t _trade_orders_arrived = 0;
    int64_t _trade_unclaimed_orders = 0;
    int64_t _trade_capacity_available = 0;
    int64_t _trade_capacity_used = 0;
    int64_t _trade_settlement_lag_days = 0;
    int64_t _trade_plan_reset_count = 0;
    int64_t _trade_signal_max_age_days = 0;
    int64_t _trade_first_dispatch_delay_max_days = 0;
    int64_t _trade_response_deadline_misses = 0;
    int64_t _trade_response_deadline_misses_cumulative = 0;
    int64_t _trade_unresolved_no_attempt = 0;
    int64_t _trade_unresolved_no_spread = 0;
    int64_t _trade_unresolved_margin = 0;
    int64_t _trade_unresolved_route = 0;
    int64_t _trade_unresolved_stock = 0;
    int64_t _trade_unresolved_capacity = 0;
    int64_t _trade_unresolved_cash = 0;
    int64_t _trade_unresolved_order_cap = 0;
    int64_t _trade_active_keys_pruned = 0;
    int64_t _trade_deficit_episodes_started = 0;
    int64_t _trade_deficit_episodes_resolved = 0;
    int64_t _trade_candidates_stale_generation = 0;
    int64_t _trade_candidates_arbitrated_out = 0;
    int64_t _trade_true_source_stock_failures = 0;
    int64_t _trade_topology_content_change_count = 0;
    std::string _trade_last_plan_reset_reason = "none";
    int64_t _building_resource_capacity_checks = 0;
    int64_t _building_resource_capacity_limited_groups = 0;
    std::string _last_building_rejection_reason;
    int32_t _worker_tasks = 1;
    int32_t _production_worker_tasks = 1;
    int32_t _market_worker_tasks_max = 1;
    int64_t _market_worker_task_sum = 0;
    int64_t _market_worker_dispatches = 0;
    int64_t _market_worker_parallel_dispatches = 0;
    int32_t _production_worker_tasks_max = 1;
    int64_t _production_worker_task_sum = 0;
    int64_t _production_worker_dispatches = 0;
    int64_t _production_worker_parallel_dispatches = 0;
    int64_t _production_worker_weight_total = 0;
    int64_t _production_worker_task_weight_min = 0;
    int64_t _production_worker_task_weight_max = 0;
    int64_t _production_worker_imbalance_q16_max = 0;
    double _production_worker_cpu_ms = 0.0;
    int32_t _audit_worker_tasks_max = 1;
    int64_t _audit_worker_dispatches = 0;
    double _audit_worker_cpu_ms = 0.0;
    int32_t _building_plan_worker_tasks_max = 1;
    int64_t _building_plan_worker_parallel_dispatches = 0;
    double _building_plan_worker_cpu_ms = 0.0;
    int64_t _opening_audit_fast_paths = 0;
    int64_t _opening_audit_full_verifications = 0;
    int64_t _closing_audit_fast_paths = 0;
    int64_t _closing_audit_full_verifications = 0;
    int64_t _closing_audit_mismatches = 0;
    int64_t _closing_audit_population_full_scan_entries = 0;
    int64_t _closing_audit_market_full_scan_entries = 0;
    AuditTotals _incremental_closing_totals;
    bool _opening_audit_force_full = false;
    // An incremental close is a derived snapshot. Do not reuse it as the
    // next epoch's opening baseline without one full physical rescan.
    bool _last_closing_audit_was_incremental = false;
    std::vector<int64_t> _audit_shadow_population;
    std::vector<int64_t> _audit_shadow_funds;
    std::vector<int64_t> _audit_shadow_market_stock;
    mutable std::array<RuntimeChunkHash, 4> _market_hash_pages;
    int64_t state_hash_internal(bool paged) const;
    std::vector<uint32_t> _audit_population_lane_stamp;
    std::vector<uint32_t> _audit_market_lane_stamp;
    std::vector<size_t> _audit_population_touched_lanes;
    std::vector<size_t> _audit_market_touched_lanes;
    uint32_t _audit_mutation_generation = 0;
    std::string _closing_audit_mismatch_ledger = "none";
    int64_t _closing_audit_mismatch_lane = -1;
    std::vector<GoodsAuditLaneDiagnostic> _goods_audit_candidate_lanes;
    std::vector<MoneyAuditAccountDiagnostic> _money_audit_candidate_accounts;
    std::vector<MoneyStageDiagnostic> _money_stage_diagnostics;
    int64_t _money_stage_probe_epoch_id = -1;
    int64_t _money_stage_probe_last_diff = 0;
    int32_t _money_stage_probe_last_stage = -1;
    int32_t _money_stage_probe_last_executed_stage = -1;
    bool _money_stage_probe_post_commit = false;
    bool _money_stage_probe_has_last = false;
    std::string _money_stage_probe_last_where;
    std::string _money_stage_probe_last_substage;
    int64_t _investment_scheduled_review_cells = 0;
    int64_t _investment_review_cells = 0;
    int64_t _investment_type_evaluations = 0;
    int64_t _investment_market_signal_rejections = 0;
    int64_t _investment_ethnicity_evaluations = 0;
    int64_t _investment_sparse_considered_types = 0;
    int64_t _investment_sparse_selected_types = 0;
    int64_t _investment_sparse_skipped_types = 0;
    int64_t _investment_sparse_mismatches = 0;
    int64_t _investment_sparse_dense_fallbacks = 0;
    // Types skipped by the capital-feasibility gate: no local sponsor cohort
    // (transferable <= raw funds) and no merchant credit can cover even the
    // construction cost, so every sponsor search for that (cell, type) is
    // guaranteed to fail. Exact no-false-negative early-out.
    int64_t _investment_gate_capital_type_skips = 0;
    int64_t _investment_displacement_type_evaluations = 0;
    int64_t _startup_demand_seed_count = 0;
    int64_t _startup_demand_touched_lanes = 0;
    int64_t _startup_demand_catalog_edges = 0;
    int64_t _startup_demand_cycle_skips = 0;
    int64_t _startup_demand_remote_lanes = 0;
    int64_t _startup_demand_matched_review_cells = 0;
    int64_t _startup_demand_buildings_started = 0;
    int64_t _startup_demand_scratch_bytes = 0;
    int64_t _approximation_decisions = 0;
    int64_t _approximation_exact_probes = 0;
    int64_t _approximation_certificate_failures = 0;
    int64_t _approximation_exact_fallbacks = 0;
    int64_t _approximation_frontier_candidates = 0;
    int64_t _approximation_frontier_pruned = 0;
    int64_t _approximation_max_observed_regret_q16 = 0;
    int64_t _approximation_probe_violations = 0;
    int64_t _approximation_probe_max_spend_error_q16 = 0;
    int64_t _approximation_probe_max_demand_error_q16 = 0;
    int32_t _approximation_cooldown_epochs_left = 0;
    int32_t _approximation_low_prune_epochs = 0;
    int32_t _active_batch_multiplier = 1;
    int64_t _high_speed_market_dispatches_saved = 0;
    int64_t _high_speed_production_dispatches_saved = 0;
    int64_t _budgeted_building_commit_phase_fusions = 0;
    int64_t _budgeted_publish_phase_fusions = 0;
    bool _investment_sparse_runtime_disabled = false;
    double _production_merge_ms = 0.0;
    double _production_worker_ms = 0.0;
    double _market_worker_ms = 0.0;
    double _household_market_prepare_ms = 0.0;
    double _market_merge_ms = 0.0;
    double _market_merge_aggregate_ms = 0.0;
    double _market_merge_trade_ms = 0.0;
    int64_t _market_result_allocation_growth_count = 0;
    int64_t _market_result_allocation_growth_bytes = 0;
    int64_t _production_result_allocation_growth_count = 0;
    int64_t _production_result_allocation_growth_bytes = 0;
    int32_t _rolling_phase = 0;
    int32_t _rolling_due_cells = 0;
    int32_t _rolling_processed_cells = 0;
    int32_t _rolling_deferred_cells = 0;
    int64_t _settlement_watermark = -1;
    int64_t _settlement_newest_day = -1;
    int64_t _settlement_max_age_days = 0;
    int64_t _rolling_deadline_violations = 0;
    // Transient epoch workset diagnostics. These counters do not participate
    // in economy state/event hashes and are reset at every epoch boundary.
    int64_t _prepare_reuse_count = 0;
    int64_t _workset_cells_planned = 0;
    int64_t _workset_cells_executed = 0;
    int64_t _duplicate_range_count = 0;
    int32_t _workset_last_cursor = 0;
    // Sparse-workset shape frozen at epoch open. Diagnostic only: read by the
    // workset probe report and never by any settlement/stage decision.
    int64_t _probe_workset_market_cells_due = 0;
    int64_t _probe_workset_building_cells = 0;
    int64_t _probe_workset_plan_cells = 0;
    int64_t _probe_workset_live_cells = 0;
    int64_t _probe_workset_coverage_permille = 0;
    int32_t _probe_market_bucket_index = 0;
    int32_t _probe_market_cycle_days = 0;
    int32_t _probe_plan_cycle_days = 0;
    int32_t _probe_cells_per_slice = 0;
    // Continuation accounting for the current epoch (slice granularity).
    int64_t _probe_slice_count = 0;
    int64_t _probe_slice_budget_hits = 0;
    double _probe_slice_ms_total = 0.0;
    double _probe_slice_ms_max = 0.0;
    // Boundary phase split fed by the simulation host around an economy day.
    double _probe_phase_attempt_ms = 0.0;
    double _probe_phase_formula_ms = 0.0;
    double _probe_phase_publish_ms = 0.0;
    double _probe_phase_mirror_capture_ms = 0.0;
    double _probe_phase_mirror_import_ms = 0.0;
    double _probe_trade_plan_ms = 0.0;

    int32_t _trace_mode = TRACE_SELECTIVE;
    int64_t _trace_memory_budget = 32LL * 1024 * 1024;
    int32_t _trace_retention_epochs = 8;
    int64_t _trace_detail_epoch_budget = 8LL * 1024 * 1024;
    int32_t _trace_poll_max_events = 4096;
    std::vector<uint8_t> _trace_cell_mask;
    std::vector<uint8_t> _pending_trace_cell_mask;
    bool _trace_filter_pending = false;
    int32_t _inspector_trace_cell = -1;
    int32_t _pending_inspector_trace_cell = -1;
    bool _inspector_trace_pending = false;
    EventBatch _staging_events;
    std::deque<EventBatch> _committed_event_batches;
    std::vector<ConstructionCommandReceipt> _staging_construction_receipts;
    std::deque<ConstructionCommandReceipt> _committed_construction_receipts;
    int64_t _next_construction_receipt_id = 1;
    std::vector<CommittedGameplayFact> _staging_gameplay_facts;
    std::vector<CommittedGameplayFact> _committed_gameplay_facts;
    std::deque<AuditFrame> _audit_history;
    std::unordered_map<std::string, int64_t> _event_consumer_ack;
    EconomyTrackedScalar<int64_t> _next_event_id{_metadata_changes, {{15, 70}, "config.next_event_id", EconomyFieldEncoding::I64, 8}, 1};
    int64_t _event_evicted_count = 0;
    int64_t _first_evicted_event_id = 0;
    int64_t _trace_detail_truncated = 0;
    int64_t _trace_uncommitted_discarded = 0;
    EconomyTrackedScalar<uint64_t> _event_stream_hash{_metadata_changes, {{15, 39}, "config.event_stream_hash", EconomyFieldEncoding::U64, 8}, 1469598103934665603ULL};
    double _event_summary_ms = 0.0;
    double _event_detail_ms = 0.0;
    double _event_publish_ms = 0.0;
    EventArchiveState _event_archive;

    double _formula_ms = 0.0;
    double _clear_ms = 0.0;
    double _ledger_ms = 0.0;
    double _fallback_ms = 0.0;
    double _merchant_settle_ms = 0.0;
    double _price_ms = 0.0;
    double _structure_ms = 0.0;
    double _publish_ms = 0.0;
    double _employment_ms = 0.0;
    double _production_ms = 0.0;
    double _building_plan_ms = 0.0;
    double _building_plan_evaluate_ms = 0.0;
    double _building_plan_reserve_ms = 0.0;
    double _building_structure_group_merge_ms = 0.0;
    double _building_structure_market_cache_ms = 0.0;
    double _building_structure_labor_cache_ms = 0.0;
    double _investment_ms = 0.0;
    double _market_signal_ms = 0.0;
    double _market_signal_insert_ms = 0.0;
    double _market_signal_flush_ms = 0.0;
    int64_t _market_signal_insert_count = 0;
    double _wage_plan_ms = 0.0;
    double _labor_signal_ms = 0.0;
    double _trade_plan_ms = 0.0;
    double _trade_plan_scan_body_ms = 0.0;
    double _trade_plan_scan_finalize_ms = 0.0;
    double _trade_plan_route_prepare_ms = 0.0;
    double _trade_plan_route_expand_ms = 0.0;
    double _trade_plan_route_finalize_ms = 0.0;
    int64_t _trade_plan_scan_pairs_slice = 0;
    int64_t _trade_plan_route_sources_prepared_slice = 0;
    int64_t _trade_plan_route_expansions_slice = 0;
    int64_t _trade_plan_candidates_finalized_slice = 0;
    double _trade_settle_ms = 0.0;
    double _trade_dispatch_ms = 0.0;
    double _epoch_begin_ms = 0.0;
    double _epoch_preflight_ms = 0.0;
    double _prepare_ms = 0.0;
    // Transient epoch-begin substage timings (diagnostics only; never saved or
    // hashed). Sum of parts <= _epoch_begin_ms.
    double _epoch_begin_reset_ms = 0.0;
    double _epoch_begin_country_ms = 0.0;
    double _epoch_begin_city_factor_ms = 0.0;
    double _epoch_begin_building_factor_ms = 0.0;
    // Lookup-scan accounting (diagnostics only; never saved or hashed). Counts
    // elements visited by the remaining linear-scan lookups so the cost of
    // finding data can be separated from the cost of computing it. Attribution
    // uses _executed_stage, which the slice dispatcher sets before doing work.
    static constexpr size_t SCAN_STAGE_SLOTS = 18;
    mutable int64_t _scan_steps_by_stage[SCAN_STAGE_SLOTS] = {};
    mutable int64_t _scan_steps_find_building_group = 0;
    mutable int64_t _scan_steps_find_signature = 0;
    mutable int64_t _scan_steps_membership_fallback = 0;
    mutable int64_t _scan_steps_person_linear = 0;
    mutable int64_t _scan_steps_family_linear = 0;
    mutable int64_t _scan_calls_find_building_group = 0;
    mutable int64_t _scan_calls_find_signature = 0;
    mutable int64_t _scan_calls_membership_fallback = 0;
    void note_scan_steps(int64_t steps) const {
        const size_t slot = static_cast<size_t>(_executed_stage);
        if (slot < SCAN_STAGE_SLOTS) _scan_steps_by_stage[slot] += steps;
    }
    // Person-commit substage timings (diagnostics only; never saved or hashed).
    double _person_commit_retire_ms = 0.0;
    double _person_commit_index_ms = 0.0;
    double _person_commit_bind_jobs_ms = 0.0;
    double _person_commit_claims_ms = 0.0;
    double _person_commit_equity_ms = 0.0;
    double _person_commit_promote_ms = 0.0;
    double _family_commit_normalize_ms = 0.0;
    double _family_commit_attribution_ms = 0.0;
    double _family_commit_form_ms = 0.0;
    double _family_commit_index_ms = 0.0;
    double _family_commit_lifecycle_ms = 0.0;
    double _family_commit_influence_ms = 0.0;
    double _family_behavior_cache_ms = 0.0;
    int64_t _family_behavior_cache_rebuilds = 0;
    int64_t _family_behavior_cache_skips = 0;
    int64_t _family_behavior_metric_contexts_built = 0;
    int64_t _family_behavior_condition_edges_evaluated = 0;
    int64_t _family_behavior_class_rows = 0;
    uint32_t _family_behavior_cache_dirty_reasons =
        FAMILY_BEHAVIOR_DIRTY_INITIAL;
    uint32_t _family_behavior_cache_last_reasons = 0;
    bool _family_behavior_cache_dirty = true;
    // Track B: last day the family behavior cache was actually rebuilt.
    int64_t _track_b_family_cache_last_day =
        std::numeric_limits<int64_t>::min();
    double _person_retire_call_ms = 0.0;
    int64_t _person_retire_calls = 0;
    double _rebuild_person_needs_ms = 0.0;
    double _rebuild_person_count_ms = 0.0;
    double _rebuild_person_fill_ms = 0.0;
    double _rebuild_person_sort_ms = 0.0;
    double _rebuild_person_needoffsets_ms = 0.0;
    double _rebuild_family_membership_ms = 0.0;
    double _rebuild_family_ownership_ms = 0.0;
    double _rebuild_family_csr_ms = 0.0;
    double _rebuild_family_cellindex_ms = 0.0;
    double _investment_evaluate_ms = 0.0;
    double _investment_allocate_ms = 0.0;
    double _investment_prepare_lanes_ms = 0.0;
    double _investment_prepare_pending_ms = 0.0;
    double _investment_prepare_groups_ms = 0.0;
    double _startup_demand_prepare_ms = 0.0;
    double _finalize_construction_ms = 0.0;
    double _finalize_reconcile_ms = 0.0;
    double _building_factor_refresh_ms = 0.0;
    double _building_role_storage_ms = 0.0;
    int64_t _building_factor_cache_hits_epoch = 0;
    int64_t _building_factor_cache_misses_epoch = 0;
    int64_t _building_factor_miss_modver_epoch = 0;
    int64_t _building_factor_miss_country_epoch = 0;
    int64_t _building_factor_miss_sector_epoch = 0;
    int64_t _building_factor_miss_research_epoch = 0;
    int64_t _building_factor_miss_identity_epoch = 0;
    double _epoch_begin_workset_ms = 0.0;
    double _epoch_begin_resource_lane_ms = 0.0;
    double _epoch_begin_fiscal_ms = 0.0;
    double _fiscal_settlement_ms = 0.0;
    double _income_subsidy_epoch_ms = 0.0;
    double _epoch_begin_construction_csr_ms = 0.0;
    double _epoch_begin_recovery_apply_ms = 0.0;
    double _epoch_begin_vector_init_ms = 0.0;
    double _epoch_begin_audit_lane_ms = 0.0;
    double _epoch_begin_commands_ms = 0.0;
    double _audit_ms = 0.0;
    double _watermark_ms = 0.0;
    std::array<double, static_cast<size_t>(PublishPhase::COUNT)> _publish_phase_ms{};
    std::array<int64_t, static_cast<size_t>(PublishPhase::COUNT)> _publish_phase_work{};
    std::array<double, static_cast<size_t>(PublishPhase::COUNT)> _publish_slice_phase_ms{};
    std::array<int64_t, static_cast<size_t>(PublishPhase::COUNT)> _publish_slice_phase_work{};
    double _publish_commit_cells_ms = 0.0;
    double _publish_commit_prepare_ms = 0.0;
    double _publish_commit_finalize_ms = 0.0;
    double _publish_commit_cells_slice_ms = 0.0;
    double _publish_commit_prepare_slice_ms = 0.0;
    double _publish_commit_finalize_slice_ms = 0.0;
    std::array<double, BUILDING_COMMIT_PHASE_COUNT> _building_commit_slice_phase_ms{};
    std::array<int64_t, BUILDING_COMMIT_PHASE_COUNT> _building_commit_slice_phase_work{};
