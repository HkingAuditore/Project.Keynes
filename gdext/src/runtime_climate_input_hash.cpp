#include "runtime_climate_kernel.h"

#include <cstring>

namespace pk {
namespace {
constexpr uint64_t FNV_OFFSET = 1469598103934665603ull;
constexpr uint64_t FNV_PRIME = 1099511628211ull;

uint64_t mix(uint64_t hash, uint64_t value) noexcept {
    hash ^= value + 0x9e3779b97f4a7c15ull + (hash << 6u) + (hash >> 2u);
    return hash * FNV_PRIME;
}

// This digest identifies the in-flight input. Saved climate state uses the
// store's own hash. Mix every byte in words, preserving the lane lengths and
// floating-point bit patterns used by both the sealed and diagnostic paths.
template <typename T>
uint64_t mix_vector(uint64_t hash, const std::vector<T> &values) noexcept {
    hash = mix(hash, values.size());
    const auto *bytes = reinterpret_cast<const unsigned char *>(values.data());
    size_t remaining = values.size() * sizeof(T);
    while (remaining >= sizeof(uint64_t)) {
        uint64_t word;
        std::memcpy(&word, bytes, sizeof(word));
        hash = mix(hash, word);
        bytes += sizeof(word);
        remaining -= sizeof(word);
    }
    if (remaining != 0) {
        uint64_t tail = 0;
        std::memcpy(&tail, bytes, remaining);
        hash = mix(hash, tail);
    }
    return hash;
}
} // namespace

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
    hash = mix_vector(hash, input.cell_pos_x); hash = mix_vector(hash, input.cell_pos_y);
    hash = mix_vector(hash, input.climate_physics_seed_slp);
    hash = mix_vector(hash, input.climate_physics_seed_psi);
    hash = mix_vector(hash, input.climate_physics_seed_upwelling);
    // 按语义字段哈希，不能读取 POD padding（会破坏重试确定性）。
    const auto &p = input.climate_physics_knobs;
    const double physics_scalars[] = {
        p.slp_lat_amp, p.slp_land_amp, p.slp_water_damp, p.slp_interior_boost, p.slp_coast_damp,
        p.slp_thermal_weight, p.slp_ice_high_weight, p.slp_snow_high_weight, p.slp_moist_low_weight,
        p.slp_response_rate, p.slp_synoptic_amp, p.slp_target_p95, double(p.slp_mobile_low_count),
        p.slp_mobile_low_amp, p.slp_mobile_low_sigma, p.slp_mobile_low_period_days,
        double(p.slp_smooth_passes), double(p.slp_recenter), p.wind_response_rate,
        p.wind_max_turn_deg_per_day, p.wind_min_flux_for_dir_update, p.wind_synoptic_amp,
        p.wind_synoptic_period_days, double(p.wind_terrain_aware), double(p.wind_belt_only_debug),
        p.wind_momentum_advect_w, p.wind_momentum_diffuse_w_daily, double(p.wind_traj_table_enabled),
        p.wind_traj_pos_scale, p.wind_traj_dt_days, double(p.wind_traj_weather_share), p.wind_div_damp_alpha,
        double(p.thermal_monsoon_enabled), p.thermal_monsoon_lat_limit, p.thermal_monsoon_deadband,
        p.thermal_monsoon_full_contrast, p.thermal_monsoon_gain, p.thermal_monsoon_breeze_floor,
        double(p.days_per_year), p.axial_tilt_deg, p.insolation_daylen_amp, double(p.lat_lut_bins),
        double(p.land_lf_mountain), double(p.land_lf_peak), double(p.land_lf_hill),
        double(p.daily_split), double(p.daily_period_days), double(p.ocean_period_days), double(p.world_seed),
        p.wrap_origin_x, p.wrap_period_x, double(p.enabled), double(p.ready), double(p.psi_warm_start),
        double(p.psi.total_iters), p.psi.omega, p.psi.r_base, p.psi.beta_floor, p.psi.source_scale,
        p.psi.oc_scale, p.psi.oc_max_mag, p.psi.thermohaline_weight, p.psi.upwelling_highlat_abs,
        p.psi.cold_sink_temp, p.psi.response_rate, p.psi.thermal_current_weight, p.psi.density_cold_weight,
        p.psi.density_ice_weight, p.psi.depth_curl_damp, p.psi.sea_level, p.psi.depth_ref, p.psi.topo_steer_w,
        double(p.psi.early_exit), double(p.psi.min_iters), double(p.psi.check_every), p.psi.residual_epsilon,
        p.upwelling.ekman_gain, p.upwelling.cold_sink_gain, p.upwelling.highlat_abs, p.upwelling.cold_sink_temp,
    };
    for (double v : physics_scalars) { uint64_t bits; std::memcpy(&bits, &v, sizeof(bits)); hash = mix(hash, bits); }
    hash = mix(hash, p.water_id_count);
    for (uint8_t id : p.water_terrain_ids) hash = mix(hash, id);
    return hash;
}

} // namespace pk
