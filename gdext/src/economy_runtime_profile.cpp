#include "economy_runtime.h"
#include "economy_runtime_variant_helpers.h"

#include <algorithm>
#include <limits>

namespace pk {

using namespace godot;
using namespace variant_helpers;

void NativeEconomyRuntime::register_builtin_formulas() {
    _formulas.clear();
    _formula_by_id.clear();
    auto add = [&](const char *id, int32_t version, int32_t min_params,
                   int32_t max_params, FormulaBatchFn fn) {
        const int32_t index = static_cast<int32_t>(_formulas.size());
        _formulas.push_back({id, version, min_params, max_params, fn});
        _formula_by_id[id] = index;
    };
    add("fixed_per_capita", 1, 1, 1, &NativeEconomyRuntime::formula_fixed_per_capita);
    add("income_price_linear", 1, 1, 7, &NativeEconomyRuntime::formula_income_price_linear);
}


bool NativeEconomyRuntime::configure_profile(const Dictionary &profile, std::string &error) {
    _price_ceiling_confirm_days = dict_num<int32_t>(profile, "price_ceiling_confirm_days", 30);
    _price_ceiling_expand_bp = dict_num<int32_t>(profile, "price_ceiling_expand_bp", 50);
    _price_ceiling_recover_bp = dict_num<int32_t>(profile, "price_ceiling_recover_bp", 10);
    if (_price_ceiling_confirm_days < 1 || _price_ceiling_confirm_days > 365 ||
        _price_ceiling_expand_bp < 1 || _price_ceiling_expand_bp > 100 ||
        _price_ceiling_recover_bp < 1 || _price_ceiling_recover_bp > 100) {
        error = "price_ceiling_profile_invalid";
        return false;
    }
    _cells_per_slice = std::clamp(dict_num<int32_t>(profile, "cells_per_slice", 256), 1, 65536);
    _auto_slice_by_scale = dict_num<bool>(profile, "auto_slice_by_scale", true);
    const int32_t configured_building_cells = dict_num<int32_t>(
        profile, "building_cells_per_slice", 0);
    _auto_building_slice_by_scale = configured_building_cells <= 0;
    _building_cells_per_slice = _auto_building_slice_by_scale
        ? AUTO_BUILDING_CELLS_PER_SLICE
        : std::clamp(configured_building_cells, 1, 65536);
    _building_groups_per_slice = std::clamp(dict_num<int32_t>(
        profile, "building_groups_per_slice", 512), 1, 65536);
    _building_plan_cells_per_slice_override = std::clamp(
        dict_num<int32_t>(profile, "building_plan_cells_per_slice", 0),
        0, 65536);
    _household_post_building_cells_per_slice_override = std::clamp(
        dict_num<int32_t>(
            profile, "household_post_building_cells_per_slice", 0),
        0, 65536);
    const int32_t configured_investment_cells = dict_num<int32_t>(
        profile, "investment_cells_per_slice", 0);
    _investment_cells_per_slice = configured_investment_cells > 0
        ? std::clamp(configured_investment_cells, 1, 65536)
        : AUTO_INVESTMENT_CELLS_PER_SLICE;
    const int32_t configured_finalize_cells = dict_num<int32_t>(
        profile, "building_finalize_cells_per_slice", 0);
    _building_finalize_cells_per_slice = configured_finalize_cells > 0
        ? std::clamp(configured_finalize_cells, 1, 65536)
        : AUTO_BUILDING_FINALIZE_CELLS_PER_SLICE;
    _building_output_efficiency_q16 = std::clamp(dict_num<int32_t>(
        profile, "building_output_efficiency_q16", Q16_ONE),
        static_cast<int32_t>(Q16_ONE), static_cast<int32_t>(Q16_ONE * 4));
    _food_building_output_efficiency_q16 = std::clamp(dict_num<int32_t>(
        profile, "food_building_output_efficiency_q16", 81920),
        static_cast<int32_t>(Q16_ONE), static_cast<int32_t>(Q16_ONE * 4));
    _commands_per_slice = std::clamp(dict_num<int32_t>(profile, "commands_per_slice", 16384), 1, 1 << 20);
    // market_cycle_days is the longest market interval (1-5). Native locks N
    // for a full cycle from populated work plus previous-cycle machine timing.
    // market_cycle_days=0 is not the retired 50/334 auto-fast-forward path.
    int32_t configured_cycle = dict_num<int32_t>(
        profile, "market_cycle_days", MARKET_CYCLE_MAX_DAYS);
    if (configured_cycle <= 0) configured_cycle = MARKET_CYCLE_MAX_DAYS;
    int32_t configured_min = dict_num<int32_t>(
        profile, "market_min_cycle_days", MARKET_CYCLE_MIN_DAYS);
    int32_t configured_max = dict_num<int32_t>(
        profile, "market_max_cycle_days", configured_cycle);
    if (configured_min <= 0) configured_min = MARKET_CYCLE_MIN_DAYS;
    if (configured_max <= 0) configured_max = MARKET_CYCLE_MAX_DAYS;
    _min_epoch_days = std::clamp(configured_min, MARKET_CYCLE_MIN_DAYS,
                                 MARKET_CYCLE_MAX_DAYS);
    _max_epoch_days = std::clamp(std::max(configured_max, configured_cycle),
                                 _min_epoch_days, MARKET_CYCLE_MAX_DAYS);
    _configured_epoch_days = _max_epoch_days;
    _cadence_target_ms = std::clamp(dict_num<double>(
        profile, "economy_cadence_target_ms", 8.0), 0.5, 32.0);
    _forced_market_cycle_days = std::clamp(dict_num<int32_t>(
        profile, "economy_cadence_force_market_days", 0),
        0, MARKET_CYCLE_MAX_DAYS);
    _forced_slow_cycle_days = dict_num<int32_t>(
        profile, "economy_cadence_force_plan_days", 0);
    if (_forced_slow_cycle_days <= 0) {
        _forced_slow_cycle_days = dict_num<int32_t>(
            profile, "economy_cadence_force_slow_days", 0);
    }
    if (_forced_slow_cycle_days > 0) {
        _forced_slow_cycle_days = std::clamp(_forced_slow_cycle_days,
            PLAN_CYCLE_MIN_DAYS, PLAN_CYCLE_MAX_DAYS);
    }
    _forced_investment_cycle_days = dict_num<int32_t>(
        profile, "economy_cadence_force_investment_days", 0);
    if (_forced_investment_cycle_days > 0) {
        _forced_investment_cycle_days = std::clamp(
            _forced_investment_cycle_days, INVEST_CYCLE_MIN_DAYS,
            INVEST_CYCLE_MAX_DAYS);
    }
    _configured_target_cohorts_per_slice = std::clamp<int64_t>(
        dict_num<int64_t>(profile, "market_target_cohorts_per_slice", 0),
        0, 1000000);
    _target_cohorts_per_slice = _configured_target_cohorts_per_slice > 0
        ? _configured_target_cohorts_per_slice : 30000;
    _max_rules_per_plan = std::clamp(dict_num<int32_t>(profile, "max_rules_per_plan", MAX_RULES_PER_PLAN), 1, MAX_RULES_PER_PLAN);
    _worker_enabled = dict_num<bool>(profile, "worker_enabled", true);
    _worker_market_threshold = std::clamp(
        dict_num<int32_t>(profile, "worker_market_threshold", 64), 1, 100000);
    _worker_tasks_hint = std::clamp(dict_num<int32_t>(profile, "worker_tasks_hint", 0), 0, 16);
    _worker_task_cap = std::clamp(
        dict_num<int32_t>(profile, "economy_worker_task_cap", 6),
        1, 16);
    _high_speed_batching_enabled = dict_num<bool>(
        profile, "economy_high_speed_batching_enabled", true);
    _full_audit_verify_interval_days = std::clamp(
        dict_num<int32_t>(profile,
            "economy_full_audit_verify_interval_days", 25),
        1, 365);
    const std::string closing_audit_mode = dict_string(
        profile, "economy_closing_audit_mode", "INCREMENTAL");
    _closing_audit_mode = closing_audit_mode == "FULL" ? 0
        : (closing_audit_mode == "INCREMENTAL" ? 2 : 1);
    _closing_audit_runtime_disabled = false;
    _closing_audit_force_full = true;
    const std::string accuracy_preset = dict_string(
        profile, "economy_accuracy_preset", "BALANCED");
    _accuracy_preset = accuracy_preset == "EXACT" ? 0
        : (accuracy_preset == "FAST" ? 2
        : (accuracy_preset == "CUSTOM" ? 3 : 1));
    const std::string approximation_mode = dict_string(
        profile, "economy_approximation_runtime_mode", "ACTIVE");
    _approximation_runtime_mode = approximation_mode == "OFF" ? 0
        : (approximation_mode == "ACTIVE" ? 2 : 1);
    if (_accuracy_preset == 0) {
        _accuracy_max_regret_q16 = 0;
        _accuracy_household_tail_share_q16 = 0;
        _accuracy_candidate_top_k = 1;
        _accuracy_choice_temperature_q16 = 0;
        _accuracy_exact_probe_rate_q16 = Q16_ONE;
        _accuracy_fallback_cooldown_epochs = 0;
    } else if (_accuracy_preset == 1) {
        _accuracy_max_regret_q16 = 1966; // 3%
        _accuracy_household_tail_share_q16 = 655; // 1%
        _accuracy_candidate_top_k = 2;
        _accuracy_choice_temperature_q16 = 983; // 1.5%
        _accuracy_exact_probe_rate_q16 = 655; // 1%
        _accuracy_fallback_cooldown_epochs = 10;
    } else if (_accuracy_preset == 2) {
        _accuracy_max_regret_q16 = 5243; // 8%
        _accuracy_household_tail_share_q16 = 3277; // 5%
        _accuracy_candidate_top_k = 4;
        _accuracy_choice_temperature_q16 = 2621; // 4%
        _accuracy_exact_probe_rate_q16 = 131; // 0.2%
        _accuracy_fallback_cooldown_epochs = 20;
    } else {
        _accuracy_max_regret_q16 = std::clamp(dict_num<int32_t>(
            profile, "economy_custom_max_regret_q16", 1966), 0,
            static_cast<int32_t>(Q16_ONE));
        _accuracy_household_tail_share_q16 = std::clamp(dict_num<int32_t>(
            profile, "economy_custom_household_tail_share_q16", 655), 0,
            static_cast<int32_t>(Q16_ONE));
        _accuracy_candidate_top_k = std::clamp(dict_num<int32_t>(
            profile, "economy_custom_candidate_top_k", 4), 1, 8);
        _accuracy_choice_temperature_q16 = std::clamp(dict_num<int32_t>(
            profile, "economy_custom_choice_temperature_q16", 983), 0,
            static_cast<int32_t>(Q16_ONE));
        _accuracy_exact_probe_rate_q16 = std::clamp(dict_num<int32_t>(
            profile, "economy_custom_exact_probe_rate_q16", 655), 1,
            static_cast<int32_t>(Q16_ONE));
        _accuracy_fallback_cooldown_epochs = std::clamp(dict_num<int32_t>(
            profile, "economy_custom_fallback_cooldown_epochs", 10), 1, 3650);
    }
    // EXACT is exact regardless of rollout selection. Approximate authority is
    // also withheld while a failed certificate family is cooling down.
    if (_accuracy_preset == 0)
        _approximation_runtime_mode = 0;
    _approximation_cooldown_epochs_left = 0;
    _approximation_low_prune_epochs = 0;
    _wealth_reference_per_capita = std::max<int64_t>(1, dict_num<int64_t>(
        profile, "wealth_reference_per_capita", MONEY_SCALE * 10));
    _living_cost_base_plan_stable_id =
        dict_string(profile, "living_cost_base_plan_id", "survival_household");
    _starvation_satisfaction_threshold_q16 = std::clamp(
        dict_num<int32_t>(profile, "starvation_satisfaction_threshold_q16",
            dict_num<int32_t>(profile, "survival_work_threshold_q16", Q16_ONE / 2)),
        1, static_cast<int32_t>(Q16_ONE));
    _survival_production_target_q16 = std::clamp(
        dict_num<int32_t>(profile, "survival_production_target_q16", Q16_ONE),
        _starvation_satisfaction_threshold_q16, static_cast<int32_t>(Q16_ONE));
    _starvation_death_rate_q32 = std::clamp<int64_t>(
        dict_num<int64_t>(profile, "starvation_death_rate_q32", Q32_ONE / 200),
        0, Q32_ONE);
    configure_satisfaction_profile(profile);
    _wage_ema_alpha_q16 = std::clamp(
        dict_num<int32_t>(profile, "wage_ema_alpha_q16", 8192), 0,
        static_cast<int32_t>(Q16_ONE));
    _employment_mobility_daily_q16 = std::clamp(
        dict_num<int32_t>(profile, "employment_mobility_daily_q16", 13107), 0,
        static_cast<int32_t>(Q16_ONE));
    _employment_choice_temperature_q16 = std::clamp(
        dict_num<int32_t>(profile, "employment_choice_temperature_q16", 6554), 1,
        static_cast<int32_t>(Q16_ONE));
    _wage_max_rise_q16_per_day = std::clamp(
        dict_num<int32_t>(profile, "wage_max_rise_q16_per_day", 1311), 0,
        static_cast<int32_t>(Q16_ONE));
    _wage_max_fall_q16_per_day = std::clamp(
        dict_num<int32_t>(profile, "wage_max_fall_q16_per_day", 1311), 0,
        static_cast<int32_t>(Q16_ONE));
    _wage_income_cap_ratio_q16 = std::max(0,
        dict_num<int32_t>(profile, "wage_income_cap_ratio_q16", 78643));
    _employee_profit_share_q16 = std::clamp(
        dict_num<int32_t>(profile, "employee_profit_share_q16", 16384), 0,
        static_cast<int32_t>(Q16_ONE));
    _building_severe_loss_threshold_q16 = std::clamp(
        dict_num<int32_t>(profile, "building_severe_loss_threshold_q16", -16384),
        -static_cast<int32_t>(Q16_ONE), 0);
    _building_severe_loss_cycles = std::clamp(
        dict_num<int32_t>(profile, "building_severe_loss_cycles", 3), 1, 32);
    _building_restart_margin_q16 = std::clamp(
        dict_num<int32_t>(profile, "building_restart_margin_q16", 6554), 0,
        static_cast<int32_t>(Q16_ONE));
    // Retained only in the v35 binary policy payload for layout compatibility;
    // the lifecycle no longer has a restart-cycle gate.
    _building_restart_cycles = 2;
    _merchant_procurement_cash_reserve_q16 = std::clamp(
        dict_num<int32_t>(profile, "merchant_procurement_cash_reserve_q16", 8192),
        0, static_cast<int32_t>(Q16_ONE));
    _merchant_market_making_days_q16 = std::clamp(
        dict_num<int32_t>(profile, "merchant_market_making_days_q16", Q16_ONE * 60),
        0, static_cast<int32_t>(Q16_ONE * 120));
    const std::string credit_mode = dict_string(
        profile, "merchant_credit_runtime_mode", "ACTIVE");
    _merchant_credit_runtime_mode = credit_mode == "OFF" ? 0
        : (credit_mode == "PROBE" ? 1 : 2);
    _merchant_credit_exposure_q16 = std::clamp(dict_num<int32_t>(
        profile, "merchant_credit_exposure_q16", 16384), 0,
        static_cast<int32_t>(Q16_ONE));
    _merchant_credit_premium_q16 = std::clamp(dict_num<int32_t>(
        profile, "merchant_credit_premium_q16", 3277), 0,
        static_cast<int32_t>(Q16_ONE));
    _merchant_credit_term_cycles = std::clamp(dict_num<int32_t>(
        profile, "merchant_credit_term_cycles", 6), 1, 64);
    // Retained only in the v35 binary policy payload; recovery is now a
    // single-boundary ACTIVE/SUSPENDED transition.
    _recovery_success_cycles = 2;
    const int32_t suspended_liquidation_reviews = dict_num<int32_t>(
        profile, "suspended_liquidation_failed_reviews", 73);
    _recovery_liquidation_failed_reviews = std::clamp(
        suspended_liquidation_reviews, 1, 365);
    _merchant_profession_stable_id = dict_string(profile, "merchant_profession_id", "merchant");
    _unemployed_profession_stable_id = dict_string(profile, "unemployed_profession_id", "unemployed");
    const std::string runtime_mode = dict_string(profile, "market_runtime_mode", "PROBE");
    _market_runtime_mode = runtime_mode == "OFF" ? 0 : (runtime_mode == "PROBE" ? 1 : 2);
    const std::string trade_mode = dict_string(profile, "trade_runtime_mode", "ACTIVE");
    _trade_runtime_mode = trade_mode == "OFF" ? 0 : (trade_mode == "ACTIVE" ? 2 : 1);
    const std::string startup_demand_mode = dict_string(
        profile, "startup_demand_runtime_mode", "ACTIVE");
    if (startup_demand_mode != "OFF" && startup_demand_mode != "ACTIVE") {
        error = "startup_demand_runtime_mode_invalid";
        return false;
    }
    _startup_demand_runtime_mode = startup_demand_mode == "ACTIVE" ? 1 : 0;
    _trade_capacity_per_merchant_q16 = std::clamp<int64_t>(dict_num<int64_t>(
        profile, "trade_capacity_per_merchant_q16", 64 * Q16_ONE), 1,
        std::numeric_limits<int32_t>::max());
    _trade_speed_cost_per_day = std::clamp(dict_num<int32_t>(
        profile, "trade_speed_cost_per_day", 4), 1, 1000000);
    _trade_min_margin_q16 = std::clamp(dict_num<int32_t>(
        profile, "trade_min_margin_q16", 3277), 0, static_cast<int32_t>(Q16_ONE));
    _trade_target_count = std::clamp(dict_num<int32_t>(
        profile, "trade_target_count", 4), 1, 8);
    _trade_signal_pairs_per_slice = std::clamp(dict_num<int32_t>(
        profile, "trade_signal_pairs_per_slice", 4096), 256, 1 << 20);
    _trade_route_searches_per_slice = std::clamp(dict_num<int32_t>(
        profile, "trade_route_searches_per_slice", 32), 1, 256);
    _trade_max_route_expansions = std::clamp(dict_num<int32_t>(
        profile, "trade_max_route_expansions", 8192), 64, 1000000);
    _trade_route_cache_entries = std::clamp(dict_num<int32_t>(
        profile, "trade_route_cache_entries", 16384), 64, 1 << 22);
    _trade_max_signals = std::clamp(dict_num<int32_t>(
        profile, "trade_max_signals", 32768), 64, 1 << 20);
    _trade_max_candidates = std::clamp(dict_num<int32_t>(
        profile, "trade_max_candidates", 8192), 16, 1 << 20);
    _trade_max_orders = std::clamp(dict_num<int32_t>(
        profile, "trade_max_orders", 4096), 16, 1 << 20);
    _trade_flow_ema_alpha_q16 = std::clamp(dict_num<int32_t>(
        profile, "trade_flow_ema_alpha_q16", 8192), 0, static_cast<int32_t>(Q16_ONE));
    _trade_max_stock_share_q16 = std::clamp(dict_num<int32_t>(
        profile, "trade_max_stock_share_q16", 16384), 1, static_cast<int32_t>(Q16_ONE));
    _trade_export_floor_days = std::clamp(dict_num<int32_t>(
        profile, "trade_export_floor_days", 5), 1, 365);
    _trade_export_inventory_fraction_q16 = std::clamp(dict_num<int32_t>(
        profile, "trade_export_inventory_fraction_q16", 32768), 0,
        static_cast<int32_t>(Q16_ONE));
    _trade_import_fill_fraction_q16 = std::clamp(dict_num<int32_t>(
        profile, "trade_import_fill_fraction_q16", 32768), 0,
        static_cast<int32_t>(Q16_ONE));
    _trade_response_days = std::clamp(dict_num<int32_t>(
        profile, "trade_response_days", 15), 1, 365);
    _investment_review_days = std::clamp(dict_num<int32_t>(
        profile, "investment_review_days", 30), 1, 3650);
    _building_plan_days = std::clamp(dict_num<int32_t>(
        profile, "building_plan_days", 10), 1, 3650);
    _slow_cycle_min_days = PLAN_CYCLE_MIN_DAYS;
    _slow_cycle_max_days = PLAN_CYCLE_MAX_DAYS;
    _invest_cycle_min_days = INVEST_CYCLE_MIN_DAYS;
    _invest_cycle_max_days = INVEST_CYCLE_MAX_DAYS;
    // These two thresholds remain in the v35 binary policy payload for
    // archive layout compatibility. No current investment path consults them.
    _investment_min_shortage_q16 = Q16_ONE / 8;
    _investment_min_utilization_q16 = 42598;
    _investment_max_payback_days = std::clamp(dict_num<int32_t>(
        profile, "investment_max_payback_days", 365), 1, 36500);
    _investment_operating_cycles = std::clamp(dict_num<int32_t>(
        profile, "investment_operating_cycles", 2), 1, 12);
    _investment_gap_fill_share_q16 = std::clamp(dict_num<int32_t>(
        profile, "investment_gap_fill_share_q16", 16384), 1,
        static_cast<int32_t>(Q16_ONE));
    _investment_portfolio_max_types = std::clamp(dict_num<int32_t>(
        profile, "investment_portfolio_max_types", 4), 1, 4);
    _investment_max_type_owner_share_q16 = std::clamp(dict_num<int32_t>(
        profile, "investment_max_type_owner_share_q16", 32768), 1,
        static_cast<int32_t>(Q16_ONE));
    _investment_max_growth_share_q16 = std::clamp(dict_num<int32_t>(
        profile, "investment_max_growth_share_q16", 16384), 1,
        static_cast<int32_t>(Q16_ONE));
    _investment_new_type_seed_buildings = std::clamp(dict_num<int32_t>(
        profile, "investment_new_type_seed_buildings", 1), 1, 1024);
    _investment_displacement_min_advantage_q16 = std::clamp(dict_num<int32_t>(
        profile, "investment_displacement_min_advantage_q16",
        Q16_ONE / 16), 1, static_cast<int32_t>(Q16_ONE));
    _investment_merchant_transition_min_improvement_q16 =
        std::clamp(dict_num<int32_t>(
            profile, "investment_merchant_transition_min_improvement_q16",
            32768), 1, static_cast<int32_t>(Q16_ONE));
    const std::string investment_sparse_mode = dict_string(
        profile, "economy_investment_sparse_mode", "ACTIVE");
    _investment_sparse_mode = investment_sparse_mode == "OFF" ? 0
        : (investment_sparse_mode == "ACTIVE" ? 2 : 1);
    _investment_sparse_runtime_disabled = false;
    _recovery_liquidation_max_share_q16 = std::clamp(dict_num<int32_t>(
        profile, "recovery_liquidation_max_share_q16", 16384), 1,
        static_cast<int32_t>(Q16_ONE));
    _resource_min_reserve_q16 = std::clamp(dict_num<int32_t>(
        profile, "resource_min_reserve_q16", 22938), 0,
        static_cast<int32_t>(Q16_ONE));
    _resource_safe_harvest_q16 = std::clamp(dict_num<int32_t>(
        profile, "resource_safe_harvest_q16", 0), 0,
        static_cast<int32_t>(Q16_ONE));
    _resource_min_horizon_days = std::clamp(dict_num<int32_t>(
        profile, "resource_min_horizon_days", 3650), 1, 365000);
    {
        const std::vector<int32_t> horizons = packed_i32(
            profile, "building_maintenance_horizon_days_by_sector");
        const int32_t defaults[5] = {5475, 2920, 3650, 2190, 7300};
        for (int32_t sector = 0; sector < 5; ++sector) {
            const int32_t value = sector < static_cast<int32_t>(horizons.size())
                ? horizons[static_cast<size_t>(sector)] : defaults[sector];
            _maintenance_horizon_days_by_sector[sector] = std::clamp(value, 1, 365000);
        }
    }
    _building_maintenance_cost_factor_q16 = std::clamp(
        dict_num<int32_t>(profile, "building_maintenance_cost_factor_q16",
                          static_cast<int32_t>(Q16_ONE)),
        1, static_cast<int32_t>(Q16_ONE * 4));
    if (!_building_types.empty()) resolve_building_maintenance_csr();
    _bullion_monthly_issue_cap_q16 = std::clamp(dict_num<int32_t>(
        profile, "bullion_monthly_issue_cap_q16", 655), 0,
        static_cast<int32_t>(Q16_ONE));
    _producer_support_monthly_cap_q16 = std::clamp(dict_num<int32_t>(
        profile, "producer_support_monthly_cap_q16", 3277), 0,
        static_cast<int32_t>(Q16_ONE));
    const std::string family_mode = dict_string(
        profile, "family_runtime_mode", "ACTIVE");
    _family_runtime_mode = family_mode == "OFF" ? 0
        : (family_mode == "PROBE" ? 1 : 2);
    _family_min_settlement_tier = std::clamp(dict_num<int32_t>(
        profile, "family_min_settlement_tier", 2), 0, 7);
    _family_review_days = std::clamp(dict_num<int32_t>(
        profile, "family_review_days", 30), 1, 3650);
    _family_min_population_per_active = std::clamp<int64_t>(dict_num<int64_t>(
        profile, "family_min_population_per_active", 150), 1, 1000000000LL);
    _family_max_per_cell = std::clamp(dict_num<int32_t>(
        profile, "family_max_per_cell", 8), 1, 4096);
    _family_cells_per_slice = std::clamp(dict_num<int32_t>(
        profile, "family_cells_per_slice", 128), 1, 65536);
    _family_decline_reviews = std::clamp(dict_num<int32_t>(
        profile, "family_decline_reviews", 3), 1, 32);
    _family_household_people_per_owner_slot = std::clamp(dict_num<int32_t>(
        profile, "family_household_people_per_owner_slot", 256), 1, 256);
    _family_household_max_people = std::clamp(dict_num<int32_t>(
        profile, "family_household_max_people", 1024), 1, 100000);
    const std::string person_mode = dict_string(
        profile, "notable_person_runtime_mode", "ACTIVE");
    _person_runtime_mode = person_mode == "OFF" ? 0
        : (person_mode == "PROBE" ? 1 : 2);
    _person_max_per_family = std::clamp(dict_num<int32_t>(
        profile, "notable_person_max_per_family", 4), 1, 64);
    _person_max_per_cell = std::clamp(dict_num<int32_t>(
        profile, "notable_person_max_per_cell", 128), 1, 4096);
    _person_max_total = std::clamp(dict_num<int32_t>(
        profile, "notable_person_max_total", 65536), 1, 1000000);
    _person_records_per_slice = std::clamp(dict_num<int32_t>(
        profile, "notable_person_records_per_slice", 4096), 1, 65536);
    const std::string trace_mode = dict_string(profile, "economy_trace_mode", "SELECTIVE");
    _trace_mode = trace_mode == "OFF" ? TRACE_OFF
        : (trace_mode == "SUMMARY" ? TRACE_SUMMARY
        : (trace_mode == "FULL_DEBUG" ? TRACE_FULL_DEBUG : TRACE_SELECTIVE));
    _trace_memory_budget = std::clamp<int64_t>(
        dict_num<int64_t>(profile, "economy_trace_memory_bytes", 32LL * 1024 * 1024),
        1024 * 1024, 1024LL * 1024 * 1024);
    _trace_retention_epochs = std::clamp(
        dict_num<int32_t>(profile, "economy_trace_retention_epochs", 8), 1, 3650);
    _trace_detail_epoch_budget = std::clamp<int64_t>(
        dict_num<int64_t>(profile, "economy_trace_detail_epoch_bytes", 8LL * 1024 * 1024),
        64 * 1024, 256LL * 1024 * 1024);
    _trace_poll_max_events = std::clamp(
        dict_num<int32_t>(profile, "economy_trace_poll_max_events", 4096), 1, 65536);
    const int64_t money_scale = dict_num<int64_t>(profile, "money_scale", MONEY_SCALE);
    const int64_t goods_scale = dict_num<int64_t>(profile, "goods_scale", GOODS_SCALE);
    const int64_t ratio_scale = dict_num<int64_t>(profile, "ratio_scale", Q16_ONE);
    const int64_t rate_scale = dict_num<int64_t>(profile, "rate_scale", Q32_ONE);
    if (money_scale != MONEY_SCALE || goods_scale != GOODS_SCALE ||
        ratio_scale != Q16_ONE || rate_scale != Q32_ONE) {
        error = "numeric_scale_mismatch";
        return false;
    }
    return true;
}


void NativeEconomyRuntime::configure_satisfaction_profile(const Dictionary &profile) {
    const auto read_weights = [&](const char *key, int32_t *out, size_t count) {
        const std::vector<int32_t> values = packed_i32(profile, key);
        if (values.size() != count) return;
        for (size_t i = 0; i < count; ++i)
            out[i] = std::clamp<int32_t>(values[i], 0,
                                         static_cast<int32_t>(Q16_ONE));
    };
    read_weights("satisfaction_default_dimension_weights_q16",
                 _satisfaction_default_weights_q16.data(),
                 _satisfaction_default_weights_q16.size());
    read_weights("satisfaction_development_weights_q16",
                 _satisfaction_development_weights_q16.data(),
                 _satisfaction_development_weights_q16.size());
    _satisfaction_subsistence_gate_slack_q16 = std::clamp(
        dict_num<int32_t>(profile, "satisfaction_subsistence_gate_slack_q16",
                          6554),
        0, static_cast<int32_t>(Q16_ONE));
    _satisfaction_income_growth_floor_q16 = std::max(0, dict_num<int32_t>(
        profile, "satisfaction_income_growth_floor_q16", 58982));
    _satisfaction_income_growth_ceiling_q16 = std::max(
        _satisfaction_income_growth_floor_q16 + 1,
        dict_num<int32_t>(profile, "satisfaction_income_growth_ceiling_q16",
                          78643));
    _satisfaction_income_baseline_alpha_q16 = std::clamp(
        dict_num<int32_t>(profile, "satisfaction_income_baseline_alpha_q16",
                          1024),
        1, static_cast<int32_t>(Q16_ONE));
    _satisfaction_savings_target_months_q16 = std::max<int64_t>(1,
        dict_num<int64_t>(profile, "satisfaction_savings_target_months_q16",
                          393216));
    _satisfaction_tax_tolerance_q16 = std::clamp(
        dict_num<int32_t>(profile, "satisfaction_tax_tolerance_q16", 22938),
        1, static_cast<int32_t>(Q16_ONE));
    _satisfaction_development_variety_target = std::clamp(
        dict_num<int32_t>(profile, "satisfaction_development_variety_target",
                          12),
        1, 256);
    _satisfaction_birth_reference_q16 = std::clamp(
        dict_num<int32_t>(profile, "satisfaction_birth_reference_q16", 45875),
        1, static_cast<int32_t>(Q16_ONE));
    const std::vector<int32_t> thresholds = packed_i32(
        profile, "satisfaction_pressure_thresholds_q16");
    if (thresholds.size() == _satisfaction_pressure_thresholds_q16.size()) {
        int32_t previous = 0;
        for (size_t i = 0; i < thresholds.size(); ++i) {
            // Ascending and strictly inside (0, 1) so every level stays reachable.
            previous = std::clamp<int32_t>(thresholds[i], previous + 1,
                                           static_cast<int32_t>(Q16_ONE) - 1);
            _satisfaction_pressure_thresholds_q16[i] = previous;
        }
    }
    _carrying_k_habitat_ref = std::max<int64_t>(0,
        dict_num<int64_t>(profile, "carrying_k_habitat_ref", 40));
    _carrying_k_floor = std::max<int64_t>(0,
        dict_num<int64_t>(profile, "carrying_k_floor", 8));
    const int32_t q16 = static_cast<int32_t>(Q16_ONE);
    _carrying_river_bonus_q16 = std::clamp(
        dict_num<int32_t>(profile, "carrying_river_bonus_q16", 72090),
        0, q16 * 4);
    _carrying_water_habitability_q16 = std::clamp(
        dict_num<int32_t>(profile, "carrying_water_habitability_q16", 49152),
        0, q16);
    _carrying_surplus_elasticity_q16 = std::clamp(
        dict_num<int32_t>(profile, "carrying_surplus_elasticity_q16", q16 / 2),
        0, q16);
    _carrying_sat_elasticity_q16 = std::clamp(
        dict_num<int32_t>(profile, "carrying_sat_elasticity_q16", 22938),
        0, q16);
    _carrying_soft_start_q16 = std::clamp(
        dict_num<int32_t>(profile, "carrying_soft_start_q16", 58982),
        1, q16);
    _carrying_stock_buffer_days = std::clamp(
        dict_num<int32_t>(profile, "carrying_stock_buffer_days", 30),
        1, 3650);
    _carrying_surplus_floor_q16 = std::clamp(
        dict_num<int32_t>(profile, "carrying_surplus_floor_q16", 16384),
        0, q16);
    _carrying_surplus_cap_q16 = std::max(_carrying_surplus_floor_q16,
        dict_num<int32_t>(profile, "carrying_surplus_cap_q16", 98304));
    _carrying_sat_floor_q16 = std::clamp(
        dict_num<int32_t>(profile, "carrying_sat_floor_q16", 8192),
        0, q16);
    _carrying_sat_cap_q16 = std::max(_carrying_sat_floor_q16,
        dict_num<int32_t>(profile, "carrying_sat_cap_q16", q16));
    _carrying_residual_floor_q16 = std::clamp(
        dict_num<int32_t>(profile, "carrying_residual_floor_q16", q16 / 2),
        1, q16 * 4);
    _carrying_residual_cap_q16 = std::max(_carrying_residual_floor_q16,
        dict_num<int32_t>(profile, "carrying_residual_cap_q16", q16 * 2));
    _carrying_support_ema_alpha_q16 = std::clamp(
        dict_num<int32_t>(profile, "carrying_support_ema_alpha_q16", 1024),
        1, q16);
    _carrying_temp_opt_lo_q16 = std::clamp(
        dict_num<int32_t>(profile, "carrying_temp_opt_lo_q16", 19661),
        0, q16);
    _carrying_temp_opt_hi_q16 = std::clamp(
        dict_num<int32_t>(profile, "carrying_temp_opt_hi_q16", 45875),
        _carrying_temp_opt_lo_q16, q16);
    _carrying_paw_opt_lo_q16 = std::clamp(
        dict_num<int32_t>(profile, "carrying_paw_opt_lo_q16", 16384),
        0, q16);
    _carrying_paw_opt_hi_q16 = std::clamp(
        dict_num<int32_t>(profile, "carrying_paw_opt_hi_q16", 58982),
        _carrying_paw_opt_lo_q16, q16);
    _carrying_family_weight = packed_i32(profile, "carrying_family_weight");
    _carrying_profile_class_ids = packed_strings(profile, "carrying_class_ids");
    _carrying_profile_class_weight_q16 = packed_i32(
        profile, "carrying_class_weight_q16");
    _carrying_landform_habitability_q16 = packed_i32(
        profile, "carrying_landform_habitability_q16");
    _carrying_vegetation_habitability_q16 = packed_i32(
        profile, "carrying_vegetation_habitability_q16");
    if (_carrying_landform_habitability_q16.size() < CARRYING_LANDFORM_COUNT)
        _carrying_landform_habitability_q16.resize(CARRYING_LANDFORM_COUNT, q16);
    if (_carrying_vegetation_habitability_q16.size() < CARRYING_VEGETATION_COUNT)
        _carrying_vegetation_habitability_q16.resize(CARRYING_VEGETATION_COUNT, q16);
}


} // namespace pk

