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

void NativeEconomyRuntime::begin_startup_demand_generation() {
    const size_t lane_count = static_cast<size_t>(std::max(0, _cell_count.get())) *
        static_cast<size_t>(std::max(0, market_store().good_count.get()));
    if (_startup_demand_values.size() != lane_count)
        _startup_demand_values.assign(lane_count, 0);
    if (_startup_demand_stamps.size() != lane_count)
        _startup_demand_stamps.assign(lane_count, 0);
    ++_startup_demand_generation;
    if (_startup_demand_generation == 0) {
        std::fill(_startup_demand_stamps.begin(),
                  _startup_demand_stamps.end(), 0);
        _startup_demand_generation = 1;
    }
    _startup_demand_touched_keys.clear();
    _startup_remote_lanes.clear();
    _startup_remote_groups.clear();
    _startup_inbound_lanes.clear();
}

void NativeEconomyRuntime::record_startup_demand(
        int32_t cell, int32_t good_id, int64_t daily_quantity) {
    if (_startup_demand_runtime_mode.get() == 0 || daily_quantity <= 0 ||
        cell < 0 || cell >= _cell_count.get() || good_id < 0 ||
        good_id >= market_store().good_count.get()) return;
    const size_t lane = static_cast<size_t>(cell) *
        static_cast<size_t>(market_store().good_count.get()) + static_cast<size_t>(good_id);
    if (lane >= _startup_demand_stamps.size()) return;
    if (_startup_demand_stamps[lane] != _startup_demand_generation) {
        _startup_demand_stamps[lane] = _startup_demand_generation;
        _startup_demand_values[lane] = daily_quantity;
        _startup_demand_touched_keys.push_back(
            (static_cast<uint64_t>(static_cast<uint32_t>(cell)) << 32) |
            static_cast<uint32_t>(good_id));
        ++_startup_demand_touched_lanes;
    } else {
        _startup_demand_values[lane] = std::max(
            _startup_demand_values[lane], daily_quantity);
    }
}

int64_t NativeEconomyRuntime::startup_demand_for(
        int32_t cell, int32_t good_id) const {
    if (_startup_demand_runtime_mode.get() == 0 || cell < 0 || cell >= _cell_count.get() ||
        good_id < 0 || good_id >= market_store().good_count.get()) return 0;
    const size_t lane = static_cast<size_t>(cell) *
        static_cast<size_t>(market_store().good_count.get()) + static_cast<size_t>(good_id);
    return lane < _startup_demand_stamps.size() &&
            _startup_demand_stamps[lane] == _startup_demand_generation
        ? std::max<int64_t>(0, _startup_demand_values[lane]) : 0;
}

int64_t NativeEconomyRuntime::remote_startup_demand_for(
        int32_t cell, int32_t good_id) const {
    if (_startup_demand_runtime_mode.get() == 0 || !_trade_topology.ready ||
        cell < 0 || cell >= _cell_count.get() || good_id < 0 ||
        good_id >= market_store().good_count.get() ||
        _epoch_cell_country.size() != static_cast<size_t>(_cell_count.get()) ||
        _trade_topology.component.size() != static_cast<size_t>(_cell_count.get()))
        return 0;
    const int32_t country = _epoch_cell_country[static_cast<size_t>(cell)];
    const int32_t component = _trade_topology.component[static_cast<size_t>(cell)];
    if (country < 0 || component < 0) return 0;
    if (_epoch_trade_vision_gated && country == _epoch_player_country_slot &&
        _epoch_cell_visible.size() == static_cast<size_t>(_cell_count.get()) &&
        _epoch_cell_visible[static_cast<size_t>(cell)] == 0) return 0;
    const auto group = std::lower_bound(
        _startup_remote_groups.begin(), _startup_remote_groups.end(),
        std::pair<int32_t, int32_t>{country, component},
        [](const StartupRemoteGroup &lhs,
           const std::pair<int32_t, int32_t> &rhs) {
            return std::pair<int32_t, int32_t>{lhs.country, lhs.component} < rhs;
        });
    if (group == _startup_remote_groups.end() || group->country != country ||
        group->component != component) return 0;
    const auto first = _startup_remote_lanes.begin() + group->lane_begin;
    const auto last = _startup_remote_lanes.begin() + group->lane_end;
    const auto lane = std::lower_bound(first, last, good_id,
        [](const StartupRemoteLane &lhs, int32_t rhs) {
            return lhs.good_id < rhs;
        });
    return lane != last && lane->good_id == good_id
        ? std::max<int64_t>(0, lane->remaining_daily) : 0;
}

void NativeEconomyRuntime::consume_remote_startup_demand(
        int32_t cell, int32_t good_id, int64_t daily_capacity) {
    if (daily_capacity <= 0 || cell < 0 || cell >= _cell_count.get() ||
        _epoch_cell_country.size() != static_cast<size_t>(_cell_count.get()) ||
        _trade_topology.component.size() != static_cast<size_t>(_cell_count.get()))
        return;
    const int32_t country = _epoch_cell_country[static_cast<size_t>(cell)];
    const int32_t component = _trade_topology.component[static_cast<size_t>(cell)];
    const auto group = std::lower_bound(
        _startup_remote_groups.begin(), _startup_remote_groups.end(),
        std::pair<int32_t, int32_t>{country, component},
        [](const StartupRemoteGroup &lhs,
           const std::pair<int32_t, int32_t> &rhs) {
            return std::pair<int32_t, int32_t>{lhs.country, lhs.component} < rhs;
        });
    if (group == _startup_remote_groups.end() || group->country != country ||
        group->component != component) return;
    auto first = _startup_remote_lanes.begin() + group->lane_begin;
    auto last = _startup_remote_lanes.begin() + group->lane_end;
    auto lane = std::lower_bound(first, last, good_id,
        [](const StartupRemoteLane &lhs, int32_t rhs) {
            return lhs.good_id < rhs;
        });
    if (lane != last && lane->good_id == good_id) {
        lane->remaining_daily = std::max<int64_t>(
            0, lane->remaining_daily -
                std::min(lane->remaining_daily, daily_capacity));
    }
}

int64_t NativeEconomyRuntime::startup_producer_hard_input_cover_q16(
        int32_t cell, int32_t good_id, int64_t &sat) const {
    // recursion guard: cover ranking may nest through select_startup_producer
    // → select_startup_input_candidate → cover again on a different good.
    int32_t &depth = startup_cover_depth();
    if (depth >= 3) return 0;
    ++depth;
    struct DepthGuard {
        int32_t &value;
        ~DepthGuard() { --value; }
    } guard{depth};
    auto &memo = startup_producer_memo_state();
    const bool memo_active = memo.depth > 0 && memo.owner == this &&
        good_id >= 0 && good_id < static_cast<int32_t>(_good_ids.size()) &&
        depth >= 0 && depth < 4;
    const size_t slot_idx =
        static_cast<size_t>(good_id >= 0 ? good_id : 0) * 4u +
        static_cast<size_t>(depth & 3);
    if (memo_active) {
        memo.ensure_cell(cell, _good_ids.size(),
                         _building_construction_goods.size(),
                         _building_inputs.size(), _building_types.size());
        if (memo.cover_stamp[slot_idx] == memo.fast_gen) {
            sat += memo.cover_sat_delta[slot_idx];
            return memo.cover_value[slot_idx];
        }
    }
    const int64_t sat_before = sat;
    const int32_t type_id = select_startup_producer(cell, good_id);
    if (type_id < 0) {
        if (memo_active && memo.fast_cell == cell) {
            memo.cover_stamp[slot_idx] = memo.fast_gen;
            memo.cover_value[slot_idx] = 0;
            memo.cover_sat_delta[slot_idx] = sat - sat_before;
        }
        return 0;
    }
    const BuildingType &type = _building_types[type_id];
    if (type.input_count <= 0) {
        if (memo_active && memo.fast_cell == cell) {
            memo.cover_stamp[slot_idx] = memo.fast_gen;
            memo.cover_value[slot_idx] = Q16_ONE;
            memo.cover_sat_delta[slot_idx] = sat - sat_before;
        }
        return Q16_ONE;
    }
    const int32_t market = market_store().cell_to_market[cell];
    if (market < 0) {
        if (memo_active && memo.fast_cell == cell) {
            memo.cover_stamp[slot_idx] = memo.fast_gen;
            memo.cover_value[slot_idx] = 0;
            memo.cover_sat_delta[slot_idx] = sat - sat_before;
        }
        return 0;
    }
    int64_t cover = Q16_ONE;
    bool saw_hard = false;
    for (int32_t edge = 0; edge < type.input_count; ++edge) {
        const ProductionInput &input = _building_inputs[type.input_begin + edge];
        if (input.required_q16 < Q16_ONE) continue;
        saw_hard = true;
        int64_t physical = 0;
        const int32_t input_good = select_startup_input_candidate(
            cell, input, physical);
        if (input_good < 0 || physical <= 0) {
            if (memo_active && memo.fast_cell == cell) {
                memo.cover_stamp[slot_idx] = memo.fast_gen;
                memo.cover_value[slot_idx] = 0;
                memo.cover_sat_delta[slot_idx] = sat - sat_before;
            }
            return 0;
        }
        const int64_t stock = std::max<int64_t>(0,
            market_store().stock[market_store().index(market, input_good)]);
        const int32_t signal = market_signal_index(cell, input_good);
        const int64_t supply = signal >= 0
            ? std::max<int64_t>(0, _market_signals.offered_supply_ema[signal]) : 0;
        const int64_t required_period = saturating_mul(
            physical, std::max(1, _epoch_days.get()), sat);
        const int64_t edge_cover = required_period > 0
            ? std::min<int64_t>(Q16_ONE, mul_div_sat(saturating_add(
                stock, saturating_mul(supply, std::max(1, _epoch_days.get()), sat),
                sat), Q16_ONE, required_period, sat))
            : Q16_ONE;
        cover = std::min(cover, edge_cover);
    }
    // Soft-only (or input-free) recipes must not win empty-shelf ranking with a
    // vacuous Q16_ONE cover. That steered soft tools demand onto metal SKUs
    // whose producers have no hard gate, while knapping (hard flint, empty)
    // scored 0 and never received substitute pressure. Neutral 0 lets price /
    // quality break ties among uncovered substitutes.
    const int64_t result_cover = saw_hard ? cover : 0;
    if (memo_active && memo.fast_cell == cell) {
        memo.cover_stamp[slot_idx] = memo.fast_gen;
        memo.cover_value[slot_idx] = result_cover;
        memo.cover_sat_delta[slot_idx] = sat - sat_before;
    }
    return result_cover;
}

bool NativeEconomyRuntime::startup_candidate_better(
        int64_t coverage, int64_t cold_cover, int64_t price,
        int32_t good_id, int64_t best_coverage, int64_t best_cold_cover,
        int64_t best_price, int32_t best_good) const {
    // All startup material selectors use this same lexicographic economic
    // ordering.  `cold_cover` is zero for construction materials, where
    // there is no recursive producer-cover signal.
    return coverage > best_coverage ||
        (coverage == best_coverage && cold_cover > best_cold_cover) ||
        (coverage == best_coverage && cold_cover == best_cold_cover &&
         price < best_price) ||
        (coverage == best_coverage && cold_cover == best_cold_cover &&
         price == best_price && good_id < best_good);
}

int32_t NativeEconomyRuntime::select_startup_input_candidate(
        int32_t cell, const ProductionInput &input,
        int64_t &physical_daily) const {
    physical_daily = 0;
    if (cell < 0 || cell >= _cell_count.get()) return -1;
    // Startup selection re-evaluates the same input rows across many candidate
    // producer types and BFS depths within one cell. The result only depends on
    // current cell state (memo scope is a read-only phase), so cache it per
    // input row like the producer/construction selections above.
    const int32_t input_index = static_cast<int32_t>(
        &input - _building_inputs.data());
    auto &memo = startup_producer_memo_state();
    const bool memo_active = memo.depth > 0 && memo.owner == this &&
        input_index >= 0 &&
        input_index < static_cast<int32_t>(_building_inputs.size());
    if (memo_active) {
        memo.ensure_cell(cell, _good_ids.size(),
                         _building_construction_goods.size(),
                         _building_inputs.size(), _building_types.size());
        if (memo.input_stamp[static_cast<size_t>(input_index)] == memo.fast_gen) {
            physical_daily = memo.input_physical[static_cast<size_t>(input_index)];
            return memo.input_good[static_cast<size_t>(input_index)];
        }
    }
    const int32_t market = market_store().cell_to_market[cell];
    int32_t best_good = -1;
    int64_t best_coverage = -1;
    int64_t best_cold_cover = -1;
    int64_t best_price = std::numeric_limits<int64_t>::max();
    int64_t best_physical = 0;
    int64_t sat = 0;
    for (int32_t cursor = input.candidate_begin;
         cursor < input.candidate_begin + input.candidate_count; ++cursor) {
        const InputCandidate &candidate = _building_input_candidates[cursor];
        if (!good_input_candidate_available(cell, candidate.good_id, true)) continue;
        int64_t physical = cursor >= 0 && cursor < static_cast<int32_t>(
                _building_input_candidate_physical_daily.size())
            ? _building_input_candidate_physical_daily[
                  static_cast<size_t>(cursor)]
            : 0;
        if (physical <= 0) {
            physical = mul_div_sat(input.quantity, Q16_ONE,
                std::max<int32_t>(1, candidate.efficiency_q16), sat);
            if (mul_div_sat(physical, candidate.efficiency_q16,
                    Q16_ONE, sat) < input.quantity) ++physical;
        }
        const int32_t signal = market_signal_index(cell, candidate.good_id);
        const int64_t stock = std::max<int64_t>(0,
            market_store().stock[market_store().index(market, candidate.good_id)]);
        const int64_t supply = signal >= 0
            ? std::max<int64_t>(0, _market_signals.offered_supply_ema[signal]) : 0;
        const int64_t required_period = saturating_mul(
            physical, std::max(1, _epoch_days.get()), sat);
        const int64_t coverage = required_period > 0
            ? std::min<int64_t>(Q16_ONE, mul_div_sat(saturating_add(
                stock, saturating_mul(supply, std::max(1, _epoch_days.get()), sat),
                sat), Q16_ONE, required_period, sat)) : Q16_ONE;
        // When every substitute is empty, ghost ceiling prices are not a
        // discovery signal. Prefer the good whose preferred producer can
        // already cover hard inputs from local stock (e.g. knapping+flint
        // over copper tools with no ore) so soft-tool demand lands on the
        // cold-start lane.
        const int64_t cold_cover = (stock <= 0 && supply <= 0)
            ? startup_producer_hard_input_cover_q16(cell, candidate.good_id, sat)
            : Q16_ONE;
        const int64_t price = mul_div_sat(
            market_store().price[market_store().index(market, candidate.good_id)], Q16_ONE,
            std::max<int32_t>(1, candidate.efficiency_q16), sat);
        if (startup_candidate_better(coverage, cold_cover, price,
                candidate.good_id, best_coverage, best_cold_cover,
                best_price, best_good)) {
            best_good = candidate.good_id;
            best_coverage = coverage;
            best_cold_cover = cold_cover;
            best_price = price;
            best_physical = physical;
        }
    }
    physical_daily = best_physical;
    if (memo_active && memo.fast_cell == cell) {
        const size_t slot = static_cast<size_t>(input_index);
        memo.input_stamp[slot] = memo.fast_gen;
        memo.input_good[slot] = best_good;
        memo.input_physical[slot] = best_physical;
    }
    return best_good;
}

int32_t NativeEconomyRuntime::select_startup_construction_candidate(
        int32_t cell, int32_t group, int64_t &physical_quantity) const {
    physical_quantity = 0;
    if (cell < 0 || cell >= _cell_count.get() || group < 0 ||
        group >= static_cast<int32_t>(_building_construction_goods.size()) ||
        group + 1 >= static_cast<int32_t>(
            _building_construction_candidate_offsets.size())) return -1;
    const int32_t cur_depth = startup_cover_depth();
    auto &memo = startup_producer_memo_state();
    const bool memo_active = memo.depth > 0 && memo.owner == this &&
        cur_depth >= 0 && cur_depth < 4;
    const size_t slot_idx =
        static_cast<size_t>(group) * 4u + static_cast<size_t>(cur_depth & 3);
    if (memo_active) {
        memo.ensure_cell(cell, _good_ids.size(),
                         _building_construction_goods.size(),
                         _building_inputs.size(), _building_types.size());
        if (memo.construction_stamp[slot_idx] == memo.fast_gen) {
            physical_quantity = memo.construction_physical[slot_idx];
            return memo.construction_good[slot_idx];
        }
    }
    const int32_t market = market_store().cell_to_market[cell];
    const GoodAmount &preferred = _building_construction_goods[group];
    int32_t best_good = -1;
    int64_t best_coverage = -1;
    int64_t best_price = std::numeric_limits<int64_t>::max();
    int64_t best_physical = 0;
    int64_t sat = 0;
    for (int32_t cursor = _building_construction_candidate_offsets[group];
         cursor < _building_construction_candidate_offsets[group + 1]; ++cursor) {
        const ConstructionCandidate &candidate =
            _building_construction_candidates[cursor];
        // Construction materials must be able to bootstrap their own supply.
        // A zero-stock good is still a valid candidate when a locally available
        // producer can be started for it; otherwise the selector drops the
        // material before demand is recorded and upstream pressure never forms.
        if (!good_market_available(cell, candidate.good_id, true) &&
            select_startup_producer(cell, candidate.good_id) < 0) continue;
        int64_t physical = mul_div_sat(preferred.quantity, Q16_ONE,
            std::max<int32_t>(1, candidate.efficiency_q16), sat);
        if (mul_div_sat(physical, candidate.efficiency_q16,
                Q16_ONE, sat) < preferred.quantity) ++physical;
        const int64_t stock = std::max<int64_t>(0,
            market_store().stock[market_store().index(market, candidate.good_id)]);
        const int64_t coverage = physical > 0
            ? std::min<int64_t>(Q16_ONE,
                mul_div_sat(stock, Q16_ONE, physical, sat)) : Q16_ONE;
        const int64_t price = mul_div_sat(
            market_store().price[market_store().index(market, candidate.good_id)], Q16_ONE,
            std::max<int32_t>(1, candidate.efficiency_q16), sat);
        if (startup_candidate_better(coverage, 0, price, candidate.good_id,
                best_coverage, 0, best_price, best_good)) {
            best_good = candidate.good_id;
            best_coverage = coverage;
            best_price = price;
            best_physical = physical;
        }
    }
    if (memo_active && memo.fast_cell == cell) {
        memo.construction_stamp[slot_idx] = memo.fast_gen;
        memo.construction_good[slot_idx] = best_good;
        memo.construction_physical[slot_idx] = best_physical;
    }
    physical_quantity = best_physical;
    return best_good;
}

int32_t NativeEconomyRuntime::select_startup_producer(
        int32_t cell, int32_t good_id) const {
    return select_startup_producer(cell, good_id, nullptr);
}

NativeEconomyRuntime::StartupProducerMemoScope::StartupProducerMemoScope(
        const NativeEconomyRuntime &owner) : runtime(owner) {
    auto &state = startup_producer_memo_state();
    static const bool memo_disabled = [] {
        const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_MEMO_DISABLE);
        return value && std::strcmp(value, "1") == 0;
    }();
    if (memo_disabled) return;
    if (state.depth != 0 && state.owner != &owner) return;
    if (state.depth++ == 0) {
        state.owner = &owner;
        state.invalidate();
        state.hits = state.misses = 0;
    }
    active = true;
}

NativeEconomyRuntime::StartupProducerMemoScope::~StartupProducerMemoScope() {
    if (!active) return;
    auto &state = startup_producer_memo_state();
    if (--state.depth == 0) {
        EconomyCostProbe::record("startup_producer.memo_hit",
            runtime._current_day.get(), 0.0, state.hits);
        EconomyCostProbe::record("startup_producer.memo_miss",
            runtime._current_day.get(), 0.0, state.misses);
        state.invalidate();
        state.owner = nullptr;
    }
}

bool NativeEconomyRuntime::same_startup_plan(const InvestmentCandidatePlan &a,
                                             const InvestmentCandidatePlan &b) {
    return a.cell == b.cell && a.type_id == b.type_id &&
        a.utilization_q16 == b.utilization_q16 &&
        a.construction_cost == b.construction_cost &&
        a.required_capital == b.required_capital &&
        a.payback_days == b.payback_days &&
        a.target_profit_per_day == b.target_profit_per_day &&
        a.target_return_on_capital_q16 == b.target_return_on_capital_q16 &&
        a.planned_output_quantity == b.planned_output_quantity &&
        a.employee_slots == b.employee_slots && a.owner_slots == b.owner_slots &&
        a.input_good_ids == b.input_good_ids &&
        a.input_quantities == b.input_quantities &&
        a.material_good_ids == b.material_good_ids &&
        a.material_quantities == b.material_quantities &&
        a.quote.cash_revenue_per_day == b.quote.cash_revenue_per_day &&
        a.quote.input_cost_per_day == b.quote.input_cost_per_day &&
        a.quote.wage_cost_per_day == b.quote.wage_cost_per_day &&
        a.quote.profit_per_day == b.quote.profit_per_day;
}

int32_t NativeEconomyRuntime::select_startup_producer(
        int32_t cell, int32_t good_id,
        InvestmentCandidatePlan *selected_plan) const {
    if (cell < 0 || cell >= _cell_count.get() || good_id < 0 ||
        good_id + 1 >= static_cast<int32_t>(_investment_good_type_offsets.size()))
        return -1;
    const int32_t cur_depth = startup_cover_depth();
    auto &memo = startup_producer_memo_state();
    const bool memo_active = memo.depth > 0 && memo.owner == this &&
        good_id < static_cast<int32_t>(_good_ids.size()) &&
        cur_depth >= 0 && cur_depth < 4;
    const size_t slot_idx =
        static_cast<size_t>(good_id) * 4u + static_cast<size_t>(cur_depth & 3);
    if (memo_active) {
        memo.ensure_cell(cell, _good_ids.size(),
                         _building_construction_goods.size(),
                         _building_inputs.size(), _building_types.size());
        if (memo.producer_stamp[slot_idx] == memo.fast_gen) {
            static const bool verify_startup_memo = [] {
                const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_MEMO_VERIFY);
                return value && std::strcmp(value, "1") == 0;
            }();
            if (verify_startup_memo) {
                const auto *previous_owner = memo.owner;
                memo.owner = nullptr;
                InvestmentCandidatePlan reference_plan;
                const int32_t reference = select_startup_producer(
                    cell, good_id, &reference_plan);
                memo.owner = previous_owner;
                if (reference != memo.producer_type[slot_idx] ||
                    !same_startup_plan(reference_plan,
                                       memo.producer_plan[slot_idx])) {
                    std::fprintf(stderr,
                        "[startup-producer-memo-mismatch] day=%lld cell=%d good=%d\n",
                        static_cast<long long>(_current_day.get()), cell, good_id);
                    std::abort();
                }
            }
            ++memo.hits;
            if (selected_plan != nullptr) {
                *selected_plan = memo.producer_plan[slot_idx];
            }
            return memo.producer_type[slot_idx];
        }
        ++memo.misses;
    }
    EconomyCostProbe cost("startup_producer_select", _current_day.get(), 1);
    static const bool startup_trace = [] {
        const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_STARTUP_TRACE);
        return value && std::strcmp(value, "1") == 0;
    }();
    double trace_cond_ms = 0.0;
    double trace_climate_ms = 0.0;
    double trace_inputs_ms = 0.0;
    double trace_tail_ms = 0.0;
    // Most callers only need the selected type id (cover/construction probes).
    // Skip the plan vectors and the best-plan copy for them: the copies were
    // allocating per call inside the derived-refresh hot loop.
    const bool need_plan = selected_plan != nullptr;
    int32_t best_type = -1;
    int64_t best_return = std::numeric_limits<int64_t>::min();
    int64_t best_unit_cost = std::numeric_limits<int64_t>::max();
    int64_t best_output = 0;
    // Reuse one candidate plan per recursion depth instead of constructing
    // (and heap-allocating) a fresh plan for every select call. Depth-indexing
    // keeps the recursive cover->select path safe; the vectors keep their
    // capacity across calls so the steady state performs no allocation.
    static thread_local std::array<InvestmentCandidatePlan, 4>
        candidate_plan_pool;
    InvestmentCandidatePlan &candidate_plan =
        candidate_plan_pool[static_cast<size_t>(
            std::clamp(cur_depth, 0, 3))];
    const int32_t market = market_store().cell_to_market[cell];
    int64_t sat = 0;
    for (int32_t cursor = _investment_good_type_offsets[good_id];
         cursor < _investment_good_type_offsets[good_id + 1]; ++cursor) {
        const int32_t type_id = _investment_good_type_indices[cursor];
        const auto trace_cond_started = startup_trace ? Clock::now()
            : Clock::time_point{};
        bool conditions_ok = false;
        if (memo_active && type_id >= 0 &&
            type_id < static_cast<int32_t>(memo.type_cond_stamp.size()) &&
            memo.type_cond_stamp[static_cast<size_t>(type_id)] == memo.fast_gen) {
            conditions_ok = memo.type_cond_ok[static_cast<size_t>(type_id)] != 0;
        } else {
            conditions_ok = building_available(cell, type_id, true) &&
                evaluate_building_conditions(type_id, cell);
            if (memo_active && memo.fast_cell == cell && type_id >= 0 &&
                type_id < static_cast<int32_t>(memo.type_cond_stamp.size())) {
                const size_t slot = static_cast<size_t>(type_id);
                memo.type_cond_stamp[slot] = memo.fast_gen;
                memo.type_cond_ok[slot] = conditions_ok ? 1 : 0;
            }
        }
        if (startup_trace) trace_cond_ms += elapsed_ms(trace_cond_started);
        if (!conditions_ok) continue;
        const BuildingType &type = _building_types[type_id];
        // Startup selection writes the same candidate record used by ordinary
        // investment.  The selector may still return a type id for legacy
        // callers, but its ranking is now based on one plan shape.
        candidate_plan.cell = cell;
        candidate_plan.type_id = type_id;
        candidate_plan.owner_signature_id = -1;
        candidate_plan.request.reason = INVESTMENT_REQUEST_STARTUP_DEMAND;
        candidate_plan.request.demand_pressure = 0;
        candidate_plan.request.allow_credit = true;
        candidate_plan.request.allow_reallocation = false;
        candidate_plan.owner_slots = std::max<int64_t>(1,
            type.owner_slots_per_building);
        candidate_plan.employee_slots = 0;
        if (need_plan) {
            candidate_plan.input_good_ids.clear();
            candidate_plan.input_quantities.clear();
            candidate_plan.material_good_ids.clear();
            candidate_plan.material_quantities.clear();
        }
        int64_t output_quantity = 0;
        for (int32_t edge = 0; edge < type.output_count; ++edge) {
            const GoodAmount &output = _building_outputs[type.output_begin + edge];
            if (output.good_id != good_id) continue;
            output_quantity = saturating_add(output_quantity,
                output.quantity, sat);
        }
        output_quantity = mul_div_sat(output_quantity,
            _building_output_efficiency_q16, Q16_ONE, sat);
        const auto trace_climate_started = startup_trace ? Clock::now()
            : Clock::time_point{};
        int64_t climate_cap = 0;
        const size_t climate_slot = static_cast<size_t>(type_id);
        if (memo_active &&
            climate_slot < memo.type_climate_stamp.size() &&
            memo.type_climate_stamp[climate_slot] == memo.fast_gen) {
            climate_cap = memo.type_climate_q16[climate_slot];
        } else {
            climate_cap = production_climate_capacity_q16(
                type, cell, nullptr, nullptr, sat);
            if (memo_active && memo.fast_cell == cell &&
                climate_slot < memo.type_climate_stamp.size()) {
                memo.type_climate_stamp[climate_slot] = memo.fast_gen;
                memo.type_climate_q16[climate_slot] = climate_cap;
            }
        }
        if (startup_trace) trace_climate_ms += elapsed_ms(trace_climate_started);
        output_quantity = mul_div_sat(output_quantity,
            climate_cap, Q16_ONE, sat);
        if (output_quantity <= 0) continue;
        candidate_plan.utilization_q16 = climate_cap;
        const auto trace_inputs_started = startup_trace ? Clock::now()
            : Clock::time_point{};
        const auto trace_edges_started = startup_trace ? Clock::now()
            : Clock::time_point{};
        int64_t operating_cost = 0;
        int64_t input_cost = 0;
        for (int32_t edge = 0; edge < type.input_count; ++edge) {
            const ProductionInput &input = _building_inputs[type.input_begin + edge];
            int64_t physical = 0;
            const int32_t input_good = select_startup_input_candidate(
                cell, input, physical);
            if (input_good < 0) {
                operating_cost = std::numeric_limits<int64_t>::max();
                break;
            }
            if (need_plan) {
                candidate_plan.input_good_ids.push_back(input_good);
                candidate_plan.input_quantities.push_back(physical);
            }
            const int64_t edge_cost = goods_cost(physical,
                market_store().price[market_store().index(market, input_good)], sat);
            input_cost = saturating_add(input_cost, edge_cost, sat);
            operating_cost = saturating_add(operating_cost, edge_cost, sat);
        }
        if (operating_cost == std::numeric_limits<int64_t>::max()) continue;
        const auto trace_wages_started = startup_trace ? Clock::now()
            : Clock::time_point{};
        int64_t wage_cost = 0;
        const size_t wage_slot = static_cast<size_t>(type_id);
        const bool wage_cached = memo_active &&
            wage_slot < memo.type_wage_stamp.size() &&
            memo.type_wage_stamp[wage_slot] == memo.fast_gen;
        if (wage_cached) {
            wage_cost = memo.type_wage_cost[wage_slot];
            candidate_plan.employee_slots =
                memo.type_employee_slots[wage_slot];
        } else {
            for (int32_t role = 0; role < type.employee_count; ++role) {
                candidate_plan.employee_slots = saturating_add(
                    candidate_plan.employee_slots,
                    std::max<int64_t>(0, _building_employee_roles[
                        type.employee_begin + role].slots_per_building), sat);
            }
            for (int32_t role = 0; role < type.employee_count; ++role) {
                const JobRole &job = _building_employee_roles[type.employee_begin + role];
                const int32_t signal = labor_signal_index(cell, job.profession_id);
                const int64_t living_floor = signal >= 0
                    ? std::max(_labor_signals.base_living_cost[signal],
                        _labor_signals.role_living_cost[signal]) : 0;
                const int64_t market_quote = signal >= 0 && signal <
                        static_cast<int32_t>(_labor_signals.contract_wage_ema.size())
                    ? std::max(_labor_signals.contract_wage_ema[signal],
                        _labor_signals.paid_wage_ema[signal]) : 0;
                const int64_t role_cost = saturating_mul(job.slots_per_building,
                    std::max(living_floor, market_quote), sat);
                wage_cost = saturating_add(wage_cost, role_cost, sat);
            }
            if (memo_active && memo.fast_cell == cell &&
                wage_slot < memo.type_wage_stamp.size()) {
                memo.type_wage_stamp[wage_slot] = memo.fast_gen;
                memo.type_wage_cost[wage_slot] = wage_cost;
                memo.type_employee_slots[wage_slot] =
                    candidate_plan.employee_slots;
            }
        }
        operating_cost = saturating_add(operating_cost, wage_cost, sat);
        const auto trace_construct_started = startup_trace ? Clock::now()
            : Clock::time_point{};
        int64_t construction_cost = 0;
        const size_t construct_slot = static_cast<size_t>(type_id);
        const bool construct_cacheable = memo_active &&
            construct_slot < memo.type_construct_stamp.size() &&
            type.construction_count <= 4;
        if (construct_cacheable &&
            memo.type_construct_stamp[construct_slot] == memo.fast_gen) {
            construction_cost = memo.type_construct_cost[construct_slot];
            if (need_plan) {
                const int32_t cached_count =
                    memo.type_construct_count[construct_slot];
                for (int32_t e = 0; e < cached_count; ++e) {
                    candidate_plan.material_good_ids.push_back(
                        memo.type_construct_goods[construct_slot * 4u + e]);
                    candidate_plan.material_quantities.push_back(
                        memo.type_construct_physical[construct_slot * 4u + e]);
                }
            }
        } else {
            for (int32_t edge = 0; edge < type.construction_count; ++edge) {
                int64_t physical = 0;
                const int32_t material = select_startup_construction_candidate(
                    cell, type.construction_begin + edge, physical);
                if (material < 0) {
                    construction_cost = std::numeric_limits<int64_t>::max();
                    break;
                }
                const int64_t material_cost = goods_cost(physical,
                    market_store().price[market_store().index(market, material)], sat);
                construction_cost = saturating_add(construction_cost,
                    material_cost, sat);
                if (construct_cacheable && memo.fast_cell == cell) {
                    memo.type_construct_goods[construct_slot * 4u + edge] = material;
                    memo.type_construct_physical[construct_slot * 4u + edge] =
                        physical;
                }
                if (need_plan) {
                    candidate_plan.material_good_ids.push_back(material);
                    candidate_plan.material_quantities.push_back(physical);
                }
            }
            if (construct_cacheable && memo.fast_cell == cell &&
                construction_cost != std::numeric_limits<int64_t>::max()) {
                memo.type_construct_stamp[construct_slot] = memo.fast_gen;
                memo.type_construct_cost[construct_slot] = construction_cost;
                memo.type_construct_count[construct_slot] =
                    type.construction_count;
            }
        }
        if (construction_cost == std::numeric_limits<int64_t>::max()) continue;
        if (startup_trace) {
            trace_inputs_ms += elapsed_ms(trace_inputs_started);
            EconomyCostProbe::record("startup.in_edges", _current_day.get(),
                                     elapsed_ms(trace_edges_started));
            EconomyCostProbe::record("startup.in_wages", _current_day.get(),
                                     elapsed_ms(trace_wages_started));
            EconomyCostProbe::record("startup.in_construct", _current_day.get(),
                                     elapsed_ms(trace_construct_started));
        }
        const auto trace_tail_started = startup_trace ? Clock::now()
            : Clock::time_point{};
        const int64_t revenue = mul_div_sat(output_quantity,
            mul_div_sat(market_store().price[market_store().index(market, good_id)],
                _good_merchant_buy_factor_q16[good_id], Q16_ONE, sat),
            GOODS_SCALE, sat);
        const int64_t profit = saturating_sub(revenue, operating_cost, sat);
        const int64_t capital = saturating_add(construction_cost,
            saturating_mul(operating_cost, std::max(1, _epoch_days.get()), sat), sat);
        const int64_t return_q16 = capital > 0
            ? mul_div_sat(profit, Q16_ONE, capital, sat)
            : (profit > 0 ? Q16_ONE : 0);
        const int64_t unit_cost = output_quantity > 0
            ? mul_div_sat(operating_cost, GOODS_SCALE, output_quantity, sat) :
              std::numeric_limits<int64_t>::max();
        EconomicOpportunityQuote candidate_quote;
        candidate_quote.cash_revenue_per_day = revenue;
        candidate_quote.merchant_revenue_per_day = revenue;
        candidate_quote.economic_revenue_per_day = revenue;
        candidate_quote.input_cost_per_day = input_cost;
        candidate_quote.wage_cost_per_day = wage_cost;
        candidate_quote.profit_per_day = profit;
        initialize_investment_candidate_plan(candidate_plan, cell, type_id, -1,
            candidate_plan.utilization_q16, construction_cost, capital,
            profit > 0 ? (capital + profit - 1) / profit
                       : std::numeric_limits<int64_t>::max(), profit,
            return_q16, candidate_plan.owner_slots,
            candidate_plan.employee_slots, candidate_quote);
        candidate_plan.planned_output_quantity = output_quantity;
        if (startup_trace) trace_tail_ms += elapsed_ms(trace_tail_started);
        if (best_type < 0 || return_q16 > best_return ||
            (candidate_plan.target_return_on_capital_q16 == best_return && unit_cost < best_unit_cost) ||
            (candidate_plan.target_return_on_capital_q16 == best_return && unit_cost == best_unit_cost &&
             output_quantity > best_output) ||
            (candidate_plan.target_return_on_capital_q16 == best_return && unit_cost == best_unit_cost &&
             output_quantity == best_output && type_id < best_type)) {
            best_type = type_id;
            best_return = candidate_plan.target_return_on_capital_q16;
            best_unit_cost = unit_cost;
            best_output = output_quantity;
            if (need_plan) *selected_plan = candidate_plan;
        }
    }
    if (startup_trace) {
        EconomyCostProbe::record("startup.sec_cond", _current_day.get(),
                                 trace_cond_ms);
        EconomyCostProbe::record("startup.sec_climate", _current_day.get(),
                                 trace_climate_ms);
        EconomyCostProbe::record("startup.sec_inputs", _current_day.get(),
                                 trace_inputs_ms);
        EconomyCostProbe::record("startup.sec_tail", _current_day.get(),
                                 trace_tail_ms);
    }
    if (selected_plan != nullptr && best_type < 0) {
        *selected_plan = InvestmentCandidatePlan{};
    }
    if (memo_active && memo.fast_cell == cell && need_plan) {
        memo.producer_stamp[slot_idx] = memo.fast_gen;
        memo.producer_type[slot_idx] = best_type;
        memo.producer_plan[slot_idx] = *selected_plan;
    }
    return best_type;
}

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

void NativeEconomyRuntime::prepare_startup_demand() {
    const auto started = Clock::now();
    begin_startup_demand_generation();
    if (_startup_demand_runtime_mode.get() == 0) {
        _startup_demand_scratch_bytes = static_cast<int64_t>(
            _startup_demand_values.capacity() * sizeof(int64_t) +
            _startup_demand_stamps.capacity() * sizeof(uint32_t));
        _startup_demand_prepare_ms += elapsed_ms(started);
        return;
    }
    std::sort(_trade_active_keys.begin(), _trade_active_keys.end());
    _trade_active_keys.erase(std::unique(
        _trade_active_keys.begin(), _trade_active_keys.end()),
        _trade_active_keys.end());
    if (!_trade_topology.ready ||
        _trade_topology.component.size() != static_cast<size_t>(_cell_count.get()) ||
        _epoch_cell_country.size() != static_cast<size_t>(_cell_count.get())) {
        _startup_demand_scratch_bytes = static_cast<int64_t>(
            _startup_demand_values.capacity() * sizeof(int64_t) +
            _startup_demand_stamps.capacity() * sizeof(uint32_t));
        _startup_demand_prepare_ms += elapsed_ms(started);
        return;
    }

    const int32_t order_count = trade_orders_store().size();
    if (trade_orders_store().line_offsets.size() !=
            static_cast<size_t>(order_count + 1)) {
        _startup_demand_prepare_ms += elapsed_ms(started);
        return;
    }
    for (int32_t order = 0; order < order_count; ++order) {
        if (trade_orders_store().cargo_delivered[order] != 0 ||
            trade_orders_store().destinations[order] < 0 ||
            trade_orders_store().destinations[order] >= _cell_count.get()) continue;
        const int32_t destination = trade_orders_store().destinations[order];
        for (int32_t line = trade_orders_store().line_offsets[order];
             line < trade_orders_store().line_offsets[order + 1]; ++line) {
            const int32_t good = trade_orders_store().line_goods[line];
            const int64_t quantity = trade_orders_store().line_quantities[line];
            if (good < 0 || good >= market_store().good_count.get() || quantity <= 0) continue;
            _startup_inbound_lanes.push_back({
                (static_cast<uint64_t>(static_cast<uint32_t>(destination)) << 32) |
                    static_cast<uint32_t>(good),
                quantity});
        }
    }
    std::sort(_startup_inbound_lanes.begin(), _startup_inbound_lanes.end(),
        [](const StartupInboundLane &a, const StartupInboundLane &b) {
            return a.cell_good_key < b.cell_good_key;
        });
    size_t inbound_out = 0;
    for (const StartupInboundLane &lane : _startup_inbound_lanes) {
        if (inbound_out > 0 && _startup_inbound_lanes[inbound_out - 1].cell_good_key ==
                lane.cell_good_key) {
            _startup_inbound_lanes[inbound_out - 1].quantity = saturating_add(
                _startup_inbound_lanes[inbound_out - 1].quantity,
                lane.quantity, _saturation_count);
        } else {
            _startup_inbound_lanes[inbound_out++] = lane;
        }
    }
    _startup_inbound_lanes.resize(inbound_out);
    auto inbound_daily = [&](int32_t cell, int32_t good) {
        const uint64_t key =
            (static_cast<uint64_t>(static_cast<uint32_t>(cell)) << 32) |
            static_cast<uint32_t>(good);
        const auto it = std::lower_bound(
            _startup_inbound_lanes.begin(), _startup_inbound_lanes.end(), key,
            [](const StartupInboundLane &lhs, uint64_t rhs) {
                return lhs.cell_good_key < rhs;
            });
        return it != _startup_inbound_lanes.end() && it->cell_good_key == key
            ? it->quantity / std::max(1, _epoch_days.get()) : int64_t{0};
    };
    auto actual_deficit = [&](int32_t cell, int32_t good) {
        const int32_t market = market_store().cell_to_market[cell];
        const int64_t index = market_store().index(market, good);
        const int32_t signal = market_signal_index(cell, good);
        const int64_t business = signal >= 0
            ? std::max<int64_t>(0, _market_signals.business_demand_ema[signal]) : 0;
        int64_t demand = saturating_add(
            std::max<int64_t>(0, market_store().demand_ema[index]), business,
            _saturation_count);
        demand = saturating_add(demand,
            epoch_procurement_demand_daily(cell, good), _saturation_count);
        const int64_t supply = signal >= 0
            ? std::max<int64_t>(0, _market_signals.offered_supply_ema[signal]) : 0;
        const int64_t realized = signal >= 0
            ? std::max<int64_t>(0,
                _market_signals.realized_withdrawal_ema[signal]) : 0;
        const int32_t flow = trade_flow_index(cell, good, false);
        const int64_t exports = flow >= 0
            ? std::max<int64_t>(0, _trade_flows.export_ema[flow]) : 0;
        const int64_t target = merchant_inventory_target(
            market, good, signal, realized, exports, supply, _saturation_count);
        const int64_t gap = std::max<int64_t>(
            0, target - std::max<int64_t>(0, market_store().stock[index]));
        const int64_t gap_daily = gap > 0
            ? mul_div_sat(gap, Q16_ONE,
                std::max<int64_t>(Q16_ONE,
                    _good_target_inventory_days_q16[good]), _saturation_count)
            : 0;
        int64_t deficit = std::max<int64_t>(
            std::max<int64_t>(0, demand - supply), gap_daily);
        deficit = std::max<int64_t>(0, deficit -
            std::min(deficit, inbound_daily(cell, good)));
        return deficit;
    };

    std::vector<StartupRemoteAccumulator> &raw =
        _startup_remote_accumulator_scratch;
    raw.clear();
    raw.reserve(_trade_active_keys.size());
    auto add_remote = [&](int32_t cell, int32_t good,
                          int64_t demand, int64_t available) {
        if (cell < 0 || cell >= _cell_count.get() || good < 0 ||
            good >= market_store().good_count.get()) return;
        const int32_t country = _epoch_cell_country[static_cast<size_t>(cell)];
        const int32_t component =
            _trade_topology.component[static_cast<size_t>(cell)];
        if (country < 0 || component < 0) return;
        if (_epoch_trade_vision_gated && country == _epoch_player_country_slot &&
            _epoch_cell_visible.size() == static_cast<size_t>(_cell_count.get()) &&
            _epoch_cell_visible[static_cast<size_t>(cell)] == 0) return;
        raw.push_back({country, component, good,
                       std::max<int64_t>(0, demand),
                       std::max<int64_t>(0, available)});
    };
    // Active keys are sorted by (cell, good). Process one cell run at a time
    // so the cell's pending-construction and building-group lanes are scanned
    // once instead of once per good key. Per (cell, good) contribution order is
    // unchanged; the saturation counter is diagnostics-only, so the derived
    // availability values stay bit-identical to the per-key scan.
    thread_local std::vector<uint32_t> cell_goods;
    thread_local std::vector<uint8_t> cell_active;
    thread_local std::vector<int64_t> cell_available;
    thread_local std::vector<int64_t> cell_deficit;
    size_t key_pos = 0;
    const size_t active_key_count = _trade_active_keys.size();
    while (key_pos < active_key_count) {
        const int32_t cell = static_cast<int32_t>(
            _trade_active_keys[key_pos] >> 32);
        size_t run_end = key_pos + 1;
        while (run_end < active_key_count &&
               static_cast<int32_t>(_trade_active_keys[run_end] >> 32) == cell) {
            ++run_end;
        }
        const size_t run_size = run_end - key_pos;
        cell_goods.resize(run_size);
        cell_active.assign(run_size, 0);
        cell_available.assign(run_size, 0);
        cell_deficit.assign(run_size, 0);
        size_t active_begin = run_size;
        size_t active_end = 0;
        for (size_t i = 0; i < run_size; ++i) {
            const int32_t good = static_cast<int32_t>(
                _trade_active_keys[key_pos + i] & 0xffffffffULL);
            cell_goods[i] = static_cast<uint32_t>(good);
            const bool active = cell >= 0 && cell < _cell_count.get() &&
                good >= 0 && good < market_store().good_count.get() &&
                _good_trade_enabled[good] != 0 && _good_storage_modes[good] == 0;
            cell_active[i] = active ? 1 : 0;
            if (active) {
                active_begin = std::min(active_begin, i);
                active_end = std::max(active_end, i + 1);
            }
        }
        if (active_end > active_begin) {
            const auto find_slot = [&](int32_t good, size_t &slot) -> bool {
                const auto begin = cell_goods.begin() +
                    static_cast<ptrdiff_t>(active_begin);
                const auto end = cell_goods.begin() +
                    static_cast<ptrdiff_t>(active_end);
                const auto it = std::lower_bound(begin, end,
                    static_cast<uint32_t>(good));
                if (it == end || *it != static_cast<uint32_t>(good)) return false;
                slot = static_cast<size_t>(it - cell_goods.begin());
                return cell_active[slot] != 0;
            };
            // Base stock headroom per key (same expression as before).
            for (size_t i = active_begin; i < active_end; ++i) {
                if (cell_active[i] == 0) continue;
                const int32_t good = static_cast<int32_t>(cell_goods[i]);
                const int32_t market = market_store().cell_to_market[cell];
                const int64_t stock = std::max<int64_t>(0,
                    market_store().stock[market_store().index(market, good)]);
                if (stock > 0) {
                    const int64_t floor = trade_export_floor(cell, good,
                        _saturation_count);
                    cell_available[i] = std::max<int64_t>(0, stock - floor) /
                        std::max(1, _epoch_days.get());
                }
            }
            // Pending construction lanes, once per cell.
            if (_pending_construction_cell_offsets.size() ==
                    static_cast<size_t>(_cell_count.get() + 1)) {
                for (int32_t cursor = _pending_construction_cell_offsets[cell];
                     cursor < _pending_construction_cell_offsets[cell + 1];
                     ++cursor) {
                    const int32_t pending_index =
                        _pending_construction_cell_indices[cursor];
                    if (pending_index < 0 || pending_index >= static_cast<int32_t>(
                            pending_construction_count())) continue;
                    const auto pending =
                        pending_construction()[static_cast<size_t>(pending_index)];
                    if (pending.count <= 0 || pending.type_id < 0 ||
                        pending.type_id >= static_cast<int32_t>(
                            _building_types.size())) continue;
                    const BuildingType &type = _building_types[pending.type_id];
                    for (int32_t edge = 0; edge < type.output_count; ++edge) {
                        const GoodAmount &output =
                            _building_outputs[type.output_begin + edge];
                        size_t slot = 0;
                        if (!find_slot(output.good_id, slot)) continue;
                        const int64_t climate = production_climate_capacity_q16(
                            type, cell, nullptr, nullptr, _saturation_count);
                        int64_t daily = mul_div_sat(output.quantity,
                            _building_output_efficiency_q16, Q16_ONE,
                            _saturation_count);
                        daily = mul_div_sat(daily, climate, Q16_ONE,
                            _saturation_count);
                        cell_available[slot] = saturating_add(cell_available[slot],
                            saturating_mul(daily, pending.count,
                                _saturation_count), _saturation_count);
                    }
                }
            }
            // Idle building capacity, once per cell.
            if (_building_cell_offsets.size() ==
                    static_cast<size_t>(_cell_count.get() + 1)) {
                for (int32_t group_index = _building_cell_offsets[cell];
                     group_index < _building_cell_offsets[cell + 1];
                     ++group_index) {
                    const auto group = building_view(
                        static_cast<size_t>(group_index));
                    if (group.count <= 0 || group.operating_state == 1 ||
                        group.type_id < 0 || group.type_id >=
                            static_cast<int32_t>(_building_types.size())) continue;
                    const int64_t idle_q16 = std::max<int64_t>(0,
                        std::clamp<int64_t>(group.last_capacity_q16, 0, Q16_ONE) -
                        std::clamp<int64_t>(group.planned_utilization_q16,
                            0, Q16_ONE));
                    if (idle_q16 <= 0) continue;
                    const BuildingType &type = _building_types[group.type_id];
                    for (int32_t edge = 0; edge < type.output_count; ++edge) {
                        const GoodAmount &output =
                            _building_outputs[type.output_begin + edge];
                        size_t slot = 0;
                        if (!find_slot(output.good_id, slot)) continue;
                        cell_available[slot] = saturating_add(cell_available[slot],
                            effective_building_output_quantity(
                                group, output.good_id, output.quantity, idle_q16,
                                group.count, _saturation_count),
                            _saturation_count);
                    }
                }
            }
            // Deficit and remote accumulation per key.
            for (size_t i = active_begin; i < active_end; ++i) {
                if (cell_active[i] == 0) continue;
                const int32_t good = static_cast<int32_t>(cell_goods[i]);
                cell_deficit[i] = actual_deficit(cell, good);
                if (cell_deficit[i] > 0 || cell_available[i] > 0) {
                    add_remote(cell, good, cell_deficit[i], cell_available[i]);
                }
            }
        }
        key_pos = run_end;
    }
    std::sort(raw.begin(), raw.end(), [](const StartupRemoteAccumulator &a,
                                         const StartupRemoteAccumulator &b) {
        return std::tuple<int32_t, int32_t, int32_t>{
            a.country, a.component, a.good_id} <
            std::tuple<int32_t, int32_t, int32_t>{
            b.country, b.component, b.good_id};
    });
    for (size_t begin = 0; begin < raw.size();) {
        size_t end = begin + 1;
        int64_t demand = raw[begin].demand;
        int64_t available = raw[begin].available;
        while (end < raw.size() && raw[end].country == raw[begin].country &&
               raw[end].component == raw[begin].component &&
               raw[end].good_id == raw[begin].good_id) {
            demand = saturating_add(demand, raw[end].demand,
                                    _saturation_count);
            available = saturating_add(available, raw[end].available,
                                       _saturation_count);
            ++end;
        }
        const int64_t remaining = std::max<int64_t>(
            0, demand - std::min(demand, available));
        if (remaining > 0) {
            _startup_remote_lanes.push_back({raw[begin].country,
                raw[begin].component, raw[begin].good_id, remaining});
        }
        begin = end;
    }
    for (int32_t begin = 0;
         begin < static_cast<int32_t>(_startup_remote_lanes.size());) {
        int32_t end = begin + 1;
        while (end < static_cast<int32_t>(_startup_remote_lanes.size()) &&
               _startup_remote_lanes[end].country ==
                   _startup_remote_lanes[begin].country &&
               _startup_remote_lanes[end].component ==
                   _startup_remote_lanes[begin].component) ++end;
        _startup_remote_groups.push_back({
            _startup_remote_lanes[begin].country,
            _startup_remote_lanes[begin].component, begin, end});
        begin = end;
    }
    _startup_demand_remote_lanes = static_cast<int64_t>(
        _startup_remote_lanes.size());
    _startup_demand_scratch_bytes = static_cast<int64_t>(
        _startup_demand_values.capacity() * sizeof(int64_t) +
        _startup_demand_stamps.capacity() * sizeof(uint32_t) +
        _startup_demand_touched_keys.capacity() * sizeof(uint64_t) +
        _startup_remote_lanes.capacity() * sizeof(StartupRemoteLane) +
        _startup_remote_groups.capacity() * sizeof(StartupRemoteGroup) +
        _startup_inbound_lanes.capacity() * sizeof(StartupInboundLane) +
        _startup_remote_accumulator_scratch.capacity() *
            sizeof(StartupRemoteAccumulator));
    _startup_demand_prepare_ms += elapsed_ms(started);
}

int64_t NativeEconomyRuntime::startup_producer_output_quantity(
        int32_t cell, int32_t type_id, int32_t good_id, int64_t &sat) const {
    if (cell < 0 || cell >= _cell_count.get() || type_id < 0 ||
        type_id >= static_cast<int32_t>(_building_types.size()) ||
        good_id < 0 || good_id >= market_store().good_count.get()) return 0;
    const BuildingType &type = _building_types[type_id];
    int64_t output_quantity = 0;
    for (int32_t edge = 0; edge < type.output_count; ++edge) {
        const GoodAmount &output = _building_outputs[type.output_begin + edge];
        if (output.good_id != good_id) continue;
        output_quantity = saturating_add(output_quantity, output.quantity, sat);
    }
    output_quantity = mul_div_sat(output_quantity,
        _building_output_efficiency_q16, Q16_ONE, sat);
    output_quantity = mul_div_sat(output_quantity,
        production_climate_capacity_q16(type, cell, nullptr, nullptr, sat),
        Q16_ONE, sat);
    return std::max<int64_t>(0, output_quantity);
}

int64_t NativeEconomyRuntime::market_flow_deficit_daily(
        int32_t cell, int32_t good_id, bool include_derived,
        int64_t &sat) const {
    if (cell < 0 || cell >= _cell_count.get() || good_id < 0 ||
        good_id >= market_store().good_count.get()) return 0;
    const int32_t market = market_store().cell_to_market[cell];
    if (market < 0 || market >= market_store().market_count.get()) return 0;
    const int64_t index = market_store().index(market, good_id);
    const int32_t signal = market_signal_index(cell, good_id);
    int64_t demand = std::max<int64_t>(0, market_store().demand_ema[index]);
    if (signal >= 0) {
        demand = saturating_add(demand,
            std::max<int64_t>(0, _market_signals.business_demand_ema[signal]),
            sat);
        if (signal < static_cast<int32_t>(_epoch_substitute_business_demand.size())) {
            demand = saturating_add(demand,
                std::max<int64_t>(0, _epoch_substitute_business_demand[signal]),
                sat);
        }
        if (include_derived &&
            signal < static_cast<int32_t>(_epoch_derived_business_demand.size())) {
            demand = saturating_add(demand,
                std::max<int64_t>(0, _epoch_derived_business_demand[signal]),
                sat);
        }
    }
    demand = saturating_add(demand,
        epoch_procurement_demand_daily(cell, good_id), sat);
    const int64_t supply = signal >= 0
        ? std::max<int64_t>(0, _market_signals.offered_supply_ema[signal]) : 0;
    const int64_t realized = signal >= 0
        ? std::max<int64_t>(0,
            _market_signals.realized_withdrawal_ema[signal]) : 0;
    const int32_t flow = const_cast<NativeEconomyRuntime *>(this)->
        trade_flow_index(cell, good_id, false);
    const int64_t exports = flow >= 0
        ? std::max<int64_t>(0, _trade_flows.export_ema[flow]) : 0;
    const int64_t target = merchant_inventory_target(
        market, good_id, signal, realized, exports, supply, sat);
    const int64_t gap = std::max<int64_t>(
        0, target - std::max<int64_t>(0, market_store().stock[index]));
    const int64_t gap_daily = gap > 0
        ? mul_div_sat(gap, Q16_ONE,
            std::max<int64_t>(Q16_ONE,
                _good_target_inventory_days_q16[good_id]), sat)
        : 0;
    return std::max<int64_t>(
        std::max<int64_t>(0, demand - supply), gap_daily);
}

void NativeEconomyRuntime::credit_input_substitute_demand(
        int32_t cell, const ProductionInput &input,
        int32_t selected_candidate_index, int64_t planned) {
    if (planned <= 0 || cell < 0 || cell >= _cell_count.get()) return;
    for (int32_t c = input.candidate_begin;
         c < input.candidate_begin + input.candidate_count; ++c) {
        if (c == selected_candidate_index) continue;
        const InputCandidate &candidate = _building_input_candidates[c];
        if (!good_input_candidate_available(cell, candidate.good_id, true)) continue;
        const int32_t signal = ensure_market_signal_index(cell, candidate.good_id);
        if (signal < 0) continue;
        if (signal >= static_cast<int32_t>(_epoch_substitute_business_demand.size())) {
            _epoch_substitute_business_demand.resize(
                _market_signals.good_ids.size(), 0);
        }
        _epoch_substitute_business_demand[signal] = saturating_add(
            _epoch_substitute_business_demand[signal], planned, _saturation_count);
    }
}


void NativeEconomyRuntime::propagate_startup_demand_for_cell(int32_t cell) {
    if (_startup_demand_runtime_mode.get() == 0 || cell < 0 || cell >= _cell_count.get() ||
        _investment_good_stamp.size() != _good_ids.size()) return;
    StartupProducerMemoScope startup_memo(*this);
    ++_investment_review_stamp_generation;
    if (_investment_review_stamp_generation == 0) {
        std::fill(_investment_good_stamp.begin(),
                  _investment_good_stamp.end(), 0);
        _investment_review_stamp_generation = 1;
    }
    const uint32_t visit = _investment_review_stamp_generation;
    _investment_good_queue_scratch.clear();
    auto queue_good = [&](int32_t good) {
        if (good >= 0 && good < market_store().good_count.get())
            _investment_good_queue_scratch.push_back(good);
    };
    auto actual_deficit = [&](int32_t good) {
        int64_t sat = 0;
        // Startup demand is a real-demand lane.  Shadow derived demand may
        // rank an investment candidate, but it cannot create a construction,
        // owner vacancy, input purchase, or startup producer by itself.
        return market_flow_deficit_daily(cell, good, false, sat);
    };
    const uint64_t key_begin =
        static_cast<uint64_t>(static_cast<uint32_t>(cell)) << 32;
    const uint64_t key_end = key_begin | 0xffffffffULL;
    auto active = std::lower_bound(
        _trade_active_keys.begin(), _trade_active_keys.end(), key_begin);
    for (; active != _trade_active_keys.end() && *active <= key_end; ++active) {
        const int32_t good = static_cast<int32_t>(*active & 0xffffffffULL);
        const int64_t deficit = actual_deficit(good);
        if (deficit <= 0) continue;
        if (startup_demand_for(cell, good) <= 0) ++_startup_demand_seed_count;
        record_startup_demand(cell, good, deficit);
        queue_good(good);
    }
    if (_market_signals.cell_offsets.size() ==
            static_cast<size_t>(_cell_count.get() + 1)) {
        for (int32_t signal = _market_signals.cell_offsets[cell];
             signal < _market_signals.cell_offsets[cell + 1]; ++signal) {
            const int32_t good = _market_signals.good_ids[signal];
            const int64_t deficit = actual_deficit(good);
            if (deficit <= 0) continue;
            if (startup_demand_for(cell, good) <= 0)
                ++_startup_demand_seed_count;
            record_startup_demand(cell, good, deficit);
            queue_good(good);
        }
    }
    const int64_t research = epoch_research_demand_daily(
        cell, _epoch_research_good_id);
    if (_epoch_research_good_id >= 0 && research > 0) {
        if (startup_demand_for(cell, _epoch_research_good_id) <= 0)
            ++_startup_demand_seed_count;
        record_startup_demand(cell, _epoch_research_good_id, research);
        queue_good(_epoch_research_good_id);
    }
    if (_trade_topology.component.size() == static_cast<size_t>(_cell_count.get()) &&
        _epoch_cell_country.size() == static_cast<size_t>(_cell_count.get())) {
        const int32_t country = _epoch_cell_country[static_cast<size_t>(cell)];
        const int32_t component = _trade_topology.component[static_cast<size_t>(cell)];
        const auto group = std::lower_bound(
            _startup_remote_groups.begin(), _startup_remote_groups.end(),
            std::pair<int32_t, int32_t>{country, component},
            [](const StartupRemoteGroup &lhs,
               const std::pair<int32_t, int32_t> &rhs) {
                return std::pair<int32_t, int32_t>{
                    lhs.country, lhs.component} < rhs;
            });
        if (group != _startup_remote_groups.end() &&
            group->country == country && group->component == component) {
            bool matched = false;
            for (int32_t lane = group->lane_begin; lane < group->lane_end; ++lane) {
                if (_startup_remote_lanes[lane].remaining_daily <= 0) continue;
                queue_good(_startup_remote_lanes[lane].good_id);
                matched = true;
            }
            if (matched) ++_startup_demand_matched_review_cells;
        }
    }
    size_t cursor = 0;
    while (cursor < _investment_good_queue_scratch.size()) {
        const int32_t good = _investment_good_queue_scratch[cursor++];
        if (_investment_good_stamp[good] == visit) {
            ++_startup_demand_cycle_skips;
            continue;
        }
        _investment_good_stamp[good] = visit;
        _startup_demand_catalog_edges = saturating_add(
            _startup_demand_catalog_edges,
            _investment_good_type_offsets[good + 1] -
                _investment_good_type_offsets[good], _saturation_count);
        InvestmentCandidatePlan producer_plan;
        const int32_t type_id = select_startup_producer(
            cell, good, &producer_plan);
        if (type_id < 0) continue;
        const BuildingType &type = _building_types[type_id];
        const int32_t market = market_store().cell_to_market[cell];
        const int64_t parent_deficit = std::max<int64_t>(
            startup_demand_for(cell, good), actual_deficit(good));
        const int64_t output_qty = producer_plan.planned_output_quantity;
        for (int32_t edge = 0; edge < type.input_count; ++edge) {
            const ProductionInput &input = _building_inputs[type.input_begin + edge];
            int64_t physical = 0;
            const int32_t input_good = select_startup_input_candidate(
                cell, input, physical);
            ++_startup_demand_catalog_edges;
            if (input_good < 0 || physical <= 0 || input.required_q16 <= 0)
                continue;
            int64_t derived = physical;
            if (parent_deficit > 0 && output_qty > 0) {
                derived = mul_div_sat(parent_deficit, physical, output_qty,
                    _saturation_count);
                derived = mul_div_sat(derived,
                    std::clamp<int64_t>(input.required_q16, 0, Q16_ONE),
                    Q16_ONE, _saturation_count);
            }
            if (derived <= 0) continue;
            const int32_t signal = market_signal_index(cell, input_good);
            const int64_t stock = std::max<int64_t>(0,
                market_store().stock[market_store().index(market, input_good)]);
            const int64_t supply = signal >= 0
                ? std::max<int64_t>(0,
                    _market_signals.offered_supply_ema[signal]) : 0;
            const int64_t available = saturating_add(stock,
                saturating_mul(supply, std::max(1, _epoch_days.get()),
                    _saturation_count), _saturation_count);
            const int64_t required = saturating_mul(
                derived, std::max(1, _epoch_days.get()), _saturation_count);
            if (available >= required) continue;
            if (_investment_good_stamp[input_good] == visit) {
                ++_startup_demand_cycle_skips;
                continue;
            }
            record_startup_demand(cell, input_good, derived);
            queue_good(input_good);
        }
        for (int32_t edge = 0; edge < type.construction_count; ++edge) {
            const int64_t physical = edge < static_cast<int32_t>(
                    producer_plan.material_quantities.size())
                ? producer_plan.material_quantities[edge] : 0;
            const int32_t material = edge < static_cast<int32_t>(
                    producer_plan.material_good_ids.size())
                ? producer_plan.material_good_ids[edge] : -1;
            ++_startup_demand_catalog_edges;
            if (material < 0 || physical <= 0 ||
                market_store().stock[market_store().index(market, material)] >= physical)
                continue;
            if (_investment_good_stamp[material] == visit) {
                ++_startup_demand_cycle_skips;
                continue;
            }
            const int64_t daily = std::max<int64_t>(1,
                (physical + std::max(1, _epoch_days.get()) - 1) /
                    std::max(1, _epoch_days.get()));
            record_startup_demand(cell, material, daily);
            queue_good(material);
        }
    }
}

} // namespace pk
