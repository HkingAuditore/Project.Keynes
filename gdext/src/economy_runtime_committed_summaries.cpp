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

void NativeEconomyRuntime::rebuild_committed_summaries() {
    _committed_cells.assign(_cell_count.get(), {});
    for (int32_t cell = 0; cell < _cell_count.get(); ++cell) {
        _committed_cells[cell] = build_cell_summary(cell);
    }
    _staging_cells = _committed_cells;
    _staging_touched_cells.clear();
    _staging_cell_generation.assign(_committed_cells.size(), 0);
    _staging_current_generation = 0;
}

NativeEconomyRuntime::CellSummary NativeEconomyRuntime::build_cell_summary(int32_t cell) const {
    CellSummary summary;
    int64_t satisfaction_weighted = 0;
    population_store().for_each_in_cell(cell, [&](int32_t slot) {
        ++summary.cohort_count;
        summary.population += population_store().population[slot];
        summary.funds += population_store().funds[slot];
        summary.epoch_income += population_store().epoch_income[slot];
        summary.epoch_expense += population_store().epoch_expense[slot];
        satisfaction_weighted += static_cast<int64_t>(population_store().needs_satisfaction[slot]) *
                                 population_store().population[slot];
    });
    summary.satisfaction_q16 = summary.population > 0
                                   ? static_cast<int32_t>(std::clamp<int64_t>(
                                         satisfaction_weighted / summary.population, 0, Q16_ONE - 1))
                                   : static_cast<int32_t>(Q16_ONE - 1);
    return summary;
}

void NativeEconomyRuntime::stage_cell_summary(
        int32_t cell, const CellSummary &summary) {
    if (cell < 0 || cell >= static_cast<int32_t>(_staging_cells.size()))
        return;
    // Worker tasks must find this already sized; growing a shared vector from
    // several threads is exactly the race this sink split avoids.
    if (_staging_cell_generation.size() != _staging_cells.size())
        _staging_cell_generation.assign(_staging_cells.size(), 0);
    if (_staging_cell_generation[cell] != _staging_current_generation) {
        _staging_cell_generation[cell] = _staging_current_generation;
        if (_staging_touched_sink != nullptr)
            _staging_touched_sink->push_back(cell);
        else
            _staging_touched_cells.push_back(cell);
    }
    _staging_cells[cell] = summary;
}

bool NativeEconomyRuntime::rebuild_market_cell_ranges(std::string &error) {
    if (market_store().market_count.get() <= 0 ||
        market_store().cell_to_market.size() != static_cast<size_t>(_cell_count.get())) {
        error = "market_cell_mapping_shape_invalid";
        return false;
    }
    _market_cell_offsets.assign(market_store().market_count.get() + 1, 0);
    for (int32_t cell = 0; cell < _cell_count.get(); ++cell) {
        const int32_t market = market_store().cell_to_market[cell];
        if (market < 0 || market >= market_store().market_count.get()) {
            error = "cell_to_market_entry_invalid";
            return false;
        }
        ++_market_cell_offsets[market + 1];
    }
    for (int32_t market = 0; market < market_store().market_count.get(); ++market) {
        _market_cell_offsets[market + 1] += _market_cell_offsets[market];
    }
    _market_cells.assign(_cell_count.get(), -1);
    std::vector<int32_t> cursor(_market_cell_offsets.begin(), _market_cell_offsets.end() - 1);
    for (int32_t cell = 0; cell < _cell_count.get(); ++cell) {
        const int32_t market = market_store().cell_to_market[cell];
        _market_cells[cursor[market]++] = cell;
    }
    return true;
}

} // namespace pk
