#include "economy_runtime.h"
#include "country_runtime.h"

#include <algorithm>
#include <chrono>
#include <limits>
#include <vector>

namespace pk {

namespace {
using Clock = std::chrono::steady_clock;

double elapsed_ms(const Clock::time_point &start) {
    return std::chrono::duration<double, std::milli>(Clock::now() - start).count();
}
} // namespace

void NativeEconomyRuntime::clear_epoch_metrics() {
    _families_formed = 0;
    _families_dissolved = 0;
    _family_membership_edges_processed = 0;
    _family_ownership_edges_processed = 0;
    _family_owner_jobs_filled = 0;
    _family_owner_jobs_vacant = 0;
    _persons_promoted = 0;
    _persons_died = 0;
    _persons_migrated = 0;
    _person_jobs_bound = 0;
    _person_need_edges_processed = 0;
    _person_commit_cursor = 0;
    _person_commit_phase = 0;
    _person_epoch_needs.clear();
    _person_opening_cash_claim = _persons.cash_claim;
    for (int32_t i = 0; i < static_cast<int32_t>(_persons.active.size()); ++i) {
        if (_persons.active[i] == 0) continue;
        _persons.epoch_job_income[i] = 0;
        _persons.epoch_business_result[i] = 0;
        _persons.epoch_consumption_expense[i] = 0;
        _persons.epoch_tax[i] = 0;
    }
    _epoch_business_demand_ema.clear();
    _epoch_desired_business_demand.clear();
    _epoch_funded_business_demand.clear();
    _epoch_offered_supply_ema.clear();
    _epoch_producer_sellable_current.clear();
    _epoch_producer_merchant_sold_current.clear();
    _epoch_producer_discarded_current.clear();
    _epoch_nonhousehold_withdrawals.clear();
    _epoch_cost_anchor_price.clear();
    _epoch_research_good_id = -1;
    _epoch_research_demand_by_cell.clear();
    _epoch_research_demand_by_market.clear();
    _owner_retained_outputs.clear();
    // Persistent sparse key set: each rolling phase contributes its changed
    // markets, so a planner generation covers the whole world without a dense
    // market x good scan.
    _cell_cursor = 0;
    _command_cursor = 0;
    _structural_cursor = 0;
    _building_cell_cursor = 0;
    _plan_evaluate_cursor = 0;
    _building_plan_phase = 0;
    _household_market_phase = 0;
    _household_post_cursor = 0;
    _building_commit_phase = 0;
    _building_commit_cursor = 0;
    _building_finalize_phase = 0;
    _investment_employment_cells.clear();
    _investment_review_cell_indices.clear();
    _processed_cells = 0;
    _processed_cohorts = 0;
    _processed_rules = 0;
    _processed_needs = 0;
    _processed_variants = 0;
    _processed_components = 0;
    _processed_commands = 0;
    _rejected_commands = 0;
    _merchant_repairs = 0;
    _price_cap_hits = 0;
    _price_cost_anchor_hits = 0;
    _price_inactive_reversions = 0;
    _continuation_slices = 0;
    _processed_building_groups = 0;
    _climate_profiled_building_groups = 0;
    _climate_limited_building_groups = 0;
    _climate_capacity_sum_q16 = 0;
    _filled_owner_jobs = 0;
    _filled_employee_jobs = 0;
    _unemployed_population = 0;
    // The epoch id advances after this reset. Invalidate the per-cell
    // replacement stamps now so the first employment reconciliation cannot
    // subtract the prior epoch's cached contribution from a zeroed aggregate.
    std::fill(_employment_metrics_epoch_by_cell.begin(),
              _employment_metrics_epoch_by_cell.end(),
              std::numeric_limits<int64_t>::min());
    _construction_goods_consumed = 0;
    _building_structure_count_only_updates = 0;
    _building_structure_new_groups = 0;
    _building_structure_removed_groups = 0;
    _building_structure_topology_rebuilds = 0;
    _building_structure_role_span_reuses = 0;
    _building_structure_role_span_appends = 0;
    _building_investment_candidates = 0;
    _building_owner_mobility = 0;
    _building_owner_job_reallocations = 0;
    _building_owner_job_profession_changes = 0;
    _building_owner_job_probability_skips = 0;
    _building_employee_to_owner_reallocations = 0;
    _building_investments_started = 0;
    _building_investment_blocked_funds = 0;
    _building_investment_blocked_materials = 0;
    _building_investment_blocked_sponsor_capital = 0;
    _building_investment_blocked_resources = 0;
    _building_investment_probability_skips = 0;
    _building_investment_capital_transferred = 0;
    _building_investment_buildings_started = 0;
    _building_investment_portfolios_started = 0;
    _building_investment_types_started = 0;
    _building_investment_owner_population_moved = 0;
    _building_investment_max_type_owner_share_q16 = 0;
    _building_investment_demand_limited = 0;
    _building_investment_material_limited = 0;
    _building_investment_capital_limited = 0;
    _building_investment_owner_population_limited = 0;
    _building_investment_jobs_started = 0;
    _building_investment_employment_gap = 0;
    _building_investment_employment_catchup_cells = 0;
    _trade_signal_max_age_days = 0;
    _trade_first_dispatch_delay_max_days = 0;
    _trade_response_deadline_misses = 0;
    _desired_business_demand = 0;
    _funded_business_demand = 0;
    _unfunded_business_demand = 0;
    _owner_working_capital_allocated = 0;
    _merchant_credit_budget = 0;
    _merchant_credit_committed = 0;
    _merchant_credit_drawn = 0;
    _merchant_credit_repaid = 0;
    _merchant_credit_premium_repaid = 0;
    _merchant_credit_outstanding = 0;
    _merchant_credit_bad_debt = 0;
    _recovery_candidates = 0;
    _recovery_approved = 0;
    _recovery_restarted = 0;
    _recovery_failed = 0;
    _recovery_liquidated_buildings = 0;
    _recovery_partially_liquidated_buildings = 0;
    _recovery_fully_liquidated_groups = 0;
    _working_capital_scale_error_bound_q16 = 0;
    _production_inputs_consumed = 0;
    _production_output_stock = 0;
    _production_output_discarded = 0;
    _production_output_retained = 0;
    _production_output_supported = 0;
    _owner_output_consumed = 0;
    _producer_revenue = 0;
	_producer_support_money_issued = 0;
	_bullion_money_issued = 0;
	_bullion_stock_consumed = 0;
	_gold_accepted = 0;
	_silver_accepted = 0;
	_gold_money_issued = 0;
	_silver_money_issued = 0;
	_cycle_flow_produced = 0;
	_cycle_flow_consumed = 0;
	_cycle_flow_discarded = 0;
    _building_wages_paid = 0;
    _building_wages_unpaid = 0;
    _building_base_wages_paid = 0;
    _building_base_wages_due = 0;
    _building_bonus_paid = 0;
    _building_bonus_due = 0;
    _wage_suspended_building_groups = 0;
    _loss_suspended_building_groups = 0;
    _merchant_procurement_budget = 0;
    _merchant_procurement_opportunity = 0;
    _merchant_procurement_allocated = 0;
    _merchant_procurement_unspent_allocated = 0;
    _merchant_procurement_reserved = 0;
    _merchant_procurement_spent = 0;
    _merchant_procurement_retail_value = 0;
    _merchant_procurement_factor_weighted_cash_q16 = 0;
    _merchant_survival_procurement_required = 0;
    _merchant_survival_procurement_allocated = 0;
    _merchant_input_procurement_required = 0;
    _merchant_input_procurement_allocated = 0;
    _merchant_trade_purchase_cash = 0;
    _merchant_trade_sale_cash = 0;
    _government_research_procured_points = 0;
    _government_research_procurement_cash = 0;
    _government_research_procurement_orders = 0;
    auto reset_cell_metric = [&](std::vector<int64_t> &metric) {
        if (metric.size() != static_cast<size_t>(_cell_count)) {
            metric.assign(static_cast<size_t>(_cell_count), 0);
        } else {
            std::fill(metric.begin(), metric.end(), int64_t{0});
        }
    };
    reset_cell_metric(_merchant_procurement_paid_by_cell);
    reset_cell_metric(_merchant_procurement_retail_by_cell);
    reset_cell_metric(_merchant_procurement_factor_weighted_cash_by_cell);
    reset_cell_metric(_merchant_trade_purchase_by_cell);
    reset_cell_metric(_merchant_trade_sale_by_cell);
    reset_cell_metric(_merchant_credit_drawn_by_cell);
    _owner_working_capital_reserved = 0;
    _production_input_reserved = 0;
    _production_input_reserve_shortfall = 0;
    _labor_signal_updates = 0;
    _building_resource_generated = 0;
    _building_resource_consumed = 0;
    _building_resource_limited_groups = 0;
    _unprofitable_building_groups = 0;
    _zero_utilization_building_groups = 0;
    _utilization_sum_q16 = 0;
    _market_signal_updates = 0;
    _building_resource_capacity_checks = 0;
    _building_resource_capacity_limited_groups = 0;
    _last_building_rejection_reason.clear();
    _worker_tasks = 1;
    _production_worker_tasks = 1;
    _market_worker_tasks_max = 1;
    _market_worker_task_sum = 0;
    _market_worker_dispatches = 0;
    _market_worker_parallel_dispatches = 0;
    _production_worker_tasks_max = 1;
    _production_worker_task_sum = 0;
    _production_worker_dispatches = 0;
    _production_worker_parallel_dispatches = 0;
    _production_worker_weight_total = 0;
    _production_worker_task_weight_min = 0;
    _production_worker_task_weight_max = 0;
    _production_worker_imbalance_q16_max = 0;
    _production_worker_cpu_ms = 0.0;
    _audit_worker_tasks_max = 1;
    _audit_worker_dispatches = 0;
    _audit_worker_cpu_ms = 0.0;
    _building_plan_worker_tasks_max = 1;
    _building_plan_worker_parallel_dispatches = 0;
    _building_plan_worker_cpu_ms = 0.0;
    _opening_audit_fast_paths = 0;
    _opening_audit_full_verifications = 0;
    _closing_audit_fast_paths = 0;
    _closing_audit_full_verifications = 0;
    _closing_audit_mismatches = 0;
    _closing_audit_population_full_scan_entries = 0;
    _closing_audit_market_full_scan_entries = 0;
    _closing_audit_incremental_this_epoch = false;
    _incremental_closing_totals = {};
    _closing_audit_mismatch_ledger = "none";
    _closing_audit_mismatch_lane = -1;
    _investment_scheduled_review_cells = 0;
    _investment_review_cells = 0;
    _investment_type_evaluations = 0;
    _investment_market_signal_rejections = 0;
    _investment_ethnicity_evaluations = 0;
    _investment_sparse_considered_types = 0;
    _investment_sparse_selected_types = 0;
    _investment_sparse_skipped_types = 0;
    _investment_sparse_mismatches = 0;
    _investment_sparse_dense_fallbacks = 0;
    _investment_gate_capital_type_skips = 0;
    _building_factor_cache_hits = 0;
    _building_factor_cache_misses = 0;
    _approximation_decisions = 0;
    _approximation_exact_probes = 0;
    _approximation_certificate_failures = 0;
    _approximation_exact_fallbacks = 0;
    _approximation_frontier_candidates = 0;
    _approximation_frontier_pruned = 0;
    _approximation_max_observed_regret_q16 = 0;
    _approximation_probe_violations = 0;
    _approximation_probe_max_spend_error_q16 = 0;
    _approximation_probe_max_demand_error_q16 = 0;
    _high_speed_market_dispatches_saved = 0;
    _high_speed_production_dispatches_saved = 0;
    _budgeted_building_commit_phase_fusions = 0;
    _budgeted_publish_phase_fusions = 0;
    _formula_ms = 0.0;
    _clear_ms = 0.0;
    _ledger_ms = 0.0;
    _fallback_ms = 0.0;
    _merchant_settle_ms = 0.0;
    _price_ms = 0.0;
    _structure_ms = 0.0;
    _prosperity_changed_cells = 0;
    _prosperity_promotions = 0;
    _prosperity_demotions = 0;
    _settlement_names_assigned = 0;
    _settlement_names_released = 0;
    _settlement_name_collision_probes = 0;
    _prosperity_update_ms = 0.0;
    _publish_ms = 0.0;
    _employment_ms = 0.0;
    _production_ms = 0.0;
    _production_merge_ms = 0.0;
    _production_worker_ms = 0.0;
    _market_worker_ms = 0.0;
    _household_market_prepare_ms = 0.0;
    _market_merge_ms = 0.0;
    _market_merge_aggregate_ms = 0.0;
    _market_merge_trade_ms = 0.0;
    _market_result_allocation_growth_count = 0;
    _market_result_allocation_growth_bytes = 0;
    _production_result_allocation_growth_count = 0;
    _production_result_allocation_growth_bytes = 0;
    _building_plan_ms = 0.0;
    _building_plan_evaluate_ms = 0.0;
    _building_plan_reserve_ms = 0.0;
    _building_structure_group_merge_ms = 0.0;
    _building_structure_market_cache_ms = 0.0;
    _building_structure_labor_cache_ms = 0.0;
    _investment_ms = 0.0;
    _investment_evaluate_ms = 0.0;
    _investment_allocate_ms = 0.0;
    _investment_prepare_lanes_ms = 0.0;
    _investment_prepare_pending_ms = 0.0;
    _investment_prepare_groups_ms = 0.0;
    _finalize_construction_ms = 0.0;
    _finalize_reconcile_ms = 0.0;
    _building_factor_refresh_ms = 0.0;
    _building_role_storage_ms = 0.0;
    _building_factor_cache_hits_epoch = 0;
    _building_factor_cache_misses_epoch = 0;
    _building_factor_miss_modver_epoch = 0;
    _building_factor_miss_country_epoch = 0;
    _building_factor_miss_sector_epoch = 0;
    _building_factor_miss_research_epoch = 0;
    _building_factor_miss_identity_epoch = 0;
    _market_signal_ms = 0.0;
    _market_signal_insert_ms = 0.0;
    _market_signal_flush_ms = 0.0;
    _market_signal_insert_count = 0;
    _wage_plan_ms = 0.0;
    _labor_signal_ms = 0.0;
    _trade_settle_ms = 0.0;
    _trade_dispatch_ms = 0.0;
    _epoch_begin_ms = 0.0;
    _epoch_preflight_ms = 0.0;
    _prepare_ms = 0.0;
    _epoch_begin_reset_ms = 0.0;
    _epoch_begin_country_ms = 0.0;
    _epoch_begin_city_factor_ms = 0.0;
    _epoch_begin_building_factor_ms = 0.0;
    _epoch_begin_workset_ms = 0.0;
    _epoch_begin_resource_lane_ms = 0.0;
    _epoch_begin_fiscal_ms = 0.0;
    _epoch_begin_construction_csr_ms = 0.0;
    _epoch_begin_recovery_apply_ms = 0.0;
    _epoch_begin_vector_init_ms = 0.0;
    _epoch_begin_audit_lane_ms = 0.0;
    _epoch_begin_commands_ms = 0.0;
    _prepare_reuse_count = 0;
    _workset_cells_planned = 0;
    _workset_cells_executed = 0;
    _duplicate_range_count = 0;
    _workset_last_cursor = 0;
    _audit_ms = 0.0;
    _watermark_ms = 0.0;
    _trade_capacity_available = 0;
    _trade_capacity_used = 0;
    _trade_settlement_lag_days = 0;
    _trade_orders_dispatched = 0;
    _trade_orders_arrived = 0;
    _trade_unclaimed_orders = 0;
    _trade_active_keys_pruned = 0;
    _trade_deficit_episodes_started = 0;
    _trade_deficit_episodes_resolved = 0;
    _trade_candidates_stale_generation = 0;
    _trade_candidates_arbitrated_out = 0;
    _trade_true_source_stock_failures = 0;
    _event_summary_ms = 0.0;
    _event_detail_ms = 0.0;
    _event_publish_ms = 0.0;
    _explicit_money_mint = 0;
    _explicit_money_burn = 0;
    _external_population_delta = 0;
    _explicit_stock_delta = 0;
    _country_research_consumed_opening = 0;
    _country_research_goods_consumed = 0;
    _consumed_goods = 0;
    _births = 0;
    _deaths = 0;
    _saturation_count = 0;
    _structural_touched_cells.clear();
    _population_changed_cells.clear();
    _structural_reconciled_upto = 0;
    _structural_funds_to_treasury = 0;
    _publish_accum = {};
    reset_publish_state();
    if (_staging_cells.size() != _committed_cells.size()) {
        _staging_cells = _committed_cells;
    } else {
        for (const int32_t cell : _staging_touched_cells) {
            if (cell >= 0 &&
                cell < static_cast<int32_t>(_committed_cells.size())) {
                _staging_cells[cell] = _committed_cells[cell];
            }
        }
    }
    _staging_touched_cells.clear();
    if (_staging_cell_generation.size() != _committed_cells.size())
        _staging_cell_generation.assign(_committed_cells.size(), 0);
    ++_staging_current_generation;
    if (_staging_current_generation == 0) {
        std::fill(_staging_cell_generation.begin(),
                  _staging_cell_generation.end(), 0);
        _staging_current_generation = 1;
    }
    if (_resource_remaining.size() != _resource_snapshot.size())
        _resource_remaining.resize(_resource_snapshot.size());
    if (_resource_harvest_remaining.size() != _resource_snapshot.size())
        _resource_harvest_remaining.resize(_resource_snapshot.size());
    if (_resource_deltas.size() != _resource_snapshot.size())
        _resource_deltas.resize(_resource_snapshot.size());
    if (_resource_lane_generation.size() != _resource_snapshot.size())
        _resource_lane_generation.assign(_resource_snapshot.size(), 0);
    ++_resource_current_generation;
    if (_resource_current_generation == 0) {
        std::fill(_resource_lane_generation.begin(),
                  _resource_lane_generation.end(), 0);
        _resource_current_generation = 1;
    }
    _resource_touched_lanes.clear();
    if (_last_published_resource_deltas.size() != _resource_snapshot.size())
        _last_published_resource_deltas.assign(_resource_snapshot.size(), 0);
    _resource_deltas_ready = false;
}

void NativeEconomyRuntime::capture_completed_perf_snapshot() {
    CompletedEpochPerf snapshot;
    snapshot.valid = true;
    snapshot.epoch_id = _epoch_id;
    snapshot.sample_day = _sample_day;
    snapshot.continuation_slices = _continuation_slices;
    snapshot.market_worker_tasks_max = _market_worker_tasks_max;
    snapshot.market_worker_task_sum = _market_worker_task_sum;
    snapshot.market_worker_dispatches = _market_worker_dispatches;
    snapshot.market_worker_parallel_dispatches =
        _market_worker_parallel_dispatches;
    snapshot.production_worker_tasks_max = _production_worker_tasks_max;
    snapshot.production_worker_task_sum = _production_worker_task_sum;
    snapshot.production_worker_dispatches = _production_worker_dispatches;
    snapshot.production_worker_parallel_dispatches =
        _production_worker_parallel_dispatches;
    snapshot.production_worker_weight_total =
        _production_worker_weight_total;
    snapshot.production_worker_task_weight_min =
        _production_worker_task_weight_min;
    snapshot.production_worker_task_weight_max =
        _production_worker_task_weight_max;
    snapshot.production_worker_imbalance_q16_max =
        _production_worker_imbalance_q16_max;
    snapshot.production_worker_cpu_ms = _production_worker_cpu_ms;
    snapshot.audit_worker_tasks_max = _audit_worker_tasks_max;
    snapshot.audit_worker_dispatches = _audit_worker_dispatches;
    snapshot.audit_worker_cpu_ms = _audit_worker_cpu_ms;
    snapshot.building_plan_worker_tasks_max =
        _building_plan_worker_tasks_max;
    snapshot.building_plan_worker_parallel_dispatches =
        _building_plan_worker_parallel_dispatches;
    snapshot.building_plan_worker_cpu_ms =
        _building_plan_worker_cpu_ms;
    snapshot.opening_audit_fast_paths = _opening_audit_fast_paths;
    snapshot.opening_audit_full_verifications =
        _opening_audit_full_verifications;
    snapshot.closing_audit_fast_paths = _closing_audit_fast_paths;
    snapshot.closing_audit_full_verifications =
        _closing_audit_full_verifications;
    snapshot.closing_audit_mismatches = _closing_audit_mismatches;
    snapshot.closing_audit_mismatch_ledger =
        _closing_audit_mismatch_ledger;
    snapshot.closing_audit_mismatch_lane =
        _closing_audit_mismatch_lane;
    snapshot.closing_audit_population_touched_lanes =
        static_cast<int64_t>(_audit_population_touched_lanes.size());
    snapshot.closing_audit_market_touched_lanes =
        static_cast<int64_t>(_audit_market_touched_lanes.size());
    snapshot.closing_audit_population_full_scan_entries =
        _closing_audit_population_full_scan_entries;
    snapshot.closing_audit_market_full_scan_entries =
        _closing_audit_market_full_scan_entries;
    snapshot.investment_scheduled_review_cells =
        _investment_scheduled_review_cells;
    snapshot.investment_review_cells = _investment_review_cells;
    snapshot.investment_type_evaluations =
        _investment_type_evaluations;
    snapshot.investment_market_signal_rejections =
        _investment_market_signal_rejections;
    snapshot.investment_ethnicity_evaluations =
        _investment_ethnicity_evaluations;
    snapshot.investment_sparse_considered_types =
        _investment_sparse_considered_types;
    snapshot.investment_sparse_selected_types =
        _investment_sparse_selected_types;
    snapshot.investment_sparse_skipped_types =
        _investment_sparse_skipped_types;
    snapshot.investment_sparse_mismatches =
        _investment_sparse_mismatches;
    snapshot.investment_sparse_dense_fallbacks =
        _investment_sparse_dense_fallbacks;
    snapshot.approximation_decisions = _approximation_decisions;
    snapshot.approximation_exact_probes = _approximation_exact_probes;
    snapshot.approximation_certificate_failures =
        _approximation_certificate_failures;
    snapshot.approximation_exact_fallbacks =
        _approximation_exact_fallbacks;
    snapshot.approximation_frontier_candidates =
        _approximation_frontier_candidates;
    snapshot.approximation_frontier_pruned =
        _approximation_frontier_pruned;
    snapshot.approximation_max_observed_regret_q16 =
        _approximation_max_observed_regret_q16;
    snapshot.approximation_probe_violations =
        _approximation_probe_violations;
    snapshot.approximation_probe_max_spend_error_q16 =
        _approximation_probe_max_spend_error_q16;
    snapshot.approximation_probe_max_demand_error_q16 =
        _approximation_probe_max_demand_error_q16;
    snapshot.approximation_cooldown_epochs_left =
        _approximation_cooldown_epochs_left;
    snapshot.high_speed_batch_multiplier = _active_batch_multiplier;
    snapshot.high_speed_market_dispatches_saved =
        _high_speed_market_dispatches_saved;
    snapshot.high_speed_production_dispatches_saved =
        _high_speed_production_dispatches_saved;
    snapshot.budgeted_building_commit_phase_fusions =
        _budgeted_building_commit_phase_fusions;
    snapshot.budgeted_publish_phase_fusions =
        _budgeted_publish_phase_fusions;
    snapshot.building_plan_ms = _building_plan_ms;
    snapshot.building_plan_evaluate_ms = _building_plan_evaluate_ms;
    snapshot.building_plan_reserve_ms = _building_plan_reserve_ms;
    snapshot.building_employment_ms = _employment_ms;
    snapshot.building_production_ms = _production_ms;
    snapshot.building_production_worker_ms = _production_worker_ms;
    snapshot.building_production_merge_ms = _production_merge_ms;
    snapshot.household_market_worker_ms = _market_worker_ms;
    snapshot.household_market_prepare_ms = _household_market_prepare_ms;
    snapshot.household_market_merge_aggregate_ms = _market_merge_aggregate_ms;
    snapshot.household_market_merge_trade_ms = _market_merge_trade_ms;
    snapshot.prepare_reuse_count = _prepare_reuse_count;
    snapshot.workset_cells_planned = _workset_cells_planned;
    snapshot.workset_cells_executed = _workset_cells_executed;
    snapshot.duplicate_range_count = _duplicate_range_count;
    snapshot.building_investment_ms = _investment_ms;
    snapshot.investment_evaluate_ms = _investment_evaluate_ms;
    snapshot.investment_allocate_ms = _investment_allocate_ms;
    snapshot.investment_prepare_lanes_ms = _investment_prepare_lanes_ms;
    snapshot.investment_prepare_pending_ms = _investment_prepare_pending_ms;
    snapshot.investment_prepare_groups_ms = _investment_prepare_groups_ms;
    snapshot.finalize_construction_ms = _finalize_construction_ms;
    snapshot.finalize_reconcile_ms = _finalize_reconcile_ms;
    snapshot.building_factor_refresh_ms = _building_factor_refresh_ms;
    snapshot.building_role_storage_ms = _building_role_storage_ms;
    snapshot.building_factor_cache_hits = _building_factor_cache_hits_epoch;
    snapshot.building_factor_cache_misses = _building_factor_cache_misses_epoch;
    snapshot.building_factor_miss_modver = _building_factor_miss_modver_epoch;
    snapshot.building_factor_miss_country = _building_factor_miss_country_epoch;
    snapshot.building_factor_miss_sector = _building_factor_miss_sector_epoch;
    snapshot.building_factor_miss_research = _building_factor_miss_research_epoch;
    snapshot.building_factor_miss_identity = _building_factor_miss_identity_epoch;
    snapshot.aggregate_publish_ms = _publish_ms;
    snapshot.aggregate_audit_ms = _audit_ms;
    snapshot.market_result_allocation_growth_count =
        _market_result_allocation_growth_count;
    snapshot.market_result_allocation_growth_bytes =
        _market_result_allocation_growth_bytes;
    snapshot.production_result_allocation_growth_count =
        _production_result_allocation_growth_count;
    snapshot.production_result_allocation_growth_bytes =
        _production_result_allocation_growth_bytes;
    snapshot.building_structure_count_only_updates =
        _building_structure_count_only_updates;
    snapshot.building_structure_new_groups =
        _building_structure_new_groups;
    snapshot.building_structure_removed_groups =
        _building_structure_removed_groups;
    snapshot.building_structure_topology_rebuilds =
        _building_structure_topology_rebuilds;
    snapshot.building_structure_role_span_reuses =
        _building_structure_role_span_reuses;
    snapshot.building_structure_role_span_appends =
        _building_structure_role_span_appends;
    snapshot.building_structure_group_merge_ms =
        _building_structure_group_merge_ms;
    snapshot.building_structure_market_cache_ms =
        _building_structure_market_cache_ms;
    snapshot.building_structure_labor_cache_ms =
        _building_structure_labor_cache_ms;
    _last_completed_perf = snapshot;
}

bool NativeEconomyRuntime::start_epoch(int64_t day_index, std::string &error) {
    const auto epoch_started = Clock::now();
    if (!_bootstrapped || _fatal || _epoch_active) {
        error = "epoch_start_state_invalid";
        return false;
    }
    if (day_index <= _last_committed_day) return true;
    // All failure-prone checks happen here, before any state mutation.
    if (_market.good_count != static_cast<int32_t>(_good_ids.size()) ||
        _market.cell_to_market.size() != static_cast<size_t>(_cell_count) ||
        _market.stock.size() != static_cast<size_t>(_market.market_count) * _market.good_count ||
        _market_cell_offsets.size() != static_cast<size_t>(_market.market_count + 1)) {
        error = "market_shape_invariant_broken";
        return false;
    }
    if (_environment_day != day_index || _environment_temperature_q16.size() !=
            static_cast<size_t>(_cell_count)) {
        error = "same_day_environment_not_captured";
        return false;
    }
    if (!_building_types.empty() && (_building_context_day != day_index ||
        _building_elevation_q16.size() != static_cast<size_t>(_cell_count) ||
        _building_neighbors.size() != static_cast<size_t>(_cell_count) * 6 ||
        _resource_snapshot.size() != _resource_ids.size() * static_cast<size_t>(_cell_count))) {
        error = "same_day_building_context_not_captured";
        return false;
    }
    if (_merchant_primary_slot.size() != static_cast<size_t>(_cell_count)) {
        error = "merchant_index_shape_invalid";
        return false;
    }
    const size_t cache_cells = static_cast<size_t>(_cell_count);
    const size_t cache_variants = cache_cells * _variants.size();
    const size_t cache_needs = cache_cells * _needs.size();
    if (_demand_basis_cache_day.size() != cache_cells)
        _demand_basis_cache_day.assign(
            cache_cells, std::numeric_limits<int64_t>::min());
    _demand_basis_variant_scores.resize(cache_variants);
    _demand_basis_variant_prices.resize(cache_variants);
    _demand_basis_need_score_sums.resize(cache_needs);
    _demand_basis_need_composites.resize(cache_needs);
    _demand_basis_need_environment.resize(cache_needs);
    bool merchant_index_dirty = false;
    for (int32_t cell = 0; cell < _cell_count; ++cell) {
        const int32_t primary = _merchant_primary_slot[cell];
        if (is_merchant_slot(primary)) continue;
        if (primary < 0 &&
            (cell >= static_cast<int32_t>(_committed_cells.size()) ||
             _committed_cells[cell].population <= 0))
            continue;
        int64_t population = 0;
        bool has_living_merchant = false;
        _population.for_each_in_cell(cell, [&](int32_t slot) {
            population = saturating_add(population, _population.population[slot],
                                        _saturation_count);
            if (!has_living_merchant && is_merchant_slot(slot))
                has_living_merchant = true;
        });
        if (population <= 0) {
            if (primary >= 0) merchant_index_dirty = true;
            continue;
        }
        if (!has_living_merchant) {
            int64_t repairs = 0;
            if (!ensure_merchant_invariant(cell, repairs, error)) {
                if (error.empty()) error = "merchant_invariant_broken_before_cycle";
                return false;
            }
        }
        merchant_index_dirty = true;
    }
    if (merchant_index_dirty && !rebuild_merchant_ranges(error)) {
        if (error.empty()) error = "merchant_invariant_broken_before_cycle";
        return false;
    }
    const double preflight_ms = elapsed_ms(epoch_started);
    const auto prepare_started = Clock::now();
    clear_epoch_metrics();
    _epoch_preflight_ms = preflight_ms;
    _country_research_consumed_opening = _country_runtime == nullptr
        ? 0 : _country_runtime->research_consumed_total();
    _epoch_begin_reset_ms = elapsed_ms(prepare_started);
    const auto country_started = Clock::now();
    if (!capture_country_epoch(error)) return false;
    _epoch_begin_country_ms = elapsed_ms(country_started);
    const auto workset_started = Clock::now();
    rebuild_economy_live_cells();
    maybe_lock_cadence_cycles(day_index);
    _rolling_phase = cycle_phase(day_index, _market_cycle_start_day,
                                 locked_market_cycle_days());
    _epoch_market_ids.clear();
    _epoch_settlement_cells.clear();
    _epoch_building_cells.clear();
    _epoch_plan_cells.clear();
    const int32_t market_count = std::max(0, _market.market_count);
    const bool have_market_map =
        _market.cell_to_market.size() == static_cast<size_t>(_cell_count);
    std::vector<uint8_t> market_added(static_cast<size_t>(market_count), 0);
    for (const int32_t cell : _economy_live_cells) {
        if (!cell_in_market_workset(cell, day_index)) continue;
        _epoch_settlement_cells.push_back(cell);
        int32_t market = cell;
        if (have_market_map) market = _market.cell_to_market[cell];
        if (market < 0 || market >= market_count) continue;
        if (market_added[static_cast<size_t>(market)] != 0) continue;
        market_added[static_cast<size_t>(market)] = 1;
        _epoch_market_ids.push_back(market);
    }
    std::sort(_epoch_market_ids.begin(), _epoch_market_ids.end());
    _workset_cells_planned = static_cast<int64_t>(_epoch_settlement_cells.size());
    _resource_touched_lanes.reserve(
        _resource_ids.size() * _epoch_settlement_cells.size());
    const auto resource_lane_started = Clock::now();
    // Initialize only the lanes reachable by this rolling phase. Production
    // workers then operate on disjoint, preinitialized lanes and never race on
    // the touched list.
    for (int32_t resource = 0;
         resource < static_cast<int32_t>(_resource_ids.size()); ++resource) {
        for (const int32_t cell : _epoch_settlement_cells) {
            if (cell < 0 || cell >= _cell_count) continue;
            ensure_resource_lane(
                static_cast<size_t>(resource) * _cell_count + cell);
        }
    }
    // Freeze the deterministic cost model once per epoch. Recomputing these
    // cohort/building scans in every household continuation was measurable
    // scheduler-side overhead and provided no newer information.
    _epoch_market_work_weights.resize(_epoch_market_ids.size());
    for (size_t relative = 0; relative < _epoch_market_ids.size(); ++relative) {
        const int32_t market = _epoch_market_ids[relative];
        int64_t market_work = 32;
        for (int32_t k = _market_cell_offsets[market];
             k < _market_cell_offsets[market + 1]; ++k) {
            const int32_t cell = _market_cells[k];
            market_work += static_cast<int64_t>(
                _committed_cells[cell].cohort_count) * 16;
            if (_building_cell_offsets.size() ==
                    static_cast<size_t>(_cell_count + 1)) {
                market_work += static_cast<int64_t>(
                    _building_cell_offsets[cell + 1] -
                    _building_cell_offsets[cell]) * 4;
            }
        }
        _epoch_market_work_weights[relative] = market_work;
    }
    for (const int32_t cell : _building_active_cells) {
        if (cell_in_market_workset(cell, day_index))
            _epoch_building_cells.push_back(cell);
    }
    {
        _epoch_plan_cells.clear();
        for (const int32_t cell : _epoch_building_cells) {
            if (cell_due_plan_review(cell, day_index))
                _epoch_plan_cells.push_back(cell);
        }
    }
    _epoch_days = workset_elapsed_days(day_index);
    refresh_epoch_research_demand();
    _commit_lag_budget_days = std::max(0, locked_market_cycle_days() - 1);
    _epoch_begin_workset_ms = elapsed_ms(workset_started);
    const auto fiscal_started = Clock::now();
    if (!prepare_fiscal_budgets(error)) return false;
    _epoch_begin_fiscal_ms = elapsed_ms(fiscal_started);
    const auto resource_lane_2_started = Clock::now();
    for (int32_t resource = 0;
         resource < static_cast<int32_t>(_resource_ids.size()); ++resource) {
        for (const int32_t cell : _epoch_building_cells) {
            ensure_resource_lane(
                static_cast<size_t>(resource) * _cell_count + cell);
        }
    }
    _epoch_begin_resource_lane_ms = elapsed_ms(resource_lane_started) +
        elapsed_ms(resource_lane_2_started);
    const auto construction_csr_started = Clock::now();
    _pending_construction_cell_offsets.assign(
        static_cast<size_t>(_cell_count) + 1, 0);
    for (const PendingConstruction &pending : _pending_construction) {
        if (pending.cell >= 0 && pending.cell < _cell_count)
            ++_pending_construction_cell_offsets[pending.cell + 1];
    }
    for (int32_t cell = 0; cell < _cell_count; ++cell) {
        _pending_construction_cell_offsets[cell + 1] +=
            _pending_construction_cell_offsets[cell];
    }
    _pending_construction_cell_indices.resize(
        static_cast<size_t>(_pending_construction_cell_offsets.back()));
    std::vector<int32_t> pending_cursors(
        _pending_construction_cell_offsets.begin(),
        _pending_construction_cell_offsets.end() - 1);
    for (int32_t pending_index = 0;
         pending_index < static_cast<int32_t>(_pending_construction.size());
         ++pending_index) {
        const int32_t cell = _pending_construction[pending_index].cell;
        if (cell >= 0 && cell < _cell_count)
            _pending_construction_cell_indices[pending_cursors[cell]++] = pending_index;
    }
    _epoch_begin_construction_csr_ms = elapsed_ms(construction_csr_started);
    const auto recovery_apply_started = Clock::now();
    // Recovery outcomes are committed only when this cell becomes due again.
    // This keeps employment and the published operating state on the same
    // frozen-cycle boundary instead of changing state after hiring has settled.
    for (const int32_t cell : _epoch_building_cells) {
        if (_building_cell_offsets.size() != static_cast<size_t>(_cell_count + 1))
            continue;
        for (int32_t g = _building_cell_offsets[cell];
             g < _building_cell_offsets[cell + 1]; ++g) {
            BuildingGroup &group = _buildings[g];
            const bool applying_pending = group.pending_operating_state <= 1;
            if (applying_pending) {
                group.operating_state = group.pending_operating_state;
                group.pending_operating_state = 255;
                if (group.operating_state == 0) {
                    group.severe_loss_cycles = 0;
                    group.recovery_failed_reviews = 0;
                }
            }
            if (group.operating_state > 1) {
                group.operating_state = 1;
                group.recovery_cycles = 0;
                group.recovery_cooldown_cycles = 0;
            }
            // These lanes are retained only for binary compatibility. The
            // lifecycle no longer has a probe or cooldown phase.
            group.recovery_cycles = 0;
            group.recovery_cooldown_cycles = 0;
        }
    }
    _epoch_begin_recovery_apply_ms = elapsed_ms(recovery_apply_started);
    const auto vector_init_started = Clock::now();
    _rolling_due_cells = static_cast<int32_t>(_epoch_settlement_cells.size());
    _rolling_processed_cells = 0;
    _rolling_deferred_cells = 0;
    _building_survival_utilization_floor_q16.assign(_buildings.size(), 0);
    _building_planned_capacity_before_climate_q16.assign(
        _buildings.size(), Q16_ONE);
    _building_owner_livelihood_credit.assign(_buildings.size(), 0);
    _building_merchant_credit_limit.assign(_buildings.size(), 0);
    _building_recovery_probe_capacity_q16.assign(_buildings.size(), 0);
    _building_recovery_liquidation_eligible.assign(_buildings.size(), 0);
    _production_input_reserve.assign(_market_signals.good_ids.size(), 0);
    _epoch_business_demand_ema = _market_signals.business_demand_ema;
    _epoch_desired_business_demand.assign(_market_signals.good_ids.size(), 0);
    _epoch_funded_business_demand.assign(_market_signals.good_ids.size(), 0);
    _epoch_offered_supply_ema = _market_signals.offered_supply_ema;
    _epoch_producer_sellable_current.assign(_market_signals.good_ids.size(), 0);
    _epoch_producer_merchant_sold_current.assign(
        _market_signals.good_ids.size(), 0);
    _epoch_producer_discarded_current.assign(_market_signals.good_ids.size(), 0);
    _epoch_nonhousehold_withdrawals.assign(_market_signals.good_ids.size(), 0);
    _epoch_cost_anchor_price = _market_signals.cost_anchor_price;
    _epoch_begin_vector_init_ms = elapsed_ms(vector_init_started);
    const auto audit_started = Clock::now();
    int64_t live_expedition_population = 0;
    int64_t live_expedition_funds = 0;
    int64_t live_expedition_goods = 0;
    sum_family_expedition_holdings(live_expedition_population,
                                   live_expedition_funds, live_expedition_goods,
                                   _saturation_count);
    // Idle start/return moves cohort funds into expedition escrow (or back)
    // before this opening snapshot. Copying last close then live-replacing
    // escrow would double-count or drop that money. Force a full scan whenever
    // in-transit holdings drifted since the last committed close.
    const bool expedition_holdings_changed =
        live_expedition_population != _closing_totals.transit_population ||
        live_expedition_funds != _closing_totals.expedition_funds ||
        live_expedition_goods != _closing_totals.expedition_goods;
    const bool full_audit_verify = _opening_audit_force_full ||
        expedition_holdings_changed ||
        day_index % _full_audit_verify_interval_days == 0;
    if (full_audit_verify) {
        _opening_totals = audit_totals();
        ++_opening_audit_full_verifications;
    } else {
        _opening_totals = _closing_totals;
        int64_t current_country_goods = 0;
        if (_country_runtime != nullptr) {
            _opening_totals.country_cash = _country_runtime->total_cash();
            for (int32_t good = 0; good < _market.good_count; ++good) {
                current_country_goods +=
                    _country_runtime->total_good(good);
            }
        } else {
            _opening_totals.country_cash = 0;
        }
        int64_t opening_escrow_saturation = 0;
        _opening_totals.expedition_funds = live_expedition_funds;
        _opening_totals.expedition_goods = live_expedition_goods;
        _opening_totals.transit_population = live_expedition_population;
        _opening_totals.escrow_cash = saturating_add(
            saturating_add(trade_escrow_cash(), fiscal_escrow_total(),
                           opening_escrow_saturation),
            live_expedition_funds, opening_escrow_saturation);
        _saturation_count += opening_escrow_saturation;
        _opening_totals.goods_stock +=
            current_country_goods - _opening_totals.country_goods;
        _opening_totals.country_goods = current_country_goods;
        ++_opening_audit_fast_paths;
    }
    _opening_audit_force_full = false;
    _audit_ms += elapsed_ms(audit_started);
    _sample_day = day_index;
    _current_day = day_index;
    begin_incremental_audit_epoch();
    _epoch_active = true;
    // Worker-local result lanes are registered on the owning thread when each
    // market/production range is merged. This avoids scanning every due cell
    // and every good at epoch open while preserving the incremental audit
    // shadow for all actual mutation lanes.
    _epoch_begin_audit_lane_ms = 0.0;
    _prepare_ms = elapsed_ms(prepare_started);
    ++_epoch_id;
    trace_begin_epoch();
    const auto commands_started = Clock::now();
    _epoch_commands.clear();
    auto due_end = std::stable_partition(_pending_commands.begin(), _pending_commands.end(),
                                         [&](const Command &c) { return c.effective_day <= day_index; });
    _epoch_commands.assign(_pending_commands.begin(), due_end);
    _pending_commands.erase(_pending_commands.begin(), due_end);
    std::stable_sort(_epoch_commands.begin(), _epoch_commands.end(), [](const Command &a, const Command &b) {
        if (a.effective_day != b.effective_day) return a.effective_day < b.effective_day;
        if (a.sequence != b.sequence) return a.sequence < b.sequence;
        if (a.opcode != b.opcode) return a.opcode < b.opcode;
        if (a.target_handle != b.target_handle) return a.target_handle < b.target_handle;
        if (a.i32_0 != b.i32_0) return a.i32_0 < b.i32_0;
        if (a.i32_1 != b.i32_1) return a.i32_1 < b.i32_1;
        if (a.i64_0 != b.i64_0) return a.i64_0 < b.i64_0;
        if (a.i64_1 != b.i64_1) return a.i64_1 < b.i64_1;
        return a.submit_order < b.submit_order;
    });
    auto reject_epoch_command = [&](const Command &cmd) {
        ++_rejected_commands;
        if (cmd.effect_request_id != 0) {
            EffectCommandResult &result =
                _effect_command_results[cmd.effect_request_id];
            result.complete = 1;
            result.ok = 0;
            if (result.reason.empty())
                result.reason = "effect_economy_epoch_preflight_rejected";
        }
        return true;
    };
    _epoch_commands.erase(std::remove_if(_epoch_commands.begin(), _epoch_commands.end(),
                                         [&](const Command &cmd) {
        const bool family_reward = is_family_ledger_command(cmd.opcode);
        const bool expedition_command =
            cmd.opcode == COMMAND_START_FAMILY_EXPEDITION ||
            cmd.opcode == COMMAND_CANCEL_FAMILY_EXPEDITION ||
            cmd.opcode == COMMAND_SETTLE_FAMILY_EXPEDITION;
        // Expedition commands target FamilyExpeditionStore handles, not
        // cohort handles. Treating SETTLE as a cohort write dropped the
        // command, left the Effect request incomplete, and froze the
        // expedition in SETTLING.
        const bool targets_cohort = !family_reward && !expedition_command &&
                                    cmd.opcode != COMMAND_TREASURY_SPONSORED_BUILD &&
                                    cmd.opcode != COMMAND_BUILD_CANAL &&
                                    cmd.opcode != COMMAND_ADD_STOCK &&
                                    cmd.opcode != COMMAND_REMOVE_STOCK &&
                                    cmd.opcode != COMMAND_COUNTRY_GOOD_TO_MARKET &&
                                    cmd.opcode != COMMAND_MARKET_GOOD_TO_COUNTRY;
        int32_t slot = -1;
        if (targets_cohort && !_population.valid_handle(cmd.target_handle, slot))
            return reject_epoch_command(cmd);
        if ((cmd.opcode == COMMAND_ADD_STOCK || cmd.opcode == COMMAND_REMOVE_STOCK ||
             cmd.opcode == COMMAND_COUNTRY_GOOD_TO_MARKET ||
             cmd.opcode == COMMAND_MARKET_GOOD_TO_COUNTRY) &&
            (cmd.i32_0 < 0 || cmd.i32_0 >= _market.market_count || cmd.i32_1 < 0 ||
             cmd.i32_1 >= _market.good_count)) {
            return reject_epoch_command(cmd);
        }
        if ((cmd.opcode == COMMAND_ADD_STOCK || cmd.opcode == COMMAND_COUNTRY_GOOD_TO_MARKET) &&
            _merchant_primary_slot[cmd.i32_0] < 0) {
            return reject_epoch_command(cmd);
        }
        if ((cmd.opcode == COMMAND_MOVE_POPULATION &&
             (cmd.i32_0 < 0 || cmd.i32_0 >= _cell_count)) ||
            (cmd.opcode == COMMAND_CHANGE_SIGNATURE &&
             (cmd.i32_0 < 0 || cmd.i32_0 >= static_cast<int32_t>(_signatures.size())))) {
            return reject_epoch_command(cmd);
        }
        if ((cmd.opcode == COMMAND_BUILD || cmd.opcode == COMMAND_DEMOLISH ||
             cmd.opcode == COMMAND_TREASURY_SPONSORED_BUILD) &&
            (cmd.i32_0 < 0 || cmd.i32_0 >= _cell_count || cmd.i32_1 < 0 ||
             cmd.i32_1 >= static_cast<int32_t>(_building_types.size()) || cmd.i64_0 <= 0)) {
            return reject_epoch_command(cmd);
        }
        if (cmd.opcode == COMMAND_TREASURY_SPONSORED_BUILD &&
            (cmd.i64_0 != 1 ||
             cmd.i64_1 != OWNERSHIP_TREASURY_SPONSORED_PRIVATE ||
             _country_runtime == nullptr || !_country_runtime->valid_handle(
                 static_cast<int64_t>(cmd.target_handle)))) {
            return reject_epoch_command(cmd);
        }
        if (cmd.opcode == COMMAND_BUILD_CANAL &&
            (_country_runtime == nullptr || !_country_runtime->valid_handle(
                static_cast<int64_t>(cmd.target_handle)) || cmd.i64_0 <= 0)) {
            return reject_epoch_command(cmd);
        }
        if (cmd.opcode == COMMAND_SETTLE_FAMILY_EXPEDITION) {
            int32_t expedition = -1;
            if (!_family_expeditions.valid_handle(cmd.target_handle, expedition) ||
                cmd.i32_0 != _family_expeditions.target_cell[expedition] ||
                cmd.i64_1 != static_cast<int64_t>(
                    _family_expeditions.country_handle[expedition])) {
                return reject_epoch_command(cmd);
            }
        }
        if (family_reward && !family_ledger_command_preflight(cmd)) {
            return reject_epoch_command(cmd);
        }
        return false;
    }), _epoch_commands.end());
    _epoch_begin_commands_ms = elapsed_ms(commands_started);
    _stage = _buildings.empty() ? Stage::TRADE_SETTLE : Stage::BUILDING_PLAN;
    _epoch_begin_ms = elapsed_ms(epoch_started);
    return true;
}


} // namespace pk
