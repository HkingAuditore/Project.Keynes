#include "runtime_climate_authority.h"
#include "runtime_switch_registry.h"
#include "runtime_climate_parity.h"
#include "runtime_climate_physics.h"

#include <chrono>
#include <cmath>
#include <cstring>
#include <cstdlib>
#include <limits>

namespace pk {

namespace {
constexpr uint32_t CLIMATE_SECTION_MARKER = 0x324d4c43u; // CLM2
// CLM2 ABI 2 adds the compiled map shape to the section header.  Runtime
// Domain POD ABI and save-section ABI are intentionally versioned separately.
// ABI 3 replaces the single uint8 weather_transition lane with the three lanes
// the production path actually keeps (prev type / target type / alpha), so the
// lane set and its order changed and older sections cannot be read.
// ABI 3 = 到 weather_transition_alpha 为止的 float lane 集合。
// ABI 4 = 追加 worker 自持的 synoptic ψ / ψ_prev（B8-2）。
// ABI 5 = 追加 worker 自持的 vegetation / base_vegetation（B8-P1 演替）。
// ABI 6 = 追加 worker 自持的 tropical cyclone 状态 blob（B8-2）。
// ABI 7 = 追加 worker 自持物理状态 blob；旧档以空 blob 明确冷播种。
// ABI 8 = worker 自持的 terrain + cover u8 lanes。
// 开发期不迁移旧档；版本不符必须明确拒绝，不能静默冷启动。
// ABI 9 appends committed kernel continuation lanes; the v8 prefix is unchanged.
// ABI 10 drops the 365-day per-cell temperature ring from the payload. It was the
// single largest block of a save (6400 cells: 8.91 MiB raw / 5.53 MiB after zstd,
// 55% of the file) and nothing reads it: the daily kernel only appends to it and
// the gameplay lane is temperature_365d_ema. ABI 9 stays readable so existing
// saves still load; only new writes omit the ring.
constexpr uint32_t CLIMATE_SECTION_ABI = 10u;
constexpr uint32_t CLIMATE_SECTION_ABI_MIN_SUPPORTED = 9u;

#include "runtime_climate_authority_checksum.inc"

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
    static const bool bulk = [] {
        const uint16_t endian = 1;
        const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_SAVE_CODEC_SCALAR);
        return *reinterpret_cast<const uint8_t *>(&endian) == 1 &&
            !(value && std::strcmp(value, "1") == 0);
    }();
    if (bulk && !values.empty()) {
        const auto *first = reinterpret_cast<const uint8_t *>(values.data());
        out.insert(out.end(), first, first + values.size() * sizeof(float));
        return;
    }
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
        if (!u32(count) || count != expected || cursor > size ||
            count > (size - cursor) / 4u) return false;
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
    bool blob(std::vector<uint8_t> &values, size_t limit) {
        uint32_t count = 0;
        if (!u32(count) || count > limit || cursor > size || size - cursor < count)
            return false;
        values.assign(data + cursor, data + cursor + count);
        cursor += count;
        return true;
    }
    bool ints(std::vector<int32_t> &values, uint32_t expected) {
        uint32_t count = 0;
        if (!u32(count) || count != expected || cursor > size ||
            count > (size - cursor) / 4u) return false;
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
    X(vegetation_drought_stress) X(vegetation_cold_stress) \
    X(weather_transition_alpha) \
    X(synoptic_psi) X(synoptic_psi_prev)
// CLM2 ABI 3 的 float lane 集合 = 当前列表去掉 ABI 4 追加的 synoptic ψ 两条。
// 旧档必须按这份顺序读完，新增 lane 留在 reset 给的全零，而不是被当成旧数据。
#define CLIMATE_CELL_FLOAT_LANES_V3(X) \
    X(temperature) X(temperature_30d_ema) X(temperature_365d_ema) \
    X(temperature_baseline) X(thermal_energy) X(moisture) \
    X(plant_available_water) X(water_balance_30d) X(weather_precipitation) \
    X(weather_intensity) X(vapor) X(cloud_water) X(cloud_cover) X(convergence) \
    X(instability) X(snow_cover) X(snowpack) X(sea_ice) X(runoff) X(groundwater) \
    X(river_storage) X(river_discharge) X(riparian_moisture) X(vegetation_vitality) \
    X(vegetation_growth_pressure) X(vegetation_heat_stress) \
    X(vegetation_drought_stress) X(vegetation_cold_stress) \
    X(weather_transition_alpha)
#define CLIMATE_U8_LANES(X) \
    X(weather_type) X(weather_prev_type) X(weather_target_type) \
    X(vegetation_succession_candidate) \
    X(vegetation) X(base_vegetation) \
    X(terrain) X(cover)
// CLM2 ABI 7 的 u8 lane 集合 = 当前列表去掉 ABI 8 追加的 terrain / cover。
#define CLIMATE_U8_LANES_V7(X) \
    X(weather_type) X(weather_prev_type) X(weather_target_type) \
    X(vegetation_succession_candidate) \
    X(vegetation) X(base_vegetation)
// CLM2 ABI 4 的 u8 lane 集合 = 当前列表去掉 ABI 5 追加的植被演替两条。
#define CLIMATE_U8_LANES_V4(X) \
    X(weather_type) X(weather_prev_type) X(weather_target_type) \
    X(vegetation_succession_candidate)
#define CLIMATE_I32_LANES(X) \
    X(vegetation_growth_streak) X(vegetation_drought_streak)
} // namespace

bool RuntimeClimateAuthority::serialize(std::vector<uint8_t> &bytes,
                                        std::string &error) const {
    error.clear();
    std::string validation_error;
    if (!_store.validate(validation_error)) {
        error = validation_error;
        return false;
    }
    std::vector<uint8_t> payload;
    payload.reserve(static_cast<size_t>(_store.cell_count) * 160u);
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
    // temperature_history 自 ABI 10 起不再落盘（见 CLIMATE_SECTION_ABI 注释）。
    // 恢复侧对 ABI 9 仍按旧布局读取，因此旧档的 state_hash 复核不受影响。
#define APPEND_U8(name) append_u8_vector(payload, _store.name);
    CLIMATE_U8_LANES(APPEND_U8)
#undef APPEND_U8
#define APPEND_I32(name) append_i32_vector(payload, _store.name);
    CLIMATE_I32_LANES(APPEND_I32)
#undef APPEND_I32
    // blob 已通过 store 限长与 codec 校验，不允许截断长度后仍写入完整数据。
    append_u8_vector(payload, _store.cyclone_state);
    append_u8_vector(payload, _store.physics_state);
    append_float_vector(payload, _continuation.soil);
    append_float_vector(payload, _continuation.insolation_now);
    append_float_vector(payload, _continuation.insolation_dev);
    append_float_vector(payload, _continuation.heat_input);
    append_float_vector(payload, _continuation.day_length);
    append_float_vector(payload, _continuation.temp_season_offset);
    append_float_vector(payload, _continuation.conv_inhib);
    append_i32_vector(payload, _continuation.accumulated_snow_days);
    append_i32_vector(payload, _continuation.pre_snow_cover);
    append_u8_vector(payload, _continuation.field_init);
    append_u32(payload, _continuation.field_init_seeded ? 1u : 0u);
    append_u32(payload, static_cast<uint32_t>(_continuation.capture_cursors.size()));
    for (double value : _continuation.capture_cursors) {
        uint64_t bits = 0; std::memcpy(&bits, &value, sizeof(bits));
        append_u64(payload, bits);
    }
    if (payload.size() > MAX_SECTION_BYTES - 80u) {
        error = "climate_section_too_large";
        return false;
    }

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
    if (size > MAX_SECTION_BYTES) {
        error = "climate_section_too_large";
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
    // Only the current development format is accepted; no partial-fidelity restore.
    if (section_abi < CLIMATE_SECTION_ABI_MIN_SUPPORTED ||
        section_abi > CLIMATE_SECTION_ABI) {
        error = "climate_section_version_mismatch_expected_" +
            std::to_string(CLIMATE_SECTION_ABI) + "_got_" +
            std::to_string(section_abi);
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
    if ((map_width == 0) != (map_height == 0) ||
        (map_width != 0 && static_cast<uint64_t>(map_width) * map_height != cells)) {
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
    // ABI 3 的 payload 没有 synoptic ψ 两条 lane：按旧列表顺序读完，把新 lane
    // 留在 reset 给的全零。ABI 4 读完整列表。
#define READ_FLOAT(name) if (!payload.floats(restored.name, cells)) { error = "climate_section_lane_invalid_" #name; return false; }
    if (section_abi >= 4u) {
        CLIMATE_CELL_FLOAT_LANES(READ_FLOAT)
    } else {
        CLIMATE_CELL_FLOAT_LANES_V3(READ_FLOAT)
        restored.synoptic_psi.assign(cells, 0.0f);
        restored.synoptic_psi_prev.assign(cells, 0.0f);
    }
#undef READ_FLOAT
    const uint64_t history_count = static_cast<uint64_t>(cells) * 365u;
    if (section_abi >= 10u) {
        // ABI 10 不再携带历史 lane。环内容不参与任何判定，但 validate() 仍要求
        // 它保持 cells*365 的形状，所以补一份零环即等价于“这局没有历史”。
        restored.temperature_history.assign(static_cast<size_t>(history_count), 0.0f);
    } else if (history_count > std::numeric_limits<uint32_t>::max() ||
        !payload.floats(restored.temperature_history,
                        static_cast<uint32_t>(history_count))) {
        error = "climate_section_history_invalid";
        return false;
    }
    // ABI <= 4 的 u8 集合没有 vegetation / base_vegetation；ABI <= 7 没有
    // terrain / cover：按旧列表读完，新 lane 留在 reset 给的全零。
#define READ_U8(name) if (!payload.bytes(restored.name, cells)) { error = "climate_section_lane_invalid_" #name; return false; }
    if (section_abi >= 8u) {
        CLIMATE_U8_LANES(READ_U8)
    } else if (section_abi >= 5u) {
        CLIMATE_U8_LANES_V7(READ_U8)
        restored.terrain.assign(cells, 0);
        restored.cover.assign(cells, 0);
    } else {
        CLIMATE_U8_LANES_V4(READ_U8)
        restored.vegetation.assign(cells, 0);
        restored.base_vegetation.assign(cells, 0);
        restored.terrain.assign(cells, 0);
        restored.cover.assign(cells, 0);
    }
#undef READ_U8
#define READ_I32(name) if (!payload.ints(restored.name, cells)) { error = "climate_section_lane_invalid_" #name; return false; }
    CLIMATE_I32_LANES(READ_I32)
#undef READ_I32
    // ABI 6：cyclone 条目表 blob。旧档没有这一段，读完后保持空（冷启动由 capture
    // 的生产种子或零场接管）。
    if (section_abi >= 6u &&
        !payload.blob(restored.cyclone_state, 64u * 1024u * 1024u)) {
        error = "climate_section_cyclone_blob_invalid";
        return false;
    }
    // 历史格式分支保留供审计；入口版本检查只接受 v9。
    // 非空胶囊必须经正式 physics codec 验证形状/有限性/hash，不能降级成空。
    if (section_abi >= 7u &&
        !payload.blob(restored.physics_state, RuntimeClimateStore::MAX_PHYSICS_STATE_BYTES)) {
        error = "climate_section_physics_blob_invalid";
        return false;
    }
    RuntimeClimateKernel::Continuation continuation;
    if (section_abi >= 9u) {
        // Optional lanes are either absent (stage never ran) or exactly cell-sized.
        const auto read_floats = [&](std::vector<float> &values) {
            uint32_t count = 0;
            const size_t begin = payload.cursor;
            if (!payload.u32(count) || (count != 0 && count != cells)) return false;
            payload.cursor = begin;
            if (!payload.floats(values, count)) return false;
            for (float value : values) if (!std::isfinite(value)) return false;
            return true;
        };
        const auto read_ints = [&](std::vector<int32_t> &values) {
            uint32_t count = 0;
            const size_t begin = payload.cursor;
            if (!payload.u32(count) || (count != 0 && count != cells)) return false;
            payload.cursor = begin;
            return payload.ints(values, count);
        };
        if (!read_floats(continuation.soil)) { error = "climate_continuation_soil_invalid"; return false; }
        if (!read_floats(continuation.insolation_now)) { error = "climate_continuation_insolation_now_invalid"; return false; }
        if (!read_floats(continuation.insolation_dev)) { error = "climate_continuation_insolation_dev_invalid"; return false; }
        if (!read_floats(continuation.heat_input)) { error = "climate_continuation_heat_input_invalid"; return false; }
        if (!read_floats(continuation.day_length)) { error = "climate_continuation_day_length_invalid"; return false; }
        if (!read_floats(continuation.temp_season_offset)) { error = "climate_continuation_temp_season_offset_invalid"; return false; }
        if (!read_floats(continuation.conv_inhib)) { error = "climate_continuation_conv_inhib_invalid"; return false; }
        if (!read_ints(continuation.accumulated_snow_days)) { error = "climate_continuation_accumulated_snow_days_invalid"; return false; }
        if (!read_ints(continuation.pre_snow_cover)) { error = "climate_continuation_pre_snow_cover_invalid"; return false; }
        uint32_t count = 0, seeded = 0;
        const size_t begin = payload.cursor;
        if (!payload.u32(count) || (count != 0 && count != cells)) {
            error = "climate_continuation_init_shape_invalid"; return false;
        }
        payload.cursor = begin;
        if (!payload.bytes(continuation.field_init, count) ||
            !payload.u32(seeded) || seeded > 1u || (seeded && count != cells)) {
            error = "climate_continuation_init_invalid"; return false;
        }
        for (uint8_t value : continuation.field_init) if (value > 1u) {
            error = "climate_continuation_init_value_invalid"; return false;
        }
        continuation.field_init_seeded = seeded != 0;
        if (!payload.u32(count) || (count != 0 && count != 11u)) {
            error = "climate_capture_cursor_shape_invalid"; return false;
        }
        continuation.capture_cursors.resize(count);
        for (double &value : continuation.capture_cursors) {
            uint64_t bits = 0;
            if (!payload.u64(bits)) { error = "climate_capture_cursor_truncated"; return false; }
            std::memcpy(&value, &bits, sizeof(value));
            if (!std::isfinite(value)) { error = "climate_capture_cursor_invalid"; return false; }
        }
    }
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
    // ABI 6 继续按原算法严格校验，不能随 ABI bump 自动失去哈希保护。
    // ABI 7 冻结为 abi6 + physics；ABI 8/9 再混入 terrain/cover，历史 lane 仍经
    // abi6 参与；ABI 10 起历史 lane 不再落盘，用当前 state_hash() 复核。
    // v9 沿用原 store hash，新增继续态另由完整 payload checksum 保护。
    const uint64_t expected_hash = section_abi >= 10u
        ? restored.state_hash()
        : (section_abi >= 8u ? restored.state_hash_abi8()
            : (section_abi >= 7u ? restored.state_hash_abi7()
                                 : restored.state_hash_abi6()));
    if (section_abi >= 6u && expected_hash != state_hash) {
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
    _continuation = std::move(continuation);
    _kernel.restore_continuation(_continuation);
    _store = std::move(restored);
    _kernel.invalidate_committed_physics();
    _next = std::move(restored_next);
    // v10 已校验当前格式的哈希。旧档按当前算法从安装完成的状态计算发布哈希。
    _committed_state_hash = section_abi >= 10u
        ? expected_hash
        : (section_abi >= 8u ? _store.state_hash() : 0);
    _catalog = restored_catalog;
    _catalog_ready = catalog_hash != 0;
    _economy_view_cursor = {};
    _last_input_generation = input_generation;
    _plan_ready = false;
    _planned_day = -1;
    return true;
}

} // namespace pk
