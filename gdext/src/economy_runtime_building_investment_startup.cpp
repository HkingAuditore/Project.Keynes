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

} // namespace pk
