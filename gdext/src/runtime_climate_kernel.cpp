#include "runtime_climate_kernel.h"
#include "runtime_climate_formulas.h"
// S3：生产 Climate pass 的共享纯内核。worker 不再维护第二套 stage 实现。
#include "runtime_climate_parity.h"
#include "runtime_climate_passes.h"
#include "runtime_climate_pass_math.h"

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
    copy_lane(next.weather_prev_type, current.weather_prev_type);
    copy_lane(next.weather_target_type, current.weather_target_type);
    copy_lane(next.weather_transition_alpha, current.weather_transition_alpha);
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
    // B8：新增的跨天 lane 必须一起复制。这里是手写清单，漏一条的后果是双缓冲
    // 之间状态不连续：vegetation 会在两天的值之间交替（实测 MapData 0/679 翻转），
    // ψ 也永远进不了 store（save/restore 表面上通过，实际存的是空 lane）。
    copy_lane(next.synoptic_psi, current.synoptic_psi);
    copy_lane(next.synoptic_psi_prev, current.synoptic_psi_prev);
    copy_lane(next.vegetation, current.vegetation);
    copy_lane(next.base_vegetation, current.base_vegetation);
    copy_lane(next.terrain, current.terrain);
    copy_lane(next.cover, current.cover);
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
    next.physics_state = current.physics_state;
    next.cyclone_state = current.cyclone_state;
}

bool physics_inputs_ready(const RuntimeEnvironmentSnapshot &in, size_t n) {
    const auto &k = in.climate_physics_knobs;
    std::string error;
    if (n == 0 || n > 10000000u || in.day < 0 || in.day > INT32_MAX ||
        !k.validate(error) || !in.climate_worker_authoritative || !k.ready || !k.enabled ||
        k.water_id_count != 4 || k.daily_period_days < 1 || k.ocean_period_days < 1 ||
        in.terrain.size() != n || in.landform.size() != n ||
        in.neighbor_indices.size() != n * 6) return false;
    // The capture boundary carries both the fixed six-neighbor table and its
    // canonical CSR offsets. Accept that representation, not arbitrary CSR.
    if (!in.neighbor_offsets.empty()) {
        if (in.neighbor_offsets.size() != n + 1) return false;
        for (size_t i = 0; i <= n; ++i)
            if (in.neighbor_offsets[i] != static_cast<int32_t>(i * 6)) return false;
    }
    for (const auto *v : {&in.cell_pos_x, &in.cell_pos_y, &in.cell_lat_norm,
                         &in.cell_elevation, &in.cell_temperature_transport_anomaly}) {
        if (v->size() != n) return false;
        for (float f : *v) if (!std::isfinite(f)) return false;
    }
    for (float f : in.cell_lat_norm) if (f < 0.0f || f > 1.0f) return false;
    for (int32_t i : in.neighbor_indices) if (i < -1 || i >= static_cast<int32_t>(n)) return false;
    return true;
}

bool physics_prepass(int64_t day, const RuntimeEnvironmentSnapshot &in,
                     const RuntimeClimateStore &current,
                     pk_async_physics::RuntimeClimatePhysicsState &s, std::string &error) {
    using namespace pk_async_physics;
    const auto &k = in.climate_physics_knobs;
    const int n = s.cell_count;
    const bool cold = !s.initialized;
    if (cold) {
        for (const auto *v : {&in.cell_wind_x, &in.cell_wind_y, &in.cell_wind_speed,
                             &in.cell_ocean_current_x, &in.cell_ocean_current_y}) {
            if (v->size() != static_cast<size_t>(n)) { error = "physics_seed_shape"; return false; }
            for (float f : *v) if (!std::isfinite(f)) { error = "physics_seed_nonfinite"; return false; }
        }
        s.wind_x = in.cell_wind_x; s.wind_y = in.cell_wind_y; s.wind_speed = in.cell_wind_speed;
        s.ocean_current_x = in.cell_ocean_current_x; s.ocean_current_y = in.cell_ocean_current_y;
        for (const auto *v : {&in.climate_physics_seed_slp, &in.climate_physics_seed_psi,
                             &in.climate_physics_seed_upwelling, &in.cell_ocean_thermal_anomaly}) {
            if (!v->empty() && v->size() != static_cast<size_t>(n)) { error = "physics_seed_shape"; return false; }
            for (float f : *v) if (!std::isfinite(f)) { error = "physics_seed_nonfinite"; return false; }
        }
        if (in.climate_physics_seed_slp.size() == static_cast<size_t>(n)) s.slp = in.climate_physics_seed_slp;
        if (in.climate_physics_seed_psi.size() == static_cast<size_t>(n)) s.ocean_psi = in.climate_physics_seed_psi;
        if (in.climate_physics_seed_upwelling.size() == static_cast<size_t>(n)) s.upwelling = in.climate_physics_seed_upwelling;
        if (in.cell_ocean_thermal_anomaly.size() == static_cast<size_t>(n)) s.ocean_thermal_anomaly = in.cell_ocean_thermal_anomaly;
    }
    bool water[256]{};
    for (uint8_t id : k.water_terrain_ids) water[id] = true;
    const auto &nb = in.neighbor_indices;
    // 生产物理读 cell_temp_anomaly（30d - 365d），不是 transport anomaly。
    std::vector<float> temp_anomaly(static_cast<size_t>(n));
    for (int i = 0; i < n; ++i)
        temp_anomaly[i] = current.temperature_30d_ema[i] - current.temperature_365d_ema[i];
    // 缓存可重建；存档不包含地图派生 CSR/coast。重建不得清除 cell-index ψ。
    if (!s.topo_valid) {
        int nw = 0;
        for (uint8_t t : in.terrain) if (water[t]) ++nw;
        s.resize_water(nw);
        if (nw > 0) psi_topology_build_pure(n, in.terrain.data(), nb.data(), water,
            s.cell_to_water.data(), s.water_to_cell.data(), s.nb_w.data());
        else std::fill(s.cell_to_water.begin(), s.cell_to_water.end(), -1);
        s.topo_valid = true;
    }
    if (!s.coast_valid) {
        WindCoastLanes l;
        l.terrain = in.terrain.data(); l.neighbors = nb.data(); l.is_water_lut = water;
        l.coast_dist = s.coast_dist.data(); l.coast_sea_x = s.coast_sea_x.data(); l.coast_sea_y = s.coast_sea_y.data();
        l.coast_sea_anchor = s.coast_sea_anchor.data(); l.sea_dist = s.sea_dist.data();
        l.sea_land_x = s.sea_land_x.data(); l.sea_land_y = s.sea_land_y.data();
        l.sea_land_anchor = s.sea_land_anchor.data(); l.scratch_queue = s.coast_scratch.data();
        wind_coast_build_pure(n, WindCoastKnobs{}, l); s.coast_valid = true;
    }
    auto rebuild_traj = [&]() {
        WindTrajKnobs tk;
        tk.wrap_period_x = k.wrap_period_x;
        tk.traj_pos_scale = std::clamp(double(k.wind_traj_pos_scale), 0.0, 4.0);
        tk.traj_dt_days = std::clamp(double(k.wind_traj_dt_days), 0.25, 60.0);
        WindTrajLanes tl;
        tl.pos_x = in.cell_pos_x.data(); tl.pos_y = in.cell_pos_y.data(); tl.neighbors = nb.data();
        tl.wind_x = s.wind_x.data(); tl.wind_y = s.wind_y.data(); tl.wind_speed = s.wind_speed.data();
        tl.traj_idx = s.wind_traj_idx.data(); tl.traj_w = s.wind_traj_w.data();
        wind_traj_build_range(n, 0, n, tk, tl);
        s.wind_traj_fingerprint = pk_wind_state_fp(n, s.wind_x.data(), s.wind_y.data(), s.wind_speed.data());
        s.wind_traj_valid = true;
    };
    if (s.wind_traj_generation > 0 && !s.wind_traj_valid) rebuild_traj();
    const bool daily_due = cold || day / k.daily_period_days != s.last_daily_day / k.daily_period_days;
    const bool ocean_due = cold || day - s.last_ocean_day >= k.ocean_period_days;
    const bool slp_due = daily_due && (cold || !k.daily_split || s.daily_due_seq % 2 == 0);
    const bool wind_due = daily_due && (cold || !k.daily_split || s.daily_due_seq % 2 != 0);
    const auto bounds = std::minmax_element(in.cell_pos_x.begin(), in.cell_pos_x.end());
    const double xmin = *bounds.first;
    const double invw = 1.0 / std::max(0.001, double(*bounds.second) - xmin);
    if (slp_due) {
        SlpPassAKnobs a;
        a.lat_amp = k.slp_lat_amp; a.land_amp = k.slp_land_amp; a.water_damp = k.slp_water_damp;
        a.interior_boost = k.slp_interior_boost; a.coast_damp = k.slp_coast_damp;
        a.thermal_weight = k.slp_thermal_weight; a.ice_high_weight = k.slp_ice_high_weight;
        a.snow_high_weight = k.slp_snow_high_weight; a.moist_low_weight = k.slp_moist_low_weight;
        a.synoptic_amp = k.slp_synoptic_amp; a.world_seed = k.world_seed;
        a.bounds_pos_x = float(xmin); a.inv_bounds_w = float(invw);
        a.has_wrap_domain = k.wrap_period_x > 0.001; a.wrap_origin_x = k.wrap_origin_x; a.wrap_period_x = k.wrap_period_x;
        std::vector<float> base, heat;
        prepare_slp_forcing(a, k.lat_lut_bins, float(in.season_phase), k.axial_tilt_deg,
            k.insolation_daylen_amp, static_cast<int>(day), k.wind_synoptic_period_days,
            k.slp_mobile_low_count, k.slp_mobile_low_amp, k.slp_mobile_low_sigma,
            k.slp_mobile_low_period_days, base, heat);
        SlpPassALanes l;
        l.lat_norm = in.cell_lat_norm.data(); l.pos_x = in.cell_pos_x.data(); l.pos_y = in.cell_pos_y.data();
        l.terrain = in.terrain.data(); l.neighbors = nb.data(); l.is_water_lut = water;
        l.temp_anomaly = temp_anomaly.data(); l.ice = current.sea_ice.data();
        l.snow = current.snow_cover.data(); l.vapor = current.vapor.data(); l.cloud = current.cloud_cover.data();
        s.slp_prev = s.slp;
        slp_pass_a_range(n, 0, n, a, l, s.slp.data(), s.slp_thermal.data());
        // 与生产三次调用完全同序，第三次包含混合前、混合后的 recenter。
        SlpPassBKnobs b;
        b.smooth_passes = k.slp_smooth_passes; b.recenter = false; b.response_rate = -1.0f;
        slp_pass_b_pure(n, b, nb.data(), nullptr, s.slp.data(), s.slp_scratch.data(), nullptr);
        b.smooth_passes = 0; b.recenter = k.slp_recenter != 0; b.target_p95 = k.slp_target_p95;
        slp_pass_b_pure(n, b, nullptr, nullptr, s.slp.data(), s.slp_scratch.data(), nullptr);
        b.target_p95 = 0.0f; b.response_rate = std::clamp(k.slp_response_rate, 0.0f, 1.0f);
        slp_pass_b_pure(n, b, nullptr, s.slp_prev.data(), s.slp.data(), nullptr, nullptr);
        s.last_slp_day = day;
    }
    if (wind_due) {
        const double elapsed = s.last_wind_day < 0 ? 1.0 : std::clamp(double(day - s.last_wind_day), 0.0, 60.0);
        WindFieldKnobs w;
        w.season_phase = in.season_phase; w.axial_tilt_deg = k.axial_tilt_deg;
        w.terrain_aware = k.wind_terrain_aware != 0; w.wind_belt_only = k.wind_belt_only_debug != 0;
        w.response_rate = std::clamp(k.wind_response_rate, 0.0f, 1.0f);
        w.synoptic_amp = k.wind_synoptic_amp; w.synoptic_period_days = std::max(0.5, double(k.wind_synoptic_period_days));
        w.max_turn_rad = std::clamp(double(k.wind_max_turn_deg_per_day) * (3.14159265358979323846 / 180.0) * elapsed, 0.0, 3.14159265358979323846);
        const double min_flux = std::max(0.0, double(k.wind_min_flux_for_dir_update)); w.min_flux_len2 = min_flux * min_flux;
        w.sim_day = static_cast<int>(day); w.world_seed = k.world_seed;
        w.bounds_pos_x = xmin; w.inv_bounds_w = invw; w.has_wrap_domain = k.wrap_period_x > 0.001;
        w.wrap_origin_x = k.wrap_origin_x; w.wrap_period_x = k.wrap_period_x;
        w.lf_mountain = k.land_lf_mountain; w.lf_peak = k.land_lf_peak; w.lf_hill = k.land_lf_hill;
        w.thermal_monsoon_enabled = k.thermal_monsoon_enabled != 0;
        w.monsoon_lat_limit = std::clamp(double(k.thermal_monsoon_lat_limit), 0.0, 1.0);
        w.monsoon_deadband = std::clamp(double(k.thermal_monsoon_deadband), 0.0, 0.10);
        w.monsoon_full_contrast = std::max(w.monsoon_deadband + 0.001, std::clamp(double(k.thermal_monsoon_full_contrast), 0.01, 0.25));
        w.monsoon_gain = std::clamp(double(k.thermal_monsoon_gain), 0.0, 1.5);
        w.monsoon_breeze_floor = std::clamp(double(k.thermal_monsoon_breeze_floor), 0.0, 0.5);
        w.momentum_advect_w = std::clamp(double(k.wind_momentum_advect_w), 0.0, 0.5);
        const double diffuse = std::clamp(double(k.wind_momentum_diffuse_w_daily), 0.0, 0.5);
        w.momentum_active = w.momentum_advect_w > 0.0 || diffuse > 0.0;
        const double grid_s = std::sqrt(double(n) / 15000.0);
        w.diffuse_w = std::min(0.5, (1.0 - std::pow(1.0 - diffuse, elapsed)) * grid_s * grid_s);
        std::vector<float> fx, fy;
        if (w.momentum_active) {
            fx.resize(n); fy.resize(n);
            for (int i = 0; i < n; ++i) { fx[i] = s.wind_x[i] * s.wind_speed[i]; fy[i] = s.wind_y[i] * s.wind_speed[i]; }
            w.snap_fx = fx.data(); w.snap_fy = fy.data();
        }
        if (w.momentum_advect_w > 0.0 && s.wind_traj_valid) { w.traj_idx = s.wind_traj_idx.data(); w.traj_w = s.wind_traj_w.data(); }
        WindFieldLanes l;
        l.lat_norm = in.cell_lat_norm.data(); l.pos_x = in.cell_pos_x.data(); l.pos_y = in.cell_pos_y.data();
        l.slp = s.slp.data(); l.neighbors = nb.data(); l.terrain = in.terrain.data(); l.landform = in.landform.data(); l.is_water_lut = water;
        l.coast_dist = s.coast_dist.data(); l.coast_sea_x = s.coast_sea_x.data(); l.coast_sea_y = s.coast_sea_y.data(); l.coast_sea_anchor = s.coast_sea_anchor.data();
        l.sea_dist = s.sea_dist.data(); l.sea_land_x = s.sea_land_x.data(); l.sea_land_y = s.sea_land_y.data(); l.sea_land_anchor = s.sea_land_anchor.data();
        l.temp = current.temperature.data(); l.wind_x = s.wind_x.data(); l.wind_y = s.wind_y.data(); l.wind_speed = s.wind_speed.data();
        l.wind_speed_out = s.wind_speed_out.data(); l.wind_delta = s.wind_delta.data(); l.wind_dir_delta = s.wind_dir_delta.data(); l.monsoon_thermal = s.monsoon_thermal.data();
        WindFieldStats stats;
        wind_field_range(n, 0, n, w, l, stats);
        const double alpha = std::min(0.3, std::clamp(double(k.wind_div_damp_alpha), 0.0, 0.3) * grid_s * grid_s);
        if (alpha > 0.0) {
            wind_divergence_range(n, 0, n, nb.data(), s.wind_x.data(), s.wind_y.data(), s.wind_speed.data(), s.slp_scratch.data());
            wind_divergence_apply_range(n, 0, n, nb.data(), s.slp_scratch.data(), alpha, s.wind_x.data(), s.wind_y.data(), s.wind_speed.data());
        }
        s.wind_speed_out = s.wind_speed;
        if (k.wind_traj_table_enabled || w.momentum_active) { rebuild_traj(); ++s.wind_traj_generation; }
        else { s.wind_traj_valid = false; s.wind_traj_generation = 0; }
        s.last_wind_day = day;
    }
    if (daily_due) { s.last_daily_day = day; ++s.daily_due_seq; }
    if (ocean_due) {
        s.ocean_psi_prev = s.ocean_psi;
        PsiSolveLanes l;
        l.n_cells = n; l.n_water = s.n_water; l.neighbors = nb.data(); l.terrain = in.terrain.data(); l.is_water_lut = water;
        l.cell_to_water = s.cell_to_water.data(); l.water_to_cell = s.water_to_cell.data(); l.nb_w = s.nb_w.data();
        l.wind_x = s.wind_x.data(); l.wind_y = s.wind_y.data(); l.wind_speed = s.wind_speed.data();
        l.lat_norm = in.cell_lat_norm.data(); l.pos_y = in.cell_pos_y.data(); l.temp = current.temperature.data();
        l.temp_anomaly = temp_anomaly.data(); l.ice = current.sea_ice.data(); l.elevation = in.cell_elevation.data();
        l.prev_psi = k.psi_warm_start ? s.ocean_psi_prev.data() : nullptr;
        l.old_ocean_x = s.ocean_current_x.data(); l.old_ocean_y = s.ocean_current_y.data();
        l.out_curl = s.wind_stress_curl.data(); l.out_psi = s.ocean_psi.data(); l.out_ocean_x = s.ocean_current_x.data(); l.out_ocean_y = s.ocean_current_y.data();
        PsiSolveScratch scratch{ s.psi_tau_x.data(), s.psi_tau_y.data(), s.psi_ny.data(), s.psi_ls.data(), s.psi_curl.data(), s.psi_beta.data(), s.psi_r.data(), s.psi_source.data(), s.psi_work.data() };
        PsiSolveStats stats;
        if (!psi_solve_pure(k.psi, l, scratch, stats)) { error = "physics_psi_failed"; return false; }
        UpwellingLanes u;
        u.lat_norm = in.cell_lat_norm.data(); u.pos_y = in.cell_pos_y.data(); u.terrain = in.terrain.data(); u.neighbors = nb.data(); u.is_water_lut = water;
        u.wind_x = s.wind_x.data(); u.wind_y = s.wind_y.data(); u.wind_speed = s.wind_speed.data(); u.upwelling = s.upwelling.data();
        upwelling_range(n, 0, n, k.upwelling, u);
        s.last_ocean_day = day;
    }
    s.initialized = true; s.committed_day = day; s.input_generation = in.generation; ++s.generation;
    return s.validate(error);
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
    // B8-1/P0：记录真实执行序。位掩码只回答"跑没跑"，而这一轮要修的是顺序，
    // 顺序错了掩码完全看不见。容量固定，溢出只影响诊断，不影响计算。
    if (report.stage_sequence_count < report.stage_sequence.size()) {
        report.stage_sequence[report.stage_sequence_count++] =
            static_cast<uint8_t>(stage);
    }
}
} // namespace

bool runtime_climate_physics_inputs_ready(const RuntimeEnvironmentSnapshot &input,
                                         size_t cells, std::string &error) {
    if (!input.climate_physics_knobs.validate(error)) return false;
    if (!physics_inputs_ready(input, cells)) { error = "physics_input_not_ready"; return false; }
    error.clear(); return true;
}

bool RuntimeEnvironmentSnapshot::ClimatePhysicsKnobs::validate(std::string &error) const {
    auto range = [&](double v, double lo, double hi, const char *name) {
        if (!std::isfinite(v) || v < lo || v > hi) { error = name; return false; }
        return true;
    };
#define PK_RANGE(field, lo, hi) if (!range(field, lo, hi, #field)) return false
    PK_RANGE(slp_lat_amp, 0, 10); PK_RANGE(slp_land_amp, 0, 10);
    PK_RANGE(slp_water_damp, 0, 1); PK_RANGE(slp_interior_boost, 0, 10);
    PK_RANGE(slp_coast_damp, 0, 1); PK_RANGE(slp_thermal_weight, 0, 10);
    PK_RANGE(slp_ice_high_weight, 0, 10); PK_RANGE(slp_snow_high_weight, 0, 10);
    PK_RANGE(slp_moist_low_weight, 0, 10); PK_RANGE(slp_response_rate, 0, 1);
    PK_RANGE(slp_synoptic_amp, 0, 10); PK_RANGE(slp_target_p95, 0, 10);
    PK_RANGE(slp_mobile_low_count, 0, 8); PK_RANGE(slp_mobile_low_amp, 0, 10);
    PK_RANGE(slp_mobile_low_sigma, 0.02f, 10); PK_RANGE(slp_mobile_low_period_days, 1, 1000000);
    PK_RANGE(slp_smooth_passes, 0, 64); PK_RANGE(slp_recenter, 0, 1);
    PK_RANGE(wind_response_rate, 0, 1); PK_RANGE(wind_max_turn_deg_per_day, 0, 360);
    PK_RANGE(wind_min_flux_for_dir_update, 0, 10); PK_RANGE(wind_synoptic_amp, 0, 10);
    PK_RANGE(wind_synoptic_period_days, 0.5, 1000000);
    PK_RANGE(wind_terrain_aware, 0, 1); PK_RANGE(wind_belt_only_debug, 0, 1);
    PK_RANGE(wind_momentum_advect_w, 0, 0.5); PK_RANGE(wind_momentum_diffuse_w_daily, 0, 0.5);
    PK_RANGE(wind_traj_table_enabled, 0, 1); PK_RANGE(wind_traj_weather_share, 0, 1);
    PK_RANGE(wind_traj_pos_scale, 0, 4); PK_RANGE(wind_traj_dt_days, 0.25, 60);
    PK_RANGE(wind_div_damp_alpha, 0, 0.3f); PK_RANGE(thermal_monsoon_enabled, 0, 1);
    PK_RANGE(thermal_monsoon_lat_limit, 0, 1); PK_RANGE(thermal_monsoon_deadband, 0, 0.10f);
    PK_RANGE(thermal_monsoon_full_contrast, 0.01f, 0.25);
    PK_RANGE(thermal_monsoon_gain, 0, 1.5); PK_RANGE(thermal_monsoon_breeze_floor, 0, 0.5);
    PK_RANGE(days_per_year, 1, 1000000); PK_RANGE(axial_tilt_deg, 0, 90);
    PK_RANGE(insolation_daylen_amp, 0, 10); PK_RANGE(lat_lut_bins, 16, 8192);
    PK_RANGE(land_lf_mountain, 0, 255); PK_RANGE(land_lf_peak, 0, 255); PK_RANGE(land_lf_hill, 0, 255);
    PK_RANGE(daily_period_days, 1, 1000000); PK_RANGE(ocean_period_days, 1, 1000000);
    PK_RANGE(wrap_origin_x, -1e9, 1e9); PK_RANGE(wrap_period_x, 0, 1e9);
    PK_RANGE(psi.total_iters, 1, 10000); PK_RANGE(psi.omega, 0.01, 1.99);
    PK_RANGE(psi.r_base, 0, 10); PK_RANGE(psi.beta_floor, 0.000001, 1);
    PK_RANGE(psi.source_scale, 0, 10); PK_RANGE(psi.oc_scale, 0, 10);
    PK_RANGE(psi.oc_max_mag, 0.01f, 1.4142136f); PK_RANGE(psi.thermohaline_weight, 0, 10);
    PK_RANGE(psi.upwelling_highlat_abs, 0, 1); PK_RANGE(psi.cold_sink_temp, -1, 1);
    PK_RANGE(psi.response_rate, 0, 1); PK_RANGE(psi.thermal_current_weight, 0, 10);
    PK_RANGE(psi.density_cold_weight, 0, 10); PK_RANGE(psi.density_ice_weight, 0, 10);
    PK_RANGE(psi.depth_curl_damp, 0, 1); PK_RANGE(psi.sea_level, 0.05f, 0.95f);
    PK_RANGE(psi.depth_ref, 0.01f, 10); PK_RANGE(psi.topo_steer_w, 0, 0.5);
    PK_RANGE(psi.min_iters, 1, psi.total_iters); PK_RANGE(psi.check_every, 1, 10000);
    PK_RANGE(psi.residual_epsilon, 0, 1);
    PK_RANGE(upwelling.ekman_gain, 0, 10); PK_RANGE(upwelling.cold_sink_gain, 0, 10);
    PK_RANGE(upwelling.highlat_abs, 0, 1); PK_RANGE(upwelling.cold_sink_temp, -1, 1);
#undef PK_RANGE
    if (water_id_count != 4) { error = "physics_water_id_count"; return false; }
    for (size_t i = 0; i < 4; ++i) for (size_t j = i + 1; j < 4; ++j)
        if (water_terrain_ids[i] == water_terrain_ids[j]) { error = "physics_water_id_duplicate"; return false; }
    error.clear(); return true;
}

// ─── Canonical Climate stage order（B8 P0）───────────────────────────────────
//
// 表必须与 runtime_climate_kernel.cpp 里 plan_day 的实际调用序一致。任何一侧
// 改动都会让 runtime_climate_stage_order_self_test() 或运行期 sequence 校验失败，
// 而不是等到数值对拍里出现"某个字段不同"。
const RuntimeClimateStageOrderEntry RUNTIME_CLIMATE_CANONICAL_ORDER[] = {
    {RuntimeClimateStage::PASS_A, RuntimeClimateStageOrderKind::CORE},
    {RuntimeClimateStage::PASS_B, RuntimeClimateStageOrderKind::CORE},
    {RuntimeClimateStage::OCEAN_WATER, RuntimeClimateStageOrderKind::CORE},
    {RuntimeClimateStage::OCEAN_LAND, RuntimeClimateStageOrderKind::CORE},
    {RuntimeClimateStage::WIND_AIR, RuntimeClimateStageOrderKind::CORE},
    {RuntimeClimateStage::WIND_SURFACE, RuntimeClimateStageOrderKind::CORE},
    {RuntimeClimateStage::SEA_ICE, RuntimeClimateStageOrderKind::CORE},
    {RuntimeClimateStage::TRANSPIRATION, RuntimeClimateStageOrderKind::CORE},
    {RuntimeClimateStage::WEATHER, RuntimeClimateStageOrderKind::CONDITIONAL},
    {RuntimeClimateStage::RUNTIME_HYDROLOGY, RuntimeClimateStageOrderKind::CONDITIONAL},
    {RuntimeClimateStage::ALBEDO, RuntimeClimateStageOrderKind::CONDITIONAL},
    {RuntimeClimateStage::VEGETATION_DYNAMICS, RuntimeClimateStageOrderKind::CONDITIONAL},
    {RuntimeClimateStage::CLIMATE_FEEDBACK, RuntimeClimateStageOrderKind::CONDITIONAL},
    {RuntimeClimateStage::STAGE_B_AFTER_HYDROLOGY,
     RuntimeClimateStageOrderKind::FALLBACK_TAIL},
};

static_assert(sizeof(RUNTIME_CLIMATE_CANONICAL_ORDER) /
                      sizeof(RUNTIME_CLIMATE_CANONICAL_ORDER[0]) ==
                  RUNTIME_CLIMATE_CANONICAL_ORDER_COUNT,
              "canonical climate order table is out of sync with its count");

size_t runtime_climate_canonical_order_index(RuntimeClimateStage stage) {
    for (size_t i = 0; i < RUNTIME_CLIMATE_CANONICAL_ORDER_COUNT; ++i) {
        if (RUNTIME_CLIMATE_CANONICAL_ORDER[i].stage == stage) return i;
    }
    return RUNTIME_CLIMATE_STAGE_COUNT;
}

const char *runtime_climate_canonical_order_names() {
    // 静态拼接：调用方（契约测试、soak dump）把它当只读字符串。
    static const std::string joined = [] {
        std::string out;
        for (size_t i = 0; i < RUNTIME_CLIMATE_CANONICAL_ORDER_COUNT; ++i) {
            if (i != 0) out += '>';
            out += runtime_climate_stage_name(
                RUNTIME_CLIMATE_CANONICAL_ORDER[i].stage);
        }
        return out;
    }();
    return joined.c_str();
}

bool runtime_climate_stage_order_self_test(std::string &error) {
    error.clear();
    // 1. 每个真实 stage 恰好出现一次，COUNT 不出现。
    std::array<int, RUNTIME_CLIMATE_STAGE_COUNT> seen{};
    bool saw_fallback_tail = false;
    bool saw_weather = false;
    for (size_t i = 0; i < RUNTIME_CLIMATE_CANONICAL_ORDER_COUNT; ++i) {
        const RuntimeClimateStageOrderEntry &entry =
            RUNTIME_CLIMATE_CANONICAL_ORDER[i];
        const size_t index = static_cast<size_t>(entry.stage);
        if (index >= RUNTIME_CLIMATE_STAGE_COUNT) {
            error = "climate_stage_order_contains_count";
            return false;
        }
        if (++seen[index] != 1) {
            error = std::string("climate_stage_order_duplicate_") +
                runtime_climate_stage_name(entry.stage);
            return false;
        }
        // 2. FALLBACK_TAIL 只能在表尾，且不能再出现 CORE/CONDITIONAL。
        if (entry.kind == RuntimeClimateStageOrderKind::FALLBACK_TAIL) {
            saw_fallback_tail = true;
            if (i + 1u != RUNTIME_CLIMATE_CANONICAL_ORDER_COUNT) {
                error = "climate_stage_order_fallback_tail_not_last";
                return false;
            }
        } else if (saw_fallback_tail) {
            error = "climate_stage_order_core_after_fallback_tail";
            return false;
        }
        // 3. weather 段必须在 round 之后。round 的最后一个 stage 是 TRANSPIRATION；
        //    这条断言就是 B8-1 的机器可读形式。
        if (entry.stage == RuntimeClimateStage::WEATHER) saw_weather = true;
        if (entry.stage == RuntimeClimateStage::TRANSPIRATION && saw_weather) {
            error = "climate_stage_order_weather_before_round";
            return false;
        }
    }
    for (size_t i = 0; i < RUNTIME_CLIMATE_STAGE_COUNT; ++i) {
        if (seen[i] != 1) {
            error = std::string("climate_stage_order_missing_") +
                runtime_climate_stage_name(
                    static_cast<RuntimeClimateStage>(i));
            return false;
        }
    }
    // 4. stage_b 三段必须严格在 weather 之后，且内部顺序是 albedo → veg → feedback。
    const size_t weather = runtime_climate_canonical_order_index(
        RuntimeClimateStage::WEATHER);
    const size_t albedo = runtime_climate_canonical_order_index(
        RuntimeClimateStage::ALBEDO);
    const size_t vegetation = runtime_climate_canonical_order_index(
        RuntimeClimateStage::VEGETATION_DYNAMICS);
    const size_t feedback = runtime_climate_canonical_order_index(
        RuntimeClimateStage::CLIMATE_FEEDBACK);
    const size_t hydrology = runtime_climate_canonical_order_index(
        RuntimeClimateStage::RUNTIME_HYDROLOGY);
    if (!(weather < hydrology && hydrology < albedo && albedo < vegetation &&
          vegetation < feedback)) {
        error = "climate_stage_order_stage_b_not_after_weather";
        return false;
    }
    return true;
}

bool runtime_climate_stage_sequence_is_canonical(
        const uint8_t *sequence, size_t count, std::string &error) {
    error.clear();
    if (sequence == nullptr && count != 0) {
        error = "climate_stage_sequence_null";
        return false;
    }
    size_t previous = 0;
    bool have_previous = false;
    for (size_t i = 0; i < count; ++i) {
        const size_t raw = static_cast<size_t>(sequence[i]);
        if (raw >= RUNTIME_CLIMATE_STAGE_COUNT) {
            error = "climate_stage_sequence_out_of_range";
            return false;
        }
        const auto stage = static_cast<RuntimeClimateStage>(raw);
        const size_t index = runtime_climate_canonical_order_index(stage);
        if (index == RUNTIME_CLIMATE_STAGE_COUNT) {
            error = std::string("climate_stage_sequence_unknown_") +
                runtime_climate_stage_name(stage);
            return false;
        }
        if (have_previous && index < previous) {
            error = std::string("climate_stage_sequence_out_of_order_") +
                runtime_climate_stage_name(
                    static_cast<RuntimeClimateStage>(
                        sequence[i - 1u])) +
                "_then_" +
                runtime_climate_stage_name(stage);
            return false;
        }
        previous = index;
        have_previous = true;
    }
    return true;
}

void RuntimeClimateKernel::reset(uint32_t) {
    // 换图 / authority reset 后，weather field_init 的"已播种"标记必须一起清掉。
    _weather_field_init_seeded = false;
    // B8 P2：物理常驻状态整份丢弃（含派生缓存指纹），下次 plan_day 按新 shape 重建。
    _physics = pk_async_physics::RuntimeClimatePhysicsState{};
}

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

bool RuntimeClimateKernel::plan_day(int64_t day, const RuntimeEnvironmentSnapshot &input,
                                    const RuntimeClimateCatalog &catalog,
                                    const RuntimeClimateStore &current,
                                    RuntimeClimateStore &next,
                                    RuntimeClimateKernelReport &report,
                                    bool compute_state_hash,
                                    bool validate_input) const {
    report = RuntimeClimateKernelReport{};
    // B8 P2：物理环流 prepass 的就绪状态。worker 用自己的 lane，只缺 profile 标量；
    // 未就绪时物理继续读生产 transport（不静默算错），这一行给出第一手证据。
    {
        // 前 6 天都打：bake 的 knob base 可能在首日 capture 之后才建好，只打前两天
        // 会看不到 ready 从 0→1 的切换（实测踩过）。
        static std::atomic<int> s_physics_ready_reports_left{6};
        if (s_physics_ready_reports_left.fetch_sub(1, std::memory_order_relaxed) > 0) {
            std::fprintf(stderr,
                "[climate/worker][b8] physics_knobs day=%lld ready=%d missing=%s\n",
                static_cast<long long>(day),
                input.climate_physics_knobs.ready ? 1 : 0,
                input.climate_physics_knobs.missing_key);
            std::fflush(stderr);
        }
    }
    std::string error;
    std::string current_error;
    std::string next_error;
    // publish 边界已对同一份 snapshot 做过完整 validate；热路径再跑一遍会把
    // hydro cycle（O(cells·depth)）和有限性扫描算进 plan_ms。
    if (validate_input && !validate_runtime_environment_snapshot(input, error)) {
        copy_error(report, error.c_str());
        return false;
    }
    // 提交态 store：形状契约即可。finite / physics decode 留给 save 与自测。
    if (!current.validate_shape(current_error) || &current == &next ||
        catalog.abi_version != RUNTIME_DOMAIN_POD_ABI_VERSION ||
        catalog.cell_count != current.cell_count || next.cell_count != current.cell_count ||
        (input.climate_catalog_hash != 0 && input.climate_catalog_hash != catalog.hash) ||
        day < 0 || day > INT32_MAX || current.committed_day >= day) {
        const char *reason = !current_error.empty() ? current_error.c_str()
                                                    : "climate_kernel_preflight_failed";
        copy_error(report, reason);
        return false;
    }
    // next 是可丢弃工作区。上次失败留下的无效值不能阻止从有效 current 重试。
    if (!next.validate_shape(next_error)) next.reset(current.cell_count);
    copy_store_lanes(next, current);
    // 每次计划从提交态恢复；kernel 成员只是工作区，discard/retry 不推进权威。
    if (!pk_async_physics::restore_physics_state(current.physics_state.data(),
            current.physics_state.size(), _physics, error)) {
        copy_error(report, error.c_str()); return false;
    }
    if (current.physics_state.empty()) _physics.resize(static_cast<int>(current.cell_count));
    if (_physics.cell_count != static_cast<int>(current.cell_count)) {
        copy_error(report, "physics_store_shape_mismatch"); return false;
    }
    const bool physics_owned = physics_inputs_ready(input, current.cell_count);
    if (physics_owned && !physics_prepass(day, input, current, _physics, error)) {
        copy_error(report, error.c_str()); return false;
    }
    if (physics_owned) report.work_units += uint64_t(current.cell_count) *
        (uint64_t(_physics.last_slp_day == day) + uint64_t(_physics.last_wind_day == day) +
         2u * uint64_t(_physics.last_ocean_day == day));
    // 缺配置时不能沿用上次 ready 来授权主线程停算。
    if (!physics_owned) _physics.initialized = false;
    _physics.committed_day = day;
    _physics.input_generation = input.generation;
    _cyclone_seeded = false;
    _cyclone_entries.clear();
    _cyclone_next_stable_id = 1;
    // B8-2：store 里的 synoptic ψ 是跨天 + 跨存档的权威副本。先把它装进 kernel
    // scratch；只有"store 里确实有非零状态"才算已播种，否则留着让生产 capture
    // 的冷启动种子生效（ABI 3 旧档读进来就是全零）。
    if (current.physics_state.empty() && current.synoptic_psi.size() == current.cell_count &&
        current.synoptic_psi_prev.size() == current.cell_count) {
        for (size_t i = 0; i < current.synoptic_psi.size(); ++i) {
            if (current.synoptic_psi[i] != 0.0f ||
                current.synoptic_psi_prev[i] != 0.0f) {
                _physics.synoptic_psi = current.synoptic_psi;
                _physics.synoptic_psi_prev = current.synoptic_psi_prev;
                _physics.synoptic_seeded = true;
                break;
            }
        }
    }
    // B8-P1：演替状态的冷启动。store 里全零（新图 / ABI 4 旧档）时用生产 capture
    // 的 vegetation lane 播种；之后由 worker 的演替 emit 自己推进。
    if (current.vegetation.size() == current.cell_count &&
        !current.vegetation.empty() &&
        input.vegetation.size() == current.cell_count) {
        bool vegetation_seeded = false;
        for (uint8_t value : current.vegetation) {
            if (value != 0u) {
                vegetation_seeded = true;
                break;
            }
        }
        if (!vegetation_seeded) {
            next.vegetation = input.vegetation;
            next.base_vegetation = input.vegetation;
        }
    }
    // B8-P1 / ABI 8：terrain / cover 冷启动。store 全零（新图 / ABI<=7 旧档）时
    // 用环境快照播种；之后由 sea_ice 翻转与 weather distribute 在 worker 侧推进。
    if (current.terrain.size() == current.cell_count &&
        !current.terrain.empty() &&
        input.terrain.size() == current.cell_count) {
        bool terrain_seeded = false;
        for (uint8_t value : current.terrain) {
            if (value != 0u) {
                terrain_seeded = true;
                break;
            }
        }
        if (!terrain_seeded) next.terrain = input.terrain;
    }
    if (current.cover.size() == current.cell_count &&
        !current.cover.empty() &&
        input.cover.size() == current.cell_count) {
        bool cover_seeded = false;
        for (uint8_t value : current.cover) {
            if (value != 0u) {
                cover_seeded = true;
                break;
            }
        }
        if (!cover_seeded) next.cover = input.cover;
    }
    // B8-2：cyclone 状态同样先看 store（存档恢复），再退回 capture 的生产种子。
    // blob 的语义由 cyclone_state_encode/decode 拥有；只要 header 合法就算播种成功，
    // 哪怕是"0 个条目"—— 否则 worker 会每天重新播种、永远不开始自己的推进。
    if (!_cyclone_seeded && !current.cyclone_state.empty()) {
        cyclone_state_decode(current.cyclone_state, _cyclone_entries,
                             _cyclone_next_stable_id);
        if (current.cyclone_state.size() >= 16u) {
            _cyclone_seeded = true;
        }
    }
    if (!_cyclone_seeded && !input.cyclone_seed_blob.empty()) {
        cyclone_state_decode(input.cyclone_seed_blob, _cyclone_entries,
                             _cyclone_next_stable_id);
        if (input.cyclone_seed_blob.size() >= 16u) {
            _cyclone_seeded = true;
        }
    }
    // P2 日序：physics → synoptic → cyclone stamp → round → weather。
    bool physics_cyclone_stamp_ready = false;
    if (physics_owned && input.climate_weather && input.climate_weather->ran) {
        const auto &wx = *input.climate_weather;
        const size_t n = current.cell_count;
        if (wx.n_cells != static_cast<int>(n)) { copy_error(report, "physics_weather_shape"); return false; }
        const auto &nb = input.neighbor_indices;
        const char *syn_off = std::getenv("PK_CLIMATE_SYNOPTIC_OFF");
        if (wx.synoptic_enabled && !(syn_off && syn_off[0] == '1')) {
            if (!_physics.synoptic_seeded) {
                if (wx.psi.size() == n) _physics.synoptic_psi = wx.psi;
                if (wx.psi_prev.size() == n) _physics.synoptic_psi_prev = wx.psi_prev;
                _physics.synoptic_seeded = true;
            }
            if (_physics.synoptic_tick == INT32_MAX) { copy_error(report, "physics_synoptic_tick_overflow"); return false; }
            auto syn = wx.synoptic;
            syn.tick = ++_physics.synoptic_tick;
            pk_async_climate::synoptic_advance_pure(static_cast<int>(n), nb.data(),
                input.cell_pos_x.data(), input.cell_pos_y.data(), _physics.wind_x.data(),
                _physics.wind_y.data(), current.temperature.data(), syn,
                _physics.synoptic_psi, _physics.synoptic_psi_prev);
        }
        const char *cyc_force = std::getenv("PK_CLIMATE_CYCLONE_FORCE");
        if (input.cyclone_enabled || (cyc_force && cyc_force[0] == '1')) {
            // stamp/tag 是当日派生场，每次从空工作区重建，使重试不依赖上次计划。
            _cyclone_force_tag.assign(n, 0); _cyclone_visit_tag.assign(n, 0);
            _cyclone_force_x.assign(n, 0); _cyclone_force_y.assign(n, 0); _cyclone_lift.assign(n, 0);
            _cyclone_force_generation = 1;
            pk_async_climate::CycloneAdvanceKnobs ck;
            ck.enabled = true; ck.dt_days = input.cyclone_dt_days;
            ck.world_bounds_pos_y = input.cyclone_world_bounds_pos_y;
            ck.world_bounds_size_y = input.cyclone_world_bounds_size_y;
            ck.wrap_width_x = input.cyclone_wrap_width_x; ck.max_radius_cells = input.cyclone_max_radius_cells;
            pk_async_climate::CycloneLanes cl;
            cl.neighbors = nb.data(); cl.pos_x = input.cell_pos_x.data(); cl.pos_y = input.cell_pos_y.data();
            cl.lat_norm = input.cell_lat_norm.data(); cl.terrain = input.terrain.data(); cl.temp = current.temperature.data();
            cl.wind_x = _physics.wind_x.data(); cl.wind_y = _physics.wind_y.data(); cl.wind_speed = _physics.wind_speed.data();
            cl.vapor = current.vapor.data(); cl.instability = current.instability.data(); cl.convergence = current.convergence.data();
            pk_async_climate::CycloneStamp stamp;
            stamp.force_tag = _cyclone_force_tag.data(); stamp.visit_tag = _cyclone_visit_tag.data();
            stamp.force_x = _cyclone_force_x.data(); stamp.force_y = _cyclone_force_y.data(); stamp.lift = _cyclone_lift.data();
            stamp.force_generation = stamp.visit_generation = 1;
            pk_async_climate::CycloneStats stats;
            pk_async_climate::cyclone_advance_and_stamp_pure(static_cast<int>(n), ck, cl, _cyclone_entries, stamp, stats);
            _physics.cyclone_total_decayed += static_cast<uint64_t>(std::max(0, stats.decayed));
            report.cyclone_touched = stats.touched_cells;
            physics_cyclone_stamp_ready = true;
            _cyclone_seeded = true;
        }
    }
    // climate_anomaly 是季节系统给出的全局量，不是 Climate 域自己的状态：生产每 tick
    // 从 environment 提供它，而 worker 的 store 只在 day % 365 == 0 改写。两者因此长期
    // 不等，且这个差异不在 parity 字段表里（只进 parity_hash），会一直隐身。它进
    // weather knobs 与温度合成，采纳生产的值是长期正确的语义 —— 年度漂移仍由下面的
    // annual_temperature_drift 维护，供 ACTIVE 模式下 environment 缺值时兜底。
    if (std::isfinite(input.climate_anomaly)) {
        next.climate_anomaly = static_cast<float>(input.climate_anomaly);
    }
    // 季末地理级重算在当天 climate round 之前跑（SUS priority 50 vs 210）。
    // capture 里的 cell_moisture 是 tick 开头、refresh 之前的快照，不能当权威。
    // 生产 pass_a 的输入才是 stage 0/1/3/4 全部写完之后的值。没有 production
    // overlay 时退回 stage 0：陆地 moisture = clamp(base, 0, 1)，水体 = base。
    // ACTIVE 之后这条语义依然成立：season refresh 保持在主线程，它是地理权威。
    if (input.climate_season_refresh_ran &&
        next.moisture.size() == current.cell_count) {
        const auto &round_moist = input.climate_round_input.moisture;
        const auto &round_base = input.climate_round_input.base_moisture;
        if (input.climate_round_ran &&
            round_moist.size() == current.cell_count) {
            for (size_t i = 0; i < current.cell_count; ++i) {
                const float m = round_moist[i];
                if (std::isfinite(m)) next.moisture[i] = m;
            }
        } else {
            const auto &bases = !round_base.empty() ? round_base
                                                    : input.cell_base_moisture;
            const auto &water = input.climate_round_input.is_water.empty()
                ? input.is_water : input.climate_round_input.is_water;
            if (bases.size() == current.cell_count) {
                for (size_t i = 0; i < current.cell_count; ++i) {
                    const float base = bases[i];
                    if (!std::isfinite(base)) continue;
                    const bool is_water = i < water.size() && water[i] != 0u;
                    const float m = is_water ? base
                        : climate_formula::clamp01(base);
                    next.moisture[i] = m;
                }
            }
        }
    }
    // PAW 每天在这里重算，而不是从 input 收回。它是 f(moisture, WB30, soil) 的纯派生
    // 量，没有跨天累积，所以「收回」这个动作本身就是错的抽象。
    //
    // 不收回的理由是收了没用。ACTIVE 下 PAW 有两份，通过 MapData 首尾相接：
    //
    //   next.plant_available_water（store，进回灌表）
    //       ↑ 每 48 天被 vegetation_dynamics 写一次，别处不写
    //   input.climate_round_input.plant_*（capture 从 slot 填，喂共享 round）
    //       ↑ 就是上面那份昨天回灌的结果
    //
    // 于是 PAW 只在 vegetation_dynamics 那几天动一下 —— 实测 150 天两个值
    // （0.296 / 0.302），而主线程那侧单调降 12%（0.294 → 0.258）。transpiration 每天拿
    // PAW 乘 heat 算 vegetation_growth_pressure，所以整条植被链的活跃 cell 集合跟着锁死。
    //
    // season refresh 那侧的写入也进不来：capture 早于 _sus.tick()（见
    // world_ext_simulation_host.cpp 里 fill_climate_round_input 那处说明），而 season
    // refresh 跑在 _sus.tick() 里，它写完 MapData 之后，第二天开头的回灌就把它覆盖了。
    // moisture 没有这个问题，因为它的收回走 base_moisture，那条场没有 store 成员、不在
    // 回灌表里，主线程仍是它唯一的写者。
    //
    // SHADOW 必须保持原样（PAW 跟着生产的 48/49 天节拍走），每天自算会立刻分叉，所以
    // 这一段由 climate_own_paw 门控。
    //
    // 用 next 而不是 current 读 moisture：上面那段收回可能刚把 season refresh 的
    // base_moisture 写进 next.moisture，PAW 应当看到它。soil 只能从 environment 读 ——
    // 它没有 store 成员，worker 手里那份是 distribute 的 scratch，跨天累积由 MapData
    // 承载（见 RuntimeClimateSnapshot::soil_moisture）。
    if (input.climate_worker_authoritative &&
        next.plant_available_water.size() == current.cell_count &&
        next.moisture.size() == current.cell_count &&
        next.water_balance_30d.size() == current.cell_count) {
        const auto &soil = input.cell_soil_moisture;
        const auto &water = input.is_water;
        // B8-3 归因诊断：PAW 链 collapse 的逐日输入。只打前 12 天、每图选第一个
        // 陆地格（水域 PAW 恒 0，看它没有意义）。定位"是 WB30 变负、soil 缺席、
        // 还是权重口径不同"三选一，而不是继续猜。
        static std::atomic<int> s_paw_reports_left{12};
        size_t paw_probe_cell = current.cell_count;
        for (size_t i = 0; i < current.cell_count; ++i) {
            if (i >= water.size() || water[i] == 0u) {
                paw_probe_cell = i;
                break;
            }
        }
        const bool paw_probe = paw_probe_cell < current.cell_count &&
            s_paw_reports_left.load(std::memory_order_relaxed) > 0;
        for (size_t i = 0; i < current.cell_count; ++i) {
            // 水域格 PAW 恒 0，与生产两处调用点的 is_water 分支一致
            // （runtime_climate_passes.cpp:2602 与 :5043）。
            if (i < water.size() && water[i] != 0u) {
                next.plant_available_water[i] = 0.0f;
                continue;
            }
            next.plant_available_water[i] = climate_formula::plant_available_water(
                next.moisture[i], next.water_balance_30d[i],
                i < soil.size() ? soil[i] : 0.0f,
                input.climate_paw_water_balance_weight,
                input.climate_paw_soil_buffer_weight,
                input.climate_paw_drought_penalty);
        }
        if (paw_probe) {
            s_paw_reports_left.fetch_sub(1, std::memory_order_relaxed);
            const size_t c = paw_probe_cell;
            // 零值按水/陆分类：PAW 的"collapse"要么是水域规则（生产共享内核同样
            // 把 water/veg_none 清零），要么是陆地真的算错。分类计数一次就能分开。
            size_t zero_water = 0, zero_land = 0, nonzero = 0;
            for (size_t i = 0; i < current.cell_count; ++i) {
                const bool is_water = i < water.size() && water[i] != 0u;
                if (next.plant_available_water[i] == 0.0f) {
                    if (is_water) ++zero_water; else ++zero_land;
                } else {
                    ++nonzero;
                }
            }
            std::fprintf(stderr,
                "[climate/worker][b8] paw day=%lld cell=%zu moisture=%.6g "
                "wb30=%.6g soil=%s%.6g paw=%.6g "
                "zeros(water=%zu land=%zu) nonzero=%zu weights(wb=%.4g soil=%.4g dry=%.4g) "
                "round=%d distribute=%d hydrology=%d\n",
                static_cast<long long>(day), c, next.moisture[c],
                next.water_balance_30d[c],
                c < soil.size() ? "" : "missing/",
                c < soil.size() ? soil[c] : 0.0f,
                next.plant_available_water[c],
                zero_water, zero_land, nonzero,
                input.climate_paw_water_balance_weight,
                input.climate_paw_soil_buffer_weight,
                input.climate_paw_drought_penalty,
                input.climate_round_ran ? 1 : 0,
                (input.climate_weather_distribute != nullptr &&
                 input.climate_weather_distribute->ran) ? 1 : 0,
                (input.climate_hydrology != nullptr &&
                 input.climate_hydrology->ran) ? 1 : 0);
            std::fflush(stderr);
        }
    }
    // 生产 stage 11（consume_feedback_buffers）在 climate round / hydrology 之前
    // 把 VGP *= decay。放在全部 stage 之后会让当天 hydrology 仍按未衰减的 VGP
    // 抽水，比完之后 VGP 本身却是绿的——day 28 的 moisture/PAW/河网链就是这样。
    if (input.climate_seasonal_feedback_ran &&
        next.vegetation_growth_pressure.size() == current.cell_count) {
        const float decay = input.climate_seasonal_feedback_decay;
        if (std::isfinite(decay)) {
            for (size_t i = 0; i < current.cell_count; ++i) {
                next.vegetation_growth_pressure[i] *= decay;
            }
        }
    }
    report.input_hash = input_hash(input);
    // 生产这一天跑了哪些 stage。与下面累积的 report.stage_ran_mask 的差集就是
    // "生产算了、worker 没算"——分叉矩阵里 stage 9..13 的字段全靠它归因。
    report.production_stage_mask = input.climate_production_stage_mask;

    // 生产 Climate round 按 stride 跑，不是每日一轮。这一天生产没跑 round 时，
    // reference 里 Climate 拥有的场与前一天完全相同，所以 worker 也必须一个 stage
    // 都不跑：copy_store_lanes 已经把状态原样搬过来了，直接收工即为等价。
    // 反之若 worker 每天都跑，它会在生产没动的日子里单方面推进温度场，而分叉矩阵
    // 会把这种节拍错位报成算法分叉。
    // albedo 不在 climate round 里：它跑在 native daily graph 的 stage_b 段、用
    // cp.weather_albedo_stride 自己的节拍。所以"这一天 worker 要不要干活"是两个
    // 独立条件的并集 —— 只看 round 会漏掉那些生产只跑了 albedo 的日子，而 albedo 是
    // temp 的日内最后写者，漏一天温度场就整场落后一个 delta。
    // feedback（stage 10）同在 stage_b 段、同样有自己的 stride，所以是第三个独立条件。
    // vegetation_dynamics（stage 9）与 feedback（stage 10）同在 stage_b 段、各有自己的
    // stride，所以是第三、第四个独立条件。
    const bool vegetation_requested = input.climate_vegetation != nullptr &&
        input.climate_vegetation->knobs.ran &&
        input.climate_vegetation->n_cells == static_cast<int>(current.cell_count);
    const bool feedback_requested = input.climate_feedback != nullptr &&
        input.climate_feedback->knobs.ran &&
        input.climate_feedback->n_cells == static_cast<int>(current.cell_count);
    // weather（stage 11）跑在 round 末尾，但有自己的 weather bucket cadence，所以同样
    // 是一个独立条件：只看 round 会在"生产这天只跑了 weather"的日子上什么都不做。
    const bool weather_requested = input.climate_weather != nullptr &&
        input.climate_weather->ran &&
        input.climate_weather->n_cells == static_cast<int>(current.cell_count);
    // hydrology（stage 12）有 runtime_hydrology_stride 自己的节拍，同样是一个独立条件。
    const bool hydrology_requested = input.climate_hydrology != nullptr &&
        input.climate_hydrology->ran &&
        input.climate_hydrology->n_cells == static_cast<int>(current.cell_count);
    // weather distribute 跟 weather bucket 同节拍，但它自己的记录可能缺席（字段不全）。
    const bool distribute_requested =
        input.climate_weather_distribute != nullptr &&
        input.climate_weather_distribute->ran &&
        input.climate_weather_distribute->n_cells == static_cast<int>(current.cell_count);
    if (!input.climate_round_ran && !input.climate_albedo.ran &&
        !vegetation_requested && !feedback_requested && !weather_requested &&
        !hydrology_requested && !distribute_requested) {
        if (!pk_async_physics::serialize_physics_state(_physics, next.physics_state, error)) {
            copy_error(report, error.c_str()); return false;
        }
        next.committed_day = day;
        ++next.generation;
        ++next.climate_generation;
        report.completed = 1;
        if (compute_state_hash) report.state_hash = next.state_hash();
        return true;
    }

    const size_t cells = current.cell_count;
    const float season = static_cast<float>(input.season_phase);
    // The capture boundary carries the actual logical-day delta. Clamping to
    // one day here silently slowed stride/fast-forward runs and made EMA,
    // transition, hydrology and sea-ice state depend on call frequency.
    const float dt = std::clamp(input.dt_days, 1.0f,
                                std::max(1.0f, catalog.dt_days_cap));

    // S3（断点 2）：优先走生产共享纯内核。round_in 由主线程 capture 时用
    // DCWorldExt::fill_climate_round_input 填好，与 async_climate_round_kick 走同
    // 一段提取代码，所以 worker 与生产 round 吃的是逐位相同的输入。
    //
    // n_cells 不匹配（旧 harness / 稀疏 fixture / 未接线的地图）时退回下面的诊断
    // 近似实现。这条回退路径不具备 parity 语义，只用于让 SHADOW 诊断不中断。
    const pk_async_climate::ClimateInputBuf &round_in = input.climate_round_input;
    const bool shared_passes_available =
        input.climate_round_ran &&
        round_in.n_cells > 0 && static_cast<size_t>(round_in.n_cells) == cells;

    // ─── 共享 round：9 个 pass 一次跑完（生产用的同一份编排 + 同一份内核）────
    //
    // 覆盖 stage PASS_A..TRANSPIRATION。这里刻意不逐 stage 分别调用内核：pass 之间
    // 的 in←out 接力字段是编排的一部分，拆开调用就等于在 worker 里重写一遍顺序。
    //
    // shared_passes_available 为假时（旧 harness / 未接线的地图）落到下面的诊断近似，
    // 那条路径没有 parity 语义，只保证 SHADOW 诊断不中断。
    bool shared_round_ran = false;
    if (shared_passes_available) {
        _round_in = round_in;   // 编排在 in 上做接力，必须给它可变副本
        if (physics_owned) {
            _round_in.wind_x = _physics.wind_x; _round_in.wind_y = _physics.wind_y;
            _round_in.wind_speed = _physics.wind_speed;
            _round_in.ocean_current_x = _physics.ocean_current_x;
            _round_in.ocean_current_y = _physics.ocean_current_y;
            _round_in.upwelling_strength = _physics.upwelling;
            _round_in.wind_traj_idx.clear(); _round_in.wind_traj_w.clear();
            if (input.climate_physics_knobs.wind_traj_weather_share && _physics.wind_traj_valid) {
                _round_in.wind_traj_idx = _physics.wind_traj_idx;
                _round_in.wind_traj_w = _physics.wind_traj_w;
            }
        }
        // water terrain LUT 走 static knobs（它不是 per-cell lane，capture 的 slot 兜底
        // 覆盖不到）。round input 里没带时从 static knobs 补，否则 sea_ice 会饿死。
        if (_round_in.water_terrain_ids.empty()) {
            _round_in.water_terrain_ids =
                input.climate_round_static_knobs.water_terrain_ids;
        }
        // ABI 8：ACTIVE 下 MapData terrain 被冻结，round 必须吃 worker 自持副本，
        // 否则海冰翻转无法跨天累积。
        if (next.terrain.size() == cells) {
            _round_in.terrain = next.terrain;
        }
        // scalars 由 capture 侧整套填好（world_ext_simulation_host.cpp 里
        // climate_round_scalars 那段），这里不再逐字段补。
        //
        // 留一道 season_phase 的兜底：它是 scalars 里唯一的时变量，0.0 不是"合理
        // 默认"而是"永远的春分"，日照整年不动。旧 harness / 未接线的地图不传
        // climate_round_scalars 时，至少不能让整个季节链停摆。
        if (input.climate_worker_authoritative &&
            _round_in.scalars.season_phase == 0.0 && input.season_phase != 0.0) {
            _round_in.scalars.season_phase = input.season_phase;
        }
        _round_out.n_cells = static_cast<int>(cells);
        pk_async_climate::ClimateRoundPassTiming timing;
        const bool round_ok = pk_async_climate::run_climate_round_passes(
            _round_in, input.climate_round_static_knobs, _round_work, _round_out,
            &timing);

        // 一次性诊断（worker 线程，不能用 Godot 的 print）：说明这一天走的是共享编排
        // 还是下面的近似回退。回退是静默的，而两者的数值差一个数量级，缺了这行日志
        // 就只能从分叉矩阵反推。
        static std::atomic<bool> shared_path_logged{false};
        bool expected = false;
        if (shared_path_logged.compare_exchange_strong(expected, true)) {
            std::fprintf(stderr,
                "[climate-kernel][round] shared=%d ok=%d n_cells=%d mask=0x%X "
                "ran=0x%X starved=0x%X knobs_cells=%d\n",
                1, round_ok ? 1 : 0, round_in.n_cells,
                round_in.scalars.passes_mask, timing.passes_ran,
                timing.passes_starved,
                input.climate_round_static_knobs.n_cells);
            std::fflush(stderr);
        }
        // starved = 这个 pass 被 mask 启用了，但输入 lane 不完整所以没跑。它的 out
        // 字段留空，下面的 scatter 会静默 no-op —— 于是 worker 少跑了半个 round，而
        // 分叉矩阵只会看到"某些字段停在昨天的值"，和算法分叉长得一模一样。所以这里
        // 必须当作输入边界故障报出来，而不是当成一次成功的 round。
        if (timing.passes_starved != 0) {
            report.round_passes_starved = timing.passes_starved;
            static std::atomic<bool> starved_logged{false};
            bool starved_expected = false;
            if (starved_logged.compare_exchange_strong(starved_expected, true)) {
                std::fprintf(stderr,
                    "[climate-kernel][round] input starved passes=0x%X — "
                    "round input lanes incomplete (n=%d)\n",
                    timing.passes_starved, _round_in.n_cells);
                // 只报"哪个 pass 饿死"还得回头对着守卫条件人工比对；直接把这个 pass
                // 需要的 lane 长度打出来，缺哪条一眼可见。
                if ((timing.passes_starved & 0x40) != 0) {
                    std::fprintf(stderr,
                        "[climate-kernel][round]   sea_ice lanes: terrain=%zu "
                        "base_terrain=%zu sea_ice_frac_inout=%zu tta=%zu "
                        "upwelling=%zu insol_now=%zu cell_temp_arr=%zu "
                        "water_terrain_ids=%zu\n",
                        _round_in.terrain.size(), _round_in.base_terrain.size(),
                        _round_in.sea_ice_frac_inout.size(),
                        _round_in.temp_transport_anomaly.size(),
                        _round_in.upwelling_strength.size(),
                        _round_in.insolation_now.size(),
                        _round_in.cell_temperature_arr.size(),
                        _round_in.water_terrain_ids.size());
                }
                std::fflush(stderr);
            }
        }
        report.round_passes_ran = timing.passes_ran;
        // passes_mask 的 bit 0..7 与 RuntimeClimateStage 的 PASS_A..TRANSPIRATION
        // 一一对应；bit 8 是 finalizer，它不是一个 stage（没有自己的 stage 槽位）。
        report.stage_ran_mask |= timing.passes_ran & 0xFF;
        if (!round_ok) {
            runtime_copy_text(report.error, "climate_shared_round_failed");
            return false;
        }

        // 把编排输出散射回 store。只写生产侧确实由这些 pass 授权的 lane——
        // 多写一条就会掩盖后面尚未接入共享实现的 stage 的真实分叉。
        auto scatter = [cells](std::vector<float> &dst,
                               const std::vector<float> &src) {
            if (src.size() == cells) std::memcpy(dst.data(), src.data(),
                                                 cells * sizeof(float));
        };
        scatter(next.temperature_baseline, _round_out.temp_baseline);
        scatter(next.thermal_energy,       _round_out.thermal_energy);
        scatter(next.moisture,             _round_out.moisture);
        scatter(next.temperature_30d_ema,  _round_out.temp_30d);
        scatter(next.temperature_365d_ema, _round_out.temp_365d);
        scatter(next.snowpack,             _round_out.snowpack);
        // cell_temp 由 wind_surface 末端合成、finalizer 收尾 clamp；这是 round 内
        // 温度场的唯一授权写者。
        scatter(next.temperature,          _round_out.temp);
        scatter(next.sea_ice,              _round_out.sea_ice_frac);
        // ABI 8：sea_ice 翻转后的 terrain 写回 worker store，供次日 round 与 writeback。
        if (_round_out.terrain.size() == cells && next.terrain.size() == cells) {
            std::memcpy(next.terrain.data(), _round_out.terrain.data(), cells);
        }

        // 逐 pass 耗时记进对应 stage 槽位（索引与 passes_mask 的 bit 位一致）。
        // finalizer 没有独立 stage 槽，它的耗时并入 round 尾巴不单列。
        static constexpr RuntimeClimateStage PASS_STAGES[8] = {
            RuntimeClimateStage::PASS_A,       RuntimeClimateStage::PASS_B,
            RuntimeClimateStage::OCEAN_WATER,  RuntimeClimateStage::OCEAN_LAND,
            RuntimeClimateStage::WIND_AIR,     RuntimeClimateStage::WIND_SURFACE,
            RuntimeClimateStage::SEA_ICE,      RuntimeClimateStage::TRANSPIRATION,
        };
        for (size_t k = 0; k < 8; ++k) {
            // 只记真的跑过的 pass。以前这里无条件按 cells 记账，于是被 mask 关掉或
            // 被 starve 掉的 pass 也会报出一份满额工作量而耗时为 0——导出到
            // performance.csv 之后，那一行看起来像"这个 stage 免费算完了 2400 个
            // cell"，恰好是最容易被当成优化成果的假象。
            if ((timing.passes_ran & (1 << k)) == 0) continue;
            const size_t slot = static_cast<size_t>(PASS_STAGES[k]);
            report.stage_ms[slot] = static_cast<double>(timing.pass_us[k]) / 1000.0;
            report.stage_work[slot] = static_cast<uint64_t>(cells);
            report.work_units += static_cast<uint64_t>(cells);
        }
        shared_round_ran = true;
    }

    // ─── 以下是 shared_passes_available == false 时的诊断近似 ─────────────
    // 它们不具备 parity 语义。共享 round 跑过时必须整段跳过，否则会把刚算出来的
    // 场重新覆盖成近似值。
    if (input.climate_round_ran && !shared_round_ran) {
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
            const float abs_lat = std::fabs(ny * 2.0f - 1.0f);
            float lat_t = (abs_lat - 0.18f) / 0.64f;
            if (lat_t < 0.0f) lat_t = 0.0f;
            else if (lat_t > 1.0f) lat_t = 1.0f;
            const float lat_w = lat_t * lat_t * (3.0f - 2.0f * lat_t);
            const float season_amp = is_water ? (0.08f + 0.50f * lat_w)
                                              : (0.12f + 0.36f * lat_w);
            const float season_term = (is_water ? season_amp : -season_amp) * deviation;
            float synoptic = 0.0f;
            if (input.cell_weather_vapor.size() == cells &&
                catalog.runtime_moisture_weather_vapor_weight > 0.0f) {
                const float vapor = climate_formula::clamp(
                    input.cell_weather_vapor[i], 0.0f, 1.0f);
                synoptic += (vapor - base_moisture * 0.15f) *
                    catalog.runtime_moisture_weather_vapor_weight;
            }
            if (input.cell_weather_precip.size() == cells &&
                catalog.runtime_moisture_precip_weight > 0.0f) {
                const float precip = climate_formula::clamp(
                    input.cell_weather_precip[i], 0.0f, 1.0f);
                synoptic += (precip - 0.04f) *
                    catalog.runtime_moisture_precip_weight * 3.5f;
            }
            const float synoptic_cap = is_water ? 0.12f : 0.28f;
            synoptic = climate_formula::clamp(synoptic, -synoptic_cap, synoptic_cap);
            float moisture_target = base_moisture + season_term + synoptic;
            if (!is_water) {
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
            }
            moisture_target = climate_formula::clamp01(moisture_target);
            float previous_moisture = read_or(input.cell_moisture, i,
                                              current.moisture[i]);
            if (!std::isfinite(previous_moisture) || previous_moisture < 0.0f ||
                previous_moisture > 1.0f) {
                previous_moisture = moisture_target;
            }
            const float moisture_alpha = climate_formula::thermal_alpha_eff(
                catalog.runtime_moisture_base_relax_rate, dt);
            const float moisture_now = climate_formula::clamp01(previous_moisture +
                (moisture_target - previous_moisture) * moisture_alpha);

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
            // 过渡三条 lane：这条诊断近似路径没有生产的 rate/dt knob，只记"从哪个
            // 类型过渡到哪个类型"，alpha 立即完成。它不具备 parity 语义（整条
            // fallback 都不具备），真正的过渡状态机在 stage 11 的共享内核里。
            if (next.weather_target_type[i] != type) {
                next.weather_prev_type[i] = current.weather_type[i];
                next.weather_target_type[i] = type;
            }
            next.weather_transition_alpha[i] = 0.0f;
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
    // 近似回退路径同样遵守 canonical 顺序：albedo → vegetation → feedback 在生产
    // 语义里是 weather 之后的 stage_b 三段，排在 weather/hydrology 之前会改变
    // 温度与植被链的读写接力。这条路径没有 parity 语义，但顺序不能与生产相反，
    // 否则 stage_sequence 契约会（正确地）拒绝它。
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
    run_stage(report, RuntimeClimateStage::STAGE_B_AFTER_HYDROLOGY, [&]() {
        for (size_t i = 0; i < cells; ++i) {
            next.moisture[i] = std::clamp(next.moisture[i] * 0.9f + next.plant_available_water[i] * 0.1f, 0.0f, 1.0f);
            if (next.temperature[i] != current.temperature[i] ||
                next.plant_available_water[i] != current.plant_available_water[i] ||
                next.weather_precipitation[i] != current.weather_precipitation[i]) ++report.changed_cells;
        }
        return static_cast<uint64_t>(cells) * 3u;
    });
    }

    // ─── stage 8 ALBEDO（共享纯内核，节拍独立于 round）────────────────────
    //
    // 生产侧 albedo 是一个仿真日内 temp 的最后一个写者：round 末尾 wind_surface /
    // finalizer 定下温度后，stage_b 再叠一层 (reference_albedo - alb) * gain。所以这里
    // 必须排在 round 之后，且只在生产当天真的跑过 albedo 时跑。
    //
    // 输入全部取自 environment 快照（is_water / vegetation / cover）与 static knobs 的
    // albedo_table —— 与生产 stage_b 从 SoA slot 读的是同一批 lane。
    // 走了上面那条近似回退时不叠 albedo：那条路径自带一份 ALBEDO 近似，再叠一次共享
    // 内核等于对同一天算两遍。回退路径本来就没有 parity 语义，保持它自洽即可。
    const bool shared_albedo_ran = input.climate_albedo.ran &&
        (shared_round_ran || !input.climate_round_ran);
    // B8-1：这里只登记执行体，不在当前位置执行。stage_b 的三段（albedo →
    // vegetation → feedback）在生产里跑在 weather / distribute / hydrology
    // 之后；真正调用点固定在下面气象段之后，顺序与 canonical 表一致。
    auto run_shared_albedo = [&]() {
        if (!shared_albedo_ran) return;
        run_stage(report, RuntimeClimateStage::ALBEDO, [&]() {
            const auto &knobs = input.climate_round_static_knobs;
            if (input.is_water.size() != cells ||
                input.vegetation.size() != cells ||
                input.cover.size() != cells ||
                knobs.albedo_table.empty()) {
                return static_cast<uint64_t>(0);
            }
            pk_async_climate::albedo_apply_pure(
                input.climate_albedo, input.is_water.data(),
                input.vegetation.data(), input.cover.data(),
                knobs.albedo_table.data(),
                static_cast<int>(knobs.albedo_table.size()),
                next.temperature.data(), static_cast<int>(cells));
            report.stage_ran_mask |= pk_async_climate::CLIMATE_STAGE_BIT_ALBEDO;
            return static_cast<uint64_t>(cells);
        });
    };

    // ─── stage 9 VEGETATION_DYNAMICS（共享纯内核，节拍独立于 round）────────
    //
    // 顺序必须夹在 albedo 与 feedback 之间：生产 stage_b 就是 ① albedo → ②
    // vegetation → ③ feedback 这个顺序，而三段之间通过 SoA 直接接力
    //（albedo 写 temp、vegetation 写 plant_available_water、feedback 读改后的场）。
    //
    // 输入 lane 的取值来源分两类，这个划分是当前 S3 进度的直接反映：
    //   - is_water / terrain / landform / vegetation / temp_30d / moisture /
    //     water_balance_30d / weather_* 取生产的记录。其中 water_balance_30d 与
    //     weather_* 的生产者（hydrology / weather）还没有共享实现，用 worker 自己
    //     那份必然分叉；而 vegetation 会被 GDScript 侧的演替后处理改写，那次写入
    //     不属于任何 climate stage，快照里也拿不到。stage 11/12 提取完成后，这几条
    //     才有资格换成 worker 自己的场。
    //   - vitality / streak / heat / drought / cold 与 plant_available_water /
    //     vegetation_growth_pressure 是 store 成员，必须读写 worker 自己那一份，
    //     否则 parity 就退化成"把生产的结果抄一遍"。
    //   - regen_score 没有 float store 成员，用 scratch 承接生产读到的初值后丢弃。
    const bool shared_vegetation_ran = vegetation_requested &&
        (shared_round_ran || !input.climate_round_ran);
    auto run_shared_vegetation = [&]() {
        if (!shared_vegetation_ran) return;
        run_stage(report, RuntimeClimateStage::VEGETATION_DYNAMICS, [&]() {
            const pk_async_climate::VegetationDynamicsInput &vd = *input.climate_vegetation;
            // B8-1：weather 段现在排在本段之前，worker 自己当天的场才是生产语义里
            // 的输入。生产记录只在 worker 当天没算出该场时兜底（跳过节拍 / 缺 lane）。
            const uint8_t *wx_type = (next.weather_type.size() == cells)
                ? next.weather_type.data() : vd.weather_type.data();
            const float *wx_intensity = (next.weather_intensity.size() == cells)
                ? next.weather_intensity.data() : vd.weather_intensity.data();
            const uint8_t *wx_field_init =
                (_weather_field_init_seeded &&
                 _weather_field_init_scratch.size() == cells)
                    ? _weather_field_init_scratch.data()
                    : vd.weather_field_init.data();
            // B8-3 E2：植被阶段读 worker 自己当天算出来的慢层，而不是 tick 起始的
            // 生产记录。本段已经排在 weather/distribute 之后（P1 重排），所以
            // next.moisture 是 distribute/hydrology 之后的当天值、
            // next.water_balance_30d 是 distribute 之后的当天值、
            // next.temperature_30d_ema 是 round pass_a 之后的当天值。
            //
            // 之前三条读 vd（生产记录）时，PAW/VGP/moisture/WB30 的量级偏差正好
            // 集中在它们身上：worker 用"别人的昨天"算自己的今天，再回灌覆盖，
            // 差值每天被重新引入。
            const float *veg_temp_30d = (next.temperature_30d_ema.size() == cells)
                ? next.temperature_30d_ema.data() : vd.temp_30d.data();
            const float *veg_moisture = (next.moisture.size() == cells)
                ? next.moisture.data() : vd.moisture.data();
            const float *veg_water_balance =
                (next.water_balance_30d.size() == cells)
                    ? next.water_balance_30d.data()
                    : vd.water_balance_30d.data();
            if (vd.is_water.size() != cells || vd.terrain.size() != cells ||
                vd.landform.size() != cells || vd.vegetation.size() != cells ||
                veg_temp_30d == nullptr || veg_moisture == nullptr ||
                veg_water_balance == nullptr ||
                wx_type == nullptr || wx_intensity == nullptr ||
                wx_field_init == nullptr ||
                next.plant_available_water.size() != cells ||
                next.vegetation_vitality.size() != cells ||
                next.vegetation_drought_streak.size() != cells ||
                next.vegetation_growth_streak.size() != cells) {
                // 与 round 的 starved 同类：输入边界不完整，不是算法分叉。
                return static_cast<uint64_t>(0);
            }
            pk_async_climate::VegetationDynamicsKnobs knobs = vd.knobs;
            pk_async_climate::VegetationDynamicsTables tables;
            tables.ideal_temp = vd.ideal_temp.data();
            tables.ideal_moist = vd.ideal_moist.data();
            tables.temp_tol = vd.temp_tol.data();
            tables.moist_tol = vd.moist_tol.data();
            tables.weather_penalty = vd.weather_penalty.data();
            tables.resistance = vd.resistance.data();
            tables.next_up = vd.next_up.data();
            tables.next_down = vd.next_down.data();

            pk_async_climate::VegetationDynamicsLanes lanes;
            lanes.is_water = vd.is_water.data();
            lanes.terrain = vd.terrain.data();
            lanes.landform = vd.landform.data();
            lanes.vegetation = vd.vegetation.data();
            lanes.temp_30d = veg_temp_30d;
            lanes.moisture = veg_moisture;
            lanes.water_balance_30d = veg_water_balance;
            lanes.soil_moisture = vd.has_soil_moisture ? vd.soil_moisture.data() : nullptr;
            lanes.weather_type = wx_type;
            lanes.weather_intensity = wx_intensity;
            lanes.weather_field_init = wx_field_init;
            lanes.plant_available_water = next.plant_available_water.data();
            lanes.vegetation_growth_pressure =
                (vd.has_growth_pressure &&
                 next.vegetation_growth_pressure.size() == cells)
                    ? next.vegetation_growth_pressure.data() : nullptr;
            lanes.vitality = next.vegetation_vitality.data();
            lanes.low_streak = next.vegetation_drought_streak.data();
            lanes.high_streak = next.vegetation_growth_streak.data();
            if (knobs.stress_enabled) {
                if (next.vegetation_heat_stress.size() != cells ||
                    next.vegetation_drought_stress.size() != cells ||
                    next.vegetation_cold_stress.size() != cells ||
                    vd.regen_score.size() != cells) {
                    return static_cast<uint64_t>(0);
                }
                lanes.heat_stress = next.vegetation_heat_stress.data();
                lanes.drought_stress = next.vegetation_drought_stress.data();
                lanes.cold_stress = next.vegetation_cold_stress.data();
                _vegetation_regen_scratch = vd.regen_score;
                lanes.regen_score = _vegetation_regen_scratch.data();
            }
            pk_async_climate::VegetationDynamicsEmit emit;
            pk_async_climate::vegetation_dynamics_apply_pure(
                knobs, tables, lanes, 0, static_cast<int>(cells), emit);
            // B8-P1：演替后处理从主线程搬进 worker。规则与
            // map_generator._apply_vegetation_succession_candidates 逐条对齐：
            //   * vegetation / base_vegetation 一起改成下一档；
            //   * 降级（next_down[prev] == next）用 degrade_reset_target，升级用 0.7；
            //   * vitality 取"当前与目标的中点"；
            //   * streak 冷却（-succession_cooldown_days）已由纯内核写入。
            // 生产侧对应的 GDScript 写入在 ACTIVE 下被抑制门关掉，worker 是唯一写者。
            if (next.vegetation.size() == cells &&
                next.base_vegetation.size() == cells) {
                for (size_t k = 0; k < emit.indices.size(); ++k) {
                    const int32_t idx = emit.indices[k];
                    if (idx < 0 || static_cast<size_t>(idx) >= cells) continue;
                    const uint8_t next_veg = emit.to_veg[k];
                    const uint8_t prev_veg = next.vegetation[static_cast<size_t>(idx)];
                    if (next_veg == prev_veg) continue;
                    const bool is_degrade =
                        static_cast<size_t>(prev_veg) < vd.next_down.size() &&
                        vd.next_down[prev_veg] == next_veg;
                    next.vegetation[static_cast<size_t>(idx)] = next_veg;
                    next.base_vegetation[static_cast<size_t>(idx)] = next_veg;
                    const float target =
                        is_degrade ? knobs.degrade_reset_target : 0.7f;
                    next.vegetation_vitality[static_cast<size_t>(idx)] =
                        (next.vegetation_vitality[static_cast<size_t>(idx)] +
                         target) * 0.5f;
                }
            }
            // B8-P1：演替本身已经在上面的 apply 里落到 worker 自己的
            // vegetation / base_vegetation lane；生产侧同一步 GDScript 后处理在
            // ACTIVE 下被抑制门关掉，worker 是唯一写者。
            report.stage_ran_mask |=
                pk_async_climate::CLIMATE_STAGE_BIT_VEGETATION_DYNAMICS;
            return static_cast<uint64_t>(cells);
        });
    };

    // ─── stage 10 CLIMATE_FEEDBACK（共享纯内核，节拍独立于 round）──────────
    //
    // 输入整份取自生产的记录，而不是 environment 快照的同名 lane：feedback 跑在
    // stage_b 段（weather 之后），快照是 tick 起始拍的，weather_type /
    // weather_intensity 在这两个时刻之间正好被 weather pass 整场重写过。
    //
    // 状态所有权分两类，不能混：
    //   base_moisture / soil_moisture — 不在 canonical parity 字段表里，worker store
    //       也没有对应成员。用 scratch 承接生产读到的初值，输出丢弃。
    //   vegetation_growth_pressure — 是 store 成员。必须读写 worker 自己那一份，
    //       否则 parity 就退化成"把生产的结果抄一遍"，什么都验不出来。
    const bool shared_feedback_ran = feedback_requested &&
        (shared_round_ran || !input.climate_round_ran);
    auto run_shared_feedback = [&]() {
        if (!shared_feedback_ran) return;
        run_stage(report, RuntimeClimateStage::CLIMATE_FEEDBACK, [&]() {
            const pk_async_climate::ClimateFeedbackInput &fb = *input.climate_feedback;
            const auto &neighbors = input.climate_round_static_knobs.neighbor_indices;
            // B8-1：与 vegetation 同一口径 —— feedback 读当天 weather 段的产物，
            // 而不是 tick 开始时的生产记录。weather_type/intensity 的 store 成员
            // 一定齐长；field_init 走 weather 段写过的 scratch。
            const uint8_t *wx_type = (next.weather_type.size() == cells)
                ? next.weather_type.data() : fb.weather_type.data();
            const float *wx_intensity = (next.weather_intensity.size() == cells)
                ? next.weather_intensity.data() : fb.weather_intensity.data();
            const uint8_t *wx_field_init =
                (_weather_field_init_seeded &&
                 _weather_field_init_scratch.size() == cells)
                    ? _weather_field_init_scratch.data()
                    : fb.weather_field_init.data();
            if (fb.is_water.size() != cells ||
                wx_type == nullptr || wx_intensity == nullptr ||
                wx_field_init == nullptr ||
                fb.temp_transport_anomaly.size() != cells ||
                fb.base_moisture.size() != cells ||
                fb.soil_moisture.size() != cells ||
                neighbors.size() < cells * 6u ||
                next.vegetation_growth_pressure.size() != cells) {
                // 与 round 的 starved 同类：输入边界不完整，不是算法分叉。
                // production_stage_mask 里有 feedback 而 stage_ran_mask 里没有，
                // 差集就会把它报出来，不会变成一次静默 no-op。
                return static_cast<uint64_t>(0);
            }
            _feedback_base_moisture = fb.base_moisture;
            _feedback_soil_moisture = fb.soil_moisture;
            pk_async_climate::climate_feedback_apply_pure(
                fb.knobs, fb.is_water.data(), wx_type,
                wx_intensity, wx_field_init,
                neighbors.data(), fb.temp_transport_anomaly.data(),
                _feedback_base_moisture.data(), _feedback_soil_moisture.data(),
                next.vegetation_growth_pressure.data(),
                0, static_cast<int>(cells));
            report.stage_ran_mask |=
                pk_async_climate::CLIMATE_STAGE_BIT_CLIMATE_FEEDBACK;
            return static_cast<uint64_t>(cells);
        });
    };

    // B8-3 单因子实验开关：把 stage_b 三段放回 weather 之前（旧顺序）。只用于
    // soak A/B 归因，默认关闭；进程级读取一次，不参与任何仿真状态，也不进存档。
    // 归因方法：同一 seed/尺寸跑 canonical vs legacy，只翻这一个变量，差值就是
    // "顺序"这一项的贡献，与"输入所有权""节拍""ψ"等其它因子分开。
    static const bool legacy_stage_order = [] {
        const char *value = std::getenv("PK_CLIMATE_STAGE_ORDER_LEGACY");
        return value != nullptr && value[0] == '1';
    }();
    if (legacy_stage_order) {
        run_shared_albedo();
        run_shared_vegetation();
        run_shared_feedback();
    }

    // ─── stage 11 WEATHER（共享纯内核，weather bucket 自己的 cadence）────────
    //
    // 状态所有权在这一段分得最细，因为 weather 是 climate 里跨 tick 状态最多的一段：
    //
    //   worker 自己那一份（store 成员，真正被对拍的量）：
    //       vapor / cloud_water / cloud_cover / weather_precipitation /
    //       weather_intensity / convergence / instability / weather_type 与过渡三条。
    //       prev_* 输入也取自 worker 的 store —— 也就是它自己昨天算出来的场。天气
    //       是强惯性系统（vapor/cloud 都带 inertia 项），所以逐日累积的偏差会被
    //       如实放大出来，这正是这一段该验的东西。
    //   生产记录那一份（worker 无从重建）：
    //       风场、温度、湿度等读 lane —— 它们的生产者（wind / pass_b）还没提取；
    //       ψ、对流抑制、气旋强迫、季风热力、回溯轨迹表 —— 都不是 store 成员，且
    //       ψ 与轨迹表都由 wind pass 派生并带指纹校验。这几组照抄生产当天用过的
    //       那一份，输出丢弃。stage 12/13 与 wind 提取完之后才有资格换成 worker 的。
    //
    // use_next_outputs 在 worker 侧一律取 false：生产 native daily 走 staged，把原始
    // 类型写进 int32 next buffer、由 commit pass 落成显示类型；worker 没有 commit
    // pass，用 direct 语义可以在同一次调用里直接得到显示类型。这个 flag 在内核里只
    // 切换"写 int32 原始类型"与"写 u8 显示类型 + field_init"，不影响任何数值。
    const bool shared_weather_ran = weather_requested &&
        (shared_round_ran || !input.climate_round_ran);
    if (shared_weather_ran) {
        run_stage(report, RuntimeClimateStage::WEATHER, [&]() {
            // SHADOW 保持捕获的参考输入；ACTIVE 的物理消费者只读本次 worker 计划。
            pk_async_climate::WeatherFieldInput owned_weather;
            if (physics_owned) {
                owned_weather = *input.climate_weather;
                owned_weather.wind_x = _physics.wind_x;
                owned_weather.wind_y = _physics.wind_y;
                owned_weather.wind_speed = _physics.wind_speed;
                owned_weather.monsoon_thermal = _physics.monsoon_thermal;
                owned_weather.temp_read = next.temperature;
                owned_weather.moisture_read = next.moisture;
                owned_weather.sea_ice = next.sea_ice;
                owned_weather.snow_cover = next.snow_cover;
                owned_weather.traj_idx.clear();
                owned_weather.traj_w.clear();
                if (input.climate_physics_knobs.wind_traj_weather_share && _physics.wind_traj_valid) {
                    owned_weather.traj_idx = _physics.wind_traj_idx;
                    owned_weather.traj_w = _physics.wind_traj_w;
                }
            }
            const pk_async_climate::WeatherFieldInput &wx = physics_owned
                ? owned_weather : *input.climate_weather;
            const auto &neighbors = physics_owned ? input.neighbor_indices
                : input.climate_round_static_knobs.neighbor_indices;
            const auto lane_ok = [cells](const std::vector<float> &v) {
                return v.size() == cells;
            };
            if (!lane_ok(wx.temp_read) || !lane_ok(wx.moisture_read) ||
                !lane_ok(wx.air_anomaly) || !lane_ok(wx.wind_x) ||
                !lane_ok(wx.wind_y) || !lane_ok(wx.wind_speed) ||
                !lane_ok(wx.elevation) || !lane_ok(wx.pos_x) ||
                !lane_ok(wx.pos_y) || !lane_ok(wx.temp_transport_anomaly) ||
                wx.terrain.size() != cells || wx.has_river.size() != cells ||
                wx.vegetation.size() != cells ||
                neighbors.size() < cells * 6u ||
                next.vapor.size() != cells || next.cloud_water.size() != cells ||
                next.cloud_cover.size() != cells ||
                next.weather_precipitation.size() != cells ||
                next.weather_intensity.size() != cells ||
                next.convergence.size() != cells ||
                next.instability.size() != cells ||
                next.weather_type.size() != cells ||
                next.weather_prev_type.size() != cells ||
                next.weather_target_type.size() != cells ||
                next.weather_transition_alpha.size() != cells) {
                // 与 round 的 starved 同类：输入边界不完整，不是算法分叉。
                // 这一段的 bit 与 distribute 共用（同属 stage 11），所以静默返回
                // 会被 distribute 的成功掩盖 —— 说一次哪条短了。
                static std::atomic<bool> wx_starved_reported{false};
                bool expected = false;
                if (wx_starved_reported.compare_exchange_strong(expected, true)) {
                    std::fprintf(stderr,
                        "[climate/worker] weather starved: temp=%zu moist=%zu air=%zu "
                        "wx=%zu wy=%zu wspd=%zu elev=%zu posx=%zu posy=%zu tta=%zu "
                        "terrain=%zu river=%zu veg=%zu nb=%zu | store vapor=%zu "
                        "cloudw=%zu cloud=%zu precip=%zu intens=%zu conv=%zu "
                        "instab=%zu type=%zu prev=%zu target=%zu alpha=%zu | cells=%zu\n",
                        wx.temp_read.size(), wx.moisture_read.size(),
                        wx.air_anomaly.size(), wx.wind_x.size(), wx.wind_y.size(),
                        wx.wind_speed.size(), wx.elevation.size(), wx.pos_x.size(),
                        wx.pos_y.size(), wx.temp_transport_anomaly.size(),
                        wx.terrain.size(), wx.has_river.size(),
                        wx.vegetation.size(), neighbors.size(),
                        next.vapor.size(), next.cloud_water.size(),
                        next.cloud_cover.size(), next.weather_precipitation.size(),
                        next.weather_intensity.size(), next.convergence.size(),
                        next.instability.size(), next.weather_type.size(),
                        next.weather_prev_type.size(),
                        next.weather_target_type.size(),
                        next.weather_transition_alpha.size(), cells);
                }
                return static_cast<uint64_t>(0);
            }
            // prev_* 必须是独立缓冲：内核会读 PREV_CNV[upstream_idx]，upstream 可能
            // 小于 i，与 OUT_CNV 共用同一块内存就会读到本轮已经改写过的值。生产
            // staged 路径用的是两块 buffer，这里跟着分开。
            _weather_prev_vapor = next.vapor;
            _weather_prev_precip = next.weather_precipitation;
            _weather_prev_cloud_water = next.cloud_water;
            _weather_prev_cloud = next.cloud_cover;
            _weather_prev_convergence = next.convergence;
            // own_field_state 决定 conv_inhib 跨天归属（见 WeatherFieldInput）。
            if (!wx.own_field_state || _weather_conv_inhib.size() != cells) {
                _weather_conv_inhib = wx.conv_inhib;
            }
            // field_init 是"这张图的天气场是否已经解算过一次"，一置 1 就长期为真。
            // 从前这里每轮 assign(cells, 0)，于是 distribute 侧读到的永远是"未初始化"
            // （它按 field_init 决定 weather_type/intensity/precip 取真值还是取 0），
            // worker 的天气输出因此成片写零。只在首次分配，之后由 commit 置位。
            const bool field_init_fresh =
                _weather_field_init_scratch.size() != cells;
            if (field_init_fresh) {
                _weather_field_init_scratch.assign(cells, 0u);
                // 换图/换尺寸后旧图的有效性不能继承；stage_b 在 weather 之后读
                // 这张 scratch，继承一个 true 会把新图当成已初始化。
                _weather_field_init_seeded = false;
            }
            // 生产生成阶段通常已经把 field_init 置 1。worker 若从全零起步会按
            // moisture*0.15 重做 spinup，vapor 因此整场偏 0.15。
            // own_field_state 下只首次播种。commit 会把解算过的格子置 1，每天拿
            // input 覆盖会把这份记忆抹掉 —— 若覆盖成全 1，下面的 spinup 就被整场
            // 跳过，prev_vapor 停在 store 的 0，水汽循环永远起不来（vapor / precip
            // 全场恒 0）；若覆盖成全 0 则每天重做 spinup，同样不是演化。
            if (wx.field_init.size() == cells &&
                (!wx.own_field_state || field_init_fresh)) {
                _weather_field_init_scratch = wx.field_init;
                _weather_field_init_seeded = true;
            }
            // commit 会写这张 scratch；即使 seed 分支没走（own_field_state 且非
            // fresh），只要它带着上一日的值就是有效状态。全零只可能是"首日还没解
            // 算过"，那不算有效状态 —— 否则 starved 的首日会让 stage_b 把已初始化
            // 的地图当成 spin-up。
            if (_weather_field_init_scratch.size() == cells &&
                !_weather_field_init_seeded) {
                for (size_t i = 0; i < cells; ++i) {
                    if (_weather_field_init_scratch[i] != 0u) {
                        _weather_field_init_seeded = true;
                        break;
                    }
                }
            }
            // 未初始化的格子不读 SoA vapor/precip —— 那份此刻还是零，而生产按稳态
            // 量级 moisture * WEATHER_SPINUP_VAPOR_FRACTION 起步（field_solver.gd 的
            // 首帧暴雨修复：prev_vapor=moisture 会让首 tick 处处过饱和）。少了这一步，
            // worker 首轮的 prev_vapor 就整场低 0.15，而天气是强惯性系统，这个偏差
            // 会一路带到 cloud / instability / precipitation。
            if (wx.moisture_read.size() == cells) {
                constexpr float WEATHER_SPINUP_VAPOR_FRACTION = 0.15f;
                for (size_t i = 0; i < cells; ++i) {
                    if (_weather_field_init_scratch[i] > 0) continue;
                    _weather_prev_vapor[i] =
                        wx.moisture_read[i] * WEATHER_SPINUP_VAPOR_FRACTION;
                    _weather_prev_precip[i] = 0.0f;
                }
            }
            // staged next buffer：生产 native daily 的 weather_advance 把结果写进
            // 调用方给的 next buffer（weather_type 走 int32），再由 weather_commit
            // 落到 slot 并解析 display/transition/field_init。worker 必须走同一分支，
            // 否则两边在同一 stage 上跑同一内核的不同分支。
            auto ensure_f32 = [cells](std::vector<float> &v) {
                if (v.size() != cells) v.assign(cells, 0.0f);
            };
            ensure_f32(_wx_next_vapor);
            ensure_f32(_wx_next_cloud);
            ensure_f32(_wx_next_cloud_water);
            ensure_f32(_wx_next_precip);
            ensure_f32(_wx_next_instability);
            ensure_f32(_wx_next_intensity);
            ensure_f32(_wx_next_convergence);
            if (_wx_next_type.size() != cells) _wx_next_type.assign(cells, 0);
            if (_weather_dirty_scratch.size() != cells) {
                _weather_dirty_scratch.assign(cells, 0u);
            }

            pk_async_climate::WeatherFieldKnobs knobs = wx.knobs;
            knobs.use_next_outputs = true;

            pk_async_climate::WeatherFieldLanes lanes;
            lanes.temp_read = wx.temp_read.data();
            lanes.moisture_read = wx.moisture_read.data();
            lanes.air_anomaly = wx.air_anomaly.data();
            lanes.wind_x = wx.wind_x.data();
            lanes.wind_y = wx.wind_y.data();
            lanes.wind_speed = wx.wind_speed.data();
            lanes.terrain = wx.terrain.data();
            lanes.has_river = wx.has_river.data();
            lanes.river_q30 = lane_ok(wx.river_q30) ? wx.river_q30.data() : nullptr;
            lanes.elevation = wx.elevation.data();
            lanes.vegetation = wx.vegetation.data();
            lanes.soil_moisture =
                lane_ok(wx.soil_moisture) ? wx.soil_moisture.data() : nullptr;
            lanes.vitality = lane_ok(wx.vitality) ? wx.vitality.data() : nullptr;
            lanes.sea_ice = lane_ok(wx.sea_ice) ? wx.sea_ice.data() : nullptr;
            lanes.pos_x = wx.pos_x.data();
            lanes.pos_y = wx.pos_y.data();
            lanes.temp_anomaly =
                lane_ok(wx.temp_anomaly) ? wx.temp_anomaly.data() : nullptr;
            lanes.snow_cover =
                lane_ok(wx.snow_cover) ? wx.snow_cover.data() : nullptr;
            lanes.neighbor_indices = neighbors.data();
            lanes.temp_transport_anomaly = wx.temp_transport_anomaly.data();
            lanes.prev_vapor = _weather_prev_vapor.data();
            lanes.prev_precip = _weather_prev_precip.data();
            lanes.prev_cloud_water = _weather_prev_cloud_water.data();
            lanes.prev_cloud = _weather_prev_cloud.data();
            lanes.prev_convergence = _weather_prev_convergence.data();
            // staged 分支：写 next buffer，类型走 int32；transition 三条与
            // field_init 在这一步是 nullptr（与生产 world_ext_weather.cpp:698-705
            // 的 use_next_outputs=true 分支一致），由随后的 commit 解析。
            lanes.out_vapor = _wx_next_vapor.data();
            lanes.out_cloud = _wx_next_cloud.data();
            lanes.out_cloud_water = _wx_next_cloud_water.data();
            lanes.out_precip = _wx_next_precip.data();
            lanes.out_instability = _wx_next_instability.data();
            lanes.out_intensity = _wx_next_intensity.data();
            lanes.out_convergence = _wx_next_convergence.data();
            lanes.out_type_i32 = _wx_next_type.data();
            lanes.out_type_u8 = nullptr;
            lanes.out_prev_type = nullptr;
            lanes.out_target_type = nullptr;
            lanes.out_alpha = nullptr;
            lanes.out_field_init = nullptr;

            pk_async_climate::WeatherFieldState state;
            state.conv_inhib =
                _weather_conv_inhib.size() == cells ? _weather_conv_inhib.data() : nullptr;
            // B8-2：worker 自持 cyclone —— 在生产同一位置、同一顺序（field solve 之前）
            // 推进已有条目并 stamp 当天的强迫 lane。PK_CLIMATE_CYCLONE_FORCE=1 用于
            // 特性默认关闭时的验证；生产配置走 capture 的 native_tropical_cyclone_enabled。
            static const bool cyclone_force_enabled = [] {
                const char *value = std::getenv("PK_CLIMATE_CYCLONE_FORCE");
                return value != nullptr && value[0] == '1';
            }();
            const bool cyclone_enabled_for_day =
                input.cyclone_enabled || cyclone_force_enabled;
            static std::atomic<int> s_cyc_gate_debug{2};
            if (s_cyc_gate_debug.fetch_sub(1, std::memory_order_relaxed) > 0) {
                std::fprintf(stderr,
                    "[climate/worker][b8] cyclone_gate day=%lld input_enabled=%d "
                    "force_env=%d effective=%d\n",
                    static_cast<long long>(day),
                    input.cyclone_enabled ? 1 : 0, cyclone_force_enabled ? 1 : 0,
                    cyclone_enabled_for_day ? 1 : 0);
                std::fflush(stderr);
            }
            bool cyclone_lanes_ready = physics_cyclone_stamp_ready;
            if (cyclone_enabled_for_day && input.climate_worker_authoritative && !physics_owned) {
                if (_cyclone_force_tag.size() != cells) {
                    _cyclone_force_tag.assign(cells, 0u);
                    _cyclone_visit_tag.assign(cells, 0u);
                    _cyclone_force_x.assign(cells, 0.0f);
                    _cyclone_force_y.assign(cells, 0.0f);
                    _cyclone_lift.assign(cells, 0.0f);
                    _cyclone_force_generation = 1u;
                }
                if (++_cyclone_force_generation == 0u) {
                    std::fill(_cyclone_force_tag.begin(),
                              _cyclone_force_tag.end(), 0u);
                    std::fill(_cyclone_visit_tag.begin(),
                              _cyclone_visit_tag.end(), 0u);
                    _cyclone_force_generation = 1u;
                }
                if (wx.pos_x.size() == cells && wx.pos_y.size() == cells &&
                    wx.wind_x.size() == cells && wx.wind_y.size() == cells &&
                    wx.wind_speed.size() == cells && wx.temp_read.size() == cells &&
                    wx.terrain.size() == cells && neighbors.size() >= cells * 6u &&
                    next.vapor.size() == cells && next.instability.size() == cells &&
                    next.convergence.size() == cells) {
                    pk_async_climate::CycloneAdvanceKnobs cyc;
                    cyc.enabled = true;
                    cyc.dt_days = input.cyclone_dt_days;
                    cyc.world_bounds_pos_y = input.cyclone_world_bounds_pos_y;
                    cyc.world_bounds_size_y = input.cyclone_world_bounds_size_y;
                    cyc.wrap_width_x = input.cyclone_wrap_width_x;
                    cyc.max_radius_cells = input.cyclone_max_radius_cells;
                    pk_async_climate::CycloneLanes cyc_lanes;
                    cyc_lanes.neighbors = neighbors.data();
                    cyc_lanes.pos_x = wx.pos_x.data();
                    cyc_lanes.pos_y = wx.pos_y.data();
                    cyc_lanes.terrain = wx.terrain.data();
                    cyc_lanes.temp = wx.temp_read.data();
                    cyc_lanes.wind_x = wx.wind_x.data();
                    cyc_lanes.wind_y = wx.wind_y.data();
                    cyc_lanes.wind_speed = wx.wind_speed.data();
                    // 与生产同源：生产在 solve 循环之前解引用的是 slot 里"上一轮"的
                    // vapor / instability / convergence，worker 侧对应 next.*（本段
                    // 尚未被本次 solve 覆盖）。
                    cyc_lanes.vapor = next.vapor.data();
                    cyc_lanes.instability = next.instability.data();
                    cyc_lanes.convergence = next.convergence.data();
                    cyc_lanes.lat_norm = input.cell_lat_norm.size() == cells
                        ? input.cell_lat_norm.data() : nullptr;
                    pk_async_climate::CycloneStamp cyc_stamp;
                    cyc_stamp.force_tag = _cyclone_force_tag.data();
                    cyc_stamp.visit_tag = _cyclone_visit_tag.data();
                    cyc_stamp.force_x = _cyclone_force_x.data();
                    cyc_stamp.force_y = _cyclone_force_y.data();
                    cyc_stamp.lift = _cyclone_lift.data();
                    cyc_stamp.force_generation = _cyclone_force_generation;
                    cyc_stamp.visit_generation = _cyclone_force_generation;
                    pk_async_climate::CycloneStats cyc_stats;
                    pk_async_climate::cyclone_advance_and_stamp_pure(
                        static_cast<int>(cells), cyc, cyc_lanes,
                        _cyclone_entries, cyc_stamp, cyc_stats);
                    cyclone_lanes_ready = true;
                    report.cyclone_alive = cyc_stats.alive;
                    _physics.cyclone_total_decayed +=
                        static_cast<uint64_t>(std::max(0, cyc_stats.decayed));
                    report.cyclone_decayed =
                        static_cast<int32_t>(_physics.cyclone_total_decayed);
                    report.cyclone_touched = cyc_stats.touched_cells;
                    static std::atomic<int> s_cyclone_reports_left{24};
                    if (s_cyclone_reports_left.fetch_sub(
                            1, std::memory_order_relaxed) > 0) {
                        std::fprintf(stderr,
                            "[climate/worker][b8] cyclone day=%lld cells=%zu "
                            "entries=%zu alive=%d decayed=%d touched=%d gen=%u "
                            "int(before/after)=%.3f/%.3f\n",
                            static_cast<long long>(day), cells,
                            _cyclone_entries.size(), cyc_stats.alive,
                            cyc_stats.decayed, cyc_stats.touched_cells,
                            _cyclone_force_generation,
                            static_cast<double>(cyc_stats.entry_intensity_max_before),
                            static_cast<double>(cyc_stats.entry_intensity_max_after));
                        std::fflush(stderr);
                    }
                }
            }
            // B8-2：worker 自持 ψ。生产这次只提供冷启动种子；推进会覆盖它，所以
            // 一旦播种成功就只喂 worker 自己那份。SHADOW 保持与参考同源（用捕获的
            // 生产 tick），ACTIVE 用自己的单调 tick。
            // PK_CLIMATE_SYNOPTIC_OFF=1 复现 B8 之前的"无 ψ"路径，只用于 E6 归因
            // A/B（ψ 对降水/云量/水汽的贡献），不参与生产配置。
            static const bool synoptic_disabled = [] {
                const char *value = std::getenv("PK_CLIMATE_SYNOPTIC_OFF");
                return value != nullptr && value[0] == '1';
            }();
            bool worker_psi_ready = physics_owned && _physics.synoptic_seeded && wx.synoptic_enabled && !synoptic_disabled;
            if (!physics_owned && wx.synoptic_enabled && !synoptic_disabled) {
                if (_physics.synoptic_psi.size() != cells) {
                    _physics.synoptic_psi.assign(cells, 0.0f);
                    _physics.synoptic_psi_prev.assign(cells, 0.0f);
                    _physics.synoptic_seeded = false;
                }
                if (!_physics.synoptic_seeded && wx.psi.size() == cells) {
                    _physics.synoptic_psi = wx.psi;
                    if (wx.psi_prev.size() == cells) {
                        _physics.synoptic_psi_prev = wx.psi_prev;
                    }
                    _physics.synoptic_seeded = true;
                }
                if (!_physics.synoptic_seeded && input.climate_worker_authoritative) {
                    // ACTIVE 下主线程 weather 被抑制门关掉，`_wx_synoptic` 可能永远
                    // 不被构建（cap 里就是空 lane）。这时 worker 必须从零场冷启动
                    // 自持推进；否则 `_physics.synoptic_seeded` 永远为假，ψ 一天都不参与，
                    // 降水就少掉 syn_base_lift 这条最强驱动。
                    _physics.synoptic_seeded = true;
                }
                // SHADOW 只做忠实复刻：直接用生产当天 solve 读到的 ψ，不自己推进。
                // 自己的推进节拍与生产的内联推进不会逐位相同（tick 不同），在
                // SHADOW 里推一份只会把"节拍差"记成算法分叉。自持从 ACTIVE 开始。
                if (input.climate_worker_authoritative && _physics.synoptic_seeded &&
                    wx.wind_x.size() == cells &&
                    wx.wind_y.size() == cells &&
                    wx.temp_read.size() == cells &&
                    wx.pos_x.size() == cells && wx.pos_y.size() == cells &&
                    neighbors.size() >= cells * 6u) {
                    pk_async_climate::SynopticAdvanceKnobs syn = wx.synoptic;
                    syn.tick = static_cast<int>(++_physics.synoptic_tick);
                    pk_async_climate::synoptic_advance_pure(
                        static_cast<int>(cells), neighbors.data(),
                        wx.pos_x.data(), wx.pos_y.data(), wx.wind_x.data(),
                        wx.wind_y.data(), wx.temp_read.data(), syn,
                        _physics.synoptic_psi, _physics.synoptic_psi_prev);
                    worker_psi_ready = true;
                } else if (input.climate_worker_authoritative && _physics.synoptic_seeded) {
                    // 风/温度 lane 缺失时不能推进，但已播种的 ψ 仍比 nullptr 好：
                    // 内核走无 ψ 分支会直接丢掉 syn_base_lift 这条最强降水驱动。
                    worker_psi_ready = true;
                }
            }
            if (worker_psi_ready) {
                state.psi = _physics.synoptic_psi.data();
            } else {
                state.psi = (wx.synoptic_enabled && !synoptic_disabled &&
                             wx.psi.size() == cells)
                    ? wx.psi.data() : nullptr;
            }
            if (cyclone_lanes_ready) {
                // B8-2：worker 自持 cyclone 的 stamp 结果优先。生产条目表只在冷启动
                // 播种时读过一次；之后这几条 lane 完全由 worker 推进。
                state.cyclone_tag = _cyclone_force_tag.data();
                state.cyclone_tag_count = static_cast<int>(cells);
                state.cyclone_generation = _cyclone_force_generation;
                state.cyclone_lift = _cyclone_lift.data();
                state.cyclone_x = _cyclone_force_x.data();
                state.cyclone_y = _cyclone_force_y.data();
            } else if (wx.cyclone_tag.size() == cells) {
                state.cyclone_tag = wx.cyclone_tag.data();
                state.cyclone_tag_count = static_cast<int>(cells);
                state.cyclone_generation = wx.cyclone_generation;
                state.cyclone_lift =
                    lane_ok(wx.cyclone_lift) ? wx.cyclone_lift.data() : nullptr;
                state.cyclone_x = lane_ok(wx.cyclone_x) ? wx.cyclone_x.data() : nullptr;
                state.cyclone_y = lane_ok(wx.cyclone_y) ? wx.cyclone_y.data() : nullptr;
            }
            if (lane_ok(wx.monsoon_thermal)) {
                state.monsoon_thermal = wx.monsoon_thermal.data();
                state.monsoon_thermal_count = static_cast<int>(cells);
            }
            if (wx.traj_idx.size() == cells * 3u && wx.traj_w.size() == cells * 3u) {
                state.traj_idx = wx.traj_idx.data();
                state.traj_w = wx.traj_w.data();
            }
            // 几何缓存由 worker 自己按 pos + wrap 重建：内核里缓存命中与 _xy 现算
            // 是同序同式，bit-equal，所以这块纯粹是省时间。
            const size_t geom_n = cells * 6u;
            if (_weather_geom_dx.size() != geom_n) {
                _weather_geom_dx.assign(geom_n, 0.0f);
                _weather_geom_dy.assign(geom_n, 0.0f);
                _weather_geom_invd.assign(geom_n, 0.0f);
            }
            pk_async_climate::weather_field_geometry_cache_pure(
                static_cast<int>(cells), neighbors.data(), wx.pos_x.data(),
                wx.pos_y.data(), knobs.weather_wrap_width_x,
                _weather_geom_dx.data(), _weather_geom_dy.data(),
                _weather_geom_invd.data());
            state.geom_dx = _weather_geom_dx.data();
            state.geom_dy = _weather_geom_dy.data();
            state.geom_invd = _weather_geom_invd.data();

            pk_async_climate::weather_field_solve_pure(
                knobs, lanes, state, 0, static_cast<int>(cells));

            // weather_commit：把 next buffer 落到 store，并解析 display_type /
            // transition 三条 / field_init。生产 native daily 的 weather_commit 节点
            // 做的就是这件事，走的是同一份 weather_commit_pure。
            pk_async_climate::WeatherCommitKnobs ck;
            ck.n_cells                    = static_cast<int>(cells);
            ck.refresh_convergence        = false;   // 不需要 delta 报告
            ck.weather_transition_enabled = wx.knobs.weather_transition_enabled;
            ck.transition_rate            = wx.knobs.weather_transition_alpha_rate;
            ck.transition_dt_days         = wx.knobs.weather_transition_dt_days;
            ck.lut_slots                  = 0;

            pk_async_climate::WeatherCommitLanes cl;
            cl.next_vapor        = _wx_next_vapor.data();
            cl.next_cloud        = _wx_next_cloud.data();
            cl.next_cloud_water  = _wx_next_cloud_water.data();
            cl.next_precip       = _wx_next_precip.data();
            cl.next_instability  = _wx_next_instability.data();
            cl.next_intensity    = _wx_next_intensity.data();
            cl.next_convergence  = _wx_next_convergence.data();
            cl.next_type         = _wx_next_type.data();
            cl.prev_vapor        = _weather_prev_vapor.data();
            cl.neighbor_indices  = neighbors.data();
            cl.intensity         = next.weather_intensity.data();
            cl.cloud             = next.cloud_cover.data();
            cl.cloud_water       = next.cloud_water.data();
            cl.precip            = next.weather_precipitation.data();
            cl.vapor             = next.vapor.data();
            cl.convergence       = next.convergence.data();
            cl.instability       = next.instability.data();
            cl.type              = next.weather_type.data();
            cl.prev_type         = next.weather_prev_type.data();
            cl.target_type       = next.weather_target_type.data();
            cl.transition_alpha  = next.weather_transition_alpha.data();
            cl.field_init        = _weather_field_init_scratch.data();
            cl.dirty             = _weather_dirty_scratch.data();
            cl.lut               = nullptr;
            cl.convergence_deltas = nullptr;

            pk_async_climate::WeatherCommitStats cs;
            pk_async_climate::weather_commit_pure(ck, cl, cs);

            // B8-2 genesis（出生）：与生产 native-entity 路径同一位置（field solve /
            // commit / distribute 之后的当天后段），但判据改用 worker 自己的状态：
            // 前沿等价物 = 当天 weather_type == STORM 且 intensity 过门的格子。
            // 只在 ACTIVE 下注入：SHADOW 必须保持"复刻生产前沿路径"，否则对拍会
            // 把两套 genesis 规则的差记录成算法分叉。
            if (input.climate_worker_authoritative && cyclone_enabled_for_day &&
                input.cyclone_storm_type_id >= 0 &&
                next.weather_type.size() == cells &&
                next.weather_intensity.size() == cells &&
                next.weather_precipitation.size() == cells &&
                next.cloud_cover.size() == cells &&
                next.instability.size() == cells &&
                next.convergence.size() == cells &&
                next.temperature.size() == cells) {
                const auto &water_ids =
                    input.climate_round_static_knobs.water_terrain_ids;
                if (water_ids.size() > 0u && wx.terrain.size() == cells &&
                    wx.pos_y.size() == cells && wx.wind_x.size() == cells &&
                    wx.wind_y.size() == cells &&
                    neighbors.size() >= cells * 6u) {
                    uint8_t water_lut[256] = {};
                    for (size_t k = 0; k < water_ids.size(); ++k) {
                        const uint8_t wid = water_ids[k];
                        water_lut[wid] = 1u;
                    }
                    pk_async_climate::CycloneGenesisKnobs gen;
                    gen.enabled = true;
                    gen.storm_type_id = input.cyclone_storm_type_id;
                    gen.capacity = input.cyclone_capacity;
                    gen.births_per_commit = input.cyclone_births_per_commit;
                    gen.min_temp = input.cyclone_min_temp;
                    gen.min_instability = input.cyclone_min_instability;
                    gen.max_shear = input.cyclone_max_shear;
                    gen.min_lat = input.cyclone_min_lat;
                    gen.max_lat = input.cyclone_max_lat;
                    gen.world_bounds_pos_y = input.cyclone_world_bounds_pos_y;
                    gen.world_bounds_size_y = input.cyclone_world_bounds_size_y;
                    gen.wake_days = input.cyclone_wake_days;
                    // 出生强度门 = 生产 native-entity 路径的硬编码 0.8（front
                    // intensity 就是 cluster 内最大 cell intensity，与之同源）。
                    // PK_CLIMATE_CYCLONE_GENESIS_GATE 只用于验证/归因 A/B：默认
                    // 世界里热带水格年峰值 ≈0.76，正好压在 0.8 之下，gate 不降就
                    // 拿不到"出生→推进→stamp→回灌→持久化"这条链路的实证。
                    static const float genesis_gate_override = [] {
                        const char *value =
                            std::getenv("PK_CLIMATE_CYCLONE_GENESIS_GATE");
                        return value != nullptr ? std::strtof(value, nullptr) : 0.0f;
                    }();
                    if (genesis_gate_override > 0.0f && genesis_gate_override < 1.0f) {
                        gen.intensity_gate = genesis_gate_override;
                    }
                    pk_async_climate::CycloneGenesisLanes gen_lanes;
                    gen_lanes.terrain = wx.terrain.data();
                    gen_lanes.water_lut = water_lut;
                    gen_lanes.weather_type = next.weather_type.data();
                    gen_lanes.weather_intensity = next.weather_intensity.data();
                    gen_lanes.temp = next.temperature.data();
                    gen_lanes.precip = next.weather_precipitation.data();
                    gen_lanes.cloud = next.cloud_cover.data();
                    gen_lanes.instability = next.instability.data();
                    gen_lanes.convergence = next.convergence.data();
                    gen_lanes.wind_x = wx.wind_x.data();
                    gen_lanes.wind_y = wx.wind_y.data();
                    gen_lanes.pos_y = wx.pos_y.data();
                    gen_lanes.lat_norm = input.cell_lat_norm.size() == cells
                        ? input.cell_lat_norm.data() : nullptr;
                    gen_lanes.neighbors = neighbors.data();
                    gen_lanes.is_water = input.is_water.size() == cells
                        ? input.is_water.data() : nullptr;
                    pk_async_climate::CycloneGenesisStats gen_stats;
                    pk_async_climate::cyclone_genesis_pure(
                        static_cast<int>(cells), gen, gen_lanes,
                        _cyclone_entries, _cyclone_next_stable_id, gen_stats);
                    // 纬度漏斗诊断：genesis 全部堵在 lat 闸时，必须能区分「世界
                    // 边界没送到」与「候选确实都在带外」。lat_norm 存在时应走
                    // 规范纬度（赤道=0.5），打印两次即封顶。
                    static std::atomic<int> s_cyclone_lat_reports_left{2};
                    if (s_cyclone_lat_reports_left.fetch_sub(
                            1, std::memory_order_relaxed) > 0) {
                        float ny_min = 1e30f, ny_max = -1e30f;
                        float lat_min = 1e30f, lat_max = -1e30f;
                        const float wb_h = std::max(0.001f, gen.world_bounds_size_y);
                        for (size_t i = 0; i < cells; ++i) {
                            if (water_lut[wx.terrain[i]] == 0u) continue;
                            const float ny = dc_clampf(
                                (wx.pos_y[i] - gen.world_bounds_pos_y) / wb_h,
                                0.0f, 1.0f);
                            ny_min = std::min(ny_min, ny);
                            ny_max = std::max(ny_max, ny);
                            const float abs_lat = gen_lanes.lat_norm != nullptr
                                ? std::abs((dc_clampf(gen_lanes.lat_norm[i], 0.0f, 1.0f) -
                                            0.5f) * 2.0f)
                                : std::abs((ny - 0.5f) * 2.0f);
                            lat_min = std::min(lat_min, abs_lat);
                            lat_max = std::max(lat_max, abs_lat);
                        }
                        std::fprintf(stderr,
                            "[climate/worker][b8] cyclone_lat day=%lld wb_y=%.3f "
                            "wb_h=%.3f water_ny=[%.3f,%.3f] abs_lat=[%.3f,%.3f] "
                            "lat_norm=%d band=[%.3f,%.3f]\n",
                            static_cast<long long>(day),
                            static_cast<double>(gen.world_bounds_pos_y),
                            static_cast<double>(gen.world_bounds_size_y),
                            static_cast<double>(ny_min), static_cast<double>(ny_max),
                            static_cast<double>(lat_min), static_cast<double>(lat_max),
                            gen_lanes.lat_norm != nullptr ? 1 : 0,
                            static_cast<double>(gen.min_lat),
                            static_cast<double>(gen.max_lat));
                        std::fflush(stderr);
                    }
                    if (gen_stats.injected > 0 || gen_stats.replaced > 0) {
                        _cyclone_seeded = true;
                    }
                    _physics.cyclone_total_injected +=
                        static_cast<uint64_t>(std::max(0, gen_stats.injected));
                    _physics.cyclone_total_replaced +=
                        static_cast<uint64_t>(std::max(0, gen_stats.replaced));
                    report.cyclone_injected =
                        static_cast<int32_t>(_physics.cyclone_total_injected);
                    report.cyclone_replaced =
                        static_cast<int32_t>(_physics.cyclone_total_replaced);
                    report.cyclone_alive = gen_stats.alive;
                    static std::atomic<int> s_cyclone_genesis_reports_left{24};
                    if (s_cyclone_genesis_reports_left.fetch_sub(
                            1, std::memory_order_relaxed) > 0) {
                        std::fprintf(stderr,
                            "[climate/worker][b8] cyclone_genesis day=%lld "
                            "injected=%d replaced=%d alive=%d "
                            "water=%d lat=%d phys=%d inten=%d shear=%d "
                            "storm_type=%d fail(t/p/c/i)=%d/%d/%d/%d "
                            "max(p/c/i/conv)=%.3f/%.3f/%.3f/%.3f "
                            "max_int=%.3f\n",
                            static_cast<long long>(day), gen_stats.injected,
                            gen_stats.replaced, gen_stats.alive,
                            gen_stats.cand_water, gen_stats.cand_lat,
                            gen_stats.cand_physical, gen_stats.cand_intensity,
                            gen_stats.cand_shear,
                            gen_stats.type_storm,
                            gen_stats.fail_temp, gen_stats.fail_precip,
                            gen_stats.fail_cloud, gen_stats.fail_instability,
                            static_cast<double>(gen_stats.max_precip),
                            static_cast<double>(gen_stats.max_cloud),
                            static_cast<double>(gen_stats.max_instability),
                            static_cast<double>(gen_stats.max_convergence),
                            static_cast<double>(gen_stats.max_intensity));
                        std::fflush(stderr);
                    }
                }
            }
            report.stage_ran_mask |= pk_async_climate::CLIMATE_STAGE_BIT_WEATHER;
            // B8 诊断：确认 weather field solve 真的产出非零场。headless soak 里
            // 如果这一行全零，问题在输入 lane 或 solve 资格，而不是 writeback。
            static std::atomic<int> s_weather_solve_reports_left{4};
            if (s_weather_solve_reports_left.fetch_sub(1, std::memory_order_relaxed) > 0) {
                std::fprintf(stderr,
                    "[climate/worker][b8] weather_solve day=%lld cells=%zu psi=%d "
                    "vapor0=%.6g precip0=%.6g cloud0=%.6g type0=%u field_init0=%u\n",
                    static_cast<long long>(day), cells,
                    state.psi != nullptr ? 1 : 0,
                    next.vapor.empty() ? 0.0f : next.vapor[0],
                    next.weather_precipitation.empty() ? 0.0f : next.weather_precipitation[0],
                    next.cloud_cover.empty() ? 0.0f : next.cloud_cover[0],
                    next.weather_type.empty() ? 0u : next.weather_type[0],
                    _weather_field_init_scratch.empty() ? 0u : _weather_field_init_scratch[0]);
                std::fflush(stderr);
            }
            return static_cast<uint64_t>(cells) * 6u;
        });
    }

    // ─── stage 11 后段 weather distribute（共享纯内核）────────────────────────
    //
    // 必须排在 field solve 之后、hydrology 之前：生产 native daily 的节点序是
    // weather_field → weather_commit → weather_distribute → … → runtime_hydrology，
    // 而 distribute 读 field solve 写出的 weather_type / intensity / precip，又写
    // hydrology 要读的 snowpack。
    //
    //   worker 自己那一份：temperature / moisture / snow_cover / snowpack /
    //       water_balance_30d。前两条是 distribute 之后仍会被 stage_b 改的量，后三条
    //       就是这一段的产物 —— snow_cover 尤其关键，sea_ice 与 albedo 都读它。
    //   生产记录那一份：weather_* 四条读 lane 取 worker 自己 store（field solve 刚
    //       写的），heat / elevation / landform / terrain 取记录；cover 与两条积雪
    //       计数、soil_moisture 没有 store 成员，用 scratch 承接初值后丢弃。
    const bool shared_distribute_ran = distribute_requested &&
        (shared_round_ran || !input.climate_round_ran);
    if (shared_distribute_ran) {
        run_stage(report, RuntimeClimateStage::WEATHER, [&]() {
            const pk_async_climate::WeatherDistributeInput &wd =
                *input.climate_weather_distribute;
            if (wd.heat.size() != cells || wd.elevation.size() != cells ||
                wd.landform.size() != cells || wd.terrain.size() != cells ||
                wd.weather_intensity.size() != cells ||
                wd.weather_precip.size() != cells ||
                wd.weather_type.size() != cells ||
                wd.weather_field_init.size() != cells ||
                wd.cover.size() != cells || wd.soil_moisture.size() != cells ||
                wd.accumulated_snow_days.size() != cells ||
                wd.pre_snow_cover.size() != cells ||
                next.temperature.size() != cells || next.moisture.size() != cells ||
                next.snow_cover.size() != cells || next.snowpack.size() != cells ||
                next.water_balance_30d.size() != cells) {
                return static_cast<uint64_t>(0);
            }
            // ABI 8：cover 由 worker 自持；已播种时用 store，否则跟生产冷启动。
            if (next.cover.size() == cells) {
                _distribute_cover_scratch = next.cover;
            } else {
                _distribute_cover_scratch = wd.cover;
            }
            _distribute_soil_scratch = wd.soil_moisture;
            // 两条积雪计数：own_snow_state 决定跨天由谁持有（见
            // WeatherDistributeInput 那里的说明）。SHADOW 每天跟生产播种以便对拍
            // 同一条状态链；ACTIVE 只在首次（或换图）建立初值，之后 worker 自持
            // —— 否则会一直拿生产那份不再推进的缓存重置，snow_accum_days_req
            // 永远攒不满，snow_cover 于是恒为 0。
            const bool seed_snow_state = !wd.own_snow_state ||
                _distribute_acc_snow_scratch.size() != cells ||
                _distribute_pre_cover_scratch.size() != cells;
            if (seed_snow_state) {
                _distribute_acc_snow_scratch = wd.accumulated_snow_days;
                _distribute_pre_cover_scratch = wd.pre_snow_cover;
            }

            pk_async_climate::WeatherDistributeLanes lanes;
            lanes.temp = next.temperature.data();
            lanes.moisture = next.moisture.data();
            lanes.snow_cover = next.snow_cover.data();
            lanes.snowpack = next.snowpack.data();
            lanes.water_balance_30d = next.water_balance_30d.data();
            lanes.soil_moisture = _distribute_soil_scratch.data();
            lanes.cover = _distribute_cover_scratch.data();
            lanes.heat = wd.heat.data();
            lanes.elevation = wd.elevation.data();
            lanes.landform = wd.landform.data();
            lanes.terrain = next.terrain.size() == cells
                ? next.terrain.data() : wd.terrain.data();
            // 这四条走 worker 自己的 store：field solve 刚刚写过它们，拿生产的记录
            // 等于把 field solve 的对拍结果绕过去，那一段就白验了。
            // weather_field_init 没有 store 成员，而 field solve 在 worker 侧总是走
            // direct 语义（一定写 field_init=1），所以直接给全 1。
            lanes.weather_intensity = next.weather_intensity.data();
            lanes.weather_precip = next.weather_precipitation.data();
            lanes.weather_type = next.weather_type.data();
            if (_distribute_field_init_scratch.size() != cells) {
                _distribute_field_init_scratch.assign(cells, 1u);
            }
            lanes.weather_field_init = _distribute_field_init_scratch.data();

            pk_async_climate::WeatherDistributeState state;
            state.accumulated_snow_days = _distribute_acc_snow_scratch.data();
            state.pre_snow_cover = _distribute_pre_cover_scratch.data();

            pk_async_climate::WeatherDistributeEmit emit;
            pk_async_climate::weather_distribute_pure(wd.knobs, lanes, state, emit);
            // ABI 8：distribute 就地改 cover scratch，写回 worker store 供 writeback。
            if (_distribute_cover_scratch.size() == cells &&
                next.cover.size() == cells) {
                std::memcpy(next.cover.data(), _distribute_cover_scratch.data(),
                            cells);
            }
            report.stage_ran_mask |= pk_async_climate::CLIMATE_STAGE_BIT_WEATHER;
            return static_cast<uint64_t>(cells) * 8u;
        });
    }

    // ─── stage 12 RUNTIME_HYDROLOGY（共享纯内核，runtime_hydrology_stride）──────
    //
    // 这一段的状态几乎全是 store 成员，所以它是目前 parity 信号最强的一段：
    //
    //   worker 自己那一份（被对拍的量）：moisture / plant_available_water /
    //       water_balance_30d / runoff / groundwater / river_storage /
    //       river_discharge / riparian_moisture，以及 soil_moisture 与
    //       river_discharge_30d、canal_water 这三条 scratch。前八条都是逐日累积的
    //       水量账，一天算错就再也回不来，所以这里不能拿生产的初值播种。
    //   生产记录那一份：降水 / 天气类型 / 温度 / 热输入 / 积雪 / 植被活力 / 运河
    //       掩码等读 lane —— 它们的生产者（weather distribute / pass_b / 演替）还没
    //       提取，或者根本不是 climate stage。
    //
    // hydro_parent 直接取 environment 快照那份：它只在地图生成/regen 时重建，快照
    // 本来就带着它，再往 HydrologyInput 里抄一遍纯属每天多拷一张全图 int32。
    const bool shared_hydrology_ran = hydrology_requested &&
        (shared_round_ran || !input.climate_round_ran);
    if (shared_hydrology_ran) {
        run_stage(report, RuntimeClimateStage::RUNTIME_HYDROLOGY, [&]() {
            const pk_async_climate::HydrologyInput &hy = *input.climate_hydrology;
            const auto &neighbors = input.climate_round_static_knobs.neighbor_indices;
            if (hy.has_river.size() != cells || hy.terrain.size() != cells ||
                hy.landform.size() != cells || hy.vegetation.size() != cells ||
                hy.cover.size() != cells || hy.elevation.size() != cells ||
                hy.precip.size() != cells || hy.intensity.size() != cells ||
                hy.weather_type.size() != cells || hy.temp.size() != cells ||
                hy.heat.size() != cells || hy.snowpack.size() != cells ||
                hy.base_moisture.size() != cells || hy.is_water.size() != cells ||
                hy.vitality.size() != cells || hy.canal_mask.size() != cells ||
                hy.soil_moisture.size() != cells ||
                hy.discharge_30d.size() != cells ||
                input.hydro_parent.size() != cells ||
                next.moisture.size() != cells ||
                next.plant_available_water.size() != cells ||
                next.water_balance_30d.size() != cells ||
                next.runoff.size() != cells || next.groundwater.size() != cells ||
                next.river_storage.size() != cells ||
                next.river_discharge.size() != cells) {
                // 与 round 的 starved 同类：输入边界不完整，不是算法分叉。
                return static_cast<uint64_t>(0);
            }
            // soil_moisture / river_discharge_30d / canal_water 没有 store 成员。前两
            // 条都是 in/out 的累积量，用 scratch 承接生产读到的初值再丢弃 —— 与
            // feedback 的 soil_moisture 同处理。canal_water 是每轮重算的派生量。
            _hydrology_soil_scratch = hy.soil_moisture;
            _hydrology_q30_scratch = hy.discharge_30d;
            if (hy.canal_water.size() == cells) {
                // 与 soil / q30 同理：canal_water 跨日存活，必须每天回到生产读到的
                // 初值。只在首次分配就等于让 worker 带着自己那份独立累积往邻格灌水。
                _hydrology_canal_water_scratch = hy.canal_water;
            } else if (_hydrology_canal_water_scratch.size() != cells) {
                _hydrology_canal_water_scratch.assign(cells, 0.0f);
            }

            pk_async_climate::HydrologyLanes lanes;
            lanes.hydro_parent = input.hydro_parent.data();
            lanes.has_river = hy.has_river.data();
            lanes.terrain = hy.terrain.data();
            lanes.landform = hy.landform.data();
            lanes.vegetation = hy.vegetation.data();
            lanes.cover = hy.cover.data();
            lanes.elevation = hy.elevation.data();
            lanes.precip = hy.precip.data();
            lanes.intensity = hy.intensity.data();
            lanes.weather_type = hy.weather_type.data();
            lanes.temp = hy.temp.data();
            lanes.heat = hy.heat.data();
            lanes.snowpack = hy.snowpack.data();
            lanes.base_moisture = hy.base_moisture.data();
            lanes.is_water = hy.is_water.data();
            lanes.vitality = hy.vitality.data();
            lanes.canal_mask = hy.canal_mask.data();
            lanes.neighbor_indices = (hy.has_neighbors && neighbors.size() >= cells * 6u)
                ? neighbors.data() : nullptr;
            lanes.moisture = next.moisture.data();
            lanes.soil_moisture = _hydrology_soil_scratch.data();
            lanes.water_balance_30d = next.water_balance_30d.data();
            lanes.plant_water = next.plant_available_water.data();
            lanes.discharge = next.river_discharge.data();
            lanes.discharge_30d = _hydrology_q30_scratch.data();
            lanes.river_storage = next.river_storage.data();
            lanes.groundwater = next.groundwater.data();
            lanes.runoff = next.runoff.data();
            lanes.canal_water = _hydrology_canal_water_scratch.data();

            _hydrology_canal.topology_generation = hy.canal_topology_generation;
            pk_async_climate::HydrologyStats stats;
            pk_async_climate::hydrology_pass_pure(hy.knobs, lanes, _hydrology_canal,
                                                _hydrology_scratch, stats);
            // riparian_moisture 是 store 成员但生产侧没有对应 slot（分叉表里标
            // map_data.gd declares no riparian_moisture_arr）。它的物理定义就是河道
            // 影响后的可用水，这里跟着 plant_available_water 走，免得停在昨天的值。
            if (next.riparian_moisture.size() == cells) {
                for (size_t i = 0; i < cells; ++i) {
                    next.riparian_moisture[i] = next.plant_available_water[i];
                }
            }
            report.stage_ran_mask |=
                pk_async_climate::CLIMATE_STAGE_BIT_RUNTIME_HYDROLOGY;
            return static_cast<uint64_t>(cells) * 11u;
        });
    }

    // ─── stage_b 三段：与生产落点一致，在 weather/distribute/hydrology 之后 ──
    //
    // B8-1：这三段在旧实现里排在 weather 之前（注释里写的是"必须夹在 albedo 与
    // feedback 之间"，那只约束了三段的内部顺序，没有约束它们与 weather 的相对
    // 位置）。生产语义是 stage_b 晚于 weather：runtime_hydrology_enabled=false 时
    // 内嵌在 weather_stage_b 节点，开启时由 stage_b_after_hydrology 承载。顺序错了
    // 会让 feedback 读到前一天的 weather_type/intensity，并让 hydrology 用未衰减的
    // VGP 抽水 —— 这正是 B8 记录的量级偏差来源之一。
    if (!legacy_stage_order) {
        run_shared_albedo();
        run_shared_vegetation();
        run_shared_feedback();
    }

    if (shared_round_ran || shared_albedo_ran || shared_vegetation_ran ||
        shared_feedback_ran || shared_weather_ran || shared_hydrology_ran ||
        shared_distribute_ran) {
        // 共享内核模式下 changed_cells 由实际写过的场决定。还没有共享实现的 stage
        // （vegetation / weather / hydrology / stage_b）对应的 lane 停在昨天的值——
        // 这是"worker 未实现"的诚实表示，分叉矩阵会照实报出来；用近似值填反而会把它
        // 伪装成算法分叉。
        report.changed_cells = 0;
        for (size_t i = 0; i < cells; ++i) {
            if (next.temperature[i] != current.temperature[i] ||
                next.moisture[i] != current.moisture[i] ||
                next.temperature_baseline[i] != current.temperature_baseline[i] ||
                next.vegetation_growth_pressure[i] !=
                    current.vegetation_growth_pressure[i] ||
                next.vegetation_vitality[i] != current.vegetation_vitality[i] ||
                next.plant_available_water[i] != current.plant_available_water[i]) {
                ++report.changed_cells;
            }
        }
    }
    // B8-2：把 worker 自持的 ψ 写回 store lane。提交时会随 store 一起 swap；
    // CLM2 ABI 4 的 serialize 直接从这里取，save/restore 因此保住 ψ 演化。
    if (_physics.synoptic_seeded && _physics.synoptic_psi.size() == cells &&
        cells == current.cell_count) {
        next.synoptic_psi = _physics.synoptic_psi;
        next.synoptic_psi_prev = _physics.synoptic_psi_prev;
    }
    // B8-2：cyclone 条目表进 store blob，随提交/存档持久化。空表也要写：它表示
    // "worker 已接管、当前没有活跃气旋"，与"从未播种"是两种不同状态。
    if (_cyclone_seeded) {
        next.cyclone_state = pk_async_climate::cyclone_state_encode(
            _cyclone_entries, _cyclone_next_stable_id);
    }
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

    // PK_CLIMATE_TRACE_CELL=<idx>：打印一格在这一天前后的值。定位累积类分歧时，
    // 「进来就已经是两倍」和「这一天变成两倍」是完全不同的两条线索，而分叉矩阵只给
    // 得出后者的结果。
    static const long trace_cell = [] {
        const char *v = std::getenv("PK_CLIMATE_TRACE_CELL");
        return v != nullptr ? std::strtol(v, nullptr, 10) : -1L;
    }();
    if (trace_cell >= 0 && static_cast<size_t>(trace_cell) < cells) {
        const size_t c = static_cast<size_t>(trace_cell);
        std::fprintf(stderr,
            "[cell-trace] day=%lld cell=%zu stage_mask=0x%X "
            "growth_pressure %.9g -> %.9g | paw %.9g -> %.9g | moisture %.9g -> %.9g\n",
            static_cast<long long>(day), c, report.stage_ran_mask,
            current.vegetation_growth_pressure[c], next.vegetation_growth_pressure[c],
            current.plant_available_water[c], next.plant_available_water[c],
            current.moisture[c], next.moisture[c]);
        std::fflush(stderr);
    }
    if (physics_owned && shared_round_ran && _round_out.ocean_thermal_anomaly.size() == cells)
        _physics.ocean_thermal_anomaly = _round_out.ocean_thermal_anomaly;
    if (!pk_async_physics::serialize_physics_state(_physics, next.physics_state, error)) {
        copy_error(report, error.c_str()); return false;
    }
    if (compute_state_hash) report.state_hash = next.state_hash();
    // B8-2：把 cyclone 的累计动作数与当前存活数无条件写进 report。weather 是
    // 节拍制 —— 只跑 round 的那天（stage_ran_mask=0xFF）根本不会进 genesis 段，
    // 逐日的 report 会带着零出门，于是 host/soak 最后采到的那一天永远是 0。
    // 这三个数是 kernel 级累计量，必须每天出口都要说真话。
    report.cyclone_injected = static_cast<int32_t>(_physics.cyclone_total_injected);
    report.cyclone_replaced = static_cast<int32_t>(_physics.cyclone_total_replaced);
    report.cyclone_decayed = static_cast<int32_t>(_physics.cyclone_total_decayed);
    report.cyclone_alive = static_cast<int32_t>(_cyclone_entries.size());
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
    // B8-2：cyclone 纯内核自检。7 个连成一行的水格，1 个气旋条目；验证
    //   1. 推进改变 intensity / age；
    //   2. stamp 写出 tag/x/y/lift，且 force_generation 逐位落到 tag；
    //   3. encode→decode 往返保持条目字段与 next_stable_id。
    {
        constexpr int kCells = 7;
        std::vector<int32_t> neighbors(static_cast<size_t>(kCells) * 6u, -1);
        for (int i = 0; i < kCells; ++i) {
            neighbors[static_cast<size_t>(i) * 6u + 0u] = (i > 0) ? i - 1 : -1;
            neighbors[static_cast<size_t>(i) * 6u + 1u] = (i + 1 < kCells) ? i + 1 : -1;
        }
        std::vector<float> pos_x(kCells), pos_y(kCells, 0.0f);
        std::vector<uint8_t> terrain(kCells, 0u);
        std::vector<float> temp(kCells, 0.90f), wind_x(kCells, 1.0f);
        std::vector<float> wind_y(kCells, 0.0f), wind_speed(kCells, 0.80f);
        std::vector<float> vapor(kCells, 0.85f), instability(kCells, 0.80f);
        std::vector<float> convergence(kCells, 0.70f);
        for (int i = 0; i < kCells; ++i) pos_x[static_cast<size_t>(i)] = float(i);
        pk_async_climate::CycloneAdvanceKnobs knobs;
        knobs.enabled = true;
        knobs.dt_days = 1.0f;
        knobs.world_bounds_pos_y = 0.0f;
        knobs.world_bounds_size_y = 1.0f;
        knobs.wrap_width_x = 0.0f;
        knobs.max_radius_cells = 4;
        pk_async_climate::CycloneLanes lanes;
        lanes.neighbors = neighbors.data();
        lanes.pos_x = pos_x.data();
        lanes.pos_y = pos_y.data();
        lanes.terrain = terrain.data();
        lanes.temp = temp.data();
        lanes.wind_x = wind_x.data();
        lanes.wind_y = wind_y.data();
        lanes.wind_speed = wind_speed.data();
        lanes.vapor = vapor.data();
        lanes.instability = instability.data();
        lanes.convergence = convergence.data();
        std::vector<uint32_t> tag(kCells, 0u), visit(kCells, 0u);
        std::vector<float> fx(kCells, 0.0f), fy(kCells, 0.0f), lift(kCells, 0.0f);
        pk_async_climate::CycloneStamp stamp;
        stamp.force_tag = tag.data();
        stamp.visit_tag = visit.data();
        stamp.force_x = fx.data();
        stamp.force_y = fy.data();
        stamp.lift = lift.data();
        stamp.force_generation = 1u;
        stamp.visit_generation = 1u;
        std::vector<pk_async_climate::CycloneEntry> entries(1);
        entries[0].stable_id = 7u;
        entries[0].key = 12;
        entries[0].cell_idx = 3;
        entries[0].intensity = 0.35f;
        entries[0].steering_x = 1.0f;
        entries[0].steering_y = 0.0f;
        pk_async_climate::CycloneStats stats;
        pk_async_climate::cyclone_advance_and_stamp_pure(
            kCells, knobs, lanes, entries, stamp, stats);
        if (entries.empty() || entries[0].age_days <= 0.0f) {
            error = "cyclone_kernel_advance_failed";
            return false;
        }
        bool stamped = false;
        for (int i = 0; i < kCells; ++i) {
            if (tag[static_cast<size_t>(i)] == 1u) {
                stamped = true;
                break;
            }
        }
        if (!stamped || stats.touched_cells <= 0) {
            error = "cyclone_kernel_stamp_failed";
            return false;
        }
        const std::vector<uint8_t> blob =
            pk_async_climate::cyclone_state_encode(entries, 9u);
        std::vector<pk_async_climate::CycloneEntry> decoded;
        uint64_t decoded_next = 0;
        pk_async_climate::cyclone_state_decode(blob, decoded, decoded_next);
        if (decoded.size() != entries.size() || decoded_next != 9u ||
            decoded[0].stable_id != entries[0].stable_id ||
            decoded[0].cell_idx != entries[0].cell_idx ||
            decoded[0].intensity != entries[0].intensity ||
            decoded[0].age_days != entries[0].age_days) {
            error = "cyclone_state_codec_failed";
            return false;
        }
        // genesis 自检：同一份 lanes 连续调用两次 —— 第一次注入 1 个，第二次
        // 命中同键变成 replaced，不该重复出生。
        {
            constexpr int kGenCells = 3;
            uint8_t water_lut[256] = {};
            water_lut[0] = 1u;
            std::vector<uint8_t> gen_terrain(kGenCells, 0u);
            std::vector<uint8_t> gen_is_water(kGenCells, 1u);
            std::vector<uint8_t> gen_type(kGenCells, 2u);
            std::vector<float> gen_intensity(kGenCells, 0.90f);
            std::vector<float> gen_temp(kGenCells, 0.90f);
            std::vector<float> gen_precip(kGenCells, 0.20f);
            std::vector<float> gen_cloud(kGenCells, 0.50f);
            std::vector<float> gen_inst(kGenCells, 0.60f);
            std::vector<float> gen_conv(kGenCells, 0.50f);
            std::vector<float> gen_wx(kGenCells, 1.0f);
            std::vector<float> gen_wy(kGenCells, 0.0f);
            std::vector<float> gen_posy = {0.35f, 0.35f, 0.35f};
            std::vector<int32_t> gen_nb(static_cast<size_t>(kGenCells) * 6u, -1);
            gen_nb[0] = 1; gen_nb[6] = 0; gen_nb[7] = 2; gen_nb[12] = 1;
            pk_async_climate::CycloneGenesisKnobs gen;
            gen.enabled = true;
            gen.storm_type_id = 2;
            gen.capacity = 4;
            gen.births_per_commit = 2;
            gen.world_bounds_pos_y = 0.0f;
            gen.world_bounds_size_y = 1.0f;
            pk_async_climate::CycloneGenesisLanes gen_lanes;
            gen_lanes.terrain = gen_terrain.data();
            gen_lanes.water_lut = water_lut;
            gen_lanes.weather_type = gen_type.data();
            gen_lanes.weather_intensity = gen_intensity.data();
            gen_lanes.temp = gen_temp.data();
            gen_lanes.precip = gen_precip.data();
            gen_lanes.cloud = gen_cloud.data();
            gen_lanes.instability = gen_inst.data();
            gen_lanes.convergence = gen_conv.data();
            gen_lanes.wind_x = gen_wx.data();
            gen_lanes.wind_y = gen_wy.data();
            gen_lanes.pos_y = gen_posy.data();
            gen_lanes.neighbors = gen_nb.data();
            gen_lanes.is_water = gen_is_water.data();
            std::vector<pk_async_climate::CycloneEntry> gen_entries;
            uint64_t gen_next_id = 1;
            pk_async_climate::CycloneGenesisStats gen_stats;
            pk_async_climate::cyclone_genesis_pure(kGenCells, gen, gen_lanes,
                                                  gen_entries, gen_next_id,
                                                  gen_stats);
             // births_per_commit=2、3 个同条件格：按 cell 升序注入 2 个后停。
             if (gen_stats.injected != 2 || gen_entries.size() != 2u ||
                 gen_next_id != 3u || gen_stats.cand_water != 3 ||
                 gen_stats.cand_shear != 3) {
                error = "cyclone_genesis_inject_failed";
                return false;
             }
             // 第二次调用把容量压到已满：同键（0/1）走 replaced，第 3 格因容量
             // 被挡住，不该再出生，也不该产生重复条目。
             gen.capacity = 2;
             pk_async_climate::cyclone_genesis_pure(kGenCells, gen, gen_lanes,
                                                  gen_entries, gen_next_id,
                                                  gen_stats);
            if (gen_stats.injected != 0 || gen_stats.replaced != 2 ||
                gen_entries.size() != 2u) {
                error = "cyclone_genesis_replace_failed";
                return false;
            }
        }
    }
    // B8 P0：顺序契约是 kernel 的一部分，随 self_test 一起跑。表本身错了
    // （漏 stage / 重复 / fallback tail 不在尾部）时不必等到 plan_day。
    std::string order_error;
    if (!runtime_climate_stage_order_self_test(order_error)) {
        error = "climate_kernel_stage_order_contract_failed:" + order_error;
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
    // 执行序必须与声明序一致。位掩码只能证明 stage 跑过，证明不了顺序。
    if (!runtime_climate_stage_sequence_is_canonical(
            report.stage_sequence.data(), report.stage_sequence_count,
            order_error)) {
        error = "climate_kernel_stage_sequence_contract_failed:" + order_error;
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
