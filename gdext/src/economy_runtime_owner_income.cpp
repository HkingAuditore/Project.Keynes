#include "economy_runtime_includes.inc"

namespace pk {

using namespace godot;
using namespace variant_helpers;

bool NativeEconomyRuntime::is_merchant_service_post(const BuildingType &type) const {
    // A merchant post sells no good, so every goods-receipt gate in the
    // investment and employment paths reads zero for it. Its owner income is
    // the market's household retail pool instead.
    return type.output_count <= 0 && type.owner_profession_id >= 0 &&
        type.owner_profession_id == _merchant_profession_id;
}

int64_t NativeEconomyRuntime::merchant_retail_owner_income_per_day(
        int32_t cell, int64_t owner_slots, int64_t extra_slots,
        int64_t &sat) const {
    if (cell < 0 || cell >= _cell_count.get() || owner_slots <= 0) return 0;
    const int32_t market = market_store().cell_to_market[cell];
    if (market < 0 ||
        static_cast<size_t>(market) >= _merchant_household_retail_by_market.size() ||
        static_cast<size_t>(market) >= _market_merchant_population.size()) return 0;
    const int64_t pool_per_day =
        _merchant_household_retail_by_market[static_cast<size_t>(market)];
    if (pool_per_day <= 0) return 0;
    // Only a share of the market pool is attributable to posts; the rest is
    // itinerant trade no post may claim. This is the free-entry cap and the
    // single tuning knob for how commercial a settlement can become.
    const int64_t shared_pool = mul_div_sat(pool_per_day,
        std::clamp<int64_t>(_merchant_service_post_share_q16, 1, Q16_ONE),
        Q16_ONE, sat);
    const int64_t merchant_population = std::max<int64_t>(0,
        _market_merchant_population[static_cast<size_t>(market)]);
    // Marginal dilution: a new seat competes with the merchants who already
    // live here, so the projection never promises a new post the incumbent
    // per-capita income. At equilibrium this equals the living floor and
    // investment stops on its own -- no hard population cap needed.
    const int64_t denominator = std::max<int64_t>(1, saturating_add(
        merchant_population, std::max<int64_t>(0, extra_slots), sat));
    return mul_div_sat(shared_pool, owner_slots, denominator, sat);
}

int64_t NativeEconomyRuntime::projected_owner_income_per_day(
        BuildingGroupConstRef group, int64_t &sat) const {
    if (group.type_id < 0 ||
        group.type_id >= static_cast<int32_t>(_building_types.size()) ||
        group.count <= 0) return 0;
    const BuildingType &type = _building_types[group.type_id];
    const int64_t days = std::max<int64_t>(1, _epoch_days.get());
    // Owner mobility is based on people actually attached to this lot. The
    // former max(planned, filled) fallback made an empty lot look profitable
    // at full nameplate capacity and pulled population into phantom income.
    int64_t owner_jobs = std::max<int64_t>(0, group.filled_owner);
    // A lot can be vacated by the current employment pass after producing a
    // factual period. Keep that realized receipt visible as the opportunity
    // signal for the next pass; only wholly unobserved vacant lots remain at
    // zero and cannot attract labor from phantom income.
    if (owner_jobs <= 0 && (group.last_output > 0 || group.last_sold > 0 ||
                            group.last_market_receipt > 0)) {
        owner_jobs = std::max<int64_t>(0, planned_owner_demand(group, sat));
    }
    if (owner_jobs <= 0) return 0;
    const bool observed_capacity = group.last_observed_capacity_days_q16 > 0;
    int64_t fact_scale_q16 = Q16_ONE;
    if (observed_capacity) {
        int64_t workforce_q16 = Q16_ONE;
        const int64_t owner_slots = saturating_mul(
            group.count, type.owner_slots_per_building, sat);
        workforce_q16 = owner_slots > 0
            ? std::clamp<int64_t>(mul_div_sat(
                owner_jobs, Q16_ONE, owner_slots, sat), 0, Q16_ONE)
            : Q16_ONE;
        for (int32_t r = 0; r < type.employee_count; ++r) {
            const JobRole &role = _building_employee_roles[type.employee_begin + r];
            const int64_t role_slots = saturating_mul(
                group.count, role.slots_per_building, sat);
            const int32_t role_index = group.employee_fill_begin + r;
            const int64_t filled = role_index >= 0 && role_index <
                    static_cast<int32_t>(_building_employee_filled.size())
                ? std::max<int64_t>(0, _building_employee_filled[role_index]) : 0;
            const int64_t role_capacity = role_slots > 0
                ? std::clamp<int64_t>(mul_div_sat(
                    filled, Q16_ONE, role_slots, sat), 0, Q16_ONE)
                : Q16_ONE;
            workforce_q16 = std::min(workforce_q16, role_capacity);
        }
        const int64_t current_capacity_days_q16 = saturating_mul(
            workforce_q16,
            saturating_mul(std::max<int64_t>(1, group.count), days, sat), sat);
        // This is a capacity-days multiplier, not a utilization ratio. It may
        // legitimately exceed Q16 when the current period is longer or has
        // more staffed capacity than the observed period.
        fact_scale_q16 = current_capacity_days_q16 > 0
            ? mul_div_sat(current_capacity_days_q16, Q16_ONE,
                std::max<int64_t>(1, group.last_observed_capacity_days_q16), sat)
            : 0;
    }
    auto scale_fact = [&](int64_t value) -> int64_t {
        return observed_capacity
            ? mul_div_sat(std::max<int64_t>(0, value), fact_scale_q16,
                          Q16_ONE, sat)
            : std::max<int64_t>(0, value);
    };
    int64_t input_cost = 0;
    int64_t maintenance_cost = 0;
    int64_t wage_cost = 0;
    if (observed_capacity) {
        // These are the previous committed period's actual cash outflows.
        // They remain authoritative even when the next plan is forced to a
        // lower utilization by a newly scarce input or resource.
        input_cost = scale_fact(group.last_input_cost);
        maintenance_cost = scale_fact(group.last_maintenance_cost);
        wage_cost = scale_fact(group.last_wages_paid);
    } else {
        const int64_t utilization = std::clamp<int64_t>(
            group.planned_utilization_q16, 0, Q16_ONE);
        if (utilization <= 0) return 0;
        input_cost = saturating_mul(
            saturating_mul(group.sample_unit_input_cost, group.count,
                           sat),
            days, sat);
        input_cost = mul_div_sat(input_cost, utilization, Q16_ONE, sat);
        maintenance_cost = saturating_mul(
            saturating_mul(group.sample_unit_maintenance_cost, group.count,
                           sat),
            days, sat);
        maintenance_cost = mul_div_sat(maintenance_cost, utilization, Q16_ONE,
                                       sat);
        for (int32_t r = 0; r < type.employee_count; ++r) {
            const JobRole &role = _building_employee_roles[type.employee_begin + r];
            const int32_t role_index = group.employee_fill_begin + r;
            const int64_t wage = role_index >= 0 && role_index <
                    static_cast<int32_t>(_building_role_contract_wage.size())
                ? _building_role_contract_wage[role_index]
                : 0;
            const int64_t filled = role_index >= 0 && role_index <
                    static_cast<int32_t>(_building_employee_filled.size())
                ? std::max<int64_t>(0, _building_employee_filled[role_index]) : 0;
            int64_t role_cost = saturating_mul(
                saturating_mul(filled, wage, sat), days, sat);
            role_cost = mul_div_sat(role_cost, utilization, Q16_ONE, sat);
            wage_cost = saturating_add(wage_cost, role_cost, sat);
        }
    }
    // Owner subsistence is not a business cost here: callers compare this
    // income against the owner living cost (investment viability, job
    // mobility), so netting it out would double-count it.
    const int64_t owner_living_cost = saturating_mul(
        saturating_mul(living_cost_for_signature(
            group.cell, group.owner_signature_id, _living_cost_base_plan_id,
            sat), owner_jobs, sat), days, sat);
    // Keep the owner opportunity quote on the same realized-income basis as
    // the production plan: cash receipts, support, and retained owner output
    // are all income.  Otherwise a cashless subsistence cycle is reported as
    // a loss even when it covered the owner's food needs.
    const int64_t observed_receipts = scale_fact(saturating_add(
        saturating_add(std::max<int64_t>(0, group.last_market_receipt),
                       std::max<int64_t>(0, group.last_bullion_mint_receipt), sat),
        std::max<int64_t>(0, group.last_producer_support_receipt), sat));
    int64_t realized_survival_output_value = 0;
    if (group.last_output > 0 && group.cell >= 0 && group.cell < _cell_count.get()) {
        const int32_t market = market_store().cell_to_market[group.cell];
        for (int32_t i = 0; i < type.output_count; ++i) {
            const int32_t good = _building_outputs[type.output_begin + i].good_id;
            if (good < 0 || good >= market_store().good_count.get() ||
                good >= static_cast<int32_t>(_survival_food_good_mask.size()) ||
                _survival_food_good_mask[good] == 0) continue;
            realized_survival_output_value = std::max<int64_t>(
                realized_survival_output_value,
                mul_div_sat(group.last_output,
                    market_store().price[market_store().index(market, good)],
                    GOODS_SCALE, sat));
        }
    }
    // Once a period has settled, mobility uses its actual cash receipts.
    // A production-plan quote can outlive both a price change and a workforce
    // move. Scaling that stale quote again invents income and causes workers
    // to oscillate between otherwise equivalent lots. In-kind income is added
    // exactly once below and is never a cash tax base.
    int64_t quoted_revenue = observed_capacity
        ? observed_receipts : std::max<int64_t>(0, group.last_expected_revenue);
    // Merchant posts book no building receipt at all: their owner income is
    // the market retail pool, which `process_market_cell` already settled as
    // cash to the merchant cohort. Attribute a share of it to the owner seats
    // this lot actually staffs. Pure attribution -- no cash is created -- so
    // funds, conservation and the cashflow ledger are untouched.
    if (is_merchant_service_post(type) && owner_jobs > 0) {
        quoted_revenue = saturating_add(quoted_revenue,
            merchant_retail_owner_income_per_day(
                group.cell, owner_jobs, 0, sat), sat);
    }
    const uint8_t owner_tax_mask = static_cast<uint8_t>(
        (1U << CountryApi::TAX_INCOME) |
        (1U << CountryApi::TAX_BUSINESS));
    if ((_epoch_active_tax_mask & owner_tax_mask) == 0) {
        const int64_t owner_pool = std::max<int64_t>(0,
            saturating_sub(quoted_revenue,
                saturating_add(saturating_add(
                    input_cost, wage_cost, sat),
                    maintenance_cost, sat), sat));
        const int64_t economic_owner_pool = std::max<int64_t>(saturating_add(
            owner_pool,
            scale_fact(group.last_in_kind_livelihood_value), sat),
            realized_survival_output_value);
        // Per-owner daily disposable signal for mobility / UI.
        return (economic_owner_pool / std::max<int64_t>(1, days)) /
            std::max<int64_t>(1, owner_jobs);
    }
    const int64_t operating_income = saturating_sub(
        quoted_revenue,
        saturating_add(saturating_add(
            input_cost, wage_cost, sat), maintenance_cost, sat), sat);
    const int32_t business_rate = frozen_tax_rate(
        group.cell, CountryApi::TAX_BUSINESS, group.type_id);
    const int64_t eligible_business_cost = saturating_add(
        saturating_add(input_cost, wage_cost, sat), maintenance_cost, sat);
    const int64_t business_base = business_rate < 0
        ? eligible_business_cost
        : std::max<int64_t>(0, quoted_revenue);
    const int64_t absolute_building_days = saturating_mul(
        group.count, std::max<int64_t>(1, days), sat);
    const int64_t business_transfer = observed_capacity
        ? saturating_sub(scale_fact(group.last_business_subsidy_received),
                         scale_fact(group.last_business_tax_paid), sat)
        : expected_resolved_fiscal_transfer(
            group.cell, CountryApi::TAX_BUSINESS, group.type_id,
            business_base, absolute_building_days, sat);
    const int64_t taxable_income = std::max<int64_t>(0, saturating_sub(
        operating_income, std::max<int64_t>(0, business_transfer), sat));
    const int32_t profession = group.owner_signature_id >= 0 &&
            group.owner_signature_id < static_cast<int32_t>(_signatures.size())
        ? _signatures[group.owner_signature_id].profession_id : -1;
    const int32_t income_rate = frozen_tax_rate(
        group.cell, CountryApi::TAX_INCOME, profession);
    int64_t income_subsidy_base = taxable_income;
    if (income_rate < 0) {
        income_subsidy_base = std::max(
            income_subsidy_base, owner_living_cost);
    }
    const int64_t absolute_owner_days = saturating_mul(
        owner_jobs, std::max<int64_t>(1, days), sat);
    const int64_t income_transfer = expected_resolved_fiscal_transfer(
        group.cell, CountryApi::TAX_INCOME, profession,
        income_subsidy_base, absolute_owner_days, sat);
    const int64_t owner_pool = std::max<int64_t>(0, saturating_sub(
        saturating_sub(operating_income, business_transfer, sat),
        income_transfer, sat));
    const int64_t economic_owner_pool = std::max<int64_t>(saturating_add(
        owner_pool, scale_fact(group.last_in_kind_livelihood_value), sat),
        realized_survival_output_value);
    // Per-owner daily signal (group pool ÷ attached owner people ÷ days).
    return (economic_owner_pool / std::max<int64_t>(1, days)) /
        std::max<int64_t>(1, owner_jobs);
}

} // namespace pk
