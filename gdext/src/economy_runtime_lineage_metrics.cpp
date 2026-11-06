#include "economy_cost_probe.h"
#include "economy_runtime.h"
#include "economy_hash.h"
#include "runtime_switch_registry.h"
#include "economy_graph_kernels.h"
#include "economy_graph_live_ops.h"
#include "economy_graph_stage_dispatch.h"
#include "runtime_economy_pod.h"
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

bool NativeEconomyRuntime::evaluate_family_behavior_conditions(
        int32_t edge, const int64_t *metrics, int32_t metric_count) const {
    if (edge < 0 || edge + 1 >= static_cast<int32_t>(
            _family_trait_behavior_condition_offsets.size()) ||
        metrics == nullptr)
        return false;
    const int32_t begin = _family_trait_behavior_condition_offsets[edge];
    const int32_t end = _family_trait_behavior_condition_offsets[
        static_cast<size_t>(edge) + 1];
    if (begin == end) return true;
    constexpr int32_t MAX_STACK = 8;
    std::array<uint8_t, MAX_STACK> stack{};
    int32_t sp = 0;
    auto metric = [&](int32_t id) -> int64_t {
        if (id < 0 || id >= metric_count) return 0;
        return metrics[id];
    };
    for (int32_t i = begin; i < end; ++i) {
        const int32_t op = _family_trait_behavior_condition_ops[i];
        const int32_t arg0 = _family_trait_behavior_condition_arg0[i];
        const int64_t value = _family_trait_behavior_condition_values[i];
        bool result = false;
        switch (op) {
            case 1: result = true; break;
            case 2: result = metric(arg0) >= value; break;
            case 3: result = metric(arg0) <= value; break;
            case 4: result = metric(arg0) == value; break;
            case 5: return false;
            case 6:
                if (sp < 2) return false;
                result = stack[sp - 2] != 0 && stack[sp - 1] != 0;
                --sp;
                stack[sp - 1] = result ? 1 : 0;
                continue;
            case 7:
                if (sp < 2) return false;
                result = stack[sp - 2] != 0 || stack[sp - 1] != 0;
                --sp;
                stack[sp - 1] = result ? 1 : 0;
                continue;
            case 8:
                if (sp < 1) return false;
                stack[sp - 1] = stack[sp - 1] == 0 ? 1 : 0;
                continue;
            default: return false;
        }
        if (sp >= MAX_STACK) return false;
        stack[sp++] = result ? 1 : 0;
    }
    return sp > 0 && stack[sp - 1] != 0;
}

int32_t NativeEconomyRuntime::building_local_resource_abundance_q16(
        int32_t cell, int32_t type_id) const {
    if (cell < 0 || cell >= _cell_count.get() || type_id < 0 ||
        type_id >= static_cast<int32_t>(_building_types.size()))
        return Q16_ONE;
    const BuildingType &type = _building_types[type_id];
    if (type.resource_count <= 0) return Q16_ONE;
    int64_t total = 0;
    int32_t counted = 0;
    int64_t sat = 0;
    for (int32_t edge = 0; edge < type.resource_count; ++edge) {
        const ResourceAmount &item = _building_resources[
            type.resource_begin + edge];
        if (item.resource_id < 0) continue;
        const size_t idx = static_cast<size_t>(item.resource_id) *
            static_cast<size_t>(_cell_count.get()) + static_cast<size_t>(cell);
        if (idx >= resource_stock_lanes().size() || resource_stock_lanes()[idx] <= 0)
            continue;
        const int64_t remaining = idx < resource_remaining_lanes().size()
            ? std::max<int64_t>(0, resource_remaining_lanes()[idx])
            : resource_stock_lanes()[idx];
        total = saturating_add(total, mul_div_sat(remaining, Q16_ONE,
            resource_stock_lanes()[idx], sat), sat);
        ++counted;
    }
    if (counted <= 0) return Q16_ONE;
    return static_cast<int32_t>(std::clamp<int64_t>(
        total / counted, 0, Q16_ONE));
}

int32_t NativeEconomyRuntime::cell_profession_share_q16(
        int32_t cell, int32_t profession_id) const {
    if (cell < 0 || cell >= _cell_count.get() || profession_id < 0) return 0;
    int64_t population = 0;
    int64_t employed = 0;
    population_store().for_each_in_cell(cell, [&](int32_t slot) {
        population += std::max<int64_t>(0, population_store().population[slot]);
        const int32_t signature = static_cast<int32_t>(population_store().signature_id[slot]);
        if (signature < 0 || signature >= static_cast<int32_t>(_signatures.size()))
            return;
        if (_signatures[signature].profession_id != profession_id) return;
        employed += std::max<int64_t>(0, population_store().owner_employed[slot]);
        employed += std::max<int64_t>(0, population_store().employee_employed[slot]);
    });
    if (population <= 0) return 0;
    int64_t sat = 0;
    return static_cast<int32_t>(std::clamp<int64_t>(
        mul_div_sat(employed, Q16_ONE, population, sat), 0, Q16_ONE));
}

int32_t NativeEconomyRuntime::family_variant_preference_factor_q16(
        int32_t cohort_slot, int32_t variant_id, int64_t &sat, int32_t *good_factors) const {
    if (variant_id < 0 || variant_id >= static_cast<int32_t>(_variants.size()))
        return Q16_ONE;
    const VariantChoice &variant = _variants[variant_id];
    int64_t quantity_sum = 0;
    int64_t weighted_sum = 0;
    for (int32_t c = 0; c < variant.component_count; ++c) {
        const NeedComponent &component = _components[variant.component_begin + c];
        const int64_t quantity = std::max<int64_t>(1, component.qty_per_need);
        int32_t factor = -1;
        const bool cacheable = good_factors != nullptr && component.good_id >= 0 &&
            component.good_id < static_cast<int32_t>(_good_ids.size());
        if (cacheable) factor = good_factors[component.good_id];
        if (factor < 0) {
            factor = family_good_consumption_factor_q16(cohort_slot, component.good_id);
            if (cacheable) good_factors[component.good_id] = factor;
        } else {
            static const bool verify = [] {
                const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_MEMO_VERIFY);
                return value && std::strcmp(value, "1") == 0;
            }();
            if (verify && factor != family_good_consumption_factor_q16(cohort_slot, component.good_id)) {
                std::fprintf(stderr, "[family-good-factor-cache-mismatch] slot=%d good=%d\n",
                    cohort_slot, component.good_id);
                std::abort();
            }
        }
        // 单组件的加权平均恒等于 factor；界内乘法不会产生饱和事件。
        static const bool scalar_variant = [] {
            const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_VARIANT_WEIGHT_SCALAR);
            return value && std::strcmp(value, "1") == 0;
        }();
        if (!scalar_variant && variant.component_count == 1 && quantity <=
                std::numeric_limits<int64_t>::max() / (4 * Q16_ONE))
            return factor;
        quantity_sum = saturating_add(quantity_sum, quantity, sat);
        weighted_sum = saturating_add(weighted_sum, saturating_mul(
            quantity, factor, sat), sat);
    }
    return quantity_sum > 0 ? static_cast<int32_t>(std::clamp<int64_t>(
        mul_div_sat(weighted_sum, 1, quantity_sum, sat), 0, 4 * Q16_ONE))
        : Q16_ONE;
}

int64_t NativeEconomyRuntime::building_reset_capital_value(
        BuildingGroupConstRef group) const {
    if (group.cell < 0 || group.cell >= _cell_count.get() || group.type_id < 0 ||
        group.type_id >= static_cast<int32_t>(_building_types.size()) ||
        group.count <= 0) return 0;
    const int32_t market = market_store().cell_to_market[group.cell];
    if (market < 0 || market >= market_store().market_count.get()) return 0;
    const BuildingType &type = _building_types[group.type_id];
    int64_t sat = 0;
    int64_t construction = 0;
    for (int32_t i = 0; i < type.construction_count; ++i) {
        const GoodAmount &item = _building_construction_goods[
            type.construction_begin + i];
        construction = saturating_add(construction, mul_div_sat(
            item.quantity, market_store().price[market_store().index(market, item.good_id)],
            GOODS_SCALE, sat), sat);
    }
    const int64_t operating_per_building = std::max<int64_t>(0,
        group.last_operating_cost) / std::max<int64_t>(1, group.count);
    const int64_t reserve = saturating_mul(operating_per_building,
        std::max(1, _investment_operating_cycles.get()), sat);
    return saturating_add(construction, reserve, sat);
}

bool NativeEconomyRuntime::family_free_building_resources_legal(
        int32_t cell, int32_t type_id, int64_t count) const {
    if (cell < 0 || cell >= _cell_count.get() || type_id < 0 ||
        type_id >= static_cast<int32_t>(_building_types.size()) || count <= 0 ||
        _building_cell_offsets.size() != static_cast<size_t>(_cell_count.get() + 1)) {
        return false;
    }
    const BuildingType &reward_type = _building_types[type_id];
    int64_t sat = 0;
    for (int32_t target_edge = 0; target_edge < reward_type.resource_count;
         ++target_edge) {
        const ResourceAmount &target = _building_resources[
            reward_type.resource_begin + target_edge];
        if (target.mode != 0 || target.quantity <= 0) continue;
        if (target.resource_id < 0 || target.resource_id >=
                static_cast<int32_t>(_resource_ids.size())) {
            return false;
        }
        bool already_checked = false;
        int64_t requested_per_building = 0;
        for (int32_t edge = 0; edge < reward_type.resource_count; ++edge) {
            const ResourceAmount &item = _building_resources[
                reward_type.resource_begin + edge];
            if (item.mode != 0 || item.quantity <= 0 ||
                item.resource_id != target.resource_id) continue;
            if (edge < target_edge) already_checked = true;
            requested_per_building = saturating_add(
                requested_per_building, item.quantity, sat);
        }
        if (already_checked) continue;

        int64_t committed = 0;
        const auto add_commitment = [&](int32_t committed_type,
                                        int64_t committed_count) {
            if (committed_type < 0 || committed_type >= static_cast<int32_t>(
                    _building_types.size()) || committed_count <= 0) return;
            const BuildingType &type = _building_types[committed_type];
            int64_t per_building = 0;
            for (int32_t edge = 0; edge < type.resource_count; ++edge) {
                const ResourceAmount &item = _building_resources[
                    type.resource_begin + edge];
                if (item.mode == 0 && item.quantity > 0 &&
                    item.resource_id == target.resource_id) {
                    per_building = saturating_add(
                        per_building, item.quantity, sat);
                }
            }
            committed = saturating_add(committed, saturating_mul(
                committed_count, per_building, sat), sat);
        };
        for (int32_t group = _building_cell_offsets[cell];
             group < _building_cell_offsets[cell + 1]; ++group) {
            add_commitment(buildings_store().type_id[group],
                           buildings_store().group_units[group]);
        }
        if (_pending_construction_cell_offsets.size() ==
                static_cast<size_t>(_cell_count.get() + 1)) {
            for (int32_t cursor = _pending_construction_cell_offsets[cell];
                 cursor < _pending_construction_cell_offsets[cell + 1];
                 ++cursor) {
                const int32_t pending_index =
                    _pending_construction_cell_indices[cursor];
                if (pending_index < 0 || pending_index >= static_cast<int32_t>(
                        pending_construction_count())) return false;
                const auto pending = pending_construction()[
                    static_cast<size_t>(pending_index)];
                add_commitment(pending.type_id, pending.count);
            }
        }
        // Reward commands are applied after the epoch's pending CSR is frozen.
        // Only the newly appended tail can be absent from that local index.
        const size_t indexed_pending =
            _pending_construction_cell_indices.size();
        for (size_t pending_index = indexed_pending;
             pending_index < pending_construction_count(); ++pending_index) {
            const auto pending = pending_construction()[pending_index];
            if (pending.cell == cell)
                add_commitment(pending.type_id, pending.count);
        }

        const size_t lane = static_cast<size_t>(target.resource_id) *
            static_cast<size_t>(_cell_count.get()) + static_cast<size_t>(cell);
        int64_t daily_budget = 0;
        if (resource_is_renewable(target.resource_id)) {
            daily_budget = renewable_safe_harvest(target.resource_id, cell);
        } else if (lane < resource_stock_lanes().size()) {
            const bool initialized =
                lane < resource_lane_generation_lanes().size() &&
                resource_lane_generation_lanes()[lane] ==
                    _resource_current_generation;
            const int64_t remaining = initialized &&
                    lane < resource_remaining_lanes().size()
                ? resource_remaining_lanes()[lane]
                : resource_stock_lanes()[lane];
            daily_budget = std::max<int64_t>(0, remaining) /
                std::max<int64_t>(1, _resource_min_horizon_days.get());
        }
        const int64_t requested = saturating_mul(
            count, requested_per_building, sat);
        if (committed > daily_budget || requested > daily_budget - committed)
            return false;
    }
    return true;
}

} // namespace pk
