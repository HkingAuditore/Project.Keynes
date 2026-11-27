#include "runtime_climate_kernel.h"
#include "simulation_math.h"
#include "runtime_climate_weather_input.h"
#include "economy_cost_probe.h"
#include "parallel_dispatcher.h"
#include "runtime_climate_formulas.h"
// S3：生产 Climate pass 的共享纯内核。worker 不再维护第二套 stage 实现。
#include "runtime_climate_parity.h"
#include "runtime_climate_passes.h"
#include "runtime_climate_pass_math.h"
#include "runtime_switch_registry.h"
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

namespace pk {
std::FILE *pk_sim_trace_file();
namespace {
constexpr uint64_t FNV_OFFSET = 1469598103934665603ull;
constexpr uint64_t FNV_PRIME = 1099511628211ull;

bool same_float_bits(const std::vector<float> &a, const std::vector<float> &b) {
    return a.size() == b.size() && (a.empty() ||
        std::memcmp(a.data(), b.data(), a.size() * sizeof(float)) == 0);
}

uint64_t mix(uint64_t value, uint64_t input) noexcept {
    value ^= input + 0x9e3779b97f4a7c15ull + (value << 6u) + (value >> 2u);
    return value * FNV_PRIME;
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
    destination.assign(source.begin(), source.end());
}

void copy_store_lanes(RuntimeClimateStore &next, const RuntimeClimateStore &current,
                      bool reuse_committed_history = false, bool visible_only = false,
                      bool include_physics_blob = true) {
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
    static const bool full_history = [] {
        const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_CLIMATE_HISTORY_COPY_FULL);
        return value && std::strcmp(value, "1") == 0;
    }();
    static const bool verify_history = [] {
        const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_CLIMATE_HISTORY_COPY_VERIFY);
        return value && std::strcmp(value, "1") == 0;
    }();
    const uint64_t gap = current.generation >= next.generation
        ? current.generation - next.generation : UINT64_MAX;
    const uint32_t cursor_gap = (current.history_cursor + 365u - next.history_cursor) % 365u;
    const bool incremental = reuse_committed_history && !full_history &&
        next.generation != 0 && gap < 365u && cursor_gap <= gap &&
        next.cell_count == current.cell_count &&
        current.temperature_history.size() == static_cast<size_t>(current.cell_count) * 365u &&
        next.temperature_history.size() == current.temperature_history.size();
    size_t history_copied = current.temperature_history.size();
    if (visible_only) {
        next.temperature_history.clear();
        history_copied = 0;
    } else if (incremental) {
        // 每次提交至多推进一行；即使有空跑日，最后 gap 行也覆盖所有变化。
        // 双缓冲重试的 speculative next 比 current 新，必须走完整恢复。
        history_copied = static_cast<size_t>(gap) * current.cell_count;
        for (uint64_t step = 0; step < gap; ++step) {
            const size_t row = (current.history_cursor + 365u - gap + step) % 365u;
            const size_t offset = row * current.cell_count;
            std::copy_n(current.temperature_history.data() + offset,
                current.cell_count, next.temperature_history.data() + offset);
        }
    } else {
        copy_lane(next.temperature_history, current.temperature_history);
    }
    if (!visible_only && incremental && verify_history && !current.temperature_history.empty() &&
            std::memcmp(next.temperature_history.data(), current.temperature_history.data(),
                current.temperature_history.size() * sizeof(float)) != 0) {
        std::fprintf(stderr, "[climate-history-copy-mismatch] day=%lld gap=%llu\n",
            static_cast<long long>(current.committed_day), static_cast<unsigned long long>(gap));
        std::abort();
    }
    EconomyCostProbe::record("climate.history_copied_lanes", current.committed_day, 0.0, history_copied);
    next.cell_count = current.cell_count;
    next.generation = current.generation;
    next.climate_generation = current.climate_generation;
    next.committed_day = current.committed_day;
    next.climate_anomaly = current.climate_anomaly;
    next.annual_temperature_drift = current.annual_temperature_drift;
    next.rng_state = current.rng_state;
    next.annual_rng_state = current.annual_rng_state;
    next.history_cursor = current.history_cursor;
    if (include_physics_blob) next.physics_state = current.physics_state;
    else next.physics_state.clear();
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
    // 海冰翻转在 worker 上推进 terrain；MapData 那份要等回灌才追上，流水线下落后的
    // 天数取决于机器快慢。已提交过的 worker 读自己昨天的 terrain。
    const std::vector<uint8_t> &terrain =
        (in.climate_worker_authoritative && current.committed_day >= 0 &&
         current.terrain.size() == static_cast<size_t>(n)) ? current.terrain : in.terrain;
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
        for (uint8_t t : terrain) if (water[t]) ++nw;
        s.resize_water(nw);
        if (nw > 0) psi_topology_build_pure(n, terrain.data(), nb.data(), water,
            s.cell_to_water.data(), s.water_to_cell.data(), s.nb_w.data());
        else std::fill(s.cell_to_water.begin(), s.cell_to_water.end(), -1);
        s.topo_valid = true;
    }
    if (!s.coast_valid) {
        WindCoastLanes l;
        l.terrain = terrain.data(); l.neighbors = nb.data(); l.is_water_lut = water;
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
        l.terrain = terrain.data(); l.neighbors = nb.data(); l.is_water_lut = water;
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
        w.diffuse_w = std::min(0.5, (1.0 - simulation_math::pow(1.0 - diffuse, elapsed)) * grid_s * grid_s);
        std::vector<float> fx, fy;
        if (w.momentum_active) {
            fx.resize(n); fy.resize(n);
            for (int i = 0; i < n; ++i) { fx[i] = s.wind_x[i] * s.wind_speed[i]; fy[i] = s.wind_y[i] * s.wind_speed[i]; }
            w.snap_fx = fx.data(); w.snap_fy = fy.data();
        }
        if (w.momentum_advect_w > 0.0 && s.wind_traj_valid) { w.traj_idx = s.wind_traj_idx.data(); w.traj_w = s.wind_traj_w.data(); }
        WindFieldLanes l;
        l.lat_norm = in.cell_lat_norm.data(); l.pos_x = in.cell_pos_x.data(); l.pos_y = in.cell_pos_y.data();
        l.slp = s.slp.data(); l.neighbors = nb.data(); l.terrain = terrain.data(); l.landform = in.landform.data(); l.is_water_lut = water;
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
        s.note_wind_solve(day);
    }
    if (daily_due) { s.last_daily_day = day; ++s.daily_due_seq; }
    if (ocean_due) {
        s.ocean_psi_prev = s.ocean_psi;
        PsiSolveLanes l;
        l.n_cells = n; l.n_water = s.n_water; l.neighbors = nb.data(); l.terrain = terrain.data(); l.is_water_lut = water;
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
        u.lat_norm = in.cell_lat_norm.data(); u.pos_y = in.cell_pos_y.data(); u.terrain = terrain.data(); u.neighbors = nb.data(); u.is_water_lut = water;
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

// The temperature sums use float in both paths. The legacy script uses double
// for latitude and interpolation, while the worker's own sampling uses float.
template <typename Scalar>
Scalar thermal_equator_lat_norm(const std::vector<float> &temp,
                               const std::vector<Scalar> &pos_y,
                               Scalar bounds_pos_y, Scalar bounds_size_y,
                               Scalar fallback) {
    constexpr int TE_NB = 24;
    if (!(bounds_size_y > Scalar(0.001)) || temp.empty() || pos_y.size() != temp.size())
        return fallback;
    float sum[TE_NB] = {};
    int count[TE_NB] = {};
    for (size_t i = 0; i < temp.size(); ++i) {
        const Scalar ny = std::clamp((pos_y[i] - bounds_pos_y) / bounds_size_y,
                                    Scalar(0), Scalar(0.999999));
        const int bucket = static_cast<int>(ny * TE_NB);
        sum[bucket] += temp[i];
        ++count[bucket];
    }
    Scalar best_m = Scalar(-1);
    int best_b = TE_NB / 2;
    for (int b = 0; b < TE_NB; ++b) {
        if (count[b] <= 0) continue;
        const Scalar m = static_cast<Scalar>(sum[b]) / static_cast<Scalar>(count[b]);
        if (m > best_m) { best_m = m; best_b = b; }
    }
    Scalar bf = static_cast<Scalar>(best_b);
    if (best_b > 0 && best_b < TE_NB - 1 && count[best_b - 1] > 0 && count[best_b + 1] > 0) {
        const Scalar ml = static_cast<Scalar>(sum[best_b - 1]) / static_cast<Scalar>(count[best_b - 1]);
        const Scalar mr = static_cast<Scalar>(sum[best_b + 1]) / static_cast<Scalar>(count[best_b + 1]);
        const Scalar denom = ml - Scalar(2) * best_m + mr;
        if (std::fabs(denom) > Scalar(1.0e-6))
            bf += std::clamp(Scalar(0.5) * (ml - mr) / denom, Scalar(-0.5), Scalar(0.5));
    }
    return std::clamp((bf + Scalar(0.5)) / static_cast<Scalar>(TE_NB), Scalar(0), Scalar(1));
}

// PK_SIM_DAY_TRACE 的 [climate-out]：每个 stage 之后 store 关键 lane 的短哈希，
// 用来定位两次运行从哪个 stage 开始分叉。
thread_local std::string *g_diag_stage_line = nullptr;
thread_local const RuntimeClimateStore *g_diag_stage_store = nullptr;
template <typename T>
uint64_t diag_lane_hash(const std::vector<T> &values) {
    uint64_t h = 1469598103934665603ull;
    const auto *bytes = reinterpret_cast<const uint8_t *>(values.data());
    for (size_t b = 0; b < values.size() * sizeof(T); ++b) h = (h ^ bytes[b]) * 1099511628211ull;
    return h ^ values.size();
}
void diag_note_stage(const char *tag) {
    if (g_diag_stage_line == nullptr || g_diag_stage_store == nullptr) return;
    const RuntimeClimateStore &s = *g_diag_stage_store;
    char buf[384];
    std::snprintf(buf, sizeof(buf), " %s:t=%llu,m=%llu,sc=%llu,sp=%llu,cv=%llu,wb=%llu,pw=%llu,wi=%llu,wp=%llu,wt=%llu,va=%llu",
        tag,
        static_cast<unsigned long long>(diag_lane_hash(s.temperature) % 100000),
        static_cast<unsigned long long>(diag_lane_hash(s.moisture) % 100000),
        static_cast<unsigned long long>(diag_lane_hash(s.snow_cover) % 100000),
        static_cast<unsigned long long>(diag_lane_hash(s.snowpack) % 100000),
        static_cast<unsigned long long>(diag_lane_hash(s.cover) % 100000),
        static_cast<unsigned long long>(diag_lane_hash(s.water_balance_30d) % 100000),
        static_cast<unsigned long long>(diag_lane_hash(s.plant_available_water) % 100000),
        static_cast<unsigned long long>(diag_lane_hash(s.weather_intensity) % 100000),
        static_cast<unsigned long long>(diag_lane_hash(s.weather_precipitation) % 100000),
        static_cast<unsigned long long>(diag_lane_hash(s.weather_type) % 100000),
        static_cast<unsigned long long>(diag_lane_hash(s.vapor) % 100000));
    *g_diag_stage_line += buf;
}

template <typename Fn>
void run_stage(RuntimeClimateKernelReport &report, RuntimeClimateStage stage, Fn &&body) {
    const auto begin = std::chrono::steady_clock::now();
    const uint64_t work = body();
    if (g_diag_stage_line != nullptr)
        diag_note_stage(std::to_string(static_cast<int>(stage)).c_str());
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

#include "runtime_climate_kernel_stage_order.inc"
void RuntimeClimateKernel::reset(uint32_t) {
    invalidate_committed_physics();
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

bool RuntimeClimateKernel::plan_day(int64_t day, const RuntimeEnvironmentSnapshot &input,
                                    const RuntimeClimateCatalog &catalog,
                                    const RuntimeClimateStore &current,
                                    RuntimeClimateStore &next,
                                    RuntimeClimateKernelReport &report,
                                    bool compute_state_hash,
                                    bool validate_input, bool reuse_committed_history) const {
#include "runtime_climate_kernel_seed_state.inc"
#include "runtime_climate_kernel_physical_inputs.inc"
#include "runtime_climate_kernel_daily_round.inc"
#include "runtime_climate_kernel_surface_feedback.inc"
#include "runtime_climate_kernel_weather.inc"
#include "runtime_climate_kernel_water_cycle.inc"
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
        const char *v = pk::runtime_switch_value(pk::RuntimeSwitch::PK_CLIMATE_TRACE_CELL);
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
    {
        EconomyCostProbe probe("climate.physics_serialize", day, next.physics_state.size());
        if (!pk_async_physics::serialize_physics_state(_physics, next.physics_state, error)) {
            copy_error(report, error.c_str()); return false;
        }
    }
    _planned_physics_generation = next.generation;
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

void RuntimeClimateKernel::copy_visible_store(RuntimeClimateStore &destination,
        const RuntimeClimateStore &source, bool include_physics_blob) {
    copy_store_lanes(destination, source, false, true, include_physics_blob);
}

std::shared_ptr<const pk_async_physics::RuntimeClimatePhysicsState>
RuntimeClimateKernel::copy_physics_writeback(const RuntimeClimateStore &store) const {
    if (_committed_physics_owner != &store ||
        _committed_physics_generation != store.generation ||
        _physics.committed_day != store.committed_day ||
        _physics.cell_count != static_cast<int>(store.cell_count)) return {};

    auto view = std::make_shared<pk_async_physics::RuntimeClimatePhysicsState>();
    pk_async_physics::copy_committed_physics_fields(_physics, *view);
    // The solver validated the raw trajectory settings and verified the
    // geometry, neighbors, and settings for this commit's table.
    if (_physics_cache_keys_valid && _physics.wind_traj_valid) {
        view->wind_traj_idx = _physics.wind_traj_idx;
        view->wind_traj_w = _physics.wind_traj_w;
        view->wind_traj_fingerprint = _physics.wind_traj_fingerprint;
        view->wind_traj_valid = true;
    }
    return view;
}

void RuntimeClimateKernel::commit(RuntimeClimateStore &current, RuntimeClimateStore &next) {
    using std::swap;
    swap(current, next);
}

void RuntimeClimateKernel::invalidate_committed_physics() {
    _committed_physics_owner = nullptr;
    _committed_physics_generation = 0;
    _planned_physics_generation = 0;
    _physics_cache_keys_valid = false;
}

void RuntimeClimateKernel::accept_committed_physics(const RuntimeClimateStore &store) {
    if (_planned_physics_generation == store.generation && !store.physics_state.empty()) {
        _committed_physics_owner = &store;
        _committed_physics_generation = store.generation;
    } else {
        invalidate_committed_physics();
    }
    _planned_physics_generation = 0;
}

#include "runtime_climate_kernel_selftest.inc"
} // namespace pk
