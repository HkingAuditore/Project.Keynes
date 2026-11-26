// ─── pk_async_physics 实现（B8 P2）───────────────────────────────────────────
//
// 搬移纪律与 runtime_climate_passes.cpp 相同：从 world_ext_physical.cpp 里逐行搬，
// 只做三类等价改写：
//   1. Dictionary knobs → POD（所有 get/clamp 都在调用方循环外做完）；
//   2. slot 指针 → lane 指针（调用方解析）；
//   3. ParallelDispatcher → 调用方分段（kernel 内是纯 range 循环）。
// 公式、阈值、遍历顺序、累加顺序都不许动。

#include "runtime_climate_physics.h"
#include "simulation_math.h"

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

#include "runtime_climate_physics_latitude_lookup.inc"

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
                0.65 * simulation_math::sin(TWO_PI * (double(knobs.syn_k1x) * px +
                                          double(knobs.syn_k1y) * py) +
                                double(knobs.syn_phase) + double(ls) * 0.6 +
                                double(knobs.syn_sa)) +
                0.35 * simulation_math::cos(TWO_PI * (double(knobs.syn_k2x) * px -
                                          double(knobs.syn_k2y) * py) -
                                double(knobs.syn_phase2) + double(ls_abs) * 0.9 +
                                double(knobs.syn_sb)));
        } else {
            // 退化（无 pos_x lane）：沿用 cell 索引波，保持向后兼容。
            synoptic = knobs.synoptic_amp * float(
                0.65 * simulation_math::sin(double(i) * 4.886 +
                                double(knobs.world_seed) * 0.00011 +
                                double(knobs.syn_phase) + double(ls) * 5.3) +
                0.35 * simulation_math::cos(double(i) * 2.191 -
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
                    simulation_math::exp(-r2 * knobs.mobile_low_inv2s2);
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
        const double coriolis_angle = WIND_CORIOLIS_MAX_RAD * simulation_math::pow(ls_abs, 0.55);
        const double rot = (ls < 0.0) ? coriolis_angle : -coriolis_angle;
        const double cos_r = simulation_math::cos(rot);
        const double sin_r = simulation_math::sin(rot);
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
            const double k1y = simulation_math::cos(seed_a) * 0.90 + 2.30;
            const double k2x = 3.0 + double((seed_bits >> 2) & 3u);
            const double k2y = simulation_math::sin(seed_b) * 1.00 + 2.40;
            const double p1 =
                6.283185307179586 * (k1x * px + k1y * py + syn_cycles) + seed_a;
            const double p2 =
                6.283185307179586 * (k2x * px - k2y * py - syn_cycles * 0.56) + seed_b;
            const double psi1 = simulation_math::sin(p1);
            const double psi2 = simulation_math::cos(p2);
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
                const double angle = simulation_math::acos(dot);
                if (angle > max_turn_rad) {
                    const double cross =
                        old_unit_x * final_dir_y - old_unit_y * final_dir_x;
                    const double sign = (cross < 0.0) ? -1.0 : 1.0;
                    const double cos_t = simulation_math::cos(max_turn_rad);
                    const double sin_t = simulation_math::sin(max_turn_rad) * sign;
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

} // namespace pk_async_physics
} // namespace pk
