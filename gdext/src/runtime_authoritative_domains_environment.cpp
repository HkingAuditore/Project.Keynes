#include "runtime_authoritative_domains.h"
#include "runtime_domain_pod.h"
#include "runtime_climate_physics.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>

namespace pk {

namespace {
bool finite_vector(const std::vector<float> &values) noexcept {
    // A reduction lets the compiler test several lanes at once.
    bool all_finite = true;
    for (float value : values) all_finite &= std::isfinite(value);
    return all_finite;
}
} // namespace

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
    const auto finite = finite_vector;
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
    // Range checks cannot reject cycles. Prove each path once so branches
    // reaching a shared downstream river do not walk that river again.
    if (!snapshot.hydro_parent.empty()) {
        enum Visit : uint8_t { UNVISITED, IN_PATH, CHECKED };
        std::vector<Visit> visits(cells, UNVISITED);
        for (size_t start = 0; start < cells; ++start) {
            int32_t cursor = static_cast<int32_t>(start);
            while (cursor >= 0 && visits[static_cast<size_t>(cursor)] == UNVISITED) {
                visits[static_cast<size_t>(cursor)] = IN_PATH;
                cursor = snapshot.hydro_parent[static_cast<size_t>(cursor)];
            }
            if (cursor >= 0 && visits[static_cast<size_t>(cursor)] == IN_PATH) {
                error = "runtime_input_hydro_cycle";
                return false;
            }
            cursor = static_cast<int32_t>(start);
            while (cursor >= 0 && visits[static_cast<size_t>(cursor)] == IN_PATH) {
                visits[static_cast<size_t>(cursor)] = CHECKED;
                cursor = snapshot.hydro_parent[static_cast<size_t>(cursor)];
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

} // namespace pk
