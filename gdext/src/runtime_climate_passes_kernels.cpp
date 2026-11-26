// ─── Climate pass 纯内核实现（Godot 无依赖）──────────────────────
//
// S3 搬迁体：下面 9 个 kernel 原位于 world_ext_climate.cpp（static 文件作用域），
// 现在是生产与 SHADOW worker 共用的唯一实现。搬迁是逐字的，不含任何算法改动；
// 任何数值行为变更必须单独提案，否则无法与 S2 分叉矩阵对齐。
//
// 不得 include godot_cpp。这一条约束就是“worker 可用”的全部含义。

#include "runtime_climate_passes.h"
#include "simulation_math.h"
#include "parallel_dispatcher.h"
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
    const float moisture_relax_eff = 1.0f - simulation_math::pow(1.0f - moisture_relax, thermal_dt);
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
        : (1.0f - simulation_math::pow(1.0f - 1.0f / 30.0f, thermal_dt));
    const float ema_alpha_365 = (thermal_dt <= 1.0f) ? annual_ema_alpha
        : (1.0f - simulation_math::pow(1.0f - annual_ema_alpha, thermal_dt));

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

    // A map row normally shares a latitude. Reuse the exact solar results
    // within this pass while still allowing arbitrary per-cell latitudes.
    uint32_t last_latitude_bits = 0;
    float insol_now = 0.0f;
    float day_length = 0.0f;
    float annual_mean_fallback = 0.0f;
    // ── 主循环（1:1 镜像 sync run_range body） ──
    for (int i = 0; i < n; ++i) {
        const float ny = PLN[i];
        const float temp_year_lat = PTY[i];
        const float elevation = PE[i];
        const bool is_water = IW[i] != 0;

        // (a) dev_today + insolation
        const float ny_clamped = dc_clamp01f(ny);
        uint32_t latitude_bits;
        std::memcpy(&latitude_bits, &ny_clamped, sizeof(latitude_bits));
        if (i == 0 || latitude_bits != last_latitude_bits) {
            last_latitude_bits = latitude_bits;
            insol_now = dc_insolation_now(ny_clamped, season_phase, axial_tilt_deg, daylen_amp);
            day_length = dc_day_length_norm(ny_clamped, season_phase, axial_tilt_deg);
            if (INSOL_MEAN_BAKED == nullptr)
                annual_mean_fallback = dc_insolation_annual_mean(
                    ny_clamped, axial_tilt_deg, daylen_amp);
        }
        // perf (Item 4, 2026-07-05): insol_mean 是年均、season-无关。主线程 kick 时已把
        // dc_insolation_annual_mean(dc_clamp01f(ny),...) 预烘焙进 in.insol_annual_mean（持锁、
        // 主线程算，避免 worker 触 member 缓存的 data race）。命中即读 → bit-equal；字段缺失/
        // 尺寸不符时回退 inline 重算（旧行为，向后兼容旧调用方）。
        const float insol_mean = INSOL_MEAN_BAKED ? INSOL_MEAN_BAKED[i] : annual_mean_fallback;
        float dev_today = dc_insolation_season_dev(ny_clamped, insol_now, insol_mean);
        if (dev_today < insol_dev_min) dev_today = insol_dev_min;
        else if (dev_today > insol_dev_max) dev_today = insol_dev_max;
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
} // namespace pk_async_climate
} // namespace pk
