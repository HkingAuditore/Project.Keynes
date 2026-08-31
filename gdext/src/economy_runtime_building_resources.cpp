#include "economy_runtime.h"

#include <algorithm>
#include <cstdlib>

namespace pk {

int32_t NativeEconomyRuntime::building_resource_access_cells(
        int32_t cell, int32_t resource_id, int32_t *out_cells, int32_t capacity) const {
    if (out_cells == nullptr || capacity <= 0 || cell < 0 || cell >= _cell_count ||
        resource_id < 0 || resource_id >= static_cast<int32_t>(_resource_ids.size())) {
        return 0;
    }
    out_cells[0] = cell;
    return 1;
}

int64_t NativeEconomyRuntime::available_resource_amount(
        const ResourceAmount &item, int32_t cell) const {
    if (cell < 0 || cell >= _cell_count || item.resource_id < 0 ||
        item.resource_id >= static_cast<int32_t>(_resource_ids.size())) return 0;
    const size_t idx = static_cast<size_t>(item.resource_id) * _cell_count + cell;
    // Snapshots can be queried immediately after bootstrap, before the first
    // resource epoch has allocated all lanes. Treat an absent lane as zero
    // available capacity instead of indexing an uninitialised vector.
    if (idx >= _resource_snapshot.size()) return 0;
    const bool initialized = idx < _resource_lane_generation.size() &&
        _resource_lane_generation[idx] == _resource_current_generation;
    const int64_t remaining = std::max<int64_t>(0,
        initialized ? _resource_remaining[idx] : _resource_snapshot[idx]);
    // A capacity edge represents standing habitat/capacity. Only extract edges
    // draw down the renewable harvest budget shared by this cell's producers.
    if (item.mode != 0 || idx >= _resource_harvest_remaining.size())
        return remaining;
    if (initialized)
        return std::min(remaining,
            std::max<int64_t>(0, _resource_harvest_remaining[idx]));
    int64_t sat = 0;
    const int64_t harvest = resource_is_renewable(item.resource_id) &&
            _resource_safe_harvest_q16 > 0
        ? saturating_mul(renewable_safe_harvest(item.resource_id, cell),
              std::max<int64_t>(1, _epoch_days), sat)
        : remaining;
    return std::min(remaining, std::max<int64_t>(0, harvest));
}

void NativeEconomyRuntime::ensure_resource_lane(size_t idx) {
    if (idx >= _resource_snapshot.size() ||
        idx >= _resource_remaining.size() ||
        idx >= _resource_harvest_remaining.size() ||
        idx >= _resource_deltas.size() ||
        idx >= _resource_lane_generation.size() ||
        _resource_lane_generation[idx] == _resource_current_generation) {
        return;
    }
    _resource_lane_generation[idx] = _resource_current_generation;
    _resource_remaining[idx] = _resource_snapshot[idx];
    _resource_deltas[idx] = 0;
    const int32_t resource = _cell_count > 0
        ? static_cast<int32_t>(idx / static_cast<size_t>(_cell_count)) : -1;
    const int32_t cell = _cell_count > 0
        ? static_cast<int32_t>(idx % static_cast<size_t>(_cell_count)) : -1;
    _resource_harvest_remaining[idx] =
        resource_is_renewable(resource) && _resource_safe_harvest_q16 > 0
        ? saturating_mul(renewable_safe_harvest(resource, cell),
              std::max<int64_t>(1, _epoch_days), _saturation_count)
        : std::max<int64_t>(0, _resource_remaining[idx]);
    if (_production_result_sink != nullptr) {
        _production_result_sink->resource_touched_lanes.push_back(idx);
    } else {
        _resource_touched_lanes.push_back(idx);
    }
}

void NativeEconomyRuntime::consume_resource_amount(
        const ResourceAmount &item, int32_t cell, int64_t quantity) {
    if (cell < 0 || cell >= _cell_count || item.resource_id < 0 ||
        item.resource_id >= static_cast<int32_t>(_resource_ids.size())) return;
    const size_t idx = static_cast<size_t>(item.resource_id) * _cell_count + cell;
    ensure_resource_lane(idx);
    const int64_t taken = std::min<int64_t>(
        std::max<int64_t>(0, quantity), std::max<int64_t>(0, _resource_remaining[idx]));
    if (taken <= 0) return;
    _resource_remaining[idx] -= taken;
    if (item.mode == 0 && idx < _resource_harvest_remaining.size()) {
        _resource_harvest_remaining[idx] = std::max<int64_t>(0,
            _resource_harvest_remaining[idx] - taken);
    }
    _resource_deltas[idx] = saturating_sub(
        _resource_deltas[idx], taken, _saturation_count);
}

bool NativeEconomyRuntime::resource_is_renewable(int32_t resource_id) const {
    return resource_id >= 0 &&
        resource_id < static_cast<int32_t>(_resource_ecology_capacity.size()) &&
        resource_id < static_cast<int32_t>(_resource_ecology_growth_q16.size()) &&
        _resource_ecology_capacity[resource_id] > 0 &&
        _resource_ecology_growth_q16[resource_id] > 0;
}

int32_t NativeEconomyRuntime::resource_stock_density_q16(
        int32_t resource_id, int32_t cell) const {
    if (!resource_is_renewable(resource_id) || cell < 0 || cell >= _cell_count)
        return Q16_ONE;
    const size_t resource = static_cast<size_t>(resource_id);
    const size_t idx = resource * static_cast<size_t>(_cell_count) +
        static_cast<size_t>(cell);
    if (idx >= _resource_snapshot.size() ||
        resource >= _resource_ecology_capacity.size())
        return Q16_ONE;
    const int64_t remaining = idx < _resource_lane_generation.size() &&
            _resource_lane_generation[idx] == _resource_current_generation &&
            idx < _resource_remaining.size()
        ? std::max<int64_t>(0, _resource_remaining[idx])
        : std::max<int64_t>(0, _resource_snapshot[idx]);
    int64_t sat = 0;
    int64_t runtime_fit_q16 = Q16_ONE;
    if (resource < _resource_runtime_fit_weight_q16.size()) {
        const int64_t weight = std::clamp<int64_t>(
            _resource_runtime_fit_weight_q16[resource], 0, Q16_ONE);
        if (weight > 0 &&
            cell < static_cast<int32_t>(_environment_temperature_q16.size()) &&
            cell < static_cast<int32_t>(_environment_moisture_q16.size())) {
            const bool mean_temperature =
                resource < _resource_temperature_signal.size() &&
                _resource_temperature_signal[resource] == 1;
            const bool plant_water =
                resource < _resource_moisture_signal.size() &&
                _resource_moisture_signal[resource] == 1;
            const int64_t temperature = mean_temperature &&
                    cell < static_cast<int32_t>(
                        _environment_temperature_30d_q16.size())
                ? _environment_temperature_30d_q16[cell]
                : _environment_temperature_q16[cell];
            const int64_t moisture = plant_water &&
                    cell < static_cast<int32_t>(
                        _environment_plant_available_water_q16.size())
                ? _environment_plant_available_water_q16[cell]
                : _environment_moisture_q16[cell];
            const int64_t lo = resource < _resource_temp_lo_q16.size()
                ? _resource_temp_lo_q16[resource] : 0;
            const int64_t hi = resource < _resource_temp_hi_q16.size()
                ? _resource_temp_hi_q16[resource] : Q16_ONE;
            const int64_t normalized_temperature = hi > lo
                ? std::clamp<int64_t>(mul_div_sat(
                    temperature - lo, Q16_ONE, hi - lo, sat), 0, Q16_ONE)
                : 0;
            const int64_t temp_opt =
                _resource_climate_temp_opt_q16[resource];
            const int64_t temp_tol = std::max<int64_t>(
                1, _resource_climate_temp_tol_q16[resource]);
            const int64_t moisture_opt =
                _resource_climate_moisture_opt_q16[resource];
            const int64_t moisture_tol = std::max<int64_t>(
                1, _resource_climate_moisture_tol_q16[resource]);
            const int64_t temp_fit = Q16_ONE - std::clamp<int64_t>(
                mul_div_sat(std::llabs(normalized_temperature - temp_opt),
                    Q16_ONE, temp_tol, sat), 0, Q16_ONE);
            const int64_t moisture_fit = Q16_ONE - std::clamp<int64_t>(
                mul_div_sat(std::llabs(moisture - moisture_opt),
                    Q16_ONE, moisture_tol, sat), 0, Q16_ONE);
            const int64_t climate_fit = mul_div_sat(
                temp_fit, moisture_fit, Q16_ONE, sat);
            runtime_fit_q16 = Q16_ONE + mul_div_sat(
                climate_fit - Q16_ONE, weight, Q16_ONE, sat);
        }
    }
    const int64_t local_capacity = mul_div_sat(
        std::max<int64_t>(0, _resource_ecology_capacity[resource]),
        std::max<int64_t>(0, runtime_fit_q16), Q16_ONE, sat);
    if (local_capacity <= 0) return Q16_ONE;
    const int64_t density = std::clamp<int64_t>(mul_div_sat(
        remaining, Q16_ONE, local_capacity, sat), 0, Q16_ONE);
    return static_cast<int32_t>(remaining > 0 && density == 0 ? 1 : density);
}

int64_t NativeEconomyRuntime::renewable_safe_harvest(
        int32_t resource_id, int32_t cell) const {
    if (_resource_safe_harvest_q16 <= 0 || !resource_is_renewable(resource_id) ||
        cell < 0 || cell >= _cell_count) return 0;
    const size_t idx = static_cast<size_t>(resource_id) * _cell_count + cell;
    if (idx >= _resource_remaining.size() ||
        idx >= _resource_snapshot.size()) return 0;
    int64_t sat = 0;
    const int64_t capacity = _resource_ecology_capacity[resource_id];
    // Catalog capacity is a biome-wide ceiling, not the climate-adjusted local
    // carrying capacity. Retain a share of this cell's frozen stock instead of
    // applying a false global absolute floor to naturally sparse cells.
    const int64_t reserve_floor = mul_div_sat(
        std::max<int64_t>(0,
            idx < _resource_lane_generation.size() &&
                    _resource_lane_generation[idx] ==
                        _resource_current_generation
                ? _resource_remaining[idx] : _resource_snapshot[idx]),
        _resource_min_reserve_q16, Q16_ONE, sat);
    const int64_t remaining =
        idx < _resource_lane_generation.size() &&
                _resource_lane_generation[idx] == _resource_current_generation
            ? _resource_remaining[idx] : _resource_snapshot[idx];
    const int64_t harvestable_stock = std::max<int64_t>(
        0, remaining - reserve_floor);
    const int64_t biomass = std::min<int64_t>(capacity / 8, harvestable_stock);
    return mul_div_sat(mul_div_sat(biomass,
        _resource_ecology_growth_q16[resource_id], Q16_ONE,
        sat), _resource_safe_harvest_q16, Q16_ONE, sat);
}

} // namespace pk
