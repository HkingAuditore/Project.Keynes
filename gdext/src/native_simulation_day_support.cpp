#include "native_simulation_day_support.h"
#include "runtime_switch_registry.h"
namespace pk {
std::FILE *sim_day_trace_file() {
    static std::FILE *file = [] () -> std::FILE * {
        const char *path = pk::runtime_switch_value(pk::RuntimeSwitch::PK_SIM_DAY_TRACE);
        return path != nullptr && path[0] != '\0' ? std::fopen(path, "w") : nullptr;
    }();
    return file;
}

void sim_trace_environment_fields(std::FILE *trace, const RuntimeEnvironmentSnapshot &s) {
    std::fprintf(trace, "[env-fields] day=%lld", static_cast<long long>(s.day));
#define PK_TRACE_FIELD(name) \
    std::fprintf(trace, " " #name "=%llu", static_cast<unsigned long long>(sim_trace_vector_hash(s.name)))
    PK_TRACE_FIELD(cell_temp); PK_TRACE_FIELD(cell_temp_30d); PK_TRACE_FIELD(cell_temp_365d);
    PK_TRACE_FIELD(cell_temp_baseline_year); PK_TRACE_FIELD(cell_base_moisture); PK_TRACE_FIELD(cell_moisture);
    PK_TRACE_FIELD(cell_plant_available_water); PK_TRACE_FIELD(cell_soil_moisture);
    PK_TRACE_FIELD(cell_water_balance_30d); PK_TRACE_FIELD(cell_weather_precip); PK_TRACE_FIELD(cell_snow_cover);
    PK_TRACE_FIELD(cell_weather_intensity); PK_TRACE_FIELD(cell_weather_vapor);
    PK_TRACE_FIELD(cell_weather_cloud_water); PK_TRACE_FIELD(cell_weather_cloud); PK_TRACE_FIELD(cell_weather_type);
    PK_TRACE_FIELD(cell_weather_transition); PK_TRACE_FIELD(cell_sea_ice_frac_prev);
    PK_TRACE_FIELD(cell_river_discharge_30d); PK_TRACE_FIELD(cell_vegetation_vitality);
    PK_TRACE_FIELD(cell_insolation_dev); PK_TRACE_FIELD(cell_heat_input); PK_TRACE_FIELD(cell_wind_x);
    PK_TRACE_FIELD(cell_wind_y); PK_TRACE_FIELD(cell_wind_speed); PK_TRACE_FIELD(cell_ocean_current_x);
    PK_TRACE_FIELD(cell_ocean_current_y); PK_TRACE_FIELD(cell_air_mass_temp_anomaly);
    PK_TRACE_FIELD(cell_ocean_thermal_anomaly); PK_TRACE_FIELD(cell_local_thermal_anomaly);
    PK_TRACE_FIELD(cell_temperature_transport_anomaly); PK_TRACE_FIELD(cell_ema_initialized);
    PK_TRACE_FIELD(vegetation); PK_TRACE_FIELD(cover); PK_TRACE_FIELD(is_water); PK_TRACE_FIELD(has_river);
    PK_TRACE_FIELD(canal_edge_mask); PK_TRACE_FIELD(canal_water); PK_TRACE_FIELD(visible);
    PK_TRACE_FIELD(building_resource_reserve); PK_TRACE_FIELD(building_resource_extra);
    PK_TRACE_FIELD(climate_physics_seed_slp); PK_TRACE_FIELD(climate_physics_seed_psi);
    PK_TRACE_FIELD(climate_physics_seed_upwelling); PK_TRACE_FIELD(cyclone_seed_blob);
#undef PK_TRACE_FIELD
    std::fprintf(trace, " vision=%llu season=%.17g anomaly=%.17g\n",
        static_cast<unsigned long long>(s.vision_revision), s.season_phase, s.climate_anomaly);
}

bool d7_read_u32(const uint8_t *bytes, size_t size, size_t &cursor,
                 uint32_t &out) {
    if (cursor > size || size - cursor < 4u) return false;
    out = static_cast<uint32_t>(bytes[cursor]) |
        (static_cast<uint32_t>(bytes[cursor + 1u]) << 8u) |
        (static_cast<uint32_t>(bytes[cursor + 2u]) << 16u) |
        (static_cast<uint32_t>(bytes[cursor + 3u]) << 24u);
    cursor += 4u;
    return true;
}

bool d7_read_u64(const uint8_t *bytes, size_t size, size_t &cursor,
                 uint64_t &out) {
    if (cursor > size || size - cursor < 8u) return false;
    out = 0;
    for (uint32_t i = 0; i < 8u; ++i)
        out |= static_cast<uint64_t>(bytes[cursor + i]) << (i * 8u);
    cursor += 8u;
    return true;
}

bool d7_read_i32(const uint8_t *bytes, size_t size, size_t &cursor,
                 int32_t &out) {
    uint32_t raw = 0;
    if (!d7_read_u32(bytes, size, cursor, raw)) return false;
    std::memcpy(&out, &raw, sizeof(out));
    return true;
}

bool d7_read_i64(const uint8_t *bytes, size_t size, size_t &cursor,
                 int64_t &out) {
    uint64_t raw = 0;
    if (!d7_read_u64(bytes, size, cursor, raw)) return false;
    std::memcpy(&out, &raw, sizeof(out));
    return true;
}
} // namespace pk
