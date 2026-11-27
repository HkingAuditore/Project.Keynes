#pragma once

// 烘焙期地形侵蚀核：汇流驱动的隐式 SPL 下切 + 输运受限沉积 + 限坡 + 计算栅格缩放。
//
// 设计权威：docs/plans/terrain-erosion-spl-plan.md §4.2–§4.7；
// 接口契约：docs/plans/terrain-erosion-spl-contracts.md §2（字段名/函数名/语义逐字遵守）。
//
//  · 单位物理化：长度/面积参数一律以「hex」为单位，栅格只通过 hex_px（一个 hex 跨度对应的
//    像素数）进入公式，所以 512 / 1024 / 2048 三档平台的宏观强度一致（不变量 5）。
//    面积用 hex^2（单像素初值 1/hex_px^2），受体距离用 dir_len/hex_px。
//  · 只降不升：spl_incise / crest_round / slope_limit 只会把高度往下改；deposit 只把 SPL
//    削掉的部分**部分**填回，上限仍是 H_pre（不变量 1）。陆地像素不低于 sea_level+sea_eps
//    （不变量 2）；wet 像素（水体，G2 注入开启后不再含河心）逐位不变，且不作限坡约束源（不变量 3）。
//  · [S7-T7 2026-11-18] G2 可选注入（Grid.inject_area/cell_id/cell_downstream 全非空才生效）：
//    河心像素从「汇水出口」变成「带外部汇水的普通陆地像素」，照常进入流向树并被下切/限坡；
//    三个指针任一为 nullptr 时，build_flow 的两处注入分支整体不进入，行为与改动前逐位一致。
//  · 全串行、确定性：无 parallel_for、无 RNG、无时间依赖、无可变全局状态；同输入逐位同输出
//    （不变量 6）。存储用 float、中间计算用 double，pow 用 double。
//  · 一棵流向树贯穿全流程：build_flow 给出填洼面 / 拓扑序 / 最陡受体 / 汇水面积，后面的系数
//    预计算、下切、沉积都复用它（受体在 pass 内不重算，pow 每像素只算一次）。
//
// 栅格几何约定（与 bake_dem_landform.h 的 carve 逐字一致）：
//  · 方向表 DX={1,-1,0,0,1,1,-1,-1}、DY={0,0,1,-1,1,-1,1,-1}、DL=1/√2；倒角扫描前向集
//    {1,3,5,7}（左/上邻）、后向集 {0,2,4,6}（右/下邻）。
//  · wrap_cols > 2 且 <= w 时，前 wrap_cols 列构成一个经线周期，x >= wrap_cols 的列是
//    x - wrap_cols 的别名（同一世界位置的重复像素）。计算只在前 wrap_cols 列上做，结束后
//    把结果镜像到别名列，因此调用方拿到的 H 在整幅宽度上自洽。
//  · 出口 = wet ∪ 南北边缘；wrap 生效时东西向不设边缘出口（靠环绕）。
//
// 执行顺序不可换（契约 §3.2）：build_flow → precompute_coeff → spl_incise
//   → [dep.enabled] deposit → [dep.floor_widen] floor_widen → slope_limit。
//
// 纯 C++、header-only、全 inline、零 Godot 依赖；允许单独编译（见契约 §2.4 自测）。

#include "bake_erosion_spl_flow.h"

namespace pk_erosion {

// ── P2: 下切系数预计算 ─────────────────────────────────────────────────────

// C[i] = K_iter · A_hex^m / (DL[k]/hex_px)，K_iter = k_total / max(1, iters)。
// 受体与面积在本 pass 内固定，pow 每像素只算一次（每轮只剩一次乘加扫描）。
inline void precompute_coeff(const Grid &g, const Flow &fl, const SplParams &sp,
        std::vector<float> &C) {
    const int W = g.w, R = g.h;
    const int cols = detail::periodic_cols(g);
    const size_t N = size_t(W) * size_t(R);
    C.assign(N, 0.0f);
    if (fl.rcv.size() < N || fl.area_hex.size() < N || fl.rcv_k.size() < N) return;
    const int iters = sp.iters > 0 ? sp.iters : 1;
    const double k_iter = sp.k_total / double(iters);
    const double inv_hex = 1.0 / std::max(1e-12, g.hex_px);
    for (int y = 0; y < R; ++y) {
        const size_t row = size_t(y) * size_t(W);
        for (int x = 0; x < cols; ++x) {
            const size_t i = row + size_t(x);
            if (detail::is_wet(g, i)) continue;
            if (fl.rcv[i] < 0) continue;
            const double area = double(fl.area_hex[i]);
            if (area < sp.min_area_hex) continue;
            const double dx_hex = dir_len()[fl.rcv_k[i]] * inv_hex;
            if (dx_hex <= 1e-12) continue;
            C[i] = float(k_iter * pk::simulation_math::pow(area, sp.m) / dx_hex);
        }
    }
}

// ── P2: 隐式 SPL 下切 ──────────────────────────────────────────────────────

// 按 order 正序（下游先）逐轮扫描：h_new = (h + C·h[rcv]) / (1 + C)，clamp 到
// [sea+eps, h]（只降、不下海）。受体在本轮已算过，所以是隐式下游→上游的一次线性扫描。
inline void spl_incise(Grid &g, const Flow &fl, const std::vector<float> &C, const SplParams &sp,
        Stats &st) {
    const int W = g.w, R = g.h;
    const int cols = detail::periodic_cols(g);
    const size_t N = size_t(W) * size_t(R);
    const int iters = sp.iters > 0 ? sp.iters : 1;
    st.iters_effective = iters;
    if (g.H == nullptr || g.H_pre == nullptr || C.size() < N || fl.rcv.size() < N) {
        st.nan = 0;
        st.max_drop = 0.0;
        st.p99_drop = 0.0;
        st.eroded_vol = 0.0;
        return;
    }
    const double floor_h = g.sea_level + g.sea_eps;
    for (int it = 0; it < iters; ++it) {
        for (size_t oi = 0; oi < fl.order.size(); ++oi) {
            const int32_t i = fl.order[oi];
            const size_t si = size_t(i);
            if (detail::is_wet(g, si)) continue;
            if (C[si] <= 0.0f) continue;
            const int32_t r = fl.rcv[si];
            if (r < 0) continue;
            const double ci = double(C[si]);
            const double hi = double(g.H[si]);
            const double h_new = (hi + ci * double(g.H[size_t(r)])) / (1.0 + ci);
            // 陆地不下海：H_pre 在水面之上才设地板（洼地内 h[rcv] > h[i] 时靠下面的 min 截住）
            double h_clamped = h_new;
            if (double(g.H_pre[si]) > g.sea_level && h_clamped < floor_h) {
                h_clamped = floor_h;
                ++st.sea_clamped;
            }
            if (h_clamped < hi) g.H[si] = float(h_clamped);   // 只降，绝不上抬
        }
    }
    detail::enforce_land_floor(g, &st.sea_clamped);

    // 统计：drop = H_pre - H（仅陆地非 wet），max_drop / p99_drop（4096 桶直方图，确定性）/
    // eroded_vol（height·px，逐像素体积代理）/ nan（!isfinite）。
    double max_drop = 0.0, eroded = 0.0;
    int64_t nan_cnt = 0, n_land = 0;
    for (int y = 0; y < R; ++y) {
        const size_t row = size_t(y) * size_t(W);
        for (int x = 0; x < cols; ++x) {
            const size_t i = row + size_t(x);
            const double hi = double(g.H[i]);
            if (!std::isfinite(hi)) {
                ++nan_cnt;
                continue;
            }
            if (detail::is_wet(g, i)) continue;
            if (double(g.H_pre[i]) <= g.sea_level) continue;
            const double d = double(g.H_pre[i]) - hi;
            if (d <= 0.0) continue;
            eroded += d;
            if (d > max_drop) max_drop = d;
            ++n_land;
        }
    }
    st.max_drop = max_drop;
    st.eroded_vol = eroded;
    st.nan = nan_cnt;
    st.p99_drop = 0.0;
    if (max_drop > 0.0 && n_land > 0) {
        constexpr int BUCKETS = 4096;
        std::vector<int32_t> hist(size_t(BUCKETS), 0);
        const double scale = double(BUCKETS) / max_drop;
        for (int y = 0; y < R; ++y) {
            const size_t row = size_t(y) * size_t(W);
            for (int x = 0; x < cols; ++x) {
                const size_t i = row + size_t(x);
                if (detail::is_wet(g, i)) continue;
                if (double(g.H_pre[i]) <= g.sea_level) continue;
                const double d = double(g.H_pre[i]) - double(g.H[i]);
                if (d <= 0.0) continue;
                int b = int(d * scale);
                if (b < 0) b = 0;
                if (b >= BUCKETS) b = BUCKETS - 1;
                ++hist[size_t(b)];
            }
        }
        const int64_t target = (n_land * 99 + 99) / 100;   // ceil(0.99·n)
        int64_t cum = 0;
        for (int b = 0; b < BUCKETS; ++b) {
            cum += int64_t(hist[size_t(b)]);
            if (cum >= target) {
                st.p99_drop = double(b + 1) / double(BUCKETS) * max_drop;
                break;
            }
        }
    }
    detail::mirror_alias_cols(g);
}

// ── P3a: 输运受限沉积（默认关） ────────────────────────────────────────────

// 沿 order 逆序（上游先）累积削蚀体积：超出搬运能力 Qc 的部分按 rate 填回本像素，
// 上限 = min(H_pre, min_child_h - eps) —— 因此「h <= h_pre」与「不高于任一上游子像素（不造洼）」
// 同时成立；剩余泥沙交给下游，wet 处丢弃（不做三角洲）。体积守恒：ΣD <= Σdrop。
inline void deposit(Grid &g, const Flow &fl, const DepParams &dp, const SplParams &sp, Stats &st) {
    if (!dp.enabled) return;
    if (g.H == nullptr || g.H_pre == nullptr) return;
    const int W = g.w, R = g.h;
    const size_t N = size_t(W) * size_t(R);
    if (fl.rcv.size() < N || fl.area_hex.size() < N || fl.rcv_k.size() < N) return;
    const double inf = std::numeric_limits<double>::infinity();
    const double inv_hex = 1.0 / std::max(1e-12, g.hex_px);
    std::vector<double> Qs(N, 0.0);           // 过境泥沙体积（height·px）
    std::vector<double> min_child_h(N, inf);  // 已 finalize 的最矮上游子像素
    double deposited = 0.0;
    for (size_t oi = fl.order.size(); oi-- > 0;) {
        const int32_t i = fl.order[oi];
        const size_t si = size_t(i);
        if (detail::is_wet(g, si)) continue;               // 出口：泥沙丢弃，不做三角洲
        const double drop = double(g.H_pre[si]) - double(g.H[si]);
        if (drop > 0.0) Qs[si] += drop;
        const int32_t r = fl.rcv[si];
        if (r < 0) continue;
        const size_t sr = size_t(r);
        const double dx_hex = dir_len()[fl.rcv_k[si]] * inv_hex;
        const double slope = std::max(double(g.H[si]) - double(g.H[sr]), 0.0) / dx_hex;
        const double area = double(fl.area_hex[si]);
        const double qc = dp.kc * pk::simulation_math::pow(area, sp.m) * slope;  // 搬运能力（同指数 m）
        if (Qs[si] > qc && area >= dp.min_area_hex) {
            double room = double(g.H_pre[si]) - double(g.H[si]);   // 不高于侵蚀前
            const double room_child = min_child_h[si] - 1e-6 - double(g.H[si]); // 不高于上游子像素
            if (room_child < room) room = room_child;
            if (room > 0.0) {
                double D = (Qs[si] - qc) * dp.rate;
                if (D > room) D = room;
                if (D > Qs[si]) D = Qs[si];                        // 守恒兜底（默认 rate 下不触发）
                if (D > 0.0) {
                    g.H[si] = float(double(g.H[si]) + D);
                    Qs[si] -= D;
                    deposited += D;
                }
            }
        }
        // 子像素已 finalize：更新父的 min_child_h，余沙交给下游
        if (double(g.H[si]) < min_child_h[sr]) min_child_h[sr] = double(g.H[si]);
        Qs[sr] += Qs[si];
    }
    st.deposited_vol += deposited;
    detail::mirror_alias_cols(g);
}

// ── P3b: 谷底展宽（默认关） ────────────────────────────────────────────────

// 对 A_hex >= floor_min_area_hex 的槽像素，以 w = floor_width_hex·√A_hex 为半宽（hex），
// 把半宽内高于「槽底 + floor_slope·距离」的像素削下来 —— 仍是只降、仍是倒角扫描：
//   1) 倒角距离变换：最近槽像素的距离与其半宽（谁给的目标跨过谁自己的半宽就截断）；
//   2) 槽底按 floor_slope 向外抬（min-plus 两遍扫描，与 P1 限坡同构）；
//   3) 只在半宽带内、且低于当前高度时写回。
inline void floor_widen(Grid &g, const Flow &fl, const DepParams &dp, Stats *st) {
    if (g.H == nullptr || g.H_pre == nullptr) return;
    const int W = g.w, R = g.h;
    const int cols = detail::periodic_cols(g);
    const bool wrap = detail::wrap_on(g);
    const size_t N = size_t(W) * size_t(R);
    if (fl.area_hex.size() < N) return;
    const float finf = std::numeric_limits<float>::infinity();
    const double dinf = std::numeric_limits<double>::infinity();
    std::vector<float> dist(N, finf), rad(N, 0.0f);
    std::vector<uint8_t> seed(N, 0);
    int n_seed = 0;
    for (int y = 0; y < R; ++y) {
        const size_t row = size_t(y) * size_t(W);
        for (int x = 0; x < cols; ++x) {
            const size_t i = row + size_t(x);
            if (detail::is_wet(g, i)) continue;
            const double area = double(fl.area_hex[i]);
            if (area < dp.floor_min_area_hex) continue;
            const double half_px = dp.floor_width_hex * std::sqrt(area) * g.hex_px;
            if (half_px < 0.5) continue;                 // 半宽不足半个像素：展宽无意义
            dist[i] = 0.0f;
            rad[i] = float(half_px);
            seed[i] = 1;
            ++n_seed;
        }
    }
    if (n_seed == 0) return;

    // 1) 倒角距离变换（前/后向各一遍，与 carve 的扫描方向一致）。
    auto relax_dist = [&](int x, int y, const int *ks) {
        const size_t i = size_t(y) * size_t(W) + size_t(x);
        if (seed[i] != 0) return;                        // 槽像素自身 dist=0
        float best = dist[i];
        float best_r = rad[i];
        for (int q = 0; q < 4; ++q) {
            const int k = ks[q];
            const int32_t m = detail::neighbor_of(x, y, k, cols, R, W, wrap);
            if (m < 0) continue;
            const float cand = dist[size_t(m)] + float(dir_len()[k]);
            if (cand < best) {
                best = cand;
                best_r = rad[size_t(m)];
            }
        }
        dist[i] = best;
        rad[i] = best_r;
    };
    static const int FWD[4] = { 1, 3, 5, 7 };
    static const int BWD[4] = { 0, 2, 4, 6 };
    for (int pass = 0; pass < 2; ++pass) {
        for (int y = 0; y < R; ++y)
            for (int x = 0; x < cols; ++x) relax_dist(x, y, FWD);
        for (int y = R - 1; y >= 0; --y)
            for (int x = cols - 1; x >= 0; --x) relax_dist(x, y, BWD);
    }

    // 2) 谷底目标：槽像素为源，按 floor_slope（height / hex）向外抬。
    const double step = dp.floor_slope / std::max(1e-12, g.hex_px);   // height / px
    std::vector<double> bed(N, dinf);
    for (int y = 0; y < R; ++y) {
        const size_t row = size_t(y) * size_t(W);
        for (int x = 0; x < cols; ++x) {
            const size_t i = row + size_t(x);
            if (seed[i] != 0) bed[i] = double(g.H[i]);
        }
    }
    auto relax_bed = [&](int x, int y, const int *ks) {
        const size_t i = size_t(y) * size_t(W) + size_t(x);
        double best = bed[i];
        for (int q = 0; q < 4; ++q) {
            const int k = ks[q];
            const int32_t m = detail::neighbor_of(x, y, k, cols, R, W, wrap);
            if (m < 0) continue;
            const double cand = bed[size_t(m)] + step * dir_len()[k];
            if (cand < best) best = cand;
        }
        bed[i] = best;
    };
    for (int pass = 0; pass < 2; ++pass) {
        for (int y = 0; y < R; ++y)
            for (int x = 0; x < cols; ++x) relax_bed(x, y, FWD);
        for (int y = R - 1; y >= 0; --y)
            for (int x = cols - 1; x >= 0; --x) relax_bed(x, y, BWD);
    }

    // 3) 只在半宽带内写回，只降。
    //    **不能造洼**（不变量 4）：展宽是横切流向的削低，与流向树无关，若不加约束会把岸削到
    //    比自己的下游更低。因此每像素的落点必须先满足「高于自己的受体」——只要这条成立，
    //    该像素就仍有更低邻点，不可能是闭合洼地；受体若稍后也被削低，约束只会更松。
    //    （deposit 先抬高了主槽、floor_widen 后按新槽底削岸时会真的踩到这条，必须显式挡住。）
    const double floor_h = g.sea_level + g.sea_eps;
    int64_t clamped = 0;
    for (int y = 0; y < R; ++y) {
        const size_t row = size_t(y) * size_t(W);
        for (int x = 0; x < cols; ++x) {
            const size_t i = row + size_t(x);
            if (detail::is_wet(g, i)) continue;
            const double d = double(dist[i]);
            if (!(d <= double(rad[i]))) continue;          // 半宽外（或从未被覆盖）
            double t = bed[i];
            const int32_t r = fl.rcv[i];
            if (r >= 0) {
                const double lo = double(g.H[size_t(r)]) + 1e-6;
                if (t < lo) t = lo;                        // 仍要低于自己的下游
            }
            if (double(g.H_pre[i]) > floor_h && t < floor_h) {
                t = floor_h;
                ++clamped;
            }
            if (t < double(g.H[i])) g.H[i] = float(t);     // 只降
        }
    }
    if (st != nullptr) st->sea_clamped += clamped;
    detail::mirror_alias_cols(g);
}

inline void floor_widen(Grid &g, const Flow &fl, const DepParams &dp, Stats &st) {
    floor_widen(g, fl, dp, &st);
}

// ── P1: 凸脊磨圆（可选，限坡之前） ─────────────────────────────────────────

// H[i] += min(0, crest_round · ∇²H)（纯 Laplacian，4 邻域 + wrap）。只取负值 → 只磨圆凸脊、
// 不填谷，满足不变量 1。双缓冲：一次扫描读旧面、写新面，结果与扫描顺序无关（确定性）。
inline void crest_round(Grid &g, const LimParams &lp, Stats *st = nullptr) {
    if (lp.crest_round <= 0.0 || g.H == nullptr) return;
    const int W = g.w, R = g.h;
    const int cols = detail::periodic_cols(g);
    const bool wrap = detail::wrap_on(g);
    const size_t N = size_t(W) * size_t(R);
    std::vector<float> src(N, 0.0f), dst(N, 0.0f);
    for (int y = 0; y < R; ++y) {
        const size_t row = size_t(y) * size_t(W);
        for (int x = 0; x < cols; ++x) src[row + size_t(x)] = g.H[row + size_t(x)];
        for (int x = cols; x < W; ++x) src[row + size_t(x)] = src[row + size_t(x % cols)];
    }
    dst = src;
    static const int NB4[4] = { 0, 1, 2, 3 };   // (1,0) (-1,0) (0,1) (0,-1)
    for (int y = 0; y < R; ++y) {
        const size_t row = size_t(y) * size_t(W);
        for (int x = 0; x < cols; ++x) {
            const size_t i = row + size_t(x);
            if (detail::is_wet(g, i)) continue;                 // 水体不动
            const double h0 = double(src[i]);
            double sum = 0.0;
            for (int q = 0; q < 4; ++q) {
                const int32_t m = detail::neighbor_of(x, y, NB4[q], cols, R, W, wrap);
                sum += (m < 0) ? h0 : double(src[size_t(m)]);     // 南北边缘克隆自身（∇²=0）
            }
            const double lap = sum - 4.0 * h0;
            if (lap < 0.0) {
                const double h_new = h0 + lp.crest_round * lap;
                if (h_new < h0) dst[i] = float(h_new);
            }
        }
    }
    for (int y = 0; y < R; ++y) {
        const size_t row = size_t(y) * size_t(W);
        for (int x = 0; x < cols; ++x) g.H[row + size_t(x)] = dst[row + size_t(x)];
    }
    detail::enforce_land_floor(g, st != nullptr ? &st->sea_clamped : nullptr);
    detail::mirror_alias_cols(g);
}

// ── P1: 限坡（只削高侧） ───────────────────────────────────────────────────

// 坡面物质被认为已被河流带走，所以只降不升（v1 的 thermal 会抬高谷底，与不变量 1 冲突）。
//   s[i]   = per_relief · max(relief[i], relief_floor) / hex      （坡限，height / hex）
//   cap[i] = cap_per_relief · relief[i]                            （单像素最大削减）
//   L[i]   = max( min(L[i], min_m(L[m] + s[i]·DL[k]/hex_px)), H[i] − cap[i] )
// 前/后向倒角扫描 2 遍（每遍各含正向与反向两次扫描），与 carve 第 4 步同构、串行、确定性。
// wet 像素既不改、也不作为约束源；relief = 0 的平原 cap = 0 → 逐位不变。
inline void slope_limit(Grid &g, const LimParams &lp, Stats &st) {
    if (g.H == nullptr) return;
    if (lp.crest_round > 0.0) crest_round(g, lp, &st);   // 可选：限坡之前磨圆凸脊
    const int W = g.w, R = g.h;
    const int cols = detail::periodic_cols(g);
    const bool wrap = detail::wrap_on(g);
    const size_t N = size_t(W) * size_t(R);
    std::vector<double> L(N, 0.0), s(N, 0.0), cap(N, 0.0);
    const double inv_hex = 1.0 / std::max(1e-12, g.hex_px);
    for (int y = 0; y < R; ++y) {
        const size_t row = size_t(y) * size_t(W);
        for (int x = 0; x < cols; ++x) {
            const size_t i = row + size_t(x);
            L[i] = double(g.H[i]);
            const double r = detail::relief_at(g, i);
            s[i] = lp.per_relief * std::max(r, lp.relief_floor) * inv_hex;
            cap[i] = lp.cap_per_relief * r;
        }
    }
    // 单个扫描步：4 个邻居候选取 min，再用 cap 兜底下限。水体不改（也不作源）。
    auto scan = [&](int x, int y, const int *ks) {
        const size_t i = size_t(y) * size_t(W) + size_t(x);
        if (detail::is_wet(g, i)) return;
        for (int q = 0; q < 4; ++q) {
            const int k = ks[q];
            const int32_t m = detail::neighbor_of(x, y, k, cols, R, W, wrap);
            if (m < 0) continue;
            if (detail::is_wet(g, size_t(m))) continue;      // 水体不作约束源
            const double cand = L[size_t(m)] + s[i] * dir_len()[k];
            if (cand < L[i]) L[i] = cand;
        }
        const double lo = double(g.H[i]) - cap[i];
        if (L[i] < lo) L[i] = lo;
    };
    static const int FWD[4] = { 1, 3, 5, 7 };   // (-1,0) (0,-1) (1,-1) (-1,-1)
    static const int BWD[4] = { 0, 2, 4, 6 };   // (1,0) (0,1) (1,1) (-1,1)
    for (int pass = 0; pass < 2; ++pass) {
        for (int y = 0; y < R; ++y)
            for (int x = 0; x < cols; ++x) scan(x, y, FWD);
        for (int y = R - 1; y >= 0; --y)
            for (int x = cols - 1; x >= 0; --x) scan(x, y, BWD);
    }
    // 写回：只降（L <= H 恒成立），陆地 clamp 到 sea+eps。
    for (int y = 0; y < R; ++y) {
        const size_t row = size_t(y) * size_t(W);
        for (int x = 0; x < cols; ++x) {
            const size_t i = row + size_t(x);
            if (detail::is_wet(g, i)) continue;
            if (L[i] < double(g.H[i])) g.H[i] = float(L[i]);
        }
    }
    detail::enforce_land_floor(g, &st.sea_clamped);
    detail::mirror_alias_cols(g);
}

// ── 辅助：填洼复核 / 计算栅格缩放 ──────────────────────────────────────────

// 需要填高的像素数（z_filled > z_orig + 0.5·FILL_EPS）；与 build_flow 同一套 float + FIFO 填洼。
inline int32_t count_pits(const Grid &g) {
    if (g.H == nullptr || g.w <= 2 || g.h <= 2) return 0;
    std::vector<float> zf;
    return detail::priority_flood(g, zf, nullptr);
}

// 盒式下采样（wrap 感知：x 按 w 取模；越界 y 克隆边缘）。f == 1 时为直接拷贝。
// dst 尺寸 = (w/f) × (h/f)（向下取整、至少 1）。
inline void downsample_box_f32(const float *src, int w, int h, int f, float *dst) {
    if (src == nullptr || dst == nullptr || w <= 0 || h <= 0) return;
    if (f <= 1) {
        for (size_t i = 0; i < size_t(w) * size_t(h); ++i) dst[i] = src[i];
        return;
    }
    const int dw = std::max(1, w / f);
    const int dh = std::max(1, h / f);
    const double inv = 1.0 / double(f * f);
    for (int y = 0; y < dh; ++y) {
        for (int x = 0; x < dw; ++x) {
            double acc = 0.0;
            for (int j = 0; j < f; ++j) {
                int sy = y * f + j;
                if (sy >= h) sy = h - 1;                 // 越界克隆边缘
                const size_t row = size_t(sy) * size_t(w);
                for (int i = 0; i < f; ++i) {
                    const int sx = (x * f + i) % w;      // wrap 感知
                    acc += double(src[row + size_t(sx)]);
                }
            }
            dst[size_t(y) * size_t(dw) + size_t(x)] = float(acc * inv);
        }
    }
}

// 盒式下采样（uint8 掩码）：块内均值 >= 0.5 → 1，否则 0（面积多数表决）。
inline void downsample_box_u8(const uint8_t *src, int w, int h, int f, uint8_t *dst) {
    if (src == nullptr || dst == nullptr || w <= 0 || h <= 0) return;
    if (f <= 1) {
        for (size_t i = 0; i < size_t(w) * size_t(h); ++i) dst[i] = src[i];
        return;
    }
    const int dw = std::max(1, w / f);
    const int dh = std::max(1, h / f);
    const int half = (f * f + 1) / 2;
    for (int y = 0; y < dh; ++y) {
        for (int x = 0; x < dw; ++x) {
            int acc = 0;
            for (int j = 0; j < f; ++j) {
                int sy = y * f + j;
                if (sy >= h) sy = h - 1;
                const size_t row = size_t(sy) * size_t(w);
                for (int i = 0; i < f; ++i) {
                    const int sx = (x * f + i) % w;
                    if (src[row + size_t(sx)] != 0) ++acc;
                }
            }
            dst[size_t(y) * size_t(dw) + size_t(x)] = (acc >= half) ? uint8_t(1) : uint8_t(0);
        }
    }
}

// delta 双线性放大：dst(x,y) = bilinear(src, u, v)，u = (x+0.5)/f - 0.5、v = (y+0.5)/f - 0.5；
// u 按 w 取模（wrap），v 夹紧到 [0,h-1]。权重全非负 → src 非负时输出非负、无 NaN。
//
// 性能（两层优化，都保证逐位不变）：
//  1) 列向：u / i0 / tu 只与列号 x 有关（y 无关），先算成长度 w_hi 的表；内层不再调
//     std::fmod / std::floor（原来是逐像素库调用，Web high 2048×1212 上 2.48M 次 ≈ 主导开销）。
//  2) 行向：a(row) = 该源行的 x 向插值，相邻输出行共享 j0/j1，用两个槽缓存最近两行，
//     每个源行只算一次（x 向插值次数从 2·w_hi·h_hi 降到 w_hi·h）。
// **表内/缓存内必须沿用与逐像素内联版完全相同的算式**（(double(x)+0.5)*inv_f-0.5 → fmod(w)
// → floor → clamp → tu = u - i0；a = s0*(1-tu) + s1*tu），否则等价写法也可能有 1 ulp 的
// 舍入差异，破坏"逐位不变"（实测 2048×1212/factor=2：旧实现 /O2 12.0 ms → 现 1.44 ms，
// /Od 52.1 ms → 5.68 ms，8 组用例 memcmp 全等）。
inline void upsample_box_f32(const float *src, int w, int h, int f, float *dst, int w_hi, int h_hi) {
    if (src == nullptr || dst == nullptr || w <= 0 || h <= 0 || w_hi <= 0 || h_hi <= 0) return;
    if (f <= 0) f = 1;
    const double inv_f = 1.0 / double(f);
    const double fw = double(w);

    // 列向映射表（逐列常量，与 y 无关）。只存 i0 与 tu（12 B/px）：i1 与 (1-tu) 由它们推出，
    // 省一半表带宽 —— 内层是纯内存/标量混合瓶颈，/Od 构建下这一点直接体现为耗时。
    const size_t nx = size_t(w_hi);
    std::vector<int32_t> i0tab(nx);
    std::vector<double> tutab(nx);
    for (int x = 0; x < w_hi; ++x) {
        double u = (double(x) + 0.5) * inv_f - 0.5;
        u = std::fmod(u, fw);
        if (u < 0.0) u += fw;
        int i0 = int(std::floor(u));
        if (i0 < 0) i0 = 0;
        if (i0 > w - 1) i0 = w - 1;
        i0tab[size_t(x)] = int32_t(i0);
        tutab[size_t(x)] = u - double(i0);
    }
    const int32_t *i0p = i0tab.data();
    const double *tup = tutab.data();
    const int wlast = w - 1;

    // 行向复用：a(row) = 该源行的 x 向插值（double，与逐像素版**同一个表达式**），复用不改变
    // 任何一个 bit。相邻输出行共享 j0/j1（factor=2 时第一次的 j1 就是下一段的 j0），滚动两个槽
    // 缓存最近两行，使每个源行只算一次：x 向插值次数从 2·W_hi·H_hi 降到 W_hi·H。
    std::vector<double> arow_a(nx), arow_b(nx);
    int have_a = -1, have_b = -1;
    const float *srcbase = src;
    auto fill_arow = [&](int j, std::vector<double> &buf) {
        const float *s = srcbase + size_t(j) * size_t(w);
        double *bp = buf.data();
        for (int x = 0; x < w_hi; ++x) {
            const int c0 = int(i0p[x]);
            const int c1 = (c0 < wlast) ? (c0 + 1) : 0;   // u 按 w 取模 → 右邻回绕
            const double tu = tup[x];
            bp[x] = double(s[c0]) * (1.0 - tu) + double(s[c1]) * tu;
        }
    };

    for (int y = 0; y < h_hi; ++y) {
        double v = (double(y) + 0.5) * inv_f - 0.5;
        if (v < 0.0) v = 0.0;
        if (v > double(h - 1)) v = double(h - 1);
        int j0 = int(std::floor(v));
        if (j0 < 0) j0 = 0;
        if (j0 > h - 1) j0 = h - 1;
        const int j1 = (j0 + 1 < h) ? (j0 + 1) : j0;
        const double tv = v - double(j0);
        const double omtv = 1.0 - tv;
        // 取行 j0 的 a 缓存：命中直接返回，否则覆盖一个"这一行用不到"的槽。
        const double *ptr0;
        if (have_a == j0) {
            ptr0 = arow_a.data();
        } else if (have_b == j0) {
            ptr0 = arow_b.data();
        } else if (have_a != j1) {
            fill_arow(j0, arow_a);
            have_a = j0;
            ptr0 = arow_a.data();
        } else {
            fill_arow(j0, arow_b);
            have_b = j0;
            ptr0 = arow_b.data();
        }
        // 取行 j1 的 a 缓存（j1 == j0 的末行直接复用 ptr0）。
        const double *ptr1;
        if (j1 == j0) {
            ptr1 = ptr0;
        } else if (have_a == j1) {
            ptr1 = arow_a.data();
        } else if (have_b == j1) {
            ptr1 = arow_b.data();
        } else if (have_a != j0) {
            fill_arow(j1, arow_a);
            have_a = j1;
            ptr1 = arow_a.data();
        } else {
            fill_arow(j1, arow_b);
            have_b = j1;
            ptr1 = arow_b.data();
        }
        float *dp = dst + size_t(y) * size_t(w_hi);
        for (int x = 0; x < w_hi; ++x) dp[x] = float(ptr0[x] * omtv + ptr1[x] * tv);
    }
}

}  // namespace pk_erosion
