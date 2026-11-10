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
    const double hex_size = std::max(0.0001, double(knobs.get("hex_size", 1.0)));
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
    const double normal_sample_radius_hex = std::max(0.01,
            double(knobs.get("normal_sample_radius_hex", 1.35)));
    const double normal_height_scale_hex = std::max(0.01,
            double(knobs.get("normal_height_scale_hex", 2.10)));
    const double normal_radius_world = normal_sample_radius_hex * hex_size;
    const int normal_radius_x = std::max(1, std::min(64, int(std::round(
            normal_radius_world / step_x))));
    const int normal_radius_y = std::max(1, std::min(64, int(std::round(
            normal_radius_world / step_y))));
    // 静态地表派生量（细节法线 / 海岸邻域 / 水面类别软过渡）需要的邻域半径。
    const double water_biome_radius_px = std::max(0.25, std::min(4.0,
            double(knobs.get("water_biome_radius_px", 4.0))));
    const int relief_flow_radius_px = int(std::ceil(hex_size / std::min(step_x, step_y))) + 2;
    const int required_halo = std::max({normal_radius_x, normal_radius_y,
            int(std::ceil(river_sdf_max_dist_px)) + 2,
            int(std::ceil(coast_sdf_max_dist_px)) + 2,
            shore_carve_band_px + 2,
            relief_flow_radius_px,
            int(std::ceil(water_biome_radius_px)) + 1});
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
    PackedFloat32Array baseline_procedural = knobs.get("baseline_procedural_height_buffer",
            PackedFloat32Array());
    const float * const BASE_P = baseline_procedural.size() >= BN ? baseline_procedural.ptr() : nullptr;
    // 基线 hm 宽度固定（桌面 1024），大地图每格只剩数个 texel，程序地形的 DEM 沟脊被奈奎斯特
    // 截断。tile 自己的 terrain-index 高度减去同位置的基线程序高度，即基线缺失的高频地形。
    const double procedural_detail_gain = std::max(0.0, std::min(2.0,
            double(knobs.get("procedural_detail_gain", 1.0))));
    const double procedural_detail_max = std::max(0.0, std::min(0.5,
            double(knobs.get("procedural_detail_max", 0.12))));
    auto sample_base_bicubic = [&](const float *src, double wx, double wy) -> double {
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
                v[kx + 1] = double(src[sy * BW + sx]);
            }
            rows[ky + 1] = cubic(v[0], v[1], v[2], v[3], tx);
        }
        return std::max(0.0, std::min(1.0,
                cubic(rows[0], rows[1], rows[2], rows[3], ty)));
    };
    auto sample_base_height = [&](double wx, double wy) -> double {
        return sample_base_bicubic(BASE_H, wx, wy);
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
            double procedural_detail = 0.0;
            if (!water && BASE_P != nullptr && procedural_detail_gain > 0.0) {
                procedural_detail = std::max(-procedural_detail_max, std::min(procedural_detail_max,
                        (double(PH[i]) - sample_base_bicubic(BASE_P, wx, wy)) * procedural_detail_gain));
            }
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
            double h = std::max(0.0, std::min(1.0, base + procedural_detail + residual));
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

    // Artificial canals share the height texture's A channel. Rasterization
    // uses only the owner cell and its six directed edges, keeping the work
    // bounded per pixel and adding no runtime sampler.
    PackedFloat32Array canal_work;
    canal_work.resize(WN);
    canal_work.fill(0.0f);
    PackedByteArray canal_mask = knobs.get("cell_canal_edge_mask", PackedByteArray());
    PackedFloat32Array canal_pos_x = knobs.get("cell_pos_x", PackedFloat32Array());
    PackedFloat32Array canal_pos_y = knobs.get("cell_pos_y", PackedFloat32Array());
    PackedInt32Array canal_neighbors = knobs.get("neighbor_indices", PackedInt32Array());
    const int canal_n_cells = int(knobs.get("n_cells", 0));
    if (canal_mask.size() >= canal_n_cells && canal_pos_x.size() >= canal_n_cells &&
        canal_pos_y.size() >= canal_n_cells && canal_neighbors.size() >= canal_n_cells * 6) {
        float * const CW = canal_work.ptrw();
        const uint8_t * const CM = canal_mask.ptr();
        const float * const CPX = canal_pos_x.ptr();
        const float * const CPY = canal_pos_y.ptr();
        const int32_t * const CN = canal_neighbors.ptr();
        const int32_t * const owner = p2c_work.ptr();
        const double radius = std::max(step_x, step_y) +
            hex_size * std::max(0.01, std::min(0.12,
                double(knobs.get("canal_stroke_hex_factor", 0.045))));
        for (int y = 0; y < WH; ++y) {
            const double py = work_origin_y + (double(y) + 0.5) * step_y;
            for (int x = 0; x < WW; ++x) {
                const int pixel = y * WW + x;
                const int32_t cell = owner[pixel];
                if (cell < 0 || cell >= canal_n_cells || (CM[cell] & 0x3fU) == 0)
                    continue;
                double px = work_origin_x + (double(x) + 0.5) * step_x;
                const double ax = double(CPX[cell]) * hex_size;
                const double ay = double(CPY[cell]) * hex_size;
                if (wrap_period_x > 0.0001) {
                    while (px - ax > wrap_period_x * 0.5) px -= wrap_period_x;
                    while (px - ax < -wrap_period_x * 0.5) px += wrap_period_x;
                }
                double best = radius;
                for (int direction = 0; direction < 6; ++direction) {
                    if ((CM[cell] & (1U << direction)) == 0) continue;
                    const int32_t neighbor = CN[cell * 6 + direction];
                    if (neighbor < 0 || neighbor >= canal_n_cells) continue;
                    double bx = double(CPX[neighbor]) * hex_size;
                    const double by = double(CPY[neighbor]) * hex_size;
                    if (wrap_period_x > 0.0001) {
                        while (bx - ax > wrap_period_x * 0.5) bx -= wrap_period_x;
                        while (bx - ax < -wrap_period_x * 0.5) bx += wrap_period_x;
                    }
                    const double vx = bx - ax, vy = by - ay;
                    const double denom2 = std::max(1e-12, vx * vx + vy * vy);
                    const double t = std::max(0.0, std::min(1.0,
                        ((px - ax) * vx + (py - ay) * vy) / denom2));
                    const double dx = px - (ax + vx * t);
                    const double dy = py - (ay + vy * t);
                    best = std::min(best, std::sqrt(dx * dx + dy * dy));
                }
                double canal = std::max(0.0, std::min(1.0, 1.0 - best / radius));
                canal = canal * canal * (3.0 - 2.0 * canal);
                CW[pixel] = float(canal);
                // Half one 8-bit horizon-height quantum: normals see the bank,
                // while horizon/GI remain valid.
                HW[pixel] = float(std::max(0.0, double(HW[pixel]) -
                    canal * (0.5 / 255.0)));
            }
        }
    }
    const float * const CANAL_W = canal_work.ptr();

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

    // height RGBA8: RG=16-bit carved visual elevation, B=natural river SDF,
    // A=artificial canal SDF.
    // 与 Legacy encode_height_flow_tex 对齐；不再单独产出 flow 层。
    // terrain_normal RGBA8: RG=粗法线 xy，BA=近景高度细节坡度（运行期只在拉近时淡入）。
    // terrain_relief RGBA8: RG=粗段细节坡度，BA=细段细节坡度。坡度均为 pk_relief::encode_slope。
    // terrain_detail R8: 连续细节噪声。
    // water_depth RGBA8: R=水深，G/B/A=湖 / 礁 / 海带的 3×3 软权重。
    // edge_distance RGBA8: R=到次生格的距离，G=沟谷深度（凹处遮蔽），B/A=8 邻域水 / 湖占比
    //   （海岸过渡；海占比 ≈ 水 − 湖）。fragment setup 每像素只读这一次，陆地和水面共用。
    PackedByteArray height_data; height_data.resize(N * 4);
    PackedByteArray normal_data; normal_data.resize(N * 4);
    // 细节坡度是 sub-hex 尺度的高频量，按 relief_supersample 倍分辨率烘焙（只这一张），
    // 运行期仍是 1 次采样：tile 寻址是归一化坐标，与该数组的物理尺寸无关。
    const int RS = std::max(1, std::min(4, int(knobs.get("relief_supersample", 1))));
    const int RW = W * RS;
    const int RH = H * RS;
    PackedByteArray relief_data; relief_data.resize(RW * RH * 4);
    PackedByteArray map_index_data; map_index_data.resize(N * 4);
    PackedByteArray water_data; water_data.resize(N * 4);
    PackedByteArray detail_data; detail_data.resize(N);
    PackedByteArray edge_data; edge_data.resize(N * 2);
    PackedByteArray edge_distance_data; edge_distance_data.resize(N * 4);
    uint8_t * const HD = height_data.ptrw();
    uint8_t * const ND = normal_data.ptrw();
    uint8_t * const RD = relief_data.ptrw();
    uint8_t * const MD = map_index_data.ptrw();
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
    const double normal_gain_x = normal_height_scale_hex * hex_size /
            (double(normal_radius_x * 2) * step_x);
    const double normal_gain_y = normal_height_scale_hex * hex_size /
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

    // 分地形细节法线与静态邻域量的输入。运行期着色参数在这里取默认值烘死；
    // 改动后需重新生成地图（与 normal_height_scale_hex 同类）。
    const float relief_coarse_strength = float(knobs.get("hillshade_coarse_strength", 1.65));
    const float relief_height_detail = float(knobs.get("hillshade_detail_strength", 0.16)) *
            float(knobs.get("hillshade_detail_quality", 0.55));
    const float relief_slope_gain = float(knobs.get("hillshade_slope_gain", 15.0));
    const float relief_shore_detail = float(knobs.get("shore_detail_strength", 0.45)) *
            float(knobs.get("hillshade_detail_quality", 0.55));
    const float relief_shore_band = std::max(0.001f, float(knobs.get("shore_band_height", 0.06)));
    const float relief_world_scale = std::max(1.0f,
            float(knobs.get("terrain_erosion_world_size", 72.0))) / 72.0f;
    const float relief_strength = std::max(0.0f, float(knobs.get("terrain_erosion_strength", 1.0)));
    const int map_w = int(knobs.get("map_width", 0));
    const int map_h = int(knobs.get("map_height", 0));
    PackedInt32Array offset_to_index = knobs.get("offset_to_index", PackedInt32Array());
    const int32_t * const O2I = (map_w > 0 && map_h > 0 &&
            offset_to_index.size() >= map_w * map_h) ? offset_to_index.ptr() : nullptr;
    const float flow_off_x = float(hex_size / step_x);
    const float flow_off_y = float(hex_size / step_y);
    const float hd_off = 3.5f;

    auto height_bilinear = [&](float fx, float fy) -> float {
        fx = std::max(0.0f, std::min(float(WW - 1), fx));
        fy = std::max(0.0f, std::min(float(WH - 1), fy));
        const int x0 = std::min(WW - 2, int(fx));
        const int y0 = std::min(WH - 2, int(fy));
        const float tx = fx - float(x0), ty = fy - float(y0);
        const float a = HW[y0 * WW + x0] * (1.0f - tx) + HW[y0 * WW + x0 + 1] * tx;
        const float b = HW[(y0 + 1) * WW + x0] * (1.0f - tx) + HW[(y0 + 1) * WW + x0 + 1] * tx;
        return a * (1.0f - ty) + b * ty;
    };
    // 沙丘只在成片沙海里成形：按本格 + 6 邻格中有沙丘配置的占比衰减，孤立的一两格沙漠不起沙丘。
    std::vector<float> dune_erg(size_t(std::max(n_cells, 0)), 1.0f);
    if (O2I != nullptr && CT != nullptr) {
        static const int NQ[6] = {1, -1, 0, 0, 1, -1};
        static const int NR[6] = {0, 0, 1, -1, -1, 1};
        auto has_dune = [&](int ci) {
            return ci >= 0 && ci < n_cells && pk_relief::profile_for(CT[ci]).dune > 0.0f;
        };
        for (int r = 0; r < map_h; ++r) {
            for (int col = 0; col < map_w; ++col) {
                const int ci = O2I[r * map_w + col];
                if (!has_dune(ci)) continue;
                const int q = col - (r - (r & 1)) / 2;
                int count = 1;
                for (int k = 0; k < 6; ++k) {
                    const int nr = r + NR[k];
                    if (nr < 0 || nr >= map_h) continue;
                    int ncol = q + NQ[k] + (nr - (nr & 1)) / 2;
                    ncol = ((ncol % map_w) + map_w) % map_w;
                    if (has_dune(O2I[nr * map_w + ncol])) ++count;
                }
                dune_erg[size_t(ci)] = pk_relief::smoothstepf(pk_relief::DUNE_ERG_FRAC_LO,
                        pk_relief::DUNE_ERG_FRAC_HI, float(count) / 7.0f);
            }
        }
    }
    auto erg_of = [&](int ci) {
        return (ci >= 0 && ci < n_cells) ? dune_erg[size_t(ci)] : 1.0f;
    };

    // 格内配置在不扭曲的 hex 对偶三角网上插值：取像素所在三角形三个格心的地形 / 地貌，
    // 按立方锐化的重心权重混合。格心必在本格内，不受边界扭曲影响。
    auto relief_profile = [&](double wx, double wy, int own_biome, int own_lf, int own_ci,
            pk_relief::Profile &P, float &lf_layered, float &lf_bad) {
        pk_relief::Profile own = pk_relief::profile_for(own_biome);
        own.dune *= erg_of(own_ci);
        const float own_layered = pk_relief::landform_is_layered(own_lf);
        const float own_bad = own_lf == pk_relief::LF_BADLANDS ? 1.0f : 0.0f;
        const double ax = (0.57735027 * wx - 0.33333333 * wy) / hex_size;
        const double ay = (0.66666667 * wy) / hex_size;
        const double bx = std::floor(ax), by = std::floor(ay);
        const float fx = float(ax - bx), fy = float(ay - by);
        const bool upper = fx + fy >= 1.0f;
        int vq[3], vr[3];
        float w[3];
        if (upper) {
            vq[0] = int(bx) + 1; vr[0] = int(by) + 1; w[0] = fx + fy - 1.0f;
            w[1] = 1.0f - fy; w[2] = 1.0f - fx;
        } else {
            vq[0] = int(bx); vr[0] = int(by); w[0] = 1.0f - fx - fy;
            w[1] = fx; w[2] = fy;
        }
        vq[1] = int(bx) + 1; vr[1] = int(by);
        vq[2] = int(bx); vr[2] = int(by) + 1;
        float wsum = 0.0f;
        for (int i = 0; i < 3; ++i) {
            w[i] = w[i] * w[i] * w[i];
            wsum += w[i];
        }
        P = {0, 0, 0, 0, 0, 0, 0};
        lf_layered = 0.0f;
        lf_bad = 0.0f;
        for (int i = 0; i < 3; ++i) {
            const float wi = w[i] / std::max(wsum, 1e-6f);
            pk_relief::Profile pi = own;
            float li_layered = own_layered, li_bad = own_bad;
            const int r = vr[i];
            if (O2I != nullptr && CT != nullptr && r >= 0 && r < map_h) {
                int col = vq[i] + (r - (r & 1)) / 2;
                col = ((col % map_w) + map_w) % map_w;
                const int ci = O2I[r * map_w + col];
                if (ci >= 0 && ci < n_cells && !pk_relief::is_water(CT[ci])) {
                    pi = pk_relief::profile_for(CT[ci]);
                    pi.dune *= dune_erg[size_t(ci)];
                    const int lf = (LF != nullptr && ci < landform.size()) ? LF[ci] : 0;
                    li_layered = pk_relief::landform_is_layered(lf);
                    li_bad = lf == pk_relief::LF_BADLANDS ? 1.0f : 0.0f;
                }
            }
            P.gully += pi.gully * wi;
            P.gully_wl += pi.gully_wl * wi;
            P.sharp += pi.sharp * wi;
            P.strata += pi.strata * wi;
            P.dune += pi.dune * wi;
            P.rolling += pi.rolling * wi;
            P.hummock += pi.hummock * wi;
            lf_layered += li_layered * wi;
            lf_bad += li_bad * wi;
        }
    };

    // ── 分地形细节坡度（RS 倍分辨率）─────────────────────────────────────
    // 子 texel 的粗法线 / 平滑高程场都从工作高度场双线性取，与基础分辨率的粗法线同半径同增益。
    const bool canal_refresh_only = bool(knobs.get("canal_refresh_only", false));
    std::vector<float> crease_sub(size_t(RW) * size_t(RH), 0.0f);
    const float sub_texel_world = float(std::sqrt(step_x * step_y) / double(RS));
    auto relief_rows = [&](int ry_begin, int ry_end) {
        for (int ry = ry_begin; ry < ry_end; ++ry) {
            const float fyw = float(halo) + (float(ry) + 0.5f) / float(RS) - 0.5f;
            const double wy = origin_y + (double(ry) + 0.5) * step_y / double(RS);
            const int by = std::min(H - 1, ry / RS);
            for (int rx = 0; rx < RW; ++rx) {
                const int ri_idx = ry * RW + rx;
                const int bx = std::min(W - 1, rx / RS);
                const int si = (by + halo) * WW + bx + halo;
                const int own_biome = BIOME_W[si];
                float out_c[4] = {0.0f, 0.0f, 0.0f, 0.0f};
                if (!pk_relief::is_water(own_biome)) {
                    const float fxw = float(halo) + (float(rx) + 0.5f) / float(RS) - 0.5f;
                    const double wx = origin_x + (double(rx) + 0.5) * step_x / double(RS);
                    const float sx = (height_bilinear(fxw + float(normal_radius_x), fyw) -
                            height_bilinear(fxw - float(normal_radius_x), fyw)) * float(normal_gain_x);
                    const float sy = (height_bilinear(fxw, fyw + float(normal_radius_y)) -
                            height_bilinear(fxw, fyw - float(normal_radius_y))) * float(normal_gain_y);
                    const float inv_len = 1.0f / std::sqrt(sx * sx + sy * sy + 1.0f);
                    pk_relief::Inputs ri;
                    ri.wx = float(wrap_world_x(wx));
                    ri.wy = float(wy);
                    ri.nc_x = -sx * inv_len * relief_coarse_strength;
                    ri.nc_y = -sy * inv_len * relief_coarse_strength;
                    ri.nc_z = std::sqrt(std::max(1e-4f,
                            1.0f - std::min(ri.nc_x * ri.nc_x + ri.nc_y * ri.nc_y, 0.998f)));
                    ri.elev = pk_relief::clampf(height_bilinear(fxw, fyw), 0.0f, 1.0f);
                    ri.sea_level = float(sea_level);
                    const float hl = height_bilinear(fxw - flow_off_x, fyw);
                    const float hr = height_bilinear(fxw + flow_off_x, fyw);
                    const float hu = height_bilinear(fxw, fyw - flow_off_y);
                    const float hd = height_bilinear(fxw, fyw + flow_off_y);
                    ri.flow_gx = (hr - hl) / float(2.0 * hex_size);
                    ri.flow_gy = (hd - hu) / float(2.0 * hex_size);
                    ri.flow_mean = (hl + hr + hu + hd) * 0.25f;
                    const int ci = P2C[si];
                    const int own_lf = (LF != nullptr && ci >= 0 && ci < landform.size()) ? LF[ci] : 0;
                    relief_profile(ri.wx, ri.wy, own_biome, own_lf, ci, ri.P, ri.lf_layered,
                            ri.lf_bad);
                    ri.hex_size = float(hex_size);
                    ri.height_scale_hex = float(normal_height_scale_hex);
                    ri.texel_world = sub_texel_world;
                    ri.wrap_period = float(wrap_period_x);
                    ri.world_scale = relief_world_scale;
                    ri.strength = relief_strength;
                    const pk_relief::Output ro = pk_relief::evaluate(ri);
                    out_c[0] = ro.coarse_x;
                    out_c[1] = ro.coarse_y;
                    out_c[2] = ro.fine_x;
                    out_c[3] = ro.fine_y;
                    crease_sub[size_t(ri_idx)] = ro.crease;
                }
                for (int c = 0; c < 4; ++c) RD[ri_idx * 4 + c] = pk_relief::encode_slope(out_c[c]);
            }
        }
    };
    if (!canal_refresh_only) {
        pk::parallel_for_range("pk_bake_visual_tile_relief", RH, bake_row_tasks(RH),
                /*seq_threshold=*/8, relief_rows);
    }

    auto encode_rows = [&](int y_begin, int y_end) {
        for (int y = y_begin; y < y_end; ++y) {
            const int wy_i = y + halo;
            const double wy = origin_y + (double(y) + 0.5) * step_y;
            for (int x = 0; x < W; ++x) {
                const int wx_i = x + halo;
                const int si = wy_i * WW + wx_i;
                const int di = y * W + x;
                const double wx = origin_x + (double(x) + 0.5) * step_x;
                const double h = std::max(0.0, std::min(1.0, double(HW[si])));
                const int h16 = std::max(0, std::min(65535, int(std::round(h * 65535.0))));
                const double f = std::max(0.0, std::min(1.0, double(FLOW_W[si])));
                HD[di * 4] = uint8_t((h16 >> 8) & 0xFF);
                HD[di * 4 + 1] = uint8_t(h16 & 0xFF);
                HD[di * 4 + 2] = uint8_t(std::round(f * 255.0));
                HD[di * 4 + 3] = uint8_t(std::round(std::max(0.0,
                    std::min(1.0, double(CANAL_W[si]))) * 255.0));

                const double sx = (double(HW[wy_i * WW + wx_i + normal_radius_x]) -
                        double(HW[wy_i * WW + wx_i - normal_radius_x])) * normal_gain_x;
                const double sy = (double(HW[(wy_i + normal_radius_y) * WW + wx_i]) -
                        double(HW[(wy_i - normal_radius_y) * WW + wx_i])) * normal_gain_y;
                const double inv_len = 1.0 / std::sqrt(sx * sx + sy * sy + 1.0);
                ND[di * 4] = uint8_t(std::max(0, std::min(255,
                        int(std::round((-sx * inv_len * 0.5 + 0.5) * 255.0)))));
                ND[di * 4 + 1] = uint8_t(std::max(0, std::min(255,
                        int(std::round((-sy * inv_len * 0.5 + 0.5) * 255.0)))));

                const int ci = P2C[si];
                const int own_biome = BIOME_W[si];
                const bool own_water = pk_relief::is_water(own_biome);

                // ── 沟谷深度（子 texel 平均）与近景高度细节 ─────────────────────
                float crease = 0.0f;
                for (int oy = 0; oy < RS; ++oy) {
                    for (int ox = 0; ox < RS; ++ox) {
                        crease += crease_sub[size_t((y * RS + oy) * RW + x * RS + ox)];
                    }
                }
                crease /= float(RS * RS);
                float hd_sx = 0.0f, hd_sy = 0.0f;
                if (!own_water) {
                    const float ncx = float(-sx * inv_len) * relief_coarse_strength;
                    const float ncy = float(-sy * inv_len) * relief_coarse_strength;
                    const float nc_z = std::sqrt(std::max(1e-4f,
                            1.0f - std::min(ncx * ncx + ncy * ncy, 0.998f)));
                    const float fxc = float(wx_i), fyc = float(wy_i);

                    // 近景高度细节：宽差分读出崖壁 / 河岸局部坡，近岸窄带单独增强。
                    // 按格主地形取强度：逐像素 biome 在过渡带是抖动抽选的，会让强度逐像素跳变。
                    const int geo_biome = (CT != nullptr && ci >= 0 && ci < n_cells &&
                            !pk_relief::is_water(CT[ci])) ? int(CT[ci]) : own_biome;
                    float hd_amt = relief_height_detail * pk_relief::height_detail_factor(geo_biome);
                    if (relief_shore_detail > 0.0f && h > sea_level) {
                        const float band = 1.0f - pk_relief::smoothstepf(0.0f, relief_shore_band,
                                float(h - sea_level));
                        hd_amt = std::max(hd_amt, band * relief_shore_detail);
                    }
                    if (hd_amt > 0.0f) {
                        const float g = relief_slope_gain / hd_off;
                        const float ddx = (height_bilinear(fxc + hd_off, fyc) -
                                height_bilinear(fxc - hd_off, fyc)) * g;
                        const float ddy = (height_bilinear(fxc, fyc + hd_off) -
                                height_bilinear(fxc, fyc - hd_off)) * g;
                        hd_sx = -ddx * hd_amt / nc_z;
                        hd_sy = -ddy * hd_amt / nc_z;
                    }
                }
                ND[di * 4 + 2] = pk_relief::encode_slope(hd_sx);
                ND[di * 4 + 3] = pk_relief::encode_slope(hd_sy);

                // ── 海岸 8 邻域：水 / 湖占比 ─────────────────────────────────
                int n_water = 0, n_lake = 0;
                for (int oy = -1; oy <= 1; ++oy) {
                    for (int ox = -1; ox <= 1; ++ox) {
                        if (ox == 0 && oy == 0) continue;
                        const int nb = BIOME_W[(wy_i + oy) * WW + wx_i + ox];
                        n_water += pk_relief::is_water(nb) ? 1 : 0;
                        n_lake += nb == pk_relief::B_LAKE ? 1 : 0;
                    }
                }
                // ── 水面类别 3×3 软权重（湖 / 礁 / 海带），足迹半径 water_biome_radius_px ─
                float c_lake = 0.0f, c_reef = 0.0f, c_kelp = 0.0f, c_total = 0.0f;
                for (int oy = -1; oy <= 1; ++oy) {
                    for (int ox = -1; ox <= 1; ++ox) {
                        const int tx = wx_i + int(std::lround(double(ox) * water_biome_radius_px));
                        const int ty = wy_i + int(std::lround(double(oy) * water_biome_radius_px));
                        const int nb = BIOME_W[ty * WW + tx];
                        const float sw = 1.0f - 0.18f * std::min(1.41421356f,
                                std::sqrt(float(ox * ox + oy * oy)));
                        c_lake += nb == pk_relief::B_LAKE ? sw : 0.0f;
                        c_reef += nb == pk_relief::B_REEF ? sw : 0.0f;
                        c_kelp += nb == pk_relief::B_KELP ? sw : 0.0f;
                        c_total += sw;
                    }
                }
                const float inv_ct = 255.0f / std::max(c_total, 0.001f);
                MD[di * 4] = BIOME_W[si];
                MD[di * 4 + 1] = ci >= 0 && ci < 0xFFFF ? uint8_t(ci & 0xFF) : 0xFF;
                MD[di * 4 + 2] = ci >= 0 && ci < 0xFFFF ? uint8_t((ci >> 8) & 0xFF) : 0xFF;
                MD[di * 4 + 3] = (LF != nullptr && ci >= 0 && ci < landform.size()) ? LF[ci] : 0;

                double depth = 0.0;
                if (CS != nullptr && ci >= 0 && ci < n_cells && CS[ci] > 1e-4f) {
                    const double raw = std::max(0.0, double(CS[ci]) - h);
                    const bool lake = CT != nullptr && CT[ci] == 18;
                    depth = std::min(1.0, raw / (lake ? 0.16 : std::max(1e-4, sea_level)));
                } else if (BWATER != nullptr) {
                    depth = sample_base_byte(BWATER, wx, wy);
                }
                WD[di * 4] = uint8_t(std::round(depth * 255.0));
                WD[di * 4 + 1] = uint8_t(std::lround(c_lake * inv_ct));
                WD[di * 4 + 2] = uint8_t(std::lround(c_reef * inv_ct));
                WD[di * 4 + 3] = uint8_t(std::lround(c_kelp * inv_ct));
                const double dn = std::max(-1.0, std::min(1.0, detail_periodic(wx, wy)));
                DD[di] = uint8_t(std::round((dn * 0.5 + 0.5) * 255.0));
                ED[di * 2] = EW[si * 2];
                ED[di * 2 + 1] = EW[si * 2 + 1];
                EDD[di * 4] = EDW[si];
                EDD[di * 4 + 1] = uint8_t(std::lround(pk_relief::clampf(crease, 0.0f, 1.0f) * 255.0f));
                EDD[di * 4 + 2] = uint8_t(std::lround(float(n_water) * (255.0f / 8.0f)));
                EDD[di * 4 + 3] = uint8_t(std::lround(float(n_lake) * (255.0f / 8.0f)));
            }
        }
    };
    pk::parallel_for_range("pk_bake_visual_tile_encode", H, bake_row_tasks(H),
            /*seq_threshold=*/8, encode_rows);

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
    if (!canal_refresh_only) {
        hashes["terrain_relief"] = hash_bytes(relief_data);
        hashes["map_index"] = hash_bytes(map_index_data);
        hashes["water_depth"] = hash_bytes(water_data);
        hashes["terrain_detail"] = hash_bytes(detail_data);
        hashes["edge_neighbor"] = hash_bytes(edge_data);
        hashes["edge_distance"] = hash_bytes(edge_distance_data);
    }

    const auto t1 = std::chrono::high_resolution_clock::now();
    out["fallback"] = false;
    out["reason"] = String();
    out["width"] = W;
    out["height"] = H;
    out["generation_id"] = int(knobs.get("generation_id", 0));
    out["layer_id"] = int(knobs.get("layer_id", 0));
    out["height"] = height_data;
    out["terrain_normal"] = normal_data;
    if (!canal_refresh_only) {
        out["terrain_relief"] = relief_data;
        out["map_index"] = map_index_data;
        out["water_depth"] = water_data;
        out["terrain_detail"] = detail_data;
        out["edge_neighbor"] = edge_data;
        out["edge_distance"] = edge_distance_data;
    }
    out["hashes"] = hashes;
    out["relief_supersample"] = RS;
    out["normal_sample_radius_hex"] = normal_sample_radius_hex;
    out["normal_height_scale_hex"] = normal_height_scale_hex;
    out["normal_radius_x_px"] = normal_radius_x;
    out["normal_radius_y_px"] = normal_radius_y;
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
            bake_row_tasks(dst_h), /*seq_threshold=*/64, run_range);
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


} // namespace pk
