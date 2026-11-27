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
    out["memory_bytes"] = memory_bytes();
    out["demand_basis_cache"] = demand_basis_cache_report();
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
    out["canal_next_project_id"] = static_cast<int64_t>(_next_canal_project_id.get());
    out["cohort_count"] = population_store().active_count.get();
    out["market_count"] = market_store().market_count.get();
    out["good_count"] = market_store().good_count.get();
    out["building_type_count"] = static_cast<int64_t>(_building_types.size());
    out["building_group_count"] = static_cast<int64_t>(building_count());
    out["pending_construction_count"] = static_cast<int64_t>(pending_construction_count());
    out["processed_building_groups"] = _processed_building_groups;
    out["climate_profiled_building_groups"] =
        _climate_profiled_building_groups;
    out["climate_limited_building_groups"] =
        _climate_limited_building_groups;
    out["average_climate_capacity_q16"] =
        _climate_profiled_building_groups > 0
        ? _climate_capacity_sum_q16 / _climate_profiled_building_groups
        : Q16_ONE;
    out["filled_owner_jobs"] = _filled_owner_jobs;
    out["filled_employee_jobs"] = _filled_employee_jobs;
    out["unemployed_population"] = _unemployed_population;
    out["construction_goods_consumed"] = _construction_goods_consumed;
    out["explicit_stock_delta"] = _explicit_stock_delta;
    out["building_investment_model"] = "endogenous_owner_portfolio_v9";
    out["startup_demand_runtime_mode"] =
        _startup_demand_runtime_mode.get() == 0 ? "OFF" : "ACTIVE";
    out["startup_demand_seed_count"] = _startup_demand_seed_count;
    out["startup_demand_touched_lanes"] = _startup_demand_touched_lanes;
    out["startup_demand_catalog_edges"] = _startup_demand_catalog_edges;
    out["startup_demand_cycle_skips"] = _startup_demand_cycle_skips;
    out["startup_demand_remote_lanes"] = _startup_demand_remote_lanes;
    out["startup_demand_matched_review_cells"] =
        _startup_demand_matched_review_cells;
    out["startup_demand_buildings_started"] =
        _startup_demand_buildings_started;
    out["startup_demand_prepare_ms"] = _startup_demand_prepare_ms;
    out["startup_demand_scratch_bytes"] = _startup_demand_scratch_bytes;
    out["investment_gap_fill_share_q16"] =
        _investment_gap_fill_share_q16.get();
    out["investment_portfolio_max_types"] =
        _investment_portfolio_max_types.get();
    out["investment_max_type_owner_share_q16"] =
        _investment_max_type_owner_share_q16.get();
    out["investment_max_growth_share_q16"] =
        _investment_max_growth_share_q16.get();
    out["investment_new_type_seed_buildings"] =
        _investment_new_type_seed_buildings.get();
    out["investment_displacement_min_advantage_q16"] =
        _investment_displacement_min_advantage_q16;
    out["investment_merchant_transition_min_improvement_q16"] =
        _investment_merchant_transition_min_improvement_q16.get();
    out["recovery_liquidation_max_share_q16"] =
        _recovery_liquidation_max_share_q16.get();
    out["building_investment_candidates"] = _building_investment_candidates;
    out["building_owner_mobility"] = _building_owner_mobility;
    out["building_owner_job_reallocations"] =
        _building_owner_job_reallocations;
    out["building_owner_understaffed_reallocations"] =
        _building_owner_understaffed_reallocations;
    out["building_employee_job_reallocations"] =
        _building_employee_job_reallocations;
    out["building_employee_job_profession_changes"] =
        _building_employee_job_profession_changes;
    out["building_distress_career_exits"] =
        _building_distress_career_exits;
    out["building_employee_job_hurdle_rejections"] =
        _building_employee_job_hurdle_rejections;
    out["building_employee_cold_start_forecasts"] =
        _building_employee_cold_start_forecasts;
    out["building_employee_funding_limited_forecasts"] =
        _building_employee_funding_limited_forecasts;
    out["building_survival_priority_candidates"] =
        _building_survival_priority_candidates;
    out["building_owner_opportunity_quotes"] =
        _building_owner_opportunity_quotes;
    out["building_owner_opportunity_zero_feasible"] =
        _building_owner_opportunity_zero_feasible;
    out["building_owner_survival_reallocations"] =
        _building_owner_survival_reallocations;
    out["bullion_quota_pressure_clamps"] = _bullion_quota_pressure_clamps;
    out["bullion_quote_overallocation_prevented"] =
        _bullion_quote_overallocation_prevented;
    out["building_owner_job_profession_changes"] =
        _building_owner_job_profession_changes;
    out["building_owner_job_probability_skips"] =
        _building_owner_job_probability_skips;
    out["building_employee_to_owner_reallocations"] =
        _building_employee_to_owner_reallocations;
    out["building_investments_started"] = _building_investments_started;
    out["building_investment_displacement_starts"] =
        _building_investment_displacement_starts;
    out["building_investment_blocked_funds"] =
        _building_investment_blocked_funds;
    out["building_investment_blocked_materials"] =
        _building_investment_blocked_materials;
    out["building_investment_blocked_sponsor_capital"] =
        _building_investment_blocked_sponsor_capital;
    out["building_investment_blocked_resources"] =
        _building_investment_blocked_resources;
    out["building_investment_probability_skips"] =
        _building_investment_probability_skips;
    out["building_investment_capital_transferred"] =
        _building_investment_capital_transferred;
    out["building_investment_buildings_started"] =
        _building_investment_buildings_started;
    out["building_investment_portfolios_started"] =
        _building_investment_portfolios_started;
    out["building_investment_types_started"] =
        _building_investment_types_started;
    out["building_investment_owner_population_moved"] =
        _building_investment_owner_population_moved;
    out["building_investment_max_type_owner_share_q16"] =
        _building_investment_max_type_owner_share_q16;
    out["building_investment_demand_limited"] =
        _building_investment_demand_limited;
    out["building_investment_material_limited"] =
        _building_investment_material_limited;
    out["building_investment_capital_limited"] =
        _building_investment_capital_limited;
    out["building_investment_cost_envelope_trimmed"] =
        _building_investment_cost_envelope_trimmed;
    out["building_investment_owner_population_limited"] =
        _building_investment_owner_population_limited;
    out["building_investment_jobs_started"] =
        _building_investment_jobs_started;
    out["building_investment_employment_gap"] =
        _building_investment_employment_gap;
    out["building_investment_employment_catchup_cells"] =
        _building_investment_employment_catchup_cells;
    out["desired_business_demand"] = _desired_business_demand;
    out["derived_business_demand_total"] = _derived_business_demand_total;
    out["derived_business_demand_lanes"] = _derived_business_demand_lanes;
    out["derived_business_demand_edges"] = _derived_business_demand_edges;
    out["derived_business_demand_weight_q16"] = _derived_business_demand_weight_q16;
    out["funded_business_demand"] = _funded_business_demand;
    out["unfunded_business_demand"] = _unfunded_business_demand;
    out["active_unfunded_building_groups"] = _active_unfunded_building_groups;
    out["last_merchant_protected_rejects"] = _last_merchant_protected_rejects;
    out["owner_working_capital_allocated"] = _owner_working_capital_allocated;
    out["production_inputs_consumed"] = _production_inputs_consumed;
    out["production_output_stock"] = _production_output_stock;
    out["production_output_discarded"] = _production_output_discarded;
    out["production_output_retained"] = _production_output_retained;
    out["production_output_supported"] = _production_output_supported;
    out["owner_output_consumed"] = _owner_output_consumed;
    out["producer_revenue"] = _producer_revenue;
	out["producer_support_money_issued"] = _producer_support_money_issued;
	out["producer_support_price_numerator"] = PRODUCER_SUPPORT_PRICE_NUMERATOR;
	out["producer_support_price_denominator"] = PRODUCER_SUPPORT_PRICE_DENOMINATOR;
	out["bullion_money_issued"] = _bullion_money_issued;
	out["bullion_stock_consumed"] = _bullion_stock_consumed;
	out["gold_accepted"] = _gold_accepted;
	out["silver_accepted"] = _silver_accepted;
	out["gold_money_issued"] = _gold_money_issued;
	out["silver_money_issued"] = _silver_money_issued;
	out["bullion_quota_initial"] = _epoch_bullion_quota_initial_total;
	out["bullion_quota_remaining"] = _epoch_bullion_quota_remaining_total;
	out["bullion_quota_remainder_units"] = _epoch_bullion_quota_remainder_units;
	out["cycle_flow_produced"] = _cycle_flow_produced;
	out["cycle_flow_consumed"] = _cycle_flow_consumed;
    out["cycle_flow_discarded"] = _cycle_flow_discarded;
    out["consumed_goods"] = _consumed_goods;
    out["building_wages_paid"] = _building_wages_paid;
    out["building_wages_unpaid"] = _building_wages_unpaid;
    out["building_base_wages_due"] = _building_base_wages_due;
    out["building_base_wages_paid"] = _building_base_wages_paid;
    out["building_bonus_due"] = _building_bonus_due;
    out["building_bonus_paid"] = _building_bonus_paid;
    out["wage_suspended_building_groups"] = _wage_suspended_building_groups;
    out["loss_suspended_building_groups"] = _loss_suspended_building_groups;
    out["merchant_procurement_budget"] = _merchant_procurement_budget;
    out["merchant_procurement_opportunity"] = _merchant_procurement_opportunity;
    out["merchant_procurement_allocated"] = _merchant_procurement_allocated;
    out["merchant_procurement_unspent_allocated"] = _merchant_procurement_unspent_allocated;
    out["merchant_survival_procurement_required"] =
        _merchant_survival_procurement_required;
    out["merchant_survival_procurement_allocated"] =
        _merchant_survival_procurement_allocated;
    out["merchant_input_procurement_required"] =
        _merchant_input_procurement_required;
    out["merchant_input_procurement_allocated"] =
        _merchant_input_procurement_allocated;
    out["merchant_procurement_reserved"] = _merchant_procurement_reserved;
    out["merchant_procurement_spent"] = _merchant_procurement_spent;
    int64_t report_sat = 0;
    const int64_t merchant_operating_outflow = saturating_add(
        saturating_add(_merchant_procurement_spent,
            _merchant_trade_purchase_cash, report_sat),
        _merchant_credit_drawn, report_sat);
    const int64_t merchant_economic_assets = saturating_add(
        _closing_totals.merchant_cash,
        _closing_totals.merchant_inventory_liquidation_value, report_sat);
    out["merchant_cash"] = _closing_totals.merchant_cash;
    out["merchant_inventory_retail_value"] =
        _closing_totals.merchant_inventory_retail_value;
    out["merchant_inventory_liquidation_value"] =
        _closing_totals.merchant_inventory_liquidation_value;
    out["merchant_economic_assets"] = merchant_economic_assets;
    out["merchant_procurement_margin_value"] = std::max<int64_t>(
        0, _merchant_procurement_retail_value -
            _merchant_procurement_spent);
    out["merchant_trade_purchase_cash"] = _merchant_trade_purchase_cash;
    out["merchant_trade_sale_cash"] = _merchant_trade_sale_cash;
    out["government_research_procured_points"] =
        _government_research_procured_points.get();
    out["government_research_procurement_cash"] =
        _government_research_procurement_cash.get();
    out["government_research_procurement_orders"] =
        _government_research_procurement_orders.get();
    out["country_research_procurement_cursor"] =
        static_cast<int64_t>(_country_research_procurement_cursor);
    out["country_research_procurement_candidate_count"] =
        static_cast<int64_t>(_country_research_procurement_candidates.size());
    out["country_research_procurement_phase"] =
        _country_research_procurement_phase;
    out["country_research_procurement_done"] =
        _country_research_procurement_done;
    out["country_research_procurement_slices"] =
        _country_research_procurement_slices;
    out["country_research_procurement_transactions"] =
        _country_research_procurement_transactions;
    out["country_research_procurement_rejections"] =
        _country_research_procurement_rejections;
    out["country_research_procurement_continuation_active"] =
        _country_research_procurement_continuation.active;
    out["country_research_procurement_continuation_phase"] =
        _country_research_procurement_continuation.phase;
    out["country_research_procurement_continuation_candidate"] =
        _country_research_procurement_continuation.candidate_index;
    out["country_research_procurement_continuation_country"] =
        _country_research_procurement_continuation.country;
    out["country_research_procurement_continuation_market"] =
        _country_research_procurement_continuation.market;
    out["country_research_procurement_continuation_good"] =
        _country_research_procurement_continuation.good;
    out["country_research_procurement_continuation_quantity"] =
        _country_research_procurement_continuation.quantity;
    out["country_research_procurement_continuation_cash"] =
        _country_research_procurement_continuation.cash;
    out["country_research_procurement_continuation_transaction_id"] =
        static_cast<int64_t>(_country_research_procurement_continuation.transaction_id);
    out["country_research_procurement_continuation_merchants"] =
        static_cast<int64_t>(_country_research_procurement_continuation.living_merchants.size());
    out["country_research_procurement_continuation_merchant_cursor"] =
        static_cast<int64_t>(_country_research_procurement_continuation.merchant_cursor);
    out["country_research_procurement_continuation_market_applied"] =
        _country_research_procurement_continuation.market_applied;
    out["country_research_procurement_continuation_session_epoch"] =
        static_cast<int64_t>(_country_research_procurement_continuation.session_epoch);
    out["country_research_procurement_continuation_country_generation"] =
        static_cast<int64_t>(_country_research_procurement_continuation.country_generation);
    out["country_research_procurement_continuation_peer_generation"] =
        static_cast<int64_t>(_country_research_procurement_continuation.peer_generation);
    out["country_research_procurement_last_error"] =
        String::utf8(_country_research_procurement_continuation.last_error.c_str());
    out["fiscal_settlement_continuation_active"] =
        _fiscal_settlement_continuation.active;
    out["fiscal_settlement_continuation_phase"] =
        _fiscal_settlement_continuation.phase;
    out["fiscal_settlement_return_completed"] =
        _fiscal_settlement_continuation.return_completed;
    out["fiscal_settlement_country_cursor"] =
        _fiscal_settlement_continuation.country_cursor;
    out["fiscal_settlement_country_count"] =
        _fiscal_settlement_continuation.country_count;
    out["fiscal_settlement_last_unused"] =
        _fiscal_settlement_continuation.last_unused;
    out["fiscal_settlement_last_collected"] =
        _fiscal_settlement_continuation.last_collected;
    out["fiscal_settlement_last_error"] = String::utf8(
        _fiscal_settlement_continuation.last_error.c_str());
    out["merchant_operating_outflow"] = merchant_operating_outflow;
    out["merchant_liquidity_coverage_q16"] =
        merchant_operating_outflow > 0
            ? mul_div_sat(_closing_totals.merchant_cash, Q16_ONE,
                merchant_operating_outflow, report_sat)
            : Q16_ONE;
    out["merchant_effective_buy_factor_q16"] =
        _merchant_procurement_spent > 0
            ? std::clamp<int64_t>(
                _merchant_procurement_factor_weighted_cash_q16 /
                    _merchant_procurement_spent,
                0, Q16_ONE)
            : Q16_ONE;
    int64_t merchant_credit_outstanding = 0;
    for (size_t pk_row = 0; pk_row < building_count(); ++pk_row) {
        const auto group = building_at(pk_row);
        merchant_credit_outstanding = saturating_add(
            merchant_credit_outstanding, saturating_add(
                group.merchant_debt_principal, group.merchant_debt_premium,
                report_sat), report_sat);
    }
    for (const auto pending : pending_construction()) {
        merchant_credit_outstanding = saturating_add(
            merchant_credit_outstanding, saturating_add(
                pending.merchant_debt_principal, pending.merchant_debt_premium,
                report_sat), report_sat);
    }
    out["merchant_credit_runtime_mode"] = _merchant_credit_runtime_mode.get() == 0
        ? "OFF" : (_merchant_credit_runtime_mode.get() == 1 ? "PROBE" : "ACTIVE");
    out["merchant_credit_budget"] = _merchant_credit_budget;
    out["merchant_credit_committed"] = _merchant_credit_committed;
    out["merchant_credit_drawn"] = _merchant_credit_drawn;
    out["merchant_credit_repaid"] = _merchant_credit_repaid;
    out["merchant_credit_premium_repaid"] = _merchant_credit_premium_repaid;
    out["merchant_credit_outstanding"] = merchant_credit_outstanding;
    out["merchant_credit_bad_debt"] = _merchant_credit_bad_debt;
    out["recovery_candidates"] = _recovery_candidates;
    out["recovery_approved"] = _recovery_approved;
    out["recovery_restarted"] = _recovery_restarted;
    out["recovery_failed"] = _recovery_failed;
    out["recovery_liquidated_buildings"] = _recovery_liquidated_buildings;
    out["recovery_partially_liquidated_buildings"] =
        _recovery_partially_liquidated_buildings;
    out["recovery_fully_liquidated_groups"] =
        _recovery_fully_liquidated_groups;
    out["production_input_reserved"] = _production_input_reserved;
    out["production_input_reserve_shortfall"] =
        _production_input_reserve_shortfall;
    out["construction_material_reserved"] = _construction_material_reserved;
    out["maintenance_goods_consumed"] = _maintenance_goods_consumed;
    out["maintenance_unmet"] = _maintenance_unmet;
    out["maintenance_unpaid_value"] = _maintenance_unpaid_value;
    out["owner_working_capital_reserved"] = _owner_working_capital_reserved;
    out["building_severe_loss_threshold_q16"] = _building_severe_loss_threshold_q16.get();
    out["building_severe_loss_cycles"] = _building_severe_loss_cycles.get();
    out["building_restart_margin_q16"] = _building_restart_margin_q16.get();
    out["building_restart_cycles"] = _building_restart_cycles.get();
    out["merchant_procurement_cash_reserve_q16"] =
        _merchant_procurement_cash_reserve_q16.get();
    out["merchant_market_making_days_q16"] = _merchant_market_making_days_q16.get();
    out["labor_signal_edges"] =
        static_cast<int64_t>(_labor_signals.profession_ids.size());
    out["labor_signal_updates"] = _labor_signal_updates;
    out["building_resource_generated"] = _building_resource_generated;
    out["building_resource_consumed"] = _building_resource_consumed;
    out["building_resource_net_delta"] =
        _building_resource_generated - _building_resource_consumed;
    out["building_resource_limited_groups"] = _building_resource_limited_groups;
    out["market_signal_edges"] = static_cast<int64_t>(_market_signals.good_ids.size());
    out["market_signal_updates"] = _market_signal_updates;
