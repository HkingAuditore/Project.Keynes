#include "world_ext.h"

#include "component_bind_table.gen.h"  // A1 / dots-migration-roadmap §3 — autogen by tools/codegen/gen_cpp_bind_table.py
#include "system_schedule.h"           // Phase C.1 — 静态 DAG 调度图
#include "parallel_dispatcher.h"       // Phase C.3a — 并行分发 helper（统一 5 个手写 _thread）
#include "bake_dem_landform.h"
#include "bake_erosion_spl.h"      // SPL 汇流侵蚀核（纯函数 header-only，契约见 terrain-erosion-spl-contracts.md §2）
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

#include "world_ext_bake_section_river_distance.inc"
#include "world_ext_bake_section_droplet_erosion.inc"
#include "world_ext_bake_section_stream_power_erosion.inc"

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

#include "world_ext_bake_section_geometry_pipeline.inc"

#include "world_ext_bake_section_terrain_index.inc"



} // namespace pk
