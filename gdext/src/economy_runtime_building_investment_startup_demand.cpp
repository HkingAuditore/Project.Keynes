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
