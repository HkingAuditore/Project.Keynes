#include "economy_cost_probe.h"
#include "economy_runtime.h"
#include "economy_hash.h"
#include "runtime_switch_registry.h"
#include "economy_graph_kernels.h"
#include "economy_graph_live_ops.h"
#include "economy_graph_stage_dispatch.h"
#include "runtime_economy_pod.h"
#include "native_simulation_host.h"
#include "economy_runtime_variant_helpers.h"
#include "parallel_dispatcher.h"
#include "pk_log.h"

#include <algorithm>
#include <array>
#include <cassert>
#include <chrono>
#include <charconv>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <iterator>
#include <limits>
#include <map>
#include <numeric>
#include <tuple>
#include <type_traits>
#include <unordered_map>
#include <unordered_set>

#if defined(_MSC_VER) && defined(_M_X64)
#include <intrin.h>
#endif

#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/variant/variant.hpp>

namespace pk {
using namespace godot;
using namespace variant_helpers;

int64_t NativeEconomyRuntime::credit_local_merchants(int32_t cell, int64_t amount,
                                                     int32_t cashflow_source,
                                                     int64_t *saturation_override) {
    int64_t &_saturation_count = saturation_override != nullptr
        ? *saturation_override : this->_saturation_count;
    amount = std::max<int64_t>(0, amount);
    if (amount == 0 || cell < 0 || cell >= _cell_count.get()) return 0;
    const int32_t begin = _merchant_offsets[cell];
    const int32_t end = _merchant_offsets[cell + 1];
    int64_t total_population = 0;
    for (int32_t k = begin; k < end; ++k) {
        if (!is_merchant_slot(_merchant_slots[k])) continue;
        total_population = saturating_add(total_population,
            population_store().population[_merchant_slots[k]], _saturation_count);
    }
    if (total_population <= 0) return 0;
    int64_t prefix = 0;
    int64_t distributed = 0;
    for (int32_t k = begin; k < end; ++k) {
        const int32_t slot = _merchant_slots[k];
        if (!is_merchant_slot(slot)) continue;
        touch_accounting_slot(slot);
        prefix = saturating_add(prefix, population_store().population[slot], _saturation_count);
        const int64_t next = mul_div_sat(amount, prefix, total_population, _saturation_count);
        const int64_t share = std::max<int64_t>(0, next - distributed);
        distributed = next;
        population_store().funds.write_scalar(slot, saturating_add(population_store().funds[slot], share, _saturation_count), market_mutation_sink());
        population_store().epoch_income.write_scalar(slot, saturating_add(population_store().epoch_income[slot], share,
                                                        _saturation_count), market_mutation_sink());
        trace_record_cashflow(cell, population_store().handle_for_slot(slot), cashflow_source,
                              share, 0);
    }
    return distributed;
}

bool NativeEconomyRuntime::local_merchants_can_receive(int32_t cell) const {
    if (cell < 0 || cell >= _cell_count.get() ||
        _merchant_offsets.size() != static_cast<size_t>(_cell_count.get() + 1))
        return false;
    for (int32_t k = _merchant_offsets[cell]; k < _merchant_offsets[cell + 1]; ++k) {
        if (is_merchant_slot(_merchant_slots[k])) return true;
    }
    return false;
}

int64_t NativeEconomyRuntime::debit_local_merchants(int32_t cell, int64_t amount,
                                                    int32_t cashflow_source,
                                                    int64_t *saturation_override) {
    int64_t &_saturation_count = saturation_override != nullptr
        ? *saturation_override : this->_saturation_count;
    amount = std::max<int64_t>(0, amount);
    if (amount == 0 || cell < 0 || cell >= _cell_count.get()) return 0;
    const int32_t begin = _merchant_offsets[cell];
    const int32_t end = _merchant_offsets[cell + 1];
    int64_t total_funds = 0;
    for (int32_t k = begin; k < end; ++k) {
        total_funds = saturating_add(total_funds,
            std::max<int64_t>(0, population_store().funds[_merchant_slots[k]]), _saturation_count);
    }
    const int64_t target = std::min(amount, total_funds);
    if (target <= 0) return 0;
    int64_t prefix = 0;
    int64_t distributed = 0;
    for (int32_t k = begin; k < end; ++k) {
        const int32_t slot = _merchant_slots[k];
        touch_accounting_slot(slot);
        prefix = saturating_add(prefix, std::max<int64_t>(0, population_store().funds[slot]),
                                _saturation_count);
        const int64_t next = mul_div_sat(target, prefix, total_funds, _saturation_count);
        const int64_t share = std::min(std::max<int64_t>(0, next - distributed),
                                       std::max<int64_t>(0, population_store().funds[slot]));
        distributed = saturating_add(distributed, share, _saturation_count);
        population_store().funds.write_scalar(slot, population_store().funds[slot] - (share), market_mutation_sink());
        population_store().epoch_expense.write_scalar(slot, saturating_add(
            population_store().epoch_expense[slot], share, _saturation_count), market_mutation_sink());
        trace_record_cashflow(cell, population_store().handle_for_slot(slot), cashflow_source,
                              0, share);
    }
    return distributed;
}

int64_t NativeEconomyRuntime::effective_building_output_quantity(
        BuildingGroupConstRef group, int32_t good_id, int64_t base_quantity,
        int64_t utilization_q16, int64_t building_days,
        int64_t &sat) const {
    return effective_building_output_quantity_at(
        group.cell, group.output_factor_q16, good_id, base_quantity,
        utilization_q16, building_days, sat);
}

int64_t NativeEconomyRuntime::effective_building_output_quantity_at(
        int32_t cell, int32_t output_factor_q16, int32_t good_id,
        int64_t base_quantity, int64_t utilization_q16, int64_t building_days,
        int64_t &sat) const {
    const int64_t physical_base = saturating_mul(
        std::max<int64_t>(0, base_quantity),
        std::max<int64_t>(0, building_days), sat);
    const int64_t utilized = mul_div_sat(
        physical_base, std::clamp<int64_t>(utilization_q16, 0, Q16_ONE),
        Q16_ONE, sat);
    const int64_t building_output = mul_div_sat(utilized,
        std::max<int32_t>(0, output_factor_q16), Q16_ONE, sat);
    const int32_t country_slot = cell >= 0 &&
            cell < static_cast<int32_t>(_epoch_cell_country.size())
        ? _epoch_cell_country[static_cast<size_t>(cell)] : -1;
    const size_t good_factor_index = static_cast<size_t>(
        std::max(0, country_slot)) * _good_ids.size() +
        static_cast<size_t>(std::max(0, good_id));
    const int64_t good_factor_q16 = country_slot >= 0 && good_id >= 0 &&
            good_factor_index < _epoch_country_good_output_factor_q16.size()
        ? _epoch_country_good_output_factor_q16[good_factor_index] : Q16_ONE;
    const int64_t country_good_output = mul_div_sat(
        building_output, std::max<int64_t>(0, good_factor_q16), Q16_ONE, sat);
    return mul_div_sat(country_good_output, std::max<int32_t>(0,
        city_good_output_factor_q16(cell, good_id)), Q16_ONE, sat);
}

int64_t NativeEconomyRuntime::effective_production_input_quantity(
        int32_t cell, int32_t good_id, int64_t base_quantity,
        int64_t &sat) const {
    const int32_t country = cell >= 0 && cell < static_cast<int32_t>(
            _epoch_cell_country.size()) ? _epoch_cell_country[cell] : -1;
    if (country < 0 || good_id < 0 || good_id >= static_cast<int32_t>(
            _good_ids.size()) || country >= static_cast<int32_t>(
            _epoch_country_production_input_factor_q16.size()))
        return std::max<int64_t>(0, base_quantity);
    int64_t quantity = mul_div_sat(std::max<int64_t>(0, base_quantity),
        _epoch_country_production_input_factor_q16[country], Q16_ONE, sat);
    const size_t index = static_cast<size_t>(country) * _good_ids.size() + good_id;
    if (index >= _epoch_country_good_input_factor_q16.size()) return quantity;
    return mul_div_sat(quantity, _epoch_country_good_input_factor_q16[index],
        Q16_ONE, sat);
}

int64_t NativeEconomyRuntime::effective_resource_use_quantity(
        int32_t cell, int32_t resource_id, int64_t base_quantity,
        int64_t &sat) const {
    const int32_t country = cell >= 0 && cell < static_cast<int32_t>(
            _epoch_cell_country.size()) ? _epoch_cell_country[cell] : -1;
    if (country < 0 || resource_id < 0 || resource_id >= static_cast<int32_t>(
            _resource_ids.size()) || country >= static_cast<int32_t>(
            _epoch_country_resource_global_use_factor_q16.size()))
        return std::max<int64_t>(0, base_quantity);
    int64_t quantity = mul_div_sat(std::max<int64_t>(0, base_quantity),
        _epoch_country_resource_global_use_factor_q16[country], Q16_ONE, sat);
    const size_t index = static_cast<size_t>(country) * _resource_ids.size() + resource_id;
    if (index >= _epoch_country_resource_use_factor_q16.size()) return quantity;
    return mul_div_sat(quantity, _epoch_country_resource_use_factor_q16[index],
        Q16_ONE, sat);
}

int64_t NativeEconomyRuntime::effective_managed_resource_generation(
        int32_t cell, int32_t resource_id, int64_t base_quantity,
        int64_t &sat) const {
    const int32_t country = cell >= 0 && cell < static_cast<int32_t>(
            _epoch_cell_country.size()) ? _epoch_cell_country[cell] : -1;
    if (country < 0 || resource_id < 0 || resource_id >= static_cast<int32_t>(
            _resource_ids.size())) return std::max<int64_t>(0, base_quantity);
    const size_t index = static_cast<size_t>(country) * _resource_ids.size() + resource_id;
    if (index >= _epoch_country_resource_generation_factor_q16.size())
        return std::max<int64_t>(0, base_quantity);
    return mul_div_sat(std::max<int64_t>(0, base_quantity),
        _epoch_country_resource_generation_factor_q16[index], Q16_ONE, sat);
}

int64_t NativeEconomyRuntime::effective_household_good_quantity(
        int32_t cell, int32_t good_id, int64_t base_quantity,
        int64_t &sat) const {
    const int32_t country = cell >= 0 && cell < static_cast<int32_t>(
            _epoch_cell_country.size()) ? _epoch_cell_country[cell] : -1;
    if (country < 0 || good_id < 0 || good_id >= static_cast<int32_t>(
            _good_ids.size())) return std::max<int64_t>(0, base_quantity);
    const size_t index = static_cast<size_t>(country) * _good_ids.size() + good_id;
    if (index >= _epoch_country_good_consumption_factor_q16.size())
        return std::max<int64_t>(0, base_quantity);
    return mul_div_sat(std::max<int64_t>(0, base_quantity),
        _epoch_country_good_consumption_factor_q16[index], Q16_ONE, sat);
}

int64_t NativeEconomyRuntime::planned_owner_demand(
        BuildingGroupConstRef group, int64_t &sat) const {
    if (group.type_id < 0 ||
        group.type_id >= static_cast<int32_t>(_building_types.size()) ||
        group.count <= 0 ||
        !building_available(group.cell, group.type_id, true))
        return 0;
    const BuildingType &type = _building_types[group.type_id];
    const int64_t full = saturating_mul(
        group.count, type.owner_slots_per_building, sat);
    if (full <= 0) return 0;
    // ACTIVE self-employment keeps every physical owner position. Utilization
    // scales work and output per building, not the number of proprietors.
    if (group.operating_state == 0) return full;
    // A suspended producer is not an employment target. Keeping its owner
    // demand alive used to pin proprietors to a zero-output lot while its hard
    // inputs were unavailable. That made upstream food vacancies impossible
    // to staff and created a starvation loop. Recovery is decided by the
    // economic plan above; when it becomes viable, pending_operating_state is
    // flipped to ACTIVE and the next employment pass hires by the normal
    // income comparison.
    if (group.operating_state == 1) {
        return 0;
    }
    return 0;
}

NativeEconomyRuntime::OwnerOpportunityQuote
NativeEconomyRuntime::owner_opportunity_quote(
        BuildingGroupConstRef group, int64_t owner_fillability_q16,
        int64_t employee_fillability_q16, int64_t &sat) const {
    auto &memo = living_cost_memo_state();
    if (memo.owner != this || !memo.quote_enabled || group.cell < 0 ||
        group.cell >= _cell_count.get() || group.type_id < 0 ||
        group.type_id >= static_cast<int32_t>(_building_types.size()))
        return owner_opportunity_quote_uncached(group, owner_fillability_q16, employee_fillability_q16, sat);
    const auto &type = _building_types[group.type_id];
    const int32_t owner = find_cohort_slot(group.cell, group.owner_signature_id);
    // Reuse one thread-local key vector: constructing a fresh std::vector per
    // call was a heap allocation on every quote probe (hit or miss).
    thread_local std::vector<int64_t> key;
    key.clear();
    key.reserve(static_cast<size_t>(32 + type.employee_count * 3));
    key.push_back(group.cell);
    key.push_back(group.type_id);
    key.push_back(group.owner_signature_id);
    key.push_back(group.count);
    key.push_back(group.filled_owner);
    key.push_back(group.operating_state);
    key.push_back(group.last_climate_capacity_q16);
    key.push_back(group.last_observed_capacity_days_q16);
    key.push_back(group.output_factor_q16);
    key.push_back(owner_fillability_q16);
    key.push_back(employee_fillability_q16);
    key.push_back(owner);
    key.push_back(owner >= 0 ? population_store().funds[owner] : 0);
    key.push_back(owner >= 0 ? population_store().population[owner] : 0);
    for (int32_t role = 0; role < type.employee_count; ++role) {
        const int32_t index = group.employee_fill_begin + role;
        key.push_back(index);
        key.push_back(index >= 0 && index < static_cast<int32_t>(_building_employee_filled.size())
            ? _building_employee_filled[index] : 0);
        key.push_back(index >= 0 && index < static_cast<int32_t>(_building_role_contract_wage.size())
            ? _building_role_contract_wage[index] : 0);
    }
    const int32_t market = market_store().cell_to_market[group.cell];
    if (market >= 0 && market + 1 < static_cast<int32_t>(_merchant_offsets.size())) {
        for (int32_t i = _merchant_offsets[market]; i < _merchant_offsets[market + 1]; ++i) {
            const int32_t slot = _merchant_slots[i];
            if (slot < 0 || slot >= static_cast<int32_t>(population_store().active.size())) continue;
            key.push_back(slot); key.push_back(population_store().active[slot]);
            key.push_back(population_store().funds[slot]); key.push_back(population_store().population[slot]);
        }
    }
    const auto found = memo.quotes.find(key);
    if (found != memo.quotes.end()) {
        EconomyCostProbe::record("owner_quote.memo_hit", _current_day.get(), 0.0, 1);
        static const bool verify_owner_quote_memo = [] {
            const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_MEMO_VERIFY);
            return value && std::strcmp(value, "1") == 0;
        }();
        if (verify_owner_quote_memo) {
            const auto *previous_owner = memo.owner;
            memo.owner = nullptr;
            int64_t reference_sat = sat;
            const auto reference = owner_opportunity_quote_uncached(group, owner_fillability_q16, employee_fillability_q16, reference_sat);
            memo.owner = previous_owner;
            if (!(reference == *found->second.first) || reference_sat - sat != found->second.second) {
                std::fprintf(stderr, "[owner-quote-memo-mismatch] day=%lld cell=%d type=%d\n", static_cast<long long>(_current_day.get()), group.cell, group.type_id);
                std::abort();
            }
        }
        sat += found->second.second;
        return *found->second.first;
    }
    const int64_t before = sat;
    EconomyCostProbe::record("owner_quote.memo_miss", _current_day.get(), 0.0, 1);
    auto result = owner_opportunity_quote_uncached(group, owner_fillability_q16, employee_fillability_q16, sat);
    memo.quotes.emplace(std::vector<int64_t>(key),
        std::make_pair(std::make_shared<const OwnerOpportunityQuote>(result),
                       sat - before));
    return result;
}

int64_t NativeEconomyRuntime::building_debt_due(
        BuildingGroupConstRef group, int64_t &sat) const {
    const int64_t outstanding = saturating_add(
        std::max<int64_t>(0, group.merchant_debt_principal),
        std::max<int64_t>(0, group.merchant_debt_premium), sat);
    if (outstanding <= 0) return 0;
    const int64_t terms = std::max<int64_t>(
        1, group.merchant_debt_term_cycles_left);
    return saturating_add(outstanding, terms - 1, sat) / terms;
}

int64_t NativeEconomyRuntime::repay_building_debt(
        int32_t cell, int32_t owner_slot, BuildingGroupRef group,
        int64_t payment_cap, int64_t &premium_paid) {
    premium_paid = 0;
    if (owner_slot < 0 || payment_cap <= 0 ||
        (group.merchant_debt_principal <= 0 && group.merchant_debt_premium <= 0))
        return 0;
    // Employment can replace a merchant slot before the CSR is refreshed.
    // An unavailable recipient defers repayment; it must not burn owner cash.
    if (!local_merchants_can_receive(cell)) return 0;
    int64_t local_sat = 0;
    const int64_t due = building_debt_due(group, local_sat);
    _saturation_count = saturating_add(_saturation_count, local_sat, _saturation_count);
    const int64_t paid = std::min({
        due, payment_cap, std::max<int64_t>(0, population_store().funds[owner_slot])});
    if (paid <= 0) return 0;
    touch_accounting_slot(owner_slot);
    population_store().funds.write_scalar(owner_slot, population_store().funds[owner_slot] - (paid), market_mutation_sink());
    population_store().epoch_expense.write_scalar(owner_slot, saturating_add(
        population_store().epoch_expense[owner_slot], paid, _saturation_count), market_mutation_sink());
    trace_record_cashflow(cell, population_store().handle_for_slot(owner_slot),
                          CASHFLOW_OTHER, 0, paid);
    if (credit_local_merchants(cell, paid, CASHFLOW_MERCHANT_BUSINESS,
                               &_saturation_count) != paid)
        return 0;
    const int64_t principal_paid = std::min(paid, group.merchant_debt_principal);
    group.merchant_debt_principal -= principal_paid;
    premium_paid = paid - principal_paid;
    group.merchant_debt_premium = std::max<int64_t>(
        0, group.merchant_debt_premium - premium_paid);
    if (group.merchant_debt_principal == 0 && group.merchant_debt_premium == 0) {
        group.merchant_debt_term_cycles_left = 0;
        group.merchant_debt_delinquent_cycles = 0;
    }
    return paid;
}

} // namespace pk
