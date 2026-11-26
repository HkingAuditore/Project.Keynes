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
void set_error(RuntimeClimateVerticalReport &report, const char *value) {
    size_t i = 0;
    if (value != nullptr) {
        for (; i + 1u < sizeof(report.error) && value[i] != '\0'; ++i)
            report.error[i] = value[i];
    }
    report.error[i] = '\0';
    report.preflight_ok = 0;
}
} // namespace

void RuntimeClimateAuthority::reset(uint32_t cell_count) {
    _economy_view_cursor = {};
    _kernel.reset(cell_count);
    _continuation = {};
    _store.reset(cell_count);
    _next.reset(cell_count);
    _catalog = RuntimeClimateCatalog{};
    _catalog_ready = false;
    _plan_ready = false;
    _planned_day = -1;
    _planned_state_hash = 0;
    _planned_parity_hash = 0;
    _committed_state_hash = 0;
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
    _committed_state_hash = 0;
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
    static const bool verify_resident = [] {
        const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_CLIMATE_PHYSICS_RESIDENT_VERIFY);
        return value && std::strcmp(value, "1") == 0;
    }();
    std::unique_ptr<RuntimeClimateKernel> reference_kernel;
    RuntimeClimateStore reference_next;
    if (verify_resident) {
        reference_kernel = std::make_unique<RuntimeClimateKernel>(_kernel);
        reference_next = _next;
    }
    if (!_kernel.plan_day(day, environment, _catalog, _store, _next,
                          kernel_report, compute_hashes, validate_input, true)) {
        set_error(report, kernel_report.error);
        report.plan_ms = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - begin).count();
        _last_report = report;
        return false;
    }
    if (reference_kernel) {
        RuntimeClimateKernelReport reference_report;
        const bool reference_ok = reference_kernel->plan_day(day, environment, _catalog,
            _store, reference_next, reference_report, compute_hashes, validate_input, false);
        const auto &a = _kernel.round_output();
        const auto &b = reference_kernel->round_output();
        if (!reference_ok || _next.state_hash() != reference_next.state_hash() ||
                kernel_report.input_hash != reference_report.input_hash ||
                kernel_report.stage_ran_mask != reference_report.stage_ran_mask ||
                _kernel.distribute_soil_moisture() != reference_kernel->distribute_soil_moisture() ||
                _kernel.weather_field_init() != reference_kernel->weather_field_init() ||
                a.insolation_now != b.insolation_now || a.insolation_dev != b.insolation_dev ||
                a.day_length != b.day_length || a.heat_input != b.heat_input ||
                a.temp_season_offset != b.temp_season_offset) {
            set_error(report, "climate_resident_physics_reference_mismatch");
            return false;
        }
    }
    report.work_units = kernel_report.work_units;
    report.changed_cells = kernel_report.changed_cells;
    report.state_hash = kernel_report.state_hash;
    // SHADOW 对拍需要 parity；ACTIVE 热路径跳过（save 会自算 state_hash，writeback 报 0）。
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
    _planned_capture_cursors = environment.climate_capture_cursors;
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
    _kernel.accept_committed_physics(_store);
    _kernel.capture_continuation(_continuation);
    _continuation.capture_cursors = _planned_capture_cursors;
    report.state_hash = _planned_state_hash;
    report.parity_hash = _planned_parity_hash;
    _committed_state_hash = _planned_state_hash;
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
    _committed_state_hash = report.state_hash;
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
    _kernel.invalidate_committed_physics();
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
    _committed_state_hash = report.state_hash;
    _last_report = report;
    return true;
}

void RuntimeClimateAuthority::discard_plan() {
    _kernel.invalidate_committed_physics();
    _next.physics_state.clear();
    _plan_ready = false;
    _planned_day = -1;
    _planned_state_hash = 0;
    _planned_parity_hash = 0;
}
} // namespace pk
