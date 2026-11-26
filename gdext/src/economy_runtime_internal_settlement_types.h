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
        bool military_order = false;
        bool demolishing = false;
        const char *step = "economy";
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
        // Sparse-workset probe (diagnostic only, never hashed, reset per epoch).
        int64_t workset_market_cells_due = 0;
        int64_t workset_building_cells = 0;
        int64_t workset_plan_cells = 0;
        int64_t workset_live_cells = 0;
        int64_t workset_coverage_permille = 0;
        int32_t workset_market_bucket = 0;
        int32_t workset_market_cycle_days = 0;
        int32_t workset_plan_cycle_days = 0;
        int32_t workset_cells_per_slice = 0;
        int64_t probe_slice_count = 0;
        int64_t probe_slice_budget_hits = 0;
        double probe_slice_ms_total = 0.0;
        double probe_slice_ms_max = 0.0;
        double probe_attempt_ms = 0.0;
        double probe_formula_ms = 0.0;
        double probe_publish_ms = 0.0;
        double probe_epoch_open_ms = 0.0;
        // Fixed-cost decomposition: boundary mirror split + trade planning.
        double probe_mirror_capture_ms = 0.0;
        double probe_mirror_import_ms = 0.0;
        double probe_trade_plan_ms = 0.0;
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

#include "economy_runtime_internal_settlement_types_archive.h"
#include "economy_runtime_internal_settlement_types_forensics.h"
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

#include "economy_runtime_internal_settlement_types_configuration.h"
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
#include "economy_runtime_internal_settlement_types_procurement.h"
#include "economy_runtime_internal_settlement_types_diagnostics.h"
