#include "economy_runtime.h"
#include "economy_cost_probe.h"
#include "country_api.h"
#include "runtime_switch_registry.h"
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

void NativeEconomyRuntime::commit_bio_introduce(int32_t cell, int32_t bit) {
    if (cell < 0 || bit < 0 || bit >= 32) return;
    const uint64_t key = (uint64_t(uint32_t(cell)) << 8) | uint32_t(bit);
    if (!_bio_introduce_keys.insert(key).second) return;
    _bio_introduce_cells.push_back(cell);
    _bio_introduce_bits.push_back(bit);
}

void NativeEconomyRuntime::queue_bio_introduce_from_good(int32_t cell, int32_t good_id) {
    if (cell < 0 || good_id < 0 ||
        good_id + 1 >= static_cast<int32_t>(_good_occupancy_bit_offsets.size())) {
        return;
    }
    const int32_t begin = _good_occupancy_bit_offsets[size_t(good_id)];
    const int32_t end = _good_occupancy_bit_offsets[size_t(good_id) + 1];
    if (begin < 0 || end <= begin ||
        end > static_cast<int32_t>(_good_occupancy_bits.size())) {
        return;
    }
    for (int32_t i = begin; i < end; ++i) {
        const int32_t bit = _good_occupancy_bits[size_t(i)];
        if (bit < 0 || bit >= 32) continue;
        // Production workers must not insert into the shared unordered_set or
        // grow the shared vectors. Land in the per-cell ProductionResult and
        // let merge_building_production_result commit on the joining thread.
        if (_production_result_sink != nullptr) {
            _production_result_sink->bio_introduce_cells.push_back(cell);
            _production_result_sink->bio_introduce_bits.push_back(bit);
            continue;
        }
        commit_bio_introduce(cell, bit);
    }
}

void NativeEconomyRuntime::take_bio_introduces(std::vector<int32_t> &cells,
                                               std::vector<int32_t> &bits) {
    cells.clear();
    bits.clear();
    cells.swap(_bio_introduce_cells);
    bits.swap(_bio_introduce_bits);
    _bio_introduce_keys.clear();
}

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
    // Foraging is a daily outdoor activity, so use the temperature from the
    // economy-day snapshot for that profile. Other profiles retain the
    // established 30-day thermal signal until their content explicitly opts
    // into daily sensitivity. This keeps the hot loop branch-free per group
    // after the profile id is resolved and avoids a second climate pass.
    const bool daily_temperature =
        type.production_climate_profile_id >= 0 &&
        type.production_climate_profile_id < static_cast<int32_t>(
            _production_climate_profile_ids.size()) &&
        _production_climate_profile_ids[static_cast<size_t>(
            type.production_climate_profile_id)] == "foraging_plants";
    temperature_fit = fit_q16(
        daily_temperature ? environment.temperature_q16 : environment.temperature_30d_q16,
        climate.temperature_opt_q16,
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
        const size_t profile_count = _production_climate_profile_ids.size();
        const size_t profile_index =
            (static_cast<size_t>(country) * profile_count +
             static_cast<size_t>(type.production_climate_profile_id)) * 4U +
            adaptation;
        if (static_cast<size_t>(type.production_climate_profile_id) < profile_count &&
            profile_index < _epoch_country_climate_profile_loss_factor_q16.size()) {
            loss_factor_q16 = mul_div_sat(loss_factor_q16,
                _epoch_country_climate_profile_loss_factor_q16[profile_index],
                Q16_ONE, saturation_count);
        }
        loss_factor_q16 = std::clamp<int64_t>(loss_factor_q16,
            Q16_ONE / 5, Q16_ONE);
    }
    const int64_t exposed_loss = mul_div_sat(climate.exposure_q16,
        Q16_ONE - bounded, Q16_ONE, saturation_count);
    const int64_t adapted_loss = mul_div_sat(exposed_loss, loss_factor_q16,
        Q16_ONE, saturation_count);
    int64_t capacity = std::clamp<int64_t>(Q16_ONE - adapted_loss, 0, Q16_ONE);
    if (temperature_fit <= water_fit &&
        environment.temperature_30d_q16 < climate.temperature_opt_q16 &&
        cell >= 0 && cell < static_cast<int32_t>(
            _epoch_cell_cold_capacity_factor_q16.size())) {
        const int32_t cold_factor_q16 =
            _epoch_cell_cold_capacity_factor_q16[static_cast<size_t>(cell)];
        if (cold_factor_q16 > Q16_ONE) {
            const int64_t reduction = cold_factor_q16 - Q16_ONE;
            const int64_t reduced_loss = mul_div_sat(adapted_loss,
                std::max<int64_t>(0, Q16_ONE - reduction), Q16_ONE,
                saturation_count);
            capacity = std::clamp<int64_t>(Q16_ONE - reduced_loss, 0, Q16_ONE);
        } else {
            capacity = mul_div_sat(capacity, cold_factor_q16, Q16_ONE,
                saturation_count);
            capacity = std::clamp<int64_t>(capacity, 0, Q16_ONE);
        }
    }
    return capacity;
}

void NativeEconomyRuntime::prepare_group_climate_capacity(
        BuildingGroupRef group, const BuildingType &type) {
    group.last_climate_capacity_q16 = production_climate_capacity_q16(
        type, group.cell, &group.last_temperature_fit_q16,
        &group.last_water_fit_q16, _saturation_count);
    group.last_climate_lost_output = 0;
}

bool NativeEconomyRuntime::building_available(int32_t cell, int32_t type_id,
                                              bool frozen) const {
    if (frozen && _epoch_active && cell >= 0 && cell < _cell_count.get() &&
        type_id >= 0 && type_id < static_cast<int32_t>(_building_types.size()) &&
        _epoch_cell_country.size() == static_cast<size_t>(_cell_count.get())) {
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
            _building_all_required_technologies, frozen) &&
        building_dependency_requirements_met(cell, type_id, frozen);
}

bool NativeEconomyRuntime::building_dependency_group_required_for_operation(
        int32_t group) const {
    // Catalog kind 1 = construction goods. Standing lots keep producing once
    // their process/output/resource tags are known; leftover processing techs
    // remain a construction and market-good gate.
    return group < 0 ||
        group >= static_cast<int32_t>(_building_dependency_kinds.size()) ||
        _building_dependency_kinds[static_cast<size_t>(group)] != 1;
}

bool NativeEconomyRuntime::building_dependency_requirements_met(
        int32_t cell, int32_t type_id, bool frozen) const {
    if (type_id < 0 || type_id + 1 >= static_cast<int32_t>(
            _building_dependency_branch_offsets.size())) return false;
    const int32_t branch_begin = _building_dependency_branch_offsets[type_id];
    const int32_t branch_end = _building_dependency_branch_offsets[type_id + 1];
    if (branch_begin < 0 || branch_end <= branch_begin ||
        branch_end > static_cast<int32_t>(
            _building_dependency_branch_technology_offsets.size() - 1) ||
        branch_end > static_cast<int32_t>(
            _building_dependency_branch_group_offsets.size() - 1)) return false;
    for (int32_t branch = branch_begin; branch < branch_end; ++branch) {
        const int32_t tech_begin = _building_dependency_branch_technology_offsets[
            static_cast<size_t>(branch)];
        const int32_t tech_end = _building_dependency_branch_technology_offsets[
            static_cast<size_t>(branch + 1)];
        bool branch_technology_available = true;
        for (int32_t edge = tech_begin; edge < tech_end; ++edge) {
            if (!cell_has_technology(cell,
                    _building_dependency_branch_technologies[static_cast<size_t>(edge)],
                    frozen)) {
                branch_technology_available = false;
                break;
            }
        }
        if (!branch_technology_available) continue;
        const int32_t group_begin = _building_dependency_branch_group_offsets[
            static_cast<size_t>(branch)];
        const int32_t group_end = _building_dependency_branch_group_offsets[
            static_cast<size_t>(branch + 1)];
        bool groups_available = true;
        for (int32_t group = group_begin; group < group_end; ++group) {
            if (!building_dependency_group_required_for_operation(group))
                continue;
            const int32_t tag_begin = _building_dependency_tag_offsets[
                static_cast<size_t>(group)];
            const int32_t tag_end = _building_dependency_tag_offsets[
                static_cast<size_t>(group + 1)];
            bool group_available = false;
            for (int32_t tag = tag_begin; tag < tag_end; ++tag) {
                if (cell_has_technology(cell, _building_dependency_tags[
                        static_cast<size_t>(tag)], frozen)) {
                    group_available = true;
                    break;
                }
            }
            if (!group_available) {
                groups_available = false;
                break;
            }
        }
        if (groups_available) return true;
    }
    return false;
}

bool NativeEconomyRuntime::building_constructible(int32_t cell, int32_t type_id,
                                                   bool frozen) const {
    // 技术进步提供更多生产方式，而不是脚本化淘汰旧方式。投资市场会按
    // 资本回报、单位成本和当地约束选择层级；这里仅判断知识与依赖闭包。
    return building_available(cell, type_id, frozen);
}

int64_t NativeEconomyRuntime::allocated_output_operating_cost(
        const BuildingType &type, int32_t output_index,
        int64_t operating_cost, int64_t &sat) const {
    if (output_index < 0 || output_index >= type.output_count ||
        operating_cost <= 0) return 0;
    int64_t reference_total = 0;
    if (type.output_cost_share_count == 0) {
        for (int32_t i = 0; i < type.output_count; ++i) {
            const GoodAmount &item = _building_outputs[type.output_begin + i];
            reference_total = saturating_add(reference_total, saturating_mul(
                item.quantity, _good_default_price[item.good_id], sat), sat);
        }
    }
    int64_t prefix = 0;
    int64_t allocated_before = 0;
    int64_t allocated = 0;
    for (int32_t i = 0; i <= output_index; ++i) {
        int64_t next = 0;
        if (type.output_cost_share_count > 0 &&
            type.output_cost_share_begin + i < static_cast<int32_t>(
                _building_output_cost_shares_q16.size())) {
            prefix = saturating_add(prefix,
                _building_output_cost_shares_q16[
                    type.output_cost_share_begin + i], sat);
            next = mul_div_sat(operating_cost, prefix, Q16_ONE, sat);
        } else {
            const GoodAmount &item = _building_outputs[type.output_begin + i];
            prefix = saturating_add(prefix, saturating_mul(
                item.quantity, _good_default_price[item.good_id], sat), sat);
            next = reference_total > 0
                ? mul_div_sat(operating_cost, prefix, reference_total, sat) : 0;
        }
        allocated = std::max<int64_t>(0, next - allocated_before);
        allocated_before = next;
    }
    return allocated;
}

bool NativeEconomyRuntime::run_building_production_cell(
        int32_t cell, ProductionResult &result, std::string &error) {
    // 所有调度入口都必须携带地块身份，合并时才能归集食物流量。
    result.cell = cell;
    ProductionResult *previous_sink = _production_result_sink;
    _production_result_sink = &result;
    const auto production_cell_started = Clock::now();
    Clock::time_point production_prepare_mark = production_cell_started;
    // production_climate_capacity_q16() is a pure function of (cell, type) and
    // also yields the temperature/water fit outputs. Groups of the same type in
    // one cell therefore share the result; cache per type within the cell call.
    thread_local std::vector<uint32_t> climate_type_stamp;
    thread_local std::vector<int64_t> climate_type_capacity;
    thread_local std::vector<int64_t> climate_type_temperature_fit;
    thread_local std::vector<int64_t> climate_type_water_fit;
    thread_local uint32_t climate_type_generation = 0;
    if (climate_type_stamp.size() < _building_types.size()) {
        climate_type_stamp.assign(_building_types.size(), 0);
        climate_type_capacity.resize(_building_types.size(), 0);
        climate_type_temperature_fit.resize(_building_types.size(), Q16_ONE);
        climate_type_water_fit.resize(_building_types.size(), Q16_ONE);
    }
    if (++climate_type_generation == 0) {
        std::fill(climate_type_stamp.begin(), climate_type_stamp.end(), 0);
        climate_type_generation = 1;
    }
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
    int64_t &_food_output_eq = result.food_output_eq;
    int64_t &_food_input_eq = result.food_input_eq;
    int64_t &_maintenance_goods_consumed = result.maintenance_goods_consumed;
    int64_t &_maintenance_unmet = result.maintenance_unmet;
    int64_t &_maintenance_unpaid_value = result.maintenance_unpaid_value;
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
        int32_t output_index = -1;
        int32_t type_id = -1;
        int64_t qty = 0;
        int64_t retained = 0;
        int64_t sellable = 0;
        int64_t merchant_sold = 0;
        int64_t supported = 0;
        int64_t support_paid = 0;
        int64_t bullion_sold = 0;
        int64_t unit_cost = 0;
    };
    thread_local std::vector<Offer> offers;
    thread_local std::vector<Offer> accepted_anchor_sales;
    accepted_anchor_sales.clear();
    thread_local std::vector<int64_t> operation_receipts_by_group;
    thread_local std::vector<int64_t> business_tax_by_group;
    thread_local std::vector<int64_t> business_transfer_by_group;
    offers.clear();
    const int32_t market = market_store().cell_to_market[cell];
    const int32_t begin = _building_cell_offsets.size() == static_cast<size_t>(_cell_count.get() + 1)
        ? _building_cell_offsets[cell] : 0;
    const int32_t end = _building_cell_offsets.size() == static_cast<size_t>(_cell_count.get() + 1)
        ? _building_cell_offsets[cell + 1] : 0;
    const bool income_tax_active =
        (_epoch_active_tax_mask & static_cast<uint8_t>(
            1U << CountryApi::TAX_INCOME)) != 0;
    const bool business_tax_active =
        (_epoch_active_tax_mask & static_cast<uint8_t>(
            1U << CountryApi::TAX_BUSINESS)) != 0;
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
            std::max<int64_t>(0, population_store().funds[_merchant_slots[k]]), _saturation_count);
    }
    int64_t merchant_procurement_remaining = mul_div_sat(
        merchant_opening_cash, Q16_ONE - _merchant_procurement_cash_reserve_q16.get(),
        Q16_ONE, _saturation_count);
    _merchant_procurement_budget = saturating_add(
        _merchant_procurement_budget, merchant_procurement_remaining, _saturation_count);
    _merchant_procurement_reserved = saturating_add(
        _merchant_procurement_reserved,
        merchant_opening_cash - merchant_procurement_remaining, _saturation_count);

    // Production must see the same merchant-backed operating-credit envelope
    // that the planning pass used.  The old production path hard-coded this
    // to zero, so an owner whose cash was exhausted was silently clamped to
    // zero funded capacity even when local merchants had drawable liquidity.
    // Keep this budget local to the cell and consume it only after a real draw;
    // the merchant debit remains the ledger authority for the cash transfer.
    int64_t outstanding_principal = 0;
    for (int32_t g = begin; g < end; ++g) {
        outstanding_principal = saturating_add(
            outstanding_principal,
            std::max<int64_t>(0, buildings_store().merchant_debt_principal[g]),
            _saturation_count);
    }
    if (_pending_construction_cell_offsets.size() ==
            static_cast<size_t>(_cell_count.get() + 1)) {
        for (int32_t cursor = _pending_construction_cell_offsets[cell];
             cursor < _pending_construction_cell_offsets[cell + 1]; ++cursor) {
            const auto &pending = pending_construction()[static_cast<size_t>(
                _pending_construction_cell_indices[cursor])];
            outstanding_principal = saturating_add(
                outstanding_principal,
                std::max<int64_t>(0, pending.merchant_debt_principal),
                _saturation_count);
        }
    }
    const int64_t exposure_limit = mul_div_sat(
        merchant_opening_cash, _merchant_credit_exposure_q16.get(), Q16_ONE,
        _saturation_count);
    int64_t cell_credit_remaining = std::max<int64_t>(0, std::min(
        exposure_limit - std::min(exposure_limit, outstanding_principal),
        merchant_opening_cash - std::min(merchant_opening_cash,
            mul_div_sat(merchant_opening_cash,
                _merchant_procurement_cash_reserve_q16.get(), Q16_ONE,
                _saturation_count))));
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
        population_store().for_each_in_cell(cell, [&](int32_t slot) {
            trace_cell_slots.push_back(slot);
            trace_cell_funds.push_back(population_store().funds[slot]);
            trace_cell_income.push_back(population_store().epoch_income[slot]);
            trace_cell_expense.push_back(population_store().epoch_expense[slot]);
        });
        trace_market_stock.resize(market_store().good_count.get());
        for (int32_t good = 0; good < market_store().good_count.get(); ++good) {
            trace_market_stock[good] = market_store().stock[market_store().index(market, good)];
        }
        trace_resource_delta.resize(_resource_ids.size());
        for (size_t resource = 0; resource < _resource_ids.size(); ++resource) {
            trace_resource_delta[resource] = resource_delta_lanes()[
                resource * static_cast<size_t>(_cell_count.get()) + cell];
        }
    }
    thread_local std::vector<BuildingGroup> trace_before;
    trace_before.clear();
    if (trace_detail) {
        trace_before.reserve(static_cast<size_t>(std::max(0, end - begin)));
        for (int32_t g = begin; g < end; ++g)
            trace_before.push_back(building_group_copy(static_cast<size_t>(g)));
    }
    auto produces_cycle_flow = [&](const BuildingType &type) {
        for (int32_t i = 0; i < type.output_count; ++i) {
            const int32_t good = _building_outputs[type.output_begin + i].good_id;
            if (_good_storage_modes[good] == 1) return true;
        }
        return false;
    };
#include "economy_runtime_building_production_owner_retention_plan.inc"
#include "economy_runtime_building_production_input_quote.inc"
#include "economy_runtime_building_production_working_capital.inc"
    const auto production_phases_started = Clock::now();
    auto process_phase = [&](bool cycle_flow_phase) -> bool {
#include "economy_runtime_building_production_process_output.inc"
#include "economy_runtime_building_production_sales_allocation.inc"
#include "economy_runtime_building_production_sales_settlement.inc"
        return true;
    };
    if (!process_phase(true) || !process_phase(false)) {
        _production_result_sink = previous_sink;
        return false;
    }
    EconomyCostProbe::record("production.sec_phases", _current_day.get(),
                             elapsed_ms(production_phases_started));
    const auto production_rest_started = Clock::now();

#include "economy_runtime_building_production_compensation.inc"
#include "economy_runtime_building_production_maintenance_and_tax.inc"
#include "economy_runtime_building_production_market_signals.inc"
    EconomyCostProbe::record("production.sec_rest", _current_day.get(),
                             elapsed_ms(production_rest_started));
    _production_result_sink = previous_sink;
    return true;
}
void NativeEconomyRuntime::merge_building_production_result(ProductionResult &result) {
    if (result.ok) record_annual_production(result.cell);
    for (const size_t lane : result.audit_population_lanes)
        audit_touch_population_lane(static_cast<int32_t>(lane));
    for (const size_t lane : result.audit_market_lanes)
        audit_touch_market_lane(lane);
    merge_economy_worker_changes(result.market_changes);
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
    merge(_maintenance_goods_consumed, result.maintenance_goods_consumed);
    merge(_maintenance_unmet, result.maintenance_unmet);
    merge(_maintenance_unpaid_value, result.maintenance_unpaid_value);
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
    merge(_food_output_events, result.food_output_events);
    merge(_food_input_events, result.food_input_events);
    if (result.cell >= 0 && result.cell < _cell_count.get()) {
        const size_t cell = static_cast<size_t>(result.cell);
        if (cell < _cell_food_output_eq_period.size())
            _cell_food_output_eq_period[cell] = saturating_add(
                _cell_food_output_eq_period[cell], result.food_output_eq,
                _saturation_count);
        if (cell < _cell_food_input_eq_period.size())
            _cell_food_input_eq_period[cell] = saturating_add(
                _cell_food_input_eq_period[cell], result.food_input_eq,
                _saturation_count);
    }
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
    merge(_active_unfunded_building_groups, result.active_unfunded_building_groups);
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
    const size_t intro_n = std::min(result.bio_introduce_cells.size(),
                                    result.bio_introduce_bits.size());
    for (size_t i = 0; i < intro_n; ++i) {
        commit_bio_introduce(result.bio_introduce_cells[i],
                             result.bio_introduce_bits[i]);
    }
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
