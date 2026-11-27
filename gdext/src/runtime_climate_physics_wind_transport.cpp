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


void wind_divergence_range(int n, int begin, int end, const int32_t *nb,
                          const float *wx, const float *wy, const float *speed, float *div) {
    for (int i = begin; i < end; ++i) {
        const double fx_i = double(wx[i]) * double(speed[i]);
        const double fy_i = double(wy[i]) * double(speed[i]);
        double dv = 0.0;
        for (int d = 0; d < 6; ++d) {
            const int32_t ni = nb[i * 6 + d];
            if (ni < 0 || ni >= n) continue;
            const double dfx = double(wx[ni]) * double(speed[ni]) - fx_i;
            const double dfy = double(wy[ni]) * double(speed[ni]) - fy_i;
            dv += dfx * NB_DIR_X[d] + dfy * NB_DIR_Y[d];
        }
        div[i] = float(dv / 3.0);
    }
}

void wind_divergence_apply_range(int n, int begin, int end, const int32_t *nb,
                                const float *div, double alpha,
                                float *wx, float *wy, float *speed) {
    for (int i = begin; i < end; ++i) {
        const double self = double(div[i]);
        double gx = 0.0, gy = 0.0;
        int count = 0;
        for (int d = 0; d < 6; ++d) {
            const int32_t ni = nb[i * 6 + d];
            if (ni < 0 || ni >= n) continue;
            gx += (double(div[ni]) - self) * NB_DIR_X[d];
            gy += (double(div[ni]) - self) * NB_DIR_Y[d];
            ++count;
        }
        if (count == 0) continue;
        gx /= 3.0; gy /= 3.0;
        const double fx = double(wx[i]) * double(speed[i]) + alpha * gx;
        const double fy = double(wy[i]) * double(speed[i]) + alpha * gy;
        const double len2 = fx * fx + fy * fy;
        if (len2 > 1e-8) {
            const double inv = 1.0 / std::sqrt(len2);
            wx[i] = float(fx * inv); wy[i] = float(fy * inv); speed[i] = float(std::sqrt(len2));
        }
    }
}

void prepare_slp_forcing(SlpPassAKnobs &k, int bins, float season,
                        float tilt, float daylen, int day, double period,
                        int mobile_count, float mobile_amp, float mobile_sigma,
                        double mobile_period, std::vector<float> &base,
                        std::vector<float> &heat, const float *annual_mean) {
    bins = std::clamp(bins, 16, 8192);
    base.resize(bins); heat.resize(bins);
    for (int b = 0; b < bins; ++b) {
        const float ny = float(b) / float(bins - 1);
        const float la = std::fabs((ny - 0.5f) * 2.0f);
        base[b] = -k.lat_amp * simulation_math::cos(la * 3.14159265358979323846f * 3.0f);
        const float s = simulation_math::sin(la * 3.14159265358979323846f);
        const float factor = s * s;
        const float now = dc_insolation_now(ny, season, tilt, daylen);
        const float mean = annual_mean ? annual_mean[b] : dc_insolation_annual_mean(ny, tilt, daylen);
        heat[b] = dc_insolation_season_dev(ny, now, mean) * factor;
    }
    k.lut_bins = bins; k.lut_base = base.data(); k.lut_heat = heat.data();
    const double sa = double(k.world_seed) * 0.00011;
    const double sb = double(k.world_seed) * 0.00017;
    const double phase = double(day) * (6.283185307179586 / std::max(0.5, period));
    const uint32_t seed = static_cast<uint32_t>(k.world_seed);
    k.syn_sa = float(sa); k.syn_sb = float(sb); k.syn_phase = float(phase); k.syn_phase2 = float(phase * 0.66);
    k.syn_k1x = float(3.0 + double(seed & 3u)); k.syn_k1y = float(1.30 + 0.40 * simulation_math::cos(sa));
    k.syn_k2x = float(3.0 + double((seed >> 2) & 3u)); k.syn_k2y = float(1.45 + 0.35 * simulation_math::sin(sb));
    k.n_mobile_low = mobile_amp > 0.0f ? std::clamp(mobile_count, 0, 8) : 0;
    k.mobile_low_amp = std::max(0.0f, mobile_amp);
    mobile_sigma = std::max(0.02f, mobile_sigma);
    k.mobile_low_inv2s2 = 1.0f / (2.0f * mobile_sigma * mobile_sigma);
    for (int j = 0; j < k.n_mobile_low; ++j) {
        uint32_t h = uint32_t(k.world_seed) * 2654435761u + uint32_t(j) * 40503u + 1013904223u;
        h ^= h >> 16; h *= 2246822519u; h ^= h >> 13;
        const float hx = float(h & 0xFFFFu) / 65535.0f;
        const float hy = float((h >> 16) & 0xFFFFu) / 65535.0f;
        double cx = double(hx) + double(day) / std::max(1.0, mobile_period);
        cx -= std::floor(cx);
        const float base_y = 0.22f + 0.56f * hy;
        const float wob = 0.05f * float(simulation_math::sin(double(day) * 0.045 + double(j) * 1.7));
        k.mobile_low_cx[j] = float(cx); k.mobile_low_cy[j] = std::clamp(base_y + wob, 0.04f, 0.96f);
    }
}

} // namespace pk_async_physics
} // namespace pk
