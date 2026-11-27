#pragma once

// Raster types, neighborhood geometry and height-floor helpers shared by the erosion stages.

#include "simulation_math.h"
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
#include <queue>
#include <utility>
#include <vector>

namespace pk_erosion {

// ── 数据契约（字段名严格照 contracts §2.1） ────────────────────────────────

struct Grid {
    int w = 0;
    int h = 0;
    int wrap_cols = 0;            // >2 且 <= w：前 wrap_cols 列经线周期，其后列是 x - wrap_cols 的别名
    double sea_level = 0.0;
    double sea_eps = 5e-4;
    double hex_px = 1.0;          // 当前栅格上「一个 hex 跨度」的像素数（下采样后必须同步缩小）
    float *H = nullptr;           // 入口 = h_pre；核修改它
    const float *H_pre = nullptr; // 入口高度快照（delta / 沉积上限 / 只降判据）
    const float *relief = nullptr;
    // 1 = 水体/出口像素（不参与下切/限坡）。G2 注入开启时只含**真水体**（pk_is_water_terrain），
    // 河心像素不再是湿区；关闭时沿用旧语义（水体 ∪ 河心）。
    const uint8_t *wet = nullptr;
    // ── [S7-T7 2026-11-18] G2：cell 汇水注入（计划 §10.4；四个成员全为缺省值 = 不注入）──────
    // 像素层原来的「河心像素 = wet 出口」把汇水在河心截断（实测 A_hex p99 只有 1.55 hex²），
    // 干流在像素层从不被 SPL 下切。注入开启后河心像素改为「带外部汇水的普通陆地像素」：
    //   inject_area[i] > 0  ⇔ i 是河心像素，其初始汇水额外加上 inject_area[i]（单位 hex²）；
    //   cell_id[i]          = i 所属 cell.index（与 cell_downstream 同一下标空间）；
    //   cell_downstream[c]  = cell c 的声明下游 cell（-1 = 无），供受体偏好用（风险 G-K3）。
    // 三个指针任一为 nullptr（或 n_cells <= 0）⇒ 注入关闭，build_flow 整段走旧实现（逐位基线）。
    const float *inject_area = nullptr;        // 每像素注入面积（hex²，只有河心像素非 0）
    const int32_t *cell_id = nullptr;          // 每像素所属 cell.index（-1 = 未知）
    const int32_t *cell_downstream = nullptr;  // by cell.index，长度 n_cells（-1 = 无下游）
    int32_t n_cells = 0;                       // cell_downstream 长度 / cell_id 取值上界
};

struct Flow {
    std::vector<int32_t> order;   // 拓扑序：下游 → 上游（出口先出栈）
    std::vector<int32_t> rcv;     // 最陡下降受体下标；-1 = 无严格更低邻点 / 水体 / 出口
    std::vector<uint8_t> rcv_k;   // 受体方向索引 0..7（rcv < 0 时无意义）
    std::vector<float> area_hex;  // 汇水面积，单位 hex^2（单像素初值 1/hex_px^2）
    std::vector<float> z_fill;    // 填洼面（供 spl+carve 复用；不要求时也填，成本可忽略）
};

struct SplParams {
    int iters = 6;
    // 总侵蚀时间（hex 单位）；iters 只把它切成几步。
    // [P2 标定 2026-11-18] 0.50：与 GDScript DEM_DEFAULTS / world_ext_bake.cpp 的 knob 兜底同值，
    //   保证「直接调核」与「走融合 pass」得到同一强度。标定依据见 checklist §A4。
    double k_total = 0.50;
    double m = 0.45;              // 面积指数（地貌学 0.4–0.6）
    double min_area_hex = 0.03;   // 低于它不下切
};

struct DepParams {
    bool enabled = false;
    double kc = 0.02, rate = 0.5, min_area_hex = 0.5;
    bool floor_widen = false;
    double floor_width_hex = 0.04, floor_slope = 0.002, floor_min_area_hex = 2.0;
};

struct LimParams {
    double per_relief = 5.0, relief_floor = 0.04, cap_per_relief = 1.4, crest_round = 0.0;
};

struct Stats {
    double p99_drop = 0.0, max_drop = 0.0;
    double eroded_vol = 0.0, deposited_vol = 0.0;
    int64_t sea_clamped = 0, nan = 0;
    int32_t pits_in = -1, pits_out = -1;   // -1 = 未计算
    int iters_effective = 0;
};

// ── 方向表（与 carve 完全一致，保证 spl+carve 沿同一套邻接） ────────────────

inline const int *dir_dx() {
    static const int DX[8] = { 1, -1, 0, 0, 1, 1, -1, -1 };
    return DX;
}

inline const int *dir_dy() {
    static const int DY[8] = { 0, 0, 1, -1, 1, -1, 1, -1 };
    return DY;
}

inline const double *dir_len() {
    static const double DL[8] = { 1.0, 1.0, 1.0, 1.0,
            1.4142135623730951, 1.4142135623730951, 1.4142135623730951, 1.4142135623730951 };
    return DL;
}

// ── 内部工具 ────────────────────────────────────────────────────────────────

namespace detail {

// 填洼 ε：与 carve 的 1e-7 同量级（carve 用 double key，这里用 float key，量级保持一致）。
constexpr float FILL_EPS = 1e-7f;

// 计算域周期列数：wrap 生效时为 wrap_cols，否则为整幅宽度。
inline int periodic_cols(const Grid &g) {
    return (g.wrap_cols > 2 && g.wrap_cols <= g.w) ? g.wrap_cols : g.w;
}

inline bool wrap_on(const Grid &g) {
    return g.wrap_cols > 2 && g.wrap_cols <= g.w;
}

inline bool is_wet(const Grid &g, size_t i) {
    return g.wet != nullptr && g.wet[i] != 0;
}

// [S7-T7 2026-11-18] G2 注入是否真正生效：三条 cell 拓扑指针齐备且 n_cells 有效才算，
// 否则 build_flow 的两处注入分支整体不进入（= 改动前的逐位基线）。
inline bool inject_on(const Grid &g) {
    return g.inject_area != nullptr && g.cell_id != nullptr
            && g.cell_downstream != nullptr && g.n_cells > 0;
}

// [S7-T7] 河心像素判据：注入面积 > 0（由调用方按「河 SDF ≥ 出口阈值且非真水体」写入）。
inline bool is_river_px(const Grid &g, size_t i) {
    return g.inject_area != nullptr && g.inject_area[i] > 0.0f;
}

inline double relief_at(const Grid &g, size_t i) {
    if (g.relief == nullptr) return 0.0;
    const double r = double(g.relief[i]);
    return r > 0.0 ? r : 0.0;
}

// 8 邻接下标；ny 越界或（不 wrap 时）nx 越界返回 -1。stride = 整幅宽度，周期 = cols。
inline int32_t neighbor_of(int x, int y, int k, int cols, int rows, int stride, bool wrap) {
    const int ny = y + dir_dy()[k];
    if (ny < 0 || ny >= rows) return -1;
    const int nx = x + dir_dx()[k];
    if (nx < 0 || nx >= cols) {
        if (!wrap) return -1;
        const int nxw = (nx < 0) ? nx + cols : nx - cols;   // |Δx| <= 1，一次补偿足够
        return int32_t(size_t(ny) * size_t(stride) + size_t(nxw));
    }
    return int32_t(size_t(ny) * size_t(stride) + size_t(nx));
}

// 别名列镜像：x >= 周期列数的列等于 x - wrap_cols 的世界位置，逐行复制周期内的结果。
inline void mirror_alias_cols(Grid &g) {
    if (g.H == nullptr) return;
    const int W = g.w, R = g.h;
    const int cols = periodic_cols(g);
    if (cols >= W) return;
    for (int y = 0; y < R; ++y) {
        const size_t row = size_t(y) * size_t(W);
        for (int x = cols; x < W; ++x) g.H[row + size_t(x)] = g.H[row + size_t(x % cols)];
    }
}

// 陆地不下海（不变量 2）：H_pre 已经是「水面以上的陆地」的像素，结果不得低于 sea+eps。
// 只对 H_pre > sea+eps 的像素生效，因此不变量 1（h <= h_pre）与不变量 2 可同时严格成立；
// H_pre 落在 (sea_level, sea_level+sea_eps] 的极窄退化带不参与（那里两条不变量互斥）。
inline void enforce_land_floor(Grid &g, int64_t *clamped) {
    if (g.H == nullptr || g.H_pre == nullptr) return;
    const int W = g.w, R = g.h;
    const int cols = periodic_cols(g);
    const double floor_h = g.sea_level + g.sea_eps;
    for (int y = 0; y < R; ++y) {
        const size_t row = size_t(y) * size_t(W);
        for (int x = 0; x < cols; ++x) {
            const size_t i = row + size_t(x);
            if (is_wet(g, i)) continue;
            if (double(g.H_pre[i]) <= floor_h) continue;
            if (double(g.H[i]) < floor_h) {
                g.H[i] = float(floor_h);
                if (clamped != nullptr) ++*clamped;
            }
        }
    }
}
}  // namespace detail
}  // namespace pk_erosion
