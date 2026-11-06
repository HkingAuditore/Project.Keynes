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
using Clock = std::chrono::steady_clock;
double elapsed_ms(const Clock::time_point &start) {
    return std::chrono::duration<double, std::milli>(Clock::now() - start).count();
}
} // namespace

uint64_t NativeEconomyRuntime::trace_hash_mix(uint64_t hash, uint64_t value) {
    hash ^= value;
    hash *= 1099511628211ULL;
    return hash;
}

int32_t NativeEconomyRuntime::find_cohort_slot(int32_t cell, int32_t signature_id) const {
    if (cell < 0 || cell >= _cell_count.get() || signature_id < 0 ||
        signature_id >= static_cast<int32_t>(_signatures.size())) return -1;
    const int64_t before = population_store().scan_steps;
    const int32_t slot = population_store().find_signature(
        cell, static_cast<uint32_t>(signature_id));
    const int64_t steps = population_store().scan_steps - before;
    _scan_steps_find_signature += steps;
    ++_scan_calls_find_signature;
    note_scan_steps(steps);
    return slot;
}

void NativeEconomyRuntime::mark_market_signal_cell_dirty(int32_t cell) {
    if (cell < 0 || cell >= _cell_count.get()) return;
    if (_market_signal_cell_dirty.size() != static_cast<size_t>(_cell_count.get()))
        _market_signal_cell_dirty.assign(static_cast<size_t>(_cell_count.get()), 0);
    _market_signal_cell_dirty[static_cast<size_t>(cell)] = 1;
}

void NativeEconomyRuntime::mark_market_signal_full_rebuild(const char *reason) {
    _market_signal_force_full = true;
    _market_signal_full_rebuild_reason =
        reason != nullptr && reason[0] != '\0' ? reason : "unspecified";
    if (_cell_count.get() > 0) {
        _market_signal_cell_dirty.assign(static_cast<size_t>(_cell_count.get()), 1);
    }
}

void NativeEconomyRuntime::mark_labor_signal_cell_dirty(int32_t cell) {
    if (cell < 0 || cell >= _cell_count.get()) return;
    if (_labor_signal_cell_dirty.size() != static_cast<size_t>(_cell_count.get()))
        _labor_signal_cell_dirty.assign(static_cast<size_t>(_cell_count.get()), 0);
    _labor_signal_cell_dirty[static_cast<size_t>(cell)] = 1;
}

void NativeEconomyRuntime::mark_labor_signal_full_rebuild(const char *reason) {
    _labor_signal_force_full = true;
    _labor_signal_full_rebuild_reason =
        reason != nullptr && reason[0] != '\0' ? reason : "unspecified";
    if (_cell_count.get() > 0) {
        _labor_signal_cell_dirty.assign(static_cast<size_t>(_cell_count.get()), 1);
    }
}

void NativeEconomyRuntime::mark_input_reserve_cell_dirty(int32_t cell) {
    if (cell < 0 || cell >= _cell_count.get()) return;
    if (_input_reserve_cell_dirty.size() != static_cast<size_t>(_cell_count.get()))
        _input_reserve_cell_dirty.assign(static_cast<size_t>(_cell_count.get()), 0);
    _input_reserve_cell_dirty[static_cast<size_t>(cell)] = 1;
}

void NativeEconomyRuntime::mark_input_reserve_full_rebuild(const char *reason) {
    _input_reserve_force_full = true;
    _input_reserve_full_rebuild_reason =
        reason != nullptr && reason[0] != '\0' ? reason : "unspecified";
    if (_cell_count.get() > 0) {
        _input_reserve_cell_dirty.assign(static_cast<size_t>(_cell_count.get()), 1);
    }
}

void NativeEconomyRuntime::rebuild_market_signals() {
    MarketSignalStore &next = _market_signals_rebuild_scratch;
    next.clear(_cell_count.get());
    const size_t old_size = _market_signals.good_ids.size();
    next.good_ids.reserve(old_size);
    next.business_demand_ema.reserve(old_size);
    next.offered_supply_ema.reserve(old_size);
    next.realized_withdrawal_ema.reserve(old_size);
    next.cost_anchor_price.reserve(old_size);
    if (_building_market_signal_stamp.size() !=
            static_cast<size_t>(market_store().good_count.get())) {
        _building_market_signal_stamp.assign(
            static_cast<size_t>(std::max(0, market_store().good_count.get())), 0);
        _building_market_signal_stamp_generation = 0;
    }
    if (_market_signal_cell_dirty.size() != static_cast<size_t>(_cell_count.get())) {
        mark_market_signal_full_rebuild(
            _market_signal_force_full ? _market_signal_full_rebuild_reason.c_str()
                                     : "dirty_mask_resize");
    }
    if (_input_reserve_cell_dirty.size() != static_cast<size_t>(_cell_count.get())) {
        mark_input_reserve_full_rebuild(
            _input_reserve_force_full ? _input_reserve_full_rebuild_reason.c_str()
                                     : "dirty_mask_resize");
    }
    auto next_stamp = [&]() {
        ++_building_market_signal_stamp_generation;
        if (_building_market_signal_stamp_generation == 0) {
            std::fill(_building_market_signal_stamp.begin(),
                      _building_market_signal_stamp.end(), 0);
            _building_market_signal_stamp_generation = 1;
        }
        return _building_market_signal_stamp_generation;
    };
    const bool old_shape_valid = _market_signals.cell_offsets.size() ==
        static_cast<size_t>(_cell_count.get() + 1) &&
        static_cast<size_t>(_market_signals.cell_offsets.back()) <= old_size;
    const bool force_full = _market_signal_force_full || !old_shape_valid;
    if (force_full && !_market_signal_force_full)
        _market_signal_full_rebuild_reason = "shape_invalid";
    const bool reserve_force_full =
        force_full || _input_reserve_force_full || !old_shape_valid ||
        _production_input_reserve.size() != old_size ||
        _construction_material_reserve.size() != old_size;
    if (reserve_force_full && !_input_reserve_force_full && !force_full)
        _input_reserve_full_rebuild_reason = "shape_invalid";
    std::vector<int64_t> next_production_reserve;
    std::vector<int64_t> next_construction_reserve;
    if (!reserve_force_full) {
        next_production_reserve.reserve(old_size);
        next_construction_reserve.reserve(old_size);
    }
    int64_t cells_rebuilt = 0;
    int64_t reserve_groups_rebuilt = 0;
    for (int32_t cell = 0; cell < _cell_count.get(); ++cell) {
        const bool dirty = force_full ||
            _market_signal_cell_dirty[static_cast<size_t>(cell)] != 0;
        const bool reserve_dirty = reserve_force_full || dirty ||
            _input_reserve_cell_dirty[static_cast<size_t>(cell)] != 0;
        const int32_t old_begin = old_shape_valid
            ? _market_signals.cell_offsets[cell] : 0;
        const int32_t old_end = old_shape_valid
            ? _market_signals.cell_offsets[cell + 1] : 0;
        if (!dirty) {
            for (int32_t signal = old_begin; signal < old_end; ++signal) {
                next.good_ids.push_back(_market_signals.good_ids[signal]);
                next.business_demand_ema.push_back(
                    _market_signals.business_demand_ema[signal]);
                next.offered_supply_ema.push_back(
                    _market_signals.offered_supply_ema[signal]);
                next.realized_withdrawal_ema.push_back(
                    _market_signals.realized_withdrawal_ema[signal]);
                next.cost_anchor_price.push_back(
                    _market_signals.cost_anchor_price[signal]);
                if (!reserve_force_full) {
                    next_production_reserve.push_back(
                        reserve_dirty ? 0 : _production_input_reserve[signal]);
                    next_construction_reserve.push_back(
                        reserve_dirty
                            ? 0
                            : _construction_material_reserve[signal]);
                }
            }
            next.cell_offsets.write_scalar(cell + 1, static_cast<int32_t>(next.good_ids.size()));
            continue;
        }
        ++cells_rebuilt;
        const uint32_t stamp = next_stamp();
        for (int32_t signal = old_begin; signal < old_end; ++signal) {
            if (_market_signals.business_demand_ema[signal] != 0 ||
                _market_signals.offered_supply_ema[signal] != 0 ||
                _market_signals.realized_withdrawal_ema[signal] != 0 ||
                _market_signals.cost_anchor_price[signal] != 0) {
                _building_market_signal_stamp[
                    _market_signals.good_ids[signal]] = stamp;
            }
        }
        if (_building_cell_offsets.size() ==
                static_cast<size_t>(_cell_count.get() + 1)) {
            for (int32_t group_index = _building_cell_offsets[cell];
                 group_index < _building_cell_offsets[cell + 1]; ++group_index) {
                const auto group = building_view(static_cast<size_t>(group_index));
                if (group.count <= 0 || group.type_id < 0 ||
                    group.type_id >= static_cast<int32_t>(_building_types.size()))
                    continue;
                const BuildingType &type = _building_types[group.type_id];
                for (int32_t edge = type.market_signal_begin;
                     edge < type.market_signal_begin + type.market_signal_count;
                     ++edge) {
                    _building_market_signal_stamp[
                        _building_type_market_signal_goods[edge]] = stamp;
                }
            }
        }
        int32_t old_cursor = old_begin;
        for (int32_t good = 0; good < market_store().good_count.get(); ++good) {
            if (_building_market_signal_stamp[good] != stamp) continue;
            while (old_cursor < old_end &&
                   _market_signals.good_ids[old_cursor] < good) ++old_cursor;
            const bool found = old_cursor < old_end &&
                _market_signals.good_ids[old_cursor] == good;
            next.good_ids.push_back(good);
            next.business_demand_ema.push_back(found
                ? _market_signals.business_demand_ema[old_cursor] : 0);
            next.offered_supply_ema.push_back(found
                ? _market_signals.offered_supply_ema[old_cursor] : 0);
            next.realized_withdrawal_ema.push_back(found
                ? _market_signals.realized_withdrawal_ema[old_cursor] : 0);
            next.cost_anchor_price.push_back(found
                ? _market_signals.cost_anchor_price[old_cursor] : 0);
            if (!reserve_force_full) {
                next_production_reserve.push_back(0);
                next_construction_reserve.push_back(0);
            }
        }
        next.cell_offsets.write_scalar(cell + 1, static_cast<int32_t>(next.good_ids.size()));
    }
    std::swap(_market_signals, _market_signals_rebuild_scratch);
    rebuild_market_signal_lookup();
    if (reserve_force_full) {
        rebuild_production_input_reserves(0, -1, true);
        reserve_groups_rebuilt = static_cast<int64_t>(building_count());
        _input_reserve_full_rebuild_reason =
            force_full ? _market_signal_full_rebuild_reason
                       : _input_reserve_full_rebuild_reason;
    } else {
        _production_input_reserve.swap(next_production_reserve);
        _construction_material_reserve.swap(next_construction_reserve);
        recount_production_input_reserve_totals();
        _production_input_reserve_shortfall = 0;
        for (int32_t cell = 0; cell < _cell_count.get(); ++cell) {
            const bool reserve_dirty =
                _market_signal_cell_dirty[static_cast<size_t>(cell)] != 0 ||
                _input_reserve_cell_dirty[static_cast<size_t>(cell)] != 0;
            if (!reserve_dirty) continue;
            reserve_groups_rebuilt +=
                rebuild_production_input_reserves_for_cell(cell);
        }
        _input_reserve_full_rebuild_reason.clear();
    }
    _market_signal_cells_rebuilt = cells_rebuilt;
    _input_reserve_groups_rebuilt = reserve_groups_rebuilt;
    _market_signal_force_full = false;
    _input_reserve_force_full = false;
    if (!_market_signal_cell_dirty.empty())
        std::fill(_market_signal_cell_dirty.begin(),
                  _market_signal_cell_dirty.end(), 0);
    if (!_input_reserve_cell_dirty.empty())
        std::fill(_input_reserve_cell_dirty.begin(),
                  _input_reserve_cell_dirty.end(), 0);
    if (cells_rebuilt == 0)
        _market_signal_full_rebuild_reason.clear();
}

void NativeEconomyRuntime::rebuild_market_signal_lookup() {
    constexpr size_t DENSE_LOOKUP_ENTRY_LIMIT = 4'000'000;
    const size_t matrix_size = static_cast<size_t>(std::max(0, _cell_count.get())) *
        static_cast<size_t>(std::max(0, market_store().good_count.get()));
    if (market_store().good_count.get() <= 0 || matrix_size > DENSE_LOOKUP_ENTRY_LIMIT ||
        _market_signals.cell_offsets.size() != static_cast<size_t>(_cell_count.get() + 1)) {
        _market_signals.dense_index.clear();
        return;
    }
    _market_signals.dense_index.assign(matrix_size, -1);
    for (int32_t cell = 0; cell < _cell_count.get(); ++cell) {
        for (int32_t signal = _market_signals.cell_offsets[cell];
             signal < _market_signals.cell_offsets[cell + 1]; ++signal) {
            const int32_t good = _market_signals.good_ids[signal];
            if (good >= 0 && good < market_store().good_count.get()) {
                _market_signals.dense_index[
                    static_cast<size_t>(cell) * market_store().good_count.get() + good] = signal;
            }
        }
    }
}

int32_t NativeEconomyRuntime::ensure_market_signal_index(int32_t cell, int32_t good) {
    if (cell < 0 || cell >= _cell_count.get() || good < 0 || good >= market_store().good_count.get() ||
        _market_signals.cell_offsets.size() != static_cast<size_t>(_cell_count.get() + 1)) return -1;
    const int32_t existing = market_signal_index(cell, good);
    if (existing >= 0) return existing;
    const auto insert_started = Clock::now();
    const size_t matrix_size = static_cast<size_t>(std::max(0, _cell_count.get())) *
        static_cast<size_t>(std::max(0, market_store().good_count.get()));
    if (_stage == Stage::BUILDING_COMMIT && _building_commit_phase == 5 &&
        _market_signals.dense_index.size() == matrix_size) {
        const size_t old_size = _market_signals.good_ids.size();
        const int32_t append_index = static_cast<int32_t>(old_size);
        _market_signals.good_ids.push_back(good);
        _market_signals.business_demand_ema.push_back(0);
        _market_signals.offered_supply_ema.push_back(0);
        _market_signals.realized_withdrawal_ema.push_back(0);
        _market_signals.cost_anchor_price.push_back(0);
        auto append_i64_if_aligned = [&](std::vector<int64_t> &values) {
            if (values.size() == old_size) values.push_back(0);
        };
        auto append_i32_if_aligned = [&](std::vector<int32_t> &values) {
            if (values.size() == old_size) values.push_back(0);
        };
        append_i64_if_aligned(_epoch_business_demand_ema);
        append_i64_if_aligned(_epoch_derived_business_demand);
        append_i64_if_aligned(_epoch_derived_anchor_price);
        append_i64_if_aligned(_epoch_substitute_business_demand);
        append_i64_if_aligned(_epoch_desired_business_demand);
        append_i64_if_aligned(_epoch_funded_business_demand);
    append_i64_if_aligned(_epoch_ceiling_business_requested);
    append_i64_if_aligned(_epoch_ceiling_business_unfilled);
        append_i64_if_aligned(_epoch_offered_supply_ema);
        append_i64_if_aligned(_epoch_producer_sellable_current);
        append_i64_if_aligned(_epoch_producer_merchant_sold_current);
        append_i64_if_aligned(_epoch_previous_producer_sellable);
        append_i64_if_aligned(_epoch_previous_producer_merchant_sold);
        append_i64_if_aligned(_epoch_producer_discarded_current);
        append_i64_if_aligned(_epoch_nonhousehold_withdrawals);
        append_i32_if_aligned(_epoch_cost_anchor_price);
        append_i64_if_aligned(_production_input_reserve);
        append_i64_if_aligned(_construction_material_reserve);
        _market_signal_overflow_cells.push_back(cell);
        _market_signals.dense_index[
            static_cast<size_t>(cell) * market_store().good_count.get() + good] = append_index;
        ++_market_signal_insert_count;
        _market_signal_insert_ms += elapsed_ms(insert_started);
        return append_index;
    }
    const int32_t begin = _market_signals.cell_offsets[cell];
    const int32_t end = _market_signals.cell_offsets[cell + 1];
    const auto first = _market_signals.good_ids.begin() + begin;
    const auto last = _market_signals.good_ids.begin() + end;
    const auto it = std::lower_bound(first, last, good);
    if (it != last && *it == good) {
        return static_cast<int32_t>(it - _market_signals.good_ids.begin());
    }
    const int32_t insert_pos = static_cast<int32_t>(it - _market_signals.good_ids.begin());
    const size_t old_size = _market_signals.good_ids.size();
    _market_signals.good_ids.insert(_market_signals.good_ids.begin() + insert_pos, good);
    _market_signals.business_demand_ema.insert(
        _market_signals.business_demand_ema.begin() + insert_pos, 0);
    _market_signals.offered_supply_ema.insert(
        _market_signals.offered_supply_ema.begin() + insert_pos, 0);
    _market_signals.realized_withdrawal_ema.insert(
        _market_signals.realized_withdrawal_ema.begin() + insert_pos, 0);
    _market_signals.cost_anchor_price.insert(
        _market_signals.cost_anchor_price.begin() + insert_pos, 0);
    for (int32_t c = cell + 1; c < static_cast<int32_t>(_market_signals.cell_offsets.size()); ++c) {
        _market_signals.cell_offsets.write_scalar(c, _market_signals.cell_offsets[c] + 1, market_mutation_sink());
    }
    auto insert_i64_if_aligned = [&](std::vector<int64_t> &values) {
        if (values.size() == old_size) values.insert(values.begin() + insert_pos, 0);
    };
    auto insert_i32_if_aligned = [&](std::vector<int32_t> &values) {
        if (values.size() == old_size) values.insert(values.begin() + insert_pos, 0);
    };
    insert_i64_if_aligned(_epoch_business_demand_ema);
    insert_i64_if_aligned(_epoch_derived_business_demand);
    insert_i64_if_aligned(_epoch_derived_anchor_price);
    insert_i64_if_aligned(_epoch_substitute_business_demand);
    insert_i64_if_aligned(_epoch_desired_business_demand);
    insert_i64_if_aligned(_epoch_funded_business_demand);
    insert_i64_if_aligned(_epoch_ceiling_business_requested);
    insert_i64_if_aligned(_epoch_ceiling_business_unfilled);
    insert_i64_if_aligned(_epoch_offered_supply_ema);
    insert_i64_if_aligned(_epoch_producer_sellable_current);
    insert_i64_if_aligned(_epoch_producer_merchant_sold_current);
    insert_i64_if_aligned(_epoch_previous_producer_sellable);
    insert_i64_if_aligned(_epoch_previous_producer_merchant_sold);
    insert_i64_if_aligned(_epoch_producer_discarded_current);
    insert_i64_if_aligned(_epoch_nonhousehold_withdrawals);
    insert_i32_if_aligned(_epoch_cost_anchor_price);
    insert_i64_if_aligned(_production_input_reserve);
    insert_i64_if_aligned(_construction_material_reserve);
    // Inserting shifts every following sparse index. Rebuilding the full dense
    // matrix here turns a rare topology mutation into O(cells * goods) per
    // investment. Fall back to the authoritative CSR until the next topology
    // rebuild, which recreates the cache once.
    _market_signals.dense_index.clear();
    ++_market_signal_insert_count;
    _market_signal_insert_ms += elapsed_ms(insert_started);
    return insert_pos;
}

bool NativeEconomyRuntime::flush_market_signal_overflow(std::string &error) {
    if (_market_signal_overflow_cells.empty()) return true;
    const auto started = Clock::now();
    const size_t total = _market_signals.good_ids.size();
    const size_t overflow_count = _market_signal_overflow_cells.size();
    if (overflow_count > total ||
        _market_signals.cell_offsets.size() != static_cast<size_t>(_cell_count.get() + 1) ||
        static_cast<size_t>(_market_signals.cell_offsets.back()) !=
            total - overflow_count) {
        error = "market_signal_overflow_shape_invalid";
        return false;
    }

    std::vector<int32_t> cells(total, -1);
    for (int32_t cell = 0; cell < _cell_count.get(); ++cell) {
        for (int32_t index = _market_signals.cell_offsets[cell];
             index < _market_signals.cell_offsets[cell + 1]; ++index) {
            cells[index] = cell;
        }
    }
    const size_t base_count = total - overflow_count;
    for (size_t i = 0; i < overflow_count; ++i)
        cells[base_count + i] = _market_signal_overflow_cells[i];

    std::vector<size_t> order(total);
    std::iota(order.begin(), order.end(), size_t{0});
    std::stable_sort(order.begin(), order.end(), [&](size_t a, size_t b) {
        if (cells[a] != cells[b]) return cells[a] < cells[b];
        if (_market_signals.good_ids[a] != _market_signals.good_ids[b])
            return _market_signals.good_ids[a] < _market_signals.good_ids[b];
        return a < b;
    });
    for (size_t i = 1; i < order.size(); ++i) {
        const size_t a = order[i - 1];
        const size_t b = order[i];
        if (cells[a] == cells[b] &&
            _market_signals.good_ids[a] == _market_signals.good_ids[b]) {
            error = "market_signal_overflow_duplicate";
            return false;
        }
    }

    _market_signals.cell_offsets.assign(
        static_cast<size_t>(_cell_count.get()) + 1, 0);
    for (const size_t index : order) {
        if (cells[index] < 0 || cells[index] >= _cell_count.get()) {
            error = "market_signal_overflow_cell_invalid";
            return false;
        }
        _market_signals.cell_offsets.write_scalar(cells[index] + 1, _market_signals.cell_offsets[cells[index] + 1] + 1, market_mutation_sink());
    }
    for (int32_t cell = 0; cell < _cell_count.get(); ++cell)
        _market_signals.cell_offsets.write_scalar(cell + 1, _market_signals.cell_offsets[cell + 1] + (_market_signals.cell_offsets[cell]), market_mutation_sink());

    auto reorder = [&](auto &values) {
        if (values.size() != total) return;
        using Value = typename std::decay_t<decltype(values)>::value_type;
        std::vector<Value> next;
        next.reserve(total);
        for (const size_t index : order) next.push_back(values[index]);
        values.swap(next);
    };
    reorder(_market_signals.good_ids);
    reorder(_market_signals.business_demand_ema);
    reorder(_market_signals.offered_supply_ema);
    reorder(_market_signals.realized_withdrawal_ema);
    reorder(_market_signals.cost_anchor_price);
    reorder(_epoch_business_demand_ema);
    reorder(_epoch_derived_business_demand);
    reorder(_epoch_derived_anchor_price);
    reorder(_epoch_substitute_business_demand);
    reorder(_epoch_desired_business_demand);
    reorder(_epoch_funded_business_demand);
    reorder(_epoch_ceiling_business_requested);
    reorder(_epoch_ceiling_business_unfilled);
    reorder(_epoch_offered_supply_ema);
    reorder(_epoch_producer_sellable_current);
    reorder(_epoch_producer_merchant_sold_current);
    reorder(_epoch_previous_producer_sellable);
    reorder(_epoch_previous_producer_merchant_sold);
    reorder(_epoch_producer_discarded_current);
    reorder(_epoch_nonhousehold_withdrawals);
    reorder(_epoch_cost_anchor_price);
    reorder(_production_input_reserve);
    reorder(_construction_material_reserve);
    _market_signal_overflow_cells.clear();
    rebuild_market_signal_lookup();
    _market_signal_flush_ms += elapsed_ms(started);
    return true;
}

int32_t NativeEconomyRuntime::market_signal_index(int32_t cell, int32_t good) const {
    if (cell < 0 || cell >= _cell_count.get() || good < 0 || good >= market_store().good_count.get() ||
        _market_signals.cell_offsets.size() != static_cast<size_t>(_cell_count.get() + 1)) return -1;
    const size_t dense_offset = static_cast<size_t>(cell) * market_store().good_count.get() + good;
    if (dense_offset < _market_signals.dense_index.size())
        return _market_signals.dense_index[dense_offset];
    const int32_t begin = _market_signals.cell_offsets[cell];
    const int32_t end = _market_signals.cell_offsets[cell + 1];
    const auto first = _market_signals.good_ids.begin() + begin;
    const auto last = _market_signals.good_ids.begin() + end;
    const auto it = std::lower_bound(first, last, good);
    return it != last && *it == good ? static_cast<int32_t>(it - _market_signals.good_ids.begin()) : -1;
}

void NativeEconomyRuntime::add_trade_active_key(int32_t market, int32_t good) {
    if (market < 0 || market >= market_store().market_count.get() || good < 0 ||
        good >= market_store().good_count.get()) return;
    const size_t matrix_size = static_cast<size_t>(market_store().market_count.get()) *
        static_cast<size_t>(market_store().good_count.get());
    if (_trade_active_key_present.size() != matrix_size) {
        _trade_active_key_present.assign(matrix_size, 0);
        for (const uint64_t existing : _trade_active_keys) {
            const int32_t existing_market = static_cast<int32_t>(existing >> 32);
            const int32_t existing_good = static_cast<int32_t>(existing & 0xffffffffU);
            if (existing_market < 0 || existing_market >= market_store().market_count.get() ||
                existing_good < 0 || existing_good >= market_store().good_count.get()) continue;
            _trade_active_key_present[market_store().index(existing_market, existing_good)] = 1;
        }
    }
    const size_t index = static_cast<size_t>(market_store().index(market, good));
    if (_trade_active_key_present[index] != 0) return;
    _trade_active_key_present[index] = 1;
    _trade_active_keys.push_back(
        (static_cast<uint64_t>(static_cast<uint32_t>(market)) << 32) |
        static_cast<uint32_t>(good));
}

} // namespace pk
