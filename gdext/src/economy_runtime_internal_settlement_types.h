// Included inside NativeEconomyRuntime; preserve declaration order and access.
    struct EventLeg {
        int32_t field = 0;
        int32_t subject_kind = SUBJECT_NONE;
        int64_t subject_id = 0;
        int32_t key_id = -1;
        int64_t before = 0;
        int64_t after = 0;
    };

    struct EventRecord {
        int64_t event_id = 0;
        int32_t stage = 0;
        int32_t kind = 0;
        int32_t flags = 0;
        int32_t cell = -1;
        int32_t subject_kind = SUBJECT_NONE;
        int64_t subject_id = 0;
        int32_t subject_i0 = -1;
        int32_t subject_i1 = -1;
        uint32_t leg_begin = 0;
        uint32_t leg_count = 0;
        int64_t value0 = 0;
        int64_t value1 = 0;
        int64_t value2 = 0;
        int64_t value3 = 0;
    };

    struct CashflowEntry {
        uint64_t cohort_handle = 0;
        int32_t source = CASHFLOW_OTHER;
        int64_t income = 0;
        int64_t expense = 0;
    };

    struct ConstructionCommandReceipt {
        int64_t receipt_id = 0;
        int64_t sequence = 0;
        int64_t effective_day = 0;
        int64_t settled_day = 0;
        uint64_t country_handle = 0;
        int32_t cell = -1;
        int32_t type_id = -1;
        bool ok = false;
        std::string code;
        int64_t cash_paid = 0;
        int64_t treasury_goods_used = 0;
        int64_t market_goods_used = 0;
    };

    enum CanalSourceKind : uint8_t {
        CANAL_SOURCE_NONE = 0,
        CANAL_SOURCE_SALINE = 1,
        CANAL_SOURCE_FRESHWATER = 2,
    };

    enum CanalProjectState : uint8_t {
        CANAL_PROJECT_BUILDING = 1,
        CANAL_PROJECT_AWAITING_EFFECT = 2,
        CANAL_PROJECT_COMPLETED = 3,
        CANAL_PROJECT_FAILED = 4,
    };

    struct CanalQuote {
        uint64_t token = 0;
        uint64_t country_handle = 0;
        int64_t snapshot_day = -1;
        uint64_t topology_hash = 0;
        uint64_t country_generation = 0;
        uint64_t price_hash = 0;
        uint8_t source_kind = CANAL_SOURCE_NONE;
        int32_t new_edge_count = 0;
        int32_t reused_edge_count = 0;
        int32_t construction_days = 0;
        int64_t cash_required = 0;
        std::array<int32_t, 2> material_good_ids{{-1, -1}};
        std::array<int64_t, 2> material_quantities{{0, 0}};
        std::vector<int32_t> route_cells;
        std::vector<int32_t> route_edge_dirs;
        template<class Visitor> void visit_persisted(Visitor &visit) const {
            visit(token); visit(country_handle); visit(snapshot_day); visit(topology_hash);
            visit(country_generation); visit(price_hash); visit(source_kind);
            visit(new_edge_count); visit(reused_edge_count); visit(construction_days);
            visit(cash_required); visit(material_good_ids); visit(material_quantities);
            visit(route_cells); visit(route_edge_dirs);
        }
    };

    struct CanalProject {
        uint64_t handle = 0;
        uint32_t generation = 1;
        uint64_t country_handle = 0;
        int64_t effective_day = 0;
        int64_t sequence = 0;
        int64_t ready_day = 0;
        int64_t effect_transaction_id = 0;
        uint64_t topology_hash = 0;
        int64_t cash_paid = 0;
        int64_t treasury_goods_used = 0;
        int64_t market_goods_used = 0;
        uint8_t source_kind = CANAL_SOURCE_NONE;
        uint8_t state = CANAL_PROJECT_BUILDING;
        std::vector<int32_t> route_cells;
        std::vector<int32_t> route_edge_dirs;
        template<class Visitor> void visit_persisted(Visitor &visit) const {
            visit(handle);
            visit(generation);
            visit(country_handle);
            visit(effective_day);
            visit(sequence);
            visit(ready_day);
            visit(effect_transaction_id);
            visit(topology_hash);
            visit(cash_paid);
            visit(treasury_goods_used);
            visit(market_goods_used);
            visit(source_kind);
            visit(state);
            visit(route_cells);
            visit(route_edge_dirs);
        }
    };

    struct CanalConstructionReceipt {
        int64_t receipt_id = 0;
        int64_t effective_day = 0;
        int64_t settled_day = 0;
        int64_t sequence = 0;
        uint64_t country_handle = 0;
        uint64_t project_handle = 0;
        bool ok = false;
        std::string code;
        int64_t cash_paid = 0;
        int64_t treasury_goods_used = 0;
        int64_t market_goods_used = 0;
    };

    enum TradeSignalDiagnosticReason : int32_t {
        TRADE_SIGNAL_DIAG_NONE = 0,
        TRADE_SIGNAL_DIAG_NO_SPREAD = 1,
        TRADE_SIGNAL_DIAG_MARGIN = 2,
        TRADE_SIGNAL_DIAG_ROUTE = 3,
        TRADE_SIGNAL_DIAG_STOCK = 4,
        TRADE_SIGNAL_DIAG_CAPACITY = 5,
        TRADE_SIGNAL_DIAG_CASH = 6,
        TRADE_SIGNAL_DIAG_ORDER_CAP = 7,
        TRADE_SIGNAL_DIAG_DISPATCHED = 8,
        TRADE_SIGNAL_DIAG_ARBITRATED_OUT = 9,
    };

    struct ProductionTraceDraft {
        int32_t kind = 0;
        int32_t stage = 0;
        int32_t cell = -1;
        int32_t subject_kind = SUBJECT_NONE;
        int64_t subject_id = 0;
        int32_t subject_i0 = -1;
        int32_t subject_i1 = -1;
        int64_t value0 = 0;
        int64_t value1 = 0;
        int64_t value2 = 0;
        int64_t value3 = 0;
        int32_t flags = 0;
        std::vector<EventLeg> legs;
    };

    struct ProductionCashflowDraft {
        int32_t cell = -1;
        CashflowEntry entry;
    };

    struct ProductionResult {
        bool ok = true;
        int32_t cell = -1;
        std::string error;
        int64_t saturation_count = 0;
        int64_t processed_building_groups = 0;
        int64_t climate_profiled_building_groups = 0;
        int64_t climate_limited_building_groups = 0;
        int64_t climate_capacity_sum_q16 = 0;
        int64_t merchant_procurement_budget = 0;
        int64_t merchant_procurement_opportunity = 0;
        int64_t merchant_procurement_allocated = 0;
        int64_t merchant_procurement_unspent_allocated = 0;
        int64_t merchant_procurement_reserved = 0;
        int64_t merchant_procurement_spent = 0;
        int64_t merchant_procurement_retail_value = 0;
        int64_t merchant_procurement_factor_weighted_cash_q16 = 0;
        int64_t merchant_survival_procurement_required = 0;
        int64_t merchant_survival_procurement_allocated = 0;
        int64_t merchant_input_procurement_required = 0;
        int64_t merchant_input_procurement_allocated = 0;
        int64_t owner_working_capital_allocated = 0;
        int64_t working_capital_scale_error_bound_q16 = 0;
        int64_t building_resource_capacity_checks = 0;
        int64_t building_resource_limited_groups = 0;
        int64_t building_resource_capacity_limited_groups = 0;
        int64_t building_resource_generated = 0;
        int64_t building_resource_consumed = 0;
        int64_t production_inputs_consumed = 0;
        int64_t maintenance_goods_consumed = 0;
        int64_t maintenance_unmet = 0;
        int64_t maintenance_unpaid_value = 0;
        int64_t production_output_stock = 0;
        int64_t production_output_discarded = 0;
        int64_t production_output_supported = 0;
        int64_t producer_revenue = 0;
        int64_t producer_support_money_issued = 0;
        int64_t explicit_money_mint = 0;
        int64_t bullion_money_issued = 0;
        int64_t bullion_stock_consumed = 0;
        int64_t gold_accepted = 0;
        int64_t silver_accepted = 0;
        int64_t gold_money_issued = 0;
        int64_t silver_money_issued = 0;
        int64_t cycle_flow_produced = 0;
        int64_t cycle_flow_consumed = 0;
        int64_t cycle_flow_discarded = 0;
        int64_t food_output_eq = 0;
        int64_t food_input_eq = 0;
        int64_t food_output_events = 0;
        int64_t food_input_events = 0;
        int64_t building_wages_paid = 0;
        int64_t building_wages_unpaid = 0;
        int64_t building_base_wages_paid = 0;
        int64_t building_base_wages_due = 0;
        int64_t building_bonus_paid = 0;
        int64_t building_bonus_due = 0;
        int64_t wage_suspended_building_groups = 0;
        int64_t desired_business_demand = 0;
        int64_t funded_business_demand = 0;
        int64_t unfunded_business_demand = 0;
        int64_t active_unfunded_building_groups = 0;
        int64_t market_signal_updates = 0;
        int64_t merchant_credit_committed = 0;
        int64_t merchant_credit_drawn = 0;
        int64_t merchant_credit_repaid = 0;
        int64_t merchant_credit_premium_repaid = 0;
        double market_signal_ms = 0.0;
        std::vector<size_t> resource_touched_lanes;
        std::vector<OwnerRetainedOutput> retained_outputs;
        std::vector<ProductionTraceDraft> trace_drafts;
        std::vector<ProductionCashflowDraft> cashflow_drafts;
        // Worker-local audit lanes, registered on the joining thread.
        std::vector<size_t> audit_population_lanes;
        std::vector<size_t> audit_market_lanes;
        // Worker-local occupancy introductions. The shared
        EconomyWorkerChanges market_changes;
        // `_bio_introduce_keys` set must not be mutated from production
        // workers; merge_building_production_result commits these in cell order.
        std::vector<int32_t> bio_introduce_cells;
        std::vector<int32_t> bio_introduce_bits;
        int64_t allocation_growth_count = 0;
        int64_t allocation_growth_bytes = 0;

        void reset();
        int64_t capacity_bytes() const;
    };

    struct BuildingPlanResult {
        bool ok = true;
        std::string error;
        int64_t saturation_count = 0;
        int64_t merchant_credit_budget = 0;
        int64_t merchant_credit_committed = 0;
        int64_t recovery_candidates = 0;
        int64_t recovery_approved = 0;
        int64_t loss_suspended_building_groups = 0;
        int64_t unprofitable_building_groups = 0;
        int64_t utilization_sum_q16 = 0;
        double worker_ms = 0.0;

        void reset() {
            *this = {};
        }
    };

    struct CompletedEpochPerf {
        bool valid = false;
        int64_t epoch_id = -1;
        int64_t sample_day = -1;
        int64_t continuation_slices = 0;
        int32_t market_worker_tasks_max = 1;
        int64_t market_worker_task_sum = 0;
        int64_t market_worker_dispatches = 0;
        int64_t market_worker_parallel_dispatches = 0;
        int32_t production_worker_tasks_max = 1;
        int64_t production_worker_task_sum = 0;
        int64_t production_worker_dispatches = 0;
        int64_t production_worker_parallel_dispatches = 0;
        int64_t production_worker_weight_total = 0;
        int64_t production_worker_task_weight_min = 0;
        int64_t production_worker_task_weight_max = 0;
        int64_t production_worker_imbalance_q16_max = 0;
        double production_worker_cpu_ms = 0.0;
        int32_t audit_worker_tasks_max = 1;
        int64_t audit_worker_dispatches = 0;
        double audit_worker_cpu_ms = 0.0;
        int32_t building_plan_worker_tasks_max = 1;
        int64_t building_plan_worker_parallel_dispatches = 0;
        double building_plan_worker_cpu_ms = 0.0;
        int64_t opening_audit_fast_paths = 0;
        int64_t opening_audit_full_verifications = 0;
        int64_t closing_audit_fast_paths = 0;
        int64_t closing_audit_full_verifications = 0;
        int64_t closing_audit_mismatches = 0;
        std::string closing_audit_mismatch_ledger = "none";
        int64_t closing_audit_mismatch_lane = -1;
        int64_t closing_audit_population_touched_lanes = 0;
        int64_t closing_audit_market_touched_lanes = 0;
        int64_t closing_audit_population_full_scan_entries = 0;
        int64_t closing_audit_market_full_scan_entries = 0;
        int64_t investment_scheduled_review_cells = 0;
        int64_t investment_review_cells = 0;
        int64_t investment_type_evaluations = 0;
        int64_t investment_market_signal_rejections = 0;
        int64_t investment_ethnicity_evaluations = 0;
        int64_t investment_sparse_considered_types = 0;
        int64_t investment_sparse_selected_types = 0;
        int64_t investment_sparse_skipped_types = 0;
        int64_t investment_sparse_mismatches = 0;
        int64_t investment_sparse_dense_fallbacks = 0;
        int64_t startup_demand_seed_count = 0;
        int64_t startup_demand_touched_lanes = 0;
        int64_t startup_demand_catalog_edges = 0;
        int64_t startup_demand_cycle_skips = 0;
        int64_t startup_demand_remote_lanes = 0;
        int64_t startup_demand_matched_review_cells = 0;
        int64_t startup_demand_buildings_started = 0;
        int64_t startup_demand_scratch_bytes = 0;
        int64_t investment_displacement_type_evaluations = 0;
        int64_t building_investment_displacement_starts = 0;
        int64_t approximation_decisions = 0;
        int64_t approximation_exact_probes = 0;
        int64_t approximation_certificate_failures = 0;
        int64_t approximation_exact_fallbacks = 0;
        int64_t approximation_frontier_candidates = 0;
        int64_t approximation_frontier_pruned = 0;
        int64_t approximation_max_observed_regret_q16 = 0;
        int64_t approximation_probe_violations = 0;
        int64_t approximation_probe_max_spend_error_q16 = 0;
        int64_t approximation_probe_max_demand_error_q16 = 0;
        int32_t approximation_cooldown_epochs_left = 0;
        int32_t high_speed_batch_multiplier = 1;
        int64_t high_speed_market_dispatches_saved = 0;
        int64_t high_speed_production_dispatches_saved = 0;
        int64_t budgeted_building_commit_phase_fusions = 0;
        int64_t budgeted_publish_phase_fusions = 0;
        double building_plan_ms = 0.0;
        double building_plan_evaluate_ms = 0.0;
        double building_plan_reserve_ms = 0.0;
        double building_employment_ms = 0.0;
        double building_production_ms = 0.0;
        double building_production_worker_ms = 0.0;
        double building_production_merge_ms = 0.0;
        int64_t price_numeric_floor_hits = 0;
        int64_t price_numeric_ceiling_hits = 0;
        int64_t price_min_tick_hits = 0;
        int64_t price_glut_cost_damp_hits = 0;
        int64_t small_payment_roundups = 0;
        double price_ms = 0.0;
        double household_market_worker_ms = 0.0;
        double household_market_prepare_ms = 0.0;
        double household_market_merge_ms = 0.0;
        double household_market_merge_aggregate_ms = 0.0;
        double household_market_merge_trade_ms = 0.0;
        int64_t prepare_reuse_count = 0;
        int64_t workset_cells_planned = 0;
        int64_t workset_cells_executed = 0;
        int64_t duplicate_range_count = 0;
        double building_investment_ms = 0.0;
        double investment_evaluate_ms = 0.0;
        double investment_allocate_ms = 0.0;
        double investment_prepare_lanes_ms = 0.0;
        double investment_prepare_pending_ms = 0.0;
        double investment_prepare_groups_ms = 0.0;
        double startup_demand_prepare_ms = 0.0;
        double finalize_construction_ms = 0.0;
        double finalize_reconcile_ms = 0.0;
        double building_factor_refresh_ms = 0.0;
        double building_role_storage_ms = 0.0;
        int64_t building_factor_cache_hits = 0;
        int64_t building_factor_cache_misses = 0;
        int64_t building_factor_miss_modver = 0;
        int64_t building_factor_miss_country = 0;
        int64_t building_factor_miss_sector = 0;
        int64_t building_factor_miss_research = 0;
        int64_t building_factor_miss_identity = 0;
        double aggregate_publish_ms = 0.0;
        double aggregate_audit_ms = 0.0;
        int64_t market_result_allocation_growth_count = 0;
        int64_t market_result_allocation_growth_bytes = 0;
        int64_t production_result_allocation_growth_count = 0;
        int64_t production_result_allocation_growth_bytes = 0;
        int64_t building_structure_count_only_updates = 0;
        int64_t building_structure_new_groups = 0;
        int64_t building_structure_removed_groups = 0;
        int64_t building_structure_topology_rebuilds = 0;
        int64_t building_structure_role_span_reuses = 0;
        int64_t building_structure_role_span_appends = 0;
        double building_structure_group_merge_ms = 0.0;
        double building_structure_market_cache_ms = 0.0;
        double building_structure_labor_cache_ms = 0.0;
    };

    struct EventBatch {
        int64_t epoch_id = 0;
        int64_t sample_day = -1;
        int64_t commit_day = -1;
        int32_t period_days = 1;
        int64_t first_event_id = 0;
        int64_t last_event_id = 0;
        uint64_t stream_hash = 1469598103934665603ULL;
        std::vector<EventRecord> events;
        std::vector<EventLeg> legs;
        int32_t cashflow_cell = -1;
        bool cashflow_complete = false;
        std::vector<CashflowEntry> cashflows;
        std::vector<CohortWelfareEntry> welfare_entries;
        int64_t bytes() const {
            int64_t welfare_bytes = 0;
            for (const CohortWelfareEntry &entry : welfare_entries) {
                welfare_bytes += static_cast<int64_t>(
                    entry.need_ids.capacity() * sizeof(int32_t) +
                    entry.need_satisfaction_q16.capacity() * sizeof(int32_t) +
                    entry.need_weight_q16.capacity() * sizeof(int32_t) +
                    entry.need_tiers.capacity() * sizeof(int32_t) +
                    entry.previous_demand_per_capita_daily.capacity() * sizeof(int64_t) +
                    entry.wealth_demand_delta_per_capita_daily.capacity() * sizeof(int64_t) +
                    entry.price_demand_delta_per_capita_daily.capacity() * sizeof(int64_t));
            }
            return static_cast<int64_t>(events.capacity() * sizeof(EventRecord) +
                                        legs.capacity() * sizeof(EventLeg) +
                                        cashflows.capacity() * sizeof(CashflowEntry) +
                                        welfare_entries.capacity() * sizeof(CohortWelfareEntry)) +
                   welfare_bytes;
        }
    };

    struct AuditFrame {
        int64_t epoch_id = 0;
        int64_t sample_day = -1;
        int64_t commit_day = -1;
        int64_t event_count = 0;
        int64_t leg_count = 0;
        int64_t population_error = 0;
        int64_t money_error = 0;
        int64_t goods_error = 0;
        uint64_t stream_hash = 1469598103934665603ULL;
    };

    struct SaveState {
        bool active = false;
        int32_t chunk_bytes = 4 * 1024 * 1024;
        int32_t section = 0;
        int32_t page_cursor = 0;
        int32_t market_cursor = 0;
        int32_t cell_cursor = 0;
        int32_t command_cursor = 0;
        int32_t building_cursor = 0;
        int32_t construction_cursor = 0;
        int32_t audit_cursor = 0;
        int32_t signal_cursor = 0;
        int32_t labor_signal_cursor = 0;
        int32_t trade_order_cursor = 0;
        int32_t trade_flow_cursor = 0;
        int32_t fiscal_cursor = 0;
        int32_t fiscal_country_count = 0;
        int32_t fiscal_peer_cursor = 0;
        int32_t d7_peer_ext_cursor = 0;
        int32_t settlement_cursor = 0;
        int32_t family_cursor = 0;
        int32_t family_membership_cursor = 0;
        int32_t family_ownership_cursor = 0;
        int32_t person_cursor = 0;
        int32_t person_need_cursor = 0;
        int32_t family_trait_cursor = 0;
        int32_t family_influence_cursor = 0;
        int32_t family_trait_command_cursor = 0;
        int32_t family_expedition_cursor = 0;
        int32_t tariff_history_cursor = 0;
        int32_t country_good_cursor = 0;
        int32_t country_partner_cursor = 0;
        int32_t canal_quote_cursor = 0;
        int32_t canal_project_cursor = 0;
        int32_t ceiling_market_cursor = 0;
        int32_t ceiling_row_cursor = 0;
        int32_t resource_cursor = 0;
        int32_t cadence_cursor = 0;
        int32_t family_founding_cursor = 0;
        // BEGIN army personnel lane (contract §1.5): PKEC section 36 cursor.
        int32_t army_personnel_cursor = 0;
        // END army personnel lane
        std::vector<int32_t> family_founding_cells;
        std::vector<uint8_t> modifier_bytes;
        size_t modifier_cursor = 0;
        bool end_emitted = false;
    };

    struct RestoreState {
        bool active = false;
        // Live lanes stay intact until prepare_restore_candidate_scratch() runs
        // (only from the ECP2 backup/rollback transaction). Streaming feed
        // rejects chunks while this is false so begin_restore alone cannot
        // wipe or partially overwrite a committed snapshot.
        bool scratch_prepared = false;
        // BEGIN army personnel lane (contract §1.5): section 36 scratch guard.
        bool army_personnel_seen = false;
        // END army personnel lane
        bool header_seen = false;
        bool end_seen = false;
        bool ceilings_seen = false;
        int64_t expected_ceilings = 0;
        int64_t restored_ceilings = 0;
        int64_t last_ceiling_key = -1;
        bool failed = false;
        std::string error;
        int32_t expected_pages = 0;
        int32_t expected_commands = 0;
        int32_t expected_buildings = 0;
        int32_t expected_construction = 0;
        int32_t restored_pages = 0;
        int32_t restored_markets = 0;
        int32_t restored_cells = 0;
        int32_t restored_commands = 0;
        int32_t schema_version = 0;
        int64_t environment_hash = 0;
        int32_t restored_buildings = 0;
        int32_t restored_construction = 0;
        int32_t expected_audits = 0;
        int32_t restored_audits = 0;
        int32_t expected_signals = 0;
        int32_t restored_signals = 0;
        int32_t expected_labor_signals = 0;
        int32_t restored_labor_signals = 0;
        int32_t expected_trade_orders = 0;
        int32_t restored_trade_orders = 0;
        int32_t expected_trade_flows = 0;
        int32_t restored_trade_flows = 0;
        int32_t expected_tariff_history = 0;
        int32_t restored_tariff_history = 0;
        int32_t expected_country_good = 0;
        int32_t restored_country_good = 0;
        int32_t expected_country_partner = 0;
        int32_t restored_country_partner = 0;
        int32_t expected_canal_quotes = 0;
        int32_t restored_canal_quotes = 0;
        int32_t expected_canal_projects = 0;
        int32_t restored_canal_projects = 0;
        int32_t expected_persons = 0;
        int32_t expected_person_needs = 0;
        int32_t expected_fiscal = -1;
        int32_t restored_fiscal = 0;
        int32_t expected_fiscal_peer = -1;
        int32_t restored_fiscal_peer = 0;
        int32_t expected_d7_peer_ext = -1;
        int32_t restored_d7_peer_ext = 0;
        int64_t expected_resource_rows = 0;
        int64_t restored_resource_rows = 0;
        int64_t last_resource_key = -1;
        int32_t last_signal_cell = -1;
        int32_t last_signal_good = -1;
        int32_t last_labor_cell = -1;
        int32_t last_labor_profession = -1;
        std::vector<uint8_t> modifier_bytes;
        bool modifier_seen = false;
        bool fiscal_seen = false;
        bool fiscal_peer_seen = false;
        bool d7_peer_ext_seen = false;
        bool family_founding_seen = false;
        int32_t expected_family_founding_records = -1;
        int32_t restored_family_founding_records = 0;
        bool resource_stock_seen = false;
        bool cadence_state_seen = false;
        int32_t restored_cadence_cells = 0;
        bool committed_generation_seen = false;
        uint64_t restored_committed_generation = 0;
        std::vector<int32_t> track_b_investment_cells_pending;
        int64_t track_b_derived_cell_cache_day = -1000000;
        std::vector<TrackBDerivedCellWork> track_b_derived_cell_cache;
        bool settlement_names_seen = false;
        int32_t restored_families = 0;
        int32_t restored_family_memberships = 0;
        int32_t restored_family_ownerships = 0;
        std::vector<int32_t> family_colonization_population_reward_pending;
        bool family_records_seen = false;
        bool family_membership_seen = false;
        bool family_ownership_seen = false;
        int32_t restored_persons = 0;
        int32_t restored_person_needs = 0;
        bool person_records_seen = false;
        bool person_needs_seen = false;
        int32_t restored_family_traits = 0;
        int32_t restored_family_influences = 0;
        int32_t restored_family_trait_commands = 0;
        int32_t expected_family_traits = 0;
        int32_t expected_family_influences = 0;
        int32_t expected_family_trait_commands = 0;
        bool family_traits_seen = false;
        bool family_influences_seen = false;
        bool family_trait_commands_seen = false;
        int32_t expected_family_expedition_slots = 0;
        int32_t expected_family_expeditions = 0;
        int32_t restored_family_expedition_slots = 0;
        int32_t restored_family_expeditions = 0;
        bool family_expeditions_seen = false;
        bool tariff_history_seen = false;
        bool country_good_seen = false;
        bool country_partner_seen = false;
        bool canal_quotes_seen = false;
        bool canal_projects_seen = false;
    };

    struct EventArchiveState {
        bool active = false;
        bool header_emitted = false;
        bool end_emitted = false;
        int32_t chunk_bytes = 4 * 1024 * 1024;
        size_t batch_limit = 0;
        size_t batch_cursor = 0;
        size_t event_cursor = 0;
    };

    bool _configured = false;
    bool _bootstrapped = false;
    bool _epoch_active = false;
    bool _fatal = false;
    std::string _fatal_reason;
    // Forensics captured at the instant fail() runs. Without it a fatal only
    // reports a reason string, and the conservation numbers next to it describe
    // a half-open epoch rather than the failure — which is how a cohort-cash
    // boundary stop used to read as a money-conservation bug in the GM panel.
    struct FatalContext {
        bool valid = false;
        std::string reason;
        std::string executed_substage;
        int32_t stage = 0;
        int32_t executed_stage = 0;
        int64_t day = 0;
        int64_t epoch_id = 0;
        int32_t command_cursor = -1;
        int32_t structural_cursor = -1;
        int32_t command_opcode = 0;
        int64_t target_handle = 0;
        int64_t subject_handle = 0;
        int64_t amount = 0;
        uint32_t d7_operation_gate_mask = 0;
        bool country_sync_writes_forbidden = false;
        bool country_worker_authoritative = false;
    };
    FatalContext _fatal_context;
    // Closing audit totals are only meaningful once PublishPhase::VERIFY has
    // recomputed them. A mid-epoch fatal leaves the previous epoch's snapshot
    // in place, so the three conservation errors must be reported as unknown
    // rather than as a real imbalance.
    bool _closing_totals_valid = false;
    Stage _stage = Stage::IDLE;
    bool _epoch_begin_post_fiscal_pending = false;
    int64_t _epoch_begin_pending_day = -1;
    Stage _executed_stage = Stage::IDLE;
    std::string _executed_substage;
    PublishPhase _publish_phase = PublishPhase::PREPARE;
    size_t _publish_cursor = 0;
    bool _publish_commit_initialized = false;
    int32_t _publish_order_cursor = 0;
    int32_t _publish_line_cursor = 0;
    int64_t _publish_valuation_sat = 0;
    int64_t _publish_trade_alpha = 0;
    bool _publish_have_populated = false;
    TradePlanInitState _trade_plan_init;

    ChangeRegistry _metadata_changes;
    EconomyTrackedScalar<int32_t> _cell_count{_metadata_changes, {{15, 4}, "metadata.cell_count", EconomyFieldEncoding::I32, 4}, 0};
    int32_t _cells_per_slice = 256;
    bool _auto_slice_by_scale = true;
    int32_t _building_cells_per_slice = AUTO_BUILDING_CELLS_PER_SLICE;
    int32_t _building_groups_per_slice = 512;
    int32_t _building_plan_cells_per_slice_override = 0;
    int32_t _household_post_building_cells_per_slice_override = 0;
    int32_t _investment_cells_per_slice =
        AUTO_INVESTMENT_CELLS_PER_SLICE;
    int32_t _building_finalize_cells_per_slice =
        AUTO_BUILDING_FINALIZE_CELLS_PER_SLICE;
    int32_t _building_output_efficiency_q16 = Q16_ONE;
    bool _auto_building_slice_by_scale = true;
    int32_t _commands_per_slice = 16384;
    EconomyTrackedScalar<int32_t> _epoch_days{_metadata_changes, {{15, 12}, "metadata.epoch_days", EconomyFieldEncoding::I32, 4}, 1};
    // 本 epoch 每格各自的未结算天数，以及全局取 min 造成的天数丢失量。
    // _epoch_days 是所有结算格的最小值：分桶齐整时每格相同、丢失恒为 0；新格上线
    // 或 cadence 重锁会让同批格的 elapsed 不齐，落后格的差额当前被直接丢弃。
    std::vector<int32_t> _cell_elapsed_days;
    // 活跃度分级（阶段 6）。当前只观测：分级结果进直方图与 report，不参与工作集
    // 选择，所以逐日数值与分级前逐位相同。要让 T2/T3 真正降频，前提是同一天内不同
    // 格能用不同的 dt，而 _epoch_days 是每 epoch 一个标量，见 cell_elapsed_days。
    EconomyOwnedColumn<uint8_t> _cell_tier{{{16, 33}, "persisted_columns.cell_tier", EconomyFieldEncoding::U8, 1}};
    EconomyOwnedColumn<int64_t> _cell_next_review_day{{{16, 31}, "persisted_columns.cell_next_review_day", EconomyFieldEncoding::I64, 8}};
    EconomyOwnedColumn<uint8_t> _cell_force_wake{{{16, 30}, "persisted_columns.cell_force_wake", EconomyFieldEncoding::U8, 1}};
    EconomyOwnedColumn<uint32_t> _cell_tier_seen_gen{{{16, 35}, "persisted_columns.cell_tier_seen_gen", EconomyFieldEncoding::U32, 4}};
    EconomyOwnedColumn<int64_t> _cell_tier_seen_population{{{16, 36}, "persisted_columns.cell_tier_seen_population", EconomyFieldEncoding::I64, 8}};
    EconomyOwnedColumn<int64_t> _cell_tier_change_day{{{16, 34}, "persisted_columns.cell_tier_change_day", EconomyFieldEncoding::I64, 8}};
    EconomyOwnedColumn<int64_t> _cell_shortage_since_day{{{16, 32}, "persisted_columns.cell_shortage_since_day", EconomyFieldEncoding::I64, 8}};
    std::vector<int64_t> _cell_population_total;
    static constexpr int32_t SHORTAGE_ACUTE_DAYS = 10;
    int64_t _tier_histogram[4] = {0, 0, 0, 0};
    int64_t _tier_reason_histogram[11] = {0};
    int64_t _tier_forced_wakes = 0;
    int32_t _epoch_elapsed_days_max = 0;
    int32_t _epoch_elapsed_days_spread_cells = 0;
    int64_t _epoch_elapsed_days_lost = 0;
    int64_t _total_elapsed_days_lost = 0;
    int32_t _peak_elapsed_days_spread_cells = 0;
    int32_t _configured_epoch_days = MARKET_CYCLE_MAX_DAYS;
    int32_t _min_epoch_days = MARKET_CYCLE_MIN_DAYS;
    int32_t _max_epoch_days = MARKET_CYCLE_MAX_DAYS;
    EconomyTrackedScalar<int32_t> _locked_market_cycle_days{_metadata_changes, {{15, 20}, "metadata.locked_market_cycle_days", EconomyFieldEncoding::I32, 4}, MARKET_CYCLE_MIN_DAYS};
    EconomyTrackedScalar<int64_t> _market_cycle_start_day{_metadata_changes, {{15, 22}, "metadata.market_cycle_start_day", EconomyFieldEncoding::I64, 8}, 0};
    EconomyTrackedScalar<int32_t> _locked_slow_cycle_days{_metadata_changes, {{15, 21}, "metadata.locked_slow_cycle_days", EconomyFieldEncoding::I32, 4}, PLAN_CYCLE_MIN_DAYS};
    EconomyTrackedScalar<int64_t> _slow_cycle_start_day{_metadata_changes, {{15, 28}, "metadata.slow_cycle_start_day", EconomyFieldEncoding::I64, 8}, 0};
    EconomyTrackedScalar<int32_t> _locked_investment_cycle_days{_metadata_changes, {{15, 19}, "metadata.locked_investment_cycle_days", EconomyFieldEncoding::I32, 4}, INVEST_CYCLE_MIN_DAYS};
    EconomyTrackedScalar<int64_t> _investment_cycle_start_day{_metadata_changes, {{15, 17}, "metadata.investment_cycle_start_day", EconomyFieldEncoding::I64, 8}, 0};
    int32_t _slow_cycle_min_days = PLAN_CYCLE_MIN_DAYS;
    int32_t _slow_cycle_max_days = PLAN_CYCLE_MAX_DAYS;
    int32_t _invest_cycle_min_days = INVEST_CYCLE_MIN_DAYS;
    int32_t _invest_cycle_max_days = INVEST_CYCLE_MAX_DAYS;
    bool _cadence_initialized = false;
    double _cadence_target_ms = 8.0;
    double _injected_cycle_market_ms = -1.0;
    double _injected_cycle_slow_ms = -1.0;
    double _injected_cycle_investment_ms = -1.0;
    int32_t _forced_market_cycle_days = 0;
    int32_t _forced_slow_cycle_days = 0;
    int32_t _forced_investment_cycle_days = 0;
    double _market_ms_per_knife_ema = 0.0;
    double _slow_ms_per_knife_ema = 0.0;
    double _investment_ms_per_knife_ema = 0.0;
    double _cycle_market_ms_accum = 0.0;
    double _cycle_slow_ms_accum = 0.0;
    double _cycle_investment_ms_accum = 0.0;
    int32_t _estimated_populated_market_knives = 1;
    int32_t _estimated_slow_knives = 1;
    int32_t _estimated_investment_knives = 1;
    int32_t _cadence_machine_knives_per_day = 64;
    int32_t _cadence_slow_knives_per_day = 64;
    int32_t _cadence_investment_knives_per_day = 64;
    int32_t _cadence_change_reason = 1;
    int32_t _estimated_market_slices_per_epoch = 1;
    int32_t _estimated_building_slices_per_epoch = 0;
    int32_t _estimated_total_slices_per_epoch = 1;
    bool _workload_deadline_feasible = true;
    bool _workload_cycle_clamped = false;
    int64_t _configured_target_cohorts_per_slice = 0;
    int64_t _target_cohorts_per_slice = 30000;
    int32_t _commit_lag_budget_days = 0;
    int32_t _max_rules_per_plan = MAX_RULES_PER_PLAN;
    int64_t _wealth_reference_per_capita = MONEY_SCALE * 10;
    int32_t _living_cost_base_plan_id = -1;
    std::string _living_cost_base_plan_stable_id = "survival_household";
    std::vector<int32_t> _survival_food_need_stable_ids;
    std::vector<uint8_t> _survival_food_need_mask;
    std::vector<int32_t> _survival_required_need_indices;
    std::vector<uint8_t> _survival_food_good_mask;
    // Q16 standard-food-equivalent per goods subunit, compiled from the
    // survival household component quantities. Zero means non-food.
    std::vector<int32_t> _good_food_equivalent_q16;
    // Ascending positive-coefficient goods; derived catalog index, not state.
    std::vector<int32_t> _food_equivalent_goods;
    std::vector<uint8_t> _survival_clothing_good_mask;
    int32_t _survival_clothing_need_stable_id = -1;
    int32_t _starvation_satisfaction_threshold_q16 = Q16_ONE / 2;
    int32_t _survival_production_target_q16 = Q16_ONE;
    int64_t _starvation_death_rate_q32 = Q32_ONE / 200;
    // Composite satisfaction tuning. Weights are authored per profession; these
    // are the profile-wide fallbacks and the shared normalization references.
    std::array<int32_t, SAT_DIM_COUNT> _satisfaction_default_weights_q16 = {
        65536, 45875, 26214, 13107, 19661, 19661, 16384, 13107};
    int32_t _satisfaction_subsistence_gate_slack_q16 = 6554;
    int32_t _satisfaction_basic_gate_slack_q16 = 13107;
    int32_t _satisfaction_income_growth_floor_q16 = 58982;
    int32_t _satisfaction_income_growth_ceiling_q16 = 78643;
    int32_t _satisfaction_income_baseline_alpha_q16 = 1024;
    int64_t _satisfaction_savings_target_months_q16 = 393216;
    int32_t _satisfaction_tax_tolerance_q16 = 22938;
    std::array<int32_t, SAT_DEVELOPMENT_INPUT_COUNT>
        _satisfaction_development_weights_q16 = {26214, 26214, 13107};
    int32_t _satisfaction_development_variety_target = 12;
    int32_t _satisfaction_birth_reference_q16 = 45875;
    int32_t _satisfaction_birth_bonus_reference_q16 = 55706;
    int64_t _carrying_k_habitat_ref = 40;
    int64_t _carrying_k_floor = 8;
    int32_t _carrying_river_bonus_q16 = 72090;
    int32_t _carrying_water_habitability_q16 = 49152;
    int32_t _carrying_surplus_elasticity_q16 = Q16_ONE / 2;
    int32_t _carrying_sat_elasticity_q16 = 22938;
    // Birth suppression starts at 90% of stock-inclusive carrying capacity.
    int32_t _carrying_soft_start_q16 = 58982;
    int32_t _carrying_stock_buffer_days = 30;
    int32_t _carrying_surplus_floor_q16 = 16384;
    int32_t _carrying_surplus_cap_q16 = 98304;
    int32_t _carrying_sat_floor_q16 = 8192;
    int32_t _carrying_sat_cap_q16 = 75366;
    int32_t _carrying_residual_floor_q16 = Q16_ONE / 2;
    int32_t _carrying_residual_cap_q16 = Q16_ONE * 2;
    int32_t _carrying_support_ema_alpha_q16 = 1024;
    int32_t _carrying_temp_opt_lo_q16 = 19661;
    int32_t _carrying_temp_opt_hi_q16 = 45875;
    int32_t _carrying_paw_opt_lo_q16 = 16384;
    int32_t _carrying_paw_opt_hi_q16 = 58982;
    std::vector<int32_t> _carrying_family_weight;
    std::vector<std::string> _carrying_profile_class_ids;
    std::vector<int32_t> _carrying_profile_class_weight_q16;
    std::vector<int32_t> _carrying_class_weight_q16;
    std::vector<int32_t> _carrying_landform_habitability_q16;
    std::vector<int32_t> _carrying_vegetation_habitability_q16;
    std::array<int32_t, SAT_PRESSURE_LEVEL_COUNT - 1>
        _satisfaction_pressure_thresholds_q16 = {13107, 26214, 39322, 52429};
    int32_t _wage_ema_alpha_q16 = 8192;
    EconomyTrackedScalar<int32_t> _employment_mobility_daily_q16{_metadata_changes, {{15, 8}, "metadata.employment_mobility_daily_q16", EconomyFieldEncoding::I32, 4}, 13107};
    // Extra hurdle when both source and target start understaffed and the source
    // still has positive opportunity income. Keeps opportunity-gradient flow
    // while suppressing small-gap understaffed↔understaffed thrashing.
    EconomyTrackedScalar<int32_t> _employment_understaffed_reallocation_hurdle_mult_q16{_metadata_changes, {{15, 9}, "metadata.employment_understaffed_reallocation_hurdle_mult_q16", EconomyFieldEncoding::I32, 4}, Q16_ONE * 2};
    // Authoritative understaffed↔understaffed reverse-move cooldown (simulation days).
    int32_t _employment_understaffed_mobility_cooldown_days = 30;
    EconomyTrackedScalar<int32_t> _employment_choice_temperature_q16{_metadata_changes, {{15, 7}, "metadata.employment_choice_temperature_q16", EconomyFieldEncoding::I32, 4}, 6554};
    int32_t _wage_max_rise_q16_per_day = 1311;
    int32_t _wage_max_fall_q16_per_day = 1311;
    // Damping: contract wage floor may not exceed the building's per-employee
    // affordable revenue times this ratio (Q16). Prevents living-cost floor from
    // pushing wages far beyond what the employer can pay. 0 disables the cap.
    int32_t _wage_income_cap_ratio_q16 = 78643; // ~1.2x
    int32_t _employee_profit_share_q16 = 16384;
    EconomyTrackedScalar<int32_t> _building_severe_loss_threshold_q16{_metadata_changes, {{15, 37}, "config.building_severe_loss_threshold_q16", EconomyFieldEncoding::I32, 4}, -16384};
    EconomyTrackedScalar<int32_t> _building_severe_loss_cycles{_metadata_changes, {{15, 36}, "config.building_severe_loss_cycles", EconomyFieldEncoding::I32, 4}, 3};
    EconomyTrackedScalar<int32_t> _building_restart_margin_q16{_metadata_changes, {{15, 35}, "config.building_restart_margin_q16", EconomyFieldEncoding::I32, 4}, 6554};
    EconomyTrackedScalar<int32_t> _building_restart_cycles{_metadata_changes, {{15, 34}, "config.building_restart_cycles", EconomyFieldEncoding::I32, 4}, 2};
    EconomyTrackedScalar<int32_t> _merchant_procurement_cash_reserve_q16{_metadata_changes, {{15, 66}, "config.merchant_procurement_cash_reserve_q16", EconomyFieldEncoding::I32, 4}, 8192};
    EconomyTrackedScalar<int32_t> _merchant_market_making_days_q16{_metadata_changes, {{15, 65}, "config.merchant_market_making_days_q16", EconomyFieldEncoding::I32, 4}, Q16_ONE * 60};
    EconomyTrackedScalar<int32_t> _merchant_credit_runtime_mode{_metadata_changes, {{15, 63}, "config.merchant_credit_runtime_mode", EconomyFieldEncoding::I32, 4}, 2}; // 0=OFF, 1=PROBE, 2=ACTIVE.
    EconomyTrackedScalar<int32_t> _merchant_credit_exposure_q16{_metadata_changes, {{15, 61}, "config.merchant_credit_exposure_q16", EconomyFieldEncoding::I32, 4}, 16384};
    EconomyTrackedScalar<int32_t> _merchant_credit_premium_q16{_metadata_changes, {{15, 62}, "config.merchant_credit_premium_q16", EconomyFieldEncoding::I32, 4}, 3277};
    EconomyTrackedScalar<int32_t> _merchant_credit_term_cycles{_metadata_changes, {{15, 64}, "config.merchant_credit_term_cycles", EconomyFieldEncoding::I32, 4}, 6};
    EconomyTrackedScalar<int32_t> _recovery_success_cycles{_metadata_changes, {{15, 82}, "config.recovery_success_cycles", EconomyFieldEncoding::I32, 4}, 2};
    // 73 five-day reviews are approximately one year. The old recovery name
    // is retained only for save/profile compatibility.
    EconomyTrackedScalar<int32_t> _recovery_liquidation_failed_reviews{_metadata_changes, {{15, 80}, "config.recovery_liquidation_failed_reviews", EconomyFieldEncoding::I32, 4}, 73};
    EconomyOwnedColumn<int32_t> _maintenance_horizon_days_by_sector{
        {{16, 51}, "config.maintenance_horizon_days_by_sector", EconomyFieldEncoding::I32, 4},
        {5475, 2920, 3650, 2190, 7300}};
    EconomyTrackedScalar<int32_t> _building_maintenance_cost_factor_q16{_metadata_changes, {{15, 32}, "config.building_maintenance_cost_factor_q16", EconomyFieldEncoding::I32, 4}, Q16_ONE};
    int32_t _merchant_profession_id = -1;
    std::string _merchant_profession_stable_id = "merchant";
    // Reserved profession representing unemployed population. Resolved from the
    // catalog like the merchant profession; used by the employment pass to keep
    // laid-off / idle population in dedicated unemployed signatures instead of
    // deriving unemployment as population - owner - employee. Never a building role.
    int32_t _unemployed_profession_id = -1;
    std::string _unemployed_profession_stable_id = "unemployed";
    int32_t _market_runtime_mode = 1; // 0=OFF, 1=PROBE, 2=ACTIVE.
    EconomyTrackedScalar<int32_t> _trade_runtime_mode{_metadata_changes, {{15, 30}, "metadata.trade_runtime_mode", EconomyFieldEncoding::I32, 4}, 2}; // 0=OFF, 1=PROBE, 2=ACTIVE.
    EconomyTrackedScalar<int32_t> _startup_demand_runtime_mode{_metadata_changes, {{15, 29}, "metadata.startup_demand_runtime_mode", EconomyFieldEncoding::I32, 4}, 1}; // 0=OFF, 1=ACTIVE.
    EconomyTrackedScalar<int64_t> _trade_capacity_per_merchant_q16{_metadata_changes, {{15, 87}, "config.trade_capacity_per_merchant_q16", EconomyFieldEncoding::I64, 8}, 64 * Q16_ONE};
    EconomyTrackedScalar<int32_t> _trade_speed_cost_per_day{_metadata_changes, {{15, 102}, "config.trade_speed_cost_per_day", EconomyFieldEncoding::I32, 4}, 4};
    EconomyTrackedScalar<int32_t> _trade_min_margin_q16{_metadata_changes, {{15, 97}, "config.trade_min_margin_q16", EconomyFieldEncoding::I32, 4}, 3277};
    EconomyTrackedScalar<int32_t> _trade_target_count{_metadata_changes, {{15, 103}, "config.trade_target_count", EconomyFieldEncoding::I32, 4}, 4};
    EconomyTrackedScalar<int32_t> _trade_signal_pairs_per_slice{_metadata_changes, {{15, 101}, "config.trade_signal_pairs_per_slice", EconomyFieldEncoding::I32, 4}, 4096};
    EconomyTrackedScalar<int32_t> _trade_route_searches_per_slice{_metadata_changes, {{15, 100}, "config.trade_route_searches_per_slice", EconomyFieldEncoding::I32, 4}, 32};
    EconomyTrackedScalar<int32_t> _trade_max_route_expansions{_metadata_changes, {{15, 94}, "config.trade_max_route_expansions", EconomyFieldEncoding::I32, 4}, 8192};
    EconomyTrackedScalar<int32_t> _trade_route_cache_entries{_metadata_changes, {{15, 99}, "config.trade_route_cache_entries", EconomyFieldEncoding::I32, 4}, 16384};
    EconomyTrackedScalar<int32_t> _trade_max_signals{_metadata_changes, {{15, 95}, "config.trade_max_signals", EconomyFieldEncoding::I32, 4}, 32768};
    EconomyTrackedScalar<int32_t> _trade_max_candidates{_metadata_changes, {{15, 92}, "config.trade_max_candidates", EconomyFieldEncoding::I32, 4}, 8192};
    EconomyTrackedScalar<int32_t> _trade_max_orders{_metadata_changes, {{15, 93}, "config.trade_max_orders", EconomyFieldEncoding::I32, 4}, 4096};
    EconomyTrackedScalar<int32_t> _trade_flow_ema_alpha_q16{_metadata_changes, {{15, 90}, "config.trade_flow_ema_alpha_q16", EconomyFieldEncoding::I32, 4}, 8192};
    EconomyTrackedScalar<int32_t> _trade_max_stock_share_q16{_metadata_changes, {{15, 96}, "config.trade_max_stock_share_q16", EconomyFieldEncoding::I32, 4}, 16384};
    EconomyTrackedScalar<int32_t> _trade_export_floor_days{_metadata_changes, {{15, 88}, "config.trade_export_floor_days", EconomyFieldEncoding::I32, 4}, 5};
    EconomyTrackedScalar<int32_t> _trade_export_inventory_fraction_q16{_metadata_changes, {{15, 89}, "config.trade_export_inventory_fraction_q16", EconomyFieldEncoding::I32, 4}, Q16_ONE / 2};
    EconomyTrackedScalar<int32_t> _trade_import_fill_fraction_q16{_metadata_changes, {{15, 91}, "config.trade_import_fill_fraction_q16", EconomyFieldEncoding::I32, 4}, Q16_ONE / 2};
    EconomyTrackedScalar<int32_t> _trade_response_days{_metadata_changes, {{15, 98}, "config.trade_response_days", EconomyFieldEncoding::I32, 4}, 15};
    EconomyTrackedScalar<int32_t> _investment_review_days{_metadata_changes, {{15, 60}, "config.investment_review_days", EconomyFieldEncoding::I32, 4}, 30};
    // Locked slow-cycle length S. Plan evaluation and investment review share
    // this value. Profile 10/30 are range hints and v37 restore compatibility,
    // not a fixed production cadence.
    EconomyTrackedScalar<int32_t> _building_plan_days{_metadata_changes, {{15, 33}, "config.building_plan_days", EconomyFieldEncoding::I32, 4}, 10};
    EconomyTrackedScalar<int32_t> _investment_min_shortage_q16{_metadata_changes, {{15, 55}, "config.investment_min_shortage_q16", EconomyFieldEncoding::I32, 4}, Q16_ONE / 8};
    EconomyTrackedScalar<int32_t> _investment_min_utilization_q16{_metadata_changes, {{15, 56}, "config.investment_min_utilization_q16", EconomyFieldEncoding::I32, 4}, 42598};
    EconomyTrackedScalar<int32_t> _investment_max_payback_days{_metadata_changes, {{15, 52}, "config.investment_max_payback_days", EconomyFieldEncoding::I32, 4}, 365};
    EconomyTrackedScalar<int32_t> _investment_operating_cycles{_metadata_changes, {{15, 58}, "config.investment_operating_cycles", EconomyFieldEncoding::I32, 4}, 2};
    EconomyTrackedScalar<int32_t> _investment_gap_fill_share_q16{_metadata_changes, {{15, 50}, "config.investment_gap_fill_share_q16", EconomyFieldEncoding::I32, 4}, Q16_ONE / 4};
    EconomyTrackedScalar<int32_t> _investment_portfolio_max_types{_metadata_changes, {{15, 59}, "config.investment_portfolio_max_types", EconomyFieldEncoding::I32, 4}, 4};
    EconomyTrackedScalar<int32_t> _investment_max_type_owner_share_q16{_metadata_changes, {{15, 53}, "config.investment_max_type_owner_share_q16", EconomyFieldEncoding::I32, 4}, Q16_ONE / 2};
    EconomyTrackedScalar<int32_t> _investment_max_growth_share_q16{_metadata_changes, {{15, 51}, "config.investment_max_growth_share_q16", EconomyFieldEncoding::I32, 4}, 16384};
    EconomyTrackedScalar<int32_t> _investment_new_type_seed_buildings{_metadata_changes, {{15, 57}, "config.investment_new_type_seed_buildings", EconomyFieldEncoding::I32, 4}, 1};
    int32_t _investment_displacement_min_advantage_q16 = Q16_ONE / 16;
    EconomyTrackedScalar<int32_t> _investment_merchant_transition_min_improvement_q16{_metadata_changes, {{15, 54}, "config.investment_merchant_transition_min_improvement_q16", EconomyFieldEncoding::I32, 4}, Q16_ONE / 2};
    int32_t _investment_sparse_mode = 2;
    EconomyTrackedScalar<int32_t> _recovery_liquidation_max_share_q16{_metadata_changes, {{15, 81}, "config.recovery_liquidation_max_share_q16", EconomyFieldEncoding::I32, 4}, Q16_ONE / 4};
    EconomyTrackedScalar<int32_t> _resource_min_reserve_q16{_metadata_changes, {{15, 84}, "config.resource_min_reserve_q16", EconomyFieldEncoding::I32, 4}, 22938};
    // Zero is open access. Positive values enable the optional managed
    // safe-harvest budget.
    EconomyTrackedScalar<int32_t> _resource_safe_harvest_q16{_metadata_changes, {{15, 85}, "config.resource_safe_harvest_q16", EconomyFieldEncoding::I32, 4}, 0};
    EconomyTrackedScalar<int32_t> _resource_min_horizon_days{_metadata_changes, {{15, 83}, "config.resource_min_horizon_days", EconomyFieldEncoding::I32, 4}, 3650};
    EconomyTrackedScalar<int32_t> _bullion_monthly_issue_cap_q16{_metadata_changes, {{15, 38}, "config.bullion_monthly_issue_cap_q16", EconomyFieldEncoding::I32, 4}, 655};
    EconomyTrackedScalar<int32_t> _producer_support_monthly_cap_q16{_metadata_changes, {{15, 79}, "config.producer_support_monthly_cap_q16", EconomyFieldEncoding::I32, 4}, 3277};
    bool _worker_enabled = true;
    int32_t _worker_market_threshold = 256;
    int32_t _worker_tasks_hint = 0;
    int32_t _worker_task_cap = 6;
    bool _high_speed_batching_enabled = true;
    int32_t _full_audit_verify_interval_days = 25;
    // Closing audit mode: 0=FULL, 1=PROBE, 2=INCREMENTAL.
    int32_t _closing_audit_mode = 2;
    bool _closing_audit_runtime_disabled = false;
    bool _closing_audit_force_full = true;
    bool _closing_audit_incremental_this_epoch = false;
    // A full audit forced by army-lane drift cannot be compared against the
    // incremental shadow: the shadow re-reads lanes live and would always differ.
    bool _closing_audit_lane_full = false;
    // Accuracy policy: 0=EXACT, 1=BALANCED, 2=FAST, 3=CUSTOM.
    // Runtime mode: 0=OFF, 1=PROBE (exact authority), 2=ACTIVE.
    int32_t _accuracy_preset = 1;
    int32_t _approximation_runtime_mode = 2;
    int32_t _accuracy_max_regret_q16 = 1966;
    int32_t _accuracy_household_tail_share_q16 = 655;
    int32_t _accuracy_candidate_top_k = 2;
    int32_t _accuracy_choice_temperature_q16 = 983;
    int32_t _accuracy_exact_probe_rate_q16 = 655;
    int32_t _accuracy_fallback_cooldown_epochs = 10;
    EconomyTrackedScalar<int64_t> _seed{_metadata_changes, {{15, 86}, "config.seed", EconomyFieldEncoding::I64, 8}, 0};
    EconomyTrackedScalar<int64_t> _catalog_hash{_metadata_changes, {{15, 3}, "metadata.catalog_hash", EconomyFieldEncoding::I64, 8}, 0};
    int64_t _catalog_compat_hash_v6 = 0;
    EconomyTrackedScalar<int64_t> _epoch_id{_metadata_changes, {{15, 13}, "metadata.epoch_id", EconomyFieldEncoding::I64, 8}, 0};
    uint64_t _committed_generation = 1;
    int64_t _sample_day = -1;
    EconomyTrackedScalar<int64_t> _current_day{_metadata_changes, {{15, 6}, "metadata.current_day", EconomyFieldEncoding::I64, 8}, -1};
    int64_t _commit_day = -1;
    EconomyTrackedScalar<int64_t> _last_committed_day{_metadata_changes, {{15, 18}, "metadata.last_committed_day", EconomyFieldEncoding::I64, 8}, -1};
    int64_t _explicit_money_mint = 0;
    int64_t _explicit_money_burn = 0;
    int64_t _external_population_delta = 0;
    int64_t _explicit_stock_delta = 0;
    int64_t _country_research_consumed_opening = 0;
    int64_t _country_research_goods_consumed = 0;
    int64_t _consumed_goods = 0;
    int64_t _births = 0;
    int64_t _deaths = 0;
    // Epoch-local per-cell demography attribution for recorder diagnostics.
    std::vector<int64_t> _cell_births;
    std::vector<int64_t> _cell_deaths;
    std::vector<int64_t> _cell_moved_in;
    std::vector<int64_t> _cell_moved_out;
    int64_t _saturation_count = 0;
    EconomyTrackedScalar<uint64_t> _next_submit_order{_metadata_changes, {{15, 72}, "config.next_submit_order", EconomyFieldEncoding::U64, 8}, 1};

    int32_t _cell_cursor = 0;
    int32_t _command_cursor = 0;
    int32_t _structural_cursor = 0;
    int32_t _building_cell_cursor = 0;
    // Cursor over _epoch_plan_cells for the BUILDING_PLAN evaluate phase.
    // Reserve still walks the full _epoch_building_cells via
    // _building_cell_cursor so production always sees a coherent (possibly
    // stale up to _building_plan_days) per-group plan snapshot.
    int32_t _plan_evaluate_cursor = 0;
    int32_t _building_plan_phase = 0;
    int32_t _household_market_phase = 0;
    int32_t _household_post_cursor = 0;
    int32_t _building_commit_phase = 0;
    int32_t _building_commit_cursor = 0;
    int32_t _building_finalize_phase = 0;
    int32_t _family_commit_cursor = 0;
    std::vector<int32_t> _family_review_cells_scratch;
    int32_t _family_commit_phase = 0;
    int32_t _person_commit_cursor = 0;
    int32_t _person_commit_phase = 0;
    int32_t _processed_cells = 0;
    int64_t _processed_cohorts = 0;
    int64_t _processed_rules = 0;
    int64_t _processed_needs = 0;
    int64_t _processed_variants = 0;
    int64_t _processed_components = 0;
    int64_t _processed_commands = 0;
    int64_t _rejected_commands = 0;
    int64_t _merchant_repairs = 0;
    int64_t _price_cap_hits = 0;
    int64_t _price_rate_clamp_hits = 0;
    int64_t _price_numeric_floor_hits = 0;
    int64_t _price_numeric_ceiling_hits = 0;
    int64_t _price_min_tick_hits = 0;
    int64_t _price_glut_cost_damp_hits = 0;
    int64_t _small_payment_roundups = 0;
    int64_t _price_rise_fade_hits = 0;
    int64_t _price_headroom_damp_hits = 0;
    int64_t _price_catalog_bound_hits = 0;
    int64_t _price_cost_anchor_hits = 0;
    int64_t _price_inactive_reversions = 0;
    int64_t _continuation_slices = 0;
    int64_t _processed_building_groups = 0;
    int64_t _climate_profiled_building_groups = 0;
    int64_t _climate_limited_building_groups = 0;
    int64_t _climate_capacity_sum_q16 = 0;
    int64_t _filled_owner_jobs = 0;
    int64_t _filled_employee_jobs = 0;
    int64_t _unemployed_population = 0;
    int64_t _families_formed = 0;
    int64_t _family_offers_opened = 0;
    int64_t _family_offers_auto_resolved = 0;
    int64_t _family_offer_choice_rejected = 0;
    int64_t _family_offers_voided = 0;
    int64_t _families_dissolved = 0;
    int64_t _family_membership_edges_processed = 0;
    int64_t _family_ownership_edges_processed = 0;
    int64_t _family_owner_jobs_filled = 0;
    int64_t _family_owner_jobs_vacant = 0;
    int64_t _persons_promoted = 0;
    int64_t _persons_died = 0;
    int64_t _persons_migrated = 0;
    int64_t _person_jobs_bound = 0;
    int64_t _person_need_edges_processed = 0;
    int64_t _construction_goods_consumed = 0;
    int64_t _building_structure_count_only_updates = 0;
    int64_t _building_structure_new_groups = 0;
    int64_t _building_structure_removed_groups = 0;
    int64_t _building_structure_topology_rebuilds = 0;
    int64_t _building_structure_role_span_reuses = 0;
    int64_t _building_structure_role_span_appends = 0;
    int64_t _building_investment_candidates = 0;
    int64_t _building_owner_mobility = 0;
    int64_t _building_owner_job_reallocations = 0;
    int64_t _building_owner_understaffed_reallocations = 0;
    int64_t _building_owner_job_profession_changes = 0;
    int64_t _building_owner_job_probability_skips = 0;
    int64_t _building_employee_to_owner_reallocations = 0;
    int64_t _building_employee_job_reallocations = 0;
    int64_t _building_employee_job_profession_changes = 0;
    // Heads forced off zero/negative-income seats while distressed so they
    // can re-enter via unemployed → survival-food hire in the same period.
    int64_t _building_distress_career_exits = 0;
    int64_t _building_employee_job_hurdle_rejections = 0;
    int64_t _building_employee_cold_start_forecasts = 0;
    int64_t _building_employee_funding_limited_forecasts = 0;
    int64_t _building_investments_started = 0;
    int64_t _building_investment_blocked_funds = 0;
    int64_t _building_investment_blocked_materials = 0;
    int64_t _building_investment_blocked_sponsor_capital = 0;
    int64_t _building_investment_blocked_resources = 0;
    int64_t _building_investment_probability_skips = 0;
    int64_t _building_investment_capital_transferred = 0;
    int64_t _building_investment_buildings_started = 0;
    int64_t _building_investment_portfolios_started = 0;
    int64_t _building_investment_types_started = 0;
    int64_t _building_investment_owner_population_moved = 0;
    int64_t _building_investment_max_type_owner_share_q16 = 0;
    int64_t _building_investment_demand_limited = 0;
    int64_t _building_investment_material_limited = 0;
    int64_t _building_investment_capital_limited = 0;
    // 下单前按共用库存重算发票时，因超出资金包络而被砍掉的栋数。
    int64_t _building_investment_cost_envelope_trimmed = 0;
    int64_t _building_investment_owner_population_limited = 0;
    int64_t _building_investment_jobs_started = 0;
    int64_t _building_investment_employment_gap = 0;
    int64_t _building_investment_employment_catchup_cells = 0;
    int64_t _building_investment_displacement_starts = 0;
    int64_t _building_survival_priority_candidates = 0;
    int64_t _building_owner_opportunity_quotes = 0;
    int64_t _building_owner_opportunity_zero_feasible = 0;
    int64_t _building_owner_survival_reallocations = 0;
    int64_t _bullion_quota_pressure_clamps = 0;
    int64_t _bullion_quote_overallocation_prevented = 0;
    int64_t _desired_business_demand = 0;
    int64_t _funded_business_demand = 0;
    int64_t _unfunded_business_demand = 0;
    // ACTIVE groups that retained purchase intent but could not fund inputs.
    // Must not be recorded as SUSPENDED_LOSS or severe-loss financing failure.
    int64_t _active_unfunded_building_groups = 0;
    int64_t _derived_snapshot_generation = 0;
    uint64_t _derived_snapshot_hash = 0;
    int64_t _last_merchant_protected_rejects = 0;
    int64_t _owner_working_capital_allocated = 0;
    int64_t _merchant_credit_budget = 0;
    int64_t _merchant_credit_committed = 0;
    int64_t _merchant_credit_drawn = 0;
    int64_t _merchant_credit_repaid = 0;
    int64_t _merchant_credit_premium_repaid = 0;
    int64_t _merchant_credit_outstanding = 0;
    int64_t _merchant_credit_bad_debt = 0;
    int64_t _recovery_candidates = 0;
    int64_t _recovery_approved = 0;
    int64_t _recovery_restarted = 0;
    int64_t _recovery_failed = 0;
    int64_t _recovery_liquidated_buildings = 0;
    int64_t _recovery_partially_liquidated_buildings = 0;
    int64_t _recovery_fully_liquidated_groups = 0;
    int64_t _working_capital_scale_error_bound_q16 = 0;
    int64_t _production_inputs_consumed = 0;
    int64_t _production_output_stock = 0;
    int64_t _production_output_discarded = 0;
    int64_t _production_output_retained = 0;
    int64_t _production_output_supported = 0;
    int64_t _owner_output_consumed = 0;
    int64_t _producer_revenue = 0;
	int64_t _producer_support_money_issued = 0;
	int64_t _bullion_money_issued = 0;
	// Bullion (gold/silver) physically absorbed by the mint each epoch. The
	// monetary system consumes the sold batch: the coined goods leave market
	// stock instead of accumulating as ghost inventory. Tracked as an explicit
	// goods-conservation sink so closing stock stays balanced.
	int64_t _bullion_stock_consumed = 0;
	int64_t _gold_accepted = 0;
	int64_t _silver_accepted = 0;
	int64_t _gold_money_issued = 0;
	int64_t _silver_money_issued = 0;
	int64_t _cycle_flow_produced = 0;
	int64_t _cycle_flow_consumed = 0;
	int64_t _cycle_flow_discarded = 0;
    int64_t _building_wages_paid = 0;
    int64_t _building_wages_unpaid = 0;
    int64_t _building_base_wages_paid = 0;
    int64_t _building_base_wages_due = 0;
    int64_t _building_bonus_paid = 0;
    int64_t _building_bonus_due = 0;
    int64_t _wage_suspended_building_groups = 0;
    int64_t _loss_suspended_building_groups = 0;
    int64_t _merchant_procurement_budget = 0;
    int64_t _merchant_procurement_opportunity = 0;
    int64_t _merchant_procurement_allocated = 0;
    int64_t _merchant_procurement_unspent_allocated = 0;
    int64_t _merchant_procurement_reserved = 0;
    int64_t _owner_working_capital_reserved = 0;
    int64_t _merchant_procurement_spent = 0;
    int64_t _merchant_procurement_retail_value = 0;
    int64_t _merchant_procurement_factor_weighted_cash_q16 = 0;
    int64_t _merchant_survival_procurement_required = 0;
    int64_t _merchant_survival_procurement_allocated = 0;
    int64_t _merchant_input_procurement_required = 0;
    int64_t _merchant_input_procurement_allocated = 0;
    int64_t _merchant_trade_purchase_cash = 0;
    int64_t _merchant_trade_sale_cash = 0;
    EconomyTrackedScalar<int64_t> _government_research_procured_points{_metadata_changes, {{15, 47}, "config.government_research_procured_points", EconomyFieldEncoding::I64, 8}, 0};
    EconomyTrackedScalar<int64_t> _government_research_procurement_cash{_metadata_changes, {{15, 48}, "config.government_research_procurement_cash", EconomyFieldEncoding::I64, 8}, 0};
    EconomyTrackedScalar<int64_t> _government_research_procurement_orders{_metadata_changes, {{15, 49}, "config.government_research_procurement_orders", EconomyFieldEncoding::I64, 8}, 0};
    // Resumable government research procurement state. These vectors are
    // epoch-local continuation data: candidate ordering and country budget
    // decisions are captured once, then consumed in stable cursor order.
    std::vector<CountryResearchProcurementCandidate>
        _country_research_procurement_candidates;
    std::vector<int64_t> _country_research_procurement_budgets;
    std::vector<int64_t> _country_research_procurement_remaining;
    std::vector<uint8_t> _country_research_procurement_enabled;
    size_t _country_research_procurement_cursor = 0;
    int32_t _country_research_procurement_phase = 0;
    bool _country_research_procurement_initialized = false;
    bool _country_research_procurement_done = false;
    int64_t _country_research_procurement_slices = 0;
    int64_t _country_research_procurement_transactions = 0;
    int64_t _country_research_procurement_rejections = 0;
    CountryResearchProcurementContinuation _country_research_procurement_continuation;
    FamilyExpeditionProcurementContinuation
        _family_expedition_procurement_continuation;
    // Cancelled preparations whose Country leg was already in flight. The
    // Country side commits that leg regardless, so the matching merchant
    // credit (market purchase) or market return (treasury transfer) must still
    // run once the terminal arrives.
    std::vector<FamilyExpeditionProcurementContinuation>
        _family_expedition_procurement_orphans;
    std::unordered_map<int32_t, FamilyExpeditionProcurementRejection>
        _family_expedition_procurement_rejections;
    // ── National procurement budget + era procurement (transient) ──────────
    // docs/cpp-dots-runtime/era-advancement-runtime.md §2.2-2.4. Nothing here
    // enters PKEC, the state hash or the read-view authority: the player
    // session re-pushes policy/targets after load.
    struct EraProcurementLine {
        int32_t good = -1;
        int64_t required = 0;
        int64_t purchased_total = 0;
    };
    struct CountryProcurementState {
        uint64_t country_handle = 0;
        bool policy_enabled = false;
        int32_t treasury_share_bp = 0;
        int32_t research_share_bp = 0;
        // Shares of other_daily for era and colonization channels. -1 keeps
        // the legacy split when both channels have demand; 0 pauses a channel.
        int32_t era_share_bp = -1;
        int32_t colonization_share_bp = -1;
        bool era_active = false;
        std::vector<EraProcurementLine> era_goods;
        // Frozen at epoch begin (MONEY_SCALE per day).
        int64_t national_daily = 0;
        int64_t research_daily = 0;
        int64_t other_daily = 0;
        int64_t era_daily = 0;
        int64_t colonization_daily = 0;
        // Colonization allowance refilled per day, capped at one epoch.
        int64_t colonization_allowance = 0;
        int64_t colonization_allowance_day = -1;
        int64_t era_cash_spent_total = 0;
        int64_t era_cash_epoch = 0;
        int64_t era_last_epoch_cash = 0;
        int64_t research_cash_epoch = 0;
        int64_t research_cash_last_epoch = 0;
        int64_t colonization_cash_epoch = 0;
        int64_t colonization_cash_last_epoch = 0;
    };
    struct PendingProcurementUpdate {
        int32_t kind = 0; // 1=policy, 2=era target
        uint64_t country_handle = 0;
        bool flag = false;
        int32_t treasury_share_bp = 0;
        int32_t research_share_bp = 0;
        int32_t era_share_bp = -1;
        int32_t colonization_share_bp = -1;
        std::vector<int32_t> goods;
        std::vector<int64_t> quantities;
        int64_t effective_day = 0;
        int64_t sequence = 0;
        uint64_t order = 0;
    };
    struct ProcurementInbox {
        std::mutex mutex;
        std::vector<PendingProcurementUpdate> updates;
        uint64_t next_order = 1;
        // Latest requested configuration per handle, visible immediately to
        // snapshot readers even before the next epoch applies it.
        std::map<uint64_t, PendingProcurementUpdate> requested_policy;
        std::map<uint64_t, PendingProcurementUpdate> requested_era;
    };
    std::unique_ptr<ProcurementInbox> _procurement_inbox =
        std::make_unique<ProcurementInbox>();
    // Owner-thread state keyed by generation-safe country handle.
    std::map<uint64_t, CountryProcurementState> _country_procurement;
    // Transient monotone trade-order counters indexed by country slot and
    // stamped with the handle that owns the slot.
    std::vector<std::pair<uint64_t, int64_t>> _country_trade_orders_by_slot;
    struct EraProcurementCandidate {
        int32_t country = -1;
        int32_t line = -1;
        int32_t good = -1;
        int32_t market = -1;
        int64_t price = 0;
    };
    struct EraProcurementContinuation {
        bool active = false;
        int32_t phase = 0; // 1=country leg, 4=market/merchant apply
        int32_t country = -1;
        int32_t line = -1;
        int32_t market = -1;
        int32_t good = -1;
        int64_t quantity = 0;
        int64_t cash = 0;
        uint64_t transaction_id = 0;
        uint64_t session_epoch = 0;
        uint64_t country_generation = 0;
        uint64_t peer_generation = 0;
        uint64_t pending_request_id = 0;
        bool host_peer = false;
        bool market_applied = false;
        int64_t merchant_population = 0;
        std::vector<int32_t> living_merchants;
        std::vector<int64_t> merchant_weights;
        std::string last_error;
    };
    std::vector<EraProcurementCandidate> _era_procurement_candidates;
    std::vector<int64_t> _era_procurement_budgets;     // per epoch country
    std::vector<int64_t> _era_procurement_remaining;   // per (country,line) flattened
    std::vector<int32_t> _era_procurement_line_offsets; // per epoch country +1
    std::vector<uint64_t> _era_procurement_handles;    // per epoch country
    size_t _era_procurement_cursor = 0;
    bool _era_procurement_initialized = false;
    bool _era_procurement_done = false;
    int64_t _era_procurement_orders = 0;
    int64_t _era_procurement_rejections = 0;
    EraProcurementContinuation _era_procurement_continuation;
    std::vector<std::pair<uint64_t, int64_t>> _epoch_era_demand_by_cell;
    std::vector<std::pair<uint64_t, int64_t>> _epoch_era_demand_by_market;
    void apply_pending_procurement_updates(int64_t day_index);
    void freeze_epoch_procurement_budgets();
    void refresh_epoch_era_demand();
    void reset_era_procurement_epoch();
    void clear_procurement_runtime_state(bool clear_pending);
    CountryProcurementState *procurement_state_for_slot(int32_t country);
    const CountryProcurementState *procurement_state_for_slot(int32_t country) const;
    // Country research_procurement_policy with the national budget override.
    bool research_procurement_policy_for(int32_t country, bool &enabled,
                                         int64_t &daily_budget,
                                         int64_t &remaining_points) const;
    // -1 = no national policy (legacy behaviour); otherwise remaining cash
    // allowance for colonization procurement today.
    int64_t colonization_procurement_allowance(uint64_t country_handle, int64_t day);
    void consume_colonization_procurement_allowance(uint64_t country_handle,
                                                    int64_t cash);
    void note_procurement_cash(uint64_t country_handle, int32_t kind, int64_t cash);
    void note_trade_order_countries(int32_t source_cell, int32_t destination_cell);
    bool run_government_era_procurement(std::string &error);
    bool advance_era_procurement(EraProcurementContinuation &c, std::string &error);
    bool era_procurement_parked() const {
        return _era_procurement_continuation.active &&
            _era_procurement_continuation.pending_request_id != 0;
    }
    std::vector<int64_t> _merchant_procurement_paid_by_cell;
    std::vector<int64_t> _merchant_procurement_retail_by_cell;
    std::vector<int64_t> _merchant_procurement_factor_weighted_cash_by_cell;
    std::vector<int64_t> _merchant_trade_purchase_by_cell;
    std::vector<int64_t> _merchant_trade_sale_by_cell;
    std::vector<int64_t> _merchant_credit_drawn_by_cell;
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
