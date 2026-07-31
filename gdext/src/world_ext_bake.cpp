#include "world_ext.h"

#include "component_bind_table.gen.h"  // A1 / dots-migration-roadmap §3 — autogen by tools/codegen/gen_cpp_bind_table.py
#include "system_schedule.h"           // Phase C.1 — 静态 DAG 调度图
#include "parallel_dispatcher.h"       // Phase C.3a — 并行分发 helper（统一 5 个手写 _thread）

// MSVC 默认不定义 M_PI；必须在引入 <cmath> 之前打开 _USE_MATH_DEFINES。
// 双保险：仍未定义时手动兜底，避免某些编译器/PCH 顺序问题。
#ifndef _USE_MATH_DEFINES
#define _USE_MATH_DEFINES
#endif

#include <godot_cpp/classes/global_constants.hpp>
#include <godot_cpp/classes/fast_noise_lite.hpp>          // native world-gen 复刻：与 GDScript _init_noise 同一引擎噪声
#include <godot_cpp/classes/random_number_generator.hpp>  // native world-gen 复刻：与 GDScript _rng 同一引擎 PCG
#include <godot_cpp/classes/worker_thread_pool.hpp>
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
//   宽半径中心差分（半径 coarse_radius texel）→ 平滑掉 per-pixel ridge/crag 高频，只留走势。
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

    int radius = int(knobs.get("coarse_radius", 4));
    if (radius < 1) radius = 1;
    else if (radius > 64) radius = 64;
    const double gain = double(knobs.get("slope_gain", 8.0));
    const bool wrap_x = bool(knobs.get("wrap_x", true));

    PackedByteArray data;
    data.resize(n * 2);
    const float * const __restrict SRC = src.ptr();
    uint8_t * const __restrict DST = data.ptrw();

    const double inv2r_gain = gain / (2.0 * double(radius));

    auto t0 = std::chrono::high_resolution_clock::now();

    auto run_range = [&](int y0, int y1) {
        for (int y = y0; y < y1; ++y) {
            const int yu = (y - radius < 0) ? 0 : (y - radius);
            const int yd = (y + radius >= h) ? (h - 1) : (y + radius);
            const int rowU = yu * w;
            const int rowD = yd * w;
            const int row  = y * w;
            for (int x = 0; x < w; ++x) {
                int xl = x - radius;
                int xr = x + radius;
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
                const double sx = (hR - hL) * inv2r_gain;
                const double sy = (hD - hU) * inv2r_gain;
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
    pk::parallel_for_range("pk_bake_terrain_normal", h, /*n_tasks=*/0, /*seq_threshold=*/64, run_range);

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
    const double bias = std::max(0.0, double(knobs.get("bias", 0.003)));
    double max_angle = double(knobs.get("max_horizon_angle", 1.309));
    if (max_angle < 0.01) max_angle = 0.01;
    else if (max_angle > M_PI * 0.5) max_angle = M_PI * 0.5;
    const double height_world_scale = std::max(1e-4, double(knobs.get("height_world_scale", 176.0)));
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
    const float * const __restrict SRC = src.ptr();
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
                    for (int s = 1; s <= steps; ++s) {
                        const double dist_px = double(s) * step_px;
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
    pk::parallel_for_range("pk_bake_horizon_tex", h, /*n_tasks=*/0, /*seq_threshold=*/32, run_range);
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
    out["sea_level"] = sea_level;
    out["max_horizon_angle"] = max_angle;
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

// ─────────────────────────────────────────────────────────────────────────
// 生成期 per-pixel 几何场 buffer-encoder（dots-total-cpp 续，2026-06-25）
// 纯 buffer-encoder：不读 _slots / 不要求 _bound。GDScript 只发请求 + 收结果。
// ─────────────────────────────────────────────────────────────────────────

// run_bake_latitude_field_pass — 复刻 map_baker.gd::_bake_latitude_buffer
// 逐像素 ny = y / max(H-1,1)（行常量）→ F32 buffer。
godot::Dictionary DCWorldExt::run_bake_latitude_field_pass(godot::Dictionary knobs) {
    using godot::Dictionary;
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

    PackedFloat32Array buf;
    buf.resize(n);
    float * const __restrict DST = buf.ptrw();
    const double denom = double(h - 1 > 1 ? h - 1 : 1);

    auto t0 = std::chrono::high_resolution_clock::now();
    for (int y = 0; y < h; ++y) {
        const float ny = float(double(y) / denom);
        const int row = y * w;
        for (int x = 0; x < w; ++x) DST[row + x] = ny;
    }
    auto t1 = std::chrono::high_resolution_clock::now();

    out["fallback"] = false;
    out["reason"] = String();
    out["path"] = String("gdext");
    out["elapsed_ms"] = std::chrono::duration<double, std::milli>(t1 - t0).count();
    out["latitude_buffer"] = buf;
    out["width"] = w;
    out["height"] = h;
    out["format"] = String("F32");
    return out;
}

// run_bake_river_sdf_pass — 复刻 map_baker.gd::_bake_river_sdf 的全部计算。
// GDScript 只 trace 原始河流链（HexCell 对象图，输出极小）；本 pass 在 C++ 内完成
// 连续经度展开 + Catmull-Rom 致密化 + warp 噪声（FastNoiseLite 复刻 _warp_noise_lo/hi）+
// 变宽 polyline stamp + chamfer 3-4 双通 SDT + 归一化。dense polyline / mask 中间数据
// 全部留在 C++（最小化跨语言传输）。几何用 float 复刻 Godot Vector2 real_t；scalar 用 double。
godot::Dictionary DCWorldExt::run_bake_river_sdf_pass(godot::Dictionary knobs) {
    using godot::Dictionary;
    using godot::FastNoiseLite;
    using godot::PackedFloat32Array;
    using godot::PackedInt32Array;
    using godot::Ref;
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

    const float origin_x = float(double(knobs.get("origin_x", 0.0)));
    const float origin_y = float(double(knobs.get("origin_y", 0.0)));
    const float inv_world_x = float(double(knobs.get("inv_world_x", 0.0)));
    const float inv_world_y = float(double(knobs.get("inv_world_y", 0.0)));
    if (inv_world_x <= 0.0f || inv_world_y <= 0.0f) return fail("invalid world scale");
    const float hex_size = float(double(knobs.get("hex_size", 1.0)));
    const int seed = int(knobs.get("seed", 0));
    const double base_radius_px = double(knobs.get("base_radius_px", 0.0));
    const double sdf_max_dist_px = double(knobs.get("sdf_max_dist_px", 5.0));
    const double wrap_period_x = double(knobs.get("wrap_period_x", 0.0));
    const int cr_step = std::max(1, int(knobs.get("cr_step", 12)));
    // [river-endpoint-taper 2026-06-26] 端点淡出：河源(headwater)与陆地死端(未入水、非汇流)的
    // 钝圆头是"断头河"观感的主因（stamp 半径有 0.40×base 下限 → 末端永远是个钝圆点）。这里沿链
    // 弧长在端点附近把"半径乘子"从 1 渐降到 taper_floor，让河首/河尾收成尖点而非钝头。仅对真正的
    // 死端(dead-end)与河源生效；入海/入湖口、汇流接点保持满宽不淡出（避免在水边/汇流处反而断开）。
    const double taper_cells = std::max(0.0, double(knobs.get("river_endpoint_taper_cells", 1.5)));
    const float taper_floor = float(std::clamp(double(knobs.get("river_endpoint_taper_floor", 0.0)), 0.0, 1.0));

    // 河流拓扑来自 ext 成员（post_base 末尾暂存），在 C++ 内 trace（零跨语言再传输）。
    const int rn = _gen_river_n;
    if (rn <= 0
            || int(_gen_river_q.size()) != rn || int(_gen_river_r.size()) != rn
            || int(_gen_river_terrain.size()) != rn || int(_gen_river_elev.size()) != rn
            || int(_gen_river_has.size()) != rn || int(_gen_river_flow.size()) != rn
            || int(_gen_river_downstream.size()) != rn
            || int(_gen_river_neighbors.size()) != size_t(rn) * 6) {
        return fail("river topology cache missing (run post_base first)");
    }

    PackedFloat32Array out_buf;
    out_buf.resize(n);
    float * const __restrict OUT = out_buf.ptrw();

    auto t0 = std::chrono::high_resolution_clock::now();

    // warp 噪声：复刻 map_baker.gd::_init_noise 的 _warp_noise_lo / _warp_noise_hi。
    Ref<FastNoiseLite> warp_lo;  warp_lo.instantiate();
    Ref<FastNoiseLite> warp_hi;  warp_hi.instantiate();
    if (warp_lo.is_null() || warp_hi.is_null()) return fail("fast_noise_lite_instantiate_failed");
    warp_lo->set_noise_type(FastNoiseLite::TYPE_SIMPLEX_SMOOTH);
    warp_lo->set_seed(seed + 71);
    warp_lo->set_frequency(0.024);  // WARP_FREQ
    warp_lo->set_fractal_type(FastNoiseLite::FRACTAL_FBM);
    warp_lo->set_fractal_octaves(3);
    warp_hi->set_noise_type(FastNoiseLite::TYPE_SIMPLEX);
    warp_hi->set_seed(seed + 233);
    warp_hi->set_frequency(0.024 * 3.4);  // WARP_FREQ * WARP_HIGH_FREQ_MUL
    warp_hi->set_fractal_type(FastNoiseLite::FRACTAL_FBM);
    warp_hi->set_fractal_octaves(3);

    // mask 初值 INF。值以 chamfer 的 3-unit 基数表示到河缘的距离：保留亚像素
    // 半径，而不是把所有落在河内的 texel 都量化成同一个 0。
    static const float MASK_INF = 1.0e9f;
    std::vector<float> mask(size_t(n), MASK_INF);

    const float warp_amp = hex_size * 0.30f;
    auto fposmodf = [](float a, float b) -> float {
        float m = std::fmod(a, b);
        if (m < 0.0f) m += b;
        return m;
    };
    auto smooth01f = [](float edge0, float edge1, float x) -> float {
        if (edge1 <= edge0) return x < edge0 ? 0.0f : 1.0f;
        float t = (x - edge0) / (edge1 - edge0);
        if (t < 0.0f) t = 0.0f;
        else if (t > 1.0f) t = 1.0f;
        return t * t * (3.0f - 2.0f * t);
    };
    auto river_cyl = [&](FastNoiseLite *nz, float x, float y, float phase_origin_x = 0.0f) -> float {
        const float period = float(wrap_period_x);
        if (period <= 0.0001f) return nz->get_noise_2d(x, y);
        const float phase = fposmodf(x - phase_origin_x, period);
        const float xw = phase_origin_x + phase;
        const float base = nz->get_noise_2d(xw, y);
        const float band = std::min(std::max(hex_size * 8.0f, 1.0f), period * 0.12f);
        if (band <= 0.0001f) return base;
        const float left = nz->get_noise_2d(phase_origin_x, y);
        const float right = nz->get_noise_2d(phase_origin_x + period, y);
        const float seam_avg = (left + right) * 0.5f;
        if (phase < band) {
            const float t = smooth01f(0.0f, band, phase);
            return seam_avg + (base - seam_avg) * t;
        }
        if (phase > period - band) {
            const float t = smooth01f(0.0f, band, period - phase);
            return seam_avg + (base - seam_avg) * t;
        }
        return base;
    };

    // catmull_rom（Vector2 real_t=float），镜像 map_baker.gd::_catmull_rom。
    auto catmull = [](float p0x, float p0y, float p1x, float p1y,
                      float p2x, float p2y, float p3x, float p3y,
                      float t, float &ox, float &oy) {
        const float t2 = t * t;
        const float t3 = t2 * t;
        ox = 0.5f * (p1x * 2.0f + (p2x - p0x) * t
                + (p0x * 2.0f - p1x * 5.0f + p2x * 4.0f - p3x) * t2
                + (-p0x + p1x * 3.0f - p2x * 3.0f + p3x) * t3);
        oy = 0.5f * (p1y * 2.0f + (p2y - p0y) * t
                + (p0y * 2.0f - p1y * 5.0f + p2y * 4.0f - p3y) * t2
                + (-p0y + p1y * 3.0f - p2y * 3.0f + p3y) * t3);
    };

    // 单段 run（≥2 原始点）：CR 致密化 + warp + 变宽 stamp。中间 buffer 全留 C++。
    // rt：每个 coarse 点的"端点半径乘子"(1=满宽，<1=向尖点淡出)，随 CR 一并致密化、逐像素缩放半径。
    std::vector<float> dpx, dpy, dwd, dtp;  // dense warped points + widths + taper（run-local，复用）
    auto stamp_run = [&](const std::vector<float> &rx, const std::vector<float> &ry,
                         const std::vector<float> &rw, const std::vector<float> &rt) {
        const int m = int(rx.size());
        if (m < 2) return;
        // ── Catmull-Rom 致密化 with widths（镜像 _catmull_rom_dense_with_widths）──
        dpx.clear(); dpy.clear(); dwd.clear(); dtp.clear();
        for (int i = 0; i < m - 1; ++i) {
            const float p0x = (i > 0) ? rx[i - 1] : rx[i];
            const float p0y = (i > 0) ? ry[i - 1] : ry[i];
            const float p1x = rx[i],     p1y = ry[i];
            const float p2x = rx[i + 1], p2y = ry[i + 1];
            const float p3x = (i + 2 < m) ? rx[i + 2] : rx[i + 1];
            const float p3y = (i + 2 < m) ? ry[i + 2] : ry[i + 1];
            const float w1 = rw[i];
            const float w2 = rw[i + 1];
            const float tp1 = rt[i];
            const float tp2 = rt[i + 1];
            for (int j = 0; j < cr_step; ++j) {
                const float t = float(j) / float(cr_step);
                float cxp, cyp;
                catmull(p0x, p0y, p1x, p1y, p2x, p2y, p3x, p3y, t, cxp, cyp);
                // warp（镜像 _warp_river_chain）：noise 在 dense 点上采样
                float wx_off = river_cyl(warp_lo.ptr(), cxp, cyp) * warp_amp;
                float wy_off = river_cyl(warp_lo.ptr(), cxp + 31.7f, cyp - 17.3f, 31.7f) * warp_amp;
                wx_off += river_cyl(warp_hi.ptr(), cxp + 91.1f, cyp + 53.7f, 91.1f) * warp_amp * 0.30f;
                wy_off += river_cyl(warp_hi.ptr(), cxp - 41.5f, cyp + 23.9f, -41.5f) * warp_amp * 0.30f;
                dpx.push_back(cxp + wx_off);
                dpy.push_back(cyp + wy_off);
                dwd.push_back(w1 + (w2 - w1) * t);
                dtp.push_back(tp1 + (tp2 - tp1) * t);
            }
        }
        dpx.push_back(rx[m - 1]);
        dpy.push_back(ry[m - 1]);
        dwd.push_back(rw[m - 1]);
        dtp.push_back(rt[m - 1]);
        // ── 变宽 polyline stamp（镜像 _stamp_polyline_variable）──
        const int dn = int(dpx.size());
        for (int i = 0; i < dn - 1; ++i) {
            const double w0 = double(dwd[i]);
            const double w1 = double(dwd[i + 1]);
            const double wmax = w0 > w1 ? w0 : w1;
            // [river-hierarchy 2026-07-31] 与 map_baker._stamp_polyline_variable 同步：
            // 0.40+pow(w,1.4)*3.7 → 0.18+pow(w,1.85)*5.2，拉开干支流宽度差。
            const double seg_radius_px = base_radius_px * (0.18 + std::pow(wmax, 1.85) * 5.2);
            const int pad = int(std::ceil(seg_radius_px)) + 1;
            const float p0x = (dpx[i] - origin_x) * inv_world_x;
            const float p0y = (dpy[i] - origin_y) * inv_world_y;
            const float p1x = (dpx[i + 1] - origin_x) * inv_world_x;
            const float p1y = (dpy[i + 1] - origin_y) * inv_world_y;
            int min_x = int(std::floor(double(p0x < p1x ? p0x : p1x))) - pad;
            int max_x = int(std::ceil(double(p0x > p1x ? p0x : p1x))) + pad;
            int min_y = int(std::floor(double(p0y < p1y ? p0y : p1y))) - pad;
            int max_y = int(std::ceil(double(p0y > p1y ? p0y : p1y))) + pad;
            if (min_x < 0) min_x = 0; if (max_x > w - 1) max_x = w - 1;
            if (min_y < 0) min_y = 0; if (max_y > h - 1) max_y = h - 1;
            const float segx = p1x - p0x;
            const float segy = p1y - p0y;
            const float seg_len_sq = segx * segx + segy * segy;
            const double tp0 = double(dtp[i]);
            const double tp1 = double(dtp[i + 1]);
            for (int y = min_y; y <= max_y; ++y) {
                for (int x = min_x; x <= max_x; ++x) {
                    const float px = float(x) + 0.5f;
                    const float py = float(y) + 0.5f;
                    double t = 0.0;
                    if (seg_len_sq > 0.0001f) {
                        const float dot = (px - p0x) * segx + (py - p0y) * segy;
                        t = double(dot) / double(seg_len_sq);
                        if (t < 0.0) t = 0.0; else if (t > 1.0) t = 1.0;
                    }
                    const double wl = w0 + (w1 - w0) * t;
                    const double taper = tp0 + (tp1 - tp0) * t;  // 端点半径乘子（1=满宽→尖点淡出）
                    const double radius = base_radius_px * (0.18 + std::pow(wl, 1.85) * 5.2) * taper;
                    const float closx = p0x + segx * float(t);
                    const float closy = p0y + segy * float(t);
                    const float ddx = px - closx;
                    const float ddy = py - closy;
                    const float dpix = std::sqrt(ddx * ddx + ddy * ddy);
                    // Keep the true local river radius in the distance seed. With a binary
                    // inside/outside mask, low-density tiles quantize every small tributary
                    // to the same one-pixel source before the SDF pass can see its flow.
                    const double edge_distance = std::max(0.0, double(dpix) - radius);
                    const float chamfer_seed = float(edge_distance * 3.0);
                    float &seed = mask[size_t(y) * w + x];
                    if (chamfer_seed < seed) seed = chamfer_seed;
                }
            }
        }
    };

    // ── 河流图遍历（镜像 _trace_all_rivers / _trace_river_chain / _find_river_*）──
    // 读 ext 暂存拓扑（by cell.index，与 _assemble_native_generation_map 装配顺序一致）。
    const int32_t * const RQ = _gen_river_q.data();
    const int32_t * const RR = _gen_river_r.data();
    const uint8_t * const RT = _gen_river_terrain.data();
    const float   * const RE = _gen_river_elev.data();
    const uint8_t * const RH = _gen_river_has.data();
    const float   * const RF = _gen_river_flow.data();
    const int32_t * const RD = _gen_river_downstream.data();
    const int32_t * const RNB = _gen_river_neighbors.data();
    const float root3 = std::sqrt(3.0f);
    // cube_to_world（pointy-top，镜像 HexUtils.cube_to_world）+ 生成期 width=clamp(river_flow)
    auto cube_wx = [&](int i) -> float { return hex_size * root3 * (float(RQ[i]) + float(RR[i]) * 0.5f); };
    auto cube_wy = [&](int i) -> float { return hex_size * 1.5f * float(RR[i]); };
    auto width_w = [&](int i) -> float { const float f = RF[i]; return f < 0.0f ? 0.0f : (f > 1.0f ? 1.0f : f); };
    // _is_river_terminal_water ≡ pk_is_water_terrain（OCEAN/COAST/LAKE/REEF/KELP/SEA_ICE 同集合）
    auto find_downstream = [&](int i) -> int {  // 镜像 _find_river_downstream_neighbor
        const int dec = RD[i];
        if (dec >= 0 && dec < rn && (RH[dec] || pk_is_water_terrain(RT[dec]))) return dec;
        int best = -1; float best_flow = RF[i];
        for (int d = 0; d < 6; ++d) {
            const int nb = RNB[size_t(i) * 6 + d];
            if (nb < 0) continue;
            if (!RH[nb] || pk_is_water_terrain(RT[nb])) continue;
            if (RF[nb] > best_flow || (std::fabs(RF[nb] - best_flow) <= 1e-5f && RE[nb] < RE[i])) {
                best_flow = RF[nb]; best = nb;
            }
        }
        return best;
    };
    auto find_terminal_water = [&](int i) -> int {  // 镜像 _find_river_terminal_water_neighbor
        int best = -1;
        for (int d = 0; d < 6; ++d) {
            const int nb = RNB[size_t(i) * 6 + d];
            if (nb < 0 || !pk_is_water_terrain(RT[nb])) continue;
            if (best < 0 || RE[nb] < RE[best]) best = nb;
        }
        return best;
    };

    // chains：每条链 = world 点序列 + 宽度 + 端点 taper（镜像 _trace_all_rivers 输出）
    std::vector<std::vector<float>> chain_x, chain_y, chain_w, chain_t;
    {
        // 端点淡出弧长（世界单位）：约 taper_cells 个 hex 间距（pointy-top 邻距 ≈ hex_size*√3）。
        const float taper_dist = hex_size * root3 * float(taper_cells);
        auto sstep01 = [](float e) -> float {
            if (e <= 0.0f) return 0.0f;
            if (e >= 1.0f) return 1.0f;
            return e * e * (3.0f - 2.0f * e);
        };
        std::vector<uint8_t> visited(size_t(rn), 0);
        std::vector<int> inbound(size_t(rn), 0);
        // pass1：inbound 计数（确定源头）
        for (int i = 0; i < rn; ++i) {
            if (!RH[i] || pk_is_water_terrain(RT[i])) continue;
            const int dec = RD[i];
            if (dec >= 0 && dec < rn && RH[dec] && !pk_is_water_terrain(RT[dec])) inbound[dec] += 1;
        }
        // pass2：从源头（inbound==0、未访问）trace 整条链
        for (int i = 0; i < rn; ++i) {
            if (!RH[i] || pk_is_water_terrain(RT[i])) continue;
            if (visited[i] || inbound[i] > 0) continue;
            std::vector<float> px, py, pw;
            px.push_back(cube_wx(i)); py.push_back(cube_wy(i)); pw.push_back(width_w(i));
            visited[i] = 1;
            int current = i;
            bool ended_in_water = false;
            bool ended_at_confluence = false;  // 在已访问的河格汇入另一条链 → 末端必须接住、不淡出
            while (true) {
                const int nxt = find_downstream(current);
                if (nxt < 0) break;
                const bool nxt_water = pk_is_water_terrain(RT[nxt]);
                px.push_back(cube_wx(nxt)); py.push_back(cube_wy(nxt));
                pw.push_back(width_w(nxt_water ? current : nxt));
                if (nxt_water) { current = nxt; ended_in_water = true; break; }
                current = nxt;
                if (visited[nxt]) { ended_at_confluence = true; break; }
                visited[nxt] = 1;
            }
            // 尾巴伸入终端水体一半（lerp 0.78），避免河口在最后陆地 cell 中心硬截断。
            bool reached_water = ended_in_water;
            if (!ended_in_water) {
                const int wnb = find_terminal_water(current);
                if (wnb >= 0) {
                    const float rex = cube_wx(current), rey = cube_wy(current);
                    const float wcx = cube_wx(wnb), wcy = cube_wy(wnb);
                    float water_dx = wcx - rex;
                    if (wrap_period_x > 0.0001) {
                        const float half_period = float(wrap_period_x * 0.5);
                        if (water_dx > half_period) water_dx -= float(wrap_period_x);
                        else if (water_dx < -half_period) water_dx += float(wrap_period_x);
                    }
                    px.push_back(rex + water_dx * 0.78f);
                    py.push_back(rey + (wcy - rey) * 0.78f);
                    pw.push_back(pw.empty() ? 0.5f : pw.back());
                    reached_water = true;
                }
            }
            const int np = int(px.size());
            if (np < 2) continue;
            // Keep a wrapped chain continuous in one unwrapped longitude frame. The
            // raster stage emits only the periodic copies intersecting this target.
            if (wrap_period_x > 0.0001) {
                const float period = float(wrap_period_x);
                const float half_period = period * 0.5f;
                for (int k = 1; k < np; ++k) {
                    while (px[k] - px[k - 1] > half_period) px[k] -= period;
                    while (px[k] - px[k - 1] < -half_period) px[k] += period;
                }
            }
            // ── 端点 taper：源头(链首)恒淡出成尖点；陆地死端(链尾且未入水、非汇流)也淡出。
            //    入海/入湖口、汇流接点保持满宽(taper=1)以接住水体/相邻链。──
            std::vector<float> pt(size_t(np), 1.0f);
            if (taper_dist > 1e-4f) {
                const bool tail_is_dead = (!reached_water) && (!ended_at_confluence);
                std::vector<float> arc(size_t(np), 0.0f);
                for (int k = 1; k < np; ++k) {
                    const float dx = px[k] - px[k - 1];
                    const float dy = py[k] - py[k - 1];
                    arc[k] = arc[k - 1] + std::sqrt(dx * dx + dy * dy);
                }
                const float total = arc[np - 1];
                const float inv_td = 1.0f / taper_dist;
                for (int k = 0; k < np; ++k) {
                    float f = sstep01(arc[k] * inv_td);              // 链首淡入（恒开）
                    if (tail_is_dead) {
                        f = std::min(f, sstep01((total - arc[k]) * inv_td));  // 链尾淡出
                    }
                    pt[k] = std::max(f, taper_floor);
                }
            }
            chain_x.push_back(px); chain_y.push_back(py); chain_w.push_back(pw); chain_t.push_back(pt);
        }
    }

    // ── 遍历 chains：连续经度 run + 与目标相交的周期副本 ──
    {
        std::vector<float> shifted_x;
        const double raster_min_x = double(origin_x);
        const double raster_max_x = double(origin_x) + double(w) / double(inv_world_x);
        const double max_radius_px = base_radius_px * 5.4 + sdf_max_dist_px + 2.0;
        const double margin_x = max_radius_px / double(inv_world_x);
        for (size_t c = 0; c < chain_x.size(); ++c) {
            const std::vector<float> &px = chain_x[c];
            const std::vector<float> &py = chain_y[c];
            const std::vector<float> &pw = chain_w[c];
            const std::vector<float> &ptp = chain_t[c];
            const int clen = int(px.size());
            if (clen < 2) continue;
            if (wrap_period_x <= 0.0001) {
                stamp_run(px, py, pw, ptp);
                continue;
            }
            const auto bounds = std::minmax_element(px.begin(), px.end());
            const double chain_min_x = double(*bounds.first);
            const double chain_max_x = double(*bounds.second);
            const int copy_min = int(std::ceil(
                    (raster_min_x - margin_x - chain_max_x) / wrap_period_x));
            const int copy_max = int(std::floor(
                    (raster_max_x + margin_x - chain_min_x) / wrap_period_x));
            for (int copy = copy_min; copy <= copy_max; ++copy) {
                if (copy == 0) {
                    stamp_run(px, py, pw, ptp);
                    continue;
                }
                shifted_x.resize(px.size());
                const float shift = float(double(copy) * wrap_period_x);
                for (size_t k = 0; k < px.size(); ++k) shifted_x[k] = px[k] + shift;
                stamp_run(shifted_x, py, pw, ptp);
            }
        }
    }

    // ── chamfer 3-4 双通 SDT（镜像 _chamfer_sdt）──
    const double d3 = 3.0, d4 = 4.0;
    for (int y = 0; y < h; ++y) {
        for (int x = 0; x < w; ++x) {
            const int idx = y * w + x;
            double v = double(mask[idx]);
            if (v <= 0.0) continue;
            if (x > 0) { double c = double(mask[idx - 1]) + d3; if (c < v) v = c; }
            if (y > 0) {
                double c = double(mask[idx - w]) + d3; if (c < v) v = c;
                if (x > 0) { double c2 = double(mask[idx - w - 1]) + d4; if (c2 < v) v = c2; }
                if (x < w - 1) { double c2 = double(mask[idx - w + 1]) + d4; if (c2 < v) v = c2; }
            }
            mask[idx] = float(v);
        }
    }
    for (int y = h - 1; y >= 0; --y) {
        for (int x = w - 1; x >= 0; --x) {
            const int idx = y * w + x;
            double v = double(mask[idx]);
            if (v <= 0.0) continue;
            if (x < w - 1) { double c = double(mask[idx + 1]) + d3; if (c < v) v = c; }
            if (y < h - 1) {
                double c = double(mask[idx + w]) + d3; if (c < v) v = c;
                if (x > 0) { double c2 = double(mask[idx + w - 1]) + d4; if (c2 < v) v = c2; }
                if (x < w - 1) { double c2 = double(mask[idx + w + 1]) + d4; if (c2 < v) v = c2; }
            }
            mask[idx] = float(v);
        }
    }
    const double inv3 = 1.0 / 3.0;
    // 归一化为 [0,1]：1 = 河上，0 = 距离 >= SDF_MAX_DIST_PX
    const double inv_max = 1.0 / sdf_max_dist_px;
    for (int i = 0; i < n; ++i) {
        const double m = double(mask[i]) * inv3;
        double tt = m * inv_max;
        if (tt < 0.0) tt = 0.0; else if (tt > 1.0) tt = 1.0;
        OUT[i] = float(1.0 - tt);
    }

    auto t1 = std::chrono::high_resolution_clock::now();

    out["fallback"] = false;
    out["reason"] = String();
    out["path"] = String("gdext");
    out["elapsed_ms"] = std::chrono::duration<double, std::milli>(t1 - t0).count();
    out["out_buf"] = out_buf;
    out["width"] = w;
    out["height"] = h;
    out["format"] = String("F32");
    return out;
}

// run_bake_erosion_pass — 复刻 map_baker.gd::_hydraulic_erosion（droplet 水力侵蚀）。
// 用 Ref<RandomNumberGenerator>（同 seed 复刻 baker _rng PCG）。in/out height，内部 clamp。
godot::Dictionary DCWorldExt::run_bake_erosion_pass(godot::Dictionary knobs) {
    using godot::Dictionary;
    using godot::PackedFloat32Array;
    using godot::RandomNumberGenerator;
    using godot::Ref;
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
    if (src.size() < n) return fail("height buffer too small");

    const int seed = int(knobs.get("seed", 0));
    const int num_drops = int(knobs.get("num_drops", 0));
    const int max_steps = int(knobs.get("max_steps", 0));
    const double inertia = double(knobs.get("inertia", 0.10));
    const double capacity_factor = double(knobs.get("capacity_factor", 1.5));
    const double min_capacity = double(knobs.get("min_capacity", 0.01));
    const double deposit_speed = double(knobs.get("deposit_speed", 0.30));
    const double erode_speed = double(knobs.get("erode_speed", 0.10));
    const double evaporation = double(knobs.get("evaporation", 0.025));
    const double gravity = double(knobs.get("gravity", 4.0));
    const int brush_radius = int(knobs.get("brush_radius", 2));

    PackedFloat32Array height_out;
    height_out.resize(n);
    {
        const float * const __restrict S = src.ptr();
        float * const __restrict D = height_out.ptrw();
        for (int i = 0; i < n; ++i) D[i] = S[i];
    }
    float * const __restrict HT = height_out.ptrw();

    auto t0 = std::chrono::high_resolution_clock::now();

    if (num_drops > 0) {
        // ── brush kernel（镜像 GDScript 预计算）──
        std::vector<int> brush_dx, brush_dy;
        std::vector<double> brush_w;
        double sum_w = 0.0;
        const int br_sq = brush_radius * brush_radius;
        for (int dy = -brush_radius; dy <= brush_radius; ++dy) {
            for (int dx = -brush_radius; dx <= brush_radius; ++dx) {
                const int d_sq = dx * dx + dy * dy;
                if (d_sq > br_sq) continue;
                const double wv = 1.0 - std::sqrt(double(d_sq)) / double(brush_radius);
                brush_dx.push_back(dx);
                brush_dy.push_back(dy);
                brush_w.push_back(wv);
                sum_w += wv;
            }
        }
        const int brush_count = int(brush_w.size());
        if (sum_w > 0.0) {
            const double inv_sum = 1.0 / sum_w;
            for (int i = 0; i < brush_count; ++i) brush_w[i] *= inv_sum;
        }

        Ref<RandomNumberGenerator> rng;  rng.instantiate();
        if (rng.is_null()) return fail("rng_instantiate_failed");
        rng->set_seed(uint64_t(seed));

        const double W_f = double(w);
        const double H_f = double(h);
        static const double PK_TAU = 6.283185307179586232;

        for (int drop_idx = 0; drop_idx < num_drops; ++drop_idx) {
            double pos_x = rng->randf_range(1.0, W_f - 2.0);
            double pos_y = rng->randf_range(1.0, H_f - 2.0);
            double dir_x = 0.0, dir_y = 0.0;
            double speed = 1.0, water = 1.0, sediment = 0.0;

            for (int step = 0; step < max_steps; ++step) {
                const int node_x = int(std::floor(pos_x));
                const int node_y = int(std::floor(pos_y));
                if (node_x < 0 || node_x >= w - 1 || node_y < 0 || node_y >= h - 1) break;
                const double cell_offset_x = pos_x - double(node_x);
                const double cell_offset_y = pos_y - double(node_y);
                const double one_minus_x = 1.0 - cell_offset_x;
                const double one_minus_y = 1.0 - cell_offset_y;

                const int idx_00 = node_y * w + node_x;
                const int idx_10 = idx_00 + 1;
                const int idx_01 = idx_00 + w;
                const int idx_11 = idx_01 + 1;

                const double h00 = double(HT[idx_00]);
                const double h10 = double(HT[idx_10]);
                const double h01 = double(HT[idx_01]);
                const double h11 = double(HT[idx_11]);

                const double h_old = h00 * one_minus_x * one_minus_y
                        + h10 * cell_offset_x * one_minus_y
                        + h01 * one_minus_x * cell_offset_y
                        + h11 * cell_offset_x * cell_offset_y;
                const double grad_x = (h10 - h00) * one_minus_y + (h11 - h01) * cell_offset_y;
                const double grad_y = (h01 - h00) * one_minus_x + (h11 - h10) * cell_offset_x;

                dir_x = dir_x * inertia - grad_x * (1.0 - inertia);
                dir_y = dir_y * inertia - grad_y * (1.0 - inertia);
                const double dir_len_sq = dir_x * dir_x + dir_y * dir_y;
                if (dir_len_sq < 0.000001) {
                    const double ang = rng->randf_range(0.0, PK_TAU);
                    dir_x = std::cos(ang);
                    dir_y = std::sin(ang);
                } else {
                    const double inv_len = 1.0 / std::sqrt(dir_len_sq);
                    dir_x *= inv_len;
                    dir_y *= inv_len;
                }

                const double new_pos_x = pos_x + dir_x;
                const double new_pos_y = pos_y + dir_y;
                if (new_pos_x < 1.0 || new_pos_x >= W_f - 1.0 || new_pos_y < 1.0 || new_pos_y >= H_f - 1.0) {
                    if (sediment > 0.0) {
                        HT[idx_00] += float(sediment * one_minus_x * one_minus_y);
                        HT[idx_10] += float(sediment * cell_offset_x * one_minus_y);
                        HT[idx_01] += float(sediment * one_minus_x * cell_offset_y);
                        HT[idx_11] += float(sediment * cell_offset_x * cell_offset_y);
                    }
                    break;
                }

                const int nnx = int(std::floor(new_pos_x));
                const int nny = int(std::floor(new_pos_y));
                const double ncx = new_pos_x - double(nnx);
                const double ncy = new_pos_y - double(nny);
                const int nidx00 = nny * w + nnx;
                const double h_new = double(HT[nidx00]) * (1.0 - ncx) * (1.0 - ncy)
                        + double(HT[nidx00 + 1]) * ncx * (1.0 - ncy)
                        + double(HT[nidx00 + w]) * (1.0 - ncx) * ncy
                        + double(HT[nidx00 + w + 1]) * ncx * ncy;
                const double delta_h = h_new - h_old;
                const double capacity = std::max(-delta_h, min_capacity) * speed * water * capacity_factor;

                if (sediment > capacity || delta_h > 0.0) {
                    double deposit_amt;
                    if (delta_h > 0.0) deposit_amt = std::min(delta_h, sediment);
                    else deposit_amt = (sediment - capacity) * deposit_speed;
                    sediment -= deposit_amt;
                    HT[idx_00] += float(deposit_amt * one_minus_x * one_minus_y);
                    HT[idx_10] += float(deposit_amt * cell_offset_x * one_minus_y);
                    HT[idx_01] += float(deposit_amt * one_minus_x * cell_offset_y);
                    HT[idx_11] += float(deposit_amt * cell_offset_x * cell_offset_y);
                } else {
                    const double erode_amt = std::min((capacity - sediment) * erode_speed, -delta_h);
                    for (int i = 0; i < brush_count; ++i) {
                        const int bx = node_x + brush_dx[i];
                        const int by = node_y + brush_dy[i];
                        if (bx < 0 || bx >= w || by < 0 || by >= h) continue;
                        const int bidx = by * w + bx;
                        const double weighted = erode_amt * brush_w[i];
                        const double actual = std::min(double(HT[bidx]), weighted);
                        HT[bidx] -= float(actual);
                        sediment += actual;
                    }
                }

                const double spd_sq = speed * speed + delta_h * gravity;
                speed = std::sqrt(std::max(spd_sq, 0.0));
                water *= (1.0 - evaporation);
                pos_x = new_pos_x;
                pos_y = new_pos_y;
                if (water < 0.001) break;
            }
        }
    }

    // clamp [0,1]（折叠原 _clamp_buffer，省一次 GDScript W*H loop）
    for (int i = 0; i < n; ++i) {
        float v = HT[i];
        if (v < 0.0f) v = 0.0f; else if (v > 1.0f) v = 1.0f;
        HT[i] = v;
    }

    auto t1 = std::chrono::high_resolution_clock::now();

    out["fallback"] = false;
    out["reason"] = String();
    out["path"] = String("gdext");
    out["elapsed_ms"] = std::chrono::duration<double, std::milli>(t1 - t0).count();
    out["height_out"] = height_out;
    out["width"] = w;
    out["height"] = h;
    out["format"] = String("F32");
    return out;
}

// ─────────────────────────────────────────────────────────────────────────
// run_bake_coast_sdf_pass — 海/湖统一"离岸像素距离场"(water-bodies systemic)。
// 从 per-pixel terrain(biome_buffer)的 land-water 边界做 chamfer 3-4 双通距离变换，产出每像素
// 到最近水体的像素距离(水体=0，向内陆递增，clamp 于 coast_sdf_max_dist_px)。供
// run_bake_geometry_fields_pass 在 river carve 后对 height_final 刻连续岸坡 → crisp 海岸/湖岸
// 法线。水集合与 terrain_index is_water / pk_is_water_terrain 对齐 = {0,1,18,19,20,21}。
// buffer-encoder 范式：循环外解析 knobs、初始 fallback=true、裸指针 __restrict、统一 report。
// 注：chamfer 两遍光栅扫描有行间依赖，单线程；O(n_pixels) 量级 <几 ms（如需并行可换 jump-flood）。
// ─────────────────────────────────────────────────────────────────────────
godot::Dictionary DCWorldExt::run_bake_coast_sdf_pass(godot::Dictionary knobs) {
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

    PackedByteArray biome = knobs.get("biome_buffer", PackedByteArray());
    if (biome.size() != n) return fail("biome_buffer size != w*h");

    const double max_dist_px = double(knobs.get("coast_sdf_max_dist_px", 8.0));
    const bool   wrap_x      = bool(knobs.get("coast_sdf_wrap_x", true));

    auto t0 = std::chrono::high_resolution_clock::now();

    const uint8_t * const __restrict BIO = biome.ptr();
    auto is_water_px = [](uint8_t t) -> bool {
        return t == 0 || t == 1 || t == 18 || t == 19 || t == 20 || t == 21;
    };

    // chamfer 以"×3"整数权重累计（orthogonal=3, diagonal=4），最后 /3 得 ~欧氏像素距离。
    constexpr float CH_ORTH = 3.0f;
    constexpr float CH_DIAG = 4.0f;
    const float BIG = 1.0e9f;
    std::vector<float> dist(size_t(n), BIG);
    for (int i = 0; i < n; ++i) if (is_water_px(BIO[i])) dist[size_t(i)] = 0.0f;

    auto col_wrap = [&](int x) -> int {
        if (wrap_x) { if (x < 0) x += w; else if (x >= w) x -= w; return x; }
        return (x < 0 || x >= w) ? -1 : x;
    };
    auto at = [&](int x, int y) -> int {
        const int xx = col_wrap(x);
        if (xx < 0 || y < 0 || y >= h) return -1;
        return y * w + xx;
    };
    auto relax = [&](int cur, int nx, int ny, float wgt) {
        const int ni = at(nx, ny);
        if (ni < 0) return;
        const float v = dist[size_t(ni)] + wgt;
        if (v < dist[size_t(cur)]) dist[size_t(cur)] = v;
    };

    // forward：左上 → 右下（读 上行 三邻 + 本行左邻）。
    for (int y = 0; y < h; ++y) {
        for (int x = 0; x < w; ++x) {
            const int cur = y * w + x;
            if (dist[size_t(cur)] == 0.0f) continue;
            relax(cur, x - 1, y,     CH_ORTH);
            relax(cur, x,     y - 1, CH_ORTH);
            relax(cur, x - 1, y - 1, CH_DIAG);
            relax(cur, x + 1, y - 1, CH_DIAG);
        }
    }
    // backward：右下 → 左上（读 下行 三邻 + 本行右邻）。
    for (int y = h - 1; y >= 0; --y) {
        for (int x = w - 1; x >= 0; --x) {
            const int cur = y * w + x;
            if (dist[size_t(cur)] == 0.0f) continue;
            relax(cur, x + 1, y,     CH_ORTH);
            relax(cur, x,     y + 1, CH_ORTH);
            relax(cur, x + 1, y + 1, CH_DIAG);
            relax(cur, x - 1, y + 1, CH_DIAG);
        }
    }

    PackedFloat32Array out_buf;
    out_buf.resize(n);
    float * const __restrict OUT = out_buf.ptrw();
    const float maxf = float(max_dist_px);
    for (int i = 0; i < n; ++i) {
        float d = dist[size_t(i)];
        if (d >= BIG) d = maxf;          // 远内陆未达 → 截断
        else d = d / 3.0f;               // ×3 权重 → 像素距离
        if (d > maxf) d = maxf;
        OUT[i] = d;
    }

    auto t1 = std::chrono::high_resolution_clock::now();
    out["fallback"] = false;
    out["path"] = String("gdext");
    out["reason"] = String();
    out["out_buf"] = out_buf;
    out["width"] = w;
    out["height"] = h;
    out["elapsed_ms"] = std::chrono::duration<double, std::milli>(t1 - t0).count();
    return out;
}

// ─────────────────────────────────────────────────────────────────────────
// run_bake_geometry_fields_pass — bake 期几何场编排下沉 C++（dots-total-cpp step2）
// GDScript 一次请求 → C++ 进程内串起 terrain-index → erosion → river → latitude，
// 中间 buffer（尤其 height_buffer）不跨语言往返，一次返回完整 bundle。
// ─────────────────────────────────────────────────────────────────────────
godot::Dictionary DCWorldExt::run_bake_geometry_fields_pass(godot::Dictionary knobs) {
    using godot::Dictionary;
    using godot::PackedByteArray;
    using godot::PackedFloat32Array;
    using godot::PackedInt32Array;
    using godot::String;

    Dictionary out;
    out["fallback"] = true;
    out["reason"] = String();
    out["path"] = String("gdscript");

    const int w = int(knobs.get("width", knobs.get("w", 0)));
    const int h = int(knobs.get("height", knobs.get("h", 0)));
    if (w <= 0 || h <= 0) {
        out["reason"] = String("invalid size");
        return out;
    }

    auto t_all0 = std::chrono::high_resolution_clock::now();

    // ① terrain-index：height/biome/moisture/veg/cover + CSR + pixel_to_cell_index。
    Dictionary terr = run_bake_terrain_index_pass(knobs);
    const bool terr_fallback = bool(terr.get("fallback", true));
    if (terr_fallback) {
        // terrain 是 bundle 的数据枢纽（CSR / pixel_to_cell 后续解包必需）；失败则整体 fallback，
        // 由 GDScript 回退旧 per-pass / _bake_height_biome_moisture 路径。
        out["reason"] = String("terrain_index_fallback:") + String(terr.get("reason", String()));
        return out;
    }
    PackedFloat32Array height_buf = terr.get("height_buffer", PackedFloat32Array());

    // ② erosion：in/out height（C++ 内注入 height_buffer，不跨语言）。失败用未侵蚀 height 续算。
    knobs["height_buffer"] = height_buf;
    Dictionary ero = run_bake_erosion_pass(knobs);
    const bool ero_ok = !bool(ero.get("fallback", true));
    PackedFloat32Array height_final = height_buf;
    if (ero_ok) {
        PackedFloat32Array he = ero.get("height_out", PackedFloat32Array());
        if (he.size() == height_buf.size()) height_final = he;
    }

    // ③ river SDF：读 ext 暂存拓扑（_gen_river_*），trace+CR+warp+stamp+chamfer+normalize。
    Dictionary riv = run_bake_river_sdf_pass(knobs);
    const bool riv_ok = !bool(riv.get("fallback", true));

    // ④ latitude。
    Dictionary lat = run_bake_latitude_field_pass(knobs);
    const bool lat_ok = !bool(lat.get("fallback", true));

    // [river-carve-bake 2026-06-25] #2a 河流切进 bake height_buffer（per-pixel，crisp 河岸法线）──
    // river SDF(flow_buffer：河心=1→远岸=0)算完后、bundle 前，按 flow 对 height_final 逐像素刻 V 形河谷。
    // flow 的 SDF 衰减天然形成河岸坡 → terrain_normal_tex/height_tex/relief 都读得到 crisp 河岸；与 #2b
    // (仿真 E 的 cell 级河谷+堤岸)叠加成多尺度河岸。仅陆地段(height>sea_level，不刻入海口/水下)；
    // fused 内 height_final 与 flow 均为 hm_size、索引对齐。GDScript legacy 路径镜像见 _carve_river_into_height。
    if (riv_ok) {
        PackedFloat32Array flow = riv.get("out_buf", PackedFloat32Array());
        const int nf = w * h;
        if (flow.size() == nf && height_final.size() == nf) {
            constexpr double PK_BAKE_RIVER_INCISE = 0.045;  // bake 河道最大下切(height 单位，× notch)
            const double bake_sea = double(knobs.get("sea_level", 0.64));
            float * const HF = height_final.ptrw();
            const float * const FL = flow.ptr();
            for (int i = 0; i < nf; ++i) {
                const double f = double(FL[i]);
                if (f <= 0.02) continue;
                double e = double(HF[i]);
                if (e <= bake_sea) continue;                    // 不刻入海口/水下
                const double notch = f * f * (3.0 - 2.0 * f);   // smoothstep 锐化河岸坡
                e -= PK_BAKE_RIVER_INCISE * notch;
                if (e < 0.0) e = 0.0;
                HF[i] = float(e);
            }
        }
    }

    // [coast-carve-bake water-bodies] 海/湖统一离岸像素 SDF 岸坡 carve（对标河流 #2a 真实做法）──
    // 在 river carve 之后、bundle 之前，用独立 run_bake_coast_sdf_pass(chamfer DT) 算出每像素
    // 离岸距离，对 height_final 逐像素刻"陆侧上坡、止于水线"的连续岸坡 → terrain_normal_tex 拿到
    // crisp 海岸/湖岸法线（取代仅贴水 1-cell 带的 barycentric beach carve，与之加性叠加、单调下切，
    // 两者都向水线方向下压且 clamp 到 sea_level，叠加无冲突）。shore_carve_amp<=0 → 关闭（回退旧法）。
    Dictionary coast;
    bool coast_ok = false;
    {
        const double shore_carve_amp  = double(knobs.get("shore_carve_amp", 0.06));
        const int    shore_carve_band = int(knobs.get("shore_carve_band", 6));
        if (shore_carve_amp > 0.0 && shore_carve_band > 0) {
            knobs["biome_buffer"] = terr.get("biome_buffer", PackedByteArray());
            coast = run_bake_coast_sdf_pass(knobs);
            coast_ok = !bool(coast.get("fallback", true));
            if (coast_ok) {
                PackedFloat32Array csdf = coast.get("out_buf", PackedFloat32Array());
                const int nc = w * h;
                if (csdf.size() == nc && height_final.size() == nc) {
                    const double bake_sea = double(knobs.get("sea_level", 0.64));
                    const double inv_band = 1.0 / double(shore_carve_band);
                    float * const HF = height_final.ptrw();
                    const float * const CD = csdf.ptr();
                    for (int i = 0; i < nc; ++i) {
                        const double d = double(CD[i]);              // 离水像素距离（0=水/水线）
                        if (d <= 0.0 || d > double(shore_carve_band)) continue; // 水体自身 / 带外不刻
                        double e = double(HF[i]);
                        if (e <= bake_sea) continue;                 // 不刻水下
                        const double tband = 1.0 - d * inv_band;     // 近岸=1 → 带缘=0
                        const double notch = tband * tband * (3.0 - 2.0 * tband); // smoothstep 锐化
                        e -= shore_carve_amp * notch;
                        if (e < bake_sea) e = bake_sea;              // 止于水线
                        HF[i] = float(e);
                    }
                }
            }
        }
    }

    // ── [water-depth-tex 2026-06-26] 海/湖统一水深 R8（per-pixel，使用真实高程图）──────────────
    // 关键：per-cell cell_water_depth 现承载"水面高度 level"（湖=hydro_fill、海=sea_level、陆=0），
    // 逐像素用 surface - height_final（含 carve 的湖盆/洋底 + 侵蚀细节）得真实水深，再按水体类型归一化
    // （湖用湖深尺度、海用 sea_level → 湖也能吃满 [0,1] 对比）。shader 每水像素仅 1 次采样。
    // 缺失/尺寸不符 → 输出空 buffer（shader 端按缺纹理回退旧路径）。
    PackedByteArray water_depth_buf;
    {
        PackedFloat32Array cell_surf = knobs.get("cell_water_depth", PackedFloat32Array());
        PackedByteArray    cell_terr = knobs.get("cell_terrain", PackedByteArray());
        PackedInt32Array p2c = terr.get("pixel_to_cell_index", PackedInt32Array());
        const int n_cells_wd = int(knobs.get("n_cells", 0));
        const double sea = double(knobs.get("sea_level", 0.64));
        const int np = w * h;
        // 湖泊水深归一尺度（height 单位）：与 world_ext_generate 的 PK_LAKE_MAX_DEPTH(0.24) 同量级、
        // 略小以放大对比 → 湖心吃满深色、近岸浅色。
        const double LAKE_DEPTH_NORM = 0.16;
        if (n_cells_wd > 0 && cell_surf.size() == n_cells_wd && p2c.size() == np
                && height_final.size() == np && sea > 1e-4) {
            water_depth_buf.resize(np);
            uint8_t * const __restrict WB = water_depth_buf.ptrw();
            const float * const __restrict SF = cell_surf.ptr();
            const uint8_t * const __restrict CT = (cell_terr.size() == n_cells_wd) ? cell_terr.ptr() : nullptr;
            const int32_t * const __restrict P2C = p2c.ptr();
            const float * const __restrict HF = height_final.ptr();
            const double inv_sea = 1.0 / sea;
            const double inv_lake = 1.0 / LAKE_DEPTH_NORM;
            for (int i = 0; i < np; ++i) {
                const int ci = P2C[i];
                double depth01 = 0.0;
                if (ci >= 0 && ci < n_cells_wd) {
                    const double surface = double(SF[ci]);   // per-cell 水面高度（陆地=0）
                    if (surface > 1e-4) {
                        double draw = surface - double(HF[i]);  // 逐像素真实水深（height 单位）
                        if (draw < 0.0) draw = 0.0;
                        const bool is_lake = (CT != nullptr) && (CT[ci] == 18);
                        depth01 = draw * (is_lake ? inv_lake : inv_sea);
                        if (depth01 > 1.0) depth01 = 1.0;
                    }
                }
                int b = int(depth01 * 255.0 + 0.5);
                if (b < 0) b = 0; else if (b > 255) b = 255;
                WB[i] = uint8_t(b);
            }
        }
    }

    auto t_all1 = std::chrono::high_resolution_clock::now();

    // ── 合并 bundle ──
    out["fallback"] = false;
    out["reason"] = String();
    out["path"] = String("gdext");
    out["width"] = w;
    out["height"] = h;

    // terrain 字段（数据枢纽，原样透传）
    out["height_buffer"] = height_final;  // 已含侵蚀
    out["biome_buffer"] = terr.get("biome_buffer", PackedByteArray());
    out["moisture_buffer"] = terr.get("moisture_buffer", PackedFloat32Array());
    out["vegetation_buffer"] = terr.get("vegetation_buffer", PackedByteArray());
    out["cover_buffer"] = terr.get("cover_buffer", PackedByteArray());
    out["pixel_to_cell_index"] = terr.get("pixel_to_cell_index", PackedInt32Array());
    out["edge_secondary_index_buffer"] = terr.get("edge_secondary_index_buffer", PackedByteArray());
    out["edge_distance_buffer"] = terr.get("edge_distance_buffer", PackedByteArray());
    out["cell_first_px"] = terr.get("cell_first_px", PackedInt32Array());
    out["cell_px_count"] = terr.get("cell_px_count", PackedInt32Array());
    out["flat_px_indices"] = terr.get("flat_px_indices", PackedInt32Array());
    out["total_px"] = terr.get("total_px", 0);

    // 其余几何场（失败置空，由 GDScript 决定是否硬报错）
    out["flow_buffer"] = riv_ok ? PackedFloat32Array(riv.get("out_buf", PackedFloat32Array())) : PackedFloat32Array();
    out["latitude_buffer"] = lat_ok ? PackedFloat32Array(lat.get("latitude_buffer", PackedFloat32Array())) : PackedFloat32Array();
    out["water_depth_buffer"] = water_depth_buf;  // [water-depth-tex] 海/湖统一 R8 深度（空=回退旧 shader 路径）

    // coast SDF（离岸距离场，供调试/校验；carve 已就地作用于 height_final）
    out["coast_ok"] = coast_ok;
    out["coast_sdf_buffer"] = coast_ok ? PackedFloat32Array(coast.get("out_buf", PackedFloat32Array())) : PackedFloat32Array();
    out["coast_ms"] = coast_ok ? coast.get("elapsed_ms", -1.0) : Variant(-1.0);
    out["coast_reason"] = coast.get("reason", String());

    // stage 诊断（GDScript 打印 / 校验用）
    out["terrain_ok"] = true;
    out["erosion_ok"] = ero_ok;
    out["river_ok"] = riv_ok;
    out["latitude_ok"] = lat_ok;
    out["terrain_ms"] = terr.get("elapsed_ms", -1.0);
    out["erosion_ms"] = ero.get("elapsed_ms", -1.0);
    out["river_ms"] = riv.get("elapsed_ms", -1.0);
    out["latitude_ms"] = lat.get("elapsed_ms", -1.0);
    out["river_reason"] = riv.get("reason", String());
    out["elapsed_ms"] = std::chrono::duration<double, std::milli>(t_all1 - t_all0).count();
    return out;
}

// ─────────────────────────────────────────────────────────────────────────
// run_bake_terrain_index_pass — 生成期 height/biome/moisture/veg/cover 逐像素烘焙
// 复刻 map_baker.gd::_bake_height_biome_moisture（warp + cube_round + sextant
// barycentric + per-biome detail noise）。离散数据始终归属 cube_round 的硬主 cell；
// 视觉边界另行输出副 cell RG8 与边界距离 R8，避免 atlas-space dither 被近景放大。
//
// 全程经 knobs 传参（不依赖 bound slot —— bake 发生在 generation 期、bind 时机
// 不确定，与 encode_bake_* 同范式）。输出 CSR 三件套（按 cell.index）直接喂
// encode_bake_enum_atlas_payload；G/B/A 由硬主 cell 的桶成员驱动。
// ─────────────────────────────────────────────────────────────────────────
godot::Dictionary DCWorldExt::run_bake_terrain_index_pass(godot::Dictionary knobs) {
    using godot::Dictionary;
    using godot::PackedByteArray;
    using godot::PackedFloat32Array;
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

    const int W = int(knobs.get("width", 0));
    const int H = int(knobs.get("height", 0));
    const int n_pix = W * H;
    if (W <= 0 || H <= 0 || n_pix <= 0) return fail("invalid size");

    const int map_w = int(knobs.get("map_width", 0));
    const int map_h = int(knobs.get("map_height", 0));
    const int n_cells = int(knobs.get("n_cells", 0));
    const bool emit_csr = bool(knobs.get("emit_csr", true));
    if (map_w <= 0 || map_h <= 0 || n_cells <= 0) return fail("invalid map dims / n_cells");

    const double origin_x = double(knobs.get("origin_x", 0.0));
    const double origin_y = double(knobs.get("origin_y", 0.0));
    const double size_x = double(knobs.get("size_x", 0.0));
    const double size_y = double(knobs.get("size_y", 0.0));
    const double hex_size = double(knobs.get("hex_size", 1.0));
    const double wrap_period_x = double(knobs.get("wrap_period_x", 0.0));
    const int seed = int(knobs.get("seed", 0));
    // [P1 hypsometric Layer A 2026-06-25] sea_level 供锚定陆地段残差重映射（caller 传 world.sea_level）。
    const double sea_level = double(knobs.get("sea_level", 0.64));

    // ── cell SoA（by cell.index）+ offset→index 映射 ──
    PackedFloat32Array elev_in = knobs.get("cell_elevation", PackedFloat32Array());
    PackedFloat32Array moist_in = knobs.get("cell_moisture", PackedFloat32Array());
    PackedByteArray terr_in = knobs.get("cell_terrain", PackedByteArray());
    PackedByteArray veg_in = knobs.get("cell_vegetation", PackedByteArray());
    PackedByteArray cov_in = knobs.get("cell_cover", PackedByteArray());
    PackedInt32Array o2i_in = knobs.get("offset_to_index", PackedInt32Array());
    if (elev_in.size() < n_cells || moist_in.size() < n_cells ||
        terr_in.size() < n_cells || veg_in.size() < n_cells || cov_in.size() < n_cells) {
        return fail("cell SoA size < n_cells");
    }
    if (o2i_in.size() < map_w * map_h) return fail("offset_to_index too small");

    const float * const __restrict E = elev_in.ptr();
    const float * const __restrict M = moist_in.ptr();
    const uint8_t * const __restrict T = terr_in.ptr();
    const uint8_t * const __restrict VG = veg_in.ptr();
    const uint8_t * const __restrict CV = cov_in.ptr();
    const int32_t * const __restrict O2I = o2i_in.ptr();

    // ── 与 map_baker.gd 常量逐一对齐 ──
    constexpr double WARP_AMP = 0.4;
    constexpr double WARP_FREQ = 0.024;
    constexpr double WARP_HIGH_FREQ_MUL = 3.4;
    constexpr double WARP_HIGH_AMP_RATIO = 0.55;
    constexpr double DETAIL_FREQ_BASE = 0.8;
    // [P0 地形 relief 重做 2026-06-25] 各向异性脊线 + 连续振幅(relief 门控) + 山脊/谷不对称 +
    //   气候耦合，取代旧的"按 terrain 硬分档各向同性 ridged 噪声"（MOUNTAIN/HILL/PLAIN_AMP 已废弃）。
    constexpr double RELIEF_AMP      = 0.26;   // 主起伏振幅（量级对齐旧 MOUNTAIN_RIDGE_AMP，与下游 erosion 同档）
    constexpr double RELIEF_LO       = 0.020;  // relief 门控下限：below→趋平（平原视觉真平）
    constexpr double RELIEF_HI       = 0.150;  // relief 门控上限：above→满振幅
    constexpr double RIDGE_SMEAR_HEX = 0.65;   // 沿脊线 3-tap smear 步长（hex 单位）
    constexpr double K_CREST         = 1.7;    // 山脊尖化指数（>1：尖脊 + 缓谷）
    constexpr double VALLEY_BIAS     = 0.35;   // 谷底负偏置（河道落低处，与河流 SDF 自洽）
    constexpr double CRAG_AMP        = 0.05;   // 高频岩屑振幅
    constexpr double CRAG_FREQ_MUL   = 1.05;   // 岩屑频率乘子
    // TerrainType.TERRAIN 枚举（与 terrain_type.gd 顺序严格一致）
    constexpr int TT_OCEAN = 0, TT_COAST = 1;

    // ── FastNoiseLite：与 map_baker.gd::_init_noise 逐位同源 ──
    Ref<FastNoiseLite> warp_lo;  warp_lo.instantiate();
    warp_lo->set_noise_type(FastNoiseLite::TYPE_SIMPLEX_SMOOTH);
    warp_lo->set_seed(seed + 71);
    warp_lo->set_frequency(WARP_FREQ);
    warp_lo->set_fractal_type(FastNoiseLite::FRACTAL_FBM);
    warp_lo->set_fractal_octaves(3);

    Ref<FastNoiseLite> warp_hi;  warp_hi.instantiate();
    warp_hi->set_noise_type(FastNoiseLite::TYPE_SIMPLEX);
    warp_hi->set_seed(seed + 233);
    warp_hi->set_frequency(WARP_FREQ * WARP_HIGH_FREQ_MUL);
    warp_hi->set_fractal_type(FastNoiseLite::FRACTAL_FBM);
    warp_hi->set_fractal_octaves(3);

    Ref<FastNoiseLite> detail;  detail.instantiate();
    detail->set_noise_type(FastNoiseLite::TYPE_SIMPLEX_SMOOTH);
    detail->set_seed(seed + 503);
    detail->set_frequency(DETAIL_FREQ_BASE);
    detail->set_fractal_type(FastNoiseLite::FRACTAL_FBM);
    detail->set_fractal_octaves(4);

    Ref<FastNoiseLite> ridge;  ridge.instantiate();
    ridge->set_noise_type(FastNoiseLite::TYPE_SIMPLEX);
    ridge->set_seed(seed + 977);
    ridge->set_frequency(DETAIL_FREQ_BASE * 1.15);
    ridge->set_fractal_type(FastNoiseLite::FRACTAL_RIDGED);
    ridge->set_fractal_octaves(3);

    FastNoiseLite *NW_LO = warp_lo.ptr();
    FastNoiseLite *NW_HI = warp_hi.ptr();
    FastNoiseLite *ND = detail.ptr();
    FastNoiseLite *NR = ridge.ptr();

    // ── 数学原语（逐一对齐 map_baker.gd / hex_utils.gd）──
    auto fposmodd = [](double a, double b) -> double {
        double m = std::fmod(a, b);
        if (m < 0.0) m += b;
        return m;
    };
    auto smooth01 = [](double e0, double e1, double x) -> double {
        if (e1 <= e0) return x < e0 ? 0.0 : 1.0;
        double t = (x - e0) / (e1 - e0);
        t = t < 0.0 ? 0.0 : (t > 1.0 ? 1.0 : t);
        return t * t * (3.0 - 2.0 * t);
    };
    // _cyl_noise：2D 接缝包裹（fposmod + band smoothstep lerp 到 seam 均值）。
    // phase_origin_x 必须跟调用点的 x 偏移/缩放同相位，否则 x+91.1 这类采样会把
    // 人造 fposmod seam 移进地图内部。
    auto cyl = [&](FastNoiseLite *nz, double x, double y,
                   double period_scale = 1.0, double phase_origin_x = 0.0) -> double {
        const double period = wrap_period_x * std::max(period_scale, 0.0001);
        if (period <= 0.0001) return double(nz->get_noise_2d(x, y));
        const double phase = fposmodd(x - phase_origin_x, period);
        double xw = phase_origin_x + phase;
        double base = double(nz->get_noise_2d(xw, y));
        double band = std::min(std::max(hex_size * 8.0 * std::max(period_scale, 0.0001), 1.0), period * 0.12);
        if (band <= 0.0001) return base;
        double left = double(nz->get_noise_2d(phase_origin_x, y));
        double right = double(nz->get_noise_2d(phase_origin_x + period, y));
        double seam_avg = (left + right) * 0.5;
        if (phase < band) {
            double tl = smooth01(0.0, band, phase);
            return seam_avg + (base - seam_avg) * tl;
        }
        if (phase > period - band) {
            double tr = smooth01(0.0, band, period - phase);
            return seam_avg + (base - seam_avg) * tr;
        }
        return base;
    };
    const double SQRT3 = std::sqrt(3.0);
    // cube_to_world(q, r, size)
    auto cube_to_world_x = [&](int q, int r) -> double { return hex_size * SQRT3 * (double(q) + double(r) / 2.0); };
    auto cube_to_world_y = [&](int r) -> double { return hex_size * 1.5 * double(r); };
    // cube → cell.index（含东西经度环绕；南北硬边界返回 -1）
    auto cell_at_cube = [&](int q, int r) -> int {
        if (r < 0 || r >= map_h) return -1;
        int col = q + ((r - (r & 1)) / 2);          // cube_to_offset.col
        col = ((col % map_w) + map_w) % map_w;       // posmod wrap
        return O2I[r * map_w + col];
    };
    // _neighbor_dir：atan2 sextant 编号 → cube 方向（0=E,1=SE,2=SW,3=W,4=NW,5=NE）
    static const int NDQ[6] = { 1, 0, -1, -1, 0, 1 };
    static const int NDR[6] = { 0, 1, 1, 0, -1, -1 };

    // ── 输出 buffer ──
    PackedFloat32Array height_buf;  height_buf.resize(n_pix);
    PackedByteArray biome_buf;      biome_buf.resize(n_pix);
    PackedFloat32Array moist_buf;   moist_buf.resize(n_pix);
    PackedByteArray veg_buf;        veg_buf.resize(n_pix);
    PackedByteArray cover_buf;      cover_buf.resize(n_pix);
    PackedInt32Array p2c;           p2c.resize(n_pix);
    PackedByteArray edge_secondary_buf; edge_secondary_buf.resize(n_pix * 2);
    PackedByteArray edge_distance_buf;  edge_distance_buf.resize(n_pix);
    float * const __restrict HBUF = height_buf.ptrw();
    uint8_t * const __restrict BBUF = biome_buf.ptrw();
    float * const __restrict MBUF = moist_buf.ptrw();
    uint8_t * const __restrict VBUF = veg_buf.ptrw();
    uint8_t * const __restrict CBUF = cover_buf.ptrw();
    int32_t * const __restrict P2C = p2c.ptrw();
    uint8_t * const __restrict ESEC = edge_secondary_buf.ptrw();
    uint8_t * const __restrict EDIST = edge_distance_buf.ptrw();

    // CSR 计数（by cell.index）
    PackedInt32Array first_px;  first_px.resize(n_cells);
    PackedInt32Array px_count;  px_count.resize(n_cells);
    int32_t * const __restrict FIRST = first_px.ptrw();
    int32_t * const __restrict CNT = px_count.ptrw();
    for (int c = 0; c < n_cells; ++c) { FIRST[c] = -1; CNT[c] = 0; }

    const double step_x = size_x / double(W);
    const double step_y = size_y / double(H);
    const double warp_scale = hex_size * WARP_AMP;
    const double PI = 3.14159265358979323846;
    // 视觉 ecotone 需要覆盖足够的 cell 内侧范围。中心距差约为实际垂直边界
    // 距离的两倍，因此 0.90 gap 对应单侧约 0.45 hex；shader 再按质量缩放。
    // 边界场本身对所有合法邻格通用；是否允许跨水陆混合由各视觉消费者决定。
    auto t0 = std::chrono::high_resolution_clock::now();

    // ── [P0] per-cell 高程梯度 + 局地起伏预计算（六邻居有限差分；O(n_cells)）──
    //    grad 方向供各向异性脊线（沿等高线方向拉长山脊）；relief（邻格最大高差）供连续
    //    振幅门控（平原→趋零、山地→满振幅），均不依赖 hex_size 量纲、不绑 terrain 类别。
    std::vector<float> CGX(size_t(n_cells), 0.0f), CGY(size_t(n_cells), 0.0f), CREL(size_t(n_cells), 0.0f);
    for (int r = 0; r < map_h; ++r) {
        const int qbase = -((r - (r & 1)) / 2);          // offset.col → cube.q（cell_at_cube 互逆）
        for (int col = 0; col < map_w; ++col) {
            const int self_c = O2I[r * map_w + col];
            if (self_c < 0 || self_c >= n_cells) continue;
            const int q = col + qbase;
            const double e0 = double(E[self_c]);
            const double sx0 = cube_to_world_x(q, r);
            const double sy0 = cube_to_world_y(r);
            double Sxx = 0.0, Sxy = 0.0, Syy = 0.0, Sxz = 0.0, Syz = 0.0;
            double relief = 0.0;
            for (int d = 0; d < 6; ++d) {
                const int nq = q + NDQ[d], nr = r + NDR[d];
                const int nb = cell_at_cube(nq, nr);     // 含经度环绕；南北极返回 -1
                if (nb < 0) continue;
                const double dz = double(E[nb]) - e0;
                // 用 unwrapped cube 世界坐标算局部偏移（接缝处仍连续，梯度方向正确）
                const double dx = cube_to_world_x(nq, nr) - sx0;
                const double dy = cube_to_world_y(nr) - sy0;
                Sxx += dx * dx; Sxy += dx * dy; Syy += dy * dy;
                Sxz += dx * dz; Syz += dy * dz;
                const double adz = dz < 0.0 ? -dz : dz;
                if (adz > relief) relief = adz;
            }
            const double det = Sxx * Syy - Sxy * Sxy;    // 2×2 最小二乘解世界空间梯度
            if (det > 1e-12 || det < -1e-12) {
                const double inv = 1.0 / det;
                CGX[size_t(self_c)] = float((Syy * Sxz - Sxy * Syz) * inv);
                CGY[size_t(self_c)] = float((Sxx * Syz - Sxy * Sxz) * inv);
            }
            CREL[size_t(self_c)] = float(relief);
        }
    }

    // [P1 hypsometric Layer A 2026-06-25] bake 期 per-pixel 残差塑形：cell E 已被 Layer B(仿真高程)
    // 重塑，经 barycentric 插值后台地边缘被线性抹软；此处对 elev_blend 以小 mix(PK_HYPSO_LAYER_A_MIX)
    // 重新施加同曲线，在像素分辨率下重锐化台地/陡坡。仅陆地段、锚定 sea_level，避免与 B 双重压缩过度。
    const PkHypsoCurve hypso = pk_make_hypso_curve();
    const double hy_above = 1.0 - sea_level;
    const double hy_inv_above = (hy_above > 1e-6) ? (1.0 / hy_above) : 0.0;

    for (int y = 0; y < H; ++y) {
        const double wy_base = origin_y + (double(y) + 0.5) * step_y;
        const int row = y * W;
        for (int x = 0; x < W; ++x) {
            const double wx_base = origin_x + (double(x) + 0.5) * step_x;

            // 1. warp（双频）
            const double warp_x = cyl(NW_LO, wx_base, wy_base);
            const double warp_y = cyl(NW_LO, wx_base + 31.7, wy_base - 17.3, 1.0, 31.7);
            const double hi_x = cyl(NW_HI, wx_base + 91.1, wy_base + 53.7, 1.0, 91.1) * WARP_HIGH_AMP_RATIO;
            const double hi_y = cyl(NW_HI, wx_base - 41.5, wy_base + 23.9, 1.0, -41.5) * WARP_HIGH_AMP_RATIO;
            const double wx = wx_base + (warp_x + hi_x) * warp_scale;
            const double wy = wy_base + (warp_y + hi_y) * warp_scale;

            // 2. cube 归属（world_to_cube_f + cube_round）
            const double qf = (SQRT3 / 3.0 * wx - (1.0 / 3.0) * wy) / hex_size;
            const double rf = (2.0 / 3.0 * wy) / hex_size;
            const double sf = -qf - rf;
            double rq = std::round(qf), rr = std::round(rf), rs = std::round(sf);
            const double dq = std::fabs(rq - qf), dr = std::fabs(rr - rf), ds = std::fabs(rs - sf);
            if (dq > dr && dq > ds) rq = -rr - rs;
            else if (dr > ds) rr = -rq - rs;
            else rs = -rq - rr;
            const int cq = int(rq), cr = int(rr);
            const int self_idx = cell_at_cube(cq, cr);

            // 3. sextant 邻居
            const double scx = cube_to_world_x(cq, cr);
            const double scy = cube_to_world_y(cr);
            const double lx = (wx - scx) / hex_size;
            const double ly = (wy - scy) / hex_size;
            const double angle = std::atan2(ly, lx);
            const int sextant = int(std::floor(fposmodd((angle + PI / 6.0) / (PI / 3.0), 6.0)));
            const int s0 = sextant % 6;
            const int s1 = (sextant + 1) % 6;
            const int nb1_q = cq + NDQ[s0], nb1_r = cr + NDR[s0];
            const int nb2_q = cq + NDQ[s1], nb2_r = cr + NDR[s1];
            const int nb1_idx = cell_at_cube(nb1_q, nb1_r);
            const int nb2_idx = cell_at_cube(nb2_q, nb2_r);

            // 4. barycentric（self + 2 邻居中心）
            const double ax = scx, ay = scy;
            const double bx = cube_to_world_x(nb1_q, nb1_r), b_y = cube_to_world_y(nb1_r);
            const double ccx = cube_to_world_x(nb2_q, nb2_r), ccy = cube_to_world_y(nb2_r);
            double w_self = 1.0, w_nb1 = 0.0, w_nb2 = 0.0;
            {
                const double v0x = bx - ax, v0y = b_y - ay;
                const double v1x = ccx - ax, v1y = ccy - ay;
                const double v2x = wx - ax, v2y = wy - ay;
                const double d00 = v0x * v0x + v0y * v0y;
                const double d01 = v0x * v1x + v0y * v1y;
                const double d11 = v1x * v1x + v1y * v1y;
                const double d20 = v2x * v0x + v2y * v0y;
                const double d21 = v2x * v1x + v2y * v1y;
                const double denom = d00 * d11 - d01 * d01;
                if (std::fabs(denom) >= 0.000001) {
                    const double inv = 1.0 / denom;
                    double vb = (d11 * d20 - d01 * d21) * inv;
                    double vc = (d00 * d21 - d01 * d20) * inv;
                    double va = 1.0 - vb - vc;
                    va = va < 0.0 ? 0.0 : va;
                    vb = vb < 0.0 ? 0.0 : vb;
                    vc = vc < 0.0 ? 0.0 : vc;
                    const double sum = va + vb + vc;
                    if (sum >= 0.0001) { w_self = va / sum; w_nb1 = vb / sum; w_nb2 = vc / sum; }
                }
            }

            // 5. 取值
            const double elev_self = self_idx >= 0 ? double(E[self_idx]) : 0.0;
            const double elev_nb1 = nb1_idx >= 0 ? double(E[nb1_idx]) : elev_self;
            const double elev_nb2 = nb2_idx >= 0 ? double(E[nb2_idx]) : elev_self;
            const double moist_self = self_idx >= 0 ? double(M[self_idx]) : 0.5;
            const double moist_nb1 = nb1_idx >= 0 ? double(M[nb1_idx]) : moist_self;
            const double moist_nb2 = nb2_idx >= 0 ? double(M[nb2_idx]) : moist_self;
            const int terrain_self = self_idx >= 0 ? int(T[self_idx]) : TT_OCEAN;
            const int veg_self = self_idx >= 0 ? int(VG[self_idx]) : 0;
            const int cover_self = self_idx >= 0 ? int(CV[self_idx]) : 0;

            // 6. barycentric 插值
            double elev_blend = elev_self * w_self + elev_nb1 * w_nb1 + elev_nb2 * w_nb2;
            const double moist_blend = moist_self * w_self + moist_nb1 * w_nb1 + moist_nb2 * w_nb2;

            // 6.5 [P1 hypsometric Layer A] 锚定 sea_level 的小 mix 残差重映射（重锐化台地边缘，
            //     不重复整条 Layer B 曲线）；水下/无陆地段时透传。relief 随后叠在重塑基底上。
            if (hy_inv_above > 0.0 && elev_blend > sea_level) {
                elev_blend = pk_hypso_remap_elev(hypso, elev_blend, sea_level,
                                                 hy_inv_above, hy_above, PK_HYPSO_LAYER_A_MIX);
            }

            // 6.6 [coast-beach 2026-06-25] 近岸海滩坡（治"海岸无法线"）：P1 后内陆平原也贴 sea_level，
            //     elev 无法区分海岸/内陆，故改用 barycentric 水邻居权重(亚格距水近度)——只有真正与水
            //     cell 相邻的陆地像素才下压成海滩坡（写进 height → terrain_normal_tex 拿到 crisp 海岸
            //     法线，与河岸 #2a 同法）。仅陆地 self、止于水线不越过；与 GDScript 镜像同公式。
            if (terrain_self != TT_OCEAN && terrain_self != TT_COAST && elev_blend > sea_level) {
                constexpr double PK_COAST_BEACH = 0.05;  // 海滩坡最大下压(height 单位，× smoothstep)
                double water_w = 0.0;
                if (nb1_idx >= 0 && pk_is_water_terrain(uint8_t(T[nb1_idx]))) water_w += w_nb1;
                if (nb2_idx >= 0 && pk_is_water_terrain(uint8_t(T[nb2_idx]))) water_w += w_nb2;
                if (water_w > 0.0) {
                    const double beach = water_w * water_w * (3.0 - 2.0 * water_w);  // smoothstep 锐化
                    double e = elev_blend - PK_COAST_BEACH * beach;
                    if (e < sea_level) e = sea_level;   // 海滩止于水线
                    elev_blend = e;
                }
            }


            // 7. [P0] per-pixel relief：各向异性脊线（沿等高线拉长）+ 连续振幅(relief 门控)
            //    + 山脊/谷不对称（尖脊缓谷）+ 气候耦合（干→岩屑、湿→圆滑）；不绑 terrain 类别。
            double elev_final = elev_blend;
            if (terrain_self != TT_OCEAN && terrain_self != TT_COAST) {
                // 插值 per-cell 梯度方向 + 局地起伏（复用 self/nb1/nb2 barycentric 权重）
                double gx = CGX[size_t(self_idx)] * w_self;
                double gy = CGY[size_t(self_idx)] * w_self;
                double relief_p = CREL[size_t(self_idx)] * w_self;
                if (nb1_idx >= 0) { gx += CGX[size_t(nb1_idx)] * w_nb1; gy += CGY[size_t(nb1_idx)] * w_nb1; relief_p += CREL[size_t(nb1_idx)] * w_nb1; }
                if (nb2_idx >= 0) { gx += CGX[size_t(nb2_idx)] * w_nb2; gy += CGY[size_t(nb2_idx)] * w_nb2; relief_p += CREL[size_t(nb2_idx)] * w_nb2; }

                // 连续振幅门控：relief 低→趋平（真平原），高→满振幅（无 terrain 硬分档）
                const double gate = smooth01(RELIEF_LO, RELIEF_HI, relief_p);
                // 脊线方向 = 梯度的垂直方向（沿等高线）
                const double glen = std::sqrt(gx * gx + gy * gy);
                double tx = 1.0, ty = 0.0;
                if (glen > 1e-9) { tx = -gy / glen; ty = gx / glen; }
                // 沿脊线 3-tap smear（每 tap 经 cyl()，圆柱接缝安全）→ 沿等高线方向拉长山脊
                const double L = hex_size * RIDGE_SMEAR_HEX;
                const double r0 = cyl(NR, wx_base, wy_base);
                const double rA = cyl(NR, wx_base + tx * L, wy_base + ty * L, 1.0, tx * L);
                const double rB = cyl(NR, wx_base - tx * L, wy_base - ty * L, 1.0, -tx * L);
                const double smeared = (r0 * 2.0 + rA + rB) * 0.25;
                const double R = r0 + (smeared - r0) * gate;   // 低起伏→各向同性，高起伏→沿脊
                double ridge01 = (R + 1.0) * 0.5;
                ridge01 = ridge01 < 0.0 ? 0.0 : (ridge01 > 1.0 ? 1.0 : ridge01);
                const double shaped = std::pow(ridge01, K_CREST);   // 尖脊 + 缓谷
                const double amp = RELIEF_AMP * gate;
                // 气候耦合：干燥→更多高频岩屑、湿润→圆滑；仅在有起伏处出现（× gate）
                const double dryness = 1.0 - moist_blend;
                const double crag = cyl(ND, wx_base * CRAG_FREQ_MUL + 17.9,
                                        wy_base * CRAG_FREQ_MUL - 11.3,
                                        CRAG_FREQ_MUL, 17.9) * 0.5;
                elev_final = elev_blend
                        + (shaped - VALLEY_BIAS) * amp
                        + crag * CRAG_AMP * (0.4 + 0.6 * dryness) * gate;
            }

            // 8. 权威硬主索引 + 通用视觉边界辅助数据。为所有合法邻格输出副索引
            //    和距离，让 terrain/fog/weather 各自决定能否以及如何形成 ecotone；
            //    动态状态、CSR 与交互仍不被视觉过渡改派。
            int edge_secondary = -1;
            double edge_gap_hex = VISUAL_EDGE_DISTANCE_SATURATE_HEX;
            if (self_idx >= 0) {
                const double self_dx = wx - scx;
                const double self_dy = wy - scy;
                const double self_distance = std::sqrt(self_dx * self_dx + self_dy * self_dy);
                auto consider_edge_neighbor = [&](int candidate_idx, double cx, double cy) {
                    if (candidate_idx < 0 || candidate_idx >= n_cells) return;
                    const double dx = wx - cx;
                    const double dy = wy - cy;
                    const double candidate_distance = std::sqrt(dx * dx + dy * dy);
                    const double gap = std::max(0.0,
                            (candidate_distance - self_distance) / std::max(hex_size, 0.0001));
                    if (edge_secondary < 0 || gap < edge_gap_hex - 1e-12 ||
                            (std::fabs(gap - edge_gap_hex) <= 1e-12 &&
                             candidate_idx < edge_secondary)) {
                        edge_secondary = candidate_idx;
                        edge_gap_hex = gap;
                    }
                };
                consider_edge_neighbor(nb1_idx, bx, b_y);
                consider_edge_neighbor(nb2_idx, ccx, ccy);
            }

            const int idx = row + x;
            double hf = elev_final; hf = hf < 0.0 ? 0.0 : (hf > 1.0 ? 1.0 : hf);
            double mf = moist_blend; mf = mf < 0.0 ? 0.0 : (mf > 1.0 ? 1.0 : mf);
            HBUF[idx] = float(hf);
            BBUF[idx] = uint8_t(terrain_self & 0xFF);
            MBUF[idx] = float(mf);
            VBUF[idx] = uint8_t(veg_self & 0xFF);
            CBUF[idx] = uint8_t(cover_self & 0xFF);
            P2C[idx] = self_idx;
            if (emit_csr && self_idx >= 0 && self_idx < n_cells) CNT[self_idx] += 1;
            if (edge_secondary >= 0 && edge_secondary < 0xFFFF) {
                ESEC[idx * 2] = uint8_t(edge_secondary & 0xFF);
                ESEC[idx * 2 + 1] = uint8_t((edge_secondary >> 8) & 0xFF);
                const double edge_n = std::min(1.0,
                        edge_gap_hex / VISUAL_EDGE_DISTANCE_SATURATE_HEX);
                EDIST[idx] = uint8_t(std::round(edge_n * 255.0));
            } else {
                ESEC[idx * 2] = 0xFF;
                ESEC[idx * 2 + 1] = 0xFF;
                EDIST[idx] = 0xFF;
            }
        }
    }

    // ── CSR build：prefix-sum first_px + scatter flat（counting sort，by cell.index）──
    int total_px = 0;
    PackedInt32Array flat_px;
    int32_t *FLAT = nullptr;
    if (emit_csr) {
        for (int c = 0; c < n_cells; ++c) {
            if (CNT[c] > 0) { FIRST[c] = total_px; total_px += CNT[c]; }
            else { FIRST[c] = -1; }
        }
        flat_px.resize(total_px);
        FLAT = flat_px.ptrw();
    }
    // 写游标：复用临时数组（各 cell 段起点）
    if (emit_csr) {
        std::vector<int> cursor(n_cells);
        for (int c = 0; c < n_cells; ++c) cursor[c] = FIRST[c];
        for (int i = 0; i < n_pix; ++i) {
            const int c = P2C[i];
            if (c >= 0 && c < n_cells && cursor[c] >= 0) {
                FLAT[cursor[c]] = i;
                cursor[c] += 1;
            }
        }
    }

    auto t1 = std::chrono::high_resolution_clock::now();

    out["fallback"] = false;
    out["reason"] = String();
    out["path"] = String("gdext");
    out["elapsed_ms"] = std::chrono::duration<double, std::milli>(t1 - t0).count();
    out["width"] = W;
    out["height"] = H;
    out["height_buffer"] = height_buf;
    out["biome_buffer"] = biome_buf;
    out["moisture_buffer"] = moist_buf;
    out["vegetation_buffer"] = veg_buf;
    out["cover_buffer"] = cover_buf;
    out["pixel_to_cell_index"] = p2c;
    out["edge_secondary_index_buffer"] = edge_secondary_buf;
    out["edge_distance_buffer"] = edge_distance_buf;
    out["edge_distance_units"] = String("normalized_hex_center_gap");
    out["edge_distance_saturate_hex"] = VISUAL_EDGE_DISTANCE_SATURATE_HEX;
    out["cell_first_px"] = first_px;
    out["cell_px_count"] = px_count;
    out["flat_px_indices"] = flat_px;
    out["total_px"] = total_px;
    out["csr_emitted"] = emit_csr;
    return out;
}

godot::Dictionary DCWorldExt::run_bake_visual_tile_layer_pass(godot::Dictionary knobs) {
    using godot::Dictionary;
    using godot::PackedByteArray;
    using godot::PackedFloat32Array;
    using godot::PackedInt32Array;
    using godot::String;

    Dictionary out;
    out["fallback"] = true;
    out["reason"] = String();
    out["path"] = String("gdext_visual_tile");
    out["elapsed_ms"] = -1.0;
    auto fail = [&](const char *why) -> Dictionary {
        out["reason"] = String(why);
        return out;
    };

    const int W = int(knobs.get("width", 0));
    const int H = int(knobs.get("height", 0));
    const int N = W * H;
    if (W <= 0 || H <= 0 || N <= 0) return fail("invalid tile size");
    const double origin_x = double(knobs.get("origin_x", 0.0));
    const double origin_y = double(knobs.get("origin_y", 0.0));
    const double size_x = double(knobs.get("size_x", 0.0));
    const double size_y = double(knobs.get("size_y", 0.0));
    if (size_x <= 0.0 || size_y <= 0.0) return fail("invalid tile world rect");

    const int BW = int(knobs.get("baseline_width", 0));
    const int BH = int(knobs.get("baseline_height", 0));
    const int BN = BW * BH;
    PackedFloat32Array baseline_height = knobs.get("baseline_height_buffer", PackedFloat32Array());
    PackedFloat32Array baseline_flow = knobs.get("baseline_flow_buffer", PackedFloat32Array());
    PackedByteArray baseline_water = knobs.get("baseline_water_depth_buffer", PackedByteArray());
    if (BW <= 0 || BH <= 0 || BN <= 0 || baseline_height.size() < BN) {
        return fail("invalid baseline height");
    }
    const double base_origin_x = double(knobs.get("baseline_origin_x", 0.0));
    const double base_origin_y = double(knobs.get("baseline_origin_y", 0.0));
    const double base_size_x = double(knobs.get("baseline_size_x", 0.0));
    const double base_size_y = double(knobs.get("baseline_size_y", 0.0));
    if (base_size_x <= 0.0 || base_size_y <= 0.0) return fail("invalid baseline world rect");

    const double step_x = size_x / double(W);
    const double step_y = size_y / double(H);
    const double normal_reference_step_x = base_size_x / double(BW);
    const double normal_reference_step_y = base_size_y / double(BH);
    const double raster_scale_x = normal_reference_step_x / step_x;
    const double raster_scale_y = normal_reference_step_y / step_y;
    const double distance_scale = std::sqrt(std::max(1e-8, raster_scale_x * raster_scale_y));
    const double river_sdf_max_dist_px = std::max(1.0, std::min(60.0,
            double(knobs.get("sdf_max_dist_px", 5.0)) * distance_scale));
    const double coast_sdf_max_dist_px = std::max(1.0, std::min(60.0,
            double(knobs.get("coast_sdf_max_dist_px", 8.0)) * distance_scale));
    const int shore_carve_band_px = std::max(1, std::min(60, int(std::round(
            double(knobs.get("shore_carve_band", 6)) * distance_scale))));
    const int normal_reference_radius = std::max(1, std::min(64,
            int(knobs.get("normal_reference_radius_px",
                    knobs.get("normal_radius_px", 4)))));
    const int normal_radius_x = std::max(1, std::min(64, int(std::round(
            double(normal_reference_radius) * normal_reference_step_x / step_x))));
    const int normal_radius_y = std::max(1, std::min(64, int(std::round(
            double(normal_reference_radius) * normal_reference_step_y / step_y))));
    const int required_halo = std::max({normal_radius_x, normal_radius_y,
            int(std::ceil(river_sdf_max_dist_px)) + 2,
            int(std::ceil(coast_sdf_max_dist_px)) + 2,
            shore_carve_band_px + 2});
    const int halo = std::max(required_halo,
            std::max(2, std::min(64, int(knobs.get("algorithm_halo_px", 8)))));
    const int WW = W + halo * 2;
    const int WH = H + halo * 2;
    const int WN = WW * WH;
    const double work_origin_x = origin_x - double(halo) * step_x;
    const double work_origin_y = origin_y - double(halo) * step_y;
    const double wrap_period_x = double(knobs.get("wrap_period_x", 0.0));
    const double sea_level = double(knobs.get("sea_level", 0.64));
    // [normal-soften 2026-07-31] 默认 0.035→0.01：过高的 residual 会进 height/法线，
    // 运行期再做 1-texel 差分后读成全图砂砾。knobs 未传时与 project.godot 新默认对齐。
    const double residual_amp = std::max(0.0, std::min(0.08,
            double(knobs.get("residual_amp", 0.01))));
    const double hex_size = std::max(0.0001, double(knobs.get("hex_size", 1.0)));
    // High-frequency residual must be a function of world space, not of the chosen
    // Tile density. Sampling its zero-mean filter one texel away made lower-density
    // layouts produce a visibly rougher height field and macro normal.
    const double residual_filter_radius = hex_size * std::max(0.005, std::min(0.25,
            double(knobs.get("residual_filter_hex", 0.06))));

    Dictionary work_knobs = knobs.duplicate(true);
    work_knobs["width"] = WW;
    work_knobs["height"] = WH;
    work_knobs["origin_x"] = work_origin_x;
    work_knobs["origin_y"] = work_origin_y;
    work_knobs["size_x"] = step_x * double(WW);
    work_knobs["size_y"] = step_y * double(WH);
    work_knobs["inv_world_x"] = 1.0 / step_x;
    work_knobs["inv_world_y"] = 1.0 / step_y;
    work_knobs["base_radius_px"] = std::max(0.5,
            hex_size * double(knobs.get("river_stroke_hex_factor", 0.035)) / step_x);
    work_knobs["sdf_max_dist_px"] = river_sdf_max_dist_px;
    work_knobs["coast_sdf_max_dist_px"] = coast_sdf_max_dist_px;
    work_knobs["shore_carve_band"] = shore_carve_band_px;
    work_knobs["emit_csr"] = false;

    const auto t0 = std::chrono::high_resolution_clock::now();
    Dictionary terr = run_bake_terrain_index_pass(work_knobs);
    if (bool(terr.get("fallback", true))) return fail("terrain index failed");
    PackedFloat32Array procedural_height = terr.get("height_buffer", PackedFloat32Array());
    PackedByteArray biome_work = terr.get("biome_buffer", PackedByteArray());
    PackedInt32Array p2c_work = terr.get("pixel_to_cell_index", PackedInt32Array());
    PackedByteArray edge_work = terr.get("edge_secondary_index_buffer", PackedByteArray());
    PackedByteArray edge_distance_work = terr.get("edge_distance_buffer", PackedByteArray());
    if (procedural_height.size() != WN || biome_work.size() != WN ||
            p2c_work.size() != WN || edge_work.size() != WN * 2 ||
            edge_distance_work.size() != WN) {
        return fail("terrain payload size mismatch");
    }

    auto wrap_world_x = [&](double x) -> double {
        if (wrap_period_x <= 0.0001) return x;
        double p = std::fmod(x, wrap_period_x);
        if (p < 0.0) p += wrap_period_x;
        return p;
    };
    auto cubic = [](double p0, double p1, double p2, double p3, double t) -> double {
        const double a0 = -0.5 * p0 + 1.5 * p1 - 1.5 * p2 + 0.5 * p3;
        const double a1 = p0 - 2.5 * p1 + 2.0 * p2 - 0.5 * p3;
        const double a2 = -0.5 * p0 + 0.5 * p2;
        return ((a0 * t + a1) * t + a2) * t + p1;
    };
    const float * const BASE_H = baseline_height.ptr();
    auto sample_base_height = [&](double wx, double wy) -> double {
        wx = wrap_world_x(wx);
        double fx = (wx - base_origin_x) / base_size_x * double(BW) - 0.5;
        double fy = (wy - base_origin_y) / base_size_y * double(BH) - 0.5;
        const int ix = int(std::floor(fx));
        const int iy = int(std::floor(fy));
        const double tx = fx - double(ix);
        const double ty = fy - double(iy);
        double rows[4];
        for (int ky = -1; ky <= 2; ++ky) {
            const int sy = std::max(0, std::min(BH - 1, iy + ky));
            double v[4];
            for (int kx = -1; kx <= 2; ++kx) {
                const int sx = std::max(0, std::min(BW - 1, ix + kx));
                v[kx + 1] = double(BASE_H[sy * BW + sx]);
            }
            rows[ky + 1] = cubic(v[0], v[1], v[2], v[3], tx);
        }
        return std::max(0.0, std::min(1.0,
                cubic(rows[0], rows[1], rows[2], rows[3], ty)));
    };
    auto sample_base_scalar = [&](const float *src, double wx, double wy) -> double {
        wx = wrap_world_x(wx);
        double fx = (wx - base_origin_x) / base_size_x * double(BW) - 0.5;
        double fy = (wy - base_origin_y) / base_size_y * double(BH) - 0.5;
        int x0 = int(std::floor(fx)), y0 = int(std::floor(fy));
        const double tx = fx - double(x0), ty = fy - double(y0);
        x0 = std::max(0, std::min(BW - 1, x0));
        y0 = std::max(0, std::min(BH - 1, y0));
        const int x1 = std::min(BW - 1, x0 + 1), y1 = std::min(BH - 1, y0 + 1);
        const double a = double(src[y0 * BW + x0]) * (1.0 - tx) + double(src[y0 * BW + x1]) * tx;
        const double b = double(src[y1 * BW + x0]) * (1.0 - tx) + double(src[y1 * BW + x1]) * tx;
        return a * (1.0 - ty) + b * ty;
    };
    auto sample_base_byte = [&](const uint8_t *src, double wx, double wy) -> double {
        wx = wrap_world_x(wx);
        int sx = int(std::floor((wx - base_origin_x) / base_size_x * double(BW)));
        int sy = int(std::floor((wy - base_origin_y) / base_size_y * double(BH)));
        sx = std::max(0, std::min(BW - 1, sx));
        sy = std::max(0, std::min(BH - 1, sy));
        return double(src[sy * BW + sx]) / 255.0;
    };

    godot::Ref<godot::FastNoiseLite> residual_noise;
    residual_noise.instantiate();
    residual_noise->set_noise_type(godot::FastNoiseLite::TYPE_SIMPLEX_SMOOTH);
    residual_noise->set_seed(int(knobs.get("seed", 0)) + 1597);
    residual_noise->set_frequency(float(0.42 / hex_size));
    residual_noise->set_fractal_type(godot::FastNoiseLite::FRACTAL_FBM);
    residual_noise->set_fractal_octaves(3);
    auto periodic_noise = [&](double wx, double wy) -> double {
        if (wrap_period_x <= 0.0001) return double(residual_noise->get_noise_2d(wx, wy));
        const double phase = wrap_world_x(wx) / wrap_period_x * (2.0 * M_PI);
        const double radius = wrap_period_x / (2.0 * M_PI);
        return double(residual_noise->get_noise_3d(
                std::cos(phase) * radius, std::sin(phase) * radius, wy));
    };

    PackedFloat32Array height_work;
    height_work.resize(WN);
    float * const HW = height_work.ptrw();
    const float * const PH = procedural_height.ptr();
    const uint8_t * const BIOME_W = biome_work.ptr();
    for (int y = 0; y < WH; ++y) {
        const double wy = work_origin_y + (double(y) + 0.5) * step_y;
        for (int x = 0; x < WW; ++x) {
            const int i = y * WW + x;
            const double wx = work_origin_x + (double(x) + 0.5) * step_x;
            const double base = sample_base_height(wx, wy);
            const bool water = pk_is_water_terrain(BIOME_W[i]);
            double residual = 0.0;
            if (!water && residual_amp > 0.0) {
                const double n0 = periodic_noise(wx, wy);
                const double navg = 0.25 * (
                        periodic_noise(wx - residual_filter_radius, wy) +
                        periodic_noise(wx + residual_filter_radius, wy) +
                        periodic_noise(wx, wy - residual_filter_radius) +
                        periodic_noise(wx, wy + residual_filter_radius));
                const double relief_gate = std::max(0.12, std::min(1.0,
                        std::fabs(double(PH[i]) - base) / 0.06));
                residual = std::max(-residual_amp, std::min(residual_amp,
                        (n0 - navg) * residual_amp * 3.0 * relief_gate));
            }
            double h = std::max(0.0, std::min(1.0, base + residual));
            if (water) h = std::min(h, sea_level);
            else h = std::max(h, sea_level);
            HW[i] = float(h);
        }
    }

    Dictionary river = run_bake_river_sdf_pass(work_knobs);
    PackedFloat32Array flow_work = river.get("out_buf", PackedFloat32Array());
    if (bool(river.get("fallback", true)) || flow_work.size() != WN) {
        flow_work.resize(WN);
        float * const FW = flow_work.ptrw();
        const float * const BF = baseline_flow.size() >= BN ? baseline_flow.ptr() : nullptr;
        for (int y = 0; y < WH; ++y) {
            const double wy = work_origin_y + (double(y) + 0.5) * step_y;
            for (int x = 0; x < WW; ++x) {
                const double wx = work_origin_x + (double(x) + 0.5) * step_x;
                FW[y * WW + x] = BF != nullptr ? float(sample_base_scalar(BF, wx, wy)) : 0.0f;
            }
        }
    }
    const float * const FLOW_W = flow_work.ptr();
    for (int i = 0; i < WN; ++i) {
        const double f = std::max(0.0, std::min(1.0, double(FLOW_W[i])));
        if (f <= 0.02 || double(HW[i]) <= sea_level) continue;
        const double notch = f * f * (3.0 - 2.0 * f);
        HW[i] = float(std::max(0.0, double(HW[i]) - 0.045 * notch));
    }

    work_knobs["biome_buffer"] = biome_work;
    Dictionary coast = run_bake_coast_sdf_pass(work_knobs);
    if (!bool(coast.get("fallback", true))) {
        PackedFloat32Array coast_sdf = coast.get("out_buf", PackedFloat32Array());
        if (coast_sdf.size() == WN) {
            const float * const CD = coast_sdf.ptr();
            const double amp = double(knobs.get("shore_carve_amp", 0.06));
            const int band = shore_carve_band_px;
            for (int i = 0; i < WN; ++i) {
                const double d = double(CD[i]);
                if (d <= 0.0 || d > double(band) || double(HW[i]) <= sea_level) continue;
                const double t = 1.0 - d / double(band);
                const double notch = t * t * (3.0 - 2.0 * t);
                HW[i] = float(std::max(sea_level, double(HW[i]) - amp * notch));
            }
        }
    }

    PackedByteArray height_data; height_data.resize(N * 2);
    PackedByteArray normal_data; normal_data.resize(N * 2);
    PackedByteArray map_index_data; map_index_data.resize(N * 4);
    PackedByteArray flow_data; flow_data.resize(N);
    PackedByteArray water_data; water_data.resize(N);
    PackedByteArray detail_data; detail_data.resize(N);
    PackedByteArray edge_data; edge_data.resize(N * 2);
    PackedByteArray edge_distance_data; edge_distance_data.resize(N);
    uint8_t * const HD = height_data.ptrw();
    uint8_t * const ND = normal_data.ptrw();
    uint8_t * const MD = map_index_data.ptrw();
    uint8_t * const FD = flow_data.ptrw();
    uint8_t * const WD = water_data.ptrw();
    uint8_t * const DD = detail_data.ptrw();
    uint8_t * const ED = edge_data.ptrw();
    uint8_t * const EDD = edge_distance_data.ptrw();
    const int32_t * const P2C = p2c_work.ptr();
    const uint8_t * const EW = edge_work.ptr();
    const uint8_t * const EDW = edge_distance_work.ptr();
    PackedByteArray landform = knobs.get("cell_landform", PackedByteArray());
    const uint8_t * const LF = landform.is_empty() ? nullptr : landform.ptr();
    const int n_cells = int(knobs.get("n_cells", 0));
    PackedFloat32Array cell_surface = knobs.get("cell_water_depth", PackedFloat32Array());
    PackedByteArray cell_terrain = knobs.get("cell_terrain", PackedByteArray());
    const float * const CS = cell_surface.size() >= n_cells ? cell_surface.ptr() : nullptr;
    const uint8_t * const CT = cell_terrain.size() >= n_cells ? cell_terrain.ptr() : nullptr;
    const uint8_t * const BWATER = baseline_water.size() >= BN ? baseline_water.ptr() : nullptr;
    const double normal_slope_gain = double(knobs.get("normal_slope_gain", 8.0));
    // 先还原世界空间导数，再校准到一个基线 texel；画质预算变化时保持 legacy 强度与平滑尺度。
    const double normal_gain_x = normal_slope_gain * normal_reference_step_x /
            (double(normal_radius_x * 2) * step_x);
    const double normal_gain_y = normal_slope_gain * normal_reference_step_y /
            (double(normal_radius_y * 2) * step_y);

    godot::Ref<godot::FastNoiseLite> detail_noise;
    detail_noise.instantiate();
    detail_noise->set_noise_type(godot::FastNoiseLite::TYPE_SIMPLEX_SMOOTH);
    detail_noise->set_seed(int(knobs.get("seed", 0)) + 2503);
    detail_noise->set_frequency(float(0.18 / hex_size));
    detail_noise->set_fractal_type(godot::FastNoiseLite::FRACTAL_FBM);
    detail_noise->set_fractal_octaves(4);
    auto detail_periodic = [&](double wx, double wy) -> double {
        if (wrap_period_x <= 0.0001) return double(detail_noise->get_noise_2d(wx, wy));
        const double phase = wrap_world_x(wx) / wrap_period_x * (2.0 * M_PI);
        const double radius = wrap_period_x / (2.0 * M_PI);
        return double(detail_noise->get_noise_3d(
                std::cos(phase) * radius, std::sin(phase) * radius, wy));
    };

    for (int y = 0; y < H; ++y) {
        const int wy_i = y + halo;
        const double wy = origin_y + (double(y) + 0.5) * step_y;
        for (int x = 0; x < W; ++x) {
            const int wx_i = x + halo;
            const int si = wy_i * WW + wx_i;
            const int di = y * W + x;
            const double wx = origin_x + (double(x) + 0.5) * step_x;
            const double h = std::max(0.0, std::min(1.0, double(HW[si])));
            const int h16 = std::max(0, std::min(65535, int(std::round(h * 65535.0))));
            HD[di * 2] = uint8_t((h16 >> 8) & 0xFF);
            HD[di * 2 + 1] = uint8_t(h16 & 0xFF);

            const double sx = (double(HW[wy_i * WW + wx_i + normal_radius_x]) -
                    double(HW[wy_i * WW + wx_i - normal_radius_x])) * normal_gain_x;
            const double sy = (double(HW[(wy_i + normal_radius_y) * WW + wx_i]) -
                    double(HW[(wy_i - normal_radius_y) * WW + wx_i])) * normal_gain_y;
            const double inv_len = 1.0 / std::sqrt(sx * sx + sy * sy + 1.0);
            ND[di * 2] = uint8_t(std::max(0, std::min(255,
                    int(std::round((-sx * inv_len * 0.5 + 0.5) * 255.0)))));
            ND[di * 2 + 1] = uint8_t(std::max(0, std::min(255,
                    int(std::round((-sy * inv_len * 0.5 + 0.5) * 255.0)))));

            const int ci = P2C[si];
            MD[di * 4] = BIOME_W[si];
            MD[di * 4 + 1] = ci >= 0 && ci < 0xFFFF ? uint8_t(ci & 0xFF) : 0xFF;
            MD[di * 4 + 2] = ci >= 0 && ci < 0xFFFF ? uint8_t((ci >> 8) & 0xFF) : 0xFF;
            MD[di * 4 + 3] = (LF != nullptr && ci >= 0 && ci < landform.size()) ? LF[ci] : 0;

            const double f = std::max(0.0, std::min(1.0, double(FLOW_W[si])));
            FD[di] = uint8_t(std::round(f * 255.0));
            double depth = 0.0;
            if (CS != nullptr && ci >= 0 && ci < n_cells && CS[ci] > 1e-4f) {
                const double raw = std::max(0.0, double(CS[ci]) - h);
                const bool lake = CT != nullptr && CT[ci] == 18;
                depth = std::min(1.0, raw / (lake ? 0.16 : std::max(1e-4, sea_level)));
            } else if (BWATER != nullptr) {
                depth = sample_base_byte(BWATER, wx, wy);
            }
            WD[di] = uint8_t(std::round(depth * 255.0));
            const double dn = std::max(-1.0, std::min(1.0, detail_periodic(wx, wy)));
            DD[di] = uint8_t(std::round((dn * 0.5 + 0.5) * 255.0));
            ED[di * 2] = EW[si * 2];
            ED[di * 2 + 1] = EW[si * 2 + 1];
            EDD[di] = EDW[si];
        }
    }

    auto hash_bytes = [](const PackedByteArray &data) -> int64_t {
        uint64_t h = 1469598103934665603ULL;
        const uint8_t *p = data.ptr();
        for (int i = 0; i < data.size(); ++i) {
            h ^= uint64_t(p[i]);
            h *= 1099511628211ULL;
        }
        return int64_t(h);
    };
    Dictionary hashes;
    hashes["height"] = hash_bytes(height_data);
    hashes["terrain_normal"] = hash_bytes(normal_data);
    hashes["map_index"] = hash_bytes(map_index_data);
    hashes["flow"] = hash_bytes(flow_data);
    hashes["water_depth"] = hash_bytes(water_data);
    hashes["terrain_detail"] = hash_bytes(detail_data);
    hashes["edge_neighbor"] = hash_bytes(edge_data);
    hashes["edge_distance"] = hash_bytes(edge_distance_data);

    const auto t1 = std::chrono::high_resolution_clock::now();
    out["fallback"] = false;
    out["reason"] = String();
    out["width"] = W;
    out["height"] = H;
    out["generation_id"] = int(knobs.get("generation_id", 0));
    out["layer_id"] = int(knobs.get("layer_id", 0));
    out["height"] = height_data;
    out["terrain_normal"] = normal_data;
    out["map_index"] = map_index_data;
    out["flow"] = flow_data;
    out["water_depth"] = water_data;
    out["terrain_detail"] = detail_data;
    out["edge_neighbor"] = edge_data;
    out["edge_distance"] = edge_distance_data;
    out["hashes"] = hashes;
    out["normal_reference_radius_px"] = normal_reference_radius;
    out["normal_radius_x_px"] = normal_radius_x;
    out["normal_radius_y_px"] = normal_radius_y;
    out["normal_reference_step_x"] = normal_reference_step_x;
    out["normal_reference_step_y"] = normal_reference_step_y;
    out["raster_scale_x"] = raster_scale_x;
    out["raster_scale_y"] = raster_scale_y;
    out["distance_scale"] = distance_scale;
    out["river_sdf_max_dist_px"] = river_sdf_max_dist_px;
    out["coast_sdf_max_dist_px"] = coast_sdf_max_dist_px;
    out["shore_carve_band_px"] = shore_carve_band_px;
    out["edge_distance_units"] = terr.get(
            "edge_distance_units", String("normalized_hex_center_gap"));
    out["edge_distance_saturate_hex"] = double(terr.get(
            "edge_distance_saturate_hex", VISUAL_EDGE_DISTANCE_SATURATE_HEX));
    out["terrain_ms"] = double(terr.get("elapsed_ms", -1.0));
    out["river_ms"] = double(river.get("elapsed_ms", -1.0));
    out["coast_ms"] = double(coast.get("elapsed_ms", -1.0));
    out["elapsed_ms"] = std::chrono::duration<double, std::milli>(t1 - t0).count();
    out["csr_emitted"] = false;
    return out;
}

godot::Dictionary DCWorldExt::run_resample_visual_horizon_layer_pass(godot::Dictionary knobs) {
    using godot::Dictionary;
    using godot::PackedByteArray;
    using godot::String;

    Dictionary out;
    out["fallback"] = true;
    out["reason"] = String();
    out["path"] = String("gdext_visual_horizon_resample");
    out["elapsed_ms"] = -1.0;
    auto fail = [&](const char *why) -> Dictionary {
        out["reason"] = String(why);
        return out;
    };

    const int src_w = int(knobs.get("source_width", 0));
    const int src_h = int(knobs.get("source_height", 0));
    const int dst_w = int(knobs.get("width", 0));
    const int dst_h = int(knobs.get("height", 0));
    if (src_w <= 0 || src_h <= 0 || dst_w <= 0 || dst_h <= 0) {
        return fail("invalid size");
    }
    PackedByteArray source = knobs.get("source_data", PackedByteArray());
    if (source.size() != src_w * src_h * 4) return fail("invalid source data");

    const double source_origin_x = double(knobs.get("source_origin_x", 0.0));
    const double source_origin_y = double(knobs.get("source_origin_y", 0.0));
    const double source_size_x = double(knobs.get("source_size_x", 0.0));
    const double source_size_y = double(knobs.get("source_size_y", 0.0));
    const double origin_x = double(knobs.get("origin_x", 0.0));
    const double origin_y = double(knobs.get("origin_y", 0.0));
    const double size_x = double(knobs.get("size_x", 0.0));
    const double size_y = double(knobs.get("size_y", 0.0));
    const double wrap_period_x = double(knobs.get("wrap_period_x", 0.0));
    if (source_size_x <= 0.0 || source_size_y <= 0.0 || size_x <= 0.0 || size_y <= 0.0) {
        return fail("invalid world rect");
    }

    PackedByteArray data;
    data.resize(dst_w * dst_h * 4);
    const uint8_t * const __restrict src = source.ptr();
    uint8_t * const __restrict dst = data.ptrw();
    const auto t0 = std::chrono::high_resolution_clock::now();
    auto run_range = [&](int y0, int y1) {
        for (int y = y0; y < y1; ++y) {
            const double wy = origin_y + (double(y) + 0.5) / double(dst_h) * size_y;
            const double v = std::max(0.0, std::min(1.0,
                    (wy - source_origin_y) / source_size_y));
            const int sy = std::max(0, std::min(src_h - 1,
                    int(std::floor(v * double(src_h)))));
            for (int x = 0; x < dst_w; ++x) {
                double wx = origin_x + (double(x) + 0.5) / double(dst_w) * size_x;
                if (wrap_period_x > 0.0001) {
                    wx = std::fmod(wx, wrap_period_x);
                    if (wx < 0.0) wx += wrap_period_x;
                }
                const double u = std::max(0.0, std::min(1.0,
                        (wx - source_origin_x) / source_size_x));
                const int sx = std::max(0, std::min(src_w - 1,
                        int(std::floor(u * double(src_w)))));
                const int si = (sy * src_w + sx) * 4;
                const int di = (y * dst_w + x) * 4;
                dst[di] = src[si];
                dst[di + 1] = src[si + 1];
                dst[di + 2] = src[si + 2];
                dst[di + 3] = src[si + 3];
            }
        }
    };
    pk::parallel_for_range("pk_visual_horizon_resample", dst_h,
            /*n_tasks=*/0, /*seq_threshold=*/64, run_range);
    const auto t1 = std::chrono::high_resolution_clock::now();

    uint64_t hash = 1469598103934665603ULL;
    for (int i = 0; i < data.size(); ++i) {
        hash ^= uint64_t(dst[i]);
        hash *= 1099511628211ULL;
    }
    out["fallback"] = false;
    out["data"] = data;
    out["width"] = dst_w;
    out["height"] = dst_h;
    out["generation_id"] = int(knobs.get("generation_id", 0));
    out["layer_id"] = int(knobs.get("layer_id", 0));
    out["hash"] = int64_t(hash);
    out["elapsed_ms"] = std::chrono::duration<double, std::milli>(t1 - t0).count();
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
