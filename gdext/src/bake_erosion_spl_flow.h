#pragma once

#include "bake_erosion_spl_grid.h"

namespace pk_erosion {
namespace detail {

// 填洼最小堆的比较器：先比高度（小根），同高度比下标 —— 与 carve 的 pair 字典序一致且确定性。
struct NodeGreater {
    bool operator()(const std::pair<float, int32_t> &a, const std::pair<float, int32_t> &b) const {
        if (a.first != b.first) return a.first > b.first;
        return a.second > b.second;
    }
};

// Priority-Flood + ε（Barnes 2014）：float key 的最小堆 + 洼地/平地内部 FIFO 队列。
//   · 出口：wet ∪ 南北边缘（wrap 生效时东西向不设出口，靠环绕）。
//   · 出栈序 order 对填洼面单调不减 → 任何 z 严格更低的邻点都已先出栈（拓扑序下游→上游）。
//   · 返回「需要填高的像素数」（z_filled > z_orig + 0.5·FILL_EPS），供 pits_in/pits_out。
//   · order 传 nullptr 即纯填洼复核（count_pits 用）。
inline int32_t priority_flood(const Grid &g, std::vector<float> &zf, std::vector<int32_t> *order) {
    const int W = g.w;
    const int R = g.h;
    const int cols = periodic_cols(g);
    const bool wrap = wrap_on(g);
    const size_t N = size_t(W) * size_t(R);
    zf.assign(N, 0.0f);
    for (int y = 0; y < R; ++y) {
        const size_t row = size_t(y) * size_t(W);
        for (int x = 0; x < cols; ++x) {
            zf[row + size_t(x)] = (g.H != nullptr) ? g.H[row + size_t(x)] : 0.0f;
        }
        for (int x = cols; x < W; ++x) zf[row + size_t(x)] = zf[row + size_t(x % cols)];
    }
    if (order != nullptr) {
        order->clear();
        order->reserve(N);
    }
    std::vector<uint8_t> closed(N, 0);
    std::priority_queue<std::pair<float, int32_t>, std::vector<std::pair<float, int32_t> >,
            NodeGreater> open;
    std::queue<int32_t> pit;
    for (int y = 0; y < R; ++y) {
        for (int x = 0; x < cols; ++x) {
            const size_t i = size_t(y) * size_t(W) + size_t(x);
            const bool edge = (y == 0) || (y == R - 1) || (!wrap && (x == 0 || x == cols - 1));
            if (is_wet(g, i) || edge) {
                closed[i] = 1;
                open.push(std::make_pair(zf[i], int32_t(i)));
            }
        }
    }
    int32_t pits = 0;
    while (!open.empty() || !pit.empty()) {
        int32_t c;
        if (!pit.empty()) {
            c = pit.front();
            pit.pop();
        } else {
            c = open.top().second;
            open.pop();
        }
        if (order != nullptr) order->push_back(c);
        const int cx = int(c % W);
        const int cy = int(c / W);
        const float lc = zf[size_t(c)];
        for (int k = 0; k < 8; ++k) {
            const int32_t n = neighbor_of(cx, cy, k, cols, R, W, wrap);
            if (n < 0 || closed[size_t(n)] != 0) continue;
            closed[size_t(n)] = 1;
            float zn = zf[size_t(n)];
            if (zn <= lc + FILL_EPS) {
                // 洼地/平地内部：抬高到当前水位 + ε，走 FIFO（只有开放边界走堆）
                zn = lc + FILL_EPS;
                zf[size_t(n)] = zn;
                pit.push(n);
            } else {
                open.push(std::make_pair(zn, n));
            }
            if (g.H != nullptr && zn > g.H[size_t(n)] + 0.5f * FILL_EPS) ++pits;
        }
    }
    for (int y = 0; y < R; ++y) {
        const size_t row = size_t(y) * size_t(W);
        for (int x = cols; x < W; ++x) zf[row + size_t(x)] = zf[row + size_t(x % cols)];
    }
    return pits;
}

}  // namespace detail

// ── P2: 流向树（填洼 → 拓扑序 → 最陡受体 → 汇水面积） ──────────────────────

// st 可选：非空时顺带写 pits_in（build_flow 内部填洼的副产品，不加额外扫描）。
inline void build_flow(const Grid &g, Flow &fl, Stats *st = nullptr) {
    const int W = g.w, R = g.h;
    const int cols = detail::periodic_cols(g);
    const bool wrap = detail::wrap_on(g);
    const size_t N = size_t(W) * size_t(R);
    if (W <= 2 || R <= 2 || cols <= 2 || g.H == nullptr) {
        fl.order.clear();
        fl.rcv.assign(N, -1);
        fl.rcv_k.assign(N, 0);
        fl.area_hex.assign(N, 0.0f);
        fl.z_fill.assign(N, 0.0f);
        return;
    }

    // 1. 填洼 + 拓扑序。
    const int32_t pits = detail::priority_flood(g, fl.z_fill, &fl.order);
    if (st != nullptr) st->pits_in = pits;

    // FIFO 快路径在 ε 量级上可能让极少数同高度像素乱序；审计一遍，必要时按 z_fill 稳定排序
    // 恢复「下游先」的合法拓扑序（stable_sort 保留同高度像素原有相对次序，仍确定性）。
    bool monotone = true;
    for (size_t t = 1; t < fl.order.size(); ++t) {
        if (fl.z_fill[size_t(fl.order[t])] < fl.z_fill[size_t(fl.order[t - 1])]) {
            monotone = false;
            break;
        }
    }
    if (!monotone) {
        const std::vector<float> &zf = fl.z_fill;
        std::stable_sort(fl.order.begin(), fl.order.end(),
                [&zf](int32_t a, int32_t b) { return zf[size_t(a)] < zf[size_t(b)]; });
    }

    // 2. 最陡受体：argmax_k (z[i]-z[nb_k])/DL[k]，只接受严格更低的邻点；平局取 k 小者。
    //    水体/出口 rcv = -1。受体取自填洼面（保证严格更低 → order 仍是合法拓扑序）。
    //
    // [S7-T7 2026-11-18] G2（计划 §10.4-3）：注入开启时，**河心像素**的受体优先选「同为河心、
    //   且所属 cell 等于本 cell 或本 cell 的下游 cell」的邻像素（平局再取最陡），免得干流在格内
    //   被最陡下降打散成乱走的折线（风险 G-K3）；找不到合格河心邻时退回普通最陡下降。
    //   注入关闭时下面的旧循环**一字不改、整段独走**（没有任何新增的逐像素判断）——这是
    //   dem_spl_inject_cell_area=false 时逐位一致的关键。
    fl.rcv.assign(N, -1);
    fl.rcv_k.assign(N, 0);
    const bool inject_on = detail::inject_on(g);
    if (!inject_on) {
        for (int y = 0; y < R; ++y) {
            for (int x = 0; x < cols; ++x) {
                const size_t i = size_t(y) * size_t(W) + size_t(x);
                if (detail::is_wet(g, i)) continue;
                const double zi = double(fl.z_fill[i]);
                double best_s = 0.0;
                int best_k = -1;
                int32_t best_n = -1;
                for (int k = 0; k < 8; ++k) {
                    const int32_t n = detail::neighbor_of(x, y, k, cols, R, W, wrap);
                    if (n < 0) continue;
                    const double dz = zi - double(fl.z_fill[size_t(n)]);
                    if (dz <= 0.0) continue;                       // 只要严格更低
                    const double slope = dz / dir_len()[k];
                    if (slope > best_s) {                          // 严格 >：平局保留 k 小者
                        best_s = slope;
                        best_k = k;
                        best_n = n;
                    }
                }
                if (best_k >= 0) {
                    fl.rcv[i] = best_n;
                    fl.rcv_k[i] = uint8_t(best_k);
                }
            }
        }
    } else {
        // ── [S7-T7] 注入分支：河心优先受体；其余像素（以及优先集为空时的河心像素）算式与旧实现相同 ──
        for (int y = 0; y < R; ++y) {
            for (int x = 0; x < cols; ++x) {
                const size_t i = size_t(y) * size_t(W) + size_t(x);
                if (detail::is_wet(g, i)) continue;
                const double zi = double(fl.z_fill[i]);
                double best_s = 0.0;
                int best_k = -1;
                int32_t best_n = -1;
                if (detail::is_river_px(g, i)) {
                    const int32_t ci = g.cell_id[i];
                    int32_t cd = -1;
                    if (ci >= 0 && ci < g.n_cells) cd = g.cell_downstream[ci];
                    for (int k = 0; k < 8; ++k) {
                        const int32_t n = detail::neighbor_of(x, y, k, cols, R, W, wrap);
                        if (n < 0) continue;
                        const size_t sn = size_t(n);
                        if (!detail::is_river_px(g, sn)) continue;      // 必须是河心
                        const int32_t cn = g.cell_id[sn];
                        if (cn < 0 || cn >= g.n_cells) continue;
                        if (!((ci >= 0 && cn == ci) || (cd >= 0 && cn == cd))) continue;  // 本格或下游格
                        const double dz = zi - double(fl.z_fill[sn]);
                        if (dz <= 0.0) continue;                        // 仍要求严格更低（拓扑序）
                        const double slope = dz / dir_len()[k];
                        if (slope > best_s) {                           // 平局保留 k 小者
                            best_s = slope;
                            best_k = k;
                            best_n = n;
                        }
                    }
                }
                if (best_k < 0) {
                    // 非河心 / 河心但优先集为空：退回最陡下降（与旧实现同一算式同一顺序）
                    best_s = 0.0;
                    for (int k = 0; k < 8; ++k) {
                        const int32_t n = detail::neighbor_of(x, y, k, cols, R, W, wrap);
                        if (n < 0) continue;
                        const double dz = zi - double(fl.z_fill[size_t(n)]);
                        if (dz <= 0.0) continue;
                        const double slope = dz / dir_len()[k];
                        if (slope > best_s) {
                            best_s = slope;
                            best_k = k;
                            best_n = n;
                        }
                    }
                }
                if (best_k >= 0) {
                    fl.rcv[i] = best_n;
                    fl.rcv_k[i] = uint8_t(best_k);
                }
            }
        }
    }

    // 3. 汇水面积：沿 order 逆序（上游 → 下游）累加；wet 不累加也不作目标。
    const double unit_area = 1.0 / std::max(1e-12, g.hex_px * g.hex_px);
    fl.area_hex.assign(N, float(unit_area));
    // [S7-T7 2026-11-18] G2（计划 §10.4-2）：河心像素的初始汇水 = 1/hex_px² + inject_area[i]。
    //   注入关闭时这段整体跳过，初值仍是逐像素的 1/hex_px²（与改动前逐位相同）。
    if (inject_on) {
        for (int y = 0; y < R; ++y) {
            const size_t row = size_t(y) * size_t(W);
            for (int x = 0; x < cols; ++x) {
                const size_t i = row + size_t(x);
                const double add = double(g.inject_area[i]);
                if (add > 0.0) fl.area_hex[i] = float(double(fl.area_hex[i]) + add);
            }
        }
    }
    for (size_t oi = fl.order.size(); oi-- > 0;) {
        const int32_t i = fl.order[oi];
        if (detail::is_wet(g, size_t(i))) continue;
        const int32_t r = fl.rcv[size_t(i)];
        if (r < 0) continue;
        fl.area_hex[size_t(r)] = float(double(fl.area_hex[size_t(r)]) + double(fl.area_hex[size_t(i)]));
    }

    // 4. 别名列镜像（rcv / rcv_k / area_hex / z_fill）。
    if (cols < W) {
        for (int y = 0; y < R; ++y) {
            const size_t row = size_t(y) * size_t(W);
            for (int x = cols; x < W; ++x) {
                const size_t d = row + size_t(x);
                const size_t s = row + size_t(x % cols);
                fl.rcv[d] = fl.rcv[s];
                fl.rcv_k[d] = fl.rcv_k[s];
                fl.area_hex[d] = fl.area_hex[s];
                fl.z_fill[d] = fl.z_fill[s];
            }
        }
    }
}

}  // namespace pk_erosion
