#include "economy_runtime.h"

#include <vector>

namespace pk {

thread_local NativeEconomyRuntime::ProductionResult *
    NativeEconomyRuntime::_production_result_sink = nullptr;
thread_local NativeEconomyRuntime::MarketResult *
    NativeEconomyRuntime::_market_result_sink = nullptr;
thread_local std::vector<int32_t> *
    NativeEconomyRuntime::_staging_touched_sink = nullptr;

void NativeEconomyRuntime::MarketResult::reset() {
    ok = true;
    market = -1;
    error.clear();
    processed_cohorts = 0;
    processed_rules = 0;
    processed_needs = 0;
    processed_variants = 0;
    processed_components = 0;
    saturation_count = 0;
    consumed_goods = 0;
    cycle_flow_consumed = 0;
    cycle_flow_discarded = 0;
    retained_output_consumed = 0;
    retained_output_discarded = 0;
    food_access_eq = 0;
    food_access_events = 0;
    food_access_by_cell.clear();
    retained_consumed_by_good.clear();
    building_in_kind_credits.clear();
    owner_working_capital_reserved = 0;
    births = 0;
    deaths = 0;
    population_changed_cells.clear();
    closing_population = 0;
    closing_cohort_funds = 0;
    closing_goods_stock = 0;
    formula_ms = 0.0;
    clear_ms = 0.0;
    fallback_ms = 0.0;
    merchant_settle_ms = 0.0;
    price_ms = 0.0;
    merchant_count = 0;
    merchant_repairs = 0;
    price_ceiling_observations.clear();
    price_ceiling_expansions = price_ceiling_recoveries = price_ceiling_blocked_rises = 0;
    price_cap_hits = 0;
    price_rate_clamp_hits = 0;
    price_numeric_floor_hits = 0;
    price_numeric_ceiling_hits = 0;
    price_min_tick_hits = 0;
    price_glut_cost_damp_hits = 0;
    small_payment_roundups = 0;
    price_rise_fade_hits = 0;
    price_headroom_damp_hits = 0;
    price_catalog_bound_hits = 0;
    price_cost_anchor_hits = 0;
    price_inactive_reversions = 0;
    revenue = 0;
    changed_prices = 0;
    mutation_hash = 1469598103934665603ULL;
    trace_legs.clear();
    cashflows.clear();
    welfare_entries.clear();
    structural_commands.clear();
    trade_active_goods.clear();
    audit_population_lanes.clear();
    audit_market_lanes.clear();
    allocation_growth_count = 0;
    allocation_growth_bytes = 0;
    approximation_decisions = 0;
    approximation_exact_probes = 0;
    approximation_certificate_failures = 0;
    approximation_exact_fallbacks = 0;
    approximation_frontier_candidates = 0;
    approximation_frontier_pruned = 0;
    approximation_max_certified_regret_q16 = 0;
    approximation_probe_violations = 0;
    approximation_probe_max_spend_error_q16 = 0;
    approximation_probe_max_demand_error_q16 = 0;
    approximation_variant_active.clear();
}

int64_t NativeEconomyRuntime::MarketResult::capacity_bytes() const {
    return static_cast<int64_t>(
        price_ceiling_observations.capacity() * sizeof(PriceCeilingObservation) +
        food_access_by_cell.capacity() * sizeof(FoodAccessEntry) +
        retained_consumed_by_good.capacity() * sizeof(int64_t) +
        building_in_kind_credits.capacity() * sizeof(BuildingInKindCredit) +
        population_changed_cells.capacity() * sizeof(int32_t) +
        trace_legs.capacity() * sizeof(EventLeg) +
        cashflows.capacity() * sizeof(CashflowEntry) +
        welfare_entries.capacity() * sizeof(CohortWelfareEntry) +
        structural_commands.capacity() * sizeof(StructuralCommand) +
        trade_active_goods.capacity() * sizeof(int32_t) +
        audit_population_lanes.capacity() * sizeof(size_t) +
        audit_market_lanes.capacity() * sizeof(size_t) +
        approximation_variant_active.capacity() * sizeof(uint8_t));
}

void NativeEconomyRuntime::ProductionResult::reset() {
    ok = true;
    cell = -1;
    error.clear();
    saturation_count = 0;
    processed_building_groups = 0;
    climate_profiled_building_groups = 0;
    climate_limited_building_groups = 0;
    climate_capacity_sum_q16 = 0;
    merchant_procurement_budget = 0;
    merchant_procurement_opportunity = 0;
    merchant_procurement_allocated = 0;
    merchant_procurement_unspent_allocated = 0;
    merchant_procurement_reserved = 0;
    merchant_procurement_spent = 0;
    merchant_procurement_retail_value = 0;
    merchant_procurement_factor_weighted_cash_q16 = 0;
    merchant_survival_procurement_required = 0;
    merchant_survival_procurement_allocated = 0;
    merchant_input_procurement_required = 0;
    merchant_input_procurement_allocated = 0;
    owner_working_capital_allocated = 0;
    working_capital_scale_error_bound_q16 = 0;
    building_resource_capacity_checks = 0;
    building_resource_limited_groups = 0;
    building_resource_capacity_limited_groups = 0;
    building_resource_generated = 0;
    building_resource_consumed = 0;
    production_inputs_consumed = 0;
    maintenance_goods_consumed = 0;
    maintenance_unmet = 0;
    maintenance_unpaid_value = 0;
    production_output_stock = 0;
    production_output_discarded = 0;
    production_output_supported = 0;
    producer_revenue = 0;
    producer_support_money_issued = 0;
    explicit_money_mint = 0;
    bullion_money_issued = 0;
    bullion_stock_consumed = 0;
    gold_accepted = 0;
    silver_accepted = 0;
    gold_money_issued = 0;
    silver_money_issued = 0;
    cycle_flow_produced = 0;
    cycle_flow_consumed = 0;
    cycle_flow_discarded = 0;
    food_output_eq = 0;
    food_input_eq = 0;
    food_output_events = 0;
    food_input_events = 0;
    building_wages_paid = 0;
    building_wages_unpaid = 0;
    building_base_wages_paid = 0;
    building_base_wages_due = 0;
    building_bonus_paid = 0;
    building_bonus_due = 0;
    wage_suspended_building_groups = 0;
    desired_business_demand = 0;
    funded_business_demand = 0;
    unfunded_business_demand = 0;
    market_signal_updates = 0;
    merchant_credit_committed = 0;
    merchant_credit_drawn = 0;
    merchant_credit_repaid = 0;
    merchant_credit_premium_repaid = 0;
    market_signal_ms = 0.0;
    resource_touched_lanes.clear();
    retained_outputs.clear();
    trace_drafts.clear();
    cashflow_drafts.clear();
    audit_population_lanes.clear();
    audit_market_lanes.clear();
    bio_introduce_cells.clear();
    bio_introduce_bits.clear();
    allocation_growth_count = 0;
    allocation_growth_bytes = 0;
}

int64_t NativeEconomyRuntime::ProductionResult::capacity_bytes() const {
    int64_t bytes = static_cast<int64_t>(
        resource_touched_lanes.capacity() * sizeof(size_t) +
        retained_outputs.capacity() * sizeof(OwnerRetainedOutput) +
        trace_drafts.capacity() * sizeof(ProductionTraceDraft) +
        cashflow_drafts.capacity() * sizeof(ProductionCashflowDraft) +
        audit_population_lanes.capacity() * sizeof(size_t) +
        audit_market_lanes.capacity() * sizeof(size_t) +
        bio_introduce_cells.capacity() * sizeof(int32_t) +
        bio_introduce_bits.capacity() * sizeof(int32_t));
    for (const ProductionTraceDraft &draft : trace_drafts)
        bytes += static_cast<int64_t>(draft.legs.capacity() * sizeof(EventLeg));
    return bytes;
}

} // namespace pk
