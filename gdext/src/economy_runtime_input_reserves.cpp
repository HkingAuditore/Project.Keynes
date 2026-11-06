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

void NativeEconomyRuntime::recount_production_input_reserve_totals() {
    _production_input_reserved = 0;
    _construction_material_reserved = 0;
    for (const int64_t value : _production_input_reserve) {
        _production_input_reserved = saturating_add(
            _production_input_reserved, value, _saturation_count);
    }
    for (const int64_t value : _construction_material_reserve) {
        _construction_material_reserved = saturating_add(
            _construction_material_reserved, value, _saturation_count);
    }
}

void NativeEconomyRuntime::rebuild_production_input_reserves(
        int32_t active_begin, int32_t active_end, bool initialize) {
    if (initialize) {
        _production_input_reserve.assign(_market_signals.good_ids.size(), 0);
        _construction_material_reserve.assign(_market_signals.good_ids.size(), 0);
        _production_input_reserved = 0;
        _production_input_reserve_shortfall = 0;
        _construction_material_reserved = 0;
    }
    const std::vector<int32_t> &active_cells = _epoch_active
        ? _epoch_building_cells : _building_active_cells;
    active_begin = std::clamp<int32_t>(
        active_begin, 0, static_cast<int32_t>(active_cells.size()));
    active_end = active_end < 0
        ? static_cast<int32_t>(active_cells.size())
        : std::clamp<int32_t>(active_end, active_begin,
                              static_cast<int32_t>(active_cells.size()));
    int64_t groups_rebuilt = 0;
    for (int32_t active = active_begin; active < active_end; ++active) {
        groups_rebuilt +=
            rebuild_production_input_reserves_for_cell(active_cells[active]);
    }
    if (initialize && active_begin == 0 &&
        active_end == static_cast<int32_t>(active_cells.size())) {
        _input_reserve_groups_rebuilt = groups_rebuilt;
    }
}

int64_t NativeEconomyRuntime::rebuild_production_input_reserves_for_cell(
        int32_t cell) {
    if (cell < 0 || cell >= _cell_count.get()) return 0;
    if (_building_cell_offsets.size() != static_cast<size_t>(_cell_count.get() + 1))
        return 0;
    const bool frozen = _epoch_active;
    thread_local std::vector<int32_t> selected_signals;
    thread_local std::vector<int64_t> selected_physical;
    auto input_purchase_scale_q16 = [&](const ProductionInput &input,
                                        int64_t output_scale_q16) -> int64_t {
        const int64_t required = std::clamp<int64_t>(input.required_q16, 0, Q16_ONE);
        if (required <= 0) return 0;
        // Soft and hard alike: buy for the objective activity scale. Soft is
        // optional productivity, not a floor-gated capacity band.
        return std::clamp<int64_t>(output_scale_q16, 0, Q16_ONE);
    };
    auto soft_efficiency_q16 = [&](const ProductionInput &input,
                                   int64_t coverage_q16) -> int64_t {
        const int64_t required = std::clamp<int64_t>(input.required_q16, 0, Q16_ONE);
        if (required <= 0) return Q16_ONE;
        coverage_q16 = std::clamp<int64_t>(coverage_q16, 0, Q16_ONE);
        if (required >= Q16_ONE) return coverage_q16;
        return std::clamp<int64_t>(
            Q16_ONE - required + mul_div_sat(
                coverage_q16, required, Q16_ONE, _saturation_count),
            0, Q16_ONE);
    };
    int64_t groups_rebuilt = 0;
    const int32_t group_begin = _building_cell_offsets[cell];
    const int32_t group_end = _building_cell_offsets[cell + 1];
    for (int32_t group_index = group_begin; group_index < group_end; ++group_index) {
        const auto group = building_view(static_cast<size_t>(group_index));
        if (group.count <= 0 ||
            group.cell < 0 || group.cell >= _cell_count.get() ||
            group.type_id < 0 ||
            group.type_id >= static_cast<int32_t>(_building_types.size()) ||
            !building_available(group.cell, group.type_id, frozen)) continue;
        ++groups_rebuilt;
        const BuildingType &type = _building_types[group.type_id];
        const int32_t market = market_store().cell_to_market[group.cell];
        const int64_t building_days = saturating_mul(
            group.count, std::max(1, _epoch_days.get()), _saturation_count);
        for (int32_t i = 0; i < type.maintenance_count; ++i) {
            const GoodAmount &item =
                _building_maintenance_goods[type.maintenance_begin + i];
            if (!is_storable_nonmonetary_good(item.good_id)) continue;
            const int32_t signal = market_signal_index(group.cell, item.good_id);
            if (signal < 0 || signal >= static_cast<int32_t>(
                    _construction_material_reserve.size())) continue;
            const int64_t period_need = saturating_mul(
                building_days, item.quantity, _saturation_count);
            int64_t one_shot = mul_div_sat(
                item.quantity, _good_target_inventory_days_q16[item.good_id],
                Q16_ONE, _saturation_count);
            for (int32_t bom = type.construction_begin;
                 bom < type.construction_begin + type.construction_count; ++bom) {
                const GoodAmount &construction =
                    _building_construction_goods[bom];
                if (construction.good_id == item.good_id)
                    one_shot = std::max(one_shot, construction.quantity);
            }
            _construction_material_reserve[signal] = saturating_add(
                _construction_material_reserve[signal], period_need,
                _saturation_count);
            _construction_material_reserve[signal] = std::max(
                _construction_material_reserve[signal], one_shot);
            _construction_material_reserved = saturating_add(
                _construction_material_reserved, period_need, _saturation_count);
        }
        for (int32_t bom = type.construction_begin;
             bom < type.construction_begin + type.construction_count; ++bom) {
            const GoodAmount &construction = _building_construction_goods[bom];
            if (!is_storable_nonmonetary_good(construction.good_id)) continue;
            const int32_t signal = market_signal_index(
                group.cell, construction.good_id);
            if (signal < 0 || signal >= static_cast<int32_t>(
                    _construction_material_reserve.size())) continue;
            _construction_material_reserve[signal] = std::max(
                _construction_material_reserve[signal], construction.quantity);
        }
        const int64_t utilization_q16 = std::clamp<int64_t>(
            group.planned_utilization_q16, 0, Q16_ONE);
        if (group.operating_state == 1 || utilization_q16 <= 0) continue;
        bool produces_survival_food = false;
        for (int32_t i = 0; i < type.output_count; ++i) {
            const int32_t good = _building_outputs[type.output_begin + i].good_id;
            produces_survival_food = produces_survival_food ||
                _survival_food_good_mask[good] != 0;
        }
        // Communal hearths are processors: they turn household-priority raw
        // food into prepared staples and must not reserve those raw inputs
        // ahead of households. Root harvesters retain the normal survival
        // reservation/fallback path.
        if (group.type_id >= 0 && group.type_id < static_cast<int32_t>(
                _building_type_ids.size()) &&
            _building_type_ids[group.type_id] == "communal_hearth")
            produces_survival_food = false;
        selected_signals.assign(type.input_count, -1);
        selected_physical.assign(type.input_count, 0);
        int64_t executable_q16 = Q16_ONE;
        bool household_priority_bundle = false;
        for (int32_t i = 0; i < type.input_count; ++i) {
            const ProductionInput &input = _building_inputs[type.input_begin + i];
            const int64_t required = std::clamp<int64_t>(input.required_q16, 0, Q16_ONE);
            // Optional inputs are decided by the production pass' marginal
            // value test.  They must never become hard inventory reserves or
            // emit full upstream shortage pressure here.
            if (required > 0 && required < Q16_ONE) continue;
            int32_t selected = -1;
            int32_t selected_signal = -1;
            int64_t selected_physical_qty = 0;
            int64_t best_capacity_q16 = -1;
            int64_t best_effective_price = std::numeric_limits<int64_t>::max();
            const int64_t full_effective = saturating_mul(
                building_days, input.quantity, _saturation_count);
            const int64_t purchase_scale_q16 = input_purchase_scale_q16(
                input, utilization_q16);
            if (purchase_scale_q16 <= 0) continue;
            const int64_t scaled_numerator = saturating_add(saturating_mul(
                full_effective, purchase_scale_q16, _saturation_count),
                Q16_ONE - 1, _saturation_count);
            const int64_t scaled_effective = scaled_numerator / Q16_ONE;
            for (int32_t c = input.candidate_begin;
                 c < input.candidate_begin + input.candidate_count; ++c) {
                const InputCandidate &candidate = _building_input_candidates[c];
                if (_good_storage_modes[candidate.good_id] != 0 ||
                !good_input_candidate_available(group.cell, candidate.good_id, frozen)) continue;
                const int32_t signal = market_signal_index(group.cell, candidate.good_id);
                if (signal < 0 || signal >= static_cast<int32_t>(
                        _production_input_reserve.size())) continue;
                const int64_t physical_numerator = saturating_add(saturating_mul(
                    scaled_effective, Q16_ONE, _saturation_count),
                    candidate.efficiency_q16 - 1, _saturation_count);
                const int64_t physical = effective_production_input_quantity(
                    cell, candidate.good_id,
                    physical_numerator / candidate.efficiency_q16,
                    _saturation_count);
                const int64_t available = std::max<int64_t>(0,
                    market_store().stock[market_store().index(market, candidate.good_id)] -
                    _production_input_reserve[signal]);
                const int64_t capacity_q16 = physical > 0
                    ? std::min<int64_t>(Q16_ONE, mul_div_sat(
                        available, Q16_ONE, physical, _saturation_count))
                    : Q16_ONE;
                const int64_t unit_numerator = saturating_add(saturating_mul(
                    GOODS_SCALE, Q16_ONE, _saturation_count),
                    candidate.efficiency_q16 - 1, _saturation_count);
                const int64_t unit_physical = effective_production_input_quantity(
                    cell, candidate.good_id,
                    unit_numerator / candidate.efficiency_q16,
                    _saturation_count);
                const int64_t effective_price = mul_div_sat(
                    market_store().price[market_store().index(market, candidate.good_id)],
                    unit_physical, GOODS_SCALE, _saturation_count);
                if (capacity_q16 > best_capacity_q16 ||
                    (capacity_q16 == best_capacity_q16 &&
                     (effective_price < best_effective_price ||
                      (effective_price == best_effective_price &&
                       (selected < 0 || candidate.good_id <
                        _building_input_candidates[selected].good_id))))) {
                    selected = c;
                    selected_signal = signal;
                    selected_physical_qty = physical;
                    best_capacity_q16 = capacity_q16;
                    best_effective_price = effective_price;
                }
            }
            if (selected < 0) {
                // Soft shortage cuts throughput efficiency later; hard zeros.
                if (required >= Q16_ONE) executable_q16 = 0;
                else if (required > 0) {
                    executable_q16 = mul_div_sat(executable_q16,
                        soft_efficiency_q16(input, 0), Q16_ONE, _saturation_count);
                }
                continue;
            }
            const InputCandidate &candidate = _building_input_candidates[selected];
            selected_signals[i] = selected_signal;
            selected_physical[i] = selected_physical_qty;
            if (required >= Q16_ONE) {
                executable_q16 = std::min(executable_q16, best_capacity_q16);
            } else if (required > 0) {
                executable_q16 = mul_div_sat(executable_q16,
                    soft_efficiency_q16(input, best_capacity_q16), Q16_ONE,
                    _saturation_count);
            }
            if (!produces_survival_food &&
                _survival_food_good_mask[candidate.good_id] != 0) {
                household_priority_bundle = true;
            }
        }
        // Hard complementary slots that share a SKU must not over-reserve.
        // Soft tools already folded into efficiency above — do not let their
        // stock re-ceiling the hard purchase band.
        for (int32_t i = 0; i < type.input_count; ++i) {
            const int32_t signal = selected_signals[i];
            if (signal < 0) continue;
            const ProductionInput &hard_probe =
                _building_inputs[type.input_begin + i];
            if (std::clamp<int64_t>(hard_probe.required_q16, 0, Q16_ONE) < Q16_ONE)
                continue;
            bool first_for_signal = true;
            int64_t combined_desired = 0;
            for (int32_t j = 0; j < type.input_count; ++j) {
                if (selected_signals[j] != signal) continue;
                const ProductionInput &peer =
                    _building_inputs[type.input_begin + j];
                if (std::clamp<int64_t>(peer.required_q16, 0, Q16_ONE) < Q16_ONE)
                    continue;
                if (j < i) first_for_signal = false;
                combined_desired = saturating_add(
                    combined_desired, selected_physical[j], _saturation_count);
            }
            if (!first_for_signal || combined_desired <= 0) continue;
            const int32_t good = _market_signals.good_ids[signal];
            const int64_t available = std::max<int64_t>(0,
                market_store().stock[market_store().index(market, good)] -
                _production_input_reserve[signal]);
            executable_q16 = std::min<int64_t>(executable_q16,
                std::min<int64_t>(Q16_ONE, mul_div_sat(
                    available, Q16_ONE, combined_desired, _saturation_count)));
        }
        // Survival producers keep a bounded next-period input reservation even
        // when local stock is temporarily empty. The reservation is a
        // protected procurement signal; it does not mint goods or bypass the
        // production quote/commit path.
        if (executable_q16 <= 0 && produces_survival_food &&
            group.filled_owner > 0 && type.input_count > 0) {
            executable_q16 = Q16_ONE;
        }
        // 家庭生存消费优先于非生存加工；此类加工只能使用家庭结算后的余量，
        // 因而整套互补投入都不提前保护。
        if (household_priority_bundle) executable_q16 = 0;
        for (int32_t i = 0; i < type.input_count; ++i) {
            const int32_t signal = selected_signals[i];
            const int64_t desired = selected_physical[i];
            if (signal < 0 || desired <= 0) continue;
            const ProductionInput &input = _building_inputs[type.input_begin + i];
            const int64_t required = std::clamp<int64_t>(
                input.required_q16, 0, Q16_ONE);
            // Soft tools reserve the full activity buy intent; hard inputs
            // scale with the stock-feasible hard executable band.
            const int64_t reserved = required < Q16_ONE
                ? desired
                : mul_div_sat(desired, executable_q16, Q16_ONE, _saturation_count);
            _production_input_reserve[signal] = saturating_add(
                _production_input_reserve[signal], reserved, _saturation_count);
            _production_input_reserved = saturating_add(
                _production_input_reserved, reserved, _saturation_count);
            _production_input_reserve_shortfall = saturating_add(
                _production_input_reserve_shortfall,
                std::max<int64_t>(0, desired - reserved), _saturation_count);
        }
    }
    reserve_first_research_construction(cell);
    return groups_rebuilt;
}

bool NativeEconomyRuntime::is_storable_nonmonetary_good(int32_t good) const {
    return good >= 0 &&
        good < static_cast<int32_t>(_good_storage_modes.size()) &&
        good < static_cast<int32_t>(_good_monetary_issue_values.size()) &&
        _good_storage_modes[good] == 0 &&
        _good_monetary_issue_values[good] <= 0;
}

int32_t NativeEconomyRuntime::resolved_maintenance_horizon_days(
        const BuildingType &type) const {
    if (type.maintenance_horizon_days > 0) return type.maintenance_horizon_days;
    const int32_t sector = std::clamp(type.economic_sector, 0, 4);
    return std::max(1, _maintenance_horizon_days_by_sector[sector]);
}

int64_t NativeEconomyRuntime::merchant_protected_reserve(int32_t signal) const {
    int64_t input = 0;
    int64_t construction = 0;
    if (signal >= 0 && signal < static_cast<int32_t>(_production_input_reserve.size()))
        input = std::max<int64_t>(0, _production_input_reserve[signal]);
    if (signal >= 0 && signal < static_cast<int32_t>(_construction_material_reserve.size()))
        construction = std::max<int64_t>(0, _construction_material_reserve[signal]);
    return std::max(input, construction);
}

int64_t NativeEconomyRuntime::maintenance_settlement_price(
        int32_t cell, int32_t good, int64_t &sat) const {
    if (!is_storable_nonmonetary_good(good)) return 0;
    int64_t retail = 0;
    if (cell >= 0 && cell < _cell_count.get() &&
        good_market_available(cell, good, true)) {
        const int32_t market = market_store().cell_to_market[cell];
        if (market >= 0)
            retail = std::max<int64_t>(0, market_store().price[market_store().index(market, good)]);
    }
    if (retail <= 0 && good < static_cast<int32_t>(_good_default_price.size()))
        retail = std::max<int64_t>(0, _good_default_price[good]);
    if (retail <= 0) return 0;
    const int32_t factor = good < static_cast<int32_t>(
            _good_merchant_buy_factor_q16.size())
        ? _good_merchant_buy_factor_q16[good] : Q16_ONE;
    return std::max<int64_t>(1, mul_div_sat(retail, factor, Q16_ONE, sat));
}

int64_t NativeEconomyRuntime::daily_maintenance_cost_for_type(
        int32_t cell, const BuildingType &type, int64_t &sat) const {
    int64_t cost = 0;
    for (int32_t i = 0; i < type.maintenance_count; ++i) {
        const GoodAmount &item = _building_maintenance_goods[type.maintenance_begin + i];
        const int64_t price = maintenance_settlement_price(cell, item.good_id, sat);
        if (price <= 0) return std::numeric_limits<int64_t>::max();
        cost = saturating_add(cost, mul_div_sat(
            item.quantity, price, GOODS_SCALE, sat), sat);
    }
    return cost;
}

void NativeEconomyRuntime::resolve_building_maintenance_csr() {
    _building_maintenance_goods.clear();
    if (_building_types.empty()) {
        _building_maintenance_author_offsets.clear();
        _building_maintenance_author_goods.clear();
        return;
    }
    if (_building_maintenance_author_offsets.size() != _building_types.size() + 1) {
        _building_maintenance_author_offsets.assign(_building_types.size() + 1, 0);
        _building_maintenance_author_goods.clear();
    }
    for (size_t type_index = 0; type_index < _building_types.size(); ++type_index) {
        BuildingType &type = _building_types[type_index];
        type.maintenance_begin = static_cast<int32_t>(_building_maintenance_goods.size());
        const int32_t author_begin = _building_maintenance_author_offsets[type_index];
        const int32_t author_end = _building_maintenance_author_offsets[type_index + 1];
        bool authored = false;
        for (int32_t item = author_begin; item < author_end; ++item) {
            if (item < 0 || item >= static_cast<int32_t>(
                    _building_maintenance_author_goods.size())) continue;
            const GoodAmount &row = _building_maintenance_author_goods[item];
            if (!is_storable_nonmonetary_good(row.good_id) || row.quantity <= 0)
                continue;
            _building_maintenance_goods.push_back(row);
            authored = true;
        }
        if (!authored && type.kind != 2 && type.construction_count > 0) {
            const int32_t horizon = resolved_maintenance_horizon_days(type);
            for (int32_t item = type.construction_begin;
                 item < type.construction_begin + type.construction_count; ++item) {
                const GoodAmount &bom = _building_construction_goods[item];
                if (!is_storable_nonmonetary_good(bom.good_id) || bom.quantity <= 0)
                    continue;
                int64_t daily = bom.quantity / std::max(1, horizon);
                if (daily <= 0) daily = 1;
                daily = mul_div_sat(daily, _building_maintenance_cost_factor_q16.get(),
                                    Q16_ONE, _saturation_count);
                if (daily <= 0) daily = 1;
                _building_maintenance_goods.push_back({bom.good_id, daily});
            }
        }
        type.maintenance_count = static_cast<int32_t>(
            _building_maintenance_goods.size()) - type.maintenance_begin;
    }
}

void NativeEconomyRuntime::build_demand_basis_cached(
        int32_t cell, int32_t market, const EnvironmentSample &sample,
        std::vector<int64_t> &variant_scores, std::vector<int64_t> &variant_prices,
        std::vector<int64_t> &need_score_sums, std::vector<int64_t> &need_composites,
        std::vector<int64_t> &need_environment, int64_t &sat) {
    if (cell < 0 || cell >= _cell_count.get()) {
        build_demand_basis(market, sample, variant_scores, variant_prices,
                           need_score_sums, need_composites, need_environment, sat);
        return;
    }
    const size_t variant_count = _variants.size();
    const size_t need_count = _needs.size();
    const size_t cells = static_cast<size_t>(_cell_count.get());
    if (_demand_basis_cache_day.size() != cells ||
        _demand_basis_variant_scores.size() != cells * variant_count ||
        _demand_basis_need_score_sums.size() != cells * need_count) {
        _demand_basis_cache_day.assign(
            cells, std::numeric_limits<int64_t>::min());
        _demand_basis_variant_scores.resize(cells * variant_count);
        _demand_basis_variant_prices.resize(cells * variant_count);
        _demand_basis_need_score_sums.resize(cells * need_count);
        _demand_basis_need_composites.resize(cells * need_count);
        _demand_basis_need_environment.resize(cells * need_count);
    }
    const size_t variant_offset = static_cast<size_t>(cell) * variant_count;
    const size_t need_offset = static_cast<size_t>(cell) * need_count;
    if (_demand_basis_cache_day[cell] != _sample_day) {
        build_demand_basis(market, sample, variant_scores, variant_prices,
                           need_score_sums, need_composites, need_environment, sat);
        std::copy(variant_scores.begin(), variant_scores.end(),
                  _demand_basis_variant_scores.begin() + variant_offset);
        std::copy(variant_prices.begin(), variant_prices.end(),
                  _demand_basis_variant_prices.begin() + variant_offset);
        std::copy(need_score_sums.begin(), need_score_sums.end(),
                  _demand_basis_need_score_sums.begin() + need_offset);
        std::copy(need_composites.begin(), need_composites.end(),
                  _demand_basis_need_composites.begin() + need_offset);
        std::copy(need_environment.begin(), need_environment.end(),
                  _demand_basis_need_environment.begin() + need_offset);
        _demand_basis_cache_day[cell] = _sample_day;
        return;
    }
    variant_scores.assign(
        _demand_basis_variant_scores.begin() + variant_offset,
        _demand_basis_variant_scores.begin() + variant_offset + variant_count);
    variant_prices.assign(
        _demand_basis_variant_prices.begin() + variant_offset,
        _demand_basis_variant_prices.begin() + variant_offset + variant_count);
    need_score_sums.assign(
        _demand_basis_need_score_sums.begin() + need_offset,
        _demand_basis_need_score_sums.begin() + need_offset + need_count);
    need_composites.assign(
        _demand_basis_need_composites.begin() + need_offset,
        _demand_basis_need_composites.begin() + need_offset + need_count);
    need_environment.assign(
        _demand_basis_need_environment.begin() + need_offset,
        _demand_basis_need_environment.begin() + need_offset + need_count);
}

void NativeEconomyRuntime::prepare_due_demand_basis_cache() {
    EconomyCostProbe cost("demand_basis.prepare", _current_day.get(), _epoch_building_cells.size());
    const int32_t cell_count = static_cast<int32_t>(_epoch_building_cells.size());
    if (cell_count <= 0) return;
    std::vector<int64_t> saturation_by_cell(static_cast<size_t>(cell_count), 0);
    // 此处每格计算整个 need/variant 基底，不能沿用轻量 market range 的 64 格阈值。
    static const bool serial = [] {
        const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_ACTIVE_WORKSET_DISABLE);
        return value && std::strcmp(value, "1") == 0;
    }();
    const int32_t task_count = !serial && _worker_enabled && cell_count >= 2 &&
            static_cast<size_t>(cell_count) * _variants.size() >= 256 &&
            parallel_has_real_worker_threads()
        ? std::min({cell_count, _worker_task_cap,
            _worker_tasks_hint > 0 ? _worker_tasks_hint : _worker_task_cap})
        : 1;
    auto prepare_range = [&](int32_t begin, int32_t end) {
        std::vector<int64_t> variant_scores;
        std::vector<int64_t> variant_prices;
        std::vector<int64_t> need_score_sums;
        std::vector<int64_t> need_composites;
        std::vector<int64_t> need_environment;
        for (int32_t index = begin; index < end; ++index) {
            const int32_t cell = _epoch_building_cells[index];
            const int32_t market = market_store().cell_to_market[cell];
            int64_t local_saturation = 0;
            build_demand_basis(
                market, environment_sample_for_cell(cell), variant_scores,
                variant_prices, need_score_sums, need_composites,
                need_environment, local_saturation);
            const size_t variant_offset =
                static_cast<size_t>(cell) * _variants.size();
            const size_t need_offset =
                static_cast<size_t>(cell) * _needs.size();
            std::copy(variant_scores.begin(), variant_scores.end(),
                      _demand_basis_variant_scores.begin() + variant_offset);
            std::copy(variant_prices.begin(), variant_prices.end(),
                      _demand_basis_variant_prices.begin() + variant_offset);
            std::copy(need_score_sums.begin(), need_score_sums.end(),
                      _demand_basis_need_score_sums.begin() + need_offset);
            std::copy(need_composites.begin(), need_composites.end(),
                      _demand_basis_need_composites.begin() + need_offset);
            std::copy(need_environment.begin(), need_environment.end(),
                      _demand_basis_need_environment.begin() + need_offset);
            _demand_basis_cache_day[cell] = _sample_day;
            saturation_by_cell[index] = local_saturation;
        }
    };
    if (task_count > 1) {
        parallel_for_range("pk_economy_demand_basis", cell_count, task_count,
                           2, prepare_range);
    } else {
        prepare_range(0, cell_count);
    }
    for (const int64_t local_saturation : saturation_by_cell) {
        _saturation_count += local_saturation;
    }
    EconomyCostProbe::record("demand_basis.prepare_tasks", _current_day.get(), 0.0, task_count);
}

} // namespace pk
