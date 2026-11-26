#include "economy_record_source.h"
#include "economy_runtime.h"
#include <algorithm>
#include <cmath>
#include <limits>

namespace pk {
using SummaryRow = EconomyCsvRecorder::SummaryRow;
using CohortRow = EconomyCsvRecorder::CohortRow;
using BuildingRow = EconomyCsvRecorder::BuildingRow;
using ResourceRow = EconomyCsvRecorder::ResourceRow;
using MarketRow = EconomyCsvRecorder::MarketRow;
using CommonCell = EconomyCsvRecorder::CommonCell;
constexpr auto DIM_COUNT = EconomyCsvRecorder::DIM_COUNT;
constexpr auto SUMMARY = EconomyCsvRecorder::SUMMARY;
constexpr auto COHORTS = EconomyCsvRecorder::COHORTS;
constexpr auto BUILDINGS = EconomyCsvRecorder::BUILDINGS;
constexpr auto RESOURCES = EconomyCsvRecorder::RESOURCES;
constexpr auto MARKET = EconomyCsvRecorder::MARKET;

bool EconomyRecordSource::configure(const Config &config, const NativeEconomyRuntime &runtime,
        std::array<Batch, 2> &_buffers, std::string &error) {
    if (!runtime._configured || !runtime._bootstrapped || runtime._fatal) {
        error = "economy_not_ready";
        return false;
    }
    if (config.q.size() != static_cast<size_t>(runtime._cell_count.get()) ||
        config.r.size() != config.q.size() || config.s.size() != config.q.size()) {
        error = "coordinate_size_mismatch";
        return false;
    }
    bool any = false;
    for (int32_t i = 0; i < DIM_COUNT; ++i) {
        if (!config.enabled[i]) continue;
        any = true;
        if (config.paths[i].empty()) {
            error = "enabled_path_missing";
            return false;
        }
    }
    if (!any) {
        error = "no_dimensions_enabled";
        return false;
    }
    if (config.resource_slot_ids.size() != config.resource_ids.size()) {
        error = "resource_config_size_mismatch";
        return false;
    }

    _config = config;
    _config.cell_stride = std::max(1, _config.cell_stride);
    _config.max_rows = std::max<int64_t>(1, _config.max_rows);
    if (!_config.cell_indices.empty()) {
        std::sort(_config.cell_indices.begin(), _config.cell_indices.end());
        _config.cell_indices.erase(
            std::unique(_config.cell_indices.begin(), _config.cell_indices.end()),
            _config.cell_indices.end());
        for (const int32_t cell : _config.cell_indices) {
            if (cell < 0 || cell >= runtime._cell_count.get()) {
                error = "cell_index_out_of_range";
                return false;
            }
        }
        _sample_cells = _config.cell_indices;
    } else {
        _sample_cells.clear();
        _sample_cells.reserve(static_cast<size_t>(
            (runtime._cell_count.get() + _config.cell_stride - 1) / _config.cell_stride));
        for (int32_t cell = 0; cell < runtime._cell_count.get(); cell += _config.cell_stride)
            _sample_cells.push_back(cell);
    }
    _sample_cell_positions.assign(static_cast<size_t>(runtime._cell_count.get()), -1);
    for (int32_t i = 0; i < static_cast<int32_t>(_sample_cells.size()); ++i)
        _sample_cell_positions[_sample_cells[i]] = i;
    _resource_runtime_indices.assign(_config.resource_ids.size(), -1);
    for (size_t resource = 0; resource < _config.resource_ids.size(); ++resource) {
        const auto it = std::lower_bound(runtime._resource_ids.begin(),
                                         runtime._resource_ids.end(),
                                         _config.resource_ids[resource]);
        if (it == runtime._resource_ids.end() || *it != _config.resource_ids[resource]) {
            error = "resource_id_not_in_runtime";
            return false;
        }
        _resource_runtime_indices[resource] = static_cast<int32_t>(
            std::distance(runtime._resource_ids.begin(), it));
    }
    const size_t resource_history_size = static_cast<size_t>(runtime._cell_count.get()) *
        _config.resource_ids.size();
    _previous_resource_reserve.assign(resource_history_size, 0.0f);
    _pending_resource_artificial.assign(resource_history_size, 0);
    _resource_history_valid.assign(resource_history_size, uint8_t{0});
    _good_ids = runtime._good_ids;
    _good_category_ids = runtime._good_category_ids;
    _good_storage_modes = runtime._good_storage_modes;
    const size_t sampled_cells = _sample_cells.size();
    size_t sampled_cohorts = 0;
    size_t sampled_buildings = 0;
    for (const int32_t cell : _sample_cells) {
        if (_config.enabled[COHORTS])
            runtime.population_store().for_each_in_cell(cell, [&](int32_t) { ++sampled_cohorts; });
        if (_config.enabled[BUILDINGS]) {
            if (runtime._building_cell_offsets.size() ==
                static_cast<size_t>(runtime._cell_count.get() + 1)) {
                sampled_buildings += static_cast<size_t>(
                    runtime._building_cell_offsets[cell + 1] -
                    runtime._building_cell_offsets[cell]);
            }
            for (const auto pending : runtime.pending_construction())
                if (pending.cell == cell) ++sampled_buildings;
        }
    }
    for (Batch &batch : _buffers) {
        batch.clear_rows();
        batch.summary.reserve(_config.enabled[SUMMARY] ? 1 : 0);
        batch.cohorts.reserve(_config.enabled[COHORTS] ? sampled_cohorts : 0);
        batch.buildings.reserve(_config.enabled[BUILDINGS] ? sampled_buildings : 0);
        batch.resources.reserve(_config.enabled[RESOURCES]
            ? sampled_cells * _config.resource_ids.size() : 0);
        batch.market.reserve(_config.enabled[MARKET]
            ? sampled_cells * static_cast<size_t>(runtime.market_store().good_count.get()) : 0);
        const size_t trade_cells = _config.enabled[MARKET]
            ? sampled_cells * runtime.market_store().good_count.get() : 0;
        batch.scratch_trade_inbound.reserve(trade_cells);
        batch.scratch_trade_outbound.reserve(trade_cells);
    }
    return true;
}

int64_t EconomyRecordSource::committed_epoch(const NativeEconomyRuntime &runtime) {
    return runtime._bootstrapped && !runtime._epoch_active && !runtime._fatal && runtime._commit_day >= 0
        ? runtime._epoch_id.get() : -1;
}
int64_t EconomyRecordSource::projected_rows(const NativeEconomyRuntime &runtime) const {
    int64_t rows = _config.enabled[SUMMARY] ? 1 : 0;
    for (const int32_t cell : _sample_cells) {
        if (_config.enabled[COHORTS]) {
            runtime.population_store().for_each_in_cell(cell, [&](int32_t) { ++rows; });
        }
        if (_config.enabled[BUILDINGS]) {
            if (runtime._building_cell_offsets.size() == static_cast<size_t>(runtime._cell_count.get() + 1)) {
                for (int32_t i = runtime._building_cell_offsets[cell];
                     i < runtime._building_cell_offsets[cell + 1]; ++i) {
                    if (runtime.buildings_store().group_units[i] > 0) ++rows;
                }
            }
            for (const auto pending : runtime.pending_construction())
                if (pending.cell == cell) ++rows;
            if (runtime._investment_diagnostic_cell == cell) {
                rows += static_cast<int64_t>(
                    runtime._investment_diagnostics.size());
            }
            if (runtime._employment_diagnostic_cell == cell) {
                rows += static_cast<int64_t>(
                    runtime._employment_diagnostics.size());
            }
        }
        if (_config.enabled[MARKET]) rows += runtime.market_store().good_count.get();
    }
    if (_config.enabled[RESOURCES]) {
        rows += static_cast<int64_t>(_sample_cells.size()) *
                static_cast<int64_t>(_config.resource_ids.size());
    }
    return rows;
}

void EconomyRecordSource::worker_resources(const NativeEconomyRuntime &runtime,
        std::vector<std::vector<float>> &lanes) const {
    // Worker must read its authoritative resource ledger, never Godot slots.
    lanes.resize(_resource_runtime_indices.size());

    const auto &stock = runtime.resource_stock_lanes();
    for (size_t r = 0; r < lanes.size(); ++r) {
        const int32_t source = _resource_runtime_indices[r];
        if (source < 0 || (static_cast<size_t>(source) + 1) * runtime._cell_count.get() > stock.size()) continue;
        lanes[r].resize(runtime._cell_count.get());
        for (int32_t c = 0; c < runtime._cell_count.get(); ++c)
            lanes[r][c] = static_cast<float>(stock[static_cast<size_t>(source) * runtime._cell_count.get() + c]) /
                static_cast<float>(NativeEconomyRuntime::GOODS_SCALE);
    }
}

} // namespace pk
