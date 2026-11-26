// ─── Climate pass 纯内核实现（Godot 无依赖）──────────────────────
//
// S3 搬迁体：下面 9 个 kernel 原位于 world_ext_climate.cpp（static 文件作用域），
// 现在是生产与 SHADOW worker 共用的唯一实现。搬迁是逐字的，不含任何算法改动；
// 任何数值行为变更必须单独提案，否则无法与 S2 分叉矩阵对齐。
//
// 不得 include godot_cpp。这一条约束就是“worker 可用”的全部含义。

#include "runtime_climate_passes.h"
#include "runtime_switch_registry.h"
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <queue>
#include <utility>
#include <vector>

namespace pk {
namespace pk_async_climate {

// ─── 生产 pass_a 输入叠加（见头文件注释）─────────────────────────────
namespace {

// Names every per-cell lane that still differs after the pass_a overlay. Some
// differences are expected — a lane the worker owns (vapor, cloud, sea ice) is
// the thing being compared, not an input — so this prints everything and leaves
// the judgement to the reader. On the first round of a run nothing has diverged
// yet, so on that day every entry here is an input bug.
bool pk_lane_diag_enabled() {
    static const bool on = [] {
        const char *v = pk::runtime_switch_value(pk::RuntimeSwitch::PK_CLIMATE_LANE_DIAG);
        return v != nullptr && v[0] == '1';
    }();
    return on;
}

template <typename T>
void pk_report_lane(const char *name, const std::vector<T> &before,
                    const std::vector<T> &after) {
    // nonzero counts matter as much as the delta: a lane the capture path never
    // populated reads as all-zero, and without a recording point the overlay
    // cannot fix it. "capture_nz=0" on a lane that should carry a field is the
    // signature of a missing capture, not of a stale one.
    size_t before_nz = 0;
    for (const T &v : before) {
        if (v != T{}) ++before_nz;
    }
    size_t after_nz = 0;
    for (const T &v : after) {
        if (v != T{}) ++after_nz;
    }
    if (before.size() != after.size()) {
        std::fprintf(stderr,
                     "[lane-diag] %-28s size capture=%zu(nz=%zu) overlaid=%zu(nz=%zu)\n",
                     name, before.size(), before_nz, after.size(), after_nz);
        return;
    }
    size_t changed = 0;
    size_t first = 0;
    for (size_t i = 0; i < after.size(); ++i) {
        if (before[i] == after[i]) continue;
        if (changed == 0) first = i;
        ++changed;
    }
    std::fprintf(stderr,
                 "[lane-diag] %-28s n=%zu capture_nz=%zu overlaid_nz=%zu changed=%zu",
                 name, after.size(), before_nz, after_nz, changed);
    if (changed != 0) {
        std::fprintf(stderr, " first=%zu capture=%.9g prod=%.9g", first,
                     static_cast<double>(before[first]),
                     static_cast<double>(after[first]));
    }
    std::fprintf(stderr, "\n");
}

} // namespace

bool round_input_lane_diag_enabled() { return pk_lane_diag_enabled(); }

void report_round_input_lane_delta(const ClimateInputBuf &before,
                                   const ClimateInputBuf &after,
                                   int64_t day) {
    std::fprintf(stderr, "[lane-diag] ==== day %lld ====\n",
                 static_cast<long long>(day));
#define PK_INPUT_LANE(field, type) pk_report_lane(#field, before.field, after.field);
#include "runtime_climate_input_lane_fields.inc"
#undef PK_INPUT_LANE
    std::fprintf(stderr, "[lane-diag] ---- end of overlay delta ----\n");
    std::fflush(stderr);
}

void overlay_production_pass_a(ClimateInputBuf &base, const ClimateInputBuf &prod) {
    if (prod.n_cells <= 0 || prod.n_cells != base.n_cells) return;

    // prod 里为空 = 生产那一轮也没启用这条可选列（sync 路径以 slot 缺失为不启用），
    // 此时保留 base 会让 worker 多启用一条列 —— 所以可选列必须连"空"一起照抄。
    // 下面按 pass_a 是否真的读它来分两类。
    auto take_f32 = [](std::vector<float> &dst, const std::vector<float> &src) {
        if (!src.empty()) dst = src;
    };
    auto take_u8 = [](std::vector<uint8_t> &dst, const std::vector<uint8_t> &src) {
        if (!src.empty()) dst = src;
    };
    // 必填列：pass_a 一定读，prod 一定非空。
    take_u8(base.is_water, prod.is_water);
    take_u8(base.cover, prod.cover);
    take_u8(base.ema_initialized, prod.ema_initialized);
    take_f32(base.elevation, prod.elevation);
    take_f32(base.base_moisture, prod.base_moisture);
    take_f32(base.lat_norm, prod.lat_norm);
    take_f32(base.temp_baseline_year, prod.temp_baseline_year);
    take_f32(base.temp, prod.temp);
    take_f32(base.temp_30d, prod.temp_30d);
    take_f32(base.temp_365d, prod.temp_365d);
    take_f32(base.thermal_energy, prod.thermal_energy);
    take_f32(base.snowpack, prod.snowpack);
    take_f32(base.moisture, prod.moisture);
    take_f32(base.insol_annual_mean, prod.insol_annual_mean);
    take_f32(base.radiative_modifier_add, prod.radiative_modifier_add);
    take_f32(base.radiative_modifier_factor, prod.radiative_modifier_factor);
    // 可选列：内核以"长度 == n"为启用条件，生产以"slot 存在"为启用条件。这里连空一起
    // 抄，才能让两边的启用集合一致；保留 base 的非空值会让 worker 多算一项 anomaly。
    base.weather_vapor = prod.weather_vapor;
    base.weather_precip = prod.weather_precip;
    base.soil_moisture = prod.soil_moisture;
    base.water_balance_30d = prod.water_balance_30d;
    base.maritime = prod.maritime;

    // pass_a 标量子集。逐字段列 —— 见头文件注释里为什么不能整体覆盖 scalars。
    ClimateRoundScalars &s = base.scalars;
    const ClimateRoundScalars &p = prod.scalars;
    s.season_phase = p.season_phase;
    s.axial_tilt_deg = p.axial_tilt_deg;
    s.day_length_gain = p.day_length_gain;
    s.solar_gain = p.solar_gain;
    s.insol_amp = p.insol_amp;
    s.insol_gain = p.insol_gain;
    s.insol_dev_min = p.insol_dev_min;
    s.insol_dev_max = p.insol_dev_max;
    s.thermal_inertia_land = p.thermal_inertia_land;
    s.thermal_inertia_water = p.thermal_inertia_water;
    s.thermal_inertia_snow = p.thermal_inertia_snow;
    s.thermal_inertia_high_mountain = p.thermal_inertia_high_mountain;
    s.thermal_daily_delta_cap = p.thermal_daily_delta_cap;
    s.thermal_dt_days = p.thermal_dt_days;
    s.runtime_moisture_base_relax_rate = p.runtime_moisture_base_relax_rate;
    s.runtime_moisture_weather_vapor_weight = p.runtime_moisture_weather_vapor_weight;
    s.runtime_moisture_precip_weight = p.runtime_moisture_precip_weight;
    s.runtime_moisture_soil_weight = p.runtime_moisture_soil_weight;
    s.runtime_moisture_soil_dry_weight = p.runtime_moisture_soil_dry_weight;
    s.runtime_moisture_water_balance_weight = p.runtime_moisture_water_balance_weight;
    s.runtime_moisture_water_balance_dry_weight = p.runtime_moisture_water_balance_dry_weight;
    // 生产 sync 路径没有给 snowpack_cover_full 赋值，它用的就是结构默认值。要逐位相同
    // 就得连这个"默认"一起抄，而不是保留 base 从 GDScript 传来的那个。
    s.snowpack_cover_low = p.snowpack_cover_low;
    s.snowpack_cover_full = p.snowpack_cover_full;
    s.maritime_season_damp = p.maritime_season_damp;
    s.sea_level = p.sea_level;
    s.days_per_year = p.days_per_year;
}


// ─── 生产其余 pass 标量叠加（见头文件注释）───────────────────────────
void overlay_production_pass_b(ClimateInputBuf &base, const ClimatePassBInput &prod) {
    if (base.n_cells <= 0 || prod.n_cells != base.n_cells) return;
    const size_t n = static_cast<size_t>(base.n_cells);
    if (prod.sea_ice_frac.size() == n) base.sea_ice_frac = prod.sea_ice_frac;
    if (prod.temp_transport_anomaly.size() == n) {
        base.temp_transport_anomaly = prod.temp_transport_anomaly;
    }
}

void overlay_production_wind_air(ClimateInputBuf &base, const WindAirInput &prod) {
    if (base.n_cells <= 0 || prod.n_cells != base.n_cells) return;
    const size_t n = static_cast<size_t>(base.n_cells);
    if (prod.baseline.size() == n) base.wind_baseline = prod.baseline;
    if (prod.wind_x.size() == n) base.wind_x = prod.wind_x;
    if (prod.wind_y.size() == n) base.wind_y = prod.wind_y;
    if (prod.wind_speed.size() == n) base.wind_speed = prod.wind_speed;
    // 轨迹表只有整对齐全才叠。生产未命中时这里清空，而不是留上一天那张 ——
    // 留着会让 worker 在生产走离散分支的那一天仍然做重心插值。
    if (prod.traj_idx.size() == n * 3u && prod.traj_w.size() == n * 3u) {
        base.wind_traj_idx = prod.traj_idx;
        base.wind_traj_w = prod.traj_w;
    } else {
        base.wind_traj_idx.clear();
        base.wind_traj_w.clear();
    }
}

namespace {

// Names every knob that production and the worker disagree on *and* that the
// overlay above does not carry across. Those are the real holes: a knob the
// worker guessed from the kick-time dictionary while production used something
// else. Enabled with PK_CLIMATE_SCALAR_DIAG=1 because it prints per round.
bool pk_scalar_diag_enabled() {
    static const bool on = [] {
        const char *v = pk::runtime_switch_value(pk::RuntimeSwitch::PK_CLIMATE_SCALAR_DIAG);
        return v != nullptr && v[0] == '1';
    }();
    return on;
}

void pk_report_uncovered_scalars(const ClimateRoundScalars &before,
                                 const ClimateRoundScalars &after,
                                 const ClimateRoundScalars &prod,
                                 int scalar_mask) {
    int holes = 0;
#define PK_ROUND_SCALAR(field)                                                 \
    if (static_cast<double>(before.field) != static_cast<double>(prod.field) && \
        static_cast<double>(after.field) != static_cast<double>(prod.field)) {  \
        std::fprintf(stderr,                                                    \
                     "[scalar-diag] mask=0x%02X uncovered %s worker=%.9g prod=%.9g\n", \
                     scalar_mask, #field, static_cast<double>(after.field),      \
                     static_cast<double>(prod.field));                          \
        ++holes;                                                                \
    }
#include "runtime_climate_round_scalar_fields.inc"
#undef PK_ROUND_SCALAR
    if (holes != 0) std::fflush(stderr);
}

} // namespace

void overlay_production_round_scalars(ClimateInputBuf &base,
                                     const ClimateRoundScalars &p,
                                     int scalar_mask) {
    ClimateRoundScalars &s = base.scalars;
    const ClimateRoundScalars before = pk_scalar_diag_enabled()
        ? base.scalars : ClimateRoundScalars{};
    // wrap_period_x 是五个 advect 类 pass 共用的域宽，任一 pass 记录过就采用。
    if (scalar_mask != 0) s.wrap_period_x = p.wrap_period_x;
    if ((scalar_mask & 0x01) != 0) {
        // pass_a 段。thermal_dt_days 在这里：生产每约十天跑一次气候并用 dt 补偿，
        // 所以它绝不是 1，而 worker 若退回默认值，所有带 dt 的量（热惯性 EMA、
        // 海冰日上限、天气过渡速率）都会整场偏掉。
        s.season_phase = p.season_phase;
        s.axial_tilt_deg = p.axial_tilt_deg;
        s.day_length_gain = p.day_length_gain;
        s.solar_gain = p.solar_gain;
        s.insol_amp = p.insol_amp;
        s.insol_gain = p.insol_gain;
        s.insol_dev_min = p.insol_dev_min;
        s.insol_dev_max = p.insol_dev_max;
        s.thermal_inertia_land = p.thermal_inertia_land;
        s.thermal_inertia_water = p.thermal_inertia_water;
        s.thermal_inertia_snow = p.thermal_inertia_snow;
        s.thermal_inertia_high_mountain = p.thermal_inertia_high_mountain;
        s.thermal_daily_delta_cap = p.thermal_daily_delta_cap;
        s.thermal_dt_days = p.thermal_dt_days;
        s.runtime_moisture_base_relax_rate = p.runtime_moisture_base_relax_rate;
        s.runtime_moisture_weather_vapor_weight = p.runtime_moisture_weather_vapor_weight;
        s.runtime_moisture_precip_weight = p.runtime_moisture_precip_weight;
        s.runtime_moisture_soil_weight = p.runtime_moisture_soil_weight;
        s.runtime_moisture_soil_dry_weight = p.runtime_moisture_soil_dry_weight;
        s.runtime_moisture_water_balance_weight = p.runtime_moisture_water_balance_weight;
        s.runtime_moisture_water_balance_dry_weight = p.runtime_moisture_water_balance_dry_weight;
        s.snowpack_cover_low = p.snowpack_cover_low;
        s.maritime_season_damp = p.maritime_season_damp;
        s.sea_level = p.sea_level;
        s.days_per_year = p.days_per_year;
    }
    if ((scalar_mask & 0x02) != 0) {
        s.pb_winter_boost = p.pb_winter_boost;
        s.pb_snow_cool = p.pb_snow_cool;
        s.pb_veg_cool = p.pb_veg_cool;
        s.pb_diurnal_amp = p.pb_diurnal_amp;
        s.pb_evap_gain = p.pb_evap_gain;
        s.pb_rs_threshold = p.pb_rs_threshold;
        s.pb_rs_factor = p.pb_rs_factor;
        s.pb_rs_lookback = p.pb_rs_lookback;
        s.pb_t_freeze = p.pb_t_freeze;
        s.pb_coupling_gain = p.pb_coupling_gain;
        s.pb_coast_leak = p.pb_coast_leak;
        s.pb_sea_ice_albedo_cooling = p.pb_sea_ice_albedo_cooling;
    }
    if ((scalar_mask & 0x04) != 0) {
        s.ow_advect_steps = p.ow_advect_steps;
        s.ow_heat_mix = p.ow_heat_mix;
        s.ow_tta_source_cap = p.ow_tta_source_cap;
        s.ow_cold_transport_form = p.ow_cold_transport_form;
        s.ow_cold_transport_melt = p.ow_cold_transport_melt;
        s.ow_tta_blend_rate = p.ow_tta_blend_rate;
        s.ow_tta_zero_current_decay = p.ow_tta_zero_current_decay;
    }
    if ((scalar_mask & 0x08) != 0) {
        s.ol_effective_leak = p.ol_effective_leak;
        s.ol_tta_source_cap = p.ol_tta_source_cap;
        s.ol_tta_blend_rate = p.ol_tta_blend_rate;
        s.ol_tta_decay_rate = p.ol_tta_decay_rate;
    }
    if ((scalar_mask & 0x10) != 0) {
        s.wa_advect_steps = p.wa_advect_steps;
        s.wa_heat_mix = p.wa_heat_mix;
    }
    if ((scalar_mask & 0x20) != 0) {
        s.ws_air_leak = p.ws_air_leak;
        s.ws_cold_transport_form = p.ws_cold_transport_form;
        s.ws_cold_transport_melt = p.ws_cold_transport_melt;
    }
    if ((scalar_mask & 0x40) != 0) {
        s.si_k_freeze = p.si_k_freeze;
        s.si_k_melt = p.si_k_melt;
        s.si_t_form = p.si_t_form;
        s.si_t_melt = p.si_t_melt;
        s.si_contagion = p.si_contagion;
        s.si_threshold = p.si_threshold;
        s.si_hysteresis = p.si_hysteresis;
        s.si_ice_delay = p.si_ice_delay;
        s.si_enable_oht = p.si_enable_oht;
        s.si_solar_gate_enabled = p.si_solar_gate_enabled;
        s.si_freeze_insol_low = p.si_freeze_insol_low;
        s.si_freeze_insol_high = p.si_freeze_insol_high;
        s.si_solar_melt_start = p.si_solar_melt_start;
        s.si_solar_melt_gain = p.si_solar_melt_gain;
        s.si_min_thick_ice_solar_exposure = p.si_min_thick_ice_solar_exposure;
        s.si_daily_delta_cap = p.si_daily_delta_cap;
        s.si_edge_mix_rate = p.si_edge_mix_rate;
        s.si_dt_days = p.si_dt_days;
        s.si_terrain_lake_id = p.si_terrain_lake_id;
        s.si_terrain_sea_ice_id = p.si_terrain_sea_ice_id;
        s.si_terrain_ocean_id = p.si_terrain_ocean_id;
    }
    // 生产这一天没跑过的 pass 不该由 worker 单方面跑：把它从 passes_mask 里摘掉，
    // 让 run_climate_round_passes 直接跳过（而不是用 base 的默认 knobs 硬跑一遍）。
    // pass_a / transp / finalizer 的启用仍由 base 决定 —— 前者由 overlay_production_pass_a
    // 保证权威，后两者没有独立的生产 knobs 记录点。
    constexpr int RECORDED_PASSES = 0x02 | 0x04 | 0x08 | 0x10 | 0x20 | 0x40;
    s.passes_mask &= ~RECORDED_PASSES;
    s.passes_mask |= (scalar_mask & RECORDED_PASSES);

    if (pk_scalar_diag_enabled()) {
        pk_report_uncovered_scalars(before, s, p, scalar_mask);
    }
}

} // namespace pk_async_climate
} // namespace pk
