#include "economy_runtime_diagnostics_includes.inc"

namespace pk {

using namespace godot;
using namespace variant_helpers;

void NativeEconomyRuntime::write_workset_probe_report(Dictionary &out) const {
    out["workset_cells_planned"] = _workset_cells_planned;
    out["workset_cells_executed"] = _workset_cells_executed;
    out["prepare_reuse_count"] = _prepare_reuse_count;
    out["duplicate_range_count"] = _duplicate_range_count;
    out["workset_market_cells_due"] = _probe_workset_market_cells_due;
    out["workset_building_cells"] = _probe_workset_building_cells;
    out["workset_plan_cells"] = _probe_workset_plan_cells;
    out["workset_live_cells"] = _probe_workset_live_cells;
    out["workset_coverage_permille"] = _probe_workset_coverage_permille;
    out["workset_market_bucket"] = _probe_market_bucket_index;
    out["workset_market_cycle_days"] = _probe_market_cycle_days;
    out["workset_plan_cycle_days"] = _probe_plan_cycle_days;
    out["workset_cells_per_slice"] = _probe_cells_per_slice;
    out["probe_slice_count"] = _probe_slice_count;
    out["probe_slice_budget_hits"] = _probe_slice_budget_hits;
    out["probe_slice_ms_total"] = _probe_slice_ms_total;
    out["probe_slice_ms_max"] = _probe_slice_ms_max;
    out["probe_attempt_ms"] = _probe_phase_attempt_ms;
    out["probe_formula_ms"] = _probe_phase_formula_ms;
    out["probe_publish_ms"] = _probe_phase_publish_ms;
    out["probe_epoch_open_ms"] = _epoch_begin_ms;
    out["probe_formula_loop_ms"] = std::max(
        0.0, _probe_phase_formula_ms - _epoch_begin_ms);
    // Fixed-cost decomposition inside the epoch. Every value is an existing or
    // newly added epoch accumulator; nothing here is recomputed from wall clock
    // outside the stage that already measured it.
    out["probe_country_capture_ms"] = _epoch_begin_country_ms;
    out["probe_workset_ms"] = _epoch_begin_workset_ms;
    out["probe_resource_lane_ms"] = _epoch_begin_resource_lane_ms;
    out["probe_fiscal_open_ms"] = _epoch_begin_fiscal_ms;
    out["probe_fiscal_settlement_ms"] = _fiscal_settlement_ms;
    out["probe_audit_ms"] = _audit_ms;
    out["probe_household_market_ms"] = _market_worker_ms +
        _household_market_prepare_ms + _market_merge_ms;
    out["probe_investment_ms"] = _investment_ms;
    out["probe_employment_ms"] = _employment_ms;
    out["probe_production_ms"] = _production_ms;
    out["probe_trade_plan_ms"] = _probe_trade_plan_ms;
    // Remaining stage timers inside the formula loop, exposed so the
    // "fixed vs per-cell" table has no large unattributed remainder.
    out["probe_building_plan_ms"] = _building_plan_ms;
    out["probe_price_ms"] = _price_ms;
    out["probe_publish_stage_ms"] = _publish_ms;
    out["probe_trade_settle_ms"] = _trade_settle_ms;
    out["probe_trade_dispatch_ms"] = _trade_dispatch_ms;
    out["probe_family_commit_ms"] = _family_commit_normalize_ms +
        _family_commit_attribution_ms + _family_commit_form_ms +
        _family_commit_index_ms + _family_commit_lifecycle_ms +
        _family_commit_influence_ms;
    out["probe_person_commit_ms"] = _person_commit_retire_ms +
        _person_commit_index_ms + _person_commit_bind_jobs_ms +
        _person_commit_claims_ms + _person_commit_equity_ms +
        _person_commit_promote_ms;
    out["probe_mirror_capture_ms"] = _probe_phase_mirror_capture_ms;
    out["probe_mirror_import_ms"] = _probe_phase_mirror_import_ms;
    // POD publish is whatever the host-measured publish window did not spend on
    // the mirror. It sits OUTSIDE the host's formulas_ms window, so it must
    // never be added into the formula total.
    out["probe_pod_publish_ms"] = std::max(0.0, _probe_phase_publish_ms -
        _probe_phase_mirror_capture_ms - _probe_phase_mirror_import_ms);
}

// Compact probe snapshot meant for cross-thread consumption: only scalar
// counters and the published cadence shape, no market/person/building arrays.
Dictionary NativeEconomyRuntime::probe_report() const {
    Dictionary out;
    out["path"] = "ECONOMY_GRAPH";
    out["mode"] = "native";
    out["report_mode"] = "workset_probe";
    out["configured"] = _configured;
    out["bootstrapped"] = _bootstrapped;
    out["epoch_active"] = _epoch_active;
    out["epoch_id"] = _epoch_id.get();
    out["current_day"] = _current_day.get();
    out["sample_day"] = _sample_day;
    out["last_committed_day"] = _last_committed_day.get();
    out["stage"] = stage_name();
    out["fatal"] = _fatal;
    out["fatal_reason"] = String(_fatal_reason.c_str());
    write_workset_probe_report(out);
    // Full cadence shape: N, plan period, per-knife ms, change reason and the
    // slice-per-epoch estimates. These explain *why* N is what it is, which a
    // bare N column cannot.
    write_cadence_report(out);
    // Cadence shape: the two rotating periods and the slice cap that decide how
    // much of the map one epoch actually touches.
    out["market_cycle_days"] = locked_market_cycle_days();
    out["building_plan_days"] = _building_plan_days.get();
    out["building_cells_per_slice"] = _building_cells_per_slice;
    out["economy_live_cells"] = static_cast<int64_t>(_economy_live_cells.size());
    const CompletedEpochPerf &completed = _last_completed_perf;
    out["last_completed_perf_valid"] = completed.valid;
    out["last_completed_epoch_id"] = completed.epoch_id;
    out["last_completed_sample_day"] = completed.sample_day;
    out["last_completed_prepare_reuse_count"] = completed.prepare_reuse_count;
    out["last_completed_workset_cells_planned"] = completed.workset_cells_planned;
    out["last_completed_workset_cells_executed"] = completed.workset_cells_executed;
    out["last_completed_duplicate_range_count"] = completed.duplicate_range_count;
    out["last_completed_household_market_prepare_ms"] =
        completed.household_market_prepare_ms;
    out["last_completed_household_market_worker_ms"] =
        completed.household_market_worker_ms;
    out["last_completed_household_market_merge_ms"] =
        completed.household_market_merge_ms;
    return out;
}

Dictionary NativeEconomyRuntime::compact_report() const {
    Dictionary out;
    write_hash_work_report(out);
    const int64_t age_days = _epoch_active
        ? std::max<int64_t>(0, _current_day.get() - _sample_day)
        : _settlement_max_age_days;
    const int64_t deadline_day = _sample_day;
    const bool commit_due = _epoch_active && _current_day.get() >= deadline_day;

    out["path"] = "ECONOMY_GRAPH";
    out["mode"] = "native";
    out["report_mode"] = "compact_slice";
    out["configured"] = _configured;
    out["bootstrapped"] = _bootstrapped;
    out["epoch_active"] = _epoch_active;
    out["epoch_id"] = _epoch_id.get();
    out["committed_generation"] = static_cast<int64_t>(_committed_generation);
    out["effect_input_revision"] = static_cast<int64_t>(effect_input_revision());
    out["effect_input_digest_computations"] =
        static_cast<int64_t>(_effect_input_digest_computations);
    out["effect_input_digest_ms"] = _effect_input_digest_ms;
    // One atomic load: reading the shared_ptr directly raced the writer and could
    // dereference a just-released object.
    const std::shared_ptr<const EffectInputConsumers> consumers =
        std::atomic_load_explicit(&_effect_input_consumers,
            std::memory_order_acquire);
    out["effect_input_consumer_columns"] =
        static_cast<int64_t>(consumers == nullptr ? 0 : consumers->metric_mask.count());
    out["effect_input_uses_tags"] = consumers != nullptr && consumers->tags_needed;
    out["sample_day"] = _sample_day;
    out["current_day"] = _current_day.get();
    out["commit_day"] = _commit_day;
    out["last_committed_day"] = _last_committed_day.get();
    out["age_days"] = age_days;
    out["stage"] = stage_name();
    out["next_stage"] = stage_name();
    out["executed_stage"] = stage_name(_executed_stage);
    out["executed_substage"] = _executed_substage.c_str();
    out["progress_q16"] = stage_progress_q16();
    out["publish_phase"] = publish_phase_name(_publish_phase);
    out["building_commit_phase"] = _stage == Stage::BUILDING_COMMIT
        ? _building_commit_phase : -1;
    out["processed_cells"] = _processed_cells;
    out["processed_cohorts"] = _processed_cohorts;
    out["processed_rules"] = _processed_rules;
    out["processed_building_groups"] = _processed_building_groups;
    out["climate_profiled_building_groups"] =
        _climate_profiled_building_groups;
    out["climate_limited_building_groups"] =
        _climate_limited_building_groups;
    out["average_climate_capacity_q16"] =
        _climate_profiled_building_groups > 0
        ? _climate_capacity_sum_q16 / _climate_profiled_building_groups
        : Q16_ONE;

    if (_executed_stage == Stage::TRADE_PLANNING || _trade_plan_ms > 0.0) {
        const double accounted_ms = _trade_plan_scan_body_ms +
            _trade_plan_scan_finalize_ms + _trade_plan_route_prepare_ms +
            _trade_plan_route_expand_ms + _trade_plan_route_finalize_ms;
        Dictionary breakdown_ms;
        breakdown_ms["trade_planning.scan_body"] = _trade_plan_scan_body_ms;
        breakdown_ms["trade_planning.scan_finalize"] = _trade_plan_scan_finalize_ms;
        breakdown_ms["trade_planning.route_prepare"] = _trade_plan_route_prepare_ms;
        breakdown_ms["trade_planning.route_expand"] = _trade_plan_route_expand_ms;
        breakdown_ms["trade_planning.route_finalize"] = _trade_plan_route_finalize_ms;
        breakdown_ms["trade_planning.other"] =
            std::max(0.0, _trade_plan_ms - accounted_ms);
        out["trade_plan_breakdown_ms"] = breakdown_ms;

        Dictionary breakdown_work;
        breakdown_work["trade_planning.scan_pairs"] = _trade_plan_scan_pairs_slice;
        breakdown_work["trade_planning.route_sources_prepared"] =
            _trade_plan_route_sources_prepared_slice;
        breakdown_work["trade_planning.route_expansions"] =
            _trade_plan_route_expansions_slice;
        breakdown_work["trade_planning.candidates_finalized"] =
            _trade_plan_candidates_finalized_slice;
        out["trade_plan_breakdown_work"] = breakdown_work;

        const char *substage = "";
        double substage_ms = 0.0;
        const auto choose_substage = [&](const char *name, double value) {
            if (value > substage_ms) {
                substage = name;
                substage_ms = value;
            }
        };
        choose_substage("scan_body", _trade_plan_scan_body_ms);
        choose_substage("scan_finalize", _trade_plan_scan_finalize_ms);
        choose_substage("route_prepare", _trade_plan_route_prepare_ms);
        choose_substage("route_expand", _trade_plan_route_expand_ms);
        choose_substage("route_finalize", _trade_plan_route_finalize_ms);
        choose_substage("other", std::max(0.0, _trade_plan_ms - accounted_ms));
        out["trade_plan_substage"] = substage;
        if (_executed_substage.empty()) out["executed_substage"] = substage;
    }

    if (_executed_stage == Stage::AGGREGATE_PUBLISH) {
        Dictionary breakdown_ms;
        Dictionary breakdown_work;
        for (size_t phase = 0; phase < static_cast<size_t>(PublishPhase::COUNT); ++phase) {
            const std::string key = std::string("aggregate_publish.") +
                publish_phase_name(static_cast<PublishPhase>(phase));
            breakdown_ms[key.c_str()] = _publish_slice_phase_ms[phase];
            breakdown_work[key.c_str()] = _publish_slice_phase_work[phase];
        }
        const size_t trade_init_phase = static_cast<size_t>(PublishPhase::TRADE_INIT);
        if (_publish_slice_phase_ms[trade_init_phase] > 0.0 &&
            _executed_substage.rfind("trade_init.", 0) == 0) {
            const std::string key = std::string("aggregate_publish.") +
                _executed_substage;
            breakdown_ms[key.c_str()] = _publish_slice_phase_ms[trade_init_phase];
            breakdown_work[key.c_str()] = _publish_slice_phase_work[trade_init_phase];
            breakdown_ms["aggregate_publish.trade_init"] = 0.0;
            breakdown_work["aggregate_publish.trade_init"] = 0;
        }
        breakdown_ms["aggregate_publish.commit_cells"] =
            _publish_commit_cells_slice_ms;
        breakdown_ms["aggregate_publish.commit_prepare"] =
            _publish_commit_prepare_slice_ms;
        breakdown_ms["aggregate_publish.commit_finalize"] =
            _publish_commit_finalize_slice_ms;
        breakdown_work["aggregate_publish.commit_cells"] =
            _publish_slice_phase_work[static_cast<size_t>(PublishPhase::COMMIT)];
        breakdown_work["aggregate_publish.commit_prepare"] =
            _publish_commit_prepare_slice_ms > 0.0 ? 1 : 0;
        breakdown_work["aggregate_publish.commit_finalize"] =
            _publish_commit_finalize_slice_ms > 0.0 ? 1 : 0;
        out["publish_breakdown_ms"] = breakdown_ms;
        out["publish_breakdown_work"] = breakdown_work;
    }

    if (_executed_stage == Stage::BUILDING_COMMIT) {
        static constexpr const char *PHASE_NAMES[BUILDING_COMMIT_PHASE_COUNT] = {
            "review_prepare", "special_reset", "recovery_review",
            "construction_commit", "investment_prepare", "investment",
            "finalize",
        };
        Dictionary breakdown_ms;
        Dictionary breakdown_work;
        for (size_t phase = 0; phase < BUILDING_COMMIT_PHASE_COUNT; ++phase) {
            const std::string key = std::string("building_commit.") + PHASE_NAMES[phase];
            breakdown_ms[key.c_str()] = _building_commit_slice_phase_ms[phase];
            breakdown_work[key.c_str()] = _building_commit_slice_phase_work[phase];
        }
        out["building_commit_breakdown_ms"] = breakdown_ms;
        out["building_commit_breakdown_work"] = breakdown_work;
    }
    if (_executed_stage == Stage::HOUSEHOLD_MARKET) {
        out["household_market_breakdown_ms"] =
            household_slice_breakdown_ms();
        out["household_market_breakdown_work"] =
            household_slice_breakdown_work();
    }

    out["economy_event_newest_id"] = _next_event_id.get() - 1;
    out["economy_event_last_batch_count"] = _committed_event_batches.empty() ? 0 :
        static_cast<int64_t>(_committed_event_batches.back().events.size());
    out["worker_tasks"] = _worker_tasks;
    out["high_speed_batching_enabled"] = _high_speed_batching_enabled;
    out["high_speed_batch_multiplier"] = _active_batch_multiplier;
    out["high_speed_market_dispatches_saved"] =
        _high_speed_market_dispatches_saved;
    out["high_speed_production_dispatches_saved"] =
        _high_speed_production_dispatches_saved;
    out["building_production_worker_tasks"] = _production_worker_tasks;
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
    out["closing_audit_runtime_disabled"] =
        _closing_audit_runtime_disabled;
    out["closing_audit_fast_paths"] = _closing_audit_fast_paths;
    out["closing_audit_full_verifications"] =
        _closing_audit_full_verifications;
    out["closing_audit_mismatches"] = _closing_audit_mismatches;
    out["closing_audit_mismatch_ledger"] =
        _closing_audit_mismatch_ledger.c_str();
    out["closing_audit_mismatch_lane"] = _closing_audit_mismatch_lane;
    out["incremental_closing_population"] =
        _incremental_closing_totals.population;
    out["incremental_closing_cohort_funds"] =
        _incremental_closing_totals.cohort_funds;
    out["incremental_closing_country_cash"] =
        _incremental_closing_totals.country_cash;
    out["incremental_closing_escrow_cash"] =
        _incremental_closing_totals.escrow_cash;
    out["incremental_closing_goods_stock"] =
        _incremental_closing_totals.goods_stock;
    out["incremental_closing_country_goods"] =
        _incremental_closing_totals.country_goods;
    out["incremental_closing_transit_goods"] =
        _incremental_closing_totals.transit_goods;
    out["incremental_closing_expedition_goods"] =
        _incremental_closing_totals.expedition_goods;
    godot::Array goods_audit_candidates;
    for (const GoodsAuditLaneDiagnostic &lane : _goods_audit_candidate_lanes) {
        godot::Dictionary item;
        item["market"] = lane.market;
        item["cell"] = lane.cell;
        item["good_index"] = lane.good;
        item["good_id"] = lane.good >= 0 &&
            lane.good < static_cast<int32_t>(_good_ids.size())
            ? godot::String(_good_ids[lane.good].c_str()) : godot::String("unknown");
        item["opening_stock"] = lane.opening_stock;
        item["closing_stock"] = lane.closing_stock;
        item["net_change"] = lane.net_change;
        goods_audit_candidates.push_back(item);
    }
    out["goods_audit_candidate_lanes"] = goods_audit_candidates;
    godot::Array money_audit_candidates;
    for (const MoneyAuditAccountDiagnostic &account : _money_audit_candidate_accounts) {
        godot::Dictionary item;
        item["slot"] = account.slot;
        item["handle"] = static_cast<int64_t>(account.handle);
        item["cell"] = account.cell;
        item["signature_id"] = account.signature;
        item["profession_id"] = account.profession;
        item["profession"] = account.profession >= 0 &&
            account.profession < static_cast<int32_t>(_profession_ids.size())
            ? godot::String(_profession_ids[account.profession].c_str())
            : godot::String("unknown");
        item["opening_funds"] = account.opening_funds;
        item["closing_funds"] = account.closing_funds;
        item["net_change"] = account.net_change;
        money_audit_candidates.push_back(item);
    }
    out["money_audit_candidate_accounts"] = money_audit_candidates;
    out["opening_escrow_cash"] = _opening_totals.escrow_cash;
    out["closing_escrow_cash"] = _closing_totals.escrow_cash;
    out["producer_support_money_issued"] = _producer_support_money_issued;
    out["bullion_money_issued"] = _bullion_money_issued;
    out["closing_audit_population_touched_lanes"] =
        static_cast<int64_t>(_audit_population_touched_lanes.size());
    out["closing_audit_market_touched_lanes"] =
        static_cast<int64_t>(_audit_market_touched_lanes.size());
    out["closing_audit_population_full_scan_entries"] =
        _closing_audit_population_full_scan_entries;
    out["closing_audit_market_full_scan_entries"] =
        _closing_audit_market_full_scan_entries;
    out["closing_audit_incremental_this_epoch"] =
        _closing_audit_incremental_this_epoch;
    out["investment_scheduled_review_cells"] =
        _investment_scheduled_review_cells;
    out["investment_review_cells"] = _investment_review_cells;
    out["investment_type_evaluations"] =
        _investment_type_evaluations;
    out["investment_market_signal_rejections"] =
        _investment_market_signal_rejections;
    out["investment_ethnicity_evaluations"] =
        _investment_ethnicity_evaluations;
    out["investment_sparse_mode"] =
        _investment_sparse_mode == 0 ? "OFF" :
        (_investment_sparse_mode == 1 ? "PROBE" : "ACTIVE");
    out["investment_sparse_runtime_disabled"] =
        _investment_sparse_runtime_disabled;
    out["investment_sparse_considered_types"] =
        _investment_sparse_considered_types;
    out["investment_sparse_selected_types"] =
        _investment_sparse_selected_types;
    out["investment_sparse_skipped_types"] =
        _investment_sparse_skipped_types;
    out["investment_sparse_mismatches"] =
        _investment_sparse_mismatches;
    out["investment_sparse_dense_fallbacks"] =
        _investment_sparse_dense_fallbacks;
    out["investment_displacement_type_evaluations"] =
        _investment_displacement_type_evaluations;
    out["investment_gate_capital_type_skips"] =
        _investment_gate_capital_type_skips;
    out["building_factor_cache_hits"] = _building_factor_cache_hits;
    out["building_factor_cache_misses"] = _building_factor_cache_misses;
    {
        const int64_t factor_total =
            _building_factor_cache_hits + _building_factor_cache_misses;
        out["building_factor_cache_hit_ratio_q16"] = factor_total > 0
            ? static_cast<int64_t>(
                  (_building_factor_cache_hits * 65536) / factor_total)
            : int64_t{0};
    }
    out["market_signal_cells_rebuilt"] = _market_signal_cells_rebuilt;
    out["labor_signal_cells_rebuilt"] = _labor_signal_cells_rebuilt;
    out["input_reserve_groups_rebuilt"] = _input_reserve_groups_rebuilt;
    out["full_rebuild_reason"] = String(
        !_market_signal_full_rebuild_reason.empty()
            ? _market_signal_full_rebuild_reason.c_str()
            : (!_labor_signal_full_rebuild_reason.empty()
                   ? _labor_signal_full_rebuild_reason.c_str()
                   : _input_reserve_full_rebuild_reason.c_str()));
    out["city_good_output_shared_count"] = static_cast<int64_t>(
        _city_output_shared_goods_q16.size());
    out["city_good_output_non_neutral_shared_count"] = static_cast<int64_t>(
        std::count_if(_city_output_shared_goods_q16.begin(),
            _city_output_shared_goods_q16.end(),
            [](int32_t value) { return value != Q16_ONE; }));
    out["city_good_output_override_count"] = static_cast<int64_t>(
        _city_output_good_indices.size());
    int64_t city_good_output_override_cells = 0;
    for (size_t cell = 0; cell + 1 < _city_output_cell_offsets.size(); ++cell)
        if (_city_output_cell_offsets[cell] != _city_output_cell_offsets[cell + 1])
            ++city_good_output_override_cells;
    out["city_good_output_override_cell_count"] =
        city_good_output_override_cells;
    out["city_good_output_cache_bytes"] = static_cast<int64_t>(
        _city_output_shared_goods_q16.capacity() * sizeof(int32_t) +
        _city_output_cell_offsets.capacity() * sizeof(int32_t) +
        _city_output_good_indices.capacity() * sizeof(int32_t) +
        _city_output_factors_q16.capacity() * sizeof(int32_t));
    out["cell_tax_compiled_policy_count"] = static_cast<int64_t>(
        _epoch_compiled_cell_tax_policies.empty()
            ? 0 : _epoch_compiled_cell_tax_policies.size() - 1);
    out["cell_tax_shared_default_row_count"] = static_cast<int64_t>(
        _epoch_compiled_cell_tax_default_rows.size());
    out["cell_tax_compiled_override_count"] = static_cast<int64_t>(
        _epoch_compiled_cell_tax_overrides.size());
    out["cell_tax_cache_bytes"] = _epoch_cell_tax_cache_bytes;
    out["cell_tax_epoch_compile_ms"] = _epoch_cell_tax_compile_ms;
    out["fiscal_business_prospective_lanes"] =
        _fiscal_business_prospective_lanes;
    out["fiscal_business_prospective_request"] =
        _fiscal_business_prospective_request;
    out["approximation_probe_violations"] =
        _approximation_probe_violations;
    out["approximation_probe_max_spend_error_q16"] =
        _approximation_probe_max_spend_error_q16;
    out["approximation_probe_max_demand_error_q16"] =
        _approximation_probe_max_demand_error_q16;
    out["approximation_cooldown_epochs_left"] =
        _approximation_cooldown_epochs_left;
    out["budgeted_building_commit_phase_fusions"] =
        _budgeted_building_commit_phase_fusions;
    out["budgeted_publish_phase_fusions"] =
        _budgeted_publish_phase_fusions;
    out["family_runtime_mode"] = _family_runtime_mode.get() == 0 ? "OFF" :
        (_family_runtime_mode.get() == 1 ? "PROBE" : "ACTIVE");
    out["family_count"] = families_store().active_count.get();
    out["family_membership_edge_count"] = static_cast<int64_t>(
        family_memberships().size());
    out["family_ownership_edge_count"] = static_cast<int64_t>(
        family_ownerships().size());
    out["family_trait_roll_count"] = static_cast<int64_t>(
        family_trait_rolls().size());
    out["family_branch_count"] = static_cast<int64_t>(std::count(
        family_influences().active.begin(), family_influences().active.end(),
        uint8_t{1}));
    out["family_modifier_binding_count"] = static_cast<int64_t>(
        _family_modifier_bindings.size());
    out["family_trigger_binding_count"] = static_cast<int64_t>(
        _family_trigger_bindings.size());
    out["family_effect_binding_count"] = static_cast<int64_t>(
        _family_effect_bindings.size());
    out["family_owned_output_row_count"] = static_cast<int64_t>(
        _family_owned_output_rows.size());
    out["family_industry_stat_count"] = static_cast<int64_t>(
        _family_industry_stats.size());
    out["family_behavior_factor_row_count"] = static_cast<int64_t>(
        _family_behavior_factor_rows.size());
    out["family_behavior_class_row_count"] = _family_behavior_class_rows;
    out["family_behavior_cache_rebuilds"] =
        _family_behavior_cache_rebuilds;
    out["family_behavior_cache_skips"] = _family_behavior_cache_skips;
    out["family_behavior_metric_contexts_built"] =
        _family_behavior_metric_contexts_built;
    out["family_behavior_condition_edges_evaluated"] =
        _family_behavior_condition_edges_evaluated;
    out["family_behavior_cache_ms"] = _family_behavior_cache_ms;
    out["family_behavior_cache_dirty"] = _family_behavior_cache_dirty;
    out["family_behavior_cache_last_dirty_reasons"] = static_cast<int64_t>(
        _family_behavior_cache_last_reasons);
    out["family_expedition_active_count"] = static_cast<int64_t>(std::count(
        family_expeditions_store().active.begin(), family_expeditions_store().active.end(),
        uint8_t{1}));
    out["family_expedition_due_heap_count"] = static_cast<int64_t>(
        _family_expedition_due_heap.size());
    out["family_expedition_transit_population"] = [&]() {
        int64_t total = 0;
        int64_t local_saturation_count = 0;
        for (size_t index = 0; index < family_expeditions_store().active.size(); ++index)
            if (family_expeditions_store().active[index] != 0)
                total = saturating_add(total,
                    family_expedition_payload_people(static_cast<int32_t>(index)),
                    local_saturation_count);
        return total;
    }();
    out["colonization_route_query_ms"] = _colonization_route_query_ms;
    out["colonization_payload_split_ms"] = _colonization_payload_split_ms;
    out["colonization_cross_domain_ms"] = _colonization_cross_domain_ms;
    out["canal_quote_count"] = static_cast<int64_t>(_canal_quotes.size());
    out["canal_active_quote_count"] = static_cast<int64_t>(
        _canal_quote_index.size());
    out["canal_project_count"] = static_cast<int64_t>(_canal_projects.size());
    out["canal_next_project_id"] = static_cast<int64_t>(_next_canal_project_id.get());
    out["canal_receipt_count"] = static_cast<int64_t>(_canal_receipts.size());
    int64_t canal_building = 0;
    int64_t canal_awaiting_effect = 0;
    int64_t canal_completed = 0;
    int64_t canal_failed = 0;
    for (const CanalProject &project : _canal_projects) {
        if (project.state == CANAL_PROJECT_BUILDING) ++canal_building;
        else if (project.state == CANAL_PROJECT_AWAITING_EFFECT)
            ++canal_awaiting_effect;
        else if (project.state == CANAL_PROJECT_COMPLETED) ++canal_completed;
        else if (project.state == CANAL_PROJECT_FAILED) ++canal_failed;
    }
    out["canal_project_building_count"] = canal_building;
    out["canal_project_awaiting_effect_count"] = canal_awaiting_effect;
    out["canal_project_completed_count"] = canal_completed;
    out["canal_project_failed_count"] = canal_failed;
    out["canal_topology_hash"] = static_cast<int64_t>(
        _trade_topology.topology_hash & 0x7fffffffffffffffULL);
    int64_t canal_directed_edges = 0;
    for (const uint8_t mask : _trade_topology.canal_edge_mask)
        for (int direction = 0; direction < 6; ++direction)
            canal_directed_edges += (mask >> direction) & 1U;
    out["canal_edge_count"] = canal_directed_edges / 2;
    out["family_membership_edges_processed"] =
        _family_membership_edges_processed;
    out["family_ownership_edges_processed"] =
        _family_ownership_edges_processed;
    out["families_formed"] = _families_formed;
    out["family_offers_opened"] = _family_offers_opened;
    out["family_offers_auto_resolved"] = _family_offers_auto_resolved;
    out["family_offer_choice_rejected"] = _family_offer_choice_rejected;
    out["family_offers_voided"] = _family_offers_voided;
    out["family_offers_pending"] = static_cast<int64_t>(_family_founding_offers.size());
    out["families_dissolved"] = _families_dissolved;
    out["family_owner_jobs_filled"] = _family_owner_jobs_filled;
    out["family_owner_jobs_vacant"] = _family_owner_jobs_vacant;
    out["family_births_attributed"] = _family_births_attributed;
    out["family_deaths_attributed"] = _family_deaths_attributed;
    out["family_reconcile_corrections"] = _family_reconcile_corrections;
    out["family_ledger_clamps"] = _family_ledger_clamps;
    out["family_people_recruited"] = _family_people_recruited;
    out["family_units_released"] = _family_units_released;
    out["family_release_deferred"] = _family_release_deferred;
    out["family_owner_seats_guarded"] = _family_owner_seats_guarded;
    out["family_demography_rows"] = static_cast<int64_t>(_family_demography_rows.size());
    out["family_demography_weights_ms"] = _family_demography_weights_ms;
    out["notable_person_runtime_mode"] = _person_runtime_mode.get() == 0 ? "OFF" :
        (_person_runtime_mode.get() == 1 ? "PROBE" : "ACTIVE");
    out["notable_person_count"] = persons_store().active_count.get();
    out["person_need_edge_count"] = static_cast<int64_t>(person_needs().size());
    out["persons_promoted"] = _persons_promoted;
    out["persons_died"] = _persons_died;
    out["persons_migrated"] = _persons_migrated;
    out["person_jobs_bound"] = _person_jobs_bound;
    out["person_need_edges_processed"] = _person_need_edges_processed;
    out["settlement_phase"] = _rolling_phase;
    out["due_cells"] = _rolling_due_cells;
    out["processed_due_cells"] = _rolling_processed_cells;
    // Host/graph pulses store compact reports; expose procurement so Country
    // ACTIVE repurchase regressions can observe durable counters without a
    // full diagnostic copy every cursor slice.
    out["government_research_procured_points"] =
        _government_research_procured_points.get();
    out["government_research_procurement_cash"] =
        _government_research_procurement_cash.get();
    out["government_research_procurement_orders"] =
        _government_research_procurement_orders.get();
    out["country_research_procurement_rejections"] =
        _country_research_procurement_rejections;
    out["country_research_procurement_transactions"] =
        _country_research_procurement_transactions;
    out["country_research_procurement_continuation_active"] =
        _country_research_procurement_continuation.active;
    out["country_research_procurement_continuation_phase"] =
        _country_research_procurement_continuation.phase;
    out["country_research_procurement_last_error"] =
        String::utf8(_country_research_procurement_continuation.last_error.c_str());
    out["deferred_cells"] = _rolling_deferred_cells;
    out["settlement_watermark"] = _settlement_watermark;
    out["newest_state_day"] = _settlement_newest_day;
    out["max_state_age_days"] = _settlement_max_age_days;
    out["fatal_reason"] = String(_fatal_reason.c_str());
    out["fatal"] = _fatal;
    out["fatal_context"] = fatal_context_report();
    out["build_id"] = String::utf8(pk::pk_build_id());
    out["restore_rejected_reason"] = String(_restore_rejected_reason.c_str());
    out["commit_over_budget"] = _epoch_active && age_days > _commit_lag_budget_days;
    out["commit_due"] = commit_due;
    out["boundary_continuation_required"] = false;
    write_fiscal_continuation_report(out);
    out["cycle_deadline_day"] = deadline_day;
    write_cadence_report(out);
    write_workset_probe_report(out);
    out["workload_deadline_feasible"] = _workload_deadline_feasible;
    out["workload_cycle_clamped"] = _workload_cycle_clamped;
    return out;
}

Dictionary NativeEconomyRuntime::committed_audit_report() const {
    Dictionary out;
    const auto view = std::atomic_load_explicit(&_committed_audit_view,
        std::memory_order_acquire);
    out["available"] = view != nullptr;
    if (!view) return out;
    out["generation"] = static_cast<int64_t>(view->generation);
    out["day"] = view->day;
    out["revision_phase"] = "before_effect_command_drain";
    out["full_verification"] = view->full_verification;
    out["population_error"] = view->population_actual - view->population_expected;
    out["money_error"] = view->money_actual - view->money_expected;
    out["goods_error"] = view->goods_actual - view->goods_expected;
    out["audit_incomplete"] = false;
    return out;
}

void NativeEconomyRuntime::write_hash_work_report(Dictionary &out) const {
    out["hash_version"] = runtime_chunk_hash_enabled() ? 2 : 1;
    RuntimeChunkHash::Metrics hash_metrics{};
    RuntimeChunkHash::Metrics cumulative_hash_metrics{};
    const auto &market_pages = _formula_owned != nullptr ? _formula_owned->market_hash_pages : _market_hash_pages;
    for (const auto &column : market_pages) {
        const auto metrics = column.metrics();
        hash_metrics.compared_bytes += metrics.compared_bytes;
        hash_metrics.copied_bytes += metrics.copied_bytes;
        hash_metrics.rebuilt_pages += metrics.rebuilt_pages;
        hash_metrics.reused_pages += metrics.reused_pages;
        const auto cumulative = column.cumulative_metrics();
        cumulative_hash_metrics.compared_bytes += cumulative.compared_bytes;
        cumulative_hash_metrics.copied_bytes += cumulative.copied_bytes;
        cumulative_hash_metrics.rebuilt_pages += cumulative.rebuilt_pages;
        cumulative_hash_metrics.reused_pages += cumulative.reused_pages;
    }
    const auto fiscal_metrics = _fiscal_hash_pages.metrics();
    hash_metrics.compared_bytes += fiscal_metrics.compared_bytes;
    hash_metrics.copied_bytes += fiscal_metrics.copied_bytes;
    hash_metrics.rebuilt_pages += fiscal_metrics.rebuilt_pages;
    hash_metrics.reused_pages += fiscal_metrics.reused_pages;
    const auto fiscal_cumulative = _fiscal_hash_pages.cumulative_metrics();
    cumulative_hash_metrics.compared_bytes += fiscal_cumulative.compared_bytes;
    cumulative_hash_metrics.copied_bytes += fiscal_cumulative.copied_bytes;
    cumulative_hash_metrics.rebuilt_pages += fiscal_cumulative.rebuilt_pages;
    cumulative_hash_metrics.reused_pages += fiscal_cumulative.reused_pages;
    out["hash_compared_bytes"] = static_cast<int64_t>(hash_metrics.compared_bytes);
    out["hash_copied_bytes"] = static_cast<int64_t>(hash_metrics.copied_bytes);
    out["hash_rebuilt_pages"] = static_cast<int64_t>(hash_metrics.rebuilt_pages);
    out["hash_reused_pages"] = static_cast<int64_t>(hash_metrics.reused_pages);
    out["hash_cumulative_compared_bytes"] = static_cast<int64_t>(cumulative_hash_metrics.compared_bytes);
    out["hash_cumulative_copied_bytes"] = static_cast<int64_t>(cumulative_hash_metrics.copied_bytes);
    out["hash_cumulative_rebuilt_pages"] = static_cast<int64_t>(cumulative_hash_metrics.rebuilt_pages);
    out["hash_cumulative_reused_pages"] = static_cast<int64_t>(cumulative_hash_metrics.reused_pages);
}

} // namespace pk
