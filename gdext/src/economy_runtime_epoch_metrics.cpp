#include "economy_cost_probe.h"
#include "economy_runtime.h"
#include "runtime_switch_registry.h"
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <limits>
#include <vector>

namespace pk {

void NativeEconomyRuntime::clear_epoch_metrics() {
    _epoch_begin_post_fiscal_pending = false;
    _epoch_begin_pending_day = -1;
    _fiscal_reservation_continuation = {};
    _families_formed = 0;
    _family_offers_opened = 0;
    _family_offers_auto_resolved = 0;
    _family_offer_choice_rejected = 0;
    _family_offers_voided = 0;
    _families_dissolved = 0;
    _family_membership_edges_processed = 0;
    _family_ownership_edges_processed = 0;
    _family_owner_jobs_filled = 0;
    _family_owner_jobs_vacant = 0;
    _family_births_attributed = 0;
    _family_deaths_attributed = 0;
    _family_reconcile_corrections = 0;
    _family_ledger_clamps = 0;
    _family_people_recruited = 0;
    _family_units_released = 0;
    _family_release_deferred = 0;
    _family_owner_seats_guarded = 0;
    _family_demography_weights_ms = 0.0;
    _persons_promoted = 0;
    _persons_died = 0;
    _persons_migrated = 0;
    _person_jobs_bound = 0;
    _person_need_edges_processed = 0;
    _person_commit_cursor = 0;
    _person_commit_phase = 0;
    _food_output_events = 0;
    _food_input_events = 0;
    _food_trade_events = 0;
    _food_access_events = 0;
    _carrying_old_resource_scan_steps = 0;
    _person_epoch_needs.clear();
    _person_opening_cash_claim = persons_store().cash_claim;
    for (int32_t i = 0; i < static_cast<int32_t>(persons_store().active.size()); ++i) {
        if (persons_store().active[i] == 0) continue;
        persons_store().epoch_job_income.write_scalar(i, 0, market_mutation_sink());
        persons_store().epoch_business_result.write_scalar(i, 0, market_mutation_sink());
        persons_store().epoch_consumption_expense.write_scalar(i, 0, market_mutation_sink());
        persons_store().epoch_tax.write_scalar(i, 0, market_mutation_sink());
    }
    _epoch_business_demand_ema.clear();
    _epoch_derived_business_demand.clear();
    _epoch_substitute_business_demand.clear();
    _epoch_desired_business_demand.clear();
    _epoch_funded_business_demand.clear();
    _epoch_price_ceiling_observations.clear();
    _epoch_ceiling_business_requested.clear();
    _epoch_ceiling_business_unfilled.clear();
    {
        EconomyCostProbe probe("research_scratch_clear", _current_day.get(),
            _epoch_ceiling_research_touched.size() * 2);
        for (int32_t market : _epoch_ceiling_research_touched) {
            _epoch_ceiling_research_requested[market] = 0;
            _epoch_ceiling_research_delivered[market] = 0;
        }
        _epoch_ceiling_research_touched.clear();
    }
    _epoch_previous_producer_sellable = _epoch_producer_sellable_current;
    _epoch_previous_producer_merchant_sold =
        _epoch_producer_merchant_sold_current;
    _epoch_offered_supply_ema.clear();
    _epoch_producer_sellable_current.clear();
    _epoch_producer_merchant_sold_current.clear();
    _epoch_producer_discarded_current.clear();
    _epoch_nonhousehold_withdrawals.clear();
    std::fill(_cell_food_output_eq_period.begin(),
              _cell_food_output_eq_period.end(), 0);
    std::fill(_cell_food_input_eq_period.begin(),
              _cell_food_input_eq_period.end(), 0);
    std::fill(_cell_food_import_eq_period.begin(),
              _cell_food_import_eq_period.end(), 0);
    std::fill(_cell_food_export_eq_period.begin(),
              _cell_food_export_eq_period.end(), 0);
    std::fill(_cell_food_access_eq_period.begin(),
              _cell_food_access_eq_period.end(), 0);
    _epoch_cost_anchor_price.clear();
    _epoch_research_good_id = -1;
    _epoch_colonization_demand_by_cell.clear();
    _epoch_colonization_demand_by_market.clear();
    _epoch_military_demand_by_cell.clear();
    _epoch_military_demand_by_market.clear();
    _epoch_research_demand_by_cell.clear();
    _epoch_research_demand_by_market.clear();
    _epoch_bullion_quota_keys.clear();
    _epoch_bullion_quota_initial.clear();
    _epoch_bullion_quota_remaining.clear();
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
    _price_rate_clamp_hits = 0;
    _price_ceiling_expansions = _price_ceiling_recoveries = _price_ceiling_blocked_rises = 0;
    _price_numeric_floor_hits = 0;
    _price_numeric_ceiling_hits = 0;
    _price_min_tick_hits = 0;
    _price_glut_cost_damp_hits = 0;
    _small_payment_roundups = 0;
    _price_rise_fade_hits = 0;
    _price_headroom_damp_hits = 0;
    _price_catalog_bound_hits = 0;
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
    _fiscal_business_prospective_lanes = 0;
    _fiscal_business_prospective_request = 0;
    _fiscal_settlement_continuation = {};
    _building_owner_mobility = 0;
    _building_owner_job_reallocations = 0;
    _building_owner_understaffed_reallocations = 0;
    _building_owner_job_profession_changes = 0;
    _building_owner_job_probability_skips = 0;
    _building_employee_to_owner_reallocations = 0;
    _building_employee_job_reallocations = 0;
    _building_employee_job_profession_changes = 0;
    _building_distress_career_exits = 0;
    _building_employee_job_hurdle_rejections = 0;
    _building_employee_cold_start_forecasts = 0;
    _building_employee_funding_limited_forecasts = 0;
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
    _building_investment_cost_envelope_trimmed = 0;
    _building_investment_owner_population_limited = 0;
    _building_investment_jobs_started = 0;
    _building_investment_employment_gap = 0;
    _building_investment_employment_catchup_cells = 0;
    _building_investment_displacement_starts = 0;
    _building_survival_priority_candidates = 0;
    _building_owner_opportunity_quotes = 0;
    _building_owner_opportunity_zero_feasible = 0;
    _building_owner_survival_reallocations = 0;
    _bullion_quota_pressure_clamps = 0;
    _bullion_quote_overallocation_prevented = 0;
    _startup_demand_seed_count = 0;
    _startup_demand_touched_lanes = 0;
    _startup_demand_catalog_edges = 0;
    _startup_demand_cycle_skips = 0;
    _startup_demand_remote_lanes = 0;
    _startup_demand_matched_review_cells = 0;
    _startup_demand_buildings_started = 0;
    _startup_demand_scratch_bytes = 0;
    _trade_signal_max_age_days = 0;
    _trade_first_dispatch_delay_max_days = 0;
    _trade_response_deadline_misses = 0;
    _desired_business_demand = 0;
    _funded_business_demand = 0;
    _unfunded_business_demand = 0;
    _active_unfunded_building_groups = 0;
    _last_merchant_protected_rejects = 0;
    _derived_business_demand_total = 0;
    _derived_business_demand_lanes = 0;
    _derived_business_demand_edges = 0;
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
    // _pending_non_tax_outflow is deliberately NOT reset here: family expedition
    // procurement settles at the idle boundary before an epoch opens, and that
    // cash must reach the next commit_fiscal (which drains the buffer).
    _country_research_procurement_candidates.clear();
    _country_research_procurement_budgets.clear();
    _country_research_procurement_remaining.clear();
    _country_research_procurement_enabled.clear();
    _country_research_procurement_cursor = 0;
    _country_research_procurement_phase = 0;
    _country_research_procurement_initialized = false;
    _country_research_procurement_done = false;
    _country_research_procurement_slices = 0;
    _country_research_procurement_transactions = 0;
    _country_research_procurement_rejections = 0;
    _country_research_procurement_continuation = {};
    reset_era_procurement_epoch();
    auto reset_cell_metric = [&](std::vector<int64_t> &metric) {
        if (metric.size() != static_cast<size_t>(_cell_count.get())) {
            metric.assign(static_cast<size_t>(_cell_count.get()), 0);
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
    // Market-keyed twins of the same epoch metric family. Cleared rather
    // than resized: the merge rewrites every settled market each day, so a
    // market that produced no retail this epoch must not keep a stale pool.
    _merchant_household_retail_by_market.clear();
    _market_merchant_population.clear();
    _owner_working_capital_reserved = 0;
    _production_input_reserved = 0;
    _production_input_reserve_shortfall = 0;
    _construction_material_reserved = 0;
    _maintenance_goods_consumed = 0;
    _maintenance_unmet = 0;
    _maintenance_unpaid_value = 0;
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
    _investment_displacement_type_evaluations = 0;
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
    _publish_commit_cells_ms = 0.0;
    _publish_commit_prepare_ms = 0.0;
    _publish_commit_finalize_ms = 0.0;
    _publish_commit_cells_slice_ms = 0.0;
    _publish_commit_prepare_slice_ms = 0.0;
    _publish_commit_finalize_slice_ms = 0.0;
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
    _startup_demand_prepare_ms = 0.0;
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
    _fiscal_settlement_ms = 0.0;
    _income_subsidy_epoch_ms = 0.0;
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
    // Sparse-workset probe: epoch-scoped, cleared with the other epoch counters
    // so every reported value belongs to exactly one epoch.
    _probe_workset_market_cells_due = 0;
    _probe_workset_building_cells = 0;
    _probe_workset_plan_cells = 0;
    _probe_workset_live_cells = 0;
    _probe_workset_coverage_permille = 0;
    _probe_market_bucket_index = 0;
    _probe_market_cycle_days = 0;
    _probe_plan_cycle_days = 0;
    _probe_cells_per_slice = 0;
    _probe_slice_count = 0;
    _probe_slice_budget_hits = 0;
    _probe_slice_ms_total = 0.0;
    _probe_slice_ms_max = 0.0;
    _probe_phase_attempt_ms = 0.0;
    _probe_phase_formula_ms = 0.0;
    _probe_phase_publish_ms = 0.0;
    _probe_phase_mirror_capture_ms = 0.0;
    _probe_phase_mirror_import_ms = 0.0;
    _probe_trade_plan_ms = 0.0;
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
    _annual_epoch_events = {};
    _annual_epoch_industries.clear();
    _deaths = 0;
    _cell_births.assign(static_cast<size_t>(std::max(0, _cell_count.get())), 0);
    _cell_deaths.assign(static_cast<size_t>(std::max(0, _cell_count.get())), 0);
    _cell_moved_in.assign(static_cast<size_t>(std::max(0, _cell_count.get())), 0);
    _cell_moved_out.assign(static_cast<size_t>(std::max(0, _cell_count.get())), 0);
    _saturation_count = 0;
    _structural_touched_cells.clear();
    // Copied, not moved: a start_epoch retry clears this vector again, and the
    // deferred cells are only dropped once STRUCTURAL_COMMIT reconciled them.
    _population_changed_cells.assign(
        _deferred_population_reconcile_cells.begin(),
        _deferred_population_reconcile_cells.end());
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
    const size_t resource_lanes = resource_stock_lanes().size();
    if (resource_remaining_lanes().size() != resource_lanes)
        resource_remaining_lanes().resize(resource_lanes);
    if (resource_harvest_remaining_lanes().size() != resource_lanes)
        resource_harvest_remaining_lanes().resize(resource_lanes);
    if (resource_delta_lanes().size() != resource_lanes)
        resource_delta_lanes().resize(resource_lanes);
    if (resource_lane_generation_lanes().size() != resource_lanes)
        resource_lane_generation_lanes().assign(resource_lanes, 0);
    ++_resource_current_generation;
    if (_resource_current_generation == 0) {
        std::fill(resource_lane_generation_lanes().begin(),
                  resource_lane_generation_lanes().end(), 0);
        _resource_current_generation = 1;
    }
    _resource_touched_lanes.clear();
    if (_last_published_resource_deltas.size() != resource_stock_lanes().size())
        _last_published_resource_deltas.assign(resource_stock_lanes().size(), 0);
    _resource_deltas_ready = false;
}

} // namespace pk
