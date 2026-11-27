// Tracked settlement metadata and settings for cadence, households, buildings, and labor.

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
    int32_t _satisfaction_birth_reference_q16 = 36045;
    int32_t _satisfaction_birth_bonus_reference_q16 = 45875;
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
