#include "economy_cost_probe.h"
#include "economy_runtime.h"
#include "economy_hash.h"
#include "runtime_switch_registry.h"
#include "economy_graph_kernels.h"
#include "economy_graph_live_ops.h"
#include "economy_graph_stage_dispatch.h"
#include "runtime_economy_pod.h"
#include "native_simulation_host.h"
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

bool NativeEconomyRuntime::capture_worker_day_input(
        const RuntimeEconomyDayInput &input, std::string &error) {
    const size_t count = static_cast<size_t>(std::max(0, _cell_count.get()));
    if (_epoch_active || input.day < 0 || input.cell_count != count ||
        input.reserves.size() != _resource_ids.size() ||
        input.changes.size() != input.reserves.size() ||
        input.neighbors.size() != count * 6) {
        error = "economy_worker_input_shape_invalid";
        return false;
    }
    for (size_t i = 0; i < input.fields.size(); ++i) {
        if (input.fields[i].size() != count) {
            error = "economy_worker_input_field_missing";
            return false;
        }
    }
    for (size_t i = 0; i < input.geography.size(); ++i) {
        if (input.geography[i].size() != count &&
            !(i == 5 && !input.fog_solved && input.geography[i].empty())) {
            error = "economy_worker_input_geography_missing";
            return false;
        }
    }
    std::vector<const float *> reserves, changes;
    for (size_t r = 0; r < input.reserves.size(); ++r) {
        const auto &stock = input.reserves[r];
        const auto &change = input.changes[r];
        if ((!stock.empty() && stock.size() != count) ||
            (!change.empty() && change.size() != count) ||
            (!stock.empty() && change.empty())) {
            error = "economy_worker_input_resource_shape_invalid";
            return false;
        }
        reserves.push_back(stock.empty() ? nullptr : stock.data());
        changes.push_back(change.empty() ? nullptr : change.data());
    }
    if (needs_environment_capture(input.day)) {
        if (input.climate_u8[0].size() != count ||
            input.climate_u8[1].size() != count) {
            error = "economy_environment_snapshot_invalid";
            return false;
        }
        if (!capture_environment(input.day, input.fields[0].data(), input.fields[1].data(),
                input.fields[2].data(), input.fields[3].data(), input.fields[4].data(),
                input.fields[5].data(), input.fields[6].data(),
                input.fields[8].data(), input.climate_u8[0].data(),
                input.climate_u8[1].data(), _cell_count.get(), error)) return false;
        if ((input.fog_solved || !trade_visibility_manual()) &&
            !capture_trade_visibility(input.geography[5].empty() ? nullptr : input.geography[5].data(),
                static_cast<int32_t>(input.geography[5].size()), input.fog_solved, true, error)) return false;
    }
    if (needs_building_context_capture(input.day) &&
        !capture_building_context(input.day, input.fields[7].data(),
            input.geography[0].data(), input.geography[1].data(), input.geography[2].data(),
            input.geography[3].data(), input.geography[4].data(), input.neighbors.data(),
            reserves, changes, _cell_count.get(), error)) return false;
    return !worker_natural_resources_configured() ||
        advance_worker_resource_reserves(input, error);
}

void NativeEconomyRuntime::configure_worker_natural_resources(
        std::vector<WorkerNaturalResource> resources) {
    _worker_natural_resources = std::move(resources);
    _worker_resource_seeded = false;
}

void NativeEconomyRuntime::mark_worker_resource_mirror_cell(int32_t cell) {
    if (cell < 0 || static_cast<size_t>(cell) >= _worker_resource_mirror_mark.size() ||
        _worker_resource_mirror_mark[static_cast<size_t>(cell)] != 0) return;
    _worker_resource_mirror_mark[static_cast<size_t>(cell)] = 1;
    _worker_resource_mirror_cells.push_back(cell);
}

void NativeEconomyRuntime::take_worker_resource_mirror_cells(std::vector<int32_t> &out) {
    out.swap(_worker_resource_mirror_cells);
    _worker_resource_mirror_cells.clear();
    for (const int32_t cell : out)
        _worker_resource_mirror_mark[static_cast<size_t>(cell)] = 0;
    std::sort(out.begin(), out.end());
}

void NativeEconomyRuntime::write_worker_resource_stock(size_t lane) {
    if (lane >= resource_stock_lanes().size() || lane >= _worker_resource_reserve.size()) return;
    const float reserve_f = _worker_resource_reserve[lane];
    const float change_f = _worker_resource_extra[lane];
    const double reserve = std::isfinite(reserve_f) ? static_cast<double>(reserve_f) : 0.0;
    const double pending = std::isfinite(change_f) ? static_cast<double>(change_f) : 0.0;
    const double value = std::max(0.0, reserve + std::min(0.0, pending));
    resource_stock_lanes().write_scalar(lane, static_cast<int64_t>(std::min<double>(
        value * static_cast<double>(GOODS_SCALE),
        static_cast<double>(std::numeric_limits<int64_t>::max()))));
}

void NativeEconomyRuntime::fold_worker_resource_deltas() {
    if (!_worker_resource_seeded) return;
    const int32_t count = _cell_count.get();
    if (count <= 0) return;
    std::vector<size_t> touched = _resource_touched_lanes;
    std::sort(touched.begin(), touched.end());
    touched.erase(std::unique(touched.begin(), touched.end()), touched.end());
    for (const size_t lane : touched) {
        if (lane >= resource_delta_lanes().size() || lane >= _worker_resource_extra.size())
            continue;
        const int64_t delta = resource_delta_lanes()[lane];
        if (delta == 0) continue;
        _worker_resource_extra[lane] += static_cast<float>(delta) /
            static_cast<float>(GOODS_SCALE);
        const size_t resource = lane / static_cast<size_t>(count);
        if (resource < _worker_resource_extra_dirty.size())
            _worker_resource_extra_dirty[resource] = 1;
        write_worker_resource_stock(lane);
        mark_worker_resource_mirror_cell(static_cast<int32_t>(lane % static_cast<size_t>(count)));
    }
}

bool NativeEconomyRuntime::capture_environment(int64_t day_index, const float *temperature,
                                               const float *temperature_30d,
                                               const float *moisture,
                                               const float *plant_available_water,
                                               const float *precipitation,
                                               const float *snow_cover,
                                               const float *weather_intensity,
                                               const float *temperature_365d,
                                               const uint8_t *weather_type,
                                               const uint8_t *cover, int32_t count,
                                               std::string &error) {
    if (!_configured || count != _cell_count.get() || temperature == nullptr ||
        temperature_30d == nullptr || moisture == nullptr || plant_available_water == nullptr ||
        precipitation == nullptr || snow_cover == nullptr ||
        weather_intensity == nullptr || temperature_365d == nullptr ||
        weather_type == nullptr || cover == nullptr) {
        error = "economy_environment_snapshot_invalid";
        return false;
    }
    auto quantize = [](float value) -> int32_t {
        if (!std::isfinite(value)) return 0;
        return static_cast<int32_t>(std::clamp<int64_t>(
            static_cast<int64_t>(std::llround(std::clamp(value, 0.0f, 1.0f) * Q16_ONE)),
            0, Q16_ONE));
    };
    for (int32_t i = 0; i < count; ++i) {
        if (weather_type[i] > 7 || cover[i] > 6) {
            error = "economy_environment_snapshot_invalid";
            return false;
        }
    }
    _environment_temperature_q16.resize(count);
    _environment_temperature_30d_q16.resize(count);
    _environment_moisture_q16.resize(count);
    _environment_plant_available_water_q16.resize(count);
    _environment_precipitation_q16.resize(count);
    _environment_snow_q16.resize(count);
    _environment_weather_q16.resize(count);
    _cell_temperature_annual_q16.resize(count);
    _cell_temperature_anomaly_q16.resize(count);
    _cell_hazard_today_mask.resize(count);
    _cell_dry_streak_days.resize(count);
    _cell_days_since_hazard.resize(count);
    _cell_previous_hazard_mask.resize(count);
    _cell_weather_type.resize(count);
    _cell_cover.resize(count);
    if (_cell_previous_precipitation_q16.size() != static_cast<size_t>(count))
        _cell_previous_precipitation_q16.assign(static_cast<size_t>(count), 0);
    if (_cell_rain_event_q16.size() != static_cast<size_t>(count))
        _cell_rain_event_q16.assign(static_cast<size_t>(count), 0);
    uint64_t hash = 1469598103934665603ULL;
    auto mix = [&](uint32_t value) {
        for (int32_t b = 0; b < 4; ++b) {
            hash ^= static_cast<uint8_t>((value >> (b * 8)) & 0xffU);
            hash *= 1099511628211ULL;
        }
    };
    // Mirrors `SNOW_FREEZE_T` in scripts/weather/weather_system.gd.
    constexpr float SNOW_FREEZE_T = 0.24f;
    for (int32_t i = 0; i < count; ++i) {
        _environment_temperature_q16.write_scalar(i, quantize(temperature[i]), market_mutation_sink());
        _environment_temperature_30d_q16.write_scalar(i, quantize(temperature_30d[i]), market_mutation_sink());
        _environment_moisture_q16.write_scalar(i, quantize(moisture[i]), market_mutation_sink());
        _environment_plant_available_water_q16.write_scalar(i, quantize(plant_available_water[i]), market_mutation_sink());
        _environment_precipitation_q16.write_scalar(i, quantize(precipitation[i]), market_mutation_sink());
        _environment_snow_q16.write_scalar(i, quantize(snow_cover[i]), market_mutation_sink());
        _environment_weather_q16.write_scalar(i, quantize(weather_intensity[i]), market_mutation_sink());
        _cell_temperature_annual_q16.write_scalar(
            i, quantize(temperature_365d[i]), market_mutation_sink());
        _cell_temperature_anomaly_q16.write_scalar(i,
            _environment_temperature_q16[i] -
                _environment_temperature_30d_q16[i],
            market_mutation_sink());
        _cell_weather_type.write_scalar(i, weather_type[i], market_mutation_sink());
        _cell_cover.write_scalar(i, cover[i], market_mutation_sink());
        // Preserve yesterday's committed hazard before replacing today's
        // derived mask. `advance_climate_day_columns` consumes both lanes.
        _cell_previous_hazard_mask.write_scalar(
            i, _cell_hazard_today_mask[i], market_mutation_sink());
        const int32_t previous = _cell_previous_precipitation_q16[
            static_cast<size_t>(i)];
        const int32_t current = _environment_precipitation_q16[i];
        constexpr int32_t RAIN_EVENT_THRESHOLD_Q16 = Q16_ONE / 4;
        const int32_t threshold =
            i < static_cast<int32_t>(_epoch_cell_rain_event_threshold_q16.size())
                ? std::max(1, _epoch_cell_rain_event_threshold_q16[
                    static_cast<size_t>(i)])
                : RAIN_EVENT_THRESHOLD_Q16;
        _cell_rain_event_q16[static_cast<size_t>(i)] =
            (current >= threshold && current > previous)
                ? static_cast<int32_t>(Q16_ONE) : 0;
        _cell_previous_precipitation_q16[static_cast<size_t>(i)] = current;
        const bool rain_event = _cell_rain_event_q16[static_cast<size_t>(i)] != 0;
        int32_t hazard_mask = 0;
        if (cover[i] == 5) hazard_mask |= 1 << 0; // flooding
        if (weather_type[i] == 4) hazard_mask |= 1 << 1; // drought
        if (weather_type[i] == 3 ||
            (temperature[i] < SNOW_FREEZE_T &&
             temperature_30d[i] >= SNOW_FREEZE_T))
            hazard_mask |= 1 << 2; // blizzard
        if (weather_type[i] == 6) hazard_mask |= 1 << 3; // heatwave
        _cell_hazard_today_mask.write_scalar(
            i, hazard_mask, market_mutation_sink());
        mix(static_cast<uint32_t>(_environment_temperature_q16[i]));
        mix(static_cast<uint32_t>(_environment_temperature_30d_q16[i]));
        mix(static_cast<uint32_t>(_environment_moisture_q16[i]));
        mix(static_cast<uint32_t>(_environment_plant_available_water_q16[i]));
        mix(static_cast<uint32_t>(_environment_precipitation_q16[i]));
        mix(static_cast<uint32_t>(_environment_snow_q16[i]));
        mix(static_cast<uint32_t>(_environment_weather_q16[i]));
    }
    _environment_day = day_index;
    _environment_hash = static_cast<int64_t>((hash & 0x7fffffffffffffffULL) | 1ULL);
    return true;
}

bool NativeEconomyRuntime::advance_climate_day_columns(std::string &error) {
    const size_t cells = static_cast<size_t>(std::max(0, _cell_count.get()));
    if (_environment_day.get() < 0 ||
        _cell_rain_event_q16.size() != cells ||
        _cell_hazard_today_mask.size() != cells ||
        _cell_dry_streak_days.size() != cells ||
        _cell_days_since_hazard.size() != cells ||
        _cell_previous_hazard_mask.size() != cells) {
        error = "economy_environment_snapshot_invalid";
        return false;
    }
    constexpr int32_t MAX_CLIMATE_STREAK_DAYS = 3650;
    for (size_t cell = 0; cell < cells; ++cell) {
        const bool rain_event = _cell_rain_event_q16[cell] != 0;
        const int32_t dry_streak = rain_event
            ? 0 : std::min(MAX_CLIMATE_STREAK_DAYS,
                _cell_dry_streak_days[static_cast<int32_t>(cell)] + 1);
        _cell_dry_streak_days.write_scalar(
            static_cast<int32_t>(cell), dry_streak, market_mutation_sink());
        const bool hazard_today = _cell_hazard_today_mask[cell] != 0;
        const int32_t days_since_hazard = hazard_today
            ? 0 : std::min(MAX_CLIMATE_STREAK_DAYS,
                _cell_days_since_hazard[static_cast<int32_t>(cell)] + 1);
        _cell_days_since_hazard.write_scalar(
            static_cast<int32_t>(cell), days_since_hazard,
            market_mutation_sink());
    }
    return true;
}

bool NativeEconomyRuntime::capture_building_context(
        int64_t day_index, const float *elevation, const uint8_t *terrain,
        const uint8_t *landform, const uint8_t *vegetation, const uint8_t *is_water,
        const uint8_t *has_river, const int32_t *neighbor_indices,
        const std::vector<const float *> &resources,
        const std::vector<const float *> &resource_changes,
        int32_t count, std::string &error) {
    if (!_configured || count != _cell_count.get() ||
        resources.size() != _resource_ids.size()) {
        error = "building_context_snapshot_invalid";
        return false;
    }
    auto quantize_q16 = [](float value) -> int32_t {
        if (!std::isfinite(value)) return 0;
        const double scaled = static_cast<double>(value) * static_cast<double>(Q16_ONE);
        return static_cast<int32_t>(std::clamp<double>(
            std::llround(scaled), std::numeric_limits<int32_t>::min(),
            std::numeric_limits<int32_t>::max()));
    };
    _building_elevation_q16.resize(count);
    _building_terrain.resize(count);
    _building_landform.resize(count);
    _building_vegetation.resize(count);
    _building_is_water.resize(count);
    _building_has_river.resize(count);
    _building_neighbors.assign(static_cast<size_t>(count) * 6, -1);
    for (int32_t cell = 0; cell < count; ++cell) {
        _building_elevation_q16[cell] = elevation != nullptr ? quantize_q16(elevation[cell]) : 0;
        _building_terrain[cell] = terrain != nullptr ? terrain[cell] : 0;
        _building_landform[cell] = landform != nullptr ? landform[cell] : 0;
        _building_vegetation[cell] = vegetation != nullptr ? vegetation[cell] : 0;
        _building_is_water[cell] = is_water != nullptr ? is_water[cell] : 0;
        _building_has_river[cell] = has_river != nullptr ? has_river[cell] : 0;
        if (neighbor_indices != nullptr) {
            for (int32_t direction = 0; direction < 6; ++direction) {
                const int32_t neighbor = neighbor_indices[cell * 6 + direction];
                _building_neighbors[static_cast<size_t>(cell) * 6 + direction] =
                    neighbor >= 0 && neighbor < count && neighbor != cell ? neighbor : -1;
            }
        }
    }
    if (resource_changes.size() != resources.size()) {
        error = "building_resource_change_shape_invalid";
        return false;
    }
    const size_t expected_resource_lanes =
        static_cast<size_t>(count) * resources.size();
    const bool preserve_restored_stock =
        (_resource_stock_restored_pending_capture || _worker_resource_seeded) &&
        resource_stock_lanes().size() == expected_resource_lanes;
    if (!preserve_restored_stock) {
        resource_stock_lanes().assign(expected_resource_lanes, 0);
        for (size_t r = 0; r < resources.size(); ++r) {
            const float *src = resources[r];
            const float *change = resource_changes[r];
            if (src == nullptr) continue;
            for (int32_t cell = 0; cell < count; ++cell) {
                const double reserve = std::isfinite(src[cell])
                    ? static_cast<double>(src[cell]) : 0.0;
                const double pending = change != nullptr && std::isfinite(change[cell])
                    ? static_cast<double>(change[cell]) : 0.0;
                const double value = std::max(0.0, reserve + std::min(0.0, pending));
                resource_stock_lanes().write_scalar(r * static_cast<size_t>(count) + cell,
                    static_cast<int64_t>(std::min<double>(
                        value * static_cast<double>(GOODS_SCALE),
                        static_cast<double>(std::numeric_limits<int64_t>::max()))));
            }
        }
    }
    _building_context_day = day_index;
    return true;
}

bool NativeEconomyRuntime::drain_building_resource_deltas(
        std::vector<size_t> &out_lanes, std::vector<int64_t> &out_deltas) {
    if (!_resource_deltas_ready) return false;
    for (const size_t index : _last_published_resource_touched_lanes) {
        if (index < _last_published_resource_deltas.size())
            _last_published_resource_deltas[index] = 0;
    }
    _last_published_resource_touched_lanes.clear();
    _last_published_resource_touched_lanes.reserve(
        _resource_touched_lanes.size());
    out_lanes.clear();
    out_deltas.clear();
    out_lanes.reserve(_resource_touched_lanes.size());
    out_deltas.reserve(_resource_touched_lanes.size());
    for (const size_t index : _resource_touched_lanes) {
        if (index >= resource_delta_lanes().size() ||
            index >= _last_published_resource_deltas.size() ||
            resource_delta_lanes()[index] == 0) continue;
        _last_published_resource_deltas[index] = resource_delta_lanes()[index];
        _last_published_resource_touched_lanes.push_back(index);
        out_lanes.push_back(index);
        out_deltas.push_back(resource_delta_lanes()[index]);
    }
    _resource_deltas_ready = false;
    return true;
}

int32_t NativeEconomyRuntime::sample_environment_curve(int32_t curve_id, int32_t cell) const {
    if (curve_id < 0) return Q16_ONE;
    if (curve_id >= static_cast<int32_t>(_environment_curves.size()) || cell < 0 ||
        cell >= _cell_count.get()) return 0;
    return sample_environment_curve(curve_id, environment_sample_for_cell(cell));
}

int32_t NativeEconomyRuntime::sample_environment_curve(
        int32_t curve_id, const EnvironmentSample &sample) const {
    if (curve_id < 0) return Q16_ONE;
    if (curve_id >= static_cast<int32_t>(_environment_curves.size())) return 0;
    const EnvironmentCurve &curve = _environment_curves[curve_id];
    int32_t signal = 0;
    switch (curve.signal_id) {
        case 0: signal = sample.temperature_q16; break;
        case 1: signal = sample.moisture_q16; break;
        case 2: signal = sample.snow_q16; break;
        case 3: signal = sample.weather_q16; break;
        default: return 0;
    }
    const int64_t scaled = static_cast<int64_t>(std::clamp(signal, 0, static_cast<int32_t>(Q16_ONE))) *
                           (ENV_CURVE_SAMPLES - 1);
    const int32_t lo = std::min(ENV_CURVE_SAMPLES - 1,
                                static_cast<int32_t>(scaled / Q16_ONE));
    const int32_t hi = std::min(ENV_CURVE_SAMPLES - 1, lo + 1);
    const int64_t frac = scaled - static_cast<int64_t>(lo) * Q16_ONE;
    return static_cast<int32_t>(curve.values_q16[lo] +
        ((static_cast<int64_t>(curve.values_q16[hi] - curve.values_q16[lo]) * frac) >> 16));
}

NativeEconomyRuntime::EnvironmentSample NativeEconomyRuntime::environment_sample_for_cell(
        int32_t cell) const {
    EnvironmentSample sample;
    if (cell < 0 || cell >= _cell_count.get() ||
        _environment_temperature_q16.size() != static_cast<size_t>(_cell_count.get()) ||
        _environment_temperature_30d_q16.size() != static_cast<size_t>(_cell_count.get()) ||
        _environment_moisture_q16.size() != static_cast<size_t>(_cell_count.get()) ||
        _environment_plant_available_water_q16.size() != static_cast<size_t>(_cell_count.get()) ||
        _environment_precipitation_q16.size() != static_cast<size_t>(_cell_count.get()) ||
        _environment_snow_q16.size() != static_cast<size_t>(_cell_count.get()) ||
        _environment_weather_q16.size() != static_cast<size_t>(_cell_count.get())) {
        return sample;
    }
    sample.temperature_q16 = _environment_temperature_q16[cell];
    sample.temperature_30d_q16 = _environment_temperature_30d_q16[cell];
    sample.moisture_q16 = _environment_moisture_q16[cell];
    sample.plant_available_water_q16 = _environment_plant_available_water_q16[cell];
    sample.snow_q16 = _environment_snow_q16[cell];
    sample.weather_q16 = _environment_weather_q16[cell];
    sample.ready = _environment_day.get() >= 0;
    return sample;
}

NativeEconomyRuntime::EnvironmentSample NativeEconomyRuntime::environment_sample_from_float(
        float temperature, float moisture, float snow_cover, float weather_intensity,
        bool ready) {
    auto quantize = [](float value, int32_t fallback) -> int32_t {
        if (!std::isfinite(value)) return fallback;
        return static_cast<int32_t>(std::clamp<int64_t>(
            static_cast<int64_t>(std::llround(std::clamp(value, 0.0f, 1.0f) * Q16_ONE)),
            0, Q16_ONE));
    };
    EnvironmentSample sample;
    sample.temperature_q16 = quantize(temperature, Q16_ONE / 2);
    sample.temperature_30d_q16 = sample.temperature_q16;
    sample.moisture_q16 = quantize(moisture, Q16_ONE / 2);
    sample.plant_available_water_q16 = sample.moisture_q16;
    sample.snow_q16 = quantize(snow_cover, 0);
    sample.weather_q16 = quantize(weather_intensity, 0);
    sample.ready = ready;
    return sample;
}

} // namespace pk
