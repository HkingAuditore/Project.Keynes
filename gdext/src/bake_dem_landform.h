#pragma once

// 烘焙期 DEM 地貌：顺坡延伸的沟谷 / 山脊 + 沿粗沟坡壁分叉的支沟。
// 单元格高程经 barycentric 插值后只有平滑大坡，读不出真实地形顺坡而下的水系纹理；
// 这里按侵蚀滤波的思路在世界空间叠加多倍频条纹：每个抖动特征点贡献一段余弦起伏，
// 相位沿垂直于下坡的方向变化，条纹因此顺坡延伸；每层把已累积的沟谷坡度并入走向，
// 细层顺着粗层沟壁流下，形成树枝状结构。
//
// 纯函数、只读输入，可在并行行循环里直接调用。X 方向格子数取整到 wrap 周期，经线环绕无缝。

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <functional>
#include <queue>
#include <utility>
#include <vector>

namespace pk_dem {

struct LandformParams {
    double wrap_period_x = 0.0;    // <= 0：不环绕
    double base_wavelength = 1.0;  // 最粗一层沟距（世界单位）
    double min_wavelength = 0.0;   // 波长低于它的倍频不叠加（按栅格奈奎斯特设定，防混叠）
    int max_octaves = 3;
    double gain = 0.5;             // 逐层振幅衰减
    uint32_t seed = 0;
};

inline uint32_t hash_u32(uint32_t x) {
    x ^= x >> 16;
    x *= 0x7feb352dU;
    x ^= x >> 15;
    x *= 0x846ca68bU;
    x ^= x >> 16;
    return x;
}

inline double hash01(int64_t cx, int64_t cy, uint32_t salt) {
    const uint32_t hx = hash_u32(uint32_t(cx) * 0x8da6b343U ^ salt);
    const uint32_t h = hash_u32(hx ^ (uint32_t(cy) * 0xd8163841U));
    return double(h) * (1.0 / 4294967296.0);
}

// (px, py) 为格坐标；(dx, dy) 为单位向量，条纹沿它变相位。cells_x > 0 时 x 格下标按周期取模。
// 输出 h ∈ [-1, 1] 及其对格坐标的梯度（忽略权重项的导数，只用于走向偏转）。
inline void gully(double px, double py, double dx, double dy, int64_t cells_x, uint32_t salt,
        double &h, double &hx, double &hy) {
    constexpr double TAU = 6.283185307179586;
    const double fx0 = std::floor(px);
    const double fy0 = std::floor(py);
    const int64_t ix = int64_t(fx0);
    const int64_t iy = int64_t(fy0);
    const double fx = px - fx0;
    const double fy = py - fy0;
    double acc_h = 0.0, acc_x = 0.0, acc_y = 0.0, wsum = 0.0;
    for (int j = -1; j <= 1; ++j) {
        for (int i = -1; i <= 1; ++i) {
            int64_t cx = ix + i;
            if (cells_x > 0) {
                cx %= cells_x;
                if (cx < 0) cx += cells_x;
            }
            const int64_t cy = iy + j;
            const double jx = hash01(cx, cy, salt) - 0.5;
            const double jy = hash01(cx, cy, salt ^ 0x68e31da4U) - 0.5;
            const double ox = fx - double(i) - 0.5 - jx * 0.9;
            const double oy = fy - double(j) - 0.5 - jy * 0.9;
            const double w = std::exp(-(ox * ox + oy * oy) * 2.0);
            const double ph = (ox * dx + oy * dy) * TAU;
            const double s = std::sin(ph);
            acc_h += std::cos(ph) * w;
            acc_x -= s * TAU * dx * w;
            acc_y -= s * TAU * dy * w;
            wsum += w;
        }
    }
    const double inv = wsum > 1e-12 ? 1.0 / wsum : 0.0;
    h = acc_h * inv;
    hx = acc_x * inv;
    hy = acc_y * inv;
}

// (gx, gy)：宏观高程梯度（height / 世界单位），决定下坡走向。amp：最粗一层的高度振幅。
// 返回要叠加到高度上的偏移（零均值，height 单位）。
inline double landform(double wx, double wy, double gx, double gy, double amp,
        const LandformParams &P) {
    if (amp <= 0.0) return 0.0;
    double xw = wx;
    if (P.wrap_period_x > 1e-6) {
        xw = std::fmod(wx, P.wrap_period_x);
        if (xw < 0.0) xw += P.wrap_period_x;
    }
    double out = 0.0, egx = 0.0, egy = 0.0;
    double a = amp;
    double wl = P.base_wavelength;
    for (int k = 0; k < P.max_octaves; ++k) {
        if (wl < P.min_wavelength) break;
        const double sx = gx + egx;
        const double sy = gy + egy;
        const double len = std::sqrt(sx * sx + sy * sy);
        double dx = 1.0, dy = 0.0;
        if (len > 1e-12) {
            dx = sy / len;
            dy = -sx / len;
        }
        int64_t cells_x = 0;
        double cw = wl;
        if (P.wrap_period_x > 1e-6) {
            cells_x = std::max<int64_t>(1, int64_t(std::llround(P.wrap_period_x / wl)));
            cw = P.wrap_period_x / double(cells_x);
        }
        double h = 0.0, hx = 0.0, hy = 0.0;
        gully(xw / cw, wy / cw, dx, dy, cells_x, P.seed + uint32_t(k) * 0x9e3779b9U, h, hx, hy);
        out += h * a;
        egx += hx / cw * a;
        egy += hy / cw * a;
        a *= P.gain;
        wl *= 0.5;
    }
    return out;
}

// ── 填洼（Priority-Flood + ε）────────────────────────────────────────────
// carve 与 SPL 的 spl+carve 分支共用同一份填洼：填洼面 + 出栈序。出栈序对填洼面单调不减，
// 所以任意填洼面严格更低的邻点都排在它前面，可直接当拓扑序（自下游到上游）用。
// 注意：SPL 自己的 float key + FIFO 洼地优化版**不复用**这里——carve 回退路径必须逐位不变。
struct FillResult {
    std::vector<double> z;       // 填洼后的高度面（size = C*R）
    std::vector<int32_t> order;  // Priority-Flood 出栈序（下游 → 上游）；下标用 int32（C*R < 2^31）
    int32_t pits = 0;            // 需填高的像素数（z_filled > z_orig + FILL_EPS/2）
};

// carve 分项耗时（毫秒）。未执行的项保持 -1，调用方据此区分「0 ms」与「没跑」。
struct CarveStats {
    double fill_ms = -1.0;   // 1. 填洼
    double mfd_ms = -1.0;    // 2–3. 多流向汇水面积 + log(面积) → 谷深
    double wall_ms = -1.0;   // 4–6. 谷壁倒角 + 谷底不低于下游 + 写回
    double total_ms = -1.0;  // 整个函数（含 z/rel/wet 装配与分项之间的空档）
};

// 填洼的 ε：每级抬高量。填洼与谷底约束共用，值必须是 1e-7（改动即改输出）。
inline constexpr double FILL_EPS = 1e-7;

// 8 邻域方向表：k 的顺序即邻接遍历顺序（填洼与刻谷共用，禁止改动）。
inline constexpr int DX[8] = { 1, -1, 0, 0, 1, 1, -1, -1 };
inline constexpr int DY[8] = { 0, 0, 1, -1, 1, -1, 1, -1 };
inline constexpr double DL[8] = { 1.0, 1.0, 1.0, 1.0,
        1.4142135623730951, 1.4142135623730951, 1.4142135623730951, 1.4142135623730951 };

// C/R：计算栅格宽高；wrap_cols > 2 且 <= C 时前 wrap_cols 列经线周期；wet 非 0 = 出口。
// 与 carve_drainage_valleys 原先的内联实现逐位等价：同一个 priority_queue<pair<double,int64_t>>
// 键序（含下标决胜）、同一个 FILL_EPS、同一套出口判定与邻接遍历顺序、closed 置位时机相同。
inline void fill_depressions(int C, int R, int wrap_cols, const double *z_in,
        const uint8_t *wet, FillResult &out) {
    out.z.clear();
    out.order.clear();
    out.pits = 0;
    if (C <= 0 || R <= 0 || z_in == nullptr || wet == nullptr) return;
    const size_t N = size_t(C) * size_t(R);
    out.z.assign(z_in, z_in + N);   // 原地填洼：先拷贝输入面
    out.order.reserve(N);

    const bool wrap = wrap_cols > 2 && wrap_cols <= C;
    auto neighbor = [&](int x, int y, int k) -> int64_t {
        int nx = x + DX[k];
        const int ny = y + DY[k];
        if (ny < 0 || ny >= R) return -1;
        if (nx < 0 || nx >= C) {
            if (!wrap) return -1;
            nx = (nx + C) % C;
        }
        return int64_t(ny) * C + nx;
    };

    using Node = std::pair<double, int64_t>;
    std::priority_queue<Node, std::vector<Node>, std::greater<Node>> open;
    std::vector<uint8_t> closed(N, 0);
    for (int y = 0; y < R; ++y) {
        for (int x = 0; x < C; ++x) {
            const int64_t i = int64_t(y) * C + x;
            const bool edge = y == 0 || y == R - 1 || (!wrap && (x == 0 || x == C - 1));
            if (wet[size_t(i)] || edge) {
                closed[size_t(i)] = 1;
                open.emplace(out.z[size_t(i)], i);
            }
        }
    }
    while (!open.empty()) {
        const Node top = open.top();
        open.pop();
        const int64_t c = top.second;
        out.order.push_back(int32_t(c));
        const int cx = int(c % C);
        const int cy = int(c / C);
        for (int k = 0; k < 8; ++k) {
            const int64_t n = neighbor(cx, cy, k);
            if (n < 0 || closed[size_t(n)]) continue;
            closed[size_t(n)] = 1;
            if (out.z[size_t(n)] <= out.z[size_t(c)] + FILL_EPS) out.z[size_t(n)] = out.z[size_t(c)] + FILL_EPS;
            open.emplace(out.z[size_t(n)], n);
        }
    }

    // 诊断：被填高的像素数（阈值取 FILL_EPS 的一半，只统计 ε 以上的真实抬升）。
    for (size_t i = 0; i < N; ++i) {
        if (out.z[i] > z_in[i] + FILL_EPS * 0.5) ++out.pits;
    }
}

// ── 汇流刻谷 ────────────────────────────────────────────────────────────
// 噪声只能给出局部纹理，给不出"小沟汇成大谷"的层级。这里在烘焙高度图上真的跑一遍汇流：
// 填洼后按多流向累积汇水面积，下切深度随 log(面积) 增长，再以有限坡度的谷壁向两侧展开成 V 形谷。
// 汇水网络天然是树枝状的，主谷与格子尺度的地势走向一致。
struct DrainageParams {
    int width = 0;
    int height = 0;
    int wrap_cols = 0;             // > 0：前 wrap_cols 列为经线周期，其后各列是 x - wrap_cols 的别名
    double sea_level = 0.0;
    double hex_px = 1.0;           // 每个六边形跨度对应的像素数
    double depth_per_relief = 0.8; // 主谷最大下切 = 局地起伏 × 该值
    double wall_per_relief = 1.5;  // 谷壁坡度 = 局地起伏 × 该值 / 每六边形
    double area_lo_px = 8.0;       // 汇水面积低于它不下切
    double area_hi_px = 4000.0;    // 汇水面积达到它时满深
    double depth_exp = 0.8;
    double mfd_exponent = 6.0;     // 多流向权重 slope^p；越大越接近单流向
    double wall_relief_floor = 0.04;
};

// H：高度（就地修改）；relief：局地起伏振幅（0 = 平原）；water：非 0 为水体（汇流出口）。
// stats：可选的分配耗时；reuse：可选的同栅格几何填洼结果（spl+carve 分支复用，省掉填洼）。
// 两者都为空时，输出与引入分项计时之前逐位相同（旧的三参数调用点因此无需改动）。
inline void carve_drainage_valleys(float *H, const float *relief, const uint8_t *water,
        const DrainageParams &P, CarveStats *stats = nullptr, const FillResult *reuse = nullptr) {
    if (stats != nullptr) *stats = CarveStats{};   // 全部 -1：未执行的项不冒充 0 ms
    const int W = P.width;
    const int R = P.height;
    if (W <= 2 || R <= 2 || H == nullptr || relief == nullptr || water == nullptr) return;
    const auto t_total = std::chrono::steady_clock::now();
    const auto ms_since = [](std::chrono::steady_clock::time_point t0) {
        return std::chrono::duration<double, std::milli>(
                std::chrono::steady_clock::now() - t0).count();
    };
    const bool wrap = P.wrap_cols > 2 && P.wrap_cols <= W;
    const int C = wrap ? P.wrap_cols : W;
    const size_t N = size_t(C) * size_t(R);

    std::vector<double> z(N);
    std::vector<float> rel(N);
    std::vector<uint8_t> wet(N);
    for (int y = 0; y < R; ++y) {
        for (int x = 0; x < C; ++x) {
            const size_t s = size_t(y) * size_t(W) + size_t(x);
            const size_t d = size_t(y) * size_t(C) + size_t(x);
            z[d] = double(H[s]);
            rel[d] = water[s] ? 0.0f : std::max(0.0f, relief[s]);
            wet[d] = water[s] ? 1 : 0;
        }
    }

    // 方向表 DX/DY/DL 提到命名空间作用域（填洼共用），k 的顺序与语义完全不变。
    auto neighbor = [&](int x, int y, int k) -> int64_t {
        int nx = x + DX[k];
        const int ny = y + DY[k];
        if (ny < 0 || ny >= R) return -1;
        if (nx < 0 || nx >= C) {
            if (!wrap) return -1;
            nx = (nx + C) % C;
        }
        return int64_t(ny) * C + nx;
    };

    // 1. 优先级洪泛填洼（Barnes ε）：出口为水体与地图边缘；出栈序即自下游到上游的拓扑序。
    //    整段实现搬进 fill_depressions（逐位等价）；reuse 非空时直接用外部结果，省掉这次填洼。
    //    reuse 只要求「同栅格几何」：像素数不符时退回自行填洼，宁可慢也不越界。
    FillResult fr_local;
    const FillResult *fr = reuse;
    if (fr != nullptr && (fr->z.size() != N || fr->order.size() != N)) fr = nullptr;
    if (fr == nullptr) {
        const auto t_fill = std::chrono::steady_clock::now();
        fill_depressions(C, R, P.wrap_cols, z.data(), wet.data(), fr_local);
        fr = &fr_local;
        if (stats != nullptr) stats->fill_ms = ms_since(t_fill);
    } else if (stats != nullptr) {
        stats->fill_ms = 0.0;   // 复用外部填洼：本函数没有填洼成本
    }
    const std::vector<double> &zf = fr->z;              // 填洼面（后续所有 z 的引用都改用它）
    const std::vector<int32_t> &order = fr->order;      // 拓扑序，下游 → 上游

    // 2. 多流向汇水面积：自上游向下游，按 slope^p 分配给所有更低的邻点。
    const auto t_mfd = std::chrono::steady_clock::now();
    std::vector<double> area(N, 1.0);
    for (size_t oi = order.size(); oi-- > 0;) {
        const int64_t c = order[oi];
        if (wet[size_t(c)]) continue;
        const int cx = int(c % C);
        const int cy = int(c / C);
        double wsum = 0.0;
        double wk[8];
        int64_t nk[8];
        for (int k = 0; k < 8; ++k) {
            nk[k] = neighbor(cx, cy, k);
            wk[k] = 0.0;
            if (nk[k] < 0) continue;
            const double dz = zf[size_t(c)] - zf[size_t(nk[k])];
            if (dz <= 0.0) continue;
            wk[k] = std::pow(dz / DL[k], P.mfd_exponent);
            wsum += wk[k];
        }
        if (wsum <= 0.0) continue;
        const double a = area[size_t(c)] / wsum;
        for (int k = 0; k < 8; ++k) {
            if (wk[k] > 0.0) area[size_t(nk[k])] += a * wk[k];
        }
    }

    // 3. 谷底下切：随 log(面积) 平滑增长，按局地起伏缩放（平原不刻）。
    const double la0 = std::log(std::max(1.0, P.area_lo_px));
    const double la1 = std::max(la0 + 1e-6, std::log(std::max(1.0, P.area_hi_px)));
    std::vector<double> V(N, 0.0);
    for (size_t i = 0; i < N; ++i) {
        if (wet[i] || rel[i] <= 0.0f) continue;
        double t = (std::log(area[i]) - la0) / (la1 - la0);
        t = std::clamp(t, 0.0, 1.0);
        t = t * t * (3.0 - 2.0 * t);
        V[i] = P.depth_per_relief * double(rel[i]) * std::pow(t, P.depth_exp);
    }
    if (stats != nullptr) stats->mfd_ms = ms_since(t_mfd);

    // 4. 谷壁：V(n) = max(V(n), V(m) - wall(n)·|n-m|)，倒角距离正反两遍扫描（含经线环绕）。
    const auto t_wall = std::chrono::steady_clock::now();
    std::vector<double> wall(N), cap(N);
    const double inv_hex = 1.0 / std::max(1e-6, P.hex_px);
    for (size_t i = 0; i < N; ++i) {
        const double r = double(rel[i]);
        wall[i] = P.wall_per_relief * std::max(r, P.wall_relief_floor) * inv_hex;
        cap[i] = wet[i] ? 0.0 : P.depth_per_relief * r;
    }
    auto relax = [&](int x, int y, const int *ks, int nks) {
        const size_t i = size_t(y) * size_t(C) + size_t(x);
        double v = V[i];
        for (int q = 0; q < nks; ++q) {
            const int k = ks[q];
            const int64_t m = neighbor(x, y, k);
            if (m < 0) continue;
            const double cand = V[size_t(m)] - wall[i] * DL[k];
            if (cand > v) v = cand;
        }
        V[i] = std::min(v, cap[i]);
    };
    static const int FWD[4] = { 1, 3, 5, 7 };   // (-1,0) (0,-1) (1,-1) (-1,-1)
    static const int BWD[4] = { 0, 2, 4, 6 };   // (1,0) (0,1) (1,1) (-1,1)
    for (int pass = 0; pass < 2; ++pass) {
        for (int y = 0; y < R; ++y)
            for (int x = 0; x < C; ++x) relax(x, y, FWD, 4);
        for (int y = R - 1; y >= 0; --y)
            for (int x = C - 1; x >= 0; --x) relax(x, y, BWD, 4);
    }

    // 5. 谷底不低于下游：按拓扑序（出口先），每点不低于其填洼后更低邻点中最低的刻后高度，
    //    支谷在河口 / 海岸处平接，不刻出凹坑。
    std::vector<double> cut(N, 0.0);
    std::vector<double> bed(N);
    for (size_t i = 0; i < N; ++i) {
        const double h0 = double(H[size_t(i / size_t(C)) * size_t(W) + i % size_t(C)]);
        cut[i] = h0;
        bed[i] = wet[i] ? h0 : h0 - V[i];
    }
    for (const int32_t c32 : order) {
        const int64_t c = c32;
        if (wet[size_t(c)]) continue;
        const int cx = int(c % C);
        const int cy = int(c / C);
        double lo = 1e30;
        for (int k = 0; k < 8; ++k) {
            const int64_t m = neighbor(cx, cy, k);
            if (m < 0 || zf[size_t(m)] >= zf[size_t(c)]) continue;
            lo = std::min(lo, bed[size_t(m)]);
        }
        if (lo < 1e29 && bed[size_t(c)] < lo + FILL_EPS) bed[size_t(c)] = lo + FILL_EPS;
    }
    for (size_t i = 0; i < N; ++i) cut[i] = std::max(0.0, cut[i] - bed[i]);

    // 6. 写回：只降不升，陆地不刻到水面以下；别名列复制周期内的值。
    for (int y = 0; y < R; ++y) {
        for (int x = 0; x < W; ++x) {
            const int sx = wrap ? (x % C) : x;
            const size_t s = size_t(y) * size_t(W) + size_t(x);
            const size_t d = size_t(y) * size_t(C) + size_t(sx);
            if (water[s]) continue;
            const double h0 = double(H[s]);
            double h = h0 - cut[d];
            if (h0 > P.sea_level && h <= P.sea_level) h = P.sea_level + 0.0005;
            H[s] = float(h);
        }
    }

    if (stats != nullptr) {
        stats->wall_ms = ms_since(t_wall);
        stats->total_ms = ms_since(t_total);
    }
}

}  // namespace pk_dem
