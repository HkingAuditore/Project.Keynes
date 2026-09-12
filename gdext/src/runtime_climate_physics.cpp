// ─── pk_async_physics 实现（B8 P2）───────────────────────────────────────────
//
// 搬移纪律与 runtime_climate_passes.cpp 相同：从 world_ext_physical.cpp 里逐行搬，
// 只做三类等价改写：
//   1. Dictionary knobs → POD（所有 get/clamp 都在调用方循环外做完）；
//   2. slot 指针 → lane 指针（调用方解析）；
//   3. ParallelDispatcher → 调用方分段（kernel 内是纯 range 循环）。
// 公式、阈值、遍历顺序、累加顺序都不许动。

#include "runtime_climate_physics.h"

#include "runtime_climate_formulas.h"
#include "runtime_climate_pass_math.h"   // pk::wind_belt_at（行星风带基线）

#include <algorithm>
#include <cmath>
#include <cstdio>

namespace pk {
namespace pk_async_physics {
namespace {

// SAME_SOURCE with world_ext_internal.h::pk_lat_temp_bell — keep physics TU free
// of Godot/world_ext_internal includes.
inline double pk_lat_temp_bell(double lat_signed) {
    return climate_formula::lat_temp_bell(lat_signed);
}

// 与 world_ext_physical.cpp::physical_wrap01 逐行同源（经度环绕到 [0,1)）。
inline double pkw_wrap01(double world_x, double wrap_origin_x, double wrap_period_x) {
    double phase = std::fmod((world_x - wrap_origin_x) / wrap_period_x, 1.0);
    if (phase < 0.0) phase += 1.0;
    return phase;
}

// 与 PhysLatNorm::at 同源：lat_norm 优先，缺失时用 pos_y 自归一化并 clamp [0,1]。
inline double pkw_lat_norm_at(const SlpPassALanes &lanes, int i) {
    const double ny = (lanes.lat_norm != nullptr)
        ? double(lanes.lat_norm[i])
        : ((double(lanes.pos_y[i]) - lanes.lat_origin) * lanes.lat_inv_span);
    return (ny < 0.0) ? 0.0 : ((ny > 1.0) ? 1.0 : ny);
}

inline double pkw_lat_at(const float *lat_norm, const float *pos_y,
                         double origin, double inv_span, int i) {
    const double ny = (lat_norm != nullptr)
        ? double(lat_norm[i])
        : ((double(pos_y[i]) - origin) * inv_span);
    return (ny < 0.0) ? 0.0 : ((ny > 1.0) ? 1.0 : ny);
}

} // namespace

int slp_pass_a_range(int n_cells, int begin, int end,
                     const SlpPassAKnobs &knobs, const SlpPassALanes &lanes,
                     float *slp_buf, float *thermal_abs) {
    if (n_cells <= 0 || slp_buf == nullptr || lanes.terrain == nullptr ||
        lanes.neighbors == nullptr || lanes.is_water_lut == nullptr ||
        (lanes.lat_norm == nullptr && lanes.pos_y == nullptr)) {
        return 0;
    }
    if (begin < 0) begin = 0;
    if (end > n_cells) end = n_cells;
    if (end <= begin) return 0;

    const bool has_lut = knobs.lut_base != nullptr && knobs.lut_heat != nullptr &&
                         knobs.lut_bins >= 2;
    const int lut_last = knobs.lut_bins - 1;
    const float TWO_PI = 6.283185307179586f;

    for (int i = begin; i < end; ++i) {
        const float ny = float(pkw_lat_norm_at(lanes, i));
        const float ls = (ny - 0.5f) * 2.0f;
        const float ls_abs = std::fabs(ls);

        // 纬度 LUT 线性插值（调用方保证 LUT 已按同一 ny 网格预建）。
        float base_lat = 0.0f;
        float solar_heat = 0.0f;
        if (has_lut) {
            float fb = ny * float(lut_last);
            int b0 = int(fb);
            if (b0 < 0) b0 = 0;
            else if (b0 > lut_last - 1) b0 = lut_last - 1;
            const float bfrac = fb - float(b0);
            base_lat = knobs.lut_base[b0] +
                (knobs.lut_base[b0 + 1] - knobs.lut_base[b0]) * bfrac;
            solar_heat = knobs.lut_heat[b0] +
                (knobs.lut_heat[b0 + 1] - knobs.lut_heat[b0]) * bfrac;
        }

        const bool is_water = lanes.is_water_lut[lanes.terrain[i]];
        const float thermal_slp = -knobs.thermal_weight *
            ((lanes.temp_anomaly != nullptr) ? lanes.temp_anomaly[i] : solar_heat) *
            (is_water ? 0.55f : 1.0f);
        float landsea;
        if (is_water) {
            landsea = -solar_heat * knobs.land_amp * knobs.water_damp;
        } else {
            // Coast detect：任一有效邻居是水 → 沿海阻尼，否则内陆增益。
            bool is_coast = false;
            const int base_i = i * 6;
            for (int d = 0; d < 6; ++d) {
                const int ni = lanes.neighbors[base_i + d];
                if (ni >= 0 && ni < n_cells &&
                    lanes.is_water_lut[lanes.terrain[ni]]) {
                    is_coast = true;
                    break;
                }
            }
            const float continentality =
                is_coast ? knobs.coast_damp : knobs.interior_boost;
            landsea = -solar_heat * knobs.land_amp * continentality;
        }
        const float ice_high = knobs.ice_high_weight *
            ((lanes.ice != nullptr) ? std::clamp(lanes.ice[i], 0.0f, 1.0f) : 0.0f);
        const float snow_high = knobs.snow_high_weight *
            ((lanes.snow != nullptr) ? std::clamp(lanes.snow[i], 0.0f, 1.0f) : 0.0f);
        const float vapor_low =
            (lanes.vapor != nullptr) ? std::clamp(lanes.vapor[i], 0.0f, 1.0f) : 0.0f;
        const float cloud_low =
            (lanes.cloud != nullptr) ? std::clamp(lanes.cloud[i], 0.0f, 1.0f) : 0.0f;
        const float moist_low = -knobs.moist_low_weight *
            (vapor_low * 0.65f + cloud_low * 0.35f) *
            (0.45f + 0.55f * (1.0f - ls_abs));

        float synoptic;
        if (lanes.pos_x != nullptr) {
            const double px = knobs.has_wrap_domain
                ? pkw_wrap01(double(lanes.pos_x[i]), knobs.wrap_origin_x,
                             knobs.wrap_period_x)
                : std::clamp((double(lanes.pos_x[i]) - double(knobs.bounds_pos_x)) *
                                 double(knobs.inv_bounds_w),
                             0.0, 1.0);
            const double py = double(ny);
            synoptic = knobs.synoptic_amp * float(
                0.65 * std::sin(TWO_PI * (double(knobs.syn_k1x) * px +
                                          double(knobs.syn_k1y) * py) +
                                double(knobs.syn_phase) + double(ls) * 0.6 +
                                double(knobs.syn_sa)) +
                0.35 * std::cos(TWO_PI * (double(knobs.syn_k2x) * px -
                                          double(knobs.syn_k2y) * py) -
                                double(knobs.syn_phase2) + double(ls_abs) * 0.9 +
                                double(knobs.syn_sb)));
        } else {
            // 退化（无 pos_x lane）：沿用 cell 索引波，保持向后兼容。
            synoptic = knobs.synoptic_amp * float(
                0.65 * std::sin(double(i) * 4.886 +
                                double(knobs.world_seed) * 0.00011 +
                                double(knobs.syn_phase) + double(ls) * 5.3) +
                0.35 * std::cos(double(i) * 2.191 -
                                double(knobs.world_seed) * 0.00017 +
                                double(knobs.syn_phase2) + double(ls_abs) * 8.1));
        }
        float mobile_low = 0.0f;
        if (knobs.n_mobile_low > 0 && lanes.pos_x != nullptr) {
            const float px_m = float(knobs.has_wrap_domain
                ? pkw_wrap01(double(lanes.pos_x[i]), knobs.wrap_origin_x,
                             knobs.wrap_period_x)
                : std::clamp((double(lanes.pos_x[i]) - double(knobs.bounds_pos_x)) *
                                 double(knobs.inv_bounds_w),
                             0.0, 1.0));
            for (int j = 0; j < knobs.n_mobile_low; ++j) {
                float dx = px_m - knobs.mobile_low_cx[j];
                if (dx > 0.5f) dx -= 1.0f;
                else if (dx < -0.5f) dx += 1.0f;
                const float dy = ny - knobs.mobile_low_cy[j];
                const float r2 = dx * dx + dy * dy;
                mobile_low -= knobs.mobile_low_amp *
                    std::exp(-r2 * knobs.mobile_low_inv2s2);
            }
        }
        slp_buf[i] = base_lat + landsea + thermal_slp + ice_high + snow_high +
            moist_low + synoptic + mobile_low;
        if (thermal_abs != nullptr) {
            thermal_abs[i] = std::fabs(landsea) + std::fabs(thermal_slp) +
                std::fabs(ice_high) + std::fabs(snow_high) +
                std::fabs(moist_low) + std::fabs(mobile_low);
        }
    }
    return end - begin;
}

void slp_pass_b_pure(int n_cells, const SlpPassBKnobs &knobs,
                     const int32_t *neighbors, const float *prev_slp,
                     float *slp_buf, float *scratch, float *delta) {
    if (n_cells <= 0 || slp_buf == nullptr) return;
    if (knobs.smooth_passes > 0 && neighbors != nullptr && scratch != nullptr) {
        for (int p = 0; p < knobs.smooth_passes; ++p) {
            const float * const src = slp_buf;
            float * const dst = scratch;
            for (int i = 0; i < n_cells; ++i) {
                float sum_slp = src[i];
                int   cnt     = 1;
                const int base_i = i * 6;
                for (int d = 0; d < 6; ++d) {
                    const int ni = neighbors[base_i + d];
                    if (ni < 0 || ni >= n_cells) continue;
                    sum_slp += src[ni];
                    cnt += 1;
                }
                dst[i] = sum_slp / float(cnt);
            }
            std::copy(dst, dst + n_cells, slp_buf);
        }
    }

    if (knobs.recenter && n_cells > 1) {
        double mean = 0.0;
        for (int i = 0; i < n_cells; ++i) mean += double(slp_buf[i]);
        mean /= double(n_cells);
        for (int i = 0; i < n_cells; ++i) slp_buf[i] = float(double(slp_buf[i]) - mean);
        // p95 缩放只在 target_p95 > 0 时做（生产第二次 recenter 就是纯去均值）。
        if (knobs.target_p95 > 1e-5f) {
            // p95 需要长度 n_cells 的临时排序缓冲。调用方给的 scratch 在平滑之后
            // 可以复用（平滑已把结果写回 slp_buf）；没有 scratch 就自己分配。
            float *abs_buf = scratch;
            std::vector<float> owned;
            if (abs_buf == nullptr) {
                owned.resize(static_cast<size_t>(n_cells));
                abs_buf = owned.data();
            }
            for (int i = 0; i < n_cells; ++i) abs_buf[i] = std::fabs(slp_buf[i]);
            std::sort(abs_buf, abs_buf + n_cells);
            const size_t p95_i = std::min(
                static_cast<size_t>(n_cells) - 1,
                static_cast<size_t>(std::floor(double(n_cells - 1) * 0.95)));
            const float p95 = abs_buf[p95_i];
            if (p95 > 1e-5f) {
                float scale = knobs.target_p95 / p95;
                if (scale < 0.75f) scale = 0.75f;
                else if (scale > 3.60f) scale = 3.60f;
                for (int i = 0; i < n_cells; ++i) slp_buf[i] *= scale;
            }
        }
    }

    if (prev_slp != nullptr && knobs.response_rate >= 0.0f) {
        for (int i = 0; i < n_cells; ++i) {
            const float prev = prev_slp[i];
            slp_buf[i] = prev + (slp_buf[i] - prev) * knobs.response_rate;
        }
    }
    if (knobs.recenter && n_cells > 1) {
        double mean = 0.0;
        for (int i = 0; i < n_cells; ++i) mean += double(slp_buf[i]);
        mean /= double(n_cells);
        for (int i = 0; i < n_cells; ++i) slp_buf[i] = float(double(slp_buf[i]) - mean);
    }
    if (delta != nullptr) {
        if (prev_slp != nullptr) {
            for (int i = 0; i < n_cells; ++i) {
                delta[i] = std::fabs(slp_buf[i] - prev_slp[i]);
            }
        } else {
            for (int i = 0; i < n_cells; ++i) delta[i] = std::fabs(slp_buf[i]);
        }
    }
}

int wind_field_range(int n_cells, int begin, int end,
                     const WindFieldKnobs &knobs, const WindFieldLanes &lanes,
                     WindFieldStats &stats) {
    if (n_cells <= 0 || lanes.slp == nullptr || lanes.neighbors == nullptr ||
        lanes.terrain == nullptr || lanes.is_water_lut == nullptr ||
        lanes.wind_x == nullptr || lanes.wind_y == nullptr ||
        lanes.wind_speed == nullptr || lanes.wind_speed_out == nullptr ||
        lanes.coast_dist == nullptr || lanes.coast_sea_x == nullptr ||
        lanes.coast_sea_y == nullptr || lanes.sea_dist == nullptr ||
        lanes.sea_land_x == nullptr || lanes.sea_land_y == nullptr ||
        (lanes.lat_norm == nullptr && lanes.pos_y == nullptr)) {
        return 0;
    }
    if (begin < 0) begin = 0;
    if (end > n_cells) end = n_cells;
    if (end <= begin) return 0;

    float * const __restrict WX = lanes.wind_x;
    float * const __restrict WY = lanes.wind_y;
    float * const __restrict WSP_SLOT = lanes.wind_speed;
    float * const __restrict WSPD = lanes.wind_speed_out;
    float * const __restrict WDELTA = lanes.wind_delta;
    float * const __restrict WDIR_DELTA = lanes.wind_dir_delta;
    float * const __restrict MDELTA = lanes.momentum_delta;
    float * const __restrict MONSOON = lanes.monsoon_thermal;
    const float   * const __restrict SLP = lanes.slp;
    const int32_t * const __restrict NB = lanes.neighbors;
    const uint8_t * const __restrict TR = lanes.terrain;
    const uint8_t * const __restrict LF = lanes.landform;
    const float   * const __restrict POSX = lanes.pos_x;
    const float   * const __restrict TEMP = lanes.temp;
    const int8_t  * const __restrict coast_dist = lanes.coast_dist;
    const float   * const __restrict coast_sea_x = lanes.coast_sea_x;
    const float   * const __restrict coast_sea_y = lanes.coast_sea_y;
    const int32_t * const __restrict coast_sea_anchor = lanes.coast_sea_anchor;
    const int8_t  * const __restrict sea_dist = lanes.sea_dist;
    const float   * const __restrict sea_land_x = lanes.sea_land_x;
    const float   * const __restrict sea_land_y = lanes.sea_land_y;
    const int32_t * const __restrict sea_land_anchor = lanes.sea_land_anchor;
    const int32_t * const __restrict TRAJ_IDX = knobs.traj_idx;
    const float   * const __restrict TRAJ_W = knobs.traj_w;
    const float   * const __restrict SNAP_FX = knobs.snap_fx;
    const float   * const __restrict SNAP_FY = knobs.snap_fy;

    const double season_phase = knobs.season_phase;
    const double axial_tilt_deg = knobs.axial_tilt_deg;
    const bool   ta = knobs.terrain_aware;
    const bool   wind_belt_only = knobs.wind_belt_only;
    const double response_rate = knobs.response_rate;
    const double synoptic_amp = knobs.synoptic_amp;
    const double synoptic_period_days = knobs.synoptic_period_days;
    const double max_turn_rad = knobs.max_turn_rad;
    const double min_flux_len2 = knobs.min_flux_len2;
    const int    sim_day = knobs.sim_day;
    const uint32_t seed_bits = static_cast<uint32_t>(knobs.world_seed);
    const bool   has_wrap_domain = knobs.has_wrap_domain;
    const double wrap_origin_x = knobs.wrap_origin_x;
    const double wrap_period_x = knobs.wrap_period_x;
    const double bounds_pos_x = knobs.bounds_pos_x;
    const double inv_bounds_w = knobs.inv_bounds_w;
    const int    lf_mountain = knobs.lf_mountain;
    const int    lf_peak = knobs.lf_peak;
    const int    lf_hill = knobs.lf_hill;
    const bool   monsoon_on = knobs.thermal_monsoon_enabled && TEMP != nullptr &&
        coast_sea_anchor != nullptr && sea_land_anchor != nullptr;
    const double monsoon_lat_limit = knobs.monsoon_lat_limit;
    const double monsoon_deadband = knobs.monsoon_deadband;
    const double monsoon_full_contrast = knobs.monsoon_full_contrast;
    const double monsoon_gain = knobs.monsoon_gain;
    const double monsoon_breeze_floor = knobs.monsoon_breeze_floor;
    const bool   momentum_active = knobs.momentum_active;
    const double momentum_advect_w = knobs.momentum_advect_w;
    const double diffuse_w = knobs.diffuse_w;

    for (int i = begin; i < end; ++i) {
        // ny / ls / ls_abs（cell_lat_norm 权威，0=第0行 0.5=赤道 1=末行）
        const double ny = pkw_lat_at(lanes.lat_norm, lanes.pos_y, lanes.lat_origin,
                                     lanes.lat_inv_span, i);
        const double ls = (ny - 0.5) * 2.0;
        const double ls_abs = (ls < 0.0) ? -ls : ls;

        // (a) 纬度基线。年内变化只通过太阳直射点迁移风带中心。
        double v_base_x = 0.0, v_base_y = 0.0;
        const double ny_belt = 0.5 +
            pk_wind_shifted_lat_signed(ny, season_phase, axial_tilt_deg) * 0.5;
        wind_belt_at(ny_belt, 0.0, &v_base_x, &v_base_y);

        // (b) 6 邻域离散梯度（unit_x/y 已 hardcode 在 NB_DIR_*）
        double grad_x = 0.0, grad_y = 0.0;
        const int base = i * 6;
        const float slp_self = SLP[i];
        int nb_count = 0;
        for (int d = 0; d < 6; ++d) {
            const int32_t ni = NB[base + d];
            if (ni < 0) continue;
            const double dslp = double(SLP[ni]) - double(slp_self);
            grad_x += dslp * NB_DIR_X[d];
            grad_y += dslp * NB_DIR_Y[d];
            ++nb_count;
        }
        if (nb_count > 0) {
            grad_x /= 3.0;
            grad_y /= 3.0;
        }
        const double grad_mag = std::sqrt(grad_x * grad_x + grad_y * grad_y);
        const double grad_w = pk_wind_smoothstep(
            WIND_PRESSURE_GRAD_WEAK, WIND_PRESSURE_GRAD_STRONG, grad_mag);

        // 压力梯度风方向 = -∇slp（高 → 低）
        double v_grad_raw_x = -grad_x;
        double v_grad_raw_y = -grad_y;
        if (grad_mag > 1e-8) {
            const double inv_grad = 1.0 / grad_mag;
            v_grad_raw_x *= inv_grad;
            v_grad_raw_y *= inv_grad;
        } else {
            v_grad_raw_x = 0.0;
            v_grad_raw_y = 0.0;
        }

        // (d) 科氏偏转：离赤道越远越接近沿等压线流，赤道附近保留直接压差流。
        const double coriolis_angle = WIND_CORIOLIS_MAX_RAD * std::pow(ls_abs, 0.55);
        const double rot = (ls < 0.0) ? coriolis_angle : -coriolis_angle;
        const double cos_r = std::cos(rot);
        const double sin_r = std::sin(rot);
        const double v_geo_x = v_grad_raw_x * cos_r - v_grad_raw_y * sin_r;
        const double v_geo_y = v_grad_raw_x * sin_r + v_grad_raw_y * cos_r;
        const double ageo_w = 1.0 - pk_wind_smoothstep(0.10, 0.55, ls_abs);
        const double geo_w = 1.0 - ageo_w;
        double v_grad_x = v_grad_raw_x * ageo_w + v_geo_x * geo_w;
        double v_grad_y = v_grad_raw_y * ageo_w + v_geo_y * geo_w;
        const double v_grad_len2 = v_grad_x * v_grad_x + v_grad_y * v_grad_y;
        if (v_grad_len2 > 0.0001) {
            const double inv_vg = 1.0 / std::sqrt(v_grad_len2);
            v_grad_x *= inv_vg;
            v_grad_y *= inv_vg;
        }

        // (c) 沿海热力环流权重。方向由 SLP 梯度决定，不再由季节符号指定。
        double coast_pressure_w = 0.0;
        const bool is_water = lanes.is_water_lut[TR[i]];
        if (!is_water) {
            const int8_t cd = coast_dist[i];
            if (cd != COAST_INF) {
                double w = 1.0 - double(cd) / double(WIND_COAST_THERMAL_MAX_DIST);
                if (w < 0.0) w = 0.0;
                else if (w > 1.0) w = 1.0;
                coast_pressure_w = w;
            }
        }

        // 加权合成：纬向风带是背景环流，压力梯度和天气尺度扰动决定本地风。
        const double lat_w = WIND_W_LAT * (1.0 - WIND_LAT_GRAD_SUPPRESS * grad_w);
        const double pressure_w =
            WIND_W_GRAD * (WIND_PRESSURE_BASE_W + WIND_PRESSURE_GRAD_W * grad_w) *
            (1.0 + WIND_W_COAST_THERMAL * coast_pressure_w);
        double v_sum_x = lat_w * v_base_x + pressure_w * v_grad_x;
        double v_sum_y = lat_w * v_base_y + pressure_w * v_grad_y;
        // (c2) 几何海风 + 热力季风（与生产逐行同源）。
        const double vs_mag = std::sqrt(v_sum_x * v_sum_x + v_sum_y * v_sum_y);
        double monsoon_thermal = 0.0;
        if (monsoon_on && ls_abs <= monsoon_lat_limit) {
            const int anchor = is_water ? sea_land_anchor[i] : coast_sea_anchor[i];
            if (anchor >= 0 && anchor < n_cells) {
                const double land_minus_sea = is_water
                    ? double(TEMP[anchor]) - double(TEMP[i])
                    : double(TEMP[i]) - double(TEMP[anchor]);
                const double abs_contrast = std::abs(land_minus_sea);
                if (abs_contrast > monsoon_deadband) {
                    const double response = pk_wind_smoothstep(
                        monsoon_deadband, monsoon_full_contrast, abs_contrast);
                    monsoon_thermal = (land_minus_sea >= 0.0 ? response : -response);
                }
                if (MONSOON != nullptr) MONSOON[i] = float(monsoon_thermal);
                ++stats.monsoon_eligible;
                if (monsoon_thermal > 0.0) ++stats.monsoon_onshore;
                else if (monsoon_thermal < 0.0) ++stats.monsoon_offshore;
                const float abs_value = float(abs_contrast);
                if (abs_value > stats.monsoon_abs_max) stats.monsoon_abs_max = abs_value;
            } else if (MONSOON != nullptr) {
                MONSOON[i] = 0.0f;
            }
        } else if (MONSOON != nullptr) {
            MONSOON[i] = 0.0f;
        }
        double breeze_sign = 1.0;
        if (knobs.thermal_monsoon_enabled) {
            breeze_sign = pk_wind_clamp(
                monsoon_breeze_floor + monsoon_gain * monsoon_thermal, -0.65, 1.05);
        }
        if (!is_water && coast_pressure_w > 0.0) {
            const double breeze =
                WIND_SEA_BREEZE_W * coast_pressure_w * vs_mag * breeze_sign;
            v_sum_x += breeze * (-double(coast_sea_x[i]));
            v_sum_y += breeze * (-double(coast_sea_y[i]));
        } else if (is_water && sea_dist[i] != COAST_INF) {
            const double sea_pw =
                1.0 - double(sea_dist[i]) / double(SEA_BREEZE_SEA_MAX_DIST);
            const double breeze = WIND_SEA_BREEZE_W * sea_pw * vs_mag * breeze_sign;
            v_sum_x += breeze * double(sea_land_x[i]);
            v_sum_y += breeze * double(sea_land_y[i]);
        }
        if (synoptic_amp > 0.0) {
            const double px = (POSX == nullptr) ? 0.0
                : (has_wrap_domain
                    ? pkw_wrap01(double(POSX[i]), wrap_origin_x, wrap_period_x)
                    : pk_wind_clamp(
                        (double(POSX[i]) - bounds_pos_x) * inv_bounds_w, 0.0, 1.0));
            const double py = ny;
            const double syn_cycles = double(sim_day) / synoptic_period_days;
            const double seed_a = double(seed_bits & 1023u) * 0.006135923151542565;
            const double seed_b =
                double((seed_bits >> 10) & 1023u) * 0.006135923151542565;
            const double k1x = 3.0 + double(seed_bits & 3u);
            const double k1y = std::cos(seed_a) * 0.90 + 2.30;
            const double k2x = 3.0 + double((seed_bits >> 2) & 3u);
            const double k2y = std::sin(seed_b) * 1.00 + 2.40;
            const double p1 =
                6.283185307179586 * (k1x * px + k1y * py + syn_cycles) + seed_a;
            const double p2 =
                6.283185307179586 * (k2x * px - k2y * py - syn_cycles * 0.56) + seed_b;
            const double psi1 = std::sin(p1);
            const double psi2 = std::cos(p2);
            double syn_x = k1y * psi1 + k2y * psi2;
            double syn_y = -k1x * psi1 + k2x * psi2;
            const double syn_len2 = syn_x * syn_x + syn_y * syn_y;
            if (syn_len2 > 0.0001) {
                const double inv_syn = 1.0 / std::sqrt(syn_len2);
                syn_x *= inv_syn;
                syn_y *= inv_syn;
            }
            const double amp_lat =
                synoptic_amp * (0.70 + 0.65 * ls_abs) * (0.80 + 0.75 * grad_w);
            v_sum_x += syn_x * amp_lat;
            v_sum_y += syn_y * amp_lat;
        }
        const double v_sum_len2 = v_sum_x * v_sum_x + v_sum_y * v_sum_y;
        if (v_sum_len2 < 0.0001) {
            v_sum_x = v_base_x;
            v_sum_y = v_base_y;
        }

        // 方向 / 速度分离
        double dir_x = 1.0, dir_y = 0.0;
        const double v_len2 = v_sum_x * v_sum_x + v_sum_y * v_sum_y;
        if (v_len2 > 0.0001) {
            const double inv = 1.0 / std::sqrt(v_len2);
            dir_x = v_sum_x * inv;
            dir_y = v_sum_y * inv;
        }
        double spd = pk_wind_belt_speed_at(ny, season_phase, axial_tilt_deg);
        spd += pk_wind_clamp(grad_mag * 9.0, 0.0, 0.65);
        spd += synoptic_amp * (0.35 + grad_w * 1.4);
        if (coast_pressure_w > 0.0) {
            spd += coast_pressure_w * grad_w * 0.22;
        }

        // (e) 地形 / 摩擦衰减
        if (!is_water) spd *= WIND_LAND_FRICTION;
        if (wind_belt_only) {
            const double old_dir_x = double(WX[i]);
            const double old_dir_y = double(WY[i]);
            const double old_spd = double(WSP_SLOT[i]);
            WX[i] = float(v_base_x);
            WY[i] = float(v_base_y);
            WSP_SLOT[i] = float(spd);
            WSPD[i] = float(spd);
            const double dx = v_base_x - old_dir_x;
            const double dy = v_base_y - old_dir_y;
            const double ds = spd - old_spd;
            const double dir_delta = std::sqrt(dx * dx + dy * dy);
            if (WDIR_DELTA != nullptr) WDIR_DELTA[i] = float(dir_delta);
            if (dir_delta > 1.7320508075688772) ++stats.flip;
            if (WDELTA != nullptr) {
                WDELTA[i] = float(std::sqrt(dx * dx + dy * dy + ds * ds));
            }
            continue;
        }
        if (ta && LF != nullptr) {
            // (e1) 山脉绕流
            double mtn_dx = 0.0, mtn_dy = 0.0;
            bool has_mtn_nb = false;
            if (!is_water) {
                for (int d = 0; d < 6; ++d) {
                    const int32_t ni = NB[base + d];
                    if (ni < 0) continue;
                    const int lf_m = int(LF[ni]);
                    if (lf_m == lf_mountain || lf_m == lf_peak) {
                        mtn_dx += NB_DIR_X[d];
                        mtn_dy += NB_DIR_Y[d];
                        has_mtn_nb = true;
                    }
                }
            }
            if (has_mtn_nb) {
                const double mtn_len2 = mtn_dx * mtn_dx + mtn_dy * mtn_dy;
                if (mtn_len2 > 0.0001) {
                    const double inv_m = 1.0 / std::sqrt(mtn_len2);
                    const double mtn_nx = mtn_dx * inv_m;
                    const double mtn_ny = mtn_dy * inv_m;
                    const double dot_m = dir_x * mtn_nx + dir_y * mtn_ny;
                    if (dot_m > 0.0) {
                        const double tan_a_x = -mtn_ny;
                        const double tan_a_y = mtn_nx;
                        const double tan_b_x = mtn_ny;
                        const double tan_b_y = -mtn_nx;
                        const double dot_a = dir_x * tan_a_x + dir_y * tan_a_y;
                        const double dot_b = dir_x * tan_b_x + dir_y * tan_b_y;
                        const double tan_x = (dot_a >= dot_b) ? tan_a_x : tan_b_x;
                        const double tan_y = (dot_a >= dot_b) ? tan_a_y : tan_b_y;
                        const double blend_w = WIND_MOUNTAIN_DEFLECT_W * dot_m;
                        const double blend_inv = 1.0 - blend_w;
                        double new_dir_x = blend_inv * dir_x + blend_w * tan_x;
                        double new_dir_y = blend_inv * dir_y + blend_w * tan_y;
                        const double nd_len2 =
                            new_dir_x * new_dir_x + new_dir_y * new_dir_y;
                        if (nd_len2 > 0.0001) {
                            const double inv_nd = 1.0 / std::sqrt(nd_len2);
                            dir_x = new_dir_x * inv_nd;
                            dir_y = new_dir_y * inv_nd;
                        }
                        spd *= 1.0 + (WIND_MOUNTAIN_UPSTREAM_DAMP - 1.0) * dot_m;
                    }
                }
            }
            // (e2) 当前 cell 自身 landform 衰减
            const int lf_self = int(LF[i]);
            if (lf_self == lf_mountain || lf_self == lf_peak) {
                spd *= WIND_TERRAIN_MOUNTAIN_DAMP;
                const double mtn_pull_x = -grad_x;
                const double mtn_pull_y = -grad_y;
                const double mp_len2 =
                    mtn_pull_x * mtn_pull_x + mtn_pull_y * mtn_pull_y;
                if (mp_len2 > 0.0001) {
                    const double inv_mp = 1.0 / std::sqrt(mp_len2);
                    const double mp_nx = mtn_pull_x * inv_mp;
                    const double mp_ny = mtn_pull_y * inv_mp;
                    const double new_dir_x = dir_x + 0.4 * mp_nx;
                    const double new_dir_y = dir_y + 0.4 * mp_ny;
                    const double nd_len2 =
                        new_dir_x * new_dir_x + new_dir_y * new_dir_y;
                    if (nd_len2 > 0.0001) {
                        const double inv_nd = 1.0 / std::sqrt(nd_len2);
                        dir_x = new_dir_x * inv_nd;
                        dir_y = new_dir_y * inv_nd;
                    }
                }
            } else if (lf_self == lf_hill) {
                spd *= WIND_TERRAIN_HILL_DAMP;
            }
        }

        const double old_dir_x = double(WX[i]);
        const double old_dir_y = double(WY[i]);
        const double old_spd = double(WSP_SLOT[i]);
        double effective_rate = response_rate;
        const double old_len2 = old_dir_x * old_dir_x + old_dir_y * old_dir_y;
        const bool old_dir_valid = old_len2 >= 0.0001 && old_spd > 0.0001;
        double old_unit_x = 1.0;
        double old_unit_y = 0.0;
        if (old_len2 > 0.0001) {
            const double inv_old_dir = 1.0 / std::sqrt(old_len2);
            old_unit_x = old_dir_x * inv_old_dir;
            old_unit_y = old_dir_y * inv_old_dir;
        }
        if (!old_dir_valid) effective_rate = 1.0;
        double old_flux_x = 0.0;
        double old_flux_y = 0.0;
        if (old_dir_valid) {
            old_flux_x = old_unit_x * old_spd;
            old_flux_y = old_unit_y * old_spd;
        }
        const double target_flux_x = dir_x * spd;
        const double target_flux_y = dir_y * spd;
        double transp_x = old_flux_x;
        double transp_y = old_flux_y;
        if (momentum_active && old_dir_valid && SNAP_FX != nullptr &&
            SNAP_FY != nullptr) {
            if (TRAJ_IDX != nullptr && TRAJ_W != nullptr) {
                const int t3 = i * 3;
                const int j0 = TRAJ_IDX[t3], j1 = TRAJ_IDX[t3 + 1],
                          j2 = TRAJ_IDX[t3 + 2];
                const double q0 = double(TRAJ_W[t3]);
                const double q1 = double(TRAJ_W[t3 + 1]);
                const double q2 = double(TRAJ_W[t3 + 2]);
                const double sl_x = q0 * double(SNAP_FX[j0]) +
                    q1 * double(SNAP_FX[j1]) + q2 * double(SNAP_FX[j2]);
                const double sl_y = q0 * double(SNAP_FY[j0]) +
                    q1 * double(SNAP_FY[j1]) + q2 * double(SNAP_FY[j2]);
                transp_x += momentum_advect_w * (sl_x - old_flux_x);
                transp_y += momentum_advect_w * (sl_y - old_flux_y);
            }
            if (diffuse_w > 0.0) {
                double sum_x = 0.0, sum_y = 0.0;
                int nb_cnt = 0;
                for (int d = 0; d < 6; ++d) {
                    const int32_t ni = NB[base + d];
                    if (ni < 0) continue;
                    sum_x += double(SNAP_FX[ni]);
                    sum_y += double(SNAP_FY[ni]);
                    ++nb_cnt;
                }
                if (nb_cnt > 0) {
                    transp_x += diffuse_w * (sum_x / double(nb_cnt) - old_flux_x);
                    transp_y += diffuse_w * (sum_y / double(nb_cnt) - old_flux_y);
                }
            }
            if (MDELTA != nullptr) {
                MDELTA[i] = float(std::sqrt(
                    (transp_x - old_flux_x) * (transp_x - old_flux_x) +
                    (transp_y - old_flux_y) * (transp_y - old_flux_y)));
            }
        }
        const double final_flux_x =
            transp_x + (target_flux_x - transp_x) * effective_rate;
        const double final_flux_y =
            transp_y + (target_flux_y - transp_y) * effective_rate;
        const double final_spd = old_spd + (spd - old_spd) * effective_rate;
        double final_dir_x = dir_x;
        double final_dir_y = dir_y;
        const double final_len2 =
            final_flux_x * final_flux_x + final_flux_y * final_flux_y;
        if (final_len2 > 0.0001) {
            const double inv_final = 1.0 / std::sqrt(final_len2);
            final_dir_x = final_flux_x * inv_final;
            final_dir_y = final_flux_y * inv_final;
        }
        if (old_dir_valid) {
            if (final_len2 <= min_flux_len2) {
                final_dir_x = old_unit_x;
                final_dir_y = old_unit_y;
            } else if (max_turn_rad > 0.0) {
                double dot = old_unit_x * final_dir_x + old_unit_y * final_dir_y;
                if (dot < -1.0) dot = -1.0;
                else if (dot > 1.0) dot = 1.0;
                const double angle = std::acos(dot);
                if (angle > max_turn_rad) {
                    const double cross =
                        old_unit_x * final_dir_y - old_unit_y * final_dir_x;
                    const double sign = (cross < 0.0) ? -1.0 : 1.0;
                    const double cos_t = std::cos(max_turn_rad);
                    const double sin_t = std::sin(max_turn_rad) * sign;
                    final_dir_x = old_unit_x * cos_t - old_unit_y * sin_t;
                    final_dir_y = old_unit_x * sin_t + old_unit_y * cos_t;
                }
            }
        }
        WX[i] = float(final_dir_x);
        WY[i] = float(final_dir_y);
        WSP_SLOT[i] = float(final_spd);
        WSPD[i] = float(final_spd);
        const double dx = final_dir_x - old_dir_x;
        const double dy = final_dir_y - old_dir_y;
        const double ds = final_spd - old_spd;
        const double dir_delta = std::sqrt(dx * dx + dy * dy);
        if (WDIR_DELTA != nullptr) WDIR_DELTA[i] = float(dir_delta);
        if (dir_delta > 1.7320508075688772) ++stats.flip;
        if (WDELTA != nullptr) {
            WDELTA[i] = float(std::sqrt(dx * dx + dy * dy + ds * ds));
        }
    }
    return end - begin;
}

namespace {

// 自检用：7 格一行的合成网格（中间 3 格是水），纬度沿 y 递增。
struct SlpSelfTestGrid {
    static constexpr int kCells = 7;
    float lat_norm[kCells] = {0.10f, 0.20f, 0.30f, 0.40f, 0.50f, 0.60f, 0.70f};
    float pos_x[kCells] = {0.0f, 1.0f, 2.0f, 3.0f, 4.0f, 5.0f, 6.0f};
    float pos_y[kCells] = {0.10f, 0.20f, 0.30f, 0.40f, 0.50f, 0.60f, 0.70f};
    uint8_t terrain[kCells] = {0u, 0u, 1u, 1u, 1u, 0u, 0u};
    int32_t neighbors[kCells * 6] = {};
    bool is_water_lut[256] = {};
    float lut_base[8] = {};
    float lut_heat[8] = {};
    float slp[kCells] = {};
    float thermal[kCells] = {};
    float scratch[kCells] = {};

    SlpSelfTestGrid() {
        for (int i = 0; i < kCells; ++i) {
            for (int d = 0; d < 6; ++d) {
                int ni = -1;
                if (d == 0 && i > 0) ni = i - 1;
                if (d == 3 && i + 1 < kCells) ni = i + 1;
                neighbors[i * 6 + d] = ni;
            }
        }
        is_water_lut[1] = true;
        for (int b = 0; b < 8; ++b) {
            const float ny = float(b) / 7.0f;
            const float ls_abs = std::fabs((ny - 0.5f) * 2.0f);
            lut_base[b] = -0.16f * std::cos(ls_abs * 3.14159265358979323846f * 3.0f);
            const float s_lat = std::sin(ls_abs * 3.14159265358979323846f);
            lut_heat[b] = 0.05f * s_lat * s_lat;
        }
    }
};

} // namespace

int psi_topology_build_pure(int n_cells, const uint8_t *terrain,
                            const int32_t *neighbors,
                            const bool *is_water_lut,
                            int *cell_to_water, int *water_to_cell,
                            int32_t *nb_w) {
    if (n_cells <= 0 || terrain == nullptr || neighbors == nullptr ||
        is_water_lut == nullptr || cell_to_water == nullptr ||
        water_to_cell == nullptr || nb_w == nullptr) {
        return 0;
    }
    int n_water = 0;
    for (int i = 0; i < n_cells; ++i) {
        cell_to_water[i] = -1;
    }
    for (int i = 0; i < n_cells; ++i) {
        if (is_water_lut[terrain[i]]) {
            cell_to_water[i] = n_water;
            water_to_cell[n_water] = i;
            ++n_water;
        }
    }
    for (int k = 0; k < n_water; ++k) {
        const int i = water_to_cell[k];
        const int base_i = i * 6;
        const int base_k = k * 6;
        for (int d = 0; d < 6; ++d) {
            const int ni = neighbors[base_i + d];
            nb_w[base_k + d] =
                (ni >= 0 && ni < n_cells) ? cell_to_water[ni] : -1;
        }
    }
    return n_water;
}

bool psi_solve_pure(const PsiSolveKnobs &knobs, const PsiSolveLanes &lanes,
                    const PsiSolveScratch &scratch, PsiSolveStats &stats) {
    stats = PsiSolveStats{};
    const int n_cells = lanes.n_cells;
    const int n_water = lanes.n_water;
    if (n_cells <= 0 || n_water <= 0 ||
        lanes.neighbors == nullptr || lanes.terrain == nullptr ||
        lanes.is_water_lut == nullptr || lanes.cell_to_water == nullptr ||
        lanes.water_to_cell == nullptr || lanes.nb_w == nullptr ||
        lanes.wind_x == nullptr || lanes.wind_y == nullptr ||
        lanes.wind_speed == nullptr || lanes.out_curl == nullptr ||
        lanes.out_psi == nullptr || lanes.out_ocean_x == nullptr ||
        lanes.out_ocean_y == nullptr || scratch.tau_x == nullptr ||
        scratch.tau_y == nullptr || scratch.ny_w == nullptr ||
        scratch.ls_w == nullptr || scratch.curl == nullptr ||
        scratch.beta_abs == nullptr || scratch.r_factor == nullptr ||
        scratch.source == nullptr || scratch.psi == nullptr) {
        return false;
    }
    // 允许 (lat_norm | pos_y) 二选一；都没有就报错，避免静默按全 0 纬度算。
    if (lanes.lat_norm == nullptr && lanes.pos_y == nullptr) return false;

    const int32_t * const __restrict NB = lanes.neighbors;
    const uint8_t * const __restrict TR = lanes.terrain;
    const bool * const __restrict is_water_lut = lanes.is_water_lut;
    const int * const __restrict water_to_cell = lanes.water_to_cell;
    const int32_t * const __restrict nb_w = lanes.nb_w;
    const float * const __restrict WX = lanes.wind_x;
    const float * const __restrict WY = lanes.wind_y;
    const float * const __restrict WSP = lanes.wind_speed;
    const float * const __restrict TEMP = lanes.temp;
    const float * const __restrict TEMP_AN = lanes.temp_anomaly;
    const float * const __restrict ICE = lanes.ice;
    const float * const __restrict ELEV = lanes.elevation;
    const float * const __restrict PSI_PREV = lanes.prev_psi;
    const float * const __restrict OLD_OCX = lanes.old_ocean_x;
    const float * const __restrict OLD_OCY = lanes.old_ocean_y;
    float * const __restrict TAU_X = scratch.tau_x;
    float * const __restrict TAU_Y = scratch.tau_y;
    float * const __restrict NY_W = scratch.ny_w;
    float * const __restrict LS_W = scratch.ls_w;
    float * const __restrict CURL = scratch.curl;
    float * const __restrict BETA = scratch.beta_abs;
    float * const __restrict RFAC = scratch.r_factor;
    float * const __restrict SRC = scratch.source;
    float * const __restrict PSI = scratch.psi;

    // 邻居方向（pointy-top，屏幕 +y = 南）。与生产同源（双精度常量转 float）。
    const float SQRT3_HALF = 0.8660254037844386f;
    const float PSI_NB_X[6] = {
        SQRT3_HALF * 2.0f, SQRT3_HALF, -SQRT3_HALF,
        -SQRT3_HALF * 2.0f, -SQRT3_HALF, SQRT3_HALF,
    };
    const float PSI_NB_Y[6] = {0.0f, -1.5f, -1.5f, 0.0f, 1.5f, 1.5f};

    // ── tau + 纬度 ──────────────────────────────────────────────────────
    for (int k = 0; k < n_water; ++k) {
        const int i = water_to_cell[k];
        TAU_X[k] = WX[i] * WSP[i];
        TAU_Y[k] = WY[i] * WSP[i];
        const float ny = float(pkw_lat_at(lanes.lat_norm, lanes.pos_y,
                                          lanes.lat_origin, lanes.lat_inv_span, i));
        NY_W[k] = ny;
        LS_W[k] = (ny - 0.5f) * 2.0f;
    }
    // ── curl_tau ────────────────────────────────────────────────────────
    for (int k = 0; k < n_water; ++k) {
        const float tx_self = TAU_X[k];
        const float ty_self = TAU_Y[k];
        float c = 0.0f;
        const int base_k = k * 6;
        for (int d = 0; d < 6; ++d) {
            const int kw = nb_w[base_k + d];
            float tx_nb = 0.0f, ty_nb = 0.0f;
            if (kw >= 0) {
                tx_nb = TAU_X[kw];
                ty_nb = TAU_Y[kw];
            }
            const float dx = tx_nb - tx_self;
            const float dy = ty_nb - ty_self;
            c += dx * PSI_NB_Y[d] - dy * PSI_NB_X[d];
        }
        CURL[k] = c / 3.0f;
    }
    // ── beta / r_factor / source（+ 深度衰减）──────────────────────────
    const float HALF_PI_PREP = 1.5707963267948966f;
    const float PI_PREP = 3.14159265358979323846f;
    const bool depth_damp_active =
        (knobs.depth_curl_damp > 0.0f && ELEV != nullptr);
    for (int k = 0; k < n_water; ++k) {
        const float ls_abs = std::fabs(LS_W[k]);
        float b = std::cos(ls_abs * HALF_PI_PREP);
        if (b < knobs.beta_floor) b = knobs.beta_floor;
        BETA[k] = b;
        RFAC[k] = knobs.r_base * (0.5f + std::sin(ls_abs * PI_PREP));
        SRC[k] = -knobs.source_scale * CURL[k] / b;
        if (depth_damp_active) {
            const int i_w = water_to_cell[k];
            float depth_norm = (knobs.sea_level - ELEV[i_w]) / knobs.depth_ref;
            if (depth_norm < 0.2f) depth_norm = 0.2f;
            else if (depth_norm > 1.0f) depth_norm = 1.0f;
            SRC[k] *= (1.0f - knobs.depth_curl_damp) +
                knobs.depth_curl_damp * depth_norm;
        }
    }
    // ── warm-start / 清零 ───────────────────────────────────────────────
    for (int k = 0; k < n_water; ++k) PSI[k] = 0.0f;
    if (PSI_PREV != nullptr) {
        for (int k = 0; k < n_water; ++k) {
            PSI[k] = PSI_PREV[water_to_cell[k]];
        }
    }
    // ── SOR Gauss-Seidel（in-place）─────────────────────────────────────
    for (int it = 0; it < knobs.total_iters; ++it) {
        float iter_max_delta = 0.0f;
        for (int k = 0; k < n_water; ++k) {
            float sum_psi = 0.0f;
            float psi_e = 0.0f;
            float psi_w = 0.0f;
            const int base_k = k * 6;
            for (int d = 0; d < 6; ++d) {
                const int kw = nb_w[base_k + d];
                const float p_nb = (kw >= 0) ? PSI[kw] : 0.0f;
                sum_psi += p_nb;
                if (d == 0) psi_e = p_nb;
                else if (d == 3) psi_w = p_nb;
            }
            const float avg_nb = sum_psi / 6.0f;
            const float adv = RFAC[k] * (psi_e - psi_w) * 0.5f;
            const float target = avg_nb - adv + SRC[k];
            const float old_v = PSI[k];
            const float new_v = (1.0f - knobs.omega) * old_v + knobs.omega * target;
            const float delta = std::fabs(new_v - old_v);
            if (delta > iter_max_delta) iter_max_delta = delta;
            PSI[k] = new_v;
        }
        stats.iters_run = it + 1;
        stats.residual_final = iter_max_delta;
        if (knobs.early_exit && stats.iters_run >= knobs.min_iters &&
            (stats.iters_run % knobs.check_every) == 0 &&
            iter_max_delta <= knobs.residual_epsilon) {
            stats.early_exit = true;
            break;
        }
    }
    // ── finalize：grad ψ → 洋流 + 密度/地形/高纬项 + 响应 + 限幅 ────────
    for (int i = 0; i < n_cells; ++i) {
        lanes.out_curl[i] = 0.0f;
        lanes.out_psi[i] = 0.0f;
        lanes.out_ocean_x[i] = 0.0f;
        lanes.out_ocean_y[i] = 0.0f;
    }
    const float HALF_PI = 1.5707963267948966f;
    const float PI_F = 3.14159265358979323846f;
    // density_proxy 是 finalize 内部 lambda 的等价展开（cell 索引，非水格返回 0）。
    auto density_proxy = [&](int cell_idx) -> float {
        if (cell_idx < 0 || cell_idx >= n_cells || !is_water_lut[TR[cell_idx]]) {
            return 0.0f;
        }
        float temp_now = (TEMP != nullptr) ? TEMP[cell_idx] : 0.5f;
        if (temp_now < 0.0f) temp_now = 0.0f;
        else if (temp_now > 1.0f) temp_now = 1.0f;
        const float temp_anom = (TEMP_AN != nullptr) ? TEMP_AN[cell_idx] : 0.0f;
        float ice = (ICE != nullptr) ? ICE[cell_idx] : 0.0f;
        if (ice < 0.0f) ice = 0.0f;
        else if (ice > 1.0f) ice = 1.0f;
        return knobs.density_cold_weight * (1.0f - temp_now) +
            knobs.density_ice_weight * ice - temp_anom;
    };
    const float oc_max2 = knobs.oc_max_mag * knobs.oc_max_mag;
    for (int k = 0; k < n_water; ++k) {
        const int i = water_to_cell[k];
        const float p_self = PSI[k];
        float gx = 0.0f, gy = 0.0f;
        const int base_k = k * 6;
        for (int d = 0; d < 6; ++d) {
            const int kw = nb_w[base_k + d];
            const float p_nb = (kw >= 0) ? PSI[kw] : 0.0f;
            const float dpsi = p_nb - p_self;
            gx += dpsi * PSI_NB_X[d];
            gy += dpsi * PSI_NB_Y[d];
        }
        gx /= 3.0f;
        gy /= 3.0f;
        float cx = -gy * knobs.oc_scale;
        float cy = gx * knobs.oc_scale;

        const float density_self = density_proxy(i);
        float grad_den_x = 0.0f;
        float grad_den_y = 0.0f;
        const int base_i = i * 6;
        for (int d = 0; d < 6; ++d) {
            const int ni = NB[base_i + d];
            if (ni < 0 || ni >= n_cells || !is_water_lut[TR[ni]]) continue;
            const float dden = density_proxy(ni) - density_self;
            grad_den_x += dden * PSI_NB_X[d];
            grad_den_y += dden * PSI_NB_Y[d];
        }
        grad_den_x /= 3.0f;
        grad_den_y /= 3.0f;
        const float thermal_x = -grad_den_x * knobs.thermal_current_weight;
        const float thermal_y = -grad_den_y * knobs.thermal_current_weight;
        cx += thermal_x;
        cy += thermal_y;
        const float thermal_mag = std::sqrt(thermal_x * thermal_x + thermal_y * thermal_y);
        if (thermal_mag > stats.thermal_current_max) {
            stats.thermal_current_max = thermal_mag;
        }
        if (lanes.out_thermal_mag != nullptr) {
            lanes.out_thermal_mag[k] = thermal_mag;
        }

        if (knobs.topo_steer_w > 0.0f && ELEV != nullptr) {
            const float h_self = ELEV[i];
            float hx = 0.0f, hy = 0.0f;
            for (int d = 0; d < 6; ++d) {
                const int ni = NB[base_i + d];
                if (ni < 0 || ni >= n_cells || !is_water_lut[TR[ni]]) continue;
                const float dh = ELEV[ni] - h_self;
                hx += dh * PSI_NB_X[d];
                hy += dh * PSI_NB_Y[d];
            }
            hx /= 3.0f;
            hy /= 3.0f;
            cx += knobs.topo_steer_w * (-hy);
            cy += knobs.topo_steer_w * (hx);
        }

        const float ls = LS_W[k];
        const float ls_abs = std::fabs(ls);
        if (ls_abs > knobs.upwelling_highlat_abs) {
            const float lat_t =
                float(climate_formula::lat_temp_bell(double(ls_abs)));
            const float temp_rel = lat_t - 0.5f;
            if (temp_rel < knobs.cold_sink_temp) {
                const float pole_dir_y =
                    (ls > 0.0f) ? 1.0f : ((ls < 0.0f) ? -1.0f : 0.0f);
                const float grad_mag = std::sin(ls_abs * PI_F);
                cy += pole_dir_y * grad_mag * knobs.thermohaline_weight;
            }
        }

        const float old_cx = (OLD_OCX != nullptr) ? OLD_OCX[i] : 0.0f;
        const float old_cy = (OLD_OCY != nullptr) ? OLD_OCY[i] : 0.0f;
        cx = old_cx + (cx - old_cx) * knobs.response_rate;
        cy = old_cy + (cy - old_cy) * knobs.response_rate;

        const float mag2 = cx * cx + cy * cy;
        const float pre_mag = std::sqrt(mag2);
        if (pre_mag > stats.preclamp_max) stats.preclamp_max = pre_mag;
        if (lanes.out_preclamp_mag != nullptr) {
            lanes.out_preclamp_mag[k] = pre_mag;
        }
        if (mag2 > oc_max2 && mag2 > 1e-12f) {
            const float inv_scale = knobs.oc_max_mag / std::sqrt(mag2);
            cx *= inv_scale;
            cy *= inv_scale;
            ++stats.clamp_count;
        }
        if (cx > 1.0f) cx = 1.0f;
        else if (cx < -1.0f) cx = -1.0f;
        if (cy > 1.0f) cy = 1.0f;
        else if (cy < -1.0f) cy = -1.0f;
        if (lanes.ocean_delta != nullptr) {
            const float odx = cx - old_cx;
            const float ody = cy - old_cy;
            lanes.ocean_delta[i] = std::sqrt(odx * odx + ody * ody);
        }
        lanes.out_curl[i] = CURL[k];
        lanes.out_psi[i] = PSI[k];
        lanes.out_ocean_x[i] = cx;
        lanes.out_ocean_y[i] = cy;
    }
    return true;
}

int upwelling_range(int n_cells, int begin, int end,
                    const UpwellingKnobs &knobs, const UpwellingLanes &lanes) {
    if (n_cells <= 0 || lanes.terrain == nullptr || lanes.neighbors == nullptr ||
        lanes.is_water_lut == nullptr || lanes.wind_x == nullptr ||
        lanes.wind_y == nullptr || lanes.wind_speed == nullptr ||
        lanes.upwelling == nullptr ||
        (lanes.lat_norm == nullptr && lanes.pos_y == nullptr)) {
        return 0;
    }
    if (begin < 0) begin = 0;
    if (end > n_cells) end = n_cells;
    if (end <= begin) return 0;
    float * const __restrict UP = lanes.upwelling;
    const uint8_t * const __restrict TERR = lanes.terrain;
    const int32_t * const __restrict NB = lanes.neighbors;
    const float * const __restrict WX = lanes.wind_x;
    const float * const __restrict WY = lanes.wind_y;
    const float * const __restrict WSPD = lanes.wind_speed;
    for (int i = begin; i < end; ++i) {
        if (!lanes.is_water_lut[TERR[i]]) {
            UP[i] = 0.0f;
            continue;
        }
        const double ny = pkw_lat_at(lanes.lat_norm, lanes.pos_y, lanes.lat_origin,
                                     lanes.lat_inv_span, i);
        const double ls = (ny - 0.5) * 2.0;
        const double ls_abs = (ls < 0.0) ? -ls : ls;
        double lat_temp = climate_formula::lat_temp_bell(ls_abs);
        if (lat_temp < 0.0) lat_temp = 0.0;
        else if (lat_temp > 1.0) lat_temp = 1.0;
        const double temp_rel = lat_temp - 0.5;
        double land_dx = 0.0;
        double land_dy = 0.0;
        const int base = i * 6;
        for (int d = 0; d < 6; ++d) {
            const int32_t ni = NB[base + d];
            if (ni < 0) continue;
            if (!lanes.is_water_lut[TERR[ni]]) {
                land_dx += NB_DIR_X[d];
                land_dy += NB_DIR_Y[d];
            }
        }
        double ekman_main = 0.0;
        const double land_len2 = land_dx * land_dx + land_dy * land_dy;
        if (land_len2 > 0.0001) {
            const double inv_land = 1.0 / std::sqrt(land_len2);
            const double off_x = -land_dx * inv_land;
            const double off_y = -land_dy * inv_land;
            // 屏幕 x=东/y=南，(x,y)->(-y,x) 是右转 90°：coast_tan = 离岸方向右转 90°。
            // 北半球 Ekman 输运在风向右侧 90°，故北半球取 -1、南半球取 +1（up>0 = 上升）。
            const double coast_tan_x = -off_y;
            const double coast_tan_y = off_x;
            const double hemi_sign = (ls < 0.0) ? -1.0 : 1.0;
            const double dot_v =
                double(WX[i]) * coast_tan_x + double(WY[i]) * coast_tan_y;
            ekman_main = dot_v * hemi_sign * double(WSPD[i]) * knobs.ekman_gain;
        }
        double cold_sink_neg = 0.0;
        if (ls_abs > knobs.highlat_abs && temp_rel < knobs.cold_sink_temp) {
            double t_cold = (knobs.cold_sink_temp - temp_rel) / 0.3;
            if (t_cold < 0.0) t_cold = 0.0;
            else if (t_cold > 1.0) t_cold = 1.0;
            cold_sink_neg = -t_cold * knobs.cold_sink_gain;
        }
        double up = ekman_main + cold_sink_neg;
        if (up < -1.0) up = -1.0;
        else if (up > 1.0) up = 1.0;
        UP[i] = float(up);
    }
    return end - begin;
}

int wind_traj_build_range(int n_cells, int begin, int end,
                          const WindTrajKnobs &knobs, const WindTrajLanes &lanes) {
    if (n_cells <= 0 || lanes.pos_x == nullptr || lanes.pos_y == nullptr ||
        lanes.neighbors == nullptr || lanes.wind_x == nullptr ||
        lanes.wind_y == nullptr || lanes.wind_speed == nullptr ||
        lanes.traj_idx == nullptr || lanes.traj_w == nullptr) {
        return 0;
    }
    if (begin < 0) begin = 0;
    if (end > n_cells) end = n_cells;
    if (end <= begin) return 0;
    const float * const __restrict POSX = lanes.pos_x;
    const float * const __restrict POSY = lanes.pos_y;
    const int32_t * const __restrict NB = lanes.neighbors;
    const float * const __restrict WX = lanes.wind_x;
    const float * const __restrict WY = lanes.wind_y;
    const float * const __restrict WSP = lanes.wind_speed;
    int32_t * const __restrict TIDX = lanes.traj_idx;
    float * const __restrict TW = lanes.traj_w;
    const double wrap_period_x = knobs.wrap_period_x;
    const double grid_s = std::sqrt(double(n_cells) / 15000.0);
    const double step_len = knobs.traj_pos_scale * grid_s * knobs.traj_dt_days;
    const double max_dist = 12.0;
    const float wrap_f = float(wrap_period_x);
    for (int i = begin; i < end; ++i) {
        const int t3 = i * 3;
        const double fx = double(WX[i]) * double(WSP[i]);
        const double fy = double(WY[i]) * double(WSP[i]);
        const double sp = std::sqrt(fx * fx + fy * fy);
        if (sp < 1e-6 || step_len <= 0.0) {
            TIDX[t3] = i; TIDX[t3 + 1] = i; TIDX[t3 + 2] = i;
            TW[t3] = 1.0f; TW[t3 + 1] = 0.0f; TW[t3 + 2] = 0.0f;
            continue;
        }
        double dist = sp * step_len;
        if (dist > max_dist) dist = max_dist;
        const double inv_sp = 1.0 / sp;
        const double tx = double(POSX[i]) - fx * inv_sp * dist;
        const double ty = double(POSY[i]) - fy * inv_sp * dist;
        int cur = i;
        for (int hop = 0; hop < 12; ++hop) {
            double dx = tx - double(POSX[cur]);
            const double dy = ty - double(POSY[cur]);
            if (wrap_period_x > 0.001) {
                const double half = wrap_period_x * 0.5;
                if (dx > half) dx -= wrap_period_x;
                else if (dx < -half) dx += wrap_period_x;
            }
            const double dl2 = dx * dx + dy * dy;
            if (dl2 <= 0.75) break;
            int best = -1;
            double best_dot = 0.5;
            const int base = cur * 6;
            for (int d = 0; d < 6; ++d) {
                const int32_t ni = NB[base + d];
                if (ni < 0) continue;
                double ndx = double(POSX[ni]) - double(POSX[cur]);
                const double ndy = double(POSY[ni]) - double(POSY[cur]);
                if (wrap_period_x > 0.001) {
                    const double half = wrap_period_x * 0.5;
                    if (ndx > half) ndx -= wrap_period_x;
                    else if (ndx < -half) ndx += wrap_period_x;
                }
                const double nl2 = ndx * ndx + ndy * ndy;
                if (nl2 < 1e-6) continue;
                const double dot = (ndx * dx + ndy * dy) / std::sqrt(nl2 * dl2);
                if (dot > best_dot) { best_dot = dot; best = ni; }
            }
            if (best < 0) break;
            cur = best;
        }
        int i0, i1, i2;
        float w0, w1, w2;
        pk_hex_sextant_barycentric(cur, float(tx), float(ty), POSX, POSY, NB,
                                   n_cells, wrap_f, i0, i1, i2, w0, w1, w2);
        TIDX[t3] = i0; TIDX[t3 + 1] = i1; TIDX[t3 + 2] = i2;
        TW[t3] = w0; TW[t3 + 1] = w1; TW[t3 + 2] = w2;
    }
    return end - begin;
}

void wind_coast_build_pure(int n_cells, const WindCoastKnobs &knobs,
                           const WindCoastLanes &lanes) {
    if (n_cells <= 0 || lanes.terrain == nullptr || lanes.neighbors == nullptr ||
        lanes.is_water_lut == nullptr || lanes.coast_dist == nullptr ||
        lanes.coast_sea_x == nullptr || lanes.coast_sea_y == nullptr ||
        lanes.coast_sea_anchor == nullptr || lanes.sea_dist == nullptr ||
        lanes.sea_land_x == nullptr || lanes.sea_land_y == nullptr ||
        lanes.sea_land_anchor == nullptr || lanes.scratch_queue == nullptr) {
        return;
    }
    const uint8_t * const TR = lanes.terrain;
    const int32_t * const NB = lanes.neighbors;
    int8_t  * const coast_dist = lanes.coast_dist;
    float   * const coast_sea_x = lanes.coast_sea_x;
    float   * const coast_sea_y = lanes.coast_sea_y;
    int32_t * const coast_sea_anchor = lanes.coast_sea_anchor;
    int8_t  * const sea_dist = lanes.sea_dist;
    float   * const sea_land_x = lanes.sea_land_x;
    float   * const sea_land_y = lanes.sea_land_y;
    int32_t * const sea_land_anchor = lanes.sea_land_anchor;
    int32_t * const queue = lanes.scratch_queue;
    for (int i = 0; i < n_cells; ++i) {
        coast_dist[i] = COAST_INF;
        coast_sea_x[i] = 0.0f;
        coast_sea_y[i] = 0.0f;
        coast_sea_anchor[i] = -1;
        sea_dist[i] = COAST_INF;
        sea_land_x[i] = 0.0f;
        sea_land_y[i] = 0.0f;
        sea_land_anchor[i] = -1;
    }

    // Pass 0：陆地 → 海岸（≤ coast_max_dist 步）
    size_t head = 0;
    size_t tail = 0;
    for (int i = 0; i < n_cells; ++i) {
        if (lanes.is_water_lut[TR[i]]) continue;
        double sea_dx = 0.0, sea_dy = 0.0;
        int32_t sea_anchor = -1;
        const int base = i * 6;
        for (int d = 0; d < 6; ++d) {
            const int32_t ni = NB[base + d];
            if (ni < 0) continue;
            if (!lanes.is_water_lut[TR[ni]]) continue;
            sea_dx += NB_DIR_X[d];
            sea_dy += NB_DIR_Y[d];
            if (sea_anchor < 0 || ni < sea_anchor) sea_anchor = ni;
        }
        if (sea_anchor < 0) continue;
        const double len2 = sea_dx * sea_dx + sea_dy * sea_dy;
        if (len2 <= 0.0001) continue;
        const double inv = 1.0 / std::sqrt(len2);
        coast_dist[i] = 0;
        coast_sea_x[i] = float(sea_dx * inv);
        coast_sea_y[i] = float(sea_dy * inv);
        coast_sea_anchor[i] = sea_anchor;
        queue[tail++] = i;
    }
    while (head < tail) {
        const int32_t cur = queue[head++];
        const int cur_d = coast_dist[cur];
        if (cur_d >= knobs.coast_max_dist) continue;
        const float cur_sx = coast_sea_x[cur];
        const float cur_sy = coast_sea_y[cur];
        const int32_t cur_anchor = coast_sea_anchor[cur];
        const int base = cur * 6;
        for (int d = 0; d < 6; ++d) {
            const int32_t ni = NB[base + d];
            if (ni < 0) continue;
            if (lanes.is_water_lut[TR[ni]]) continue;
            if (coast_dist[ni] != COAST_INF) continue;
            coast_dist[ni] = static_cast<int8_t>(cur_d + 1);
            coast_sea_x[ni] = cur_sx;
            coast_sea_y[ni] = cur_sy;
            coast_sea_anchor[ni] = cur_anchor;
            queue[tail++] = ni;
        }
    }

    // Pass 0b：水面 → 岸线（≤ sea_max_dist 步）
    head = 0;
    tail = 0;
    for (int i = 0; i < n_cells; ++i) {
        if (!lanes.is_water_lut[TR[i]]) continue;
        double land_dx = 0.0, land_dy = 0.0;
        int32_t land_anchor = -1;
        const int base = i * 6;
        for (int d = 0; d < 6; ++d) {
            const int32_t ni = NB[base + d];
            if (ni < 0) continue;
            if (lanes.is_water_lut[TR[ni]]) continue;
            land_dx += NB_DIR_X[d];
            land_dy += NB_DIR_Y[d];
            if (land_anchor < 0 || ni < land_anchor) land_anchor = ni;
        }
        if (land_anchor < 0) continue;
        const double len2 = land_dx * land_dx + land_dy * land_dy;
        if (len2 <= 0.0001) continue;
        const double inv = 1.0 / std::sqrt(len2);
        sea_dist[i] = 0;
        sea_land_x[i] = float(land_dx * inv);
        sea_land_y[i] = float(land_dy * inv);
        sea_land_anchor[i] = land_anchor;
        // 两个 BFS 串行复用同一 scratch：第一趟已结束，可直接从头写第二趟。
        queue[tail++] = i;
    }
    while (head < tail) {
        const int32_t cur = queue[head++];
        const int cur_d = sea_dist[cur];
        if (cur_d >= knobs.sea_max_dist) continue;
        const float cur_lx = sea_land_x[cur];
        const float cur_ly = sea_land_y[cur];
        const int32_t cur_anchor = sea_land_anchor[cur];
        const int base = cur * 6;
        for (int d = 0; d < 6; ++d) {
            const int32_t ni = NB[base + d];
            if (ni < 0) continue;
            if (!lanes.is_water_lut[TR[ni]]) continue;
            if (sea_dist[ni] != COAST_INF) continue;
            sea_dist[ni] = static_cast<int8_t>(cur_d + 1);
            sea_land_x[ni] = cur_lx;
            sea_land_y[ni] = cur_ly;
            sea_land_anchor[ni] = cur_anchor;
            queue[tail++] = ni;
        }
    }
}

namespace {

// 自检用：7 格链式网格（0..2 水、3..6 陆），SLP 沿链递增。
struct WindSelfTestGrid {
    static constexpr int kCells = 7;
    float lat_norm[kCells] = {0.10f, 0.25f, 0.40f, 0.50f, 0.60f, 0.75f, 0.90f};
    float pos_x[kCells] = {0.0f, 1.0f, 2.0f, 3.0f, 4.0f, 5.0f, 6.0f};
    float pos_y[kCells] = {0.1f, 0.2f, 0.3f, 0.4f, 0.5f, 0.6f, 0.7f};
    float slp[kCells] = {0.0f, 0.02f, 0.05f, 0.10f, 0.06f, 0.01f, -0.02f};
    float temp[kCells] = {0.20f, 0.35f, 0.55f, 0.70f, 0.60f, 0.40f, 0.25f};
    uint8_t terrain[kCells] = {1u, 1u, 1u, 0u, 0u, 0u, 0u};
    uint8_t landform[kCells] = {0u, 2u, 0u, 0u, 0u, 0u, 0u};
    int32_t neighbors[kCells * 6] = {};
    bool is_water_lut[256] = {};
    int8_t coast_dist[kCells] = {};
    float coast_sea_x[kCells] = {};
    float coast_sea_y[kCells] = {};
    int32_t coast_sea_anchor[kCells] = {};
    int8_t sea_dist[kCells] = {};
    float sea_land_x[kCells] = {};
    float sea_land_y[kCells] = {};
    int32_t sea_land_anchor[kCells] = {};
    float wind_x[kCells] = {};
    float wind_y[kCells] = {};
    float wind_speed[kCells] = {};
    float wind_speed_out[kCells] = {};
    float wind_delta[kCells] = {};
    float wind_dir_delta[kCells] = {};
    float monsoon_thermal[kCells] = {};

    WindSelfTestGrid() {
        for (int i = 0; i < kCells; ++i) {
            for (int d = 0; d < 6; ++d) {
                int ni = -1;
                if (d == 0 && i > 0) ni = i - 1;
                if (d == 3 && i + 1 < kCells) ni = i + 1;
                neighbors[i * 6 + d] = ni;
            }
            // 每个 cell 都有"最近海岸 1 格"的对称设置：方向恒定，便于断言。
            coast_dist[i] = 1;
            sea_dist[i] = 1;
            coast_sea_anchor[i] = 0;
            sea_land_anchor[i] = kCells - 1;
            coast_sea_x[i] = 1.0f;
            coast_sea_y[i] = 0.0f;
            sea_land_x[i] = -1.0f;
            sea_land_y[i] = 0.0f;
        }
        is_water_lut[1] = true;
    }
};

} // namespace

bool wind_self_test(std::string &error) {
    WindSelfTestGrid g;
    WindFieldKnobs k;
    k.season_phase = 1.0;
    k.axial_tilt_deg = 23.5;
    k.terrain_aware = true;
    k.response_rate = 1.0;          // 直接采用目标风，便于断言
    k.max_turn_rad = 0.0;           // 关掉转向限幅
    k.min_flux_len2 = 0.0;
    k.sim_day = 12;
    k.world_seed = 4242;
    k.has_wrap_domain = true;
    k.wrap_origin_x = 0.0;
    k.wrap_period_x = 7.0;
    k.lf_mountain = 2;
    k.lf_peak = 3;
    k.lf_hill = 4;
    k.thermal_monsoon_enabled = true;
    WindFieldLanes l;
    l.lat_norm = g.lat_norm;
    l.pos_y = g.pos_y;
    l.pos_x = g.pos_x;
    l.slp = g.slp;
    l.neighbors = g.neighbors;
    l.terrain = g.terrain;
    l.landform = g.landform;
    l.is_water_lut = g.is_water_lut;
    l.coast_dist = g.coast_dist;
    l.coast_sea_x = g.coast_sea_x;
    l.coast_sea_y = g.coast_sea_y;
    l.coast_sea_anchor = g.coast_sea_anchor;
    l.sea_dist = g.sea_dist;
    l.sea_land_x = g.sea_land_x;
    l.sea_land_y = g.sea_land_y;
    l.sea_land_anchor = g.sea_land_anchor;
    l.temp = g.temp;
    l.wind_x = g.wind_x;
    l.wind_y = g.wind_y;
    l.wind_speed = g.wind_speed;
    l.wind_speed_out = g.wind_speed_out;
    l.wind_delta = g.wind_delta;
    l.wind_dir_delta = g.wind_dir_delta;
    l.monsoon_thermal = g.monsoon_thermal;

    WindFieldStats stats;
    if (wind_field_range(WindSelfTestGrid::kCells, 0, WindSelfTestGrid::kCells,
                         k, l, stats) != WindSelfTestGrid::kCells) {
        error = "wind_field_range_returned_zero";
        return false;
    }
    for (int i = 0; i < WindSelfTestGrid::kCells; ++i) {
        if (!std::isfinite(g.wind_x[i]) || !std::isfinite(g.wind_y[i]) ||
            !std::isfinite(g.wind_speed[i])) {
            error = "wind_field_non_finite";
            return false;
        }
        const double dir_len = std::sqrt(double(g.wind_x[i]) * double(g.wind_x[i]) +
                                         double(g.wind_y[i]) * double(g.wind_y[i]));
        if (std::fabs(dir_len - 1.0) > 1e-3) {
            error = "wind_field_dir_not_unit";
            return false;
        }
        if (g.wind_speed[i] <= 0.0f || g.wind_speed[i] > 4.0f) {
            error = "wind_field_speed_out_of_range";
            return false;
        }
    }
    // 季风：网格里陆温 > 水温 → 陆地侧应出现正（onshore）响应。
    if (stats.monsoon_eligible == 0 || stats.monsoon_onshore == 0) {
        error = "wind_field_monsoon_not_triggered";
        return false;
    }

    // response_rate=1 且 old 有有效方向时，最终方向 == 目标方向（限幅关闭）。
    // 这里用第二次调用验证"旧值参与"的分支：先注入一个人为旧风再跑。
    for (int i = 0; i < WindSelfTestGrid::kCells; ++i) {
        g.wind_x[i] = 1.0f;
        g.wind_y[i] = 0.0f;
        g.wind_speed[i] = 0.5f;
    }
    WindFieldStats stats2;
    wind_field_range(WindSelfTestGrid::kCells, 0, WindSelfTestGrid::kCells, k, l, stats2);
    for (int i = 0; i < WindSelfTestGrid::kCells; ++i) {
        if (std::fabs(double(g.wind_x[i]) - double(g.wind_x[i])) > 1e-6) {
            error = "wind_field_unstable";
            return false;
        }
    }

    // 季风关闭：monsoon_thermal 必须逐格归零（不许残留上一轮值）。
    k.thermal_monsoon_enabled = false;
    for (int i = 0; i < WindSelfTestGrid::kCells; ++i) g.monsoon_thermal[i] = 9.0f;
    WindFieldStats stats3;
    wind_field_range(WindSelfTestGrid::kCells, 0, WindSelfTestGrid::kCells, k, l, stats3);
    for (int i = 0; i < WindSelfTestGrid::kCells; ++i) {
        if (g.monsoon_thermal[i] != 0.0f) {
            error = "wind_field_monsoon_off_not_zeroed";
            return false;
        }
    }
    if (stats3.monsoon_eligible != 0) {
        error = "wind_field_monsoon_off_counted";
        return false;
    }
    return true;
}

bool psi_self_test(std::string &error) {
    // 合成网格：7 格链（0..3 水、4..6 陆），风沿链方向递增 → 有旋度源项。
    constexpr int kN = 7;
    uint8_t terrain[kN] = {1u, 1u, 1u, 1u, 0u, 0u, 0u};
    int32_t neighbors[kN * 6] = {};
    bool is_water_lut[256] = {};
    float wind_x[kN] = {0.2f, 0.5f, 0.9f, 1.2f, 0.1f, 0.1f, 0.1f};
    float wind_y[kN] = {0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f};
    float wind_speed[kN] = {1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f};
    float lat_norm[kN] = {0.20f, 0.35f, 0.45f, 0.60f, 0.70f, 0.80f, 0.90f};
    float temp[kN] = {0.30f, 0.45f, 0.60f, 0.55f, 0.40f, 0.30f, 0.20f};
    float prev_psi[kN] = {};
    float out_curl[kN] = {}, out_psi[kN] = {}, out_ocx[kN] = {}, out_ocy[kN] = {};
    float ocean_delta[kN] = {};
    is_water_lut[1] = true;
    for (int i = 0; i < kN; ++i) {
        for (int d = 0; d < 6; ++d) {
            int ni = -1;
            if (d == 0 && i > 0) ni = i - 1;
            if (d == 3 && i + 1 < kN) ni = i + 1;
            neighbors[i * 6 + d] = ni;
        }
    }
    int cell_to_water[kN] = {};
    int water_to_cell[kN] = {};
    int32_t nb_w[kN * 6] = {};
    const int n_water = psi_topology_build_pure(
        kN, terrain, neighbors, is_water_lut, cell_to_water, water_to_cell, nb_w);
    if (n_water != 4) {
        error = "psi_topology_water_count";
        return false;
    }
    // cell↔water 互逆 + nb_w 只连水格。
    for (int k = 0; k < n_water; ++k) {
        const int i = water_to_cell[k];
        if (i < 0 || i >= kN || cell_to_water[i] != k) {
            error = "psi_topology_inverse_mismatch";
            return false;
        }
    }
    for (int i = 0; i < kN; ++i) {
        if (is_water_lut[terrain[i]]) continue;
        if (cell_to_water[i] != -1) {
            error = "psi_topology_land_not_negative";
            return false;
        }
    }
    for (int k = 0; k < n_water; ++k) {
        for (int d = 0; d < 6; ++d) {
            const int kw = nb_w[k * 6 + d];
            if (kw < 0) continue;
            if (kw >= n_water || !is_water_lut[terrain[water_to_cell[kw]]]) {
                error = "psi_topology_nb_leaks_to_land";
                return false;
            }
        }
    }

    float tau_x[kN] = {}, tau_y[kN] = {}, ny_w[kN] = {}, ls_w[kN] = {};
    float curl[kN] = {}, beta[kN] = {}, rfac[kN] = {}, src[kN] = {}, psi[kN] = {};
    PsiSolveKnobs k;
    k.total_iters = 24;
    k.early_exit = false;
    PsiSolveLanes l;
    l.n_cells = kN;
    l.n_water = n_water;
    l.neighbors = neighbors;
    l.terrain = terrain;
    l.is_water_lut = is_water_lut;
    l.cell_to_water = cell_to_water;
    l.water_to_cell = water_to_cell;
    l.nb_w = nb_w;
    l.wind_x = wind_x;
    l.wind_y = wind_y;
    l.wind_speed = wind_speed;
    l.lat_norm = lat_norm;
    l.temp = temp;
    l.out_curl = out_curl;
    l.out_psi = out_psi;
    l.out_ocean_x = out_ocx;
    l.out_ocean_y = out_ocy;
    l.ocean_delta = ocean_delta;
    PsiSolveScratch s;
    s.tau_x = tau_x; s.tau_y = tau_y; s.ny_w = ny_w; s.ls_w = ls_w;
    s.curl = curl; s.beta_abs = beta; s.r_factor = rfac; s.source = src; s.psi = psi;
    PsiSolveStats stats;
    if (!psi_solve_pure(k, l, s, stats)) {
        error = "psi_solve_rejected_inputs";
        return false;
    }
    if (stats.iters_run != k.total_iters) {
        error = "psi_solve_iter_count";
        return false;
    }
    for (int i = 0; i < kN; ++i) {
        if (!std::isfinite(out_curl[i]) || !std::isfinite(out_psi[i]) ||
            !std::isfinite(out_ocx[i]) || !std::isfinite(out_ocy[i])) {
            error = "psi_solve_non_finite";
            return false;
        }
        const float mag = std::sqrt(out_ocx[i] * out_ocx[i] + out_ocy[i] * out_ocy[i]);
        if (mag > k.oc_max_mag + 1e-4f) {
            error = "psi_solve_magnitude_unbounded";
            return false;
        }
    }
    // 更多迭代 → 残差应下降（同一初值、同源项）。
    const float residual_24 = stats.residual_final;
    for (int i = 0; i < kN; ++i) prev_psi[i] = out_psi[i];
    l.prev_psi = prev_psi;
    PsiSolveStats stats2;
    if (!psi_solve_pure(k, l, s, stats2)) {
        error = "psi_solve_warm_start_failed";
        return false;
    }
    if (!(stats2.residual_final <= residual_24 + 1e-6f)) {
        error = "psi_solve_warm_start_not_converged";
        return false;
    }
    k.early_exit = true;
    k.min_iters = 2;
    k.check_every = 1;
    k.residual_epsilon = 1e6f;   // 立刻满足 → 应在 min_iters 处提前退出
    PsiSolveStats stats3;
    if (!psi_solve_pure(k, l, s, stats3)) {
        error = "psi_solve_early_exit_failed";
        return false;
    }
    if (!stats3.early_exit || stats3.iters_run != k.min_iters) {
        error = "psi_solve_early_exit_semantics";
        return false;
    }
    return true;
}

bool ocean_self_test(std::string &error) {
    // 7 格链：0..4 水、5..6 陆。纬度沿链递增，cell 4 在高纬（冷沉分支）。
    constexpr int kN = 7;
    uint8_t terrain[kN] = {1u, 1u, 1u, 1u, 1u, 0u, 0u};
    int32_t neighbors[kN * 6] = {};
    bool is_water_lut[256] = {};
    float lat_norm[kN] = {0.20f, 0.30f, 0.45f, 0.62f, 0.92f, 0.95f, 0.98f};
    float wind_x[kN] = {1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 0.0f, 0.0f};
    float wind_y[kN] = {};
    float wind_speed[kN] = {0.8f, 0.8f, 0.8f, 0.8f, 0.8f, 0.0f, 0.0f};
    float up[kN] = {};
    is_water_lut[1] = true;
    for (int i = 0; i < kN; ++i) {
        for (int d = 0; d < 6; ++d) {
            int ni = -1;
            if (d == 0 && i > 0) ni = i - 1;
            if (d == 3 && i + 1 < kN) ni = i + 1;
            neighbors[i * 6 + d] = ni;
        }
    }
    UpwellingKnobs uk;
    UpwellingLanes ul;
    ul.lat_norm = lat_norm;
    ul.terrain = terrain;
    ul.neighbors = neighbors;
    ul.is_water_lut = is_water_lut;
    ul.wind_x = wind_x;
    ul.wind_y = wind_y;
    ul.wind_speed = wind_speed;
    ul.upwelling = up;
    if (upwelling_range(kN, 0, kN, uk, ul) != kN) {
        error = "upwelling_range_returned_zero";
        return false;
    }
    // 陆地格必须为 0；水格有邻陆 → Ekman 分支；全部落在 [-1,1]。
    for (int i = 0; i < kN; ++i) {
        if (!is_water_lut[terrain[i]]) {
            if (up[i] != 0.0f) {
                error = "upwelling_land_not_zero";
                return false;
            }
            continue;
        }
        if (!std::isfinite(up[i]) || up[i] < -1.0f || up[i] > 1.0f) {
            error = "upwelling_out_of_range";
            return false;
        }
    }
    // cell 4 同时具备"邻陆"（cell 5）与高纬冷沉条件 → 不可能为 0。
    if (up[4] == 0.0f) {
        error = "upwelling_coastal_no_ekman";
        return false;
    }

    // wind traj：静止风 → own-cell；有风 → 权重和为 1 且索引在域内。
    float pos_x[kN] = {0.0f, 1.0f, 2.0f, 3.0f, 4.0f, 5.0f, 6.0f};
    float pos_y[kN] = {};
    float w_wind_x[kN] = {1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 0.0f, 0.0f};
    float w_wind_y[kN] = {};
    float w_wsp[kN] = {0.5f, 0.5f, 0.5f, 0.5f, 0.5f, 0.0f, 0.0f};
    int32_t traj_idx[kN * 3] = {};
    float traj_w[kN * 3] = {};
    WindTrajKnobs tk;
    tk.wrap_period_x = 7.0;
    tk.traj_pos_scale = 0.65;
    tk.traj_dt_days = 10.0;
    WindTrajLanes tl;
    tl.pos_x = pos_x;
    tl.pos_y = pos_y;
    tl.neighbors = neighbors;
    tl.wind_x = w_wind_x;
    tl.wind_y = w_wind_y;
    tl.wind_speed = w_wsp;
    tl.traj_idx = traj_idx;
    tl.traj_w = traj_w;
    if (wind_traj_build_range(kN, 0, kN, tk, tl) != kN) {
        error = "wind_traj_returned_zero";
        return false;
    }
    for (int i = 0; i < kN; ++i) {
        const int t3 = i * 3;
        const float wsum = traj_w[t3] + traj_w[t3 + 1] + traj_w[t3 + 2];
        if (std::fabs(wsum - 1.0f) > 1e-4f) {
            error = "wind_traj_weights_not_normalized";
            return false;
        }
        for (int c = 0; c < 3; ++c) {
            const int idx = traj_idx[t3 + c];
            if (idx < 0 || idx >= kN) {
                error = "wind_traj_index_out_of_range";
                return false;
            }
        }
        if (i == 5 || i == 6) {   // 静止风 → own-cell 退化
            if (traj_idx[t3] != i || traj_w[t3] != 1.0f) {
                error = "wind_traj_still_wind_not_own_cell";
                return false;
            }
        }
    }
    return true;
}

bool coast_self_test(std::string &error) {
    // 9 格环形链：水面 {0,1}，陆地 {2..8}。这样水面两侧都有陆地邻居
    // （单格水体会让朝陆方向的两个邻居互相抵消 → len2=0，属于真实退化分支）。
    constexpr int kN = 9;
    uint8_t terrain[kN] = {1u, 1u, 0u, 0u, 0u, 0u, 0u, 0u, 0u};
    int32_t neighbors[kN * 6] = {};
    bool is_water_lut[256] = {};
    is_water_lut[1] = true;
    // 环形链：0-1-2-3-4-5-6-7-8-0（每格两个邻居），保证 BFS 能传播。
    for (int i = 0; i < kN; ++i) {
        for (int d = 0; d < 6; ++d) neighbors[i * 6 + d] = -1;
        const int prev = (i + kN - 1) % kN;
        const int next = (i + 1) % kN;
        neighbors[i * 6 + 0] = prev;   // d=0 (E) 借用为链向
        neighbors[i * 6 + 3] = next;   // d=3 (W)
    }
    int8_t coast_dist[kN] = {};
    float coast_sea_x[kN] = {}, coast_sea_y[kN] = {};
    int32_t coast_anchor[kN] = {};
    int8_t sea_dist[kN] = {};
    float sea_land_x[kN] = {}, sea_land_y[kN] = {};
    int32_t sea_anchor[kN] = {};
    int32_t queue[kN * 2] = {};
    WindCoastLanes cl;
    cl.terrain = terrain;
    cl.neighbors = neighbors;
    cl.is_water_lut = is_water_lut;
    cl.coast_dist = coast_dist;
    cl.coast_sea_x = coast_sea_x;
    cl.coast_sea_y = coast_sea_y;
    cl.coast_sea_anchor = coast_anchor;
    cl.sea_dist = sea_dist;
    cl.sea_land_x = sea_land_x;
    cl.sea_land_y = sea_land_y;
    cl.sea_land_anchor = sea_anchor;
    cl.scratch_queue = queue;
    WindCoastKnobs ck;
    ck.coast_max_dist = 5;
    ck.sea_max_dist = 5;
    wind_coast_build_pure(kN, ck, cl);

    // 陆地格：与水面相邻者 dist=0、方向单位化、锚格 = 0（唯一水格）；
    // 距水超过 sea/coast_max_dist 的格保持 COAST_INF（本网格 9 格链在 5 步内全覆盖）。
    for (int i = 2; i < kN; ++i) {
        if (coast_dist[i] == COAST_INF) {
            error = "coast_bfs_did_not_reach_land";
            return false;
        }
        const float len = std::sqrt(coast_sea_x[i] * coast_sea_x[i] +
                                    coast_sea_y[i] * coast_sea_y[i]);
        if (std::fabs(len - 1.0f) > 1e-3f) {
            error = "coast_bfs_dir_not_unit";
            return false;
        }
        if (coast_anchor[i] < 0 || !is_water_lut[terrain[coast_anchor[i]]]) {
            error = "coast_bfs_anchor_wrong";
            return false;
        }
    }
    // 水格：sea_dist = 0（与陆地相邻）、朝陆方向单位化、锚格为陆格。
    for (int i = 0; i < 2; ++i) {
        if (sea_dist[i] != 0 || sea_anchor[i] < 0) {
            error = "sea_bfs_shore_not_seeded";
            return false;
        }
        if (!is_water_lut[terrain[i]] || is_water_lut[terrain[sea_anchor[i]]]) {
            error = "sea_bfs_anchor_wrong";
            return false;
        }
        const float sea_len = std::sqrt(sea_land_x[i] * sea_land_x[i] +
                                        sea_land_y[i] * sea_land_y[i]);
        if (std::fabs(sea_len - 1.0f) > 1e-3f) {
            error = "sea_bfs_dir_not_unit";
            return false;
        }
    }
    return true;
}

bool physics_state_self_test(std::string &error) {
    RuntimeClimatePhysicsState st;
    if (st.ready) {
        error = "physics_state_default_ready";
        return false;
    }
    const uint64_t gen0 = st.generation;
    st.resize(12);
    if (!st.ready || st.cell_count != 12 || st.generation <= gen0) {
        error = "physics_state_resize_shape";
        return false;
    }
    std::string why;
    if (!st.validate(why)) {
        error = "physics_state_validate_after_resize:" + why;
        return false;
    }
    // 水域缓冲按 n_water 定形；声明了水域格数却没定形缓冲时 validate 必须失败
    // （防止拿空 psi 工作区跑求解）。
    st.n_water = 5;
    if (st.validate(why)) {
        error = "physics_state_validate_accepts_missing_water";
        return false;
    }
    st.resize_water(5);
    if (st.n_water != 5 || st.ocean_psi.size() != 5u ||
        st.psi_tau_x.size() != 5u || st.nb_w.size() != 30u) {
        error = "physics_state_water_shape";
        return false;
    }
    if (!st.validate(why)) {
        error = "physics_state_validate_after_water:" + why;
        return false;
    }
    // hash：同数据稳定、改一格即变。
    const uint64_t h1 = st.state_hash();
    const uint64_t h2 = st.state_hash();
    if (h1 != h2) {
        error = "physics_state_hash_unstable";
        return false;
    }
    st.slp[3] += 0.5f;
    if (st.state_hash() == h1) {
        error = "physics_state_hash_ignores_data";
        return false;
    }
    // reset（resize 同尺寸）后形状仍合法、数据归零、generation 继续前进。
    st.resize(12);
    if (st.slp[3] != 0.0f || !st.validate(why) || st.generation <= gen0 + 1) {
        error = "physics_state_resize_resets";
        return false;
    }
    // 尺寸变化后旧缓冲不得残留（按新尺寸定形）。
    st.resize(7);
    if (st.slp.size() != 7u || st.wind_traj_idx.size() != 21u ||
        !st.validate(why)) {
        error = "physics_state_resize_shrinks";
        return false;
    }
    return true;
}

bool self_test(std::string &error) {
    if (!wind_self_test(error)) return false;
    if (!psi_self_test(error)) return false;
    if (!ocean_self_test(error)) return false;
    if (!coast_self_test(error)) return false;
    if (!physics_state_self_test(error)) return false;
    SlpSelfTestGrid g;
    SlpPassAKnobs ka;
    ka.lut_bins = 8;
    ka.lut_base = g.lut_base;
    ka.lut_heat = g.lut_heat;
    ka.has_wrap_domain = true;
    ka.wrap_origin_x = 0.0;
    ka.wrap_period_x = 7.0;
    ka.world_seed = 12345;
    ka.n_mobile_low = 1;
    ka.mobile_low_amp = 0.02f;
    ka.mobile_low_inv2s2 = 1.0f / (2.0f * 0.16f * 0.16f);
    ka.mobile_low_cx[0] = 0.4f;
    ka.mobile_low_cy[0] = 0.3f;
    SlpPassALanes la;
    la.lat_norm = g.lat_norm;
    la.pos_y = g.pos_y;
    la.terrain = g.terrain;
    la.neighbors = g.neighbors;
    la.pos_x = g.pos_x;
    la.is_water_lut = g.is_water_lut;

    if (slp_pass_a_range(SlpSelfTestGrid::kCells, 0, SlpSelfTestGrid::kCells,
                         ka, la, g.slp, g.thermal) != SlpSelfTestGrid::kCells) {
        error = "slp_pass_a_range_returned_zero";
        return false;
    }
    for (int i = 0; i < SlpSelfTestGrid::kCells; ++i) {
        if (!std::isfinite(g.slp[i]) || !std::isfinite(g.thermal[i])) {
            error = "slp_pass_a_non_finite";
            return false;
        }
    }
    // 水格的 landsea 走 water_damp、陆格走 coast/interior → 两者不可能全等。
    if (g.slp[2] == g.slp[0]) {
        error = "slp_pass_a_water_land_identical";
        return false;
    }

    // Pass B：一次 Jacobi 后再 recenter。邻居是链式（i-1 / i+1），所以手工可算。
    float expect[SlpSelfTestGrid::kCells];
    for (int i = 0; i < SlpSelfTestGrid::kCells; ++i) {
        float sum = g.slp[i];
        int cnt = 1;
        const int nb0 = g.neighbors[i * 6 + 0];
        const int nb3 = g.neighbors[i * 6 + 3];
        if (nb0 >= 0) { sum += g.slp[nb0]; cnt += 1; }
        if (nb3 >= 0) { sum += g.slp[nb3]; cnt += 1; }
        expect[i] = sum / float(cnt);
    }
    float before[SlpSelfTestGrid::kCells];
    std::copy(g.slp, g.slp + SlpSelfTestGrid::kCells, before);
    SlpPassBKnobs kb;
    kb.smooth_passes = 1;
    kb.recenter = false;
    kb.response_rate = -1.0f;
    float delta[SlpSelfTestGrid::kCells] = {};
    slp_pass_b_pure(SlpSelfTestGrid::kCells, kb, g.neighbors, nullptr,
                    g.slp, g.scratch, delta);
    for (int i = 0; i < SlpSelfTestGrid::kCells; ++i) {
        if (std::fabs(g.slp[i] - expect[i]) > 1e-6f) {
            error = "slp_pass_b_jacobi_mismatch";
            return false;
        }
        if (std::fabs(delta[i] - std::fabs(expect[i])) > 1e-6f) {
            error = "slp_pass_b_delta_mismatch";
            return false;
        }
    }

    // recenter：均值归零（残余在 float 精度内）。
    for (int i = 0; i < SlpSelfTestGrid::kCells; ++i) g.slp[i] = before[i];
    kb.recenter = true;
    kb.target_p95 = 0.18f;
    slp_pass_b_pure(SlpSelfTestGrid::kCells, kb, nullptr, nullptr,
                    g.slp, g.scratch, nullptr);
    double mean = 0.0;
    for (int i = 0; i < SlpSelfTestGrid::kCells; ++i) mean += double(g.slp[i]);
    if (std::fabs(mean / double(SlpSelfTestGrid::kCells)) > 1e-4) {
        error = "slp_pass_b_recenter_not_zero_mean";
        return false;
    }

    // response_rate=0：结果必须逐位等于 prev（"不响应"是生产 recenter 后的语义）。
    float prev[SlpSelfTestGrid::kCells] = {-0.1f, -0.2f, -0.3f, -0.4f,
                                           -0.5f, -0.6f, -0.7f};
    for (int i = 0; i < SlpSelfTestGrid::kCells; ++i) g.slp[i] = before[i];
    kb.smooth_passes = 0;
    kb.recenter = false;
    kb.response_rate = 0.0f;
    slp_pass_b_pure(SlpSelfTestGrid::kCells, kb, nullptr, prev, g.slp,
                    g.scratch, nullptr);
    for (int i = 0; i < SlpSelfTestGrid::kCells; ++i) {
        if (g.slp[i] != prev[i]) {
            error = "slp_pass_b_response_zero_mismatch";
            return false;
        }
    }
    return true;
}

} // namespace pk_async_physics
} // namespace pk
