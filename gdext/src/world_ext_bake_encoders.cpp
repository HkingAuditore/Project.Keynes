#include "world_ext.h"

#include "component_bind_table.gen.h"  // A1 / dots-migration-roadmap §3 — autogen by tools/codegen/gen_cpp_bind_table.py
#include "system_schedule.h"           // Phase C.1 — 静态 DAG 调度图
#include "parallel_dispatcher.h"       // Phase C.3a — 并行分发 helper（统一 5 个手写 _thread）
#include "bake_dem_landform.h"
#include "bake_terrain_relief.h"

// MSVC 默认不定义 M_PI；必须在引入 <cmath> 之前打开 _USE_MATH_DEFINES。
// 双保险：仍未定义时手动兜底，避免某些编译器/PCH 顺序问题。
#ifndef _USE_MATH_DEFINES
#define _USE_MATH_DEFINES
#endif

#include <godot_cpp/classes/global_constants.hpp>
#include <godot_cpp/classes/fast_noise_lite.hpp>          // native world-gen 复刻：与 GDScript _init_noise 同一引擎噪声
#include <godot_cpp/classes/random_number_generator.hpp>  // native world-gen 复刻：与 GDScript _rng 同一引擎 PCG
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/error_macros.hpp>
#include <godot_cpp/core/math.hpp>
#include <godot_cpp/variant/char_string.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/variant/variant.hpp>

#include <algorithm>
#include <atomic>
#include <charconv>
#include <chrono>
#include <cmath>
#include <cstdio>
#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif
#include <condition_variable>
#include <cstring>
#include <limits>
#include <memory>
#include <mutex>
#include <functional>
#include <queue>
#include <string>
#include <thread>
#include <unordered_map>
#include <utility>
#include <vector>

#if defined(PK_HAVE_AVX2) && PK_HAVE_AVX2
#  include <immintrin.h>
#endif


#include "world_ext_internal.h"

namespace pk {

using namespace godot;

namespace {

// Cell transition distance is a world/hex-space field, unlike river and coast
// SDFs whose encoded ranges are measured in raster pixels.
constexpr double VISUAL_EDGE_DISTANCE_SATURATE_HEX = 0.90;

// Task count for row-sliced bake images.
//
// pk::parallel_default_n_tasks() budgets one task per 1024 work units, which is
// calibrated for simulation cells. A bake row is orders of magnitude heavier
// (a full scanline of per-pixel noise), so at realistic heights (476 tile rows,
// 600 heightmap rows) that formula collapses to a single task and the pass runs
// serially. Slice by rows instead, keeping the dispatcher's 16-task ceiling.
inline int bake_row_tasks(int rows) {
    if (rows <= 1) return 1;
    return std::max(1, std::min(16, rows / 8));
}

} // namespace

godot::Dictionary DCWorldExt::encode_bake_height_tex_data(godot::Dictionary knobs) {
    using godot::Dictionary;
    using godot::PackedByteArray;
    using godot::PackedFloat32Array;
    using godot::String;

    Dictionary out;
    out["fallback"] = true;
    out["reason"] = String();
    out["path"] = String("gdscript");
    out["elapsed_ms"] = -1.0;

    auto fail = [&](const char *why) -> Dictionary {
        out["reason"] = String(why);
        return out;
    };

    const int w = int(knobs.get("width", knobs.get("w", 0)));
    const int h = int(knobs.get("height", knobs.get("h", 0)));
    const int n = w * h;
    if (w <= 0 || h <= 0 || n <= 0) return fail("invalid size");
    PackedFloat32Array src = knobs.get("buffer", PackedFloat32Array());
    if (src.size() < n) return fail("height buffer too small");

    PackedByteArray data;
    data.resize(n * 2);
    const float * const __restrict SRC = src.ptr();
    uint8_t * const __restrict DST = data.ptrw();

    auto t0 = std::chrono::high_resolution_clock::now();
    for (int i = 0; i < n; ++i) {
        double v = double(SRC[i]);
        if (v < 0.0) v = 0.0;
        else if (v > 1.0) v = 1.0;
        int v16 = int(std::round(v * 65535.0));
        if (v16 < 0) v16 = 0;
        else if (v16 > 65535) v16 = 65535;
        DST[i * 2]     = uint8_t((v16 >> 8) & 0xFF);
        DST[i * 2 + 1] = uint8_t(v16 & 0xFF);
    }
    auto t1 = std::chrono::high_resolution_clock::now();

    out["fallback"] = false;
    out["reason"] = String();
    out["path"] = String("gdext");
    out["elapsed_ms"] = std::chrono::duration<double, std::milli>(t1 - t0).count();
    out["data"] = data;
    out["width"] = w;
    out["height"] = h;
    out["format"] = String("RG8");
    return out;
}

// [terrain-normal-bake 2026-06-25] 生成期烘焙"总体地形法线"：地形是静态的，把宏观山脉走向的
//   粗法线一次性算好编码成 RG8（nx,ny ∈ [0,1] 由 [-1,1] 映射，nz 在 shader 重建）。运行期 shader
//   只需 1 次采样拿走向，替代每帧的宽半径 4-tap，细节法线另由运行期按 biome/性能档叠加。
//   中心差分半径按 sample_radius_hex × hex_size 换算到栅格 → 平滑掉高频，只留走势。
//   X 方向按圆柱环绕（wrap_x），Y 方向 clamp；按行 parallel_for_range 并行。
godot::Dictionary DCWorldExt::encode_bake_terrain_normal_tex_data(godot::Dictionary knobs) {
    using godot::Dictionary;
    using godot::PackedByteArray;
    using godot::PackedFloat32Array;
    using godot::String;

    Dictionary out;
    out["fallback"] = true;
    out["reason"] = String();
    out["path"] = String("gdscript");
    out["elapsed_ms"] = -1.0;

    auto fail = [&](const char *why) -> Dictionary {
        out["reason"] = String(why);
        return out;
    };

    const int w = int(knobs.get("width", knobs.get("w", 0)));
    const int h = int(knobs.get("height", knobs.get("h", 0)));
    const int n = w * h;
    if (w <= 0 || h <= 0 || n <= 0) return fail("invalid size");
    PackedFloat32Array src = knobs.get("buffer", PackedFloat32Array());
    if (src.size() < n) return fail("height buffer too small");

    const double world_size_x = std::max(1e-6, double(knobs.get("world_size_x", double(w))));
    const double world_size_y = std::max(1e-6, double(knobs.get("world_size_y", double(h))));
    const double hex_size = std::max(1e-4, double(knobs.get("hex_size", 1.0)));
    const double sample_radius_hex = std::max(0.01, double(knobs.get("sample_radius_hex", 1.35)));
    const double height_scale_hex = std::max(0.01, double(knobs.get("height_scale_hex", 2.10)));
    const double texel_x = world_size_x / double(w);
    const double texel_y = world_size_y / double(h);
    const double radius_world = sample_radius_hex * hex_size;
    const int radius_x = std::max(1, std::min(64, int(std::round(radius_world / texel_x))));
    const int radius_y = std::max(1, std::min(64, int(std::round(radius_world / texel_y))));
    const bool wrap_x = bool(knobs.get("wrap_x", true));

    PackedByteArray data;
    data.resize(n * 2);
    const float * const __restrict SRC = src.ptr();
    uint8_t * const __restrict DST = data.ptrw();

    const double gain_x = height_scale_hex * hex_size / (2.0 * double(radius_x) * texel_x);
    const double gain_y = height_scale_hex * hex_size / (2.0 * double(radius_y) * texel_y);

    auto t0 = std::chrono::high_resolution_clock::now();

    auto run_range = [&](int y0, int y1) {
        for (int y = y0; y < y1; ++y) {
            const int yu = (y - radius_y < 0) ? 0 : (y - radius_y);
            const int yd = (y + radius_y >= h) ? (h - 1) : (y + radius_y);
            const int rowU = yu * w;
            const int rowD = yd * w;
            const int row  = y * w;
            for (int x = 0; x < w; ++x) {
                int xl = x - radius_x;
                int xr = x + radius_x;
                if (wrap_x) {
                    xl = ((xl % w) + w) % w;
                    xr = xr % w;
                } else {
                    if (xl < 0) xl = 0;
                    if (xr >= w) xr = w - 1;
                }
                const double hL = double(SRC[row + xl]);
                const double hR = double(SRC[row + xr]);
                const double hU = double(SRC[rowU + x]);
                const double hD = double(SRC[rowD + x]);
                const double sx = (hR - hL) * gain_x;
                const double sy = (hD - hU) * gain_y;
                // N = normalize(-sx, -sy, 1)
                const double inv_len = 1.0 / std::sqrt(sx * sx + sy * sy + 1.0);
                const double nx = -sx * inv_len;
                const double ny = -sy * inv_len;
                int bx = int(std::round((nx * 0.5 + 0.5) * 255.0));
                int by = int(std::round((ny * 0.5 + 0.5) * 255.0));
                if (bx < 0) bx = 0; else if (bx > 255) bx = 255;
                if (by < 0) by = 0; else if (by > 255) by = 255;
                DST[(row + x) * 2]     = uint8_t(bx);
                DST[(row + x) * 2 + 1] = uint8_t(by);
            }
        }
    };
    pk::parallel_for_range("pk_bake_terrain_normal", h, bake_row_tasks(h),
            /*seq_threshold=*/64, run_range);

    auto t1 = std::chrono::high_resolution_clock::now();

    out["fallback"] = false;
    out["reason"] = String();
    out["path"] = String("gdext");
    out["elapsed_ms"] = std::chrono::duration<double, std::milli>(t1 - t0).count();
    out["data"] = data;
    out["width"] = w;
    out["height"] = h;
    out["format"] = String("RG8");
    return out;
}

// [terrain-horizon 2026-07-03] 生成期烘焙 8 方向 horizon angle：
//   RGBA8，每个 byte 拆成 high/low nibble，方向顺序 E/NE, N/NW, W/SW, S/SE。
//   运行期 shader 只采样一次并按 TOD 太阳方位插值，避免每帧 heightmap tracing。
godot::Dictionary DCWorldExt::encode_bake_horizon_tex_data(godot::Dictionary knobs) {
    using godot::Dictionary;
    using godot::PackedByteArray;
    using godot::PackedFloat32Array;
    using godot::String;

    Dictionary out;
    out["fallback"] = true;
    out["reason"] = String();
    out["path"] = String("gdscript");
    out["elapsed_ms"] = -1.0;

    auto fail = [&](const char *why) -> Dictionary {
        out["reason"] = String(why);
        return out;
    };

    const int w = int(knobs.get("width", knobs.get("w", 0)));
    const int h = int(knobs.get("height", knobs.get("h", 0)));
    const int n = w * h;
    if (w <= 0 || h <= 0 || n <= 0) return fail("invalid size");

    PackedFloat32Array src = knobs.get("height_buffer", PackedFloat32Array());
    if (src.size() < n) src = knobs.get("buffer", PackedFloat32Array());
    if (src.size() < n) return fail("height buffer too small");

    int steps = int(knobs.get("steps", 48));
    if (steps < 1) steps = 1;
    else if (steps > 256) steps = 256;
    const double step_px = std::max(0.25, double(knobs.get("step_px", 2.0)));
    // Near blockers need dense samples, while far blockers are low-frequency silhouettes.
    // Quadratically increasing distance removes the regular fixed-step comb without
    // sacrificing near-field accuracy. 0 restores the legacy fixed stride.
    const double step_growth = std::clamp(
        double(knobs.get("step_growth", 0.35)), 0.0, 2.0);
    const int lowpass_radius = std::clamp(
        int(knobs.get("lowpass_radius", 1)), 0, 1);
    const double bias = std::max(0.0, double(knobs.get("bias", 0.003)));
    double max_angle = double(knobs.get("max_horizon_angle", 1.309));
    if (max_angle < 0.01) max_angle = 0.01;
    else if (max_angle > M_PI * 0.5) max_angle = M_PI * 0.5;
    const double height_world_scale = std::max(1e-4, double(knobs.get("height_world_scale", 176.0)));
    const double max_distance_world = std::max(0.0, double(knobs.get("max_distance_world", 0.0)));
    const double sea_level = std::clamp(double(knobs.get("sea_level", 0.0)), 0.0, 1.0);
    double world_size_x = double(knobs.get("world_size_x", double(w)));
    double world_size_y = double(knobs.get("world_size_y", double(h)));
    if (world_size_x <= 1e-6) world_size_x = double(w);
    if (world_size_y <= 1e-6) world_size_y = double(h);
    const double texel_x = world_size_x / double(w);
    const double texel_y = world_size_y / double(h);
    const bool wrap_x = bool(knobs.get("wrap_x", true));
    // [terrain-horizon-wrap 2026-07-03] 真正经度环绕周期（world units）。柱状地图东西连续，但
    // height_tex 覆盖的 world_bounds 含 padding（world_size_x = wrap_period_x + 约 4.87·hex），
    // 必须按此周期在世界经度空间折叠，才能与运行期 wrap_map_uv 对齐、接缝无缝。缺省(0)时退化为整图宽。
    const double wrap_period_x_world = double(knobs.get("wrap_period_x", 0.0));
    const double period_px = (wrap_period_x_world > 1e-6) ? (wrap_period_x_world / texel_x) : double(w);

    // [terrain-gi 2026-07-31] 可选的遮挡源 cell id 输出。默认关闭，现有调用点逐字节不变。
    // map_index_data 是 legacy 全局 map_index atlas（RGBA8，G/B = cell.index 低/高字节），
    // 与 tiled 路径的 compute 共用同一编码；这里只记录几何，颜色由运行期 bounce_lut 提供。
    const bool emit_occluder = bool(knobs.get("emit_occluder_cells", false));
    PackedByteArray map_index_data = knobs.get("map_index_data", PackedByteArray());
    const bool occluder_ready = emit_occluder && map_index_data.size() >= n * 4;
    if (emit_occluder && !occluder_ready) return fail("map_index_data too small for occluder");

    PackedByteArray data;
    data.resize(n * 4);
    PackedByteArray occluder_data;
    if (occluder_ready) occluder_data.resize(n * 4);
    // Horizon owns a low-frequency height view. The authoritative eroded/carved height
    // stays untouched and continues to drive normals, rivers and all simulation fields.
    // A separable 1-2-1 kernel suppresses one-texel erosion residue before tracing.
    PackedFloat32Array horizon_height;
    if (lowpass_radius > 0) {
        horizon_height.resize(n);
        PackedFloat32Array horizontal;
        horizontal.resize(n);
        const float * const raw = src.ptr();
        float * const tmp = horizontal.ptrw();
        const int period_cols = std::clamp(int(std::round(period_px)), 1, w);
        auto wrap_col = [&](int sx) -> int {
            if (!wrap_x) return std::clamp(sx, 0, w - 1);
            sx %= period_cols;
            if (sx < 0) sx += period_cols;
            return std::clamp(sx, 0, w - 1);
        };
        auto blur_rows = [&](int y0, int y1) {
            for (int y = y0; y < y1; ++y) {
                const int row = y * w;
                for (int x = 0; x < w; ++x) {
                    const double l = std::max(double(raw[row + wrap_col(x - 1)]), sea_level);
                    const double c = std::max(double(raw[row + wrap_col(x)]), sea_level);
                    const double r = std::max(double(raw[row + wrap_col(x + 1)]), sea_level);
                    tmp[row + x] = float((l + 2.0 * c + r) * 0.25);
                }
            }
        };
        pk::parallel_for_range("pk_bake_horizon_blur_x", h, bake_row_tasks(h), 32, blur_rows);
        const float * const mid = horizontal.ptr();
        float * const dst_h = horizon_height.ptrw();
        auto blur_columns = [&](int y0, int y1) {
            for (int y = y0; y < y1; ++y) {
                const int yu = std::max(y - 1, 0);
                const int yd = std::min(y + 1, h - 1);
                for (int x = 0; x < w; ++x) {
                    dst_h[y * w + x] = (mid[yu * w + x]
                        + 2.0f * mid[y * w + x] + mid[yd * w + x]) * 0.25f;
                }
            }
        };
        pk::parallel_for_range("pk_bake_horizon_blur_y", h, bake_row_tasks(h), 32, blur_columns);
    }
    const float * const __restrict SRC = lowpass_radius > 0
        ? horizon_height.ptr() : src.ptr();
    uint8_t * const __restrict DST = data.ptrw();
    const uint8_t * const __restrict MAP_INDEX = occluder_ready ? map_index_data.ptr() : nullptr;
    uint8_t * const __restrict OCC = occluder_ready ? occluder_data.ptrw() : nullptr;

    constexpr uint32_t OCCLUDER_SENTINEL = 0xFFFFu;
    auto cell_id_at = [&](int pixel_index) -> uint32_t {
        if (!MAP_INDEX || pixel_index < 0) return OCCLUDER_SENTINEL;
        const int base = pixel_index * 4;
        const uint32_t cid = uint32_t(MAP_INDEX[base + 1]) + uint32_t(MAP_INDEX[base + 2]) * 256u;
        return (cid >= OCCLUDER_SENTINEL) ? OCCLUDER_SENTINEL : cid;
    };

    constexpr double INV_SQRT2 = 0.70710678118654752440;
    const double dir_x[8] = { 1.0, INV_SQRT2, 0.0, -INV_SQRT2, -1.0, -INV_SQRT2, 0.0, INV_SQRT2 };
    const double dir_y[8] = { 0.0, INV_SQRT2, 1.0, INV_SQRT2, 0.0, -INV_SQRT2, -1.0, -INV_SQRT2 };

    auto q_horizon = [&](double angle) -> uint8_t {
        double v = angle / max_angle;
        if (v < 0.0) v = 0.0;
        else if (v > 1.0) v = 1.0;
        int q = int(std::round(v * 15.0));
        if (q < 0) q = 0;
        else if (q > 15) q = 15;
        return uint8_t(q);
    };

    auto t0 = std::chrono::high_resolution_clock::now();
    auto run_range = [&](int y0, int y1) {
        for (int y = y0; y < y1; ++y) {
            const int row = y * w;
            for (int x = 0; x < w; ++x) {
                const int idx = row + x;
                // Horizon is a surface-visibility field. Ocean pixels receive light at
                // the water surface, not at the authoritative bathymetric height.
                const double h0 = std::max(double(SRC[idx]), sea_level);
                uint8_t q[8] = {};
                int hit_index[8] = {};
                for (int d = 0; d < 8; ++d) {
                    // [terrain-horizon perf 2026-07-03] 逐步只维护最大 slope² = (dh·scale)²/dist²。
                    // atan2 对正 slope 单调 → argmax 不变；把每像素 8×steps 次 sqrt+atan2 降为每方向
                    // 末尾 1 次 sqrt+atan。量化到 16 级后输出与旧 atan2 路径一致。
                double best_slope_sq = 0.0;
                int best_hit = -1;
                const double dir_world_step = std::sqrt(
                        (dir_x[d] * texel_x) * (dir_x[d] * texel_x) +
                        (dir_y[d] * texel_y) * (dir_y[d] * texel_y));
                const double max_distance_px = max_distance_world > 0.0
                        ? std::min(
                            (max_distance_world / std::max(dir_world_step, 1e-6)),
                            (wrap_x && std::abs(dir_y[d]) <= 1e-9)
                                ? period_px
                                : std::numeric_limits<double>::max())
                        : std::numeric_limits<double>::max();
                for (int s = 1; s <= steps; ++s) {
                        const double sf = double(s);
                        const double dist_px = step_px
                            * (sf + 0.5 * step_growth * sf * (sf - 1.0));
                        if (dist_px > max_distance_px) break;
                        const double sx_f = double(x) + dir_x[d] * dist_px;
                        const int sy = int(std::floor(double(y) + dir_y[d] * dist_px + 0.5));
                        if (sy < 0 || sy >= h) break;
                        int sx;
                        double off_x_world;
                        if (wrap_x) {
                            // 按真实经度周期 period_px 折回规范列（height 关于经度以 period 周期），
                            // 但遮挡距离必须按射线实际行进距离算，不能取圆柱最短经度距离。
                            // 否则正东/正西扫线绕一圈后 dist 接近 0，会把 horizon angle 打满。
                            const double sxw = sx_f - period_px * std::floor(sx_f / period_px);  // [0, period_px)
                            sx = int(std::floor(sxw + 0.5));
                            if (sx >= w) sx -= w;   // period_px≈w 时进位兜底
                            if (sx < 0) sx = 0;
                            off_x_world = std::abs(dir_x[d] * dist_px * texel_x);
                        } else {
                            sx = int(std::floor(sx_f + 0.5));
                            if (sx < 0 || sx >= w) break;
                            off_x_world = std::abs(double(sx - x)) * texel_x;
                        }
                        // dh<=0 的采样（海平面/下坡）占绝大多数，前置判断可跳过 world_dist 计算。
                        const double sample_height = std::max(double(SRC[sy * w + sx]), sea_level);
                        const double dh = sample_height - h0 - bias;
                        if (dh <= 0.0) continue;
                        const double off_y_world = std::abs(double(sy - y)) * texel_y;
                        const double world_dist_sq = off_x_world * off_x_world + off_y_world * off_y_world;
                        if (world_dist_sq <= 1e-12) continue;
                        const double num = dh * height_world_scale;  // dh>0 → num>0
                        const double slope_sq = (num * num) / world_dist_sq;
                        if (slope_sq > best_slope_sq) {
                            best_slope_sq = slope_sq;
                            best_hit = sy * w + sx;
                        }
                    }
                    q[d] = q_horizon(std::atan(std::sqrt(best_slope_sq)));
                    hit_index[d] = best_hit;
                }
                const int di = idx * 4;
                DST[di]     = uint8_t((q[0] << 4) | q[1]);
                DST[di + 1] = uint8_t((q[2] << 4) | q[3]);
                DST[di + 2] = uint8_t((q[4] << 4) | q[5]);
                DST[di + 3] = uint8_t((q[6] << 4) | q[7]);
                if (OCC) {
                    // 取遮挡最强的两个方向作为弹射源。只挑 top-2 而非全 8 方向：主导遮挡贡献了
                    // 绝大部分近场弹射能量，尾部方向的 cell 往往远到色彩已被距离衰减掉。
                    int d0 = -1;
                    int d1 = -1;
                    for (int d = 0; d < 8; ++d) {
                        if (q[d] == 0) continue;
                        if (d0 < 0 || q[d] > q[d0]) { d1 = d0; d0 = d; }
                        else if (d1 < 0 || q[d] > q[d1]) { d1 = d; }
                    }
                    const uint32_t cid0 = (d0 >= 0) ? cell_id_at(hit_index[d0]) : OCCLUDER_SENTINEL;
                    const uint32_t cid1 = (d1 >= 0) ? cell_id_at(hit_index[d1]) : OCCLUDER_SENTINEL;
                    OCC[di]     = uint8_t(cid0 & 0xFFu);
                    OCC[di + 1] = uint8_t((cid0 >> 8) & 0xFFu);
                    OCC[di + 2] = uint8_t(cid1 & 0xFFu);
                    OCC[di + 3] = uint8_t((cid1 >> 8) & 0xFFu);
                }
            }
        }
    };
    pk::parallel_for_range("pk_bake_horizon_tex", h, bake_row_tasks(h),
            /*seq_threshold=*/32, run_range);
    auto t1 = std::chrono::high_resolution_clock::now();

    out["fallback"] = false;
    out["reason"] = String();
    out["path"] = String("gdext");
    out["elapsed_ms"] = std::chrono::duration<double, std::milli>(t1 - t0).count();
    out["data"] = data;
    out["width"] = w;
    out["height"] = h;
    out["format"] = String("RGBA8");
    out["directions"] = String("E,NE,N,NW,W,SW,S,SE");
    out["height_world_scale"] = height_world_scale;
    out["step_growth"] = step_growth;
    out["lowpass_radius"] = lowpass_radius;
    out["sea_level"] = sea_level;
    out["max_horizon_angle"] = max_angle;
    out["max_distance_world"] = max_distance_world;
    out["occluder_ready"] = occluder_ready;
    if (occluder_ready) out["occluder_data"] = occluder_data;
    return out;
}

godot::Dictionary DCWorldExt::encode_bake_r8_tex_data(godot::Dictionary knobs) {
    using godot::Dictionary;
    using godot::PackedByteArray;
    using godot::String;

    Dictionary out;
    out["fallback"] = true;
    out["reason"] = String();
    out["path"] = String("gdscript");
    out["elapsed_ms"] = -1.0;

    auto fail = [&](const char *why) -> Dictionary {
        out["reason"] = String(why);
        return out;
    };

    const int w = int(knobs.get("width", knobs.get("w", 0)));
    const int h = int(knobs.get("height", knobs.get("h", 0)));
    const int n = w * h;
    if (w <= 0 || h <= 0 || n <= 0) return fail("invalid size");
    const int def = std::clamp(int(knobs.get("default_byte", 0)), 0, 255);
    PackedByteArray src = knobs.get("buffer", PackedByteArray());

    PackedByteArray data;
    data.resize(n);
    uint8_t * const __restrict DST = data.ptrw();
    const bool has_src = src.size() >= n;
    const uint8_t * const __restrict SRC = has_src ? src.ptr() : nullptr;

    auto t0 = std::chrono::high_resolution_clock::now();
    if (has_src) {
        for (int i = 0; i < n; ++i) DST[i] = SRC[i];
    } else {
        for (int i = 0; i < n; ++i) DST[i] = uint8_t(def);
    }
    auto t1 = std::chrono::high_resolution_clock::now();

    out["fallback"] = false;
    out["reason"] = String();
    out["path"] = String("gdext");
    out["elapsed_ms"] = std::chrono::duration<double, std::milli>(t1 - t0).count();
    out["data"] = data;
    out["width"] = w;
    out["height"] = h;
    out["format"] = String("L8");
    return out;
}

godot::Dictionary DCWorldExt::encode_bake_flow_tex_data(godot::Dictionary knobs) {
    using godot::Dictionary;
    using godot::PackedByteArray;
    using godot::PackedFloat32Array;
    using godot::String;

    Dictionary out;
    out["fallback"] = true;
    out["reason"] = String();
    out["path"] = String("gdscript");
    out["elapsed_ms"] = -1.0;

    auto fail = [&](const char *why) -> Dictionary {
        out["reason"] = String(why);
        return out;
    };

    const int w = int(knobs.get("width", knobs.get("w", 0)));
    const int h = int(knobs.get("height", knobs.get("h", 0)));
    const int n = w * h;
    if (w <= 0 || h <= 0 || n <= 0) return fail("invalid size");
    PackedFloat32Array src = knobs.get("buffer", PackedFloat32Array());
    if (src.size() < n) return fail("flow buffer too small");

    PackedByteArray data;
    data.resize(n);
    const float * const __restrict SRC = src.ptr();
    uint8_t * const __restrict DST = data.ptrw();

    auto t0 = std::chrono::high_resolution_clock::now();
    for (int i = 0; i < n; ++i) {
        float v = SRC[i];
        if (v < 0.0f) v = 0.0f;
        else if (v > 1.0f) v = 1.0f;
        int q = int(v * 255.0f + 0.5f);
        if (q < 0) q = 0;
        else if (q > 255) q = 255;
        DST[i] = uint8_t(q);
    }
    auto t1 = std::chrono::high_resolution_clock::now();

    out["fallback"] = false;
    out["reason"] = String();
    out["path"] = String("gdext");
    out["elapsed_ms"] = std::chrono::duration<double, std::milli>(t1 - t0).count();
    out["data"] = data;
    out["width"] = w;
    out["height"] = h;
    out["format"] = String("L8");
    return out;
}

godot::Dictionary DCWorldExt::encode_bake_enum_atlas_payload(godot::Dictionary knobs) {
    using godot::Dictionary;
    using godot::PackedByteArray;
    using godot::PackedInt32Array;
    using godot::String;

    Dictionary out;
    out["fallback"] = true;
    out["reason"] = String();
    out["path"] = String("gdscript");
    out["elapsed_ms"] = -1.0;

    auto fail = [&](const char *why) -> Dictionary {
        out["reason"] = String(why);
        return out;
    };

    const int w = int(knobs.get("width", knobs.get("w", 0)));
    const int h = int(knobs.get("height", knobs.get("h", 0)));
    const int n_pix = w * h;
    const int n_cells = int(knobs.get("n_cells", 0));
    if (w <= 0 || h <= 0 || n_pix <= 0) return fail("invalid size");
    if (n_cells <= 0) return fail("invalid n_cells");

    PackedByteArray biome = knobs.get("biome_buffer", PackedByteArray());
    PackedByteArray landform = knobs.get("landform_by_cell", PackedByteArray());
    PackedInt32Array first_px = knobs.get("cell_first_px", PackedInt32Array());
    PackedInt32Array px_count = knobs.get("cell_px_count", PackedInt32Array());
    PackedInt32Array flat_px = knobs.get("flat_px_indices", PackedInt32Array());
    if (biome.size() < n_pix) return fail("biome buffer too small");
    if (first_px.size() < n_cells || px_count.size() < n_cells) return fail("cell CSR size < n_cells");

    PackedByteArray data;
    data.resize(n_pix * 4);
    const uint8_t * const __restrict BIOME = biome.ptr();
    const uint8_t * const __restrict LF = landform.size() >= n_cells ? landform.ptr() : nullptr;
    const int32_t * const __restrict FIRST = first_px.ptr();
    const int32_t * const __restrict CNT = px_count.ptr();
    const int32_t * const __restrict FLAT = flat_px.ptr();
    const int flat_n = flat_px.size();
    uint8_t * const __restrict DST = data.ptrw();

    auto t0 = std::chrono::high_resolution_clock::now();
    for (int i = 0; i < n_pix; ++i) {
        const int di = i * 4;
        DST[di] = BIOME[i];
        DST[di + 1] = 0xFF;
        DST[di + 2] = 0xFF;
        DST[di + 3] = 0;
    }
    for (int ci = 0; ci < n_cells; ++ci) {
        const int first = FIRST[ci];
        const int count = CNT[ci];
        if (count <= 0 || first < 0 || first + count > flat_n) continue;
        const uint8_t lf = LF != nullptr ? LF[ci] : uint8_t(0);
        const uint8_t lo = uint8_t(ci & 0xFF);
        const uint8_t hi = uint8_t((ci >> 8) & 0xFF);
        for (int p = 0; p < count; ++p) {
            const int px = FLAT[first + p];
            if (px < 0 || px >= n_pix) continue;
            const int di = px * 4;
            DST[di + 1] = lo;
            DST[di + 2] = hi;
            DST[di + 3] = lf;
        }
    }
    auto t1 = std::chrono::high_resolution_clock::now();

    out["fallback"] = false;
    out["reason"] = String();
    out["path"] = String("gdext");
    out["elapsed_ms"] = std::chrono::duration<double, std::milli>(t1 - t0).count();
    out["data"] = data;
    out["width"] = w;
    out["height"] = h;
    out["format"] = String("RGBA8");
    return out;
}


godot::Dictionary DCWorldExt::encode_bake_upwelling_tex_data(godot::Dictionary knobs) {
    using godot::Dictionary;
    using godot::PackedByteArray;
    using godot::PackedInt32Array;
    using godot::String;
    using godot::StringName;

    Dictionary out;
    out["fallback"] = true;
    out["reason"] = String();
    out["path"] = String("gdscript");
    out["elapsed_ms"] = -1.0;

    auto fail = [&](const char *why) -> Dictionary {
        out["reason"] = String(why);
        return out;
    };

    if (!_bound) return fail("not bound");
    const int w = int(knobs.get("width", knobs.get("w", 0)));
    const int h = int(knobs.get("height", knobs.get("h", 0)));
    const int n_pix = w * h;
    const int n_cells = int(knobs.get("n_cells", _entity_count));
    if (w <= 0 || h <= 0 || n_pix <= 0) return fail("invalid size");
    if (n_cells <= 0 || n_cells > _entity_count) return fail("invalid n_cells");
    PackedInt32Array p2c = knobs.get("pixel_to_cell_idx", PackedInt32Array());
    if (p2c.size() < n_pix) return fail("pixel_to_cell_idx too small");

    const int sid_terrain = component_id(StringName("cell_terrain"));
    const int sid_up = component_id(StringName("cell_upwelling_strength"));
    if (sid_terrain < 0 || sid_up < 0) return fail("missing slot id");
    Slot &s_terr = _slots.write[sid_terrain];
    Slot &s_up = _slots.write[sid_up];
    if (s_terr.arr_u8.size() < n_cells || s_up.arr_f32.size() < n_cells) {
        return fail("slot array size < n_cells");
    }

    PackedByteArray data;
    data.resize(n_pix);
    const int32_t * const __restrict P2C = p2c.ptr();
    const uint8_t * const __restrict TERR = s_terr.arr_u8.ptr();
    const float * const __restrict UP = s_up.arr_f32.ptr();
    uint8_t * const __restrict DST = data.ptrw();

    auto quantize_upwelling = [](float v) -> uint8_t {
        if (v < -1.0f) v = -1.0f;
        else if (v > 1.0f) v = 1.0f;
        int q = int(std::round(128.0f + 127.0f * v));
        if (q < 0) q = 0;
        else if (q > 255) q = 255;
        return uint8_t(q);
    };

    auto t0 = std::chrono::high_resolution_clock::now();
    for (int i = 0; i < n_pix; ++i) {
        const int ci = P2C[i];
        if (ci < 0 || ci >= n_cells || !pk_is_water_terrain(TERR[ci])) {
            DST[i] = 128;
            continue;
        }
        DST[i] = quantize_upwelling(UP[ci]);
    }
    auto t1 = std::chrono::high_resolution_clock::now();

    out["fallback"] = false;
    out["reason"] = String();
    out["path"] = String("gdext");
    out["elapsed_ms"] = std::chrono::duration<double, std::milli>(t1 - t0).count();
    out["data"] = data;
    out["width"] = w;
    out["height"] = h;
    out["format"] = String("L8");
    return out;
}


} // namespace pk
