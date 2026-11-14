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

// ─── Pure kernels（worker 线程跑，零 Godot API） ─────────────────────────

// Latitude weight for the seasonal moisture envelope: 0 at the equator, 1 near the poles.
static float pk_moisture_lat_weight(float ny) {
    const float abs_lat = std::fabs(ny * 2.0f - 1.0f);
    float t = (abs_lat - 0.18f) / 0.64f;
    if (t < 0.0f) t = 0.0f;
    else if (t > 1.0f) t = 1.0f;
    return t * t * (3.0f - 2.0f * t);
}

// pass_a pure kernel — 移植自 DCWorldExt::run_climate_pass_a（world_ext.cpp:2096）。
// 算法逐行 1:1 镜像 sync 路径 line 2293-2417 的 run_range lambda body：
//   - 每 cell 独立（无邻居 gather，无跨 cell 写）
//   - 用 dc_* helper（dc_insolation_now / dc_clamp01f / dc_clampf 等），它们已经
//     是 pure inline 函数，worker 安全调用
//   - 末尾把 ocean_anom / local_anom 清 0（开启新一日累加，与 sync line 2393-2394 一致）
//
// 输入：in.{is_water, terrain, cover, ema_initialized, moisture, elevation,
//           base_moisture, lat_norm, temp_baseline_year, temp, temp_30d, temp_365d,
//           thermal_energy, snowpack} + in.scalars
// 输出：out.{moisture, snow_cover, temp_baseline, temp_season_offset,
//            ema_initialized, temp_30d, temp_365d, temp_anomaly,
//            insolation_now, insolation_dev, day_length, heat_input,
//            thermal_energy, snowpack, ocean_thermal_anomaly, local_thermal_anomaly}
//
// 注意：sync 路径直接 ptrw() 写 _slots（同一 buffer in/out 别名）。pure kernel
// 严格分 in/out，避免 worker 看到自己上一 cell 写的中间状态——因为 pass_a 每个
// cell 独立，**没有 in-place 依赖**，分 in/out 不影响 bit-equal。
bool _async_pass_a_kernel_pure(const ClimateInputBuf &in,
                                      ClimateOutputBuf &out) {
    const int n = in.n_cells;
    if (n <= 0) return false;
    // 输入维度校验
    if ((int)in.is_water.size()           != n) return false;
    if ((int)in.cover.size()              != n) return false;
    if ((int)in.ema_initialized.size()    != n) return false;
    if ((int)in.elevation.size()          != n) return false;
    if ((int)in.base_moisture.size()      != n) return false;
    if ((int)in.lat_norm.size()           != n) return false;
    if ((int)in.temp_baseline_year.size() != n) return false;
    if ((int)in.temp.size()               != n) return false;
    if ((int)in.temp_30d.size()           != n) return false;
    if ((int)in.temp_365d.size()          != n) return false;
    if ((int)in.thermal_energy.size()     != n) return false;
    if ((int)in.snowpack.size()           != n) return false;

    // ── scalars ──
    const float season_phase = (float)in.scalars.season_phase;
    const float axial_tilt_deg = (float)in.scalars.axial_tilt_deg;
    const float daylen_amp     = (float)in.scalars.day_length_gain;
    const float solar_gain     = (float)in.scalars.solar_gain;
    const float insol_amp      = (float)in.scalars.insol_amp;
    const float insol_gain     = (float)in.scalars.insol_gain;
    const float insol_amp_gain = insol_amp * insol_gain;
    const float land_continentality = 1.0f;  // compatibility field; pass-A helper ignores it
    const float moisture_relax = dc_clampf(in.scalars.runtime_moisture_base_relax_rate, 0.0f, 1.0f);
    const float moisture_vapor_w = dc_clampf(in.scalars.runtime_moisture_weather_vapor_weight, 0.0f, 1.0f);
    const float moisture_precip_w = dc_clampf(in.scalars.runtime_moisture_precip_weight, 0.0f, 2.5f);
    const float moisture_soil_w = dc_clampf(in.scalars.runtime_moisture_soil_weight, 0.0f, 2.5f);
    const float moisture_soil_dry_w = dc_clampf(in.scalars.runtime_moisture_soil_dry_weight, 0.0f, 2.5f);
    const float moisture_wb_w = dc_clampf(in.scalars.runtime_moisture_water_balance_weight, 0.0f, 2.5f);
    const float moisture_wb_dry_w = dc_clampf(in.scalars.runtime_moisture_water_balance_dry_weight, 0.0f, 2.5f);
    const float insol_dev_min  = (float)in.scalars.insol_dev_min;
    const float insol_dev_max  = (float)in.scalars.insol_dev_max;
    const float thermal_land   = (float)in.scalars.thermal_inertia_land;
    const float thermal_water  = (float)in.scalars.thermal_inertia_water;
    const float thermal_snow   = (float)in.scalars.thermal_inertia_snow;
    const float thermal_high   = (float)in.scalars.thermal_inertia_high_mountain;
    const float thermal_delta_cap = (float)in.scalars.thermal_daily_delta_cap;
    // 加速/跳日补偿：α 与 delta_cap 按经过天数积分（dt<=1 退化为原值）。
    float thermal_dt = (float)in.scalars.thermal_dt_days;
    if (thermal_dt < 1.0f) thermal_dt = 1.0f;
    else if (thermal_dt > 30.0f) thermal_dt = 30.0f;
    const float moisture_relax_eff = 1.0f - std::pow(1.0f - moisture_relax, thermal_dt);
    const float thermal_land_eff  = pk_thermal_alpha_eff(thermal_land,  thermal_dt);
    const float thermal_water_eff = pk_thermal_alpha_eff(thermal_water, thermal_dt);
    const float thermal_snow_eff  = pk_thermal_alpha_eff(thermal_snow,  thermal_dt);
    const float thermal_high_eff  = pk_thermal_alpha_eff(thermal_high,  thermal_dt);
    const float thermal_delta_cap_eff = thermal_delta_cap * thermal_dt;
    const float snowpack_cover_low  = (float)in.scalars.snowpack_cover_low;
    const float snowpack_cover_full = (float)in.scalars.snowpack_cover_full;
    const float sea_level = (float)in.scalars.sea_level;
    int days_per_year = in.scalars.days_per_year;
    if (days_per_year < 1) days_per_year = 1;
    else if (days_per_year > 3660) days_per_year = 3660;
    const float annual_ema_alpha = 1.0f / float(days_per_year);
    // [dt-aware EMA 2026-06-28] 与 sync run_climate_pass_a 对齐。原来这个修复只落在
    // sync 路径上，纯内核仍用固定 1/30、1/365——正是 plan 说的"生产改一次就要手动同步
    // worker"那笔债。加速档下 pass_a 每次推进 ~dt 天，固定日 alpha 会把 EMA 窗口拉长到
    // 30·dt / 365·dt 天，m30 跟不上季节循环、与 m365 一起趋近年均 → temp_anomaly 坍缩
    // 到 ≈0，DROUGHT/HEATWAVE 结构性不可达。
    //
    // dt <= 1 时刻意走"直接取基础 alpha"这一支而不是统一算 1-(1-a)^dt：后者在
    // dt == 1 时会引入一次 pow 往返的末位误差，非加速档就不再逐位一致。
    const float ema_alpha_30 = (thermal_dt <= 1.0f) ? (1.0f / 30.0f)
        : (1.0f - std::pow(1.0f - 1.0f / 30.0f, thermal_dt));
    const float ema_alpha_365 = (thermal_dt <= 1.0f) ? annual_ema_alpha
        : (1.0f - std::pow(1.0f - annual_ema_alpha, thermal_dt));

    constexpr uint8_t COVER_GLACIER = 2;

    // ── 输出 resize ──
    auto ensure_f32 = [n](std::vector<float> &v) {
        if ((int)v.size() != n) v.resize(n);
    };
    auto ensure_u8 = [n](std::vector<uint8_t> &v) {
        if ((int)v.size() != n) v.resize(n);
    };
    ensure_f32(out.moisture);
    ensure_f32(out.temp_baseline);
    ensure_f32(out.temp_season_offset);
    ensure_u8(out.ema_initialized);
    ensure_f32(out.temp_30d);
    ensure_f32(out.temp_365d);
    ensure_f32(out.temp_anomaly);
    ensure_f32(out.insolation_now);
    ensure_f32(out.insolation_dev);
    ensure_f32(out.day_length);
    ensure_f32(out.heat_input);
    ensure_f32(out.thermal_energy);
    ensure_f32(out.snowpack);
    ensure_f32(out.ocean_thermal_anomaly);
    ensure_f32(out.local_thermal_anomaly);

    // ── 输入指针 ──
    const uint8_t *IW = in.is_water.data();
    const uint8_t *COV = in.cover.data();
    const uint8_t *EI_IN = in.ema_initialized.data();
    const float *PE = in.elevation.data();
    const float *PBM = in.base_moisture.data();
    const float *PWEATHERV = ((int)in.weather_vapor.size() == n) ? in.weather_vapor.data() : nullptr;
    const float *PPRECIP = ((int)in.weather_precip.size() == n) ? in.weather_precip.data() : nullptr;
    const float *PSOIL = ((int)in.soil_moisture.size() == n) ? in.soil_moisture.data() : nullptr;
    const float *PWB = ((int)in.water_balance_30d.size() == n) ? in.water_balance_30d.data() : nullptr;
    const float *PLN = in.lat_norm.data();
    // Item 4：主线程预烘焙的年均日照 LUT（尺寸匹配才启用，否则 null → inline 回退）。
    const float *INSOL_MEAN_BAKED =
        ((int)in.insol_annual_mean.size() == n) ? in.insol_annual_mean.data() : nullptr;
    const float *PTY = in.temp_baseline_year.data();
    const float *PT_IN = in.temp.data();
    const float *P30_IN = in.temp_30d.data();
    const float *P365_IN = in.temp_365d.data();
    const float *PTH_IN = in.thermal_energy.data();
    const float *PSP_IN = in.snowpack.data();
    const float *PRAD_ADD = ((int)in.radiative_modifier_add.size() == n)
        ? in.radiative_modifier_add.data() : nullptr;
    const float *PRAD_FACTOR = ((int)in.radiative_modifier_factor.size() == n)
        ? in.radiative_modifier_factor.data() : nullptr;
    // [climate-zone-fix P2] 海洋性调温：per-cell maritime 因子 + 全局衰减比。缺省空/0→关闭。
    const float maritime_damp = (float)in.scalars.maritime_season_damp;
    const float *PMAR = ((int)in.maritime.size() == n) ? in.maritime.data() : nullptr;

    // ── 输出指针 ──
    float *PMOIST = out.moisture.data();
    float *PTB = out.temp_baseline.data();
    float *PSO = out.temp_season_offset.data();
    uint8_t *EI_OUT = out.ema_initialized.data();
    float *P30 = out.temp_30d.data();
    float *P365 = out.temp_365d.data();
    float *PA = out.temp_anomaly.data();
    float *PINSOL = out.insolation_now.data();
    float *PDEV = out.insolation_dev.data();
    float *PDAY = out.day_length.data();
    float *PHEAT = out.heat_input.data();
    float *PTHERM = out.thermal_energy.data();
    float *PSPOUT = out.snowpack.data();
    float *POANOM = out.ocean_thermal_anomaly.data();
    float *PLANOM = out.local_thermal_anomaly.data();

    // ── 主循环（1:1 镜像 sync run_range body） ──
    for (int i = 0; i < n; ++i) {
        const float ny = PLN[i];
        const float temp_year_lat = PTY[i];
        const float elevation = PE[i];
        const bool is_water = IW[i] != 0;

        // (a) dev_today + insolation
        const float ny_clamped = dc_clamp01f(ny);
        const float insol_now = dc_insolation_now(ny_clamped, season_phase, axial_tilt_deg, daylen_amp);
        // perf (Item 4, 2026-07-05): insol_mean 是年均、season-无关。主线程 kick 时已把
        // dc_insolation_annual_mean(dc_clamp01f(ny),...) 预烘焙进 in.insol_annual_mean（持锁、
        // 主线程算，避免 worker 触 member 缓存的 data race）。命中即读 → bit-equal；字段缺失/
        // 尺寸不符时回退 inline 重算（旧行为，向后兼容旧调用方）。
        const float insol_mean = INSOL_MEAN_BAKED
            ? INSOL_MEAN_BAKED[i]
            : dc_insolation_annual_mean(ny_clamped, axial_tilt_deg, daylen_amp);
        float dev_today = dc_insolation_season_dev(ny_clamped, insol_now, insol_mean);
        if (dev_today < insol_dev_min) dev_today = insol_dev_min;
        else if (dev_today > insol_dev_max) dev_today = insol_dev_max;
        const float day_length = dc_day_length_norm(ny_clamped, season_phase, axial_tilt_deg);
        const float heat_input = dc_clamp01f(insol_now * solar_gain);

        // (b) moisture. Geographic base stays the annual mean. Insolation
        // deviation is zero-mean over the year, so it supplies the seasonal
        // envelope that a flat precip field cannot: land dries in the warm
        // season (evaporative demand), ocean specific humidity rises with it.
        // Weather is an anomaly around a light rain-rate reference, capped so
        // a wet spell moves wetness by tenths without pinning the cell at 1.
        float moisture_now;
        float bm = PBM[i];
        if (bm > 1.0f) bm = 1.0f;
        else if (bm < 0.0f) bm = 0.0f;
        const float lat_w = pk_moisture_lat_weight(ny_clamped);
        float season_amp = is_water ? (0.08f + 0.50f * lat_w) : (0.12f + 0.36f * lat_w);
        if (!is_water && PMAR != nullptr && maritime_damp > 0.0f) {
            float coast = 1.0f - maritime_damp * PMAR[i];
            if (coast < 0.25f) coast = 0.25f;
            season_amp *= coast;
        }
        const float season_term = (is_water ? season_amp : -season_amp) * dev_today;
        float synoptic = 0.0f;
        if (PWEATHERV != nullptr && moisture_vapor_w > 0.0f) {
            const float vapor = dc_clampf(PWEATHERV[i], 0.0f, 1.0f);
            synoptic += (vapor - bm * 0.15f) * moisture_vapor_w;
        }
        if (PPRECIP != nullptr && moisture_precip_w > 0.0f) {
            const float precip = dc_clampf(PPRECIP[i], 0.0f, 1.0f);
            synoptic += (precip - 0.04f) * moisture_precip_w * 3.5f;
        }
        const float synoptic_cap = is_water ? 0.12f : 0.28f;
        if (synoptic > synoptic_cap) synoptic = synoptic_cap;
        else if (synoptic < -synoptic_cap) synoptic = -synoptic_cap;
        float moisture_target = bm + season_term + synoptic;
        if (!is_water) {
            if (PSOIL != nullptr) {
                const float soil = dc_clampf(PSOIL[i], -0.5f, 0.5f);
                moisture_target += pk_signed_hydrology_contribution(
                    soil, moisture_soil_w, moisture_soil_dry_w);
            }
            if (PWB != nullptr) {
                const float wb = dc_clampf(PWB[i], -1.0f, 1.0f);
                moisture_target += pk_signed_hydrology_contribution(
                    wb, moisture_wb_w, moisture_wb_dry_w);
            }
        }
        moisture_target = dc_clampf(moisture_target, 0.0f, 1.0f);
        float previous = moisture_target;
        if ((int)in.moisture.size() == n) {
            const float raw = in.moisture[size_t(i)];
            if (std::isfinite(raw) && raw >= 0.0f && raw <= 1.0f) previous = raw;
        }
        moisture_now = previous + (moisture_target - previous) * moisture_relax_eff;
        if (moisture_now > 1.0f) moisture_now = 1.0f;
        else if (moisture_now < 0.0f) moisture_now = 0.0f;

        // (c) temperature
        float temp_year = temp_year_lat - float(pk_alt_penalty(double(elevation), double(sea_level)));
        if (temp_year < 0.0f) temp_year = 0.0f;
        else if (temp_year > 1.0f) temp_year = 1.0f;
        // 物理化（2026-06-16）：季节项按吸收短波因子缩放（持久冰封→低吸收）。
        // 用【年均温度 P365_IN[i]】（上一步 temp_365d）作冰封代理，避免夏季融化正反馈失控。
        float season_offset = pk_season_offset_continental(insol_amp_gain, is_water, P365_IN[i], dev_today, land_continentality);
        // [climate-zone-fix P2] 沿海陆地海洋性调温：按距海衰减缩小季节振幅（冬暖夏凉），
        // 让温带海洋性(Cfb)在中纬沿海涌现。water/内陆(maritime≈0)不受影响。
        if (!is_water && PMAR != nullptr && maritime_damp > 0.0f) {
            season_offset *= (1.0f - maritime_damp * PMAR[i]);
        }
        float radiative_target = temp_year + season_offset;
        if (PRAD_ADD != nullptr) radiative_target += PRAD_ADD[i];
        if (PRAD_FACTOR != nullptr) radiative_target *= PRAD_FACTOR[i];
        if (radiative_target < 0.0f) radiative_target = 0.0f;
        else if (radiative_target > 1.0f) radiative_target = 1.0f;

        // (d) thermal inertia
        const float current_temp = PT_IN[i];
        float prev_energy = PTH_IN[i];
        if (EI_IN[i] == 0) {
            prev_energy = current_temp;
        }
        const float prev_temp = prev_energy;
        float alpha = thermal_land_eff;
        if (is_water) alpha = thermal_water_eff;
        else if (COV[i] == COVER_GLACIER) alpha = thermal_snow_eff;
        else if (PSP_IN[i] > snowpack_cover_low) alpha = thermal_snow_eff;
        else if (elevation > 0.70f) alpha = thermal_high_eff;
        const float heat_next = prev_energy + (radiative_target - prev_energy) * alpha;
        float temp_delta = heat_next - prev_temp;
        if (temp_delta > thermal_delta_cap_eff) temp_delta = thermal_delta_cap_eff;
        else if (temp_delta < -thermal_delta_cap_eff) temp_delta = -thermal_delta_cap_eff;
        float temp_now = prev_temp + temp_delta;
        if (temp_now < 0.0f) temp_now = 0.0f;
        else if (temp_now > 1.0f) temp_now = 1.0f;
        PTHERM[i] = heat_next;

        // (e) snowpack maintenance. Runtime visual snow cover is authored by
// weather distribute; climate only keeps physical snowpack for thermal
        // inertia and pass-b albedo.
        // 注意：sync 路径中 psnowpack[i] 可能被改写（GLACIER min=0.80）。这里
        // 我们使用 out.snowpack（写回值），先 default 复制 in，再按需 clamp。
        float sp = PSP_IN[i];
        if (!is_water) {
            if (COV[i] == COVER_GLACIER && sp < 0.80f) {
                sp = 0.80f;
            }
        } else {
            sp = 0.0f;
        }
        PSPOUT[i] = sp;

        // (e) write outputs（pass_a 不再写 cell_temp，由 wind_surface 末端合成；
        // 这里 PMOIST/PTB/PSO/PINSOL/PDEV/PDAY/PHEAT 写入）
        PTB[i] = temp_now;
        POANOM[i] = 0.0f;     // pass_a 末尾清 0，开启新一日累加
        PLANOM[i] = 0.0f;
        PMOIST[i] = moisture_now;
        PSO[i] = season_offset;
        PINSOL[i] = insol_now;
        PDEV[i] = dev_today;
        PDAY[i] = day_length;
        PHEAT[i] = heat_input;

        // (f) EMA
        float m30, m365;
        if (EI_IN[i] == 0) {
            m30 = temp_now;
            m365 = temp_now;
            EI_OUT[i] = 1;
        } else {
            m30 = P30_IN[i] + (temp_now - P30_IN[i]) * ema_alpha_30;
            m365 = P365_IN[i] + (temp_now - P365_IN[i]) * ema_alpha_365;
            EI_OUT[i] = EI_IN[i];
        }
        P30[i] = m30;
        P365[i] = m365;
        PA[i] = m30 - m365;
    }
    return true;
}

// pass_b pure kernel — 移植自 DCWorldExt::run_climate_pass_b（world_ext.cpp:5256）。
// 算法逐行 1:1 镜像 sync 路径主循环（line 5399-5546）+ 海冰反照率尾循环（line 5552-5560）：
//   - 5 段决定：albedo / coastal heat leak / landform diurnal / evap / rain_shadow
//   - 写出 cell_local_thermal_anomaly（累加，clamp ±0.08）和 cell_moisture
//   - 海冰反照率尾循环只对水域 cell 写 LANOM
//
// 输入：in.{is_water, landform, vegetation, snow_cover, elevation, lat_norm,
//           pos_x, pos_y, insolation_dev, temp（snapshot 入参）, moisture（in/out）,
//           local_thermal_anomaly（in/out）, temp_transport_anomaly, sea_ice_frac} +
//      static knobs.{neighbor_indices, foliage_table} + scalars
// 输出：out.{moisture, local_thermal_anomaly}
//
// 注意：算法本体严格 1:1，与 sync 路径在同一 input 下输出 bit-equal。
// 海冰反照率尾循环（sync line 5548-5560）也实装。
// pass_b 的单 land cell 体。生产的 scalar / _simd / _thread 与 worker 四条路径
// 现在都落到这里。is_water 分支保留原样：land cell 走的就是每个 guard 都命中的
// 那条路，所以这份 body 与被替换掉的三份逐字一致。
static inline void pass_b_land_cell(const ClimatePassBKnobs &knobs,
                                   const ClimatePassBLanes &lanes,
                                   int i) {
    // ── 前言：把 knobs/lanes 摊回生产里的局部名，主循环得以原样保留 ──
    const auto winter_boost = knobs.winter_boost;
    const auto snow_cool = knobs.snow_cool;
    const auto veg_cool = knobs.veg_cool;
    const auto diurnal_amp = knobs.diurnal_amp;
    const auto evap_gain = knobs.evap_gain;
    const auto rs_threshold = knobs.rs_threshold;
    const auto rs_factor = knobs.rs_factor;
    const auto rs_lookback = knobs.rs_lookback;
    const auto wrap_period_x = knobs.wrap_period_x;
    const auto t_freeze = knobs.t_freeze;
    const auto coupling_gain = knobs.coupling_gain;
    const auto coast_leak = knobs.coast_leak;
    const auto sea_ice_albedo_cooling = knobs.sea_ice_albedo_cooling;
    const auto season_phase = knobs.season_phase;
    const auto snowpack_cover_low = knobs.snowpack_cover_low;
    const auto snowpack_cover_full = knobs.snowpack_cover_full;
    const auto foliage_size = knobs.foliage_size;
    const auto n_cells = knobs.n_cells;
    const auto TS = lanes.temp_snapshot;
    const auto SNOWPACK = lanes.snowpack;
    const auto ELEV = lanes.elevation;
    const auto LAT = lanes.lat_norm;
    const auto POSX = lanes.pos_x;
    const auto POSY = lanes.pos_y;
    const auto INSOL_DEV = lanes.insolation_dev;
    const auto TTA = lanes.temp_transport_anomaly;
    const auto IW = lanes.is_water;
    const auto LF = lanes.landform;
    const auto VG = lanes.vegetation;
    const auto SIF_PB = lanes.sea_ice_frac;
    const auto NB = lanes.neighbor_indices;
    const auto FOL = lanes.foliage_table;
    const auto LANOM = lanes.local_thermal_anomaly;
    const auto M = lanes.moisture;

    // LandformType.LF: LOWLAND=5, HILL=6, MOUNTAIN=7, PEAK=8, DELTA=9,
    //                  SALT_FLAT=11 (per landform_type.gd:9-23)
    constexpr uint8_t LF_LOWLAND   = 5;
    constexpr uint8_t LF_MOUNTAIN  = 7;
    constexpr uint8_t LF_PEAK      = 8;
    constexpr uint8_t LF_DELTA     = 9;
    constexpr uint8_t LF_SALT_FLAT = 11;

        const bool is_water = IW[i] != 0;
        const float temp_now     = TS[i];
        const float moisture_now = M[i];
        const float snow_cover   = pk_snowpack_cover_for_albedo(SNOWPACK[i], snowpack_cover_low, snowpack_cover_full);

        float d_albedo      = 0.0f;
        float d_coastal     = 0.0f;
        float d_landform    = 0.0f;
        float d_evap        = 0.0f;
        float d_rain_shadow = 1.0f;

        // (line 4413-4416) ① albedo (land only)
        if (!is_water) {
            d_albedo = -snow_cool * snow_cover;
            const uint8_t veg_id = VG[i];
            const float foliage = (veg_id < foliage_size) ? FOL[veg_id] : 0.0f;
            d_albedo -= veg_cool * foliage;
        }

        // (line 4419-4431) ② coastal heat leak (land only, using snapshot
        //                   of cells[ni].temperature_transport_anomaly)
        if (!is_water) {
            float sum_anomaly = 0.0f;
            int   n_water     = 0;
            const int base = i * 6;
            for (int d = 0; d < 6; ++d) {
                const int32_t ni = NB[base + d];
                if (ni < 0) continue;
                if (IW[ni] != 0) {
                    sum_anomaly += TTA[ni];
                    n_water += 1;
                }
            }
            if (n_water > 0) {
                d_coastal = coast_leak * (sum_anomaly / float(n_water)) * winter_boost;
            }
        }

        // (line 4434-4440) ③ landform diurnal (land only)
        if (!is_water) {
            const uint8_t lf = LF[i];
            const float solar_factor = std::clamp(INSOL_DEV[i], -1.0f, 1.0f);
            if (lf == LF_LOWLAND || lf == LF_SALT_FLAT || lf == LF_DELTA) {
                d_landform = diurnal_amp * solar_factor;
            } else if (lf == LF_PEAK || lf == LF_MOUNTAIN) {
                d_landform = -diurnal_amp * 0.5f * std::max(0.0f, -solar_factor);
            }
        }

        // (line 4442-4445) A 修复（2026-06）：原 `T[i] = clamp(temp_now + d_*)`
        // 改为累加到 cell_local_thermal_anomaly。temp_final 仍计算用于下面 evap
        // 阶段的 t_eff（保持 GDScript bit-equal 的语义：evap 用 "本日 d_* 注入后" 的 t）。
        float local_anom_contrib = d_albedo + d_coastal + d_landform;
        if (local_anom_contrib < -0.08f) local_anom_contrib = -0.08f;
        else if (local_anom_contrib > 0.08f) local_anom_contrib = 0.08f;
        LANOM[i] = LANOM[i] + local_anom_contrib;
        if (LANOM[i] < -0.08f) LANOM[i] = -0.08f;
        else if (LANOM[i] > 0.08f) LANOM[i] = 0.08f;
        float temp_final = temp_now + local_anom_contrib;
        if (temp_final < 0.0f) temp_final = 0.0f;
        else if (temp_final > 1.0f) temp_final = 1.0f;

        // (line 4456-4481) ④ evap (land only)
        if (!is_water) {
            const float t_eff = temp_final + TTA[i];
            float water_neighbor_w = 0.0f;
            float sum_water_anomaly = 0.0f;
            const int bo = i * 6;
            for (int d = 0; d < 6; ++d) {
                const int32_t ni = NB[bo + d];
                if (ni < 0) continue;
                if (IW[ni] != 0) {
                    water_neighbor_w += 1.0f;
                    sum_water_anomaly += TTA[ni];
                }
            }
            float avg_water_anomaly = 0.0f;
            if (water_neighbor_w > 0.0f) {
                avg_water_anomaly = sum_water_anomaly / water_neighbor_w;
            }
            float nb_w_norm = water_neighbor_w / 6.0f;
            if (nb_w_norm > 1.0f) nb_w_norm = 1.0f;
            if (t_eff > t_freeze && nb_w_norm > 0.0f) {
                d_evap = evap_gain * (t_eff - t_freeze) * nb_w_norm;
                if (coupling_gain > 0.0f && std::fabs(avg_water_anomaly) > 0.001f) {
                    float evap_mul = 1.0f + coupling_gain * avg_water_anomaly;
                    if (evap_mul < 0.0f) evap_mul = 0.0f;
                    else if (evap_mul > 2.0f) evap_mul = 2.0f;
                    d_evap *= evap_mul;
                }
            }
            if (avg_water_anomaly < -0.01f && nb_w_norm > 0.0f && coupling_gain > 0.0f) {
                d_evap += -evap_gain * (-avg_water_anomaly) * nb_w_norm * coupling_gain * 0.5f;
            }
        }

        // (line 4484-4518) ⑤ rain shadow (land only, gated by rs_lookback>0)
        if (!is_water && rs_lookback > 0) {
            const double ny = double(LAT[i]);
            // jitter = sin(q*0.31 + r*0.47) * 0.05；schema 没存 q/r。本实现把
            // jitter 取 0（jitter 仅 ±0.05 ny，对 wind_at 输出方向影响极小，
            // bit-equal 容差 1e-4 内可容忍。后续 PR 加 cell_q/cell_r schema 后
            // 可补 jitter）。
            double w_dx = 0.0, w_dy = 0.0;
            wind_belt_at(ny, season_phase, &w_dx, &w_dy);
            const double wlen2 = w_dx * w_dx + w_dy * w_dy;
            if (wlen2 > 1e-6) {
                float max_upwind_h = ELEV[i];
                int probe_idx = i;
                for (int step = 0; step < rs_lookback; ++step) {
                    int   best_idx = -1;
                    double best_dot = 0.1;
                    const float pwx = POSX[probe_idx];
                    const float pwy = POSY[probe_idx];
                    const int pbase = probe_idx * 6;
                    for (int d3 = 0; d3 < 6; ++d3) {
                        const int32_t ni3 = NB[pbase + d3];
                        if (ni3 < 0) continue;
                        const double dx = pk_wrap_min_image_dx(
                            double(pwx) - double(POSX[ni3]), wrap_period_x);
                        const double dy = double(pwy) - double(POSY[ni3]);
                        const double len2 = dx * dx + dy * dy;
                        if (len2 < 1e-6) continue;
                        const double inv_len = 1.0 / std::sqrt(len2);
                        const double dotv = (dx * w_dx + dy * w_dy) * inv_len;
                        if (dotv > best_dot) {
                            best_dot = dotv;
                            best_idx = ni3;
                        }
                    }
                    if (best_idx < 0) break;
                    probe_idx = best_idx;
                    if (ELEV[probe_idx] > max_upwind_h) {
                        max_upwind_h = ELEV[probe_idx];
                    }
                }
                if (max_upwind_h - ELEV[i] >= rs_threshold) {
                    d_rain_shadow = rs_factor;
                }
            }
        }

        // (line 4520-4523) write moisture
        float moisture_final = (moisture_now + d_evap) * d_rain_shadow;
        if (moisture_final < 0.0f) moisture_final = 0.0f;
        else if (moisture_final > 1.0f) moisture_final = 1.0f;
        M[i] = moisture_final;
}

void climate_pass_b_land_range_pure(const ClimatePassBKnobs &knobs,
                                    const ClimatePassBLanes &lanes,
                                    const int *land_idx,
                                    int begin, int end) {
    if (land_idx == nullptr) return;
    for (int k = begin; k < end; ++k) {
        pass_b_land_cell(knobs, lanes, land_idx[k]);
    }
}

void climate_pass_b_sea_ice_tail_pure(const ClimatePassBKnobs &knobs,
                                      const ClimatePassBLanes &lanes) {
    const auto n_cells = knobs.n_cells;
    const auto sea_ice_albedo_cooling = knobs.sea_ice_albedo_cooling;
    const auto IW = lanes.is_water;
    const auto SIF_PB = lanes.sea_ice_frac;
    const auto LANOM = lanes.local_thermal_anomaly;

    // climate-loop-closure Phase 4.1：海冰反照率→温度反馈尾循环（仅水域）。
    // A 修复（2026-06）：水域 cell sea-ice 反照率冷却也作为 local anomaly 贡献，
    // 不再直接改写 cell_temp。LANOM 已被 pass_a 末尾清零，pass_b 主循环对 water cell
    // 也不写（与原 scalar 一致），所以此处直接累加为水域唯一的 LANOM 贡献。
    if (sea_ice_albedo_cooling > 0.0f && SIF_PB != nullptr) {
        for (int i = 0; i < n_cells; ++i) {
            if (IW[i] == 0) continue;
            float water_local = LANOM[i] - sea_ice_albedo_cooling * SIF_PB[i];
            if (water_local < -0.08f) water_local = -0.08f;
            else if (water_local > 0.08f) water_local = 0.08f;
            LANOM[i] = water_local;
        }
    }
}

void climate_pass_b_pure(const ClimatePassBKnobs &knobs,
                         const ClimatePassBLanes &lanes) {
    if (knobs.n_cells <= 0) return;
    // 生产热路径（_thread）预筛 land_idx 后只迭代陆地；这里等价地跳过水域，
    // 保证 dense 驱动与分块驱动逐位一致。
    for (int i = 0; i < knobs.n_cells; ++i) {
        if (lanes.is_water[i] != 0) continue;
        pass_b_land_cell(knobs, lanes, i);
    }
    climate_pass_b_sea_ice_tail_pure(knobs, lanes);
}

// wf_wind_speed_norm 的原地展开。world_ext_internal.h 拖进整个 Godot 头链，纯内核
// 这一侧不能包含它，所以这里复制一份——三行且无分支歧义，比让两边各写一遍安全。
static inline float wind_speed_norm(float dir_x, float dir_y, float speed) {
    if (speed > 0.0001f) return speed;
    const float len2 = dir_x * dir_x + dir_y * dir_y;
    return (len2 > 0.0001f) ? std::sqrt(len2) : 0.0f;
}

void wind_air_pure(const WindAirKnobs &knobs, const WindAirLanes &lanes,
                   int start_idx, int end_idx) {
    const int   advect_steps  = knobs.advect_steps;
    const float heat_mix      = knobs.heat_mix;
    const float wrap_period_x = knobs.wrap_period_x;

    const float   *WX   = lanes.wind_x;
    const float   *WY   = lanes.wind_y;
    const float   *WSP  = lanes.wind_speed;
    const float   *POSX = lanes.pos_x;
    const float   *POSY = lanes.pos_y;
    const float   *TB   = lanes.temp_before;
    const float   *BL   = lanes.baseline;
    const int32_t *NB   = lanes.neighbor_indices;
    float         *A    = lanes.air_anomaly;

    // 轨迹表要么整对可用，要么整对不用。只给一半时按未命中处理，而不是解引用
    // 空指针——生产的资格判定也是两个字段一起过的。
    const int32_t *TRAJ_IDX =
        (lanes.traj_idx != nullptr && lanes.traj_w != nullptr) ? lanes.traj_idx : nullptr;
    const float *TRAJ_W = TRAJ_IDX != nullptr ? lanes.traj_w : nullptr;

    for (int i = start_idx; i < end_idx; ++i) {
        A[i] = 0.0f;

        const float wind_x = WX[i];
        const float wind_y = WY[i];
        const float wind_len2 = wind_x * wind_x + wind_y * wind_y;
        if (wind_len2 < 1e-6f || advect_steps == 0) {
            continue;
        }

        const float inv_wind_len = 1.0f / std::sqrt(wind_len2);
        const float up_dx = -wind_x * inv_wind_len;
        const float up_dy = -wind_y * inv_wind_len;

        int upstream_idx = i;
        for (int step = 0; step < advect_steps; ++step) {
            int best_idx = -1;
            float best_dot = 0.1f;
            const float swx = POSX[upstream_idx];
            const float swy = POSY[upstream_idx];
            const int ub = upstream_idx * 6;
            for (int d = 0; d < 6; ++d) {
                const int32_t ni = NB[ub + d];
                if (ni < 0) continue;
                const float dx = pk_wrap_min_image_dx(POSX[ni] - swx, wrap_period_x);
                const float dy = POSY[ni] - swy;
                const float len2 = dx * dx + dy * dy;
                if (len2 < 1e-6f) continue;
                const float inv_len = 1.0f / std::sqrt(len2);
                const float dot_v = (dx * up_dx + dy * up_dy) * inv_len;
                if (dot_v > best_dot) {
                    best_dot = dot_v;
                    best_idx = ni;
                }
            }
            if (best_idx < 0) break;
            upstream_idx = best_idx;
        }

        const float temp_self_raw = TB[i];
        const float temp_self = std::isfinite(temp_self_raw) ? temp_self_raw : BL[i];
        // 轨迹表命中 → 回溯三角形三点插值上游温度（每顶点独立 finite 守门，与
        // 离散分支的单点守门同语义）；未命中 → 离散上游。
        float temp_up;
        if (TRAJ_IDX != nullptr) {
            const int t3 = i * 3;
            const int j0 = TRAJ_IDX[t3], j1 = TRAJ_IDX[t3 + 1], j2 = TRAJ_IDX[t3 + 2];
            const float t0r = TB[j0], t1r = TB[j1], t2r = TB[j2];
            const float t0v = std::isfinite(t0r) ? t0r : BL[j0];
            const float t1v = std::isfinite(t1r) ? t1r : BL[j1];
            const float t2v = std::isfinite(t2r) ? t2r : BL[j2];
            temp_up = TRAJ_W[t3] * t0v + TRAJ_W[t3 + 1] * t1v + TRAJ_W[t3 + 2] * t2v;
        } else {
            const float temp_up_raw = TB[upstream_idx];
            temp_up = std::isfinite(temp_up_raw) ? temp_up_raw : BL[upstream_idx];
        }
        float speed_mix = wind_speed_norm(wind_x, wind_y, WSP[i]) / 1.2f;
        if (speed_mix < 0.25f) speed_mix = 0.25f;
        else if (speed_mix > 1.35f) speed_mix = 1.35f;
        const float temp_mixed_raw = temp_self + (temp_up - temp_self) * heat_mix * speed_mix;
        A[i] = temp_mixed_raw - BL[i];
    }
}

// PK_WS_PROBE_CELL 一次性解析；未设或非法时返回 -1（探针整条不触发）。
static int pk_ws_probe_cell() {
    static const int cached = []() {
        const char *v = pk::runtime_switch_value(pk::RuntimeSwitch::PK_WS_PROBE_CELL);
        if (v == nullptr || *v == 0) return -1;
        return std::atoi(v);
    }();
    return cached;
}

void wind_surface_pure(const WindSurfaceKnobs &knobs,
                       const WindSurfaceLanes &lanes,
                       int start_idx, int end_idx) {
    const float air_leak            = knobs.air_leak;
    const float wrap_period_x       = knobs.wrap_period_x;
    const float cold_transport_form = knobs.cold_transport_form;
    const float cold_transport_melt = knobs.cold_transport_melt;

    const float   *WX    = lanes.wind_x;
    const float   *WY    = lanes.wind_y;
    const float   *WSP   = lanes.wind_speed;
    const float   *POSX  = lanes.pos_x;
    const float   *POSY  = lanes.pos_y;
    const float   *AIN   = lanes.air_anomaly_in;
    const uint8_t *IW    = lanes.is_water;
    const int32_t *NB    = lanes.neighbor_indices;
    const float   *FBL   = lanes.fallback_baseline;
    const float   *BL_RUNTIME = lanes.baseline;
    const float   *OANOM = lanes.ocean_anomaly;
    const float   *LANOM = lanes.local_anomaly;
    float         *AOUT  = lanes.air_anomaly_out;
    float         *T     = lanes.temp_out;

    for (int i = start_idx; i < end_idx; ++i) {
        const float swx = POSX[i];
        const float swy = POSY[i];
        float weighted_sum = 0.0f;
        float weight_total = 0.0f;
        const int b = i * 6;
        for (int d = 0; d < 6; ++d) {
            const int32_t ni = NB[b + d];
            if (ni < 0) continue;
            const float wind_x = WX[ni];
            const float wind_y = WY[ni];
            if (wind_x * wind_x + wind_y * wind_y < 1e-6f) continue;
            const float dx = pk_wrap_min_image_dx(swx - POSX[ni], wrap_period_x);
            const float dy = swy - POSY[ni];
            const float len2 = dx * dx + dy * dy;
            if (len2 < 1e-6f) continue;
            const float inv_len = 1.0f / std::sqrt(len2);
            const float weight = (dx * wind_x + dy * wind_y) * inv_len;
            if (weight <= 0.0f) continue;
            float speed_w = wind_speed_norm(wind_x, wind_y, WSP[ni]) / 1.2f;
            if (speed_w < 0.20f) speed_w = 0.20f;
            else if (speed_w > 1.35f) speed_w = 1.35f;
            const float adv_weight = weight * speed_w;
            weighted_sum += AIN[ni] * adv_weight;
            weight_total += adv_weight;
        }

        // 风致 air-mass 平流：把邻接 air-mass anomaly 加权平均到本 cell。
        float anomaly_in = 0.0f;
        if (weight_total > 0.0f) {
            anomaly_in = (weighted_sum / weight_total) * air_leak;
        }
        // air anomaly 是单 round 的瞬时 deviation（不持久），OVERWRITE 而非累加。
        float air_final = anomaly_in;
        if (air_final < -0.08f) air_final = -0.08f;
        else if (air_final > 0.08f) air_final = 0.08f;
        AOUT[i] = air_final;

        // 合成 cell_temp：ocean 与 air 都是横向热输运，共享同一 ±0.08 预算；
        // 对接近结冰线的水格，正向输运先被潜热/成冰门控吸收，避免无冰边缘水面
        // 被固定抬高到 melt 阈值以上而无法重新结冰。
        float base = BL_RUNTIME[i];
        // 极夜/结冰 baseline 恰好等于 0.0 是合法值，只有非有限值才回退静态基线。
        if (!std::isfinite(base)) base = FBL[i];
        float transport_anom = (OANOM != nullptr ? OANOM[i] : 0.0f) + air_final;
        if (IW[i] != 0 && transport_anom > 0.0f) {
            // wf_smoothstep 的原地展开（span 由调用方保证非零）。
            float t = (base - cold_transport_form) /
                      (cold_transport_melt - cold_transport_form);
            if (t < 0.0f) t = 0.0f;
            else if (t > 1.0f) t = 1.0f;
            transport_anom *= t * t * (3.0f - 2.0f * t);
        }
        if (transport_anom < -0.08f) transport_anom = -0.08f;
        else if (transport_anom > 0.08f) transport_anom = 0.08f;
        float total_anom = transport_anom + (LANOM != nullptr ? LANOM[i] : 0.0f);
        if (total_anom < -0.15f) total_anom = -0.15f;
        else if (total_anom > 0.15f) total_anom = 0.15f;
        float total = base + total_anom;
        if (total < 0.0f) total = 0.0f;
        else if (total > 1.0f) total = 1.0f;
        T[i] = total;

        // 对拍定位用：PK_WS_PROBE_CELL=<idx> 时打印这一格的温度分量。生产与 worker
        // 走同一份内核，两边输出并列即可指出是哪条 lane 先偏。默认不设 → 零开销。
        if (i == pk_ws_probe_cell()) {
            std::fprintf(stderr,
                "[ws-probe] cell=%d base=%.9g oanom=%.9g ain=%.9g lanom=%.9g "
                "transport=%.9g total_anom=%.9g T=%.9g wind=(%.6g,%.6g,%.6g)\n",
                i, double(base), double(OANOM != nullptr ? OANOM[i] : 0.0f),
                double(air_final), double(LANOM != nullptr ? LANOM[i] : 0.0f),
                double(transport_anom), double(total_anom), double(total),
                double(WX[i]), double(WY[i]), double(WSP[i]));
        }
    }
}

bool _async_pass_b_kernel_pure(const ClimateInputBuf &in,
                                      const ClimateRoundStaticKnobs &knobs,
                                      ClimateOutputBuf &out) {
    const int n = in.n_cells;
    if (n <= 0) return false;
    if ((int)in.is_water.size()       != n) return false;
    if ((int)in.landform.size()       != n) return false;
    if ((int)in.vegetation.size()     != n) return false;
    if ((int)in.snowpack.size()       != n) return false;
    if ((int)in.elevation.size()      != n) return false;
    if ((int)in.lat_norm.size()       != n) return false;
    if ((int)in.pos_x.size()          != n) return false;
    if ((int)in.pos_y.size()          != n) return false;
    if ((int)in.insolation_dev.size() != n) return false;
    if ((int)in.temp.size()           != n) return false;
    if ((int)in.moisture.size()       != n) return false;
    if ((int)in.local_thermal_anomaly.size() != n) return false;
    if ((int)in.temp_transport_anomaly.size() != n) return false;
    if ((int)knobs.neighbor_indices.size() < n * 6) return false;
    const int foliage_size = (int)knobs.foliage_table.size();
    if (foliage_size <= 0) return false;
    // sea_ice_frac 可选；尾循环要求 size == n_cells，否则跳过
    const bool sif_valid = ((int)in.sea_ice_frac.size() == n);

    // S3 P3：worker 与生产吃同一份 climate_pass_b_pure。
    // 这里原本是一份逐行抄来的平行实现，唯一的差异是多了一个 cover == GLACIER
    // 时把 snow_cover 抬到 0.80 的钳位——生产 pass_b 并没有这一步，那条钳位让
    // moisture 在分叉矩阵里一直挂着 0.78 的最大差。合成一份内核后差异不复存在。
    ClimatePassBKnobs pbk;
    pbk.n_cells                = n;
    pbk.winter_boost           = in.scalars.pb_winter_boost;
    pbk.snow_cool              = in.scalars.pb_snow_cool;
    pbk.veg_cool               = in.scalars.pb_veg_cool;
    pbk.diurnal_amp            = in.scalars.pb_diurnal_amp;
    pbk.evap_gain              = in.scalars.pb_evap_gain;
    pbk.rs_threshold           = in.scalars.pb_rs_threshold;
    pbk.rs_factor              = in.scalars.pb_rs_factor;
    pbk.rs_lookback            = in.scalars.pb_rs_lookback;
    pbk.wrap_period_x          = double(in.scalars.wrap_period_x);
    pbk.t_freeze               = in.scalars.pb_t_freeze;
    pbk.coupling_gain          = in.scalars.pb_coupling_gain;
    pbk.coast_leak             = in.scalars.pb_coast_leak;
    pbk.sea_ice_albedo_cooling = in.scalars.pb_sea_ice_albedo_cooling;
    pbk.season_phase           = in.scalars.season_phase;
    pbk.snowpack_cover_low     = float(in.scalars.snowpack_cover_low);
    pbk.snowpack_cover_full    = float(in.scalars.snowpack_cover_full);
    pbk.foliage_size           = foliage_size;

    // LANOM 与 moisture 都是 in/out：生产路径直接在 slot 上原位累加，等价于
    // in == out 别名。先 copy 进 out，再让内核在 out 上原位改。
    auto ensure_f32 = [n](std::vector<float> &v) {
        if ((int)v.size() != n) v.resize(n);
    };
    ensure_f32(out.moisture);
    ensure_f32(out.local_thermal_anomaly);
    std::memcpy(out.local_thermal_anomaly.data(),
                in.local_thermal_anomaly.data(), n * sizeof(float));
    std::memcpy(out.moisture.data(), in.moisture.data(), n * sizeof(float));

    ClimatePassBLanes pbl;
    pbl.temp_snapshot          = in.temp.data();   // pass_b 不写 temp
    pbl.snowpack               = in.snowpack.data();
    pbl.elevation              = in.elevation.data();
    pbl.lat_norm               = in.lat_norm.data();
    pbl.pos_x                  = in.pos_x.data();
    pbl.pos_y                  = in.pos_y.data();
    pbl.insolation_dev         = in.insolation_dev.data();
    pbl.temp_transport_anomaly = in.temp_transport_anomaly.data();
    pbl.is_water               = in.is_water.data();
    pbl.landform               = in.landform.data();
    pbl.vegetation             = in.vegetation.data();
    pbl.sea_ice_frac           = sif_valid ? in.sea_ice_frac.data() : nullptr;
    pbl.neighbor_indices       = knobs.neighbor_indices.data();
    pbl.foliage_table          = knobs.foliage_table.data();
    pbl.local_thermal_anomaly  = out.local_thermal_anomaly.data();
    pbl.moisture               = out.moisture.data();

    climate_pass_b_pure(pbk, pbl);
    return true;
}

// ocean_water pure kernel — 移植自 DCWorldExt::run_ocean_water_pass（world_ext.cpp:4558）。
// 算法逐行 1:1 镜像 sync 路径（line 4655-4708）：
//   - 仅 water cell：沿 -current 方向回溯 advect_steps 步，找最对齐邻居
//   - temp_mixed = lerp(temp_self, temp_up, heat_mix)，clamp [0,1]
//   - 写 ocean_thermal_anomaly slot = clamp(temp_mixed - baseline, ±0.08)
//   - 用 dc_stabilize_tta / dc_decay_tta 更新 work.ocean_tta_inout（per-cell TTA）
//
// 输入：in.{is_water, pos_x, pos_y, ocean_current_x, ocean_current_y} + scalars
// work：work.ocean_tta_inout（in/out 累加器，pass_b 也会读它作为 TTA snapshot）
// 输出：out.ocean_thermal_anomaly（写 water cells）
//
// 注意：sync 路径接 `baseline_arr` / `temp_before_arr` knobs，但本 kernel 把
// baseline 等同于 cell_temp_baseline (in.temp_baseline)，temp_before 等同于
// in.temp（pre-pass_a 快照）。这与 sync 路径同语义（caller 都用 baseline=
// temp_baseline_a 或 EMA-init 时算的派生值；temp_before=temp_a or baseline）。
// Stage 2 期间 sync 端 caller 仍传 baseline_arr/temp_before_arr knobs，所以
// async 这里直接复用 in.temp_baseline_year / in.temp 做参考——bench 时主线程
// 把 sync 端用到的 baseline/temp_before 一并传过来。
bool _async_ocean_water_kernel_pure(const ClimateInputBuf &in,
                                           const ClimateRoundStaticKnobs &knobs,
                                           ClimateWorkBuf &work,
                                           ClimateOutputBuf &out) {
    const int n = in.n_cells;
    if (n <= 0) return false;
    if ((int)in.is_water.size()        != n) return false;
    if ((int)in.pos_x.size()           != n) return false;
    if ((int)in.pos_y.size()           != n) return false;
    if ((int)in.ocean_current_x.size() != n) return false;
    if ((int)in.ocean_current_y.size() != n) return false;
    if ((int)in.temp.size()            != n) return false;
    if ((int)in.temp_baseline_year.size() != n) return false;
    if ((int)in.sea_ice_frac.size()    != n) return false;
    if ((int)in.ocean_thermal_anomaly.size() != n) return false;
    if ((int)knobs.neighbor_indices.size() < n * 6) return false;

    const int advect_steps = in.scalars.ow_advect_steps;
    const float heat_mix   = in.scalars.ow_heat_mix;
    const float wrap_period_x = in.scalars.wrap_period_x;  // seam-advection-fix
    const float tta_source_cap = dc_clampf(in.scalars.ow_tta_source_cap, 0.0f, 0.5f);
    const float tta_blend_rate = dc_clampf(in.scalars.ow_tta_blend_rate, 0.0f, 1.0f);
    const float tta_zero_current_decay = dc_clampf(in.scalars.ow_tta_zero_current_decay, 0.0f, 1.0f);

    // 输出
    if ((int)out.ocean_thermal_anomaly.size() != n) out.ocean_thermal_anomaly.resize(n);
    // ocean_water 累加到 ocean_thermal_anomaly slot；首先 copy in → out 作为基础。
    std::memcpy(out.ocean_thermal_anomaly.data(),
                in.ocean_thermal_anomaly.data(),
                n * sizeof(float));

    // work.ocean_tta_inout：sync 路径的 anomaly_out。round 入口处由主线程从
    // map.temperature_transport_anomaly_arr 初始化（kick 写 in.temp_transport_anomaly），
    // worker 入口再 copy 到 work scratch。
    if ((int)work.ocean_tta_inout.size() != n) work.ocean_tta_inout.resize(n);
    std::memcpy(work.ocean_tta_inout.data(),
                in.temp_transport_anomaly.data(),
                n * sizeof(float));

    const uint8_t *IW = in.is_water.data();
    const float *POSX = in.pos_x.data();
    const float *POSY = in.pos_y.data();
    const float *OCX  = in.ocean_current_x.data();
    const float *OCY  = in.ocean_current_y.data();
    // 生产在消费点抽的真值优先；没有时才退回旧拄本的等同假设。
    const float *TB   = ((int) in.production_ocean_temp_before.size() == n)
                        ? in.production_ocean_temp_before.data()
                        : in.temp.data();
    const float *BL   = ((int) in.production_ocean_baseline.size() == n)
                        ? in.production_ocean_baseline.data()
                        : in.temp_baseline_year.data();
    const float *SIF  = in.sea_ice_frac.data();
    const int32_t *NB = knobs.neighbor_indices.data();

    float *AOUT = work.ocean_tta_inout.data();
    float *OANOM = out.ocean_thermal_anomaly.data();

    // 与生产同一份内核。worker 整图跑，所以 [0, n)。
    {
        OceanWaterKnobs ok;
        ok.n_cells = n;
        // worker 整图跑。试过跟随生产的分片区间，结果反而退化 —— 两边对 TTA
        // 的持久方式不同：生产的分片是就地增量更新一个跳 tick 存活的数组，数组本身
        // 始终完整；worker 每天从 in.temp_transport_anomaly 重新初始化。只跑一片的话其余
        // 格子停在 kick 初值，而生产那些格子带着历史累积。
        ok.start_idx = 0;
        ok.end_idx = n;
        ok.advect_steps = advect_steps;
        ok.heat_mix = heat_mix;
        ok.wrap_period_x = wrap_period_x;
        ok.tta_source_cap = tta_source_cap;
        ok.tta_blend_rate = tta_blend_rate;
        ok.tta_zero_current_decay = tta_zero_current_decay;
        // 旧拄本这里用的是 sea_ice 的 si_t_form / si_t_melt，而生产用的是
        // cold_transport_{form,melt}_threshold —— 两组不同的 knob。现在跟生产走。
        ok.cold_transport_form = in.scalars.ow_cold_transport_form;
        ok.cold_transport_melt = in.scalars.ow_cold_transport_melt;

        OceanWaterLanes ol;
        ol.is_water = IW;
        ol.pos_x = POSX;
        ol.pos_y = POSY;
        ol.ocean_current_x = OCX;
        ol.ocean_current_y = OCY;
        ol.baseline = BL;
        ol.temp_before = TB;
        ol.sea_ice_frac = SIF;
        ol.neighbors = NB;
        ol.ocean_anomaly = OANOM;
        ol.tta_inout = AOUT;

        ocean_water_pure(ok, ol);
    }
    return true;
}

// ocean_land pure kernel — 移植自 DCWorldExt::run_ocean_land_pass（world_ext.cpp:4736）。
// 算法逐行 1:1 镜像 sync 主循环（line 4831-4871）：
//   - 仅 land cell：在 6 邻居里取 water cell，按 dot(self→nb, nb_current) 加权
//   - anomaly_in = dc_decay_tta(prev) 或 dc_stabilize_tta(prev, weighted_avg * eff_leak, ...)
//   - 写 work.ocean_tta_inout[i]
//   - if |anomaly_in| > 1e-5 → 累加到 out.ocean_thermal_anomaly[i]（clamp ±0.08）
//
// 注意：必须在 ocean_water 之后跑，依赖 work.ocean_tta_inout 里 water cells 的
// fresh anomaly（ocean_water 已写）。
bool _async_ocean_land_kernel_pure(const ClimateInputBuf &in,
                                          const ClimateRoundStaticKnobs &knobs,
                                          ClimateWorkBuf &work,
                                          ClimateOutputBuf &out) {
    const int n = in.n_cells;
    if (n <= 0) return false;
    if ((int)in.is_water.size()        != n) return false;
    if ((int)in.pos_x.size()           != n) return false;
    if ((int)in.pos_y.size()           != n) return false;
    if ((int)in.ocean_current_x.size() != n) return false;
    if ((int)in.ocean_current_y.size() != n) return false;
    if ((int)knobs.neighbor_indices.size() < n * 6) return false;
    if ((int)work.ocean_tta_inout.size() != n) return false;

    const float effective_leak = in.scalars.ol_effective_leak;
    const float wrap_period_x = in.scalars.wrap_period_x;  // seam-advection-fix
    const float tta_source_cap = dc_clampf(in.scalars.ol_tta_source_cap, 0.0f, 0.5f);
    const float tta_blend_rate = dc_clampf(in.scalars.ol_tta_blend_rate, 0.0f, 1.0f);
    const float tta_decay_rate = dc_clampf(in.scalars.ol_tta_decay_rate, 0.0f, 1.0f);

    if ((int)out.ocean_thermal_anomaly.size() != n) {
        // 防御：若 ocean_water 没跑，则用 in.ocean_thermal_anomaly 作为基础
        out.ocean_thermal_anomaly.resize(n);
        std::memcpy(out.ocean_thermal_anomaly.data(),
                    in.ocean_thermal_anomaly.data(),
                    n * sizeof(float));
    }

    const uint8_t *IW = in.is_water.data();
    const float *POSX = in.pos_x.data();
    const float *POSY = in.pos_y.data();
    const float *OCX  = in.ocean_current_x.data();
    const float *OCY  = in.ocean_current_y.data();
    const int32_t *NB = knobs.neighbor_indices.data();
    float *A = work.ocean_tta_inout.data();
    float *OANOM = out.ocean_thermal_anomaly.data();

    {
        OceanLandKnobs ok;
        ok.n_cells = n;
        // worker 整图跑。试过跟随生产的分片区间，结果反而退化 —— 两边对 TTA
        // 的持久方式不同：生产的分片是就地增量更新一个跳 tick 存活的数组，数组本身
        // 始终完整；worker 每天从 in.temp_transport_anomaly 重新初始化。只跑一片的话其余
        // 格子停在 kick 初值，而生产那些格子带着历史累积。
        ok.start_idx = 0;
        ok.end_idx = n;
        ok.effective_leak = effective_leak;
        ok.wrap_period_x = wrap_period_x;
        ok.tta_source_cap = tta_source_cap;
        ok.tta_blend_rate = tta_blend_rate;
        ok.tta_decay_rate = tta_decay_rate;

        OceanLandLanes ol;
        ol.is_water = IW;
        ol.pos_x = POSX;
        ol.pos_y = POSY;
        ol.ocean_current_x = OCX;
        ol.ocean_current_y = OCY;
        ol.neighbors = NB;
        ol.tta_inout = A;
        ol.ocean_anomaly = OANOM;

        ocean_land_pure(ok, ol);
    }
    return true;
}

// wind_air pure kernel — 移植自 DCWorldExt::run_wind_air_mass_pass（world_ext.cpp:4887）。
// 算法逐行 1:1 镜像 sync 主循环（line 4963-5009）：
//   - 每 cell：A[i] = 0
//   - 若 wind_speed^2 < 1e-6 或 advect_steps==0：跳过（A=0）
//   - 否则沿 -wind 方向回溯 advect_steps 步找最对齐邻居（**不限 water**——
//     与 sync 路径一致；与 ocean_water 限 water 不同）
//   - temp_mixed = lerp(temp_self, temp_up, heat_mix * speed_mix)
//     speed_mix = clamp(wf_wind_speed_norm(...) / 1.2, 0.25, 1.35)
//   - A[i] = temp_mixed - baseline
//
// 输入：in.{wind_x, wind_y, wind_speed, pos_x, pos_y, temp（snapshot）,
//           temp_baseline_year（作 baseline_arr）} + scalars
// 输出：out.air_mass_temp_anomaly
bool _async_wind_air_kernel_pure(const ClimateInputBuf &in,
                                        const ClimateRoundStaticKnobs &knobs,
                                        ClimateOutputBuf &out) {
    const int n = in.n_cells;
    if (n <= 0) return false;
    if ((int)in.wind_x.size()             != n) return false;
    if ((int)in.wind_y.size()             != n) return false;
    if ((int)in.wind_speed.size()         != n) return false;
    if ((int)in.pos_x.size()              != n) return false;
    if ((int)in.pos_y.size()              != n) return false;
    if ((int)in.temp.size()               != n) return false;
    if ((int)in.temp_baseline_year.size() != n) return false;
    if ((int)knobs.neighbor_indices.size() < n * 6) return false;

    if ((int)out.air_mass_temp_anomaly.size() != n) out.air_mass_temp_anomaly.resize(n);

    WindAirKnobs wa_knobs;
    wa_knobs.n_cells = n;
    wa_knobs.advect_steps = in.scalars.wa_advect_steps;
    wa_knobs.heat_mix = in.scalars.wa_heat_mix;
    wa_knobs.wrap_period_x = in.scalars.wrap_period_x;  // seam-advection-fix

    WindAirLanes wa_lanes;
    wa_lanes.wind_x = in.wind_x.data();
    wa_lanes.wind_y = in.wind_y.data();
    wa_lanes.wind_speed = in.wind_speed.data();
    wa_lanes.pos_x = in.pos_x.data();
    wa_lanes.pos_y = in.pos_y.data();
    wa_lanes.temp_before = in.temp.data();
    // 生产的 baseline_arr 优先；没记到时退回年级 LUT（旧行为），但那会偏。
    wa_lanes.baseline = (int)in.wind_baseline.size() == n
        ? in.wind_baseline.data() : in.temp_baseline_year.data();
    wa_lanes.neighbor_indices = knobs.neighbor_indices.data();
    if ((int)in.wind_traj_idx.size() == n * 3 &&
        (int)in.wind_traj_w.size() == n * 3) {
        wa_lanes.traj_idx = in.wind_traj_idx.data();
        wa_lanes.traj_w = in.wind_traj_w.data();
    }
    wa_lanes.air_anomaly = out.air_mass_temp_anomaly.data();

    wind_air_pure(wa_knobs, wa_lanes, 0, n);
    return true;
}

// wind_surface pure kernel — 移植自 DCWorldExt::run_wind_surface_pass（world_ext.cpp:5022）。
// 算法逐行 1:1 镜像 sync 主循环（line 5114-5166）：
//   - 每 cell：对 6 邻居计算 weight = dot(self→nb_pos, nb_wind) * speed_mix(nb)
//     speed_mix = clamp(wf_wind_speed_norm(nb_wind, nb_wind_speed) / 1.2, 0.20, 1.35)
//   - anomaly_in = (weighted_sum / weight_total) * air_leak，clamp ±0.08
//   - 写 out.air_mass_temp_anomaly[i] = anomaly_in（OVERWRITE 不累加）
//   - 合成 cell_temp = clamp(baseline + clamp(ocean_anom + air_anom, ±0.08)
//                     + local_anom, 0, 1)，总 anomaly 再 clamp ±0.15
//
// 依赖：必须在 pass_a / pass_b / ocean_water / ocean_land / wind_air 之后跑（依赖
// 它们写的 temp_baseline / ocean_thermal_anomaly / local_thermal_anomaly /
// air_mass_temp_anomaly 当前值）。
//
// 输入：in.{wind_x, wind_y, wind_speed, pos_x, pos_y, temp_baseline_year（备份 baseline）}
// in/out：out.{air_mass_temp_anomaly, temp_baseline, ocean_thermal_anomaly,
//              local_thermal_anomaly}（前序 pass 输出，wind_surface 读取做合成）
// 输出：out.{air_mass_temp_anomaly（覆写）, temp（最终温度）}
bool _async_wind_surface_kernel_pure(const ClimateInputBuf &in,
                                            const ClimateRoundStaticKnobs &knobs,
                                            ClimateOutputBuf &out) {
    const int n = in.n_cells;
    if (n <= 0) return false;
    if ((int)in.wind_x.size()             != n) return false;
    if ((int)in.wind_y.size()             != n) return false;
    if ((int)in.wind_speed.size()         != n) return false;
    if ((int)in.pos_x.size()              != n) return false;
    if ((int)in.pos_y.size()              != n) return false;
    if ((int)in.temp_baseline_year.size() != n) return false;
    if ((int)knobs.neighbor_indices.size() < n * 6) return false;

    const float air_leak = in.scalars.ws_air_leak;
    const float cold_transport_form = in.scalars.ws_cold_transport_form;
    const float cold_transport_melt = in.scalars.ws_cold_transport_melt;
    const float wrap_period_x = in.scalars.wrap_period_x;  // seam-advection-fix

    // 准备 input snapshot：sync 路径用 anomaly_src.duplicate()（air_anom 旧值）
    // 作为读取来源，AOUT 作为新输出。但 wind_air 已写 out.air_mass_temp_anomaly。
    // 我们这里 AIN 用 in.air_mass_temp_anomaly（或 out.air_mass_temp_anomaly 如果非空），
    // AOUT 直接写 out.air_mass_temp_anomaly。复刻 sync 的 AIN/AOUT 分离。
    // Stage 2 bench 时主线程会传 in.air_mass_temp_anomaly = MapData.air_mass_temp_anomaly_arr。
    // Round 模式下（mask=0x30 + 上一 pass wind_air 跑过），out.air_mass_temp_anomaly 已是
    // wind_air 输出——但 sync 路径的 AIN 也是 wind_air 写完的值（slot 写后再读），所以
    // **正确做法是用 out.air_mass_temp_anomaly 作为 AIN**（如果它是 wind_air 输出的话）。
    // 决策：bench 时 mask=0x20（仅 wind_surface），主线程要把 sync 路径"wind_air 跑完之后"
    // 的 air_anom 传成 in.air_mass_temp_anomaly。该字段同时也是 out 的初值。
    if ((int)out.air_mass_temp_anomaly.size() != n) {
        out.air_mass_temp_anomaly.resize(n);
        if ((int)in.air_mass_temp_anomaly.size() == n) {
            std::memcpy(out.air_mass_temp_anomaly.data(),
                        in.air_mass_temp_anomaly.data(),
                        n * sizeof(float));
        }
    }
    if ((int)out.temp.size() != n) out.temp.resize(n);

    // 准备合成 baseline / oanom / lanom 输入。这些字段如果 out 已写则用 out 值；
    // 否则用 in 值（bench 模式：主线程把 sync 路径"pass_a/b/ocean_* 之后"的快照传过来）。
    auto choose_field = [n](const std::vector<float> &out_v,
                            const std::vector<float> &in_v) -> const float* {
        if ((int)out_v.size() == n) return out_v.data();
        if ((int)in_v.size()  == n) return in_v.data();
        return nullptr;
    };
    const float *BL_RUNTIME = choose_field(out.temp_baseline, in.temp_baseline);
    if (BL_RUNTIME == nullptr) {
        // 兜底：用 in.temp_baseline_year（年级 LUT）作为 fallback baseline
        BL_RUNTIME = in.temp_baseline_year.data();
    }
    const float *OANOM = choose_field(out.ocean_thermal_anomaly, in.ocean_thermal_anomaly);
    const float *LANOM = choose_field(out.local_thermal_anomaly, in.local_thermal_anomaly);
    const float *FBL = in.temp_baseline_year.data();  // fallback_baseline_arr

    // AIN：上一 pass wind_air 输出的 air anomaly。bench mask=0x20 时主线程把它
    // 装到 in.air_mass_temp_anomaly。
    // 注意：sync 路径 AIN 与 AOUT 是同 slot 的 in-place 别名读/写，因为
    // wind_surface 读 ni（邻居）的旧 air_anom 计算 weighted_sum，写 i 自己的
    // 新 air_anom。**邻居 ni 的写时序在 i 之前**（loop 顺序），所以 sync 实际是
    // 类似 Gauss-Seidel：当 i 处理时，nb_idx < i 的邻居用的是它们刚刚的新值，
    // nb_idx > i 用的是旧值。
    // 但 sync 用 anomaly_src.duplicate() → AIN 永远指向"调用前"的旧 air anomaly，
    // 即 wind_air 写完后的整套值，loop 内 ni 邻居读的是 AIN[ni] 旧值；
    // AOUT 写的是新值。这是 Jacobi 风格——pure kernel 必须严格遵守。
    std::vector<float> ain_snapshot;
    ain_snapshot.assign(out.air_mass_temp_anomaly.begin(), out.air_mass_temp_anomaly.end());
    const float *AIN = ain_snapshot.data();
    float *AOUT = out.air_mass_temp_anomaly.data();
    float *T_OUT = out.temp.data();

    const float *WX  = in.wind_x.data();
    const float *WY  = in.wind_y.data();
    const float *WSP = in.wind_speed.data();
    const float *POSX = in.pos_x.data();
    const float *POSY = in.pos_y.data();
    const int32_t *NB = knobs.neighbor_indices.data();

    // is_water 缺失时按"全非水"处理，等价于旧实现里那个 size 守卫：结冰线门控
    // 只对水格生效，没有 is_water 就没有水格。
    static const std::vector<uint8_t> s_no_water;
    const std::vector<uint8_t> &iw_src =
        (int)in.is_water.size() == n ? in.is_water : s_no_water;
    std::vector<uint8_t> iw_zero;
    if ((int)iw_src.size() != n) iw_zero.assign(n, 0u);
    const uint8_t *IW = (int)iw_src.size() == n ? iw_src.data() : iw_zero.data();

    WindSurfaceKnobs ws_knobs;
    ws_knobs.n_cells = n;
    ws_knobs.air_leak = air_leak;
    ws_knobs.wrap_period_x = wrap_period_x;
    ws_knobs.cold_transport_form = cold_transport_form;
    ws_knobs.cold_transport_melt = cold_transport_melt;

    WindSurfaceLanes ws_lanes;
    ws_lanes.wind_x = WX;
    ws_lanes.wind_y = WY;
    ws_lanes.wind_speed = WSP;
    ws_lanes.pos_x = POSX;
    ws_lanes.pos_y = POSY;
    ws_lanes.is_water = IW;
    ws_lanes.baseline = BL_RUNTIME;
    ws_lanes.fallback_baseline = FBL;
    ws_lanes.ocean_anomaly = OANOM;
    ws_lanes.local_anomaly = LANOM;
    ws_lanes.neighbor_indices = NB;
    ws_lanes.air_anomaly_in = AIN;
    ws_lanes.air_anomaly_out = AOUT;
    ws_lanes.temp_out = T_OUT;

    wind_surface_pure(ws_knobs, ws_lanes, 0, n);
    return true;
}

void sea_ice_pure(const SeaIceKnobs &knobs,
                  const SeaIceLanes &lanes,
                  SeaIceScratch &scratch,
                  SeaIceEmit &emit) {
    const int n_cells = knobs.n_cells;
    if (n_cells <= 0) return;

    float edge_mix_rate = knobs.edge_mix_rate;
    if (edge_mix_rate < 0.0f) edge_mix_rate = 0.0f;
    else if (edge_mix_rate > 0.20f) edge_mix_rate = 0.20f;

    float dt_days = knobs.dt_days;
    if (dt_days < 0.0f) dt_days = 0.0f;
    else if (dt_days > 30.0f) dt_days = 30.0f;

    const uint8_t * const TR    = lanes.terrain;
    const uint8_t * const BT    = lanes.base_terrain;
    const float   * const T     = lanes.cell_temperature;
    const float   * const TTA   = lanes.temp_transport_anomaly;
    const float   * const OANOM = lanes.ocean_thermal_anomaly;
    const float   * const UPW   = lanes.upwelling_strength;
    const float   * const INS   = lanes.insolation_now;
    const int32_t * const NB    = lanes.neighbor_indices;
    float         * const SIF   = lanes.sea_ice_frac;

    // is_water 是 map_generator.gd::_is_water 的 1:1 镜像，靠调用方传进来的
    // water_terrain_ids 建 256 项 LUT —— 不硬编码 enum，加水地形不用改这里。
    bool is_water_lut[256];
    for (int i = 0; i < 256; ++i) is_water_lut[i] = false;
    for (int k = 0; k < lanes.water_terrain_ids_size; ++k) {
        const int wid = int(lanes.water_terrain_ids[k]);
        if (wid >= 0 && wid < 256) is_water_lut[wid] = true;
    }

    if ((int) scratch.prev_sif.size() != n_cells) scratch.prev_sif.resize(n_cells);
    if ((int) scratch.has_cold_neighbor.size() != n_cells) scratch.has_cold_neighbor.resize(n_cells);
    float   * const prev_sif = scratch.prev_sif.data();
    uint8_t * const has_cold_neighbor = scratch.has_cold_neighbor.data();
    for (int i = 0; i < n_cells; ++i) prev_sif[i] = SIF[i];

    // ─── Phase A: has_cold_neighbor 快照（前一日 SIF）──────────────────
    // 只看 prev SIF >= 0.6，"邻居必须是水" 由 LUT 兜住（陆地恒 0，进不了阈值）。
    for (int i = 0; i < n_cells; ++i) {
        has_cold_neighbor[i] = 0;
        if (!is_water_lut[TR[i]]) continue;
        const int base = i * 6;
        for (int d = 0; d < 6; ++d) {
            const int32_t ni = NB[base + d];
            if (ni < 0) continue;
            if (!is_water_lut[TR[ni]]) continue;
            if (prev_sif[ni] >= 0.6f) { has_cold_neighbor[i] = 1; break; }
        }
    }

    // ─── Phase B: 主循环（fraction 增量更新 + flip 候选收集）──────────
    emit.flip_to_ice.clear();
    emit.flip_to_base.clear();
    emit.flip_to_base_terrain.clear();
    emit.water_count = 0;
    emit.flipped_count = 0;

    for (int i = 0; i < n_cells; ++i) {
        const uint8_t terr = TR[i];

        // 非 water → 强制 0
        if (!is_water_lut[terr]) { SIF[i] = 0.0f; continue; }
        // LAKE → 强制 0（淡水冻结留给后续 phase）
        if (int(terr) == knobs.terrain_lake_id) { SIF[i] = 0.0f; continue; }
        ++emit.water_count;

        float t_eff = T[i];
        if (knobs.enable_ocean_heat_transport) {
            const float tta_residual = sea_ice_positive_tta_residual(TTA[i], OANOM[i]);
            if (tta_residual > 0.0f) t_eff += knobs.ice_delay * tta_residual;
            const float upw = UPW[i];
            // 旧式 upw>0.3 时一次减 0.5*upw，会把暖水也压到冰点、冰缘快速堆满；
            // 上升流退掉的那天又按真实温度猛融，再被邻居混合拉回，形成隔日闪烁。
            if (upw > 0.0f) t_eff -= 0.15f * upw;
        }
        if (t_eff < 0.0f) t_eff = 0.0f;
        else if (t_eff > 1.0f) t_eff = 1.0f;

        float k_freeze_eff = knobs.k_freeze;
        if (has_cold_neighbor[i]) k_freeze_eff = knobs.k_freeze * (1.0f + knobs.contagion);

        const float prev_frac = prev_sif[i];

        const float diff_freeze = (knobs.t_form > t_eff) ? (knobs.t_form - t_eff) : 0.0f;
        const float diff_melt   = (t_eff > knobs.t_melt) ? (t_eff - knobs.t_melt) : 0.0f;
        float freeze_gate = 1.0f;
        const float insolation_now = knobs.solar_gate_enabled ? INS[i] : 0.0f;
        if (knobs.solar_gate_enabled) {
            freeze_gate = sea_ice_freeze_gate(insolation_now, knobs.freeze_insol_low, knobs.freeze_insol_high);
        }
        const float solar_melt_base = knobs.solar_gate_enabled
            ? sea_ice_solar_melt(insolation_now, knobs.solar_melt_start, knobs.solar_melt_gain) : 0.0f;
        const float freeze_term = k_freeze_eff * diff_freeze * freeze_gate;

        // daily_delta_cap 是"每日"上限。单步 clamp(rate)*dt_days 在加速档下会把
        // melt 过冲截到 0，把已累积的冰的"记忆"丢掉（极地饱和度随速度档退化、单
        // tick 视觉突变）。改按日子步积分：每步独立 clamp 速率、各自 clamp[0,1]，
        // solar_exposure 随 frac 逐步重算。dt_days == 1 时 n_sub == 1，与单步逐位等价。
        int n_sub = int(dt_days);
        if (float(n_sub) < dt_days) ++n_sub;   // ceil
        if (n_sub < 1) n_sub = 1;
        else if (n_sub > 30) n_sub = 30;
        const float sub_dt = dt_days / float(n_sub);
        float new_frac = prev_frac;
        float thermo_tendency = 0.0f;
        for (int sub = 0; sub < n_sub; ++sub) {
            const float solar_melt_s = knobs.solar_gate_enabled
                ? solar_melt_base * sea_ice_solar_exposure(new_frac, knobs.min_thick_ice_solar_exposure)
                : 0.0f;
            float rate = freeze_term - (knobs.k_melt * diff_melt + solar_melt_s);
            if (knobs.daily_delta_cap > 0.0f) {
                if (rate > knobs.daily_delta_cap) rate = knobs.daily_delta_cap;
                else if (rate < -knobs.daily_delta_cap) rate = -knobs.daily_delta_cap;
            }
            thermo_tendency += rate * sub_dt;
            new_frac += rate * sub_dt;
            if (new_frac <= 0.0f) { new_frac = 0.0f; if (rate < 0.0f) break; }
            else if (new_frac >= 1.0f) { new_frac = 1.0f; if (rate > 0.0f) break; }
        }

        if (edge_mix_rate > 0.0f) {
            float sum_nb_frac = 0.0f;
            int nb_water_count = 0;
            const int base = i * 6;
            for (int d = 0; d < 6; ++d) {
                const int32_t ni = NB[base + d];
                if (ni < 0 || !is_water_lut[TR[ni]] || int(TR[ni]) == knobs.terrain_lake_id) continue;
                sum_nb_frac += prev_sif[ni];
                ++nb_water_count;
            }
            if (nb_water_count > 0) {
                const float avg_nb_frac = sum_nb_frac / float(nb_water_count);
                const float contrast = std::abs(avg_nb_frac - new_frac);
                if (contrast > 0.05f && (prev_frac > 0.001f || avg_nb_frac > 0.001f)) {
                    const float mix = std::min(0.12f, edge_mix_rate * std::max(1.0f, dt_days));
                    const float thermo_frac = new_frac;
                    new_frac += (avg_nb_frac - new_frac) * mix;
                    // Neighbor smoothing may continue today's freeze or melt, but
                    // must not oppose it. A pullback of even 25% is enough to
                    // reverse the visible edge every other day once the pack exists.
                    // The direction comes from the unclamped rate: a freezing cell
                    // pinned at 1 (or a melting cell pinned at 0) has
                    // thermo_frac == prev_frac, and treating it as neutral lets the
                    // mix pull it off the bound only for the next day to undo it.
                    if (thermo_tendency > 0.0f) {
                        if (new_frac < thermo_frac) new_frac = thermo_frac;
                    } else if (thermo_tendency < 0.0f) {
                        if (new_frac > thermo_frac) new_frac = thermo_frac;
                    } else {
                        const float lo = prev_frac - 0.02f;
                        const float hi = prev_frac + 0.02f;
                        if (new_frac < lo) new_frac = lo;
                        else if (new_frac > hi) new_frac = hi;
                    }
                    if (new_frac < 0.0f) new_frac = 0.0f;
                    else if (new_frac > 1.0f) new_frac = 1.0f;
                }
            }
        }
        SIF[i] = new_frac;

        // 翻转候选收集（带迟滞）
        const bool was_ice = (int(terr) == knobs.terrain_sea_ice_id);
        if (!was_ice && new_frac >= knobs.threshold) {
            emit.flip_to_ice.push_back(i);
            ++emit.flipped_count;
        } else if (was_ice && new_frac < (knobs.threshold - knobs.hysteresis)) {
            const int base_t_int = int(BT[i]);
            int target_terr = base_t_int;
            if (base_t_int == knobs.terrain_sea_ice_id) target_terr = knobs.terrain_ocean_id;
            emit.flip_to_base.push_back(i);
            emit.flip_to_base_terrain.push_back(uint8_t(target_terr & 0xFF));
            ++emit.flipped_count;
        }
    }
}

void overlay_production_ocean_water(ClimateInputBuf &base, const OceanWaterInput &prod) {
    if (base.n_cells <= 0 || prod.n_cells != base.n_cells) return;
    const size_t n = static_cast<size_t>(base.n_cells);
    if (prod.baseline.size() == n) base.production_ocean_baseline = prod.baseline;
    if (prod.temp_before.size() == n) base.production_ocean_temp_before = prod.temp_before;
}

void ocean_water_pure(const OceanWaterKnobs &knobs, const OceanWaterLanes &lanes) {
    const int start = knobs.start_idx;
    const int end = knobs.end_idx;
    if (end <= start) return;

    const uint8_t * const __restrict IW = lanes.is_water;
    const float * const __restrict POSX = lanes.pos_x;
    const float * const __restrict POSY = lanes.pos_y;
    const float * const __restrict OCX = lanes.ocean_current_x;
    const float * const __restrict OCY = lanes.ocean_current_y;
    const float * const __restrict BL = lanes.baseline;
    const float * const __restrict TB = lanes.temp_before;
    const float * const __restrict SIF = lanes.sea_ice_frac;
    const int32_t * const __restrict NB = lanes.neighbors;
    float * const __restrict OANOM = lanes.ocean_anomaly;
    float * const __restrict AOUT = lanes.tta_inout;

    const int   advect_steps = knobs.advect_steps;
    const float heat_mix = knobs.heat_mix;
    const float wrap_period_x = knobs.wrap_period_x;

    for (int i = start; i < end; ++i) {
        if (IW[i] == 0) continue;  // skip land
        const float cur_x = OCX[i];
        const float cur_y = OCY[i];
        const float cur_len2 = cur_x * cur_x + cur_y * cur_y;
        if (cur_len2 < 1e-6f || advect_steps == 0) {
            AOUT[i] = dc_decay_tta(AOUT[i], knobs.tta_zero_current_decay);
            // current 不足时 ocean anomaly 也朝 0 衰减，避免上轮残值滞留。
            OANOM[i] = OANOM[i] * (1.0f - knobs.tta_zero_current_decay);
            continue;
        }
        const float inv_cur = 1.0f / std::sqrt(cur_len2);
        const float up_dx = -cur_x * inv_cur;
        const float up_dy = -cur_y * inv_cur;

        int upstream_idx = i;
        for (int step = 0; step < advect_steps; ++step) {
            int   best_idx = -1;
            float best_dot = 0.1f;
            const float swx = POSX[upstream_idx];
            const float swy = POSY[upstream_idx];
            const int ub = upstream_idx * 6;
            for (int d = 0; d < 6; ++d) {
                const int32_t ni = NB[ub + d];
                if (ni < 0) continue;
                if (IW[ni] == 0) continue;
                const float dx = pk_wrap_min_image_dx(POSX[ni] - swx, wrap_period_x);
                const float dy = POSY[ni] - swy;
                const float len2 = dx * dx + dy * dy;
                if (len2 < 1e-6f) continue;
                const float inv_len = 1.0f / std::sqrt(len2);
                const float dot_v = (dx * up_dx + dy * up_dy) * inv_len;
                if (dot_v > best_dot) {
                    best_dot = dot_v;
                    best_idx = ni;
                }
            }
            if (best_idx < 0) break;
            upstream_idx = best_idx;
        }

        const float temp_self = TB[i];
        const float temp_up = TB[upstream_idx];
        float temp_mixed = temp_self + (temp_up - temp_self) * heat_mix;  // = lerpf
        if (temp_mixed < 0.0f) temp_mixed = 0.0f;
        else if (temp_mixed > 1.0f) temp_mixed = 1.0f;
        // 海冰把表层与正的洋流热异常隔开：冷异常保留，暖流注入按冰盖折减。
        float source = temp_mixed - BL[i];
        source = pk_limit_cold_water_positive_transport_source(
            source, BL[i], SIF[i], knobs.cold_transport_form, knobs.cold_transport_melt);
        float oanom = source;
        if (oanom < -0.08f) oanom = -0.08f;
        else if (oanom > 0.08f) oanom = 0.08f;
        OANOM[i] = oanom;
        AOUT[i] = dc_stabilize_tta(AOUT[i], source,
                                   knobs.tta_source_cap, knobs.tta_blend_rate);
    }
}

void ocean_land_pure(const OceanLandKnobs &knobs, const OceanLandLanes &lanes) {
    const int start = knobs.start_idx;
    const int end = knobs.end_idx;
    if (end <= start) return;

    const uint8_t * const __restrict IW = lanes.is_water;
    const float * const __restrict POSX = lanes.pos_x;
    const float * const __restrict POSY = lanes.pos_y;
    const float * const __restrict OCX = lanes.ocean_current_x;
    const float * const __restrict OCY = lanes.ocean_current_y;
    const int32_t * const __restrict NB = lanes.neighbors;
    float * const __restrict A = lanes.tta_inout;
    float * const __restrict OANOM = lanes.ocean_anomaly;

    const float wrap_period_x = knobs.wrap_period_x;

    for (int i = start; i < end; ++i) {
        if (IW[i] != 0) continue;  // skip water
        const float swx = POSX[i];
        const float swy = POSY[i];
        float weighted_sum = 0.0f;
        float weight_total = 0.0f;
        const int b = i * 6;
        for (int d = 0; d < 6; ++d) {
            const int32_t ni = NB[b + d];
            if (ni < 0) continue;
            if (IW[ni] == 0) continue;  // 只有 water 邻居贡献
            const float cx = OCX[ni];
            const float cy = OCY[ni];
            if (cx * cx + cy * cy < 1e-6f) continue;
            const float dx = pk_wrap_min_image_dx(swx - POSX[ni], wrap_period_x);
            const float dy = swy - POSY[ni];
            const float dlen2 = dx * dx + dy * dy;
            if (dlen2 < 1e-6f) continue;
            const float inv_len = 1.0f / std::sqrt(dlen2);
            const float dot_v = (dx * cx + dy * cy) * inv_len;
            if (dot_v <= 0.0f) continue;
            weighted_sum += A[ni] * dot_v;
            weight_total += dot_v;
        }
        const float prev_anomaly = A[i];
        float anomaly_in = dc_decay_tta(prev_anomaly, knobs.tta_decay_rate);
        if (weight_total > 0.0f) {
            anomaly_in = dc_stabilize_tta(
                prev_anomaly, (weighted_sum / weight_total) * knobs.effective_leak,
                knobs.tta_source_cap, knobs.tta_blend_rate);
        }
        A[i] = anomaly_in;
        // anomaly_in 已过 dc_decay/stabilize，本身有界；这里累加到 oanom 再 clamp。
        if ((anomaly_in < 0.0f ? -anomaly_in : anomaly_in) > 1e-5f) {
            float oanom = OANOM[i] + anomaly_in;
            if (oanom < -0.08f) oanom = -0.08f;
            else if (oanom > 0.08f) oanom = 0.08f;
            OANOM[i] = oanom;
        }
    }
}

} // namespace pk_async_climate
} // namespace pk
