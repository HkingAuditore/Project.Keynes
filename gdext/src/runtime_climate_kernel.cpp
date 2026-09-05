#include "runtime_climate_kernel.h"
#include "runtime_climate_formulas.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>

namespace pk {
namespace {
constexpr uint64_t FNV_OFFSET = 1469598103934665603ull;
constexpr uint64_t FNV_PRIME = 1099511628211ull;

uint64_t mix(uint64_t value, uint64_t input) noexcept {
    value ^= input + 0x9e3779b97f4a7c15ull + (value << 6u) + (value >> 2u);
    return value * FNV_PRIME;
}

template <typename T>
uint64_t mix_vector(uint64_t hash, const std::vector<T> &values) noexcept {
    hash = mix(hash, values.size());
    for (const T &value : values) {
        const auto *bytes = reinterpret_cast<const uint8_t *>(&value);
        for (size_t i = 0; i < sizeof(T); ++i) hash = mix(hash, bytes[i]);
    }
    return hash;
}

float read_or(const std::vector<float> &values, size_t index, float fallback) noexcept {
    return index < values.size() ? values[index] : fallback;
}

uint8_t read_or(const std::vector<uint8_t> &values, size_t index, uint8_t fallback) noexcept {
    return index < values.size() ? values[index] : fallback;
}

void copy_error(RuntimeClimateKernelReport &report, const char *error) {
    size_t index = 0;
    for (; error != nullptr && error[index] != '\0' && index + 1 < sizeof(report.error); ++index)
        report.error[index] = error[index];
    report.error[index] = '\0';
}

template <typename T>
void copy_lane(std::vector<T> &destination, const std::vector<T> &source) {
    std::copy(source.begin(), source.end(), destination.begin());
}

void copy_store_lanes(RuntimeClimateStore &next, const RuntimeClimateStore &current) {
    copy_lane(next.temperature, current.temperature);
    copy_lane(next.temperature_30d_ema, current.temperature_30d_ema);
    copy_lane(next.temperature_365d_ema, current.temperature_365d_ema);
    copy_lane(next.temperature_baseline, current.temperature_baseline);
    copy_lane(next.thermal_energy, current.thermal_energy);
    copy_lane(next.moisture, current.moisture);
    copy_lane(next.plant_available_water, current.plant_available_water);
    copy_lane(next.water_balance_30d, current.water_balance_30d);
    copy_lane(next.weather_precipitation, current.weather_precipitation);
    copy_lane(next.weather_intensity, current.weather_intensity);
    copy_lane(next.vapor, current.vapor);
    copy_lane(next.cloud_water, current.cloud_water);
    copy_lane(next.cloud_cover, current.cloud_cover);
    copy_lane(next.convergence, current.convergence);
    copy_lane(next.instability, current.instability);
    copy_lane(next.weather_type, current.weather_type);
    copy_lane(next.weather_transition, current.weather_transition);
    copy_lane(next.snow_cover, current.snow_cover);
    copy_lane(next.snowpack, current.snowpack);
    copy_lane(next.sea_ice, current.sea_ice);
    copy_lane(next.runoff, current.runoff);
    copy_lane(next.groundwater, current.groundwater);
    copy_lane(next.river_storage, current.river_storage);
    copy_lane(next.river_discharge, current.river_discharge);
    copy_lane(next.riparian_moisture, current.riparian_moisture);
    copy_lane(next.vegetation_vitality, current.vegetation_vitality);
    copy_lane(next.vegetation_growth_pressure, current.vegetation_growth_pressure);
    copy_lane(next.vegetation_heat_stress, current.vegetation_heat_stress);
    copy_lane(next.vegetation_drought_stress, current.vegetation_drought_stress);
    copy_lane(next.vegetation_cold_stress, current.vegetation_cold_stress);
    copy_lane(next.vegetation_growth_streak, current.vegetation_growth_streak);
    copy_lane(next.vegetation_drought_streak, current.vegetation_drought_streak);
    copy_lane(next.vegetation_succession_candidate, current.vegetation_succession_candidate);
    copy_lane(next.temperature_history, current.temperature_history);
    next.cell_count = current.cell_count;
    next.generation = current.generation;
    next.climate_generation = current.climate_generation;
    next.committed_day = current.committed_day;
    next.climate_anomaly = current.climate_anomaly;
    next.annual_temperature_drift = current.annual_temperature_drift;
    next.rng_state = current.rng_state;
    next.annual_rng_state = current.annual_rng_state;
    next.history_cursor = current.history_cursor;
}

float normalised_rng(uint64_t &value) noexcept {
    return climate_formula::normalized_rng(value);
}

template <typename Fn>
void run_stage(RuntimeClimateKernelReport &report, RuntimeClimateStage stage, Fn &&body) {
    const auto begin = std::chrono::steady_clock::now();
    const uint64_t work = body();
    const size_t index = static_cast<size_t>(stage);
    report.stage_work[index] = work;
    report.work_units += work;
    report.stage_ms[index] = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - begin).count();
}
} // namespace

void RuntimeClimateKernel::reset(uint32_t) {}

bool RuntimeClimateKernel::compile_catalog(const RuntimeEnvironmentSnapshot &input,
                                           RuntimeClimateCatalog &catalog,
                                           std::string &error) const {
    if (input.climate_catalog_abi_version != RUNTIME_DOMAIN_POD_ABI_VERSION ||
        input.cell_count == 0) {
        error = "climate_catalog_abi_or_shape_invalid";
        return false;
    }
    // Formula parameters belong to the immutable worker catalog, not to the
    // per-day environment protocol.  Reset first so a catalog compiled for a
    // new topology cannot accidentally retain values from a previous map.
    catalog = RuntimeClimateCatalog{};
    catalog.abi_version = input.climate_catalog_abi_version;
    catalog.cell_count = input.cell_count;
    catalog.map_width = input.climate_map_width;
    catalog.map_height = input.climate_map_height;
    // A catalog hash is static metadata, never a day-varying input hash. The
    // facade may provide a compiled profile hash; otherwise derive a stable
    // shape/topology identity that survives daily dynamic field changes.
    catalog.hash = input.climate_catalog_hash != 0 ? input.climate_catalog_hash :
        (0x434c494d415445ull ^ static_cast<uint64_t>(input.cell_count) ^
         (static_cast<uint64_t>(input.climate_map_width) << 16u) ^
         (static_cast<uint64_t>(input.climate_map_height) << 32u) ^
         input.topology_generation);
    if (catalog.hash == 0) {
        error = "climate_catalog_hash_invalid";
        return false;
    }
    return true;
}

uint64_t RuntimeClimateKernel::input_hash(const RuntimeEnvironmentSnapshot &input) {
    uint64_t hash = mix(FNV_OFFSET, input.generation);
    hash = mix(hash, static_cast<uint64_t>(input.day));
    hash = mix(hash, input.cell_count);
    hash = mix(hash, input.climate_catalog_abi_version);
    hash = mix(hash, input.climate_catalog_hash);
    hash = mix(hash, input.climate_map_width);
    hash = mix(hash, input.climate_map_height);
    hash = mix(hash, input.topology_generation);
    hash = mix(hash, input.vision_revision);
    hash = mix(hash, input.topology_validated ? 1u : 0u);
    hash = mix(hash, input.fog_solved ? 1u : 0u);
    hash = mix(hash, input.climate_input_complete ? 1u : 0u);
    uint32_t dt_bits = 0;
    std::memcpy(&dt_bits, &input.dt_days, sizeof(input.dt_days));
    hash = mix(hash, dt_bits);
    uint64_t season_bits = 0;
    uint64_t anomaly_bits = 0;
    std::memcpy(&season_bits, &input.season_phase, sizeof(input.season_phase));
    std::memcpy(&anomaly_bits, &input.climate_anomaly, sizeof(input.climate_anomaly));
    hash = mix(hash, season_bits);
    hash = mix(hash, anomaly_bits);
    hash = mix_vector(hash, input.cell_temp);
    hash = mix_vector(hash, input.cell_temp_30d);
    hash = mix_vector(hash, input.cell_temp_365d);
    hash = mix_vector(hash, input.cell_temp_baseline_year);
    hash = mix_vector(hash, input.cell_base_moisture);
    hash = mix_vector(hash, input.cell_moisture);
    hash = mix_vector(hash, input.cell_plant_available_water);
    hash = mix_vector(hash, input.cell_soil_moisture);
    hash = mix_vector(hash, input.cell_water_balance_30d);
    hash = mix_vector(hash, input.cell_weather_precip);
    hash = mix_vector(hash, input.cell_snow_cover);
    hash = mix_vector(hash, input.cell_weather_intensity);
    hash = mix_vector(hash, input.cell_weather_vapor);
    hash = mix_vector(hash, input.cell_weather_cloud_water);
    hash = mix_vector(hash, input.cell_weather_cloud);
    hash = mix_vector(hash, input.cell_weather_type);
    hash = mix_vector(hash, input.cell_weather_transition);
    hash = mix_vector(hash, input.cell_sea_ice_frac_prev);
    hash = mix_vector(hash, input.cell_river_discharge_30d);
    hash = mix_vector(hash, input.cell_vegetation_vitality);
    hash = mix_vector(hash, input.cell_insolation_dev);
    hash = mix_vector(hash, input.cell_heat_input);
    hash = mix_vector(hash, input.cell_wind_x);
    hash = mix_vector(hash, input.cell_wind_y);
    hash = mix_vector(hash, input.cell_wind_speed);
    hash = mix_vector(hash, input.cell_ocean_current_x);
    hash = mix_vector(hash, input.cell_ocean_current_y);
    hash = mix_vector(hash, input.cell_air_mass_temp_anomaly);
    hash = mix_vector(hash, input.cell_ocean_thermal_anomaly);
    hash = mix_vector(hash, input.cell_local_thermal_anomaly);
    hash = mix_vector(hash, input.cell_temperature_transport_anomaly);
    hash = mix_vector(hash, input.cell_ema_initialized);
    hash = mix_vector(hash, input.cell_elevation);
    hash = mix_vector(hash, input.cell_lat_norm);
    hash = mix_vector(hash, input.cell_geometry_area);
    hash = mix_vector(hash, input.cell_wind_band);
    hash = mix_vector(hash, input.cell_ocean_heat_capacity);
    hash = mix_vector(hash, input.neighbor_offsets);
    hash = mix_vector(hash, input.neighbor_indices);
    hash = mix_vector(hash, input.hydro_parent);
    hash = mix_vector(hash, input.terrain);
    hash = mix_vector(hash, input.landform);
    hash = mix_vector(hash, input.vegetation);
    hash = mix_vector(hash, input.cover);
    hash = mix_vector(hash, input.is_water);
    hash = mix_vector(hash, input.has_river);
    hash = mix_vector(hash, input.canal_edge_mask);
    hash = mix_vector(hash, input.canal_water);
    hash = mix_vector(hash, input.trade_passable_lut);
    hash = mix_vector(hash, input.trade_move_cost_lut);
    hash = mix_vector(hash, input.visible);
    hash = mix_vector(hash, input.building_resource_reserve);
    hash = mix_vector(hash, input.building_resource_extra);
    return hash;
}

bool RuntimeClimateKernel::plan_day(int64_t day, const RuntimeEnvironmentSnapshot &input,
                                    const RuntimeClimateCatalog &catalog,
                                    const RuntimeClimateStore &current,
                                    RuntimeClimateStore &next,
                                    RuntimeClimateKernelReport &report) const {
    report = RuntimeClimateKernelReport{};
    std::string error;
    std::string current_error;
    std::string next_error;
    if (!validate_runtime_environment_snapshot(input, error) ||
        !current.validate(current_error) || !next.validate(next_error) ||
        catalog.abi_version != RUNTIME_DOMAIN_POD_ABI_VERSION ||
        catalog.cell_count != current.cell_count || next.cell_count != current.cell_count ||
        (input.climate_catalog_hash != 0 && input.climate_catalog_hash != catalog.hash) ||
        day < 0 || current.committed_day >= day) {
        const char *reason = !error.empty() ? error.c_str() :
            (!current_error.empty() ? current_error.c_str() :
            (!next_error.empty() ? next_error.c_str() : "climate_kernel_preflight_failed"));
        copy_error(report, reason);
        return false;
    }
    copy_store_lanes(next, current);
    report.input_hash = input_hash(input);
    const size_t cells = current.cell_count;
    const float season = static_cast<float>(input.season_phase);
    // The capture boundary carries the actual logical-day delta. Clamping to
    // one day here silently slowed stride/fast-forward runs and made EMA,
    // transition, hydrology and sea-ice state depend on call frequency.
    const float dt = std::clamp(input.dt_days, 1.0f,
                                std::max(1.0f, catalog.dt_days_cap));

    run_stage(report, RuntimeClimateStage::PASS_A, [&]() {
        for (size_t i = 0; i < cells; ++i) {
            const float ny = climate_formula::clamp01(
                read_or(input.cell_lat_norm, i, 0.5f));
            const float elevation = read_or(input.cell_elevation, i, 0.0f);
            const bool is_water = read_or(input.is_water, i, 0u) != 0u;
            const float annual_mean = climate_formula::annual_insolation_mean(
                ny, catalog.axial_tilt_deg, catalog.day_length_gain);
            const float current_insolation = climate_formula::daily_insolation(
                ny, season, catalog.axial_tilt_deg, catalog.day_length_gain);
            float deviation = climate_formula::insolation_season_dev(
                ny, current_insolation,
                annual_mean);
            deviation = climate_formula::clamp(
                deviation, catalog.insol_dev_min, catalog.insol_dev_max);

            float base_moisture = read_or(input.cell_base_moisture, i,
                                          read_or(input.cell_moisture, i, 0.0f));
            base_moisture = climate_formula::clamp01(base_moisture);
            float moisture_target = base_moisture;
            if (!is_water) {
                if (input.cell_weather_vapor.size() == cells) {
                    const float vapor = climate_formula::clamp(
                        input.cell_weather_vapor[i], 0.0f, 1.0f);
                    moisture_target += (vapor - base_moisture * 0.15f) *
                        catalog.runtime_moisture_weather_vapor_weight;
                }
                if (input.cell_weather_precip.size() == cells) {
                    moisture_target += climate_formula::clamp(
                        input.cell_weather_precip[i], 0.0f, 1.0f) *
                        catalog.runtime_moisture_precip_weight;
                }
                if (input.cell_soil_moisture.size() == cells) {
                    moisture_target += climate_formula::signed_hydrology_contribution(
                        climate_formula::clamp(input.cell_soil_moisture[i], -0.5f, 0.5f),
                        catalog.runtime_moisture_soil_weight,
                        catalog.runtime_moisture_soil_dry_weight);
                }
                if (input.cell_water_balance_30d.size() == cells) {
                    moisture_target += climate_formula::signed_hydrology_contribution(
                        climate_formula::clamp(input.cell_water_balance_30d[i], -1.0f, 1.0f),
                        catalog.runtime_moisture_water_balance_weight,
                        catalog.runtime_moisture_water_balance_dry_weight);
                }
                moisture_target = climate_formula::clamp01(moisture_target);
            }
            float previous_moisture = read_or(input.cell_moisture, i,
                                              current.moisture[i]);
            if (!std::isfinite(previous_moisture) || previous_moisture < 0.0f ||
                previous_moisture > 1.0f) {
                previous_moisture = moisture_target;
            }
            const float moisture_alpha = climate_formula::thermal_alpha_eff(
                catalog.runtime_moisture_base_relax_rate, dt);
            const float moisture_now = is_water ? moisture_target :
                climate_formula::clamp01(previous_moisture +
                    (moisture_target - previous_moisture) *
                    moisture_alpha);

            float temp_year = read_or(input.cell_temp_baseline_year, i,
                                      0.0f) - static_cast<float>(
                                          climate_formula::altitude_penalty(
                                              elevation, catalog.sea_level));
            temp_year = climate_formula::clamp01(temp_year);
            const float insolation_gain = catalog.insol_amp * catalog.insol_gain;
            float season_offset = climate_formula::season_offset_continental(
                insolation_gain, is_water,
                current.temperature_365d_ema[i], deviation,
                catalog.land_continentality);
            float radiative_target = climate_formula::clamp01(temp_year + season_offset);
            const float current_temp = read_or(input.cell_temp, i,
                                               current.temperature[i]);
            float previous_energy = current.thermal_energy[i];
            if (current.committed_day < 0) previous_energy = current_temp;
            float alpha = catalog.thermal_inertia_land;
            const uint8_t cover = read_or(input.cover, i, 0u);
            const float snowpack = current.snowpack[i];
            if (is_water) alpha = catalog.thermal_inertia_water;
            else if (cover == 2u || snowpack > catalog.snowpack_cover_low)
                alpha = catalog.thermal_inertia_snow;
            else if (elevation > 0.70f)
                alpha = catalog.thermal_inertia_high_mountain;
            alpha = climate_formula::thermal_alpha_eff(alpha, dt);
            const float heat_next = previous_energy +
                (radiative_target - previous_energy) * alpha;
            const float delta_cap = std::max(0.0f,
                catalog.thermal_daily_delta_cap) * dt;
            const float temp_now = climate_formula::clamp01(
                previous_energy + climate_formula::clamp(
                    heat_next - previous_energy, -delta_cap, delta_cap));
            next.temperature_baseline[i] = temp_now;
            next.thermal_energy[i] = heat_next;
            next.moisture[i] = moisture_now;
            next.temperature_30d_ema[i] = current.temperature_30d_ema[i] +
                (temp_now - current.temperature_30d_ema[i]) *
                climate_formula::thermal_alpha_eff(1.0f / 30.0f, dt);
            next.temperature_365d_ema[i] = current.temperature_365d_ema[i] +
                (temp_now - current.temperature_365d_ema[i]) *
                climate_formula::thermal_alpha_eff(
                    1.0f / static_cast<float>(std::max(1u, catalog.days_per_year)), dt);
            next.snowpack[i] = is_water ? 0.0f : snowpack;
            next.snow_cover[i] = climate_formula::clamp01(next.snowpack[i]);
            next.temperature[i] = temp_now;
            next.convergence[i] = 0.0f;
            next.vapor[i] = read_or(input.cell_weather_vapor, i, current.vapor[i]);
            next.weather_precipitation[i] = read_or(input.cell_weather_precip, i,
                                                     current.weather_precipitation[i]);
            next.weather_intensity[i] = read_or(input.cell_weather_intensity, i,
                                                current.weather_intensity[i]);
            next.plant_available_water[i] = read_or(input.cell_plant_available_water,
                                                    i, current.plant_available_water[i]);
        }
        return static_cast<uint64_t>(cells) * 6u;
    });
    run_stage(report, RuntimeClimateStage::PASS_B, [&]() {
        for (size_t i = 0; i < cells; ++i) {
            const float moisture = read_or(input.cell_moisture, i, current.moisture[i]);
            const float terrain = static_cast<float>(read_or(input.terrain, i, 0u));
            next.moisture[i] = std::clamp(moisture + (terrain > 0.0f ? -0.002f : 0.002f), 0.0f, 1.0f);
            next.temperature[i] = next.thermal_energy[i] + next.temperature_baseline[i] * 0.05f;
        }
        return static_cast<uint64_t>(cells) * 3u;
    });
    run_stage(report, RuntimeClimateStage::OCEAN_WATER, [&]() {
        for (size_t i = 0; i < cells; ++i) if (read_or(input.is_water, i, 0u) != 0) {
            next.temperature[i] = next.temperature[i] * 0.96f + current.temperature_365d_ema[i] * 0.04f;
        }
        return static_cast<uint64_t>(cells);
    });
    run_stage(report, RuntimeClimateStage::OCEAN_LAND, [&]() {
        for (size_t i = 0; i < cells; ++i) if (read_or(input.is_water, i, 0u) == 0) {
            next.temperature[i] += (next.moisture[i] - 0.5f) * 0.15f;
        }
        return static_cast<uint64_t>(cells);
    });
    run_stage(report, RuntimeClimateStage::WIND_AIR, [&]() {
        for (size_t i = 0; i < cells; ++i) {
            float sum = 0.0f;
            uint32_t count = 0;
            const size_t begin = input.neighbor_offsets.empty() ? i * 6u :
                static_cast<size_t>(input.neighbor_offsets[i]);
            const size_t end = input.neighbor_offsets.empty() ? begin + 6u :
                static_cast<size_t>(input.neighbor_offsets[i + 1u]);
            for (size_t p = begin; p < end && p < input.neighbor_indices.size(); ++p) {
                const int32_t n = input.neighbor_indices[p];
                if (n >= 0) { sum += next.temperature[static_cast<size_t>(n)]; ++count; }
            }
            next.convergence[i] = count == 0 ? 0.0f : (sum / static_cast<float>(count) - next.temperature[i]);
        }
        return static_cast<uint64_t>(cells) * 7u;
    });
    run_stage(report, RuntimeClimateStage::WIND_SURFACE, [&]() {
        for (size_t i = 0; i < cells; ++i) next.temperature[i] += next.convergence[i] * 0.18f;
        return static_cast<uint64_t>(cells) * 2u;
    });
    run_stage(report, RuntimeClimateStage::SEA_ICE, [&]() {
        for (size_t i = 0; i < cells; ++i) {
            float ice = current.sea_ice[i];
            if (read_or(input.is_water, i, 0u) != 0) {
                if (next.temperature[i] < catalog.sea_ice_freeze) ice += 0.04f * dt;
                else if (next.temperature[i] > catalog.sea_ice_melt) ice -= 0.03f * dt;
            } else ice = 0.0f;
            next.sea_ice[i] = std::clamp(ice, 0.0f, 1.0f);
            next.snowpack[i] = std::max(0.0f, current.snowpack[i] +
                (next.temperature[i] < 0.0f ? 0.01f : -0.02f * dt));
            next.snow_cover[i] = std::clamp(next.snowpack[i], 0.0f, 1.0f);
        }
        return static_cast<uint64_t>(cells) * 5u;
    });
    run_stage(report, RuntimeClimateStage::TRANSPIRATION, [&]() {
        for (size_t i = 0; i < cells; ++i) {
            const float heat = std::max(0.0f, next.temperature[i] - 3.0f) / 35.0f;
            next.vegetation_growth_pressure[i] = std::clamp(next.plant_available_water[i] * heat, 0.0f, 1.0f);
        }
        return static_cast<uint64_t>(cells) * 2u;
    });
    run_stage(report, RuntimeClimateStage::ALBEDO, [&]() {
        for (size_t i = 0; i < cells; ++i) next.temperature[i] -= next.snow_cover[i] * 0.4f + next.sea_ice[i] * 0.25f;
        return static_cast<uint64_t>(cells) * 2u;
    });
    run_stage(report, RuntimeClimateStage::VEGETATION_DYNAMICS, [&]() {
        for (size_t i = 0; i < cells; ++i) {
            next.vegetation_heat_stress[i] = std::clamp((next.temperature[i] - 30.0f) / 20.0f, 0.0f, 1.0f);
            next.vegetation_drought_stress[i] = 1.0f - std::clamp(next.plant_available_water[i], 0.0f, 1.0f);
            next.vegetation_cold_stress[i] = std::clamp((-next.temperature[i]) / 20.0f, 0.0f, 1.0f);
            const float pressure = next.vegetation_growth_pressure[i] -
                (next.vegetation_heat_stress[i] + next.vegetation_drought_stress[i] + next.vegetation_cold_stress[i]) / 3.0f;
            next.vegetation_vitality[i] = std::clamp(current.vegetation_vitality[i] + pressure * 0.02f, 0.0f, 1.0f);
            next.vegetation_growth_streak[i] = pressure > 0.0f ? current.vegetation_growth_streak[i] + 1 : 0;
            next.vegetation_drought_streak[i] = next.vegetation_drought_stress[i] > 0.7f ? current.vegetation_drought_streak[i] + 1 : 0;
            next.vegetation_succession_candidate[i] = next.vegetation_growth_streak[i] >= 30 ? 1u : 0u;
        }
        return static_cast<uint64_t>(cells) * 9u;
    });
    run_stage(report, RuntimeClimateStage::CLIMATE_FEEDBACK, [&]() {
        for (size_t i = 0; i < cells; ++i) next.temperature[i] += (next.vegetation_vitality[i] - 0.5f) * 0.05f;
        return static_cast<uint64_t>(cells) * 2u;
    });
    run_stage(report, RuntimeClimateStage::WEATHER, [&]() {
        for (size_t i = 0; i < cells; ++i) {
            next.vapor[i] = std::clamp(next.moisture[i] + std::max(0.0f, next.temperature[i]) * 0.004f, 0.0f, 1.0f);
            next.cloud_water[i] = std::max(0.0f, next.vapor[i] + next.convergence[i] * 0.02f - 0.35f);
            next.cloud_cover[i] = std::clamp(next.cloud_water[i] * 2.0f, 0.0f, 1.0f);
            next.instability[i] = std::clamp(std::abs(next.temperature[i] - next.temperature_30d_ema[i]) / 12.0f, 0.0f, 1.0f);
            const float precipitation = std::max(0.0f, next.cloud_water[i] * (0.25f + next.instability[i]));
            next.weather_precipitation[i] = precipitation;
            next.weather_intensity[i] = std::clamp(precipitation * 4.0f, 0.0f, 1.0f);
            const uint8_t type = precipitation > 0.20f ? 3u : precipitation > 0.04f ? 2u : next.cloud_cover[i] > 0.35f ? 1u : 0u;
            next.weather_transition[i] = type == current.weather_type[i] ? 0u : 1u;
            next.weather_type[i] = type;
        }
        return static_cast<uint64_t>(cells) * 10u;
    });
    run_stage(report, RuntimeClimateStage::RUNTIME_HYDROLOGY, [&]() {
        for (size_t i = 0; i < cells; ++i) {
            const float melt = next.temperature[i] > 0.0f ? std::min(next.snowpack[i], next.temperature[i] * 0.01f) : 0.0f;
            next.snowpack[i] -= melt;
            const float inflow = next.weather_precipitation[i] + melt + read_or(input.canal_water, i, 0.0f);
            const float water = std::clamp(current.plant_available_water[i] + inflow - next.vegetation_growth_pressure[i] * 0.015f, 0.0f, catalog.soil_capacity);
            next.plant_available_water[i] = water;
            next.water_balance_30d[i] = current.water_balance_30d[i] * (29.0f / 30.0f) + (inflow - next.vegetation_growth_pressure[i] * 0.015f) / 30.0f;
            next.runoff[i] = std::max(0.0f, water - 0.85f);
            next.groundwater[i] = std::max(0.0f, current.groundwater[i] * 0.995f + next.runoff[i] * 0.15f);
            next.river_storage[i] = std::max(0.0f, current.river_storage[i] + next.runoff[i] - current.river_discharge[i]);
            next.river_discharge[i] = next.river_storage[i] * (read_or(input.has_river, i, 0u) != 0 ? 0.25f : 0.02f);
            next.riparian_moisture[i] = std::clamp(water + next.river_discharge[i] * 0.25f, 0.0f, 1.0f);
        }
        return static_cast<uint64_t>(cells) * 11u;
    });
    run_stage(report, RuntimeClimateStage::STAGE_B_AFTER_HYDROLOGY, [&]() {
        for (size_t i = 0; i < cells; ++i) {
            next.moisture[i] = std::clamp(next.moisture[i] * 0.9f + next.plant_available_water[i] * 0.1f, 0.0f, 1.0f);
            if (next.temperature[i] != current.temperature[i] ||
                next.plant_available_water[i] != current.plant_available_water[i] ||
                next.weather_precipitation[i] != current.weather_precipitation[i]) ++report.changed_cells;
        }
        return static_cast<uint64_t>(cells) * 3u;
    });
    next.committed_day = day;
    ++next.generation;
    ++next.climate_generation;
    if (day > 0 && day % 365 == 0) {
        next.annual_temperature_drift = (normalised_rng(next.annual_rng_state) - 0.5f) * 0.4f;
        next.climate_anomaly = next.annual_temperature_drift;
    }
    const size_t history_offset = static_cast<size_t>(next.history_cursor % 365u) * cells;
    for (size_t i = 0; i < cells; ++i) next.temperature_history[history_offset + i] = next.temperature[i];
    next.history_cursor = (next.history_cursor + 1u) % 365u;
    report.state_hash = next.state_hash();
    report.completed = 1;
    return true;
}

void RuntimeClimateKernel::commit(RuntimeClimateStore &current, RuntimeClimateStore &next) {
    using std::swap;
    swap(current, next);
}

bool RuntimeClimateKernel::self_test(std::string &error) {
    if (!climate_formula::self_test()) {
        error = "climate_formula_self_test_failed";
        return false;
    }
    RuntimeEnvironmentSnapshot input;
    input.generation = 1;
    input.day = 0;
    input.cell_count = 2;
    input.climate_catalog_hash = 7;
    input.cell_temp = {15.0f, -8.0f};
    input.cell_moisture = {0.5f, 0.25f};
    input.cell_plant_available_water = {0.7f, 0.2f};
    input.terrain = {1, 0};
    input.is_water = {0, 1};
    input.neighbor_offsets = {0, 1, 2};
    input.neighbor_indices = {1, 0};
    RuntimeClimateStore current;
    RuntimeClimateStore next;
    current.reset(2);
    next.reset(2);
    RuntimeClimateCatalog catalog;
    RuntimeClimateKernel kernel;
    if (!kernel.compile_catalog(input, catalog, error)) return false;
    RuntimeClimateKernelReport report;
    if (!kernel.plan_day(0, input, catalog, current, next, report) || !report.completed) {
        error = report.error;
        return false;
    }
    commit(current, next);
    if (current.committed_day != 0 || current.state_hash() != report.state_hash || report.work_units == 0) {
        error = "climate_kernel_self_test_state_invalid";
        return false;
    }
    return true;
}
} // namespace pk
