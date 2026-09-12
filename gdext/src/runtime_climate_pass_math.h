#pragma once

// ─── Climate pass scalar helpers（Godot 无依赖）────────────────────────────
//
// S3（plan「Climate 对拍可比性修复路线」）第一步：把生产 Climate pass 用到的
// 标量 helper 从 world_ext_internal.h / world_ext_climate.cpp 抽到这里。
//
// 为什么必须单独一个 header：
//   world_ext_internal.h 里这些 helper 与 Godot 类型（FastNoiseLite、Vector2、
//   PackedArray）混在同一个 TU 头里，worker 侧的共享 pass TU 不能包含它——
//   否则 runtime_* 目录就被 Godot API 污染，SHADOW worker 也不再是纯 POD。
//   这里只依赖 <algorithm>/<cmath>/<cstdint> 与同样 Godot 无依赖的
//   runtime_climate_formulas.h。
//
// 约束（不可放松）：
//   1. 本文件**只允许**出现标量数学。任何 Godot 类型、任何 per-cell 循环、
//      任何 DCWorldExt 成员访问都不属于这里。
//   2. 所有函数体从原位置**逐字搬迁**，不得顺手"优化"。生产与 worker 共用同
//      一份实现是 S3 的全部意义；一旦这里的数值行为与原来有偏差，对拍矩阵会
//      把它记成"提取引入的新分叉"，无法与真实分叉区分。
//   3. 名字保持在 namespace pk 的全局作用域（与搬迁前一致），因此原有约 900
//      处调用点不需要任何改动。

#include "runtime_climate_formulas.h"

#include <algorithm>
#include <cmath>
#include <cstdint>

namespace pk {

// ─── clamp（搬自 world_ext_internal.h:254-260）────────────────────────────
// 注意：这里刻意不转发到 climate_formula::clamp01——原实现是独立 inline，
// 转发会改变 NaN 传播（v<0 与 v>1 都 false → 返回 NaN，与 std::clamp 不同）。
// 搬迁必须逐字，语义差异留给后续独立提案。
static inline float dc_clamp01f(float v) {
    return v < 0.0f ? 0.0f : (v > 1.0f ? 1.0f : v);
}

static inline float dc_clampf(float v, float lo, float hi) {
    return v < lo ? lo : (v > hi ? hi : v);
}

// 圆柱地球最小映像修正（seam-advection-fix 2026-08-03，搬自
// world_ext_internal.h:271-286）。
// 六邻居表在东西方向用 posmod 环绕（map_data.gd::_build_indices），最左列与最右列互为
// 邻居；但 cell_pos_x 存的是不环绕的规范坐标，所以接缝邻居的裸差分等于 ±(period − 一格
// 列距)：符号与真实位移相反、量级放大约 map.width 倍。任何把裸差分当方向向量的平流内核
// 都会在接缝两列把上/下游判反，且因 |dx| >> |dy| 退化成纯东西向 —— 表现为一条方向恒定、
// 不随纬度和时间变化的经线伪影（实测 slp 接缝跳变 7×、ocean_psi 12×）。
// 这里把 dx 折回半周期内取最近映像；y 方向是两极硬边界、不环绕，故不做处理。
// wrap_period_x <= 0（未配置环绕域）时退化为原始差分，保持向后兼容。
// 语义与 world_ext_bake.cpp 的 water_dx half-period 折叠一致。
static inline float pk_wrap_min_image_dx(float dx, float wrap_period_x) {
    if (!(wrap_period_x > 0.0f)) return dx;
    const float half = wrap_period_x * 0.5f;
    if (dx > half) return dx - wrap_period_x;
    if (dx < -half) return dx + wrap_period_x;
    return dx;
}

// double 版本：pass_b 雨影上风探测用 double 累加方向点积，保持原精度。
static inline double pk_wrap_min_image_dx(double dx, double wrap_period_x) {
    if (!(wrap_period_x > 0.0)) return dx;
    const double half = wrap_period_x * 0.5;
    if (dx > half) return dx - wrap_period_x;
    if (dx < -half) return dx + wrap_period_x;
    return dx;
}

// ─── 温度输送异常（TTA）稳定化（搬自 world_ext_internal.h:288-298）───────
static inline float dc_stabilize_tta(float prev, float source,
                                     float source_cap, float blend_rate) {
    const float cap = std::fabs(source_cap);
    const float capped_source = dc_clampf(source, -cap, cap);
    const float blend = dc_clampf(blend_rate, 0.0f, 1.0f);
    return prev + (capped_source - prev) * blend;
}

static inline float dc_decay_tta(float prev, float decay_rate) {
    return prev * (1.0f - dc_clampf(decay_rate, 0.0f, 1.0f));
}

// ─── 日照 / 昼长（搬自 world_ext_internal.h:300-331）─────────────────────
static inline float dc_phase_progress(float season_phase) {
    return climate_formula::phase_progress(season_phase);
}

static inline float dc_subsolar_lat_rad(float season_phase, float axial_tilt_deg) {
    return climate_formula::subsolar_lat_rad(season_phase, axial_tilt_deg);
}

static inline float dc_sunset_hour_angle(float lat_rad, float decl_rad) {
    return climate_formula::sunset_hour_angle(lat_rad, decl_rad);
}

static inline float dc_day_length_norm(float ny, float season_phase, float axial_tilt_deg) {
    return climate_formula::day_length_norm(ny, season_phase, axial_tilt_deg);
}

static inline float dc_insolation_now(float ny, float season_phase, float axial_tilt_deg, float daylen_amp) {
    return climate_formula::daily_insolation(ny, season_phase, axial_tilt_deg, daylen_amp);
}

static inline float dc_insolation_annual_mean(float ny, float axial_tilt_deg, float daylen_amp) {
    return climate_formula::annual_insolation_mean(ny, axial_tilt_deg, daylen_amp);
}

// SAME_SOURCE（C++ 镜像）: DCClimateMath.compute_insolation_dev_from_values。
// 2026-06-16 物理化：删除"极地放大/衰减"band-aid，dev 还原为纯物理偏差
//   dev = insol_now - insol_mean。极地夏季过热改由 pk_surface_absorbed_factor
//   （吸收短波 / 冰反照率反馈）在 season_offset 处处理，更物理。
// ny 保留入参以稳定签名与调用点，但不再参与计算。
static inline float dc_insolation_season_dev(float ny, float insol_now, float insol_mean) {
    return climate_formula::insolation_season_dev(ny, insol_now, insol_mean);
}

// ─── 表面吸收短波因子（搬自 world_ext_internal.h:333-351）────────────────
// SAME_SOURCE（C++ 镜像）: DCClimateMath.surface_absorbed_factor / ALBEDO_*。
// absorb = 1 - 反照率；冰雪高反照率反射极昼强日射 → 极地夏季自然变冷，并形成
// "冷→结冰→反照率升高→更冷"的自洽冰反照率正反馈。海洋反照率低于陆地→吸收更多
// （季节强迫更大），但其高热容（低 thermal_inertia_water）阻尼实际摆幅→大陆性对比。
// 归一化基准 = 无冰陆地 (1-PK_ALBEDO_LAND)，使无冰陆地 factor=1.0（中纬零重调）。
// 仅缩放 season_offset，不动 cos^1.6 年均基线 → 反馈有下界、不失控。
static constexpr float PK_ALBEDO_OCEAN = climate_formula::ALBEDO_OCEAN;
static constexpr float PK_ALBEDO_LAND  = climate_formula::ALBEDO_LAND;
static constexpr float PK_ALBEDO_ICE   = climate_formula::ALBEDO_ICE;
static constexpr float PK_T_ICE_LO     = climate_formula::ICE_TEMP_LOW;
static constexpr float PK_T_ICE_HI     = climate_formula::ICE_TEMP_HIGH;
// temp_annual 必须传【年均温度 temp_365d】（慢 EMA），不能传瞬时温度——否则
// "暖→脱冰→吸收增→更暖"会形成夏季融化正反馈使极地夏季失控变热（实测 0.43）。
// 用年均温度作"持久冰封气候"代理：深极地年均≈0.05 常年冰封 → 因子≈0.475 →
// 极地夏季自然压低且稳定（夏峰 0.30→0.22）；中纬年均高 → 因子=1.0 → 季节性不变。
static inline float pk_surface_absorbed_factor(bool is_water, float temp_annual) {
    return climate_formula::surface_absorbed_factor(is_water, temp_annual);
}

// ─── 季节项冷侧软压缩（搬自 world_ext_internal.h:353-364）────────────────
// SAME_SOURCE（C++ 镜像）: DCClimateMath.compress_season_cooling / WINTER_COOL_KNEE。
// 物理依据：极向热量输送 + 海洋/地表热库在冬季半球托底，使中/高纬冬季远比纯局地
// 辐射平衡暖。暖侧(s≥0)原样返回（保留夏季/极昼季节性与吸收因子效果）；冷侧(s<0)
// 按 tanh 软饱和到约 −KNEE：小幅降温几乎不变，深冬大幅降温不再无限过冷。
// KNEE=0.13：温带平原冬季 min 0.087→0.21（叠加 pass_b≈0.13 严寒、脱离极寒），
// 夏峰不变，深极地仍冻结（海冰核/冰带不塌）。
static constexpr float PK_WINTER_COOL_KNEE = climate_formula::WINTER_COOL_KNEE;

static inline float pk_compress_season_cooling(float season_offset) {
    return climate_formula::compress_season_cooling(season_offset);
}

// 热惯性松弛系数的多日积分：单日 α 表示"每日向 radiative target 逼近 α 比例"。
// 经过 dt 天（加速/跳日）后等效一次性系数 α_eff = 1 - (1-α)^dt（target 视作窗口内
// 近似恒定）。dt<=1 时退化为原 α，保持非加速档 bit-equal。SAME_SOURCE：
// map_generator.gd 同名内联与 climate_daily_system 共享同一公式。
static inline float pk_thermal_alpha_eff(float alpha, float dt_days) {
    return climate_formula::thermal_alpha_eff(alpha, dt_days);
}

// ─── 季节项组合（legacy parity，搬自 world_ext_internal.h:374-386）───────
// 2026-06-27 regression: native/SoA once multiplied land season forcing by
// land_continentality, while the original AoS fallback did not. At subpolar
// summer/daylight extremes that extra factor pushed season_offset to ~0.45 and
// made runtime baselines far warmer than pre-migration behavior. Keep the
// parameter in the signature for cp_struct/resource compatibility, but do not
// let pass-A amplify land temperatures outside the legacy formula.
static inline float pk_season_offset_continental(float insol_amp_gain, bool is_water,
                                                 float temp_annual, float dev_today,
                                                 float land_continentality) {
    return climate_formula::season_offset_continental(
        insol_amp_gain, is_water, temp_annual, dev_today, land_continentality);
}

// ─── 平滑阶跃 / 高程温度惩罚（搬自 world_ext_internal.h:1656-1684）───────
static inline double pk_smoothstep(double a, double b, double x) {
    if (b <= a) return x < a ? 0.0 : 1.0;
    double t = (x - a) / (b - a);
    if (t < 0.0) t = 0.0;
    else if (t > 1.0) t = 1.0;
    return t * t * (3.0 - 2.0 * t);
}

static constexpr double PK_ALT_PEN_ABS_ELEV_BLEND = climate_formula::ALT_PEN_ABS_ELEV_BLEND;

// SAME_SOURCE: map_generator.gd::_alt_penalty。
//   ALT_PEN_LINEAR=0.40, ALT_PEN_HIGH_LO=0.45, ALT_PEN_HIGH_HI=1.00, ALT_PEN_HIGH_AMP=0.22。
//   输入先从绝对 elevation 转为 sea_level 以上的 land_h，再混入少量绝对 elevation。
//   这样海平面附近不被过度扣温，同时中高海拔仍保留一部分冷却锚点。
static inline double pk_alt_penalty_from_height(double height_norm) {
    return climate_formula::altitude_penalty_from_height(height_norm);
}

static inline double pk_land_height_for_temperature(double elevation, double sea_level) {
    return climate_formula::land_height_for_temperature(elevation, sea_level);
}

static inline double pk_temperature_height_for_penalty(double elevation, double sea_level) {
    return climate_formula::temperature_height_for_penalty(elevation, sea_level);
}

static inline double pk_alt_penalty(double elevation, double sea_level) {
    return climate_formula::altitude_penalty(elevation, sea_level);
}

// SAME_SOURCE（C++ 镜像）: DCClimateMath.LAT_TEMP_CURVE_EXP —— 纬度温度钟形曲线指数的
// 唯一 C++ 值。赤道=1、两极=0，指数越大高纬越冷。2026-06-16：1.2→1.6（调低极地温度、
// 拓宽海冰带）。改这里务必同步 DCClimateMath.LAT_TEMP_CURVE_EXP（GDScript）+
// climate_season.gdshaderinc（Shader），并重编 gdext。
// terrain-overhaul（2026-06-18）：1.6→1.3，拓宽温带带——旧值钟形过窄使中纬迅速跌入
// taiga/tundra，温带森林/草原带被压扁；下调指数让温带/亚热带占据更多纬度。
static constexpr double PK_LAT_TEMP_CURVE_EXP = climate_formula::LAT_TEMP_CURVE_EXP;

// ─── 行星风带（搬自 world_ext_internal.h:963-1013）───────────────────────
// pass_b 雨影内核用它求上风方向。原本在 world_ext_internal.h 的匿名 namespace，
// 搬到 pk 作用域后既有的非限定调用点（都在 namespace pk 内）解析不变。
// Mirror weather/wind_belt.gd::wind_at — bit-equal scalar translation.
// Constants from wind_belt.gd:38-51. All scalar; promote to double for
// bit-equal stability across libm differences (charter §12.6.2).
inline void wind_belt_at(double ny, double season_phase,
                         double *out_wx, double *out_wy) {
    (void)season_phase;
    constexpr double ITCZ_HALF_WIDTH = 0.05;
    constexpr double TRADE_TOP       = 0.40;
    constexpr double WEST_TOP        = 0.70;
    constexpr double TRADE_X         = -1.0;
    constexpr double TRADE_Y_AMP     = 0.20;
    constexpr double WEST_X          = 1.0;
    constexpr double WEST_Y_AMP      = 0.10;
    constexpr double POLAR_X         = -1.0;
    constexpr double POLAR_Y_AMP     = 0.20;
    constexpr double ITCZ_X          = -0.20;
    constexpr double BBH             = 0.06;
    const double lat_signed = (ny - 0.5) * 2.0; // F.3 不传 lat_jitter
    const double abs_lat    = (lat_signed < 0.0) ? -lat_signed : lat_signed;
    const double sl         = (lat_signed < -0.001) ? -1.0 : (lat_signed > 0.001 ? 1.0 : 1.0);

    // smoothstep(a, b, x) = (clamp((x-a)/(b-a), 0, 1))^2 * (3 - 2*t)
    auto smoothstep = [](double a, double b, double x) -> double {
        const double span = b - a;
        if (std::abs(span) < 1e-12) return (x >= a) ? 1.0 : 0.0;
        double t = (x - a) / span;
        if (t < 0.0) t = 0.0; else if (t > 1.0) t = 1.0;
        return t * t * (3.0 - 2.0 * t);
    };

    const double w_itcz_b = 1.0 - smoothstep(ITCZ_HALF_WIDTH - BBH, ITCZ_HALF_WIDTH + BBH, abs_lat);
    const double w_trade_b = smoothstep(ITCZ_HALF_WIDTH - BBH, ITCZ_HALF_WIDTH + BBH, abs_lat)
                           * (1.0 - smoothstep(TRADE_TOP - BBH, TRADE_TOP + BBH, abs_lat));
    const double w_west_b = smoothstep(TRADE_TOP - BBH, TRADE_TOP + BBH, abs_lat)
                          * (1.0 - smoothstep(WEST_TOP - BBH, WEST_TOP + BBH, abs_lat));
    const double w_polar_b = smoothstep(WEST_TOP - BBH, WEST_TOP + BBH, abs_lat);
    const double base_x = w_itcz_b * ITCZ_X + w_trade_b * TRADE_X + w_west_b * WEST_X + w_polar_b * POLAR_X;
    const double base_y = w_trade_b * (-TRADE_Y_AMP * sl) + w_west_b * (WEST_Y_AMP * sl) + w_polar_b * (-POLAR_Y_AMP * sl);

    double wx = base_x;
    double wy = base_y;
    const double wlen2 = wx * wx + wy * wy;
    if (wlen2 < 0.0001) {
        *out_wx = 1.0;
        *out_wy = 0.0;
        return;
    }
    const double inv = 1.0 / std::sqrt(wlen2);
    *out_wx = wx * inv;
    *out_wy = wy * inv;
}

// ─── 水文/植被标量（搬自 world_ext_climate.cpp:57-71）────────────────────
static inline float pk_signed_hydrology_contribution(float anomaly,
                                                      float wet_weight,
                                                      float dry_weight) {
    return climate_formula::signed_hydrology_contribution(
        anomaly, wet_weight, dry_weight);
}

static inline float pk_plant_available_water(
        float moisture, float water_balance_30d, float soil_moisture,
        float water_balance_weight, float soil_buffer_weight,
        float drought_penalty) {
    return climate_formula::plant_available_water(
        moisture, water_balance_30d, soil_moisture,
        water_balance_weight, soil_buffer_weight, drought_penalty);
}

// ─── 冷水正向输送闸门（搬自 world_ext_climate.cpp:1023-1036）─────────────
// ocean_water/ocean_land pass 用：source>0（暖输送）时按海冰覆盖与"距融点还有
// 多少余量"双重压制，避免把冰封海面直接加热到融化。
static inline float pk_limit_cold_water_positive_transport_source(
        float source, float baseline, float sea_ice_frac, float t_form, float t_melt) {
    if (source <= 0.0f) return source;
    source *= 1.0f - dc_clampf(sea_ice_frac, 0.0f, 1.0f);
    const float span = std::max(0.001f, t_melt - t_form);
    float t = (baseline - t_form) / span;
    if (t < 0.0f) t = 0.0f;
    else if (t > 1.0f) t = 1.0f;
    const float cold_gate = t * t * (3.0f - 2.0f * t);
    source *= cold_gate;
    const float melt_room = t_melt - baseline;
    if (melt_room <= 0.0f) return source;
    return std::min(source, melt_room);
}

// ─── 雪盖反照率（搬自 world_ext_climate.cpp:1639-1645）───────────────────
static inline float pk_snowpack_cover_for_albedo(float snowpack, float low, float full) {
    const float span = (full - low) > 0.001f ? (full - low) : 0.001f;
    float u = (snowpack - low) / span;
    if (u < 0.0f) u = 0.0f;
    else if (u > 1.0f) u = 1.0f;
    return u * u * (3.0f - 2.0f * u);
}

// ─── 海冰标量（搬自 world_ext_climate.cpp:3312-3352）─────────────────────
static inline float sea_ice_smoothstep(float edge0, float edge1, float x) {
    const float span = edge1 - edge0;
    if (span == 0.0f) {
        return x < edge0 ? 0.0f : 1.0f;
    }
    float t = (x - edge0) / span;
    if (t < 0.0f) t = 0.0f;
    else if (t > 1.0f) t = 1.0f;
    return t * t * (3.0f - 2.0f * t);
}

static inline float sea_ice_freeze_gate(float insolation_now, float freeze_low, float freeze_high) {
    const float high = std::max(freeze_high, freeze_low + 0.001f);
    const float gate = 1.0f - sea_ice_smoothstep(freeze_low, high, insolation_now);
    if (gate < 0.0f) return 0.0f;
    if (gate > 1.0f) return 1.0f;
    return gate;
}

static inline float sea_ice_solar_melt(float insolation_now, float melt_start, float melt_gain) {
    const float gain = std::max(melt_gain, 0.0f);
    const float excess = insolation_now - melt_start;
    return excess > 0.0f ? gain * excess : 0.0f;
}

static inline float sea_ice_solar_exposure(float sea_ice_frac, float min_thick_ice_exposure = 0.32f) {
    float kMinThickIceExposure = min_thick_ice_exposure;
    if (kMinThickIceExposure < 0.0f) kMinThickIceExposure = 0.0f;
    else if (kMinThickIceExposure > 0.50f) kMinThickIceExposure = 0.50f;
    const float cover = dc_clampf(sea_ice_frac, 0.0f, 1.0f);
    const float shield = sea_ice_smoothstep(0.05f, 0.55f, cover);
    const float exposure = 1.0f - (1.0f - kMinThickIceExposure) * shield;
    return exposure < kMinThickIceExposure ? kMinThickIceExposure : exposure;
}

static inline float sea_ice_positive_tta_residual(float tta, float ocean_thermal_anom) {
    if (tta <= 0.0f) return 0.0f;
    const float realized = ocean_thermal_anom > 0.0f ? ocean_thermal_anom : 0.0f;
    const float residual = tta - realized;
    return residual > 0.0f ? residual : 0.0f;
}


// ─── vegetation 适应度 / 演替标量 helper（S3 自 world_ext_internal.h 搬迁）───
//
// 搬迁理由：stage 9 vegetation_dynamics 的共享纯内核（runtime_climate_passes.cpp）
// 要调这几个函数，而那一层不得 include godot_cpp。函数体逐字搬迁，无数值改动。
// 里面的魔术数字是 VegetationType / TerrainType / LandformType 的 enum id，
// 与 GDScript 侧 vegetation_type.gd / terrain_type.gd 同源。

static inline bool pk_vegetation_is_wet_type(uint8_t veg) {
    return veg == 5 || veg == 7 || veg == 8 || veg == 12 || veg == 14 ||
           veg == 15 || veg == 19 || veg == 20 || veg == 21 || veg == 24 ||
           veg == 25 || veg == 27;
}

static inline bool pk_vegetation_is_alpine_type(uint8_t veg) {
    return veg == 3 || veg == 4 || veg == 5 || veg == 6 || veg == 8 || veg == 27;
}

static inline bool pk_vegetation_is_arid_type(uint8_t veg) {
    return veg == 10 || veg == 11 || veg == 16 || veg == 17;
}

// Wet forests and wetlands are constrained primarily by water deficit.
// Surplus water retains a small waterlogging cost, but is not symmetric with drought.
static inline float pk_vegetation_climate_score_for_type(
        uint8_t veg, float temperature, float moisture,
        float ideal_temp, float ideal_moist,
        float temp_tolerance, float moist_tolerance) {
    const float st = std::max(temp_tolerance, 0.05f);
    const float sm = std::max(moist_tolerance, 0.05f);
    const float dt = (temperature - ideal_temp) / st;
    float dm = (moisture - ideal_moist) / sm;
    if (dm > 0.0f && pk_vegetation_is_wet_type(veg)) dm *= 0.25f;
    return float(std::exp(-0.5 * double(dt * dt + dm * dm)));
}

static inline bool pk_vegetation_candidate_allowed(uint8_t terrain, uint8_t veg) {
    if (veg == 22 || veg == 23 || veg == 26) return false; // aquatic only
    // Saturated substrates resolve to marsh/swamp/mangrove/monsoon communities.
    if (veg == 14 && (terrain == 10 || terrain == 16 || terrain == 22 || terrain == 29)) {
        return false;
    }
    return true;
}

// Climate biome envelope shared with VegetationType.biome_envelope_weight.
// Biome is the slow climate identity; vegetation may lag it, but a severe
// cross-biome mismatch must be a poor suitability candidate.
static inline float pk_vegetation_biome_weight(uint8_t terrain, uint8_t veg) {
    switch (terrain) {
        case 0: // OCEAN
            if (veg == 0) return 1.00f;
            if (veg == 22 || veg == 23 || veg == 26) return 0.30f;
            return 0.18f;
        case 1: // COAST
            if (veg == 26) return 1.00f;
            if (veg == 0) return 0.90f;
            if (veg == 22) return 0.70f;
            if (veg == 23) return 0.65f;
            if (veg == 19) return 0.45f;
            return 0.18f;
        case 2: // PLAIN
        case 5: // HILL
        case 6: // MOUNTAIN
            return 1.00f; // climate-agnostic substrates
        case 4: // FOREST
            if (veg == 7 || veg == 12) return 1.00f; // temperate deciduous / subtropical
            if (veg == 8) return 0.90f;               // temperate conifer
            if (veg == 24) return 0.88f;              // cloud forest
            if (veg == 15) return 0.72f;              // tropical dry forest
            if (veg == 25) return 0.55f;              // monsoon forest
            if (veg == 14) return 0.28f;              // tropical rainforest
            if (veg == 13) return 0.65f;              // savanna
            if (veg == 9) return 0.76f;               // temperate grassland
            return 0.70f;
        case 11: // JUNGLE
            if (veg == 14) return 1.00f;              // tropical rainforest
            if (veg == 24) return 0.95f;              // cloud forest
            if (veg == 25) return 0.90f;              // monsoon forest
            if (veg == 15) return 0.82f;              // tropical dry forest
            if (veg == 12) return 0.72f;              // subtropical forest
            if (veg == 13) return 0.58f;              // savanna
            if (veg == 9) return 0.50f;               // temperate grassland
            return 0.28f;
        case 12: // SAVANNA
            if (veg == 13) return 1.00f;              // savanna
            if (veg == 15) return 0.82f;              // tropical dry forest
            if (veg == 9) return 0.72f;               // temperate grassland
            if (veg == 10) return 0.64f;              // temperate steppe
            if (veg == 16) return 0.55f;              // desert scrub
            if (veg == 25) return 0.45f;              // monsoon forest
            if (veg == 14) return 0.25f;              // tropical rainforest
            return 0.55f;
        case 3: // GRASSLAND
            if (veg == 9) return 1.00f;               // temperate grassland
            if (veg == 10) return 0.88f;              // temperate steppe
            if (veg == 13) return 0.72f;              // savanna
            if (veg == 4 || veg == 6) return 0.75f;   // alpine meadow / boreal shrub
            if (veg == 15) return 0.55f;              // tropical dry forest
            if (veg == 25) return 0.38f;              // monsoon forest
            if (veg == 14) return 0.25f;              // tropical rainforest
            return 0.65f;
        case 14: // STEPPE
            if (veg == 10) return 1.00f;              // temperate steppe
            if (veg == 9) return 0.82f;               // temperate grassland
            if (veg == 16 || veg == 11 || veg == 13) return 0.72f;
            if (veg == 15) return 0.52f;              // tropical dry forest
            if (veg == 25) return 0.25f;              // monsoon forest
            if (veg == 14) return 0.18f;              // tropical rainforest
            return 0.65f;
        case 7: // DESERT
            if (veg == 16 || veg == 17) return 1.00f; // desert scrub / xeric desert
            if (veg == 10 || veg == 13) return 0.68f;
            if (veg == 11) return 0.62f;              // mediterranean shrub
            if (veg == 15) return 0.35f;              // tropical dry forest
            if (veg == 25 || veg == 14) return 0.18f;
            return 0.55f;
        case 8: // TUNDRA
            if (veg == 2 || veg == 1 || veg == 3) return 1.00f;
            if (veg == 6 || veg == 5) return 0.78f;
            if (veg == 4) return 0.70f;
            return 0.18f;
        case 13: // TAIGA
            if (veg == 5 || veg == 8) return 1.00f;
            if (veg == 6) return 0.90f;
            if (veg == 2 || veg == 3) return 0.72f;
            if (veg == 7) return 0.65f;
            return 0.18f;
        case 26: // COLD_DESERT
            if (veg == 17 || veg == 16) return 0.95f;
            if (veg == 1 || veg == 10) return 0.78f;
            if (veg == 2) return 0.68f;
            return 0.18f;
        case 27: // CHAPARRAL
            if (veg == 11) return 1.00f;
            if (veg == 16 || veg == 10) return 0.74f;
            if (veg == 13) return 0.60f;
            if (veg == 25 || veg == 14) return 0.30f;
            return 0.65f;
        case 15: // SHRUBLAND
            if (veg == 11) return 0.95f;
            if (veg == 16 || veg == 10) return 0.78f;
            if (veg == 13) return 0.62f;
            if (veg == 25 || veg == 14) return 0.25f;
            return 0.65f;
        case 9: // SNOW
            if (veg == 1) return 1.00f;                // polar desert
            if (veg == 3) return 0.95f;                // alpine tundra
            if (veg == 2) return 0.90f;                // tundra
            if (veg == 4) return 0.70f;                // alpine meadow
            if (veg == 5 || veg == 8) return 0.45f;    // taiga / conifer under snow
            if (veg == 0) return 0.80f;
            return 0.18f;
        case 10: // SWAMP
            if (veg == 20) return 1.00f;
            if (veg == 27) return 0.95f;
            if (veg == 21) return 0.90f;
            if (veg == 14 || veg == 25) return 0.65f;
            if (veg == 19) return 0.45f;
            if (veg == 0) return 0.75f;
            return 0.18f;
        case 16: // MANGROVE terrain
            if (veg == 19) return 1.00f;
            if (veg == 21 || veg == 20) return 0.80f;
            if (veg == 14 || veg == 25) return 0.55f;
            if (veg == 0) return 0.70f;
            return 0.18f;
        case 17: // GLACIER
            if (veg == 0) return 1.00f;
            if (veg == 1) return 0.80f;
            if (veg == 3) return 0.75f;
            return 0.18f;
        case 18: // LAKE
            return veg == 0 ? 1.00f : 0.18f;
        case 19: // REEF
            if (veg == 23) return 1.00f;
            if (veg == 0) return 0.80f;
            if (veg == 26) return 0.65f;
            return 0.18f;
        case 20: // SEA_ICE
            if (veg == 0) return 1.00f;
            if (veg == 1) return 0.55f;
            return 0.18f;
        case 21: // KELP
            if (veg == 22) return 1.00f;
            if (veg == 0) return 0.80f;
            if (veg == 26) return 0.65f;
            return 0.18f;
        case 22: // DELTA
            if (veg == 21) return 0.98f;
            if (veg == 19) return 0.90f;
            if (veg == 20) return 0.85f;
            if (veg == 0) return 0.85f;
            if (veg == 25 || veg == 13) return 0.80f;
            if (veg == 14) return 0.72f;
            if (veg == 15) return 0.65f;
            if (veg == 9 || veg == 7) return 0.78f;
            if (veg == 5 || veg == 6 || veg == 8) return 0.50f;
            return 0.18f;
        case 23: // OASIS
            if (veg == 18) return 1.00f;
            if (veg == 0) return 0.80f;
            if (veg == 16 || veg == 17 || veg == 13) return 0.60f;
            if (veg == 9) return 0.55f;
            return 0.18f;
        case 24: // SALT_FLAT
            if (veg == 0) return 1.00f;
            if (veg == 17 || veg == 16) return 0.45f;
            return 0.18f;
        case 25: // BADLANDS
            if (veg == 16) return 1.00f;
            if (veg == 17) return 0.85f;
            if (veg == 10 || veg == 11) return 0.70f;
            if (veg == 13) return 0.50f;
            if (veg == 0) return 0.80f;
            return 0.18f;
        case 28: // MOOR
            if (veg == 27) return 1.00f;
            if (veg == 21 || veg == 20) return 0.90f;
            if (veg == 5 || veg == 6) return 0.65f;
            if (veg == 4) return 0.55f;
            if (veg == 9) return 0.75f;
            return 0.18f;
        case 29: // FLOODPLAIN
            if (veg == 21) return 0.98f;
            if (veg == 20) return 0.90f;
            if (veg == 19) return 0.80f;
            if (veg == 25 || veg == 13) return 0.80f;
            if (veg == 14) return 0.72f;
            if (veg == 15) return 0.65f;
            if (veg == 9 || veg == 7) return 0.90f;
            if (veg == 5 || veg == 6 || veg == 8) return 0.60f;
            if (veg == 0) return 0.85f;
            return 0.45f;
        case 30: // MESA
            if (veg == 16) return 1.00f;
            if (veg == 17) return 0.85f;
            if (veg == 10) return 0.65f;
            if (veg == 11) return 0.60f;
            if (veg == 13) return 0.55f;
            if (veg == 0) return 0.80f;
            return 0.18f;
        default:
            return 1.00f;
    }
}

static constexpr float PK_BIOME_RECONCILE_WEIGHT_THRESHOLD = 0.58f;

static inline bool pk_vegetation_needs_biome_reconcile(uint8_t terrain, uint8_t veg) {
    return veg != 0 &&
           pk_vegetation_biome_weight(terrain, veg) <= PK_BIOME_RECONCILE_WEIGHT_THRESHOLD;
}

// Returns a bounded soft multiplier.  A value of zero is reserved for a
// physically impossible substrate and is handled separately by the caller.
static inline float pk_vegetation_terrain_weight(uint8_t terrain, uint8_t landform,
                                                uint8_t veg, float moisture) {
    float w = 1.0f;
    const bool wet = pk_vegetation_is_wet_type(veg);
    const bool arid = pk_vegetation_is_arid_type(veg);
    const bool alpine = pk_vegetation_is_alpine_type(veg);

    switch (terrain) {
        case 25: // BADLANDS: aridity is a prior, not a hard mapping.
            w *= arid ? 1.10f : 0.84f;
            break;
        case 28: // MOOR: wet/cold vegetation is favored.
            w *= (veg == 27) ? 1.20f : (wet ? 1.08f : 0.62f);
            break;
        case 29: // FLOODPLAIN: water availability still decides the winner.
            w *= wet ? 1.16f : (arid ? 0.68f : 1.02f);
            break;
        case 30: // MESA: dry scrub is favored, but never forced.
            w *= arid ? 1.08f : 0.90f;
            break;
        case 10: // SWAMP.
            w *= wet ? 1.15f : 0.65f;
            break;
        case 16: // MANGROVE coast.
            w *= (veg == 19) ? 1.20f : (wet ? 1.05f : 0.58f);
            break;
        case 15: // Mediterranean shrubland.
            w *= (veg == 11) ? 1.14f : 0.92f;
            break;
        default:
            break;
    }

    if (landform == 7 || landform == 8) { // MOUNTAIN / PEAK.
        w *= alpine ? 1.16f : (arid && moisture > 0.45f ? 0.58f : 0.90f);
    } else if (landform == 6) { // HILL.
        w *= alpine ? 1.06f : 1.0f;
    }
    w *= pk_vegetation_biome_weight(terrain, veg);
    return std::clamp(w, 0.18f, 1.25f);
}

// ─── weather field solve 的无状态 helper（原在 world_ext_internal.h）────────
//
// 这些本来就不依赖 Godot，搬来是为了让 stage 11 的纯内核和生产热路径共用同一
// 份定义。名字与作用域不变（namespace pk 全局），原有的非限定调用点照旧解析。
// 唯一的替换是 Math::sqrt → std::sqrt：两者都是 IEEE 正确舍入的 sqrtf，逐位相同
// （p1-psi 已在 30 日对拍上验证过这一替换是 bit-neutral）。

inline void wf_wrapped_delta(float ax, float ay, float bx, float by,
                             float wrap_width_x, float &dx, float &dy) {
    dx = bx - ax;
    dy = by - ay;
    if (wrap_width_x > 0.001f) {
        const float half = wrap_width_x * 0.5f;
        if (dx > half) {
            dx -= wrap_width_x;
        } else if (dx < -half) {
            dx += wrap_width_x;
        }
    }
}

inline float wf_smoothstep(float edge0, float edge1, float x) {
    float t = (x - edge0) / (edge1 - edge0);
    if (t < 0.0f) t = 0.0f;
    else if (t > 1.0f) t = 1.0f;
    return t * t * (3.0f - 2.0f * t);
}

// Deterministic per-(cell,tick) hash → [0,1). Integer ops chosen to mirror GDScript exactly
// (32-bit wrap). Used to seed the synoptic eddy field ψ (Stage7). Same formula in field_solver.gd.
inline float wf_hash01(int cell, int tick) {
    uint32_t h = (uint32_t)cell * 374761393u + (uint32_t)tick * 668265263u;
    h = (h ^ (h >> 13)) * 1274126177u;
    h ^= (h >> 16);
    return (float)(h & 0x00FFFFFFu) / (float)0x01000000u;
}

// Mirror weather_system.gd::_neighbor_average_vapor_idx (line 1314).
inline float wf_neighbor_average_vapor_idx(int idx, const int32_t *NB,
                                          const float *PV) {
    float sum_v = PV[idx];
    int   n     = 1;
    const int base = idx * 6;
    for (int d = 0; d < 6; ++d) {
        const int32_t nb_idx = NB[base + d];
        if (nb_idx < 0) continue;
        sum_v += PV[nb_idx];
        n += 1;
    }
    return sum_v / float(n);
}

// POD position variant of wf_neighbor_aligned_idx. Bit-identical to the
// godot::Vector2 version in world_ext_internal.h — same operation order, same
// sqrt — with the interleaved position array split into two float lanes so a
// worker-side kernel can call it. The Vector2 version delegates here.
inline int wf_neighbor_aligned_idx_xy(int idx, float dir_x, float dir_y,
                                      const float *POSX, const float *POSY,
                                      const int32_t *NB,
                                      int n_cells, float cell_pos_scale,
                                      float wrap_width_x) {
    if (idx < 0 || idx >= n_cells) return -1;
    const float dl2 = dir_x * dir_x + dir_y * dir_y;
    if (dl2 <= 0.0001f) return -1;
    const float inv_dl = 1.0f / std::sqrt(dl2);
    const float ndx = dir_x * inv_dl;
    const float ndy = dir_y * inv_dl;
    const float self_x = POSX[idx];
    const float self_y = POSY[idx];
    int   best_idx = -1;
    const float pos_scale = (cell_pos_scale > 0.001f) ? cell_pos_scale : 1.0f;
    float best_dot = pos_scale * 0.31176915f;
    const int base = idx * 6;
    for (int d = 0; d < 6; ++d) {
        const int32_t nb_idx = NB[base + d];
        if (nb_idx < 0) continue;
        float to_nb_x = 0.0f;
        float to_nb_y = 0.0f;
        wf_wrapped_delta(self_x, self_y, POSX[nb_idx], POSY[nb_idx],
                         wrap_width_x, to_nb_x, to_nb_y);
        const float dot = to_nb_x * ndx + to_nb_y * ndy;
        if (dot > best_dot) {
            best_dot = dot;
            best_idx = nb_idx;
        }
    }
    return best_idx;
}

// Mirror weather_system.gd::_is_water_terrain — bit-equal terrain enum check.
// OCEAN=0, COAST=1, LAKE=18, REEF=19, SEA_ICE=20, KELP=21 (terrain_type.gd).
inline bool wf_is_water_terrain(uint8_t t) {
    return t == 0 || t == 1 || t == 18 || t == 19 || t == 20 || t == 21;
}

// Mirror weather_system.gd::_vegetation_transpiration_factor. Veg ordinals from
// vegetation_type.gd VEG enum.
inline float wf_vegetation_transp_factor(uint8_t veg) {
    if (veg == 0) return 0.0f;                          // NONE
    if (veg == 14 || veg == 19 || veg == 20) return 1.0f;   // RAINFOREST/MANGROVE/SWAMP
    if (veg == 5 || veg == 7 || veg == 12) return 0.65f;    // TAIGA/DECIDUOUS/SUBTROPICAL
    if (veg == 9 || veg == 13 || veg == 21) return 0.35f;   // GRASSLAND/SAVANNA/MARSH
    return 0.18f;
}

// Mirror weather_system.gd::_avg_ocean_anomaly_at_idx.
// `TA` is per-cell `cell.temperature_transport_anomaly`.
inline float wf_avg_ocean_anomaly_at_idx(int idx, const uint8_t *TERR,
                                         const int32_t *NB, const float *TA) {
    if (wf_is_water_terrain(TERR[idx])) return TA[idx];
    float sum_an  = 0.0f;
    int   n_water = 0;
    const int base = idx * 6;
    for (int d = 0; d < 6; ++d) {
        const int32_t nb_idx = NB[base + d];
        if (nb_idx < 0) continue;
        if (wf_is_water_terrain(TERR[nb_idx])) {
            sum_an += TA[nb_idx];
            n_water += 1;
        }
    }
    if (n_water == 0) return 0.0f;
    return sum_an / float(n_water);
}

// Mirror weather_system.gd::_evaporation_for_cell_idx.
inline float wf_evaporation_for_cell_idx(int idx, const uint8_t *TERR,
                                         const uint8_t *VEG,
                                         const uint8_t *HAS_RIV,
                                         const int32_t *NB,
                                         float temp, float moisture,
                                         float ocean_an, bool on_water,
                                         float field_ocean_evap_gain,
                                         float field_lake_evap_scale) {
    float evap = on_water ? 0.028f : 0.006f;
    if (TERR[idx] == 18) {
        evap *= field_lake_evap_scale;
    }
    const float excess_moist = moisture - 0.45f;
    if (excess_moist > 0.0f) evap += excess_moist * 0.018f;
    evap += wf_vegetation_transp_factor(VEG[idx]) * 0.012f;
    if (!on_water) {
        if (HAS_RIV[idx] != 0) evap += 0.012f;
        const int base = idx * 6;
        for (int d = 0; d < 6; ++d) {
            const int32_t nb_idx = NB[base + d];
            if (nb_idx < 0) continue;
            if (wf_is_water_terrain(TERR[nb_idx])) {
                evap += 0.018f;
                break;
            }
        }
    }
    float ocean_mul = 1.0f + ocean_an * field_ocean_evap_gain;
    if (ocean_mul < 0.55f) ocean_mul = 0.55f;
    else if (ocean_mul > 1.85f) ocean_mul = 1.85f;
    float temp_mul = 0.35f + temp * 1.25f;
    if (temp_mul < 0.12f) temp_mul = 0.12f;
    else if (temp_mul > 1.35f) temp_mul = 1.35f;
    return evap * ocean_mul * temp_mul;
}

// Mirror weather_system.gd::_orographic_lift_from_upstream_idx.
inline float wf_orographic_lift_from_upstream_idx(int idx, int upstream_idx,
                                                  const float *ELEV) {
    if (upstream_idx < 0) return 0.0f;
    const float diff = ELEV[idx] - ELEV[upstream_idx];
    if (diff > 0.02f) {
        float v = diff * 2.2f;
        if (v > 1.0f) v = 1.0f;
        return v;
    }
    if (diff < -0.02f) {
        float v = diff * 1.6f;
        if (v < -1.0f) v = -1.0f;
        return v;
    }
    return 0.0f;
}

inline float wf_wind_speed_norm(float dir_x, float dir_y, float speed) {
    if (speed > 0.0001f) return speed;
    const float len2 = dir_x * dir_x + dir_y * dir_y;
    return (len2 > 0.0001f) ? std::sqrt(len2) : 0.0f;
}

// POD position variant of wf_upstream_vapor_idx_from_first.
inline float wf_upstream_vapor_idx_from_first_xy(
        int idx, int first_upstream_idx,
        const float *POSX, const float *POSY, const int32_t *NB,
        const float *PV, float wind_dx, float wind_dy,
        int n_cells, float cell_pos_scale, float wrap_width_x,
        int field_advect_steps) {
    if (first_upstream_idx < 0 || field_advect_steps <= 0) return PV[idx];
    int   current_idx = first_upstream_idx;
    float sum_v   = PV[current_idx];
    float weight  = 1.0f;
    float w_decay = 0.75f;
    for (int step = 1; step < field_advect_steps; ++step) {
        const int upstream_idx = wf_neighbor_aligned_idx_xy(
            current_idx, -wind_dx, -wind_dy, POSX, POSY, NB, n_cells,
            cell_pos_scale, wrap_width_x);
        if (upstream_idx < 0) break;
        sum_v   += PV[upstream_idx] * w_decay;
        weight  += w_decay;
        w_decay *= 0.75f;
        current_idx = upstream_idx;
    }
    return sum_v / weight;
}

// POD position variant of wf_wind_convergence_idx.
inline float wf_wind_convergence_idx_xy(int idx,
                                        const float *POSX, const float *POSY,
                                        const int32_t *NB,
                                        const float *WX, const float *WY,
                                        const float *WSPD,
                                        float wrap_width_x) {
    const float self_x = POSX[idx];
    const float self_y = POSY[idx];
    float incoming = 0.0f;
    int   checked  = 0;
    const int base = idx * 6;
    for (int d = 0; d < 6; ++d) {
        const int32_t nb_idx = NB[base + d];
        if (nb_idx < 0) continue;
        float dx = 0.0f;
        float dy = 0.0f;
        wf_wrapped_delta(POSX[nb_idx], POSY[nb_idx], self_x, self_y,
                         wrap_width_x, dx, dy);
        const float dl2 = dx * dx + dy * dy;
        if (dl2 <= 0.0001f) continue;
        const float wx = WX[nb_idx];
        const float wy = WY[nb_idx];
        const float wl2 = wx * wx + wy * wy;
        if (wl2 <= 0.0001f) continue;
        const float inv_d = 1.0f / std::sqrt(dl2);
        const float inv_w = 1.0f / std::sqrt(wl2);
        float cos_in = (dx * wx + dy * wy) * (inv_d * inv_w);
        if (cos_in < 0.0f) cos_in = 0.0f;
        const float wsp = (WSPD != nullptr)
            ? wf_wind_speed_norm(wx, wy, WSPD[nb_idx]) : std::sqrt(wl2);
        float speed_w = wsp / 1.2f;
        if (speed_w < 0.20f) speed_w = 0.20f;
        else if (speed_w > 1.25f) speed_w = 1.25f;
        incoming += cos_in * speed_w;
        checked  += 1;
    }
    if (checked == 0) return 0.0f;
    float v = incoming / float(checked);
    if (v < 0.0f) v = 0.0f;
    else if (v > 1.0f) v = 1.0f;
    return v;
}

// ─── 邻域几何缓存版（bit-equal 加速变体）────────────────────────────────────
// 与上面三个逐位等价，只把热循环里每次重算的 self->nb wrapped delta 与
// 1/sqrt(dl2) 换成调用方预算的缓存 NB_DX/NB_DY/NB_INVD（n*6，dir 序）。
// NB_DX/NB_DY[base+d] == wf_wrapped_delta(self, POS[nb])（nb<0 处为 0）；
// NB_INVD[base+d] == 1/sqrt(dl2)（dl2<=1e-4 或 nb<0 处为 0 哨兵）。
inline int wf_neighbor_aligned_idx_cached(int idx, float dir_x, float dir_y,
                                          const int32_t *NB,
                                          const float *NB_DX, const float *NB_DY,
                                          int n_cells, float cell_pos_scale) {
    if (idx < 0 || idx >= n_cells) return -1;
    const float dl2 = dir_x * dir_x + dir_y * dir_y;
    if (dl2 <= 0.0001f) return -1;
    const float inv_dl = 1.0f / std::sqrt(dl2);
    const float ndx = dir_x * inv_dl;
    const float ndy = dir_y * inv_dl;
    int   best_idx = -1;
    const float pos_scale = (cell_pos_scale > 0.001f) ? cell_pos_scale : 1.0f;
    float best_dot = pos_scale * 0.31176915f;
    const int base = idx * 6;
    for (int d = 0; d < 6; ++d) {
        const int32_t nb_idx = NB[base + d];
        if (nb_idx < 0) continue;
        const float dot = NB_DX[base + d] * ndx + NB_DY[base + d] * ndy;
        if (dot > best_dot) {
            best_dot = dot;
            best_idx = nb_idx;
        }
    }
    return best_idx;
}

inline float wf_upstream_vapor_idx_from_first_cached(
        int idx, int first_upstream_idx, const int32_t *NB,
        const float *NB_DX, const float *NB_DY, const float *PV,
        float wind_dx, float wind_dy, int n_cells, float cell_pos_scale,
        int field_advect_steps) {
    if (first_upstream_idx < 0 || field_advect_steps <= 0) return PV[idx];
    int   current_idx = first_upstream_idx;
    float sum_v   = PV[current_idx];
    float weight  = 1.0f;
    float w_decay = 0.75f;
    for (int step = 1; step < field_advect_steps; ++step) {
        const int upstream_idx = wf_neighbor_aligned_idx_cached(
            current_idx, -wind_dx, -wind_dy, NB, NB_DX, NB_DY, n_cells,
            cell_pos_scale);
        if (upstream_idx < 0) break;
        sum_v   += PV[upstream_idx] * w_decay;
        weight  += w_decay;
        w_decay *= 0.75f;
        current_idx = upstream_idx;
    }
    return sum_v / weight;
}

inline float wf_wind_convergence_idx_cached(
        int idx, const int32_t *NB,
        const float *NB_DX, const float *NB_DY, const float *NB_INVD,
        const float *WX, const float *WY, const float *WSPD) {
    float incoming = 0.0f;
    int   checked  = 0;
    const int base = idx * 6;
    for (int d = 0; d < 6; ++d) {
        const int32_t nb_idx = NB[base + d];
        if (nb_idx < 0) continue;
        const float inv_d = NB_INVD[base + d];
        if (inv_d <= 0.0f) continue;          // dl2<=1e-4 哨兵：与原 dl2 跳过等价
        // 原版 dx,dy = wf_wrapped_delta(POS[nb], self) = self-nb = -(self->nb)。
        const float dx = -NB_DX[base + d];
        const float dy = -NB_DY[base + d];
        const float wx = WX[nb_idx];
        const float wy = WY[nb_idx];
        const float wl2 = wx * wx + wy * wy;
        if (wl2 <= 0.0001f) continue;
        const float inv_w = 1.0f / std::sqrt(wl2);
        float cos_in = (dx * wx + dy * wy) * (inv_d * inv_w);
        if (cos_in < 0.0f) cos_in = 0.0f;
        const float wsp = (WSPD != nullptr)
            ? wf_wind_speed_norm(wx, wy, WSPD[nb_idx]) : std::sqrt(wl2);
        float speed_w = wsp / 1.2f;
        if (speed_w < 0.20f) speed_w = 0.20f;
        else if (speed_w > 1.25f) speed_w = 1.25f;
        incoming += cos_in * speed_w;
        checked  += 1;
    }
    if (checked == 0) return 0.0f;
    float v = incoming / float(checked);
    if (v < 0.0f) v = 0.0f;
    else if (v > 1.0f) v = 1.0f;
    return v;
}

inline float wf_precip_terrain_damping_factor(uint8_t terrain) {
    // TerrainType.TERRAIN: HILL=5, SWAMP=10, JUNGLE=11, LAKE=18, DELTA=22.
    switch (terrain) {
        case 18: return 0.50f; // LAKE
        case 22: return 0.40f; // DELTA
        case 10: return 0.30f; // SWAMP
        case 11: return 0.0f;  // JUNGLE
        case 5:  return 0.0f;  // HILL
        default: return 0.0f;
    }
}

inline float wf_apply_precip_stability(uint8_t terrain, float precip,
                                       float wet_damp, float lake_damp,
                                       float soft_cap, float softness) {
    float out = precip;
    if (out < 0.0f) out = 0.0f;
    else if (out > 1.0f) out = 1.0f;
    const float factor = wf_precip_terrain_damping_factor(terrain);
    if (factor > 0.0f && out > 0.08f) {
        float damp = (terrain == 18) ? lake_damp : wet_damp;
        if (damp < 0.0f) damp = 0.0f;
        else if (damp > 1.0f) damp = 1.0f;
        out -= (out - 0.08f) * damp * factor;
    }
    if (soft_cap < 0.0f) soft_cap = 0.0f;
    else if (soft_cap > 1.0f) soft_cap = 1.0f;
    if (softness < 0.0f) softness = 0.0f;
    else if (softness > 1.0f) softness = 1.0f;
    if (soft_cap > 0.0f && out > soft_cap) {
        out = soft_cap + (out - soft_cap) * softness;
    }
    if (out < 0.0f) out = 0.0f;
    else if (out > 1.0f) out = 1.0f;
    return out;
}

// Mirror weather_system.gd::_classify_field_weather_core.
// WeatherType.WT: CLEAR=0 RAIN=1 STORM=2 BLIZZARD=3 DROUGHT=4 FOG=5 HEATWAVE=6
//                 MONSOON=7
inline uint8_t wf_classify_field_weather_at(float temp, float vapor, float cloud,
                                            float cloud_water, float precip,
                                            float instability, float ocean_an,
                                            float wind_speed, float temp_anom,
                                            float monsoon_flux,
                                            bool cold_precip_as_blizzard,
                                            float snow_classification_margin,
                                            bool is_water,
                                            float snow_cover) {
    const bool warm  = temp > 0.55f;
    const float humid_gate     = is_water ? 0.28f  : 0.09f;
    const float mp_cloud_gate  = is_water ? 0.22f  : 0.12f;
    const float mp_vapor_gate  = is_water ? 0.28f  : 0.09f;
    const float monsoon_vapor  = is_water ? 0.40f  : 0.14f;
    const float monsoon_precip = is_water ? 0.055f : 0.065f;
    const float monsoon_cloud  = is_water ? 0.45f  : 0.24f;
    const float fog_vapor      = is_water ? 0.22f  : 0.16f;
    const float fog_cloud      = is_water ? 0.085f : 0.10f;
    const bool humid = vapor > humid_gate;
    const float effective_cloud = (cloud > cloud_water * 1.25f) ? cloud : (cloud_water * 1.25f);
    const float precip_cloud_mass = (cloud_water > precip * 0.70f) ? cloud_water : (precip * 0.70f);
    const float precip_gate = is_water ? 0.032f : 0.040f;
    const float weak_precip_gate = is_water ? 0.022f : 0.030f;
    const bool meaningful_precip = precip > precip_gate ||
        (precip > weak_precip_gate && effective_cloud > mp_cloud_gate &&
         precip_cloud_mass > mp_cloud_gate * 0.35f && vapor > mp_vapor_gate);

    if (cold_precip_as_blizzard && meaningful_precip) {
        if (temp <= 0.24f)
            return 3; // BLIZZARD
        if (!is_water && snow_cover >= 0.25f &&
            temp < 0.31f + snow_classification_margin)
            return 3;
        if (temp < 0.31f + snow_classification_margin &&
            effective_cloud > 0.18f && vapor > 0.20f && precip > 0.04f &&
            wind_speed > 1.0f)
            return 3;
    }
    const bool warm_ocean_core = is_water && ocean_an > 0.05f &&
        instability > 0.64f && precip > 0.060f && effective_cloud > 0.24f &&
        precip_cloud_mass > 0.045f;
    if (warm && humid &&
        ((instability > 0.70f && precip > 0.065f && precip_cloud_mass > 0.050f) ||
         warm_ocean_core))
        return 2; // STORM
    float monsoon_driver = wf_smoothstep(monsoon_vapor * 0.78f,
                                         monsoon_vapor + 0.06f, vapor) * 0.24f;
    if (monsoon_flux > monsoon_driver) monsoon_driver = monsoon_flux;
    const bool sustained_precip = precip > monsoon_precip * 0.82f &&
        precip_cloud_mass > monsoon_cloud * 0.38f;
    const float monsoon_flux_gate = is_water ? 0.08f : 0.13f;
    const bool inland_monsoon_plume = !is_water && vapor > 0.24f &&
        wind_speed > 0.75f && precip > monsoon_precip &&
        precip_cloud_mass > monsoon_cloud * 0.45f;
    const bool monsoon_flow_gate = monsoon_driver > monsoon_flux_gate ||
        inland_monsoon_plume;
    if (warm && sustained_precip && effective_cloud > monsoon_cloud * 0.82f &&
        monsoon_flow_gate)
        return 7; // MONSOON
    if (meaningful_precip)
        return 1; // RAIN
    if (vapor > fog_vapor && effective_cloud > fog_cloud && precip < 0.030f &&
        temp < 0.55f)
        return 5; // FOG
    if (!is_water && temp > 0.55f && temp_anom > 0.05f && precip < 0.006f &&
        effective_cloud < 0.18f)
        return 4; // DROUGHT
    if (!is_water && warm && temp_anom > 0.04f && precip < 0.012f &&
        effective_cloud < 0.24f && vapor < 0.12f)
        return 6; // HEATWAVE
    return 0; // CLEAR
}

inline bool wf_is_precip_weather_type(uint8_t wt) {
    return wt == 1 || wt == 2 || wt == 3 || wt == 7;
}

// Mirror weather_system.gd::_field_intensity_for_type.
inline float wf_field_intensity_for_type(uint8_t wt, float temp, float vapor,
                                         float cloud, float precip,
                                         float instability, float ocean_an) {
    float v = 0.0f;
    switch (wt) {
        case 2: { // STORM
            const float m = (precip > instability) ? precip : instability;
            v = m * 0.82f + cloud * 0.18f;
            break;
        }
        case 7: // MONSOON
            v = precip * 0.72f + vapor * 0.18f + cloud * 0.18f;
            break;
        case 1: // RAIN
        case 3: // BLIZZARD
            v = precip * 1.15f + cloud * 0.20f;
            break;
        case 5: // FOG
            v = cloud * 0.75f + vapor * 0.20f;
            break;
        case 6: { // HEATWAVE
            float dry = 0.32f - vapor;
            if (dry < 0.0f) dry = 0.0f;
            v = (temp - 0.65f) * 2.2f + dry;
            break;
        }
        case 4: { // DROUGHT
            float oa = -ocean_an;
            if (oa < 0.0f) oa = 0.0f;
            v = (0.35f - vapor) * 2.0f + (0.16f - cloud) + oa * 0.6f;
            break;
        }
        default:
            return 0.0f;
    }
    if (v < 0.0f) v = 0.0f;
    else if (v > 1.0f) v = 1.0f;
    return v;
}

// Mirror weather_system.gd::_apply_frontal_convergence_boost fast-indexed path.
inline void wf_apply_frontal_convergence_boost_idx(
        int idx, const float *T, const float *AA, const int32_t *NB,
        float climate_anomaly, float convergence,
        float temp_self, float vapor, float ocean_an,
        float &cloud, float &precip, float &instability, uint8_t &wt,
        float &intensity) {
    constexpr float STORM_TEMP_DIFF = 0.28f;
    constexpr float WEAK_TEMP_DIFF = 0.06f;
    constexpr float CONVERGENCE_THRESHOLD = 0.45f;
    if (convergence < CONVERGENCE_THRESHOLD) return;

    float t_min = temp_self;
    float t_max = temp_self;
    const int base = idx * 6;
    for (int d = 0; d < 6; ++d) {
        const int32_t nb_idx = NB[base + d];
        if (nb_idx < 0) continue;
        float t_nb = T[nb_idx] + climate_anomaly + AA[nb_idx];
        if (t_nb < 0.0f) t_nb = 0.0f;
        else if (t_nb > 1.0f) t_nb = 1.0f;
        if (t_nb < t_min) t_min = t_nb;
        if (t_nb > t_max) t_max = t_nb;
    }

    const float temp_diff = t_max - t_min;
    float diff_score = temp_diff / STORM_TEMP_DIFF;
    if (diff_score < 0.0f) diff_score = 0.0f;
    else if (diff_score > 1.0f) diff_score = 1.0f;
    float frontal_score = ((convergence - CONVERGENCE_THRESHOLD)
            / (1.0f - CONVERGENCE_THRESHOLD)) * diff_score;
    if (frontal_score < 0.0f) frontal_score = 0.0f;
    else if (frontal_score > 1.0f) frontal_score = 1.0f;
    if (frontal_score < 0.45f) return;

    const float cloud_min = 0.25f + frontal_score * 0.20f;
    const bool frontal_precip_allowed = vapor > 0.09f;
    const float precip_min = frontal_precip_allowed
        ? (0.05f + frontal_score * 0.12f) : 0.0f;
    const float inst_min = 0.25f + frontal_score * 0.15f;
    if (cloud < cloud_min) cloud = cloud_min;
    if (frontal_precip_allowed && precip < precip_min) precip = precip_min;
    if (instability < inst_min) instability = inst_min;
    if (cloud > 1.0f) cloud = 1.0f;
    if (precip > 1.0f) precip = 1.0f;
    if (instability > 1.0f) instability = 1.0f;

    if (temp_diff < WEAK_TEMP_DIFF && (wt == 2 || wt == 7)) {
        wt = 1; // RAIN
    }
    if (!wf_is_precip_weather_type(wt) && precip >= 0.040f) {
        wt = 1; // RAIN
    }
    intensity = wf_field_intensity_for_type(
        wt, temp_self, vapor, cloud, precip, instability, ocean_an);
}

// ─── NS 化 Phase 0：六分扇形 barycentric（半拉格朗日终点插值）──────────────
// 原在 world_ext_internal.h 的匿名 namespace；B8 P2 把风轨迹内核搬进
// runtime_climate_physics 后，这里成为唯一来源（生产与 worker 共用）。
// 给定回溯终点 P=(tx,ty) 与宿主 cell `cur`，在 cur 与其 1-ring 构成的 6 个扇形
// 三角形中找包含 P 者，返回 (i0=cur, i1, i2) 与重心权重 (w0,w1,w2)。
// 权重 clamp 到 [0,1] 且和恒为 1；邻居缺失的扇形跳过；全部不可用退化 own-cell。
// x 方向按 wrap_period_x 最小映像折叠（≤0.001 = 不环绕），y 不环绕。
// SAME_SOURCE：GDScript 镜像 field_solver.gd::_hex_sextant_barycentric()。
inline void pk_hex_sextant_barycentric(
        int cur, float tx, float ty,
        const float *POSX, const float *POSY, const int32_t *NB, int n_cells,
        float wrap_period_x,
        int &i0, int &i1, int &i2, float &w0, float &w1, float &w2) {
    i0 = cur; i1 = cur; i2 = cur; w0 = 1.0f; w1 = 0.0f; w2 = 0.0f;
    if (cur < 0 || cur >= n_cells) return;
    const float cx = POSX[cur];
    const float cy = POSY[cur];
    float dx = tx - cx;
    const float dy = ty - cy;
    if (wrap_period_x > 0.001f) {
        const float half = wrap_period_x * 0.5f;
        if (dx > half) dx -= wrap_period_x;
        else if (dx < -half) dx += wrap_period_x;
    }
    const int base = cur * 6;
    float best_score = -2.0f;
    int   best_a = -1, best_b = -1;
    float best_u1 = 0.0f, best_u2 = 0.0f;
    for (int s = 0; s < 6; ++s) {
        const int a = NB[base + s];
        const int b = NB[base + ((s + 1) % 6)];
        if (a < 0 || a >= n_cells || b < 0 || b >= n_cells) continue;
        float eax = POSX[a] - cx;
        const float eay = POSY[a] - cy;
        float ebx = POSX[b] - cx;
        const float eby = POSY[b] - cy;
        if (wrap_period_x > 0.001f) {
            const float half = wrap_period_x * 0.5f;
            if (eax > half) eax -= wrap_period_x;
            else if (eax < -half) eax += wrap_period_x;
            if (ebx > half) ebx -= wrap_period_x;
            else if (ebx < -half) ebx += wrap_period_x;
        }
        const float det = eax * eby - eay * ebx;
        if (det > -1e-7f && det < 1e-7f) continue;
        const float inv_det = 1.0f / det;
        const float u1 = (dx * eby - dy * ebx) * inv_det;
        const float u2 = (eax * dy - eay * dx) * inv_det;
        if (u1 < -1e-4f || u2 < -1e-4f) continue;
        const float score = 1.0f - u1 - u2;
        if (score > best_score) {
            best_score = score;
            best_a = a; best_b = b;
            best_u1 = u1; best_u2 = u2;
            if (score >= 0.0f) break;
        }
    }
    if (best_a < 0) return;
    float c1 = best_u1 < 0.0f ? 0.0f : (best_u1 > 1.0f ? 1.0f : best_u1);
    float c2 = best_u2 < 0.0f ? 0.0f : (best_u2 > 1.0f ? 1.0f : best_u2);
    float c0 = 1.0f - c1 - c2;
    if (c0 < 0.0f) {
        const float inv_sum = 1.0f / (c1 + c2);
        c1 *= inv_sum; c2 *= inv_sum; c0 = 0.0f;
    }
    i1 = best_a; i2 = best_b;
    w0 = c0; w1 = c1; w2 = c2;
}

// 风场状态轻量指纹（64 降采样 + n_cells）：轨迹表构建时快照，消费端复算比对，
// 任何绕过 wind pass 的风槽改写（GDScript fallback / 换图）即失配 → 落旧路径。
// 非加密强度，仅作 stale 安全网；采样索引固定 → 确定性。
inline uint64_t pk_wind_state_fp(int n_cells, const float *WX, const float *WY,
                                 const float *WSP) {
    uint64_t fp = 1469598103934665603ull;  // FNV-1a offset basis
    auto mix = [&fp](uint32_t bits) {
        fp ^= uint64_t(bits);
        fp *= 1099511628211ull;  // FNV-1a prime
    };
    mix(uint32_t(n_cells));
    const int stride = (n_cells > 64) ? (n_cells / 64) : 1;
    for (int i = 0; i < n_cells; i += stride) {
        uint32_t bx = 0, by = 0, bs = 0;
        std::memcpy(&bx, WX + i, sizeof(float));
        std::memcpy(&by, WY + i, sizeof(float));
        std::memcpy(&bs, WSP + i, sizeof(float));
        mix(bx); mix(by); mix(bs);
    }
    return fp;
}

} // namespace pk
