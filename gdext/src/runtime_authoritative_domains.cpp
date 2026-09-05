#include "runtime_authoritative_domains.h"
#include "runtime_domain_pod.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>

namespace pk {

namespace {
constexpr uint64_t FNV_OFFSET = 1469598103934665603ull;
constexpr uint64_t FNV_PRIME = 1099511628211ull;

uint64_t mix(uint64_t hash, uint64_t value) noexcept {
    hash ^= value + 0x9e3779b97f4a7c15ull + (hash << 6u) + (hash >> 2u);
    return hash * FNV_PRIME;
}

template <typename T>
uint64_t mix_vector(uint64_t hash, const std::vector<T> &values) noexcept {
    hash = mix(hash, static_cast<uint64_t>(values.size()));
    for (const T &value : values) {
        static_assert(std::is_trivially_copyable_v<T>);
        std::array<uint8_t, sizeof(T)> bytes{};
        std::memcpy(bytes.data(), &value, sizeof(T));
        for (uint8_t byte : bytes) hash = mix(hash, byte);
    }
    return hash;
}

bool finite_vector(const std::vector<float> &values) noexcept {
    for (float value : values) if (!std::isfinite(value)) return false;
    return true;
}

template <typename T>
bool same_size(const std::vector<T> &values, size_t expected) noexcept {
    return values.size() == expected;
}

void set_error(std::string &error, const char *value) {
    if (error.empty()) error = value;
}
}

bool validate_runtime_environment_snapshot(
        const RuntimeEnvironmentSnapshot &snapshot, std::string &error) {
    error.clear();
    const size_t cells = static_cast<size_t>(snapshot.cell_count);
    if (cells == 0) {
        error = "runtime_input_cell_count_invalid";
        return false;
    }
    if (snapshot.climate_catalog_abi_version != RUNTIME_DOMAIN_POD_ABI_VERSION ||
        snapshot.day < 0 || !std::isfinite(snapshot.season_phase) ||
        !std::isfinite(snapshot.climate_anomaly) ||
        !std::isfinite(snapshot.dt_days) || snapshot.dt_days <= 0.0f) {
        error = "runtime_input_value_invalid";
        return false;
    }
    if (snapshot.climate_input_complete &&
        (snapshot.climate_catalog_hash == 0 ||
         snapshot.climate_map_width == 0 || snapshot.climate_map_height == 0 ||
         !snapshot.topology_validated)) {
        error = "runtime_input_complete_metadata_missing";
        return false;
    }
    if ((snapshot.climate_map_width == 0) !=
        (snapshot.climate_map_height == 0)) {
        error = "runtime_input_map_shape_invalid";
        return false;
    }
    if (snapshot.climate_input_complete &&
        snapshot.climate_map_width != 0 && snapshot.climate_map_height != 0) {
        const uint64_t expected_cells =
            static_cast<uint64_t>(snapshot.climate_map_width) *
            static_cast<uint64_t>(snapshot.climate_map_height);
        if (expected_cells != static_cast<uint64_t>(snapshot.cell_count)) {
            error = "runtime_input_map_cell_count_mismatch";
            return false;
        }
    }
    const auto sized = [cells](size_t count) {
        return count == 0 || count == cells;
    };
    const auto finite = [](const std::vector<float> &values) {
        for (const float value : values) {
            if (!std::isfinite(value)) return false;
        }
        return true;
    };
    if (!sized(snapshot.cell_temp.size()) ||
        !sized(snapshot.cell_temp_30d.size()) ||
        !sized(snapshot.cell_temp_365d.size()) ||
        !sized(snapshot.cell_temp_baseline_year.size()) ||
        !sized(snapshot.cell_base_moisture.size()) ||
        !sized(snapshot.cell_moisture.size()) ||
        !sized(snapshot.cell_plant_available_water.size()) ||
        !sized(snapshot.cell_soil_moisture.size()) ||
        !sized(snapshot.cell_water_balance_30d.size()) ||
        !sized(snapshot.cell_weather_precip.size()) ||
        !sized(snapshot.cell_snow_cover.size()) ||
        !sized(snapshot.cell_weather_intensity.size()) ||
        !sized(snapshot.cell_weather_vapor.size()) ||
        !sized(snapshot.cell_weather_cloud_water.size()) ||
        !sized(snapshot.cell_weather_cloud.size()) ||
        !sized(snapshot.cell_weather_type.size()) ||
        !sized(snapshot.cell_weather_transition.size()) ||
        !sized(snapshot.cell_sea_ice_frac_prev.size()) ||
        !sized(snapshot.cell_river_discharge_30d.size()) ||
        !sized(snapshot.cell_vegetation_vitality.size()) ||
        !sized(snapshot.cell_insolation_dev.size()) ||
        !sized(snapshot.cell_heat_input.size()) ||
        !sized(snapshot.cell_wind_x.size()) ||
        !sized(snapshot.cell_wind_y.size()) ||
        !sized(snapshot.cell_wind_speed.size()) ||
        !sized(snapshot.cell_ocean_current_x.size()) ||
        !sized(snapshot.cell_ocean_current_y.size()) ||
        !sized(snapshot.cell_air_mass_temp_anomaly.size()) ||
        !sized(snapshot.cell_ocean_thermal_anomaly.size()) ||
        !sized(snapshot.cell_local_thermal_anomaly.size()) ||
        !sized(snapshot.cell_temperature_transport_anomaly.size()) ||
        !sized(snapshot.cell_ema_initialized.size()) ||
        !sized(snapshot.cell_elevation.size()) ||
        !sized(snapshot.cell_lat_norm.size()) ||
        !sized(snapshot.cell_geometry_area.size()) ||
        !sized(snapshot.cell_wind_band.size()) ||
        !sized(snapshot.cell_ocean_heat_capacity.size()) ||
        !sized(snapshot.canal_water.size()) ||
        !sized(snapshot.visible.size()) ||
        !sized(snapshot.terrain.size()) ||
        !sized(snapshot.landform.size()) ||
        !sized(snapshot.vegetation.size()) ||
        !sized(snapshot.cover.size()) ||
        !sized(snapshot.is_water.size()) ||
        !sized(snapshot.has_river.size()) ||
        !sized(snapshot.canal_edge_mask.size()) ||
        !sized(snapshot.building_resource_reserve.size()) ||
        !sized(snapshot.building_resource_extra.size())) {
        error = "runtime_input_shape_mismatch";
        return false;
    }
    if (!finite(snapshot.cell_temp) || !finite(snapshot.cell_temp_30d) ||
        !finite(snapshot.cell_temp_365d) ||
        !finite(snapshot.cell_temp_baseline_year) ||
        !finite(snapshot.cell_base_moisture) ||
        !finite(snapshot.cell_moisture) ||
        !finite(snapshot.cell_plant_available_water) ||
        !finite(snapshot.cell_soil_moisture) ||
        !finite(snapshot.cell_water_balance_30d) ||
        !finite(snapshot.cell_weather_precip) ||
        !finite(snapshot.cell_snow_cover) ||
        !finite(snapshot.cell_weather_intensity) ||
        !finite(snapshot.cell_weather_vapor) ||
        !finite(snapshot.cell_weather_cloud_water) ||
        !finite(snapshot.cell_weather_cloud) ||
        !finite(snapshot.cell_sea_ice_frac_prev) ||
        !finite(snapshot.cell_river_discharge_30d) ||
        !finite(snapshot.cell_vegetation_vitality) ||
        !finite(snapshot.cell_insolation_dev) ||
        !finite(snapshot.cell_heat_input) ||
        !finite(snapshot.cell_wind_x) || !finite(snapshot.cell_wind_y) ||
        !finite(snapshot.cell_wind_speed) ||
        !finite(snapshot.cell_ocean_current_x) ||
        !finite(snapshot.cell_ocean_current_y) ||
        !finite(snapshot.cell_air_mass_temp_anomaly) ||
        !finite(snapshot.cell_ocean_thermal_anomaly) ||
        !finite(snapshot.cell_local_thermal_anomaly) ||
        !finite(snapshot.cell_temperature_transport_anomaly) ||
        !finite(snapshot.cell_elevation) || !finite(snapshot.cell_lat_norm) ||
        !finite(snapshot.cell_geometry_area) || !finite(snapshot.cell_wind_band) ||
        !finite(snapshot.cell_ocean_heat_capacity) ||
        !finite(snapshot.canal_water) ||
        !finite(snapshot.building_resource_reserve) ||
        !finite(snapshot.building_resource_extra)) {
        error = "runtime_input_non_finite";
        return false;
    }
    if (snapshot.climate_input_complete) {
        const auto complete = [cells](size_t count) { return count == cells; };
        if (!complete(snapshot.cell_temp.size()) ||
            !complete(snapshot.cell_temp_30d.size()) ||
            !complete(snapshot.cell_temp_365d.size()) ||
            !complete(snapshot.cell_temp_baseline_year.size()) ||
            !complete(snapshot.cell_base_moisture.size()) ||
            !complete(snapshot.cell_moisture.size()) ||
            !complete(snapshot.cell_plant_available_water.size()) ||
            !complete(snapshot.cell_soil_moisture.size()) ||
            !complete(snapshot.cell_water_balance_30d.size()) ||
            !complete(snapshot.cell_weather_precip.size()) ||
            !complete(snapshot.cell_snow_cover.size()) ||
            !complete(snapshot.cell_weather_intensity.size()) ||
            !complete(snapshot.cell_weather_vapor.size()) ||
            !complete(snapshot.cell_weather_cloud_water.size()) ||
            !complete(snapshot.cell_weather_cloud.size()) ||
            !complete(snapshot.cell_weather_type.size()) ||
            !complete(snapshot.cell_weather_transition.size()) ||
            !complete(snapshot.cell_sea_ice_frac_prev.size()) ||
            !complete(snapshot.cell_river_discharge_30d.size()) ||
            !complete(snapshot.cell_vegetation_vitality.size()) ||
            !complete(snapshot.cell_insolation_dev.size()) ||
            !complete(snapshot.cell_heat_input.size()) ||
            !complete(snapshot.cell_wind_x.size()) ||
            !complete(snapshot.cell_wind_y.size()) ||
            !complete(snapshot.cell_wind_speed.size()) ||
            !complete(snapshot.cell_ocean_current_x.size()) ||
            !complete(snapshot.cell_ocean_current_y.size()) ||
            !complete(snapshot.cell_air_mass_temp_anomaly.size()) ||
            !complete(snapshot.cell_ocean_thermal_anomaly.size()) ||
            !complete(snapshot.cell_local_thermal_anomaly.size()) ||
            !complete(snapshot.cell_temperature_transport_anomaly.size()) ||
            !complete(snapshot.cell_ema_initialized.size()) ||
            !complete(snapshot.cell_elevation.size()) ||
            !complete(snapshot.cell_lat_norm.size()) ||
            !complete(snapshot.cell_geometry_area.size()) ||
            !complete(snapshot.cell_wind_band.size()) ||
            !complete(snapshot.cell_ocean_heat_capacity.size()) ||
            !complete(snapshot.canal_water.size()) ||
            !complete(snapshot.visible.size())) {
            error = "runtime_input_complete_shape_missing";
            return false;
        }
        if (snapshot.neighbor_offsets.size() != cells + 1u ||
            snapshot.hydro_parent.size() != cells ||
            snapshot.terrain.size() != cells || snapshot.landform.size() != cells ||
            snapshot.vegetation.size() != cells || snapshot.cover.size() != cells ||
            snapshot.is_water.size() != cells || snapshot.has_river.size() != cells ||
            snapshot.canal_edge_mask.size() != cells ||
            snapshot.visible.size() != cells) {
            error = "runtime_input_complete_topology_missing";
            return false;
        }
    }
    if (!snapshot.hydro_parent.empty() && snapshot.hydro_parent.size() != cells) {
        error = "runtime_input_hydro_shape_invalid";
        return false;
    }
    for (const int32_t parent : snapshot.hydro_parent) {
        if (parent < -1 || (parent >= 0 && static_cast<size_t>(parent) >= cells)) {
            error = "runtime_input_hydro_parent_invalid";
            return false;
        }
    }
    // The routing graph is a parent DAG. Range checks alone would allow a
    // closed cycle and make a deterministic downstream reduction depend on
    // the traversal guard. Validate cycles at the cold capture boundary.
    if (!snapshot.hydro_parent.empty()) {
        for (size_t start = 0; start < cells; ++start) {
            int32_t cursor = static_cast<int32_t>(start);
            size_t steps = 0;
            while (cursor >= 0 && steps <= cells) {
                cursor = snapshot.hydro_parent[static_cast<size_t>(cursor)];
                ++steps;
            }
            if (cursor >= 0) {
                error = "runtime_input_hydro_cycle";
                return false;
            }
        }
    }
    if ((!snapshot.trade_passable_lut.empty() ||
         !snapshot.trade_move_cost_lut.empty()) &&
        (snapshot.trade_passable_lut.size() != 256u ||
         snapshot.trade_move_cost_lut.size() != 256u)) {
        error = "runtime_input_lut_shape_mismatch";
        return false;
    }
    for (const int32_t cost : snapshot.trade_move_cost_lut) {
        if (cost < 0) {
            error = "runtime_input_value_invalid";
            return false;
        }
    }
    if (!snapshot.neighbor_offsets.empty()) {
        if (snapshot.neighbor_offsets.size() != cells + 1u ||
            snapshot.neighbor_offsets.front() != 0 ||
            snapshot.neighbor_offsets.back() < 0 ||
            static_cast<size_t>(snapshot.neighbor_offsets.back()) !=
                snapshot.neighbor_indices.size()) {
            error = "runtime_input_csr_invalid";
            return false;
        }
        for (size_t i = 1; i < snapshot.neighbor_offsets.size(); ++i) {
            if (snapshot.neighbor_offsets[i] < snapshot.neighbor_offsets[i - 1]) {
                error = "runtime_input_csr_invalid";
                return false;
            }
            if (static_cast<size_t>(snapshot.neighbor_offsets[i]) >
                    snapshot.neighbor_indices.size()) {
                error = "runtime_input_csr_invalid";
                return false;
            }
        }
    } else if (!snapshot.neighbor_indices.empty() &&
               snapshot.neighbor_indices.size() != cells * 6u) {
        error = "runtime_input_topology_invalid";
        return false;
    }
    for (const int32_t neighbour : snapshot.neighbor_indices) {
        if (neighbour < -1 ||
            (neighbour >= 0 && static_cast<size_t>(neighbour) >= cells)) {
            error = "runtime_input_topology_invalid";
            return false;
        }
    }
    return true;
}

void RuntimeClimateStore::reset(uint32_t cells) {
    cell_count = cells;
    generation = 0;
    climate_generation = 0;
    committed_day = -1;
    auto resize = [cells](std::vector<float> &values) {
        values.assign(cells, 0.0f);
        values.shrink_to_fit();
        values.reserve(cells);
    };
    resize(temperature);
    resize(temperature_30d_ema);
    resize(temperature_365d_ema);
    resize(temperature_baseline);
    resize(thermal_energy);
    resize(moisture);
    resize(plant_available_water);
    resize(water_balance_30d);
    resize(weather_precipitation);
    resize(weather_intensity);
    resize(vapor);
    resize(cloud_water);
    resize(cloud_cover);
    resize(convergence);
    resize(instability);
    weather_type.assign(cells, 0);
    weather_transition.assign(cells, 0);
    resize(snow_cover);
    resize(snowpack);
    resize(sea_ice);
    resize(runoff);
    resize(groundwater);
    resize(river_storage);
    resize(river_discharge);
    resize(riparian_moisture);
    resize(vegetation_vitality);
    resize(vegetation_growth_pressure);
    resize(vegetation_heat_stress);
    resize(vegetation_drought_stress);
    resize(vegetation_cold_stress);
    vegetation_growth_streak.assign(cells, 0);
    vegetation_drought_streak.assign(cells, 0);
    vegetation_succession_candidate.assign(cells, 0);
    climate_anomaly = 0.0f;
    annual_temperature_drift = 0.0f;
    rng_state = 0x9e3779b97f4a7c15ull;
    annual_rng_state = 0x243f6a8885a308d3ull;
    history_cursor = 0;
    temperature_history.assign(static_cast<size_t>(cells) * 365u, 0.0f);
}

bool RuntimeClimateStore::validate(std::string &error) const {
    const size_t n = cell_count;
    const bool shape = same_size(temperature, n) && same_size(temperature_30d_ema, n) &&
        same_size(temperature_365d_ema, n) && same_size(temperature_baseline, n) &&
        same_size(thermal_energy, n) &&
        same_size(moisture, n) && same_size(plant_available_water, n) &&
        same_size(water_balance_30d, n) && same_size(weather_precipitation, n) &&
        same_size(weather_intensity, n) && same_size(vapor, n) &&
        same_size(cloud_water, n) && same_size(cloud_cover, n) &&
        same_size(convergence, n) && same_size(instability, n) &&
        same_size(weather_type, n) && same_size(weather_transition, n) &&
        same_size(snow_cover, n) && same_size(snowpack, n) && same_size(sea_ice, n) &&
        same_size(runoff, n) && same_size(groundwater, n) &&
        same_size(river_storage, n) && same_size(river_discharge, n) &&
        same_size(riparian_moisture, n) && same_size(vegetation_vitality, n) &&
        same_size(vegetation_growth_pressure, n) &&
        same_size(vegetation_heat_stress, n) &&
        same_size(vegetation_drought_stress, n) &&
        same_size(vegetation_cold_stress, n) && same_size(vegetation_growth_streak, n) &&
        same_size(vegetation_drought_streak, n) && same_size(vegetation_succession_candidate, n) &&
        temperature_history.size() == n * 365u;
    if (!shape) {
        set_error(error, "climate_store_shape_invalid");
        return false;
    }
    const bool finite = finite_vector(temperature) && finite_vector(temperature_30d_ema) &&
        finite_vector(temperature_365d_ema) && finite_vector(temperature_baseline) &&
        finite_vector(thermal_energy) &&
        finite_vector(moisture) && finite_vector(plant_available_water) &&
        finite_vector(water_balance_30d) && finite_vector(weather_precipitation) &&
        finite_vector(weather_intensity) && finite_vector(vapor) &&
        finite_vector(cloud_water) && finite_vector(cloud_cover) &&
        finite_vector(convergence) && finite_vector(instability) &&
        finite_vector(snow_cover) && finite_vector(snowpack) && finite_vector(sea_ice) &&
        finite_vector(runoff) && finite_vector(groundwater) && finite_vector(river_storage) &&
        finite_vector(river_discharge) && finite_vector(riparian_moisture) &&
        finite_vector(vegetation_vitality) && finite_vector(temperature_history) &&
        finite_vector(vegetation_growth_pressure) && finite_vector(vegetation_heat_stress) &&
        finite_vector(vegetation_drought_stress) && finite_vector(vegetation_cold_stress) &&
        std::isfinite(climate_anomaly) && std::isfinite(annual_temperature_drift);
    if (!finite) set_error(error, "climate_store_non_finite");
    return finite;
}

uint64_t RuntimeClimateStore::state_hash() const {
    uint64_t hash = mix(FNV_OFFSET, generation);
    hash = mix(hash, climate_generation);
    hash = mix(hash, static_cast<uint64_t>(committed_day));
    hash = mix(hash, rng_state);
    hash = mix(hash, annual_rng_state);
    hash = mix(hash, history_cursor);
    uint32_t anomaly_bits = 0;
    std::memcpy(&anomaly_bits, &climate_anomaly, sizeof(anomaly_bits));
    hash = mix(hash, anomaly_bits);
    hash = mix_vector(hash, temperature);
    hash = mix_vector(hash, temperature_30d_ema);
    hash = mix_vector(hash, temperature_365d_ema);
    hash = mix_vector(hash, temperature_baseline);
    hash = mix_vector(hash, thermal_energy);
    hash = mix_vector(hash, moisture);
    hash = mix_vector(hash, plant_available_water);
    hash = mix_vector(hash, water_balance_30d);
    hash = mix_vector(hash, weather_precipitation);
    hash = mix_vector(hash, weather_intensity);
    hash = mix_vector(hash, vapor);
    hash = mix_vector(hash, cloud_water);
    hash = mix_vector(hash, cloud_cover);
    hash = mix_vector(hash, convergence);
    hash = mix_vector(hash, instability);
    hash = mix_vector(hash, weather_type);
    hash = mix_vector(hash, weather_transition);
    hash = mix_vector(hash, snow_cover);
    hash = mix_vector(hash, snowpack);
    hash = mix_vector(hash, sea_ice);
    hash = mix_vector(hash, runoff);
    hash = mix_vector(hash, groundwater);
    hash = mix_vector(hash, river_storage);
    hash = mix_vector(hash, river_discharge);
    hash = mix_vector(hash, riparian_moisture);
    hash = mix_vector(hash, vegetation_vitality);
    hash = mix_vector(hash, vegetation_growth_pressure);
    hash = mix_vector(hash, vegetation_heat_stress);
    hash = mix_vector(hash, vegetation_drought_stress);
    hash = mix_vector(hash, vegetation_cold_stress);
    hash = mix_vector(hash, vegetation_growth_streak);
    hash = mix_vector(hash, vegetation_drought_streak);
    hash = mix_vector(hash, vegetation_succession_candidate);
    hash = mix_vector(hash, temperature_history);
    uint32_t drift_bits = 0;
    std::memcpy(&drift_bits, &annual_temperature_drift, sizeof(drift_bits));
    hash = mix(hash, drift_bits);
    return hash;
}

void RuntimeCountryStore::reset(uint32_t cells, uint32_t countries) {
    cell_count = cells;
    country_count = countries;
    generation = 0;
    committed_day = -1;
    active.assign(countries, 0);
    entity_generation.assign(countries, 1);
    treasury.assign(countries, 0);
    cell_country_slot.assign(cells, -1);
    territory_offsets.assign(static_cast<size_t>(countries) + 1u, 0);
    territory_cells.clear();
    technologies.assign(countries, 0);
    discovered.assign(countries, 0);
    pending_technologies.assign(countries, 0);
    research_queue.assign(static_cast<size_t>(countries) * 4u, -1);
    research_queue_lengths.assign(countries, 0);
    research_active_slots.clear();
    state_generation = territory_generation = visual_generation = research_generation = 0;
}

bool RuntimeCountryStore::validate(std::string &error) const {
    const bool shape = active.size() == country_count &&
        entity_generation.size() == country_count && treasury.size() == country_count &&
        cell_country_slot.size() == cell_count &&
        territory_offsets.size() == static_cast<size_t>(country_count) + 1u &&
        technologies.size() == country_count && discovered.size() == country_count &&
        pending_technologies.size() == country_count &&
        research_queue.size() == static_cast<size_t>(country_count) * 4u &&
        research_queue_lengths.size() == country_count;
    if (!shape) {
        set_error(error, "country_store_shape_invalid");
        return false;
    }
    if (territory_offsets.empty() || territory_offsets.front() != 0 ||
        territory_offsets.back() != static_cast<int32_t>(territory_cells.size())) {
        set_error(error, "country_territory_csr_invalid");
        return false;
    }
    for (size_t i = 1; i < territory_offsets.size(); ++i) {
        if (territory_offsets[i] < territory_offsets[i - 1]) {
            set_error(error, "country_territory_offsets_not_sorted");
            return false;
        }
    }
    for (int32_t cell : territory_cells) {
        if (cell < 0 || static_cast<uint32_t>(cell) >= cell_count) {
            set_error(error, "country_territory_cell_invalid");
            return false;
        }
    }
    for (int32_t slot : research_active_slots) {
        if (slot < 0 || static_cast<uint32_t>(slot) >= country_count) {
            set_error(error, "country_research_slot_invalid");
            return false;
        }
    }
    return true;
}

uint64_t RuntimeCountryStore::state_hash() const {
    uint64_t hash = mix(FNV_OFFSET, generation);
    hash = mix(hash, static_cast<uint64_t>(committed_day));
    hash = mix_vector(hash, active);
    hash = mix_vector(hash, entity_generation);
    hash = mix_vector(hash, treasury);
    hash = mix_vector(hash, cell_country_slot);
    hash = mix_vector(hash, territory_offsets);
    hash = mix_vector(hash, territory_cells);
    hash = mix_vector(hash, technologies);
    hash = mix_vector(hash, discovered);
    hash = mix_vector(hash, pending_technologies);
    hash = mix_vector(hash, research_queue);
    hash = mix_vector(hash, research_queue_lengths);
    hash = mix_vector(hash, research_active_slots);
    return hash;
}

void RuntimeModifierStore::reset(size_t capacity) {
    generation = bucket_revision = 0;
    committed_day = -1;
    entries.clear(); entries.reserve(capacity);
    expiry_heap.clear(); expiry_heap.reserve(capacity);
}

bool RuntimeModifierStore::validate(std::string &error) const {
    for (const RuntimeModifierEntry &entry : entries) {
        if (entry.stacks < 0 || entry.target_handle == 0 || entry.definition_id == 0) {
            set_error(error, "modifier_store_entry_invalid");
            return false;
        }
    }
    return true;
}

uint64_t RuntimeModifierStore::state_hash() const {
    uint64_t hash = mix(mix(mix(FNV_OFFSET, generation), bucket_revision),
                         static_cast<uint64_t>(committed_day));
    return mix_vector(hash, entries);
}

void RuntimeEffectStore::reset(size_t capacity) {
    generation = 0; next_instance_id = 1; committed_day = -1;
    instances.clear(); instances.reserve(capacity);
}

bool RuntimeEffectStore::validate(std::string &error) const {
    uint64_t previous = 0;
    for (const RuntimeEffectInstance &instance : instances) {
        if (instance.instance_id == 0 || instance.instance_id < previous ||
            (instance.active > 1) || instance.retry_count > 255) {
            set_error(error, "effect_store_entry_invalid");
            return false;
        }
        previous = instance.instance_id;
    }
    return true;
}

uint64_t RuntimeEffectStore::state_hash() const {
    return mix_vector(mix(mix(FNV_OFFSET, generation),
                          static_cast<uint64_t>(committed_day)), instances);
}

void RuntimeIdeologyStore::reset(size_t capacity) {
    generation = 0; committed_day = -1;
    countries.clear(); countries.reserve(capacity);
}

bool RuntimeIdeologyStore::validate(std::string &error) const {
    for (const RuntimeIdeologyCountry &country : countries) {
        if (country.country_handle == 0 || country.dominant_id < -1 ||
            country.pending_transition < -1) {
            set_error(error, "ideology_store_entry_invalid");
            return false;
        }
    }
    return true;
}

uint64_t RuntimeIdeologyStore::state_hash() const {
    return mix_vector(mix(mix(FNV_OFFSET, generation),
                          static_cast<uint64_t>(committed_day)), countries);
}

void RuntimeTriggerStore::reset(size_t state_capacity, size_t distinct_capacity) {
    generation = 0; committed_day = -1;
    states.clear(); states.reserve(state_capacity);
    distinct_keys.clear(); distinct_keys.reserve(distinct_capacity);
}

bool RuntimeTriggerStore::validate(std::string &error) const {
    for (const RuntimeTriggerState &state : states) {
        if (state.target_handle == 0 || state.completed > 1) {
            set_error(error, "trigger_store_entry_invalid");
            return false;
        }
    }
    return true;
}

uint64_t RuntimeTriggerStore::state_hash() const {
    uint64_t hash = mix_vector(mix(mix(FNV_OFFSET, generation),
                                   static_cast<uint64_t>(committed_day)), states);
    return mix_vector(hash, distinct_keys);
}

void RuntimeEconomyStore::reset(uint32_t cells) {
    cell_count = cells; generation = 0; committed_day = -1;
    rng_state = 0x9e3779b97f4a7c15ull;
    ledger_failures = 0;
    auto reset = [cells](std::vector<int64_t> &values) {
        values.assign(cells, 0); values.reserve(cells);
    };
    reset(population); reset(treasury); reset(inventory); reset(production);
    reset(household_demand); reset(construction); reset(price_q16);
}

bool RuntimeEconomyStore::validate(std::string &error) const {
    const bool shape = population.size() == cell_count && treasury.size() == cell_count &&
        inventory.size() == cell_count && production.size() == cell_count &&
        household_demand.size() == cell_count && construction.size() == cell_count &&
        price_q16.size() == cell_count;
    if (!shape) set_error(error, "economy_store_shape_invalid");
    return shape;
}

uint64_t RuntimeEconomyStore::state_hash() const {
    uint64_t hash = mix(mix(mix(FNV_OFFSET, generation),
                            static_cast<uint64_t>(committed_day)), rng_state);
    hash = mix(hash, ledger_failures);
    hash = mix_vector(hash, population); hash = mix_vector(hash, treasury);
    hash = mix_vector(hash, inventory); hash = mix_vector(hash, production);
    hash = mix_vector(hash, household_demand); hash = mix_vector(hash, construction);
    return mix_vector(hash, price_q16);
}

void RuntimeEventsStore::reset(size_t capacity) {
    generation = 0; next_event_id = 1; committed_day = -1;
    journal.clear(); journal.reserve(capacity);
}

bool RuntimeEventsStore::validate(std::string &error) const {
    uint64_t previous = 0;
    for (const RuntimeEventRecord &event : journal) {
        if (event.event_id == 0 || event.event_id < previous || event.committed > 1 ||
            event.gameplay > 1 || event.visual > 1 || event.debug > 1) {
            set_error(error, "events_store_entry_invalid");
            return false;
        }
        previous = event.event_id;
    }
    return true;
}

uint64_t RuntimeEventsStore::state_hash() const {
    uint64_t hash = mix(mix(mix(FNV_OFFSET, generation), next_event_id),
                        static_cast<uint64_t>(committed_day));
    return mix_vector(hash, journal);
}

void RuntimeAuthoritativeDomainStores::reset(uint32_t cell_count,
        uint32_t country_count, uint32_t technology_words) {
    (void)technology_words;
    climate.reset(cell_count);
    country.reset(cell_count, country_count);
    modifier.reset(std::max<size_t>(64u, country_count * 4u));
    effect.reset(std::max<size_t>(64u, country_count * 4u));
    ideology.reset(std::max<size_t>(64u, country_count));
    trigger.reset(4096u, 65536u);
    economy.reset(cell_count);
    events.reset(RUNTIME_DOMAIN_EVENT_CAPACITY);
    _completed_mask = runtime_domain_mask(RuntimeDomainId::COMMIT);
}

bool RuntimeAuthoritativeDomainStores::self_test(std::string &error) {
    RuntimeAuthoritativeDomainStores stores;
    stores.reset(4u, 2u);
    if (!stores.validate_all(error)) return false;
    const uint64_t initial_hash = stores.state_hash();
    stores.country.active[0] = 1;
    stores.country.entity_generation[0] = 2;
    stores.country.territory_offsets = {0, 2, 2};
    stores.country.territory_cells = {0, 1};
    stores.country.research_active_slots = {0};
    stores.climate.temperature[0] = 12.5f;
    stores.events.journal.push_back(RuntimeEventRecord{});
    stores.events.journal.back().event_id = 1;
    stores.events.journal.back().committed = 1;
    if (!stores.validate_all(error) || stores.state_hash() == initial_hash) return false;
    const RuntimeDomainDayResult barrier = stores.validate_day_barrier(
        RuntimeDomainId::CLIMATE, 0, 1);
    if (!barrier.header.preflight_ok || !barrier.planned || barrier.committed ||
        barrier.ack_barrier_complete) {
        error = "domain_barrier_contract_invalid";
        return false;
    }
    stores.climate.temperature[0] = std::numeric_limits<float>::quiet_NaN();
    if (stores.validate_all(error) || error != "climate_store_non_finite") return false;
    error.clear();
    return true;
}

bool RuntimeAuthoritativeDomainStores::validate_all(std::string &error) const {
    error.clear();
    return climate.validate(error) && country.validate(error) &&
        modifier.validate(error) && effect.validate(error) &&
        ideology.validate(error) && trigger.validate(error) &&
        economy.validate(error) && events.validate(error);
}

uint64_t RuntimeAuthoritativeDomainStores::state_hash() const {
    uint64_t hash = FNV_OFFSET;
    hash = mix(hash, climate.state_hash());
    hash = mix(hash, country.state_hash());
    hash = mix(hash, modifier.state_hash());
    hash = mix(hash, effect.state_hash());
    hash = mix(hash, ideology.state_hash());
    hash = mix(hash, trigger.state_hash());
    hash = mix(hash, economy.state_hash());
    hash = mix(hash, events.state_hash());
    return hash;
}

RuntimeDomainDayResult RuntimeAuthoritativeDomainStores::validate_day_barrier(
        RuntimeDomainId domain, int64_t day, uint64_t input_generation) const {
    RuntimeDomainDayResult result;
    result.header.domain = static_cast<uint16_t>(domain);
    result.header.abi_version = RUNTIME_DOMAIN_POD_ABI_VERSION;
    result.header.day = day;
    result.header.input_generation = input_generation;
    result.header.state_hash = state_hash();
    if (day < 0 || input_generation == 0) {
        runtime_copy_text(result.error, "domain_barrier_input_invalid");
        result.header.preflight_ok = false;
        return result;
    }
    std::string validation_error;
    if (!validate_all(validation_error)) {
        runtime_copy_text(result.error, validation_error.c_str());
        result.header.preflight_ok = false;
        return result;
    }
    result.header.preflight_ok = true;
    result.planned = 1;
    result.committed = (domain == RuntimeDomainId::COMMIT) ? 1 : 0;
    result.ack_barrier_complete = result.committed;
    return result;
}

RuntimeDomainReport RuntimeAuthoritativeDomainStores::stage_preflight(
        RuntimeDomainId domain, const RuntimeDayContext &context,
        const RuntimeEnvironmentSnapshot *environment) const {
    RuntimeDomainReport report;
    report.domain = domain;
    report.day = context.day;
    report.input_generation = context.input_generation;
    report.base_generation = generation_for_domain(domain);
    const bool valid_context = context.day >= 0 && context.input_generation != 0;
    std::string error;
    if (!valid_context) {
        report.preflight_ok = 0;
        report.fallback = 1;
        runtime_copy_text(report.fallback_reason, "domain_context_invalid");
        return report;
    }
    if (domain == RuntimeDomainId::INPUT_CAPTURE ||
        domain == RuntimeDomainId::CLIMATE) {
        if (environment == nullptr ||
            !validate_runtime_environment_snapshot(*environment, error)) {
            report.preflight_ok = 0;
            report.fallback = 1;
            runtime_copy_text(report.fallback_reason,
                              error.empty() ? "runtime_input_missing" : error.c_str());
            return report;
        }
    }
    if (!validate_all(error)) {
        report.preflight_ok = 0;
        report.fallback = 1;
        runtime_copy_text(report.fallback_reason, error.c_str());
        return report;
    }
    report.preflight_ok = 1;
    report.completed = (domain == RuntimeDomainId::COMMIT) ? 1 : 0;
    report.fallback = report.completed ? 0 : 1;
    if (!report.completed) {
        runtime_copy_text(report.fallback_reason, "domain_handler_not_migrated");
    }
    report.timing.state_hash = state_hash();
    return report;
}

uint64_t RuntimeAuthoritativeDomainStores::generation_for_domain(
        RuntimeDomainId domain) const {
    switch (domain) {
        case RuntimeDomainId::CLIMATE: return climate.generation;
        case RuntimeDomainId::COUNTRY: return country.generation;
        case RuntimeDomainId::MODIFIER: return modifier.generation;
        case RuntimeDomainId::EFFECT: return effect.generation;
        case RuntimeDomainId::IDEOLOGY: return ideology.generation;
        case RuntimeDomainId::TRIGGER_INPUT: return trigger.generation;
        case RuntimeDomainId::ECONOMY: return economy.generation;
        case RuntimeDomainId::EVENTS: return events.generation;
        default: return 0;
    }
}

void RuntimeAuthoritativeDomainStores::set_completed(RuntimeDomainId domain,
        bool completed) {
    const uint32_t mask = runtime_domain_mask(domain);
    if (completed) _completed_mask |= mask;
    else _completed_mask &= ~mask;
}

} // namespace pk
