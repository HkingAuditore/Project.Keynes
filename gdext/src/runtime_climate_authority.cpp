#include "runtime_climate_authority.h"

#include <chrono>
#include <cstring>
#include <limits>

namespace pk {
namespace {
constexpr uint32_t CLIMATE_SECTION_MARKER = 0x324d4c43u; // CLM2
// CLM2 ABI 2 adds the compiled map shape to the section header.  Runtime
// Domain POD ABI and save-section ABI are intentionally versioned separately.
constexpr uint32_t CLIMATE_SECTION_ABI = 2u;
constexpr uint64_t FNV_OFFSET = 1469598103934665603ull;
constexpr uint64_t FNV_PRIME = 1099511628211ull;

void set_error(RuntimeClimateVerticalReport &report, const char *value) {
    size_t i = 0;
    if (value != nullptr) {
        for (; i + 1u < sizeof(report.error) && value[i] != '\0'; ++i)
            report.error[i] = value[i];
    }
    report.error[i] = '\0';
    report.preflight_ok = 0;
}

uint64_t checksum(const uint8_t *bytes, size_t size) {
    uint64_t value = FNV_OFFSET;
    for (size_t i = 0; i < size; ++i) {
        value ^= bytes[i];
        value *= FNV_PRIME;
    }
    return value;
}

void append_u32(std::vector<uint8_t> &out, uint32_t value) {
    for (uint32_t i = 0; i < 4; ++i)
        out.push_back(static_cast<uint8_t>((value >> (i * 8u)) & 0xffu));
}
void append_u64(std::vector<uint8_t> &out, uint64_t value) {
    for (uint32_t i = 0; i < 8; ++i)
        out.push_back(static_cast<uint8_t>((value >> (i * 8u)) & 0xffu));
}
void append_i64(std::vector<uint8_t> &out, int64_t value) {
    append_u64(out, static_cast<uint64_t>(value));
}
void append_f32(std::vector<uint8_t> &out, float value) {
    uint32_t bits = 0;
    std::memcpy(&bits, &value, sizeof(bits));
    append_u32(out, bits);
}
void append_float_vector(std::vector<uint8_t> &out,
                         const std::vector<float> &values) {
    append_u32(out, static_cast<uint32_t>(values.size()));
    for (float value : values) append_f32(out, value);
}
void append_u8_vector(std::vector<uint8_t> &out,
                      const std::vector<uint8_t> &values) {
    append_u32(out, static_cast<uint32_t>(values.size()));
    out.insert(out.end(), values.begin(), values.end());
}
void append_i32_vector(std::vector<uint8_t> &out,
                       const std::vector<int32_t> &values) {
    append_u32(out, static_cast<uint32_t>(values.size()));
    for (int32_t value : values) append_u32(out, static_cast<uint32_t>(value));
}

struct Reader {
    const uint8_t *data = nullptr;
    size_t size = 0;
    size_t cursor = 0;

    bool u32(uint32_t &value) {
        if (cursor > size || size - cursor < 4u) return false;
        value = 0;
        for (uint32_t i = 0; i < 4; ++i)
            value |= static_cast<uint32_t>(data[cursor + i]) << (i * 8u);
        cursor += 4u;
        return true;
    }
    bool u64(uint64_t &value) {
        if (cursor > size || size - cursor < 8u) return false;
        value = 0;
        for (uint32_t i = 0; i < 8; ++i)
            value |= static_cast<uint64_t>(data[cursor + i]) << (i * 8u);
        cursor += 8u;
        return true;
    }
    bool i64(int64_t &value) {
        uint64_t raw = 0;
        if (!u64(raw)) return false;
        value = static_cast<int64_t>(raw);
        return true;
    }
    bool f32(float &value) {
        uint32_t raw = 0;
        if (!u32(raw)) return false;
        std::memcpy(&value, &raw, sizeof(value));
        return true;
    }
    bool floats(std::vector<float> &values, uint32_t expected) {
        uint32_t count = 0;
        if (!u32(count) || count != expected) return false;
        values.resize(count);
        for (float &value : values) if (!f32(value)) return false;
        return true;
    }
    bool bytes(std::vector<uint8_t> &values, uint32_t expected) {
        uint32_t count = 0;
        if (!u32(count) || count != expected || cursor > size || size - cursor < count)
            return false;
        values.assign(data + cursor, data + cursor + count);
        cursor += count;
        return true;
    }
    bool ints(std::vector<int32_t> &values, uint32_t expected) {
        uint32_t count = 0;
        if (!u32(count) || count != expected) return false;
        values.resize(count);
        for (int32_t &value : values) {
            uint32_t raw = 0;
            if (!u32(raw)) return false;
            value = static_cast<int32_t>(raw);
        }
        return true;
    }
};

#define CLIMATE_CELL_FLOAT_LANES(X) \
    X(temperature) X(temperature_30d_ema) X(temperature_365d_ema) \
    X(temperature_baseline) X(thermal_energy) X(moisture) \
    X(plant_available_water) X(water_balance_30d) X(weather_precipitation) \
    X(weather_intensity) X(vapor) X(cloud_water) X(cloud_cover) X(convergence) \
    X(instability) X(snow_cover) X(snowpack) X(sea_ice) X(runoff) X(groundwater) \
    X(river_storage) X(river_discharge) X(riparian_moisture) X(vegetation_vitality) \
    X(vegetation_growth_pressure) X(vegetation_heat_stress) \
    X(vegetation_drought_stress) X(vegetation_cold_stress)
#define CLIMATE_U8_LANES(X) \
    X(weather_type) X(weather_transition) X(vegetation_succession_candidate)
#define CLIMATE_I32_LANES(X) \
    X(vegetation_growth_streak) X(vegetation_drought_streak)
} // namespace

void RuntimeClimateAuthority::reset(uint32_t cell_count) {
    _kernel.reset(cell_count);
    _store.reset(cell_count);
    _next.reset(cell_count);
    _catalog = RuntimeClimateCatalog{};
    _catalog_ready = false;
    _plan_ready = false;
    _planned_day = -1;
    _last_input_generation = 0;
    _last_report = RuntimeClimateVerticalReport{};
}

bool RuntimeClimateAuthority::seed_from_input(
        const RuntimeEnvironmentSnapshot &environment, std::string &error) {
    if (_store.cell_count != environment.cell_count) {
        error = "climate_seed_shape_mismatch";
        return false;
    }
    const size_t cells = environment.cell_count;
    for (size_t i = 0; i < cells; ++i) {
        _store.temperature[i] = environment.cell_temp[i];
        _store.temperature_30d_ema[i] = environment.cell_temp_30d.empty()
            ? environment.cell_temp[i] : environment.cell_temp_30d[i];
        _store.temperature_365d_ema[i] = _store.temperature_30d_ema[i];
        _store.thermal_energy[i] = environment.cell_temp[i];
        _store.moisture[i] = environment.cell_moisture.empty()
            ? 0.0f : environment.cell_moisture[i];
        _store.plant_available_water[i] = environment.cell_plant_available_water.empty()
            ? 0.0f : environment.cell_plant_available_water[i];
        _store.water_balance_30d[i] = _store.plant_available_water[i];
        _store.weather_precipitation[i] = environment.cell_weather_precip.empty()
            ? 0.0f : environment.cell_weather_precip[i];
        _store.weather_intensity[i] = environment.cell_weather_intensity.empty()
            ? 0.0f : environment.cell_weather_intensity[i];
        _store.snow_cover[i] = environment.cell_snow_cover.empty()
            ? 0.0f : environment.cell_snow_cover[i];
        _store.snowpack[i] = _store.snow_cover[i];
        _store.vegetation_vitality[i] = 0.5f;
    }
    _next = _store;
    return _store.validate(error) && _next.validate(error);
}

bool RuntimeClimateAuthority::plan_day(
        int64_t day, const RuntimeEnvironmentSnapshot &environment,
        RuntimeClimateVerticalReport &report) {
    report = RuntimeClimateVerticalReport{};
    const auto begin = std::chrono::steady_clock::now();
    std::string error;
    if (day < 0 || environment.day != day) {
        set_error(report, day < 0 ? "climate_day_invalid"
                                  : "climate_environment_day_mismatch");
        report.plan_ms = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - begin).count();
        _last_report = report;
        return false;
    }
    if (environment.climate_catalog_abi_version !=
        RUNTIME_DOMAIN_POD_ABI_VERSION) {
        set_error(report, "climate_catalog_abi_mismatch");
        report.plan_ms = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - begin).count();
        _last_report = report;
        return false;
    }
    if (!validate_runtime_environment_snapshot(environment, error)) {
        set_error(report, error.c_str());
        report.plan_ms = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - begin).count();
        _last_report = report;
        return false;
    }
    if (_store.cell_count == 0 && _store.generation == 0 &&
        _store.committed_day < 0) {
        reset(environment.cell_count);
    }
    if (_plan_ready) {
        set_error(report, "climate_plan_already_pending");
        report.plan_ms = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - begin).count();
        _last_report = report;
        return false;
    }
    if (!_catalog_ready) {
        if (!_kernel.compile_catalog(environment, _catalog, error) ||
            !seed_from_input(environment, error)) {
            set_error(report, error.c_str());
            report.plan_ms = std::chrono::duration<double, std::milli>(
                std::chrono::steady_clock::now() - begin).count();
            _last_report = report;
            return false;
        }
        _catalog_ready = true;
    }
    if (_last_input_generation != 0 &&
        environment.generation <= _last_input_generation) {
        set_error(report, "climate_input_generation_not_monotonic");
        report.plan_ms = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - begin).count();
        _last_report = report;
        return false;
    }
    if (_store.committed_day >= 0 && day <= _store.committed_day) {
        set_error(report, "climate_day_not_monotonic");
        report.plan_ms = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - begin).count();
        _last_report = report;
        return false;
    }
    if (_catalog.abi_version != environment.climate_catalog_abi_version) {
        set_error(report, "climate_catalog_abi_mismatch");
        report.plan_ms = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - begin).count();
        _last_report = report;
        return false;
    }
    if (_catalog.cell_count != environment.cell_count) {
        set_error(report, "climate_catalog_shape_mismatch");
        report.plan_ms = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - begin).count();
        _last_report = report;
        return false;
    }
    if (((_catalog.map_width != 0 || environment.climate_map_width != 0) &&
         _catalog.map_width != environment.climate_map_width) ||
        ((_catalog.map_height != 0 || environment.climate_map_height != 0) &&
         _catalog.map_height != environment.climate_map_height)) {
        set_error(report, "climate_catalog_map_shape_mismatch");
        report.plan_ms = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - begin).count();
        _last_report = report;
        return false;
    }
    if (environment.climate_catalog_hash != 0 &&
        environment.climate_catalog_hash != _catalog.hash) {
        set_error(report, "climate_catalog_hash_mismatch");
        report.plan_ms = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - begin).count();
        _last_report = report;
        return false;
    }
    RuntimeClimateKernelReport kernel_report;
    if (!_kernel.plan_day(day, environment, _catalog, _store, _next,
                          kernel_report)) {
        set_error(report, kernel_report.error);
        report.plan_ms = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - begin).count();
        _last_report = report;
        return false;
    }
    report.work_units = kernel_report.work_units;
    report.changed_cells = kernel_report.changed_cells;
    report.state_hash = kernel_report.state_hash;
    report.input_hash = kernel_report.input_hash;
    report.catalog_hash = _catalog.hash;
    report.input_generation = environment.generation;
    report.stage_ms = kernel_report.stage_ms;
    report.stage_work = kernel_report.stage_work;
    report.plan_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - begin).count();
    _planned_day = day;
    _plan_ready = true;
    _last_report = report;
    return true;
}

bool RuntimeClimateAuthority::commit_day(
        int64_t day, RuntimeClimateVerticalReport &report) {
    if (!_plan_ready || _planned_day != day) {
        report = RuntimeClimateVerticalReport{};
        set_error(report, "climate_plan_missing");
        return false;
    }
    const auto begin = std::chrono::steady_clock::now();
    _kernel.commit(_store, _next);
    report.state_hash = _store.state_hash();
    report.replay_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - begin).count();
    report.completed = 1;
    report.preflight_ok = 1;
    _last_input_generation = report.input_generation;
    _plan_ready = false;
    _last_report = report;
    return true;
}

void RuntimeClimateAuthority::discard_plan() {
    _plan_ready = false;
    _planned_day = -1;
}

bool RuntimeClimateAuthority::serialize(std::vector<uint8_t> &bytes,
                                        std::string &error) const {
    error.clear();
    std::string validation_error;
    if (!_store.validate(validation_error)) {
        error = validation_error;
        return false;
    }
    std::vector<uint8_t> payload;
    payload.reserve(static_cast<size_t>(_store.cell_count) * 160u +
                    _store.temperature_history.size() * sizeof(float));
    append_u32(payload, _store.cell_count);
    append_u64(payload, _store.generation);
    append_u64(payload, _store.climate_generation);
    append_i64(payload, _store.committed_day);
    append_f32(payload, _store.climate_anomaly);
    append_f32(payload, _store.annual_temperature_drift);
    append_u64(payload, _store.rng_state);
    append_u64(payload, _store.annual_rng_state);
    append_u32(payload, _store.history_cursor);
#define APPEND_FLOAT(name) append_float_vector(payload, _store.name);
    CLIMATE_CELL_FLOAT_LANES(APPEND_FLOAT)
#undef APPEND_FLOAT
    append_float_vector(payload, _store.temperature_history);
#define APPEND_U8(name) append_u8_vector(payload, _store.name);
    CLIMATE_U8_LANES(APPEND_U8)
#undef APPEND_U8
#define APPEND_I32(name) append_i32_vector(payload, _store.name);
    CLIMATE_I32_LANES(APPEND_I32)
#undef APPEND_I32

    bytes.clear();
    bytes.reserve(80u + payload.size());
    append_u32(bytes, CLIMATE_SECTION_MARKER);
    append_u32(bytes, CLIMATE_SECTION_ABI);
    append_u32(bytes, RUNTIME_DOMAIN_POD_ABI_VERSION);
    append_u32(bytes, _store.cell_count);
    append_u32(bytes, _catalog.map_width);
    append_u32(bytes, _catalog.map_height);
    append_i64(bytes, _store.committed_day);
    append_u64(bytes, _store.generation);
    append_u64(bytes, _catalog.hash);
    append_u64(bytes, _last_input_generation);
    append_u64(bytes, _store.state_hash());
    append_u64(bytes, payload.size());
    append_u64(bytes, checksum(payload.data(), payload.size()));
    bytes.insert(bytes.end(), payload.begin(), payload.end());
    return true;
}

bool RuntimeClimateAuthority::restore(const uint8_t *bytes, size_t size,
                                      std::string &error) {
    error.clear();
    if (bytes == nullptr || size < 80u) {
        error = "climate_section_truncated";
        return false;
    }
    Reader reader{bytes, size, 0};
    uint32_t marker = 0, section_abi = 0, runtime_abi = 0, cells = 0;
    uint32_t map_width = 0, map_height = 0;
    int64_t day = -1;
    uint64_t generation = 0, catalog_hash = 0, input_generation = 0;
    uint64_t state_hash = 0, payload_size = 0, payload_checksum = 0;
    if (!reader.u32(marker) || !reader.u32(section_abi) ||
        !reader.u32(runtime_abi) || !reader.u32(cells) ||
        !reader.u32(map_width) || !reader.u32(map_height) ||
        !reader.i64(day) || !reader.u64(generation) ||
        !reader.u64(catalog_hash) || !reader.u64(input_generation) ||
        !reader.u64(state_hash) || !reader.u64(payload_size) ||
        !reader.u64(payload_checksum)) {
        error = "climate_section_header_truncated";
        return false;
    }
    if (marker != CLIMATE_SECTION_MARKER) {
        error = "climate_section_marker_mismatch";
        return false;
    }
    if (section_abi != CLIMATE_SECTION_ABI) {
        error = "climate_section_abi_mismatch";
        return false;
    }
    if (runtime_abi != RUNTIME_DOMAIN_POD_ABI_VERSION) {
        error = "climate_runtime_abi_mismatch";
        return false;
    }
    const bool bootstrap_section = catalog_hash == 0 && day == -1 &&
        generation == 0 && input_generation == 0;
    if (cells == 0 || day < -1 || (!bootstrap_section &&
        (catalog_hash == 0 || day < 0 || generation == 0 ||
         input_generation == 0))) {
        error = "climate_section_header_value_invalid";
        return false;
    }
    if (payload_size != size - reader.cursor) {
        error = "climate_section_payload_bounds_invalid";
        return false;
    }
    if (checksum(bytes + reader.cursor, static_cast<size_t>(payload_size)) !=
        payload_checksum) {
        error = "climate_section_checksum_invalid";
        return false;
    }
    if ((map_width == 0) != (map_height == 0)) {
        error = "climate_section_map_shape_invalid";
        return false;
    }
    if (_catalog_ready &&
        (_catalog.hash != catalog_hash || _catalog.cell_count != cells ||
         _catalog.abi_version != RUNTIME_DOMAIN_POD_ABI_VERSION ||
         ((_catalog.map_width != 0 || map_width != 0) &&
          _catalog.map_width != map_width) ||
         ((_catalog.map_height != 0 || map_height != 0) &&
          _catalog.map_height != map_height))) {
        error = "climate_restore_catalog_mismatch";
        return false;
    }
    if (_store.committed_day >= 0 && day <= _store.committed_day) {
        error = "climate_restore_day_not_monotonic";
        return false;
    }
    if (_store.cell_count != 0 && _store.cell_count != cells) {
        error = "climate_restore_shape_mismatch";
        return false;
    }
    Reader payload{bytes + reader.cursor, static_cast<size_t>(payload_size), 0};
    RuntimeClimateStore restored;
    uint32_t stored_cells = 0;
    if (!payload.u32(stored_cells) || stored_cells != cells ||
        !payload.u64(restored.generation) ||
        !payload.u64(restored.climate_generation) ||
        !payload.i64(restored.committed_day) ||
        !payload.f32(restored.climate_anomaly) ||
        !payload.f32(restored.annual_temperature_drift) ||
        !payload.u64(restored.rng_state) ||
        !payload.u64(restored.annual_rng_state) ||
        !payload.u32(restored.history_cursor)) {
        error = "climate_section_payload_truncated";
        return false;
    }
    restored.cell_count = cells;
#define READ_FLOAT(name) if (!payload.floats(restored.name, cells)) { error = "climate_section_lane_invalid_" #name; return false; }
    CLIMATE_CELL_FLOAT_LANES(READ_FLOAT)
#undef READ_FLOAT
    const uint64_t history_count = static_cast<uint64_t>(cells) * 365u;
    if (history_count > std::numeric_limits<uint32_t>::max() ||
        !payload.floats(restored.temperature_history,
                        static_cast<uint32_t>(history_count))) {
        error = "climate_section_history_invalid";
        return false;
    }
#define READ_U8(name) if (!payload.bytes(restored.name, cells)) { error = "climate_section_lane_invalid_" #name; return false; }
    CLIMATE_U8_LANES(READ_U8)
#undef READ_U8
#define READ_I32(name) if (!payload.ints(restored.name, cells)) { error = "climate_section_lane_invalid_" #name; return false; }
    CLIMATE_I32_LANES(READ_I32)
#undef READ_I32
    if (payload.cursor != payload.size) {
        error = "climate_section_payload_trailing_bytes";
        return false;
    }
    if (restored.committed_day != day) {
        error = "climate_section_day_mismatch";
        return false;
    }
    if (restored.generation != generation) {
        error = "climate_section_generation_mismatch";
        return false;
    }
    std::string validation_error;
    if (!restored.validate(validation_error)) {
        error = validation_error.empty() ? "climate_section_state_invalid"
                                         : validation_error;
        return false;
    }
    if (restored.state_hash() != state_hash) {
        error = "climate_section_state_hash_mismatch";
        return false;
    }
    RuntimeClimateStore restored_next = restored;
    RuntimeClimateCatalog restored_catalog;
    restored_catalog.abi_version = RUNTIME_DOMAIN_POD_ABI_VERSION;
    restored_catalog.hash = catalog_hash;
    restored_catalog.cell_count = cells;
    restored_catalog.map_width = map_width;
    restored_catalog.map_height = map_height;
    _store = std::move(restored);
    _next = std::move(restored_next);
    _catalog = restored_catalog;
    _catalog_ready = catalog_hash != 0;
    _last_input_generation = input_generation;
    _plan_ready = false;
    _planned_day = -1;
    return true;
}

bool RuntimeClimateAuthority::self_test(std::string &error) {
    if (!RuntimeClimateKernel::self_test(error)) return false;
    RuntimeEnvironmentSnapshot environment;
    environment.generation = 1;
    environment.day = 0;
    environment.cell_count = 2;
    environment.climate_map_width = 2;
    environment.climate_map_height = 1;
    environment.climate_catalog_hash = 7;
    environment.cell_temp = {15.0f, -8.0f};
    environment.cell_temp_30d = environment.cell_temp;
    environment.cell_moisture = {0.5f, 0.25f};
    environment.cell_plant_available_water = {0.7f, 0.2f};
    environment.terrain = {1, 0};
    environment.is_water = {0, 1};
    environment.neighbor_offsets = {0, 1, 2};
    environment.neighbor_indices = {1, 0};
    std::string validation_error;
    RuntimeEnvironmentSnapshot bad_nan = environment;
    bad_nan.cell_temp[0] = std::numeric_limits<float>::quiet_NaN();
    if (validate_runtime_environment_snapshot(bad_nan, validation_error) ||
        validation_error != "runtime_input_non_finite") {
        error = "climate_input_nan_not_rejected";
        return false;
    }
    RuntimeEnvironmentSnapshot bad_csr = environment;
    bad_csr.neighbor_offsets = {0, 2, 1};
    validation_error.clear();
    if (validate_runtime_environment_snapshot(bad_csr, validation_error) ||
        validation_error != "runtime_input_csr_invalid") {
        error = "climate_input_csr_not_rejected";
        return false;
    }
    RuntimeEnvironmentSnapshot bad_hydro = environment;
    bad_hydro.hydro_parent = {-1, 2};
    validation_error.clear();
    if (validate_runtime_environment_snapshot(bad_hydro, validation_error) ||
        validation_error != "runtime_input_hydro_parent_invalid") {
        error = "climate_input_hydro_parent_not_rejected";
        return false;
    }
    RuntimeEnvironmentSnapshot bad_hydro_cycle = environment;
    bad_hydro_cycle.hydro_parent = {1, 0};
    validation_error.clear();
    if (validate_runtime_environment_snapshot(bad_hydro_cycle, validation_error) ||
        validation_error != "runtime_input_hydro_cycle") {
        error = "climate_input_hydro_cycle_not_rejected";
        return false;
    }
    RuntimeEnvironmentSnapshot bad_lut = environment;
    bad_lut.trade_passable_lut = {1};
    bad_lut.trade_move_cost_lut = {1};
    validation_error.clear();
    if (validate_runtime_environment_snapshot(bad_lut, validation_error) ||
        validation_error != "runtime_input_lut_shape_mismatch") {
        error = "climate_input_lut_not_rejected";
        return false;
    }
    RuntimeEnvironmentSnapshot incomplete = environment;
    incomplete.climate_input_complete = true;
    incomplete.climate_catalog_hash = 7;
    incomplete.climate_map_width = 2;
    incomplete.climate_map_height = 1;
    incomplete.topology_validated = true;
    validation_error.clear();
    if (validate_runtime_environment_snapshot(incomplete, validation_error) ||
        validation_error != "runtime_input_complete_shape_missing") {
        error = "climate_complete_input_missing_lane_not_rejected";
        return false;
    }
    RuntimeEnvironmentSnapshot bad_dt = environment;
    bad_dt.dt_days = 0.0f;
    validation_error.clear();
    if (validate_runtime_environment_snapshot(bad_dt, validation_error) ||
        validation_error != "runtime_input_value_invalid") {
        error = "climate_invalid_dt_not_rejected";
        return false;
    }
    RuntimeClimateAuthority authority;
    RuntimeClimateVerticalReport report;
    if (!authority.plan_day(0, environment, report) ||
        !authority.commit_day(0, report)) {
        error = report.error;
        return false;
    }
    // A parity barrier may reject the planned next state before commit. The
    // abort must leave the last committed day/hash untouched and allow the
    // same input frame to be planned again deterministically.
    RuntimeClimateAuthority transaction;
    RuntimeClimateVerticalReport transaction_report;
    if (!transaction.plan_day(0, environment, transaction_report)) {
        error = "climate_discard_plan_fixture_failed";
        return false;
    }
    const uint64_t transaction_initial_hash = transaction.store().state_hash();
    transaction.discard_plan();
    if (transaction.store().committed_day != -1 ||
        transaction.store().generation != 0 ||
        transaction.store().state_hash() != transaction_initial_hash ||
        !transaction.plan_day(0, environment, transaction_report) ||
        !transaction.commit_day(0, transaction_report)) {
        error = "climate_discard_plan_not_transactional";
        return false;
    }
    std::vector<uint8_t> bytes;
    if (!authority.serialize(bytes, error)) return false;
    RuntimeClimateAuthority restored;
    if (!restored.restore(bytes.data(), bytes.size(), error) ||
        restored.store().state_hash() != authority.store().state_hash()) {
        if (error.empty()) error = "climate_section_roundtrip_failed";
        return false;
    }

    // The worker must reject a second plan that reuses an input generation,
    // and must expose catalog drift as a preflight error instead of silently
    // reseeding the POD store.
    RuntimeClimateVerticalReport rejected;
    RuntimeEnvironmentSnapshot repeated = environment;
    repeated.generation = 2;
    repeated.day = 1;
    repeated.climate_catalog_hash = 8;
    if (authority.plan_day(1, repeated, rejected) ||
        std::string(rejected.error) != "climate_catalog_hash_mismatch") {
        error = "climate_catalog_mismatch_not_rejected";
        return false;
    }
    repeated.climate_catalog_hash = environment.climate_catalog_hash;
    repeated.generation = 1;
    if (authority.plan_day(1, repeated, rejected) ||
        std::string(rejected.error) != "climate_input_generation_not_monotonic") {
        error = "climate_generation_reuse_not_rejected";
        return false;
    }

    RuntimeEnvironmentSnapshot bad_abi = environment;
    bad_abi.generation = 2;
    bad_abi.day = 1;
    bad_abi.climate_catalog_abi_version = RUNTIME_DOMAIN_POD_ABI_VERSION + 1u;
    if (authority.plan_day(1, bad_abi, rejected) ||
        std::string(rejected.error) != "climate_catalog_abi_mismatch") {
        error = "climate_catalog_abi_mismatch_not_rejected";
        return false;
    }

    // A restore is decoded into a temporary store, then checked against the
    // already bootstrapped catalog and map shape before any member is changed.
    RuntimeClimateAuthority shape_mismatch;
    if (!shape_mismatch.plan_day(0, environment, rejected) ||
        !shape_mismatch.commit_day(0, rejected)) {
        error = "climate_restore_shape_fixture_failed";
        return false;
    }
    RuntimeEnvironmentSnapshot different_shape = environment;
    different_shape.climate_map_width = 1;
    different_shape.climate_map_height = 2;
    RuntimeClimateAuthority shape_reference;
    if (!shape_reference.plan_day(0, different_shape, rejected) ||
        !shape_reference.commit_day(0, rejected)) {
        error = "climate_restore_shape_reference_failed";
        return false;
    }
    if (shape_reference.restore(bytes.data(), bytes.size(), error) ||
        error != "climate_restore_catalog_mismatch") {
        error = "climate_restore_shape_mismatch_not_rejected";
        return false;
    }

    std::vector<uint8_t> bad_section_abi = bytes;
    bad_section_abi[4] = 1u;
    RuntimeClimateAuthority incompatible;
    if (incompatible.restore(bad_section_abi.data(), bad_section_abi.size(), error) ||
        error != "climate_section_abi_mismatch") {
        error = "climate_section_abi_mismatch_not_rejected";
        return false;
    }
    return true;
}

} // namespace pk
