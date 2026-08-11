#include "economy_runtime.h"
#include "country_runtime.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <iterator>
#include <limits>

namespace pk {

namespace {
using Clock = std::chrono::steady_clock;

constexpr int64_t PRODUCER_SUPPORT_PRICE_DENOMINATOR = 5;
constexpr int32_t PRICE_NUMERIC_GUARD_MIN = 1;
constexpr int32_t PRICE_NUMERIC_GUARD_MAX = std::numeric_limits<int32_t>::max();

double elapsed_ms(const Clock::time_point &start) {
    return std::chrono::duration<double, std::milli>(Clock::now() - start).count();
}
} // namespace

int64_t NativeEconomyRuntime::production_climate_capacity_q16(
        const BuildingType &type, int32_t cell,
        int64_t *temperature_fit_q16, int64_t *water_fit_q16,
        int64_t &saturation_count) const {
    int64_t temperature_fit = Q16_ONE;
    int64_t water_fit = Q16_ONE;
    if (type.production_climate_profile_id < 0) {
        if (temperature_fit_q16 != nullptr) *temperature_fit_q16 = temperature_fit;
        if (water_fit_q16 != nullptr) *water_fit_q16 = water_fit;
        return Q16_ONE;
    }
    const ProductionClimateProfile &climate = _production_climate_profiles[
        static_cast<size_t>(type.production_climate_profile_id)];
    const EnvironmentSample environment = environment_sample_for_cell(cell);
    auto fit_q16 = [&](int32_t signal, int32_t optimum,
                       int32_t tolerance) -> int64_t {
        const int64_t delta = std::llabs(
            static_cast<int64_t>(signal) - optimum);
        return std::clamp<int64_t>(Q16_ONE - mul_div_sat(
            delta, Q16_ONE, tolerance, saturation_count), 0, Q16_ONE);
    };
    temperature_fit = fit_q16(
        environment.temperature_30d_q16, climate.temperature_opt_q16,
        climate.temperature_tolerance_q16);
    water_fit = fit_q16(
        environment.plant_available_water_q16, climate.water_opt_q16,
        climate.water_tolerance_q16);
    if (temperature_fit_q16 != nullptr) *temperature_fit_q16 = temperature_fit;
    if (water_fit_q16 != nullptr) *water_fit_q16 = water_fit;
    const int64_t raw = std::min(temperature_fit, water_fit);
    const int64_t bounded = std::max<int64_t>(climate.floor_q16, raw);
    int64_t loss_factor_q16 = Q16_ONE;
    const int32_t country = cell >= 0 &&
            cell < static_cast<int32_t>(_epoch_cell_country.size())
        ? _epoch_cell_country[static_cast<size_t>(cell)] : -1;
    if (country >= 0 && country < _epoch_country_count) {
        const bool temperature_limiting = temperature_fit <= water_fit;
        const size_t adaptation = temperature_limiting
            ? (environment.temperature_30d_q16 < climate.temperature_opt_q16 ? 2U : 3U)
            : (environment.plant_available_water_q16 < climate.water_opt_q16 ? 0U : 1U);
        const size_t index = static_cast<size_t>(country) * 4U + adaptation;
        if (index < _epoch_country_climate_loss_factor_q16.size())
            loss_factor_q16 = _epoch_country_climate_loss_factor_q16[index];
    }
    const int64_t exposed_loss = mul_div_sat(climate.exposure_q16,
        Q16_ONE - bounded, Q16_ONE, saturation_count);
    const int64_t adapted_loss = mul_div_sat(exposed_loss, loss_factor_q16,
        Q16_ONE, saturation_count);
    return std::clamp<int64_t>(Q16_ONE - adapted_loss, 0, Q16_ONE);
}

void NativeEconomyRuntime::prepare_group_climate_capacity(
        BuildingGroup &group, const BuildingType &type) {
    group.last_climate_capacity_q16 = production_climate_capacity_q16(
        type, group.cell, &group.last_temperature_fit_q16,
        &group.last_water_fit_q16, _saturation_count);
    group.last_climate_lost_output = 0;
}

bool NativeEconomyRuntime::building_available(int32_t cell, int32_t type_id,
                                              bool frozen) const {
    if (frozen && _epoch_active && cell >= 0 && cell < _cell_count &&
        type_id >= 0 && type_id < static_cast<int32_t>(_building_types.size()) &&
        _epoch_cell_country.size() == static_cast<size_t>(_cell_count)) {
        const int32_t country = _epoch_cell_country[static_cast<size_t>(cell)];
        const size_t index = static_cast<size_t>(country) * _building_types.size() +
            static_cast<size_t>(type_id);
        return country >= 0 && country < _epoch_country_count &&
            index < _epoch_country_building_available.size() &&
            _epoch_country_building_available[index] != 0;
    }
    return type_id >= 0 &&
        type_id + 1 < static_cast<int32_t>(_building_technology_offsets.size()) &&
        cell_has_requirements(cell, _building_technology_offsets[type_id],
            _building_technology_offsets[type_id + 1],
            _building_required_technologies, frozen) &&
        type_id + 1 < static_cast<int32_t>(_building_all_technology_offsets.size()) &&
        cell_has_all_requirements(cell, _building_all_technology_offsets[type_id],
            _building_all_technology_offsets[type_id + 1],
            _building_all_required_technologies, frozen);
}

bool NativeEconomyRuntime::building_constructible(int32_t cell, int32_t type_id,
                                                  bool frozen) const {
    if (!building_available(cell, type_id, frozen) || type_id < 0 ||
        type_id >= static_cast<int32_t>(_building_upgrade_family_indices.size()) ||
        type_id >= static_cast<int32_t>(_building_upgrade_tiers.size())) return false;
    const int32_t family = _building_upgrade_family_indices[type_id];
    if (family < 0) return true;
    const int32_t tier = _building_upgrade_tiers[type_id];
    for (int32_t candidate = 0;
         candidate < static_cast<int32_t>(_building_upgrade_family_indices.size());
         ++candidate) {
        if (_building_upgrade_family_indices[candidate] == family &&
            _building_upgrade_tiers[candidate] > tier &&
            building_available(cell, candidate, frozen)) return false;
    }
    return true;
}

bool NativeEconomyRuntime::run_building_production_cell(
        int32_t cell, ProductionResult &result, std::string &error) {
    ProductionResult *previous_sink = _production_result_sink;
    _production_result_sink = &result;
    int64_t &_saturation_count = result.saturation_count;
    int64_t &_processed_building_groups = result.processed_building_groups;
    int64_t &_climate_profiled_building_groups =
        result.climate_profiled_building_groups;
    int64_t &_climate_limited_building_groups =
        result.climate_limited_building_groups;
    int64_t &_climate_capacity_sum_q16 = result.climate_capacity_sum_q16;
    int64_t &_merchant_procurement_budget = result.merchant_procurement_budget;
    int64_t &_merchant_procurement_opportunity = result.merchant_procurement_opportunity;
    int64_t &_merchant_procurement_allocated = result.merchant_procurement_allocated;
    int64_t &_merchant_procurement_unspent_allocated = result.merchant_procurement_unspent_allocated;
    int64_t &_merchant_procurement_reserved = result.merchant_procurement_reserved;
    int64_t &_merchant_procurement_spent = result.merchant_procurement_spent;
    int64_t &_merchant_procurement_retail_value =
        result.merchant_procurement_retail_value;
    int64_t &_merchant_procurement_factor_weighted_cash_q16 =
        result.merchant_procurement_factor_weighted_cash_q16;
    int64_t &_merchant_survival_procurement_required =
        result.merchant_survival_procurement_required;
    int64_t &_merchant_survival_procurement_allocated =
        result.merchant_survival_procurement_allocated;
    int64_t &_merchant_input_procurement_required =
        result.merchant_input_procurement_required;
    int64_t &_merchant_input_procurement_allocated =
        result.merchant_input_procurement_allocated;
    int64_t &_owner_working_capital_allocated = result.owner_working_capital_allocated;
    int64_t &_working_capital_scale_error_bound_q16 =
        result.working_capital_scale_error_bound_q16;
    int64_t &_building_resource_capacity_checks =
        result.building_resource_capacity_checks;
    int64_t &_building_resource_limited_groups = result.building_resource_limited_groups;
    int64_t &_building_resource_capacity_limited_groups =
        result.building_resource_capacity_limited_groups;
    int64_t &_building_resource_generated = result.building_resource_generated;
    int64_t &_building_resource_consumed = result.building_resource_consumed;
    int64_t &_production_inputs_consumed = result.production_inputs_consumed;
    int64_t &_production_output_stock = result.production_output_stock;
    int64_t &_production_output_discarded = result.production_output_discarded;
    int64_t &_production_output_supported = result.production_output_supported;
    int64_t &_producer_revenue = result.producer_revenue;
    int64_t &_producer_support_money_issued = result.producer_support_money_issued;
    int64_t &_explicit_money_mint = result.explicit_money_mint;
    int64_t &_bullion_money_issued = result.bullion_money_issued;
    int64_t &_bullion_stock_consumed = result.bullion_stock_consumed;
    int64_t &_gold_accepted = result.gold_accepted;
    int64_t &_silver_accepted = result.silver_accepted;
    int64_t &_gold_money_issued = result.gold_money_issued;
    int64_t &_silver_money_issued = result.silver_money_issued;
    int64_t &_cycle_flow_produced = result.cycle_flow_produced;
    int64_t &_cycle_flow_consumed = result.cycle_flow_consumed;
    int64_t &_cycle_flow_discarded = result.cycle_flow_discarded;
    int64_t &_building_wages_paid = result.building_wages_paid;
    int64_t &_building_wages_unpaid = result.building_wages_unpaid;
    int64_t &_building_base_wages_paid = result.building_base_wages_paid;
    int64_t &_building_base_wages_due = result.building_base_wages_due;
    int64_t &_building_bonus_paid = result.building_bonus_paid;
    int64_t &_building_bonus_due = result.building_bonus_due;
    int64_t &_wage_suspended_building_groups = result.wage_suspended_building_groups;
    int64_t &_desired_business_demand = result.desired_business_demand;
    int64_t &_funded_business_demand = result.funded_business_demand;
    int64_t &_unfunded_business_demand = result.unfunded_business_demand;
    int64_t &_market_signal_updates = result.market_signal_updates;
    double &_market_signal_ms = result.market_signal_ms;
    std::vector<OwnerRetainedOutput> &_owner_retained_outputs = result.retained_outputs;
    const int64_t cell_procurement_paid_before = _merchant_procurement_spent;
    const int64_t cell_procurement_retail_before =
        _merchant_procurement_retail_value;
    const int64_t cell_procurement_factor_before =
        _merchant_procurement_factor_weighted_cash_q16;
    const int64_t cell_credit_drawn_before = result.merchant_credit_drawn;
    struct Offer {
        int32_t good = -1;
        int32_t owner_slot = -1;
        int32_t group = -1;
        int64_t qty = 0;
        int64_t retained = 0;
        int64_t sellable = 0;
        int64_t merchant_sold = 0;
        int64_t supported = 0;
        int64_t support_paid = 0;
    };
    thread_local std::vector<Offer> offers;
    thread_local std::vector<int64_t> operation_receipts_by_group;
    thread_local std::vector<int64_t> business_tax_by_group;
    thread_local std::vector<int64_t> business_transfer_by_group;
    offers.clear();
    const int32_t market = _market.cell_to_market[cell];
    const int32_t begin = _building_cell_offsets.size() == static_cast<size_t>(_cell_count + 1)
        ? _building_cell_offsets[cell] : 0;
    const int32_t end = _building_cell_offsets.size() == static_cast<size_t>(_cell_count + 1)
        ? _building_cell_offsets[cell + 1] : 0;
    const bool income_tax_active =
        (_epoch_active_tax_mask & static_cast<uint8_t>(
            1U << NativeCountryRuntime::TAX_INCOME)) != 0;
    const bool business_tax_active =
        (_epoch_active_tax_mask & static_cast<uint8_t>(
            1U << NativeCountryRuntime::TAX_BUSINESS)) != 0;
    const bool owner_operation_tax_active =
        income_tax_active || business_tax_active;
    if (owner_operation_tax_active)
        operation_receipts_by_group.assign(
            static_cast<size_t>(std::max(0, end - begin)), 0);
    else
        operation_receipts_by_group.clear();
    if (business_tax_active) {
        business_tax_by_group.assign(
            static_cast<size_t>(std::max(0, end - begin)), 0);
        business_transfer_by_group.assign(
            static_cast<size_t>(std::max(0, end - begin)), 0);
    } else {
        business_tax_by_group.clear();
        business_transfer_by_group.clear();
    }
    int64_t merchant_opening_cash = 0;
    for (int32_t k = _merchant_offsets[cell]; k < _merchant_offsets[cell + 1]; ++k) {
        merchant_opening_cash = saturating_add(merchant_opening_cash,
            std::max<int64_t>(0, _population.funds[_merchant_slots[k]]), _saturation_count);
    }
    int64_t merchant_procurement_remaining = mul_div_sat(
        merchant_opening_cash, Q16_ONE - _merchant_procurement_cash_reserve_q16,
        Q16_ONE, _saturation_count);
    _merchant_procurement_budget = saturating_add(
        _merchant_procurement_budget, merchant_procurement_remaining, _saturation_count);
    _merchant_procurement_reserved = saturating_add(
        _merchant_procurement_reserved,
        merchant_opening_cash - merchant_procurement_remaining, _saturation_count);
    const bool trace_detail = trace_detail_for_cell(cell);
    thread_local std::vector<int32_t> trace_cell_slots;
    thread_local std::vector<int64_t> trace_cell_funds;
    thread_local std::vector<int64_t> trace_cell_income;
    thread_local std::vector<int64_t> trace_cell_expense;
    thread_local std::vector<int64_t> trace_market_stock;
    thread_local std::vector<int64_t> trace_resource_delta;
    trace_cell_slots.clear(); trace_cell_funds.clear(); trace_cell_income.clear();
    trace_cell_expense.clear(); trace_market_stock.clear(); trace_resource_delta.clear();
    if (trace_detail) {
        _population.for_each_in_cell(cell, [&](int32_t slot) {
            trace_cell_slots.push_back(slot);
            trace_cell_funds.push_back(_population.funds[slot]);
            trace_cell_income.push_back(_population.epoch_income[slot]);
            trace_cell_expense.push_back(_population.epoch_expense[slot]);
        });
        trace_market_stock.resize(_market.good_count);
        for (int32_t good = 0; good < _market.good_count; ++good) {
            trace_market_stock[good] = _market.stock[_market.index(market, good)];
        }
        trace_resource_delta.resize(_resource_ids.size());
        for (size_t resource = 0; resource < _resource_ids.size(); ++resource) {
            trace_resource_delta[resource] =
                _resource_deltas[resource * static_cast<size_t>(_cell_count) + cell];
        }
    }
    thread_local std::vector<BuildingGroup> trace_before;
    trace_before.clear();
    if (trace_detail) {
        trace_before.reserve(static_cast<size_t>(std::max(0, end - begin)));
        for (int32_t g = begin; g < end; ++g) trace_before.push_back(_buildings[g]);
    }
    auto produces_cycle_flow = [&](const BuildingType &type) {
        for (int32_t i = 0; i < type.output_count; ++i) {
            const int32_t good = _building_outputs[type.output_begin + i].good_id;
            if (_good_storage_modes[good] == 1) return true;
        }
        return false;
    };
    for (int32_t g = begin; g < end; ++g) {
        BuildingGroup &group = _buildings[g];
        if (group.cell != cell || group.count <= 0) continue;
        group.last_capacity_q16 = 0;
        group.last_input = group.last_output = group.last_sold = group.last_discarded = 0;
        group.last_resource = group.last_revenue = 0;
        group.last_resource_generated = 0;
        group.last_input_cost = group.last_wages_paid = group.last_wages_due = 0;
        group.last_operating_cost = 0;
        group.purchase_intent_capacity_q16 = 0;
        group.last_base_wages_paid = group.last_base_wages_due = 0;
        group.last_bonus_paid = group.last_bonus_due = 0;
        group.wage_suspended = 0;
        const BuildingType &type = _building_types[group.type_id];
        prepare_group_climate_capacity(group, type);
        for (int32_t input = 0; input < type.input_count; ++input) {
            _building_last_input_selected_goods[
                group.last_input_selection_begin + input] = -1;
        }
        if (!building_available(cell, group.type_id, true)) continue;
        for (int32_t r = 0; r < type.employee_count; ++r) {
            const int32_t role_index = group.employee_fill_begin + r;
            const int64_t wage_due = saturating_mul(
                saturating_mul(_building_employee_filled[role_index],
                               _building_role_contract_wage[role_index],
                               _saturation_count),
                std::max(1, _epoch_days), _saturation_count);
            _building_role_base_wage_due[role_index] = wage_due;
            _building_role_base_wage_paid[role_index] = 0;
            _building_role_bonus_due[role_index] = 0;
            _building_role_bonus_paid[role_index] = 0;
            group.last_base_wages_due = saturating_add(
                group.last_base_wages_due, wage_due, _saturation_count);
        }
        group.last_wages_due = group.last_base_wages_due;
    }
    thread_local std::vector<int32_t> payroll_owners;
    payroll_owners.clear();
    for (int32_t g = begin; g < end; ++g) {
        if (_buildings[g].count > 0 && building_available(cell, _buildings[g].type_id, true))
            payroll_owners.push_back(_buildings[g].owner_signature_id);
    }
    std::sort(payroll_owners.begin(), payroll_owners.end());
    payroll_owners.erase(std::unique(payroll_owners.begin(), payroll_owners.end()),
                         payroll_owners.end());
    thread_local std::vector<int32_t> retention_owner_slots;
    thread_local std::vector<int64_t> retention_targets;
    thread_local std::vector<int64_t> retention_used;
    thread_local std::vector<int32_t> retention_lane_by_owner_good;
    thread_local std::vector<uint32_t> retention_lane_stamp;
    thread_local std::vector<int32_t> retention_owner_by_signature;
    thread_local std::vector<uint32_t> retention_signature_stamp;
    thread_local std::vector<int32_t> retention_owner_by_slot;
    thread_local std::vector<uint32_t> retention_slot_stamp;
    thread_local uint32_t retention_generation = 0;
    thread_local std::vector<int64_t> retention_food_targets;
    thread_local std::vector<int64_t> retention_food_used;
    thread_local std::vector<uint8_t> retention_food_staple_route;
    thread_local std::vector<int64_t> retention_clothing_targets;
    thread_local std::vector<int64_t> retention_clothing_used;
    thread_local std::vector<uint8_t> retention_produces_survival_food;
    thread_local std::vector<uint8_t> retention_produces_staple_food;
    thread_local std::vector<int64_t> retention_variant_scores;
    thread_local std::vector<int64_t> retention_variant_prices;
    thread_local std::vector<int64_t> retention_need_score_sums;
    thread_local std::vector<int64_t> retention_need_composites;
    thread_local std::vector<int64_t> retention_need_environment;
    ++retention_generation;
    if (retention_generation == 0) {
        std::fill(retention_lane_stamp.begin(), retention_lane_stamp.end(), 0);
        std::fill(retention_signature_stamp.begin(), retention_signature_stamp.end(), 0);
        std::fill(retention_slot_stamp.begin(), retention_slot_stamp.end(), 0);
        retention_generation = 1;
    }
    const size_t retention_dense_size = payroll_owners.size() *
        static_cast<size_t>(_market.good_count);
    if (retention_lane_by_owner_good.size() < retention_dense_size) {
        retention_lane_by_owner_good.resize(retention_dense_size, -1);
        retention_lane_stamp.resize(retention_dense_size, 0);
    }
    if (retention_owner_by_signature.size() < _signatures.size()) {
        retention_owner_by_signature.resize(_signatures.size(), -1);
        retention_signature_stamp.resize(_signatures.size(), 0);
    }
    if (retention_owner_by_slot.size() < _population.active.size()) {
        retention_owner_by_slot.resize(_population.active.size(), -1);
        retention_slot_stamp.resize(_population.active.size(), 0);
    }
    for (size_t owner = 0; owner < payroll_owners.size(); ++owner) {
        const int32_t signature = payroll_owners[owner];
        if (signature < 0 || signature >= static_cast<int32_t>(_signatures.size())) continue;
        retention_owner_by_signature[signature] = static_cast<int32_t>(owner);
        retention_signature_stamp[signature] = retention_generation;
    }
    auto retention_lane = [&](size_t owner, int32_t good) -> int32_t {
        if (owner >= payroll_owners.size() || good < 0 || good >= _market.good_count)
            return -1;
        const size_t key = owner * static_cast<size_t>(_market.good_count) +
            static_cast<size_t>(good);
        return retention_lane_stamp[key] == retention_generation
            ? retention_lane_by_owner_good[key] : -1;
    };
    auto ensure_retention_lane = [&](size_t owner, int32_t good) -> int32_t {
        const size_t key = owner * static_cast<size_t>(_market.good_count) +
            static_cast<size_t>(good);
        if (retention_lane_stamp[key] == retention_generation)
            return retention_lane_by_owner_good[key];
        const int32_t lane = static_cast<int32_t>(retention_targets.size());
        retention_lane_by_owner_good[key] = lane;
        retention_lane_stamp[key] = retention_generation;
        retention_targets.push_back(0);
        retention_used.push_back(0);
        return lane;
    };
    retention_owner_slots.assign(payroll_owners.size(), -1);
    retention_targets.clear();
    retention_used.clear();
    retention_food_targets.assign(payroll_owners.size(), 0);
    retention_food_used.assign(payroll_owners.size(), 0);
    retention_food_staple_route.assign(payroll_owners.size(), uint8_t{0});
    retention_clothing_targets.assign(payroll_owners.size(), 0);
    retention_clothing_used.assign(payroll_owners.size(), 0);
    retention_produces_survival_food.assign(payroll_owners.size(), uint8_t{0});
    retention_produces_staple_food.assign(payroll_owners.size(), uint8_t{0});
    for (int32_t g = begin; g < end; ++g) {
        const BuildingGroup &group = _buildings[g];
        if (group.cell != cell || group.count <= 0) continue;
        if (group.owner_signature_id < 0 ||
            group.owner_signature_id >= static_cast<int32_t>(_signatures.size()) ||
            retention_signature_stamp[group.owner_signature_id] != retention_generation)
            continue;
        const size_t owner_index = static_cast<size_t>(
            retention_owner_by_signature[group.owner_signature_id]);
        const BuildingType &type = _building_types[group.type_id];
        for (int32_t i = 0; i < type.output_count; ++i) {
            const int32_t good = _building_outputs[type.output_begin + i].good_id;
            ensure_retention_lane(owner_index, good);
            if (_survival_food_good_mask[good] != 0) {
                retention_produces_survival_food[owner_index] = 1;
                if (_survival_staple_good_mask[good] != 0)
                    retention_produces_staple_food[owner_index] = 1;
            }
        }
    }
    const EnvironmentSample retention_environment = environment_sample_for_cell(cell);
    build_demand_basis_cached(cell, market, retention_environment,
                       retention_variant_scores, retention_variant_prices,
                       retention_need_score_sums, retention_need_composites,
                       retention_need_environment, _saturation_count);
    for (size_t owner = 0; owner < payroll_owners.size(); ++owner) {
        const int32_t owner_slot = find_cohort_slot(cell, payroll_owners[owner]);
        retention_owner_slots[owner] = owner_slot;
        if (owner_slot < 0) continue;
        retention_owner_by_slot[owner_slot] = static_cast<int32_t>(owner);
        retention_slot_stamp[owner_slot] = retention_generation;
        const uint32_t signature_id = _population.signature_id[owner_slot];
        if (signature_id >= _signatures.size()) continue;
        const Signature &signature = _signatures[signature_id];
        const Plan &plan = _plans[signature.plan_id];
        const int64_t population = std::max<int64_t>(0, _population.population[owner_slot]);
        const bool produces_survival_food =
            retention_produces_survival_food[owner] != 0;
        const bool produces_staple_food =
            retention_produces_staple_food[owner] != 0;
        const int64_t temperature_exposure_q16 = std::clamp<int64_t>(
            (Q16_ONE / 2 - retention_environment.temperature_q16) * 2,
            0, Q16_ONE);
        const int64_t cold_exposure_q16 = std::max<int64_t>(
            temperature_exposure_q16,
            std::clamp<int64_t>(retention_environment.snow_q16, 0, Q16_ONE));
        int64_t clothing_retention_q16 = 0;
        if (cold_exposure_q16 > Q16_ONE - _survival_production_target_q16) {
            clothing_retention_q16 = Q16_ONE - mul_div_sat(
                Q16_ONE - _survival_production_target_q16,
                Q16_ONE, cold_exposure_q16, _saturation_count);
        }
        int64_t survival_food_desired = 0;
        int64_t produced_food_desired = 0;
        for (int32_t n = 0; n < plan.need_count; ++n) {
            const int32_t need_index = plan.need_begin + n;
            const Need &need = _needs[need_index];
            const int32_t stable_need = need.stable_id;
            const bool survival_food = stable_need >= 0 &&
                stable_need < static_cast<int32_t>(
                    _survival_food_need_mask.size()) &&
                _survival_food_need_mask[stable_need] != 0;
            if (survival_food) {
                const int64_t food_desired = survival_required_units(
                    owner_slot, stable_need, _epoch_days,
                    retention_environment, _saturation_count);
                survival_food_desired = saturating_add(
                    survival_food_desired, food_desired,
                    _saturation_count);
            }
            const bool survival_clothing =
                stable_need == _survival_clothing_need_stable_id &&
                population > 0 && clothing_retention_q16 > 0;
            int64_t desired = survival_food
                ? survival_required_units(owner_slot, stable_need, _epoch_days,
                    retention_environment, _saturation_count)
                : 0;
            if (survival_clothing) {
                const int64_t full_desired = survival_required_units(
                    owner_slot, stable_need, _epoch_days,
                    retention_environment, _saturation_count);
                desired = std::max<int64_t>(desired, mul_div_sat(
                    full_desired, clothing_retention_q16, Q16_ONE,
                    _saturation_count));
                retention_clothing_targets[owner] = std::max<int64_t>(
                    retention_clothing_targets[owner], desired);
            }
            if (!survival_food && !survival_clothing) continue;
            std::array<int64_t, MAX_VARIANTS_PER_NEED>
                owner_variant_scores{};
            int64_t score_sum = 0;
            for (int32_t v = 0; v < need.variant_count; ++v) {
                const int32_t variant_id = need.variant_begin + v;
                owner_variant_scores[v] = std::max<int64_t>(0, mul_div_sat(
                    retention_variant_scores[variant_id],
                    family_variant_preference_factor_q16(
                        owner_slot, variant_id, _saturation_count),
                    Q16_ONE, _saturation_count));
                score_sum = saturating_add(
                    score_sum, owner_variant_scores[v], _saturation_count);
            }
            if (desired <= 0 || score_sum <= 0) continue;
            int64_t score_prefix = 0;
            int64_t allocated = 0;
            for (int32_t v = 0; v < need.variant_count; ++v) {
                const int32_t variant_id = need.variant_begin + v;
                const VariantChoice &variant = _variants[variant_id];
                score_prefix = saturating_add(
                    score_prefix, owner_variant_scores[v], _saturation_count);
                const int64_t next = mul_div_sat(
                    desired, score_prefix, score_sum, _saturation_count);
                const int64_t units = std::max<int64_t>(0, next - allocated);
                allocated = next;
                if (units <= 0) continue;
                // Composite variant components are retained only when the owner produces them.
                // Other components continue through normal market procurement.
                for (int32_t c = 0; c < variant.component_count; ++c) {
                    const NeedComponent &component = _components[
                        variant.component_begin + c];
                    const int32_t lane = retention_lane(owner, component.good_id);
                    if (lane < 0) continue;
                    const int64_t quantity = mul_div_sat(
                        units, component.qty_per_need, GOODS_SCALE,
                        _saturation_count);
                    if (survival_food) {
                        produced_food_desired = saturating_add(
                            produced_food_desired, quantity, _saturation_count);
                    } else {
                        retention_targets[lane] = saturating_add(
                            retention_targets[lane], quantity, _saturation_count);
                    }
                }
            }
        }
        if (produces_survival_food && population > 0) {
            // Staple output may satisfy the other survival-food needs through
            // emergency substitution, so retain against the complete healthy
            // food basket rather than the staple row alone.
            const int64_t desired = survival_food_desired;
            const int64_t numerator = saturating_add(saturating_mul(
                desired, _survival_production_target_q16,
                _saturation_count), Q16_ONE - 1, _saturation_count);
            retention_food_targets[owner] = std::max<int64_t>(
                numerator / Q16_ONE, produced_food_desired);
            retention_food_staple_route[owner] = produces_staple_food ? 1 : 0;
        }
    }
    const bool has_cell_signals =
        _market_signals.cell_offsets.size() == static_cast<size_t>(_cell_count + 1);
    const int32_t cell_signal_begin = has_cell_signals
        ? _market_signals.cell_offsets[cell] : 0;
    const int32_t cell_signal_end = has_cell_signals
        ? _market_signals.cell_offsets[cell + 1] : 0;
    const size_t cell_signal_count = static_cast<size_t>(
        std::max(0, cell_signal_end - cell_signal_begin));
    thread_local std::vector<int64_t> retained_by_signal;
    retained_by_signal.assign(cell_signal_count, 0);
    auto physical_input_quantity = [&](int64_t effective,
                                       const InputCandidate &candidate) -> int64_t {
        int64_t physical = mul_div_sat(
            effective, Q16_ONE, candidate.efficiency_q16, _saturation_count);
        if (mul_div_sat(physical, candidate.efficiency_q16, Q16_ONE,
                        _saturation_count) < effective)
            physical = saturating_add(physical, 1, _saturation_count);
        return physical;
    };
    auto soft_input_bound_q16 = [&](const ProductionInput &input,
                                    int64_t raw_capacity_q16) -> int64_t {
        const int64_t required = std::clamp<int64_t>(input.required_q16, 0, Q16_ONE);
        if (required <= 0) return Q16_ONE;
        raw_capacity_q16 = std::clamp<int64_t>(raw_capacity_q16, 0, Q16_ONE);
        return std::clamp<int64_t>(
            Q16_ONE - required + mul_div_sat(
                raw_capacity_q16, required, Q16_ONE, _saturation_count),
            0, Q16_ONE);
    };
    auto input_purchase_scale_q16 = [&](const ProductionInput &input,
                                        int64_t output_scale_q16) -> int64_t {
        const int64_t required = std::clamp<int64_t>(input.required_q16, 0, Q16_ONE);
        if (required <= 0) return 0;
        const int64_t floor_q16 = Q16_ONE - required;
        output_scale_q16 = std::clamp<int64_t>(output_scale_q16, 0, Q16_ONE);
        if (output_scale_q16 <= floor_q16) return 0;
        const int64_t delta = output_scale_q16 - floor_q16;
        return std::min<int64_t>(
            Q16_ONE, mul_div_sat(delta, Q16_ONE, required, _saturation_count));
    };
    auto scaled_input_quantity = [&](int64_t full_physical,
                                     int64_t purchase_scale_q16) -> int64_t {
        purchase_scale_q16 = std::clamp<int64_t>(purchase_scale_q16, 0, Q16_ONE);
        if (full_physical <= 0 || purchase_scale_q16 <= 0) return 0;
        const int64_t numerator = saturating_mul(
            full_physical, purchase_scale_q16, _saturation_count);
        return std::max<int64_t>(1, saturating_add(
            numerator, Q16_ONE - 1, _saturation_count) / Q16_ONE);
    };
    auto select_input_candidate = [&](const ProductionInput &input,
                                      bool require_stock,
                                      int64_t effective_required) -> int32_t {
        int32_t best = -1;
        int64_t best_capacity_q16 = -1;
        int64_t best_effective_price = std::numeric_limits<int64_t>::max();
        for (int32_t c = input.candidate_begin;
             c < input.candidate_begin + input.candidate_count; ++c) {
            const InputCandidate &candidate = _building_input_candidates[c];
            if (!good_market_available(cell, candidate.good_id, true)) continue;
            if (require_stock &&
                _market.stock[_market.index(market, candidate.good_id)] <= 0) continue;
            int64_t capacity_q16 = Q16_ONE;
            if (require_stock && effective_required > 0) {
                const int64_t physical_required = physical_input_quantity(
                    effective_required, candidate);
                capacity_q16 = physical_required > 0 ? std::min<int64_t>(
                    Q16_ONE, mul_div_sat(
                        _market.stock[_market.index(market, candidate.good_id)],
                        Q16_ONE, physical_required, _saturation_count)) : Q16_ONE;
            }
            const int64_t effective_price = mul_div_sat(
                _market.price[_market.index(market, candidate.good_id)], Q16_ONE,
                candidate.efficiency_q16, _saturation_count);
            if (capacity_q16 > best_capacity_q16 ||
                (capacity_q16 == best_capacity_q16 &&
                 (effective_price < best_effective_price ||
                  (effective_price == best_effective_price &&
                   (best < 0 || candidate.good_id <
                    _building_input_candidates[best].good_id))))) {
                best = c;
                best_capacity_q16 = capacity_q16;
                best_effective_price = effective_price;
            }
        }
        return best;
    };
    auto desired_scale_for_group = [&](const BuildingGroup &group,
                                       const BuildingType &type,
                                       bool apply_climate) -> int64_t {
        const int64_t owner_demand = saturating_mul(
            group.count, type.owner_slots_per_building, _saturation_count);
        int64_t scale = owner_demand > 0 ? std::min<int64_t>(Q16_ONE, mul_div_sat(
            group.filled_owner, Q16_ONE, owner_demand, _saturation_count)) : 0;
        const int32_t group_index = static_cast<int32_t>(
            &group - _buildings.data());
        const int64_t planned_capacity_q16 = !apply_climate && group_index >= 0 &&
                group_index < static_cast<int32_t>(
                    _building_planned_capacity_before_climate_q16.size())
            ? _building_planned_capacity_before_climate_q16[group_index]
            : group.planned_utilization_q16;
        scale = std::min<int64_t>(scale, planned_capacity_q16);
        for (int32_t r = 0; r < type.employee_count; ++r) {
            const JobRole &role = _building_employee_roles[type.employee_begin + r];
            const int64_t demand = saturating_mul(
                group.count, role.slots_per_building, _saturation_count);
            const int64_t filled = _building_employee_filled[group.employee_fill_begin + r];
            scale = std::min<int64_t>(scale, demand > 0 ? std::min<int64_t>(
                Q16_ONE, mul_div_sat(filled, Q16_ONE, demand, _saturation_count)) : Q16_ONE);
        }
        const int64_t building_days = saturating_mul(
            group.count, std::max(1, _epoch_days), _saturation_count);
        for (int32_t i = 0; i < type.input_count; ++i) {
            const ProductionInput &item = _building_inputs[type.input_begin + i];
            if (select_input_candidate(item, false, saturating_mul(
                    building_days, item.quantity, _saturation_count)) < 0) {
                scale = std::min<int64_t>(scale, soft_input_bound_q16(item, 0));
            }
        }
        if (apply_climate) {
            scale = std::min<int64_t>(scale, group.last_climate_capacity_q16);
        }
        return std::clamp<int64_t>(scale, 0, Q16_ONE);
    };
    thread_local std::vector<int32_t> quoted_input_candidates;
    thread_local std::vector<int64_t> quoted_input_quantities;
    thread_local std::vector<std::pair<int32_t, int64_t>> quoted_good_totals;
    auto quote_group_inputs = [&](const BuildingGroup &group,
                                  const BuildingType &type,
                                  int64_t output_scale_q16,
                                  bool require_stock,
                                  std::vector<int32_t> *selected_out,
                                  std::vector<int64_t> *quantities_out) -> int64_t {
        int64_t total_cost = 0;
        const int64_t building_days = saturating_mul(
            group.count, std::max(1, _epoch_days), _saturation_count);
        output_scale_q16 = std::clamp<int64_t>(output_scale_q16, 0, Q16_ONE);
        quoted_good_totals.clear();
        if (selected_out != nullptr) selected_out->assign(type.input_count, -1);
        if (quantities_out != nullptr) quantities_out->assign(type.input_count, 0);
        for (int32_t input_index = 0; input_index < type.input_count; ++input_index) {
            const ProductionInput &item = _building_inputs[type.input_begin + input_index];
            const int64_t purchase_scale_q16 = input_purchase_scale_q16(
                item, output_scale_q16);
            if (purchase_scale_q16 <= 0) continue;
            const int64_t effective = saturating_mul(
                building_days, item.quantity, _saturation_count);
            const int32_t selected = select_input_candidate(item, require_stock, effective);
            if (selected < 0) return std::numeric_limits<int64_t>::max();
            const InputCandidate &candidate = _building_input_candidates[selected];
            const int64_t qty = scaled_input_quantity(
                physical_input_quantity(effective, candidate), purchase_scale_q16);
            if (selected_out != nullptr) (*selected_out)[input_index] = selected;
            if (quantities_out != nullptr) (*quantities_out)[input_index] = qty;
            if (require_stock && qty > 0) {
                auto total = std::find_if(
                    quoted_good_totals.begin(), quoted_good_totals.end(),
                    [&](const std::pair<int32_t, int64_t> &entry) {
                        return entry.first == candidate.good_id;
                    });
                if (total == quoted_good_totals.end()) {
                    quoted_good_totals.push_back({candidate.good_id, qty});
                    total = quoted_good_totals.end() - 1;
                } else {
                    total->second = saturating_add(
                        total->second, qty, _saturation_count);
                }
                if (total->second > _market.stock[
                        _market.index(market, candidate.good_id)]) {
                    return std::numeric_limits<int64_t>::max();
                }
            }
            total_cost = saturating_add(total_cost, mul_div_sat(
                qty, _market.price[_market.index(market, candidate.good_id)],
                GOODS_SCALE, _saturation_count), _saturation_count);
        }
        return total_cost;
    };
    auto group_input_cost_at_scale = [&](const BuildingGroup &group,
                                         const BuildingType &type,
                                         int64_t output_scale_q16,
                                         bool require_stock) -> int64_t {
        return quote_group_inputs(group, type, output_scale_q16, require_stock,
                                  nullptr, nullptr);
    };

    struct WorkingCapitalCandidate {
        int32_t group = -1;
        int64_t score_q16 = 0;
        int64_t desired_cost = 0;
        int64_t minimum_executable_cost = 0;
        bool critical = false;
        bool survival = false;
    };
    thread_local std::vector<WorkingCapitalCandidate> candidates;
    std::fill(_building_funded_capacity_q16.begin() + begin,
              _building_funded_capacity_q16.begin() + end, 0);
    std::fill(_building_working_capital_allocated.begin() + begin,
              _building_working_capital_allocated.begin() + end, 0);
    for (int32_t owner_signature : payroll_owners) {
        const int32_t owner_slot = find_cohort_slot(cell, owner_signature);
        if (owner_slot < 0) continue;
        int64_t wage_commitment = 0;
        int64_t expected_revenue = 0;
        int64_t filled_owner = 0;
        candidates.clear();
        candidates.reserve(static_cast<size_t>(std::max(0, end - begin)));
        for (int32_t g = begin; g < end; ++g) {
            BuildingGroup &group = _buildings[g];
            if (group.owner_signature_id != owner_signature || group.count <= 0 ||
                group.operating_state == 1 || !building_available(cell, group.type_id, true)) continue;
            const BuildingType &type = _building_types[group.type_id];
            wage_commitment = saturating_add(
                wage_commitment, group.last_base_wages_due, _saturation_count);
            expected_revenue = saturating_add(
                expected_revenue, group.last_expected_revenue, _saturation_count);
            filled_owner = saturating_add(filled_owner, group.filled_owner, _saturation_count);
            const int64_t desired_scale = desired_scale_for_group(group, type, false);
            group.purchase_intent_capacity_q16 = desired_scale;
            const int64_t desired_cost = group_input_cost_at_scale(
                group, type, desired_scale, false);
            int64_t survival_pressure = 0;
            int64_t ordinary_pressure = 0;
            int64_t downstream_pressure = 0;
            bool critical = false;
            bool survival_output = false;
            int64_t survival_absorption_q16 = 0;
            for (int32_t i = 0; i < type.output_count; ++i) {
                const int32_t good = _building_outputs[type.output_begin + i].good_id;
                const int64_t idx = _market.index(market, good);
                const int64_t shortage = std::clamp<int64_t>(
                    _market.last_shortage_q16[idx], 0, Q16_ONE);
                const bool survival = _survival_food_good_mask[good] != 0 ||
                    _survival_clothing_good_mask[good] != 0;
                if (survival) {
                    survival_pressure = std::max(survival_pressure, shortage);
                    critical = true;
                    survival_output = true;
                    const GoodAmount &output = _building_outputs[type.output_begin + i];
                    const int64_t offered =
                        effective_building_output_quantity(
                            group, output.quantity, desired_scale,
                            saturating_mul(group.count,
                                std::max(1, _epoch_days), _saturation_count),
                            _saturation_count);
                    const int32_t signal = market_signal_index(cell, good);
                    const int64_t realized = signal >= 0
                        ? _market_signals.realized_withdrawal_ema[signal] : 0;
                    const int32_t flow = trade_flow_index(cell, good, false);
                    const int64_t exports = flow >= 0 ? _trade_flows.export_ema[flow] : 0;
                    const int64_t target = merchant_inventory_target(
                        market, good, signal, realized, exports,
                        offered / std::max(1, _epoch_days), _saturation_count);
                    const int64_t quota = merchant_procurement_quota(
                        market, good, signal, offered, target,
                        _market.stock[idx], realized, exports, _saturation_count);
                    if (offered > 0) {
                        survival_absorption_q16 = std::max<int64_t>(
                            survival_absorption_q16,
                            std::min<int64_t>(Q16_ONE, mul_div_sat(
                                quota, Q16_ONE, offered, _saturation_count)));
                    }
                } else {
                    ordinary_pressure = std::max(ordinary_pressure, shortage);
                }
                const int32_t signal = market_signal_index(cell, good);
                if (signal >= 0) {
                    const int64_t demand = _market_signals.business_demand_ema[signal];
                    const int64_t stock = _market.stock[idx];
                    if (demand > 0) {
                        downstream_pressure = std::max<int64_t>(downstream_pressure,
                            std::clamp<int64_t>(mul_div_sat(
                                std::max<int64_t>(0, demand - stock), Q16_ONE,
                                std::max<int64_t>(1, demand), _saturation_count), 0, Q16_ONE));
                        critical = true;
                    }
                }
            }
            const int64_t contribution = std::clamp<int64_t>(
                Q16_ONE + group.last_margin_gap_q16, -Q16_ONE, 2 * Q16_ONE);
            const int64_t score = saturating_add(saturating_add(
                4 * survival_pressure, 3 * downstream_pressure, _saturation_count),
                saturating_add(2 * ordinary_pressure, contribution, _saturation_count),
                _saturation_count);
            int64_t executable_scale = desired_scale;
            if (survival_output) {
                executable_scale = mul_div_sat(executable_scale,
                    survival_absorption_q16, Q16_ONE, _saturation_count);
                if (type.behavior_id == 1 || type.behavior_id == 2) {
                    const int64_t building_days = saturating_mul(
                        group.count, std::max(1, _epoch_days), _saturation_count);
                    for (int32_t edge = 0; edge < type.resource_count; ++edge) {
                        const ResourceAmount &item = _building_resources[
                            type.resource_begin + edge];
                        const int64_t base = item.mode == 1
                            ? saturating_mul(group.count, item.quantity, _saturation_count)
                            : saturating_mul(building_days, item.quantity, _saturation_count);
                        if (base <= 0) continue;
                        executable_scale = std::min<int64_t>(executable_scale,
                            mul_div_sat(available_resource_amount(item, cell),
                                Q16_ONE, base, _saturation_count));
                    }
                }
            }
            const int64_t minimum_executable_cost = survival_output
                ? group_input_cost_at_scale(group, type,
                    std::clamp<int64_t>(executable_scale, 0, desired_scale), false)
                : 0;
            const int64_t fundable_cost = survival_output
                ? minimum_executable_cost : desired_cost;
            if (fundable_cost > 0 && fundable_cost != std::numeric_limits<int64_t>::max() &&
                (score > 0 || critical)) {
                candidates.push_back({g, score, fundable_cost,
                    minimum_executable_cost, critical, survival_output});
            }
        }
        const int64_t owner_cash = std::max<int64_t>(0, _population.funds[owner_slot]);
        // Household clearing already protected this period's input float before
        // paying livelihood. Reserve only the wage gap here; holding livelihood
        // a second time permanently cuts the same owner's funded capacity.
        const int64_t wage_cash_gap = std::max<int64_t>(
            0, saturating_sub(wage_commitment, expected_revenue, _saturation_count));
        int64_t budget = std::max<int64_t>(
            0, owner_cash - std::min(owner_cash, wage_cash_gap));
        std::stable_sort(candidates.begin(), candidates.end(),
            [](const WorkingCapitalCandidate &a, const WorkingCapitalCandidate &b) {
                if (a.score_q16 != b.score_q16) return a.score_q16 > b.score_q16;
                return a.group < b.group;
            });
        auto allocate = [&](WorkingCapitalCandidate &candidate, int64_t target) {
            const int64_t current = _building_working_capital_allocated[candidate.group];
            const int64_t grant = std::min<int64_t>(budget, std::max<int64_t>(0, target - current));
            _building_working_capital_allocated[candidate.group] += grant;
            budget -= grant;
            _owner_working_capital_allocated = saturating_add(
                _owner_working_capital_allocated, grant, _saturation_count);
        };
        for (WorkingCapitalCandidate &candidate : candidates) {
            if (budget <= 0) break;
            if (candidate.survival) {
                allocate(candidate, candidate.minimum_executable_cost);
            } else if (candidate.critical) allocate(candidate, std::max<int64_t>(
                1, (candidate.desired_cost + 3) / 4));
        }
        for (WorkingCapitalCandidate &candidate : candidates) {
            if (budget <= 0) break;
            allocate(candidate, candidate.desired_cost);
        }
    }
    if (_merchant_credit_runtime_mode == 2) {
        for (int32_t g = begin; g < end; ++g) {
            if (_buildings[g].operating_state != 2 ||
                _buildings[g].merchant_debt_delinquent_cycles != 0 ||
                g >= static_cast<int32_t>(_building_merchant_credit_limit.size())) continue;
            const int64_t grant = std::max<int64_t>(
                0, _building_merchant_credit_limit[g]);
            _building_working_capital_allocated[g] = saturating_add(
                _building_working_capital_allocated[g], grant, _saturation_count);
        }
    }
    int64_t cell_opening_cash = 0;
    _population.for_each_in_cell(cell, [&](int32_t slot) {
        cell_opening_cash = saturating_add(cell_opening_cash,
            std::max<int64_t>(0, _population.funds[slot]), _saturation_count);
    });
    int64_t producer_support_remaining = mul_div_sat(mul_div_sat(
        cell_opening_cash, _producer_support_monthly_cap_q16, Q16_ONE,
        _saturation_count), std::max(1, _epoch_days), 30, _saturation_count);
    auto process_phase = [&](bool cycle_flow_phase) -> bool {
        offers.clear();
        for (int32_t g = begin; g < end; ++g) {
            BuildingGroup &group = _buildings[g];
            if (group.cell != cell || group.count <= 0 ||
                !building_available(cell, group.type_id, true)) continue;
            if (group.operating_state == 1) continue;
            const BuildingType &type = _building_types[group.type_id];
            if (produces_cycle_flow(type) != cycle_flow_phase) continue;
            ++_processed_building_groups;
            if (type.production_climate_profile_id >= 0) {
                ++_climate_profiled_building_groups;
                if (group.last_climate_capacity_q16 < Q16_ONE)
                    ++_climate_limited_building_groups;
                _climate_capacity_sum_q16 = saturating_add(
                    _climate_capacity_sum_q16,
                    group.last_climate_capacity_q16, _saturation_count);
            }
            const int32_t owner_slot = find_cohort_slot(cell, group.owner_signature_id);
            if (owner_slot < 0) continue;
            const int64_t intent_scale_without_climate = desired_scale_for_group(
                group, type, false);
            int64_t intent_scale_q16 = intent_scale_without_climate;
            const int64_t building_days = saturating_mul(
                group.count, std::max(1, _epoch_days), _saturation_count);
            const int64_t group_budget = g < static_cast<int32_t>(
                _building_working_capital_allocated.size())
                ? _building_working_capital_allocated[g] : 0;
            const int64_t credit_cap = g < static_cast<int32_t>(
                    _building_merchant_credit_limit.size()) &&
                    group.operating_state == 2 &&
                    group.merchant_debt_delinquent_cycles == 0
                ? std::max<int64_t>(0, _building_merchant_credit_limit[g]) : 0;
            const int64_t owner_capital_budget = std::max<int64_t>(
                0, group_budget - std::min(group_budget, credit_cap));
            const int64_t owner_contribution_cap = std::min<int64_t>(
                owner_capital_budget, std::max<int64_t>(
                    0, _population.funds[owner_slot]));
            int64_t merchant_credit_cash = 0;
            if (_merchant_credit_runtime_mode == 2 && credit_cap > 0) {
                for (int32_t k = _merchant_offsets[cell];
                     k < _merchant_offsets[cell + 1]; ++k) {
                    merchant_credit_cash = saturating_add(
                        merchant_credit_cash,
                        std::max<int64_t>(0, _population.funds[_merchant_slots[k]]),
                        _saturation_count);
                }
            }
            const int64_t drawable_credit = std::min<int64_t>(
                credit_cap, merchant_credit_cash);
            const int64_t settlement_budget = saturating_add(
                owner_contribution_cap, drawable_credit, _saturation_count);
            auto clamp_scale_to_group_budget = [&](int64_t output_scale_q16,
                                                   bool require_stock) -> int64_t {
                if (group_input_cost_at_scale(group, type, output_scale_q16,
                                              require_stock) <= settlement_budget) {
                    return output_scale_q16;
                }
                int64_t lo = 0;
                int64_t hi = std::clamp<int64_t>(output_scale_q16, 0, Q16_ONE);
                // Keep the allocation conservative. Eight probes leave at most
                // 1/256 of the requested utilization interval unresolved.
                for (int iter = 0; iter < 8; ++iter) {
                    const int64_t mid = (lo + hi + 1) / 2;
                    if (group_input_cost_at_scale(group, type, mid, require_stock) <= settlement_budget) lo = mid;
                    else hi = mid - 1;
                }
                _working_capital_scale_error_bound_q16 = std::max<int64_t>(
                    _working_capital_scale_error_bound_q16,
                    std::max<int64_t>(0, hi - lo));
                return lo;
            };
            int64_t scale_q16 = intent_scale_q16;
            for (int32_t i = 0; i < type.input_count; ++i) {
                const ProductionInput &item = _building_inputs[type.input_begin + i];
                const int64_t effective = saturating_mul(
                    building_days, item.quantity, _saturation_count);
                const int32_t selected = select_input_candidate(item, true, effective);
                if (selected < 0) {
                    scale_q16 = std::min<int64_t>(
                        scale_q16, soft_input_bound_q16(item, 0));
                    continue;
                }
                const InputCandidate &candidate = _building_input_candidates[selected];
                const int64_t physical = physical_input_quantity(effective, candidate);
                int64_t raw_capacity_q16 = Q16_ONE;
                if (physical > 0) {
                    raw_capacity_q16 = std::min<int64_t>(Q16_ONE, mul_div_sat(
                        _market.stock[_market.index(market, candidate.good_id)], Q16_ONE,
                        physical, _saturation_count));
                }
                scale_q16 = std::min<int64_t>(
                    scale_q16, soft_input_bound_q16(item, raw_capacity_q16));
            }
            scale_q16 = clamp_scale_to_group_budget(scale_q16, true);
            const int64_t non_resource_scale_without_climate_q16 =
                std::clamp<int64_t>(scale_q16, 0, Q16_ONE);
            bool resource_limited = false;
            bool resource_capacity_limited = false;
            if (type.behavior_id == 1 || type.behavior_id == 2) {
                for (int32_t i = 0; i < type.resource_count; ++i) {
                    const ResourceAmount &item = _building_resources[type.resource_begin + i];
                    const int64_t base = item.mode == 1
                        ? saturating_mul(group.count, item.quantity, _saturation_count)
                        : saturating_mul(building_days, item.quantity, _saturation_count);
                    if (base <= 0) continue;
                    if (item.mode == 1) ++_building_resource_capacity_checks;
                    const int64_t resource_scale = mul_div_sat(
                        available_resource_amount(item, cell), Q16_ONE, base, _saturation_count);
                    const bool resource_capacity_bound = intent_scale_q16 > 0 &&
                        resource_scale < Q16_ONE &&
                        resource_scale <= intent_scale_q16;
                    if (resource_capacity_bound || resource_scale < scale_q16)
                        resource_limited = true;
                    if (item.mode == 1 &&
                        (resource_capacity_bound || resource_scale < scale_q16)) {
                        resource_capacity_limited = true;
                    }
                    scale_q16 = std::min(scale_q16, resource_scale);
                }
            }
            const int64_t scale_without_climate_q16 = std::clamp<int64_t>(
                scale_q16, 0, Q16_ONE);
            intent_scale_q16 = std::min<int64_t>(
                std::clamp<int64_t>(intent_scale_without_climate, 0, Q16_ONE),
                group.last_climate_capacity_q16);
            scale_q16 = std::min<int64_t>(
                scale_without_climate_q16, group.last_climate_capacity_q16);
            if (resource_limited) ++_building_resource_limited_groups;
            if (resource_capacity_limited) ++_building_resource_capacity_limited_groups;
            group.purchase_intent_capacity_q16 = intent_scale_q16;
            group.last_capacity_q16 = scale_q16;
            _building_funded_capacity_q16[g] = scale_q16;
            if (group.last_climate_capacity_q16 < Q16_ONE) {
                for (int32_t i = 0; i < type.output_count; ++i) {
                    const GoodAmount &output = _building_outputs[type.output_begin + i];
                    const int64_t without_climate = effective_building_output_quantity(
                        group, output.quantity, scale_without_climate_q16, building_days,
                        _saturation_count);
                    const int64_t with_climate = effective_building_output_quantity(
                        group, output.quantity, scale_q16, building_days,
                        _saturation_count);
                    group.last_climate_lost_output = saturating_add(
                        group.last_climate_lost_output,
                        std::max<int64_t>(0, without_climate - with_climate),
                        _saturation_count);
                }
            }
            if (type.behavior_id == 2) {
                const int64_t generation_scale_q16 = std::min<int64_t>(
                    group.last_climate_capacity_q16,
                    std::min<int64_t>(non_resource_scale_without_climate_q16,
                        std::max<int64_t>(scale_q16,
                            type.generation_floor_q16)));
                for (int32_t i = 0; i < type.generation_count; ++i) {
                    const ResourceAmount &item =
                        _building_resource_generation[type.generation_begin + i];
                    const int64_t qty = mul_div_sat(saturating_mul(
                        building_days, item.quantity, _saturation_count),
                        generation_scale_q16, Q16_ONE, _saturation_count);
                    const size_t idx = static_cast<size_t>(item.resource_id) * _cell_count + cell;
                    ensure_resource_lane(idx);
                    _resource_deltas[idx] = saturating_add(
                        _resource_deltas[idx], qty, _saturation_count);
                    group.last_resource_generated = saturating_add(
                        group.last_resource_generated, qty, _saturation_count);
                    _building_resource_generated = saturating_add(
                        _building_resource_generated, qty, _saturation_count);
                }
            }
            if (scale_q16 == 0) continue;
            touch_accounting_slot(owner_slot);
            const int64_t actual_cost = quote_group_inputs(
                group, type, scale_q16, true,
                &quoted_input_candidates, &quoted_input_quantities);
            if (actual_cost == std::numeric_limits<int64_t>::max() ||
                actual_cost > settlement_budget) {
                error = "building_input_quote_drift:cell=" + std::to_string(cell) +
                    ",group=" + std::to_string(g) +
                    ",type=" + std::to_string(group.type_id) +
                    ",cost=" + std::to_string(actual_cost) +
                    ",budget=" + std::to_string(settlement_budget);
                return false;
            }
            const int64_t owner_contribution = std::min<int64_t>(
                actual_cost, owner_contribution_cap);
            const int64_t draw = actual_cost - owner_contribution;
            if (draw > 0) {
                if (_merchant_credit_runtime_mode != 2 ||
                    group.operating_state != 2 ||
                    group.merchant_debt_delinquent_cycles != 0 ||
                    draw > drawable_credit ||
                    debit_local_merchants(cell, draw, CASHFLOW_MERCHANT_BUSINESS,
                                          &_saturation_count) != draw) {
                    error = "building_input_credit_preflight_drift:cell=" +
                        std::to_string(cell) +
                        ",group=" + std::to_string(g) +
                        ",type=" + std::to_string(group.type_id) +
                        ",cost=" + std::to_string(actual_cost) +
                        ",owner_cap=" + std::to_string(owner_contribution_cap) +
                        ",draw=" + std::to_string(draw) +
                        ",credit_cap=" + std::to_string(credit_cap) +
                        ",drawable=" + std::to_string(drawable_credit);
                    return false;
                }
                touch_accounting_slot(owner_slot);
                _population.funds[owner_slot] = saturating_add(
                    _population.funds[owner_slot], draw, _saturation_count);
                trace_record_cashflow(cell, _population.handle_for_slot(owner_slot),
                                      CASHFLOW_OTHER, draw, 0);
                const int64_t premium = saturating_add(saturating_mul(
                    draw, _merchant_credit_premium_q16, _saturation_count),
                    Q16_ONE - 1, _saturation_count) / Q16_ONE;
                group.merchant_debt_principal = saturating_add(
                    group.merchant_debt_principal, draw, _saturation_count);
                group.merchant_debt_premium = saturating_add(
                    group.merchant_debt_premium, premium, _saturation_count);
                group.merchant_debt_term_cycles_left = static_cast<uint16_t>(
                    _merchant_credit_term_cycles);
                result.merchant_credit_drawn = saturating_add(
                    result.merchant_credit_drawn, draw, _saturation_count);
            }
            for (int32_t i = 0; i < type.input_count; ++i) {
                const int32_t selected = quoted_input_candidates[i];
                const int64_t qty = quoted_input_quantities[i];
                if (selected < 0 || qty <= 0) continue;
                const InputCandidate &candidate = _building_input_candidates[selected];
                _building_last_input_selected_goods[
                    group.last_input_selection_begin + i] = candidate.good_id;
                const int64_t stock_index =
                    _market.index(market, candidate.good_id);
                audit_touch_market_lane(static_cast<size_t>(stock_index));
                _market.stock[stock_index] -= qty;
                const int32_t signal = market_signal_index(cell, candidate.good_id);
                if (signal >= 0 && signal < static_cast<int32_t>(
                        _epoch_nonhousehold_withdrawals.size())) {
                    _epoch_nonhousehold_withdrawals[signal] = saturating_add(
                        _epoch_nonhousehold_withdrawals[signal], qty, _saturation_count);
                }
                group.last_input = saturating_add(group.last_input, qty, _saturation_count);
                _production_inputs_consumed = saturating_add(
                    _production_inputs_consumed, qty, _saturation_count);
                if (_good_storage_modes[candidate.good_id] == 1) {
                    _cycle_flow_consumed = saturating_add(
                        _cycle_flow_consumed, qty, _saturation_count);
                }
            }
            _population.funds[owner_slot] -= actual_cost;
            group.last_input_cost = actual_cost;
            group.last_operating_cost = saturating_add(
                actual_cost, group.last_wages_due, _saturation_count);
            _population.epoch_expense[owner_slot] = saturating_add(
                _population.epoch_expense[owner_slot], actual_cost, _saturation_count);
            trace_record_cashflow(cell, _population.handle_for_slot(owner_slot),
                                  CASHFLOW_PRODUCTION_INPUT, 0, actual_cost);
            if (credit_local_merchants(cell, actual_cost,
                                       CASHFLOW_MERCHANT_BUSINESS,
                                       &_saturation_count) != actual_cost) {
                error = "building_input_has_no_merchant_owner";
                return false;
            }
            if (type.behavior_id == 1 || type.behavior_id == 2) {
                for (int32_t i = 0; i < type.resource_count; ++i) {
                    const ResourceAmount &item = _building_resources[type.resource_begin + i];
                    if (item.mode == 1) continue;
                    const int64_t qty = mul_div_sat(saturating_mul(
                        building_days, item.quantity, _saturation_count),
                        scale_q16, Q16_ONE, _saturation_count);
                    consume_resource_amount(item, cell, qty);
                    group.last_resource = saturating_add(
                        group.last_resource, qty, _saturation_count);
                    _building_resource_consumed = saturating_add(
                        _building_resource_consumed, qty, _saturation_count);
                }
            }
            for (int32_t i = 0; i < type.output_count; ++i) {
                const GoodAmount &item = _building_outputs[type.output_begin + i];
                const int64_t qty = effective_building_output_quantity(
                    group, item.quantity, scale_q16, building_days,
                    _saturation_count);
                if (qty > 0) offers.push_back({item.good_id, owner_slot, g, qty, 0, qty});
                group.last_output = saturating_add(
                    group.last_output, qty, _saturation_count);
            }
        }
        std::stable_sort(offers.begin(), offers.end(), [](const Offer &a, const Offer &b) {
            if (a.good != b.good) return a.good < b.good;
            return a.group < b.group;
        });
        thread_local std::vector<int64_t> sellable_by_good;
        thread_local std::vector<int64_t> quota_by_good;
        thread_local std::vector<int64_t> purchase_value_by_good;
        thread_local std::vector<int64_t> budget_by_good;
        thread_local std::vector<int64_t> spent_by_good;
        thread_local std::vector<int64_t> weight_by_good;
        thread_local std::vector<int32_t> buy_factor_by_good;
        thread_local std::vector<int32_t> touched_goods;
        const size_t good_count = static_cast<size_t>(_market.good_count);
        sellable_by_good.resize(good_count);
        quota_by_good.resize(good_count);
        purchase_value_by_good.resize(good_count);
        budget_by_good.resize(good_count);
        spent_by_good.resize(good_count);
        weight_by_good.resize(good_count);
        buy_factor_by_good.resize(good_count);
        touched_goods.clear();
        int32_t last_touched = -1;
        for (Offer &offer : offers) {
            if (offer.owner_slot >= 0 &&
                offer.owner_slot < static_cast<int32_t>(retention_slot_stamp.size()) &&
                retention_slot_stamp[offer.owner_slot] == retention_generation) {
                const size_t owner = static_cast<size_t>(
                    retention_owner_by_slot[offer.owner_slot]);
                if (_survival_food_good_mask[offer.good] != 0) {
                    if (retention_food_staple_route[owner] == 0 ||
                        _survival_staple_good_mask[offer.good] != 0) {
                        offer.retained = std::min<int64_t>(offer.qty, std::max<int64_t>(
                            0, retention_food_targets[owner] - retention_food_used[owner]));
                        retention_food_used[owner] = saturating_add(
                            retention_food_used[owner], offer.retained, _saturation_count);
                    }
                } else if (_survival_clothing_good_mask[offer.good] != 0) {
                    offer.retained = std::min<int64_t>(offer.qty, std::max<int64_t>(
                        0, retention_clothing_targets[owner] -
                            retention_clothing_used[owner]));
                    retention_clothing_used[owner] = saturating_add(
                        retention_clothing_used[owner], offer.retained,
                        _saturation_count);
                } else {
                    const int32_t lane = retention_lane(owner, offer.good);
                    if (lane >= 0) {
                        offer.retained = std::min<int64_t>(offer.qty, std::max<int64_t>(
                            0, retention_targets[lane] - retention_used[lane]));
                        retention_used[lane] = saturating_add(
                            retention_used[lane], offer.retained, _saturation_count);
                    }
                }
            }
            offer.sellable = offer.qty - offer.retained;
            const int32_t producer_signal = market_signal_index(cell, offer.good);
            if (producer_signal >= 0 && producer_signal < static_cast<int32_t>(
                    _epoch_producer_sellable_current.size())) {
                _epoch_producer_sellable_current[producer_signal] = saturating_add(
                    _epoch_producer_sellable_current[producer_signal],
                    offer.sellable, _saturation_count);
            }
            if (offer.retained > 0) {
                _owner_retained_outputs.push_back(
                    {offer.owner_slot, offer.good, offer.group, offer.retained});
                const int32_t signal = market_signal_index(cell, offer.good);
                if (signal >= cell_signal_begin && signal < cell_signal_end) {
                    const size_t local_signal = static_cast<size_t>(signal - cell_signal_begin);
                    retained_by_signal[local_signal] = saturating_add(
                        retained_by_signal[local_signal], offer.retained, _saturation_count);
                }
            }
            if (_good_monetary_issue_values[offer.good] <= 0 && offer.sellable > 0) {
                sellable_by_good[offer.good] = saturating_add(
                    sellable_by_good[offer.good], offer.sellable, _saturation_count);
                if (offer.good != last_touched) {
                    // Offers are sorted by good. Reset only the sparse goods
                    // touched by this cell instead of clearing every catalog good.
                    sellable_by_good[offer.good] = offer.sellable;
                    quota_by_good[offer.good] = 0;
                    purchase_value_by_good[offer.good] = 0;
                    budget_by_good[offer.good] = 0;
                    spent_by_good[offer.good] = 0;
                    weight_by_good[offer.good] = 0;
                    buy_factor_by_good[offer.good] = 0;
                    touched_goods.push_back(offer.good);
                    last_touched = offer.good;
                }
            }
        }
        int64_t total_purchase_value = 0;
        for (int32_t good : touched_goods) {
            const int32_t signal = market_signal_index(cell, good);
            const int64_t realized = signal >= 0
                ? _market_signals.realized_withdrawal_ema[signal] : 0;
            const int32_t flow = trade_flow_index(cell, good, false);
            const int64_t exports = flow >= 0 ? _trade_flows.export_ema[flow] : 0;
            const int64_t cold_start_supply = sellable_by_good[good] /
                std::max(1, _epoch_days);
            const int64_t target = merchant_inventory_target(
                market, good, signal, realized, exports, cold_start_supply,
                _saturation_count);
            if (_good_storage_modes[good] == 1) {
                // Cycle-flow goods cannot persist as inventory. Let the producer
                // attempt a low-price same-cycle clearing/support pass before the
                // remaining transient stock is discarded at the cell boundary.
                quota_by_good[good] = std::max<int64_t>(0, sellable_by_good[good]);
            } else {
                quota_by_good[good] = merchant_procurement_quota(
                    market, good, signal, sellable_by_good[good], target,
                    _market.stock[_market.index(market, good)], realized,
                    exports, _saturation_count);
            }
            buy_factor_by_good[good] = effective_merchant_buy_factor_q16(
                market, good, target,
                _market.stock[_market.index(market, good)], _saturation_count);
            const int64_t buy_price = std::max<int64_t>(1, mul_div_sat(
                _market.price[_market.index(market, good)],
                buy_factor_by_good[good], Q16_ONE, _saturation_count));
            const int64_t base_weight = mul_div_sat(
                quota_by_good[good], buy_price, GOODS_SCALE, _saturation_count);
            purchase_value_by_good[good] = base_weight;
            total_purchase_value = saturating_add(
                total_purchase_value, base_weight, _saturation_count);
            const bool survival_good = _survival_food_good_mask[good] != 0 ||
                _survival_clothing_good_mask[good] != 0;
            const bool input_gap = signal >= 0 && signal < static_cast<int32_t>(
                    _production_input_reserve.size()) &&
                _production_input_reserve[signal] >
                    _market.stock[_market.index(market, good)];
            if (survival_good) {
                _merchant_survival_procurement_required = saturating_add(
                    _merchant_survival_procurement_required, base_weight,
                    _saturation_count);
            } else if (input_gap) {
                _merchant_input_procurement_required = saturating_add(
                    _merchant_input_procurement_required, base_weight,
                    _saturation_count);
            }
            int64_t priority_q16 = Q16_ONE;
            if (_survival_food_good_mask[good] != 0 ||
                _survival_clothing_good_mask[good] != 0) {
                priority_q16 = saturating_add(
                    priority_q16, 2 * Q16_ONE, _saturation_count);
            }
            const int64_t market_index = _market.index(market, good);
            priority_q16 = saturating_add(priority_q16, mul_div_sat(
                std::clamp<int64_t>(_market.last_shortage_q16[market_index],
                                    0, Q16_ONE),
                2 * Q16_ONE, Q16_ONE, _saturation_count),
                _saturation_count);
            if (signal >= 0 && signal < static_cast<int32_t>(
                    _production_input_reserve.size())) {
                const int64_t reserve = std::max<int64_t>(
                    0, _production_input_reserve[signal]);
                const int64_t stock = std::max<int64_t>(
                    0, _market.stock[market_index]);
                if (reserve > stock) {
                    priority_q16 = saturating_add(priority_q16, mul_div_sat(
                        reserve - stock, 2 * Q16_ONE,
                        std::max<int64_t>(1, reserve), _saturation_count),
                        _saturation_count);
                }
            }
            weight_by_good[good] = mul_div_sat(
                base_weight, priority_q16, Q16_ONE, _saturation_count);
        }
        const int64_t allocated_budget = std::min(
            merchant_procurement_remaining, total_purchase_value);
        _merchant_procurement_opportunity = saturating_add(
            _merchant_procurement_opportunity, total_purchase_value, _saturation_count);
        _merchant_procurement_allocated = saturating_add(
            _merchant_procurement_allocated, allocated_budget, _saturation_count);
        int64_t remaining_budget = allocated_budget;
        auto procurement_tier = [&](int32_t good) {
            if (_survival_food_good_mask[good] != 0 ||
                _survival_clothing_good_mask[good] != 0) return 0;
            const int32_t signal = market_signal_index(cell, good);
            if (signal >= 0 && signal < static_cast<int32_t>(
                    _production_input_reserve.size()) &&
                _production_input_reserve[signal] >
                    _market.stock[_market.index(market, good)]) return 1;
            return 2;
        };
        auto allocate_tier = [&](int tier) {
            if (remaining_budget <= 0) return;
            int64_t tier_cap = 0;
            int64_t tier_weight = 0;
            for (int32_t good : touched_goods) {
                if (procurement_tier(good) != tier) continue;
                tier_cap = saturating_add(
                    tier_cap, purchase_value_by_good[good], _saturation_count);
                tier_weight = saturating_add(
                    tier_weight, weight_by_good[good], _saturation_count);
            }
            int64_t tier_budget = std::min(remaining_budget, tier_cap);
            const int64_t committed = tier_budget;
            while (tier_budget > 0 && tier_weight > 0) {
                bool capped_any = false;
                for (int32_t good : touched_goods) {
                    if (procurement_tier(good) != tier) continue;
                    const int64_t weight = weight_by_good[good];
                    const int64_t cap = purchase_value_by_good[good];
                    if (weight <= 0 || cap <= 0) continue;
                    const int64_t share = mul_div_sat(
                        tier_budget, weight, tier_weight, _saturation_count);
                    if (share < cap) continue;
                    budget_by_good[good] = cap;
                    tier_budget = std::max<int64_t>(0, tier_budget - cap);
                    tier_weight = std::max<int64_t>(0, tier_weight - weight);
                    weight_by_good[good] = 0;
                    capped_any = true;
                }
                if (!capped_any) break;
            }
            int64_t weight_prefix = 0;
            int64_t distributed = 0;
            for (int32_t good : touched_goods) {
                if (procurement_tier(good) != tier) continue;
                const int64_t weight = weight_by_good[good];
                if (weight <= 0 || tier_weight <= 0) continue;
                weight_prefix = saturating_add(
                    weight_prefix, weight, _saturation_count);
                const int64_t next = mul_div_sat(
                    tier_budget, weight_prefix, tier_weight, _saturation_count);
                budget_by_good[good] = std::min<int64_t>(
                    purchase_value_by_good[good], std::max<int64_t>(
                        0, next - distributed));
                distributed = next;
            }
            int64_t assigned = 0;
            for (int32_t good : touched_goods) {
                if (procurement_tier(good) == tier) assigned = saturating_add(
                    assigned, budget_by_good[good], _saturation_count);
            }
            int64_t rounding = std::max<int64_t>(0, committed - assigned);
            for (int32_t good : touched_goods) {
                if (rounding <= 0) break;
                if (procurement_tier(good) != tier) continue;
                const int64_t headroom = std::max<int64_t>(
                    0, purchase_value_by_good[good] - budget_by_good[good]);
                const int64_t extra = std::min(headroom, rounding);
                budget_by_good[good] += extra;
                rounding -= extra;
            }
            remaining_budget = std::max<int64_t>(
                0, remaining_budget - committed);
            if (tier == 0) {
                _merchant_survival_procurement_allocated = saturating_add(
                    _merchant_survival_procurement_allocated, committed,
                    _saturation_count);
            } else if (tier == 1) {
                _merchant_input_procurement_allocated = saturating_add(
                    _merchant_input_procurement_allocated, committed,
                    _saturation_count);
            }
        };
        allocate_tier(0);
        allocate_tier(1);
        allocate_tier(2);
        size_t offer_cursor = 0;
        for (int32_t good : touched_goods) {
            while (offer_cursor < offers.size() && offers[offer_cursor].good < good)
                ++offer_cursor;
            const size_t good_begin = offer_cursor;
            while (offer_cursor < offers.size() && offers[offer_cursor].good == good)
                ++offer_cursor;
            const size_t good_end = offer_cursor;
            const int64_t buy_price = std::max<int64_t>(1, mul_div_sat(
                _market.price[_market.index(market, good)],
                std::max<int32_t>(1, buy_factor_by_good[good]),
                Q16_ONE, _saturation_count));
            const int64_t merchant_total = std::min<int64_t>(quota_by_good[good],
                mul_div_sat(budget_by_good[good], GOODS_SCALE, buy_price,
                    _saturation_count));
            int64_t sellable_prefix = 0;
            int64_t merchant_allocated = 0;
            for (size_t i = good_begin; i < good_end; ++i) {
                sellable_prefix = saturating_add(
                    sellable_prefix, offers[i].sellable, _saturation_count);
                const int64_t next = mul_div_sat(
                    merchant_total, sellable_prefix,
                    std::max<int64_t>(1, sellable_by_good[good]),
                    _saturation_count);
                offers[i].merchant_sold = std::min<int64_t>(offers[i].sellable,
                    std::max<int64_t>(0, next - merchant_allocated));
                merchant_allocated = next;
            }
            const int64_t remaining_target = std::max<int64_t>(
                0, quota_by_good[good] - merchant_total);
            const int64_t remaining_sellable = std::max<int64_t>(
                0, sellable_by_good[good] - merchant_total);
            int64_t support_total = std::min(remaining_target, remaining_sellable);
            if (producer_support_remaining <= 0) {
                support_total = 0;
            } else {
                support_total = std::min<int64_t>(support_total, mul_div_sat(
                    producer_support_remaining,
                    GOODS_SCALE * PRODUCER_SUPPORT_PRICE_DENOMINATOR,
                    std::max<int64_t>(1, _market.price[_market.index(market, good)]),
                    _saturation_count));
            }
            const int64_t total_support_paid = support_total > 0
                ? std::max<int64_t>(1, mul_div_sat(support_total,
                    _market.price[_market.index(market, good)],
                    GOODS_SCALE * PRODUCER_SUPPORT_PRICE_DENOMINATOR,
                    _saturation_count))
                : 0;
            int64_t unsold_prefix = 0;
            int64_t support_allocated = 0;
            int64_t support_cash_allocated = 0;
            for (size_t i = good_begin; i < good_end; ++i) {
                const int64_t unsold = std::max<int64_t>(
                    0, offers[i].sellable - offers[i].merchant_sold);
                unsold_prefix = saturating_add(
                    unsold_prefix, unsold, _saturation_count);
                const int64_t next_support = mul_div_sat(
                    support_total, unsold_prefix,
                    std::max<int64_t>(1, remaining_sellable),
                    _saturation_count);
                offers[i].supported = std::min<int64_t>(unsold,
                    std::max<int64_t>(0, next_support - support_allocated));
                support_allocated = next_support;
                const int64_t next_cash = mul_div_sat(
                    total_support_paid, support_allocated,
                    std::max<int64_t>(1, support_total), _saturation_count);
                offers[i].support_paid = std::max<int64_t>(
                    0, next_cash - support_cash_allocated);
                support_cash_allocated = next_cash;
            }
            producer_support_remaining = std::max<int64_t>(
                0, producer_support_remaining - total_support_paid);
        }
        for (const Offer &offer : offers) {
            BuildingGroup &group = _buildings[offer.group];
            const int64_t issue_value = _good_monetary_issue_values[offer.good];
            const int64_t buy_price = std::max<int64_t>(1, mul_div_sat(
                _market.price[_market.index(market, offer.good)],
                std::max<int32_t>(1, buy_factor_by_good[offer.good]),
                Q16_ONE, _saturation_count));
            int64_t sold = offer.sellable;
            int64_t paid = 0;
            int64_t supported = offer.supported;
            int64_t support_paid = offer.support_paid;
            if (issue_value > 0) {
                paid = mul_div_sat(sold, issue_value, GOODS_SCALE, _saturation_count);
                _explicit_money_mint = saturating_add(
                    _explicit_money_mint, paid, _saturation_count);
                _bullion_money_issued = saturating_add(
                    _bullion_money_issued, paid, _saturation_count);
                if (_good_ids[offer.good] == "gold") {
                    _gold_accepted = saturating_add(_gold_accepted, sold, _saturation_count);
                    _gold_money_issued = saturating_add(
                        _gold_money_issued, paid, _saturation_count);
                } else {
                    _silver_accepted = saturating_add(_silver_accepted, sold, _saturation_count);
                    _silver_money_issued = saturating_add(
                        _silver_money_issued, paid, _saturation_count);
                }
                // Bullion mint is the primary sink for monetary goods (gold/silver):
                // the whole sellable batch is absorbed by the money system every epoch.
                // Feed this back into the withdrawal signal so the utilization planner
                // (see prepare_building_economic_plan inventory-absorption path) does
                // not treat mint-cleared bullion as unsellable inventory and throttle
                // production to the probe floor. Without this, demand_ema stays 0,
                // target inventory collapses to ~0, stock >> target, and util decays.
                const int32_t bullion_signal = market_signal_index(cell, offer.good);
                if (bullion_signal >= 0 && bullion_signal < static_cast<int32_t>(
                        _epoch_nonhousehold_withdrawals.size())) {
                    _epoch_nonhousehold_withdrawals[bullion_signal] = saturating_add(
                        _epoch_nonhousehold_withdrawals[bullion_signal], sold,
                        _saturation_count);
                }
            } else {
                sold = offer.merchant_sold;
                const int64_t payment = mul_div_sat(
                    sold, buy_price, GOODS_SCALE, _saturation_count);
                paid = debit_local_merchants(cell, payment,
                                             CASHFLOW_MERCHANT_PROCUREMENT,
                                             &_saturation_count);
                if (paid != payment) {
                    error = "merchant_purchase_payment_drift";
                    return false;
                }
                spent_by_good[offer.good] = saturating_add(
                    spent_by_good[offer.good], paid, _saturation_count);
                merchant_procurement_remaining = std::max<int64_t>(
                    0, merchant_procurement_remaining - paid);
                _merchant_procurement_spent = saturating_add(
                    _merchant_procurement_spent, paid, _saturation_count);
                const int64_t retail_value = mul_div_sat(
                    sold, _market.price[_market.index(market, offer.good)],
                    GOODS_SCALE, _saturation_count);
                _merchant_procurement_retail_value = saturating_add(
                    _merchant_procurement_retail_value, retail_value,
                    _saturation_count);
                _merchant_procurement_factor_weighted_cash_q16 =
                    saturating_add(
                        _merchant_procurement_factor_weighted_cash_q16,
                        saturating_mul(paid,
                            buy_factor_by_good[offer.good],
                            _saturation_count),
                        _saturation_count);
                if (supported > 0) {
                    _explicit_money_mint = saturating_add(
                        _explicit_money_mint, support_paid, _saturation_count);
                    _producer_support_money_issued = saturating_add(
                        _producer_support_money_issued, support_paid,
                        _saturation_count);
                    _production_output_supported = saturating_add(
                        _production_output_supported, supported,
                        _saturation_count);
                }
            }
            int64_t business_tax = 0;
            if (business_tax_active) {
                const BuildingGroup &tax_group = _buildings[offer.group];
                const int8_t business_rate = frozen_tax_rate(
                    cell, NativeCountryRuntime::TAX_BUSINESS,
                    tax_group.type_id);
                business_tax = apply_fiscal_tax(
                    cell, NativeCountryRuntime::TAX_BUSINESS, paid,
                    business_rate, _saturation_count);
                record_cohort_fiscal(offer.owner_slot, business_tax);
            }
            const int64_t producer_after_business_tax = saturating_sub(
                paid, business_tax, _saturation_count);
            const int64_t total_paid = saturating_add(
                producer_after_business_tax, support_paid, _saturation_count);
            if (owner_operation_tax_active)
                operation_receipts_by_group[offer.group - begin] =
                    saturating_add(
                        operation_receipts_by_group[offer.group - begin],
                        paid, _saturation_count);
            if (business_tax_active)
                business_transfer_by_group[offer.group - begin] =
                    saturating_add(
                        business_transfer_by_group[offer.group - begin],
                        business_tax, _saturation_count);
            if (business_tax > 0)
                business_tax_by_group[offer.group - begin] = saturating_add(
                    business_tax_by_group[offer.group - begin], business_tax,
                    _saturation_count);
            const int64_t accepted = saturating_add(
                sold, supported, _saturation_count);
            touch_accounting_slot(offer.owner_slot);
            _population.funds[offer.owner_slot] = saturating_add(
                _population.funds[offer.owner_slot], total_paid, _saturation_count);
            _population.epoch_income[offer.owner_slot] = saturating_add(
                _population.epoch_income[offer.owner_slot], total_paid,
                _saturation_count);
            trace_record_cashflow(cell, _population.handle_for_slot(offer.owner_slot),
                                  CASHFLOW_OWNER_OPERATIONS, paid, 0);
            trace_record_cashflow(cell, _population.handle_for_slot(offer.owner_slot),
                                  CASHFLOW_PRODUCER_SUPPORT, support_paid, 0);
            if (business_tax > 0)
                trace_record_cashflow(cell,
                    _population.handle_for_slot(offer.owner_slot),
                    CASHFLOW_BUSINESS_TAX, 0, business_tax);
            else if (business_tax < 0)
                trace_record_cashflow(cell,
                    _population.handle_for_slot(offer.owner_slot),
                    CASHFLOW_BUSINESS_SUBSIDY, -business_tax, 0);
            const int64_t offer_stock_index =
                _market.index(market, offer.good);
            audit_touch_market_lane(
                static_cast<size_t>(offer_stock_index));
            _market.stock[offer_stock_index] = saturating_add(
                _market.stock[offer_stock_index], accepted,
                _saturation_count);
            if (issue_value > 0) {
                // Coined bullion is consumed by the money system: the sold batch
                // was minted into currency (see the issue_value branch above), so
                // it must not linger as market stock. Net stock change for these
                // goods is zero (+accepted then -sold, and supported==0 here).
                // Record the removal as an explicit goods-conservation sink so the
                // closing-stock check stays balanced. Without this, gold/silver
                // stock accrues as ghost inventory, the utilization planner reads
                // it as unsellable surplus, and throttles production to the probe
                // floor -> owner/employee targets collapse -> mines shed workers.
                _market.stock[offer_stock_index] = saturating_sub(
                    _market.stock[offer_stock_index], sold,
                    _saturation_count);
                _bullion_stock_consumed = saturating_add(
                    _bullion_stock_consumed, sold, _saturation_count);
            }
            group.last_sold = saturating_add(
                group.last_sold, accepted, _saturation_count);
            const int64_t unsold = offer.sellable - accepted;
            const int32_t producer_signal = market_signal_index(cell, offer.good);
            if (producer_signal >= 0 && producer_signal < static_cast<int32_t>(
                    _epoch_producer_merchant_sold_current.size())) {
                // Bullion issuance and producer support are non-market sinks.
                // Only purchases debited from merchant cash count as sell-through.
                const int64_t merchant_sold = issue_value > 0 ? 0 : sold;
                _epoch_producer_merchant_sold_current[producer_signal] =
                    saturating_add(
                        _epoch_producer_merchant_sold_current[producer_signal],
                        merchant_sold, _saturation_count);
                _epoch_producer_discarded_current[producer_signal] =
                    saturating_add(
                        _epoch_producer_discarded_current[producer_signal],
                        unsold, _saturation_count);
            }
            if (unsold > 0) {
                group.last_discarded = saturating_add(
                    group.last_discarded, unsold, _saturation_count);
            }
            group.last_revenue = saturating_add(
                group.last_revenue, total_paid, _saturation_count);
            _production_output_stock = saturating_add(
                _production_output_stock, accepted, _saturation_count);
            if (unsold > 0) {
                _production_output_discarded = saturating_add(
                    _production_output_discarded, unsold, _saturation_count);
            }
            _producer_revenue = saturating_add(
                _producer_revenue, total_paid, _saturation_count);
            if (_good_storage_modes[offer.good] == 1) {
                _cycle_flow_produced = saturating_add(
                    _cycle_flow_produced, accepted, _saturation_count);
            }
        }
        return true;
    };
    if (!process_phase(true) || !process_phase(false)) {
        _production_result_sink = previous_sink;
        return false;
    }

    // Production first spends only on physical inputs. Base wages are income
    // distribution and settle after the producer has sold this cycle's output.
    for (int32_t owner_signature : payroll_owners) {
        const int32_t owner_slot = find_cohort_slot(cell, owner_signature);
        int64_t total_due = 0;
        for (int32_t g = begin; g < end; ++g) {
            const BuildingGroup &group = _buildings[g];
            if (group.owner_signature_id != owner_signature ||
                !building_available(cell, group.type_id, true)) continue;
            total_due = saturating_add(total_due, std::max<int64_t>(
                0, group.last_base_wages_due - group.last_base_wages_paid),
                _saturation_count);
        }
        const int64_t available = owner_slot >= 0
            ? std::min(total_due, std::max<int64_t>(
                0, _population.funds[owner_slot])) : 0;
        int64_t prefix = 0;
        int64_t allocated = 0;
        int64_t owner_paid = 0;
        for (int32_t g = begin; g < end; ++g) {
            BuildingGroup &group = _buildings[g];
            if (group.owner_signature_id != owner_signature ||
                !building_available(cell, group.type_id, true)) continue;
            const BuildingType &type = _building_types[group.type_id];
            for (int32_t r = 0; r < type.employee_count; ++r) {
                const int32_t role_index = group.employee_fill_begin + r;
                const JobRole &role = _building_employee_roles[type.employee_begin + r];
                const int64_t due = std::max<int64_t>(
                    0, _building_role_base_wage_due[role_index] -
                       _building_role_base_wage_paid[role_index]);
                prefix = saturating_add(prefix, due, _saturation_count);
                const int64_t next = total_due > 0 ? mul_div_sat(
                    available, prefix, total_due, _saturation_count) : 0;
                const int64_t cap = std::max<int64_t>(0, next - allocated);
                allocated = next;
                const int64_t paid = pay_building_wage_amount(
                    cell, owner_slot, role.profession_id,
                    _building_employee_filled[role_index], due, cap,
                    &_saturation_count);
                _building_role_base_wage_paid[role_index] = saturating_add(
                    _building_role_base_wage_paid[role_index], paid, _saturation_count);
                group.last_base_wages_paid = saturating_add(
                    group.last_base_wages_paid, paid, _saturation_count);
                owner_paid = saturating_add(owner_paid, paid, _saturation_count);
            }
        }
        _building_base_wages_paid = saturating_add(
            _building_base_wages_paid, owner_paid, _saturation_count);
        _building_base_wages_due = saturating_add(
            _building_base_wages_due, total_due, _saturation_count);
        _building_wages_paid = saturating_add(
            _building_wages_paid, owner_paid, _saturation_count);
        _building_wages_unpaid = saturating_add(
            _building_wages_unpaid, total_due - owner_paid, _saturation_count);
        for (int32_t g = begin; g < end; ++g) {
            BuildingGroup &group = _buildings[g];
            if (group.owner_signature_id != owner_signature ||
                !building_available(cell, group.type_id, true)) continue;
            group.last_wages_paid = group.last_base_wages_paid;
            group.last_operating_cost = saturating_add(
                group.last_input_cost, group.last_base_wages_due, _saturation_count);
            group.wage_suspended = group.last_base_wages_paid < group.last_base_wages_due ? 1 : 0;
            if (group.wage_suspended != 0) ++_wage_suspended_building_groups;
        }
    }

    // Merchant debt is serviced after base wages and before discretionary
    // bonuses. Principal is retired before the one-time premium.
    for (int32_t g = begin; g < end; ++g) {
        BuildingGroup &group = _buildings[g];
        if (group.merchant_debt_principal <= 0 && group.merchant_debt_premium <= 0)
            continue;
        const int32_t owner_slot = find_cohort_slot(cell, group.owner_signature_id);
        int64_t due_sat = 0;
        const int64_t due = building_debt_due(group, due_sat);
        _saturation_count = saturating_add(
            _saturation_count, due_sat, _saturation_count);
        int64_t premium_paid = 0;
        const int64_t paid = repay_building_debt(
            cell, owner_slot, group, due, premium_paid);
        result.merchant_credit_repaid = saturating_add(
            result.merchant_credit_repaid, paid, _saturation_count);
        result.merchant_credit_premium_repaid = saturating_add(
            result.merchant_credit_premium_repaid, premium_paid,
            _saturation_count);
        if (group.merchant_debt_principal > 0 || group.merchant_debt_premium > 0) {
            if (group.merchant_debt_term_cycles_left > 0)
                --group.merchant_debt_term_cycles_left;
            if (paid < due) {
                group.merchant_debt_delinquent_cycles = static_cast<uint16_t>(
                    std::min<int32_t>(65535,
                        static_cast<int32_t>(group.merchant_debt_delinquent_cycles) + 1));
            } else {
                group.merchant_debt_delinquent_cycles = 0;
            }
            if (group.merchant_debt_term_cycles_left == 0)
                group.merchant_debt_delinquent_cycles = std::max<uint16_t>(
                    1, group.merchant_debt_delinquent_cycles);
        }
    }

    // Profit bonuses are settled after sales. They cannot retroactively stop
    // production and are excluded from the local regular-wage anchor.
    for (int32_t g = begin; g < end; ++g) {
        BuildingGroup &group = _buildings[g];
        if (group.wage_suspended != 0 || group.last_base_wages_due <= 0) continue;
        const BuildingType &type = _building_types[group.type_id];
        const int64_t base_cost = saturating_add(
            group.last_input_cost, group.last_base_wages_due, _saturation_count);
        const int64_t target_profit = mul_div_sat(
            base_cost, type.target_operating_margin_q16, Q16_ONE, _saturation_count);
        const int64_t excess = std::max<int64_t>(0, saturating_sub(
            saturating_sub(group.last_revenue, base_cost, _saturation_count),
            target_profit, _saturation_count));
        group.last_bonus_due = mul_div_sat(
            excess, _employee_profit_share_q16, Q16_ONE, _saturation_count);
        int64_t prefix = 0;
        int64_t allocated = 0;
        for (int32_t r = 0; r < type.employee_count; ++r) {
            const int32_t role_index = group.employee_fill_begin + r;
            prefix = saturating_add(prefix,
                _building_role_base_wage_due[role_index], _saturation_count);
            const int64_t next = mul_div_sat(
                group.last_bonus_due, prefix, group.last_base_wages_due,
                _saturation_count);
            _building_role_bonus_due[role_index] =
                std::max<int64_t>(0, next - allocated);
            allocated = next;
        }
    }
    for (int32_t owner_signature : payroll_owners) {
        const int32_t owner_slot = find_cohort_slot(cell, owner_signature);
        int64_t total_due = 0;
        for (int32_t g = begin; g < end; ++g) {
            if (_buildings[g].owner_signature_id == owner_signature)
                total_due = saturating_add(
                    total_due, _buildings[g].last_bonus_due, _saturation_count);
        }
        const int64_t available = owner_slot >= 0
            ? std::min(total_due, std::max<int64_t>(
                0, _population.funds[owner_slot])) : 0;
        int64_t prefix = 0;
        int64_t allocated = 0;
        int64_t owner_paid = 0;
        for (int32_t g = begin; g < end; ++g) {
            BuildingGroup &group = _buildings[g];
            if (group.owner_signature_id != owner_signature) continue;
            const BuildingType &type = _building_types[group.type_id];
            for (int32_t r = 0; r < type.employee_count; ++r) {
                const int32_t role_index = group.employee_fill_begin + r;
                const JobRole &role = _building_employee_roles[type.employee_begin + r];
                const int64_t due = _building_role_bonus_due[role_index];
                prefix = saturating_add(prefix, due, _saturation_count);
                const int64_t next = total_due > 0 ? mul_div_sat(
                    available, prefix, total_due, _saturation_count) : 0;
                const int64_t cap = std::max<int64_t>(0, next - allocated);
                allocated = next;
                const int64_t paid = pay_building_wage_amount(
                    cell, owner_slot, role.profession_id,
                    _building_employee_filled[role_index], due, cap,
                    &_saturation_count);
                _building_role_bonus_paid[role_index] = paid;
                owner_paid = saturating_add(owner_paid, paid, _saturation_count);
                group.last_bonus_paid = saturating_add(
                    group.last_bonus_paid, paid, _saturation_count);
            }
            group.last_wages_due = saturating_add(
                group.last_base_wages_due, group.last_bonus_due, _saturation_count);
            group.last_wages_paid = saturating_add(
                group.last_base_wages_paid, group.last_bonus_paid, _saturation_count);
            group.last_operating_cost = saturating_add(
                saturating_add(group.last_input_cost, group.last_base_wages_due,
                               _saturation_count),
                group.last_bonus_due, _saturation_count);
        }
        _building_bonus_due = saturating_add(
            _building_bonus_due, total_due, _saturation_count);
        _building_bonus_paid = saturating_add(
            _building_bonus_paid, owner_paid, _saturation_count);
        _building_wages_paid = saturating_add(
            _building_wages_paid, owner_paid, _saturation_count);
        _building_wages_unpaid = saturating_add(
            _building_wages_unpaid, total_due - owner_paid, _saturation_count);
    }
    // Tax positive net operating income only after inputs, actually paid wages,
    // and positive business tax are known. Tax/subsidy transfers themselves are
    // intentionally excluded from this base and losses never cross a cycle.
    if (income_tax_active) for (const int32_t owner_signature : payroll_owners) {
        const int32_t owner_slot = find_cohort_slot(cell, owner_signature);
        if (owner_slot < 0) continue;
        int64_t net_operating_income = 0;
        for (int32_t g = begin; g < end; ++g) {
            if (_buildings[g].owner_signature_id != owner_signature) continue;
            const int64_t costs = saturating_add(
                saturating_add(_buildings[g].last_input_cost,
                               _buildings[g].last_wages_paid,
                               _saturation_count),
                business_tax_active
                    ? business_tax_by_group[g - begin] : 0,
                _saturation_count);
            net_operating_income = saturating_add(
                net_operating_income,
                saturating_sub(operation_receipts_by_group[g - begin], costs,
                               _saturation_count),
                _saturation_count);
        }
        net_operating_income = std::max<int64_t>(0, net_operating_income);
        const int32_t signature = static_cast<int32_t>(
            _population.signature_id[owner_slot]);
        const int32_t profession = signature >= 0 &&
                signature < static_cast<int32_t>(_signatures.size())
            ? _signatures[signature].profession_id : -1;
        const int8_t income_rate = frozen_tax_rate(
            cell, NativeCountryRuntime::TAX_INCOME, profession);
        int64_t income_tax = 0;
        if (income_rate < 0) {
            if (owner_slot < static_cast<int32_t>(
                    _income_taxable_base_by_slot.size())) {
                _income_taxable_base_by_slot[owner_slot] = saturating_add(
                    _income_taxable_base_by_slot[owner_slot],
                    net_operating_income, _saturation_count);
            }
        } else {
            income_tax = apply_fiscal_tax(
                cell, NativeCountryRuntime::TAX_INCOME, net_operating_income,
                income_rate, _saturation_count);
            record_cohort_fiscal(owner_slot, income_tax);
        }
        if (income_tax == 0) continue;
        touch_accounting_slot(owner_slot);
        _population.funds[owner_slot] = saturating_sub(
            _population.funds[owner_slot], income_tax, _saturation_count);
        if (income_tax > 0)
            trace_record_cashflow(cell, _population.handle_for_slot(owner_slot),
                                  CASHFLOW_INCOME_TAX, 0, income_tax);
        else
            trace_record_cashflow(cell, _population.handle_for_slot(owner_slot),
                                  CASHFLOW_INCOME_SUBSIDY, -income_tax, 0);
    }
    for (int32_t g = begin; g < end; ++g) {
        BuildingGroup &group = _buildings[g];
        const int64_t owner_livelihood = saturating_mul(saturating_mul(
            living_cost_for_signature(cell, group.owner_signature_id, -1,
                                      _saturation_count),
            std::max<int64_t>(0, group.filled_owner), _saturation_count),
            std::max(1, _epoch_days), _saturation_count);
        const int64_t realized_cost = saturating_add(saturating_add(
            group.last_input_cost, group.last_base_wages_due, _saturation_count),
            owner_livelihood, _saturation_count);
        const int64_t after_business_revenue = business_tax_active
            ? saturating_sub(
                group.last_revenue, business_transfer_by_group[g - begin],
                _saturation_count)
            : group.last_revenue;
        int64_t margin = realized_cost <= 0 ? 0 : mul_div_sat(
            saturating_sub(after_business_revenue, realized_cost,
                           _saturation_count),
            Q16_ONE, std::max<int64_t>(MONEY_SCALE, realized_cost), _saturation_count);
        group.realized_profit_margin_q16 = static_cast<int32_t>(
            std::clamp<int64_t>(margin, -Q16_ONE, Q16_ONE));
    }
    update_cell_labor_signals(cell);
    const auto signal_started = Clock::now();
    thread_local std::vector<int64_t> business_observed;
    thread_local std::vector<int64_t> supply_observed;
    thread_local std::vector<int64_t> anchor_weighted;
    thread_local std::vector<int64_t> anchor_quantity;
    business_observed.assign(cell_signal_count, 0);
    supply_observed.assign(cell_signal_count, 0);
    anchor_weighted.assign(cell_signal_count, 0);
    anchor_quantity.assign(cell_signal_count, 0);
    for (int32_t g = begin; g < end; ++g) {
        const BuildingGroup &group = _buildings[g];
        if (group.cell != cell || group.count <= 0 ||
            !building_available(cell, group.type_id, true)) continue;
        const BuildingType &type = _building_types[group.type_id];
        const int64_t building_days = saturating_mul(
            group.count, std::max(1, _epoch_days), _saturation_count);
        if (group.operating_state == 1) {
            const int64_t probe_q16 = g < static_cast<int32_t>(
                    _building_recovery_probe_capacity_q16.size())
                ? std::clamp<int64_t>(
                    _building_recovery_probe_capacity_q16[g], 0, Q16_ONE)
                : 0;
            // A suspended producer releases all labor, but a small unfunded
            // probe remains visible to upstream suppliers. This is a signal,
            // not a stock withdrawal or a financing commitment.
            if (type.kind != 2 && probe_q16 > 0) {
                for (int32_t i = 0; i < type.input_count; ++i) {
                    const ProductionInput &item =
                        _building_inputs[type.input_begin + i];
                    const int64_t purchase_scale_q16 =
                        input_purchase_scale_q16(item, probe_q16);
                    if (purchase_scale_q16 <= 0) continue;
                    const int64_t effective = saturating_mul(
                        building_days, item.quantity, _saturation_count);
                    const int32_t selected =
                        select_input_candidate(item, false, effective);
                    if (selected < 0) continue;
                    const InputCandidate &candidate =
                        _building_input_candidates[selected];
                    const int64_t planned = scaled_input_quantity(
                        physical_input_quantity(effective, candidate),
                        purchase_scale_q16);
                    const int32_t signal = market_signal_index(
                        cell, candidate.good_id);
                    if (signal >= cell_signal_begin && signal < cell_signal_end) {
                        const size_t local_signal = static_cast<size_t>(
                            signal - cell_signal_begin);
                        business_observed[local_signal] = saturating_add(
                            business_observed[local_signal], planned,
                            _saturation_count);
                    }
                    if (signal >= 0 && signal < static_cast<int32_t>(
                            _epoch_desired_business_demand.size())) {
                        _epoch_desired_business_demand[signal] = saturating_add(
                            _epoch_desired_business_demand[signal], planned,
                            _saturation_count);
                    }
                    _desired_business_demand = saturating_add(
                        _desired_business_demand, planned, _saturation_count);
                    _unfunded_business_demand = saturating_add(
                        _unfunded_business_demand, planned, _saturation_count);
                }
            }
            continue;
        }
        const int64_t owner_livelihood = saturating_mul(saturating_mul(
            living_cost_for_signature(cell, group.owner_signature_id, -1,
                                      _saturation_count),
            std::max<int64_t>(0, group.filled_owner), _saturation_count),
            std::max(1, _epoch_days), _saturation_count);
        const int64_t viability_operating_cost = saturating_add(
            group.last_operating_cost, owner_livelihood, _saturation_count);
        for (int32_t i = 0; i < type.input_count; ++i) {
            const ProductionInput &item = _building_inputs[type.input_begin + i];
            const int32_t selected = select_input_candidate(item, false, 0);
            if (selected < 0) continue;
            const InputCandidate &candidate = _building_input_candidates[selected];
            const int64_t effective = mul_div_sat(saturating_mul(
                building_days, item.quantity, _saturation_count),
                group.purchase_intent_capacity_q16, Q16_ONE, _saturation_count);
            const int64_t planned = physical_input_quantity(effective, candidate);
            const int32_t signal = market_signal_index(cell, candidate.good_id);
            if (signal >= cell_signal_begin && signal < cell_signal_end) {
                const size_t local_signal = static_cast<size_t>(signal - cell_signal_begin);
                business_observed[local_signal] = saturating_add(
                    business_observed[local_signal], planned, _saturation_count);
            }
            const int64_t funded_effective = mul_div_sat(saturating_mul(
                building_days, item.quantity, _saturation_count),
                group.last_capacity_q16, Q16_ONE, _saturation_count);
            const int64_t funded = physical_input_quantity(funded_effective, candidate);
            if (signal >= 0) {
                if (signal < static_cast<int32_t>(_epoch_desired_business_demand.size())) {
                    _epoch_desired_business_demand[signal] = saturating_add(
                        _epoch_desired_business_demand[signal], planned, _saturation_count);
                }
                if (signal < static_cast<int32_t>(_epoch_funded_business_demand.size())) {
                    _epoch_funded_business_demand[signal] = saturating_add(
                        _epoch_funded_business_demand[signal], funded, _saturation_count);
                }
            }
            _desired_business_demand = saturating_add(
                _desired_business_demand, planned, _saturation_count);
            _funded_business_demand = saturating_add(
                _funded_business_demand, funded, _saturation_count);
            _unfunded_business_demand = saturating_add(
                _unfunded_business_demand, std::max<int64_t>(0, planned - funded),
                _saturation_count);
        }
        int64_t reference_total = 0;
        if (type.output_cost_share_count == 0) {
            for (int32_t i = 0; i < type.output_count; ++i) {
                const GoodAmount &item = _building_outputs[type.output_begin + i];
                reference_total = saturating_add(reference_total, saturating_mul(
                    item.quantity, _good_default_price[item.good_id], _saturation_count),
                    _saturation_count);
            }
        }
        int64_t prefix = 0;
        int64_t allocated_before = 0;
        for (int32_t i = 0; i < type.output_count; ++i) {
            const GoodAmount &item = _building_outputs[type.output_begin + i];
            const int64_t qty = mul_div_sat(saturating_mul(
                building_days, item.quantity, _saturation_count),
                group.last_capacity_q16, Q16_ONE, _saturation_count);
            const int32_t output_signal = market_signal_index(cell, item.good_id);
            if (output_signal >= cell_signal_begin && output_signal < cell_signal_end) {
                const size_t local_signal = static_cast<size_t>(output_signal - cell_signal_begin);
                supply_observed[local_signal] = saturating_add(
                    supply_observed[local_signal], qty, _saturation_count);
            }
            if (qty <= 0) continue;
            int64_t next_allocated = 0;
            if (type.output_cost_share_count > 0) {
                prefix = saturating_add(prefix,
                    _building_output_cost_shares_q16[type.output_cost_share_begin + i],
                    _saturation_count);
                next_allocated = mul_div_sat(viability_operating_cost, prefix,
                                              Q16_ONE, _saturation_count);
            } else {
                prefix = saturating_add(prefix, saturating_mul(
                    item.quantity, _good_default_price[item.good_id], _saturation_count),
                    _saturation_count);
                next_allocated = reference_total > 0 ? mul_div_sat(
                    viability_operating_cost, prefix, reference_total,
                    _saturation_count) : 0;
            }
            const int64_t allocated = std::max<int64_t>(0, next_allocated - allocated_before);
            allocated_before = next_allocated;
            if (_good_monetary_issue_values[item.good_id] > 0) continue;
            const int64_t required = saturating_add(allocated, mul_div_sat(
                allocated, type.target_operating_margin_q16, Q16_ONE,
                _saturation_count), _saturation_count);
            const int64_t settlement_unit = mul_div_sat(
                required, GOODS_SCALE, qty, _saturation_count);
            const int32_t output_flow = trade_flow_index(cell, item.good_id, false);
            const int64_t output_target = merchant_inventory_target(
                market, item.good_id, output_signal,
                output_signal >= 0 ? _market_signals.realized_withdrawal_ema[
                    output_signal] : 0,
                output_flow >= 0 ? _trade_flows.export_ema[output_flow] : 0,
                qty / std::max(1, _epoch_days), _saturation_count);
            const int32_t buy_factor = effective_merchant_buy_factor_q16(
                market, item.good_id, output_target,
                _market.stock[_market.index(market, item.good_id)],
                _saturation_count);
            const int64_t retail_target = mul_div_sat(
                settlement_unit, Q16_ONE,
                std::max<int32_t>(1, buy_factor),
                _saturation_count);
            if (output_signal < cell_signal_begin || output_signal >= cell_signal_end)
                continue;
            const size_t local_signal = static_cast<size_t>(output_signal - cell_signal_begin);
            anchor_weighted[local_signal] = saturating_add(
                anchor_weighted[local_signal], saturating_mul(
                    retail_target, qty, _saturation_count), _saturation_count);
            anchor_quantity[local_signal] = saturating_add(
                anchor_quantity[local_signal], qty, _saturation_count);
        }
    }
    if (has_cell_signals) {
        for (int32_t signal = cell_signal_begin; signal < cell_signal_end; ++signal) {
            const size_t local_signal = static_cast<size_t>(signal - cell_signal_begin);
            const int32_t good = _market_signals.good_ids[signal];
            supply_observed[local_signal] = std::max<int64_t>(
                0, supply_observed[local_signal] - retained_by_signal[local_signal]);
            const int64_t business_daily =
                business_observed[local_signal] / std::max(1, _epoch_days);
            const int64_t supply_daily =
                supply_observed[local_signal] / std::max(1, _epoch_days);
            const int64_t business_alpha = std::min<int64_t>(Q16_ONE,
                static_cast<int64_t>(_good_business_demand_ema_alpha_q16[good]) * _epoch_days);
            const int64_t supply_alpha = std::min<int64_t>(Q16_ONE,
                static_cast<int64_t>(_good_supply_ema_alpha_q16[good]) * _epoch_days);
            _market_signals.business_demand_ema[signal] = saturating_add(
                mul_div_sat(_market_signals.business_demand_ema[signal],
                            Q16_ONE - business_alpha, Q16_ONE, _saturation_count),
                mul_div_sat(business_daily, business_alpha, Q16_ONE, _saturation_count),
                _saturation_count);
            _market_signals.offered_supply_ema[signal] = saturating_add(
                mul_div_sat(_market_signals.offered_supply_ema[signal],
                            Q16_ONE - supply_alpha, Q16_ONE, _saturation_count),
                mul_div_sat(supply_daily, supply_alpha, Q16_ONE, _saturation_count),
                _saturation_count);
            if (anchor_quantity[local_signal] > 0) {
                const int64_t observed =
                    anchor_weighted[local_signal] / anchor_quantity[local_signal];
                const int64_t cost_alpha = std::min<int64_t>(Q16_ONE,
                    static_cast<int64_t>(_good_cost_ema_alpha_q16[good]) * _epoch_days);
                const int64_t old_anchor = _market_signals.cost_anchor_price[signal] > 0
                    ? _market_signals.cost_anchor_price[signal] : observed;
                const int64_t next_anchor = saturating_add(
                    mul_div_sat(old_anchor, Q16_ONE - cost_alpha, Q16_ONE, _saturation_count),
                    mul_div_sat(observed, cost_alpha, Q16_ONE, _saturation_count),
                    _saturation_count);
                _market_signals.cost_anchor_price[signal] = static_cast<int32_t>(
                    std::clamp<int64_t>(next_anchor, PRICE_NUMERIC_GUARD_MIN,
                                        PRICE_NUMERIC_GUARD_MAX));
            }
            ++_market_signal_updates;
        }
    }
    _market_signal_ms += elapsed_ms(signal_started);
    for (int32_t good : _cycle_flow_good_ids) {
        const int64_t idx = _market.index(market, good);
        const int64_t discarded = std::max<int64_t>(0, _market.stock[idx]);
        audit_touch_market_lane(static_cast<size_t>(idx));
        _market.stock[idx] = 0;
        _cycle_flow_discarded = saturating_add(
            _cycle_flow_discarded, discarded, _saturation_count);
    }
    for (int32_t g = begin; g < end; ++g) {
        const BuildingGroup &group = _buildings[g];
        if (group.cell != cell || group.count <= 0) continue;
        std::vector<EventLeg> legs;
        if (trace_detail) {
            const BuildingGroup &before = trace_before[static_cast<size_t>(g - begin)];
            auto add = [&](int32_t field, int64_t old_value, int64_t new_value) {
                if (old_value != new_value) {
                    legs.push_back({field, SUBJECT_BUILDING_GROUP,
                                    group.owner_signature_id, group.type_id,
                                    old_value, new_value});
                }
            };
            add(FIELD_BUILDING_CAPACITY, before.last_capacity_q16, group.last_capacity_q16);
            add(FIELD_BUILDING_INPUT, before.last_input, group.last_input);
            add(FIELD_BUILDING_OUTPUT, before.last_output, group.last_output);
            add(FIELD_BUILDING_SOLD, before.last_sold, group.last_sold);
            add(FIELD_BUILDING_DISCARDED, before.last_discarded, group.last_discarded);
            add(FIELD_BUILDING_RESOURCE, before.last_resource, group.last_resource);
            add(FIELD_BUILDING_RESOURCE_GENERATED, before.last_resource_generated,
                group.last_resource_generated);
            add(FIELD_BUILDING_REVENUE, before.last_revenue, group.last_revenue);
            add(FIELD_BUILDING_INPUT_COST, before.last_input_cost, group.last_input_cost);
            add(FIELD_BUILDING_WAGES_PAID, before.last_wages_paid, group.last_wages_paid);
            add(FIELD_BUILDING_WAGES_DUE, before.last_wages_due, group.last_wages_due);
            add(FIELD_BUILDING_EXPECTED_REVENUE, before.last_expected_revenue,
                group.last_expected_revenue);
            add(FIELD_BUILDING_OPERATING_COST, before.last_operating_cost,
                group.last_operating_cost);
            add(FIELD_BUILDING_MARGIN_GAP, before.last_margin_gap_q16,
                group.last_margin_gap_q16);
            add(FIELD_BUILDING_PLANNED_UTILIZATION, before.planned_utilization_q16,
                group.planned_utilization_q16);
            add(FIELD_BUILDING_BASE_WAGES_PAID, before.last_base_wages_paid,
                group.last_base_wages_paid);
            add(FIELD_BUILDING_BASE_WAGES_DUE, before.last_base_wages_due,
                group.last_base_wages_due);
            add(FIELD_BUILDING_BONUS_PAID, before.last_bonus_paid,
                group.last_bonus_paid);
            add(FIELD_BUILDING_BONUS_DUE, before.last_bonus_due,
                group.last_bonus_due);
            add(FIELD_BUILDING_WAGE_SUSPENDED, before.wage_suspended,
                group.wage_suspended);
        }
        trace_append(EVENT_BUILDING_PRODUCTION_SETTLED,
                     static_cast<int32_t>(Stage::BUILDING_PRODUCTION), cell,
                     SUBJECT_BUILDING_GROUP, group.owner_signature_id,
                     group.type_id, -1, group.last_output, group.last_sold,
                     group.last_revenue, group.last_wages_paid,
                     legs.empty() ? nullptr : &legs);
    }
    if (trace_detail) {
        std::vector<EventLeg> cell_legs;
        auto add = [&](int32_t field, int32_t subject_kind, int64_t subject_id,
                       int32_t key_id, int64_t before, int64_t after) {
            if (before != after) {
                cell_legs.push_back({field, subject_kind, subject_id, key_id, before, after});
            }
        };
        for (size_t i = 0; i < trace_cell_slots.size(); ++i) {
            const int32_t slot = trace_cell_slots[i];
            const int64_t handle = static_cast<int64_t>(_population.handle_for_slot(slot));
            add(FIELD_COHORT_FUNDS, SUBJECT_COHORT, handle, -1,
                trace_cell_funds[i], _population.funds[slot]);
            add(FIELD_COHORT_EPOCH_INCOME, SUBJECT_COHORT, handle, -1,
                trace_cell_income[i], _population.epoch_income[slot]);
            add(FIELD_COHORT_EPOCH_EXPENSE, SUBJECT_COHORT, handle, -1,
                trace_cell_expense[i], _population.epoch_expense[slot]);
        }
        for (int32_t good = 0; good < _market.good_count; ++good) {
            add(FIELD_MARKET_STOCK, SUBJECT_MARKET, market, good,
                trace_market_stock[good], _market.stock[_market.index(market, good)]);
        }
        for (size_t resource = 0; resource < _resource_ids.size(); ++resource) {
            const int64_t after = _resource_deltas[
                resource * static_cast<size_t>(_cell_count) + cell];
            add(FIELD_RESOURCE_DELTA, SUBJECT_RESOURCE, cell,
                static_cast<int32_t>(resource), trace_resource_delta[resource], after);
        }
        if (!cell_legs.empty()) {
            trace_append(EVENT_BUILDING_PRODUCTION_SETTLED,
                         static_cast<int32_t>(Stage::BUILDING_PRODUCTION), cell,
                         SUBJECT_MARKET, market, -1, -1,
                         static_cast<int64_t>(cell_legs.size()), 0, 0, 0, &cell_legs);
        }
    }
    if (cell >= 0 && cell < static_cast<int32_t>(
            _merchant_procurement_paid_by_cell.size())) {
        _merchant_procurement_paid_by_cell[cell] = saturating_add(
            _merchant_procurement_paid_by_cell[cell],
            std::max<int64_t>(0, _merchant_procurement_spent -
                cell_procurement_paid_before), _saturation_count);
        _merchant_procurement_retail_by_cell[cell] = saturating_add(
            _merchant_procurement_retail_by_cell[cell],
            std::max<int64_t>(0, _merchant_procurement_retail_value -
                cell_procurement_retail_before), _saturation_count);
        _merchant_procurement_factor_weighted_cash_by_cell[cell] =
            saturating_add(
                _merchant_procurement_factor_weighted_cash_by_cell[cell],
                std::max<int64_t>(0,
                    _merchant_procurement_factor_weighted_cash_q16 -
                    cell_procurement_factor_before), _saturation_count);
        _merchant_credit_drawn_by_cell[cell] = saturating_add(
            _merchant_credit_drawn_by_cell[cell],
            std::max<int64_t>(0, result.merchant_credit_drawn -
                cell_credit_drawn_before), _saturation_count);
    }
    _production_result_sink = previous_sink;
    return true;
}
void NativeEconomyRuntime::merge_building_production_result(ProductionResult &result) {
    _saturation_count = saturating_add(
        _saturation_count, result.saturation_count, _saturation_count);
    auto merge = [&](int64_t &target, int64_t value) {
        target = saturating_add(target, value, _saturation_count);
    };
    merge(_processed_building_groups, result.processed_building_groups);
    merge(_climate_profiled_building_groups,
          result.climate_profiled_building_groups);
    merge(_climate_limited_building_groups,
          result.climate_limited_building_groups);
    merge(_climate_capacity_sum_q16, result.climate_capacity_sum_q16);
    merge(_merchant_procurement_budget, result.merchant_procurement_budget);
    merge(_merchant_procurement_opportunity, result.merchant_procurement_opportunity);
    merge(_merchant_procurement_allocated, result.merchant_procurement_allocated);
    merge(_merchant_procurement_unspent_allocated, result.merchant_procurement_unspent_allocated);
    merge(_merchant_procurement_reserved, result.merchant_procurement_reserved);
    merge(_merchant_procurement_spent, result.merchant_procurement_spent);
    merge(_merchant_procurement_retail_value,
          result.merchant_procurement_retail_value);
    merge(_merchant_procurement_factor_weighted_cash_q16,
          result.merchant_procurement_factor_weighted_cash_q16);
    merge(_merchant_survival_procurement_required,
          result.merchant_survival_procurement_required);
    merge(_merchant_survival_procurement_allocated,
          result.merchant_survival_procurement_allocated);
    merge(_merchant_input_procurement_required,
          result.merchant_input_procurement_required);
    merge(_merchant_input_procurement_allocated,
          result.merchant_input_procurement_allocated);
    _merchant_procurement_unspent_allocated = std::max<int64_t>(
        0, _merchant_procurement_allocated - _merchant_procurement_spent);
    merge(_owner_working_capital_allocated, result.owner_working_capital_allocated);
    _working_capital_scale_error_bound_q16 = std::max(
        _working_capital_scale_error_bound_q16,
        result.working_capital_scale_error_bound_q16);
    merge(_building_resource_capacity_checks,
          result.building_resource_capacity_checks);
    merge(_building_resource_limited_groups,
          result.building_resource_limited_groups);
    merge(_building_resource_capacity_limited_groups,
          result.building_resource_capacity_limited_groups);
    merge(_building_resource_generated, result.building_resource_generated);
    merge(_building_resource_consumed, result.building_resource_consumed);
    merge(_production_inputs_consumed, result.production_inputs_consumed);
    merge(_production_output_stock, result.production_output_stock);
    merge(_production_output_discarded, result.production_output_discarded);
    merge(_production_output_supported, result.production_output_supported);
    merge(_producer_revenue, result.producer_revenue);
    merge(_producer_support_money_issued, result.producer_support_money_issued);
    merge(_explicit_money_mint, result.explicit_money_mint);
    merge(_bullion_money_issued, result.bullion_money_issued);
    merge(_bullion_stock_consumed, result.bullion_stock_consumed);
    merge(_gold_accepted, result.gold_accepted);
    merge(_silver_accepted, result.silver_accepted);
    merge(_gold_money_issued, result.gold_money_issued);
    merge(_silver_money_issued, result.silver_money_issued);
    merge(_cycle_flow_produced, result.cycle_flow_produced);
    merge(_cycle_flow_consumed, result.cycle_flow_consumed);
    merge(_cycle_flow_discarded, result.cycle_flow_discarded);
    merge(_building_wages_paid, result.building_wages_paid);
    merge(_building_wages_unpaid, result.building_wages_unpaid);
    merge(_building_base_wages_paid, result.building_base_wages_paid);
    merge(_building_base_wages_due, result.building_base_wages_due);
    merge(_building_bonus_paid, result.building_bonus_paid);
    merge(_building_bonus_due, result.building_bonus_due);
    merge(_wage_suspended_building_groups,
          result.wage_suspended_building_groups);
    merge(_desired_business_demand, result.desired_business_demand);
    merge(_funded_business_demand, result.funded_business_demand);
    merge(_unfunded_business_demand, result.unfunded_business_demand);
    merge(_market_signal_updates, result.market_signal_updates);
    merge(_merchant_credit_committed, result.merchant_credit_committed);
    merge(_merchant_credit_drawn, result.merchant_credit_drawn);
    merge(_merchant_credit_repaid, result.merchant_credit_repaid);
    merge(_merchant_credit_premium_repaid,
          result.merchant_credit_premium_repaid);
    merge(_production_result_allocation_growth_count,
          result.allocation_growth_count);
    merge(_production_result_allocation_growth_bytes,
          result.allocation_growth_bytes);
    _market_signal_ms += result.market_signal_ms;
    _resource_touched_lanes.insert(
        _resource_touched_lanes.end(),
        result.resource_touched_lanes.begin(),
        result.resource_touched_lanes.end());
    _owner_retained_outputs.insert(
        _owner_retained_outputs.end(),
        std::make_move_iterator(result.retained_outputs.begin()),
        std::make_move_iterator(result.retained_outputs.end()));
    for (const ProductionCashflowDraft &draft : result.cashflow_drafts) {
        trace_record_cashflow(draft.cell, draft.entry.cohort_handle,
                              draft.entry.source, draft.entry.income,
                              draft.entry.expense);
    }
    for (ProductionTraceDraft &draft : result.trace_drafts) {
        trace_append(draft.kind, draft.stage, draft.cell, draft.subject_kind,
                     draft.subject_id, draft.subject_i0, draft.subject_i1,
                     draft.value0, draft.value1, draft.value2, draft.value3,
                     draft.legs.empty() ? nullptr : &draft.legs, draft.flags);
    }
}


} // namespace pk
