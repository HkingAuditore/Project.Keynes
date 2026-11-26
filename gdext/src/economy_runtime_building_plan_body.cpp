// NativeEconomyRuntime::prepare_building_economic_plan_body, extracted from economy_runtime.cpp; body is token-preserved.
#include "economy_cost_probe.h"
#include "economy_effect_forward.h"
#include "economy_runtime.h"
#include "economy_hash.h"
#include "runtime_switch_registry.h"
#include "economy_graph_kernels.h"
#include "economy_graph_live_ops.h"
#include "economy_graph_stage_dispatch.h"
#include "runtime_economy_pod.h"
#include "country_api.h"
#include "economy_runtime_internal_external_types.inc"
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


namespace {
int32_t modifier_factor_q16(double factor) {
    if (!std::isfinite(factor) || factor <= 0.0) return 0;
    const double scaled = std::round(factor *
        static_cast<double>(NativeEconomyRuntime::Q16_ONE));
    return static_cast<int32_t>(std::clamp(
        scaled, 0.0, static_cast<double>(std::numeric_limits<int32_t>::max())));
}
} // namespace

namespace {

using Clock = std::chrono::steady_clock;

// effect_pod_upsert / effect_pod_metric / effect_pod_retire now live in
// economy_effect_forward.h: the family write points are split across
// economy_runtime.cpp and economy_runtime_family_buff.cpp, and both translation
// units have to funnel through the same routing decision.

constexpr int64_t price_adjustment_reference(
        int64_t current_price, int64_t adjustment_anchor_price,
        int64_t period_change_q16) {
    return period_change_q16 < 0
        ? std::max<int64_t>(NativeEconomyRuntime::PRICE_NUMERIC_GUARD_MIN,
                            current_price)
        : adjustment_anchor_price;
}

static_assert(price_adjustment_reference(100, 1000, -1) == 100);
static_assert(price_adjustment_reference(100, 1000, 1) == 1000);

double elapsed_ms(const Clock::time_point &start) {
    return std::chrono::duration<double, std::milli>(Clock::now() - start).count();
}


} // namespace

// ─── PopulationStore ───────────────────────────────────────────────────

// PopulationStore implementation moved to economy_runtime_storage.cpp.

// PopulationStore allocation and lookup implementation moved to
// economy_runtime_storage.cpp.

// PopulationStore::allocate_slot implementation moved to
// economy_runtime_storage.cpp.

// PopulationStore handle/release implementation moved to
// economy_runtime_storage.cpp.



bool NativeEconomyRuntime::prepare_building_economic_plan_body(
        int32_t active_begin, int32_t active_end,
        const std::vector<int32_t> *cells_override,
        BuildingPlanResult &result, std::string &error) {
    result.reset();
    // These locals intentionally shadow epoch diagnostics. Cell/group state is
    // disjoint across worker ranges; diagnostics are reduced serially by the
    // caller after every task has completed.
    int64_t _saturation_count = 0;
    int64_t _merchant_credit_budget = 0;
    int64_t _merchant_credit_committed = 0;
    int64_t _recovery_candidates = 0;
    int64_t _recovery_approved = 0;
    int64_t _loss_suspended_building_groups = 0;
    int64_t _unprofitable_building_groups = 0;
    int64_t _utilization_sum_q16 = 0;
    auto publish_result = [&]() {
        result.saturation_count = _saturation_count;
        result.merchant_credit_budget = _merchant_credit_budget;
        result.merchant_credit_committed = _merchant_credit_committed;
        result.recovery_candidates = _recovery_candidates;
        result.recovery_approved = _recovery_approved;
        result.loss_suspended_building_groups =
            _loss_suspended_building_groups;
        result.unprofitable_building_groups =
            _unprofitable_building_groups;
        result.utilization_sum_q16 = _utilization_sum_q16;
    };
    constexpr int64_t DISCARD_RATE_TOLERANCE_Q16 = Q16_ONE / 100;
    constexpr int64_t HIGH_DISCARD_RATE_Q16 = Q16_ONE / 4;
    constexpr int64_t SEVERE_DISCARD_RATE_Q16 = Q16_ONE / 2;
    constexpr int64_t SHORTAGE_RECOVERY_THRESHOLD_Q16 = Q16_ONE / 8;
    constexpr int64_t STOCK_ROUNDING_TOLERANCE = 1;
    // 同一业主的生存食物产能合并计算，只保护跨过饥饿阈值所需的最低利用率。
    const std::vector<int32_t> &active_cells = cells_override != nullptr
        ? *cells_override
        : (_epoch_active ? _epoch_building_cells : _building_active_cells);
    active_begin = std::clamp<int32_t>(
        active_begin, 0, static_cast<int32_t>(active_cells.size()));
    active_end = std::clamp<int32_t>(
        active_end, active_begin, static_cast<int32_t>(active_cells.size()));
    // owner_seen_key 是 (generation, cell) 复合 stamp。原来这里是
    // owner_seen_cell.assign(_signatures.size(), -1)：每次调用都要写一遍整张
    // signature 表（随存档规模单调增长，且永不收缩）才能清掉上一次的残留，而单次
    // 调用实际触碰到的 owner 只有当前格的几个。把 generation 编进 stamp 后旧值自动
    // 失效，清表成本从 O(signatures) 降到 0——这也是"把切片调细反而不省时间"的来源。
    thread_local std::vector<uint64_t> owner_seen_key;
    thread_local uint64_t owner_seen_generation = 0;
    thread_local std::vector<uint8_t> owner_output_flags;
    thread_local std::vector<int64_t> owner_relevant_output;
    thread_local std::vector<int64_t> owner_floor_q16;
    thread_local std::vector<int64_t> owner_clothing_output;
    thread_local std::vector<int64_t> owner_clothing_floor_q16;
    thread_local std::vector<int32_t> touched_owners;
    // Legacy probe planner storage is retained only so old object files and
    // save diagnostics stay ABI-compatible. The planner branch below is
    // permanently disabled; suspended buildings never purchase or produce.
    thread_local std::vector<std::pair<int32_t, int64_t>> recovery_probe_goods;
    ++owner_seen_generation;
    owner_seen_key.resize(_signatures.size(), 0);
    owner_output_flags.resize(_signatures.size());
    owner_relevant_output.resize(_signatures.size());
    owner_floor_q16.resize(_signatures.size());
    owner_clothing_output.resize(_signatures.size());
    owner_clothing_floor_q16.resize(_signatures.size());
    if (_building_cell_offsets.size() == static_cast<size_t>(_cell_count.get() + 1)) {
        for (int32_t active = active_begin; active < active_end; ++active) {
            const int32_t cell = active_cells[active];
            const int32_t begin = _building_cell_offsets[cell];
            const int32_t end = _building_cell_offsets[cell + 1];
            const uint64_t cell_key = (owner_seen_generation << 32) |
                static_cast<uint32_t>(cell);
            touched_owners.clear();
            for (int32_t g = begin; g < end; ++g) {
                const auto group = building_view(static_cast<size_t>(g));
                if (group.count <= 0 || group.operating_state != 0 ||
                    !building_available(cell, group.type_id, true)) continue;
                if (group.owner_signature_id < 0 || group.owner_signature_id >=
                        static_cast<int32_t>(owner_seen_key.size())) continue;
                const int32_t owner = group.owner_signature_id;
                if (owner_seen_key[owner] != cell_key) {
                    owner_seen_key[owner] = cell_key;
                    owner_output_flags[owner] = 0;
                    owner_relevant_output[owner] = 0;
                    owner_floor_q16[owner] = 0;
                    owner_clothing_output[owner] = 0;
                    owner_clothing_floor_q16[owner] = 0;
                    touched_owners.push_back(owner);
                }
                const BuildingType &type = _building_types[group.type_id];
                for (int32_t i = 0; i < type.output_count; ++i) {
                    const int32_t good = _building_outputs[type.output_begin + i].good_id;
                    if (_survival_food_good_mask[good] != 0)
                        owner_output_flags[owner] |= 1;
                    if (_survival_clothing_good_mask[good] != 0)
                        owner_output_flags[owner] |= 4;
                }
            }
            for (int32_t g = begin; g < end; ++g) {
                const auto group = building_view(static_cast<size_t>(g));
                if (group.count <= 0 || group.operating_state != 0 ||
                    !building_available(cell, group.type_id, true)) continue;
                const int32_t owner = group.owner_signature_id;
                if (owner < 0 || owner >= static_cast<int32_t>(owner_seen_key.size()) ||
                    owner_seen_key[owner] != cell_key || (owner_output_flags[owner] & 5) == 0)
                    continue;
                const BuildingType &type = _building_types[group.type_id];
                int64_t group_relevant_output = 0;
                int64_t group_clothing_output = 0;
                for (int32_t i = 0; i < type.output_count; ++i) {
                    const GoodAmount &output = _building_outputs[type.output_begin + i];
                    const bool relevant = _survival_food_good_mask[output.good_id] != 0;
                    const int64_t full_output =
                        effective_building_output_quantity(
                            group, output.good_id, output.quantity, Q16_ONE,
                            saturating_mul(group.count,
                                std::max(1, _epoch_days.get()), _saturation_count),
                            _saturation_count);
                    if (relevant) group_relevant_output = saturating_add(
                        group_relevant_output, full_output, _saturation_count);
                    if (_survival_clothing_good_mask[output.good_id] != 0)
                        group_clothing_output = saturating_add(
                            group_clothing_output, full_output, _saturation_count);
                }
                if (group_relevant_output > 0) {
                    owner_relevant_output[owner] = saturating_add(
                        owner_relevant_output[owner], group_relevant_output,
                        _saturation_count);
                }
                if (group_clothing_output > 0) {
                    owner_clothing_output[owner] = saturating_add(
                        owner_clothing_output[owner], group_clothing_output,
                        _saturation_count);
                }
            }
            const EnvironmentSample environment = environment_sample_for_cell(cell);
            for (const int32_t owner : touched_owners) {
                const int64_t full_relevant_output = owner_relevant_output[owner];
                if ((owner_output_flags[owner] & 1) == 0 || full_relevant_output <= 0)
                    continue;
                const int32_t owner_slot = find_cohort_slot(
                    cell, owner);
                if (owner_slot < 0 || population_store().population[owner_slot] <= 0) continue;
                int64_t required_food = 0;
                for (int32_t stable_need : _survival_food_need_stable_ids) {
                    required_food = saturating_add(required_food,
                        survival_required_units(owner_slot, stable_need,
                            _epoch_days.get(), environment, _saturation_count),
                        _saturation_count);
                }
                const int64_t protected_food = saturating_add(saturating_mul(
                    required_food, _survival_production_target_q16,
                    _saturation_count), Q16_ONE - 1, _saturation_count) / Q16_ONE;
                const int64_t floor_q16 = std::clamp<int64_t>(
                    saturating_add(saturating_mul(protected_food, Q16_ONE,
                        _saturation_count), full_relevant_output - 1,
                        _saturation_count) / full_relevant_output,
                    0, Q16_ONE);
                owner_floor_q16[owner] = floor_q16;
                const int64_t full_clothing_output = owner_clothing_output[owner];
                if ((owner_output_flags[owner] & 4) != 0 && full_clothing_output > 0) {
                    const int64_t required_clothing = survival_required_units(
                        owner_slot, _survival_clothing_need_stable_id,
                        _epoch_days.get(), environment, _saturation_count);
                    owner_clothing_floor_q16[owner] = std::clamp<int64_t>(
                        saturating_add(saturating_mul(required_clothing, Q16_ONE,
                            _saturation_count), full_clothing_output - 1,
                            _saturation_count) / full_clothing_output,
                        0, Q16_ONE);
                }
            }
            for (int32_t g = begin; g < end; ++g) {
                const auto group = building_view(static_cast<size_t>(g));
                const int32_t owner = group.owner_signature_id;
                if (group.count <= 0 || group.operating_state != 0 ||
                    owner < 0 || owner >= static_cast<int32_t>(owner_seen_key.size()) ||
                    owner_seen_key[owner] != cell_key || owner_floor_q16[owner] <= 0 ||
                    !building_available(cell, group.type_id, true)) continue;
                const BuildingType &type = _building_types[group.type_id];
                int64_t group_floor_q16 = 0;
                // The owner floor is expressed in full-recipe output.  When a
                // soft input is absent, production deliberately keeps only the
                // bare efficiency (1 - required), so the planned activity must
                // be lifted to preserve the same survival quantity.  Without
                // this conversion a missing tool silently halves food output
                // and can turn a temporary shortage into starvation.
                int64_t bare_efficiency_q16 = Q16_ONE;
                for (int32_t i = 0; i < type.input_count; ++i) {
                    const ProductionInput &input = _building_inputs[
                        type.input_begin + i];
                    const int64_t required = std::clamp<int64_t>(
                        input.required_q16, 0, Q16_ONE);
                    if (required > 0 && required < Q16_ONE)
                        bare_efficiency_q16 = std::min<int64_t>(
                            bare_efficiency_q16, Q16_ONE - required);
                }
                if (bare_efficiency_q16 <= 0) bare_efficiency_q16 = 1;
                for (int32_t i = 0; i < type.output_count; ++i) {
                    const int32_t good = _building_outputs[type.output_begin + i].good_id;
                    if (_survival_food_good_mask[good] != 0) {
                        group_floor_q16 = std::max(
                            group_floor_q16, owner_floor_q16[owner]);
                    }
                    if (_survival_clothing_good_mask[good] != 0)
                        group_floor_q16 = std::max(
                            group_floor_q16, owner_clothing_floor_q16[owner]);
                }
                if (group_floor_q16 > 0 && bare_efficiency_q16 < Q16_ONE)
                    group_floor_q16 = std::clamp<int64_t>(
                        saturating_add(
                            saturating_mul(group_floor_q16, Q16_ONE,
                                _saturation_count),
                            bare_efficiency_q16 - 1, _saturation_count) /
                            bare_efficiency_q16,
                        0, Q16_ONE);
                _building_survival_utilization_floor_q16[g] = group_floor_q16;
            }
        }
    }
    for (int32_t active = active_begin; active < active_end; ++active) {
        const int32_t cell = active_cells[active];
        const int32_t group_begin = _building_cell_offsets[cell];
        const int32_t group_end = _building_cell_offsets[cell + 1];
        int64_t merchant_opening_cash = 0;
        for (int32_t k = _merchant_offsets[cell]; k < _merchant_offsets[cell + 1]; ++k) {
            merchant_opening_cash = saturating_add(
                merchant_opening_cash,
                std::max<int64_t>(0, population_store().funds[_merchant_slots[k]]),
                _saturation_count);
        }
        int64_t outstanding_principal = 0;
        for (int32_t g = group_begin; g < group_end; ++g) {
            outstanding_principal = saturating_add(
                outstanding_principal,
                std::max<int64_t>(0, buildings_store().merchant_debt_principal[g]),
                _saturation_count);
        }
        if (_pending_construction_cell_offsets.size() ==
                static_cast<size_t>(_cell_count.get() + 1)) {
            for (int32_t cursor = _pending_construction_cell_offsets[cell];
                 cursor < _pending_construction_cell_offsets[cell + 1]; ++cursor) {
                const auto pending = pending_construction()[
                    static_cast<size_t>(
                        _pending_construction_cell_indices[cursor])];
                outstanding_principal = saturating_add(
                    outstanding_principal,
                    std::max<int64_t>(0, pending.merchant_debt_principal),
                    _saturation_count);
            }
        } else {
            for (const auto pending : pending_construction()) {
                if (pending.cell != cell) continue;
                outstanding_principal = saturating_add(
                    outstanding_principal,
                    std::max<int64_t>(0, pending.merchant_debt_principal),
                    _saturation_count);
            }
        }
        const int64_t exposure_limit = mul_div_sat(
            merchant_opening_cash, _merchant_credit_exposure_q16.get(),
            Q16_ONE, _saturation_count);
        const int64_t procurement_reserve = mul_div_sat(
            merchant_opening_cash, _merchant_procurement_cash_reserve_q16.get(),
            Q16_ONE, _saturation_count);
        int64_t cell_credit_remaining = std::max<int64_t>(0, std::min(
            exposure_limit - std::min(exposure_limit, outstanding_principal),
            merchant_opening_cash - std::min(merchant_opening_cash, procurement_reserve)));
        _merchant_credit_budget = saturating_add(
            _merchant_credit_budget, cell_credit_remaining, _saturation_count);
        struct RecoveryPlanOrder {
            int32_t group = -1;
            int32_t survival_shortage_q16 = 0;
            int64_t downstream_shortage = 0;
            int64_t cash_free_flow = 0;
            int64_t economic_profit = 0;
            int64_t required_credit = 0;
        };
        thread_local std::vector<RecoveryPlanOrder> group_order;
        group_order.clear();
        if (group_order.capacity() <
                static_cast<size_t>(group_end - group_begin)) {
            group_order.reserve(static_cast<size_t>(group_end - group_begin));
        }
        for (int32_t g = group_begin; g < group_end; ++g) {
            const auto candidate = building_view(static_cast<size_t>(g));
            RecoveryPlanOrder order;
            order.group = g;
            if (candidate.operating_state == 1 && candidate.type_id >= 0 &&
                candidate.type_id < static_cast<int32_t>(_building_types.size())) {
                const BuildingType &candidate_type = _building_types[candidate.type_id];
                for (int32_t i = 0; i < candidate_type.output_count; ++i) {
                    const int32_t good = _building_outputs[
                        candidate_type.output_begin + i].good_id;
                    const int64_t market_index = market_store().index(cell, good);
                    if (_survival_food_good_mask[good] != 0 ||
                        _survival_clothing_good_mask[good] != 0) {
                        order.survival_shortage_q16 = std::max<int32_t>(
                            order.survival_shortage_q16,
                            market_store().last_shortage_q16[market_index]);
                    }
                    const int32_t signal = market_signal_index(cell, good);
                    if (signal >= 0) {
                        order.downstream_shortage = saturating_add(
                            order.downstream_shortage,
                            _market_signals.business_demand_ema[signal],
                            _saturation_count);
                    }
                }
                int64_t due_sat = 0;
                const int64_t debt_due = building_debt_due(candidate, due_sat);
                _saturation_count = saturating_add(
                    _saturation_count, due_sat, _saturation_count);
                const int64_t cash_cost = saturating_add(
                    saturating_add(candidate.last_input_cost,
                        candidate.last_base_wages_due, _saturation_count),
                    debt_due, _saturation_count);
                order.cash_free_flow = saturating_sub(
                    candidate.last_revenue, cash_cost, _saturation_count);
                order.economic_profit = saturating_sub(saturating_add(
                    candidate.last_revenue,
                    candidate.last_in_kind_livelihood_value,
                    _saturation_count), cash_cost, _saturation_count);
                int64_t probe_cost = saturating_mul(
                    saturating_mul(candidate.sample_unit_input_cost,
                        candidate.count, _saturation_count),
                    std::max(1, _epoch_days.get()), _saturation_count);
                probe_cost /= 32;
                const int32_t owner_slot = find_cohort_slot(
                    cell, candidate.owner_signature_id);
                const int64_t owner_cash = owner_slot >= 0
                    ? std::max<int64_t>(0, population_store().funds[owner_slot]) : 0;
                order.required_credit = std::max<int64_t>(
                    0, probe_cost - std::min(probe_cost, owner_cash));
            }
            group_order.push_back(order);
        }
        std::stable_sort(group_order.begin(), group_order.end(),
            [&](const RecoveryPlanOrder &a, const RecoveryPlanOrder &b) {
                const bool a_recovery = buildings_store().operating_state[a.group] == 1;
                const bool b_recovery = buildings_store().operating_state[b.group] == 1;
                if (a_recovery != b_recovery) return a_recovery;
                if (!a_recovery) return a.group < b.group;
                if (a.survival_shortage_q16 != b.survival_shortage_q16)
                    return a.survival_shortage_q16 > b.survival_shortage_q16;
                if (a.downstream_shortage != b.downstream_shortage)
                    return a.downstream_shortage > b.downstream_shortage;
                if (a.cash_free_flow != b.cash_free_flow)
                    return a.cash_free_flow > b.cash_free_flow;
                if (a.economic_profit != b.economic_profit)
                    return a.economic_profit > b.economic_profit;
                if (a.required_credit != b.required_credit)
                    return a.required_credit < b.required_credit;
                return a.group < b.group;
            });
    // monetary_units 是一个格级标量：同格所有 operating 且产出货币性商品的 group 的
    // count 之和。原来每个 group 都重扫一遍同格全部 peer 来求它，单格 G 个 group 就是
    // O(G^2)，而且内层还要为每个 peer 再遍历一遍它的 output 列表。改成按格缓存 +
    // 按 type 预判 emits_monetary：每格只扫一次，peer 判定退化成一次查表。
    thread_local std::vector<uint8_t> type_emits_monetary;
    type_emits_monetary.assign(_building_types.size(), 0);
    for (size_t type_index = 0; type_index < _building_types.size(); ++type_index) {
        const BuildingType &monetary_type = _building_types[type_index];
        for (int32_t i = 0; i < monetary_type.output_count; ++i) {
            const int32_t good =
                _building_outputs[monetary_type.output_begin + i].good_id;
            if (good >= 0 && good < static_cast<int32_t>(
                    _good_monetary_issue_values.size()) &&
                _good_monetary_issue_values[good] > 0) {
                type_emits_monetary[type_index] = 1;
                break;
            }
        }
    }
    thread_local std::vector<int64_t> cell_monetary_units;
    thread_local std::vector<uint64_t> cell_monetary_units_key;
    thread_local uint64_t monetary_units_generation = 0;
    ++monetary_units_generation;
    const size_t monetary_cell_slots = static_cast<size_t>(std::max(0, _cell_count.get()));
    cell_monetary_units.resize(monetary_cell_slots);
    cell_monetary_units_key.resize(monetary_cell_slots, 0);
    // 这个循环自己会翻转 operating_state，而 monetary_units 直接依赖它。每个写入点都
    // 必须让所在格重算，否则缓存会冻结一份过期快照，铸币配额就不再逐位等价。
    auto invalidate_cell_monetary_units = [&](int32_t cell) {
        if (cell >= 0 && static_cast<size_t>(cell) < cell_monetary_units_key.size())
            cell_monetary_units_key[static_cast<size_t>(cell)] = 0;
    };
    auto cell_monetary_units_for = [&](int32_t cell) -> int64_t {
        if (cell < 0 || static_cast<size_t>(cell) >= cell_monetary_units_key.size())
            return 0;
        const size_t slot = static_cast<size_t>(cell);
        if (cell_monetary_units_key[slot] == monetary_units_generation)
            return cell_monetary_units[slot];
        int64_t units = 0;
        for (int32_t peer = _building_cell_offsets[cell];
             peer < _building_cell_offsets[cell + 1]; ++peer) {
            const auto peer_group = building_view(static_cast<size_t>(peer));
            if (peer_group.count <= 0 || peer_group.operating_state != 0 ||
                peer_group.type_id < 0 || peer_group.type_id >=
                    static_cast<int32_t>(type_emits_monetary.size())) continue;
            if (type_emits_monetary[peer_group.type_id] == 0) continue;
            units = saturating_add(units, peer_group.count, _saturation_count);
        }
        cell_monetary_units_key[slot] = monetary_units_generation;
        cell_monetary_units[slot] = units;
        return units;
    };
        for (const RecoveryPlanOrder &order : group_order) {
        const int32_t group_index = order.group;
        auto group = building_at(static_cast<size_t>(group_index));
        if (group.count <= 0 || group.cell < 0 || group.cell >= _cell_count.get() ||
            group.type_id < 0 || group.type_id >= static_cast<int32_t>(_building_types.size())) {
            error = "building_economic_plan_group_invalid";
            result.ok = false;
            result.error = error;
            publish_result();
            return false;
        }
        const BuildingType &type = _building_types[group.type_id];
        // RECOVERY_PROBE was removed from the public lifecycle. Old saves may
        // still carry state 2; treat it as an ordinary suspended building and
        // clear every probe-only lane before evaluating the new restart gate.
        if (group.operating_state == 2) {
            group.operating_state = 1;
            group.pending_operating_state = 255;
            group.recovery_cycles = 0;
            group.recovery_cooldown_cycles = 0;
            invalidate_cell_monetary_units(group.cell);
        }
        prepare_group_climate_capacity(group, type);
        if (type.kind == 2) {
            // Service buildings (currently merchant posts) do not settle
            // production inputs/outputs and therefore have no meaningful
            // production profit margin. Keep them outside the producer loss,
            // recovery and liquidation state machine, including old saves that
            // captured a service in a suspended state.
            group.operating_state = 0;
            group.severe_loss_cycles = 0;
            group.recovery_cycles = 0;
            group.recovery_failed_reviews = 0;
            group.pending_operating_state = 255;
            group.recovery_cooldown_cycles = 0;
            invalidate_cell_monetary_units(group.cell);
        }
        if (type.kind == 3) {
            // Military v1: state-owned buildings are financed by the treasury.
            // Private loss closure, recovery review and liquidation never apply;
            // keep the lot ACTIVE with full planned utilization and zero
            // private operating cost so the payroll and rail paths behave.
            group.operating_state = 0;
            group.severe_loss_cycles = 0;
            group.recovery_cycles = 0;
            group.recovery_failed_reviews = 0;
            group.pending_operating_state = 255;
            group.recovery_cooldown_cycles = 0;
            group.merchant_debt_principal = 0;
            group.merchant_debt_premium = 0;
            group.sample_unit_input_cost = 0;
            group.sample_unit_maintenance_cost = 0;
            group.planned_utilization_q16 = Q16_ONE;
            group.purchase_intent_capacity_q16 = Q16_ONE;
            invalidate_cell_monetary_units(group.cell);
        }
        bool produces_cycle_flow = false;
        bool produces_survival_food = false;
        for (int32_t i = 0; i < type.output_count; ++i) {
            const int32_t good = _building_outputs[type.output_begin + i].good_id;
            produces_cycle_flow = produces_cycle_flow || _good_storage_modes[good] == 1;
            produces_survival_food = produces_survival_food ||
                _survival_food_good_mask[good] != 0;
        }
        if (type.kind == 3) {
            // Military v1: a state-owned lot has no private production
            // economics (no output, no inputs, no owner livelihood). It is
            // always ACTIVE at full planned capacity so its payroll roles can
            // be staffed and the treasury pays the wages; everything else in
            // this private plan/recovery/revenue pipeline is skipped.
            const int32_t capacity_index = static_cast<int32_t>(group.index);
            if (capacity_index >= 0 && capacity_index < static_cast<int32_t>(
                    _building_planned_capacity_before_climate_q16.size())) {
                _building_planned_capacity_before_climate_q16[capacity_index] =
                    Q16_ONE;
            }
            group.last_expected_revenue = 0;
            group.last_quoted_market_receipt = 0;
            group.last_quoted_operating_cost = 0;
            group.last_maintenance_due = 0;
            group.last_margin_gap_q16 = 0;
            group.sample_unit_input_cost = 0;
            continue;
        }
        if (!building_available(group.cell, group.type_id, true)) {
            group.sample_unit_input_cost = 0;
            group.sample_unit_maintenance_cost = 0;
            group.last_margin_gap_q16 = 0;
            group.planned_utilization_q16 = 0;
            group.purchase_intent_capacity_q16 = 0;
            const int32_t unavailable_index = static_cast<int32_t>(group.index);
            if (unavailable_index >= 0 && unavailable_index <
                    static_cast<int32_t>(
                        _building_planned_capacity_before_climate_q16.size())) {
                _building_planned_capacity_before_climate_q16[
                    unavailable_index] = 0;
            }
            group.recovery_cycles = 0;
            group.last_expected_revenue = 0;
            group.last_quoted_market_receipt = 0;
            group.last_quoted_operating_cost = 0;
            group.last_maintenance_due = 0;
            if (group.operating_state != 0) ++_loss_suspended_building_groups;
            continue;
        }
#include "economy_runtime_building_plan_body_operating_quote.inc"
#include "economy_runtime_building_plan_body_restart.inc"
#include "economy_runtime_building_plan_body_utilization.inc"
        }
    }
    publish_result();
    return true;
}

} // namespace pk
