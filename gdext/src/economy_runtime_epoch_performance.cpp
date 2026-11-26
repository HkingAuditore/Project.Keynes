#include "economy_cost_probe.h"
#include "economy_runtime.h"
#include "runtime_switch_registry.h"
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <limits>
#include <vector>

namespace pk {

void NativeEconomyRuntime::capture_completed_perf_snapshot() {
    CompletedEpochPerf snapshot;
    snapshot.valid = true;
    snapshot.epoch_id = _epoch_id.get();
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
    snapshot.investment_displacement_type_evaluations =
        _investment_displacement_type_evaluations;
    snapshot.building_investment_displacement_starts =
        _building_investment_displacement_starts;
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
    snapshot.startup_demand_seed_count = _startup_demand_seed_count;
    snapshot.startup_demand_touched_lanes = _startup_demand_touched_lanes;
    snapshot.startup_demand_catalog_edges = _startup_demand_catalog_edges;
    snapshot.startup_demand_cycle_skips = _startup_demand_cycle_skips;
    snapshot.startup_demand_remote_lanes = _startup_demand_remote_lanes;
    snapshot.startup_demand_matched_review_cells =
        _startup_demand_matched_review_cells;
    snapshot.startup_demand_buildings_started =
        _startup_demand_buildings_started;
    snapshot.startup_demand_scratch_bytes = _startup_demand_scratch_bytes;
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
    snapshot.price_numeric_floor_hits = _price_numeric_floor_hits;
    snapshot.price_numeric_ceiling_hits = _price_numeric_ceiling_hits;
    snapshot.price_min_tick_hits = _price_min_tick_hits;
    snapshot.price_glut_cost_damp_hits = _price_glut_cost_damp_hits;
    snapshot.small_payment_roundups = _small_payment_roundups;
    snapshot.price_ms = _price_ms;
    snapshot.household_market_worker_ms = _market_worker_ms;
    snapshot.household_market_prepare_ms = _household_market_prepare_ms;
    snapshot.household_market_merge_aggregate_ms = _market_merge_aggregate_ms;
    snapshot.household_market_merge_trade_ms = _market_merge_trade_ms;
    snapshot.prepare_reuse_count = _prepare_reuse_count;
    snapshot.workset_cells_planned = _workset_cells_planned;
    snapshot.workset_cells_executed = _workset_cells_executed;
    snapshot.duplicate_range_count = _duplicate_range_count;
    snapshot.workset_market_cells_due = _probe_workset_market_cells_due;
    snapshot.workset_building_cells = _probe_workset_building_cells;
    snapshot.workset_plan_cells = _probe_workset_plan_cells;
    snapshot.workset_live_cells = _probe_workset_live_cells;
    snapshot.workset_coverage_permille = _probe_workset_coverage_permille;
    snapshot.workset_market_bucket = _probe_market_bucket_index;
    snapshot.workset_market_cycle_days = _probe_market_cycle_days;
    snapshot.workset_plan_cycle_days = _probe_plan_cycle_days;
    snapshot.workset_cells_per_slice = _probe_cells_per_slice;
    snapshot.probe_slice_count = _probe_slice_count;
    snapshot.probe_slice_budget_hits = _probe_slice_budget_hits;
    snapshot.probe_slice_ms_total = _probe_slice_ms_total;
    snapshot.probe_slice_ms_max = _probe_slice_ms_max;
    snapshot.probe_attempt_ms = _probe_phase_attempt_ms;
    snapshot.probe_formula_ms = _probe_phase_formula_ms;
    snapshot.probe_publish_ms = _probe_phase_publish_ms;
    snapshot.probe_epoch_open_ms = _epoch_begin_ms;
    snapshot.probe_mirror_capture_ms = _probe_phase_mirror_capture_ms;
    snapshot.probe_mirror_import_ms = _probe_phase_mirror_import_ms;
    snapshot.probe_trade_plan_ms = _probe_trade_plan_ms;
    snapshot.building_investment_ms = _investment_ms;
    snapshot.investment_evaluate_ms = _investment_evaluate_ms;
    snapshot.investment_allocate_ms = _investment_allocate_ms;
    snapshot.investment_prepare_lanes_ms = _investment_prepare_lanes_ms;
    snapshot.investment_prepare_pending_ms = _investment_prepare_pending_ms;
    snapshot.investment_prepare_groups_ms = _investment_prepare_groups_ms;
    snapshot.startup_demand_prepare_ms = _startup_demand_prepare_ms;
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
    // Phase-timer attribution for the optimization gates: one aggregated
    // PK_ECONOMY_COST_CSV row per (epoch, phase). These values already exist for
    // the diagnostics report; recording them costs one map insert per epoch and
    // never touches simulation state.
    const int64_t perf_day = _current_day.get();
    const auto record_epoch_ms = [perf_day](const char *name, double ms) {
        if (ms > 0.0) EconomyCostProbe::record(name, perf_day, ms);
    };
    record_epoch_ms("epoch_perf.building_production", snapshot.building_production_ms);
    record_epoch_ms("epoch_perf.building_production_worker_cpu",
                    snapshot.production_worker_cpu_ms);
    record_epoch_ms("epoch_perf.building_employment", snapshot.building_employment_ms);
    record_epoch_ms("epoch_perf.labor_signal", _labor_signal_ms);
    record_epoch_ms("epoch_perf.building_plan", snapshot.building_plan_ms);
    record_epoch_ms("epoch_perf.building_plan_evaluate", _building_plan_evaluate_ms);
    record_epoch_ms("epoch_perf.building_plan_worker_cpu",
                    snapshot.building_plan_worker_cpu_ms);
    record_epoch_ms("epoch_perf.market_signal", _market_signal_ms);
    record_epoch_ms("epoch_perf.investment", snapshot.building_investment_ms);
    record_epoch_ms("epoch_perf.investment_evaluate", snapshot.investment_evaluate_ms);
    record_epoch_ms("epoch_perf.investment_allocate", snapshot.investment_allocate_ms);
    record_epoch_ms("epoch_perf.startup_demand_prepare",
                    snapshot.startup_demand_prepare_ms);
    record_epoch_ms("epoch_perf.finalize_construction",
                    snapshot.finalize_construction_ms);
    record_epoch_ms("epoch_perf.finalize_reconcile", snapshot.finalize_reconcile_ms);
    record_epoch_ms("epoch_perf.building_factor_refresh",
                    snapshot.building_factor_refresh_ms);
    record_epoch_ms("epoch_perf.building_role_storage",
                    snapshot.building_role_storage_ms);
    record_epoch_ms("epoch_perf.publish", snapshot.aggregate_publish_ms);
    record_epoch_ms("epoch_perf.audit", snapshot.aggregate_audit_ms);
    record_epoch_ms("epoch_perf.household_prepare",
                    snapshot.household_market_prepare_ms);
    record_epoch_ms("epoch_perf.household_worker", snapshot.household_market_worker_ms);
    record_epoch_ms("epoch_perf.household_merge_aggregate",
                    snapshot.household_market_merge_aggregate_ms);
    record_epoch_ms("epoch_perf.household_merge_trade",
                    snapshot.household_market_merge_trade_ms);
    record_epoch_ms("epoch_perf.family_commit_normalize", _family_commit_normalize_ms);
    record_epoch_ms("epoch_perf.family_commit_attribution",
                    _family_commit_attribution_ms);
    record_epoch_ms("epoch_perf.family_behavior_cache", _family_behavior_cache_ms);
    record_epoch_ms("epoch_perf.person_commit_retire", _person_commit_retire_ms);
    record_epoch_ms("epoch_perf.epoch_begin", _epoch_begin_ms);
    record_epoch_ms("epoch_perf.epoch_begin_vector_init", _epoch_begin_vector_init_ms);
    record_epoch_ms("epoch_perf.epoch_begin_reset", _epoch_begin_reset_ms);
    record_epoch_ms("epoch_perf.epoch_begin_country", _epoch_begin_country_ms);
    record_epoch_ms("epoch_perf.epoch_begin_workset", _epoch_begin_workset_ms);
    record_epoch_ms("epoch_perf.epoch_begin_resource_lane",
                    _epoch_begin_resource_lane_ms);
    record_epoch_ms("epoch_perf.epoch_begin_fiscal", _epoch_begin_fiscal_ms);
    record_epoch_ms("epoch_perf.epoch_begin_construction_csr",
                    _epoch_begin_construction_csr_ms);
    record_epoch_ms("epoch_perf.epoch_begin_recovery_apply",
                    _epoch_begin_recovery_apply_ms);
    record_epoch_ms("epoch_perf.epoch_begin_commands", _epoch_begin_commands_ms);
    record_epoch_ms("epoch_perf.prepare", _prepare_ms);
    record_epoch_ms("epoch_perf.price", _price_ms);
    record_epoch_ms("epoch_perf.formula", _formula_ms);
    record_epoch_ms("epoch_perf.clear", _clear_ms);
    EconomyCostProbe::record("epoch_perf.building_factor_cache_hits", perf_day, 0.0,
        static_cast<uint64_t>(std::max<int64_t>(0,
            snapshot.building_factor_cache_hits)));
    EconomyCostProbe::record("epoch_perf.building_factor_cache_misses", perf_day, 0.0,
        static_cast<uint64_t>(std::max<int64_t>(0,
            snapshot.building_factor_cache_misses)));
}

} // namespace pk
