#include "runtime_climate_authority.h"

#include "runtime_climate_parity.h"
#include "runtime_climate_physics.h"

#include <chrono>
#include <cstring>
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
// 旧档必须继续可读：只允许在这些版本之间迁移，不做"猜版本"。
constexpr uint32_t CLIMATE_SECTION_ABI = 8u;
constexpr uint32_t CLIMATE_SECTION_ABI_MIN_SUPPORTED = 3u;
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

void RuntimeClimateAuthority::reset(uint32_t cell_count) {
    _kernel.reset(cell_count);
    _store.reset(cell_count);
    _next.reset(cell_count);
    _catalog = RuntimeClimateCatalog{};
    _catalog_ready = false;
    _plan_ready = false;
    _planned_day = -1;
    _planned_state_hash = 0;
    _planned_parity_hash = 0;
    _last_input_generation = 0;
    _last_report = RuntimeClimateVerticalReport{};
}

bool RuntimeClimateAuthority::seed_from_input(
        const RuntimeEnvironmentSnapshot &environment, std::string &error) {
    if (_store.cell_count != environment.cell_count ||
        environment.cell_temp.size() != environment.cell_count) {
        error = "climate_seed_shape_mismatch";
        return false;
    }
    // 输入已过有限性校验；先验证目标形状，避免播种失败留下半写状态。
    if (!_store.validate(error)) return false;
    const size_t cells = environment.cell_count;
    for (size_t i = 0; i < cells; ++i) {
        _store.temperature[i] = environment.cell_temp[i];
        _store.temperature_30d_ema[i] = environment.cell_temp_30d.empty()
            ? environment.cell_temp[i] : environment.cell_temp_30d[i];
        // 365d EMA 有自己的 environment lane，退回 30d 只是占位。两者在春秋季相差
        // 最大（30d 跟着季节走，365d 基本是年均），拿 30d 顶替等于让年际基线从一个
        // 季节性偏移起步。与 WB30 同一类缺陷。
        _store.temperature_365d_ema[i] = environment.cell_temp_365d.empty()
            ? _store.temperature_30d_ema[i] : environment.cell_temp_365d[i];
        _store.thermal_energy[i] = environment.cell_temp[i];
        _store.moisture[i] = environment.cell_moisture.empty()
            ? 0.0f : environment.cell_moisture[i];
        _store.plant_available_water[i] = environment.cell_plant_available_water.empty()
            ? 0.0f : environment.cell_plant_available_water[i];
        // WB30 有自己的 environment lane，不能拿 PAW 顶替。两者物理意义不同：PAW 是
        // 植物可用水（同图量级 0.3~1.2），WB30 是 30 天水平衡（生产同图约 0.04）。
        //
        // 播成 PAW 的后果在 ACTIVE 下会一直留在场里：distribute 是 store 里 WB30
        // 唯一的写者，而它对陆地格只把原值写回、对水域格按 29/30 衰减，没有任何一步
        // 会把这个初值纠正回来。WB30 又是 pk_plant_available_water 的输入，于是
        // PAW 与 vegetation_growth_pressure 整条链跟着偏。
        //
        // 连形状都不对：seed 在 bind 时执行，那时地图生成刚算完的 PAW 还是全场非零
        // （水域格要等第一次 vegetation_dynamics 才被 is_water 分支清零），所以错误
        // 初值是 2400 格全非零，而生产只有 914 个陆地格非零。
        _store.water_balance_30d[i] = environment.cell_water_balance_30d.empty()
            ? 0.0f : environment.cell_water_balance_30d[i];
        _store.weather_precipitation[i] = environment.cell_weather_precip.empty()
            ? 0.0f : environment.cell_weather_precip[i];
        _store.weather_intensity[i] = environment.cell_weather_intensity.empty()
            ? 0.0f : environment.cell_weather_intensity[i];
        _store.snow_cover[i] = environment.cell_snow_cover.empty()
            ? 0.0f : environment.cell_snow_cover[i];
        _store.snowpack[i] = _store.snow_cover[i];
        // vitality 同样有 environment lane。硬编码 0.5 会把水域格和无植被格也播成
        // 半健康（生产那里它们是 0），而 vegetation_dynamics 要等 48 天才跑第一次，
        // 这个假值在那之前一直是下游的输入。
        _store.vegetation_vitality[i] = environment.cell_vegetation_vitality.empty()
            ? 0.5f : environment.cell_vegetation_vitality[i];
    }
    // 未编译 catalog 的新基线没有物理历史，下一次计划从输入冷播种。
    _store.physics_state.clear();
    _next = _store;
    return true;
}

bool RuntimeClimateAuthority::plan_day(
        int64_t day, const RuntimeEnvironmentSnapshot &environment,
        RuntimeClimateVerticalReport &report,
        bool compute_hashes,
        bool validate_input) {
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
    // Host publish 已对 ring 内 snapshot 做过完整 validate；热路径默认仍校验
    // （自测 / 直接调用），生产 ACTIVE/SHADOW 传入 validate_input=false。
    if (validate_input &&
        !validate_runtime_environment_snapshot(environment, error)) {
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
                          kernel_report, compute_hashes, validate_input)) {
        set_error(report, kernel_report.error);
        report.plan_ms = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - begin).count();
        _last_report = report;
        return false;
    }
    report.work_units = kernel_report.work_units;
    report.changed_cells = kernel_report.changed_cells;
    report.state_hash = kernel_report.state_hash;
    // SHADOW 对拍需要 parity；ACTIVE 热路径跳过（writeback/save 会自算 state_hash）。
    report.parity_hash = compute_hashes ? _next.parity_hash() : 0;
    report.input_hash = kernel_report.input_hash;
    report.catalog_hash = _catalog.hash;
    report.input_generation = environment.generation;
    report.stage_ms = kernel_report.stage_ms;
    report.stage_work = kernel_report.stage_work;
    report.production_stage_mask = kernel_report.production_stage_mask;
    report.worker_stage_mask = kernel_report.stage_ran_mask;
    report.cyclone_alive = kernel_report.cyclone_alive;
    report.cyclone_injected = kernel_report.cyclone_injected;
    report.cyclone_replaced = kernel_report.cyclone_replaced;
    report.cyclone_decayed = kernel_report.cyclone_decayed;
    report.cyclone_touched = kernel_report.cyclone_touched;
    report.plan_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - begin).count();
    _planned_day = day;
    // compute_hashes 时这两份就是提交后的权威归约；否则为 0（commit 原样写出）。
    _planned_state_hash = report.state_hash;
    _planned_parity_hash = report.parity_hash;
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
    std::string error;
    // 热路径：只做 O(lanes) 形状检查。finite / physics decode 已由 plan 写路径与
    // save/restore 全量 validate 覆盖；这里再扫一遍会把 replay_ms 抬到数毫秒。
    if (!_next.validate_shape(error)) {
        set_error(report, error.c_str());
        _last_report = report;
        return false;
    }
    // 整 store 交换包含 physics_state；发布前绝不改变 current 的胶囊。
    _kernel.commit(_store, _next);
    report.state_hash = _planned_state_hash;
    report.parity_hash = _planned_parity_hash;
    report.replay_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - begin).count();
    report.completed = 1;
    report.preflight_ok = 1;
    _last_input_generation = report.input_generation;
    _plan_ready = false;
    _planned_day = -1;
    _planned_state_hash = 0;
    _planned_parity_hash = 0;
    _last_report = report;
    return true;
}

bool RuntimeClimateAuthority::commit_day_forced(
        int64_t day, const RuntimeClimateStore &reference,
        RuntimeClimateVerticalReport &report) {
    // comparable adopt 不校验 lane 形状/NaN；必须在提交之前验证整份 reference。
    std::string error;
    if (reference.cell_count != _store.cell_count || !reference.validate(error)) {
        set_error(report, error.empty() ? "climate_reference_shape_mismatch" : error.c_str());
        return false;
    }
    if (!commit_day(day, report)) return false;
    if (!runtime_climate_parity_adopt_comparable_fields(_store, reference)) {
        set_error(report, "climate_reference_shape_mismatch");
        return false;
    }
    // Both hashes must be recomputed: the physical fields just changed, so the
    // pre-adoption values would misdescribe the state that is now committed.
    report.state_hash = _store.state_hash();
    report.parity_hash = _store.parity_hash();
    _last_report = report;
    return true;
}

bool RuntimeClimateAuthority::adopt_reference_baseline(
        int64_t day, const RuntimeClimateStore &reference,
        const RuntimeEnvironmentSnapshot &environment,
        RuntimeClimateVerticalReport &report) {
    report = RuntimeClimateVerticalReport{};
    if (_store.cell_count != reference.cell_count ||
        environment.cell_count != reference.cell_count) {
        set_error(report, "climate_reference_shape_mismatch");
        return false;
    }
    std::string validation_error;
    if (!reference.validate(validation_error) ||
        !validate_runtime_environment_snapshot(environment, validation_error)) {
        set_error(report, validation_error.c_str());
        return false;
    }
    if (day < 0 || day != environment.day) {
        set_error(report, "climate_environment_day_mismatch");
        return false;
    }
    // The catalog must be compiled here, not left to the next plan_day. That
    // path treats `!_catalog_ready` as "the store has never been seeded" and
    // runs seed_from_input(), which overwrites every physical lane from the raw
    // environment — i.e. it throws away the baseline this function just
    // adopted. The symptom is a single divergent day right after cold start
    // (the store is re-seeded, the reference is not), which reads as an
    // algorithmic divergence in the matrix while nothing algorithmic is wrong.
    if (!_catalog_ready) {
        std::string catalog_error;
        if (!_kernel.compile_catalog(environment, _catalog, catalog_error)) {
            set_error(report, catalog_error.c_str());
            return false;
        }
        _catalog_ready = true;
    }
    if (!runtime_climate_parity_adopt_comparable_fields(_store, reference)) {
        set_error(report, "climate_reference_shape_mismatch");
        return false;
    }
    // Only the comparable physical fields come from the reference. Bookkeeping
    // stays the worker's own, which is why this is a baseline and not a restore:
    // rng_state and history intentionally keep their cold-start values.
    // 新基线采用 reference 的物理胶囊；旧 reference 无胶囊时明确冷播种，
    // 不能保留另一段历史的物理缓存。forced commit 则保留刚计划出的 worker 胶囊。
    _store.physics_state = reference.physics_state;
    _store.committed_day = day;
    ++_store.generation;
    ++_store.climate_generation;
    // Both lanes take the baseline. copy_store_lanes would refresh `next` on the
    // next plan anyway, but leaving the two lanes out of sync means any lane the
    // copy list ever misses shows up exactly once, on the first day after cold
    // start — the hardest possible day to attribute.
    _next = _store;
    _last_input_generation = environment.generation;
    _plan_ready = false;
    _planned_day = -1;
    report.completed = 1;
    report.preflight_ok = 1;
    report.input_generation = environment.generation;
    report.catalog_hash = _catalog.hash;
    report.state_hash = _store.state_hash();
    report.parity_hash = _store.parity_hash();
    _last_report = report;
    return true;
}

void RuntimeClimateAuthority::discard_plan() {
    _next.physics_state.clear();
    _plan_ready = false;
    _planned_day = -1;
    _planned_state_hash = 0;
    _planned_parity_hash = 0;
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
    // blob 已通过 store 限长与 codec 校验，不允许截断长度后仍写入完整数据。
    append_u8_vector(payload, _store.cyclone_state);
    append_u8_vector(payload, _store.physics_state);
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
    // 接受 [MIN_SUPPORTED, CLIMATE_SECTION_ABI] 区间内的所有版本：ABI 4 是 B8-2
    // 的中间档（有 ψ、没有演替 lane），也是必须能读的旧档。
    if (section_abi < CLIMATE_SECTION_ABI_MIN_SUPPORTED ||
        section_abi > CLIMATE_SECTION_ABI) {
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
    if (history_count > std::numeric_limits<uint32_t>::max() ||
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
    // ABI 3-6 没有物理胶囊：保持空，由 kernel 下一次计划显式冷播种。
    // 非空胶囊必须经正式 physics codec 验证形状/有限性/hash，不能降级成空。
    if (section_abi >= 7u &&
        !payload.blob(restored.physics_state, RuntimeClimateStore::MAX_PHYSICS_STATE_BYTES)) {
        error = "climate_section_physics_blob_invalid";
        return false;
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
    // ABI 7 冻结为 abi6 + physics；ABI 8+ 再混入 terrain/cover。
    // ABI 3-5 保持既有迁移契约：checksum + lane 形状/有限性校验，缺失 lane 冷播种。
    const uint64_t expected_hash = section_abi >= 8u
        ? restored.state_hash()
        : (section_abi >= 7u ? restored.state_hash_abi7()
                             : restored.state_hash_abi6());
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
    // B8 P2：物理环流共享纯内核自检（SLP Pass A 有限性/水陆差异、Pass B Jacobi
    // 平均、recenter 零均值、response_rate=0 保持 prev）。生产路径已经切到同一份
    // 内核，所以这里的失败等价于 MapBaker 每日 SLP 求解失败。
    if (!pk_async_physics::self_test(error)) {
        error = "climate_physics_self_test_failed:" + error;
        return false;
    }
    // B8-2 / CLM2 ABI 4 迁移自检：造一份 ABI 3 的 payload（= 当前 payload 去掉末尾
    // 两条 synoptic ψ lane），改写 header 的 ABI / payload_size / checksum，再走
    // 正式 restore。通过条件：restore 成功、ψ 两条 lane 全零、其余字段逐 lane 一致。
    {
        const auto migration_fail = [&](const std::string &reason) {
            error = reason;
            std::fprintf(stderr, "[climate][abi-migration] %s\n", reason.c_str());
            std::fflush(stderr);
            return false;
        };
        RuntimeClimateAuthority authority;
        authority.reset(2);
        RuntimeEnvironmentSnapshot env;
        env.generation = 1;
        env.day = 0;
        env.cell_count = 2;
        env.climate_map_width = 2;
        env.climate_map_height = 1;
        env.climate_catalog_hash = 7;
        env.cell_temp = {15.0f, -8.0f};
        env.cell_temp_30d = env.cell_temp;
        env.cell_moisture = {0.5f, 0.25f};
        env.cell_plant_available_water = {0.7f, 0.2f};
        env.terrain = {1, 0};
        env.is_water = {0, 1};
        env.neighbor_offsets = {0, 1, 2};
        env.neighbor_indices = {1, 0};
        RuntimeClimateVerticalReport report;
        if (!authority.plan_day(0, env, report) ||
            !authority.commit_day(0, report)) {
            return migration_fail("climate_abi_migration_seed_failed");
        }
        std::vector<uint8_t> v4;
        if (!authority.serialize(v4, error) || v4.size() <= 88u) {
            return migration_fail(error.empty()
                ? "climate_abi_migration_serialize_failed" : error);
        }
        // payload 布局（ABI 8）：header 80B + 前缀 56B +
        //   31 条 float lane（每条 u32 长度 + cells*f32）+
        //   temperature_history（u32 长度 + 365*cells*f32）+
        //   8 条 u8 lane（每条 u32 长度 + cells 字节）+
        //   2 条 i32 lane（每条 u32 长度 + cells*i32）+
        //   cyclone blob + physics blob。
        // 旧档 = 从这份 payload 里剪掉对应版本没有的 lane，改写 header 三处字段。
        constexpr size_t PAYLOAD_PREFIX = 56u;
        constexpr size_t FLOAT_LANES = 31u;
        constexpr size_t U8_LANES = 8u;
        constexpr size_t I32_LANES = 2u;
        const uint32_t cells = 2u;
        const size_t float_lane = sizeof(uint32_t) + cells * sizeof(float);
        const size_t u8_lane = sizeof(uint32_t) + cells;
        const size_t i32_lane = sizeof(uint32_t) + cells * sizeof(uint32_t);
        const size_t history_block =
            sizeof(uint32_t) + static_cast<size_t>(cells) * 365u * sizeof(float);
        const size_t floats_start = 80u + PAYLOAD_PREFIX;
        const size_t history_start = floats_start + FLOAT_LANES * float_lane;
        const size_t u8_start = history_start + history_block;
        const size_t i32_start = u8_start + U8_LANES * u8_lane;
        const size_t blob_start = i32_start + I32_LANES * i32_lane;
        // blob 区 = u32 长度前缀 + bytes；长度必须与实际长度一致，否则形状异常。
        if (v4.size() < blob_start + sizeof(uint32_t)) {
            return migration_fail("climate_abi_migration_shape_unexpected");
        }
        uint32_t blob_len = 0;
        std::memcpy(&blob_len, v4.data() + blob_start, sizeof(blob_len));
        const size_t physics_start = blob_start + sizeof(uint32_t) + blob_len;
        if (v4.size() != physics_start + sizeof(uint32_t) +
                         authority.store().physics_state.size()) {
            return migration_fail("climate_abi_migration_blob_shape_unexpected");
        }
        const auto build_legacy = [&](uint32_t abi, size_t drop_float_lanes,
                                      size_t drop_u8_lanes,
                                      std::vector<uint8_t> &out,
                                      std::string &why) {
            out.assign(v4.begin(), v4.begin() + 80);
            out.insert(out.end(), v4.begin() + 80,
                       v4.begin() + static_cast<ptrdiff_t>(
                           floats_start + (FLOAT_LANES - drop_float_lanes) *
                               float_lane));
            out.insert(out.end(),
                       v4.begin() + static_cast<ptrdiff_t>(
                           history_start),
                       v4.begin() + static_cast<ptrdiff_t>(
                           u8_start + (U8_LANES - drop_u8_lanes) * u8_lane));
            // ABI >= 7 保留 physics；ABI 6 保留 cyclone、剪掉 physics；更旧剪掉 blob。
            const size_t payload_end = abi >= 7u ? v4.size()
                : (abi >= 6u ? physics_start : blob_start);
            out.insert(out.end(),
                       v4.begin() + static_cast<ptrdiff_t>(i32_start),
                       v4.begin() + static_cast<ptrdiff_t>(payload_end));
            std::memcpy(out.data() + 4, &abi, sizeof(abi));
            const uint64_t legacy_hash = abi >= 7u
                ? authority.store().state_hash_abi7()
                : authority.store().state_hash_abi6();
            std::memcpy(out.data() + 56, &legacy_hash, sizeof(legacy_hash));
            const uint64_t payload_size =
                static_cast<uint64_t>(out.size() - 80u);
            std::memcpy(out.data() + 64, &payload_size, sizeof(payload_size));
            const uint64_t payload_checksum =
                checksum(out.data() + 80, out.size() - 80u);
            std::memcpy(out.data() + 72, &payload_checksum,
                        sizeof(payload_checksum));
            why.clear();
            return true;
        };
        const auto check_legacy = [&](uint32_t abi, size_t drop_float_lanes,
                                      size_t drop_u8_lanes,
                                      const char *label) -> bool {
            std::vector<uint8_t> legacy;
            std::string why;
            if (!build_legacy(abi, drop_float_lanes, drop_u8_lanes, legacy, why)) {
                return migration_fail(std::string(label) + "_build_failed");
            }
            RuntimeClimateAuthority restored;
            restored.reset(2);
            std::string restore_error;
            if (!restored.restore(legacy.data(), legacy.size(), restore_error)) {
                return migration_fail(std::string(label) + "_restore_failed:" +
                                      restore_error);
            }
            const RuntimeClimateStore &store = restored.store();
            if (store.committed_day != 0 || store.cell_count != 2) {
                return migration_fail(std::string(label) + "_metadata_mismatch");
            }
            if (drop_float_lanes > 0) {
                for (float value : store.synoptic_psi) {
                    if (value != 0.0f) return migration_fail(
                        std::string(label) + "_psi_not_zeroed");
                }
                for (float value : store.synoptic_psi_prev) {
                    if (value != 0.0f) return migration_fail(
                        std::string(label) + "_psi_prev_not_zeroed");
                }
            }
            // ABI 8 末尾两条 u8 是 terrain / cover；再往前两条是 vegetation。
            if (drop_u8_lanes >= 2u) {
                for (uint8_t value : store.terrain) {
                    if (value != 0u) return migration_fail(
                        std::string(label) + "_terrain_not_zeroed");
                }
                for (uint8_t value : store.cover) {
                    if (value != 0u) return migration_fail(
                        std::string(label) + "_cover_not_zeroed");
                }
            }
            if (drop_u8_lanes >= 4u) {
                for (uint8_t value : store.vegetation) {
                    if (value != 0u) return migration_fail(
                        std::string(label) + "_vegetation_not_zeroed");
                }
                for (uint8_t value : store.base_vegetation) {
                    if (value != 0u) return migration_fail(
                        std::string(label) + "_base_vegetation_not_zeroed");
                }
            }
            if (abi < 7u && !store.physics_state.empty()) {
                return migration_fail(std::string(label) + "_physics_not_cold_seeded");
            }
            if (abi <= 5u && !store.cyclone_state.empty()) {
                return migration_fail(std::string(label) +
                                      "_cyclone_blob_not_cleared");
            }
            return true;
        };
        // ABI 7 = 只缺 terrain / cover（2 条 u8 lane），保留 physics。
        if (!check_legacy(7u, 0u, 2u, "climate_abi7")) return false;
        // ABI 6 = 缺 terrain/cover + physics blob；仍须通过旧算法 hash 校验。
        if (!check_legacy(6u, 0u, 2u, "climate_abi6")) return false;
        // ABI 5 = 缺 terrain/cover + cyclone / physics blob。
        if (!check_legacy(5u, 0u, 2u, "climate_abi5")) return false;
        // ABI 4 = 缺 vegetation / base_vegetation / terrain / cover（4 条 u8）。
        if (!check_legacy(4u, 0u, 4u, "climate_abi4")) return false;
        // ABI 3 = 同时缺 ψ 两条 float lane 与上述 4 条 u8 lane。
        if (!check_legacy(3u, 2u, 4u, "climate_abi3")) return false;
    }
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
    if (!authority.plan_day(0, environment, report)) {
        error = report.error;
        return false;
    }
    // The host compares parity at plan time but only the committed state
    // becomes authoritative. If commit could change the parity reduction, a
    // day could be admitted on the strength of a hash that no longer describes
    // what was committed.
    const uint64_t planned_parity = report.parity_hash;
    if (planned_parity == 0) {
        error = "climate_plan_parity_hash_zero";
        return false;
    }
    if (!authority.commit_day(0, report)) {
        error = report.error;
        return false;
    }
    if (report.parity_hash != planned_parity) {
        error = "climate_commit_changed_parity_hash";
        return false;
    }
    if (authority.store().parity_hash() != planned_parity) {
        error = "climate_committed_store_parity_hash_mismatch";
        return false;
    }
    // commit 复用 plan 缓存的 state_hash；必须与提交后 store 重算一致。
    if (report.state_hash == 0 ||
        report.state_hash != authority.store().state_hash()) {
        error = "climate_commit_state_hash_reuse_mismatch";
        return false;
    }
    // parity_hash and state_hash must stay distinct concerns: the former is
    // comparable across the boundary, the latter guards save integrity.
    if (authority.store().parity_hash() == authority.store().state_hash()) {
        error = "climate_parity_and_state_hash_conflated";
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

// ─── RuntimeClimateWritebackRing ──────────────────────────────────────────

RuntimeClimateWritebackRing::RuntimeClimateWritebackRing() {
    for (auto &state : _states) state.store(FREE, std::memory_order_relaxed);
}

bool RuntimeClimateWritebackRing::try_begin_write(uint32_t &index) {
    for (size_t i = 0; i < SLOT_COUNT; ++i) {
        uint8_t expected = FREE;
        if (_states[i].compare_exchange_strong(expected, WRITING,
                std::memory_order_acq_rel, std::memory_order_relaxed)) {
            index = static_cast<uint32_t>(i);
            return true;
        }
    }
    // A READY slot the main thread has not taken yet is recyclable: the newer
    // day supersedes it. Only a slot actively being READ is untouchable.
    for (size_t i = 0; i < SLOT_COUNT; ++i) {
        uint8_t expected = READY;
        if (_states[i].compare_exchange_strong(expected, WRITING,
                std::memory_order_acq_rel, std::memory_order_relaxed)) {
            _publish_drop_count.fetch_add(1, std::memory_order_relaxed);
            index = static_cast<uint32_t>(i);
            return true;
        }
    }
    _publish_drop_count.fetch_add(1, std::memory_order_relaxed);
    return false;
}

void RuntimeClimateWritebackRing::publish(uint32_t index) {
    if (index >= SLOT_COUNT) return;
    _published_generation.store(_buffers[index].generation,
                                std::memory_order_release);
    _states[index].store(READY, std::memory_order_release);
}

bool RuntimeClimateWritebackRing::try_acquire_latest(uint64_t after_generation,
                                                     uint32_t &index) {
    // Pick the newest READY slot strictly newer than the caller's cursor. The
    // scan is over three slots, so there is no reason to keep a hint.
    bool found = false;
    size_t best = 0;
    uint64_t best_generation = 0;
    for (size_t i = 0; i < SLOT_COUNT; ++i) {
        if (_states[i].load(std::memory_order_acquire) != READY) continue;
        const uint64_t generation = _buffers[i].generation;
        if (generation <= after_generation) continue;
        if (!found || generation > best_generation) {
            found = true;
            best = i;
            best_generation = generation;
        }
    }
    if (!found) return false;
    uint8_t expected = READY;
    if (!_states[best].compare_exchange_strong(expected, READING,
            std::memory_order_acq_rel, std::memory_order_relaxed)) {
        // The worker recycled it between the scan and the claim. The caller
        // retries on the next frame against a newer day.
        return false;
    }
    index = static_cast<uint32_t>(best);
    return true;
}

void RuntimeClimateWritebackRing::release(uint32_t index) {
    if (index >= SLOT_COUNT) return;
    _states[index].store(FREE, std::memory_order_release);
}

void RuntimeClimateWritebackRing::reset() {
    for (auto &state : _states) state.store(FREE, std::memory_order_relaxed);
    for (auto &buffer : _buffers) buffer = RuntimeClimateSnapshot{};
    _published_generation.store(0, std::memory_order_relaxed);
    _publish_drop_count.store(0, std::memory_order_relaxed);
}

bool RuntimeClimateWritebackRing::self_test(std::string &error) {
    RuntimeClimateWritebackRing ring;
    uint32_t slot = 0;
    if (ring.try_acquire_latest(0, slot)) {
        error = "climate_writeback_empty_ring_acquired";
        return false;
    }
    if (!ring.try_begin_write(slot)) {
        error = "climate_writeback_first_write_refused";
        return false;
    }
    ring.write_buffer(slot).generation = 1;
    ring.write_buffer(slot).committed_day = 7;
    ring.publish(slot);
    uint32_t read_slot = 0;
    if (!ring.try_acquire_latest(0, read_slot)) {
        error = "climate_writeback_published_not_visible";
        return false;
    }
    if (ring.read_buffer(read_slot).committed_day != 7) {
        error = "climate_writeback_payload_mismatch";
        return false;
    }
    // Re-reading the same generation must not hand out the same day twice.
    uint32_t again = 0;
    if (ring.try_acquire_latest(1, again)) {
        error = "climate_writeback_stale_generation_acquired";
        return false;
    }
    // The worker must keep making progress while that slot is held.
    uint32_t next_write = 0;
    if (!ring.try_begin_write(next_write) || next_write == read_slot) {
        error = "climate_writeback_write_blocked_by_reader";
        return false;
    }
    ring.write_buffer(next_write).generation = 2;
    ring.write_buffer(next_write).committed_day = 8;
    ring.publish(next_write);
    ring.release(read_slot);
    uint32_t newest = 0;
    if (!ring.try_acquire_latest(1, newest) ||
        ring.read_buffer(newest).committed_day != 8) {
        error = "climate_writeback_newest_not_selected";
        return false;
    }
    ring.release(newest);
    return true;
}

// ─── RuntimeEnvironmentInputRing ──────────────────────────────────────────

size_t RuntimeEnvironmentInputRing::size() const {
    std::lock_guard<std::mutex> lock(_mutex);
    return _queue.size();
}

bool RuntimeEnvironmentInputRing::try_push(
        std::shared_ptr<const RuntimeEnvironmentSnapshot> snapshot) {
    if (!snapshot) return false;
    std::lock_guard<std::mutex> lock(_mutex);
    if (_queue.size() >= SLOT_COUNT) return false;
    _queue.push_back(snapshot);
    _latest = std::move(snapshot);
    return true;
}

bool RuntimeEnvironmentInputRing::force_push(
        std::shared_ptr<const RuntimeEnvironmentSnapshot> snapshot,
        bool &dropped) {
    dropped = false;
    if (!snapshot) return false;
    std::lock_guard<std::mutex> lock(_mutex);
    if (_queue.size() >= SLOT_COUNT) {
        _queue.pop_front();
        dropped = true;
    }
    _queue.push_back(snapshot);
    _latest = std::move(snapshot);
    return true;
}

std::shared_ptr<const RuntimeEnvironmentSnapshot>
RuntimeEnvironmentInputRing::peek_oldest() const {
    std::lock_guard<std::mutex> lock(_mutex);
    if (_queue.empty()) return nullptr;
    return _queue.front();
}

std::shared_ptr<const RuntimeEnvironmentSnapshot>
RuntimeEnvironmentInputRing::latest() const {
    std::lock_guard<std::mutex> lock(_mutex);
    return _latest;
}

bool RuntimeEnvironmentInputRing::pop_generation(uint64_t generation) {
    std::lock_guard<std::mutex> lock(_mutex);
    if (_queue.empty() || !_queue.front() ||
        _queue.front()->generation != generation) {
        return false;
    }
    _queue.pop_front();
    return true;
}

size_t RuntimeEnvironmentInputRing::pop_while_day_at_most(int64_t day) {
    std::lock_guard<std::mutex> lock(_mutex);
    size_t popped = 0;
    while (!_queue.empty() && _queue.front() &&
           _queue.front()->day <= day) {
        _queue.pop_front();
        ++popped;
    }
    return popped;
}

void RuntimeEnvironmentInputRing::reset() {
    std::lock_guard<std::mutex> lock(_mutex);
    _queue.clear();
    _latest.reset();
}

bool RuntimeEnvironmentInputRing::self_test(std::string &error) {
    RuntimeEnvironmentInputRing ring;
    if (ring.peek_oldest() != nullptr) {
        error = "environment_ring_empty_peek";
        return false;
    }
    auto make = [](uint64_t generation, int64_t day) {
        auto snap = std::make_shared<RuntimeEnvironmentSnapshot>();
        snap->generation = generation;
        snap->day = day;
        snap->cell_count = 1;
        snap->topology_validated = true;
        return snap;
    };
    if (!ring.try_push(make(1, 10)) || ring.size() != 1) {
        error = "environment_ring_first_push_failed";
        return false;
    }
    for (uint64_t g = 2; g <= RuntimeEnvironmentInputRing::SLOT_COUNT; ++g) {
        if (!ring.try_push(make(g, static_cast<int64_t>(10 + g)))) {
            error = "environment_ring_fill_failed";
            return false;
        }
    }
    if (ring.try_push(make(99, 99))) {
        error = "environment_ring_overfill_accepted";
        return false;
    }
    bool dropped = false;
    if (!ring.force_push(make(100, 100), dropped) || !dropped) {
        error = "environment_ring_force_drop_failed";
        return false;
    }
    auto oldest = ring.peek_oldest();
    if (!oldest || oldest->generation != 2) {
        error = "environment_ring_fifo_order_broken";
        return false;
    }
    if (!ring.pop_generation(2) || ring.peek_oldest()->generation != 3) {
        error = "environment_ring_pop_failed";
        return false;
    }
    if (ring.latest() == nullptr || ring.latest()->generation != 100) {
        error = "environment_ring_latest_broken";
        return false;
    }
    // After force_push the queue holds gens 2..SLOT_COUNT then 100 was a drop of
    // gen1 and push 100 — then we popped 2, so head is 3. Days were 10+g.
    // Pop everything through day 14 (gen 4 has day 14).
    const size_t drained = ring.pop_while_day_at_most(14);
    if (drained == 0) {
        error = "environment_ring_day_drain_empty";
        return false;
    }
    oldest = ring.peek_oldest();
    if (oldest != nullptr && oldest->day <= 14) {
        error = "environment_ring_day_drain_left_old";
        return false;
    }
    return true;
}

} // namespace pk
