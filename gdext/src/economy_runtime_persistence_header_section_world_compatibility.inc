    if (saved_cells != _cell_count.get()) header_mismatch = "cell_count";
    else if (markets <= 0 || markets > _cell_count.get()) header_mismatch = "market_count";
    else if (goods != static_cast<int32_t>(_good_ids.size())) header_mismatch = "good_count";
    else if (pages < 0 || active_count < 0 ||
             active_count > static_cast<int64_t>(pages) * COHORT_PAGE_SIZE)
        header_mismatch = "cohort_pages";
    else if (pending_count < 0 || pending_count > 1000000) header_mismatch = "pending_count";
    else if (audit_count < 0 || audit_count > 3650) header_mismatch = "audit_count";
    else if (signal_count < 0 || signal_count > 10000000 ||
             labor_signal_count < 0 || labor_signal_count > 10000000)
        header_mismatch = "signal_count";
    else if (next_event_id <= 0) header_mismatch = "next_event_id";
    else if (trade_order_count < 0 || trade_order_count > _trade_max_orders.get())
        header_mismatch = "trade_order_capacity";
    else if (trade_flow_count < 0 || trade_flow_count > _trade_max_signals.get())
        header_mismatch = "trade_flow_capacity";
    else if (tariff_history_count < 0 || tariff_history_count > 1000000)
        header_mismatch = "tariff_history_count";
    else if (country_good_count < 0 || country_good_count > 10000000 ||
             country_partner_count < 0 || country_partner_count > 10000000)
        header_mismatch = "country_trade_count";
    else if (next_trade_order_id <= 0) header_mismatch = "next_trade_order_id";
    else if (person_count < 0 || person_count > _person_max_total.get())
        header_mismatch = "person_capacity";
    else if (person_need_count < 0 ||
             person_need_count > _person_max_total.get() * MAX_NEEDS_PER_PLAN)
        header_mismatch = "person_need_capacity";
    else if (!market_hash_ok) header_mismatch = "catalog_hash";
    else if (money_scale != MONEY_SCALE || goods_scale != GOODS_SCALE ||
             ratio_scale != Q16_ONE || rate_scale != Q32_ONE)
        header_mismatch = "fixed_point_scale";
    else if (professions != _profession_ids.values()) header_mismatch = "profession_ids";
    else if (ethnicities != _ethnicity_ids.values()) header_mismatch = "ethnicity_ids";
    else if (good_ids != _good_ids.values()) header_mismatch = "good_ids";
    else if (plan_ids != _plan_ids.values()) header_mismatch = "plan_ids";
    if (header_mismatch != nullptr) {
        error = std::string("save_catalog_scale_or_capacity_mismatch:") +
            header_mismatch;
        return false;
    }
    if (schema >= 11 && (saved_trade_mode != _trade_runtime_mode.get() ||
        saved_trade_capacity != _trade_capacity_per_merchant_q16.get() ||
        saved_trade_speed != _trade_speed_cost_per_day.get() ||
        saved_trade_margin != _trade_min_margin_q16.get() ||
        saved_trade_targets != _trade_target_count.get() ||
        saved_trade_signal_budget != _trade_signal_pairs_per_slice.get() ||
        saved_trade_route_budget != _trade_route_searches_per_slice.get() ||
        saved_trade_expansions != _trade_max_route_expansions.get() ||
        saved_trade_cache != _trade_route_cache_entries.get() ||
        saved_trade_signals != _trade_max_signals.get() ||
        saved_trade_candidates != _trade_max_candidates.get() ||
        saved_trade_orders != _trade_max_orders.get() ||
        saved_trade_alpha != _trade_flow_ema_alpha_q16.get() ||
        saved_trade_stock_share != _trade_max_stock_share_q16.get())) {
        error = "save_trade_profile_mismatch";
        return false;
    }
    const bool policy_matches =
        saved_loss_threshold == _building_severe_loss_threshold_q16.get() &&
        saved_loss_cycles == _building_severe_loss_cycles.get() &&
        saved_restart_margin == _building_restart_margin_q16.get() &&
        saved_restart_cycles == _building_restart_cycles.get() &&
        saved_merchant_reserve == _merchant_procurement_cash_reserve_q16.get() &&
        saved_market_making_days == _merchant_market_making_days_q16.get() &&
        saved_credit_mode == _merchant_credit_runtime_mode.get() &&
        saved_credit_exposure == _merchant_credit_exposure_q16.get() &&
        saved_credit_premium == _merchant_credit_premium_q16.get() &&
        saved_credit_terms == _merchant_credit_term_cycles.get() &&
        saved_recovery_cycles == _recovery_success_cycles.get() &&
        saved_liquidation_reviews == _recovery_liquidation_failed_reviews.get();
    // v33/v34 saves contain the retired probe/restart policy fields. They
    // remain decodable, but the current profile is authoritative after
    // migration, including the one-year suspended liquidation window.
    if ((schema >= 35 && !policy_matches) ||
        (schema == 11 && _trade_runtime_mode.get() == 2 && !policy_matches)) {
        error = "save_business_policy_profile_mismatch";
        return false;
    }
    const bool dynamic_policy_matches =
        saved_trade_export_days == _trade_export_floor_days.get() &&
        saved_trade_export_fraction == _trade_export_inventory_fraction_q16.get() &&
        saved_trade_import_fraction == _trade_import_fill_fraction_q16.get() &&
        saved_trade_response_days == _trade_response_days.get() &&
        (schema >= 38 ||
         saved_investment_review_days == _investment_review_days.get()) &&
        saved_investment_shortage == _investment_min_shortage_q16.get() &&
        saved_investment_utilization == _investment_min_utilization_q16.get() &&
        saved_investment_payback_days == _investment_max_payback_days.get() &&
        saved_investment_cycles == _investment_operating_cycles.get() &&
        saved_investment_gap_fill_share ==
            _investment_gap_fill_share_q16.get() &&
        saved_investment_portfolio_max_types ==
            _investment_portfolio_max_types.get() &&
        saved_investment_max_type_owner_share ==
            _investment_max_type_owner_share_q16.get() &&
        saved_investment_max_growth_share ==
            _investment_max_growth_share_q16.get() &&
        saved_investment_new_type_seed_buildings ==
            _investment_new_type_seed_buildings.get() &&
        saved_investment_merchant_transition_min_improvement ==
            _investment_merchant_transition_min_improvement_q16.get() &&
        saved_recovery_liquidation_max_share ==
            _recovery_liquidation_max_share_q16.get() &&
        saved_resource_reserve == _resource_min_reserve_q16.get() &&
        saved_resource_harvest == _resource_safe_harvest_q16.get() &&
        saved_resource_horizon == _resource_min_horizon_days.get() &&
        saved_bullion_cap == _bullion_monthly_issue_cap_q16.get() &&
        saved_support_cap == _producer_support_monthly_cap_q16.get();
