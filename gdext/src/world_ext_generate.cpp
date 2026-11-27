#include "world_ext.h"
#include "simulation_math.h"

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
#include <cstring>
#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif
#include <condition_variable>
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


#include "world_ext_generate_section_generation_entry_points.inc"
// ─────────────────────────────────────────────────────────────────────────
// run_temp_baseline_year_bake — cell_temp_baseline_year 的权威 C++ 烘焙
//   (cpp-dots-runtime：仿真量计算归 C++，GDScript 仅留 fallback)。
//
// 海冰 + 显示温度的运行期 baseline (cell_temp_baseline_year) 原本由 GDScript
//   map_data.bake_lat_temp_year_lut 就地 pow(cos,..) 烤出来再经
//   refresh_slots_from_map 推给 slot——仿真量的权威落在 GDScript，逼着
//   GDScript / C++ / Shader 三处镜像同一条 lat_temp_bell。本 pass 把这步收回 C++：
//   用唯一 C++ 实现 pk_lat_temp_bell 从 lat_norm 算 baseline，写
//   cell_temp_baseline_year slot 并 _flush_slot_to_map 回 MapData。
//
// 输入：knobs["lat_norm"] = PackedFloat32Array（归一化纬度 ny∈[0,1]，0=北极/1=南极；
//   依赖地图几何 cube_row_norm，仍由 GDScript 生成期烤）。lat_norm 走 knob 而非 slot：
//   本 pass 在生成期 bake_lat_temp_year_lut 之后立即调，此刻 cell_lat_norm slot 可能尚未 refresh。
// 输出：cell_temp_baseline_year slot（写满 + flush 回 MapData.temp_baseline_year_arr，
//   供 GDScript fallback pass / climate_daily / debug 消费）。
// fallback：未 bind / 缺 slot / 缺 knob / n<=0 → fallback=true，GDScript 自烤兜底。
godot::Dictionary DCWorldExt::run_temp_baseline_year_bake(godot::Dictionary knobs) {
    using godot::Dictionary;
    using godot::PackedFloat32Array;
    using godot::String;
    using godot::StringName;

    Dictionary out;
    out["path"] = String("gdscript_fallback");
    out["fallback"] = true;
    out["reason"] = String();
    out["elapsed_ms"] = -1.0;

    auto fail = [&](const char *why) -> Dictionary {
        out["reason"] = String(why);
        return out;
    };

    if (!_bound) return fail("not bound");
    const int sid_ty = component_id(StringName("cell_temp_baseline_year"));
    if (sid_ty < 0) return fail("no cell_temp_baseline_year slot");
    if (!knobs.has("lat_norm")) return fail("missing lat_norm knob");
    const PackedFloat32Array lat = knobs["lat_norm"];
    const int n = lat.size();
    if (n <= 0) return fail("lat_norm empty");

    auto t0 = std::chrono::high_resolution_clock::now();

    Slot &s_ty = _slots.write[sid_ty];
    if (s_ty.arr_f32.size() != n) s_ty.arr_f32.resize(n);
    const float * const __restrict LAT = lat.ptr();
    float       * const __restrict TY  = s_ty.arr_f32.ptrw();
    for (int i = 0; i < n; ++i) {
        // SAME_SOURCE: DCClimateMath.lat_temp_bell_from_ny —— ny∈[0,1] → 钟形∈[0,1]。
        TY[i] = float(pk_clamp01(pk_lat_temp_bell((double(LAT[i]) - 0.5) * 2.0)));
    }

    // 写回 MapData.temp_baseline_year_arr（GDScript fallback pass / climate_daily / debug 消费）。
    _flush_slot_to_map(sid_ty);

    auto t1 = std::chrono::high_resolution_clock::now();
    out["path"] = String("gdext");
    out["fallback"] = false;
    out["n_cells"] = n;
    out["published_to_slot"] = true;
    out["elapsed_ms"] = std::chrono::duration<double, std::milli>(t1 - t0).count();
    return out;
}


godot::Dictionary DCWorldExt::run_native_world_generate_post_base_pass(
    int seed,
    const Dictionary &cfg,
    const Dictionary &profile,
    const Dictionary &input) {
    using godot::Dictionary;
    using godot::PackedByteArray;
    using godot::PackedFloat32Array;
    using godot::PackedInt32Array;
    using godot::String;

    Dictionary out;
    out["rc"] = -1;
    out["status"] = String("failed");
    out["path"] = String("gdscript_fallback");
    out["fallback"] = true;
    out["fallback_reason"] = String();
    out["reason"] = String();
    out["fail_stage"] = String("native_generation_post_base");
    out["published_to_slot"] = false;
    out["n_cells"] = 0;
    out["elapsed_ms"] = -1.0;
    out["native_ms"] = -1.0;
    out["compute_ms"] = 0.0;
    out["native_algorithm"] = String("post_base_priority_flood_hydrology_v3");

    auto fail = [&](const char *why, const char *stage = "native_generation_post_base") -> Dictionary {
        out["fallback_reason"] = String(why);
        out["reason"] = String(why);
        out["fail_stage"] = String(stage);
        return out;
    };

    const int width = int(cfg.get("width", 0));
    const int height = int(cfg.get("height", 0));
    if (width <= 0 || height <= 0) return fail("invalid_dimensions", "config");
    const int64_t n64 = int64_t(width) * int64_t(height);
    if (n64 <= 0 || n64 > 1000000) return fail("invalid_cell_count", "config");
    const int n = int(n64);

    auto getd = [](const Dictionary &d, const char *key, double fallback) -> double {
        return d.has(key) ? double(d.get(key, fallback)) : fallback;
    };
    auto geti = [](const Dictionary &d, const char *key, int fallback) -> int {
        return d.has(key) ? int(d.get(key, fallback)) : fallback;
    };
    auto getb = [](const Dictionary &d, const char *key, bool fallback) -> bool {
        return d.has(key) ? bool(d.get(key, fallback)) : fallback;
    };

    const double sea_level = getd(cfg, "sea_level", 0.64);
    const bool ocean_enabled = getb(cfg, "enable_ocean_heat_transport", false);
    // ── [scale-fix 2026-07-30] 分辨率归一（与 base pass 湿度块同源）──────────────────
    // s = sqrt(N/15000)：固定世界的线性分辨率比。凡"以格数标定的物理距离"都要换算：
    // 雨影探针距离 ×s（下方 lookback）；relief 阈值 ×(15000/N)^0.5（relief_thresh_scale）；
    // 河流成河阈值 / RFLOW 归一见 river_map_scale（双向）与 flow_eq_scale。
    constexpr double PK_GEN_REF_CELLS = 15000.0;
    const double gen_dist_scale = std::sqrt(std::max(0.0625, double(n) / PK_GEN_REF_CELLS));
    // [scale-fix] lookback ×s 保持雨影物理到达距离恒定（0 仍是"关闭雨影"的语义，不改写）。
    const int lookback_base = std::max(0, geti(profile, "rain_shadow_lookback", 3));
    const int lookback = (lookback_base > 0)
            ? std::max(1, int(std::round(double(lookback_base) * gen_dist_scale)))
            : 0;
    const double rain_threshold = getd(profile, "rain_shadow_threshold", 0.13);
    const double rain_factor = getd(profile, "rain_shadow_factor", 0.65);
    const double river_percentile = getd(profile, "river_flow_percentile", 0.72);  // 干支流树状河网：0.80→0.72（绘出支流）
    const int hydro_river_min_length_base = std::max(1, geti(profile, "hydro_river_min_length", 5));  // 最短河长：8→5
    const int river_headwater_init_base = std::max(1, geti(profile, "river_headwater_init_cells", 10));  // [density-fix] 6→10
    const double river_headwater_min_land_h = getd(profile, "river_headwater_min_land_h", 0.30);
    const int hydro_lake_min_cells = std::max(1, geti(profile, "hydro_lake_min_cells", 8));  // 成湖最小面积：18→8
    const double hydro_lake_min_depth = std::max(0.0, getd(profile, "hydro_lake_min_depth", 0.018));
    const double hydro_lake_min_volume = std::max(0.0, getd(profile, "hydro_lake_min_volume", 0.22));
    const double orographic_boost = getd(profile, "orographic_boost", 1.2);
    const double veg_elev_decay = getd(profile, "veg_feedback_elev_decay", 0.5);
    const int max_volcanoes = std::max(0, geti(profile, "max_volcanoes", 8));
    const int volcano_min_dist = std::max(0, geti(profile, "volcano_min_dist", 6));
    const double volcano_min_land_h = getd(profile, "volcano_min_land_h", 0.55);
    // [volcano-crater 2026-06-25] 火山环形山高度场塑形幅度（归一化高程 0..1 空间，量级参考
    // 其他 relief pass 的 0.035~0.115）：中心 cell 下凹成 caldera，第一环邻居抬升成环山脊。
    const double volcano_crater_depth = std::max(0.0, getd(profile, "volcano_crater_depth", 0.05));
    const double volcano_rim_height   = std::max(0.0, getd(profile, "volcano_rim_height", 0.07));
    const double plateau_min_land_h = getd(profile, "plateau_min_land_h", 0.35);
    const double plateau_max_relief_base = std::max(0.0, getd(profile, "plateau_max_relief", 0.14));
    const int plateau_min_cells = std::max(1, geti(profile, "plateau_min_cells", 3));
    // [density-fix 2026-06-30] PLATEAU area-ratio cap: unlike PEAK (land/N count
    // cap) and RIFT (land/N cap), PLATEAU previously had no density limit at all.
    // Cap total plateau area to a fraction of land; when exceeded, keep the
    // largest connected components and demote smaller ones to HILL.
    const double plateau_max_land_ratio = std::max(0.0, std::min(1.0, getd(profile, "plateau_max_land_ratio", 0.25)));
    // [density-fix] plateau_max_relief scales down for large maps: finer cell
    // sampling makes per-cell relief naturally smaller (same gradient sampled at
    // higher resolution → smaller per-cell deltas), so a fixed threshold admits
    // too many plateau candidates on large maps. Tighten by (ref/N)^k; exponent
    // 0.25 is a mild, conservative factor — the area-ratio cap above is the
    // primary density control, this is a secondary nudge.
    // [relief-physical 2026-10-12] PLATEAU/MOUNTAIN 的局部起伏改在固定物理半径上测量：
    // 噪声在归一化坐标采样，N 增大时 1 圈邻格高差随之变小，1 圈 relief 会把大图高地整片
    // 判成 PLATEAU（实测 60x40→200x150 占陆 6%→30%）。N > relief_ref_cells 时取半径
    // k=round(sqrt(N/ref)) 圈的 max-min，并按 sqrt(N/ref)/k 换算回参考格距的 1 圈当量；
    // 阈值冻结在 ref 尺寸的值。N <= ref 时 k=1、换算系数 1，与旧行为逐位一致。
    // base pass 的造山/山脊噪声已按 feature_scale 改为格距定义，只剩未抵消的那部分放大需要扩半径。
    const double relief_ref_cells = std::max(100.0, getd(profile, "relief_ref_cells", 2400.0));
    const double relief_feature_scale = simulation_math::pow(
            std::max(1.0, std::sqrt(double(n) / std::max(100.0, getd(profile, "feature_ref_cells", 2400.0)))),
            std::clamp(getd(profile, "feature_scale_exp", 1.0), 0.0, 1.0));
    const double relief_ideal_radius = std::max(1.0, std::sqrt(double(n) / relief_ref_cells) / relief_feature_scale);
    const int relief_radius = std::clamp(int(std::lround(relief_ideal_radius)), 1, 6);
    const double relief_radius_norm = relief_ideal_radius / double(relief_radius);
    const double geomorph_relief_n = std::min(double(n), relief_ref_cells);
    constexpr double plateau_relief_ref_cells = 15000.0;
    constexpr double plateau_relief_scale_exp = 0.25;
    const double plateau_relief_scale = simulation_math::pow(
            std::min(1.0, plateau_relief_ref_cells / std::max(1.0, geomorph_relief_n)),
            plateau_relief_scale_exp);
    const double plateau_max_relief = plateau_max_relief_base * plateau_relief_scale;
    const double mountain_min_land_h = getd(profile, "mountain_min_land_h", 0.70);
    const double mountain_min_relief_base = std::max(0.0, getd(profile, "mountain_min_relief", 0.115));
    const double peak_min_land_h = getd(profile, "peak_min_land_h", 0.74);
    const double peak_min_prominence = std::max(0.0, getd(profile, "peak_min_prominence", 0.035));
    const int peak_land_cells_per_peak = std::max(1, geti(profile, "peak_land_cells_per_peak", 120));
    const double rift_min_wall_base = std::max(0.0, getd(profile, "rift_min_wall", 0.024));
    const double rift_min_axis_base = std::max(0.0, getd(profile, "rift_min_axis", 0.052));
    const int rift_min_length_base = std::max(1, geti(profile, "rift_min_length_cells", 3));
    const double badlands_min_relief_base = std::max(0.0, getd(profile, "badlands_min_relief", 0.06));
    const int badlands_min_rugged_neighbors = std::max(1, std::min(6,
            geti(profile, "badlands_min_rugged_neighbors", 2)));
    const double badlands_max_land_ratio = std::clamp(
            getd(profile, "badlands_max_land_ratio", 1.0), 0.0, 1.0);
    const double badlands_max_arid_ratio = std::clamp(
            getd(profile, "badlands_max_arid_ratio", 1.0), 0.0, 1.0);
    // 默认不截断自然候选区；调试极端地图时仍可显式设置安全阀。
    const int badlands_max_patch_cells = std::max(0,
            geti(profile, "badlands_max_patch_cells", 0));
    // [scale-fix 2026-07-30] mountain/badlands 的 relief 阈值参照 plateau 的 (ref/N)^k 模式
    // 补分辨率缩放，但双向、指数默认 0.25：保留分辨率补偿，同时避免 60x40 等小地图
    // 把 mountain/rift/badlands 的局部高差门槛放大到候选集之外。
    // peak_min_prominence 维持不缩（PEAK 有 land/N 数量上限主控）。
    const double relief_thresh_scale_exp = getd(profile, "relief_thresh_scale_exp", 0.25);
    const double relief_thresh_scale = simulation_math::pow(
            std::max(0.25, PK_GEN_REF_CELLS / std::max(1.0, double(n))),
            relief_thresh_scale_exp);
    const double geomorph_relief_scale = simulation_math::pow(
            std::max(0.25, PK_GEN_REF_CELLS / std::max(1.0, geomorph_relief_n)),
            relief_thresh_scale_exp);
    const double mountain_min_relief = mountain_min_relief_base * geomorph_relief_scale;
    const double badlands_min_relief = badlands_min_relief_base * relief_thresh_scale;
    const double rift_min_wall = rift_min_wall_base * relief_thresh_scale;
    const double rift_min_axis = rift_min_axis_base * relief_thresh_scale;
    const int rift_min_length = std::max(1, int(std::round(
            double(rift_min_length_base) * gen_dist_scale)));
    const int river_channel_init_base = std::max(2, geti(profile, "river_channel_init_cells", 16));
    // 15000 格(150×100)是 ClimateProfile 的调参基准。世界是固定大小的行星：同源点的
    // up_count ∝ N（流域物理面积不变 → 流域格数 ∝ N），成河阈值须随 N 线性缩放才能
    // 保持河网物理密度恒定。
    //
    // [density-fix 2026-06-30] exponent 0.65→1.0: 线性缩放等价于把 up_count 归一化。
    // [scale-fix 2026-07-30] max(1.0,…) clamp → 双向缩放：旧 clamp 使 N<15000 的小图
    // 不缩，阈值相对流域面积偏高(64×100 时 ~2.3×) → 支流发不出来，小图河稀反衬大图
    // 河多。下限 0.25 仅防极端小图阈值归零。
    constexpr double river_map_reference_cells = 15000.0;
    constexpr double river_map_scale_exponent = 1.0;
    const double river_map_scale = simulation_math::pow(
            std::max(0.25, double(n) / river_map_reference_cells),
            river_map_scale_exponent);
    const int channel_init = std::max(2, int(std::round(double(river_channel_init_base) * river_map_scale)));
    const int river_headwater_init = std::max(1, int(std::round(double(river_headwater_init_base) * river_map_scale)));
    // [density-fix] min_length scale exponent 0.75→1.0: keep prune strength in
    // lockstep with channel_init so large-map short tributaries are pruned
    // proportionally rather than retained at a relatively weaker rate.
    const int hydro_river_min_length = std::max(1, int(std::round(
            double(hydro_river_min_length_base) * simulation_math::pow(river_map_scale, 1.0))));

    PackedInt32Array q_arr = input.get("q_arr", PackedInt32Array());
    PackedInt32Array r_arr = input.get("r_arr", PackedInt32Array());
    PackedInt32Array s_arr = input.get("s_arr", PackedInt32Array());
    PackedFloat32Array elevation_arr = input.get("elevation_arr", PackedFloat32Array());
    PackedFloat32Array moisture_arr = input.get("moisture_arr", PackedFloat32Array());
    PackedFloat32Array base_moisture_arr = input.get("base_moisture_arr", PackedFloat32Array());
    PackedFloat32Array temp_arr = input.get("temp_arr", PackedFloat32Array());
    PackedFloat32Array temp_baseline_arr = input.get("temp_baseline_arr", PackedFloat32Array());
    PackedFloat32Array temp_30d_arr = input.get("temp_30d_arr", PackedFloat32Array());
    PackedFloat32Array temp_365d_arr = input.get("temp_365d_arr", PackedFloat32Array());
    PackedFloat32Array temp_anomaly_arr = input.get("temp_anomaly_arr", PackedFloat32Array());
    PackedFloat32Array thermal_energy_arr = input.get("thermal_energy_arr", PackedFloat32Array());
    PackedFloat32Array cell_lat_norm_arr = input.get("cell_lat_norm_arr", PackedFloat32Array());
    PackedFloat32Array temp_baseline_year_arr = input.get("temp_baseline_year_arr", PackedFloat32Array());
    PackedFloat32Array snow_cover_arr = input.get("snow_cover_arr", PackedFloat32Array());
    PackedFloat32Array upwelling_arr = input.get("upwelling_strength_arr", PackedFloat32Array());
    PackedInt32Array dist_ocean_arr = input.get("dist_ocean_arr", PackedInt32Array());
    PackedByteArray terrain_arr = input.get("terrain_arr", PackedByteArray());
    PackedByteArray cover_arr = input.get("cover_arr", PackedByteArray());
    PackedByteArray ema_initialized_arr = input.get("ema_initialized_arr", PackedByteArray());

    if (q_arr.size() != n || r_arr.size() != n || elevation_arr.size() != n ||
        moisture_arr.size() != n || terrain_arr.size() != n) {
        return fail("required_input_size_mismatch", "input");
    }
    if (s_arr.size() != n) {
        s_arr.resize(n);
        int32_t *S = s_arr.ptrw();
        const int32_t *Q = q_arr.ptr();
        const int32_t *R = r_arr.ptr();
        for (int i = 0; i < n; ++i) S[i] = -Q[i] - R[i];
    }
    if (base_moisture_arr.size() != n) base_moisture_arr = moisture_arr.duplicate();
    if (temp_arr.size() != n) {
        temp_arr.resize(n);
        float *T = temp_arr.ptrw();
        const float *E = elevation_arr.ptr();
        const int32_t *R = r_arr.ptr();
        const double inv_h = 1.0 / double(std::max(height - 1, 1));
        for (int i = 0; i < n; ++i) T[i] = pk_compute_temperature(double(R[i]) * inv_h, E[i], sea_level);
    }
    if (temp_baseline_arr.size() != n) temp_baseline_arr = temp_arr.duplicate();
    if (temp_30d_arr.size() != n) temp_30d_arr = temp_arr.duplicate();
    if (temp_365d_arr.size() != n) temp_365d_arr = temp_arr.duplicate();
    if (temp_anomaly_arr.size() != n) {
        temp_anomaly_arr.resize(n);
        float *TA = temp_anomaly_arr.ptrw();
        for (int i = 0; i < n; ++i) TA[i] = 0.0f;
    }
    if (thermal_energy_arr.size() != n) thermal_energy_arr = temp_arr.duplicate();
    if (cell_lat_norm_arr.size() != n) {
        cell_lat_norm_arr.resize(n);
        float *LAT = cell_lat_norm_arr.ptrw();
        const int32_t *R = r_arr.ptr();
        const double inv_h = 1.0 / double(std::max(height - 1, 1));
        for (int i = 0; i < n; ++i) LAT[i] = float(double(R[i]) * inv_h);
    }
    if (temp_baseline_year_arr.size() != n) {
        temp_baseline_year_arr.resize(n);
        const float *LAT = cell_lat_norm_arr.ptr();
        float *TY = temp_baseline_year_arr.ptrw();
        for (int i = 0; i < n; ++i) {
            TY[i] = float(pk_clamp01(pk_lat_temp_bell((double(LAT[i]) - 0.5) * 2.0)));
        }
    }
    if (snow_cover_arr.size() != n) {
        snow_cover_arr.resize(n);
        float *SN = snow_cover_arr.ptrw();
        for (int i = 0; i < n; ++i) SN[i] = 0.0f;
    }
    if (cover_arr.size() != n) {
        cover_arr.resize(n);
        uint8_t *C = cover_arr.ptrw();
        for (int i = 0; i < n; ++i) C[i] = 0;
    }
    if (ema_initialized_arr.size() != n) {
        ema_initialized_arr.resize(n);
        uint8_t *EMA = ema_initialized_arr.ptrw();
        for (int i = 0; i < n; ++i) EMA[i] = 1;
    }

    PackedByteArray base_terrain_arr;
    base_terrain_arr.resize(n);
    PackedByteArray landform_arr;
    landform_arr.resize(n);
    PackedByteArray base_landform_arr;
    base_landform_arr.resize(n);
    PackedByteArray vegetation_arr;
    vegetation_arr.resize(n);
    PackedByteArray base_vegetation_arr;
    base_vegetation_arr.resize(n);
    PackedFloat32Array vegetation_vitality_arr;
    PackedFloat32Array soil_moisture_arr;
    PackedFloat32Array water_balance_30d_arr;
    PackedFloat32Array plant_available_water_arr;
    PackedFloat32Array vegetation_growth_pressure_arr;
    PackedFloat32Array vegetation_heat_stress_arr;
    PackedFloat32Array vegetation_drought_stress_arr;
    PackedFloat32Array vegetation_cold_stress_arr;
    PackedFloat32Array vegetation_regen_score_arr;
    vegetation_vitality_arr.resize(n);
    soil_moisture_arr.resize(n);
    water_balance_30d_arr.resize(n);
    plant_available_water_arr.resize(n);
    vegetation_growth_pressure_arr.resize(n);
    vegetation_heat_stress_arr.resize(n);
    vegetation_drought_stress_arr.resize(n);
    vegetation_cold_stress_arr.resize(n);
    vegetation_regen_score_arr.resize(n);
    PackedByteArray is_water_arr;
    is_water_arr.resize(n);
    PackedByteArray has_river_arr;
    has_river_arr.resize(n);
    PackedFloat32Array river_flow_arr;
    river_flow_arr.resize(n);
    PackedInt32Array river_downstream_arr;
    river_downstream_arr.resize(n);
    PackedInt32Array hydro_parent_arr;
    hydro_parent_arr.resize(n);
    PackedByteArray has_volcano_arr;
    has_volcano_arr.resize(n);

    const auto t0 = std::chrono::high_resolution_clock::now();

    const int32_t * const Q = q_arr.ptr();
    const int32_t * const R = r_arr.ptr();
    const int32_t * const S = s_arr.ptr();
    // [volcano-crater 2026-06-25] E 改为可写(.ptrw 前置 CoW，确保唯一缓冲)：火山 pass 需对火山
    // 及第一环邻居写高程塑成环形山，写回经 out["elevation_arr"] 传播到 HexCell.elevation。所有既有
    // 只读用法不受影响；后续结构地貌 pass 读到的是塑形后的高程（自洽：环脊更易判为 PEAK/MOUNTAIN）。
    float * const E = elevation_arr.ptrw();
    float * const M = moisture_arr.ptrw();
    float * const BM = base_moisture_arr.ptrw();
    float * const TEMP = temp_arr.ptrw();
    float * const T30 = temp_30d_arr.ptrw();
    float * const T365 = temp_365d_arr.ptrw();
    uint8_t * const TERR = terrain_arr.ptrw();
    uint8_t * const BTERR = base_terrain_arr.ptrw();
    uint8_t * const LF = landform_arr.ptrw();
    uint8_t * const BLF = base_landform_arr.ptrw();
    uint8_t * const VEG = vegetation_arr.ptrw();
    uint8_t * const BVEG = base_vegetation_arr.ptrw();
    uint8_t * const COV = cover_arr.ptrw();
    uint8_t * const IW = is_water_arr.ptrw();
    uint8_t * const RIV = has_river_arr.ptrw();
    float * const RFLOW_OUT = river_flow_arr.ptrw();
    int32_t * const RDOWN = river_downstream_arr.ptrw();
    int32_t * const HPARENT_OUT = hydro_parent_arr.ptrw();
    uint8_t * const VOLC = has_volcano_arr.ptrw();
    float * const VITALITY = vegetation_vitality_arr.ptrw();
    float * const SOIL = soil_moisture_arr.ptrw();
    float * const WB30 = water_balance_30d_arr.ptrw();
    float * const PLANT_WATER = plant_available_water_arr.ptrw();
    float * const VG_PRESSURE = vegetation_growth_pressure_arr.ptrw();
    float * const VHEAT = vegetation_heat_stress_arr.ptrw();
    float * const VDROUGHT = vegetation_drought_stress_arr.ptrw();
    float * const VCOLD = vegetation_cold_stress_arr.ptrw();
    float * const VREGEN = vegetation_regen_score_arr.ptrw();
    float * const UP = (upwelling_arr.size() == n) ? upwelling_arr.ptrw() : nullptr;

    constexpr int DQ[6] = { 1, 1, 0, -1, -1, 0 };
    constexpr int DR[6] = { 0, -1, -1, 0, 1, 1 };
    auto index_for_qr = [&](int q, int r) -> int {
        // [cylindrical-earth-daylight] 东西经度环绕：r(南北)保持硬边界返回 -1，
        // col(经度)用 posmod 绕回 [0,width) → 生成期邻居访问与运行时 map_data 一样东西连通；
        // 雨影 upwind 探针、侵蚀/水文 BFS 等读此函数的 pass 自动获得东西环绕。
        if (r < 0 || r >= height) return -1;
        int col = q + ((r - (r & 1)) / 2);
        col = ((col % width) + width) % width;
        return r * width + col;
    };
    std::vector<int32_t> NB(size_t(n) * 6, -1);
    bool row_major = true;
    for (int i = 0; i < n; ++i) {
        row_major &= R[i] == i / width && Q[i] == i % width - ((R[i] - (R[i] & 1)) / 2);
        for (int d = 0; d < 6; ++d) {
            NB[size_t(i) * 6 + d] = index_for_qr(Q[i] + DQ[d], R[i] + DR[d]);
        }
    }
    auto row_norm = [&](int i) -> double {
        return double(R[i]) / double(std::max(height - 1, 1));
    };
    auto land_h = [&](int i) -> double {
        return (double(E[i]) - sea_level) / std::max(1.0 - sea_level, 0.001);
    };
    auto geomorph_h = [&](int i) -> double {
        return pk_geomorph_h(double(E[i]), sea_level);
    };

#include "world_ext_generate_section_climate_and_river_network.inc"
#include "world_ext_generate_section_freshwater_feedback_and_landmarks.inc"
    // ── terrain-overhaul 新增地形特征 pass（均仅作用于陆地，在水体清理之前）──
    // 泛滥平原(FLOODPLAIN)：紧邻河道的低海拔非干旱陆地 → 周期性泛滥的肥沃冲积带。
    int floodplain_touched = 0;
    for (int i : land) {
        const uint8_t t = TERR[i];
        if (pk_is_water_terrain(t) || pk_is_permanent_landform(t)) continue;
        if (t == 30) continue;            // 方山已定型
        if (RIV[i] != 0) continue;        // 河道本身前面已按流量定型
        if (land_h(i) > 0.18) continue;   // 低地/河漫滩
        if (M[i] < 0.34f) continue;       // 干旱区只有紧贴大河才形成泛滥平原
        bool river_nb = false;
        bool strong_river_nb = false;
        for (int d = 0; d < 6; ++d) {
            const int ni = NB[size_t(i) * 6 + d];
            if (ni >= 0 && RIV[ni] != 0) {
                river_nb = true;
                if (river_ecology_flow[size_t(ni)] >= 0.45f) strong_river_nb = true;
            }
        }
        if (river_nb && (strong_river_nb || M[i] >= 0.52f)) {
            TERR[i] = 29; // FLOODPLAIN
            if (M[i] < 0.62f) M[i] = 0.62f;
            ++floodplain_touched;
        }
    }

    // 泥炭湿原(MOOR)：凉冷 + 极湿 + 排水不畅(低坡)的非高山陆地 → 酸性泥炭湿原。
    int moor_touched = 0;
    for (int i : land) {
        const uint8_t t = TERR[i];
        if (pk_is_water_terrain(t) || pk_is_permanent_landform(t)) continue;
        if (t == 9 || t == 17 || t == 8 || t == 10 || t == 29) continue; // 雪/冰/冻原/沼泽/泛滥平原跳过
        const double gt = gen_temp(i);
        if (gt < 0.14 || gt > 0.50) continue; // 凉冷带
        if (M[i] < 0.62f) continue;            // 高湿
        if (land_h(i) > 0.55) continue;        // 非高山
        float min_e = E[i], max_e = E[i];
        for (int d = 0; d < 6; ++d) {
            const int ni = NB[size_t(i) * 6 + d];
            if (ni < 0) continue;
            min_e = std::min(min_e, E[ni]);
            max_e = std::max(max_e, E[ni]);
        }
        if ((max_e - min_e) > 0.035f) continue; // 坡陡→不积水
        TERR[i] = 28; // MOOR
        ++moor_touched;
    }

    // 硬叶灌丛(CHAPARRAL)：暖温带 + 中等偏旱 + 近海(地中海式干夏)。
    const int chaparral_max_dist = std::max(1, geti(profile, "chaparral_max_dist_ocean", 4));
    int chaparral_touched = 0;
    for (int i : land) {
        const uint8_t t = TERR[i];
        if (t != 3 && t != 14 && t != 15) continue; // 仅从草/灌过渡带转化
        const int dd = dist_ocean[size_t(i)];
        if (dd < 0 || dd > chaparral_max_dist) continue; // 仅近海
        const double gt = gen_temp(i);
        // [climate-zone-fix P1] 温度上限 0.62→0.58 排除亚热带，与 shrubland 对齐地中海生态位；
        // 湿度上沿 0.50→0.46 收窄到地中海半干区间。
        if (gt < 0.42 || gt > 0.58) continue;  // 暖温带
        if (M[i] < 0.20f || M[i] > 0.46f) continue; // 中等偏旱
        if (land_h(i) > 0.55) continue;
        TERR[i] = 27; // CHAPARRAL
        ++chaparral_touched;
    }

    int reef_touched = 0;
    int kelp_touched = 0;
    int pelagic_touched = 0;
    for (int i = 0; i < n; ++i) {
        const uint8_t t = TERR[i];
        if (t != 0 && t != 1) continue;
        const double temp = pk_compute_temperature(row_norm(i), E[i], sea_level);
        bool has_land_neighbor = false;
        bool has_river_outlet_neighbor = false;
        bool has_water_neighbor = false;
        for (int d = 0; d < 6; ++d) {
            const int ni = NB[size_t(i) * 6 + d];
            if (ni < 0) continue;
            if (pk_is_water_terrain(TERR[ni])) {
                has_water_neighbor = true;
            } else {
                has_land_neighbor = true;
                if (RIV[ni] != 0) has_river_outlet_neighbor = true;
            }
        }
        const float up = (ocean_enabled && UP != nullptr) ? UP[i] : 0.0f;
        const double widen = (has_land_neighbor && up > 0.4f) ? 0.08 : 0.0;
        // 必须同时邻接陆地与开放水域（真实海岸线），否则内陆孤立水格不得升级为礁/藻林。
        if (has_land_neighbor && has_water_neighbor) {
            if (temp > (0.60 - widen) && !has_river_outlet_neighbor && t == 1) {
                TERR[i] = 19;
                ++reef_touched;
                continue;
            }
            if (temp >= (0.30 - widen) && temp <= (0.55 + widen) && t == 1) {
                TERR[i] = 21;
                ++kelp_touched;
                continue;
            }
        }
        if (ocean_enabled && !has_land_neighbor && t == 0 && up > 0.6f) {
            COV[i] = 6;
            ++pelagic_touched;
        }
    }

#include "world_ext_generate_section_water_cleanup_and_depth.inc"
#include "world_ext_generate_section_landform_refinement.inc"
#include "world_ext_generate_section_vegetation_and_final_fields.inc"
}

#include "world_ext_generate_section_river_cache_and_publish.inc"


} // namespace pk
