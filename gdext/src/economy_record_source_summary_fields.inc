    if (_config.enabled[SUMMARY]) {
        SummaryRow row;
        row.epoch_row_id = epoch_row_id; row.epoch_id = runtime._epoch_id.get(); row.day_index = day;
        row.epoch_active = runtime._epoch_active; row.stage = static_cast<int32_t>(runtime._stage);
        row.progress_q16 = runtime.stage_progress_q16(); row.sample_day = runtime._sample_day;
        row.commit_day = runtime._commit_day; row.cohort_count = runtime.population_store().active_count;
        row.market_count = runtime.market_store().market_count.get(); row.good_count = runtime.market_store().good_count.get();
        row.building_type_count = runtime._building_types.size();
        row.building_group_count = runtime.building_count();
        row.pending_construction_count = runtime.pending_construction_count();
        row.filled_owner_jobs = runtime._filled_owner_jobs;
        row.filled_employee_jobs = runtime._filled_employee_jobs;
        row.unemployed_population = runtime._unemployed_population;
        row.births = runtime._births;
        row.deaths = runtime._deaths;
        row.production_inputs_consumed = runtime._production_inputs_consumed;
        row.production_output_stock = runtime._production_output_stock;
        row.production_output_discarded = runtime._production_output_discarded;
        row.production_output_retained = runtime._production_output_retained;
        row.production_output_supported = runtime._production_output_supported;
        row.owner_output_consumed = runtime._owner_output_consumed;
        row.producer_revenue = runtime._producer_revenue;
        row.producer_support_money_issued = runtime._producer_support_money_issued;
        row.bullion_money_issued = runtime._bullion_money_issued;
        row.bullion_stock_consumed = runtime._bullion_stock_consumed;
        row.gold_accepted = runtime._gold_accepted;
        row.silver_accepted = runtime._silver_accepted;
        row.gold_money_issued = runtime._gold_money_issued;
        row.silver_money_issued = runtime._silver_money_issued;
        row.bullion_quota_initial = runtime._epoch_bullion_quota_initial_total;
        row.bullion_quota_remaining = runtime._epoch_bullion_quota_remaining_total;
        row.bullion_quota_remainder_units =
            runtime._epoch_bullion_quota_remainder_units;
        row.cycle_flow_produced = runtime._cycle_flow_produced;
        row.cycle_flow_consumed = runtime._cycle_flow_consumed;
        row.cycle_flow_discarded = runtime._cycle_flow_discarded;
        row.building_wages_paid = runtime._building_wages_paid;
        row.building_wages_unpaid = runtime._building_wages_unpaid;
        row.building_resource_generated = runtime._building_resource_generated;
        row.building_resource_consumed = runtime._building_resource_consumed;
        row.building_resource_net_delta = runtime._building_resource_generated -
                                          runtime._building_resource_consumed;
        row.loss_suspended_building_groups = runtime._loss_suspended_building_groups;
        row.climate_profiled_building_groups =
            runtime._climate_profiled_building_groups;
        row.climate_limited_building_groups =
            runtime._climate_limited_building_groups;
        row.average_climate_capacity_q16 =
            runtime._climate_profiled_building_groups > 0
            ? runtime._climate_capacity_sum_q16 /
                runtime._climate_profiled_building_groups
            : NativeEconomyRuntime::Q16_ONE;
        row.merchant_procurement_budget = runtime._merchant_procurement_budget;
        row.merchant_procurement_opportunity = runtime._merchant_procurement_opportunity;
        row.merchant_procurement_allocated = runtime._merchant_procurement_allocated;
        row.merchant_procurement_unspent_allocated = runtime._merchant_procurement_unspent_allocated;
        row.merchant_procurement_reserved = runtime._merchant_procurement_reserved;
        row.merchant_procurement_spent = runtime._merchant_procurement_spent;
        row.owner_working_capital_reserved = runtime._owner_working_capital_reserved;
        row.production_input_reserved = runtime._production_input_reserved;
        row.production_input_reserve_shortfall =
            runtime._production_input_reserve_shortfall;
        row.construction_material_reserved = runtime._construction_material_reserved;
        row.maintenance_goods_consumed = runtime._maintenance_goods_consumed;
        row.maintenance_unmet = runtime._maintenance_unmet;
        row.construction_goods_consumed = runtime._construction_goods_consumed;
        row.building_investment_candidates = runtime._building_investment_candidates;
        row.building_owner_mobility = runtime._building_owner_mobility;
        row.building_owner_job_reallocations =
            runtime._building_owner_job_reallocations;
        row.building_owner_job_profession_changes =
            runtime._building_owner_job_profession_changes;
        row.building_owner_job_probability_skips =
            runtime._building_owner_job_probability_skips;
        row.building_employee_to_owner_reallocations =
            runtime._building_employee_to_owner_reallocations;
        row.building_investments_started = runtime._building_investments_started;
        row.building_investment_blocked_funds =
            runtime._building_investment_blocked_funds;
        row.building_investment_blocked_materials =
            runtime._building_investment_blocked_materials;
        row.building_investment_blocked_sponsor_capital =
            runtime._building_investment_blocked_sponsor_capital;
        row.building_investment_blocked_resources =
            runtime._building_investment_blocked_resources;
        row.building_investment_probability_skips =
            runtime._building_investment_probability_skips;
        row.building_investment_capital_transferred =
            runtime._building_investment_capital_transferred;
        row.building_investment_buildings_started =
            runtime._building_investment_buildings_started;
        row.building_investment_portfolios_started =
            runtime._building_investment_portfolios_started;
        row.building_investment_types_started =
            runtime._building_investment_types_started;
        row.building_investment_owner_population_moved =
            runtime._building_investment_owner_population_moved;
        row.building_investment_max_type_owner_share_q16 =
            runtime._building_investment_max_type_owner_share_q16;
        row.building_investment_demand_limited =
            runtime._building_investment_demand_limited;
        row.building_investment_material_limited =
            runtime._building_investment_material_limited;
        row.building_investment_capital_limited =
            runtime._building_investment_capital_limited;
        row.building_investment_owner_population_limited =
            runtime._building_investment_owner_population_limited;
        row.building_investment_jobs_started =
            runtime._building_investment_jobs_started;
        row.building_investment_employment_gap =
            runtime._building_investment_employment_gap;
        row.building_investment_employment_catchup_cells =
            runtime._building_investment_employment_catchup_cells;
        row.building_investment_displacement_starts =
            runtime._building_investment_displacement_starts;
        row.investment_displacement_type_evaluations =
            runtime._investment_displacement_type_evaluations;
        row.desired_business_demand = runtime._desired_business_demand;
        row.funded_business_demand = runtime._funded_business_demand;
        row.unfunded_business_demand = runtime._unfunded_business_demand;
        row.owner_working_capital_allocated =
            runtime._owner_working_capital_allocated;
        row.trade_signal_max_age_days = runtime._trade_signal_max_age_days;
        row.trade_first_dispatch_delay_max_days =
            runtime._trade_first_dispatch_delay_max_days;
        row.trade_response_deadline_misses =
            runtime._trade_response_deadline_misses;
        row.trade_response_deadline_misses_cumulative =
            runtime._trade_response_deadline_misses_cumulative;
        row.trade_unresolved_no_attempt = runtime._trade_unresolved_no_attempt;
        row.trade_unresolved_no_spread = runtime._trade_unresolved_no_spread;
        row.trade_unresolved_margin = runtime._trade_unresolved_margin;
        row.trade_unresolved_route = runtime._trade_unresolved_route;
        row.trade_unresolved_stock = runtime._trade_unresolved_stock;
        row.trade_unresolved_capacity = runtime._trade_unresolved_capacity;
        row.trade_unresolved_cash = runtime._trade_unresolved_cash;
        row.trade_unresolved_order_cap = runtime._trade_unresolved_order_cap;
        row.trade_runtime_mode = runtime._trade_runtime_mode.get();
        row.trade_topology_ready = runtime._trade_topology.ready;
        row.trade_topology_generation = runtime._trade_topology.topology_generation;
        row.trade_topology_hash = runtime._trade_topology.topology_hash;
        row.trade_country_generation = runtime._trade_topology.component_country_hash;
        row.trade_plan_phase = runtime._trade_plan.phase;
        row.trade_scan_cursor = runtime._trade_plan.scan_cursor;
        row.trade_scan_total = runtime._trade_plan.scan_total;
        row.trade_route_cursor = runtime._trade_plan.route_cursor;
        row.trade_route_total = runtime._trade_plan.sources.size();
        row.trade_completed_scans = runtime._trade_plan.completed_scans;
        row.trade_plan_reset_count = runtime._trade_plan_reset_count;
        row.trade_topology_content_change_count =
            runtime._trade_topology_content_change_count;
        row.trade_last_plan_reset_reason = runtime._trade_last_plan_reset_reason;
        row.trade_source_signals = runtime._trade_plan.sources.size();
        row.trade_destination_signals = runtime._trade_plan.destinations.size();
        row.trade_ready_candidates = runtime._trade_plan.ready_candidates.size();
        row.trade_route_expansions = runtime._trade_route_expansions;
        row.trade_route_cache_hits = runtime._trade_route_cache_hits;
        row.trade_route_cache_misses = runtime._trade_route_cache_misses;
        row.trade_candidates_generated = runtime._trade_candidates_generated;
        row.trade_candidates_accepted = runtime._trade_candidates_accepted;
        row.trade_rejected_profit = runtime._trade_rejected_profit;
        row.trade_rejected_no_spread = runtime._trade_rejected_no_spread;
        row.trade_rejected_margin = runtime._trade_rejected_margin;
        row.trade_quantity_profit_clips = runtime._trade_quantity_profit_clips;
        row.trade_relief_candidates = runtime._trade_relief_candidates;
        row.trade_rejected_capacity = runtime._trade_rejected_capacity;
        row.trade_rejected_stock = runtime._trade_rejected_stock;
        row.trade_rejected_cash = runtime._trade_rejected_cash;
        row.trade_rejected_route = runtime._trade_rejected_route;
        row.trade_rejected_order_cap = runtime._trade_rejected_order_cap;
        row.trade_orders_in_flight = runtime.trade_orders_store().size();
        row.trade_orders_dispatched = runtime._trade_orders_dispatched;
        row.trade_orders_arrived = runtime._trade_orders_arrived;
        row.trade_unclaimed_orders = runtime._trade_unclaimed_orders;
        row.trade_capacity_available = runtime._trade_capacity_available;
        row.trade_capacity_used = runtime._trade_capacity_used;
        row.merchant_credit_budget = runtime._merchant_credit_budget;
        row.merchant_credit_committed = runtime._merchant_credit_committed;
        row.merchant_credit_drawn = runtime._merchant_credit_drawn;
        row.merchant_credit_repaid = runtime._merchant_credit_repaid;
        row.merchant_credit_premium_repaid = runtime._merchant_credit_premium_repaid;
        row.merchant_credit_bad_debt = runtime._merchant_credit_bad_debt;
        row.recovery_candidates = runtime._recovery_candidates;
        row.recovery_approved = runtime._recovery_approved;
        row.recovery_restarted = runtime._recovery_restarted;
        row.recovery_failed = runtime._recovery_failed;
        row.recovery_liquidated_buildings = runtime._recovery_liquidated_buildings;
        row.recovery_partially_liquidated_buildings =
            runtime._recovery_partially_liquidated_buildings;
        row.recovery_fully_liquidated_groups =
            runtime._recovery_fully_liquidated_groups;
        row.merchant_survival_procurement_required =
            runtime._merchant_survival_procurement_required;
        row.merchant_survival_procurement_allocated =
            runtime._merchant_survival_procurement_allocated;
        row.merchant_input_procurement_required =
            runtime._merchant_input_procurement_required;
        row.merchant_input_procurement_allocated =
            runtime._merchant_input_procurement_allocated;
        row.trade_active_keys_pruned = runtime._trade_active_keys_pruned;
        row.trade_deficit_episodes_started = runtime._trade_deficit_episodes_started;
        row.trade_deficit_episodes_resolved = runtime._trade_deficit_episodes_resolved;
        row.trade_candidates_stale_generation = runtime._trade_candidates_stale_generation;
        row.trade_candidates_arbitrated_out = runtime._trade_candidates_arbitrated_out;
        row.trade_true_source_stock_failures = runtime._trade_true_source_stock_failures;
        int64_t liquidity_sat = 0;
        row.merchant_cash = runtime._closing_totals.merchant_cash;
        row.merchant_inventory_retail_value =
            runtime._closing_totals.merchant_inventory_retail_value;
        row.merchant_inventory_liquidation_value =
            runtime._closing_totals.merchant_inventory_liquidation_value;
        row.merchant_economic_assets = runtime.saturating_add(
            row.merchant_cash, row.merchant_inventory_liquidation_value,
            liquidity_sat);
        row.merchant_procurement_margin_value = std::max<int64_t>(
            0, runtime._merchant_procurement_retail_value -
                runtime._merchant_procurement_spent);
        row.merchant_trade_purchase_cash =
            runtime._merchant_trade_purchase_cash;
        row.merchant_trade_sale_cash = runtime._merchant_trade_sale_cash;
        row.merchant_operating_outflow = runtime.saturating_add(
            runtime.saturating_add(runtime._merchant_procurement_spent,
                runtime._merchant_trade_purchase_cash, liquidity_sat),
            runtime._merchant_credit_drawn, liquidity_sat);
        row.merchant_liquidity_coverage_q16 =
            row.merchant_operating_outflow > 0
                ? runtime.mul_div_sat(row.merchant_cash,
                    NativeEconomyRuntime::Q16_ONE,
                    row.merchant_operating_outflow, liquidity_sat)
                : NativeEconomyRuntime::Q16_ONE;
        row.merchant_effective_buy_factor_q16 =
            runtime._merchant_procurement_spent > 0
                ? static_cast<int32_t>(std::clamp<int64_t>(
                    runtime._merchant_procurement_factor_weighted_cash_q16 /
                        runtime._merchant_procurement_spent,
                    0, NativeEconomyRuntime::Q16_ONE))
                : NativeEconomyRuntime::Q16_ONE;
        for (size_t pk_row = 0; pk_row < runtime.building_count(); ++pk_row) {
            const auto group = runtime.building_at(pk_row);
            row.merchant_credit_outstanding += group.merchant_debt_principal +
                group.merchant_debt_premium;
        }
        for (const auto pending : runtime.pending_construction()) {
            row.merchant_credit_outstanding += pending.merchant_debt_principal +
                pending.merchant_debt_premium;
        }
        batch.summary.push_back(row);
    }
