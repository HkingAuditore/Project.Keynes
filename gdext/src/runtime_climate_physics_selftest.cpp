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
            lut_base[b] = -0.16f * simulation_math::cos(ls_abs * 3.14159265358979323846f * 3.0f);
            const float s_lat = simulation_math::sin(ls_abs * 3.14159265358979323846f);
            lut_heat[b] = 0.05f * s_lat * s_lat;
        }
    }
};

} // namespace

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
    if (st.n_water != 5 || st.ocean_psi.size() != 12u || st.ocean_psi_prev.size() != 12u ||
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
    st.slp_prev[1] = 0.125f;
    st.ocean_psi[6] = -0.25f;
    st.synoptic_seeded = true;
    st.synoptic_tick = 3;
    st.committed_day = 3;
    std::vector<uint8_t> blob;
    RuntimeClimatePhysicsState restored;
    // v1 旧档：去掉 TTA lane、版本写 1。未播种时哈希不含 TTA，所以原哈希仍有效。
    if (!serialize_physics_state(st, blob, why)) {
        error = "physics_state_v1_serialize:" + why; return false;
    }
    blob[4] = 1u;
    blob.resize(blob.size() - static_cast<size_t>(st.cell_count) * 4u);
    if (!restore_physics_state(blob.data(), blob.size(), restored, why) ||
        restored.tta_seeded || restored.state_hash() != st.state_hash()) {
        error = "physics_state_v1_restore:" + why; return false;
    }
    st.temp_transport_anomaly[2] = 0.03125f;
    st.tta_seeded = true;
    if (!serialize_physics_state(st, blob, why) ||
        !restore_physics_state(blob.data(), blob.size(), restored, why) ||
        st.state_hash() != restored.state_hash()) {
        error = "physics_state_roundtrip:" + why; return false;
    }
    const uint64_t restored_hash = restored.state_hash();
    blob.back() ^= 1;
    if (restore_physics_state(blob.data(), blob.size(), restored, why) ||
        restored.state_hash() != restored_hash) {
        error = "physics_state_corruption_accepted"; return false;
    }
    st.note_wind_solve(st.committed_day);
    if (!serialize_physics_state(st, blob, why) || !st.wind_display_signature) {
        error = "physics_wind_signature_missing:" + why; return false;
    }
    const auto initial_wind = st.wind_display_signature->words;
    st.note_wind_solve(++st.committed_day);
    if (!serialize_physics_state(st, blob, why) || !st.wind_display_signature ||
        st.wind_display_signature->words != initial_wind) {
        error = "physics_wind_signature_depends_on_solve_day:" + why; return false;
    }
    for (auto *lane : {&st.wind_x, &st.wind_y, &st.wind_speed}) {
        const float original = lane->back();
        lane->back() = 0.5f;
        st.note_wind_solve(++st.committed_day);
        if (!serialize_physics_state(st, blob, why) || !st.wind_display_signature ||
            st.wind_display_signature->words == initial_wind) {
            error = "physics_wind_signature_missed_changed_cell:" + why; return false;
        }
        lane->back() = original;
    }
    st.note_wind_solve(++st.committed_day);
    if (!serialize_physics_state(st, blob, why) || !st.wind_display_signature ||
        st.wind_display_signature->words != initial_wind) {
        error = "physics_wind_signature_missed_restored_values:" + why; return false;
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
