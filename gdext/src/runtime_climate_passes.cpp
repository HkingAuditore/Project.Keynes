// ─── Climate pass 纯内核实现（Godot 无依赖）──────────────────────
//
// S3 搬迁体：下面 9 个 kernel 原位于 world_ext_climate.cpp（static 文件作用域），
// 现在是生产与 SHADOW worker 共用的唯一实现。搬迁是逐字的，不含任何算法改动；
// 任何数值行为变更必须单独提案，否则无法与 S2 分叉矩阵对齐。
//
// 不得 include godot_cpp。这一条约束就是“worker 可用”的全部含义。

#include "runtime_climate_passes.h"

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

        // (b) moisture: no direct insolation/season multiplier.
        float moisture_now;
        if (is_water) {
            moisture_now = PBM[i];
        } else {
            float bm = PBM[i];
            if (bm > 1.0f) bm = 1.0f;
            else if (bm < 0.0f) bm = 0.0f;
            float moisture_target = bm;
            if (PWEATHERV != nullptr) {
                const float vapor = dc_clampf(PWEATHERV[i], 0.0f, 1.0f);
                moisture_target += (vapor - bm * 0.15f) * moisture_vapor_w;
            }
            if (PPRECIP != nullptr) {
                moisture_target += dc_clampf(PPRECIP[i], 0.0f, 1.0f) * moisture_precip_w;
            }
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
            moisture_target = dc_clampf(moisture_target, 0.0f, 1.0f);
            // sync run_climate_pass_a 的 prev 守卫：非有限或越界的历史 moisture 视为
            // 尚未初始化，直接落到 target（而不是把 NaN 传播进松弛式）。缺 moisture
            // 输入列时同样退化为 target。
            float previous = moisture_target;
            if ((int)in.moisture.size() == n) {
                const float raw = in.moisture[size_t(i)];
                if (std::isfinite(raw) && raw >= 0.0f && raw <= 1.0f) previous = raw;
            }
            moisture_now = previous + (moisture_target - previous) * moisture_relax_eff;
            if (moisture_now > 1.0f) moisture_now = 1.0f;
            else if (moisture_now < 0.0f) moisture_now = 0.0f;
        }

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
        const char *v = std::getenv("PK_WS_PROBE_CELL");
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
            if (upw > 0.3f) t_eff -= 0.5f * upw;
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
        for (int sub = 0; sub < n_sub; ++sub) {
            const float solar_melt_s = knobs.solar_gate_enabled
                ? solar_melt_base * sea_ice_solar_exposure(new_frac, knobs.min_thick_ice_solar_exposure)
                : 0.0f;
            float rate = freeze_term - (knobs.k_melt * diff_melt + solar_melt_s);
            if (knobs.daily_delta_cap > 0.0f) {
                if (rate > knobs.daily_delta_cap) rate = knobs.daily_delta_cap;
                else if (rate < -knobs.daily_delta_cap) rate = -knobs.daily_delta_cap;
            }
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
                    new_frac += (avg_nb_frac - new_frac) * mix;
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

void finalizer_pure(const FinalizerKnobs &knobs,
                    const FinalizerLanes &lanes,
                    FinalizerStats &stats) {
    const int n = knobs.n_cells;
    if (n <= 0) return;

    // 全程 double，只在写回时收窄 —— 见头文件注释。
    float * const tp = lanes.temp;
    const float * const ts = knobs.has_temp_start ? lanes.temp_start : nullptr;
    const bool cap_temp = knobs.temp_cap_enabled && knobs.has_temp_start && ts != nullptr;

    for (int i = 0; i < n; ++i) {
        const double start_t = (ts != nullptr) ? double(ts[i]) : double(tp[i]);
        const double raw = double(tp[i]);
        double final_t = raw;
        const double pre = std::fabs(raw - start_t);
        if (lanes.preclamp_temp_deltas != nullptr) {
            lanes.preclamp_temp_deltas[i] = float(pre);
        }
        if (pre > stats.preclamp_max_temp_delta) stats.preclamp_max_temp_delta = pre;
        if (cap_temp) {
            const double lo = start_t - knobs.temp_cap;
            const double hi = start_t + knobs.temp_cap;
            final_t = final_t < lo ? lo : (final_t > hi ? hi : final_t);
            final_t = final_t < 0.0 ? 0.0 : (final_t > 1.0 ? 1.0 : final_t);
            if (std::fabs(final_t - raw) > 0.000001) ++stats.temp_clamped;
            tp[i] = float(final_t);
        }
        const double dt = std::fabs(final_t - start_t);
        if (lanes.temp_deltas != nullptr) lanes.temp_deltas[i] = float(dt);
        if (dt > 0.005) ++stats.temp_delta_gt_005;
        if (dt > 0.010) ++stats.temp_delta_gt_010;
        if (dt > 0.020) ++stats.temp_delta_gt_020;
        if (dt > stats.max_temp_delta) stats.max_temp_delta = dt;
    }

    // TTA：只在真的被 clamp 时才写。生产侧靠这个决定 CoW 要不要 fork —— 无条件
    // 写会让 buffer 与 map.* 解除别名，反而偏 ~1e-5（见生产注释）。
    float * const qp = lanes.tta;
    const float * const qs = knobs.has_tta_start ? lanes.tta_start : nullptr;
    const bool cap_tta = knobs.tta_cap > 0.0 && knobs.has_tta_start && qs != nullptr;
    for (int i = 0; i < n; ++i) {
        const double start_q = (qs != nullptr) ? double(qs[i]) : 0.0;
        const double raw = double(qp[i]);
        double final_q = raw;
        if (cap_tta) {
            const double lo = start_q - knobs.tta_cap;
            const double hi = start_q + knobs.tta_cap;
            final_q = final_q < lo ? lo : (final_q > hi ? hi : final_q);
            if (std::fabs(final_q - raw) > 0.000001) {
                qp[i] = float(final_q);
                ++stats.tta_clamped;
            }
        }
        const double aq = std::fabs(final_q);
        if (aq > stats.max_transport_anomaly) stats.max_transport_anomaly = aq;
    }

    // thermal 初始化用的是**已 clamp 的** temp。
    if (lanes.thermal != nullptr) {
        float * const hp = lanes.thermal;
        for (int i = 0; i < n; ++i) {
            bool needs = !std::isfinite(hp[i]);
            if (!needs && lanes.ema != nullptr && i < lanes.ema_size && lanes.ema[i] == 0) {
                needs = true;
            }
            if (needs) { hp[i] = tp[i]; ++stats.thermal_init; }
        }
    }
}

void overlay_production_wind_surface(ClimateInputBuf &base, const WindSurfaceInput &prod) {
    if (prod.n_cells != base.n_cells) return;
    if ((int) prod.ocean_anomaly.size() == base.n_cells) {
        base.production_ocean_anomaly = prod.ocean_anomaly;
    }
}

void overlay_production_sea_ice(ClimateInputBuf &base, const SeaIceInput &prod) {
    if (prod.n_cells != base.n_cells) return;
    const int n = prod.n_cells;
    // 只叠 sea_ice 自己消费、且不会被更早 pass 当输入的字段。
    // terrain / sif / insolation / upwelling 写进共享 lane 会让 ocean / pass_b
    // 吃到 sea_ice 时刻的快照；cell_temperature_arr 仅供 sea_ice 读，且
    // wind_surface 之后会用 worker 自己的合成温度覆盖。
    if ((int) prod.cell_temperature.size() == n) {
        base.cell_temperature_arr = prod.cell_temperature;
    }
    if ((int) prod.ocean_thermal_anomaly.size() == n) {
        base.production_sea_ice_oanom = prod.ocean_thermal_anomaly;
    }
    if ((int) prod.temp_transport_anomaly.size() == n) {
        base.production_sea_ice_tta = prod.temp_transport_anomaly;
    }
    if (base.water_terrain_ids.empty() && !prod.water_terrain_ids.empty()) {
        base.water_terrain_ids = prod.water_terrain_ids;
    }
}

// sea_ice pure kernel — 移植自 DCWorldExt::run_sea_ice_daily_pass（world_ext.cpp:6784）。
// 算法逐行 1:1 镜像 sync 路径主循环：
//   Phase A：build has_cold_neighbor[]（前一日 SIF 邻居快照）
//   Phase B：fraction 增量更新 + flip 候选收集
//
// 关键依赖：
//   - is_water_lut（256-entry 表，由 water_terrain_ids 构建）
//   - cell_temperature_arr（climate/ocean 之后调整的 T——主线程算）
//   - sea_ice_freeze_gate / sea_ice_solar_melt（已有 inline helper，worker 安全）
//
// 输入：in.{terrain, base_terrain, sea_ice_frac_inout, temp_transport_anomaly,
//           ocean_thermal_anomaly, upwelling_strength, insolation_now, cell_temperature_arr,
//           water_terrain_ids} + scalars + static knobs.neighbor_indices
// 输出：out.{sea_ice_frac, terrain, flipped_cell_indices, flipped_new_terrain}
//
// 注意：flipped lists 主线程在 poll 时消费（atlas dirty / map.terrain mirror sync）。
// out.terrain 已包含翻转结果（与 in.terrain 不同），主线程 poll 写 _slots[cell_terrain]
// 时若 apply_terrain_flips 为 true 则会同步生效。
bool _async_sea_ice_kernel_pure(const ClimateInputBuf &in,
                                       const ClimateRoundStaticKnobs &knobs,
                                       ClimateOutputBuf &out) {
    const int n = in.n_cells;
    if (n <= 0) return false;
    if ((int) in.terrain.size()                != n) return false;
    if ((int) in.base_terrain.size()           != n) return false;
    if ((int) in.sea_ice_frac_inout.size()     != n) return false;
    if ((int) in.temp_transport_anomaly.size() != n) return false;
    if ((int) in.ocean_thermal_anomaly.size()  != n) return false;
    if ((int) in.upwelling_strength.size()     != n) return false;
    if ((int) in.insolation_now.size()         != n) return false;
    if ((int) in.cell_temperature_arr.size()   != n) return false;
    if ((int) in.water_terrain_ids.size()      <= 0) return false;
    if ((int) knobs.neighbor_indices.size() < n * 6) return false;

    if ((int) out.sea_ice_frac.size() != n) out.sea_ice_frac.resize(n);
    // 起始冰量优先取生产 pass_b 消费点记录的那份（ClimatePassBInput.sea_ice_frac）。
    // pass_b 与 sea_ice 在同一天内读的是同一个值 —— 当天还没有人改写过它 —— 而
    // capture 侧的 sea_ice_frac_inout 是 tick 某一刻的 slot 快照，两者并不同时。
    // 没有生产记录时（例如生产这天没跑 pass_b）才退回快照。
    const float *frac_in = ((int) in.sea_ice_frac.size() == n)
        ? in.sea_ice_frac.data() : in.sea_ice_frac_inout.data();
    std::memcpy(out.sea_ice_frac.data(), frac_in, n * sizeof(float));
    if ((int) out.terrain.size() != n) out.terrain.resize(n);
    std::memcpy(out.terrain.data(), in.terrain.data(), n);
    out.flipped_cell_indices.clear();
    out.flipped_new_terrain.clear();

    SeaIceKnobs sk;
    sk.n_cells = n;
    sk.k_freeze = in.scalars.si_k_freeze;
    sk.k_melt = in.scalars.si_k_melt;
    sk.t_form = in.scalars.si_t_form;
    sk.t_melt = in.scalars.si_t_melt;
    sk.contagion = in.scalars.si_contagion;
    sk.threshold = in.scalars.si_threshold;
    sk.hysteresis = in.scalars.si_hysteresis;
    sk.ice_delay = in.scalars.si_ice_delay;
    sk.enable_ocean_heat_transport = in.scalars.si_enable_oht;
    sk.solar_gate_enabled = in.scalars.si_solar_gate_enabled;
    sk.freeze_insol_low = in.scalars.si_freeze_insol_low;
    sk.freeze_insol_high = in.scalars.si_freeze_insol_high;
    sk.solar_melt_start = in.scalars.si_solar_melt_start;
    sk.solar_melt_gain = in.scalars.si_solar_melt_gain;
    sk.min_thick_ice_solar_exposure = in.scalars.si_min_thick_ice_solar_exposure;
    sk.daily_delta_cap = in.scalars.si_daily_delta_cap;
    sk.edge_mix_rate = in.scalars.si_edge_mix_rate;
    sk.dt_days = in.scalars.si_dt_days;
    sk.terrain_lake_id = in.scalars.si_terrain_lake_id;
    sk.terrain_sea_ice_id = in.scalars.si_terrain_sea_ice_id;
    sk.terrain_ocean_id = in.scalars.si_terrain_ocean_id;

    SeaIceLanes sl;
    sl.terrain = in.terrain.data();
    sl.base_terrain = in.base_terrain.data();
    sl.cell_temperature = in.cell_temperature_arr.data();
    sl.temp_transport_anomaly =
        ((int) in.production_sea_ice_tta.size() == n)
            ? in.production_sea_ice_tta.data()
            : in.temp_transport_anomaly.data();
    sl.ocean_thermal_anomaly =
        ((int) in.production_sea_ice_oanom.size() == n)
            ? in.production_sea_ice_oanom.data()
            : in.ocean_thermal_anomaly.data();
    sl.upwelling_strength = in.upwelling_strength.data();
    sl.insolation_now = in.insolation_now.data();
    sl.water_terrain_ids = in.water_terrain_ids.data();
    sl.water_terrain_ids_size = (int) in.water_terrain_ids.size();
    sl.neighbor_indices = knobs.neighbor_indices.data();
    sl.sea_ice_frac = out.sea_ice_frac.data();

    SeaIceScratch scratch;
    SeaIceEmit emit;
    sea_ice_pure(sk, sl, scratch, emit);

    // 生产把两份 flip 列表分开回填给 GDScript，worker 侧的 out 只有一对
    // (indices, new_terrain)，所以在这里合成。顺序按生产的收集顺序：同一个主循环
    // 里按 cell idx 升序，to_ice 与 to_base 交错 —— 但两份列表各自升序且互斥，
    // 合并成一条时按 idx 归并即可复现同一序列。
    size_t a = 0, b = 0;
    const uint8_t ice_terr = uint8_t(sk.terrain_sea_ice_id & 0xFF);
    while (a < emit.flip_to_ice.size() || b < emit.flip_to_base.size()) {
        const bool take_ice = (b >= emit.flip_to_base.size()) ||
            (a < emit.flip_to_ice.size() && emit.flip_to_ice[a] <= emit.flip_to_base[b]);
        if (take_ice) {
            out.flipped_cell_indices.push_back(emit.flip_to_ice[a]);
            out.flipped_new_terrain.push_back(ice_terr);
            ++a;
        } else {
            out.flipped_cell_indices.push_back(emit.flip_to_base[b]);
            out.flipped_new_terrain.push_back(emit.flip_to_base_terrain[b]);
            ++b;
        }
    }
    if (in.scalars.si_apply_terrain_flips) {
        uint8_t *TR_OUT = out.terrain.data();
        for (size_t k = 0; k < out.flipped_cell_indices.size(); ++k) {
            const int idx = out.flipped_cell_indices[k];
            if (idx >= 0 && idx < n) TR_OUT[idx] = out.flipped_new_terrain[k];
        }
    }
    return true;
}

// transp pure kernel — 移植自 run_transpiration_pass（world_ext.cpp:7341）。
// 算法逐行 1:1，输入输出全 std::vector，不写 _slots，不调 _flush_slot_to_map。
// 输出在 out.moisture / out.moisture_dirty_indices / out.moisture_dirty_values。
//
// ✅ Stage 3 数据流闭环：worker loop 在每个 pass 跑完后把 out.field 同步回
// in.field，让后续 pass 读 in 就拿到 fresh 值。transp 是 round 最后 pass，
// 读 in.moisture 时 pass_b 已把它的输出同步回去（pass_b → in.moisture），
// 等价于 sync 路径里 transp 读 _slots[cell_moisture]（已被 pass_b 写过）。
//
// 返回 true 成功，false 表示 input 验证失败（输入维度不匹配）。
bool _async_transp_kernel_pure(const ClimateInputBuf &in,
                                      const ClimateRoundStaticKnobs &knobs,
                                      ClimateWorkBuf &work,
                                      ClimateOutputBuf &out) {
    const int n = in.n_cells;
    if (n <= 0) return false;
    if ((int)in.landform.size()   != n) return false;
    if ((int)in.vegetation.size() != n) return false;
    if ((int)in.moisture.size()   != n) return false;
    if ((int)knobs.neighbor_indices.size() < n * 6) return false;
    const int donor_size = (int)knobs.donor_table.size();
    if (donor_size <= 0) return false;

    const float outflow_rate = in.scalars.transp_outflow_rate;
    const float self_rate    = in.scalars.transp_self_rate;

    // 准备工作 buffer
    if ((int)work.deltas.size() != n) work.deltas.assign(n, 0.0f);
    else std::fill(work.deltas.begin(), work.deltas.end(), 0.0f);
    float *D = work.deltas.data();

    const uint8_t *LF  = in.landform.data();
    const uint8_t *VEG = in.vegetation.data();
    const float   *M_in = in.moisture.data();
    const int32_t *NB   = knobs.neighbor_indices.data();
    const float   *DON  = knobs.donor_table.data();

    // ─── Phase 1: compute deltas（与 sync 路径 1:1） ───
    for (int i = 0; i < n; ++i) {
        if (LF[i] <= 3) continue;             // skip water cells (LandformType.is_water)
        const uint8_t veg_id = VEG[i];
        if (veg_id >= donor_size) continue;    // safety
        const float trans = DON[veg_id];
        if (trans < 0.01f) continue;
        const float moist = M_in[i];
        const float output      = trans * moist;
        const float self_share = output * self_rate;

        const int base = i * 6;
        int valid_land_neighbors = 0;
        for (int d = 0; d < 6; ++d) {
            const int32_t nb_idx = NB[base + d];
            if (nb_idx < 0) continue;
            if (LF[nb_idx] <= 3) continue;     // 水面邻居不接受陆地蒸腾外溢
            ++valid_land_neighbors;
        }
        const float transported = valid_land_neighbors > 0 ? output * outflow_rate : 0.0f;
        D[i] += self_share - transported;
        const float nb_share = valid_land_neighbors > 0
            ? transported / float(valid_land_neighbors) : 0.0f;
        for (int d = 0; d < 6; ++d) {
            const int32_t nb_idx = NB[base + d];
            if (nb_idx < 0 || LF[nb_idx] <= 3) continue;
            D[nb_idx] += nb_share;
        }
    }

    // ─── Phase 2: apply deltas to output（先 copy input → output，再 +deltas） ───
    if ((int)out.moisture.size() != n) out.moisture.assign(n, 0.0f);
    std::memcpy(out.moisture.data(), M_in, n * sizeof(float));
    if ((int)out.moisture_dirty_indices.size() < n) {
        out.moisture_dirty_indices.assign(n, 0);
    }
    if ((int)out.moisture_dirty_values.size() < n) {
        out.moisture_dirty_values.assign(n, 0.0f);
    }
    int32_t *dirty_idx = out.moisture_dirty_indices.data();
    float   *dirty_val = out.moisture_dirty_values.data();
    int dirty_count = 0;

    float *M_out = out.moisture.data();
    for (int i = 0; i < n; ++i) {
        const float d = D[i];
        if (d == 0.0f) continue;
        float v = M_out[i] + d;
        if (v < 0.0f) v = 0.0f;
        else if (v > 1.0f) v = 1.0f;
        if (M_out[i] != v) {
            M_out[i] = v;
            dirty_idx[dirty_count] = i;
            dirty_val[dirty_count] = v;
            ++dirty_count;
        }
    }
    out.moisture_dirty_indices.resize(dirty_count);
    out.moisture_dirty_values.resize(dirty_count);
    return true;
}

// ─── finalizer kernel（Stage 9，2026-06-16） ──────────────────────────────
// 移植自 GDScript ClimateDailySystem::_apply_daily_climate_finalizer
// (climate_daily_system.gd:586)。
//
// 行为完全 1:1（含 mirror_temperature_cells / TTA clamp / thermal init / sort /
// percentile / sea_ice_delta_max / precip_p95）。但有几点关键区别：
//   1. 不写 HexCell facade（worker thread 不能碰 Godot Object）。GDScript 端
//      在 facade 启用时 mirror=false，cell.temperature getter 直接走 SoA，所以
//      worker 写 out.temp + 主线程 publish_to_slot 完全等价。facade 关闭时
//      （兼容 fallback 路径）GDScript 自己跑 finalizer。
//   2. 读 in.temp / in.tta / in.thermal_energy / in.ema_initialized / in.sea_ice_frac /
//      in.sea_ice_frac_prev / in.weather_precip。
//   3. 输入 baseline：in.temp_start_of_day / in.tta_start_of_day。size==n 时
//      启用 clamp，否则跳过（diag 仍累计 max_delta）。
//   4. 写 out.temp（覆盖 wind_surface 的输出）/ out.tta（in/out aliasing —
//      需要先 copy in→out 再 clamp）/ out.thermal_energy（覆盖 pass_a 的输出）。
//
// 返回 true 成功 / false 输入维度问题。
bool _async_finalizer_kernel_pure(const ClimateInputBuf &in,
                                         ClimateOutputBuf &out) {
    const int n = in.n_cells;
    if (n <= 0) return false;
    if ((int) in.temp.size() != n) return false;
    if ((int) in.temp_transport_anomaly.size() != n) return false;
    if ((int) in.thermal_energy.size() != n) return false;

    // wind_surface 是 out.temp 的唯一写者（round 最终 temp），finalizer 在它之上 cap。
    // mask 关掉 wind_surface 时用 in.temp 兜底。
    if ((int) out.temp.size() != n) {
        out.temp.assign(size_t(n), 0.0f);
        std::memcpy(out.temp.data(), in.temp.data(), size_t(n) * sizeof(float));
    }
    if ((int) out.tta_final.size() != n) out.tta_final.assign(size_t(n), 0.0f);
    std::memcpy(out.tta_final.data(), in.temp_transport_anomaly.data(),
                size_t(n) * sizeof(float));
    if ((int) out.thermal_energy.size() != n) out.thermal_energy.assign(size_t(n), 0.0f);
    std::memcpy(out.thermal_energy.data(), in.thermal_energy.data(),
                size_t(n) * sizeof(float));

    const bool has_temp_start = in.scalars.fin_has_temp_start
                                && (int) in.temp_start_of_day.size() == n;
    const bool has_tta_start = in.scalars.fin_has_tta_start
                               && (int) in.tta_start_of_day.size() == n;

    FinalizerKnobs fk;
    fk.n_cells = n;
    fk.temp_cap_enabled = in.scalars.fin_temp_cap_enabled;
    fk.temp_cap = double(in.scalars.fin_temp_cap);
    fk.tta_cap = double(in.scalars.fin_tta_cap);
    fk.has_temp_start = has_temp_start;
    fk.has_tta_start = has_tta_start;

    std::vector<float> temp_deltas(size_t(n), 0.0f);
    std::vector<float> preclamp_temp_deltas(size_t(n), 0.0f);

    FinalizerLanes fl;
    fl.temp_start = has_temp_start ? in.temp_start_of_day.data() : nullptr;
    fl.tta_start = has_tta_start ? in.tta_start_of_day.data() : nullptr;
    fl.ema = in.ema_initialized.empty() ? nullptr : in.ema_initialized.data();
    fl.ema_size = (int) in.ema_initialized.size();
    fl.temp = out.temp.data();
    fl.tta = out.tta_final.data();
    fl.thermal = out.thermal_energy.data();
    fl.temp_deltas = temp_deltas.data();
    fl.preclamp_temp_deltas = preclamp_temp_deltas.data();

    FinalizerStats fs;
    finalizer_pure(fk, fl, fs);

    out.fin_max_temp_delta = float(fs.max_temp_delta);
    out.fin_preclamp_max_temp_delta = float(fs.preclamp_max_temp_delta);
    out.fin_temp_delta_gt_005_count = fs.temp_delta_gt_005;
    out.fin_temp_delta_gt_010_count = fs.temp_delta_gt_010;
    out.fin_temp_delta_gt_020_count = fs.temp_delta_gt_020;
    out.fin_temp_delta_clamped_count = fs.temp_clamped;
    out.fin_max_transport_anomaly = float(fs.max_transport_anomaly);
    out.fin_tta_clamped_count = fs.tta_clamped;
    out.fin_thermal_init_count = fs.thermal_init;

    // p95 / p99 是 worker 独有的观测量，生产不算，所以留在适配器里。
    std::sort(temp_deltas.begin(), temp_deltas.end());
    std::sort(preclamp_temp_deltas.begin(), preclamp_temp_deltas.end());
    auto percentile = [](const std::vector<float> &sorted, double pct) -> float {
        if (sorted.empty()) return 0.0f;
        const int idx = std::min((int) sorted.size() - 1,
                                 (int) std::floor(double(sorted.size() - 1) * pct));
        return sorted[size_t(idx)];
    };
    out.fin_p95_temp_delta = percentile(temp_deltas, 0.95);
    out.fin_p99_temp_delta = percentile(temp_deltas, 0.99);
    out.fin_preclamp_p99_temp_delta = percentile(preclamp_temp_deltas, 0.99);

    // ── sea_ice_delta_max（仅当 in.sea_ice_frac / in.sea_ice_frac_prev 都齐） ──
    out.fin_sea_ice_delta_max = 0.0f;
    if ((int)in.sea_ice_frac.size() == n && (int)in.sea_ice_frac_prev.size() == n) {
        const float *SIF = in.sea_ice_frac.data();
        const float *SIFp = in.sea_ice_frac_prev.data();
        float max_ds = 0.0f;
        for (int i = 0; i < n; ++i) {
            const float ds = std::fabs(SIF[i] - SIFp[i]);
            if (ds > max_ds) max_ds = ds;
        }
        out.fin_sea_ice_delta_max = max_ds;
    }

    // ── precip_p95（sort weather_precip duplicate） ──
    out.fin_precip_p95 = 0.0f;
    if ((int)in.weather_precip.size() == n) {
        std::vector<float> precip_vals(in.weather_precip);
        std::sort(precip_vals.begin(), precip_vals.end());
        out.fin_precip_p95 = percentile(precip_vals, 0.95f);
    }

    out.fin_cells_seen = n;
    out.fin_applied = true;
    return true;
}


// ─── 生产 pass_a 输入叠加（见头文件注释）─────────────────────────────
namespace {

// Names every per-cell lane that still differs after the pass_a overlay. Some
// differences are expected — a lane the worker owns (vapor, cloud, sea ice) is
// the thing being compared, not an input — so this prints everything and leaves
// the judgement to the reader. On the first round of a run nothing has diverged
// yet, so on that day every entry here is an input bug.
bool pk_lane_diag_enabled() {
    static const bool on = [] {
        const char *v = std::getenv("PK_CLIMATE_LANE_DIAG");
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
        const char *v = std::getenv("PK_CLIMATE_SCALAR_DIAG");
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


// ─── albedo（stage 8）─────────────────────────────────────────────────
//
// 从 DCWorldExt::run_albedo_pass 的主循环逐字搬来（原 lambda run_range）。水格跳过，
// 陆格按 vegetation 查反照率、雪/冰川抬底，再把 (reference - alb) * gain 叠到温度上并
// clamp 到 [0,1]。零邻居、零状态，是 stage 8..13 里唯一能原样搬迁的一段。
void albedo_apply_pure(const ClimateAlbedoKnobs &knobs,
                       const uint8_t *is_water,
                       const uint8_t *vegetation,
                       const uint8_t *cover,
                       const float *albedo_table,
                       int albedo_size,
                       float *temp,
                       int n_cells) {
    if (!knobs.ran || n_cells <= 0 || albedo_size <= 0) return;
    if (is_water == nullptr || vegetation == nullptr || cover == nullptr ||
        albedo_table == nullptr || temp == nullptr) {
        return;
    }
    for (int i = 0; i < n_cells; ++i) {
        if (is_water[i] != 0) continue;                     // skip water cells
        const uint8_t veg_id = vegetation[i];
        float alb = (veg_id < albedo_size) ? albedo_table[veg_id] : 0.0f;
        const uint8_t cover_id = cover[i];
        if (cover_id == knobs.cover_snow_id ||
            cover_id == knobs.cover_glacier_id) {
            if (alb < knobs.snow_cover_albedo) alb = knobs.snow_cover_albedo;
        }
        const float dt = (knobs.reference_albedo - alb) * knobs.temp_gain;
        float v = temp[i] + dt;
        if (v < 0.0f) v = 0.0f;
        else if (v > 1.0f) v = 1.0f;
        temp[i] = v;
    }
}


// ─── climate_feedback（stage 10）───────────────────────────────────────
//
// 从 DCWorldExt::run_climate_feedback_pass 的 run_range lambda 逐字搬来。生产侧原有
// 三份逐字副本（run_climate_feedback_pass / _thread / run_stage_b_pass ③ 段），全部
// 转发到这里。
//
// 两段独立的作用：① 海洋 TTA 经海岸格漂移进 base_moisture（年尺度，每日 clamp）；
// ② 天气强度按类型折成 precip，累加进 soil_moisture / base_moisture / VGP。
// ② 段以 wi < 0.01 提前 continue，所以 ① 段必须排在它前面 —— 顺序是行为的一部分。
void climate_feedback_apply_pure(const ClimateFeedbackKnobs &knobs,
                                 const uint8_t *is_water,
                                 const uint8_t *weather_type,
                                 const float *weather_intensity,
                                 const uint8_t *weather_field_init,
                                 const int32_t *neighbor_indices,
                                 const float *temp_transport_anomaly,
                                 float *base_moisture,
                                 float *soil_moisture,
                                 float *veg_growth_pressure,
                                 int begin,
                                 int end) {
    if (!knobs.ran || begin >= end) return;
    if (is_water == nullptr || weather_type == nullptr ||
        weather_intensity == nullptr || weather_field_init == nullptr ||
        neighbor_indices == nullptr || temp_transport_anomaly == nullptr ||
        base_moisture == nullptr || soil_moisture == nullptr) {
        return;
    }
    const float soil_gain = knobs.soil_gain;
    const float veg_gain = knobs.veg_gain;
    const float scale = knobs.scale;
    const float per_day_clamp = knobs.per_day_clamp;
    const float ocean_drift_gain = knobs.ocean_drift_gain;
    const float base_m_gain = knobs.base_moisture_gain;
    const bool write_vgp =
        knobs.write_weather_veg_pressure && veg_growth_pressure != nullptr;

    for (int i = begin; i < end; ++i) {
        if (is_water[i] != 0) continue;                        // skip water cells

        // ① ocean → base_moisture drift（年尺度，每日 |Δ| ≤ per_day_clamp）
        if (ocean_drift_gain > 0.0f) {
            float sum_an = 0.0f;
            int   n_water = 0;
            const int base = i * 6;
            for (int d = 0; d < 6; ++d) {
                const int32_t ni = neighbor_indices[base + d];
                if (ni < 0) continue;
                if (is_water[ni] != 0) {
                    sum_an += temp_transport_anomaly[ni];
                    n_water += 1;
                }
            }
            if (n_water > 0) {
                const float avg_an = sum_an / float(n_water);
                if (std::fabs(avg_an) > 0.005f) {
                    float coastal_ratio = float(n_water) / 6.0f;
                    if (coastal_ratio > 1.0f) coastal_ratio = 1.0f;
                    float d_base = ocean_drift_gain * avg_an * coastal_ratio * scale;
                    if (d_base < -per_day_clamp) d_base = -per_day_clamp;
                    else if (d_base > per_day_clamp) d_base = per_day_clamp;
                    float bm = base_moisture[i] + d_base;
                    if (bm < 0.0f) bm = 0.0f;
                    else if (bm > 1.0f) bm = 1.0f;
                    base_moisture[i] = bm;
                }
            }
        }

        // ② weather → soil / vegetation_growth_pressure 累加（小权重）
        const bool init = weather_field_init[i] != 0;
        const int   wt = init ? int(weather_type[i]) : -1;   // -1 = uninit (== CLEAR)
        const float wi = init ? weather_intensity[i] : 0.0f;
        if (wi < 0.01f) continue;

        float precip = 0.0f;
        if      (wt == knobs.wt_rain_id)     precip = wi;
        else if (wt == knobs.wt_storm_id)    precip = wi * 0.8f;
        else if (wt == knobs.wt_monsoon_id)  precip = wi * 1.2f;
        else if (wt == knobs.wt_blizzard_id) precip = wi * 0.3f;
        else if (wt == knobs.wt_drought_id)  precip = -wi * 0.6f;
        else if (wt == knobs.wt_heatwave_id) precip = -wi * 0.4f;
        // else: precip = 0.0 (CLEAR / FOG / etc.)

        // soil_moisture (clamp -0.5..0.5)
        float d_soil = soil_gain * precip * scale;
        if (d_soil < -per_day_clamp) d_soil = -per_day_clamp;
        else if (d_soil > per_day_clamp) d_soil = per_day_clamp;
        float soil = soil_moisture[i] + d_soil;
        if (soil < -0.5f) soil = -0.5f;
        else if (soil > 0.5f) soil = 0.5f;
        soil_moisture[i] = soil;

        // 让天气流动(2026-06-21)：weather → base_moisture 直接反馈。
        if (base_m_gain > 0.0f) {
            float d_bm = base_m_gain * precip * scale;
            if (d_bm < -per_day_clamp) d_bm = -per_day_clamp;
            else if (d_bm > per_day_clamp) d_bm = per_day_clamp;
            float bmw = base_moisture[i] + d_bm;
            if (bmw < 0.0f) bmw = 0.0f;
            else if (bmw > 1.0f) bmw = 1.0f;
            base_moisture[i] = bmw;
        }

        if (write_vgp) {
            // vegetation_growth_pressure (clamp -0.5..0.5)
            float d_veg = veg_gain * precip * scale;
            if (d_veg < -per_day_clamp) d_veg = -per_day_clamp;
            else if (d_veg > per_day_clamp) d_veg = per_day_clamp;
            float vg_v = veg_growth_pressure[i] + d_veg;
            if (vg_v < -0.5f) vg_v = -0.5f;
            else if (vg_v > 0.5f) vg_v = 0.5f;
            veg_growth_pressure[i] = vg_v;
        }
    }
}


// ─── vegetation_dynamics pure kernel（stage 9）─────────────────────────────
//
// S3 搬迁体：原位是 world_ext_climate.cpp 的三份逐字副本
// （run_vegetation_dynamics_pass / _thread / run_stage_b_pass ② 段）。逐字搬迁，
// 无算法改动。stress_enabled 分支合并了两处差异：
//   - 独立 pass 的退化条件 `target < low || (severe && target < high)`
//   - stage_b 的 `((stress && stress_max>0.65) || severe) && target < high`
//     后接 `else if (degrade && target < low)`
// 在 stress_enabled=false 时两者等价（stress_days == streak_days），所以一份实现
// 覆盖两条路径。

static inline float vegdyn_clamp01(float v) {
    if (v < 0.0f) return 0.0f;
    if (v > 1.0f) return 1.0f;
    return v;
}

static inline float vegdyn_compat_climate(
        int vg,
        float temp,
        float plant_water,
        int n_veg,
        const VegetationDynamicsTables &t) {
    if (vg < 0 || vg >= n_veg) return -1.0f;
    return pk_vegetation_climate_score_for_type(
        uint8_t(vg), temp, plant_water,
        t.ideal_temp[vg], t.ideal_moist[vg], t.temp_tol[vg], t.moist_tol[vg]);
}

static inline float vegdyn_compat_of(
        int vg,
        float temp,
        float plant_water,
        int n_veg,
        const VegetationDynamicsTables &t,
        uint8_t terrain,
        uint8_t landform) {
    const float climate = vegdyn_compat_climate(vg, temp, plant_water, n_veg, t);
    if (climate < 0.0f) return climate;
    return climate * pk_vegetation_terrain_weight(terrain, landform, uint8_t(vg), plant_water);
}

static inline uint8_t vegdyn_best_transition(
        uint8_t current,
        float temp,
        float plant_water,
        int n_veg,
        const VegetationDynamicsTables &t,
        uint8_t terrain,
        uint8_t landform,
        float &best_score) {
    uint8_t best = current;
    best_score = -1.0f;
    if (current >= n_veg) return best;
    for (int candidate = 1; candidate < n_veg; ++candidate) {
        if (candidate == current || !pk_vegetation_candidate_allowed(terrain, uint8_t(candidate))) continue;
        const float score = vegdyn_compat_of(
            candidate, temp, plant_water, n_veg, t, terrain, landform);
        if (score > best_score) {
            best = uint8_t(candidate);
            best_score = score;
        }
    }
    return best;
}

static inline float vegdyn_weather_stress(
        uint8_t v_id,
        int wt,
        float wi,
        int n_veg,
        int n_wt,
        int wt_pen_size,
        const VegetationDynamicsTables &t,
        float weather_penalty_scale) {
    const float base_pen = (wt >= 0 && wt < wt_pen_size) ? t.weather_penalty[wt] : 0.0f;
    float resist = 0.0f;
    if (v_id < n_veg && wt >= 0 && wt < n_wt) {
        resist = t.resistance[int(v_id) * n_wt + wt];
    }
    return base_pen * weather_penalty_scale * (wi > 0.0f ? wi : 0.0f) * (1.0f - resist);
}

void vegetation_dynamics_apply_pure(const VegetationDynamicsKnobs &knobs,
                                    const VegetationDynamicsTables &t,
                                    const VegetationDynamicsLanes &io,
                                    int begin,
                                    int end,
                                    VegetationDynamicsEmit &emit) {
    if (!knobs.ran || begin >= end) return;
    if (knobs.n_veg <= 0 || knobs.n_wt <= 0) return;
    if (t.ideal_temp == nullptr || t.ideal_moist == nullptr ||
        t.temp_tol == nullptr || t.moist_tol == nullptr ||
        t.weather_penalty == nullptr || t.resistance == nullptr ||
        t.next_up == nullptr) {
        return;
    }
    if (io.is_water == nullptr || io.terrain == nullptr || io.landform == nullptr ||
        io.vegetation == nullptr || io.temp_30d == nullptr || io.moisture == nullptr ||
        io.water_balance_30d == nullptr || io.weather_type == nullptr ||
        io.weather_intensity == nullptr || io.weather_field_init == nullptr ||
        io.plant_available_water == nullptr || io.vitality == nullptr ||
        io.low_streak == nullptr || io.high_streak == nullptr) {
        return;
    }
    const bool stress = knobs.stress_enabled;
    if (stress && (io.heat_stress == nullptr || io.drought_stress == nullptr ||
                   io.cold_stress == nullptr || io.regen_score == nullptr)) {
        return;
    }

    const int   n_veg = knobs.n_veg;
    const int   n_wt = knobs.n_wt;
    const int   wt_pen_size = knobs.wt_pen_size;
    const float scale = knobs.scale;
    const int   streak_days = knobs.streak_days;
    const float rate = knobs.vitality_change_rate;
    const float harshness = knobs.compat_harshness;
    const float low_thresh = knobs.low_threshold;
    const float high_thresh = knobs.high_threshold;
    const int   degrade_days = knobs.succession_degrade_days;
    const int   upgrade_days = knobs.succession_upgrade_days;
    const int   wt_clear_id = knobs.wt_clear_id;
    const uint8_t veg_none_id = knobs.veg_none_id;
    const float weather_penalty_scale = knobs.weather_penalty_scale;
    const float low_vitality_damping_threshold = knobs.low_vitality_damping_threshold;
    const int   succession_cooldown_days = knobs.succession_cooldown_days;
    const float stress_blend = knobs.stress_blend;

    for (int i = begin; i < end; ++i) {
        const uint8_t v_id = io.vegetation[i];
        const float soil_now = io.soil_moisture != nullptr ? io.soil_moisture[i] : 0.0f;
        const float plant_water = io.is_water[i] != 0 ? 0.0f : pk_plant_available_water(
            io.moisture[i], io.water_balance_30d[i], soil_now,
            knobs.plant_water_balance_weight, knobs.plant_soil_buffer_weight,
            knobs.plant_drought_penalty);
        io.plant_available_water[i] = plant_water;
        if (io.is_water[i] != 0 || v_id == veg_none_id) {
            io.vitality[i] = 0.0f;
            io.low_streak[i] = 0;
            io.high_streak[i] = 0;
            if (io.vegetation_growth_pressure != nullptr) io.vegetation_growth_pressure[i] = 0.0f;
            if (stress) {
                io.heat_stress[i] = 0.0f;
                io.drought_stress[i] = 0.0f;
                io.cold_stress[i] = 0.0f;
                io.regen_score[i] = 0.0f;
            }
            continue;
        }
        const uint8_t terrain = io.terrain[i];
        const uint8_t landform = io.landform[i];
        const float temp = io.temp_30d[i];
        const float compat = vegdyn_compat_of(v_id, temp, plant_water, n_veg, t, terrain, landform);

        int wt = wt_clear_id;
        float wi = 0.0f;
        const bool wt_init = io.weather_field_init[i] != 0;
        if (wt_init) {
            wt = int(io.weather_type[i]);
            wi = io.weather_intensity[i];
        }
        const float weather_stress = vegdyn_weather_stress(
            v_id, wt, wi, n_veg, n_wt, wt_pen_size, t, weather_penalty_scale);

        float stress_max = 0.0f;
        float regen_score = 0.0f;
        if (stress) {
            float heat_input = 0.0f;
            float cold_input = 0.0f;
            float drought_input = 0.0f;
            if (v_id < n_veg) {
                const float temp_tol = std::max(t.temp_tol[v_id], 0.05f);
                const float moist_tol = std::max(t.moist_tol[v_id], 0.05f);
                heat_input = vegdyn_clamp01((temp - (t.ideal_temp[v_id] + temp_tol)) / temp_tol);
                cold_input = vegdyn_clamp01(((t.ideal_temp[v_id] - temp_tol) - temp) / temp_tol);
                const float water_deficit = vegdyn_clamp01(((t.ideal_moist[v_id] - moist_tol) - plant_water) / moist_tol);
                drought_input = water_deficit;
                if (wt_init && wt == knobs.wt_drought_id) {
                    drought_input = std::max(drought_input, water_deficit * vegdyn_clamp01(wi));
                }
            }
            if (wt_init) {
                const float wi_clamped = vegdyn_clamp01(wi);
                if (wt == knobs.wt_heatwave_id) {
                    heat_input = std::max(heat_input, wi_clamped);
                } else if (wt == knobs.wt_blizzard_id) {
                    cold_input = std::max(cold_input, wi_clamped);
                }
            }
            const float regen_input = vegdyn_clamp01(compat * (1.0f - weather_stress) * (0.5f + 0.5f * plant_water));
            const float heat = io.heat_stress[i] + (heat_input - io.heat_stress[i]) * stress_blend;
            const float drought = io.drought_stress[i] + (drought_input - io.drought_stress[i]) * stress_blend;
            const float cold = io.cold_stress[i] + (cold_input - io.cold_stress[i]) * stress_blend;
            const float regen = io.regen_score[i] + (regen_input - io.regen_score[i]) * stress_blend;
            io.heat_stress[i] = heat;
            io.drought_stress[i] = drought;
            io.cold_stress[i] = cold;
            io.regen_score[i] = regen;
            stress_max = std::max(heat, std::max(drought, cold));
            regen_score = regen;
        }

        float water_pressure = io.water_balance_30d[i] * 0.18f + soil_now * 0.10f;
        if (water_pressure < -0.12f) water_pressure = -0.12f;
        else if (water_pressure > 0.12f) water_pressure = 0.12f;
        const float target = stress
            ? vegdyn_clamp01(compat + water_pressure - weather_stress - stress_max * 0.25f + regen_score * 0.10f)
            : vegdyn_clamp01(compat + water_pressure - weather_stress);
        const float prev_vit = io.vitality[i];
        float dv = (target - prev_vit) * rate;
        if (dv < 0.0f) {
            dv *= harshness;
            if (low_vitality_damping_threshold > 0.0f && prev_vit < low_vitality_damping_threshold) {
                float damping = prev_vit / low_vitality_damping_threshold;
                if (damping < 0.25f) damping = 0.25f;
                else if (damping > 1.0f) damping = 1.0f;
                dv *= damping;
            }
        }
        if (io.vegetation_growth_pressure != nullptr) {
            io.vegetation_growth_pressure[i] = target - prev_vit;
        }

        const float vit = vegdyn_clamp01(prev_vit + dv * scale);
        io.vitality[i] = vit;

        int ls = io.low_streak[i];
        int hs = io.high_streak[i];
        if (ls < 0 || hs < 0) {
            ls += streak_days; if (ls > 0) ls = 0;
            hs += streak_days; if (hs > 0) hs = 0;
            io.low_streak[i] = ls;
            io.high_streak[i] = hs;
            continue;
        }

        const uint8_t nxt_up_for_streak = (v_id < n_veg) ? t.next_up[v_id] : v_id;
        const float nxt_up_score_for_streak = (nxt_up_for_streak != v_id &&
                                               pk_vegetation_candidate_allowed(terrain, nxt_up_for_streak))
            ? vegdyn_compat_of(nxt_up_for_streak, temp, plant_water, n_veg, t, terrain, landform)
            : -1.0f;
        const bool upgrade_candidate =
            nxt_up_for_streak != v_id &&
            nxt_up_score_for_streak >= compat + knobs.succession_min_compat_gain &&
            nxt_up_score_for_streak >= high_thresh;
        float best_transition_score = -1.0f;
        const uint8_t best_transition = vegdyn_best_transition(
            v_id, temp, plant_water, n_veg, t, terrain, landform, best_transition_score);
        const bool degrade_candidate = best_transition != v_id &&
            best_transition_score >= compat + knobs.succession_min_compat_gain;
        const bool severe_biome_mismatch = pk_vegetation_needs_biome_reconcile(terrain, v_id);
        if (degrade_candidate &&
            ((stress && stress_max > 0.65f) || severe_biome_mismatch) &&
            target < high_thresh) {
            const int stress_days = std::max(streak_days, int(std::round(float(streak_days) * stress_max)));
            ls += stress_days;
            hs = 0;
        } else if (degrade_candidate && target < low_thresh) {
            ls += streak_days;
            hs = 0;
        } else if (upgrade_candidate && vit > low_thresh && target > low_thresh) {
            hs += streak_days;
            ls = 0;
        } else {
            ls -= streak_days; if (ls < 0) ls = 0;
            hs -= streak_days; if (hs < 0) hs = 0;
        }

        bool fired = false;
        if (ls >= degrade_days) {
            if (degrade_candidate) {
                emit.indices.push_back(i);
                emit.to_veg.push_back(best_transition);
                const int cooldown = succession_cooldown_days > 0 ? -succession_cooldown_days : 0;
                ls = cooldown;
                hs = cooldown;
                fired = true;
            } else {
                // 没有下家：把 ls 清零防止反复触发（与 GDScript 一致）
                ls = 0;
            }
        }
        if (!fired && hs >= upgrade_days) {
            const uint8_t nxt = (v_id < n_veg) ? t.next_up[v_id] : v_id;
            const float nxt_sc = (nxt != v_id && pk_vegetation_candidate_allowed(terrain, nxt))
                ? vegdyn_compat_of(nxt, temp, plant_water, n_veg, t, terrain, landform) : -1.0f;
            if (nxt != v_id && nxt_sc >= compat + knobs.succession_min_compat_gain) {
                emit.indices.push_back(i);
                emit.to_veg.push_back(nxt);
                const int cooldown = succession_cooldown_days > 0 ? -succession_cooldown_days : 0;
                ls = cooldown;
                hs = cooldown;
            } else {
                hs = 0;
            }
        }
        io.low_streak[i] = ls;
        io.high_streak[i] = hs;
    }
}


// ─── Round 编排（9 pass 串联，生产 worker main 与 runtime worker 共用）──────
//
// S3：这段编排本身也必须共享。它决定 pass 顺序、mask 门控、尺寸守卫，以及每个
// pass 写完后哪些字段要刷回 in 供后续 pass 读（sync 路径靠 _flush_slot_to_map +
// refresh_slots_from_map 达到同样效果）。复制一份到 runtime worker 就等于重新引入
// “两套实现”——顺序或接力字段差一条，分叉矩阵就会把它报成算法分叉。
//
// in 是 in/out：逐 pass 的接力就写在它上面，所以调用方必须传自己的可变副本
// （生产是 worker 私有的 w_in_buf，runtime worker 是 kernel 的 scratch buf）。

// Stage breadcrumb。worker 线程上的访存违例会绕过 Godot 的 crash handler，日志里
// 看不到栈。开 PK_CLIMATE_STAGE_TRACE=1 后每个 stage 前写一行并 flush，崩溃后日志
// 最后一行就是出事的 stage。默认关，开关只读一次。
static bool pk_stage_trace_enabled() {
    static const bool on = [] {
        const char *v = std::getenv("PK_CLIMATE_STAGE_TRACE");
        return v != nullptr && v[0] == '1';
    }();
    return on;
}

static void pk_stage_trace(const char *stage, int day, int n_cells, uint32_t mask) {
    if (!pk_stage_trace_enabled()) return;
    std::fprintf(stderr, "[climate][stage-trace] day=%d mask=0x%X n=%d -> %s\n",
                 day, mask, n_cells, stage);
    std::fflush(stderr);
}

bool run_climate_round_passes(ClimateInputBuf &in,
                              const ClimateRoundStaticKnobs &knobs,
                              ClimateWorkBuf &work,
                              ClimateOutputBuf &out,
                              ClimateRoundPassTiming *timing) {
    using clock = std::chrono::steady_clock;
    bool ok = true;
    const int mask = in.scalars.passes_mask;

    // ─── pass_a（bit 0） ──────────────────────────────────────────
    pk_stage_trace("pass_a", -1, in.n_cells, mask);
    const auto pa0 = clock::now();
    if ((mask & 0x01) != 0 && (int)in.is_water.size() == in.n_cells) {
        // 输入完整时跑 pass_a pure kernel
        if (timing) timing->passes_ran |= 0x1;
        if (!_async_pass_a_kernel_pure(in, out)) {
            ok = false;
        }
        // Round 数据流：pass_a 写的字段刷新到 in，让后续 pass 读到 fresh 值。
        // sync 路径里 pass_a 通过 _flush_slot_to_map 把 16 个 slot 推回 MapData，
        // 然后下一 pass 入口的 refresh_slots_from_map 把 _slots 又拉到最新。
        // async 路径不走 MapData，但同 round 内的"上一 pass 写 → 下一 pass 读"
        // 必须用 in/out 同步实现。
        // 注：pass_a 是 round 第一个 pass，没有前序 pass 写过 in 字段；只刷新
        // pass_a 的输出回 in，让 pass_b / ocean_water / wind_air / transp 等读到。
        const int n_pa = in.n_cells;
        if (n_pa > 0) {
            auto cp_if_size = [n_pa](std::vector<float> &dst, const std::vector<float> &src) {
                if ((int)src.size() == n_pa) {
                    if ((int)dst.size() != n_pa) dst.resize(n_pa);
                    std::memcpy(dst.data(), src.data(), n_pa * sizeof(float));
                }
            };
            auto cp_if_size_u8 = [n_pa](std::vector<uint8_t> &dst, const std::vector<uint8_t> &src) {
                if ((int)src.size() == n_pa) {
                    if ((int)dst.size() != n_pa) dst.resize(n_pa);
                    std::memcpy(dst.data(), src.data(), n_pa);
                }
            };
            // pass_b 读这些字段：temp_baseline / moisture / snow_cover / insolation_dev
            // ocean_water 读 temp_baseline (作 baseline_arr)；其他 pass 间接读
            cp_if_size(in.moisture,         out.moisture);
            cp_if_size(in.temp_baseline,    out.temp_baseline);
            cp_if_size(in.insolation_dev,   out.insolation_dev);
            // sea_ice 的 solar gate 与融冰量读 in.insolation_now。漏掉这一行，它读到的
            // 是 capture 快照里的全零（该 slot 在 capture 时刻还没被这一天的 pass_a
            // 写过），于是 freeze_gate / solar_melt 整场按"永夜"走 —— 生产读的是
            // pass_a 刚算出的真值。
            cp_if_size(in.insolation_now,   out.insolation_now);
            cp_if_size(in.thermal_energy,   out.thermal_energy);
            cp_if_size(in.snowpack,         out.snowpack);
            cp_if_size(in.temp_30d,         out.temp_30d);
            cp_if_size(in.temp_365d,        out.temp_365d);
            cp_if_size_u8(in.ema_initialized, out.ema_initialized);
            // ocean / local anomaly 被 pass_a 清 0；同步给 pass_b/ocean_*
            cp_if_size(in.ocean_thermal_anomaly, out.ocean_thermal_anomaly);
            cp_if_size(in.local_thermal_anomaly, out.local_thermal_anomaly);
        }
    }
    const auto pa1 = clock::now();
    if (timing) timing->pass_us[0] =
        (int64_t)std::chrono::duration_cast<std::chrono::microseconds>(
            pa1 - pa0).count();
    if (timing && (mask & 0x1) != 0 &&
        (timing->passes_ran & 0x1) == 0) {
        timing->passes_starved |= 0x1;
    }

    // ─── pass_b（bit 1） ──────────────────────────────────────────
    pk_stage_trace("pass_b", -1, in.n_cells, mask);
    const auto pb0 = clock::now();
    if ((mask & 0x02) != 0
            && (int)in.is_water.size()       == in.n_cells
            && (int)in.landform.size()       == in.n_cells
            && (int)in.vegetation.size()     == in.n_cells
            && (int)in.snowpack.size()       == in.n_cells
            && (int)in.elevation.size()      == in.n_cells
            && (int)in.lat_norm.size()       == in.n_cells
            && (int)in.pos_x.size()          == in.n_cells
            && (int)in.pos_y.size()          == in.n_cells
            && (int)in.insolation_dev.size() == in.n_cells
            && (int)in.temp.size()           == in.n_cells
            && (int)in.moisture.size()       == in.n_cells
            && (int)in.local_thermal_anomaly.size() == in.n_cells
            && (int)in.temp_transport_anomaly.size() == in.n_cells
            && (int)knobs.foliage_table.size() > 0) {
        if (timing) timing->passes_ran |= 0x2;
        if (!_async_pass_b_kernel_pure(in, knobs, out)) {
            ok = false;
        }
        // Round 数据流：pass_b 写 moisture（覆盖 pass_a）+ local_thermal_anomaly。
        // 同步给 ocean_water/land 和 wind_air/surface 等后续 pass。
        const int n_pb = in.n_cells;
        if (n_pb > 0) {
            if (((int)out.moisture.size() == n_pb)
                    && (int) in.moisture.size() == n_pb) {
                std::memcpy(in.moisture.data(),
                            out.moisture.data(), n_pb * sizeof(float));
            }
            if (((int)out.local_thermal_anomaly.size() == n_pb)
                    && (int) in.local_thermal_anomaly.size() == n_pb) {
                std::memcpy(in.local_thermal_anomaly.data(),
                            out.local_thermal_anomaly.data(), n_pb * sizeof(float));
            }
        }
    }
    const auto pb1 = clock::now();
    if (timing) timing->pass_us[1] =
        (int64_t)std::chrono::duration_cast<std::chrono::microseconds>(
            pb1 - pb0).count();
    if (timing && (mask & 0x2) != 0 &&
        (timing->passes_ran & 0x2) == 0) {
        timing->passes_starved |= 0x2;
    }

    // ─── ocean_water（bit 2） ─────────────────────────────────────
    pk_stage_trace("ocean_water", -1, in.n_cells, mask);
    const auto ow0 = clock::now();
    if ((mask & 0x04) != 0
            && (int)in.is_water.size()        == in.n_cells
            && (int)in.pos_x.size()           == in.n_cells
            && (int)in.pos_y.size()           == in.n_cells
            && (int)in.ocean_current_x.size() == in.n_cells
            && (int)in.ocean_current_y.size() == in.n_cells
            && (int)in.temp.size()            == in.n_cells
            && (int)in.temp_baseline_year.size() == in.n_cells
            && (int)in.ocean_thermal_anomaly.size() == in.n_cells
            && (int)in.temp_transport_anomaly.size() == in.n_cells) {
        if (timing) timing->passes_ran |= 0x4;
        if (!_async_ocean_water_kernel_pure(in, knobs,
                                            work, out)) {
            ok = false;
        }
        // Round 数据流：ocean_water 写 ocean_thermal_anomaly (water cells)。
        // ocean_land 通过 work.ocean_tta_inout 读 water cells fresh anomaly，
        // ocean_thermal_anomaly slot 也要同步给 wind_surface 做合成。
        const int n_ow = in.n_cells;
        if ((n_ow > 0 && (int)out.ocean_thermal_anomaly.size() == n_ow)
                && (int) in.ocean_thermal_anomaly.size() == n_ow) {
            std::memcpy(in.ocean_thermal_anomaly.data(),
                        out.ocean_thermal_anomaly.data(), n_ow * sizeof(float));
        }
    }
    const auto ow1 = clock::now();
    if (timing) timing->pass_us[2] =
        (int64_t)std::chrono::duration_cast<std::chrono::microseconds>(
            ow1 - ow0).count();
    if (timing && (mask & 0x4) != 0 &&
        (timing->passes_ran & 0x4) == 0) {
        timing->passes_starved |= 0x4;
    }

    // ─── ocean_land（bit 3） — 依赖 ocean_water 写完 work.ocean_tta_inout
    pk_stage_trace("ocean_land", -1, in.n_cells, mask);
    const auto ol0 = clock::now();
    if ((mask & 0x08) != 0
            && (int)in.is_water.size()        == in.n_cells
            && (int)in.pos_x.size()           == in.n_cells
            && (int)in.pos_y.size()           == in.n_cells
            && (int)in.ocean_current_x.size() == in.n_cells
            && (int)in.ocean_current_y.size() == in.n_cells) {
        // 若 ocean_water 没跑，ocean_tta_inout 还是空——单跑 ocean_land 时
        // 用 in.temp_transport_anomaly 初始化它。
        if ((int)work.ocean_tta_inout.size() != in.n_cells
                && (int)in.temp_transport_anomaly.size() == in.n_cells) {
            work.ocean_tta_inout.resize(in.n_cells);
            std::memcpy(work.ocean_tta_inout.data(),
                        in.temp_transport_anomaly.data(),
                        in.n_cells * sizeof(float));
        }
        if (timing) timing->passes_ran |= 0x8;
        if (!_async_ocean_land_kernel_pure(in, knobs,
                                           work, out)) {
            ok = false;
        }
        // Round 数据流：ocean_land 累加 ocean_thermal_anomaly (land cells)。
        // wind_surface 读它做合成。
        const int n_ol = in.n_cells;
        if ((n_ol > 0 && (int)out.ocean_thermal_anomaly.size() == n_ol)
                && (int) in.ocean_thermal_anomaly.size() == n_ol) {
            std::memcpy(in.ocean_thermal_anomaly.data(),
                        out.ocean_thermal_anomaly.data(), n_ol * sizeof(float));
        }
    }
    const auto ol1 = clock::now();
    if (timing) timing->pass_us[3] =
        (int64_t)std::chrono::duration_cast<std::chrono::microseconds>(
            ol1 - ol0).count();
    if (timing && (mask & 0x8) != 0 &&
        (timing->passes_ran & 0x8) == 0) {
        timing->passes_starved |= 0x8;
    }

    // ─── wind_air / wind_surface / sea_ice 仍是 stub
    // TTA 在 round 内只活在 work.ocean_tta_inout 里（ocean_water 写水格、ocean_land
    // 写陆格），而 wind_surface 与 sea_ice 读的是 in.temp_transport_anomaly。少了这次
    // 回写，它们读到的是 kick 时刻的初值 —— 生产那两个 pass 跑在 ocean 之后，读的是
    // 刚累加完的值。与 insolation_now 是同一类漏接。
    if ((int) work.ocean_tta_inout.size() == in.n_cells &&
        (int) in.temp_transport_anomaly.size() == in.n_cells && in.n_cells > 0) {
        std::memcpy(in.temp_transport_anomaly.data(),
                    work.ocean_tta_inout.data(),
                    size_t(in.n_cells) * sizeof(float));
    }

    // 把生产 wind_surface 真正读到的 oanom 注回来（见 WindSurfaceInput 注释）。
    //
    // 位置必须在 ocean_land 之后、wind_air 之前，不能提到 pass_a 后面：
    //   • ocean_water / ocean_land 是**累加** oanom 的。提前注入等于让它们在生产的
    //     成品值上再累一遍 —— 实测 wind_surface 读到的 oanom 正好是生产的两倍。
    //   • 生产的 pass_b 跑在 ocean 之前，读到的是 pass_a 刚清零的 oanom。提前注入
    //     会让 worker 的 pass_b 读到非零值。
    // in 与 out 都要写：wind_surface 取的是 choose_field(out, in)，只写一边会被另一
    // 边的值盖掉。
    if ((int) in.production_ocean_anomaly.size() == in.n_cells && in.n_cells > 0) {
        const size_t bytes = size_t(in.n_cells) * sizeof(float);
        if ((int) in.ocean_thermal_anomaly.size() == in.n_cells) {
            std::memcpy(in.ocean_thermal_anomaly.data(),
                        in.production_ocean_anomaly.data(), bytes);
        }
        if ((int) out.ocean_thermal_anomaly.size() == in.n_cells) {
            std::memcpy(out.ocean_thermal_anomaly.data(),
                        in.production_ocean_anomaly.data(), bytes);
        }
    }

    pk_stage_trace("wind_air", -1, in.n_cells, mask);
    // ─── wind_air（bit 4） ────────────────────────────────────────
    const auto wa0 = clock::now();
    if ((mask & 0x10) != 0
            && (int)in.wind_x.size()  == in.n_cells
            && (int)in.wind_y.size()  == in.n_cells
            && (int)in.wind_speed.size() == in.n_cells
            && (int)in.pos_x.size()   == in.n_cells
            && (int)in.pos_y.size()   == in.n_cells
            && (int)in.temp.size()    == in.n_cells
            && (int)in.temp_baseline_year.size() == in.n_cells) {
        if (timing) timing->passes_ran |= 0x10;
        if (!_async_wind_air_kernel_pure(in, knobs, out)) {
            ok = false;
        }
        // Round 数据流：wind_air 写 air_mass_temp_anomaly。
        // wind_surface 读它（作为 AIN snapshot）做加权平均。
        const int n_wa = in.n_cells;
        if ((n_wa > 0 && (int)out.air_mass_temp_anomaly.size() == n_wa)
                && (int) in.air_mass_temp_anomaly.size() == n_wa) {
            std::memcpy(in.air_mass_temp_anomaly.data(),
                        out.air_mass_temp_anomaly.data(), n_wa * sizeof(float));
        }
    }
    const auto wa1 = clock::now();
    if (timing) timing->pass_us[4] =
        (int64_t)std::chrono::duration_cast<std::chrono::microseconds>(
            wa1 - wa0).count();
    if (timing && (mask & 0x10) != 0 &&
        (timing->passes_ran & 0x10) == 0) {
        timing->passes_starved |= 0x10;
    }

    // ─── wind_surface（bit 5） — 依赖 wind_air / pass_a / pass_b / ocean_*
    pk_stage_trace("wind_surface", -1, in.n_cells, mask);
    const auto ws0 = clock::now();
    if ((mask & 0x20) != 0
            && (int)in.wind_x.size()  == in.n_cells
            && (int)in.wind_y.size()  == in.n_cells
            && (int)in.wind_speed.size() == in.n_cells
            && (int)in.pos_x.size()   == in.n_cells
            && (int)in.pos_y.size()   == in.n_cells) {
        if (timing) timing->passes_ran |= 0x20;
        if (!_async_wind_surface_kernel_pure(in, knobs, out)) {
            ok = false;
        }
        // Round 数据流：wind_surface 写 cell_temp（合成）+ overwrite air_anom。
        // sea_ice 期望读 climate/ocean-adjusted T —— round 模式下这就是 wind_surface
        // 输出的 cell_temp，同步给 in.cell_temperature_arr（覆盖 kick 传入的旧值）。
        const int n_ws = in.n_cells;
        if (n_ws > 0) {
            if ((int)out.temp.size() == n_ws) {
                if ((int)in.cell_temperature_arr.size() != n_ws) {
                    in.cell_temperature_arr.resize(n_ws);
                }
                std::memcpy(in.cell_temperature_arr.data(),
                            out.temp.data(), n_ws * sizeof(float));
            }
            if (((int)out.air_mass_temp_anomaly.size() == n_ws)
                    && (int) in.air_mass_temp_anomaly.size() == n_ws) {
                std::memcpy(in.air_mass_temp_anomaly.data(),
                            out.air_mass_temp_anomaly.data(), n_ws * sizeof(float));
            }
        }
    }
    const auto ws1 = clock::now();
    if (timing) timing->pass_us[5] =
        (int64_t)std::chrono::duration_cast<std::chrono::microseconds>(
            ws1 - ws0).count();
    if (timing && (mask & 0x20) != 0 &&
        (timing->passes_ran & 0x20) == 0) {
        timing->passes_starved |= 0x20;
    }

    // sea_ice 仍是 stub（Stage 2 余下工作）
    // ─── sea_ice（bit 6） ─────────────────────────────────────────
    pk_stage_trace("sea_ice", -1, in.n_cells, mask);
    const auto si0 = clock::now();
    if ((mask & 0x40) != 0
            && (int)in.terrain.size()              == in.n_cells
            && (int)in.base_terrain.size()         == in.n_cells
            && (int)in.sea_ice_frac_inout.size()   == in.n_cells
            && (int)in.temp_transport_anomaly.size() == in.n_cells
            && (int)in.upwelling_strength.size()   == in.n_cells
            && (int)in.insolation_now.size()       == in.n_cells
            && (int)in.cell_temperature_arr.size() == in.n_cells
            && (int)in.water_terrain_ids.size()    > 0) {
        if (timing) timing->passes_ran |= 0x40;
        if (!_async_sea_ice_kernel_pure(in, knobs, out)) {
            ok = false;
        }
        // Round 数据流：sea_ice 写 sea_ice_frac + 翻转 terrain。transp 不依赖
        // 它们；但 in.sea_ice_frac_inout / in.terrain 同步以便后续诊断 / round
        // 重复 kick 时拿到最新值（虽然单 round 不会重复跑同一 pass）。
        const int n_si = in.n_cells;
        if (n_si > 0) {
            if (((int)out.sea_ice_frac.size() == n_si)
                    && (int) in.sea_ice_frac_inout.size() == n_si) {
                std::memcpy(in.sea_ice_frac_inout.data(),
                            out.sea_ice_frac.data(), n_si * sizeof(float));
            }
            if (((int)out.terrain.size() == n_si)
                    && (int) in.terrain.size() == n_si) {
                std::memcpy(in.terrain.data(),
                            out.terrain.data(), n_si);
            }
        }
    }
    const auto si1 = clock::now();
    if (timing) timing->pass_us[6] =
        (int64_t)std::chrono::duration_cast<std::chrono::microseconds>(
            si1 - si0).count();
    if (timing && (mask & 0x40) != 0 &&
        (timing->passes_ran & 0x40) == 0) {
        timing->passes_starved |= 0x40;
    }

    // ─── transp（bit 7） ──────────────────────────────────────────
    pk_stage_trace("transp", -1, in.n_cells, mask);
    const auto tr0 = clock::now();
    if ((mask & 0x80) != 0
            && (int)in.landform.size()   == in.n_cells
            && (int)in.vegetation.size() == in.n_cells
            && (int)in.moisture.size()   == in.n_cells) {
        if (timing) timing->passes_ran |= 0x80;
        if (!_async_transp_kernel_pure(in, knobs,
                                       work, out)) {
            ok = false;
        }
    }
    const auto tr1 = clock::now();
    if (timing) timing->pass_us[7] =
        (int64_t)std::chrono::duration_cast<std::chrono::microseconds>(
            tr1 - tr0).count();
    if (timing && (mask & 0x80) != 0 &&
        (timing->passes_ran & 0x80) == 0) {
        timing->passes_starved |= 0x80;
    }

    // ─── finalizer（bit 8，Stage 9 2026-06-16） ──────────────────────
    pk_stage_trace("finalizer", -1, in.n_cells, mask);
    // 在 round 末尾跑一次：clamp temp/TTA、统计 Δ percentile、thermal init、
    // sea_ice_delta_max、precip_p95。等价 GDScript _apply_daily_climate_finalizer。
    const auto fi0 = clock::now();
    if ((mask & 0x100) != 0
            && (int)in.temp.size() == in.n_cells
            && (int)in.temp_transport_anomaly.size() == in.n_cells
            && (int)in.thermal_energy.size() == in.n_cells) {
        // out.temp 已被 wind_surface 写入（mask bit 5 启用时）；finalizer
        // 在它之上 clamp。若 wind_surface 没写过（mask bit 5 关闭），kernel
        // 内部用 in.temp 兜底初始化 out.temp。
        if (timing) timing->passes_ran |= 0x100;
        if (!_async_finalizer_kernel_pure(in, out)) {
            ok = false;
        }
    }
    const auto fi1 = clock::now();
    if (timing) timing->pass_us[8] =
        (int64_t)std::chrono::duration_cast<std::chrono::microseconds>(
            fi1 - fi0).count();
    if (timing && (mask & 0x100) != 0 &&
        (timing->passes_ran & 0x100) == 0) {
        timing->passes_starved |= 0x100;
    }
    out.n_cells = in.n_cells;
    return ok;
}

// ─── stage 11 WEATHER：ψ 整步推进 ───────────────────────────────────────────
//
// 这里是 ψ 推进的唯一实现。搬过来之前生产热路径里内联了一份、
// DCWorldExt::run_synoptic_advance_pass 里另有一份，两份的 damp / diffuse 默认值
// 不同，且只有内联版带斜压振幅饱和与阈值清零 —— 也就是说"提取出的内核该等价于
// 哪一份"没有答案。以内联版为准合成一份，因为跑在生产热路径上的是它。
void synoptic_advance_pure(int n_cells,
                           const int32_t *neighbor_indices,
                           const float *pos_x,
                           const float *pos_y,
                           const float *wind_x,
                           const float *wind_y,
                           const float *temp_norm,
                           const SynopticAdvanceKnobs &knobs,
                           std::vector<float> &psi,
                           std::vector<float> &psi_prev) {
    if (n_cells <= 0 || neighbor_indices == nullptr || pos_x == nullptr ||
        pos_y == nullptr || wind_x == nullptr || wind_y == nullptr ||
        temp_norm == nullptr) {
        return;
    }
    if (psi.size() != (size_t)n_cells) psi.assign((size_t)n_cells, 0.0f);
    psi_prev = psi;                                     // 整步快照（脱离切片）
    float * const __restrict PSI_W = psi.data();
    const float * const __restrict PSI_R = psi_prev.data();
    const int32_t * const __restrict NB = neighbor_indices;
    const float * const __restrict WX = wind_x;
    const float * const __restrict WY = wind_y;
    const float * const __restrict TR = temp_norm;

    int adv_cells = knobs.adv_cells;
    if (adv_cells < 0) adv_cells = 0;
    else if (adv_cells > 16) adv_cells = 16;

    for (int p = 0; p < n_cells; ++p) {
        const int pb = p * 6;
        // 平滑引导流：风邻域平均（去地转风小尺度切变→平移连贯，不打散）
        float gx = WX[p], gy = WY[p];
        int gn = 1;
        for (int d = 0; d < 6; ++d) {
            const int nb = NB[pb + d];
            if (nb < 0) continue;
            gx += WX[nb]; gy += WY[nb]; ++gn;
        }
        gx /= float(gn); gy /= float(gn);
        // 半拉格朗日真平移：沿 -引导流走 adv_cells 格取 departure 的 ψ_prev
        int dep = p;
        for (int s = 0; s < adv_cells; ++s) {
            const int up = wf_neighbor_aligned_idx_xy(
                dep, -gx, -gy, pos_x, pos_y, NB, n_cells,
                knobs.cell_pos_scale, knobs.wrap_width_x);
            if (up < 0 || up >= n_cells) break;
            dep = up;
        }
        float ps = PSI_R[dep];
        // 斜压门：邻域温度梯度
        float tmn = TR[p], tmx = TR[p];
        for (int d = 0; d < 6; ++d) {
            const int nb = NB[pb + d];
            if (nb < 0) continue;
            const float tv = TR[nb];
            if (tv < tmn) tmn = tv;
            if (tv > tmx) tmx = tv;
        }
        const float g = wf_smoothstep(0.04f, 0.16f, tmx - tmn);
        const float aps0 = ps < 0.0f ? -ps : ps;
        // 斜压增长随振幅饱和→有界，不会全场饱和
        ps *= (1.0f + knobs.baroclinic * g * (1.0f - aps0));
        const float sr = knobs.seed_rate * (0.30f + 0.70f * g);
        if (wf_hash01(p, knobs.tick) < sr)
            ps += knobs.seed_amp * (wf_hash01(p + 50021, knobs.tick) - 0.5f) * 2.0f;
        ps += (wf_neighbor_average_vapor_idx(p, NB, PSI_R) - ps) * knobs.diffuse;
        ps *= knobs.damp;
        if (ps > 1.0f) ps = 1.0f; else if (ps < -1.0f) ps = -1.0f;
        // 阈值清零→防低值 ψ 经扩散/平流铺满全场，保稀疏移动涡旋
        if (ps < 0.05f && ps > -0.05f) ps = 0.0f;
        PSI_W[p] = ps;
    }
}

// ─── stage 11 WEATHER：field solve 主循环（纯内核）──────────────────────────
//
// 循环体是从 DCWorldExt::run_weather_field_solve_pass 原样搬过来的，只把原先解析
// 到 DCWorldExt 成员或 Dictionary 查找的名字换成结构体字段（见
// tools/runtime/extract_weather_kernel.py 里的替换表）。数值语句一行未改。
void weather_field_solve_pure(const WeatherFieldKnobs &knobs,
                              const WeatherFieldLanes &lanes,
                              const WeatherFieldState &state,
                              int begin,
                              int end) {
    const int n_cells = knobs.n_cells;
    if (n_cells <= 0 || begin < 0 || end > n_cells || end <= begin) return;

    // 原循环体里的自由名字，逐个绑回结构体。名字保持不变，循环体才能原样搬。
    const float climate_anomaly = knobs.climate_anomaly;
    const bool  refresh_convergence = knobs.refresh_convergence;
    const bool  apply_convergence_boost = knobs.apply_convergence_boost;
    const bool  use_next_outputs = knobs.use_next_outputs;
    const int   field_advect_steps = knobs.field_advect_steps;
    const float field_diffusion = knobs.field_diffusion;
    const float field_ocean_evap_gain = knobs.field_ocean_evap_gain;
    const float field_precip_inertia = knobs.field_precip_inertia;
    const float field_precip_spatial_smooth = knobs.field_precip_spatial_smooth;
    const float field_cloud_inertia = knobs.field_cloud_inertia;
    const float field_wet_terrain_precip_damping = knobs.field_wet_terrain_precip_damping;
    const float field_lake_precip_damping = knobs.field_lake_precip_damping;
    const float field_lake_evap_scale = knobs.field_lake_evap_scale;
    const float field_extreme_precip_soft_cap = knobs.field_extreme_precip_soft_cap;
    const float field_extreme_precip_softness = knobs.field_extreme_precip_softness;
    const float field_land_evapotranspiration_gain = knobs.field_land_evapotranspiration_gain;
    const float field_ocean_precip_suppression = knobs.field_ocean_precip_suppression;
    const float field_frontogenesis_gain = knobs.field_frontogenesis_gain;
    const float field_rain_shadow_drying = knobs.field_rain_shadow_drying;
    const float field_advect_vapor = knobs.field_advect_vapor;
    const float field_advect_cloud = knobs.field_advect_cloud;
    const float field_rh_condense = knobs.field_rh_condense;
    const float field_static_cond_w = knobs.field_static_cond_w;
    const float field_condense_rate = knobs.field_condense_rate;
    const float field_lift_cond_gain = knobs.field_lift_cond_gain;
    const float field_conv_cond_gain = knobs.field_conv_cond_gain;
    const float field_thermal_conv_cond = knobs.field_thermal_conv_cond;
    const float field_thermal_conv_precip = knobs.field_thermal_conv_precip;
    const float field_autoconversion = knobs.field_autoconversion;
    const float field_precip_base_frac = knobs.field_precip_base_frac;
    const float field_lift_precip_gain = knobs.field_lift_precip_gain;
    const float field_conv_precip_gain = knobs.field_conv_precip_gain;
    const float field_oro_precip_gain = knobs.field_oro_precip_gain;
    const float field_stratiform_gain = knobs.field_stratiform_gain;
    const float field_cool_season_vapor_floor = knobs.field_cool_season_vapor_floor;
    const float field_cloud_reevap = knobs.field_cloud_reevap;
    const float weather_cell_pos_scale = knobs.weather_cell_pos_scale;
    const float weather_wrap_width_x = knobs.weather_wrap_width_x;
    const bool  cold_precip_as_blizzard = knobs.cold_precip_as_blizzard;
    const float snow_classification_margin = knobs.snow_classification_margin;
    const float weather_lat_te_norm = knobs.weather_lat_te_norm;
    const float OMEGA_ASCENT_GAIN = knobs.omega_ascent_gain;
    const float wb_pos_y = knobs.world_bounds_pos_y;
    const float wb_size_y = knobs.world_bounds_size_y;
    const float syn_supp = knobs.syn_supp;
    const float syn_enh = knobs.syn_enh;
    const float syn_front_force = knobs.syn_front_force;
    const float syn_front_enh = knobs.syn_front_enh;
    const float syn_base_lift = knobs.syn_base_lift;
    const bool  weather_transition_enabled = knobs.weather_transition_enabled;
    const float weather_transition_alpha_rate = knobs.weather_transition_alpha_rate;
    const float weather_transition_dt_days = knobs.weather_transition_dt_days;
    const bool  thermal_monsoon_enabled = knobs.thermal_monsoon_enabled;
    const uint8_t cyclone_storm_type_id = knobs.cyclone_storm_type_id;

    // 循环体内的编译期常量（原本是 pass 函数体里的 constexpr）。
    constexpr float OMEGA_DESCENT_GAIN = 0.70f;
    constexpr float OMEGA_DESCENT_COND = 0.45f;
    constexpr float VAPOR_DISCHARGE = 0.70f;
    constexpr float DISCHARGE_SUSTAIN = 0.65f;
    constexpr float INHIB_CHARGE = 0.26f;
    constexpr float INHIB_REFRAC = 0.18f;
    constexpr float INHIB_LEAK = 0.88f;
    constexpr float INHIB_STRENGTH = 0.92f;
    constexpr float INHIB_WET = 0.02f;

    const float   * const __restrict TR   = lanes.temp_read;
    const float   * const __restrict MR   = lanes.moisture_read;
    const float   * const __restrict AA   = lanes.air_anomaly;
    const float   * const __restrict WX   = lanes.wind_x;
    const float   * const __restrict WY   = lanes.wind_y;
    const float   * const __restrict WSPD = lanes.wind_speed;
    const uint8_t * const __restrict TERR = lanes.terrain;
    const uint8_t * const __restrict RIV  = lanes.has_river;
    const float   * const __restrict RQ30 = lanes.river_q30;
    const float   * const __restrict ELEV = lanes.elevation;
    const uint8_t * const __restrict VEG  = lanes.vegetation;
    const float   * const __restrict SOIL = lanes.soil_moisture;
    const float   * const __restrict VITA = lanes.vitality;
    const float   * const __restrict SICE = lanes.sea_ice;
    const float   * const __restrict POSX = lanes.pos_x;
    const float   * const __restrict POSY = lanes.pos_y;
    const float   * const __restrict TANO = lanes.temp_anomaly;
    const float   * const __restrict SNOWR = lanes.snow_cover;
    const int32_t * const __restrict NB   = lanes.neighbor_indices;
    const float   * const __restrict PV   = lanes.prev_vapor;
    const float   * const __restrict PP   = lanes.prev_precip;
    const float   * const __restrict PCW  = lanes.prev_cloud_water;
    const float   * const __restrict TA   = lanes.temp_transport_anomaly;
    const float   * const __restrict PREV_CNV = lanes.prev_convergence;
    const float   * const __restrict PREV_CLOUD = lanes.prev_cloud;

    float   * const __restrict OUT_VAP = lanes.out_vapor;
    float   * const __restrict OUT_CLD = lanes.out_cloud;
    float   * const __restrict OUT_CW  = lanes.out_cloud_water;
    float   * const __restrict OUT_PRE = lanes.out_precip;
    float   * const __restrict OUT_INS = lanes.out_instability;
    float   * const __restrict OUT_INT = lanes.out_intensity;
    float   * const __restrict OUT_CNV = lanes.out_convergence;
    uint8_t * const __restrict OUT_TYP = lanes.out_type_u8;
    int32_t * const __restrict OUT_TYP_I32 = lanes.out_type_i32;
    uint8_t * const __restrict OUT_PREV_TYP = lanes.out_prev_type;
    uint8_t * const __restrict OUT_TARGET_TYP = lanes.out_target_type;
    float   * const __restrict OUT_ALPHA = lanes.out_alpha;
    uint8_t * const __restrict OUT_FIN = lanes.out_field_init;
    float   * const __restrict INHIB = state.conv_inhib;

    const float * const __restrict PSI = state.psi;
    const uint32_t * const __restrict CYC_TAG = state.cyclone_tag;
    const uint32_t cyclone_generation = state.cyclone_generation;
    const float * const __restrict CYC_LIFT = state.cyclone_lift;
    const float * const __restrict CYC_X = state.cyclone_x;
    const float * const __restrict CYC_Y = state.cyclone_y;
    const float * const __restrict MONS = state.monsoon_thermal;
    const int32_t * const __restrict TRAJ_IDX = state.traj_idx;
    const float   * const __restrict TRAJ_W = state.traj_w;
    const bool use_geom_cache = state.geom_dx != nullptr &&
        state.geom_dy != nullptr && state.geom_invd != nullptr;
    const float * const __restrict GEOM_DX   = state.geom_dx;
    const float * const __restrict GEOM_DY   = state.geom_dy;
    const float * const __restrict GEOM_INVD = state.geom_invd;

    if (TR == nullptr || MR == nullptr || AA == nullptr || WX == nullptr ||
        WY == nullptr || WSPD == nullptr || TERR == nullptr || RIV == nullptr ||
        ELEV == nullptr || VEG == nullptr || POSX == nullptr || POSY == nullptr ||
        NB == nullptr || PV == nullptr || PP == nullptr || TA == nullptr ||
        PREV_CNV == nullptr || PREV_CLOUD == nullptr || OUT_VAP == nullptr ||
        OUT_CLD == nullptr || OUT_PRE == nullptr || OUT_INS == nullptr ||
        OUT_INT == nullptr || OUT_CNV == nullptr) {
        return;
    }
    // direct 路径写 uint8 类型 + field_init，staged 路径写 int32 类型。少哪一边都
    // 意味着调用方接错了 buffer，静默跑完会把这一天的 weather_type 丢掉。
    if (use_next_outputs ? (OUT_TYP_I32 == nullptr)
                         : (OUT_TYP == nullptr || OUT_FIN == nullptr)) {
        return;
    }

    auto wx_traj_sample = [&](int idx, const float *FIELD) -> float {
        const int t3 = idx * 3;
        return TRAJ_W[t3] * FIELD[TRAJ_IDX[t3]]
             + TRAJ_W[t3 + 1] * FIELD[TRAJ_IDX[t3 + 1]]
             + TRAJ_W[t3 + 2] * FIELD[TRAJ_IDX[t3 + 2]];
    };
    auto wx_aligned = [&](int idx, float dx, float dy) -> int {
        return use_geom_cache
            ? wf_neighbor_aligned_idx_cached(idx, dx, dy, NB, GEOM_DX, GEOM_DY,
                                             n_cells, weather_cell_pos_scale)
            : wf_neighbor_aligned_idx_xy(idx, dx, dy, POSX, POSY, NB, n_cells,
                                         weather_cell_pos_scale, weather_wrap_width_x);
    };
    auto wx_upstream_avg = [&](int idx, int first_up, const float *FIELD,
                               float wdx, float wdy) -> float {
        return use_geom_cache
            ? wf_upstream_vapor_idx_from_first_cached(
                  idx, first_up, NB, GEOM_DX, GEOM_DY, FIELD, wdx, wdy, n_cells,
                  weather_cell_pos_scale, field_advect_steps)
            : wf_upstream_vapor_idx_from_first_xy(
                  idx, first_up, POSX, POSY, NB, FIELD, wdx, wdy, n_cells,
                  weather_cell_pos_scale, weather_wrap_width_x, field_advect_steps);
    };
    auto wx_convergence = [&](int idx) -> float {
        return use_geom_cache
            ? wf_wind_convergence_idx_cached(idx, NB, GEOM_DX, GEOM_DY, GEOM_INVD,
                                             WX, WY, WSPD)
            : wf_wind_convergence_idx_xy(idx, POSX, POSY, NB, WX, WY, WSPD,
                                         weather_wrap_width_x);
    };

    auto surface_vapor_source = [&](int src_idx, float src_temp, float src_base_m,
                                     float src_wind_mag, float src_ocean_an,
                                     bool src_on_water, bool src_is_lake,
                                     bool src_has_river, float src_river_q,
                                     float src_river_source_scale) -> float {
        // [climate-zone-fix P3] 冷季地板抬高低温端蒸发；floor=0 时与原 smoothstep 逐位一致。
        float temp_evap = wf_smoothstep(0.10f, 0.78f, src_temp);
        if (temp_evap < field_cool_season_vapor_floor) temp_evap = field_cool_season_vapor_floor;
        const float wind_evap = 0.70f + src_wind_mag * 0.55f;
        float wet_bonus = 0.0f;
        switch (TERR[src_idx]) {
            case 10: // SWAMP
            case 11: // JUNGLE
            case 22: // DELTA
                wet_bonus = 0.010f;
                break;
            case 18: // LAKE
                wet_bonus = 0.016f;
                break;
            default:
                wet_bonus = 0.0f;
                break;
        }
        if (src_on_water) {
            const float sea_ice = (SICE != nullptr) ? dc_clampf(SICE[src_idx], 0.0f, 1.0f) : 0.0f;
            float src = (0.018f + temp_evap * 0.052f) * field_ocean_evap_gain * wind_evap;
            src *= dc_clampf(1.0f + src_ocean_an * 0.55f, 0.55f, 1.45f);
            src *= (1.0f - sea_ice * 0.92f);
            if (src_is_lake) src *= field_lake_evap_scale;
            return (src > 0.0f) ? src : 0.0f;
        }
        const float soil_norm = (SOIL != nullptr)
            ? dc_clampf(0.5f + SOIL[src_idx], 0.0f, 1.0f)
            : dc_clampf(src_base_m, 0.0f, 1.0f);
        const float vitality = (VITA != nullptr) ? dc_clampf(VITA[src_idx], 0.0f, 1.0f) : 0.7f;
        const float veg_flux = wf_vegetation_transp_factor(VEG[src_idx]) * (0.45f + vitality * 0.65f);
        float src = (0.005f + src_base_m * 0.010f + soil_norm * 0.020f + veg_flux * 0.016f + wet_bonus)
            * field_land_evapotranspiration_gain * temp_evap * (0.85f + src_wind_mag * 0.25f);
        if (src_has_river) {
            const float river_scale = dc_clampf(src_river_source_scale, 0.0f, 1.0f);
            const float river_extra = (0.010f + src_river_q * 0.020f)
                * field_land_evapotranspiration_gain * temp_evap;
            src += river_extra * river_scale;
        }
        return (src > 0.0f) ? src : 0.0f;
    };

    const int rb = begin;
    const int re = end;
    for (int i = rb; i < re; ++i) {
        float temp = TR[i] + climate_anomaly + AA[i];
        if (temp < 0.0f) temp = 0.0f;
        else if (temp > 1.0f) temp = 1.0f;

        float base_m = MR[i];
        if (base_m < 0.0f) base_m = 0.0f;
        else if (base_m > 1.0f) base_m = 1.0f;
        float vapor_capacity = 0.18f + 0.82f * temp - 0.18f * ELEV[i];
        if (vapor_capacity < 0.14f) vapor_capacity = 0.14f;
        else if (vapor_capacity > 1.0f) vapor_capacity = 1.0f;

        const bool on_water = wf_is_water_terrain(TERR[i]);
        // ── perf P3: 融合 3 个 6-邻域 gather 为一次遍历（逐 d 顺序与原版一致→bit-equal）──
        //   ① ocean_an     = wf_avg_ocean_anomaly_at_idx(i, TERR, NB, TA)
        //   ② neighbor_vapor= wf_neighbor_average_vapor_idx(i, NB, PV)
        //   ③ temp_min/max  = 邻域温度极值（原下方 temp gradient 循环）
        float ocean_an;
        float neighbor_vapor;
        float temp_min = temp;
        float temp_max = temp;
        {
            const int fb = i * 6;
            float vap_sum = PV[i];
            int   vap_n   = 1;
            float oa_sum  = 0.0f;
            int   oa_n    = 0;
            for (int d = 0; d < 6; ++d) {
                const int32_t nb_idx = NB[fb + d];
                if (nb_idx < 0) continue;
                vap_sum += PV[nb_idx];                // ② vapor 邻域均值（含 self）
                vap_n   += 1;
                float nb_temp = TR[nb_idx] + climate_anomaly + AA[nb_idx];  // ③ 温度梯度极值
                if (nb_temp < 0.0f) nb_temp = 0.0f;
                else if (nb_temp > 1.0f) nb_temp = 1.0f;
                if (nb_temp < temp_min) temp_min = nb_temp;
                if (nb_temp > temp_max) temp_max = nb_temp;
                if (!on_water && wf_is_water_terrain(TERR[nb_idx])) {       // ① 陆格→水邻居 TA 均值
                    oa_sum += TA[nb_idx];
                    oa_n   += 1;
                }
            }
            neighbor_vapor = vap_sum / float(vap_n);
            ocean_an = on_water ? TA[i] : ((oa_n == 0) ? 0.0f : (oa_sum / float(oa_n)));
        }
        const float local_sea_ice = (on_water && SICE != nullptr) ? dc_clampf(SICE[i], 0.0f, 1.0f) : 0.0f;

        float wind_x = WX[i];
        float wind_y = WY[i];
        const bool cyclone_forced = i < state.cyclone_tag_count &&
            CYC_TAG[static_cast<size_t>(i)] == cyclone_generation;
        const float cyclone_lift = cyclone_forced
            ? CYC_LIFT[static_cast<size_t>(i)] : 0.0f;
        if (cyclone_forced) {
            wind_x += CYC_X[static_cast<size_t>(i)];
            wind_y += CYC_Y[static_cast<size_t>(i)];
        }
        const float wlen2 = wind_x * wind_x + wind_y * wind_y;
        float wind_dx, wind_dy;
        if (wlen2 < 0.0001f) {
            // Conservative fallback: dir = (1,0) like the GDScript final
            // `wind.normalized() if length_squared > 0.0001 else Vector2.RIGHT`.
            // Magnitude stays 0 → wind_mag=0 → advect_w lower bound.
            wind_dx = 1.0f;
            wind_dy = 0.0f;
        } else {
            const float inv = 1.0f / std::sqrt(wlen2);
            wind_dx = wind_x * inv;
            wind_dy = wind_y * inv;
        }
        const float wind_len = wf_wind_speed_norm(wind_x, wind_y, WSPD[i]);

        const int upstream_idx = (field_advect_steps > 0)
            ? wx_aligned(i, -wind_dx, -wind_dy)
            : -1;

        // NS 化 Phase 2:轨迹表命中 → 真半拉格朗日三点插值(1 次表查 + 3 点 lerp,
        // 替代 3×6 邻居探测的 hopping,回溯长度含风速×dt 语义);未命中 → 旧路径。
        const float advected_vapor = (TRAJ_IDX != nullptr)
            ? wx_traj_sample(i, PV)
            : wx_upstream_avg(i, upstream_idx, PV, wind_dx, wind_dy);

        // neighbor_vapor 已在上方 P3 融合 gather 中算出。

        float wind_mag = wind_len / 1.2f;
        if (wind_mag < 0.0f) wind_mag = 0.0f;
        else if (wind_mag > 1.0f) wind_mag = 1.0f;

        const float lift = wf_orographic_lift_from_upstream_idx(
            i, upstream_idx, ELEV);
        float convergence = PREV_CNV[i];
        if (refresh_convergence) {
            convergence = wx_convergence(i);
        }

        float advect_w = 0.65f + wind_mag * 0.30f;
        if (advect_w < 0.65f) advect_w = 0.65f;
        else if (advect_w > 0.95f) advect_w = 0.95f;

        const bool is_lake = (TERR[i] == 18);
        const bool has_river = (!is_lake) && (RIV[i] != 0) && (!on_water);
        const float river_flow_feedback = has_river
            ? dc_clampf((RQ30 != nullptr ? RQ30[i] : 0.0f), 0.0f, 1.0f)
            : 0.0f;
        float river_recycle_lock = 0.0f;
        if (has_river) {
            float river_forcing_proxy = convergence * 0.65f;
            const float lift_forcing = (lift > 0.0f) ? lift * 0.80f : 0.0f;
            if (lift_forcing > river_forcing_proxy) river_forcing_proxy = lift_forcing;
            river_recycle_lock = wf_smoothstep(0.035f, 0.12f, PP[i])
                * (1.0f - wf_smoothstep(0.16f, 0.44f, river_forcing_proxy))
                * (0.35f + river_flow_feedback * 0.65f);
            river_recycle_lock = dc_clampf(river_recycle_lock, 0.0f, 1.0f);
        }
        const float river_source_scale = 1.0f - river_recycle_lock * 0.72f;
        const float river_evap_floor = has_river
            ? std::max(0.08f, river_flow_feedback * 0.22f) * (1.0f - river_recycle_lock * 0.65f)
            : 0.0f;
        if (is_lake) {
            advect_w *= 0.5f;
            if (advect_w < 0.20f) advect_w = 0.20f;
            else if (advect_w > 0.50f) advect_w = 0.50f;
        } else if (has_river) {
            advect_w *= (0.88f - river_flow_feedback * 0.10f);
            if (advect_w < 0.55f) advect_w = 0.55f;
            else if (advect_w > 0.85f) advect_w = 0.85f;
        }

        float effective_ocean_an = ocean_an;
        if (is_lake) {
            effective_ocean_an = 0.20f;
        } else if (has_river) {
            if (ocean_an > river_evap_floor) effective_ocean_an = ocean_an;
            else                             effective_ocean_an = river_evap_floor;
        }

        const float source_local = surface_vapor_source(
            i, temp, base_m, wind_mag, effective_ocean_an, on_water, is_lake,
            has_river, river_flow_feedback, river_source_scale);
        float source_upwind = source_local;
        bool upstream_on_water = false;
        if (upstream_idx >= 0 && upstream_idx < n_cells) {
            float up_temp = TR[upstream_idx] + climate_anomaly + AA[upstream_idx];
            if (up_temp < 0.0f) up_temp = 0.0f;
            else if (up_temp > 1.0f) up_temp = 1.0f;
            float up_base_m = MR[upstream_idx];
            if (up_base_m < 0.0f) up_base_m = 0.0f;
            else if (up_base_m > 1.0f) up_base_m = 1.0f;
            const bool up_on_water = wf_is_water_terrain(TERR[upstream_idx]);
            upstream_on_water = up_on_water;
            const bool up_is_lake = (TERR[upstream_idx] == 18);
            const bool up_has_river = (!up_is_lake) && (RIV[upstream_idx] != 0) && (!up_on_water);
            const float up_river_q = up_has_river
                ? dc_clampf((RQ30 != nullptr ? RQ30[upstream_idx] : 0.0f), 0.0f, 1.0f)
                : 0.0f;
            float up_river_recycle_lock = 0.0f;
            if (up_has_river) {
                const float up_forcing_proxy = dc_clampf(PREV_CNV[upstream_idx] * 0.65f, 0.0f, 1.0f);
                up_river_recycle_lock = wf_smoothstep(0.035f, 0.12f, PP[upstream_idx])
                    * (1.0f - wf_smoothstep(0.16f, 0.44f, up_forcing_proxy))
                    * (0.35f + up_river_q * 0.65f);
                up_river_recycle_lock = dc_clampf(up_river_recycle_lock, 0.0f, 1.0f);
            }
            const float up_river_source_scale = 1.0f - up_river_recycle_lock * 0.72f;
            const float up_ocean_an = up_on_water ? TA[upstream_idx] : effective_ocean_an;
            source_upwind = surface_vapor_source(
                upstream_idx, up_temp, up_base_m, wind_mag, up_ocean_an,
                up_on_water, up_is_lake, up_has_river, up_river_q, up_river_source_scale);
        }

        // 平流式湿团：vapor 去 base_m 锚定 → 本地与上风加权平流(强度随风速) + 邻域扩散 + 蒸发源。
        // 允许短暂过饱和(不夹 cap 上限)，由后续凝结消耗 → 随风移动的湿团。镜像 field_solver.gd。
        // 方案③ vapor 全预报化:平流主导(floor 0.55→0.75,低风也强输送)→水汽主要由上风决定=连续方程平流项,
        // 蒸发只是注入、降水/凝结是汇,水汽随风成河(atmospheric river)→ψ 在水汽河上移动沿途有水可榨成雨。
        float adv_w_v = field_advect_vapor * (0.75f + 0.25f * wind_mag);
        if (adv_w_v > 0.99f) adv_w_v = 0.99f;
        float vapor = PV[i] + (advected_vapor - PV[i]) * adv_w_v;
        vapor = vapor + (neighbor_vapor - vapor) * field_diffusion;
        vapor += source_local + source_upwind * wind_mag * 0.25f;
        // Stage14c ψ>0 气旋水汽辐合抽吸：向邻域较湿处靠拢(把周围湿气卷入移动涡旋)→突破"水汽静止锚定"，
        // 让降水能随 ψ 平移。仅邻域更湿时抽(不凭空造汽,有界≤邻域均值)，避免破坏水量平衡致全局过湿。
        const float psi_now = (PSI != nullptr) ? PSI[i] : 0.0f;
        if (psi_now > 0.0f && neighbor_vapor > vapor) {
            vapor += (neighbor_vapor - vapor) * psi_now * 0.78f;   // Stage14e 0.55→0.78 更强抽吸→湿气更跟 ψ→移动更明显
        }
        if (vapor < 0.0f) vapor = 0.0f;
        (void)advect_w;

        // (背风焚风干燥已移入下方凝结/降水的 lift<0 抑制，避免对 vapor 重复扣减)

        // temp_min/temp_max 已在上方 P3 融合 gather 中算出。
        const float temp_gradient = temp_max - temp_min;
        // 斜压门(温度梯度大=锋面/中纬冷季)；Stage9 #5 用于把 ψ 致雨限定在斜压带(锋面雨)。
        const float baroclinic_gate = wf_smoothstep(0.04f, 0.16f, temp_gradient);
        // Stage13「让天气移动」：ψ 的演化已抽到独立全场 pass run_synoptic_advance_pass(每轮一次、
        // 不切片、半拉格朗日平移)。本 solve 循环只【读】ψ 当前值做耦合 → ψ 移动 → 云/雨成片随风平移。
        const float psi = (PSI != nullptr) ? PSI[i] : 0.0f;
        float relative_humidity = vapor / ((vapor_capacity > 0.001f) ? vapor_capacity : 0.001f);
        if (relative_humidity < 0.0f) relative_humidity = 0.0f;
        const float frontal_convergence = wf_smoothstep(0.14f, 0.46f, convergence);
        const float humidity_front_gate = wf_smoothstep(0.25f, 0.78f, relative_humidity);  // Stage2: 0.38→0.25 冷湿锋面成雨
        float frontogenesis = frontal_convergence * wf_smoothstep(0.04f, 0.16f, temp_gradient)
                            * humidity_front_gate * field_frontogenesis_gain;
        if (frontogenesis < 0.0f) frontogenesis = 0.0f;
        else if (frontogenesis > 1.0f) frontogenesis = 1.0f;
        const float lift_pos = (lift > 0.0f) ? lift : 0.0f;

        // Stage11 层状降水(stratiform)：对流(temp>0.48 暖门)挡死的冷/高/水区水汽充足却无触发——补一支不需浮力
        // 的层状成雨：湿度 + 弱动力抬升(地形/辐合/锋面/海面层云·lake-effect),温度越低权重越高(与对流互补,
        // 不在暖区重复加雨)。海面项=海洋层云/冷湖效应(修#4湖/冷海·实测水汽0.204最足却几乎不降)。
        const float strat_cool = 1.0f - wf_smoothstep(0.40f, 0.62f, temp);       // 暖→0(交给对流) 冷→1
        const float oro_elev = wf_smoothstep(0.45f, 0.82f, ELEV[i]);             // 高地形(山地)抬升强度,供 stratiform + trig 复用
        const float strat_humid = wf_smoothstep(0.32f, 0.62f, relative_humidity); // Stage14f 0.42→0.32 中湿(山地/冷区 rh~0.39)也成层状雨
        float strat_drive = lift_pos * 0.90f + convergence * 0.60f + frontogenesis * 0.80f
                          + oro_elev * 0.35f;                                     // 弱化静态山地云源，避免固定山地永雨
        if (on_water) strat_drive += (0.22f + wind_mag * 0.30f) * (1.0f - local_sea_ice * 0.92f);
        if (strat_drive > 1.0f) strat_drive = 1.0f;
        float stratiform = strat_humid * strat_cool * strat_drive * field_stratiform_gain;
        if (stratiform < 0.0f) stratiform = 0.0f;
        else if (stratiform > 1.0f) stratiform = 1.0f;

        // 热力对流(大陆夏季雷暴/对流雨)：地表加热(高温)+本地水汽 → 浮力抬升凝结+高效降水。修复内陆
        // rh 永远<<静力阈(实测~0.15<<0.55)、lift/辐合皆缺 → 蒸散/平流来的 vapor 凝不成云的死结
        // (用户洞察:内陆本地蒸发应能成雨)。仅陆地(海洋有独立对流抑制)。季节自限:冬温<0.45 不触发;
        // 降水耗 vapor→rh 降→对流减弱→不永雨,呈"晴-积累-雷暴"间歇。rh*4.2 门控干空气(rh<0.05)不虚假对流。
        // 2026-06-22 雨云化根因修复：陆地 rh 中位仅0.18(>0.55 仅2.7% → 静力凝结 sup 基本为0=死)，
        // 成云降水 76% 靠本项热力对流。rh*5.0 门控把干空气(rh0.18)硬拉成半饱和 → 温暖陆地处处冒弱对流
        // → 产云水后平流扩散 → 遍地雾+小雨、无晴无强雨。convective 实测双峰(p50=0,p75=0.39)：在谷底
        // 0.28 硬截断 → 砍遍地弱对流(仅损失6.5%降水)使其转晴/多云，保留强对流核 → 明显降水突显、拉开
        // "晴↔强降水"对比。(GDScript field_solver 镜像同值)
        float conv_raw = wf_smoothstep(0.48f, 0.74f, temp) * dc_clampf(relative_humidity * 2.6f, 0.0f, 1.0f);
        const float convective = (on_water || conv_raw < 0.42f) ? 0.0f : conv_raw;
        float ocean_convective = 0.0f;
        if (on_water) {
            ocean_convective = wf_smoothstep(0.10f, 0.22f, ocean_an)
                * wf_smoothstep(0.58f, 0.78f, temp)
                * dc_clampf(relative_humidity, 0.0f, 1.0f);
            const float open_water = 1.0f - local_sea_ice * 0.92f;
            const float warm_humid_marine = wf_smoothstep(0.54f, 0.74f, temp)
                * wf_smoothstep(0.47f, 0.69f, relative_humidity)
                * dc_clampf(open_water, 0.0f, 1.0f);
            const float marine_convective_seed = warm_humid_marine * (0.20f + wind_mag * 0.36f);
            if (marine_convective_seed > ocean_convective) ocean_convective = marine_convective_seed;
            if (ocean_convective > 1.0f) ocean_convective = 1.0f;
        }
        float onshore_moist_flux = 0.0f;
        float coastal_monsoon_flux = 0.0f;
        if (!on_water && upstream_idx >= 0 && upstream_on_water) {
            onshore_moist_flux = wind_mag * dc_clampf(relative_humidity, 0.0f, 1.0f)
                               * wf_smoothstep(0.54f, 0.75f, temp);
            coastal_monsoon_flux = onshore_moist_flux;
        } else if (on_water && upstream_idx >= 0) {
            const int downwind_idx = wx_aligned(i, wind_dx, wind_dy);
            bool near_land = false;
            if (downwind_idx >= 0 && downwind_idx < n_cells) {
                near_land = !wf_is_water_terrain(TERR[downwind_idx]);
            }
            if (near_land) {
                coastal_monsoon_flux = wind_mag * dc_clampf(relative_humidity, 0.0f, 1.0f)
                                     * wf_smoothstep(0.56f, 0.76f, temp) * 0.75f;
            }
        }
        if (thermal_monsoon_enabled &&
            i < state.monsoon_thermal_count) {
            coastal_monsoon_flux *= std::max(
                0.0f, MONS[static_cast<size_t>(i)]);
        }
        float dynamic_forcing = frontogenesis;
        const float convergence_forcing = convergence * 0.65f;
        if (convergence_forcing > dynamic_forcing) dynamic_forcing = convergence_forcing;
        if (convective > dynamic_forcing) dynamic_forcing = convective;
        if (ocean_convective > dynamic_forcing) dynamic_forcing = ocean_convective;
        if (coastal_monsoon_flux > dynamic_forcing) dynamic_forcing = coastal_monsoon_flux;
        if (cyclone_lift > dynamic_forcing) dynamic_forcing = cyclone_lift;
        if (stratiform > dynamic_forcing) dynamic_forcing = stratiform;  // Stage11 冷区层状降水
        // Stage12「让天气移动」: ψ>0(气旋/低压)在所有纬度加抬升(base)+斜压带额外强化(锋面)→移动的雨系统;
        // ψ 随流场平流→雨带跟着移动。Stage9 的纯斜压门控改为 base + 斜压 bonus(热带也吃 base,接受适度热带变率)。
        // Stage14「激进推 ψ 主导」: ψ>0(低压)强抬升成降水主驱动；ψ<0(高压)下沉【压低静止 lift】→连静止
        // 强迫的降水也压住 → 移动的晴空带。这样降水/晴空都跟 ψ 平移(天气成片移动)。代价:过湿+扰动雨热。
        if (psi > 0.0f) {
            dynamic_forcing += psi * (syn_base_lift + syn_front_force * baroclinic_gate);
        } else {
            dynamic_forcing *= (1.0f + psi * 0.85f);   // psi<0 → ×<1 压低静止抬升
            if (dynamic_forcing < 0.0f) dynamic_forcing = 0.0f;
        }
        // Stage6: post-rain 抑制留 45% 残余(辐合带雨团下完也进入不应期)。镜像 field_solver.gd。
        float post_rain_subsidence = wf_smoothstep(0.035f, 0.11f, PP[i])
            * (1.0f - 0.55f * wf_smoothstep(0.18f, 0.55f, dynamic_forcing));

        // climate-realism Stage1: Hadley/Ferrel omega (镜像 field_solver.gd)
        // dlat = 本格纬度距「热赤道」度数; ITCZ/风暴轴上升带增雨, 副热带下沉带抑制凝结+降水→晴干。
        float omega_ny = (wb_size_y > 0.001f)
            ? dc_clampf((POSY[i] - wb_pos_y) / wb_size_y, 0.0f, 1.0f) : 0.5f;
        float omega_adlat = (omega_ny - weather_lat_te_norm) * 180.0f;
        if (omega_adlat < 0.0f) omega_adlat = -omega_adlat;
        const float omega_itcz = 1.0f - wf_smoothstep(8.0f, 16.0f, omega_adlat);
        const float omega_storm = wf_smoothstep(40.0f, 48.0f, omega_adlat)
            * (1.0f - wf_smoothstep(62.0f, 70.0f, omega_adlat));
        float omega_ascent = (omega_itcz > omega_storm) ? omega_itcz : omega_storm;
        const float omega_descent = wf_smoothstep(14.0f, 22.0f, omega_adlat)
            * (1.0f - wf_smoothstep(34.0f, 42.0f, omega_adlat));
        const float omega_precip_mult = (1.0f + omega_ascent * OMEGA_ASCENT_GAIN)
            * (1.0f - omega_descent * OMEGA_DESCENT_GAIN);

        // 凝结 vapor→cloud_water：动力(抬升/辐合)主导 + 静力过饱和(rh 超阈) + 热力对流。
        float sup = relative_humidity - field_rh_condense;
        if (sup < 0.0f) sup = 0.0f;
        // Stage14「ψ 主导降水」：ψ 直接进【凝结/降水生成】(像 convective/stratiform 旁路 autoconv)，让移动的
        // ψ 涡旋成为降水主源→云雨成片随 ψ 平移。之前 base_lift 误加进 dynamic_forcing(不驱动 cond/trig)→无效。
        const float psi_lift = (psi > 0.0f) ? psi * (syn_base_lift + syn_front_force * baroclinic_gate) : 0.0f;
        const float psi_supp = (psi < 0.0f) ? (1.0f + psi * 0.50f) : 1.0f;  // ψ<0(高压)压低凝结+降水→移动晴空(Stage14c 0.80→0.50 收温和,防压太干)
        float cond_force = sup * field_static_cond_w + lift_pos * field_lift_cond_gain
                         + convergence * field_conv_cond_gain + frontogenesis * 1.35f
                         + convective * field_thermal_conv_cond
                         + ocean_convective * 0.90f
                         + stratiform * 0.75f
                         + cyclone_lift * 1.10f
                         + psi_lift * 1.20f;     // 方案③+ 0.90→1.20 ψ 致凝结(移动涡旋成云,主导)
        if (cond_force < 0.0f) cond_force = 0.0f;
        else if (cond_force > 1.0f) cond_force = 1.0f;
        cond_force *= psi_supp;                  // Stage14 ψ<0 压低凝结
        cond_force *= (1.0f - post_rain_subsidence * 0.45f);
        cond_force *= (1.0f - omega_descent * OMEGA_DESCENT_COND);   // 副热带下沉抑制凝结
        float condensation = vapor * cond_force * field_condense_rate;
        if (lift < 0.0f) {                       // 背风下沉(焚风)抑制凝结
            float foehn = 1.0f + lift * field_rain_shadow_drying;
            if (foehn < 0.0f) foehn = 0.0f;
            condensation *= foehn;
        }
        if (condensation > vapor * 0.92f) condensation = vapor * 0.92f;
        if (condensation < 0.0f) condensation = 0.0f;
        vapor -= condensation;

        // cloud_water 随风平流(搬运湿团) + 凝结加入 + 邻域扩散。复用 vapor 平流 helper(传 PCW)。
        float cloud_water = (PCW != nullptr) ? PCW[i] : 0.0f;
        if (PCW != nullptr && upstream_idx >= 0 && upstream_idx < n_cells) {
            // NS 化 Phase 2:与 vapor 同一张轨迹表(湿团整体随风输运)。
            const float cw_upwind = (TRAJ_IDX != nullptr)
                ? wx_traj_sample(i, PCW)
                : wx_upstream_avg(i, upstream_idx, PCW, wind_dx, wind_dy);
            const float cw_neighbor = wf_neighbor_average_vapor_idx(i, NB, PCW);
            float adv_w_c = field_advect_cloud * (0.55f + 0.45f * wind_mag);
            if (adv_w_c > 0.98f) adv_w_c = 0.98f;
            cloud_water = cloud_water + (cw_upwind - cloud_water) * adv_w_c;
            cloud_water = cloud_water + (cw_neighbor - cloud_water) * field_diffusion;
        }
        cloud_water += condensation;
        if (cloud_water < 0.0f) cloud_water = 0.0f;
        else if (cloud_water > 1.0f) cloud_water = 1.0f;

        float instability = (temp - 0.48f) * 0.80f
                          + relative_humidity * 0.30f
                          + convergence * 0.55f
                          + lift_pos * 1.20f
                          + frontogenesis * 0.55f
                          + ocean_convective * 0.35f;
        instability += cyclone_lift * 0.45f;
        if (instability < 0.0f) instability = 0.0f;
        else if (instability > 1.0f) instability = 1.0f;

        // 降水：autoconversion 消耗 cloud_water。动力(辐合/抬升/不稳定)触发主导，地形弱增强；
        // 背景 base_frac 很小 → 无动力区降水压到 wet 阈值以下 → 只有移动天气系统处成雨 → 雨随系统移动。
        float trig = field_autoconversion * (field_precip_base_frac
                        + lift_pos * field_lift_precip_gain
                        + convergence * field_conv_precip_gain
                        + frontogenesis * 0.85f
                        + instability * 0.30f);
        trig *= (1.0f + lift_pos * field_oro_precip_gain);
        trig += convective * field_thermal_conv_precip;   // 对流雨高效成雨，旁路 autoconv 瓶颈(内陆 cw 少)
        trig += ocean_convective * 0.95f;
        trig += stratiform * 0.80f;   // Stage11 层状降水高效成雨(冷/高/水区,旁路 autoconv)→修 #4湖/#5a雪/#6山
        trig += cyclone_lift * 0.75f;
        trig += psi_lift * 1.50f;     // 方案③+ 1.10→1.50 ψ 致雨主驱动(降水成片随 ψ 平移,盖过静止 lift)
        trig += oro_elev * 0.18f * wf_smoothstep(0.02f, 0.10f, cloud_water);  // 弱化固定地形转化，保留迎风坡但不锁死雨核
        trig *= psi_supp;             // Stage14 ψ<0 压低降水→移动晴空
        if (trig < 0.0f) trig = 0.0f;
        else if (trig > 0.95f) trig = 0.95f;
        float precip_target = cloud_water * trig;
        precip_target *= omega_precip_mult;   // Stage1 omega: ITCZ/风暴轴增雨 + 副热带下沉抑雨(纬向廓线)
        // Stage9 #5 ψ 耦合：ψ<0(高压)强抑雨→湿季间断；ψ>0(低压)增雨——基础弱(syn_enh，热带也仅此)，
        // 斜压带额外强增(syn_front_enh×gate)→冷季锋面雨。这样热带不堆暴雨、中纬冷季出现雨热不同期降水。
        if (PSI != nullptr) {
            float syn_enh_eff = syn_enh + syn_front_enh * baroclinic_gate;
            float syn_mult = 1.0f + (psi < 0.0f ? psi * syn_supp : psi * syn_enh_eff);
            if (syn_mult < 0.0f) syn_mult = 0.0f;
            precip_target *= syn_mult;
        }
        // Stage6e 对流抑制记忆(双稳)：读累积抑制(本 tick 起始)，硬阈压制移到最终降水处(EMA 之后)。
        const float inhib_old = (INHIB != nullptr) ? INHIB[i] : 0.0f;
        if (lift < 0.0f) {
            float shadow = (-lift) * field_rain_shadow_drying;
            if (shadow > 0.85f) shadow = 0.85f;
            precip_target *= (1.0f - shadow);
        }
        if (has_river && river_recycle_lock > 0.0f) {
            const float river_relief = river_recycle_lock
                * (1.0f - wf_smoothstep(0.22f, 0.50f, dynamic_forcing));
            if (river_relief > 0.0f) {
                const float cloud_relief = cloud_water * 0.22f * river_relief;
                cloud_water -= cloud_relief;
                vapor += cloud_relief * 0.60f;
                precip_target *= (1.0f - 0.48f * river_relief);
            }
        }
        // 水面对流抑制(保留动力门控：辐合/锋生/暖流异常 释放降水；instability 仅极端深对流安全阀)。
        float ocean_drive = 0.0f;
        if (on_water) {
            float drv_an = ocean_an / 0.16f;
            if (drv_an < 0.0f) drv_an = 0.0f; else if (drv_an > 1.0f) drv_an = 1.0f;
            float drv_in = (instability - 0.52f) / 0.30f;
            if (drv_in < 0.0f) drv_in = 0.0f; else if (drv_in > 1.0f) drv_in = 1.0f;
            float drv_cv = (convergence - 0.38f) / 0.16f;
            if (drv_cv < 0.0f) drv_cv = 0.0f; else if (drv_cv > 1.0f) drv_cv = 1.0f;
            float drv_fr = frontogenesis / 0.16f;
            if (drv_fr < 0.0f) drv_fr = 0.0f; else if (drv_fr > 1.0f) drv_fr = 1.0f;
            float drv_mn = coastal_monsoon_flux / 0.18f;
            if (drv_mn < 0.0f) drv_mn = 0.0f; else if (drv_mn > 1.0f) drv_mn = 1.0f;
            float drv_hc = wf_smoothstep(0.47f, 0.69f, relative_humidity)
                * wf_smoothstep(0.040f, 0.105f, cloud_water)
                * wf_smoothstep(0.54f, 0.74f, temp);
            // Stage14e 湖泊不再额外压低 humid-convective 驱动(原 ×0.60 致湖面少雨绕湖)；湖泊像小内海正常对流。
            drv_hc *= 0.68f;
            ocean_drive = drv_an;
            if (drv_in > ocean_drive) ocean_drive = drv_in;
            if (drv_cv > ocean_drive) ocean_drive = drv_cv;
            if (drv_fr > ocean_drive) ocean_drive = drv_fr;
            if (drv_mn > ocean_drive) ocean_drive = drv_mn;
            if (drv_hc > ocean_drive) ocean_drive = drv_hc;
            if (omega_ascent > ocean_drive) ocean_drive = omega_ascent;   // ITCZ/风暴轴释放海面抑制
            float precip_suppression = field_ocean_precip_suppression;
            if (is_lake && precip_suppression > 0.10f) precip_suppression = 0.10f;  // Stage14e 湖泊几乎不抑制(像内陆水体能下雨)→不再绕湖(原0.35仍压制)
            if (!is_lake && precip_suppression > 0.78f) precip_suppression = 0.78f;
            const float ocean_lo = 1.0f - precip_suppression;
            precip_target *= ocean_lo + (1.0f - ocean_lo) * ocean_drive;
            const float marine_relief = post_rain_subsidence
                * (1.0f - wf_smoothstep(0.30f, 0.58f, ocean_drive));
            precip_target *= (1.0f - marine_relief * 0.72f);
        }
        if (precip_target > cloud_water) precip_target = cloud_water;   // 降水不超过现有云水
        if (precip_target < 0.0f) precip_target = 0.0f;
        cloud_water -= precip_target;
        if (cloud_water < 0.0f) cloud_water = 0.0f;
        const float precip_cloud_reserve = precip_target * (0.18f + dynamic_forcing * 0.18f);
        cloud_water += precip_cloud_reserve;
        if (cloud_water > 1.0f) cloud_water = 1.0f;
        const float quiet_core = 1.0f - wf_smoothstep(0.12f, 0.50f, dynamic_forcing);
        if (on_water && !is_lake && ocean_drive < 0.34f) {   // Stage14e 湖泊不刮云水(marine_scour 是海洋机制,会让小湖云存不住→绕湖)
            float marine_scour = cloud_water * (0.036f + (0.34f - ocean_drive) * 0.18f)
                               * (1.0f + post_rain_subsidence * 1.60f);
            if (marine_scour < 0.0f) marine_scour = 0.0f;
            if (marine_scour > cloud_water) marine_scour = cloud_water;
            cloud_water -= marine_scour;
            vapor += marine_scour * 0.55f;
        }

        // 干空气云水再蒸发回 vapor（湿团边缘消散 → 闭合水量收支）。
        float reevap = cloud_water * field_cloud_reevap * (1.0f - relative_humidity)
                     * (1.0f + post_rain_subsidence * 1.75f + quiet_core * 0.75f);
        if (reevap < 0.0f) reevap = 0.0f;
        if (reevap > cloud_water) reevap = cloud_water;
        cloud_water -= reevap;
        vapor += reevap;
        if (on_water) {
            vapor *= (1.0f - post_rain_subsidence
                * (1.0f - wf_smoothstep(0.28f, 0.58f, ocean_drive)) * 0.045f);
        }

        // 降水稳定性(地形阻尼 + 极端 soft cap) + EMA 时间惯性(保留)。
        precip_target = wf_apply_precip_stability(
            TERR[i], precip_target,
            field_wet_terrain_precip_damping,
            field_lake_precip_damping,
            field_extreme_precip_soft_cap,
            field_extreme_precip_softness);
        // Stage10 不应期(inhib≥1)作用于 target(EMA 前)→降水随惯性平滑衰减到近零，不再瞬间砍断(去时间跳变)。镜像 field_solver.gd。
        if (inhib_old >= 1.0f) {
            precip_target *= (1.0f - INHIB_STRENGTH);
        }
        float precip = PP[i] + (precip_target - PP[i]) * field_precip_inertia;
        if (precip_target < PP[i] && dynamic_forcing < 0.20f) {
            precip = precip + (precip_target - precip) * (post_rain_subsidence * 0.55f);
        }
        // Stage10b 空间平滑(非对称)：强填洞(precip<邻域→去棋盘洞+扩雨到干邻格，降永晴)、弱削峰(×0.30→保超级单体暴雨)。镜像 field_solver.gd。
        if (field_precip_spatial_smooth > 0.0f) {
            const float nbr_precip = wf_neighbor_average_vapor_idx(i, NB, PP);
            const float k = (nbr_precip > precip) ? field_precip_spatial_smooth
                                                  : field_precip_spatial_smooth * 0.30f;
            precip += (nbr_precip - precip) * k;
        }
        const float effective_precip_floor = on_water ? 0.014f : 0.018f;
        if (precip < 0.003f) precip = 0.0f;
        const float provisional_cloud = dc_clampf(cloud_water * 1.10f + condensation * 0.25f, 0.0f, 1.0f);
        const float temp_anom_i = (TANO != nullptr) ? TANO[i] : 0.0f;
        const float snow_cover_cls = (SNOWR != nullptr) ? SNOWR[i] : 0.0f;
        uint8_t pre_wt = wf_classify_field_weather_at(
            temp, vapor, provisional_cloud, cloud_water, precip, instability,
            ocean_an, wind_len, temp_anom_i,
            std::max(onshore_moist_flux, coastal_monsoon_flux),
            cold_precip_as_blizzard, snow_classification_margin, on_water, snow_cover_cls);
        const bool quiet_non_precip = !wf_is_precip_weather_type(pre_wt) && quiet_core > 0.0f;
        if ((precip < 0.003f || quiet_non_precip) && quiet_core > 0.0f) {
            float clear_cap = 0.065f + dynamic_forcing * 0.12f;
            if (on_water && ocean_drive < 0.20f) {
                const float ocean_cap = 0.070f + ocean_drive * 0.18f;
                if (ocean_cap < clear_cap) clear_cap = ocean_cap;
            }
            if (cloud_water > clear_cap) {
                const float excess_cloud_water = (cloud_water - clear_cap) * quiet_core;
                cloud_water -= excess_cloud_water;
                vapor += excess_cloud_water * 0.75f;
            }
        }
        if (quiet_non_precip && precip < effective_precip_floor) {
            vapor += precip * 0.65f;
            precip = 0.0f;
        }
        if (vapor < 0.0f) vapor = 0.0f;
        else if (vapor > 1.0f) vapor = 1.0f;   // 写回夹 [0,1]：下游(分类/可视/植被)按归一化消费
        float vapor_after_precip = vapor;
        const float rain_core = wf_smoothstep(0.025f, 0.095f, precip);
        const float front_core = wf_smoothstep(0.08f, 0.55f, frontogenesis);
        float cloud_floor = rain_core * (0.14f + rain_core * 0.22f);
        const float front_cloud_floor = front_core * 0.30f;
        if (front_cloud_floor > cloud_floor) cloud_floor = front_cloud_floor;
        if (convective > 0.0f) {
            const float convective_cloud_floor = 0.06f + convective * 0.18f;
            if (convective_cloud_floor > cloud_floor) cloud_floor = convective_cloud_floor;
        }
        if (ocean_convective > 0.0f) {
            const float ocean_cloud_floor = 0.10f + ocean_convective * 0.16f;
            if (ocean_cloud_floor > cloud_floor) cloud_floor = ocean_cloud_floor;
        }
        if (quiet_non_precip) {
            const float fair_humid = wf_smoothstep(0.34f, 0.56f, relative_humidity);
            const float fair_cloud_floor = fair_humid * quiet_core * (0.050f + fair_humid * 0.070f);
            if (fair_cloud_floor > cloud_floor) cloud_floor = fair_cloud_floor;
        }
        float cloud = cloud_water * 1.10f + condensation * 0.25f;
        if (cloud < cloud_floor) cloud = cloud_floor;
        // Stage15 云量时间 EMA(减 shader 闪烁)：cloud 混入瞬时 condensation/cloud_floor(无时间惯性)→在渲染阈值
        // 附近抖动闪烁。用上帧云量做 EMA 平滑(cloud_water 本身已平滑,只需压住瞬时项的抖)。
        const float prev_cloud = PREV_CLOUD[i];
        cloud = prev_cloud + (cloud - prev_cloud) * field_cloud_inertia;
        if (cloud < 0.0f) cloud = 0.0f;
        else if (cloud > 1.0f) cloud = 1.0f;

        // classify + intensity
        uint8_t wt = wf_classify_field_weather_at(
            temp, vapor, cloud, cloud_water, precip, instability,
            ocean_an, wind_len, temp_anom_i,
            std::max(onshore_moist_flux, coastal_monsoon_flux),
            cold_precip_as_blizzard, snow_classification_margin, on_water, snow_cover_cls);
        if (cyclone_lift >= 0.58f && on_water) {
            wt = cyclone_storm_type_id;
        }
        if (!wf_is_precip_weather_type(wt) && precip > 0.0f) {
            vapor += precip * 0.65f;
            if (vapor > 1.0f) vapor = 1.0f;
            vapor_after_precip = vapor;
            precip = 0.0f;
        } else if (precip > 0.0f) {
            // Stage6 放电：实际降水抽干本格水汽→自发停雨/消散+随上风水汽移动+海面自生成。镜像 field_solver.gd。
            // Stage6b：持续降水(PP[i])放电翻倍→砍"连下一周"长尾，不动新生短雨段。
            const float discharge_amp = 1.0f + DISCHARGE_SUSTAIN * wf_smoothstep(0.04f, 0.10f, PP[i]);
            vapor_after_precip -= precip * VAPOR_DISCHARGE * discharge_amp;
            if (vapor_after_precip < 0.0f) vapor_after_precip = 0.0f;
        }
        // Stage6g 更新对流抑制(按时长两段)：充能期连续降水累加→满进不应期；不应期衰减→落回清零重启。镜像 field_solver.gd。
        if (INHIB != nullptr) {
            float ni;
            if (inhib_old >= 1.0f) {
                ni = inhib_old - INHIB_REFRAC;
                if (ni < 1.0f) ni = 0.0f;
            } else if (precip > INHIB_WET) {
                ni = inhib_old + INHIB_CHARGE;
                if (ni >= 1.0f) ni = 2.0f;
            } else {
                ni = inhib_old * INHIB_LEAK;
            }
            INHIB[i] = ni;
        }
        float intensity = wf_field_intensity_for_type(
            wt, temp, vapor, cloud, precip, instability, ocean_an);
        if (refresh_convergence && apply_convergence_boost) {
            wf_apply_frontal_convergence_boost_idx(
                i, TR, AA, NB, climate_anomaly, convergence,
                temp, vapor, ocean_an,
                cloud, precip, instability, wt, intensity);
        }

        uint8_t display_wt = wt;
        if (weather_transition_enabled && OUT_PREV_TYP != nullptr && OUT_TARGET_TYP != nullptr && OUT_ALPHA != nullptr) {
            const uint8_t current_display = OUT_TYP[i];
            uint8_t prev_type = OUT_PREV_TYP[i];
            uint8_t target_type = OUT_TARGET_TYP[i];
            float alpha = OUT_ALPHA[i];
            if (alpha < 0.0f) alpha = 0.0f;
            else if (alpha > 1.0f) alpha = 1.0f;
            if (target_type != wt) {
                prev_type = current_display;
                target_type = wt;
                alpha = weather_transition_alpha_rate * weather_transition_dt_days; // [dt-aware] 当前求解即计入
                if (alpha > 1.0f) alpha = 1.0f;
            } else if (prev_type == target_type || current_display == target_type) {
                prev_type = target_type;
                alpha = 0.0f;
            } else {
                alpha += weather_transition_alpha_rate * weather_transition_dt_days;
                if (alpha > 1.0f) alpha = 1.0f;
            }
            display_wt = (alpha >= 1.0f) ? target_type : prev_type;
            if (alpha >= 1.0f) {
                prev_type = target_type;
                alpha = 0.0f;
            }
            OUT_PREV_TYP[i] = prev_type;
            OUT_TARGET_TYP[i] = target_type;
            OUT_ALPHA[i] = alpha;
        }

        // (line 751-757) write outputs
        OUT_VAP[i] = vapor_after_precip;
        OUT_CLD[i] = cloud;
        if (OUT_CW != nullptr) {
            OUT_CW[i] = cloud_water;
        }
        OUT_PRE[i] = precip;
        OUT_INS[i] = instability;
        OUT_INT[i] = intensity;
        OUT_CNV[i] = convergence;
        if (use_next_outputs) {
            OUT_TYP_I32[i] = int32_t(wt);
        } else {
            OUT_TYP[i] = display_wt;
            OUT_FIN[i] = 1; // weather_field_initialized = true
        }
    }
}

void weather_commit_pure(const WeatherCommitKnobs &knobs,
                         const WeatherCommitLanes &lanes,
                         WeatherCommitStats &stats) {
    stats = WeatherCommitStats{};
    if (knobs.n_cells <= 0) return;
    if (lanes.next_vapor == nullptr || lanes.next_cloud == nullptr ||
        lanes.next_precip == nullptr || lanes.next_instability == nullptr ||
        lanes.next_intensity == nullptr || lanes.next_convergence == nullptr ||
        lanes.next_type == nullptr || lanes.prev_vapor == nullptr ||
        lanes.neighbor_indices == nullptr) {
        return;
    }
    if (lanes.intensity == nullptr || lanes.cloud == nullptr ||
        lanes.precip == nullptr || lanes.vapor == nullptr ||
        lanes.convergence == nullptr || lanes.instability == nullptr ||
        lanes.type == nullptr || lanes.field_init == nullptr ||
        lanes.dirty == nullptr) {
        return;
    }
    // ── 前言：把 knobs/lanes 摊回生产里的局部名，计算体得以原样保留 ──
    const int n_cells = knobs.n_cells;
    const bool refresh_convergence = knobs.refresh_convergence;
    const bool weather_transition_enabled = knobs.weather_transition_enabled;
    const float transition_rate = knobs.transition_rate;
    const float transition_dt_days = knobs.transition_dt_days;

    const int32_t * const __restrict NB = lanes.neighbor_indices;
    const float * const __restrict PREV_VAP = lanes.prev_vapor;
    const float * const __restrict NEXT_VAP = lanes.next_vapor;
    const float * const __restrict NEXT_CLD = lanes.next_cloud;
    const float * const __restrict NEXT_CW = lanes.next_cloud_water;
    const float * const __restrict NEXT_PRE = lanes.next_precip;
    const float * const __restrict NEXT_INS = lanes.next_instability;
    const float * const __restrict NEXT_INT = lanes.next_intensity;
    const float * const __restrict NEXT_CNV = lanes.next_convergence;
    const int32_t * const __restrict NEXT_TYP = lanes.next_type;

    float * const __restrict W_INT = lanes.intensity;
    float * const __restrict W_CLD = lanes.cloud;
    float * const __restrict W_CW = lanes.cloud_water;
    float * const __restrict W_PRE = lanes.precip;
    uint8_t * const __restrict W_TYP = lanes.type;
    uint8_t * const __restrict W_PREV = lanes.prev_type;
    uint8_t * const __restrict W_TARGET = lanes.target_type;
    float * const __restrict W_ALPHA = lanes.transition_alpha;
    float * const __restrict W_VAP = lanes.vapor;
    float * const __restrict W_CNV = lanes.convergence;
    float * const __restrict W_INS = lanes.instability;
    uint8_t * const __restrict W_FIN = lanes.field_init;
    uint8_t * const __restrict W_DIRTY = lanes.dirty;

    // LUT 是纯输出；生产总会给一块 lut_slots*4 的 buffer，worker 可以不要。
    uint8_t * const __restrict WX = lanes.lut;
    auto q01_byte_commit = [](float v) -> uint8_t {
        if (v <= 0.0f) return uint8_t(0);
        if (v >= 1.0f) return uint8_t(255);
        return uint8_t(std::clamp(int(std::round(double(v) * 255.0)), 0, 255));
    };

    for (int i = 0; i < n_cells; ++i) {
        W_DIRTY[i] = 0;
    }

    int dirty_count = 0;
    int convergence_dirty_count = 0;
    float * const __restrict CONV_DELTA =
        refresh_convergence ? lanes.convergence_deltas : nullptr;
    double water_budget_error_acc = 0.0;
    constexpr float CHANGE_EPS = 0.002f;

    for (int i = 0; i < n_cells; ++i) {
        const float v_vapor = NEXT_VAP[i];
        const float v_cloud = NEXT_CLD[i];
        const float v_cloud_water =
            (NEXT_CW != nullptr) ? NEXT_CW[i] : (v_cloud * 0.5f);
        const float v_precip = NEXT_PRE[i];
        const float v_instability = NEXT_INS[i];
        const float v_intensity = NEXT_INT[i];
        const float v_convergence = NEXT_CNV[i];
        const uint8_t v_type = static_cast<uint8_t>(NEXT_TYP[i] & 0xFF);
        if (refresh_convergence) {
            const float conv_delta = std::fabs(W_CNV[i] - v_convergence);
            if (conv_delta > 0.0005f && CONV_DELTA != nullptr) {
                CONV_DELTA[convergence_dirty_count++] = conv_delta;
            }
        }

        const float prev_budget_cloud_water = (W_CW != nullptr) ? W_CW[i] : 0.0f;
        water_budget_error_acc += std::fabs(
            double(v_vapor + v_cloud_water + v_precip) -
            double(PREV_VAP[i] + prev_budget_cloud_water));

        uint8_t display_type = v_type;
        uint8_t prev_type = v_type;
        uint8_t target_type = v_type;
        float alpha = 1.0f;
        if (weather_transition_enabled && W_PREV != nullptr && W_TARGET != nullptr && W_ALPHA != nullptr) {
            const uint8_t current_display = W_TYP[i];
            prev_type = W_PREV[i];
            target_type = W_TARGET[i];
            alpha = W_ALPHA[i];
            if (alpha < 0.0f) alpha = 0.0f;
            else if (alpha > 1.0f) alpha = 1.0f;
            if (target_type != v_type) {
                prev_type = current_display;
                target_type = v_type;
                alpha = transition_rate * transition_dt_days; // [dt-aware] 当前求解即计入
                if (alpha > 1.0f) alpha = 1.0f;
            } else if (prev_type == target_type || current_display == target_type) {
                prev_type = target_type;
                alpha = 0.0f;
            } else {
                alpha += transition_rate * transition_dt_days;
                if (alpha > 1.0f) alpha = 1.0f;
            }
            display_type = (alpha >= 1.0f) ? target_type : prev_type;
            if (alpha >= 1.0f) {
                prev_type = target_type;
                alpha = 0.0f;
            }
        }

        bool weather_changed = false;
        weather_changed = weather_changed || (std::fabs(W_VAP[i] - v_vapor) > CHANGE_EPS);
        weather_changed = weather_changed || (std::fabs(W_CLD[i] - v_cloud) > CHANGE_EPS);
        if (W_CW != nullptr) {
            weather_changed = weather_changed || (std::fabs(W_CW[i] - v_cloud_water) > CHANGE_EPS);
        }
        weather_changed = weather_changed || (std::fabs(W_PRE[i] - v_precip) > CHANGE_EPS);
        weather_changed = weather_changed || (W_TYP[i] != display_type);

        if (weather_changed) {
            if (W_DIRTY[i] == 0) {
                W_DIRTY[i] = 1;
                ++dirty_count;
            }
            const int nb_base = i * 6;
            for (int d = 0; d < 6; ++d) {
                const int32_t nb_i = NB[nb_base + d];
                if (nb_i >= 0 && nb_i < n_cells && W_DIRTY[nb_i] == 0) {
                    W_DIRTY[nb_i] = 1;
                    ++dirty_count;
                }
            }
        }

        W_INT[i] = v_intensity;
        W_CLD[i] = v_cloud;
        if (W_CW != nullptr) {
            W_CW[i] = v_cloud_water;
        }
        W_PRE[i] = v_precip;
        W_TYP[i] = display_type;
        if (WX != nullptr) {
            const int w4 = i * 4;
            WX[w4] = display_type;
            WX[w4 + 1] = q01_byte_commit(v_intensity);
            WX[w4 + 2] = q01_byte_commit(v_cloud);
            WX[w4 + 3] = q01_byte_commit(v_vapor);
        }
        if (W_PREV != nullptr) {

            W_PREV[i] = prev_type;
        }
        if (W_TARGET != nullptr) {
            W_TARGET[i] = target_type;
        }
        if (W_ALPHA != nullptr) {
            W_ALPHA[i] = alpha;
        }
        W_VAP[i] = v_vapor;
        W_CNV[i] = v_convergence;
        W_INS[i] = v_instability;
        W_FIN[i] = 1;
    }

    stats.dirty_count = dirty_count;
    stats.convergence_dirty_count = convergence_dirty_count;
    stats.water_budget_error_sum = water_budget_error_acc;
}

// weather distribute。计算体从 DCWorldExt::run_weather_distribute_pass 原样搬来，
// 连那几个局部 lambda 一起 —— 它们本来就不碰 Godot，跟着走比重写一遍安全。
void weather_distribute_pure(const WeatherDistributeKnobs &k,
                             const WeatherDistributeLanes &lanes,
                             const WeatherDistributeState &state,
                             WeatherDistributeEmit &emit) {
    const int n_cells = k.n_cells;
    if (n_cells <= 0) return;
    if (lanes.temp == nullptr || lanes.moisture == nullptr ||
        lanes.snow_cover == nullptr || lanes.snowpack == nullptr ||
        lanes.water_balance_30d == nullptr || lanes.soil_moisture == nullptr ||
        lanes.cover == nullptr || lanes.heat == nullptr ||
        lanes.elevation == nullptr || lanes.landform == nullptr ||
        lanes.terrain == nullptr || lanes.weather_intensity == nullptr ||
        lanes.weather_precip == nullptr || lanes.weather_type == nullptr ||
        lanes.weather_field_init == nullptr ||
        state.accumulated_snow_days == nullptr ||
        state.pre_snow_cover == nullptr) {
        return;
    }

    const float snow_min_intensity = k.snow_min_intensity;
    const float snow_freeze_t = k.snow_freeze_t;
    const float snow_melt_t = k.snow_melt_t;
    const float snow_intensity_snow = k.snow_intensity_snow;
    const int   snow_accum_days_req = k.snow_accum_days_req;
    const float flood_heavy_int = k.flood_heavy_int;
    const float flood_heavy_pre = k.flood_heavy_pre;
    const float flood_low_int = k.flood_low_int;
    const float flood_low_elev = k.flood_low_elev;
    const float flood_low_moist = k.flood_low_moist;
    const int   wt_clear = k.wt_clear;
    const int   cv_snow = k.cv_snow;
    const int   cv_none = k.cv_none;
    const int   cv_flooding = k.cv_flooding;
    const float snowpack_accum_gain = k.snowpack_accum_gain;
    const float snowpack_melt_temp_gain = k.snowpack_melt_temp_gain;
    const float snowpack_melt_sun_gain = k.snowpack_melt_sun_gain;
    const float snowpack_cover_low = k.snowpack_cover_low;
    const float snowpack_cover_full = k.snowpack_cover_full;
    // 与生产同式：span/band 的下限保护在这里做，不在调用方。
    const float snowpack_cover_span = (snowpack_cover_full - snowpack_cover_low) > 0.001f
        ? (snowpack_cover_full - snowpack_cover_low) : 0.001f;
    const float snowline_temp_threshold = k.snowline_temp_threshold;
    const float snowline_band_safe = k.snowline_band > 0.001f ? k.snowline_band : 0.001f;
    const float weather_temp_anomaly_cap = k.weather_temp_anomaly_cap;
    const bool  direct_moisture_enabled = k.direct_moisture_enabled;

    float * const __restrict T = lanes.temp;
    float * const __restrict M = lanes.moisture;
    float * const __restrict SC = lanes.snow_cover;
    float * const __restrict SP = lanes.snowpack;
    float * const __restrict WB = lanes.water_balance_30d;
    float * const __restrict SOIL = lanes.soil_moisture;
    uint8_t * const __restrict CV = lanes.cover;
    const uint8_t * const __restrict LF = lanes.landform;
    const uint8_t * const __restrict TERR = lanes.terrain;
    const float * const __restrict EL = lanes.elevation;
    const float * const __restrict HEAT = lanes.heat;
    const float * const __restrict WI = lanes.weather_intensity;
    const float * const __restrict WP = lanes.weather_precip;
    const uint8_t * const __restrict WT_ = lanes.weather_type;
    const uint8_t * const __restrict WFI = lanes.weather_field_init;
    int32_t * const __restrict ACC = state.accumulated_snow_days;
    int32_t * const __restrict PRE = state.pre_snow_cover;
    const float * const __restrict TD = k.temp_delta;
    const float * const __restrict MD = k.moist_delta;
    const uint8_t * const __restrict CFS = k.can_form_snow;
    const uint8_t * const __restrict CFF = k.can_form_flood;

    auto clamp01 = [](float v) -> float {
        if (v < 0.0f) return 0.0f;
        if (v > 1.0f) return 1.0f;
        return v;
    };
    auto clampf = [](float v, float lo, float hi) -> float {
        return v < lo ? lo : (v > hi ? hi : v);
    };
    auto smoothstep_local = [&](float a, float b, float x) -> float {
        if (b <= a) return x >= b ? 1.0f : 0.0f;
        float t = (x - a) / (b - a);
        if (t < 0.0f) t = 0.0f; else if (t > 1.0f) t = 1.0f;
        return t * t * (3.0f - 2.0f * t);
    };
    constexpr uint8_t COVER_GLACIER = 2;

    auto snow_summer_melt_bonus = [&](float heat_input, float elevation) -> float {
        const float sun = smoothstep_local(0.55f, 0.90f, clampf(heat_input, 0.0f, 1.0f));
        const float high_elev = smoothstep_local(0.62f, 0.95f, clampf(elevation, 0.0f, 1.0f));
        return sun * (1.0f - high_elev * 0.60f) * 0.045f;
    };

    auto snowline_floor_for_cell = [&](float temp_now, float heat_input, float elevation,
                                       float snowline_temp_threshold,
                                       float snowline_band_safe) -> float {
        if (snowline_temp_threshold <= 0.0f) return 0.0f;
        const float sun = smoothstep_local(0.45f, 0.85f, clampf(heat_input, 0.0f, 1.0f));
        const float high_elev = smoothstep_local(0.60f, 0.95f, clampf(elevation, 0.0f, 1.0f));
        const float summer_drop = sun * (0.14f + (0.045f - 0.14f) * high_elev);
        const float elev_bonus = clampf((elevation - 0.30f) * 0.10f, 0.0f, 0.08f);
        const float effective_threshold = snowline_temp_threshold + elev_bonus - summer_drop;
        const float raw_floor = clampf((effective_threshold - temp_now) / snowline_band_safe, 0.0f, 1.0f);
        // Stage4(2026-06-23): 雪线 floor 只为深冻区自动铺白；雪线边缘交给 snowpack-from-snowfall。
        // 镜像 weather_system.gd _snowline_floor_for_cell。
        return smoothstep_local(0.30f, 0.80f, raw_floor);
    };

    // LandformType.is_water：DEEP_OCEAN(0) / OCEAN(1) / COAST(2) / LAKE(3) → true
    auto is_water_lf = [](uint8_t lf) -> bool {
        return lf <= 3;
    };
    auto is_water_terrain = [](uint8_t t) -> bool {
        return t == 0  ||  // OCEAN
               t == 1  ||  // COAST
               t == 18 ||  // LAKE
               t == 19 ||  // REEF
               t == 20 ||  // SEA_ICE
               t == 21;    // KELP
    };

    // ─── 主循环（1:1 复刻 _distribute_weather_field_to_cells + _apply_snow_accumulation）─
    std::vector<int32_t> &changed_cells = emit.changed_cells;
    bool cover_dirty = false;
    for (int i = 0; i < n_cells; ++i) {
        const bool field_init = WFI[i] != 0;
        const int  wt        = field_init ? int(WT_[i]) : wt_clear;
        const float intensity = field_init ? WI[i] : 0.0f;
        const float raw_precip = field_init ? WP[i] : 0.0f;
        const float precip = (field_init && wf_is_precip_weather_type(uint8_t(wt))) ? raw_precip : 0.0f;

        // CLEAR / 低强度退化分支
        if (wt == wt_clear || intensity <= snow_min_intensity) {
            const bool water_lf = is_water_lf(LF[i]) || is_water_terrain(TERR[i]);
            if (!water_lf && (ACC[i] > 0 || CV[i] == cv_snow)) {
                // _apply_snow_accumulation(cell, wt, cell.temperature, 0.0)
                // intensity = 0 ⇒ snowing 永假；只有融化 / 升级判定可能触发。
                // 2026-05-18 雪线修正：melt_t 加 elev 偏移（高山难融，平原易融）。
                //   与 GDScript SNOW_ELEV_NEUTRAL=0.30 / MELT_GAIN=0.30 / MAX_OFF=0.10 SAME_SOURCE。
                const float elev_delta_c = EL[i] - 0.30f;
                float melt_off_c = elev_delta_c * 0.30f;
                if (melt_off_c >  0.10f) melt_off_c =  0.10f;
                else if (melt_off_c < -0.10f) melt_off_c = -0.10f;
                const float melt_t_local = snow_melt_t + melt_off_c;
                const float temp_now = T[i];
                if (temp_now > melt_t_local) {
                    int new_acc = ACC[i] - 1;
                    if (new_acc < 0) new_acc = 0;
                    ACC[i] = new_acc;
                }
                // 升级 / 融化（与下方主分支同算法）
                if (ACC[i] >= snow_accum_days_req && CV[i] != cv_snow && CV[i] != COVER_GLACIER) {
                    PRE[i] = int(CV[i]);
                    CV[i] = uint8_t(cv_snow);
                    changed_cells.push_back(i);
                    cover_dirty = true;
                } else if (ACC[i] <= 0 && CV[i] == cv_snow) {
                    int restored = (PRE[i] >= 0) ? PRE[i] : cv_none;
                    CV[i] = uint8_t(restored);
                    PRE[i] = -1;
                    changed_cells.push_back(i);
                    cover_dirty = true;
                }
            }
            float sp = SP[i];
            float wb = WB[i];
            float soil = SOIL[i];
            float sc = 0.0f;
            if (water_lf) {
                SP[i] = 0.0f;
                WB[i] = wb + (0.0f - wb) * (1.0f / 30.0f);
                SC[i] = 0.0f;
            } else {
                const float elev_delta = EL[i] - 0.30f;
                float melt_off = elev_delta * 0.30f;
                if (melt_off > 0.10f) melt_off = 0.10f;
                else if (melt_off < -0.10f) melt_off = -0.10f;
                const float melt_t_local = snow_melt_t + melt_off;
                float freeze_off = elev_delta * 0.20f;
                if (freeze_off > 0.06f) freeze_off = 0.06f;
                else if (freeze_off < -0.06f) freeze_off = -0.06f;
                const float freeze_t_local = snow_freeze_t + freeze_off;
                const bool cold_precip = (T[i] < freeze_t_local) && (precip > 0.002f);
                float snow_accum = cold_precip ? precip * snowpack_accum_gain * 0.75f : 0.0f;
                if (cold_precip) {
                    snow_accum += (intensity < 0.15f ? intensity : 0.15f) * 0.006f;
                }
                const float melt = ((T[i] - melt_t_local) > 0.0f ? (T[i] - melt_t_local) : 0.0f) * snowpack_melt_temp_gain
                    + HEAT[i] * snowpack_melt_sun_gain
                    + snow_summer_melt_bonus(HEAT[i], EL[i]);
                sp = clampf(sp + snow_accum - melt, 0.0f, 1.0f);
                if (CV[i] == COVER_GLACIER && sp < 0.80f) sp = 0.80f;
                const float evap_proxy = clampf((0.01f + ((M[i] - 0.45f) > 0.0f ? (M[i] - 0.45f) : 0.0f) * 0.03f)
                    * (0.35f + T[i] * 1.05f) * 0.65f, 0.0f, 1.0f);
                const float runoff = ((M[i] - 0.82f) > 0.0f ? (M[i] - 0.82f) : 0.0f) * 0.25f
                    + ((EL[i] - 0.70f) > 0.0f ? (EL[i] - 0.70f) : 0.0f) * precip * 0.06f;
                const float daily_balance = clampf(precip - evap_proxy - runoff, -1.0f, 1.0f);
                wb = wb + (daily_balance - wb) * (1.0f / 30.0f);
                // climate-loop-closure Phase 3.1：土壤水每日衰减(×0.97)，停雨后排干。
                soil = clampf(soil * 0.97f + daily_balance * 0.08f, -0.5f, 0.5f);
                if (direct_moisture_enabled) {
                    M[i] = clamp01(M[i] + precip * 0.35f
                        + ((daily_balance > 0.0f) ? daily_balance * 0.04f : 0.0f));
                }
                // climate-loop-closure Phase 2.1/2.2：物理雪线 floor（仅陆地）。
                float snow_floor_c = 0.0f;
                if (snowline_temp_threshold > 0.0f) {
                    snow_floor_c = snowline_floor_for_cell(T[i], HEAT[i], EL[i], snowline_temp_threshold, snowline_band_safe);
                    if (snow_floor_c * snowpack_cover_full > sp) sp = snow_floor_c * snowpack_cover_full;
                }
                float u = (sp - snowpack_cover_low) / snowpack_cover_span;
                if (u < 0.0f) u = 0.0f; else if (u > 1.0f) u = 1.0f;
                sc = u * u * (3.0f - 2.0f * u);
                if (snow_floor_c > sc) sc = snow_floor_c;
                if (CV[i] == COVER_GLACIER && sc < 0.80f) sc = 0.80f;
                SP[i] = sp;
                WB[i] = wb;
                SOIL[i] = soil;
                SC[i] = sc;
            }
            continue;
        }

        const float td_v = (wt >= 0 && wt < 8) ? TD[wt] : 0.0f;
        const float md_v = (wt >= 0 && wt < 8) ? MD[wt] : 0.0f;
        const float moist_now = direct_moisture_enabled
            ? clamp01(M[i] + md_v * intensity + precip * 0.35f)
            : M[i];
        float temp_delta = td_v * intensity;
        if (temp_delta > weather_temp_anomaly_cap) temp_delta = weather_temp_anomaly_cap;
        else if (temp_delta < -weather_temp_anomaly_cap) temp_delta = -weather_temp_anomaly_cap;
        const float temp_now  = clamp01(T[i] + temp_delta);
        M[i] = moist_now;
        T[i] = temp_now;

        float sp_now = SP[i];
        const float prev_sp = sp_now;
        float wb_now = WB[i];
        float soil_now = SOIL[i];
        const bool water_lf_weather = is_water_lf(LF[i]) || is_water_terrain(TERR[i]);
        if (water_lf_weather) {
            sp_now = 0.0f;
            wb_now = wb_now + (0.0f - wb_now) * (1.0f / 30.0f);
        } else {
            const float elev_delta_sp = EL[i] - 0.30f;
            float freeze_off_sp = elev_delta_sp * 0.20f;
            if (freeze_off_sp > 0.06f) freeze_off_sp = 0.06f;
            else if (freeze_off_sp < -0.06f) freeze_off_sp = -0.06f;
            float melt_off_sp = elev_delta_sp * 0.30f;
            if (melt_off_sp > 0.10f) melt_off_sp = 0.10f;
            else if (melt_off_sp < -0.10f) melt_off_sp = -0.10f;
            const float freeze_t_sp = snow_freeze_t + freeze_off_sp;
            const float melt_t_sp = snow_melt_t + melt_off_sp;
            const bool can_snow_sp = (wt >= 0 && wt < 8) && (CFS[wt] != 0);
            const bool precip_can_snow_sp = (wt != wt_clear) && (wt != 4) && (wt != 6);
            const bool snowing_sp = (can_snow_sp || precip_can_snow_sp) && (temp_now < freeze_t_sp) && (precip > 0.0f);
            float snow_accum = snowing_sp ? (precip * snowpack_accum_gain + intensity * 0.015f) : 0.0f;
            const float warm_rain_melt = (temp_now > melt_t_sp) ? precip * 0.03f : 0.0f;
            const float melt = ((temp_now - melt_t_sp) > 0.0f ? (temp_now - melt_t_sp) : 0.0f) * snowpack_melt_temp_gain
                + HEAT[i] * snowpack_melt_sun_gain
                + snow_summer_melt_bonus(HEAT[i], EL[i])
                + warm_rain_melt;
            sp_now = clampf(sp_now + snow_accum - melt, 0.0f, 1.0f);
            if (CV[i] == COVER_GLACIER && sp_now < 0.80f) sp_now = 0.80f;
            const float meltwater = (prev_sp - sp_now) > 0.0f ? (prev_sp - sp_now) : 0.0f;
            const float runoff = ((moist_now - 0.82f) > 0.0f ? (moist_now - 0.82f) : 0.0f) * 0.25f
                + ((EL[i] - 0.70f) > 0.0f ? (EL[i] - 0.70f) : 0.0f) * precip * 0.06f;
            const float evap_proxy = clampf((0.01f + ((moist_now - 0.45f) > 0.0f ? (moist_now - 0.45f) : 0.0f) * 0.03f)
                * (0.35f + temp_now * 1.05f) * 0.65f, 0.0f, 1.0f);
            const float daily_balance = clampf(precip * 1.15f + meltwater * 0.65f - evap_proxy - runoff, -1.0f, 1.0f);
            wb_now = wb_now + (daily_balance - wb_now) * (1.0f / 30.0f);
            // climate-loop-closure Phase 3.1：土壤水每日衰减(×0.97)，停雨后排干。
            soil_now = clampf(soil_now * 0.97f + daily_balance * 0.08f, -0.5f, 0.5f);
        }
        // climate-loop-closure Phase 2.1/2.2：物理雪线 floor（仅陆地）。
        float snow_floor_w = 0.0f;
        if (snowline_temp_threshold > 0.0f && !water_lf_weather) {
            snow_floor_w = snowline_floor_for_cell(temp_now, HEAT[i], EL[i], snowline_temp_threshold, snowline_band_safe);
            if (snow_floor_w * snowpack_cover_full > sp_now) sp_now = snow_floor_w * snowpack_cover_full;
        }
        float u_sp = (sp_now - snowpack_cover_low) / snowpack_cover_span;
        if (u_sp < 0.0f) u_sp = 0.0f; else if (u_sp > 1.0f) u_sp = 1.0f;
        float snow_cover_now = u_sp * u_sp * (3.0f - 2.0f * u_sp);
        if (snow_floor_w > snow_cover_now) snow_cover_now = snow_floor_w;
        if (CV[i] == COVER_GLACIER && snow_cover_now < 0.80f) snow_cover_now = 0.80f;
        SP[i] = sp_now;
        SC[i] = snow_cover_now;
        WB[i] = wb_now;
        SOIL[i] = soil_now;

        if (!water_lf_weather) {
            // 雪：累积式 _apply_snow_accumulation(cell, wt, temp_now, intensity)
            // 2026-05-18 雪线修正：freeze_t / melt_t 随 elev 偏移（与 GDScript SAME_SOURCE）。
            //   neutral=0.30；freeze_gain=0.20，max_off=±0.06；melt_gain=0.30，max_off=±0.10。
            const float elev_delta_m = EL[i] - 0.30f;
            float freeze_off_m = elev_delta_m * 0.20f;
            if (freeze_off_m >  0.06f) freeze_off_m =  0.06f;
            else if (freeze_off_m < -0.06f) freeze_off_m = -0.06f;
            float melt_off_m = elev_delta_m * 0.30f;
            if (melt_off_m >  0.10f) melt_off_m =  0.10f;
            else if (melt_off_m < -0.10f) melt_off_m = -0.10f;
            const float freeze_t_local = snow_freeze_t + freeze_off_m;
            const float melt_t_local   = snow_melt_t   + melt_off_m;
            const bool can_snow = (wt >= 0 && wt < 8) && (CFS[wt] != 0);
            const bool snowing  = can_snow && (temp_now < freeze_t_local) && (intensity > snow_intensity_snow);
            if (snowing) {
                ACC[i] += 1;
            } else if (temp_now > melt_t_local) {
                int new_acc = ACC[i] - 1;
                if (new_acc < 0) new_acc = 0;
                ACC[i] = new_acc;
            }
            if (ACC[i] >= snow_accum_days_req && CV[i] != cv_snow && CV[i] != COVER_GLACIER) {
                PRE[i] = int(CV[i]);
                CV[i] = uint8_t(cv_snow);
                changed_cells.push_back(i);
                cover_dirty = true;
            } else if (ACC[i] <= 0 && CV[i] == cv_snow) {
                int restored = (PRE[i] >= 0) ? PRE[i] : cv_none;
                CV[i] = uint8_t(restored);
                PRE[i] = -1;
                changed_cells.push_back(i);
                cover_dirty = true;
            }

            // 洪涝
            const bool can_flood = (wt >= 0 && wt < 8) && (CFF[wt] != 0);
            if (CV[i] != cv_snow && can_flood) {
                const bool heavy_flood   = (intensity > flood_heavy_int) && (precip > flood_heavy_pre);
                const bool lowland_flood = (intensity > flood_low_int) && (EL[i] < flood_low_elev) && (moist_now > flood_low_moist);
                if ((heavy_flood || lowland_flood) && CV[i] != cv_flooding) {
                    CV[i] = uint8_t(cv_flooding);
                    changed_cells.push_back(i);
                    cover_dirty = true;
                }
            }
            // Stage8 退水(不受 can_flood 门限制→DROUGHT/CLEAR 也能退)：修"洪泛与旱灾共存"。镜像 weather_system.gd。
            if (CV[i] == cv_flooding && moist_now < 0.50f && precip < 0.04f) {
                CV[i] = uint8_t(cv_none);
                changed_cells.push_back(i);
                cover_dirty = true;
            }
        }
    }

    emit.cover_dirty = cover_dirty;
}

// stage 12 RUNTIME_HYDROLOGY。计算体从 DCWorldExt::run_runtime_hydrology_pass
// 原样搬来：Dictionary 取值、slot 解引用、flush 与报告留在 Godot 侧的 wrapper 里，
// 这里一行算术都没改。派生系数在这里算，不在调用方算。
void hydrology_pass_pure(const HydrologyKnobs &k,
                         const HydrologyLanes &lanes,
                         HydrologyCanalState &canal,
                         HydrologyScratch &scratch,
                         HydrologyStats &stats) {
    const int n_cells = k.n_cells;
    if (n_cells <= 0) return;
    // 必需 lane 缺一条就整段不跑：半跑会把 store 写成前后不一致的状态，而那比
    // "这天没跑水文"难诊断得多。
    if (lanes.hydro_parent == nullptr || lanes.has_river == nullptr ||
        lanes.terrain == nullptr || lanes.landform == nullptr ||
        lanes.vegetation == nullptr || lanes.cover == nullptr ||
        lanes.elevation == nullptr || lanes.precip == nullptr ||
        lanes.intensity == nullptr || lanes.weather_type == nullptr ||
        lanes.temp == nullptr || lanes.heat == nullptr ||
        lanes.snowpack == nullptr || lanes.base_moisture == nullptr ||
        lanes.is_water == nullptr || lanes.vitality == nullptr ||
        lanes.canal_mask == nullptr || lanes.moisture == nullptr ||
        lanes.soil_moisture == nullptr || lanes.water_balance_30d == nullptr ||
        lanes.plant_water == nullptr || lanes.discharge == nullptr ||
        lanes.discharge_30d == nullptr || lanes.river_storage == nullptr ||
        lanes.groundwater == nullptr || lanes.runoff == nullptr ||
        lanes.canal_water == nullptr) {
        return;
    }

    const float precip_scale = k.precip_scale;
    const float snowmelt_scale = k.snowmelt_scale;
    const float soil_capacity = k.soil_capacity;
    const float infiltration_rate = k.infiltration_rate;
    const float quickflow_fraction = k.quickflow_fraction;
    const float baseflow_recession = k.baseflow_recession;
    const float channel_release = k.channel_release;
    const float lake_release = k.lake_release;
    const float discharge_ema = k.discharge_ema;
    const float bank_moisture_gain = k.bank_moisture_gain;
    const float river_moisture_floor = k.river_moisture_floor;
    const float riparian_moisture_floor = k.riparian_moisture_floor;
    const float river_evap_gain = k.river_evap_gain;
    const float moisture_response_rate = k.moisture_response_rate;
    const float flood_threshold = k.flood_threshold;
    const float snowpack_melt_temp_gain = k.snowpack_melt_temp_gain;
    const float snowpack_melt_sun_gain = k.snowpack_melt_sun_gain;
    const float plant_water_balance_weight = k.plant_water_balance_weight;
    const float plant_soil_buffer_weight = k.plant_soil_buffer_weight;
    const float plant_drought_penalty = k.plant_drought_penalty;
    const float dt_days = k.dt_days;
    const float baseflow_recession_eff = 1.0f - std::pow(1.0f - baseflow_recession, dt_days);
    const float discharge_ema_eff = 1.0f - std::pow(1.0f - discharge_ema, dt_days);
    const float nonriver_discharge_decay = std::pow(1.0f - discharge_ema * 0.5f, dt_days);
    const float soil_decay_eff = std::pow(0.985f, dt_days);
    const float water_balance_ema_eff = 1.0f - std::pow(1.0f - (1.0f / 30.0f), dt_days);
    const float moisture_response_alpha = 1.0f - std::pow(1.0f - moisture_response_rate, dt_days);

    const int32_t * const __restrict NB = lanes.neighbor_indices;
    const bool has_neighbor_indices = NB != nullptr;
    const int32_t * const __restrict HP = lanes.hydro_parent;
    const uint8_t * const __restrict HAS_RIV = lanes.has_river;
    const uint8_t * const __restrict TERR = lanes.terrain;
    const uint8_t * const __restrict LF = lanes.landform;
    const uint8_t * const __restrict VEG = lanes.vegetation;
    const uint8_t * const __restrict COV = lanes.cover;
    const float * const __restrict ELEV = lanes.elevation;
    const float * const __restrict PREC = lanes.precip;
    const float * const __restrict INTEN = lanes.intensity;
    const uint8_t * const __restrict WTYPE = lanes.weather_type;
    const float * const __restrict TEMP = lanes.temp;
    const float * const __restrict HEAT = lanes.heat;
    const float * const __restrict SNOWP = lanes.snowpack;
    float * const __restrict MOIST = lanes.moisture;
    const float * const __restrict BASE_M = lanes.base_moisture;
    float * const __restrict SOIL = lanes.soil_moisture;
    float * const __restrict WB30 = lanes.water_balance_30d;
    float * const __restrict PLANT_WATER = lanes.plant_water;
    const uint8_t * const __restrict IS_WATER = lanes.is_water;
    const float * const __restrict VITAL = lanes.vitality;
    float * const __restrict Q = lanes.discharge;
    float * const __restrict Q30 = lanes.discharge_30d;
    float * const __restrict STORAGE = lanes.river_storage;
    float * const __restrict GW = lanes.groundwater;
    float * const __restrict RUNOFF = lanes.runoff;
    const uint8_t * const __restrict CANAL_MASK = lanes.canal_mask;
    float * const __restrict CANAL_WATER = lanes.canal_water;

    // scratch 是复用缓冲，所以每天必须显式重置成原来的初值 —— assign 而不是
    // resize，否则昨天的 incoming 会当成今天的产流加进汇流里。
    scratch.child_count.assign(size_t(n_cells), 0);
    scratch.incoming.assign(size_t(n_cells), 0.0f);
    scratch.moisture_target.assign(size_t(n_cells), -1.0f);
    scratch.queue.clear();
    scratch.queue.reserve(size_t(n_cells));
    std::vector<int32_t> &child_count = scratch.child_count;
    std::vector<float> &incoming = scratch.incoming;
    std::vector<float> &moisture_target = scratch.moisture_target;
    std::vector<int32_t> &queue = scratch.queue;

    double water_in_total = 0.0;
    double outlet_total = 0.0;
    int runoff_source_cells = 0;
    int river_cells_processed = 0;
    int riparian_neighbor_touches = 0;
    int river_moisture_floor_touches = 0;
    int riparian_moisture_floor_touches = 0;
    float river_moisture_max_delta = 0.0f;
    float riparian_moisture_max_delta = 0.0f;
    int flood_candidate_count = 0;
    int canal_cells_processed = 0;
    int canal_edges_processed = 0;
    int canal_freshwater_cells = 0;
    int canal_saline_cells = 0;

    for (int i = 0; i < n_cells; ++i) {
        const int32_t p = HP[i];
        if (p >= 0 && p < n_cells && p != i) child_count[size_t(p)] += 1;
    }

    for (int i = 0; i < n_cells; ++i) {
        const bool is_water = wf_is_water_terrain(TERR[i]) || LF[i] <= 3;
        const uint8_t wt = WTYPE[i];
        const float hydro_precip = wf_is_precip_weather_type(wt) ? PREC[i] : 0.0f;
        const float wet_event = ((wt == 2 || wt == 3 || wt == 7) ? 0.12f : 0.0f) * INTEN[i];
        const float precip_daily = std::max(0.0f, hydro_precip + wet_event) * precip_scale;
        const float melt_potential = std::max(0.0f, TEMP[i] - 0.24f) * snowpack_melt_temp_gain
            + std::max(0.0f, HEAT[i]) * snowpack_melt_sun_gain;
        const float snowmelt = std::min(std::max(0.0f, SNOWP[i]), melt_potential * dt_days) * snowmelt_scale;
        const float water_in = precip_daily * dt_days + snowmelt;
        water_in_total += double(water_in);

        const float wetness = dc_clampf((SOIL[i] + 0.5f) * 0.55f + BASE_M[i] * 0.25f + MOIST[i] * 0.20f, 0.0f, 1.0f);
        const float veg_absorb = (VEG[i] == 0 ? 0.0f : dc_clampf(VITAL[i], 0.0f, 1.0f)) * 0.14f;
        const float cover_runoff = (COV[i] == 1 || COV[i] == 2) ? 0.18f : ((COV[i] == 3) ? 0.10f : 0.0f);
        const float relief_runoff = dc_clampf((ELEV[i] - 0.55f) * 0.20f, 0.0f, 0.16f);
        const float saturation = dc_clampf((wetness - soil_capacity) / std::max(0.001f, 1.0f - soil_capacity), 0.0f, 1.0f);
        float runoff_coeff = quickflow_fraction + wetness * 0.32f + saturation * 0.35f + cover_runoff + relief_runoff - veg_absorb;
        runoff_coeff = is_water ? 1.0f : dc_clampf(runoff_coeff, 0.04f, 0.96f);
        const float quick_runoff = water_in * runoff_coeff;
        const float infiltration = is_water ? 0.0f : water_in * (1.0f - runoff_coeff) * infiltration_rate;

        GW[i] = std::max(0.0f, GW[i] + infiltration * 0.55f);
        const float baseflow = GW[i] * baseflow_recession_eff;
        GW[i] = std::max(0.0f, GW[i] - baseflow);
        const float local_runoff = quick_runoff + baseflow;
        RUNOFF[i] = local_runoff;
        incoming[size_t(i)] += local_runoff;
        if (local_runoff > 0.0001f) ++runoff_source_cells;

        const float daily_balance = dc_clampf(
            (water_in - quick_runoff - infiltration * 0.35f) / dt_days, -1.0f, 1.0f);
        SOIL[i] = dc_clampf(SOIL[i] * soil_decay_eff + infiltration * 0.16f - quick_runoff * 0.025f, -0.5f, 0.5f);
        WB30[i] = WB30[i] + (daily_balance - WB30[i]) * water_balance_ema_eff;

        if (child_count[size_t(i)] == 0) queue.push_back(i);
    }

    for (size_t qh = 0; qh < queue.size(); ++qh) {
        const int i = queue[qh];
        const bool is_channel = HAS_RIV[i] != 0 || wf_is_water_terrain(TERR[i]) || LF[i] <= 3;
        const bool is_lake = wf_is_water_terrain(TERR[i]) && TERR[i] != 0;
        float outflow = incoming[size_t(i)];
        if (is_channel) {
            const float release_daily = is_lake ? lake_release : channel_release;
            const float release = 1.0f - std::pow(1.0f - release_daily, dt_days);
            STORAGE[i] = std::max(0.0f, STORAGE[i] + incoming[size_t(i)]);
            outflow = STORAGE[i] * release;
            STORAGE[i] = std::max(0.0f, STORAGE[i] - outflow);
            ++river_cells_processed;
        } else {
            STORAGE[i] = 0.0f;
        }
        Q[i] = (HAS_RIV[i] != 0 || wf_is_water_terrain(TERR[i])) ? outflow : 0.0f;
        const int32_t p = HP[i];
        if (p >= 0 && p < n_cells && p != i) {
            incoming[size_t(p)] += outflow;
            child_count[size_t(p)] -= 1;
            if (child_count[size_t(p)] == 0) queue.push_back(p);
        } else {
            outlet_total += double(outflow);
        }
    }

    for (int i = 0; i < n_cells; ++i) {
        if (child_count[size_t(i)] <= 0) continue;
        const int32_t p = HP[i];
        if (p >= 0 && p < n_cells && p != i) incoming[size_t(p)] += incoming[size_t(i)];
        else outlet_total += double(incoming[size_t(i)]);
    }

    float q_max = 0.0f;
    std::vector<float> river_q;
    river_q.reserve(size_t(n_cells));
    for (int i = 0; i < n_cells; ++i) {
        if (HAS_RIV[i] == 0 && !wf_is_water_terrain(TERR[i])) {
            Q[i] = 0.0f;
            Q30[i] = std::max(0.0f, Q30[i] * nonriver_discharge_decay);
            continue;
        }
        q_max = std::max(q_max, Q[i]);
        river_q.push_back(Q[i]);
    }
    const float denom = std::log1p(std::max(q_max, 0.001f));
    for (int i = 0; i < n_cells; ++i) {
        if (HAS_RIV[i] == 0 && !wf_is_water_terrain(TERR[i])) continue;
        const float q_norm = dc_clampf(std::log1p(std::max(0.0f, Q[i])) / denom, 0.0f, 1.0f);
        Q30[i] = dc_clampf(Q30[i] + (q_norm - Q30[i]) * discharge_ema_eff, 0.0f, 1.0f);
        if (HAS_RIV[i] != 0 && Q30[i] > flood_threshold) ++flood_candidate_count;
        if (HAS_RIV[i] != 0) {
            const float bank_gain = Q30[i] * bank_moisture_gain;
            const float moisture_floor = dc_clampf(
                river_moisture_floor + Q30[i] * river_evap_gain * 0.5f, 0.0f, 1.0f);
            moisture_target[size_t(i)] = std::max(moisture_target[size_t(i)], moisture_floor);
            SOIL[i] = dc_clampf(SOIL[i] + bank_gain, -0.5f, 0.5f);
            WB30[i] = dc_clampf(WB30[i] + bank_gain * 0.5f, -1.0f, 1.0f);
            if (NB != nullptr && bank_gain > 0.0f) {
                const float neighbor_gain = bank_gain * 0.45f;
                const int nb_base = i * 6;
                for (int d = 0; d < 6; ++d) {
                    const int ni = NB[nb_base + d];
                    if (ni < 0 || ni >= n_cells || ni == i) continue;
                    const bool nb_is_water = wf_is_water_terrain(TERR[ni]) || LF[ni] <= 3;
                    if (nb_is_water || HAS_RIV[ni] != 0) continue;
                    const float neighbor_floor = dc_clampf(
                        riparian_moisture_floor + Q30[i] * river_evap_gain * 0.25f, 0.0f, 1.0f);
                    moisture_target[size_t(ni)] = std::max(moisture_target[size_t(ni)], neighbor_floor);
                    SOIL[ni] = dc_clampf(SOIL[ni] + neighbor_gain, -0.5f, 0.5f);
                    WB30[ni] = dc_clampf(WB30[ni] + neighbor_gain * 0.5f, -1.0f, 1.0f);
                    ++riparian_neighbor_touches;
                }
            }
        }
    }

    // Sparse artificial-water phase. It is deliberately downstream of the
    // natural drainage DAG: HP/incoming/Q/STORAGE are read-only here, so canals
    // neither divert natural rivers nor create/destroy discharge.
    if (has_neighbor_indices) {
        if (canal.compiled_generation != canal.topology_generation ||
            canal.compiled_cell_count != n_cells) {
            // Clear water left by cells removed from the topology, then do the
            // only full-map canal scan. Normal daily passes below touch only
            // the compiled canal cells and their immediate neighbors.
            for (const int32_t cell : canal.cells) {
                if (cell >= 0 && cell < n_cells) CANAL_WATER[cell] = 0.0f;
            }
            canal.cells.clear();
            canal.cells.reserve(256);
            for (int32_t cell = 0; cell < n_cells; ++cell) {
                if ((CANAL_MASK[cell] & 0x3fU) != 0)
                    canal.cells.push_back(cell);
            }
            canal.source_kind.assign(size_t(n_cells), 0);
            canal.strength.assign(size_t(n_cells), 0.0f);
            canal.compiled_generation = canal.topology_generation;
            canal.compiled_cell_count = n_cells;
        }
        std::vector<uint8_t> &source_kind = canal.source_kind;
        std::vector<float> &strength = canal.strength;
        using CanalNode = std::pair<float, int32_t>;
        std::priority_queue<CanalNode> propagation;
        for (const int32_t cell : canal.cells) {
            CANAL_WATER[cell] = 0.0f;
            source_kind[size_t(cell)] = 0;
            strength[size_t(cell)] = 0.0f;
            uint8_t source = HAS_RIV[cell] != 0 || TERR[cell] == 18 ? 2 : 0;
            for (int direction = 0; direction < 6; ++direction) {
                const int32_t neighbor = NB[cell * 6 + direction];
                if (neighbor < 0 || neighbor >= n_cells) continue;
                if (HAS_RIV[neighbor] != 0 || TERR[neighbor] == 18) source = 2;
                else if (source == 0 && (TERR[neighbor] == 0 || TERR[neighbor] == 1 ||
                         TERR[neighbor] == 19 || TERR[neighbor] == 20 ||
                         TERR[neighbor] == 21)) source = 1;
            }
            if (source != 0) {
                source_kind[size_t(cell)] = source;
                strength[size_t(cell)] = 1.0f;
                propagation.push({1.0f, cell});
            }
        }
        while (!propagation.empty()) {
            const auto [current_strength, cell] = propagation.top();
            propagation.pop();
            if (current_strength + 0.000001f < strength[size_t(cell)]) continue;
            for (int direction = 0; direction < 6; ++direction) {
                if ((CANAL_MASK[cell] & (1U << direction)) == 0) continue;
                const int32_t neighbor = NB[cell * 6 + direction];
                if (neighbor < 0 || neighbor >= n_cells ||
                    (CANAL_MASK[neighbor] & (1U << ((direction + 3) % 6))) == 0)
                    continue;
                ++canal_edges_processed;
                const float next_strength = current_strength * 0.96f;
                // Freshwater wins deterministic ties over saline.
                if (next_strength > strength[size_t(neighbor)] + 0.000001f ||
                    (std::abs(next_strength - strength[size_t(neighbor)]) <= 0.000001f &&
                     source_kind[size_t(cell)] > source_kind[size_t(neighbor)])) {
                    strength[size_t(neighbor)] = next_strength;
                    source_kind[size_t(neighbor)] = source_kind[size_t(cell)];
                    propagation.push({next_strength, neighbor});
                }
            }
        }
        canal_edges_processed /= 2;
        for (const int32_t cell : canal.cells) {
            const float available = dc_clampf(strength[size_t(cell)], 0.0f, 1.0f);
            CANAL_WATER[cell] = available;
            ++canal_cells_processed;
            if (source_kind[size_t(cell)] == 2) {
                ++canal_freshwater_cells;
                const float own_target = dc_clampf(
                    river_moisture_floor * 0.60f * available, 0.0f, 1.0f);
                moisture_target[size_t(cell)] = std::max(
                    moisture_target[size_t(cell)], own_target);
                const float soil_target = dc_clampf(available * 0.30f, -0.5f, 0.5f);
                SOIL[cell] += (soil_target - SOIL[cell]) * moisture_response_alpha * 0.60f;
                WB30[cell] += (available * 0.35f - WB30[cell]) *
                    water_balance_ema_eff * 0.60f;
                for (int direction = 0; direction < 6; ++direction) {
                    const int32_t neighbor = NB[cell * 6 + direction];
                    if (neighbor < 0 || neighbor >= n_cells || IS_WATER[neighbor] != 0)
                        continue;
                    const float neighbor_target = dc_clampf(
                        riparian_moisture_floor * 0.50f * available, 0.0f, 1.0f);
                    moisture_target[size_t(neighbor)] = std::max(
                        moisture_target[size_t(neighbor)], neighbor_target);
                    SOIL[neighbor] += (available * 0.18f - SOIL[neighbor]) *
                        moisture_response_alpha * 0.50f;
                    WB30[neighbor] += (available * 0.20f - WB30[neighbor]) *
                        water_balance_ema_eff * 0.50f;
                }
            } else if (source_kind[size_t(cell)] == 1) {
                ++canal_saline_cells;
                const float saline_target = dc_clampf(MOIST[cell] +
                    river_evap_gain * 0.20f * available, 0.0f, 1.0f);
                moisture_target[size_t(cell)] = std::max(
                    moisture_target[size_t(cell)], saline_target);
            }
        }
    } else {
        for (const int32_t cell : canal.cells) {
            if (cell >= 0 && cell < n_cells) CANAL_WATER[cell] = 0.0f;
        }
        canal.cells.clear();
        canal.source_kind.clear();
        canal.strength.clear();
        canal.compiled_generation = std::numeric_limits<uint64_t>::max();
        canal.compiled_cell_count = -1;
    }

    // Aggregate all river/canal influences first, then approach the strongest target once per cell.
    // This prevents multi-river neighbors from receiving several response steps in one pass.
    if (moisture_response_alpha > 0.0f) {
        for (int i = 0; i < n_cells; ++i) {
            const float target = moisture_target[size_t(i)];
            if (target < 0.0f || MOIST[i] >= target) continue;
            const float before = MOIST[i];
            MOIST[i] = dc_clampf(before + (target - before) * moisture_response_alpha, 0.0f, 1.0f);
            const float delta = MOIST[i] - before;
            if (HAS_RIV[i] != 0) {
                ++river_moisture_floor_touches;
                river_moisture_max_delta = std::max(river_moisture_max_delta, delta);
            } else {
                ++riparian_moisture_floor_touches;
                riparian_moisture_max_delta = std::max(riparian_moisture_max_delta, delta);
            }
        }
    }

    for (int i = 0; i < n_cells; ++i) {
        PLANT_WATER[i] = IS_WATER[i] != 0 ? 0.0f : pk_plant_available_water(
            MOIST[i], WB30[i], SOIL[i], plant_water_balance_weight,
            plant_soil_buffer_weight, plant_drought_penalty);
    }
    std::sort(river_q.begin(), river_q.end());
    const float q_p95 = river_q.empty() ? 0.0f : river_q[size_t(std::min<int>(int(river_q.size()) - 1, int(std::floor(double(river_q.size() - 1) * 0.95))))];

    stats.water_in_total = water_in_total;
    stats.outlet_total = outlet_total;
    stats.runoff_source_cells = runoff_source_cells;
    stats.river_cells_processed = river_cells_processed;
    stats.riparian_neighbor_touches = riparian_neighbor_touches;
    stats.river_moisture_floor_touches = river_moisture_floor_touches;
    stats.riparian_moisture_floor_touches = riparian_moisture_floor_touches;
    stats.river_moisture_max_delta = river_moisture_max_delta;
    stats.riparian_moisture_max_delta = riparian_moisture_max_delta;
    stats.flood_candidate_count = flood_candidate_count;
    stats.canal_cells_processed = canal_cells_processed;
    stats.canal_edges_processed = canal_edges_processed;
    stats.canal_freshwater_cells = canal_freshwater_cells;
    stats.canal_saline_cells = canal_saline_cells;
    stats.q_max = q_max;
    stats.q_p95 = q_p95;
}

// 邻域几何缓存：self->nb 的 wrapped delta 与 1/sqrt(dl2)。原来内联在 solve pass 里，
// 与主循环的 wf_wrapped_delta / sqrt 同序同式，所以缓存命中与否 bit-equal。
void weather_field_geometry_cache_pure(int n_cells,
                                       const int32_t *neighbor_indices,
                                       const float *pos_x,
                                       const float *pos_y,
                                       float wrap_width_x,
                                       float *geom_dx,
                                       float *geom_dy,
                                       float *geom_invd) {
    if (n_cells <= 0 || neighbor_indices == nullptr || pos_x == nullptr ||
        pos_y == nullptr || geom_dx == nullptr || geom_dy == nullptr ||
        geom_invd == nullptr) {
        return;
    }
    for (int p = 0; p < n_cells; ++p) {
        const int b = p * 6;
        const float sx = pos_x[p];
        const float sy = pos_y[p];
        for (int d = 0; d < 6; ++d) {
            const int32_t nb_idx = neighbor_indices[b + d];
            if (nb_idx < 0) {
                geom_dx[b + d] = 0.0f;
                geom_dy[b + d] = 0.0f;
                geom_invd[b + d] = 0.0f;
                continue;
            }
            float dx = 0.0f, dy = 0.0f;
            wf_wrapped_delta(sx, sy, pos_x[nb_idx], pos_y[nb_idx],
                             wrap_width_x, dx, dy);
            geom_dx[b + d] = dx;
            geom_dy[b + d] = dy;
            const float dl2 = dx * dx + dy * dy;
            geom_invd[b + d] = (dl2 > 0.0001f) ? (1.0f / std::sqrt(dl2)) : 0.0f;
        }
    }
}

// ─── B8-2：tropical cyclone 推进 + stamp（生产/worker 共用）─────────────────
//
// 这份实现逐行来自 DCWorldExt::_advance_and_stamp_cyclones，只做两类等价改写：
//   1. godot::Vector2 → 标量对（steering_x/y、vec_x/y、vec_init_x/y、pos_x/pos_y）；
//   2. knobs Dictionary → CycloneAdvanceKnobs POD；条目表指向调用方的 vector。
// 没有改动任何公式、阈值、顺序或迭代步数 —— 任何"顺手优化"都会让它不再可对拍。
namespace {

void cyc_append_u32(std::vector<uint8_t> &out, uint32_t value) {
    out.push_back(static_cast<uint8_t>(value & 0xFFu));
    out.push_back(static_cast<uint8_t>((value >> 8u) & 0xFFu));
    out.push_back(static_cast<uint8_t>((value >> 16u) & 0xFFu));
    out.push_back(static_cast<uint8_t>((value >> 24u) & 0xFFu));
}

void cyc_append_u64(std::vector<uint8_t> &out, uint64_t value) {
    for (int i = 0; i < 8; ++i) {
        out.push_back(static_cast<uint8_t>((value >> (8u * i)) & 0xFFu));
    }
}

void cyc_append_f32(std::vector<uint8_t> &out, float value) {
    uint32_t bits = 0;
    std::memcpy(&bits, &value, sizeof(bits));
    cyc_append_u32(out, bits);
}

bool cyc_read_u32(const std::vector<uint8_t> &in, size_t &cursor, uint32_t &out) {
    if (cursor + 4u > in.size()) return false;
    out = static_cast<uint32_t>(in[cursor]) |
          (static_cast<uint32_t>(in[cursor + 1u]) << 8u) |
          (static_cast<uint32_t>(in[cursor + 2u]) << 16u) |
          (static_cast<uint32_t>(in[cursor + 3u]) << 24u);
    cursor += 4u;
    return true;
}

bool cyc_read_u64(const std::vector<uint8_t> &in, size_t &cursor, uint64_t &out) {
    if (cursor + 8u > in.size()) return false;
    out = 0;
    for (int i = 0; i < 8; ++i) {
        out |= static_cast<uint64_t>(in[cursor + static_cast<size_t>(i)]) << (8u * i);
    }
    cursor += 8u;
    return true;
}

bool cyc_read_f32(const std::vector<uint8_t> &in, size_t &cursor, float &out) {
    uint32_t bits = 0;
    if (!cyc_read_u32(in, cursor, bits)) return false;
    std::memcpy(&out, &bits, sizeof(out));
    return true;
}

void cyc_normalize(float &x, float &y) {
    const float len2 = x * x + y * y;
    if (len2 <= 1e-12f) {
        x = 0.0f;
        y = 0.0f;
        return;
    }
    const float inv = 1.0f / std::sqrt(len2);
    x *= inv;
    y *= inv;
}

} // namespace

void cyclone_genesis_pure(int n_cells,
                          const CycloneGenesisKnobs &knobs,
                          const CycloneGenesisLanes &lanes,
                          std::vector<CycloneEntry> &entries,
                          uint64_t &next_stable_id,
                          CycloneGenesisStats &stats) {
    stats = CycloneGenesisStats{};
    stats.alive = static_cast<int32_t>(entries.size());
    if (!knobs.enabled || n_cells <= 0 || knobs.storm_type_id < 0) return;
    if (lanes.terrain == nullptr || lanes.water_lut == nullptr ||
        lanes.weather_type == nullptr || lanes.weather_intensity == nullptr ||
        lanes.temp == nullptr || lanes.precip == nullptr ||
        lanes.cloud == nullptr || lanes.instability == nullptr ||
        lanes.convergence == nullptr || lanes.wind_x == nullptr ||
        lanes.wind_y == nullptr || lanes.pos_y == nullptr ||
        lanes.neighbors == nullptr) {
        return;
    }
    const float wb_h = std::max(0.001f, knobs.world_bounds_size_y);
    const uint8_t storm_id = static_cast<uint8_t>(knobs.storm_type_id);
    for (int i = 0; i < n_cells; ++i) {
        const bool on_water = lanes.water_lut[lanes.terrain[i]] != 0u;
        if (!on_water) continue;
        if (lanes.is_water != nullptr && lanes.is_water[i] == 0u) continue;
        ++stats.cand_water;
        if (lanes.weather_intensity[i] > stats.max_intensity) {
            stats.max_intensity = lanes.weather_intensity[i];
        }
        const float ny = dc_clampf(
            (lanes.pos_y[i] - knobs.world_bounds_pos_y) / wb_h, 0.0f, 1.0f);
        const float abs_lat = (lanes.lat_norm != nullptr)
            ? std::abs((dc_clampf(lanes.lat_norm[i], 0.0f, 1.0f) - 0.5f) * 2.0f)
            : std::abs((ny - 0.5f) * 2.0f);
        if (abs_lat < knobs.min_lat || abs_lat > knobs.max_lat) continue;
        ++stats.cand_lat;
        if (lanes.weather_type[i] == storm_id) ++stats.type_storm;
        stats.max_precip = std::max(stats.max_precip, lanes.precip[i]);
        stats.max_cloud = std::max(stats.max_cloud, lanes.cloud[i]);
        stats.max_instability = std::max(stats.max_instability, lanes.instability[i]);
        stats.max_convergence = std::max(stats.max_convergence, lanes.convergence[i]);
        if (lanes.temp[i] < knobs.min_temp) { ++stats.fail_temp; continue; }
        if (lanes.precip[i] < knobs.precip_gate) { ++stats.fail_precip; continue; }
        if (lanes.cloud[i] < knobs.cloud_gate) { ++stats.fail_cloud; continue; }
        if (lanes.instability[i] < knobs.min_instability &&
            lanes.convergence[i] < 0.30f) {
            ++stats.fail_instability;
            continue;
        }
        ++stats.cand_physical;
        // 生产 genesis 的"前沿等价物"是 summary 段给出的 WeatherFront：type == STORM
        // 且 intensity ≥ 0.8。worker 里没有 front 对象，直接等价映射到 field solve
        // 写出的 intensity lane（front 的 intensity 本来就是从这个 lane 派生的），
        // 否则 type 只有在已有 cyclone stamp 之后才会变成 STORM —— 新气旋永远
        // 生不出来（闭锁）。require_storm_type 只用于 A/B 复现旧闭锁路径。
        if (knobs.require_storm_type && lanes.weather_type[i] != storm_id) {
            continue;
        }
        if (lanes.weather_intensity[i] < knobs.intensity_gate) continue;
        ++stats.cand_intensity;
        float shear = 0.0f;
        for (int d = 0; d < 6; ++d) {
            const int ni = lanes.neighbors[i * 6 + d];
            if (ni < 0) continue;
            const float dx = lanes.wind_x[ni] - lanes.wind_x[i];
            const float dy = lanes.wind_y[ni] - lanes.wind_y[i];
            shear = std::max(shear, std::sqrt(dx * dx + dy * dy) / 2.0f);
        }
        if (shear > knobs.max_shear) continue;
        ++stats.cand_shear;
        float wind_x = lanes.wind_x[i];
        float wind_y = lanes.wind_y[i];
        if (wind_x * wind_x + wind_y * wind_y < 1e-4f) {
            wind_x = 1.0f;
            wind_y = 0.0f;
        }
        float tangent_x = -wind_y;
        float tangent_y = wind_x;
        cyc_normalize(tangent_x, tangent_y);
        const float perturb_scale = lanes.weather_intensity[i] * 0.6f;
        float steering_x = wind_x;
        float steering_y = wind_y;
        cyc_normalize(steering_x, steering_y);
        bool replaced = false;
        for (CycloneEntry &e : entries) {
            if (e.key != static_cast<int64_t>(i)) continue;
            e.cell_idx = i;
            e.vec_x = tangent_x * perturb_scale;
            e.vec_y = tangent_y * perturb_scale;
            e.vec_init_x = e.vec_x;
            e.vec_init_y = e.vec_y;
            e.steering_x = steering_x;
            e.steering_y = steering_y;
            e.intensity = std::max(e.intensity, lanes.weather_intensity[i]);
            e.radius_cells = 2.0f + lanes.weather_intensity[i] * 3.0f;
            e.days_left = static_cast<int32_t>(knobs.wake_days);
            e.init_days = static_cast<int32_t>(knobs.wake_days);
            replaced = true;
            break;
        }
        if (replaced) {
            ++stats.replaced;
            continue;
        }
        // 出生预算只约束"新条目"：刷新同一条已是气旋的前沿（replaced）不吃预算，
        // 否则 births_per_commit 会在已有条目上被白白耗尽、丢掉当天真实的新气旋。
        if (static_cast<int32_t>(entries.size()) >= knobs.capacity) break;
        if (stats.injected >= knobs.births_per_commit) break;
        CycloneEntry entry;
        entry.stable_id = next_stable_id++;
        entry.key = static_cast<int64_t>(i);
        entry.cell_idx = i;
        entry.steering_x = steering_x;
        entry.steering_y = steering_y;
        entry.vec_x = tangent_x * perturb_scale;
        entry.vec_y = tangent_y * perturb_scale;
        entry.vec_init_x = entry.vec_x;
        entry.vec_init_y = entry.vec_y;
        entry.intensity = lanes.weather_intensity[i];
        entry.radius_cells = 2.0f + lanes.weather_intensity[i] * 3.0f;
        entry.age_days = 0.0f;
        entry.move_progress = 0.0f;
        entry.days_left = static_cast<int32_t>(knobs.wake_days);
        entry.init_days = static_cast<int32_t>(knobs.wake_days);
        entries.push_back(entry);
        ++stats.injected;
    }
    stats.alive = static_cast<int32_t>(entries.size());
}

void cyclone_advance_and_stamp_pure(int n_cells,
                                    const CycloneAdvanceKnobs &knobs,
                                    const CycloneLanes &lanes,
                                    std::vector<CycloneEntry> &entries,
                                    CycloneStamp &stamp,
                                    CycloneStats &stats) {
    stats = CycloneStats{};
    for (const CycloneEntry &e : entries) {
        stats.entry_intensity_max_before =
            std::max(stats.entry_intensity_max_before, e.intensity);
    }
    if (!knobs.enabled || n_cells <= 0) return;
    if (lanes.neighbors == nullptr || lanes.pos_x == nullptr ||
        lanes.pos_y == nullptr || lanes.terrain == nullptr ||
        lanes.temp == nullptr || lanes.wind_x == nullptr ||
        lanes.wind_y == nullptr || lanes.wind_speed == nullptr ||
        lanes.vapor == nullptr || lanes.instability == nullptr ||
        lanes.convergence == nullptr) {
        return;
    }
    if (stamp.force_tag == nullptr || stamp.visit_tag == nullptr ||
        stamp.force_x == nullptr || stamp.force_y == nullptr ||
        stamp.lift == nullptr) {
        return;
    }
    const int32_t * const neighbors = lanes.neighbors;
    const float * const positions_x = lanes.pos_x;
    const float * const positions_y = lanes.pos_y;
    const uint8_t * const terrain = lanes.terrain;
    const float dt_total = dc_clampf(knobs.dt_days, 0.0f, 30.0f);
    const int steps = std::max(1, static_cast<int>(std::ceil(dt_total)));
    const float dt = dt_total / static_cast<float>(steps);
    const float wb_y = knobs.world_bounds_pos_y;
    const float wb_h = std::max(0.001f, knobs.world_bounds_size_y);
    const float wrap_x = std::max(0.0f, knobs.wrap_width_x);
    const int max_radius = std::clamp(knobs.max_radius_cells, 2, 6);

    for (CycloneEntry &e : entries) {
        for (int step = 0; step < steps; ++step) {
            const int i = e.cell_idx;
            if (i < 0 || i >= n_cells) { e.intensity = 0.0f; break; }
            const float ny = dc_clampf((positions_y[i] - wb_y) / wb_h, 0.0f, 1.0f);
            const float signed_lat = (lanes.lat_norm != nullptr)
                ? (dc_clampf(lanes.lat_norm[i], 0.0f, 1.0f) - 0.5f) * 2.0f
                : (ny - 0.5f) * 2.0f;
            float shear = 0.0f;
            for (int d = 0; d < 6; ++d) {
                const int ni = neighbors[i * 6 + d];
                if (ni < 0) continue;
                const float dx = lanes.wind_x[ni] - lanes.wind_x[i];
                const float dy = lanes.wind_y[ni] - lanes.wind_y[i];
                shear = std::max(shear, std::sqrt(dx * dx + dy * dy) / 2.0f);
            }
            const bool on_water = wf_is_water_terrain(terrain[i]);
            const float potential = wf_smoothstep(0.54f, 0.76f, lanes.temp[i]) *
                wf_smoothstep(0.42f, 0.72f, lanes.vapor[i]) *
                (0.35f + 0.65f * std::max(lanes.instability[i], lanes.convergence[i])) *
                (1.0f - dc_clampf(shear, 0.0f, 1.0f)) * (on_water ? 1.0f : 0.15f);
            e.intensity += (potential - e.intensity) * (on_water ? 0.16f : 0.38f) * dt;
            if (lanes.temp[i] < 0.50f) {
                e.intensity -= (0.50f - lanes.temp[i]) * 0.35f * dt;
            }
            e.intensity = dc_clampf(e.intensity, 0.0f, 1.0f);
            e.age_days += dt;
            float guide_x = lanes.wind_x[i] - 0.12f * std::abs(signed_lat);
            float guide_y = lanes.wind_y[i];
            const float guide_len2 = guide_x * guide_x + guide_y * guide_y;
            if (guide_len2 > 1e-5f) {
                cyc_normalize(guide_x, guide_y);
            } else {
                const float steer_len2 = e.steering_x * e.steering_x +
                    e.steering_y * e.steering_y;
                if (steer_len2 > 1e-5f) {
                    cyc_normalize(e.steering_x, e.steering_y);
                    guide_x = e.steering_x;
                    guide_y = e.steering_y;
                } else {
                    guide_x = -1.0f;
                    guide_y = 0.0f;
                }
            }
            e.steering_x = e.steering_x + (guide_x - e.steering_x) * 0.35f;
            e.steering_y = e.steering_y + (guide_y - e.steering_y) * 0.35f;
            cyc_normalize(e.steering_x, e.steering_y);
            e.move_progress += dt *
                (0.25f + dc_clampf(lanes.wind_speed[i], 0.0f, 1.5f) * 0.35f);
            if (e.move_progress >= 1.0f) {
                int best = -1;
                float best_dot = 0.10f;
                for (int d = 0; d < 6; ++d) {
                    const int ni = neighbors[i * 6 + d];
                    if (ni < 0) continue;
                    float dx = positions_x[ni] - positions_x[i];
                    if (wrap_x > 0.0f) dx = pk_wrap_min_image_dx(dx, wrap_x);
                    const float dy = positions_y[ni] - positions_y[i];
                    const float len2 = dx * dx + dy * dy;
                    if (len2 <= 1e-6f) continue;
                    const float dot = (dx * e.steering_x + dy * e.steering_y) /
                        std::sqrt(len2);
                    if (dot > best_dot) {
                        best_dot = dot;
                        best = ni;
                    }
                }
                if (best >= 0) e.cell_idx = best;
                e.move_progress -= 1.0f;
            }
        }
        e.radius_cells = dc_clampf(2.0f + e.intensity *
            static_cast<float>(max_radius - 2), 2.0f,
            static_cast<float>(max_radius));
        e.days_left = std::max(0, static_cast<int>(std::ceil(32.0f - e.age_days)));
        e.init_days = 32;
    }
    const size_t before = entries.size();
    entries.erase(std::remove_if(entries.begin(), entries.end(),
        [](const CycloneEntry &e) {
            return e.intensity < 0.075f || e.age_days > 32.0f;
        }), entries.end());
    stats.decayed = static_cast<int32_t>(before - entries.size());
    stats.alive = static_cast<int32_t>(entries.size());
    for (const CycloneEntry &e : entries) {
        stats.entry_intensity_max_after =
            std::max(stats.entry_intensity_max_after, e.intensity);
    }

    for (const CycloneEntry &e : entries) {
        if (e.cell_idx < 0 || e.cell_idx >= n_cells) continue;
        stamp.visit_generation += 1u;
        if (stamp.visit_generation == 0u) {
            std::fill(stamp.visit_tag, stamp.visit_tag + n_cells, 0u);
            stamp.visit_generation = 1u;
        }
        std::vector<int32_t> queue;
        std::vector<int8_t> distance;
        queue.reserve(256);
        distance.reserve(256);
        queue.push_back(e.cell_idx);
        distance.push_back(0);
        stamp.visit_tag[static_cast<size_t>(e.cell_idx)] = stamp.visit_generation;
        const int radius = std::clamp(static_cast<int>(std::ceil(e.radius_cells)),
                                      2, max_radius);
        for (size_t head = 0; head < queue.size(); ++head) {
            const int i = queue[head];
            const int dist = static_cast<int>(distance[head]);
            const float falloff = 1.0f - static_cast<float>(dist) /
                static_cast<float>(radius + 1);
            if (stamp.force_tag[static_cast<size_t>(i)] != stamp.force_generation) {
                stamp.force_tag[static_cast<size_t>(i)] = stamp.force_generation;
                stamp.force_x[static_cast<size_t>(i)] = 0.0f;
                stamp.force_y[static_cast<size_t>(i)] = 0.0f;
                stamp.lift[static_cast<size_t>(i)] = 0.0f;
                ++stats.touched_cells;
            }
            float dx = positions_x[i] - positions_x[e.cell_idx];
            if (wrap_x > 0.0f) dx = pk_wrap_min_image_dx(dx, wrap_x);
            const float dy = positions_y[i] - positions_y[e.cell_idx];
            float tangent_x = 0.0f;
            float tangent_y = 0.0f;
            if (dx * dx + dy * dy > 1e-6f) {
                const float ny = dc_clampf(
                    (positions_y[e.cell_idx] - wb_y) / wb_h, 0.0f, 1.0f);
                const float hemi = ny < 0.5f ? 1.0f : -1.0f;
                tangent_x = -dy * hemi;
                tangent_y = dx * hemi;
                cyc_normalize(tangent_x, tangent_y);
            } else {
                tangent_x = -e.steering_y;
                tangent_y = e.steering_x;
            }
            const float force = e.intensity * falloff * 0.62f;
            stamp.force_x[static_cast<size_t>(i)] += tangent_x * force;
            stamp.force_y[static_cast<size_t>(i)] += tangent_y * force;
            stamp.lift[static_cast<size_t>(i)] = std::max(
                stamp.lift[static_cast<size_t>(i)], e.intensity * falloff);
            if (dist >= radius) continue;
            for (int d = 0; d < 6; ++d) {
                const int ni = neighbors[i * 6 + d];
                if (ni < 0 || stamp.visit_tag[static_cast<size_t>(ni)] ==
                              stamp.visit_generation) {
                    continue;
                }
                stamp.visit_tag[static_cast<size_t>(ni)] = stamp.visit_generation;
                queue.push_back(ni);
                distance.push_back(static_cast<int8_t>(dist + 1));
            }
        }
    }
    for (CycloneEntry &e : entries) {
        e.vec_x = e.steering_x * e.intensity;
        e.vec_y = e.steering_y * e.intensity;
        e.vec_init_x = e.vec_x;
        e.vec_init_y = e.vec_y;
    }
}

std::vector<uint8_t> cyclone_state_encode(const std::vector<CycloneEntry> &entries,
                                          uint64_t next_stable_id) {
    std::vector<uint8_t> out;
    out.reserve(16u + entries.size() * 68u);
    cyc_append_u32(out, 0x31435943u);  // "CYC1"
    cyc_append_u32(out, 1u);
    cyc_append_u32(out, static_cast<uint32_t>(
        std::min<size_t>(entries.size(), 0xFFFFFFFFu)));
    cyc_append_u64(out, next_stable_id);
    for (const CycloneEntry &e : entries) {
        cyc_append_u64(out, e.stable_id);
        cyc_append_u64(out, static_cast<uint64_t>(e.key));
        cyc_append_u32(out, static_cast<uint32_t>(e.cell_idx));
        cyc_append_f32(out, e.steering_x);
        cyc_append_f32(out, e.steering_y);
        cyc_append_f32(out, e.vec_x);
        cyc_append_f32(out, e.vec_y);
        cyc_append_f32(out, e.vec_init_x);
        cyc_append_f32(out, e.vec_init_y);
        cyc_append_f32(out, e.intensity);
        cyc_append_f32(out, e.radius_cells);
        cyc_append_f32(out, e.age_days);
        cyc_append_f32(out, e.move_progress);
        cyc_append_u32(out, static_cast<uint32_t>(e.days_left));
        cyc_append_u32(out, static_cast<uint32_t>(e.init_days));
    }
    return out;
}

void cyclone_state_decode(const std::vector<uint8_t> &blob,
                          std::vector<CycloneEntry> &entries,
                          uint64_t &next_stable_id) {
    entries.clear();
    next_stable_id = 1;
    size_t cursor = 0;
    uint32_t magic = 0, version = 0, count = 0;
    if (!cyc_read_u32(blob, cursor, magic) || magic != 0x31435943u) return;
    if (!cyc_read_u32(blob, cursor, version) || version != 1u) return;
    if (!cyc_read_u32(blob, cursor, count)) return;
    if (!cyc_read_u64(blob, cursor, next_stable_id)) return;
    entries.reserve(count);
    for (uint32_t k = 0; k < count; ++k) {
        CycloneEntry e;
        uint64_t key_bits = 0;
        uint32_t value32 = 0;
        if (!cyc_read_u64(blob, cursor, e.stable_id)) return;
        if (!cyc_read_u64(blob, cursor, key_bits)) return;
        e.key = static_cast<int64_t>(key_bits);
        if (!cyc_read_u32(blob, cursor, value32)) return;
        e.cell_idx = static_cast<int32_t>(value32);
        if (!cyc_read_f32(blob, cursor, e.steering_x) ||
            !cyc_read_f32(blob, cursor, e.steering_y) ||
            !cyc_read_f32(blob, cursor, e.vec_x) ||
            !cyc_read_f32(blob, cursor, e.vec_y) ||
            !cyc_read_f32(blob, cursor, e.vec_init_x) ||
            !cyc_read_f32(blob, cursor, e.vec_init_y) ||
            !cyc_read_f32(blob, cursor, e.intensity) ||
            !cyc_read_f32(blob, cursor, e.radius_cells) ||
            !cyc_read_f32(blob, cursor, e.age_days) ||
            !cyc_read_f32(blob, cursor, e.move_progress)) {
            entries.clear();
            return;
        }
        if (!cyc_read_u32(blob, cursor, value32)) return;
        e.days_left = static_cast<int32_t>(value32);
        if (!cyc_read_u32(blob, cursor, value32)) return;
        e.init_days = static_cast<int32_t>(value32);
        entries.push_back(e);
    }
}

} // namespace pk_async_climate
} // namespace pk
