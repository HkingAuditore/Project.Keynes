// Extracted residual economy methods; function bodies are token-preserved.
// Residual economy methods extracted from economy_runtime.cpp; bodies are token-preserved.
#include "economy_cost_probe.h"
#include "economy_effect_forward.h"
#include "economy_runtime.h"
#include "economy_hash.h"
#include "runtime_switch_registry.h"
#include "economy_graph_kernels.h"
#include "economy_graph_live_ops.h"
#include "economy_graph_stage_dispatch.h"
#include "runtime_economy_pod.h"
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
        const int32_t market = market_store().cell_to_market[group.cell];
        // The production result is still constrained by the capacity that can
        // actually operate in this cell. The planning quote itself is kept
        // independent of current staffing so a vacant installed group can
        // attract labour and recover instead of locking into zero demand.
        const int64_t owner_slots = saturating_mul(
            group.count, type.owner_slots_per_building, _saturation_count);
        // Epoch planning runs before the employment stage. A newly installed
        // or never-observed group therefore has no factual fill yet, but it
        // still needs a bounded nameplate prior so its first owner/employee
        // positions can be hired. Once production has emitted a capacity-day
        // receipt, replace that prior with the minimum observed role fill.
        const bool observed_capacity = group.last_observed_capacity_days_q16 > 0;
        // Keep the factual execution scale separate from the economic forecast.
        // A partially staffed group must produce proportionally less, but its
        // building-level attraction must not collapse merely because the same
        // vacancy caused the partial staffing in the first place.
        int64_t actual_workforce_capacity_q16 = !observed_capacity ? Q16_ONE
            : owner_slots > 0
                ? std::clamp<int64_t>(mul_div_sat(
                    std::max<int64_t>(0, group.filled_owner), Q16_ONE,
                    owner_slots, _saturation_count), 0, Q16_ONE)
                : Q16_ONE;
        for (int32_t r = 0; r < type.employee_count; ++r) {
            const JobRole &role = _building_employee_roles[type.employee_begin + r];
            const int64_t role_slots = saturating_mul(
                group.count, role.slots_per_building, _saturation_count);
            const int32_t role_index = group.employee_fill_begin + r;
            const int64_t role_fill = role_index >= 0 && role_index <
                    static_cast<int32_t>(_building_employee_filled.size())
                ? std::max<int64_t>(0, _building_employee_filled[role_index]) : 0;
            const int64_t role_capacity = !observed_capacity ? Q16_ONE
                : role_slots > 0
                ? std::clamp<int64_t>(mul_div_sat(
                    role_fill, Q16_ONE, role_slots, _saturation_count),
                    0, Q16_ONE) : Q16_ONE;
            actual_workforce_capacity_q16 = std::min(actual_workforce_capacity_q16,
                                              role_capacity);
        }
        constexpr int64_t forecast_workforce_capacity_q16 = Q16_ONE;
        // Suspended recovery must quote the counterfactual full-capacity lot.
        // Scaling living cost by the emptied workforce collapses both sides of
        // the margin to zero and permanently blocks restart after SUSPENDED_LOSS
        // releases owners into unemployment.
        const int64_t planning_workforce_capacity_q16 =
            group.operating_state == 1 ? forecast_workforce_capacity_q16
                                      : actual_workforce_capacity_q16;
        int64_t input_cost = 0;
        int64_t employee_wages = 0;
        const int64_t owner_living_cost_full = saturating_mul(
            living_cost_for_signature(group.cell, group.owner_signature_id, -1,
                                      _saturation_count),
            type.owner_slots_per_building, _saturation_count);
        const int64_t owner_living_cost = mul_div_sat(
            owner_living_cost_full, planning_workforce_capacity_q16, Q16_ONE,
            _saturation_count);
        int64_t revenue = 0;
        bool inputs_available = true;
        bool hard_input_market_available = true;
        for (int32_t i = 0; i < type.input_count; ++i) {
            const ProductionInput &item = _building_inputs[type.input_begin + i];
            // Soft inputs add a productivity bonus on top of the base recipe,
            // and production buys them only when the bonus output is worth
            // more than their outlay. The quote here prices base output only,
            // so billing a soft input would charge for a bonus never counted.
            if (std::clamp<int64_t>(item.required_q16, 0, Q16_ONE) < Q16_ONE)
                continue;
            int64_t best_effective_price = std::numeric_limits<int64_t>::max();
            for (int32_t c = item.candidate_begin;
                 c < item.candidate_begin + item.candidate_count; ++c) {
                const InputCandidate &candidate = _building_input_candidates[c];
                if (!good_input_candidate_available(group.cell, candidate.good_id, true)) continue;
                const int64_t physical_numerator = saturating_add(
                    saturating_mul(item.quantity, Q16_ONE, _saturation_count),
                    candidate.efficiency_q16 - 1, _saturation_count);
                const int64_t physical = effective_production_input_quantity(
                    group.cell, candidate.good_id,
                    physical_numerator / candidate.efficiency_q16,
                    _saturation_count);
                const int64_t candidate_cost = mul_div_sat(
                    physical,
                    market_store().price[market_store().index(market, candidate.good_id)],
                    GOODS_SCALE, _saturation_count);
                best_effective_price = std::min(best_effective_price, candidate_cost);
            }
            if (best_effective_price == std::numeric_limits<int64_t>::max()) {
                if (item.required_q16 >= Q16_ONE) {
                    hard_input_market_available = false;
                    inputs_available = false;
                    break;
                }
                continue;
            }
            input_cost = saturating_add(
                input_cost, best_effective_price, _saturation_count);
        }
        int64_t maintenance_cost = daily_maintenance_cost_for_type(
            group.cell, type, _saturation_count);
        if (maintenance_cost == std::numeric_limits<int64_t>::max())
            maintenance_cost = 0;
        if (!inputs_available) {
            group.sample_unit_input_cost = 0;
            group.sample_unit_maintenance_cost = 0;
            group.last_margin_gap_q16 = -Q16_ONE;
            group.planned_utilization_q16 = 0;
            // A hard input shortage blocks execution, but it must not erase
            // the downstream signal that can restart the upstream producer.
            // Keep a bounded, cash-backed probe in the transient planning
            // vector; production will still re-check stock and settle zero
            // output when the input is absent.
            int64_t structural_intent_q16 = 0;
            const int32_t owner_slot = find_cohort_slot(
                group.cell, group.owner_signature_id);
            if (type.kind != 2 && hard_input_market_available && owner_slot >= 0 &&
                    population_store().population[owner_slot] > 0 &&
                    group.operating_state == 0) {
                int64_t output_pressure_q16 = 0;
                bool has_output_gap = false;
                bool cycle_flow_output = false;
                for (int32_t i = 0; i < type.output_count; ++i) {
                    const int32_t good = _building_outputs[
                        type.output_begin + i].good_id;
                    if (good < 0 || good >= market_store().good_count.get()) continue;
                    cycle_flow_output = cycle_flow_output ||
                        _good_storage_modes[good] == 1;
                    const int32_t signal = market_signal_index(group.cell, good);
                    const int64_t business_demand = signal >= 0
                        ? std::max<int64_t>(0,
                            _market_signals.business_demand_ema[signal]) : 0;
                    const int64_t stock = std::max<int64_t>(0,
                        market_store().stock[market_store().index(market, good)]);
                    const int64_t demand_gap_q16 = business_demand > 0
                        ? std::clamp<int64_t>(mul_div_sat(
                            std::max<int64_t>(0, business_demand - stock),
                            Q16_ONE, std::max<int64_t>(business_demand, GOODS_SCALE),
                            _saturation_count), 0, Q16_ONE) : 0;
                    const int64_t household_shortage_q16 = std::clamp<int64_t>(
                        market_store().last_shortage_q16[market_store().index(market, good)],
                        0, Q16_ONE);
                    output_pressure_q16 = std::max(output_pressure_q16,
                        std::max(demand_gap_q16, household_shortage_q16));
                    has_output_gap = has_output_gap || demand_gap_q16 > 0 ||
                        household_shortage_q16 > 0;
                }
                if (has_output_gap) {
                    const int64_t probe_floor_q16 = cycle_flow_output
                        ? std::max<int64_t>(1, Q16_ONE / 6)
                        : std::max<int64_t>(1, Q16_ONE / 32);
                    structural_intent_q16 = std::clamp<int64_t>(
                        std::max(output_pressure_q16, probe_floor_q16),
                        0, Q16_ONE);
                    const int64_t period_input_cost = saturating_mul(
                        saturating_mul(std::max<int64_t>(0, input_cost),
                            std::max<int64_t>(1, group.count),
                            _saturation_count),
                        std::max(1, _epoch_days.get()), _saturation_count);
                    int64_t available_cash = std::max<int64_t>(0,
                        population_store().funds[owner_slot]);
                    for (int32_t k = _merchant_offsets[group.cell];
                         k < _merchant_offsets[group.cell + 1]; ++k) {
                        available_cash = saturating_add(available_cash,
                            std::max<int64_t>(0,
                                population_store().funds[_merchant_slots[k]]),
                            _saturation_count);
                    }
                    if (period_input_cost > 0) {
                        structural_intent_q16 = std::min<int64_t>(
                            structural_intent_q16,
                            std::clamp<int64_t>(mul_div_sat(
                                available_cash, Q16_ONE, period_input_cost,
                                _saturation_count), 0, Q16_ONE));
                    }
                }
            }
            group.purchase_intent_capacity_q16 = structural_intent_q16;
            const int32_t missing_input_index = static_cast<int32_t>(group.index);
            if (missing_input_index >= 0 && missing_input_index <
                    static_cast<int32_t>(
                        _building_planned_capacity_before_climate_q16.size())) {
                _building_planned_capacity_before_climate_q16[
                    missing_input_index] = structural_intent_q16;
            }
            group.recovery_cycles = 0;
            group.last_expected_revenue = 0;
            group.last_quoted_market_receipt = 0;
            group.last_quoted_operating_cost = 0;
            group.last_maintenance_due = 0;
            if (type.kind != 2 && group.operating_state == 2) {
                group.operating_state = 1;
                group.pending_operating_state = 255;
                invalidate_cell_monetary_units(group.cell);
            }
            // Missing a technologically available hard input is a recoverable
            // execution blockage, not evidence of a realized operating loss.
            // Keep the installed group active/idle so it retains a labor claim
            // and can resume as soon as the input chain supplies it.
            if (type.kind != 2 && group.operating_state == 0)
                group.severe_loss_cycles = 0;
            if (group.operating_state != 0) ++_loss_suspended_building_groups;
            continue;
        }
        for (int32_t r = 0; r < type.employee_count; ++r) {
            const JobRole &role = _building_employee_roles[type.employee_begin + r];
            const int32_t role_index = group.employee_fill_begin + r;
            const int64_t wage = role_index >= 0 &&
                role_index < static_cast<int32_t>(_building_role_contract_wage.size())
                    ? _building_role_contract_wage[role_index]
                    : 0;
            const int32_t filled_index = role_index;
            const int64_t filled = filled_index >= 0 && filled_index <
                    static_cast<int32_t>(_building_employee_filled.size())
                ? std::max<int64_t>(0, _building_employee_filled[filled_index]) : 0;
            // Recovery quotes the full roster; staffed quotes use current fill.
            const int64_t wage_heads = group.operating_state == 1
                ? saturating_mul(group.count, role.slots_per_building,
                    _saturation_count)
                : filled;
            employee_wages = saturating_add(employee_wages, saturating_mul(
                wage_heads, wage, _saturation_count), _saturation_count);
        }
        for (int32_t i = 0; i < type.output_count; ++i) {
            const GoodAmount &item = _building_outputs[type.output_begin + i];
            int64_t settlement = _good_monetary_issue_values[item.good_id];
            if (settlement > 0) {
                // Monetary income is face × quantity. Never rewrite settlement
                // from the cell bullion pool — a rich merchant's cash weight
                // used to inflate expected revenue far above face×output.
            } else {
                const int32_t output_signal = market_signal_index(
                    group.cell, item.good_id);
                const int32_t output_flow = trade_flow_index(
                    group.cell, item.good_id, false);
                const int64_t output_target = merchant_inventory_target(
                    market, item.good_id, output_signal,
                    output_signal >= 0 ? _market_signals.realized_withdrawal_ema[
                        output_signal] : 0,
                    output_flow >= 0 ? _trade_flows.export_ema[output_flow] : 0,
                    item.quantity, _saturation_count);
                const int32_t buy_factor = effective_merchant_buy_factor_q16(
                    market, item.good_id, output_target,
                    market_store().stock[market_store().index(market, item.good_id)],
                    _saturation_count);
                settlement = mul_div_sat(
                    market_store().price[market_store().index(market, item.good_id)],
                    buy_factor, Q16_ONE, _saturation_count);
            }
            revenue = saturating_add(revenue, mul_div_sat(
                item.quantity, settlement, GOODS_SCALE, _saturation_count),
                _saturation_count);
        }
        // Keep a full-capacity daily quote separate from the current staffed
        // quote. The latter is used for margin gating; the former is used at
        // the end of the plan to apply the effective execution scale exactly
        // once. Mixing the two double-counts workforce when utilization is
        // below nameplate capacity.
        int64_t full_capacity_revenue = revenue;
        revenue = mul_div_sat(full_capacity_revenue, forecast_workforce_capacity_q16,
                              Q16_ONE, _saturation_count);
        // Active lots forecast from committed cash receipts. Suspended lots keep
        // the nameplate counterfactual above: in-kind self-employment often has
        // zero market/bullion receipts, and observing that zero would make every
        // restart margin fail after owners are shed.
        if (observed_capacity && group.operating_state != 1) {
            // Installed groups forecast from the previous committed receipt,
            // normalized by the observed workforce-capacity-days. A zero
            // receipt therefore remains zero; it cannot fall back to a stale
            // nameplate quote or a frozen commodity price.
            // Economic receipts include both cash settlement and the market
            // value of output consumed in kind by the owner household.  A
            // survival producer can legitimately receive zero cash while its
            // retained food fully pays for the owner's livelihood; treating
            // that period as zero revenue creates a self reinforcing shutdown.
            const int64_t observed_sales = saturating_add(
                saturating_add(std::max<int64_t>(0, group.last_market_receipt),
                               std::max<int64_t>(0, group.last_bullion_mint_receipt),
                               _saturation_count),
                std::max<int64_t>(0, group.last_producer_support_receipt),
                _saturation_count);
            const int64_t observed_in_kind = std::max<int64_t>(
                0, group.last_in_kind_livelihood_value);
            // `last_observed_capacity_days_q16` already contains the prior
            // group count, elapsed days, and Q16 workforce share. Convert
            // the receipt to a full-capacity per-building-day quote here;
            // apply the current effective scale only once below.
            //
            // Production ran at min(workforce, previous plan). Sales scale
            // with that chosen activity, so divide it back out; otherwise a
            // group parked on its survival floor reads its own throttling as
            // low prices and never quotes a profitable full run again. In-kind
            // retention is capped by the owner basket, so it is not scaled.
            const int64_t observed_days = std::max<int64_t>(
                1, group.last_observed_capacity_days_q16);
            const int64_t observed_workforce_q16 = std::clamp<int64_t>(
                observed_days / std::max<int64_t>(1, saturating_mul(
                    group.count, std::max(1, _epoch_days.get()),
                    _saturation_count)), 0, Q16_ONE);
            const int64_t previous_plan_q16 = group_index >= 0 &&
                    group_index < static_cast<int32_t>(
                        _building_planned_capacity_before_climate_q16.size())
                ? std::clamp<int64_t>(
                    _building_planned_capacity_before_climate_q16[group_index],
                    0, Q16_ONE)
                : Q16_ONE;
            // A zero plan observed nothing about prices; a tiny probe floor
            // is capped so one noisy sale cannot be amplified without bound.
            const int64_t chosen_activity_share_q16 = previous_plan_q16 > 0 &&
                    observed_workforce_q16 > 0 &&
                    previous_plan_q16 < observed_workforce_q16
                ? std::max<int64_t>(Q16_ONE / 32, mul_div_sat(
                    previous_plan_q16, Q16_ONE, observed_workforce_q16,
                    _saturation_count))
                : Q16_ONE;
            full_capacity_revenue = group.last_observed_capacity_days_q16 > 0
                ? saturating_add(
                    mul_div_sat(observed_sales, Q16_ONE,
                        std::max<int64_t>(1, mul_div_sat(observed_days,
                            chosen_activity_share_q16, Q16_ONE,
                            _saturation_count)),
                        _saturation_count),
                    mul_div_sat(observed_in_kind, Q16_ONE, observed_days,
                        _saturation_count),
                    _saturation_count)
                : 0;
            revenue = mul_div_sat(full_capacity_revenue,
                                  forecast_workforce_capacity_q16, Q16_ONE,
                                  _saturation_count);
        }
        const int64_t operating = saturating_add(saturating_add(
            saturating_add(input_cost, employee_wages, _saturation_count),
            owner_living_cost, _saturation_count),
            maintenance_cost, _saturation_count);
        const int64_t required = saturating_add(operating, mul_div_sat(
            operating, type.target_operating_margin_q16, Q16_ONE,
            _saturation_count), _saturation_count);
        int64_t margin_gap = required <= 0 ? (revenue > 0 ? Q16_ONE : 0) :
            mul_div_sat(saturating_sub(revenue, required, _saturation_count), Q16_ONE,
                        std::max<int64_t>(MONEY_SCALE, required), _saturation_count);
        margin_gap = std::clamp<int64_t>(margin_gap, -Q16_ONE, Q16_ONE);
        int64_t expected_profit_margin = operating <= 0 ? (revenue > 0 ? Q16_ONE : 0) :
            mul_div_sat(saturating_sub(revenue, operating, _saturation_count), Q16_ONE,
                        std::max<int64_t>(MONEY_SCALE, operating), _saturation_count);
        // Owners and employees evaluate the same after-tax operating cash that
        // production will settle. Positive business tax is a deductible cost;
        // negative business tax is a cost reimbursement and negative income tax
        // is valued only at the funded fiscal fulfillment ratio.
        const int32_t expected_business_rate = frozen_tax_rate(
            group.cell, NativeCountryRuntime::TAX_BUSINESS, group.type_id);
        const int64_t expected_business_eligible_cost = saturating_add(
            saturating_add(input_cost, employee_wages, _saturation_count),
            maintenance_cost, _saturation_count);
        const int64_t expected_business_base = expected_business_rate < 0
            ? expected_business_eligible_cost : std::max<int64_t>(0, revenue);
        const int64_t expected_business_transfer =
            expected_resolved_fiscal_transfer(
                group.cell, NativeCountryRuntime::TAX_BUSINESS, group.type_id,
                expected_business_base, 1, _saturation_count);
        // Income tax excludes owner livelihood from the tax base. Business
        // tax is deductible only when positive; a business subsidy is a
        // transfer and must not recursively increase taxable income.
        const int64_t expected_income_base = std::max<int64_t>(0,
            saturating_sub(saturating_sub(
                revenue, expected_business_eligible_cost, _saturation_count),
                std::max<int64_t>(0, expected_business_transfer),
                _saturation_count));
        const int32_t expected_income_rate = frozen_tax_rate(
            group.cell, NativeCountryRuntime::TAX_INCOME,
            type.owner_profession_id);
        const int64_t expected_income_transfer =
            expected_resolved_fiscal_transfer(
                group.cell, NativeCountryRuntime::TAX_INCOME,
                type.owner_profession_id,
                expected_income_rate < 0
                    ? std::max<int64_t>(expected_income_base, owner_living_cost)
                    : expected_income_base,
                1, _saturation_count);
        const int64_t expected_after_tax_profit = saturating_sub(
            saturating_sub(saturating_sub(revenue, operating,
                _saturation_count), expected_business_transfer,
                _saturation_count), expected_income_transfer,
            _saturation_count);
        expected_profit_margin = operating <= 0
            ? (expected_after_tax_profit > 0 ? Q16_ONE : 0)
            : mul_div_sat(expected_after_tax_profit, Q16_ONE,
                std::max<int64_t>(MONEY_SCALE, operating), _saturation_count);
        expected_profit_margin = std::clamp<int64_t>(
            expected_profit_margin, -Q16_ONE, Q16_ONE);
        group.sample_unit_input_cost = input_cost;
        group.sample_unit_maintenance_cost = maintenance_cost;
        group.last_margin_gap_q16 = static_cast<int32_t>(margin_gap);
        bool suspended_now = false;
        if (type.kind != 2 && group.operating_state == 0) {
            // 停业沿用实际经营收支；业主生活成本属于岗位机会评价。
            // 不可把单座单日生活报价加到整组已结算的成本中。
            const bool settled_production = group.last_output > 0 ||
                group.last_resource_generated > 0 ||
                (type.employee_count == 0 && type.input_count == 0 &&
                 type.resource_count == 0 && group.filled_owner > 0 &&
                 owner_living_cost > 0);
            const int64_t owner_business_income = saturating_add(
                group.last_revenue,
                std::max<int64_t>(0, group.last_in_kind_livelihood_value),
                _saturation_count);
            const int64_t owner_business_cost = saturating_add(
                saturating_add(group.last_input_cost,
                    group.last_base_wages_due, _saturation_count),
                group.last_maintenance_cost, _saturation_count);
            const int64_t realized_taxable_cost = saturating_add(
                saturating_add(group.last_input_cost, group.last_base_wages_paid,
                    _saturation_count),
                group.last_maintenance_cost, _saturation_count);
            const int32_t realized_business_rate = frozen_tax_rate(
                group.cell, NativeCountryRuntime::TAX_BUSINESS,
                group.type_id);
            // Fiscal bases follow realized cash, while lifecycle viability still
            // includes wage obligations through owner_business_cost.
            const int64_t realized_business_eligible_cost = realized_taxable_cost;
            const int64_t absolute_building_days = saturating_mul(
                group.count, std::max<int64_t>(1, _epoch_days.get()),
                _saturation_count);
            const int64_t realized_business_transfer = realized_business_rate < 0
                ? expected_resolved_fiscal_transfer(
                    group.cell, NativeCountryRuntime::TAX_BUSINESS,
                    group.type_id, realized_business_eligible_cost,
                    absolute_building_days, _saturation_count)
                : 0;
            const bool positive_self_employment = type.employee_count == 0 &&
                saturating_add(owner_business_income,
                    std::max<int64_t>(0, -realized_business_transfer),
                    _saturation_count) > owner_business_cost;
            const int32_t realized_profession = group.owner_signature_id >= 0 &&
                    group.owner_signature_id < static_cast<int32_t>(_signatures.size())
                ? _signatures[group.owner_signature_id].profession_id : -1;
            const int32_t realized_income_rate = frozen_tax_rate(
                group.cell, NativeCountryRuntime::TAX_INCOME,
                realized_profession);
            const int64_t realized_income_base = std::max<int64_t>(0,
                saturating_sub(group.last_revenue, realized_taxable_cost,
                    _saturation_count));
            const int64_t absolute_owner_days = saturating_mul(
                std::max<int64_t>(1, group.count),
                std::max<int64_t>(1, _epoch_days.get()), _saturation_count);
            const int64_t realized_income_transfer =
                expected_resolved_fiscal_transfer(
                    group.cell, NativeCountryRuntime::TAX_INCOME,
                    realized_profession,
                    realized_income_rate < 0
                        ? std::max<int64_t>(realized_income_base, owner_living_cost)
                        : realized_income_base,
                    absolute_owner_days, _saturation_count);
            const int64_t realized_after_tax_profit = saturating_sub(
                saturating_sub(
                    // Retained output pays owner livelihood in kind. Include
                    // the same income used by the self-employment gate above;
                    // cash-only profit falsely suspends subsistence producers.
                    saturating_sub(owner_business_income, owner_business_cost,
                        _saturation_count), realized_business_transfer,
                    _saturation_count),
                realized_income_transfer, _saturation_count);
            const int64_t realized_after_tax_margin = mul_div_sat(
                realized_after_tax_profit, Q16_ONE,
                std::max<int64_t>(MONEY_SCALE, owner_business_cost),
                _saturation_count);
            const bool realized_severe_loss = settled_production &&
                !positive_self_employment &&
                realized_after_tax_margin <= _building_severe_loss_threshold_q16.get();
            if (realized_severe_loss) {
                // Count consecutive observed owner losses. A single settled loss
                // must remain visible to employment and audit while the configured
                // hysteresis threshold decides when the group is suspended.
                const int32_t threshold = std::max(1, _building_severe_loss_cycles.get());
                group.severe_loss_cycles = static_cast<uint16_t>(std::min<int32_t>(
                    threshold, static_cast<int32_t>(group.severe_loss_cycles) + 1));
                if (group.severe_loss_cycles >= threshold) {
                    group.operating_state = 1;
                    group.recovery_cycles = 0;
                    suspended_now = true;
                    invalidate_cell_monetary_units(group.cell);
                }
            } else {
                // Zero settlement covers labor, input, resource and financing
                // blockages. None is a realized loss observation.
                group.severe_loss_cycles = 0;
            }
            group.pending_operating_state = 255;
            group.recovery_cooldown_cycles = 0;
            if (!suspended_now && group.severe_loss_cycles >= _building_severe_loss_cycles.get()) {
                group.operating_state = 1;
                group.recovery_cycles = 0;
                suspended_now = true;
                invalidate_cell_monetary_units(group.cell);
            }
        }
        if (type.kind != 2 && group.operating_state == 1 && !suspended_now &&
            group.recovery_cooldown_cycles == 0) {
            ++_recovery_candidates;
            const int64_t building_days = saturating_mul(
                group.count, std::max(1, _epoch_days.get()), _saturation_count);
            // Soft inputs (required_q16 < 1) are optional productivity, not an
            // entry gate. Match production/investment: missing soft stock only
            // lowers executable throughput via (1-required)+required*coverage,
            // and must not keep a profitable suspended lot permanently idle
            // (e.g. flint_quarry tools shelf empty after a price spike).
            bool physical_inputs_available = true;
            int64_t soft_coverage_scale_q16 = Q16_ONE;
            int64_t restart_input_unit_cost = 0;
            int64_t restart_hard_input_unit_cost = 0;
            for (int32_t i = 0; i < type.input_count && physical_inputs_available; ++i) {
                const ProductionInput &item = _building_inputs[type.input_begin + i];
                const int64_t required_q16 = std::clamp<int64_t>(
                    item.required_q16, 0, Q16_ONE);
                if (required_q16 <= 0) continue;
                const int64_t effective = saturating_mul(
                    building_days, item.quantity, _saturation_count);
                bool candidate_available = false;
                int64_t best_unit_cost = std::numeric_limits<int64_t>::max();
                for (int32_t c = item.candidate_begin;
                     c < item.candidate_begin + item.candidate_count; ++c) {
                    const InputCandidate &candidate = _building_input_candidates[c];
                    if (!good_input_candidate_available(group.cell, candidate.good_id, true)) continue;
                    int64_t physical = mul_div_sat(effective, Q16_ONE,
                        std::max<int32_t>(1, candidate.efficiency_q16),
                        _saturation_count);
                    if (mul_div_sat(physical, candidate.efficiency_q16,
                            Q16_ONE, _saturation_count) < effective)
                        physical = saturating_add(physical, 1, _saturation_count);
                    physical = effective_production_input_quantity(
                        group.cell, candidate.good_id, physical, _saturation_count);
                    const int64_t physical_numerator = saturating_add(
                        saturating_mul(item.quantity, Q16_ONE, _saturation_count),
                        candidate.efficiency_q16 - 1, _saturation_count);
                    const int64_t unit_physical = effective_production_input_quantity(
                        group.cell, candidate.good_id,
                        physical_numerator / std::max<int32_t>(1, candidate.efficiency_q16),
                        _saturation_count);
                    const int64_t candidate_cost = mul_div_sat(
                        unit_physical,
                        market_store().price[market_store().index(market, candidate.good_id)],
                        GOODS_SCALE, _saturation_count);
                    if (market_store().stock[market_store().index(market, candidate.good_id)] >= physical) {
                        candidate_available = true;
                        best_unit_cost = std::min(best_unit_cost, candidate_cost);
                    }
                }
                if (required_q16 >= Q16_ONE) {
                    physical_inputs_available = candidate_available;
                    if (candidate_available &&
                        best_unit_cost != std::numeric_limits<int64_t>::max()) {
                        restart_input_unit_cost = saturating_add(
                            restart_input_unit_cost, best_unit_cost,
                            _saturation_count);
                        restart_hard_input_unit_cost = saturating_add(
                            restart_hard_input_unit_cost, best_unit_cost,
                            _saturation_count);
                    }
                } else if (candidate_available &&
                    best_unit_cost != std::numeric_limits<int64_t>::max()) {
                    // Soft and stocked: bill only the covered share that
                    // production would actually purchase.
                    restart_input_unit_cost = saturating_add(
                        restart_input_unit_cost, best_unit_cost,
                        _saturation_count);
                } else {
                    // Soft and unstocked: coverage 0 → efficiency 1-required.
                    soft_coverage_scale_q16 = std::min<int64_t>(
                        soft_coverage_scale_q16, Q16_ONE - required_q16);
                }
            }
            // Production clamps a resource-limited group to its capacity or
            // safe-harvest budget, so restart needs one building's worth, not
            // the whole group: 35 hunting camps built in a good decade need
            // far more than the regrown game's safe harvest and would
            // otherwise stay shut forever while the cell starves of protein.
            bool physical_resources_available = true;
            if (type.behavior_id == 1 || type.behavior_id == 2) {
                for (int32_t i = 0; i < type.resource_count; ++i) {
                    const ResourceAmount &item = _building_resources[type.resource_begin + i];
                    const int64_t raw_base = item.mode == 1
                        ? item.quantity
                        : saturating_mul(std::max(1, _epoch_days.get()),
                            item.quantity, _saturation_count);
                    const int64_t base = effective_resource_use_quantity(
                        group.cell, item.resource_id, raw_base, _saturation_count);
                    if (base > available_resource_amount(item, group.cell)) {
                        physical_resources_available = false;
                        break;
                    }
                }
            }
            const int32_t owner_slot = find_cohort_slot(
                group.cell, group.owner_signature_id);
            int64_t owner_slot_cash = owner_slot >= 0
                ? std::max<int64_t>(0, population_store().funds[owner_slot]) : 0;
            // Suspension moves the owner, including savings, into unemployment.
            // Quote the cash that idle recruits would carry back with them;
            // an empty canonical slot must not force a wealthy former owner to
            // borrow (or reject them because the old lot has overdue debt).
            // This is eligibility only: employment transfers the actual share,
            // and production independently caps purchases by installed cash.
            int64_t recruitable = std::max<int64_t>(0,
                saturating_mul(group.count, type.owner_slots_per_building,
                    _saturation_count) - (owner_slot >= 0
                    ? population_store().population[owner_slot] : 0));
            population_store().for_each_in_cell(group.cell, [&](int32_t slot) {
                if (recruitable <= 0 || slot == owner_slot || is_merchant_slot(slot)) return;
                const int64_t people = population_store().population[slot];
                if (people <= 0) return;
                const uint32_t signature = population_store().signature_id[slot];
                if (signature >= _signatures.size()) return;
                const int32_t profession = _signatures[signature].profession_id;
                if (profession != _unemployed_profession_id &&
                    profession != type.owner_profession_id) return;
                const int64_t idle = std::max<int64_t>(0, people -
                    population_store().owner_employed[slot] -
                    population_store().employee_employed[slot]);
                const int64_t moving = std::min(recruitable, idle);
                owner_slot_cash = saturating_add(owner_slot_cash,
                    mul_div_sat(std::max<int64_t>(0, population_store().funds[slot]),
                        moving, people, _saturation_count), _saturation_count);
                recruitable -= moving;
            });
            // Restart finance bills only hard inputs and employee wages. Soft
            // tools are optional productivity bought from the recruited
            // owners' carried savings; billing them, or owner livelihood
            // (paid by the lot's own output, cash or in kind), made every
            // suspended lot with delinquent merchant debt need credit it could
            // never get, so a profitable hunting camp stayed shut forever
            // while its cell starved.
            const int64_t restart_cost = saturating_add(
                saturating_mul(restart_hard_input_unit_cost, building_days,
                    _saturation_count), saturating_mul(employee_wages,
                    building_days, _saturation_count), _saturation_count);
            const int64_t credit_needed = std::max<int64_t>(0,
                restart_cost - std::min(restart_cost, owner_slot_cash));
            const bool finance_available = credit_needed == 0 ||
                (_merchant_credit_runtime_mode.get() != 0 &&
                 group.merchant_debt_delinquent_cycles == 0 &&
                 credit_needed <= cell_credit_remaining);
            // Owner-operated buildings cannot restart without local labour that
            // can refill the canonical owner signature. SUSPENDED_LOSS sheds
            // owners into unemployment, so an emptied signature alone must not
            // block restart when the unemployed pool (or same profession) still
            // has people. Ledger population commands apply after this plan
            // stage; early-apply due population adjusts before planning so the
            // hireable check and tests that drain labour stay coherent.
            bool owner_cohort_live = owner_slot >= 0 &&
                owner_slot < static_cast<int32_t>(
                    population_store().population.size()) &&
                population_store().population[owner_slot] > 0;
            int64_t hireable_owner_labor = 0;
            if (!owner_cohort_live && type.owner_slots_per_building > 0) {
                population_store().for_each_in_cell(group.cell, [&](int32_t slot) {
                    if (is_merchant_slot(slot)) return;
                    const uint32_t sig = population_store().signature_id[slot];
                    if (sig >= _signatures.size()) return;
                    // Profitable recovery may draw cross-profession labour via
                    // the next employment pass (same path as survival-food
                    // restarts). Counting only unemployed / same-profession
                    // workers left flint quarries locked when every local adult
                    // was pinned on gathering after the unemployed pool cleared.
                    hireable_owner_labor = saturating_add(
                        hireable_owner_labor,
                        std::max<int64_t>(0, population_store().population[slot]),
                        _saturation_count);
                });
            }
            const bool owner_available = type.owner_slots_per_building <= 0 ||
                owner_cohort_live || hireable_owner_labor > 0;
            const bool executable = owner_available && physical_inputs_available &&
                physical_resources_available && finance_available;
            // Counterfactual restart margin must match the executable soft path:
            // unstocked soft inputs cut throughput and drop out of operating cost.
            int64_t recovery_profit_margin = expected_profit_margin;
            int64_t recovery_margin_denominator = std::max<int64_t>(
                MONEY_SCALE, operating);
            if (soft_coverage_scale_q16 < Q16_ONE ||
                restart_input_unit_cost != input_cost) {
                const int64_t recovery_revenue = mul_div_sat(
                    revenue, soft_coverage_scale_q16, Q16_ONE, _saturation_count);
                const int64_t recovery_operating = saturating_add(
                    saturating_add(saturating_add(restart_input_unit_cost,
                        employee_wages, _saturation_count),
                        owner_living_cost, _saturation_count),
                    maintenance_cost, _saturation_count);
                recovery_margin_denominator = std::max<int64_t>(
                    MONEY_SCALE, recovery_operating);
                const int64_t recovery_business_eligible = saturating_add(
                    saturating_add(restart_input_unit_cost, employee_wages,
                        _saturation_count),
                    maintenance_cost, _saturation_count);
                const int64_t recovery_business_base = expected_business_rate < 0
                    ? recovery_business_eligible
                    : std::max<int64_t>(0, recovery_revenue);
                const int64_t recovery_business_transfer =
                    expected_resolved_fiscal_transfer(
                        group.cell, NativeCountryRuntime::TAX_BUSINESS,
                        group.type_id, recovery_business_base, 1,
                        _saturation_count);
                const int64_t recovery_income_base = std::max<int64_t>(0,
                    saturating_sub(saturating_sub(
                        recovery_revenue, recovery_business_eligible,
                        _saturation_count),
                        std::max<int64_t>(0, recovery_business_transfer),
                        _saturation_count));
                const int64_t recovery_income_transfer =
                    expected_resolved_fiscal_transfer(
                        group.cell, NativeCountryRuntime::TAX_INCOME,
                        type.owner_profession_id,
                        expected_income_rate < 0
                            ? std::max<int64_t>(
                                recovery_income_base, owner_living_cost)
                            : recovery_income_base,
                        1, _saturation_count);
                const int64_t recovery_after_tax = saturating_sub(
                    saturating_sub(saturating_sub(recovery_revenue,
                        recovery_operating, _saturation_count),
                        recovery_business_transfer, _saturation_count),
                    recovery_income_transfer, _saturation_count);
                recovery_profit_margin = recovery_operating <= 0
                    ? (recovery_after_tax > 0 ? Q16_ONE : 0)
                    : mul_div_sat(recovery_after_tax, Q16_ONE,
                        std::max<int64_t>(MONEY_SCALE, recovery_operating),
                        _saturation_count);
                recovery_profit_margin = std::clamp<int64_t>(
                    recovery_profit_margin, -Q16_ONE, Q16_ONE);
            }
            // Owner-retained output is income for every building, including a
            // suspended one. Revalue it at the current market price in the
            // same recovery decision; do not create a food-only exception.
            if (executable) {
                int64_t quote_sat = 0;
                EconomyCostProbe::record("owner_quote.call.plan_recovery",
                                          _current_day.get(), 0.0, 1);
                const OwnerOpportunityQuote recovery_quote =
                    owner_opportunity_quote(group, Q16_ONE, Q16_ONE, quote_sat);
                const int64_t recovery_cash_profit = mul_div_sat(
                    recovery_profit_margin, recovery_margin_denominator,
                    Q16_ONE, _saturation_count);
                const int64_t recovery_total_profit = saturating_add(
                    recovery_cash_profit,
                    std::max<int64_t>(0, recovery_quote.in_kind_retail_value),
                    _saturation_count);
                recovery_profit_margin = std::clamp<int64_t>(mul_div_sat(
                    recovery_total_profit, Q16_ONE,
                    recovery_margin_denominator, _saturation_count),
                    -Q16_ONE, Q16_ONE);
                _saturation_count = saturating_add(_saturation_count, quote_sat,
                    _saturation_count);
            }
            if (group_index < static_cast<int32_t>(
                    _building_recovery_liquidation_eligible.size())) {
                _building_recovery_liquidation_eligible[group_index] =
                    executable &&
                    recovery_profit_margin < _building_restart_margin_q16.get();
            }
            // Recovery must be able to bootstrap an empty owner roster. The
            // employment pass only advertises vacancies for ACTIVE groups, so
            // requiring an already seated owner here creates a circular gate.
            // All buildings use the same current-price cash + owner-retained
            // income test; survival goods receive no special profitability
            // exemption.
            const bool viable = executable &&
                recovery_profit_margin >= _building_restart_margin_q16.get();
            if (viable) {
                group.pending_operating_state = 0;
                group.severe_loss_cycles = 0;
                group.recovery_failed_reviews = 0;
                group.recovery_cooldown_cycles = 0;
                if (credit_needed > 0) {
                    _building_merchant_credit_limit[group_index] = credit_needed;
                    _merchant_credit_committed = saturating_add(
                        _merchant_credit_committed, credit_needed, _saturation_count);
                    cell_credit_remaining -= credit_needed;
                }
                ++_recovery_approved;
                ++_recovery_restarted;
            }
        }
        constexpr int64_t recovery_probe_floor_q16 = 0;
        if (false && type.kind != 2 && group.operating_state == 1 && !suspended_now &&
            group.recovery_cooldown_cycles == 0) {
            const int32_t owner_slot = find_cohort_slot(group.cell, group.owner_signature_id);
            ++_recovery_candidates;
            const int64_t restart_input_cost = mul_div_sat(saturating_mul(
                saturating_mul(input_cost, group.count, _saturation_count),
                std::max(1, _epoch_days.get()), _saturation_count),
                recovery_probe_floor_q16, Q16_ONE, _saturation_count);
            const int64_t owner_cash = owner_slot >= 0
                ? std::max<int64_t>(0, population_store().funds[owner_slot]) : 0;
            const int64_t credit_needed = std::max<int64_t>(
                0, restart_input_cost - std::min(restart_input_cost, owner_cash));
            const bool credit_allowed = group.merchant_debt_delinquent_cycles == 0 &&
                credit_needed <= cell_credit_remaining;
            const bool finance_available = credit_needed == 0 ||
                (_merchant_credit_runtime_mode.get() != 0 && credit_allowed);
            bool physical_inputs_available = inputs_available;
            recovery_probe_goods.clear();
            const int64_t building_days = saturating_mul(
                group.count, std::max(1, _epoch_days.get()), _saturation_count);
            for (int32_t i = 0; physical_inputs_available && i < type.input_count; ++i) {
                const ProductionInput &item = _building_inputs[type.input_begin + i];
                const int64_t required_q16 = std::clamp<int64_t>(
                    item.required_q16, 0, Q16_ONE);
                if (required_q16 <= 0) continue;
                const int64_t floor_q16 = Q16_ONE - required_q16;
                if (recovery_probe_floor_q16 <= floor_q16) continue;
                const int64_t purchase_scale_q16 = std::min<int64_t>(Q16_ONE,
                    mul_div_sat(recovery_probe_floor_q16 - floor_q16,
                        Q16_ONE, required_q16, _saturation_count));
                const int64_t effective = saturating_mul(
                    building_days, item.quantity, _saturation_count);
                int32_t selected_good = -1;
                int64_t selected_quantity = 0;
                int64_t best_spare = -1;
                bool best_sufficient = false;
                int64_t best_effective_price = std::numeric_limits<int64_t>::max();
                for (int32_t c = item.candidate_begin;
                     c < item.candidate_begin + item.candidate_count; ++c) {
                    const InputCandidate &candidate = _building_input_candidates[c];
                if (!good_input_candidate_available(group.cell, candidate.good_id, true)) continue;
                    int64_t physical = mul_div_sat(
                        effective, Q16_ONE, candidate.efficiency_q16,
                        _saturation_count);
                    if (mul_div_sat(physical, candidate.efficiency_q16, Q16_ONE,
                                    _saturation_count) < effective) {
                        physical = saturating_add(physical, 1, _saturation_count);
                    }
                    physical = effective_production_input_quantity(
                        group.cell, candidate.good_id, physical,
                        _saturation_count);
                    int64_t quantity = saturating_add(saturating_mul(
                        physical, purchase_scale_q16, _saturation_count),
                        Q16_ONE - 1, _saturation_count) / Q16_ONE;
                    quantity = std::max<int64_t>(1, quantity);
                    int64_t reserved = 0;
                    for (const auto &entry : recovery_probe_goods) {
                        if (entry.first == candidate.good_id) reserved = entry.second;
                    }
                    const int64_t spare = std::max<int64_t>(0,
                        market_store().stock[market_store().index(market, candidate.good_id)] - reserved);
                    const int64_t unit_numerator = saturating_add(saturating_mul(
                        GOODS_SCALE, Q16_ONE, _saturation_count),
                        candidate.efficiency_q16 - 1, _saturation_count);
                    const int64_t unit_physical = effective_production_input_quantity(
                        group.cell, candidate.good_id,
                        unit_numerator / candidate.efficiency_q16,
                        _saturation_count);
                    const int64_t effective_price = mul_div_sat(
                        market_store().price[market_store().index(market, candidate.good_id)],
                        unit_physical, GOODS_SCALE, _saturation_count);
                    const bool sufficient = spare >= quantity;
                    if (sufficient != best_sufficient ? sufficient :
                        (spare > best_spare ||
                         (spare == best_spare &&
                          effective_price < best_effective_price))) {
                        selected_good = candidate.good_id;
                        selected_quantity = quantity;
                        best_spare = spare;
                        best_sufficient = sufficient;
                        best_effective_price = effective_price;
                    }
                }
                if (selected_good < 0 || best_spare < selected_quantity) {
                    physical_inputs_available = false;
                    break;
                }
                auto total = std::find_if(recovery_probe_goods.begin(),
                    recovery_probe_goods.end(), [&](const auto &entry) {
                        return entry.first == selected_good;
                    });
                if (total == recovery_probe_goods.end()) {
                    recovery_probe_goods.push_back({selected_good, selected_quantity});
                } else {
                    total->second = saturating_add(
                        total->second, selected_quantity, _saturation_count);
                }
            }
            bool physical_resources_available = true;
            if (type.behavior_id == 1 || type.behavior_id == 2) {
                for (int32_t i = 0; i < type.resource_count; ++i) {
                    const ResourceAmount &item =
                        _building_resources[type.resource_begin + i];
                    const int64_t raw_base = item.mode == 1
                        ? saturating_mul(group.count, item.quantity, _saturation_count)
                        : saturating_mul(building_days, item.quantity, _saturation_count);
                    const int64_t base = effective_resource_use_quantity(
                        group.cell, item.resource_id, raw_base, _saturation_count);
                    const int64_t required = saturating_add(saturating_mul(
                        base, recovery_probe_floor_q16, _saturation_count),
                        Q16_ONE - 1, _saturation_count) / Q16_ONE;
                    if (required > available_resource_amount(item, group.cell)) {
                        physical_resources_available = false;
                        break;
                    }
                }
            }
            const bool executable = physical_inputs_available &&
                physical_resources_available && finance_available;
            const bool viable = expected_profit_margin >= _building_restart_margin_q16.get() &&
                executable;
            if (group_index < static_cast<int32_t>(
                    _building_recovery_liquidation_eligible.size())) {
                _building_recovery_liquidation_eligible[group_index] =
                    executable &&
                    expected_profit_margin < _building_restart_margin_q16.get();
            }
            if (viable) {
                _building_merchant_credit_limit[group_index] = credit_needed;
                _merchant_credit_committed = saturating_add(
                    _merchant_credit_committed, credit_needed, _saturation_count);
                cell_credit_remaining -= credit_needed;
                if (_merchant_credit_runtime_mode.get() == 2) {
                    // The legacy probe branch is unreachable. Keep any
                    // defensive transition in the suspended state so an old
                    // execution path can never publish state 2.
                    group.operating_state = 1;
                    group.pending_operating_state = 255;
                    group.recovery_cycles = 0;
                    ++_recovery_approved;
                    invalidate_cell_monetary_units(group.cell);
                }
            }
        }
        if (group.operating_state != 1) {
            // A rational operator scales only against expected after-tax cash
            // profit. Demand, inventory, sell-through and shortages contribute
            // to the revenue forecast above, but are not independent priorities
            // or health gates. Physical input/resource capacity remains applied
            // below because it is an execution constraint, not a preference.
            const int64_t expected_operating_cost = saturating_add(
                saturating_add(input_cost, employee_wages, _saturation_count),
                saturating_add(owner_living_cost, maintenance_cost,
                    _saturation_count), _saturation_count);
            const int64_t expected_business_eligible_cost = saturating_add(
                saturating_add(input_cost, employee_wages, _saturation_count),
                maintenance_cost, _saturation_count);
            const int32_t business_rate = frozen_tax_rate(
                group.cell, NativeCountryRuntime::TAX_BUSINESS, group.type_id);
            const int64_t business_base = business_rate < 0
                ? expected_business_eligible_cost : std::max<int64_t>(0, revenue);
            const int64_t business_transfer = expected_resolved_fiscal_transfer(
                group.cell, NativeCountryRuntime::TAX_BUSINESS, group.type_id,
                business_base, 1, _saturation_count);
            const int64_t income_base = std::max<int64_t>(0,
                saturating_sub(saturating_sub(
                    revenue, expected_business_eligible_cost, _saturation_count),
                    std::max<int64_t>(0, business_transfer), _saturation_count));
            const int32_t income_rate = frozen_tax_rate(
                group.cell, NativeCountryRuntime::TAX_INCOME,
                type.owner_profession_id);
            const int64_t income_transfer = expected_resolved_fiscal_transfer(
                group.cell, NativeCountryRuntime::TAX_INCOME,
                type.owner_profession_id,
                income_rate < 0
                    ? std::max<int64_t>(income_base, owner_living_cost)
                    : income_base,
                1, _saturation_count);
            // Owner-retained output is economic income for every building.
            // Cache the current-price opportunity quote for this group during
            // the frozen epoch, rather than reusing last epoch's currency
            // value. A new epoch invalidates the cache and observes prices,
            // stocks, and demand again.
            thread_local const NativeEconomyRuntime *in_kind_cache_runtime = nullptr;
            thread_local int64_t in_kind_cache_epoch = std::numeric_limits<int64_t>::min();
            thread_local std::vector<int64_t> in_kind_cache_values;
            thread_local std::vector<uint8_t> in_kind_cache_valid;
            if (in_kind_cache_runtime != this || in_kind_cache_epoch != _epoch_id.get()) {
                in_kind_cache_runtime = this;
                in_kind_cache_epoch = _epoch_id.get();
                in_kind_cache_values.assign(building_count(), 0);
                in_kind_cache_valid.assign(building_count(), 0);
            } else if (in_kind_cache_values.size() < building_count()) {
                const size_t old_size = in_kind_cache_values.size();
                in_kind_cache_values.resize(building_count(), 0);
                in_kind_cache_valid.resize(building_count(), 0);
                std::fill(in_kind_cache_valid.begin() + old_size,
                    in_kind_cache_valid.end(), 0);
            }
            int64_t expected_in_kind = 0;
            if (group.index >= 0 && group.index < static_cast<int32_t>(
                    in_kind_cache_values.size())) {
                const size_t cache_index = static_cast<size_t>(group.index);
                if (in_kind_cache_valid[cache_index] == 0) {
                    EconomyCostProbe::record("owner_quote.call.plan_inkind",
                                              _current_day.get(), 0.0, 1);
                    const OwnerOpportunityQuote opportunity = owner_opportunity_quote(
                        group, Q16_ONE, Q16_ONE, _saturation_count);
                    in_kind_cache_values[cache_index] = std::max<int64_t>(0,
                        opportunity.in_kind_retail_value);
                    in_kind_cache_valid[cache_index] = 1;
                }
                expected_in_kind = in_kind_cache_values[cache_index];
            }
            const int64_t expected_cash_profit = saturating_sub(
                saturating_sub(saturating_sub(revenue, expected_operating_cost,
                    _saturation_count), business_transfer, _saturation_count),
                income_transfer, _saturation_count);
            // When an observed group uses its realized-receipt quote above,
            // retained owner output is already part of `revenue`.  Add the
            // counterfactual in-kind quote only for unobserved groups so the
            // unified income basis does not count the same livelihood twice.
            const int64_t expected_profit = saturating_add(
                expected_cash_profit,
                observed_capacity ? 0 : expected_in_kind,
                _saturation_count);
            group.planned_utilization_q16 = expected_profit > 0
                ? static_cast<int32_t>(Q16_ONE) : 0;
            // Survival output is a bounded exception to pure cash-profit
            // gating. It may run only far enough to cover the frozen
            // subsistence/clothing floor computed for this owner, while its
            // monetary forecast remains the factual receipt above (possibly
            // zero). Resource, input, climate, and working-capital checks
            // below still constrain what can actually execute.
            if (group_index >= 0 && group_index < static_cast<int32_t>(
                    _building_survival_utilization_floor_q16.size())) {
                group.planned_utilization_q16 = std::max<int32_t>(
                    group.planned_utilization_q16,
                    static_cast<int32_t>(std::clamp<int64_t>(
                        _building_survival_utilization_floor_q16[group_index],
                        0, Q16_ONE)));
            }
            // Keep a bounded industrial probe for an occupied group even when
            // the current quote is temporarily unprofitable or input-funded
            // production is blocked. This preserves intent and the next
            // cycle's demand signal without creating a vacant owner or
            // bypassing physical input checks.
            if (group.filled_owner > 0 && type.input_count > 0 &&
                type.output_count > 0) {
                int32_t probe_floor_q16 = Q16_ONE / 32 + 1;
                for (int32_t i = 0; i < type.output_count; ++i) {
                    const int32_t output_good = _building_outputs[
                        type.output_begin + i].good_id;
                    if (output_good >= 0 && output_good <
                            static_cast<int32_t>(_good_storage_modes.size()) &&
                        _good_storage_modes[output_good] == 1) {
                        probe_floor_q16 = std::max<int32_t>(
                            probe_floor_q16, Q16_ONE / 6 + 1);
                    }
                }
                group.planned_utilization_q16 = std::max<int32_t>(
                    group.planned_utilization_q16, probe_floor_q16);
            }
        } else {
            group.planned_utilization_q16 = 0;
        }
        // Natural constraints are applied once by the production quote.  The
        // planning pass only decides whether the group wants to operate; it
        // must not pre-clamp the same plan by resource and climate again.
        // Otherwise owner/finance intent, resource capacity, and climate are
        // all counted as competing utilization minima before production even
        // gets a chance to form the final output quantity.
        if (group_index < static_cast<int32_t>(
                _building_planned_capacity_before_climate_q16.size())) {
            _building_planned_capacity_before_climate_q16[group_index] =
                group.planned_utilization_q16;
        }
        const int64_t effective_execution_q16 = std::min<int64_t>(
            std::clamp<int64_t>(actual_workforce_capacity_q16, 0, Q16_ONE),
            std::clamp<int64_t>(group.planned_utilization_q16, 0, Q16_ONE));
        group.purchase_intent_capacity_q16 = 0;
        const int64_t group_days = saturating_mul(
            group.count, std::max(1, _epoch_days.get()), _saturation_count);
        group.last_expected_revenue = mul_div_sat(
            saturating_mul(group_days, full_capacity_revenue, _saturation_count),
            effective_execution_q16, Q16_ONE, _saturation_count);
        group.last_quoted_market_receipt = group.last_expected_revenue;
        group.last_quoted_operating_cost = mul_div_sat(
            saturating_mul(group_days, operating, _saturation_count),
            effective_execution_q16, Q16_ONE, _saturation_count);
        group.last_maintenance_due = mul_div_sat(
            saturating_mul(group_days, maintenance_cost, _saturation_count),
            effective_execution_q16, Q16_ONE, _saturation_count);
        if (margin_gap < 0) ++_unprofitable_building_groups;
        if (group.operating_state != 0) ++_loss_suspended_building_groups;
        _utilization_sum_q16 = saturating_add(
            _utilization_sum_q16, group.planned_utilization_q16, _saturation_count);
        }
    }
    publish_result();
    return true;
}

} // namespace pk
