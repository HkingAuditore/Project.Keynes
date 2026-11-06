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

int32_t NativeEconomyRuntime::building_slice_end(int32_t active_begin) const {
    return building_slice_end(active_begin, _building_cells_per_slice,
                              _building_groups_per_slice);
}

int32_t NativeEconomyRuntime::building_slice_end(
        int32_t active_begin, int32_t cell_cap, int32_t group_cap) const {
    const std::vector<int32_t> &active_cells = _epoch_active
        ? _epoch_building_cells : _building_active_cells;
    return slice_end_over(active_cells, active_begin, cell_cap, group_cap);
}

int32_t NativeEconomyRuntime::slice_end_over(
        const std::vector<int32_t> &active_cells,
        int32_t active_begin, int32_t cell_cap, int32_t group_cap) const {
    const int32_t active_count = static_cast<int32_t>(active_cells.size());
    active_begin = std::clamp(active_begin, 0, active_count);
    const int32_t cell_limit = std::min(active_count,
        active_begin + std::max(1, cell_cap));
    int32_t end = active_begin;
    int64_t groups = 0;
    while (end < cell_limit) {
        const int32_t cell = active_cells[end];
        const int64_t cell_groups = _building_cell_offsets.size() ==
                static_cast<size_t>(_cell_count.get() + 1)
            ? _building_cell_offsets[cell + 1] - _building_cell_offsets[cell] : 0;
        if (end > active_begin && groups + cell_groups > std::max(1, group_cap))
            break;
        groups += cell_groups;
        ++end;
    }
    return end;
}

int32_t NativeEconomyRuntime::building_plan_slice_end(int32_t active_begin) const {
    const int32_t cell_cap = _building_plan_cells_per_slice_override > 0
        ? _building_plan_cells_per_slice_override
        : std::min(65536, std::max(1, _building_cells_per_slice) * 2);
    const int32_t group_cap = _building_plan_cells_per_slice_override > 0
        ? _building_groups_per_slice
        : std::min(65536, std::max(1, _building_groups_per_slice) * 2);
    return building_slice_end(
        active_begin, cell_cap, group_cap);
}

int32_t NativeEconomyRuntime::plan_evaluate_slice_end(int32_t active_begin) const {
    const int32_t cell_cap = _building_plan_cells_per_slice_override > 0
        ? _building_plan_cells_per_slice_override
        : std::min(65536, std::max(1, _building_cells_per_slice) * 2);
    const int32_t group_cap = _building_plan_cells_per_slice_override > 0
        ? _building_groups_per_slice
        : std::min(65536, std::max(1, _building_groups_per_slice) * 2);
    return slice_end_over(_epoch_plan_cells, active_begin, cell_cap, group_cap);
}

int32_t NativeEconomyRuntime::household_post_slice_end(
        int32_t active_begin) const {
    const int32_t cell_cap =
        _household_post_building_cells_per_slice_override > 0
        ? _household_post_building_cells_per_slice_override
        : std::min(65536, std::max(1, _building_cells_per_slice) * 2);
    const int32_t group_cap =
        _household_post_building_cells_per_slice_override > 0
        ? _building_groups_per_slice
        : std::min(65536, std::max(1, _building_groups_per_slice) * 2);
    return building_slice_end(
        active_begin, cell_cap, group_cap);
}

int32_t NativeEconomyRuntime::estimate_building_ranges() const {
    int32_t ranges = 0;
    int32_t cursor = 0;
    const int32_t active_count = static_cast<int32_t>(_building_active_cells.size());
    while (cursor < active_count) {
        const int32_t end = building_slice_end(cursor);
        cursor = std::max(cursor + 1, end);
        ++ranges;
    }
    return ranges;
}

bool NativeEconomyRuntime::deadline_critical(int64_t day_index) const {
    if (!_bootstrapped || _fatal || _save.active || _restore.active ||
        _market_runtime_mode != 2) {
        return false;
    }
    if (_epoch_active) return day_index >= _sample_day;
    return day_index > _last_committed_day.get();
}

bool NativeEconomyRuntime::trade_planner_should_run() const {
    return _market_runtime_mode == 2 && _trade_runtime_mode.get() != 0 &&
           _trade_plan.phase != TradePlanStore::IDLE;
}

bool NativeEconomyRuntime::begin_trade_plan_slice(
        int64_t &work_done, std::string &error) {
    constexpr size_t budget = static_cast<size_t>(PUBLISH_ENTRIES_PER_SLICE);
    if (_trade_plan_init.phase == TradePlanInitPhase::IDLE) {
        _trade_plan_init.clear();
        _trade_plan_init.phase = TradePlanInitPhase::COMPONENT_PREPARE;
    }
    if (_trade_plan_init.phase == TradePlanInitPhase::COMPONENT_PREPARE) {
        if (_trade_runtime_mode.get() == 0 || !_trade_topology.ready ||
            market_store().market_count.get() <= 0 || market_store().good_count.get() <= 0) {
            _trade_plan_init.phase = TradePlanInitPhase::DONE;
            return true;
        }
        if (_trade_topology.neighbors.size() != static_cast<size_t>(_cell_count.get()) * 6 ||
            _trade_topology.passable.size() != static_cast<size_t>(_cell_count.get())) {
            error = "trade_topology_or_country_snapshot_not_ready";
            return false;
        }
        if (_trade_topology.component_country_hash == _trade_topology.topology_hash &&
            _trade_topology.component.size() == static_cast<size_t>(_cell_count.get())) {
            _trade_plan_init.phase = TradePlanInitPhase::PREPARE;
            return true;
        } else {
            _trade_topology.component.resize(static_cast<size_t>(_cell_count.get()));
            _trade_plan_init.cursor = 0;
            _trade_plan_init.component_seed = 0;
            _trade_plan_init.next_component = 0;
            _trade_plan_init.component_queue_cursor = 0;
            _trade_plan_init.component_queue.clear();
            _trade_plan_init.component_queue.reserve(static_cast<size_t>(
                std::min(_cell_count.get(), PUBLISH_ENTRIES_PER_SLICE * 4)));
            _trade_plan_init.phase = TradePlanInitPhase::COMPONENT_CLEAR;
            ++work_done;
            return true;
        }
    }
    if (_trade_plan_init.phase == TradePlanInitPhase::COMPONENT_CLEAR) {
        const size_t start = _trade_plan_init.cursor;
        const size_t end = std::min(static_cast<size_t>(_cell_count.get()), start + budget);
        for (; _trade_plan_init.cursor < end; ++_trade_plan_init.cursor)
            _trade_topology.component[_trade_plan_init.cursor] = -1;
        work_done += static_cast<int64_t>(end - start);
        if (_trade_plan_init.cursor >= static_cast<size_t>(_cell_count.get())) {
            _trade_plan_init.cursor = 0;
            _trade_plan_init.phase = TradePlanInitPhase::COMPONENT_BUILD;
        }
        return true;
    }
    if (_trade_plan_init.phase == TradePlanInitPhase::COMPONENT_BUILD) {
        size_t processed = 0;
        while (processed < budget) {
            if (_trade_plan_init.component_queue_cursor <
                    _trade_plan_init.component_queue.size()) {
                const int32_t cell = _trade_plan_init.component_queue[
                    _trade_plan_init.component_queue_cursor++];
                const int32_t component = _trade_topology.component[cell];
                for (int32_t direction = 0; direction < 6; ++direction) {
                    const int32_t neighbor = _trade_topology.neighbors[
                        static_cast<size_t>(cell) * 6 + direction];
                    if (neighbor < 0 || _trade_topology.passable[neighbor] == 0 ||
                        _trade_topology.component[neighbor] >= 0) continue;
                    _trade_topology.component[neighbor] = component;
                    _trade_plan_init.component_queue.push_back(neighbor);
                }
                ++processed;
                continue;
            }
            _trade_plan_init.component_queue.clear();
            _trade_plan_init.component_queue_cursor = 0;
            bool seeded = false;
            while (_trade_plan_init.component_seed < _cell_count.get() && processed < budget) {
                const int32_t seed = _trade_plan_init.component_seed++;
                ++processed;
                if (_trade_topology.passable[seed] == 0 ||
                    _trade_topology.component[seed] >= 0) continue;
                _trade_topology.component[seed] = _trade_plan_init.next_component++;
                _trade_plan_init.component_queue.push_back(seed);
                seeded = true;
                break;
            }
            if (!seeded && _trade_plan_init.component_seed >= _cell_count.get()) break;
        }
        work_done += static_cast<int64_t>(processed);
        if (_trade_plan_init.component_seed >= _cell_count.get() &&
            _trade_plan_init.component_queue_cursor >=
                _trade_plan_init.component_queue.size()) {
            _trade_topology.component_country_hash = _trade_topology.topology_hash;
            _trade_plan_init.phase = TradePlanInitPhase::PREPARE;
        }
        return true;
    }
    if (_trade_plan_init.phase == TradePlanInitPhase::PREPARE) {
        if (_trade_runtime_mode.get() == 0 || !_trade_topology.ready ||
            market_store().market_count.get() <= 0 || market_store().good_count.get() <= 0) {
            _trade_plan_init.phase = TradePlanInitPhase::DONE;
            return true;
        }
        _trade_plan.phase = TradePlanStore::SCAN;
        _trade_plan.scan_cursor = 0;
        _trade_plan.route_cursor = 0;
        _trade_plan.route_search_active = false;
        _trade_plan.route_search_source = -1;
        _trade_plan.route_search_accepted = 0;
        _trade_plan.route_search_pending_targets = 0;
        _trade_plan.route_search_expansions = 0;
        std::sort(_trade_active_keys.begin(), _trade_active_keys.end());
        _trade_active_keys.erase(
            std::unique(_trade_active_keys.begin(), _trade_active_keys.end()),
            _trade_active_keys.end());
        _trade_plan_init.active_before_prune = _trade_active_keys.size();
        _trade_plan_init.inflight_keys.clear();
        _trade_plan_init.inflight_keys.reserve(trade_orders_store().line_goods.size());
        _trade_plan_init.order_cursor = 0;
        _trade_plan_init.line_cursor = trade_orders_store().line_offsets.empty()
            ? 0 : trade_orders_store().line_offsets[0];
        _trade_plan_init.phase = TradePlanInitPhase::INFLIGHT_BUILD;
        ++work_done;
        return true;
    }
    if (_trade_plan_init.phase == TradePlanInitPhase::INFLIGHT_BUILD) {
        size_t processed = 0;
        while (_trade_plan_init.order_cursor < trade_orders_store().size() && processed < budget) {
            const int32_t order = _trade_plan_init.order_cursor;
            if (_trade_plan_init.line_cursor >= trade_orders_store().line_offsets[order + 1]) {
                ++_trade_plan_init.order_cursor;
                if (_trade_plan_init.order_cursor < trade_orders_store().size())
                    _trade_plan_init.line_cursor =
                        trade_orders_store().line_offsets[_trade_plan_init.order_cursor];
                continue;
            }
            const int32_t line = _trade_plan_init.line_cursor++;
            _trade_plan_init.inflight_keys.push_back(
                (static_cast<uint64_t>(static_cast<uint32_t>(
                    trade_orders_store().destinations[order])) << 32) |
                static_cast<uint32_t>(trade_orders_store().line_goods[line]));
            ++processed;
        }
        work_done += static_cast<int64_t>(processed);
        if (_trade_plan_init.order_cursor >= trade_orders_store().size())
            _trade_plan_init.phase = TradePlanInitPhase::INFLIGHT_SORT;
        return true;
    }
    if (_trade_plan_init.phase == TradePlanInitPhase::INFLIGHT_SORT) {
        auto &keys = _trade_plan_init.inflight_keys;
        std::sort(keys.begin(), keys.end());
        keys.erase(std::unique(keys.begin(), keys.end()), keys.end());
        _trade_plan_init.retained_active_keys.clear();
        _trade_plan_init.retained_active_keys.reserve(_trade_active_keys.size());
        _trade_plan_init.cursor = 0;
        _trade_plan_init.phase = TradePlanInitPhase::PRUNE;
        work_done += static_cast<int64_t>(keys.size());
        return true;
    }
    if (_trade_plan_init.phase == TradePlanInitPhase::PRUNE) {
        const size_t start = _trade_plan_init.cursor;
        const size_t end = std::min(_trade_active_keys.size(), start + budget);
        for (; _trade_plan_init.cursor < end; ++_trade_plan_init.cursor) {
            const uint64_t key = _trade_active_keys[_trade_plan_init.cursor];
            const int32_t cell = static_cast<int32_t>(key >> 32);
            const int32_t good = static_cast<int32_t>(key & 0xffffffffU);
            bool idle = cell < 0 || cell >= market_store().market_count.get() || good < 0 ||
                good >= market_store().good_count.get();
            if (!idle) {
                const int64_t index = market_store().index(cell, good);
                const int32_t signal = market_signal_index(cell, good);
                const bool building_signal = signal >= 0 &&
                    (_market_signals.business_demand_ema[signal] > 0 ||
                     _market_signals.offered_supply_ema[signal] > 0);
                idle = market_store().stock[index] <= 0 && market_store().demand_ema[index] <= 0 &&
                    market_store().last_shortage_q16[index] == 0 && !building_signal &&
                    !std::binary_search(_trade_plan_init.inflight_keys.begin(),
                                        _trade_plan_init.inflight_keys.end(), key);
            }
            if (!idle) {
                _trade_active_key_idle_cycles.erase(key);
                _trade_plan_init.retained_active_keys.push_back(key);
                continue;
            }
            uint8_t &idle_cycles = _trade_active_key_idle_cycles[key];
            idle_cycles = static_cast<uint8_t>(std::min<int32_t>(
                255, static_cast<int32_t>(idle_cycles) + 1));
            if (idle_cycles < 2)
                _trade_plan_init.retained_active_keys.push_back(key);
            else {
                _trade_active_key_idle_cycles.erase(key);
                if (cell >= 0 && cell < market_store().market_count.get() && good >= 0 &&
                    good < market_store().good_count.get() &&
                    _trade_active_key_present.size() == market_store().stock.size()) {
                    _trade_active_key_present[market_store().index(cell, good)] = 0;
                }
            }
        }
        work_done += static_cast<int64_t>(end - start);
        if (_trade_plan_init.cursor >= _trade_active_keys.size()) {
            _trade_active_keys.swap(_trade_plan_init.retained_active_keys);
            _trade_active_keys_pruned = saturating_add(
                _trade_active_keys_pruned,
                static_cast<int64_t>(_trade_plan_init.active_before_prune -
                                     _trade_active_keys.size()),
                _saturation_count);
            _trade_plan.scan_cells.clear();
            _trade_plan.scan_goods.clear();
            _trade_plan.scan_inbound.assign(_trade_active_keys.size(), 0);
            _trade_plan.scan_cells.reserve(_trade_active_keys.size());
            _trade_plan.scan_goods.reserve(_trade_active_keys.size());
            _trade_plan_init.order_cursor = 0;
            _trade_plan_init.line_cursor = trade_orders_store().line_offsets.empty()
                ? 0 : trade_orders_store().line_offsets[0];
            _trade_plan_init.phase = TradePlanInitPhase::INBOUND_BUILD;
        }
        return true;
    }
    if (_trade_plan_init.phase == TradePlanInitPhase::INBOUND_BUILD) {
        size_t processed = 0;
        while (_trade_plan_init.order_cursor < trade_orders_store().size() && processed < budget) {
            const int32_t order = _trade_plan_init.order_cursor;
            if (_trade_plan_init.line_cursor >= trade_orders_store().line_offsets[order + 1]) {
                ++_trade_plan_init.order_cursor;
                if (_trade_plan_init.order_cursor < trade_orders_store().size())
                    _trade_plan_init.line_cursor =
                        trade_orders_store().line_offsets[_trade_plan_init.order_cursor];
                continue;
            }
            const int32_t line = _trade_plan_init.line_cursor++;
            const uint64_t key =
                (static_cast<uint64_t>(static_cast<uint32_t>(
                    trade_orders_store().destinations[order])) << 32) |
                static_cast<uint32_t>(trade_orders_store().line_goods[line]);
            const auto it = std::lower_bound(_trade_active_keys.begin(),
                                             _trade_active_keys.end(), key);
            if (it != _trade_active_keys.end() && *it == key) {
                const size_t index = static_cast<size_t>(it - _trade_active_keys.begin());
                _trade_plan.scan_inbound[index] = saturating_add(
                    _trade_plan.scan_inbound[index], trade_orders_store().line_quantities[line],
                    _saturation_count);
            }
            ++processed;
        }
        work_done += static_cast<int64_t>(processed);
        if (_trade_plan_init.order_cursor >= trade_orders_store().size()) {
            const size_t signal_count = _trade_active_keys.size();
            const uint64_t day = static_cast<uint64_t>(std::max<int64_t>(0, _sample_day));
            _trade_plan_init.rotation = signal_count == 0 ? 0 : static_cast<size_t>(
                (day * static_cast<uint64_t>(std::max(1, _trade_max_signals.get()))) %
                static_cast<uint64_t>(signal_count));
            _trade_plan_init.rotated_inbound.clear();
            _trade_plan_init.rotated_inbound.reserve(signal_count);
            _trade_plan_init.cursor = 0;
            _trade_plan_init.phase = TradePlanInitPhase::ROTATE;
        }
        return true;
    }
    if (_trade_plan_init.phase == TradePlanInitPhase::ROTATE) {
        const size_t start = _trade_plan_init.cursor;
        const size_t end = std::min(_trade_active_keys.size(), start + budget);
        for (; _trade_plan_init.cursor < end; ++_trade_plan_init.cursor) {
            const size_t index = (_trade_plan_init.rotation +
                                  _trade_plan_init.cursor) % _trade_active_keys.size();
            const uint64_t key = _trade_active_keys[index];
            _trade_plan.scan_cells.push_back(static_cast<int32_t>(key >> 32));
            _trade_plan.scan_goods.push_back(static_cast<int32_t>(key & 0xffffffffU));
            _trade_plan_init.rotated_inbound.push_back(_trade_plan.scan_inbound[index]);
        }
        work_done += static_cast<int64_t>(end - start);
        if (_trade_plan_init.cursor >= _trade_active_keys.size()) {
            _trade_plan.scan_inbound.swap(_trade_plan_init.rotated_inbound);
            _trade_plan.distance.resize(static_cast<size_t>(_cell_count.get()));
            _trade_plan.distance_stamp.resize(static_cast<size_t>(_cell_count.get()));
            _trade_plan.target_signal.resize(static_cast<size_t>(_cell_count.get()));
            _trade_plan.target_stamp.resize(static_cast<size_t>(_cell_count.get()));
            _trade_plan_init.cursor = 0;
            _trade_plan_init.phase = TradePlanInitPhase::WORKSPACE_CLEAR;
        }
        return true;
    }
    if (_trade_plan_init.phase == TradePlanInitPhase::WORKSPACE_CLEAR) {
        const size_t start = _trade_plan_init.cursor;
        const size_t end = std::min(static_cast<size_t>(_cell_count.get()), start + budget);
        for (; _trade_plan_init.cursor < end; ++_trade_plan_init.cursor) {
            _trade_plan.distance[_trade_plan_init.cursor] = 0;
            _trade_plan.distance_stamp[_trade_plan_init.cursor] = 0;
            _trade_plan.target_signal[_trade_plan_init.cursor] = -1;
            _trade_plan.target_stamp[_trade_plan_init.cursor] = 0;
        }
        work_done += static_cast<int64_t>(end - start);
        if (_trade_plan_init.cursor >= static_cast<size_t>(_cell_count.get()))
            _trade_plan_init.phase = TradePlanInitPhase::FINALIZE;
        return true;
    }
    if (_trade_plan_init.phase == TradePlanInitPhase::FINALIZE) {
        _trade_plan.scan_total = static_cast<int64_t>(_trade_plan.scan_cells.size());
        _trade_plan.country_topology_hash = _epoch_country_topology_hash;
        _trade_plan.topology_generation = _trade_topology.topology_generation;
        _trade_plan.sources.clear();
        _trade_plan.destinations.clear();
        _trade_plan.working_candidates.clear();
        _trade_plan.heap.clear();
        size_t cache_size = 1;
        while (cache_size < static_cast<size_t>(_trade_route_cache_entries.get())) cache_size <<= 1;
        const bool route_cache_invalid =
            _trade_plan.route_cache_keys.size() != cache_size ||
            _trade_plan.route_cache_costs.size() != cache_size ||
            _trade_plan.route_cache_country_topology_hash !=
                _trade_topology.topology_hash ||
            _trade_plan.route_cache_topology_generation !=
                _trade_topology.topology_generation;
        if (route_cache_invalid) {
            _trade_plan.route_cache_keys.assign(
                cache_size, std::numeric_limits<uint64_t>::max());
            _trade_plan.route_cache_costs.assign(cache_size, -1);
            _trade_plan.route_cache_country_topology_hash =
                _trade_topology.topology_hash;
            _trade_plan.route_cache_topology_generation =
                _trade_topology.topology_generation;
            work_done += static_cast<int64_t>(cache_size);
        }
        _trade_plan_init.phase = TradePlanInitPhase::DONE;
    }
    return true;
}

void NativeEconomyRuntime::refresh_investment_active_goods_for_cell(
        int32_t cell, int64_t &sat) {
    if (cell < 0 || cell >= _cell_count.get() || market_store().good_count.get() <= 0 ||
        market_store().cell_to_market.size() != static_cast<size_t>(_cell_count.get())) {
        return;
    }
    const int32_t market = market_store().cell_to_market[static_cast<size_t>(cell)];
    if (market < 0 || market >= market_store().market_count.get()) return;
    const size_t words_per_market =
        (static_cast<size_t>(market_store().good_count.get()) + 63U) / 64U;
    if (_investment_active_good_words.size() != words_per_market) return;
    std::fill(_investment_active_good_words.begin(),
              _investment_active_good_words.end(), uint64_t{0});
    _investment_active_goods_scratch.clear();
    auto mark_good = [&](int32_t good) {
        if (good < 0 || good >= market_store().good_count.get()) return;
        uint64_t &word = _investment_active_good_words[
            static_cast<size_t>(good / 64)];
        const uint64_t bit = uint64_t{1} <<
            static_cast<uint32_t>(good % 64);
        if ((word & bit) != 0) return;
        word |= bit;
        _investment_active_goods_scratch.push_back(good);
    };

    // All sources below are sparse. No review cell scans the goods catalog.
    const uint64_t key_begin =
        static_cast<uint64_t>(static_cast<uint32_t>(cell)) << 32;
    const uint64_t key_end = key_begin | 0xffffffffULL;
    auto active = std::lower_bound(
        _trade_active_keys.begin(), _trade_active_keys.end(), key_begin);
    for (; active != _trade_active_keys.end() && *active <= key_end; ++active)
        mark_good(static_cast<int32_t>(*active & 0xffffffffULL));

    if (_market_signals.cell_offsets.size() ==
            static_cast<size_t>(_cell_count.get() + 1)) {
        for (int32_t signal = _market_signals.cell_offsets[cell];
             signal < _market_signals.cell_offsets[cell + 1]; ++signal) {
            mark_good(_market_signals.good_ids[signal]);
        }
    }

    // Propagation for the current stable review cell appends a contiguous tail.
    for (size_t cursor = _startup_demand_touched_keys.size(); cursor > 0;) {
        const uint64_t key = _startup_demand_touched_keys[--cursor];
        const int32_t key_cell = static_cast<int32_t>(key >> 32);
        if (key_cell != cell) break;
        mark_good(static_cast<int32_t>(key & 0xffffffffULL));
    }

    if (_trade_topology.component.size() == static_cast<size_t>(_cell_count.get()) &&
        _epoch_cell_country.size() == static_cast<size_t>(_cell_count.get())) {
        const int32_t country = _epoch_cell_country[static_cast<size_t>(cell)];
        const int32_t component =
            _trade_topology.component[static_cast<size_t>(cell)];
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
            for (int32_t lane = group->lane_begin; lane < group->lane_end;
                 ++lane) {
                if (_startup_remote_lanes[lane].remaining_daily > 0)
                    mark_good(_startup_remote_lanes[lane].good_id);
            }
        }
    }
    for (const int32_t good : _startup_monetary_good_indices) mark_good(good);
    if (epoch_research_demand_daily(cell, _epoch_research_good_id) > 0)
        mark_good(_epoch_research_good_id);

    // Keep deterministic candidate order independent of sparse source order.
    std::sort(_investment_active_goods_scratch.begin(),
              _investment_active_goods_scratch.end());
    (void)sat;
}

int64_t NativeEconomyRuntime::merchant_procurement_quota(
        int32_t market, int32_t good, int32_t signal_index,
        int64_t sellable, int64_t target, int64_t stock,
        int64_t realized_withdrawal, int64_t export_ema,
        int64_t &sat) const {
    if (sellable <= 0 || market < 0 || market >= market_store().market_count.get() ||
        good < 0 || good >= market_store().good_count.get() || _good_storage_modes[good] != 0)
        return 0;
    const int64_t index = market_store().index(market, good);
    int64_t feasible_daily = std::max<int64_t>(0, market_store().demand_ema[index]);
    if (signal_index >= 0 && signal_index < static_cast<int32_t>(
            _market_signals.business_demand_ema.size())) {
        feasible_daily = saturating_add(feasible_daily,
            std::max<int64_t>(0, _market_signals.business_demand_ema[signal_index]), sat);
    }
    // Derived demand remains a shadow price/investment signal.  It is not a
    // merchant procurement quota and therefore cannot spend stock or cash.
    feasible_daily = saturating_add(
        feasible_daily,
        epoch_procurement_demand_daily_for_market(market, good), sat);
    const int64_t forecast_daily = std::max<int64_t>(
        std::max<int64_t>(0, realized_withdrawal), feasible_daily);
    const int64_t cycle_withdrawal = saturating_mul(
        saturating_add(forecast_daily, std::max<int64_t>(0, export_ema), sat),
        std::max(1, _epoch_days.get()), sat);
    const int64_t projected_stock = std::max<int64_t>(
        0, saturating_sub(std::max<int64_t>(0, stock), cycle_withdrawal, sat));
    const int64_t restock_quota = std::max<int64_t>(
        0, saturating_sub(std::max<int64_t>(0, target), projected_stock, sat));
    int64_t continuity_quota = 0;
    if (is_storable_nonmonetary_good(good) && forecast_daily > 0) {
        const int64_t high_water = mul_div_sat(
            std::max<int64_t>(0, target), MERCHANT_INVENTORY_HIGH_WATER_Q16,
            Q16_ONE, sat);
        if (stock <= high_water) {
            const int64_t projected_high_water = std::max<int64_t>(
                0, saturating_sub(high_water, projected_stock, sat));
            continuity_quota = std::min<int64_t>(sellable, std::min<int64_t>(
                cycle_withdrawal, projected_high_water));
        }
    }
    return std::min<int64_t>(sellable,
        std::max<int64_t>(restock_quota, continuity_quota));
}

int32_t NativeEconomyRuntime::effective_merchant_buy_factor_q16(
        int32_t market, int32_t good, int64_t target, int64_t stock,
        int64_t &sat) const {
    if (good < 0 || good >= market_store().good_count.get() || market < 0 ||
        market >= market_store().market_count.get()) return 0;
    (void)target;
    (void)stock;
    (void)sat;
    // The configured factor is the producer settlement factor and a hard
    // ceiling. Shortage still controls quantity and budget priority, but may
    // not erase the merchant's configured distribution margin.
    return static_cast<int32_t>(std::clamp<int64_t>(
        _good_merchant_buy_factor_q16[good], 0, Q16_ONE));
}

bool NativeEconomyRuntime::apply_family_free_building_reward(
        const Command &cmd, std::string &error) {
    int32_t branch = -1;
    if (!family_influences().valid_handle(cmd.target_handle, branch)) {
        ++_rejected_commands;
        return true;
    }
    const uint64_t family_handle = family_influences().family_handle[branch];
    int32_t family = -1;
    const int32_t cell = family_influences().cell[branch];
    const int32_t type_id = family_free_building_type_id(cmd);
    const int64_t count = cmd.i64_0;
    if (!families_store().valid_handle(family_handle, family) || cell < 0 ||
        cell >= _cell_count.get() || type_id < 0 ||
        type_id >= static_cast<int32_t>(_building_types.size()) || count <= 0) {
        ++_rejected_commands;
        return true;
    }
    if (!building_available(cell, type_id, true)) {
        _last_building_rejection_reason = "reward_building_technology_locked";
        ++_rejected_commands;
        return true;
    }
    if (!building_constructible(cell, type_id, true)) {
        _last_building_rejection_reason =
            "reward_building_tier_obsolete_for_construction";
        ++_rejected_commands;
        return true;
    }
    if (!evaluate_building_conditions(type_id, cell)) {
        _last_building_rejection_reason = "reward_building_conditions_failed";
        ++_rejected_commands;
        return true;
    }
    if (!family_free_building_resources_legal(cell, type_id, count)) {
        _last_building_rejection_reason =
            "reward_building_resource_unavailable";
        ++_rejected_commands;
        return true;
    }

    int32_t ethnicity = families_store().origin_ethnicity[family];
    if (cmd.i32_0 == 1) {
        int64_t largest_population = -1;
        population_store().for_each_in_cell(cell, [&](int32_t slot) {
            const int32_t signature = static_cast<int32_t>(
                population_store().signature_id[slot]);
            if (signature < 0 || signature >= static_cast<int32_t>(
                    _signatures.size())) return;
            if (population_store().population[slot] > largest_population) {
                largest_population = population_store().population[slot];
                ethnicity = _signatures[signature].ethnicity_id;
            }
        });
    }
    const BuildingType &type = _building_types[type_id];
    const int32_t owner_signature = signature_for_profession_ethnicity(
        type.owner_profession_id, ethnicity);
    if (owner_signature < 0) {
        _last_building_rejection_reason = "reward_building_owner_signature_missing";
        ++_rejected_commands;
        return true;
    }
    const int32_t country_slot = cell < static_cast<int32_t>(
            _epoch_cell_country.size()) ? _epoch_cell_country[cell] : -1;
    const int32_t time_factor = country_slot >= 0 && country_slot <
            static_cast<int32_t>(_epoch_country_construction_time_factor_q16.size())
        ? _epoch_country_construction_time_factor_q16[country_slot] : Q16_ONE;
    const int32_t construction_days = type.construction_days <= 0 ? 0 :
        std::max<int32_t>(1, static_cast<int32_t>(mul_div_sat(
            type.construction_days, time_factor, Q16_ONE, _saturation_count)));
    const int64_t reward_sequence = -std::max<int64_t>(1, cmd.sequence);
    append_pending_construction({cell, type_id, owner_signature, count,
        _sample_day + construction_days, reward_sequence, 0, 0, 0,
        cmd.i32_0 == 0 ? family_handle : 0});
    trace_append(EVENT_CONSTRUCTION_STARTED,
        static_cast<int32_t>(Stage::LEDGER_APPLY), cell,
        SUBJECT_FAMILY_BRANCH, static_cast<int64_t>(cmd.target_handle),
        type_id, cmd.i32_0, count, _sample_day + construction_days,
        cmd.i64_1, reward_sequence, nullptr);
    return true;
}

bool NativeEconomyRuntime::apply_family_purchase_discount(
        const Command &cmd, std::string &error) {
    (void)error;
    int32_t branch = -1;
    if (!family_influences().valid_handle(cmd.target_handle, branch)) {
        ++_rejected_commands;
        return true;
    }
    int32_t family = -1;
    if (!families_store().valid_handle(family_influences().family_handle[branch], family)) {
        ++_rejected_commands;
        return true;
    }
    ensure_family_policy_factors();
    if (family >= 0 && family < static_cast<int32_t>(
            _family_purchase_factor_q16.size()))
        _family_purchase_factor_q16[static_cast<size_t>(family)] =
            static_cast<int32_t>(std::clamp<int64_t>(cmd.i64_0, 0, Q16_ONE));
    return true;
}

} // namespace pk
