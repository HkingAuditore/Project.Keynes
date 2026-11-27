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
#include <array>
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
    // [cell-field warp 2026-11-18] 边界扭曲场 RG8，与 edge_* 同一 halo 工作栅格、逐 texel 2 字节。
    PackedByteArray boundary_warp_work = terr.get("boundary_warp_buffer", PackedByteArray());
    if (procedural_height.size() != WN || biome_work.size() != WN ||
            p2c_work.size() != WN || edge_work.size() != WN * 2 ||
            edge_distance_work.size() != WN) {
        return fail("terrain payload size mismatch");
    }
    // warp 是附加视觉层：尺寸不符时只丢这一层（shader 侧 terrain_warp_layer_bound 保持 false），
    // 不让一个附加输出把整张 tile 打成 fallback。
    const uint8_t * const BW_W = (boundary_warp_work.size() == WN * 2)
            ? boundary_warp_work.ptr() : nullptr;

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

    // [tile-height-parallel 2026-11-18] 工作高度场原本是单线程逐 texel 循环：
    // 每个 texel 5 次 FBM（中心 + 上下左右滤波）+ 双三次基线高程采样，实测占
    // 单层烘焙六成以上——纯海洋层（跳过噪声）只要 ~55ms，陆地层 ~230ms，差值
    // 就是这段。这里按行分带并行，写入互不重叠，结果逐字节等价。
    //
    // 噪声实例必须**每带一份**：FastNoiseLite 没有跨线程重入的保证，共用一份
    // 就是把未定义行为放进热循环。配置参数与原单实例完全一致（同 seed / 同
    // 频率 / 同分形），因此每带的噪声输出与串行版逐位相同。
    const int height_bands = bake_row_tasks(WH);
    const int height_band_rows = (WH + height_bands - 1) / std::max(1, height_bands);
    std::vector<godot::Ref<godot::FastNoiseLite>> band_noise;
    band_noise.reserve(size_t(height_bands));
    for (int band = 0; band < height_bands; ++band) {
        godot::Ref<godot::FastNoiseLite> noise;
        noise.instantiate();
        noise->set_noise_type(godot::FastNoiseLite::TYPE_SIMPLEX_SMOOTH);
        noise->set_seed(int(knobs.get("seed", 0)) + 1597);
        noise->set_frequency(float(0.42 / hex_size));
        noise->set_fractal_type(godot::FastNoiseLite::FRACTAL_FBM);
        noise->set_fractal_octaves(3);
        band_noise.push_back(noise);
    }
    // [tile-height-columns PR#9] 回绕坐标只跟 x 有关，逐 texel 算 4 次 cos/sin 是白费：
    // 按列预计算 {cos(phase)*radius, sin(phase)*radius}，中心 / 左右滤波共用，
    // y 方向 ±r 只改第三个分量。纯数学、无共享状态，可以和上面的每带实例并存。
    using NoiseColumn = std::array<double, 2>;
    const bool wrap_noise = wrap_period_x > 0.0001;
    auto noise_column = [&](double wx) -> NoiseColumn {
        if (!wrap_noise) return {wx, 0.0};
        const double phase = wrap_world_x(wx) / wrap_period_x * (2.0 * M_PI);
        const double radius = wrap_period_x / (2.0 * M_PI);
        return {std::cos(phase) * radius, std::sin(phase) * radius};
    };
    std::vector<std::array<NoiseColumn, 3>> residual_columns;
    if (residual_amp > 0.0) {
        residual_columns.reserve(WW);
        for (int x = 0; x < WW; ++x) {
            const double wx = work_origin_x + (double(x) + 0.5) * step_x;
            residual_columns.push_back({noise_column(wx),
                noise_column(wx - residual_filter_radius),
                noise_column(wx + residual_filter_radius)});
        }
    }
    auto band_periodic_noise = [&](int band, const NoiseColumn &column, double wy) -> double {
        godot::FastNoiseLite *noise = band_noise[size_t(band)].ptr();
        if (!wrap_noise) return double(noise->get_noise_2d(column[0], wy));
        return double(noise->get_noise_3d(column[0], column[1], wy));
    };

    // [tile-profile 2026-11-18] 每层瓦片的内部耗时拆分，随 bundle 回给
    // surface_baker 写进 visual tiles 报告。六个 steady_clock 读数对单层
    // ~170ms 的量级可以忽略，换来的是"下一刀该切哪里"不用再猜。
    auto now_ms = []() -> double {
        return std::chrono::duration<double, std::milli>(
                std::chrono::steady_clock::now().time_since_epoch()).count();
    };
    Dictionary prof;
    double prof_last = now_ms();
    auto mark = [&](const char *key) {
        const double t = now_ms();
        prof[String(key)] = t - prof_last;
        prof_last = t;
    };

    PackedFloat32Array height_work;
    height_work.resize(WN);
    float * const HW = height_work.ptrw();
    const float * const PH = procedural_height.ptr();
    const uint8_t * const BIOME_W = biome_work.ptr();
    // n_tasks_hint == n 让每个 task 恰好是一整条带（chunk = 1），闭包拿到的
    // begin 就是带号，可以直接索引自己的噪声实例——parallel_for_range 的闭包
    // 只暴露 (begin,end)，没有 task_idx。
#include "world_ext_bake_visual_tiles_section_height_and_water_sampling.inc"
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

#include "world_ext_bake_visual_tiles_section_relief_and_tile_encoding.inc"
    if (bool(knobs.get("include_hashes", false))) {
        auto hash_bytes = [](const PackedByteArray &data) -> int64_t {
            uint64_t h = 1469598103934665603ULL;
            const uint8_t *p = data.ptr();
            for (int i = 0; i < data.size(); ++i) {
                h ^= uint64_t(p[i]);
                h *= 1099511628211ULL;
            }
            return int64_t(h);
        };
        hashes["height"] = hash_bytes(height_data);
        hashes["terrain_normal"] = hash_bytes(normal_data);
        if (!canal_refresh_only) {
            hashes["terrain_relief"] = hash_bytes(relief_data);
            hashes["map_index"] = hash_bytes(map_index_data);
            hashes["water_depth"] = hash_bytes(water_data);
            hashes["terrain_detail"] = hash_bytes(detail_data);
            hashes["edge_neighbor"] = hash_bytes(edge_data);
            hashes["edge_distance"] = hash_bytes(edge_distance_data);
            if (BW_W != nullptr) hashes["boundary_warp"] = hash_bytes(boundary_warp_data);
        }
        mark("hash");
    }

    const auto t1 = std::chrono::high_resolution_clock::now();
    out["profile"] = prof;
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
        // [cell-field warp 2026-11-18] tiled warp field：每 tile RG8（N*2），GDScript 侧
        //   VisualTileSet.FIELD_FORMATS 需登记 boundary_warp: FORMAT_RG8 才会上传成 tex 层。
        if (BW_W != nullptr) out["boundary_warp"] = boundary_warp_data;
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
    // [cell-field warp 2026-11-18] 解码分母 + clamp 诊断（诊断统计覆盖含 halo 的工作栅格）。
    out["boundary_warp_range"] = double(terr.get("boundary_warp_range", 1.6));
    out["boundary_warp_clamped"] = int(terr.get("boundary_warp_clamped", 0));
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
