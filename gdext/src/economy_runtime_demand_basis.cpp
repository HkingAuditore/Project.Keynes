#include "economy_runtime.h"
#include "economy_cost_probe.h"
#include "parallel_dispatcher.h"

#include <algorithm>
#include <cstring>
#include <stdexcept>

namespace pk {

size_t NativeEconomyRuntime::demand_basis_row_width() const {
    return 2 * _variants.size() + 3 * _needs.size();
}

void NativeEconomyRuntime::clear_demand_basis_day() {
    for (const auto &slot : _demand_basis_cache.slots)
        _demand_basis_cache.cell_to_slot[slot.cell] = -1;
    _demand_basis_cache.slots.clear();
}

void NativeEconomyRuntime::register_demand_basis_cell(int32_t cell) {
    if (cell < 0 || cell >= _cell_count.get()) return;
    auto &cache = _demand_basis_cache;
    if (cache.cell_to_slot.empty())
        cache.cell_to_slot.assign(static_cast<size_t>(_cell_count.get()), -1);
    int32_t &slot = cache.cell_to_slot[cell];
    if (slot >= 0) return;

    const size_t next = cache.slots.size();
    const size_t width = demand_basis_row_width();
    if (width != 0) {
        const size_t slot_limit = std::min(
            static_cast<size_t>(_cell_count.get()), cache.values.max_size() / width);
        if (next >= slot_limit)
            throw std::length_error("demand_basis_cache_size");
        const size_t required = (next + 1) * width;
        if (required > cache.values.capacity()) {
            // Geometric growth amortizes allocation without reserving more rows
            // than the world can ever use.
            const size_t slots = std::clamp(
                2 * (cache.values.capacity() / width), next + 1, slot_limit);
            cache.values.reserve(slots * width);
        }
        if (required > cache.values.size())
            cache.values.resize(required);
    }
    cache.slots.push_back({cell, false});
    slot = static_cast<int32_t>(next);
}

void NativeEconomyRuntime::store_demand_basis_row(
        int32_t slot, const std::vector<int64_t> &variant_scores,
        const std::vector<int64_t> &variant_prices,
        const std::vector<int64_t> &need_score_sums,
        const std::vector<int64_t> &need_composites,
        const std::vector<int64_t> &need_environment) {
    auto &cache = _demand_basis_cache;
    auto dest = cache.values.begin() + static_cast<size_t>(slot) * demand_basis_row_width();
    dest = std::copy(variant_scores.begin(), variant_scores.end(), dest);
    dest = std::copy(variant_prices.begin(), variant_prices.end(), dest);
    dest = std::copy(need_score_sums.begin(), need_score_sums.end(), dest);
    dest = std::copy(need_composites.begin(), need_composites.end(), dest);
    std::copy(need_environment.begin(), need_environment.end(), dest);
    cache.slots[slot].ready = true;
}

void NativeEconomyRuntime::build_demand_basis_cached(
        int32_t cell, int32_t market, const EnvironmentSample &sample,
        std::vector<int64_t> &variant_scores, std::vector<int64_t> &variant_prices,
        std::vector<int64_t> &need_score_sums, std::vector<int64_t> &need_composites,
        std::vector<int64_t> &need_environment, int64_t &sat) {
    const auto &cache = _demand_basis_cache;
    const int32_t slot = cell >= 0 && static_cast<size_t>(cell) < cache.cell_to_slot.size()
        ? cache.cell_to_slot[cell] : -1;
    if (slot >= 0 && cache.slots[slot].ready) {
        auto source = cache.values.cbegin() + static_cast<size_t>(slot) * demand_basis_row_width();
        auto read_column = [&](std::vector<int64_t> &column, size_t count) {
            const auto end = source + count;
            column.assign(source, end);
            source = end;
        };
        read_column(variant_scores, _variants.size());
        read_column(variant_prices, _variants.size());
        read_column(need_score_sums, _needs.size());
        read_column(need_composites, _needs.size());
        read_column(need_environment, _needs.size());
        return;
    }

    // A worker can always compute a missing row in its own scratch. Only the
    // economy owner may register keys or grow the backing storage.
    build_demand_basis(market, sample, variant_scores, variant_prices,
                       need_score_sums, need_composites, need_environment, sat);
    if (slot >= 0)
        store_demand_basis_row(slot, variant_scores, variant_prices,
                              need_score_sums, need_composites, need_environment);
}

godot::Dictionary NativeEconomyRuntime::demand_basis_cache_report() const {
    const auto &cache = _demand_basis_cache;
    const size_t width = demand_basis_row_width();
    godot::Dictionary out;
    out["sample_day"] = _sample_day;
    out["allocated_slots"] = static_cast<int64_t>(
        width > 0 ? cache.values.capacity() / width : cache.slots.capacity());
    out["registered_cells"] = static_cast<int64_t>(cache.slots.size());
    out["valid_cells"] = static_cast<int64_t>(std::count_if(
        cache.slots.begin(), cache.slots.end(),
        [](const DemandBasisCache::Slot &slot) { return slot.ready; }));
    out["values_bytes"] = cache.values_bytes();
    out["index_bytes"] = cache.index_bytes();
    out["variant_count"] = static_cast<int64_t>(_variants.size());
    out["need_count"] = static_cast<int64_t>(_needs.size());
    return out;
}

void NativeEconomyRuntime::prepare_due_demand_basis_cache() {
    EconomyCostProbe cost("demand_basis.prepare", _current_day.get(), _epoch_building_cells.size());
    const int32_t cell_count = static_cast<int32_t>(_epoch_building_cells.size());
    if (cell_count <= 0) return;
    for (const int32_t cell : _epoch_building_cells)
        register_demand_basis_cell(cell);
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
            // Refresh the wage-time row after employment, as before.
            store_demand_basis_row(_demand_basis_cache.cell_to_slot[cell],
                variant_scores, variant_prices, need_score_sums, need_composites,
                need_environment);
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
