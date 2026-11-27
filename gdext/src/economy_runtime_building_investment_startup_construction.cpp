#include "economy_runtime.h"
#include "economy_runtime_building_investment_internal.h"
#include "economy_cost_probe.h"
#include "runtime_switch_registry.h"
#include <algorithm>
#include <array>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <tuple>


namespace pk {

bool NativeEconomyRuntime::resolve_startup_construction_material(
        int32_t cell, int32_t bom, int32_t cost_factor_q16,
        int32_t &good, int64_t &physical) const {
    good = -1;
    physical = 0;
    if (bom < 0 || bom >= static_cast<int32_t>(
            _building_construction_goods.size())) return false;
    int64_t sat = 0;
    int64_t selected = 0;
    good = select_startup_construction_candidate(cell, bom, selected);
    if (!is_storable_nonmonetary_good(good) || selected <= 0) {
        good = -1;
        return false;
    }
    const int64_t required = std::max<int64_t>(1, mul_div_sat(
        _building_construction_goods[bom].quantity,
        std::max<int32_t>(1, cost_factor_q16), Q16_ONE, sat));
    physical = selected;
    for (int32_t cursor = _building_construction_candidate_offsets[bom];
         cursor < _building_construction_candidate_offsets[bom + 1]; ++cursor) {
        const ConstructionCandidate &candidate =
            _building_construction_candidates[cursor];
        if (candidate.good_id != good) continue;
        const int32_t efficiency = std::max<int32_t>(1,
            candidate.efficiency_q16);
        physical = mul_div_sat(required, Q16_ONE, efficiency,
            sat);
        if (mul_div_sat(physical, efficiency, Q16_ONE,
                sat) < required)
            physical = saturating_add(physical, 1, sat);
        break;
    }
    return physical > 0;
}

void NativeEconomyRuntime::initialize_investment_candidate_plan(
        InvestmentCandidatePlan &plan, int32_t cell, int32_t type_id,
        int32_t owner_signature_id, int64_t utilization_q16,
        int64_t construction_cost, int64_t required_capital,
        int64_t payback_days, int64_t profit_per_day,
        int64_t return_on_capital_q16, int64_t owner_slots,
        int64_t employee_slots,
        const EconomicOpportunityQuote &quote) const {
    // Keep the legacy call shape for existing discovery code, but route the
    // shared financial fields through the single evaluator below.
    evaluate_investment_candidate(plan, cell, type_id, owner_signature_id,
        utilization_q16, construction_cost, required_capital, owner_slots,
        employee_slots, quote);
    // The historical scalar arguments remain in the ABI for callers compiled
    // against the previous helper shape. They are intentionally ignored: the
    // normalized quote is now the sole source of candidate economics.
    (void)payback_days;
    (void)profit_per_day;
    (void)return_on_capital_q16;
}

bool NativeEconomyRuntime::evaluate_investment_candidate(
        InvestmentCandidatePlan &plan, int32_t cell, int32_t type_id,
        int32_t owner_signature_id, int64_t utilization_q16,
        int64_t construction_cost, int64_t required_capital,
        int64_t owner_slots, int64_t employee_slots,
        const EconomicOpportunityQuote &quote) const {
    plan.cell = cell;
    plan.type_id = type_id;
    plan.owner_signature_id = owner_signature_id;
    plan.utilization_q16 = utilization_q16;
    plan.construction_cost = construction_cost;
    plan.required_capital = required_capital;
    plan.owner_slots = owner_slots;
    plan.employee_slots = employee_slots;
    plan.quote = quote;
    plan.quote.cell = cell;
    plan.quote.type_id = type_id;
    plan.quote.owner_signature_id = owner_signature_id;
    plan.quote.utilization_q16 = utilization_q16;
    // The quote is the sole source for the normalized daily economics.  Keep
    // the derived return fields deterministic even when a caller supplied an
    // incomplete legacy quote.
    int64_t sat = 0;
    if (plan.quote.profit_per_day == 0) {
        const int64_t revenue = std::max<int64_t>(0,
            plan.quote.economic_revenue_per_day);
        const int64_t costs = saturating_add(
            saturating_add(std::max<int64_t>(0, plan.quote.input_cost_per_day),
                std::max<int64_t>(0, plan.quote.wage_cost_per_day),
                sat),
            saturating_add(std::max<int64_t>(0,
                    plan.quote.maintenance_cost_per_day),
                std::max<int64_t>(0, plan.quote.owner_living_cost_per_day),
                sat), sat);
        plan.quote.profit_per_day = saturating_sub(revenue, costs,
            sat);
    }
    plan.target_profit_per_day = plan.quote.profit_per_day;
    plan.payback_days = plan.target_profit_per_day > 0
        ? (required_capital + plan.target_profit_per_day - 1) /
            plan.target_profit_per_day
        : std::numeric_limits<int64_t>::max();
    plan.target_return_on_capital_q16 = plan.target_profit_per_day > 0
        ? mul_div_sat(plan.target_profit_per_day, Q16_ONE,
            std::max<int64_t>(1, required_capital), sat)
        : 0;
    plan.rejection_reason = plan.target_profit_per_day > 0
        ? INVESTMENT_REJECTION_NONE : INVESTMENT_REJECTION_TARGET_MARGIN;
    return plan.rejection_reason == INVESTMENT_REJECTION_NONE;
}

void NativeEconomyRuntime::record_investment_material_demand(
        int32_t cell, int32_t type_id, int64_t count, int32_t cost_factor_q16) {
    if (cell < 0 || cell >= _cell_count.get() || type_id < 0 ||
        type_id >= static_cast<int32_t>(_building_types.size()) || count <= 0)
        return;
    const BuildingType &type = _building_types[type_id];
    for (int32_t edge = 0; edge < type.construction_count; ++edge) {
        const int32_t bom = type.construction_begin + edge;
        int64_t physical = 0;
        int32_t good = -1;
        if (!resolve_startup_construction_material(cell, bom,
                cost_factor_q16, good, physical)) continue;
        const int32_t signal = ensure_market_signal_index(cell, good);
        if (signal < 0) continue;
        // 投资在生产 EMA 更新之后执行；只追加新出现的有资金支持的缺口，
        // 使用 max 保证批量二分/组合重试不会反复制造需求。
        const int64_t demand = saturating_mul(physical, count, _saturation_count);
        const int64_t previous = _epoch_desired_business_demand[signal];
        const int64_t increase = std::max<int64_t>(0, demand - previous);
        _epoch_desired_business_demand[signal] = std::max(previous, demand);
        const int64_t daily = increase / std::max(1, _epoch_days.get());
        const int64_t alpha = std::min<int64_t>(Q16_ONE,
            static_cast<int64_t>(_good_business_demand_ema_alpha_q16[good]) *
                std::max(1, _epoch_days.get()));
        _market_signals.business_demand_ema.write_scalar(signal, saturating_add(
            _market_signals.business_demand_ema[signal],
            mul_div_sat(daily, alpha, Q16_ONE, _saturation_count), _saturation_count), market_mutation_sink());
        _desired_business_demand = saturating_add(_desired_business_demand,
            increase, _saturation_count);
        _unfunded_business_demand = saturating_add(_unfunded_business_demand,
            increase, _saturation_count);
        int64_t &reserve = _construction_material_reserve[signal];
        _construction_material_reserved = saturating_add(_construction_material_reserved,
            std::max<int64_t>(0, demand - reserve), _saturation_count);
        reserve = std::max(reserve, demand);
    }

    // A candidate producer also creates a future operating-input demand.  It
    // must enter the same total-good price signal as household and installed
    // building demand; otherwise a hard-input chain can never cold-start
    // (for example knapping waits for flint while the flint quarry waits for
    // a flint price signal).  This is prospective demand, so it is recorded
    // as desired/unfunded demand and never as a spend or a physical reserve.
    for (int32_t input_index = 0; input_index < type.input_count; ++input_index) {
        const ProductionInput &input = _building_inputs[
            type.input_begin + input_index];
        if (input.quantity <= 0) continue;
        int32_t good = input.preferred_good_id;
        if (good < 0 && input.candidate_count > 0)
            good = _building_input_candidates[input.candidate_begin].good_id;
        if (good < 0 || good >= market_store().good_count.get()) continue;
        const int32_t signal = ensure_market_signal_index(cell, good);
        if (signal < 0) continue;
        const int64_t demand = saturating_mul(
            saturating_mul(input.quantity, std::max<int64_t>(1, count),
                _saturation_count),
            std::max<int64_t>(1, _epoch_days.get()), _saturation_count);
        const int64_t previous = _epoch_desired_business_demand[signal];
        const int64_t increase = std::max<int64_t>(0, demand - previous);
        _epoch_desired_business_demand[signal] = std::max(previous, demand);
        if (increase <= 0) continue;
        const int64_t daily = increase / std::max(1, _epoch_days.get());
        const int64_t alpha = std::min<int64_t>(Q16_ONE,
            static_cast<int64_t>(_good_business_demand_ema_alpha_q16[good]) *
                std::max(1, _epoch_days.get()));
        _market_signals.business_demand_ema.write_scalar(signal, saturating_add(
            _market_signals.business_demand_ema[signal],
            mul_div_sat(daily, alpha, Q16_ONE, _saturation_count),
            _saturation_count), market_mutation_sink());
        _desired_business_demand = saturating_add(
            _desired_business_demand, increase, _saturation_count);
        _unfunded_business_demand = saturating_add(
            _unfunded_business_demand, increase, _saturation_count);
    }
}

void NativeEconomyRuntime::reserve_first_research_construction(int32_t cell) {
    if (!_epoch_active || epoch_research_demand_daily(
            cell, _epoch_research_good_id) <= 0) return;
    // 首座机构的材料必须能跨周期积累；已有科研产能后交回普通投资规则。
    for (int32_t g = _building_cell_offsets[cell];
         g < _building_cell_offsets[cell + 1]; ++g) {
        const auto group = building_view(static_cast<size_t>(g));
        if (group.count <= 0) continue;
        const BuildingType &type = _building_types[group.type_id];
        for (int32_t i = 0; i < type.output_count; ++i)
            if (_building_outputs[type.output_begin + i].good_id ==
                    _epoch_research_good_id) return;
    }
    InvestmentCandidatePlan research_plan;
    const int32_t type_id = select_startup_producer(
        cell, _epoch_research_good_id, &research_plan);
    if (type_id < 0) return;
    const BuildingType &type = _building_types[type_id];
    research_plan.request.reason = INVESTMENT_REQUEST_RESEARCH_DEMAND;
    research_plan.request.demand_pressure = epoch_research_demand_daily(
        cell, _epoch_research_good_id);
    research_plan.request.allow_credit = true;
    research_plan.request.allow_reallocation = false;
    research_plan.request.max_batch_count = 1;
    research_plan.max_batch_count = 1;
    const int32_t country = _epoch_cell_country[cell];
    const int32_t factor = country >= 0 && country < static_cast<int32_t>(
            _epoch_country_construction_cost_factor_q16.size())
        ? std::max<int32_t>(1, _epoch_country_construction_cost_factor_q16[country])
        : Q16_ONE;
    for (int32_t edge = 0; edge < type.construction_count; ++edge) {
        const int32_t bom = type.construction_begin + edge;
        int64_t physical = 0;
            int32_t good = -1;
            if (!resolve_startup_construction_material(cell, bom, factor,
                    good, physical)) continue;
            research_plan.material_good_ids.push_back(good);
            research_plan.material_quantities.push_back(physical);
        const int32_t signal = ensure_market_signal_index(cell, good);
        if (signal < 0) continue;
        int64_t &reserve = _construction_material_reserve[signal];
        const int64_t increase = std::max<int64_t>(0, physical - reserve);
        reserve = std::max(reserve, physical);
        _construction_material_reserved = saturating_add(
            _construction_material_reserved, increase, _saturation_count);
    }
}

} // namespace pk
