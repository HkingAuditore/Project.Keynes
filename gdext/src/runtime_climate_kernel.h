#pragma once

#include "runtime_authoritative_domains.h"

#include <array>
#include <cstdint>
#include <string>
#include <vector>

namespace pk {

// Numeric cold-start contract for the worker Climate graph. The facade builds
// this from the selected profile and map constants before a trace is accepted.
struct RuntimeClimateCatalog {
    static constexpr uint32_t FORMULA_VERSION = 1u;
    uint32_t abi_version = RUNTIME_DOMAIN_POD_ABI_VERSION;
    uint32_t formula_version = FORMULA_VERSION;
    uint32_t cell_count = 0;
    uint32_t map_width = 0;
    uint32_t map_height = 0;
    uint64_t hash = 0;
    // Pass-A numeric configuration. Values are copied from the immutable
    // capture boundary; defaults preserve the existing diagnostic fixture.
    float insol_amp = 0.20f;
    float insol_gain = 1.0f;
    float axial_tilt_deg = 23.5f;
    float day_length_gain = 0.35f;
    float solar_gain = 1.0f;
    float insol_dev_min = -1.0f;
    float insol_dev_max = 1.0f;
    float land_continentality = 1.0f;
    float thermal_inertia_land = 0.35f;
    float thermal_inertia_water = 0.045f;
    float thermal_inertia_snow = 0.09f;
    float thermal_inertia_high_mountain = 0.16f;
    float thermal_daily_delta_cap = 0.15f;
    float runtime_moisture_base_relax_rate = 0.24f;
    float runtime_moisture_weather_vapor_weight = 0.12f;
    float runtime_moisture_precip_weight = 0.78f;
    float runtime_moisture_soil_weight = 1.82f;
    float runtime_moisture_soil_dry_weight = 2.21f;
    float runtime_moisture_water_balance_weight = 1.04f;
    float runtime_moisture_water_balance_dry_weight = 1.30f;
    float snowpack_cover_low = 0.05f;
    float snowpack_cover_full = 0.80f;
    float sea_level = 0.5f;
    float dt_days_cap = 30.0f;
    float sea_ice_freeze = -1.8f;
    float sea_ice_melt = -0.5f;
    float soil_capacity = 1.0f;
    uint32_t days_per_year = 365u;
};

enum class RuntimeClimateStage : uint8_t {
    PASS_A = 0,
    PASS_B,
    OCEAN_WATER,
    OCEAN_LAND,
    WIND_AIR,
    WIND_SURFACE,
    SEA_ICE,
    TRANSPIRATION,
    ALBEDO,
    VEGETATION_DYNAMICS,
    CLIMATE_FEEDBACK,
    WEATHER,
    RUNTIME_HYDROLOGY,
    STAGE_B_AFTER_HYDROLOGY,
    COUNT,
};

constexpr size_t RUNTIME_CLIMATE_STAGE_COUNT =
    static_cast<size_t>(RuntimeClimateStage::COUNT);

struct RuntimeClimateKernelReport {
    std::array<uint64_t, RUNTIME_CLIMATE_STAGE_COUNT> stage_work{};
    std::array<double, RUNTIME_CLIMATE_STAGE_COUNT> stage_ms{};
    uint64_t work_units = 0;
    uint32_t changed_cells = 0;
    uint64_t input_hash = 0;
    uint64_t state_hash = 0;
    uint8_t completed = 0;
    char error[64]{};
};

struct RuntimeClimateParityReport {
    bool compared = false;
    bool matched = false;
    int64_t day = -1;
    uint32_t cell = 0;
    uint16_t stage = 0;
    uint64_t input_generation = 0;
    uint64_t base_generation = 0;
    uint64_t trace_hash = 0;
    uint64_t reference_state_hash = 0;
    uint64_t worker_state_hash = 0;
    char field[48]{};
    char reference_bits[24]{};
    char worker_bits[24]{};
    char reason[64]{};
};

struct RuntimeClimateVisualIntent {
    uint32_t cell = 0;
    uint16_t field = 0;
    float value = 0.0f;
    uint64_t generation = 0;
};

// Pure C++ staged kernel. It does not own clock, host, visual resources, or
// source objects. The caller supplies two preallocated stores: plan writes the
// next store; commit swaps them only at the day barrier.
class RuntimeClimateKernel {
public:
    void reset(uint32_t cell_count);
    bool compile_catalog(const RuntimeEnvironmentSnapshot &input,
                         RuntimeClimateCatalog &catalog, std::string &error) const;
    bool plan_day(int64_t day, const RuntimeEnvironmentSnapshot &input,
                  const RuntimeClimateCatalog &catalog,
                  const RuntimeClimateStore &current, RuntimeClimateStore &next,
                  RuntimeClimateKernelReport &report) const;
    static void commit(RuntimeClimateStore &current, RuntimeClimateStore &next);
    static uint64_t input_hash(const RuntimeEnvironmentSnapshot &input);
    static bool self_test(std::string &error);
};

} // namespace pk
