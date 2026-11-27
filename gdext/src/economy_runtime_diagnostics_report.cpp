#include "economy_runtime_diagnostics_includes.inc"

namespace pk {

using namespace godot;
using namespace variant_helpers;

Dictionary NativeEconomyRuntime::report() const {
    Dictionary out;
    write_hash_work_report(out);
    const int64_t age_days = _epoch_active
        ? std::max<int64_t>(0, _current_day.get() - _sample_day)
        : _settlement_max_age_days;
    const int64_t deadline_day = _sample_day;
    const bool commit_due = _epoch_active && _current_day.get() >= deadline_day;
    const int64_t population_expected = _opening_totals.population + _births - _deaths +
                                        _external_population_delta;
    const int64_t money_open = _opening_totals.cohort_funds +
        _opening_totals.country_cash + _opening_totals.escrow_cash;
    const int64_t money_close = _closing_totals.cohort_funds +
        _closing_totals.country_cash + _closing_totals.escrow_cash;
    const int64_t goods_expected = _opening_totals.goods_stock +
        _explicit_stock_delta + _production_output_stock +
        _production_output_discarded + _production_output_retained -
        _consumed_goods - _owner_output_consumed -
        _construction_goods_consumed - _production_inputs_consumed -
        _maintenance_goods_consumed -
        _production_output_discarded - _cycle_flow_discarded -
        _bullion_stock_consumed - _country_research_goods_consumed;
    out["path"] = "ECONOMY_GRAPH";
    out["mode"] = "native";
    out["report_mode"] = "full";
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
    write_cadence_report(out);
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
    out["publish_entries_per_slice"] = PUBLISH_ENTRIES_PER_SLICE;
    out["publish_audit_entries_per_slice"] = PUBLISH_AUDIT_ENTRIES_PER_SLICE;
    out["building_review_groups_per_slice"] = BUILDING_REVIEW_GROUPS_PER_SLICE;
    out["investment_cells_per_slice"] =
        _investment_cells_per_slice;
    out["building_finalize_cells_per_slice"] =
        _building_finalize_cells_per_slice;
    out["building_plan_cells_per_slice"] =
        _building_plan_cells_per_slice_override > 0
        ? _building_plan_cells_per_slice_override
        : std::min(65536, std::max(1, _building_cells_per_slice) * 2);
    out["plan_evaluate_cells"] =
        static_cast<int64_t>(_epoch_plan_cells.size());
    out["household_post_building_cells_per_slice"] =
        _household_post_building_cells_per_slice_override > 0
        ? _household_post_building_cells_per_slice_override
        : std::min(65536, std::max(1, _building_cells_per_slice) * 2);
    out["epoch_available_building_type_count"] = static_cast<int64_t>(
        _epoch_country_building_type_indices.size());
    out["household_market_phase"] = _stage == Stage::HOUSEHOLD_MARKET
        ? _household_market_phase : -1;
    out["building_plan_phase"] = _stage == Stage::BUILDING_PLAN
        ? _building_plan_phase : -1;
    out["building_commit_phase"] = _stage == Stage::BUILDING_COMMIT
        ? _building_commit_phase : -1;
    out["processed_cells"] = _processed_cells;
    out["processed_cohorts"] = _processed_cohorts;
    out["processed_rules"] = _processed_rules;
    out["processed_commands"] = _processed_commands;
    out["rejected_commands"] = _rejected_commands;
    out["formula_ms"] = _formula_ms;
    out["clear_ms"] = _clear_ms;
    out["ledger_ms"] = _ledger_ms;
    out["processed_needs"] = _processed_needs;
    out["processed_variants"] = _processed_variants;
    out["processed_components"] = _processed_components;
    out["carrying_old_resource_scan_steps"] = _carrying_old_resource_scan_steps;
    out["food_output_events"] = _food_output_events;
    out["food_input_events"] = _food_input_events;
    out["food_trade_events"] = _food_trade_events;
    out["food_access_events"] = _food_access_events;
    out["fallback_ms"] = _fallback_ms;
    out["merchant_settle_ms"] = _merchant_settle_ms;
    out["price_ms"] = _price_ms;
    out["structure_ms"] = _structure_ms;
    out["prosperity_changed_cells"] = _prosperity_changed_cells;
    out["prosperity_promotions"] = _prosperity_promotions;
    out["prosperity_demotions"] = _prosperity_demotions;
    out["settlement_names_assigned"] = _settlement_names_assigned;
    out["settlement_names_released"] = _settlement_names_released;
    out["settlement_name_collision_probes"] =
        _settlement_name_collision_probes;
    out["prosperity_update_ms"] = _prosperity_update_ms;
    out["settlement_revision"] = _settlements.revision;
#include "economy_runtime_diagnostics_memory_and_live_timing.inc"
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
    out["last_completed_price_numeric_floor_hits"] = _last_completed_perf.price_numeric_floor_hits;
    out["last_completed_price_numeric_ceiling_hits"] = _last_completed_perf.price_numeric_ceiling_hits;
#include "economy_runtime_diagnostics_last_epoch_timing.inc"
#include "economy_runtime_diagnostics_settlement_activity.inc"
    out["trade_runtime_mode"] = _trade_runtime_mode.get() == 0 ? "OFF"
        : (_trade_runtime_mode.get() == 1 ? "PROBE" : "ACTIVE");
    out["trade_topology_ready"] = _trade_topology.ready;
    out["trade_topology_generation"] = static_cast<int64_t>(
        _trade_topology.topology_generation);
    out["trade_topology_hash"] = static_cast<int64_t>(
        _trade_topology.topology_hash);
    int64_t water_portals = 0;
    int64_t water_portal_edges = 0;
    for (const auto &graph : _trade_topology.water_portals) {
        water_portals += static_cast<int64_t>(graph.portal_cells.size());
        water_portal_edges += static_cast<int64_t>(graph.targets.size());
    }
    out["trade_water_portal_count"] = water_portals;
    out["trade_water_portal_edges"] = water_portal_edges;
    // Compatibility key retained for CSV/UI readers; this is now the stable
    // frozen border hash rather than the country's treasury mutation generation.
    out["trade_country_generation"] = static_cast<int64_t>(
        _trade_topology.component_country_hash);
    out["trade_country_topology_hash"] = static_cast<int64_t>(
        _epoch_country_topology_hash);
    out["trade_plan_phase"] = _trade_plan.phase == TradePlanStore::SCAN ? "SCAN"
        : (_trade_plan.phase == TradePlanStore::ROUTE ? "ROUTE" : "IDLE");
    out["trade_scan_cursor"] = _trade_plan.scan_cursor;
    out["trade_scan_total"] = _trade_plan.scan_total;
    out["trade_active_key_count"] = static_cast<int64_t>(_trade_active_keys.size());
    out["trade_scan_progress_q16"] = _trade_plan.scan_total <= 0 ? 0
        : static_cast<int64_t>(std::min<int64_t>(Q16_ONE,
            (_trade_plan.scan_cursor * Q16_ONE) / _trade_plan.scan_total));
    out["trade_completed_scans"] = _trade_plan.completed_scans;
    out["trade_route_cursor"] = _trade_plan.route_cursor;
    out["trade_route_total"] = static_cast<int64_t>(_trade_plan.sources.size());
    out["trade_source_signals"] = static_cast<int64_t>(_trade_plan.sources.size());
    out["trade_destination_signals"] =
        static_cast<int64_t>(_trade_plan.destinations.size());
    out["trade_route_current_source_cell"] =
        _trade_plan.route_cursor >= 0 && _trade_plan.route_cursor <
            static_cast<int32_t>(_trade_plan.sources.size())
        ? _trade_plan.sources[_trade_plan.route_cursor].cell : -1;
    out["trade_route_current_source_good"] =
        _trade_plan.route_cursor >= 0 && _trade_plan.route_cursor <
            static_cast<int32_t>(_trade_plan.sources.size())
        ? _trade_plan.sources[_trade_plan.route_cursor].good : -1;
    out["trade_route_current_source_country"] =
        _trade_plan.route_cursor >= 0 && _trade_plan.route_cursor <
            static_cast<int32_t>(_trade_plan.sources.size())
        ? _trade_plan.sources[_trade_plan.route_cursor].country : -1;
    out["trade_route_search_active"] = _trade_plan.route_search_active;
    out["trade_route_search_source"] = _trade_plan.route_search_source;
    out["trade_route_expansion_cursor"] = _trade_plan.route_search_expansions;
    out["trade_route_expansions_per_slice"] =
        TRADE_ROUTE_EXPANSIONS_PER_SLICE;
    out["trade_route_pending_targets"] =
        _trade_plan.route_search_pending_targets;
    out["trade_route_accepted_targets"] =
        _trade_plan.route_search_accepted;
    out["trade_plan_reset_count"] = _trade_plan_reset_count;
    out["trade_topology_content_change_count"] =
        _trade_topology_content_change_count;
    out["trade_last_plan_reset_reason"] = String(
        _trade_last_plan_reset_reason.c_str());
    out["trade_source_signals"] = static_cast<int64_t>(_trade_plan.sources.size());
    out["trade_destination_signals"] = static_cast<int64_t>(
        _trade_plan.destinations.size());
    out["trade_ready_candidates"] = static_cast<int64_t>(
        _trade_plan.ready_candidates.size());
    out["trade_signal_max_age_days"] = _trade_signal_max_age_days;
    out["trade_first_dispatch_delay_max_days"] =
        _trade_first_dispatch_delay_max_days;
    out["trade_response_deadline_misses"] = _trade_response_deadline_misses;
    out["trade_response_deadline_misses_cumulative"] =
        _trade_response_deadline_misses_cumulative;
    out["trade_unresolved_no_attempt"] = _trade_unresolved_no_attempt;
    out["trade_unresolved_no_spread"] = _trade_unresolved_no_spread;
    out["trade_unresolved_margin"] = _trade_unresolved_margin;
    out["trade_unresolved_route"] = _trade_unresolved_route;
    out["trade_unresolved_stock"] = _trade_unresolved_stock;
    out["trade_unresolved_capacity"] = _trade_unresolved_capacity;
    out["trade_unresolved_cash"] = _trade_unresolved_cash;
    out["trade_unresolved_order_cap"] = _trade_unresolved_order_cap;
    out["trade_route_expansions"] = _trade_route_expansions;
    out["trade_route_cache_hits"] = _trade_route_cache_hits;
    out["trade_route_cache_misses"] = _trade_route_cache_misses;
    out["trade_candidates_generated"] = _trade_candidates_generated;
    out["trade_candidates_accepted"] = _trade_candidates_accepted;
    out["trade_rejected_profit"] = _trade_rejected_profit;
    out["trade_rejected_no_spread"] = _trade_rejected_no_spread;
    out["trade_rejected_margin"] = _trade_rejected_margin;
    out["trade_quantity_profit_clips"] = _trade_quantity_profit_clips;
    out["trade_relief_candidates"] = _trade_relief_candidates;
    out["trade_rejected_capacity"] = _trade_rejected_capacity;
    out["trade_rejected_stock"] = _trade_rejected_stock;
    out["trade_rejected_cash"] = _trade_rejected_cash;
    out["trade_rejected_route"] = _trade_rejected_route;
    out["trade_rejected_vision"] = _trade_rejected_vision;
    out["trade_vision_gated"] = _epoch_trade_vision_gated;
    out["trade_rejected_order_cap"] = _trade_rejected_order_cap;
    out["trade_active_keys_pruned"] = _trade_active_keys_pruned;
    out["trade_deficit_episodes_started"] = _trade_deficit_episodes_started;
    out["trade_deficit_episodes_resolved"] = _trade_deficit_episodes_resolved;
    out["trade_candidates_stale_generation"] =
        _trade_candidates_stale_generation;
    out["trade_candidates_arbitrated_out"] =
        _trade_candidates_arbitrated_out;
    out["trade_true_source_stock_failures"] =
        _trade_true_source_stock_failures;
    out["trade_orders_in_flight"] = trade_orders_store().size();
    out["trade_arrival_bucket_count"] = static_cast<int64_t>(
        trade_orders_store().arrival_bucket_days.size());
    out["trade_orders_dispatched"] = _trade_orders_dispatched;
    out["trade_orders_arrived"] = _trade_orders_arrived;
    out["trade_unclaimed_orders"] = _trade_unclaimed_orders;
    out["trade_capacity_available"] = _trade_capacity_available;
    out["trade_capacity_used"] = _trade_capacity_used;
    out["trade_capacity_utilization_q16"] = _trade_capacity_available <= 0 ? 0
        : std::min<int64_t>(Q16_ONE,
            (_trade_capacity_used * Q16_ONE) / _trade_capacity_available);
    out["trade_tariff_lane_count"] = static_cast<int64_t>(
        _tariff_epoch_cells.size());
    out["trade_country_good_aggregate_count"] = static_cast<int64_t>(
        _country_good_trade.countries.size());
    out["trade_country_partner_aggregate_count"] = static_cast<int64_t>(
        _country_partner_trade.countries.size());
    out["trade_transit_goods"] = trade_transit_goods();
    out["trade_escrow_cash"] = trade_escrow_cash();
    out["trade_settlement_lag_days"] = _trade_settlement_lag_days;
    out["price_cost_anchor_hits"] = _price_cost_anchor_hits;
    out["price_inactive_reversions"] = _price_inactive_reversions;
    out["unprofitable_building_groups"] = _unprofitable_building_groups;
    out["zero_utilization_building_groups"] = _zero_utilization_building_groups;
    out["average_planned_utilization_q16"] = building_count() == 0 ? Q16_ONE :
        _utilization_sum_q16 / static_cast<int64_t>(building_count());
    out["building_resource_capacity_checks"] = _building_resource_capacity_checks;
    out["building_resource_capacity_limited_groups"] =
        _building_resource_capacity_limited_groups;
    out["last_building_rejection_reason"] = String(_last_building_rejection_reason.c_str());
    // A fatal aborts the epoch before AGGREGATE_PUBLISH recomputes the closing
    // totals, so the three deltas below would compare this epoch's staged mints
    // and stock against last epoch's close. Report them as zero and say why:
    // reading them as a real imbalance sent every previous investigation after
    // a conservation bug that did not exist.
    const bool audit_incomplete = !_epoch_active && !_closing_totals_valid;
    out["audit_incomplete"] = audit_incomplete;
    out["audit_incomplete_reason"] = audit_incomplete
        ? String(_fatal ? "epoch_aborted_before_closing_audit"
                        : "closing_audit_not_run_this_epoch")
        : String("");
    const bool conservation_reportable = !_epoch_active && !audit_incomplete;
    out["population_error"] = conservation_reportable
        ? _closing_totals.population - population_expected : 0;
    out["opening_population"] = _opening_totals.population;
    out["closing_population"] = _closing_totals.population;
    out["population_expected"] = population_expected;
    out["external_population_delta"] = _external_population_delta;
    out["money_error"] = conservation_reportable
        ? money_close - (money_open + _explicit_money_mint - _explicit_money_burn)
        : 0;
    godot::Array money_stage_diagnostics;
    money_stage_diagnostics.resize(
        static_cast<int64_t>(_money_stage_diagnostics.size()));
    for (size_t index = 0; index < _money_stage_diagnostics.size(); ++index) {
        const MoneyStageDiagnostic &diagnostic =
            _money_stage_diagnostics[index];
        godot::Dictionary item;
        item["day"] = diagnostic.day;
        item["epoch_id"] = diagnostic.epoch_id;
        item["stage"] = stage_name(
            static_cast<Stage>(diagnostic.stage));
        item["executed_stage"] = stage_name(
            static_cast<Stage>(diagnostic.executed_stage));
        item["where"] = String::utf8(diagnostic.where.data());
        item["substage"] = String::utf8(diagnostic.substage.data());
        item["money_open"] = diagnostic.money_open;
        item["money_now"] = diagnostic.money_now;
        item["money_expected"] = diagnostic.money_expected;
        item["diff"] = diagnostic.diff;
        item["delta"] = diagnostic.delta;
        item["cohort_funds"] = diagnostic.cohort_funds;
        item["country_cash"] = diagnostic.country_cash;
        item["escrow_cash"] = diagnostic.escrow_cash;
        item["explicit_money_mint"] = diagnostic.explicit_money_mint;
        item["explicit_money_burn"] = diagnostic.explicit_money_burn;
        money_stage_diagnostics[index] = item;
    }
    out["money_stage_diagnostics"] = money_stage_diagnostics;
    out["money_open"] = money_open;
    out["money_close"] = money_close;
    out["money_expected"] = money_open + _explicit_money_mint - _explicit_money_burn;
    out["explicit_money_mint"] = _explicit_money_mint;
    out["explicit_money_burn"] = _explicit_money_burn;
    out["opening_cohort_funds"] = _opening_totals.cohort_funds;
    out["closing_cohort_funds"] = _closing_totals.cohort_funds;
    out["opening_country_cash"] = _opening_totals.country_cash;
    out["closing_country_cash"] = _closing_totals.country_cash;
    out["opening_escrow_cash"] = _opening_totals.escrow_cash;
    out["closing_escrow_cash"] = _closing_totals.escrow_cash;
    out["opening_expedition_funds"] = _opening_totals.expedition_funds;
    out["closing_expedition_funds"] = _closing_totals.expedition_funds;
    out["opening_expedition_goods"] = _opening_totals.expedition_goods;
    out["closing_expedition_goods"] = _closing_totals.expedition_goods;
    out["opening_transit_goods"] = _opening_totals.transit_goods;
    out["closing_transit_goods"] = _closing_totals.transit_goods;
    out["opening_transit_population"] = _opening_totals.transit_population;
    out["closing_transit_population"] = _closing_totals.transit_population;
    out["closing_audit_incremental_this_epoch"] =
        _closing_audit_incremental_this_epoch;
    out["opening_goods_stock"] = _opening_totals.goods_stock;
    out["closing_goods_stock"] = _closing_totals.goods_stock;
    out["opening_country_goods"] = _opening_totals.country_goods;
    out["closing_country_goods"] = _closing_totals.country_goods;
    out["goods_expected"] = goods_expected;
    out["goods_error"] = conservation_reportable
        ? _closing_totals.goods_stock - goods_expected : 0;
    out["country_research_goods_consumed"] =
        _country_research_goods_consumed;
    out["saturation_count"] = _saturation_count;
    out["fatal_reason"] = String(_fatal_reason.c_str());
    out["fatal"] = _fatal;
    out["fatal_context"] = fatal_context_report();
    out["build_id"] = String::utf8(pk::pk_build_id());
    out["restore_rejected_reason"] = String(_restore_rejected_reason.c_str());
    out["commit_lag_budget_days"] = _commit_lag_budget_days;
    out["commit_over_budget"] = _epoch_active && age_days > _commit_lag_budget_days;
    out["commit_due"] = commit_due;
    out["boundary_continuation_required"] = false;
    write_fiscal_continuation_report(out);
    out["cycle_deadline_day"] = deadline_day;
    out["days_until_commit"] = _epoch_active
        ? std::max<int64_t>(0, deadline_day - _current_day.get()) : 0;
    write_cadence_report(out);
    out["market_target_cohorts_per_slice"] = _target_cohorts_per_slice;
    out["market_cells_per_slice"] = _cells_per_slice;
    out["building_cells_per_slice"] = _building_cells_per_slice;
    out["estimated_market_slices_per_epoch"] =
        _estimated_market_slices_per_epoch;
    out["estimated_building_slices_per_epoch"] =
        _estimated_building_slices_per_epoch;
    out["estimated_total_slices_per_epoch"] =
        _estimated_total_slices_per_epoch;
    out["workload_deadline_feasible"] = _workload_deadline_feasible;
    out["workload_cycle_clamped"] = _workload_cycle_clamped;
    out["approximation_version"] = 19;
    out["approximation_model"] =
        "rolling_cell_settlement_v19_class_good_elasticity";
    out["economy_accuracy_preset"] = _accuracy_preset == 0 ? "EXACT" :
        (_accuracy_preset == 1 ? "BALANCED" :
        (_accuracy_preset == 2 ? "FAST" : "CUSTOM"));
    out["economy_approximation_runtime_mode"] =
        _approximation_runtime_mode == 0 ? "OFF" :
        (_approximation_runtime_mode == 1 ? "PROBE" : "ACTIVE");
    out["approximation_large_world_scalar_guard"] = false;
    out["approximation_authoritative"] =
        _approximation_runtime_mode == 2 && _accuracy_preset != 0 &&
        _approximation_cooldown_epochs_left == 0;
    out["accuracy_max_regret_q16"] = _accuracy_max_regret_q16;
    out["accuracy_household_tail_share_q16"] =
        _accuracy_household_tail_share_q16;
    out["accuracy_candidate_top_k"] = _accuracy_candidate_top_k;
    out["accuracy_choice_temperature_q16"] =
        _accuracy_choice_temperature_q16;
    out["employment_mobility_daily_q16"] = _employment_mobility_daily_q16.get();
    out["employment_understaffed_reallocation_hurdle_mult_q16"] =
        _employment_understaffed_reallocation_hurdle_mult_q16.get();
    out["employment_choice_temperature_q16"] =
        _employment_choice_temperature_q16.get();
    out["accuracy_exact_probe_rate_q16"] = _accuracy_exact_probe_rate_q16;
    out["accuracy_fallback_cooldown_epochs"] =
        _accuracy_fallback_cooldown_epochs;
    out["approximation_decisions"] = _approximation_decisions;
    out["approximation_exact_probes"] = _approximation_exact_probes;
    out["approximation_certificate_failures"] =
        _approximation_certificate_failures;
    out["approximation_exact_fallbacks"] = _approximation_exact_fallbacks;
    out["approximation_frontier_candidates"] =
        _approximation_frontier_candidates;
    out["approximation_frontier_pruned"] = _approximation_frontier_pruned;
    out["approximation_max_observed_regret_q16"] =
        _approximation_max_observed_regret_q16;
    out["approximation_probe_violations"] =
        _approximation_probe_violations;
    out["approximation_probe_max_spend_error_q16"] =
        _approximation_probe_max_spend_error_q16;
    out["approximation_probe_max_demand_error_q16"] =
        _approximation_probe_max_demand_error_q16;
    out["approximation_cooldown_epochs_left"] =
        _approximation_cooldown_epochs_left;
    out["starvation_satisfaction_threshold_q16"] =
        _starvation_satisfaction_threshold_q16;
    out["survival_production_target_q16"] = _survival_production_target_q16;
    out["starvation_death_rate_q32"] = _starvation_death_rate_q32;
    out["births"] = _births;
    out["deaths"] = _deaths;
    out["period_transactions"] = true;
    out["max_command_latency_days"] = locked_market_cycle_days();
    out["pending_commands"] = static_cast<int64_t>(_pending_commands.size());
    append_epoch_input_report(out);
    out["country_schema_version"] = CountryApi::SCHEMA_VERSION;
    out["merchant_count"] = static_cast<int64_t>(_merchant_slots.size());
    out["merchant_repairs"] = _merchant_repairs;
    out["price_cap_hits"] = _price_cap_hits;
    out["price_rate_clamp_hits"] = _price_rate_clamp_hits;
    out["price_ceiling_expansions"] = _price_ceiling_expansions;
    out["price_ceiling_recoveries"] = _price_ceiling_recoveries;
    out["price_ceiling_blocked_rises"] = _price_ceiling_blocked_rises;
    out["price_ceiling_active_states"] = price_ceiling_state_count();
    int64_t ceiling_capacity_bytes = 0;
    for (const auto &row : market_store().price_ceilings)
        ceiling_capacity_bytes += static_cast<int64_t>(row.capacity() * sizeof(PriceCeilingState));
    out["price_ceiling_state_bytes"] = ceiling_capacity_bytes;
    out["price_ceiling_confirm_days"] = _price_ceiling_confirm_days.get();
    out["price_ceiling_expand_bp"] = _price_ceiling_expand_bp.get();
    out["price_ceiling_recover_bp"] = _price_ceiling_recover_bp.get();
    out["price_numeric_floor_hits"] = _price_numeric_floor_hits;
    out["price_numeric_ceiling_hits"] = _price_numeric_ceiling_hits;
    out["price_ceiling_limit_hits"] = _price_catalog_bound_hits;
    out["price_min_tick_hits"] = _price_min_tick_hits;
    out["price_glut_cost_damp_hits"] = _price_glut_cost_damp_hits;
    out["small_payment_roundups"] = _small_payment_roundups;
    out["price_rise_fade_hits"] = _price_rise_fade_hits;
    out["price_headroom_damp_hits"] = _price_headroom_damp_hits;
    out["price_catalog_bound_hits"] = _price_catalog_bound_hits;
    out["price_rise_fade_model"] = "disabled_price_v6";
    out["price_runtime_bounds"] = "numeric_min_dynamic_ceiling";
    out["price_model"] = "price_v6_dynamic_ceiling";
    out["price_numeric_guard_min"] = PRICE_NUMERIC_GUARD_MIN;
    out["price_numeric_guard_max"] = PRICE_NUMERIC_GUARD_MAX;
    out["continuation_slices"] = _continuation_slices;
    out["market_runtime_mode"] = _market_runtime_mode == 0 ? "OFF" :
                                   (_market_runtime_mode == 1 ? "PROBE" : "ACTIVE");
    return out;
}

} // namespace pk
