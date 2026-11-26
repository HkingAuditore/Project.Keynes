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
#include "runtime_climate_physics_latitude_lookup.inc"
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
    if (n_cells > 0 && n_water == 0 && lanes.out_curl && lanes.out_psi &&
        lanes.out_ocean_x && lanes.out_ocean_y) {
        std::fill_n(lanes.out_curl, n_cells, 0.0f);
        std::fill_n(lanes.out_psi, n_cells, 0.0f);
        std::fill_n(lanes.out_ocean_x, n_cells, 0.0f);
        std::fill_n(lanes.out_ocean_y, n_cells, 0.0f);
        if (lanes.ocean_delta) std::fill_n(lanes.ocean_delta, n_cells, 0.0f);
        return true;
    }
    if (n_cells <= 0 || n_water <= 0 || n_water > n_cells ||
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
    const float * const OLD_OCX = lanes.old_ocean_x;
    const float * const OLD_OCY = lanes.old_ocean_y;
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
        float b = simulation_math::cos(ls_abs * HALF_PI_PREP);
        if (b < knobs.beta_floor) b = knobs.beta_floor;
        BETA[k] = b;
        RFAC[k] = knobs.r_base * (0.5f + simulation_math::sin(ls_abs * PI_PREP));
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
        // 水格稍后全量覆盖；不能先清零与 old_ocean 同址的响应基准。
        if (lanes.cell_to_water[i] >= 0) continue;
        lanes.out_curl[i] = 0.0f;
        lanes.out_psi[i] = 0.0f;
        lanes.out_ocean_x[i] = 0.0f;
        lanes.out_ocean_y[i] = 0.0f;
        if (lanes.ocean_delta) lanes.ocean_delta[i] = 0.0f;
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
                const float grad_mag = simulation_math::sin(ls_abs * PI_F);
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

} // namespace pk_async_physics
} // namespace pk
