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

namespace {
bool derived_price_conduction_enabled() {
    static const bool value = [] {
        const char *flag = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_DERIVED_PRICE_CONDUCTION);
        return !(flag && std::strcmp(flag, "0") == 0);
    }();
    return value;
}

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

} // namespace

NativeEconomyRuntime::PricePressure NativeEconomyRuntime::price_pressure(
        int32_t market, int32_t good, int64_t household_demand, int64_t stock,
        int64_t shortage_q16, int32_t signal_index, int64_t &sat) const {
    PricePressure out;
    out.household_demand = std::max<int64_t>(0, household_demand);
    if (signal_index >= 0) {
        const bool frozen_signals =
            _epoch_business_demand_ema.size() == _market_signals.business_demand_ema.size() &&
            _epoch_offered_supply_ema.size() == _market_signals.offered_supply_ema.size();
        out.business_demand = frozen_signals
            ? _epoch_business_demand_ema[signal_index]
            : _market_signals.business_demand_ema[signal_index];
        out.supply = frozen_signals
            ? _epoch_offered_supply_ema[signal_index]
            : _market_signals.offered_supply_ema[signal_index];
    }
    // Government research procurement is a frozen non-household buyer. It
    // must participate in price formation as well as investment candidate
    // discovery; otherwise the first research producer is valued at the
    // default price forever because no historical stock withdrawal exists.
    out.business_demand = saturating_add(
        out.business_demand,
        epoch_procurement_demand_daily_for_market(market, good), sat);
    // Shadow derived demand is consumed by price formation and investment
    // ranking only. Keep it out of real business demand so it cannot change
    // stock targets, procurement, sales, or owner vacancy.
    int64_t shadow_derived_pressure_q16 = 0;
    int64_t shadow_derived_quantity = 0;
    if (signal_index >= 0) {
        if (signal_index < static_cast<int32_t>(
                _epoch_derived_business_demand.size())) {
            shadow_derived_quantity = saturating_add(
                shadow_derived_quantity,
                std::max<int64_t>(0, _epoch_derived_business_demand[signal_index]),
                sat);
        }
        if (signal_index < static_cast<int32_t>(
                _epoch_substitute_business_demand.size())) {
            shadow_derived_quantity = saturating_add(
                shadow_derived_quantity,
                std::max<int64_t>(0, _epoch_substitute_business_demand[signal_index]),
                sat);
        }
    }
    if (shadow_derived_quantity > 0) {
        const int64_t derived = shadow_derived_quantity;
        const int64_t real_flow = saturating_add(
            saturating_add(out.household_demand, out.business_demand, sat),
            out.supply, sat);
        // Demand conduction only: normalize derived against local flow and
        // apply the configured weight. No stock-gated pressure floor and no
        // later change_q16 clamp — inventory/excess still clear a glut.
        // Relative-gap normalization keeps a small BOM requirement visible on
        // an otherwise empty lane while a real local glut still dilutes it.
        const int64_t derived_scale = derived_price_conduction_enabled()
            ? std::max<int64_t>(1, saturating_add(derived, real_flow, sat))
            : std::max<int64_t>(GOODS_SCALE, real_flow);
        shadow_derived_pressure_q16 = mul_div_sat(
            std::min<int64_t>(derived, derived_scale),
            Q16_ONE, derived_scale, sat);
        shadow_derived_pressure_q16 = mul_div_sat(
            shadow_derived_pressure_q16,
            std::clamp<int64_t>(_derived_business_demand_weight_q16, 0, Q16_ONE),
            Q16_ONE, sat);
    }
    out.derived_q16 = shadow_derived_pressure_q16;
    const int64_t demand = saturating_add(out.household_demand, out.business_demand, sat);
    const int64_t flow = saturating_add(demand, out.supply, sat);
    out.excess_q16 = std::clamp<int64_t>(mul_div_sat(
        saturating_sub(demand, out.supply, sat), Q16_ONE,
        std::max<int64_t>(GOODS_SCALE, flow), sat), -Q16_ONE, Q16_ONE);
    if (_good_storage_modes[good] == 0) {
        const int64_t price_inventory_days_q16 = std::min<int64_t>(
            _good_target_inventory_days_q16[good],
            saturating_mul(std::max(1, _epoch_days.get()), Q16_ONE, sat));
        out.inventory_target = mul_div_sat(
            demand, price_inventory_days_q16, Q16_ONE, sat);
        out.inventory_q16 = std::clamp<int64_t>(mul_div_sat(
            saturating_sub(out.inventory_target, stock, sat), Q16_ONE,
            std::max<int64_t>(GOODS_SCALE, out.inventory_target), sat), -Q16_ONE, Q16_ONE);
        out.shortage_q16 = std::clamp<int64_t>(shortage_q16, 0, Q16_ONE);
    }
    const int64_t price = std::max<int64_t>(1, market_store().price[market_store().index(market, good)]);
    const int64_t anchor = signal_index >= 0 &&
        _epoch_cost_anchor_price.size() == _market_signals.cost_anchor_price.size()
            ? _epoch_cost_anchor_price[signal_index]
            : (signal_index >= 0 ? _market_signals.cost_anchor_price[signal_index] : 0);
    int64_t adjustment_anchor = std::max<int64_t>(
        _good_default_price[good], anchor);
    if (derived_price_conduction_enabled() && anchor <= 0 &&
        signal_index >= 0 &&
        signal_index < static_cast<int32_t>(_epoch_derived_anchor_price.size()) &&
        _epoch_derived_anchor_price[signal_index] > 0) {
        const int64_t shadow = _epoch_derived_anchor_price[signal_index];
        adjustment_anchor = std::max<int64_t>(adjustment_anchor,
            std::min<int64_t>(shadow, std::max<int64_t>(1, shadow - price)));
    }
    out.adjustment_anchor_price = std::max<int64_t>(1, adjustment_anchor);
    if (signal_index >= 0 && _good_monetary_issue_values[good] == 0 && anchor > 0) {
        const int64_t confidence = std::min<int64_t>(Q16_ONE, mul_div_sat(
            out.supply, Q16_ONE, std::max<int64_t>(GOODS_SCALE, demand), sat));
        out.cost_q16 = mul_div_sat(std::clamp<int64_t>(mul_div_sat(
            anchor - price, Q16_ONE, std::max<int64_t>(anchor, price), sat),
            -Q16_ONE, Q16_ONE), confidence, Q16_ONE, sat);
    }
    // Inventory overhang weakens only upward cost anchoring. This reuses the
    // existing normalized inventory signal, with no new per-market history.
    if (out.cost_q16 > 0 && out.inventory_q16 < 0) {
        out.cost_q16 = inventory_adjusted_cost_pressure(
            out.cost_q16, out.inventory_q16, sat);
        out.glut_cost_damped = true;
    }
    // Idle reversion is for truly quiet lanes. A one-hop Leontief shadow from
    // a scarce downstream good is still a price signal: suppressing idle here
    // lets intermediate prices rise without folding derived into procurement
    // targets or owner opportunity (those stay on real business demand only).
    if (demand == 0 && out.supply == 0 && stock == 0 &&
        shadow_derived_quantity <= 0) {
        out.idle_q16 = std::clamp<int64_t>(mul_div_sat(
            static_cast<int64_t>(_good_default_price[good]) - price, Q16_ONE,
            std::max<int64_t>(1, std::max<int64_t>(_good_default_price[good], price)), sat),
            -Q16_ONE, Q16_ONE);
    }
    out.total_q16 = 0;
    out.total_q16 = saturating_add(out.total_q16, mul_div_sat(
        out.excess_q16, _good_excess_demand_weight_q16[good], Q16_ONE, sat), sat);
    out.total_q16 = saturating_add(out.total_q16, mul_div_sat(
        out.inventory_q16, _good_inventory_weight_q16[good], Q16_ONE, sat), sat);
    out.total_q16 = saturating_add(out.total_q16, mul_div_sat(
        out.shortage_q16, _good_shortage_weight_q16[good], Q16_ONE, sat), sat);
    out.total_q16 = saturating_add(out.total_q16, mul_div_sat(
        out.cost_q16, _good_cost_anchor_weight_q16[good], Q16_ONE, sat), sat);
    out.total_q16 = saturating_add(out.total_q16, mul_div_sat(
        shadow_derived_pressure_q16, _good_excess_demand_weight_q16[good],
        Q16_ONE, sat), sat);
    const int64_t elasticity = std::clamp<int64_t>(
        _good_demand_price_elasticity_q16[good], Q16_ONE / 4, Q16_ONE * 4);
    const int64_t adjusted = mul_div_sat(out.total_q16, Q16_ONE, elasticity, sat);
    out.change_q16 = mul_div_sat(adjusted, _good_price_adjust_q16[good], Q16_ONE, sat);
    out.inactive_reversion_alpha_q16 = mul_div_sat(mul_div_sat(
        _good_inactive_reversion_weight_q16[good], Q16_ONE, elasticity, sat),
        _good_price_adjust_q16[good], Q16_ONE, sat);
    return out;
}

int32_t NativeEconomyRuntime::market_price_ceiling(
        int32_t market, int32_t good, int64_t cost_anchor) const {
    int32_t limit = base_price_ceiling(_good_reference_max_price[good],
                                      _good_default_price[good], cost_anchor);
    const auto &rows = market_store().price_ceilings[market];
    const auto it = std::lower_bound(rows.begin(), rows.end(), good,
        [](const PriceCeilingState &row, int32_t id) { return row.good < id; });
    if (it != rows.end() && it->good == good) limit = std::max(limit, it->limit);
    return limit;
}

int64_t NativeEconomyRuntime::price_ceiling_state_count() const {
    int64_t count = 0;
    for (const auto &row : market_store().price_ceilings) count += row.size();
    return count;
}

void NativeEconomyRuntime::commit_price_ceilings() {
    // All household/building work is joined and actual research delivery is now
    // known. Query and trade prediction never enter this state transition.
    std::sort(_epoch_price_ceiling_observations.begin(), _epoch_price_ceiling_observations.end(),
        [](const auto &a, const auto &b) { return std::pair{a.market,a.good} < std::pair{b.market,b.good}; });
    size_t begin = 0;
    while (begin < _epoch_price_ceiling_observations.size()) {
        const int32_t market = _epoch_price_ceiling_observations[begin].market;
        size_t end = begin + 1;
        while (end < _epoch_price_ceiling_observations.size() &&
               _epoch_price_ceiling_observations[end].market == market) ++end;
        auto ceiling_write = market_store().price_ceilings.edit_row(market);
        auto &old = ceiling_write[0];
        // Reuse the previous row's storage at the serial merge boundary.
        // Once active rows have warmed up this performs no allocation.
        auto &next = _price_ceiling_merge_scratch;
        next.clear();
        next.reserve(end - begin);
        size_t cursor = 0;
        for (size_t i = begin; i < end; ++i) {
            const auto &observation = _epoch_price_ceiling_observations[i];
            while (cursor < old.size() && old[cursor].good < observation.good) ++cursor;
            PriceCeilingState state = cursor < old.size() && old[cursor].good == observation.good
                ? old[cursor] : PriceCeilingState{observation.good, observation.base, 0};
            int64_t requested = observation.requested, unfilled = observation.unfilled;
            if (observation.good == _epoch_research_good_id) {
                requested = saturating_add(requested, _epoch_ceiling_research_requested[market], _saturation_count);
                unfilled = saturating_add(unfilled, std::max<int64_t>(0,
                    _epoch_ceiling_research_requested[market] - _epoch_ceiling_research_delivered[market]), _saturation_count);
            }
            const int64_t shortage = requested > 0 ? std::clamp<int64_t>(
                mul_div_sat(unfilled, Q16_ONE, requested, _saturation_count), 0, Q16_ONE) : 0;
            const int32_t before = std::max(state.limit, observation.base);
            state = advance_price_ceiling(state, observation.base, observation.price, shortage,
                observation.days, _price_ceiling_confirm_days.get(), _price_ceiling_expand_bp.get(), _price_ceiling_recover_bp.get());
            if (state.limit > before) ++_price_ceiling_expansions;
            if (state.limit < before) ++_price_ceiling_recoveries;
            if (state.limit > observation.base || state.confirmation_days > 0 ||
                int64_t(observation.price) * 10 >= int64_t(observation.base) * 7) next.push_back(state);
        }
        old.swap(next);
        begin = end;
    }
    _epoch_price_ceiling_observations.clear();
}

int64_t NativeEconomyRuntime::next_price_v6(
        int32_t good, int64_t current_price, const PricePressure &pressure,
        int32_t days, int64_t &sat, bool &rate_clamped, bool &rise_damped, bool *minimum_tick) const {
    if (minimum_tick) *minimum_tick = false;
    const int64_t unclamped_change_q16 = pressure.change_q16;
    const int64_t change_q16 = std::clamp<int64_t>(unclamped_change_q16,
        -static_cast<int64_t>(_good_max_price_fall_q16[good]),
        static_cast<int64_t>(_good_max_price_rise_q16[good]));
    rate_clamped = unclamped_change_q16 != change_q16;
    rise_damped = false;
    int64_t period_change_q16 = saturating_mul(
        change_q16, std::max(1, days), sat);
    // Positive pressure uses the stable default/cost anchor so repeated
    // shortages do not compound exponentially. Negative pressure uses the
    // current market price: a high cost anchor must not amplify a glut-driven
    // markdown into a collapse below the producer's economic scale.
    const int64_t adjustment_reference = price_adjustment_reference(
        current_price, pressure.adjustment_anchor_price, period_change_q16);
    int64_t delta = mul_div_sat(
        adjustment_reference, period_change_q16, Q16_ONE, sat);
    // Preserve a nonzero rate through price quantization, at the numeric floor.
    if (delta == 0 && change_q16 != 0) {
        delta = change_q16 > 0 ? 1 : -1;
        if (minimum_tick) *minimum_tick = true;
    }
    int64_t next = saturating_add(current_price, delta, sat);
    if (pressure.idle_q16 != 0 && pressure.inactive_reversion_alpha_q16 > 0) {
        const int64_t alpha_q16 = std::min<int64_t>(Q16_ONE, saturating_mul(
            pressure.inactive_reversion_alpha_q16, std::max(1, days), sat));
        next = saturating_add(next, mul_div_sat(
            static_cast<int64_t>(_good_default_price[good]) - next,
            alpha_q16, Q16_ONE, sat), sat);
    }
    return next;
}

bool NativeEconomyRuntime::evaluate_building_conditions(int32_t type_id, int32_t cell) const {
    if (type_id < 0 || type_id >= static_cast<int32_t>(_building_types.size()) ||
        cell < 0 || cell >= _cell_count.get()) return false;
    const BuildingType &type = _building_types[type_id];
    if (type.condition_count == 0) return true;
    if (type.condition_count > 64) return false;
    if (type.condition_begin < 0 ||
        static_cast<size_t>(type.condition_begin) +
            static_cast<size_t>(type.condition_count) >
            _building_conditions.size())
        return false;
    bool stack[64]{};
    int32_t top = 0;
    auto compare = [](int64_t lhs, int32_t op, int64_t rhs) {
        switch (op) {
            case 0: return lhs == rhs;
            case 1: return lhs != rhs;
            case 2: return lhs < rhs;
            case 3: return lhs <= rhs;
            case 4: return lhs > rhs;
            case 5: return lhs >= rhs;
            default: return false;
        }
    };
    // Environment and building-context lanes are captured per day, so a cold
    // query that runs before the first capture (UI inspector, colonization
    // preview) sees empty vectors. Report "conditions unmet" for the missing
    // signal instead of indexing past the lane.
    bool lanes_ready = true;
    auto lane = [&](const auto &values) -> int64_t {
        if (static_cast<size_t>(cell) >= values.size()) {
            lanes_ready = false;
            return 0;
        }
        return static_cast<int64_t>(values[static_cast<size_t>(cell)]);
    };
    for (int32_t i = 0; i < type.condition_count; ++i) {
        const ConditionToken &token = _building_conditions[type.condition_begin + i];
        if (token.opcode == 1) {
            int64_t lhs = 0;
            switch (token.signal) {
                case 0: lhs = lane(_environment_temperature_q16); break;
                case 1: lhs = lane(_environment_moisture_q16); break;
                case 2: lhs = lane(_environment_snow_q16); break;
                case 3: lhs = lane(_environment_weather_q16); break;
                case 4: lhs = lane(_building_elevation_q16); break;
                case 5: lhs = lane(_building_terrain); break;
                case 6: lhs = lane(_building_landform); break;
                case 7: lhs = lane(_building_vegetation); break;
                case 8: lhs = lane(_building_is_water); break;
                case 9: lhs = lane(_building_has_river); break;
                case 10: {
                    if (token.reference < 0 || token.reference >=
                            static_cast<int32_t>(_resource_ids.size()))
                        return false;
                    const size_t index =
                        static_cast<size_t>(token.reference) *
                            static_cast<size_t>(_cell_count.get()) +
                        static_cast<size_t>(cell);
                    if (index >= resource_stock_lanes().size()) return false;
                    lhs = resource_stock_lanes()[index];
                    break;
                }
                default: return false;
            }
            if (!lanes_ready) return false;
            if (top >= 64) return false;
            stack[top++] = compare(lhs, token.compare, token.value);
        } else if (token.opcode == 4) {
            if (top < 1) return false;
            stack[top - 1] = !stack[top - 1];
        } else {
            if (top < 2) return false;
            const bool rhs = stack[--top];
            const bool lhs = stack[top - 1];
            stack[top - 1] = token.opcode == 2 ? lhs && rhs : lhs || rhs;
        }
    }
    return top == 1 && stack[0];
}

} // namespace pk
