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


Dictionary DCWorldExt::run_native_world_generate_pass(int seed,
                                                      const Dictionary &cfg,
                                                      const Dictionary &profile) {
    Dictionary out = _run_native_generation_publish_pass(seed, cfg, profile, Dictionary());
    _native_generation_active = false;
    _native_generation_seed = seed;
    _native_generation_cfg = cfg.duplicate(true);
    _native_generation_profile = profile.duplicate(true);
    _native_generation_report = out.duplicate(true);
    return out;
}

// dots-total-cpp step4（2026-06-25）：base + post_base 融合单次驱动。
// base 的 10×n_cells SoA bundle 在 C++ 进程内直接喂给 post_base，不出语言边界。
Dictionary DCWorldExt::run_native_world_generate_full_pass(int seed,
                                                           const Dictionary &cfg,
                                                           const Dictionary &profile) {
    using godot::String;
    Dictionary base_res = run_native_world_generate_base_pass(seed, cfg, profile);
    if (int(base_res.get("rc", -1)) != 0 || bool(base_res.get("fallback", true))) {
        // base 失败：透传 base 结果（含 rc/fallback_reason），由 GDScript 中止。
        return base_res;
    }
    Dictionary post_res = run_native_world_generate_post_base_pass(seed, cfg, profile, base_res);
    // 合并 base 诊断键（GDScript 打印 base path 用），不覆盖 post_base 已有键。
    if (!post_res.has("native_algorithm") && base_res.has("native_algorithm")) {
        post_res["native_algorithm"] = base_res.get("native_algorithm", String("unknown"));
    }
    post_res["base_water_count"] = base_res.get("water_count", 0);
    post_res["base_land_count"] = base_res.get("land_count", 0);
    post_res["base_native_ms"] = base_res.get("native_ms", base_res.get("elapsed_ms", 0.0));
    post_res["base_n_cells"] = base_res.get("n_cells", 0);
    // [zonal-envelope 2026-08-01] 透传 base 期纬带湿度统计，供 headless 回归/审计断言。
    {
        static const char *kZonalKeys[] = {
            "zonal_moist_mean_eq", "zonal_moist_mean_subtrop",
            "zonal_moist_mean_midlat", "zonal_moist_mean_polar",
            "zonal_moist_min_subtrop",
            "zonal_land_cells_eq", "zonal_land_cells_subtrop",
            "zonal_land_cells_midlat", "zonal_land_cells_polar",
        };
        for (const char *key : kZonalKeys) {
            if (base_res.has(key) && !post_res.has(key)) {
                post_res[key] = base_res.get(key, Variant());
            }
        }
    }
    post_res["fused_base_post"] = true;
    return post_res;
}

Dictionary DCWorldExt::start_native_generation(int seed,
                                               const Dictionary &cfg,
                                               const Dictionary &profile) {
    _native_generation_active = true;
    _native_generation_seed = seed;
    _native_generation_cfg = cfg.duplicate(true);
    _native_generation_profile = profile.duplicate(true);
    _native_generation_report.clear();
    _native_generation_report["rc"] = 0;
    _native_generation_report["status"] = String("started");
    _native_generation_report["path"] = String("gdext");
    _native_generation_report["seed"] = seed;
    _native_generation_report["has_config"] = !cfg.is_empty();
    _native_generation_report["has_profile"] = !profile.is_empty();
    _native_generation_report["generation_progress"] = 0.0;
    _native_generation_report["implemented"] = true;
    _native_generation_report["published_to_slot"] = false;
    _native_generation_report["fallback"] = false;
    _native_generation_report["fallback_reason"] = String();
    _native_generation_report["fail_stage"] = String();
    return _native_generation_report.duplicate(true);
}

Dictionary DCWorldExt::run_native_generation_slice(const Dictionary &budget) {
    if (!_native_generation_active) {
        Dictionary out;
        out["rc"] = -1;
        out["status"] = String("idle");
        out["path"] = String("gdscript_fallback");
        out["fallback"] = true;
        out["fallback_reason"] = String("generation_not_started");
        out["reason"] = String("generation_not_started");
        out["seed"] = _native_generation_seed;
        out["budget"] = budget.duplicate(true);
        out["generation_progress"] = 0.0;
        out["implemented"] = true;
        out["published_to_slot"] = false;
        _native_generation_report = out.duplicate(true);
        return out;
    }
    Dictionary out = _run_native_generation_publish_pass(
        _native_generation_seed,
        _native_generation_cfg,
        _native_generation_profile,
        budget);
    _native_generation_active = false;
    _native_generation_report = out.duplicate(true);
    return out;
}

Dictionary DCWorldExt::finish_native_generation() {
    if (_native_generation_active) {
        Dictionary out = _run_native_generation_publish_pass(
            _native_generation_seed,
            _native_generation_cfg,
            _native_generation_profile,
            Dictionary());
        _native_generation_active = false;
        _native_generation_report = out.duplicate(true);
        return out;
    }
    if (!_native_generation_report.is_empty()) {
        return _native_generation_report.duplicate(true);
    }
    Dictionary out;
    out["rc"] = -1;
    out["status"] = String("idle");
    out["path"] = String("gdscript_fallback");
    out["fallback"] = true;
    out["fallback_reason"] = String("generation_not_started");
    out["reason"] = String("generation_not_started");
    out["seed"] = _native_generation_seed;
    out["generation_progress"] = 0.0;
    out["implemented"] = true;
    out["published_to_slot"] = false;
    _native_generation_report = out.duplicate(true);
    return out;
}

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

godot::Dictionary DCWorldExt::run_native_world_generate_base_pass(
    int seed,
    const Dictionary &cfg,
    const Dictionary &profile) {
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
    out["published_to_slot"] = false;
    out["native_algorithm"] = String("hydrology_basin_seed_v2");
    out["n_cells"] = 0;
    out["elapsed_ms"] = -1.0;
    out["native_ms"] = -1.0;
    out["compute_ms"] = 0.0;

    auto fail = [&](const char *why, const char *stage = "native_generation_base") -> Dictionary {
        out["fallback_reason"] = String(why);
        out["reason"] = String(why);
        out["fail_stage"] = String(stage);
        return out;
    };

    const int width = int(cfg.get("width", 0));
    const int height = int(cfg.get("height", 0));
    if (width <= 0 || height <= 0) {
        return fail("invalid_dimensions", "config");
    }
    const int64_t n64 = int64_t(width) * int64_t(height);
    if (n64 <= 0 || n64 > 1000000) {
        return fail("invalid_cell_count", "config");
    }
    const int n = int(n64);

    auto getd = [](const Dictionary &d, const char *key, double fallback) -> double {
        return d.has(key) ? double(d.get(key, fallback)) : fallback;
    };
    auto geti = [](const Dictionary &d, const char *key, int fallback) -> int {
        return d.has(key) ? int(d.get(key, fallback)) : fallback;
    };

    const double sea_level = getd(cfg, "sea_level", 0.64);
    const double continent_size = getd(cfg, "continent_size", 0.9);
    const int num_continents = std::max(1, std::min(8, geti(cfg, "num_continents", 3)));

    const double continent_warp_amp = getd(profile, "continent_warp_amp", 0.15);
    const double dist_field_weight = getd(profile, "dist_field_weight", 0.55);
    const double noise_weight = getd(profile, "noise_weight", 0.45);
    const double ridge_boost_amp = getd(profile, "ridge_boost_amp", 0.68);  // macro-relief：0.50→0.68（更高耸连片山系）
    const double meso_weight = getd(profile, "meso_weight", 0.40);   // 2026-06-19 回退：保留多块大陆+岛屿群（用户认可的形状）
    const double offshore_amp = getd(profile, "offshore_amp", 0.45);  // 2026-06-19 回退：保留近海点缀岛屿/群岛
    // [macro-relief 2026-06-19] 低频大尺度起伏权重。meso(400×高频)负责海岸破碎/群岛(用户认可，
    // 不动)；macro(~4周期/全宽低频)叠加大尺度高地/盆地结构 → 出现"大平原/大高地/大盆地"，并把
    // 汇水盆地放大 → 长干流+支流。乘 dist_field 只作用于陆地核心、海岸渐隐 → 不改变大陆轮廓。
    const double macro_relief_weight = getd(profile, "macro_relief_weight", 0.18);
    const double edge_falloff_start = getd(profile, "edge_falloff_start", 0.80);
    const double edge_falloff_end = getd(profile, "edge_falloff_end", 0.95);
    const double edge_falloff_depth = getd(profile, "edge_falloff_depth", 0.55);
    const double main_radius_min = getd(profile, "main_radius_min", 0.70);
    const double main_radius_max = getd(profile, "main_radius_max", 0.90);
    const double sat_radius_min = getd(profile, "satellite_radius_min", 0.18);
    const double sat_radius_max = getd(profile, "satellite_radius_max", 0.40);
    const int satellites_per_main = std::max(0, std::min(8, geti(profile, "satellites_per_main", 3)));
    const double main_place_min = getd(profile, "main_placement_min", 0.18);
    const double main_place_max = getd(profile, "main_placement_max", 0.82);
    const double sat_place_min = getd(profile, "satellite_placement_min", 0.08);
    const double sat_place_max = getd(profile, "satellite_placement_max", 0.92);
    const double main_sep = getd(profile, "main_separation_factor", 0.85);
    const double sat_sep = getd(profile, "satellite_separation_factor", 0.55);
    const double coastal_boost = getd(profile, "coastal_moisture_boost", 0.20);
    const double orographic_boost = getd(profile, "orographic_boost", 1.2);
    (void)coastal_boost; (void)orographic_boost; // 旧单向加湿棘轮已被风输送模型取代，保留 knob 读取以兼容 profile dict。

    // ── 统一气候场 knobs（terrain-overhaul Phase 3：盛行风水汽输送 + 海洋温度调节）──
    const double moisture_wind_evap = getd(profile, "moisture_wind_evap", 0.18);        // 海面每格蒸发增湿
    const double moisture_rainout_base = getd(profile, "moisture_rainout_base", 0.12);  // 陆地基础降水率（再平衡：0.16→0.12）
    const double moisture_orographic_gain = getd(profile, "moisture_orographic_gain", 6.0); // 迎风坡增雨系数
    const double moisture_continental_dry = getd(profile, "moisture_continental_dry", 0.022); // 内陆每格湿空气衰减(大陆度)
    const double moisture_land_base = getd(profile, "moisture_land_base", 0.17);        // 陆地湿度地板
    const double moisture_precip_gain = getd(profile, "moisture_precip_gain", 3.4);     // 降水→湿度映射增益
    const double moisture_humidity_cap = getd(profile, "moisture_humidity_cap", 1.2);   // 空气含水上限
    const double moisture_smooth = getd(profile, "moisture_smooth", 0.35);              // 纬向扫描后各向同性平滑权重
    const double moisture_noise_amp = getd(profile, "moisture_noise_amp", 0.08);        // 陆地湿度细节噪声
    // [zonal-envelope] 0.22→0.30 / 0.33→0.36：生产路径副热带 51% 草、荒漠 2.9%，加深并
    // 极移干带使草原落为真荒漠；center 极移避免高斯尾触赤道带（见 climate_profile.gd 注释）。
    const double subtropical_dry_strength = std::max(0.0, getd(profile, "moisture_subtropical_dry_strength", 0.30));
    const double subtropical_dry_center = std::clamp(getd(profile, "moisture_subtropical_dry_center", 0.36), 0.0, 1.0);
    const double subtropical_dry_width = std::max(0.02, getd(profile, "moisture_subtropical_dry_width", 0.18));
    // ── 行星尺度纬带降水结构（[zonal-envelope 2026-08-01]）──────────────────────────
    // 旧模型湿度只反映"距海里程"：海岸湿、内陆干，赤道/副热带/中纬几乎同湿 → 赤道核心
    // 无雨林(实测赤道陆地湿度 p50=0.29)、全图零荒漠(base_moisture<0.2 为 0 格)、草原系
    // 占陆地 48%。新增 ITCZ 赤道辐合湿带 / 中纬风暴路径湿带 / 极地干冷三条纬带包络，
    // 作用于 6b 纬向扫描的 rainout 乘数：辐合带就地降落水汽，并让信风下游(副热带)空气
    // 更干，与 Hadley/Ferrel 环流定性自洽。副热带干带仍走大陆度门控减法(原 6c+)，
    // 但移到海岸 guard 之后才能真实跌破 0.2(见下方顺序调整)。
    const double itcz_wet_strength = std::max(0.0, getd(profile, "moisture_itcz_wet_strength", 0.90));
    const double itcz_center = std::clamp(getd(profile, "moisture_itcz_center", 0.05), 0.0, 1.0);
    const double itcz_width = std::max(0.02, getd(profile, "moisture_itcz_width", 0.10));
    const double stormtrack_wet_strength = std::max(0.0, getd(profile, "moisture_stormtrack_wet_strength", 0.60));
    const double stormtrack_center = std::clamp(getd(profile, "moisture_stormtrack_center", 0.55), 0.0, 1.0);
    const double stormtrack_width = std::max(0.02, getd(profile, "moisture_stormtrack_width", 0.15));
    const double polar_dry_strength = std::clamp(getd(profile, "moisture_polar_dry_strength", 0.35), 0.0, 1.0);
    // 热带海洋蒸发增强：暖海蒸发更强，把信风水汽源加湿——ITCZ 的"辐合供水"在本模型
    // 里以源头增蒸表达（否则赤道陆格 rainout 因子再高，空气湿度本身枯竭也无雨可降）。
    const double tropical_evap_boost = std::max(0.0, getd(profile, "moisture_tropical_evap_boost", 1.0));
    // 雨林水分再循环 + ITCZ 辐合注入：实测探针显示仅靠海洋平流，赤道大陆内部空气湿度
    // 沿程枯竭（humidity→0），evap boost 因 humidity cap 饱和无效。地球亚马逊/刚果靠
    // ~50% 降水蒸散再循环 + 双半球信风辐合持续供水维持内陆雨林。recycle 截留部分降水
    // 回到气柱，convergence 每格恒量注入（辐合流），二者共同让雨林湿带深入内陆。
    const double itcz_recycle_strength = std::clamp(getd(profile, "moisture_itcz_recycle_strength", 0.62), 0.0, 0.9);
    const double itcz_convergence = std::max(0.0, getd(profile, "moisture_itcz_convergence", 0.05));
    const double coastal_temp_moderation = getd(profile, "coastal_temp_moderation", 0.18); // 海洋温度调节强度(拉向温带)
    const double coastal_temp_scale = getd(profile, "coastal_temp_scale", 6.0);         // 海洋影响随距海(格)的衰减尺度

    // ── [scale-fix 2026-07-30] 湿度/气候"格距"参数的分辨率归一 ─────────────────────
    // 世界是固定大小的行星（经度恒 2π、纬度恒 [0,1]，噪声在归一化坐标采样，与格数无关），
    // N 变化时 1 格的物理尺寸 ∝ 1/sqrt(N)。下列参数本质是"物理距离/每物理距离比率"，但
    // 历史上以格数标定（基准 150×100=15000 格）→ 不缩放时小图过湿、大图内陆整片沙漠。
    // 统一按线性分辨率比 s=sqrt(N/15000) 换算成物理一致：
    //   · 指数衰减长度/BFS 格数阈值  ×s   （coastal_temp_scale / coastal_moist_scale / 副热带 interior ramp）
    //   · 每格保留率类  换成每物理距离保留率 (1-r)^(1/s)（rainout_base / continental_dry）
    //   · 加性海面增湿  ÷s   （wind_evap；cap 饱和使长距离海上穿越本来就不敏感）
    //   · 地形增雨 upslope×gain 不动：相邻格 ΔE 自带 1/s，与"坡面格数 ∝ s"相消，天然自洽。
    constexpr double PK_HYDRO_REF_CELLS = 15000.0;
    const double hydro_dist_scale = std::sqrt(std::max(0.0625, double(n) / PK_HYDRO_REF_CELLS));
    const double inv_hydro_dist_scale = 1.0 / hydro_dist_scale;
    const double moisture_wind_evap_eff = moisture_wind_evap * inv_hydro_dist_scale;
    const double moisture_rainout_base_eff = 1.0 - std::pow(1.0 - moisture_rainout_base, inv_hydro_dist_scale);
    const double moisture_continental_dry_eff = 1.0 - std::pow(1.0 - moisture_continental_dry, inv_hydro_dist_scale);
    const double coastal_temp_scale_eff = std::max(0.5, coastal_temp_scale * hydro_dist_scale);
    const double coastal_moist_scale_eff = std::max(0.25,
            std::max(1.0, getd(profile, "moisture_coastal_scale", 7.0)) * hydro_dist_scale);
    const double subtropical_interior_scale_eff = std::max(0.5, 8.0 * hydro_dist_scale);

    // ── lake-seed / pit-fill knobs（镜像 ClimateProfile，复刻 _carve_lake_seeds / _smooth_pit_depressions）──
    const double lake_seed_freq = getd(profile, "lake_seed_freq", 0.07);
    const double lake_seed_threshold = getd(profile, "lake_seed_threshold", 0.62);
    const double lake_seed_depth = getd(profile, "lake_seed_depth", 0.04);
    const double lake_seed_min_interior = getd(profile, "lake_seed_min_interior", 0.12);
    const int pit_fill_max_iters = std::max(0, geti(profile, "pit_fill_max_iters", 100));

    // ── FastNoiseLite 实例：与 map_generator.gd::_init_noise 逐位同源 ──
    // 复刻策略：native 生成改用 Godot 同款引擎噪声（同 seed/freq/octaves/lacunarity/gain），
    // 而非自带 pk_hash_fbm，使 C++ 生成与 GDScript 路径 bit-exact，可走 A/B 验证后删 GDScript。
    Ref<FastNoiseLite> height_noise;  height_noise.instantiate();
    height_noise->set_noise_type(FastNoiseLite::TYPE_SIMPLEX_SMOOTH);
    height_noise->set_seed(seed);
    height_noise->set_frequency(0.014);
    height_noise->set_fractal_type(FastNoiseLite::FRACTAL_FBM);
    height_noise->set_fractal_octaves(4);
    height_noise->set_fractal_lacunarity(2.0);
    height_noise->set_fractal_gain(0.5);

    Ref<FastNoiseLite> height_warp;  height_warp.instantiate();
    height_warp->set_noise_type(FastNoiseLite::TYPE_SIMPLEX_SMOOTH);
    height_warp->set_seed(seed + 13);
    height_warp->set_frequency(0.025);
    height_warp->set_fractal_type(FastNoiseLite::FRACTAL_FBM);
    height_warp->set_fractal_octaves(3);

    Ref<FastNoiseLite> detail_noise;  detail_noise.instantiate();
    detail_noise->set_noise_type(FastNoiseLite::TYPE_SIMPLEX);
    detail_noise->set_seed(seed + 257);
    detail_noise->set_frequency(0.040);
    detail_noise->set_fractal_type(FastNoiseLite::FRACTAL_FBM);
    detail_noise->set_fractal_octaves(3);

    Ref<FastNoiseLite> moisture_noise;  moisture_noise.instantiate();
    moisture_noise->set_noise_type(FastNoiseLite::TYPE_SIMPLEX_SMOOTH);
    moisture_noise->set_seed(seed + 9973);
    moisture_noise->set_frequency(0.022);
    moisture_noise->set_fractal_type(FastNoiseLite::FRACTAL_FBM);
    moisture_noise->set_fractal_octaves(4);
    moisture_noise->set_fractal_lacunarity(2.0);
    moisture_noise->set_fractal_gain(0.5);

    // 湖泊种子噪声：镜像 _carve_lake_seeds 内部局部 FastNoiseLite。
    Ref<FastNoiseLite> lake_noise;  lake_noise.instantiate();
    lake_noise->set_noise_type(FastNoiseLite::TYPE_SIMPLEX);
    lake_noise->set_seed(seed + 9173);
    lake_noise->set_frequency(lake_seed_freq);
    lake_noise->set_fractal_type(FastNoiseLite::FRACTAL_FBM);
    lake_noise->set_fractal_octaves(3);
    // [湖泊多样化 2026-06-19] 高频小湖噪声：低频 lake_noise 给大/中湖盆，本层给散布的小湖点，
    // 二者叠加产生"小/中/大"大小层次；同时复用本噪声做 domain-warp 让湖盆边界不规则(形状多样)。
    Ref<FastNoiseLite> lake_noise_small;  lake_noise_small.instantiate();
    lake_noise_small->set_noise_type(FastNoiseLite::TYPE_SIMPLEX);
    lake_noise_small->set_seed(seed + 4421);
    lake_noise_small->set_frequency(lake_seed_freq * 2.6);
    lake_noise_small->set_fractal_type(FastNoiseLite::FRACTAL_FBM);
    lake_noise_small->set_fractal_octaves(3);

    if (height_noise.is_null() || height_warp.is_null() || detail_noise.is_null()
            || moisture_noise.is_null() || lake_noise.is_null() || lake_noise_small.is_null()) {
        return fail("fast_noise_lite_instantiate_failed", "noise");
    }

    // ── 大陆中心点：与 _make_continent_centers + _try_place 逐位同源 ──
    // GDScript `_rng.seed = effective_seed`（无 xor 混淆），用 Godot RNG 同款 PCG。
    struct Center {
        double x;
        double y;
        double radius;
    };
    std::vector<Center> centers;
    centers.reserve(size_t(std::max(1, num_continents) * (1 + std::max(0, satellites_per_main))));
    Ref<RandomNumberGenerator> rng;  rng.instantiate();
    if (rng.is_null()) {
        return fail("rng_instantiate_failed", "rng");
    }
    rng->set_seed(uint64_t(seed));
    const double base_radius_unit = continent_size * 0.6;
    const int n_main = std::max(1, num_continents);
    const int n_satellite = n_main * std::max(0, satellites_per_main);
    auto try_place = [&](double radius, double lo, double hi, double sep_factor, int attempts) -> void {
        for (int attempt = 0; attempt < attempts; ++attempt) {
            const double px = double(rng->randf_range(lo, hi));
            const double py = double(rng->randf_range(lo, hi));
            bool ok = true;
            for (const Center &c : centers) {
                // [cylindrical-earth-daylight] 经度环绕最短距离 → 中心间距在接缝处也正确，避免左右各放一坨。
                double dx = std::fabs(px - c.x);
                if (dx > 0.5) dx = 1.0 - dx;
                const double dy = py - c.y;
                const double d = std::sqrt(dx * dx + dy * dy);
                if (d < (radius + c.radius) * sep_factor) {
                    ok = false;
                    break;
                }
            }
            if (ok) {
                centers.push_back(Center{px, py, radius});
                return;
            }
        }
    };
    for (int i = 0; i < n_main; ++i) {
        const double radius = (main_radius_min + (main_radius_max - main_radius_min) * double(rng->randf())) * base_radius_unit;
        try_place(radius, main_place_min, main_place_max, main_sep, 50);
    }
    for (int i = 0; i < n_satellite; ++i) {
        const double radius = (sat_radius_min + (sat_radius_max - sat_radius_min) * double(rng->randf())) * base_radius_unit;
        try_place(radius, sat_place_min, sat_place_max, sat_sep, 30);
    }

    // ── 板块构造基底（terrain-overhaul Phase 0）─────────────────────────────
    // 用 Voronoi 板块（泊松散点 + Lloyd 松弛）替代放射状大陆中心：每板块标 oceanic/
    // continental + 漂移向量；会聚边界沿板块缝隙抬升线状山脉带/岛弧，离散边界成洋中脊/
    // 裂谷。基础海拔 = 板块基线(跨边界平滑混合) + 边界抬升，再叠 fBm 细节。tectonic_blend
    // 在板块场与旧放射场之间插值（默认偏板块，可调回 0 降风险）。
    // 回归修复(2026-06-18)：默认回退到放射状大陆(0.0)。板块基线归一化后会把全图抬成超大
    // 高原大陆，导致过冷/枯干/山地荒漠铺满。代码保留，重新标定前默认关闭。
    const double tectonic_blend = pk_clamp01(getd(profile, "tectonic_blend", 0.0));
    const int tectonic_plate_count = std::max(3, std::min(40, geti(profile, "tectonic_plate_count", 14)));
    const double tectonic_continental_fraction = pk_clamp01(getd(profile, "tectonic_continental_fraction", 0.45));
    const double tectonic_continental_base = getd(profile, "tectonic_continental_base", 0.62);
    const double tectonic_oceanic_base = getd(profile, "tectonic_oceanic_base", 0.15);
    const double tectonic_uplift_amp = getd(profile, "tectonic_uplift_amp", 0.55);
    const double tectonic_ridge_width = std::max(0.005, getd(profile, "tectonic_ridge_width", 0.06));
    const double tectonic_drift_speed = getd(profile, "tectonic_drift_speed", 1.0);
    const int tectonic_lloyd_iters = std::max(0, std::min(6, geti(profile, "tectonic_lloyd_iters", 2)));

    struct Plate { double x, y; double dx, dy; bool continental; double base_h; };
    std::vector<Plate> plates;
    if (tectonic_blend > 0.0) {
        Ref<RandomNumberGenerator> prng;  prng.instantiate();
        if (prng.is_valid()) prng->set_seed(uint64_t(seed) + 4400ull);
        plates.reserve(size_t(tectonic_plate_count));
        for (int i = 0; i < tectonic_plate_count; ++i) {
            Plate p;
            p.x = prng.is_valid() ? double(prng->randf()) : 0.5;
            p.y = prng.is_valid() ? double(prng->randf()) : 0.5;
            const double ang = (prng.is_valid() ? double(prng->randf()) : 0.0) * 2.0 * M_PI;
            const double spd = tectonic_drift_speed * (0.4 + 0.6 * (prng.is_valid() ? double(prng->randf()) : 0.5));
            p.dx = std::cos(ang) * spd;
            p.dy = std::sin(ang) * spd;
            p.continental = (prng.is_valid() ? double(prng->randf()) : 0.5) < tectonic_continental_fraction;
            p.base_h = p.continental ? tectonic_continental_base : tectonic_oceanic_base;
            plates.push_back(p);
        }
        // Lloyd 松弛：32x32 采样网格 → 质心，去聚集得到近泊松分布。
        for (int it = 0; it < tectonic_lloyd_iters && plates.size() > 1; ++it) {
            constexpr int G = 32;
            std::vector<double> ax(plates.size(), 0.0), ay(plates.size(), 0.0);
            std::vector<int> cnt(plates.size(), 0);
            for (int gy = 0; gy < G; ++gy) {
                for (int gx = 0; gx < G; ++gx) {
                    const double sx = (double(gx) + 0.5) / double(G);
                    const double sy = (double(gy) + 0.5) / double(G);
                    int best = 0; double bestd = 1e30;
                    for (size_t p = 0; p < plates.size(); ++p) {
                        const double ddx = sx - plates[p].x, ddy = sy - plates[p].y;
                        const double dd = ddx * ddx + ddy * ddy;
                        if (dd < bestd) { bestd = dd; best = int(p); }
                    }
                    ax[size_t(best)] += sx; ay[size_t(best)] += sy; cnt[size_t(best)]++;
                }
            }
            for (size_t p = 0; p < plates.size(); ++p) {
                if (cnt[p] > 0) { plates[p].x = ax[p] / double(cnt[p]); plates[p].y = ay[p] / double(cnt[p]); }
            }
        }
    }
    auto tectonic_elev_at = [&](double nx, double ny, double dist_perturb) -> double {
        int p0 = -1, p1 = -1;
        double d0 = 1e30, d1 = 1e30;
        for (size_t p = 0; p < plates.size(); ++p) {
            const double ddx = nx - plates[p].x;
            const double ddy = ny - plates[p].y;
            const double dd = std::sqrt(ddx * ddx + ddy * ddy) + dist_perturb;
            if (dd < d0) { d1 = d0; p1 = p0; d0 = dd; p0 = int(p); }
            else if (dd < d1) { d1 = dd; p1 = int(p); }
        }
        if (p0 < 0) return tectonic_oceanic_base;
        if (p1 < 0) return plates[size_t(p0)].base_h;
        const double denom = std::max(d0 + d1, 1e-6);
        const double w1 = d0 / denom; // 越靠近边界 → 对方板块权重越大(被动陆缘/大陆架)
        double base = plates[size_t(p0)].base_h * (1.0 - w1) + plates[size_t(p1)].base_h * w1;
        const double bf = 1.0 - pk_smoothstep(0.0, tectonic_ridge_width, std::fabs(d1 - d0));
        if (bf > 0.0) {
            const Plate &A = plates[size_t(p0)];
            const Plate &B = plates[size_t(p1)];
            double n01x = B.x - A.x, n01y = B.y - A.y;
            const double nl = std::sqrt(n01x * n01x + n01y * n01y);
            if (nl > 1e-6) { n01x /= nl; n01y /= nl; }
            double approach = (A.dx * n01x + A.dy * n01y) - (B.dx * n01x + B.dy * n01y);
            if (approach > 1.5) approach = 1.5;
            else if (approach < -1.5) approach = -1.5;
            if (approach > 0.0) {
                base += bf * approach * tectonic_uplift_amp; // 会聚：山脉带/岛弧
            } else {
                const bool both_ocean = !A.continental && !B.continental;
                if (both_ocean) base += bf * (-approach) * tectonic_uplift_amp * 0.35; // 洋中脊
                else base -= bf * (-approach) * tectonic_uplift_amp * 0.30;            // 裂谷
            }
        }
        return base;
    };
    (void)tectonic_elev_at;  // [bimodal 2026-06-26] 双峰路径不调用（tectonic 仍保留作回退基础设施）

    PackedInt32Array q_arr;
    PackedInt32Array r_arr;
    PackedInt32Array s_arr;
    PackedFloat32Array elevation_arr;
    PackedFloat32Array moisture_arr;
    PackedFloat32Array base_moisture_arr;
    PackedFloat32Array temp_arr;
    PackedFloat32Array temp_baseline_arr;
    PackedFloat32Array temp_30d_arr;
    PackedFloat32Array temp_365d_arr;
    PackedFloat32Array temp_anomaly_arr;
    PackedFloat32Array thermal_energy_arr;
    PackedFloat32Array cell_lat_norm_arr;
    PackedFloat32Array temp_baseline_year_arr;
    PackedFloat32Array snow_cover_arr;
    PackedByteArray terrain_arr;
    PackedByteArray base_terrain_arr;
    PackedByteArray landform_arr;
    PackedByteArray base_landform_arr;
    PackedByteArray vegetation_arr;
    PackedByteArray base_vegetation_arr;
    PackedByteArray cover_arr;
    PackedByteArray is_water_arr;
    PackedByteArray ema_initialized_arr;

    q_arr.resize(n);
    r_arr.resize(n);
    s_arr.resize(n);
    elevation_arr.resize(n);
    moisture_arr.resize(n);
    base_moisture_arr.resize(n);
    temp_arr.resize(n);
    temp_baseline_arr.resize(n);
    temp_30d_arr.resize(n);
    temp_365d_arr.resize(n);
    temp_anomaly_arr.resize(n);
    thermal_energy_arr.resize(n);
    cell_lat_norm_arr.resize(n);
    temp_baseline_year_arr.resize(n);
    snow_cover_arr.resize(n);
    terrain_arr.resize(n);
    base_terrain_arr.resize(n);
    landform_arr.resize(n);
    base_landform_arr.resize(n);
    vegetation_arr.resize(n);
    base_vegetation_arr.resize(n);
    cover_arr.resize(n);
    is_water_arr.resize(n);
    ema_initialized_arr.resize(n);

    int32_t *Q = q_arr.ptrw();
    int32_t *R = r_arr.ptrw();
    int32_t *S = s_arr.ptrw();
    float *E = elevation_arr.ptrw();
    float *M = moisture_arr.ptrw();
    float *BM = base_moisture_arr.ptrw();
    float *T = temp_arr.ptrw();
    float *TB = temp_baseline_arr.ptrw();
    float *T30 = temp_30d_arr.ptrw();
    float *T365 = temp_365d_arr.ptrw();
    float *TA = temp_anomaly_arr.ptrw();
    float *TH = thermal_energy_arr.ptrw();
    float *LAT = cell_lat_norm_arr.ptrw();
    float *TY = temp_baseline_year_arr.ptrw();
    float *SNOW = snow_cover_arr.ptrw();
    uint8_t *TERR = terrain_arr.ptrw();
    uint8_t *BTERR = base_terrain_arr.ptrw();
    uint8_t *LF = landform_arr.ptrw();
    uint8_t *BLF = base_landform_arr.ptrw();
    uint8_t *VEG = vegetation_arr.ptrw();
    uint8_t *BVEG = base_vegetation_arr.ptrw();
    uint8_t *COV = cover_arr.ptrw();
    uint8_t *IW = is_water_arr.ptrw();
    uint8_t *EMA = ema_initialized_arr.ptrw();

    const auto t0 = std::chrono::high_resolution_clock::now();
    const double inv_w = 1.0 / double(std::max(width - 1, 1));
    const double inv_h = 1.0 / double(std::max(height - 1, 1));

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

    // [cylindrical-earth-daylight] 圆柱噪声采样 helper：把经度轴(nx∈[0,1))映射到半径
    // scale/TWO_PI 的圆环 (cosθ,sinθ)，纬度走 z 轴线性。圆周长 = scale → 与原 nx*scale
    // 特征尺度一致；col=0 与 col=width 处 (cosθ,sinθ) 严格相等 → 海拔/气候/湖等噪声东西无缝。
    // PK_TWO_PI 为文件作用域常量（见上方定义）→ 无捕获 lambda 可直接用、不触发 MSVC C3493。
    auto cyl_noise = [](FastNoiseLite *nz, double ct, double st, double ny, double scale,
                        double ox, double oy, double oz) -> double {
        const double rc = scale / PK_TWO_PI;
        return double(nz->get_noise_3d(ct * rc + ox, st * rc + oy, ny * scale + oz));
    };

    // ── 1. coords + elevation —— 镜像 _compute_elevation（行主序，与 all_cells() 一致）──
    for (int row = 0; row < height; ++row) {
        for (int col = 0; col < width; ++col) {
            const int idx = row * width + col;
            const int q = col - ((row - (row & 1)) / 2);
            Q[idx] = q;
            R[idx] = row;
            S[idx] = -q - row;
            LAT[idx] = float(double(row) * inv_h);

            const double nx = double(col) * inv_w;   // [0,1] 含端点：仅保留给 tectonic_elev_at（默认关闭）
            (void)nx;                                 // [bimodal] 双峰路径不用 nx（tectonic 旁路）
            const double ny = double(row) * inv_h;
            // [cylindrical-earth-daylight] 经度坐标 period=width（lon=col/width∈[0,1)）：col=0 与
            // col=width-1 仅差 1 角步、相邻而非重合（若用 col/(width-1) 会让首尾列采到同一角→"双列"接缝）。
            const double lon = double(col) / double(width);
            const double theta = PK_TWO_PI * lon;   // 经度角（周期）→ 东西无缝
            const double ct = std::cos(theta);
            const double st = std::sin(theta);
            const double dist_perturb = cyl_noise(height_warp.ptr(), ct, st, ny, 250.0, 11.3, -7.1, 0.0) * continent_warp_amp;
            // [bimodal-hypsography 2026-06-26] 大陆距离场（不再 pow → 当 mask 种子而非穹顶）。
            double dist_field = 0.0;
            for (const Center &c : centers) {
                // [cylindrical-earth-daylight] 经度环绕最短距离 → 大陆可跨接缝、东西无缝。
                double dx = std::fabs(lon - c.x);
                if (dx > 0.5) dx = 1.0 - dx;
                const double dy = ny - c.y;
                const double d = std::sqrt(dx * dx + dy * dy) + dist_perturb;
                const double df = pk_clamp01(1.0 - d / c.radius);
                if (df > dist_field) dist_field = df;
            }
            // [cylindrical-earth-daylight] 大陆形状 fBm（domain-warp，圆柱无缝）。
            const double rc200 = 200.0 / PK_TWO_PI;
            const double cx = ct * rc200;
            const double cy = st * rc200;
            const double cz = ny * 200.0;
            const double u_warp = double(height_warp->get_noise_3d(cx + 11.3, cy - 7.1, cz)) * 35.0;
            const double v_warp = double(height_warp->get_noise_3d(cx - 23.7, cy + 41.5, cz)) * 35.0;
            const double c1 = double(height_noise->get_noise_3d(cx + u_warp, cy + v_warp, cz));
            const double c2 = double(detail_noise->get_noise_3d(cx * 1.7 + u_warp, cy * 1.7 + v_warp, cz * 1.7));
            const double cont_noise = ((c1 * 0.70 + c2 * 0.30) + 1.0) * 0.5;
            const double offshore_raw = cyl_noise(detail_noise.ptr(), ct, st, ny, 900.0, -333.0, 217.0, 0.0);
            const double offshore = std::pow(std::max(offshore_raw - 0.55, 0.0), 1.5) * offshore_amp;  // 近海岛屿
            const double macro = cyl_noise(height_noise.ptr(), ct, st, ny, 95.0, 701.0, -419.0, 0.0);   // 大尺度起伏
            // 极地纬度衰减（双峰下用于降低极地大陆性；旧路径下仍用于减高程）。
            const double edge_dy = std::fabs(ny - 0.5) * 2.0;
            const double edge_perturb = cyl_noise(height_warp.ptr(), ct, st, ny, 150.0, 199.0, -73.0, 0.0) * 0.38;
            const double edge_t = pk_smoothstep(edge_falloff_start, edge_falloff_end, edge_dy + edge_perturb);

            double e_out;
            if (PK_BIMODAL_ENABLED) {
                // ── 双峰地台模型：大陆性 mask → 平坦大陆地台 / 平坦深海平原 + 陡大陆坡折 + 造山带 ──
                double cont = dist_field * PK_CONT_RADIAL_W + (cont_noise - 0.5) * PK_CONT_NOISE_W + offshore;
                cont *= (1.0 - edge_t * PK_POLAR_OCEAN);   // 极地偏海/冰盖
                const double C = pk_smoothstep(PK_CONT_THRESH - PK_CONT_MARGIN,
                                               PK_CONT_THRESH + PK_CONT_MARGIN, cont);  // 锐化→陡坡折
                // 造山带：ridged(1-|n|，成脉) × 低频 belt(成带) → 成脉山系；仅陆地(随 C)。
                const double ro1 = cyl_noise(height_noise.ptr(), ct, st, ny, 115.0, 313.0, -271.0, 0.0);
                const double ro2 = cyl_noise(detail_noise.ptr(), ct, st, ny, 57.0, -191.0, 421.0, 0.0);
                double ridge = (1.0 - std::fabs(ro1)) * 0.7 + (1.0 - std::fabs(ro2)) * 0.3;
                ridge = pk_clamp01(ridge);
                const double belt_n = cyl_noise(detail_noise.ptr(), ct, st, ny, 70.0, 137.0, -91.0, 0.0);
                const double belt = pk_smoothstep(PK_OROG_BELT_LO, PK_OROG_BELT_HI, (belt_n + 1.0) * 0.5);
                const double orogeny = std::pow(ridge, PK_OROG_SHARP) * belt * PK_OROGENY_AMP;
                // 合成：海岸线定在 C=0.5。陆地从海岸(sea)抬到内陆平台(含造山) → 内陆平坦 + 海岸上坡(海岸法线)；
                // 水侧仅占位(确保 E<sea)，真实深度由下面 #3 距岸 BFS 重塑出大陆架→坡→深渊。跳过 min/max normalize。
                const double platform = PK_PLATFORM_H + macro * PK_PLATFORM_UNDULATE + orogeny;
                if (C >= 0.5) {
                    const double lt = (C - 0.5) * 2.0;          // 0=海岸 → 1=内陆（margin 内成海岸坡，之后平台）
                    e_out = sea_level + lt * platform;
                } else {
                    // [water-tuning 2026-06-26] 此处仅产出"水侧占位深度"(确保 E<sea_level，供 dist_ocean
                    // 与海陆 mask 正确播种)；最终洋底深度由上文 dist_ocean 之后的"距岸距离驱动洋底深度"
                    // BFS 统一重写。凹幂律(p=0.62)使占位本身也呈架→坡过渡，BFS 关闭时仍是合理回退。
                    const double wt = std::pow(pk_clamp01((0.5 - C) * 2.0), 0.62);          // 0=海岸 → 1=开阔洋
                    e_out = sea_level - 0.02 - wt * (sea_level * PK_OCEAN_DEPTH_FRAC);
                }
            } else {
                // ── 旧径向穹顶（回退路径；配合 PK_HYPSO Layer A/B 与 #3 BFS 的开关）──
                const double noise_01 = cont_noise;
                const double meso = (cyl_noise(detail_noise.ptr(), ct, st, ny, 400.0, 137.0, -91.0, 0.0) + 1.0) * 0.5;
                const double coast = cyl_noise(height_noise.ptr(), ct, st, ny, 80.0, 500.0, 500.0, 0.0) * 0.06;
                const double df15 = std::pow(dist_field, 1.5);
                double raw = df15 * (dist_field_weight + noise_01 * noise_weight + meso * meso_weight)
                    + coast + offshore + macro * df15 * macro_relief_weight;
                raw -= edge_t * edge_falloff_depth;
                e_out = raw;
            }
            E[idx] = float(pk_clamp01(e_out));
        }
    }

    // ── 2. normalize —— 镜像 _normalize_elevation ──
    // [bimodal 2026-06-26] 双峰模型已锚定 sea_level 直接产出 [0,1]；min/max 拉伸会移动海平面位置 →
    // 双峰路径下跳过，仅旧径向路径(PK_BIMODAL_ENABLED=false)才归一化。
    if (!PK_BIMODAL_ENABLED) {
        double min_e = std::numeric_limits<double>::infinity();
        double max_e = -std::numeric_limits<double>::infinity();
        for (int i = 0; i < n; ++i) {
            const double e = double(E[i]);
            if (e < min_e) min_e = e;
            if (e > max_e) max_e = e;
        }
        const double range_e = max_e - min_e;
        if (range_e >= 0.001) {
            const double inv_range = 1.0 / range_e;
            for (int i = 0; i < n; ++i) E[i] = float((double(E[i]) - min_e) * inv_range);
        }
    }

    // ── 2.55 [ocean-bathymetry 2026-06-25] 海洋深度自然化（离岸越远越深）─────────────
    // 现状根因：海洋 raw 的起伏项全乘 dist_field，离岸即趋 0，海底没有任何"拉深"机制；唯一向下的
    // 力量是极地 edge_falloff → min/max 归一化后只有极地深海、其余全挤在 sea_level 下方(浅海)。此处
    // 在 normalize 之后、侵蚀/分类之前，对 below-sea 段按"距岸 hex 距离"重塑海底：近岸大陆架(浅)→
    // 远海深渊(深)，叠低频盆地噪声造海沟/海岭。锚定 sea_level：陆地(E>=sea)完全不动 → 海陆边界/normalize
    // 的 land 段不破坏。下游 DEEP_OCEAN/OCEAN 分类、距海气候、水面深浅色全部看到自然海底（远海变深蓝、
    // 浅海大陆架，符合预期）。base pass 已 100% C++（生成 fallback 已删）→ 无 GDScript 镜像。
    // [bimodal 2026-06-26] 双峰模型负责陆地平台 + 海陆 mask；本 BFS 作为"海洋这一半"的科学剖面：
    // 给回大陆架(近海浅水)→大陆坡→深海平原的距岸渐变（不靠 cont 值，避免被海岸线噪声打散）。常开。
    {
        constexpr double PK_OCEAN_SHELF_CELLS = 3.0;    // 大陆架宽度(hex)：近岸浅水带(近海/reef/kelp)
        constexpr double PK_OCEAN_DEEP_CELLS  = 10.0;   // 到此距离(hex)达深渊
        constexpr double PK_OCEAN_SHELF_D01   = 0.06;   // 大陆架归一深度（浅，落在 COAST 带→近海可见）
        constexpr double PK_OCEAN_ABYSS_FRAC  = 0.92;   // 深渊最大深度占 sea_level 的比例
        constexpr double PK_OCEAN_BASIN_AMP   = 0.30;   // 低频盆地噪声幅度(海沟/海岭，仅深水区生效)
        const double sea = sea_level;
        if (sea > 1e-4) {
            // 多源 BFS：所有陆地格(E>=sea)为源(dist=0)，向海洋格逐 hex 扩散 → 每个海洋格得到距岸距离。
            std::vector<int32_t> cdist(size_t(n), -1);
            std::vector<int32_t> bfsq;
            bfsq.reserve(size_t(n));
            for (int i = 0; i < n; ++i) {
                if (double(E[i]) >= sea) { cdist[i] = 0; bfsq.push_back(i); }
            }
            size_t head = 0;
            while (head < bfsq.size()) {
                const int ci = bfsq[head++];
                const int cd = cdist[ci];
                const int cq = Q[ci], cr = R[ci];
                for (int k = 0; k < 6; ++k) {
                    const int ni = index_for_qr(cq + DQ[k], cr + DR[k]);
                    if (ni < 0 || cdist[ni] >= 0) continue;
                    cdist[ni] = cd + 1;
                    bfsq.push_back(ni);
                }
            }
            const double max_depth = sea * PK_OCEAN_ABYSS_FRAC;
            const double inv_ramp = 1.0 / std::max(1.0, PK_OCEAN_DEEP_CELLS - PK_OCEAN_SHELF_CELLS);
            for (int i = 0; i < n; ++i) {
                if (double(E[i]) >= sea) continue;       // 陆地不动（锚定 sea_level）
                const int d = cdist[i];
                const double dist = (d < 0) ? PK_OCEAN_DEEP_CELLS : double(d);  // 全封闭内海(理论上不会)按最深兜底
                double ramp = (dist - PK_OCEAN_SHELF_CELLS) * inv_ramp;
                if (ramp < 0.0) ramp = 0.0; else if (ramp > 1.0) ramp = 1.0;
                double depth01 = PK_OCEAN_SHELF_D01 + (1.0 - PK_OCEAN_SHELF_D01) * pk_smoothstep(0.0, 1.0, ramp);
                // 低频盆地噪声(海沟/海岭)：仅在深水(× ramp)出现，避免扰动大陆架与海岸线判定。
                const int row = i / width;
                const int col = i % width;
                const double ny = double(row) * inv_h;
                const double th = PK_TWO_PI * (double(col) / double(width));
                const double basin = cyl_noise(height_noise.ptr(), std::cos(th), std::sin(th), ny, 120.0, -571.0, 311.0, 0.0);
                depth01 += basin * PK_OCEAN_BASIN_AMP * ramp;
                if (depth01 < 0.0) depth01 = 0.0; else if (depth01 > 1.0) depth01 = 1.0;
                double e_new = sea - depth01 * max_depth;
                if (e_new < 0.0) e_new = 0.0; else if (e_new >= sea) e_new = sea - 1e-4;
                E[i] = float(e_new);
            }
        }
    }

    // ── 2.5 水力液滴侵蚀 + 热力坍塌（terrain-overhaul Phase 1）────────────────
    // 移植 map_baker.gd::_hydraulic_erosion 液滴模型，改为作用于 cell 海拔(hex 6 邻域最陡
    // 下降)，置于 normalize 之后、地形决策之前。产出河谷/山脊线/冲积平原，让地貌更连续、河网
    // 更自然；热力坍塌(talus 角)软化过陡坡。迭代上限参数化以控生成耗时(<几百 ms@15000 格)。
    {
        // ── 2.4 Stream-Power 河流侵蚀 (Cordonnier et al. 2016；隐式、无条件稳定) ──────
        // 学术界标准做法：构造抬升 + 河流(stream-power)侵蚀达准平衡 → 自然产生连贯山脉脊线、
        // 流域、树状河网。每轮：priority-flood 求填洼后的下游指针+处理序(全程排水) → 汇水面积 A
        // 沿下游累积 → 隐式 SPL 下切：
        //     E[i] = (E[i] + U[i] + C·E[down]) / (1+C),   C = K·(A/Ā)^m
        // U=抬升回补(维持山体不被侵平)。proc 升序(下游先)⇒更新 E[i] 时 E[down] 本轮已就绪，
        // 且 E[i]≥E[down] 恒成立(加权平均) ⇒ 不倒灌、不发散。产出：高汇水处下切成树状河谷
        // (长干流+支流、Strahler↑)、低汇水脊线保留(宏观山脉/高原读得出)、杂散闭流洼地被抬填
        // (减少内陆碎水，并修复运行时"盆地凭空灌满水")。性能：O(n log n)×iters，15000格几十ms。
        // 一键回退：spl_iters=0（退回随机液滴侵蚀）。
        const int spl_iters = std::max(0, geti(profile, "spl_iters", 14));
        const double spl_k = std::max(0.0, getd(profile, "spl_erodibility", 1.2));
        const double spl_m = getd(profile, "spl_area_exp", 0.45);
        const double spl_uplift_rate = std::max(0.0, getd(profile, "spl_uplift_rate", 0.10));
        if (spl_iters > 0) {
            std::vector<float> relief0(size_t(n), 0.0f);
            for (int i = 0; i < n; ++i) relief0[size_t(i)] = std::max(0.0f, float(double(E[i]) - sea_level));
            std::vector<float> filled(size_t(n), 0.0f);
            std::vector<int32_t> down(size_t(n), -1);
            std::vector<int> proc; proc.reserve(size_t(n));
            std::vector<uint8_t> pf_seen(size_t(n), 0);
            std::vector<double> area(size_t(n), 0.0);
            for (int it = 0; it < spl_iters; ++it) {
                std::fill(pf_seen.begin(), pf_seen.end(), uint8_t(0));
                for (int i = 0; i < n; ++i) down[size_t(i)] = -1;
                proc.clear();
                std::priority_queue<std::pair<float, int>, std::vector<std::pair<float, int>>,
                                    std::greater<std::pair<float, int>>> pq;
                for (int row = 0; row < height; ++row) {
                    for (int col = 0; col < width; ++col) {
                        // [cylindrical-earth-daylight] 仅南北极(row)作排水基准；东西经度环绕由 index_for_qr 在 flood 扩散时处理。
                        if (row != 0 && row != height - 1) continue;
                        const int i = row * width + col;
                        pf_seen[size_t(i)] = 1; filled[size_t(i)] = E[i];
                        pq.push(std::make_pair(E[i], i));
                    }
                }
                while (!pq.empty()) {
                    const std::pair<float, int> top = pq.top(); pq.pop();
                    const int cur = top.second;
                    if (top.first > filled[size_t(cur)] + 1e-6f) continue;
                    proc.push_back(cur);
                    for (int d = 0; d < 6; ++d) {
                        const int ni = index_for_qr(Q[cur] + DQ[d], R[cur] + DR[d]);
                        if (ni < 0 || pf_seen[size_t(ni)]) continue;
                        pf_seen[size_t(ni)] = 1;
                        const float sp = std::max(E[ni], top.first);
                        filled[size_t(ni)] = sp; down[size_t(ni)] = cur;
                        pq.push(std::make_pair(sp, ni));
                    }
                }
                for (int i = 0; i < n; ++i) area[size_t(i)] = 1.0;
                for (int k = int(proc.size()) - 1; k >= 0; --k) {
                    const int i = proc[k]; const int d = down[size_t(i)];
                    if (d >= 0) area[size_t(d)] += area[size_t(i)];
                }
                double area_mean = 0.0;
                for (int i = 0; i < n; ++i) area_mean += area[size_t(i)];
                const double inv_area_mean = 1.0 / std::max(1.0, area_mean / double(std::max(1, n)));
                for (int k = 0; k < int(proc.size()); ++k) {
                    const int i = proc[k]; const int d = down[size_t(i)];
                    if (d < 0) continue;
                    if (double(E[i]) < sea_level) continue; // 海洋不侵蚀
                    const double C = spl_k * std::pow(area[size_t(i)] * inv_area_mean, spl_m);
                    const double U = spl_uplift_rate * double(relief0[size_t(i)]);
                    double z = (double(E[i]) + U + C * double(E[d])) / (1.0 + C);
                    if (z < double(E[d])) z = double(E[d]);
                    E[i] = float(z);
                }
            }
            for (int i = 0; i < n; ++i) {
                double e = double(E[i]);
                E[i] = float(e < 0.0 ? 0.0 : (e > 1.0 ? 1.0 : e));
            }
        }

        const double erosion_droplet_factor = std::max(0.0, getd(profile, "erosion_droplet_factor", 0.6)); // 2026-06-19 回退到 0.6（河谷/沟壑下切，助宏观地貌可读）
        // SPL 开启时跳过随机液滴侵蚀，避免双重侵蚀互相打架（SPL 的下切更连贯）。
        const int erosion_droplets = (spl_iters > 0) ? 0 : std::max(0, int(double(n) * erosion_droplet_factor));
        const int erosion_lifetime = std::max(1, geti(profile, "erosion_max_lifetime", 30));
        const double ero_capacity = getd(profile, "erosion_capacity", 4.0);
        const double ero_deposit = pk_clamp01(getd(profile, "erosion_deposit_rate", 0.3));
        const double ero_erode = pk_clamp01(getd(profile, "erosion_erode_rate", 0.3));
        const double ero_evap = pk_clamp01(getd(profile, "erosion_evaporation", 0.02));
        const double ero_gravity = getd(profile, "erosion_gravity", 4.0);
        const double ero_min_slope = getd(profile, "erosion_min_slope", 0.01);
        const int thermal_iters = std::max(0, geti(profile, "erosion_thermal_iters", 2));
        const double thermal_talus = std::max(0.001, getd(profile, "erosion_thermal_talus", 0.04));
        const double thermal_rate = pk_clamp01(getd(profile, "erosion_thermal_rate", 0.5));

        if (erosion_droplets > 0) {
            Ref<RandomNumberGenerator> erng;  erng.instantiate();
            if (erng.is_valid()) erng->set_seed(uint64_t(seed) + 5500ull);
            for (int drop = 0; drop < erosion_droplets; ++drop) {
                int pos = erng.is_valid() ? int(erng->randi_range(0, n - 1)) : (drop % n);
                if (double(E[pos]) < sea_level) continue; // 仅从陆地起步
                double water = 1.0, speed = 1.0, sediment = 0.0;
                for (int life = 0; life < erosion_lifetime; ++life) {
                    int best = -1; double best_e = double(E[pos]);
                    for (int d = 0; d < 6; ++d) {
                        const int ni = index_for_qr(Q[pos] + DQ[d], R[pos] + DR[d]);
                        if (ni < 0) continue;
                        if (double(E[ni]) < best_e) { best_e = double(E[ni]); best = ni; }
                    }
                    if (best < 0) { // 局部洼地 → 全部沉积
                        E[pos] = float(double(E[pos]) + sediment);
                        break;
                    }
                    const double dh = double(E[best]) - double(E[pos]); // <0 下坡
                    const double capacity = std::max(-dh, ero_min_slope) * speed * water * ero_capacity;
                    if (sediment > capacity) {
                        const double dep = (sediment - capacity) * ero_deposit;
                        E[pos] = float(double(E[pos]) + dep);
                        sediment -= dep;
                    } else {
                        const double ero = std::min((capacity - sediment) * ero_erode, -dh);
                        if (ero > 0.0) {
                            E[pos] = float(double(E[pos]) - ero);
                            sediment += ero;
                        }
                    }
                    speed = std::sqrt(std::max(speed * speed + (-dh) * ero_gravity, 0.0));
                    water *= (1.0 - ero_evap);
                    pos = best;
                    if (double(E[pos]) < sea_level) { // 入海 → 沉积(冲积/三角洲)
                        E[pos] = float(double(E[pos]) + sediment * 0.5);
                        break;
                    }
                }
            }
        }
        // 热力坍塌：超 talus 角的坡差向最低邻居转移部分物质，软化陡崖。
        for (int it = 0; it < thermal_iters; ++it) {
            for (int i = 0; i < n; ++i) {
                if (double(E[i]) < sea_level) continue;
                int low = -1; double low_e = double(E[i]);
                for (int d = 0; d < 6; ++d) {
                    const int ni = index_for_qr(Q[i] + DQ[d], R[i] + DR[d]);
                    if (ni < 0) continue;
                    if (double(E[ni]) < low_e) { low_e = double(E[ni]); low = ni; }
                }
                if (low < 0) continue;
                const double diff = double(E[i]) - low_e;
                if (diff > thermal_talus) {
                    const double move = (diff - thermal_talus) * 0.5 * thermal_rate;
                    E[i] = float(double(E[i]) - move);
                    E[low] = float(double(E[low]) + move);
                }
            }
        }
        for (int i = 0; i < n; ++i) {
            double e = double(E[i]);
            if (e < 0.0) e = 0.0; else if (e > 1.0) e = 1.0;
            E[i] = float(e);
        }
    }

    // ── 2.6 [P1 hypsometric Layer B 2026-06-25] 高程分段重映射（粗，定结构）──────────────
    // 置于 normalize + 侵蚀(SPL/droplet/thermal)之后、湖判/分类之前：对陆地段(E>sea_level)按
    // land_h 应用单调三段曲线——低地压平(真平原)、中段台地、高段陡升(拉开起伏)。锚定 sea_level：
    // below-sea(海洋/湖种)保持不变，海陆边界与 ocean/coast 分类不被破坏；下游湖判/气候/分类全部
    // 看到重塑后的 E。单调 → 不倒置高程序；置于侵蚀之后 → 保留河谷网络与台地保形。Layer A(bake)
    // 在此基础上做 per-pixel 小 mix 残差精修。曲线与 map_baker.gd / Layer A 同源。
    // [bimodal 2026-06-26] 双峰地台模型已直接产出平坦地台，P1 压平被吸收 → 默认关闭。
    if (!PK_BIMODAL_ENABLED) {
        const PkHypsoCurve hypso = pk_make_hypso_curve();
        const double sea = sea_level;
        const double above = 1.0 - sea;
        const double inv_above = (above > 1e-6) ? (1.0 / above) : 0.0;
        if (inv_above > 0.0) {
            for (int i = 0; i < n; ++i) {
                const double e = double(E[i]);
                if (e <= sea) continue;  // 水下不动（锚定 sea_level）
                E[i] = float(pk_hypso_remap_elev(hypso, e, sea, inv_above, above, 1.0));
            }
        }
    }

    // ── 3. carve lake seeds —— 两阶段标记后统一下沉，避免同一低频湖盆内的
    // 邻接候选被先凿出的水格排斥成碎小湖。
    PackedByteArray is_lake_seed_arr;
    is_lake_seed_arr.resize(n);
    {
        uint8_t *LS = is_lake_seed_arr.ptrw();
        for (int i = 0; i < n; ++i) LS[i] = 0;
        const double sea = sea_level;
        const double w_min = lake_seed_min_interior;
        const double w_max = 1.0 - lake_seed_min_interior;
        // [湖泊多样化 2026-06-19] 每格记录目标下沉深度(0=非种子)，按噪声强度做"中心深/边缘浅"渐变。
        std::vector<float> seed_depth(size_t(n), 0.0f);
        const double small_thr = std::min(0.95, lake_seed_threshold + 0.08);  // 小湖阈值(+0.14 过严→几乎无小湖；放宽到 +0.08 让小湖成形，仍靠 pit-fill≥4 格防碎湖)
        const double warp_amp = 7.0;                                          // domain-warp 振幅(hex 单位)
        for (int row = 0; row < height; ++row) {
            for (int col = 0; col < width; ++col) {
                const int idx = row * width + col;
                if (double(E[idx]) < sea + 0.04) continue;
                const double ny = double(row) * inv_h;
                // [cylindrical-earth-daylight] 仅排除南北极附近(纬度)，东西可环绕成湖、不再排除。
                if (ny < w_min || ny > w_max) continue;
                // [cylindrical-earth-daylight] domain warp + 圆柱采样：经度走半径 width/TWO_PI
                // 的圆环(arc/col≈1 hex，尺度与原 Q 一致)，纬度走 z；经度 period=width（col/width）
                // 使 col=0 与 col=width-1 相邻不重合 → 湖盆可跨接缝、东西无缝。经度 warp 经 Δθ 施加。
                const double l_theta = PK_TWO_PI * (double(col) / double(width));
                const double l_rc = double(width) / PK_TWO_PI;
                const double lcx = std::cos(l_theta) * l_rc;
                const double lcy = std::sin(l_theta) * l_rc;
                const double lz = double(row);
                const double warp_lon = double(lake_noise_small->get_noise_3d(lcx + 211.0, lcy - 77.0, lz)) * warp_amp;
                const double warp_lat = double(lake_noise_small->get_noise_3d(lcx - 53.0, lcy + 169.0, lz)) * warp_amp;
                const double th2 = l_theta + warp_lon / l_rc;   // 经度方向 warp（保持周期）
                const double wcx = std::cos(th2) * l_rc;
                const double wcy = std::sin(th2) * l_rc;
                const double wz = lz + warp_lat;                // 纬度方向 warp
                const double n_large = double(lake_noise->get_noise_3d(wcx, wcy, wz));
                const double n_small = double(lake_noise_small->get_noise_3d(wcx, wcy, wz));
                double strength = -1.0;  // <0 表示非种子
                if (n_large >= lake_seed_threshold) {
                    // 大/中湖盆：强度=超阈幅度→噪声峰(湖心)深、近阈值(湖缘)浅
                    strength = (n_large - lake_seed_threshold) / std::max(1e-3, 1.0 - lake_seed_threshold);
                } else if (n_small >= small_thr) {
                    // 小湖点：整体更浅(0.35 缩放)，避免与大湖同深
                    strength = 0.35 * (n_small - small_thr) / std::max(1e-3, 1.0 - small_thr);
                }
                if (strength < 0.0) continue;
                bool has_water_nb = false;
                for (int d = 0; d < 6; ++d) {
                    const int ni = index_for_qr(Q[idx] + DQ[d], R[idx] + DR[d]);
                    if (ni >= 0 && double(E[ni]) < sea) { has_water_nb = true; break; }
                }
                if (has_water_nb) continue;
                LS[idx] = 1;
                const double sc = (strength > 1.0) ? 1.0 : strength;                    // clamp01
                seed_depth[size_t(idx)] = float(lake_seed_depth * (0.55 + 0.95 * sc));  // 0.55x~1.5x 深度梯度
            }
        }
        for (int i = 0; i < n; ++i) {
            if (LS[i] != 0) E[i] = float(sea - double(seed_depth[size_t(i)]));
        }
    }

    // ── 4. smooth pit depressions —— 镜像 _smooth_pit_depressions（就地，迭代至稳定）──
    for (int it = 0; it < pit_fill_max_iters; ++it) {
        bool changed = false;
        for (int row = 0; row < height; ++row) {
            for (int col = 0; col < width; ++col) {
                const int idx = row * width + col;
                if (double(E[idx]) < sea_level) continue;
                double lowest_nb = std::numeric_limits<double>::infinity();
                for (int d = 0; d < 6; ++d) {
                    const int ni = index_for_qr(Q[idx] + DQ[d], R[idx] + DR[d]);
                    if (ni < 0) continue;
                    const double e = double(E[ni]);
                    if (e < lowest_nb) lowest_nb = e;
                }
                if (lowest_nb < std::numeric_limits<double>::infinity() && double(E[idx]) <= lowest_nb) {
                    E[idx] = float(lowest_nb + 0.001);
                    changed = true;
                }
            }
        }
        if (!changed) break;
    }

    // ── 5. mountain ridges —— 镜像 _apply_mountain_ridges（就地，slope 读当前 E）──
    if (ridge_boost_amp > 0.0) {
        const double denom_lf = std::max(1.0 - sea_level, 0.001);
        for (int row = 0; row < height; ++row) {
            for (int col = 0; col < width; ++col) {
                const int idx = row * width + col;
                if (double(E[idx]) < sea_level) continue;
                const double ny2 = double(row) * inv_h;
                // [cylindrical-earth-daylight] 山脊噪声圆柱采样 → 山脉跨接缝东西无缝；
                // 经度 period=width（col/width），col=0 与 col=width-1 相邻不重合。
                const double th2 = PK_TWO_PI * (double(col) / double(width));
                const double ct2 = std::cos(th2);
                const double st2 = std::sin(th2);
                const double ridge_a = 1.0 - std::fabs(cyl_noise(detail_noise.ptr(), ct2, st2, ny2, 180.0, 71.3, -33.7, 0.0));
                const double ridge_b = 1.0 - std::fabs(cyl_noise(detail_noise.ptr(), ct2, st2, ny2, 220.0, -50.7, 91.1, 0.0));
                const double ridge_signal = std::pow(std::max(ridge_a, ridge_b), 1.4);
                double lowest = double(E[idx]);
                for (int d = 0; d < 6; ++d) {
                    const int ni = index_for_qr(Q[idx] + DQ[d], R[idx] + DR[d]);
                    if (ni >= 0 && double(E[ni]) < lowest) lowest = double(E[ni]);
                }
                const double slope = double(E[idx]) - lowest;
                double slope_gate = slope * 8.0;
                if (slope_gate < 0.30) slope_gate = 0.30;
                else if (slope_gate > 1.0) slope_gate = 1.0;
                double land_factor = (double(E[idx]) - sea_level) / denom_lf;
                land_factor = std::pow(land_factor, 1.5);
                const double addition = ridge_signal * land_factor * slope_gate * ridge_boost_amp;
                double raw_post = double(E[idx]) + addition;
                const double soft_max = 0.78;
                const double land_elev_cap = 0.93;
                if (raw_post > soft_max) {
                    const double excess = raw_post - soft_max;
                    raw_post = soft_max + (land_elev_cap - soft_max) * (1.0 - std::exp(-excess * 3.0));
                }
                if (raw_post < 0.0) raw_post = 0.0;
                else if (raw_post > land_elev_cap) raw_post = land_elev_cap;
                E[idx] = float(raw_post);
            }
        }
    }

    // ── 5b. 小型内陆洼地高程回填（消除"零碎湖"根因）────────────────────────
    // 实证(CSV 20260619_032716)：内陆遍布 ~96 个 1~5 格、高程恒为 sea-lake_seed_depth
    // 的 below-sea 洼地(湖泊种子散点)，后续被判成 COAST → 满屏"零碎湖"，且其原始 E<sea
    // 在运行时被重新判水 → 用户所述"前几 tick 干盆地、之后突然灌满水"(issue#1)。
    // 根治：在 E 仍可写的 base pass，按【高程连通性】找出未与主海洋相连的 below-sea 连通块——
    // 面积 < lake_min 的小块直接抬到 sea+eps(永久成陆，下游任何 pass 都不会再把它判成水)；
    // >= lake_min 的大盆地保留(在 post pass 自然成内陆湖 LAKE)。阈值与 post pass 的
    // hydro_lake_min_cells 同源，保证 base/post 判定一致、不再有"漏网孤立水"。
    {
        const double sea = sea_level;
        const int lake_min = std::max(1, int(getd(profile, "hydro_lake_min_cells", 8.0)));
        std::vector<uint8_t> ocean_e(size_t(n), 0);
        std::vector<int> obfs;
        obfs.reserve(size_t(n));
        for (int row = 0; row < height; ++row) {
            for (int col = 0; col < width; ++col) {
                const int idx = row * width + col;
                if (double(E[idx]) >= sea) continue;
                if (row == 0 || row == height - 1) {  // [cylindrical] 仅南北极作海洋种子；东西经度环绕由 index_for_qr 处理
                    ocean_e[size_t(idx)] = 1;
                    obfs.push_back(idx);
                }
            }
        }
        for (size_t bi = 0; bi < obfs.size(); ++bi) {
            const int cur = obfs[bi];
            for (int d = 0; d < 6; ++d) {
                const int ni = index_for_qr(Q[cur] + DQ[d], R[cur] + DR[d]);
                if (ni < 0 || ocean_e[size_t(ni)]) continue;
                if (double(E[ni]) >= sea) continue;
                ocean_e[size_t(ni)] = 1;
                obfs.push_back(ni);
            }
        }
        std::vector<uint8_t> pit_seen(size_t(n), 0);
        std::vector<int> pit_comp;
        pit_comp.reserve(256);
        int pit_filled = 0;
        // [湖泊多样化 2026-06-19] 含 lake_seed 的洼地放宽到 ≥4 格即保留为小湖；非种子的噪声碎坑
        // 仍按 lake_min(8) 填平 → 既出现小湖大小层次，又不让随机碎湖回归(沿用之前碎湖修复)。
        const uint8_t *LS_ptr = is_lake_seed_arr.ptr();
        const int seed_keep_min = std::min(lake_min, 4);
        for (int s = 0; s < n; ++s) {
            if (double(E[s]) >= sea || ocean_e[size_t(s)] || pit_seen[size_t(s)]) continue;
            pit_comp.clear();
            pit_comp.push_back(s);
            pit_seen[size_t(s)] = 1;
            // 同时记录该洼地的"溢出口"高度 = 最低的陆地(E>=sea)边界邻居。
            double spill_e = std::numeric_limits<double>::infinity();
            bool comp_has_seed = (LS_ptr[size_t(s)] != 0);
            for (size_t qi = 0; qi < pit_comp.size(); ++qi) {
                const int cur = pit_comp[qi];
                for (int d = 0; d < 6; ++d) {
                    const int ni = index_for_qr(Q[cur] + DQ[d], R[cur] + DR[d]);
                    if (ni < 0) continue;
                    if (double(E[ni]) >= sea) {            // 陆地边界 = 出口候选
                        if (double(E[ni]) < spill_e) spill_e = double(E[ni]);
                        continue;
                    }
                    if (pit_seen[size_t(ni)] || ocean_e[size_t(ni)]) continue;
                    pit_seen[size_t(ni)] = 1;
                    pit_comp.push_back(ni);
                    if (LS_ptr[size_t(ni)] != 0) comp_has_seed = true;
                }
            }
            const int keep_min = comp_has_seed ? seed_keep_min : lake_min;
            if (int(pit_comp.size()) < keep_min) {
                // [空洞平滑 2026-06-19] 旧版统一压到 sea+0.012 的固定低值 → 内陆遍布比周围明显
                // 低一截的"小坑斑块"(用户反馈：空洞太小、地面碎)。改为回填到溢出口高度(略低
                // 0.012)，使原洼地与最近陆地出口齐平、平滑融入周围地形，不再读作突兀低斑。
                double fill_e = sea + 0.012;
                if (std::isfinite(spill_e)) fill_e = std::max(sea + 0.012, spill_e - 0.012);
                for (int v : pit_comp) E[v] = float(fill_e);
                pit_filled += int(pit_comp.size());
            }
        }
    }

    // ── 6. 统一气候场（terrain-overhaul Phase 3）：距海距离 + 盛行风水汽输送湿度 + 初判地形 ──
    // 取代旧"噪声基底 + 单向 coastal/orographic 加湿"棘轮（该模型只增不减→陆地普遍过湿、
    // 沙漠/草原消失）。新模型：海面蒸发为水汽源，沿 wind_belt 盛行风纬向平流，过陆地按里程
    // rain-out 衰减（大陆度），迎风山坡增雨、背风自然成雨影；温度叠加海洋邻近调节。

    // 6a. 距海距离场（多源 BFS，单位=cell 步数）：elev<sea_level 的水体为源。
    std::vector<int32_t> dist_ocean(size_t(n), -1);
    {
        std::vector<int> bfsq;
        bfsq.reserve(size_t(n));
        for (int i = 0; i < n; ++i) {
            if (double(E[i]) < sea_level) { dist_ocean[size_t(i)] = 0; bfsq.push_back(i); }
        }
        for (size_t qi = 0; qi < bfsq.size(); ++qi) {
            const int cur = bfsq[qi];
            const int nd = dist_ocean[size_t(cur)] + 1;
            for (int d = 0; d < 6; ++d) {
                const int ni = index_for_qr(Q[cur] + DQ[d], R[cur] + DR[d]);
                if (ni < 0 || dist_ocean[size_t(ni)] >= 0) continue;
                dist_ocean[size_t(ni)] = nd;
                bfsq.push_back(ni);
            }
        }
    }

    // [water-tuning 2026-06-26] 距岸距离驱动洋底深度（根治"深海消失"）──────────────────
    // 双峰模型用大陆性噪声 C 给洋底深度，在陆地铺满、缺开阔洋面的图里 wt 到不了 1 → 洋底全卡在
    // 大陆架深度（实测浅海占 99%、近海/深海 0%）。这里改为：从陆地多源 BFS 出"水格到最近陆地的
    // 步数 shore_dist"，按 shore_dist 单调加深洋底——离岸越远越深，大陆之间够宽的内海中心也能成
    // 深海平原，不再依赖随机大陆布局是否留出大洋。海岸线形状不动（海陆 mask 仍由 E<sea_level 决定），
    // 仅重写水格深度；陆地 E 不碰。深度上限沿用既有 PK_OCEAN_DEPTH_FRAC。
    {
        std::vector<int32_t> shore_dist(size_t(n), -1);
        std::vector<int> sq;
        sq.reserve(size_t(n));
        for (int i = 0; i < n; ++i) {
            if (double(E[i]) >= sea_level) { shore_dist[size_t(i)] = 0; sq.push_back(i); }  // 源=陆地
        }
        for (size_t qi = 0; qi < sq.size(); ++qi) {
            const int cur = sq[qi];
            const int nd = shore_dist[size_t(cur)] + 1;
            for (int d = 0; d < 6; ++d) {
                const int ni = index_for_qr(Q[cur] + DQ[d], R[cur] + DR[d]);
                if (ni < 0 || shore_dist[size_t(ni)] >= 0) continue;
                shore_dist[size_t(ni)] = nd;
                sq.push_back(ni);
            }
        }
        // 洋底深度剖面：shore_dist=1 紧贴海岸→大陆架浅；>=PK_SHORE_DEEP_DIST→深海平原满深度。
        constexpr int    PK_SHORE_DEEP_DIST = 7;     // 离岸几格即视为开阔洋/深海平原（调小→深海更普遍）
        constexpr double PK_SHELF_DEPTH     = 0.03;  // 大陆架最浅下潜（贴岸）
        const double max_depth = sea_level * PK_OCEAN_DEPTH_FRAC;   // 深海平原最大下潜（沿用既有常量）
        const double inv_deep  = 1.0 / double(PK_SHORE_DEEP_DIST);
        for (int i = 0; i < n; ++i) {
            if (double(E[i]) >= sea_level) continue;                 // 只重写水格
            const int sd = shore_dist[size_t(i)];
            if (sd <= 0) continue;                                   // 无陆地参照（全海）→保持双峰占位
            double t = double(sd - 1) * inv_deep;                    // 贴岸=0 … 深处=1
            if (t > 1.0) t = 1.0;
            const double ts = t * t * (3.0 - 2.0 * t);               // smoothstep：大陆架→坡→深海平原
            const double depth = PK_SHELF_DEPTH + (max_depth - PK_SHELF_DEPTH) * ts;
            E[i] = float(sea_level - depth);                         // 离岸越远越深；恒 < sea_level
        }
    }

    auto ocean_influence = [&](int i) -> double {
        const int dd = dist_ocean[size_t(i)];
        if (dd < 0) return 0.0; // 全陆地(无海)→极内陆
        return std::exp(-double(dd) / coastal_temp_scale_eff);  // [scale-fix] ×s，见 knobs 区
    };
    // 生成期温度：纬度钟形 - 海平面相对海拔惩罚，再按海洋邻近度拉向温带(沿海冬暖夏凉)。仅用于
    // 生成期地形/biome 分类；运行时温度场同样走 pk_compute_temperature(ny, elevation, sea_level)。
    auto gen_temp = [&](int i) -> double {
        const double ny = double(R[i]) * inv_h;
        const double base = pk_lat_temp_bell((ny - 0.5) * 2.0) - pk_alt_penalty(double(E[i]), sea_level);
        const double infl = ocean_influence(i);
        return pk_clamp01(base + infl * coastal_temp_moderation * (0.5 - base));
    };

    // [zonal-envelope] 行星尺度纬带降水因子：eq_dist=|ny*2-1|（0=赤道、1=极）。
    // ITCZ 辐合增雨（赤道核心 rainout 最高 ×(1+strength)）+ 中纬风暴路径次级增雨
    // + 极地干冷抑雨（冷空气含水量低）。clamp 下限保留基础降水，上限防噪声放大失控。
    // 乘在 rainout 上而非直接加减 M：辐合带快速降空水汽 → 信风带下游(副热带)自然更干。
    auto zgauss = [](double x, double c, double w) {
        const double z = (x - c) / w;
        return std::exp(-0.5 * z * z);
    };
    auto zonal_precip_factor = [&](double ny) -> double {
        const double eq_dist = std::abs(ny * 2.0 - 1.0);
        const double f = 1.0
            + itcz_wet_strength       * zgauss(eq_dist, itcz_center, itcz_width)
            + stormtrack_wet_strength * zgauss(eq_dist, stormtrack_center, stormtrack_width)
            - polar_dry_strength      * zgauss(eq_dist, 0.95, 0.15);
        return std::clamp(f, 0.20, 3.0);
    };
    // 热带海洋蒸发乘数：eq_dist≈0.08、宽 0.28 的宽热带峰（覆盖整个信风带供水区）。
    auto tropical_evap_mult = [&](double ny) -> double {
        const double eq_dist = std::abs(ny * 2.0 - 1.0);
        return 1.0 + tropical_evap_boost * zgauss(eq_dist, 0.08, 0.28);
    };
    // ITCZ 再循环/辐合的纬度包络：比 rainout 峰更宽（±约 16°），覆盖整个赤道雨林带。
    auto itcz_recycle_env = [&](double ny) -> double {
        const double eq_dist = std::abs(ny * 2.0 - 1.0);
        return zgauss(eq_dist, itcz_center, itcz_width * 1.8);
    };

    // 6b. 盛行风纬向扫描湿度场（沿 wind.x 方向 upwind→downwind 推进携带的空气湿度）。
    for (int row = 0; row < height; ++row) {
        const double ny = double(row) * inv_h;
        const PkWind2 wind = pk_wind_belt_wind_at(ny, 0.0, 0.0);
        const double zpf = zonal_precip_factor(ny);   // [zonal-envelope] 行星尺度纬带降水因子
        const double zevap = tropical_evap_mult(ny);  // [zonal-envelope] 热带海洋蒸发乘数
        const double zrecycle = itcz_recycle_strength * itcz_recycle_env(ny); // [zonal-envelope] 雨林水分再循环率
        const double zconv = itcz_convergence * itcz_recycle_env(ny);         // [zonal-envelope] ITCZ 辐合注入
        const int dir = (wind.x >= 0.0) ? 1 : -1;   // +1：风自西吹向东 → 从西向东扫
        // [cylindrical-earth-daylight] 环向(经度环绕)扫描：绕两整圈，第一圈预热让 humidity
        // 沿盛行风环流平衡，第二圈才写 M。消除旧"每行从边界 humidity=0"导致的西岸假干旱
        // 与接缝突变 → 湿度在东西方向连续、随盛行风环流闭合。
        double humidity = 0.0;
        int prev_idx = -1;
        const int start_col = (dir > 0) ? 0 : (width - 1);
        for (int step = 0; step < 2 * width; ++step) {
            const int col = (((start_col + dir * step) % width) + width) % width;
            const int idx = row * width + col;
            const bool record = (step >= width);    // 第一圈预热不写、第二圈记录
            const bool is_water = double(E[idx]) < sea_level;
            if (is_water) {
                // [zonal-envelope] 热带洋面蒸发增强（暖海供水，ITCZ/信风水汽源）
                humidity = std::min(moisture_humidity_cap, humidity + moisture_wind_evap_eff * zevap);  // [scale-fix] ÷s
                if (record) M[idx] = float(pk_clamp01(0.85 + 0.15 * humidity)); // 开放水域恒湿
            } else {
                const double upslope = (prev_idx >= 0) ? std::max(0.0, double(E[idx]) - double(E[prev_idx])) : 0.0;
                // [scale-fix] 基础降水率换每物理距离保留率；upslope 项 ΔE 自带 1/s 不缩放。
                // [zonal-envelope] 乘纬带降水因子：ITCZ/风暴路径增雨、极地抑雨。
                double rainout = (moisture_rainout_base_eff + upslope * moisture_orographic_gain) * zpf;
                if (rainout > 0.95) rainout = 0.95;
                const double precip = humidity * rainout;
                // [cylindrical-earth-daylight] 湿度抖动噪声圆柱采样 → 东西无缝；经度 period=width（col/width）
                const double mth = PK_TWO_PI * (double(col) / double(width));
                const double jitter = cyl_noise(moisture_noise.ptr(), std::cos(mth), std::sin(mth), ny, 100.0, 0.0, 0.0, 0.0) * moisture_noise_amp;
                double m = moisture_land_base + precip * moisture_precip_gain + jitter;
                if (record) M[idx] = float(pk_clamp01(m));
                // [zonal-envelope] ITCZ：降水一部分蒸散回气柱(再循环)，另有辐合流恒量注入——
                // 二者只改变气柱水量，不改变已落地的 m（m 始终按落地 precip 记账）。
                humidity -= precip * (1.0 - zrecycle);
                humidity += zconv;
                if (humidity < 0.0) humidity = 0.0;
                if (humidity > moisture_humidity_cap) humidity = moisture_humidity_cap;
                humidity *= (1.0 - moisture_continental_dry_eff); // 大陆度：内陆持续干燥化 [scale-fix] 每物理距离保留率
            }
            prev_idx = idx;
        }
    }

    // 6c. 轻度各向同性平滑，消除纬向扫描在风带切换处的行间缝隙。
    if (moisture_smooth > 0.0) {
        std::vector<float> msm(size_t(n), 0.0f);
        for (int i = 0; i < n; ++i) {
            double sum = double(M[i]);
            double wsum = 1.0;
            for (int d = 0; d < 6; ++d) {
                const int ni = index_for_qr(Q[i] + DQ[d], R[i] + DR[d]);
                if (ni < 0) continue;
                sum += double(M[ni]) * moisture_smooth;
                wsum += moisture_smooth;
            }
            msm[size_t(i)] = float(sum / wsum);
        }
        for (int i = 0; i < n; ++i) M[i] = msm[size_t(i)];
    }

    // 全量海洋地板先参与大尺度干带计算，让近海格以海洋输入为起点，而不是以噪声低值为起点。
    const double coastal_moist_floor = pk_clamp01(getd(profile, "moisture_coastal_floor", 0.42));
    for (int i = 0; i < n; ++i) {
        if (double(E[i]) < sea_level) continue;
        const int dd = dist_ocean[size_t(i)];
        if (dd <= 0) continue;
        const double prox = std::exp(-double(dd) / coastal_moist_scale_eff);
        const double floor_m = moisture_land_base + coastal_moist_floor * prox;
        if (double(M[i]) < floor_m) M[i] = float(floor_m);
    }

    // 6c++. 海岸残余保障（35%）：阻止无物理依据的贴岸极旱，
    // 但不会让海岸尺度覆盖小大陆并消灭内陆沙漠。明确雨影仍在 post-base 后置生效。
    // [zonal-envelope 2026-08-01] 顺序调整：本 guard 移到副热带干带【之前】——旧顺序
    // "floor→dry→guard" 里 guard 会把干带扣出的近岸格重新抬回 ~0.22+，全图 0 格跌破
    // 荒漠线(实测 base_moisture p10=0.234)。现在干带最后生效，guard 只挡"干带之外"
    // 的无依据贴岸极旱；干带纬度内的近岸荒漠(纳米布/阿塔卡马型)允许出现。
    constexpr double PK_COASTAL_MOIST_GUARD = 0.35;
    for (int i = 0; i < n; ++i) {
        if (double(E[i]) < sea_level) continue;
        const int dd = dist_ocean[size_t(i)];
        if (dd <= 0) continue;
        const double prox = std::exp(-double(dd) / coastal_moist_scale_eff);
        const double guard_m = moisture_land_base
            + coastal_moist_floor * PK_COASTAL_MOIST_GUARD * prox;
        if (double(M[i]) < guard_m) M[i] = float(guard_m);
    }

    // 6c+. 副热带干旱带：在南北约 20-35 度、且离海较远的陆地扣湿。
    // 这不是噪声硬塞沙漠，而是用纬度环流 + 大陆度恢复自然荒漠带。
    // [zonal-envelope] 移到海岸 guard 之后执行，使干带核心能真实跌破 0.2 荒漠线；
    // 同时 6b 的 ITCZ 辐合已抽干信风水汽，干带不再孤军奋战。
    if (subtropical_dry_strength > 0.0) {
        for (int i = 0; i < n; ++i) {
            if (double(E[i]) < sea_level) continue;
            const int dd = dist_ocean[size_t(i)];
            // [scale-fix 2026-07-30] interior 饱和距离 8 格 ×s：此前大图 8 格只是窄海岸边，
            // 整片亚热带陆地吃满扣湿 → 大陆几乎全沙漠。
            const double interior = (dd < 0) ? 1.0 : std::clamp(double(dd) / subtropical_interior_scale_eff, 0.0, 1.0);
            if (interior <= 0.0) continue;
            const double abs_lat = std::abs(double(R[i]) * inv_h * 2.0 - 1.0);
            const double z = (abs_lat - subtropical_dry_center) / subtropical_dry_width;
            const double dry_belt = std::exp(-0.5 * z * z);
            M[i] = float(pk_clamp01(double(M[i]) - subtropical_dry_strength * dry_belt * interior));
        }
    }

    // [zonal-envelope] 纬带湿度统计：赤道(eq_dist<0.2)/副热带(0.2-0.45)/中纬(0.45-0.7)/
    // 极地(>0.7) 四带陆地均值 + 副热带最低值。供 headless 回归与 CSV 审计断言"赤道湿于
    // 副热带、荒漠真实可达"，不再靠目视抽查。统计在 6d 分类之前、全部湿度 pass 之后。
    {
        double zsum[4] = {0.0, 0.0, 0.0, 0.0};
        int zcnt[4] = {0, 0, 0, 0};
        double zmin_sub = 1.0;
        for (int i = 0; i < n; ++i) {
            if (double(E[i]) < sea_level) continue;
            const double eqd = std::abs(double(R[i]) * inv_h * 2.0 - 1.0);
            const int zb = (eqd < 0.20) ? 0 : ((eqd < 0.45) ? 1 : ((eqd < 0.70) ? 2 : 3));
            zsum[zb] += double(M[i]);
            zcnt[zb] += 1;
            if (zb == 1 && double(M[i]) < zmin_sub) zmin_sub = double(M[i]);
        }
        out["zonal_moist_mean_eq"]      = (zcnt[0] > 0) ? zsum[0] / zcnt[0] : 0.0;
        out["zonal_moist_mean_subtrop"] = (zcnt[1] > 0) ? zsum[1] / zcnt[1] : 0.0;
        out["zonal_moist_mean_midlat"]  = (zcnt[2] > 0) ? zsum[2] / zcnt[2] : 0.0;
        out["zonal_moist_mean_polar"]   = (zcnt[3] > 0) ? zsum[3] / zcnt[3] : 0.0;
        out["zonal_moist_min_subtrop"]  = (zcnt[1] > 0) ? zmin_sub : 0.0;
        out["zonal_land_cells_eq"]      = zcnt[0];
        out["zonal_land_cells_subtrop"] = zcnt[1];
        out["zonal_land_cells_midlat"]  = zcnt[2];
        out["zonal_land_cells_polar"]   = zcnt[3];
    }

    // 6d. 初判地形（permanent_only=true）：用统一气候场（海洋调节温度 + 风输送湿度）。
    for (int i = 0; i < n; ++i) {
        const double temp = gen_temp(i);
        const uint8_t terrain = pk_decide_terrain_ex(double(E[i]), temp, double(M[i]), sea_level, true);
        TERR[i] = terrain;
        IW[i] = pk_is_water_terrain(terrain) ? uint8_t(1) : uint8_t(0);
    }

    // ── 8. 初始仿真字段 + base 快照 + 轴派生（中间值，post_base 末尾会重算 landform/veg/cover）──
    for (int i = 0; i < n; ++i) {
        const double ny = double(LAT[i]);
        const float temp = pk_compute_temperature(ny, double(E[i]), sea_level);
        const uint8_t terrain = TERR[i];
        BTERR[i] = terrain;
        IW[i] = pk_is_water_terrain(terrain) ? uint8_t(1) : uint8_t(0);
        BM[i] = M[i];
        T[i] = temp;
        TB[i] = temp;
        T30[i] = temp;
        T365[i] = temp;
        TA[i] = 0.0f;
        TH[i] = temp;
        TY[i] = float(pk_clamp01(pk_lat_temp_bell((ny - 0.5) * 2.0)));
        SNOW[i] = 0.0f;
        EMA[i] = 1;
        const uint8_t lf = pk_derive_landform(terrain, E[i], float(sea_level));
        const uint8_t veg = pk_derive_vegetation(terrain, lf, temp, M[i]);
        const uint8_t cov = pk_derive_cover(terrain, 0.0f);
        LF[i] = lf;
        BLF[i] = lf;
        VEG[i] = veg;
        BVEG[i] = veg;
        COV[i] = cov;
    }

    int final_water_count = 0;
    for (int i = 0; i < n; ++i) {
        final_water_count += int(IW[i]);
    }

    const auto t1 = std::chrono::high_resolution_clock::now();
    const double elapsed_ms = std::chrono::duration<double, std::milli>(t1 - t0).count();

    out["rc"] = 0;
    out["status"] = String("completed");
    out["path"] = String("gdext");
    out["fallback"] = false;
    out["fallback_reason"] = String();
    out["reason"] = String();
    out["fail_stage"] = String();
    out["published_to_slot"] = false;
    // [scale-fix 2026-07-30] 湿度格距参数分辨率归一诊断（验证时核对：s=sqrt(N/15000)）
    out["hydro_dist_scale"] = hydro_dist_scale;
    out["moisture_rainout_base_effective"] = moisture_rainout_base_eff;
    out["moisture_continental_dry_effective"] = moisture_continental_dry_eff;
    out["moisture_wind_evap_effective"] = moisture_wind_evap_eff;
    out["coastal_temp_scale_effective"] = coastal_temp_scale_eff;
    out["coastal_moist_scale_effective"] = coastal_moist_scale_eff;
    out["subtropical_interior_scale_effective"] = subtropical_interior_scale_eff;
    out["n_cells"] = n;
    out["width"] = width;
    out["height"] = height;
    out["seed"] = seed;
    out["water_count"] = final_water_count;
    out["land_count"] = n - final_water_count;
    out["elapsed_ms"] = elapsed_ms;
    out["native_ms"] = elapsed_ms;
    out["compute_ms"] = elapsed_ms;
    out["generation_progress"] = 1.0;
    out["q_arr"] = q_arr;
    out["r_arr"] = r_arr;
    out["s_arr"] = s_arr;
    out["elevation_arr"] = elevation_arr;
    out["moisture_arr"] = moisture_arr;
    out["base_moisture_arr"] = base_moisture_arr;
    out["temp_arr"] = temp_arr;
    out["temp_baseline_arr"] = temp_baseline_arr;
    out["temp_30d_arr"] = temp_30d_arr;
    out["temp_365d_arr"] = temp_365d_arr;
    out["temp_anomaly_arr"] = temp_anomaly_arr;
    out["thermal_energy_arr"] = thermal_energy_arr;
    out["cell_lat_norm_arr"] = cell_lat_norm_arr;
    out["temp_baseline_year_arr"] = temp_baseline_year_arr;
    out["snow_cover_arr"] = snow_cover_arr;
    out["is_lake_seed_arr"] = is_lake_seed_arr;
    // 距海距离场（terrain-overhaul Phase 3）：供 post_base 海洋温度调节/大陆度复用，避免重算 BFS。
    {
        PackedInt32Array dist_ocean_arr;
        dist_ocean_arr.resize(n);
        int32_t *D = dist_ocean_arr.ptrw();
        for (int i = 0; i < n; ++i) D[i] = dist_ocean[size_t(i)];
        out["dist_ocean_arr"] = dist_ocean_arr;
    }
    out["terrain_arr"] = terrain_arr;
    out["base_terrain_arr"] = base_terrain_arr;
    out["landform_arr"] = landform_arr;
    out["base_landform_arr"] = base_landform_arr;
    out["vegetation_arr"] = vegetation_arr;
    out["base_vegetation_arr"] = base_vegetation_arr;
    out["cover_arr"] = cover_arr;
    out["is_water_arr"] = is_water_arr;
    out["ema_initialized_arr"] = ema_initialized_arr;
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
    constexpr double plateau_relief_ref_cells = 15000.0;
    constexpr double plateau_relief_scale_exp = 0.25;
    const double plateau_relief_scale = std::pow(
            std::min(1.0, plateau_relief_ref_cells / std::max(1.0, double(n))),
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
    const double relief_thresh_scale = std::pow(
            std::max(0.25, PK_GEN_REF_CELLS / std::max(1.0, double(n))),
            relief_thresh_scale_exp);
    const double mountain_min_relief = mountain_min_relief_base * relief_thresh_scale;
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
    const double river_map_scale = std::pow(
            std::max(0.25, double(n) / river_map_reference_cells),
            river_map_scale_exponent);
    const int channel_init = std::max(2, int(std::round(double(river_channel_init_base) * river_map_scale)));
    const int river_headwater_init = std::max(1, int(std::round(double(river_headwater_init_base) * river_map_scale)));
    // [density-fix] min_length scale exponent 0.75→1.0: keep prune strength in
    // lockstep with channel_init so large-map short tributaries are pruned
    // proportionally rather than retained at a relatively weaker rate.
    const int hydro_river_min_length = std::max(1, int(std::round(
            double(hydro_river_min_length_base) * std::pow(river_map_scale, 1.0))));

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
    for (int i = 0; i < n; ++i) {
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

    // ── 统一气候场（terrain-overhaul Phase 3）：距海距离 + 海洋温度调节 ──
    // 复用 base pass 传来的 dist_ocean_arr；缺失则按 elev<sea_level 现场重算 BFS。
    const double coastal_temp_moderation = getd(profile, "coastal_temp_moderation", 0.18);
    // [scale-fix 2026-07-30] 衰减长度 ×s（与 base pass 一致），保持海洋调温的物理范围恒定。
    const double coastal_temp_scale = std::max(0.5, getd(profile, "coastal_temp_scale", 6.0) * gen_dist_scale);
    std::vector<int32_t> dist_ocean(size_t(n), -1);
    if (dist_ocean_arr.size() == n) {
        const int32_t *DO = dist_ocean_arr.ptr();
        for (int i = 0; i < n; ++i) dist_ocean[size_t(i)] = DO[i];
    } else {
        std::vector<int> bfsq;
        bfsq.reserve(size_t(n));
        for (int i = 0; i < n; ++i) {
            if (double(E[i]) < sea_level) { dist_ocean[size_t(i)] = 0; bfsq.push_back(i); }
        }
        for (size_t qi = 0; qi < bfsq.size(); ++qi) {
            const int cur = bfsq[qi];
            const int nd = dist_ocean[size_t(cur)] + 1;
            for (int d = 0; d < 6; ++d) {
                const int ni = NB[size_t(cur) * 6 + d];
                if (ni < 0 || dist_ocean[size_t(ni)] >= 0) continue;
                dist_ocean[size_t(ni)] = nd;
                bfsq.push_back(ni);
            }
        }
    }
    auto ocean_influence = [&](int i) -> double {
        const int dd = dist_ocean[size_t(i)];
        if (dd < 0) return 0.0;
        return std::exp(-double(dd) / std::max(coastal_temp_scale, 0.5));
    };
    // 生成期分类温度：纬度钟形 - 海拔惩罚，再按海洋邻近度拉向温带。与 base pass gen_temp 一致，
    // 保证 base/post_base 同一套温度→biome 判定（gen_once）。运行时温度场 TEMP[] 不受影响。
    auto gen_temp = [&](int i) -> double {
        const double base = pk_lat_temp_bell((row_norm(i) - 0.5) * 2.0) - pk_alt_penalty(double(E[i]), sea_level);
        const double infl = ocean_influence(i);
        return pk_clamp01(base + infl * coastal_temp_moderation * (0.5 - base));
    };

    auto cube_distance = [&](int a, int b) -> int {
        // [cylindrical-earth-daylight] 东西环绕的最短 cube 距离：把 b 沿 col 方向 ±width
        // 平移（offset col±width ⇔ cube q±width, s∓width, r 不变），取三者最小 →
        // 火山间距等横向度量在接缝处也正确。
        const int dq = Q[a] - Q[b];
        const int dr = R[a] - R[b];
        const int ds = S[a] - S[b];
        const int d0 = (std::abs(dq) + std::abs(dr) + std::abs(ds)) / 2;
        const int d1 = (std::abs(dq - width) + std::abs(dr) + std::abs(ds + width)) / 2;
        const int d2 = (std::abs(dq + width) + std::abs(dr) + std::abs(ds - width)) / 2;
        return std::min(d0, std::min(d1, d2));
    };
    auto sync_axes = [&](int i) {
        const uint8_t lf = pk_derive_landform_with_volcano(TERR[i], E[i], float(sea_level), VOLC[i] != 0);
        const uint8_t veg = pk_derive_vegetation(TERR[i], lf, TEMP[i], M[i]);
        uint8_t cov = pk_derive_cover(TERR[i], 0.0f);
        if (ocean_enabled && UP != nullptr && TERR[i] == 0) {
            bool has_land_neighbor = false;
            for (int d = 0; d < 6; ++d) {
                const int ni = NB[size_t(i) * 6 + d];
                if (ni >= 0 && !pk_is_water_terrain(TERR[ni])) {
                    has_land_neighbor = true;
                    break;
                }
            }
            if (!has_land_neighbor && UP[i] > 0.6f) cov = 6; // PELAGIC_BLOOM
        }
        LF[i] = lf;
        BLF[i] = lf;
        VEG[i] = veg;
        BVEG[i] = veg;
        COV[i] = cov;
        IW[i] = pk_is_water_terrain(TERR[i]) ? uint8_t(1) : uint8_t(0);
        BTERR[i] = TERR[i];
    };

    for (int i = 0; i < n; ++i) {
        BM[i] = M[i];
        RIV[i] = 0;
        RFLOW_OUT[i] = 0.0f;
        RDOWN[i] = -1;
        HPARENT_OUT[i] = -1;
        VOLC[i] = 0;
        IW[i] = pk_is_water_terrain(TERR[i]) ? uint8_t(1) : uint8_t(0);
    }

    // Hydrologic correction: Priority-Flood style spill surface + parent graph.
    // This is the light-weight equivalent of DEM depression filling used by
    // RichDEM/FlowFill workflows: every cell gets an outlet path through its
    // lowest spill, so lakes and rivers are derived from one coherent drainage
    // surface rather than local raw-elevation pits.
    std::vector<uint8_t> connected(size_t(n), 0);
    std::vector<int> queue;
    queue.reserve(size_t(n));
    for (int i = 0; i < n; ++i) {
        if (!pk_is_ocean_connected_seed_terrain(TERR[i])) continue;
        // [cylindrical-earth-daylight] 仅南北极(row)作排水出口种子；东西经度环绕由 NB(已 posmod) 在 BFS 扩散时连通。
        const int row = R[i];
        if (row == 0 || row == height - 1) {
            connected[size_t(i)] = 1;
            queue.push_back(i);
        }
    }
    for (size_t qi = 0; qi < queue.size(); ++qi) {
        const int cur = queue[qi];
        for (int d = 0; d < 6; ++d) {
            const int ni = NB[size_t(cur) * 6 + d];
            if (ni < 0 || connected[size_t(ni)]) continue;
            if (!pk_is_ocean_connected_seed_terrain(TERR[ni])) continue;
            connected[size_t(ni)] = 1;
            queue.push_back(ni);
        }
    }

    using HydroNode = std::pair<float, int>;
    std::priority_queue<HydroNode, std::vector<HydroNode>, std::greater<HydroNode>> hydro_pq;
    std::vector<uint8_t> hydro_seen(size_t(n), 0);
    std::vector<float> hydro_fill(size_t(n), std::numeric_limits<float>::infinity());
    std::vector<int32_t> hydro_parent(size_t(n), -1);
    std::vector<int> hydro_order;
    hydro_order.reserve(size_t(n));
    for (int i = 0; i < n; ++i) {
        // [cylindrical-earth-daylight] 仅南北极(row)作水文 flood 出海口；东西经度环绕由 index_for_qr/NB 处理。
        const int row = R[i];
        if (row != 0 && row != height - 1) continue;
        hydro_seen[size_t(i)] = 1;
        hydro_fill[size_t(i)] = E[i];
        hydro_pq.push(HydroNode(E[i], i));
        hydro_order.push_back(i);
    }
    while (!hydro_pq.empty()) {
        const HydroNode cur_node = hydro_pq.top();
        hydro_pq.pop();
        const float cur_z = cur_node.first;
        const int cur = cur_node.second;
        if (cur_z > hydro_fill[size_t(cur)] + 0.000001f) continue;
        for (int d = 0; d < 6; ++d) {
            const int ni = NB[size_t(cur) * 6 + d];
            if (ni < 0 || hydro_seen[size_t(ni)] != 0) continue;
            hydro_seen[size_t(ni)] = 1;
            const float spill_z = std::max(E[ni], cur_z);
            hydro_fill[size_t(ni)] = spill_z;
            hydro_parent[size_t(ni)] = cur;
            hydro_pq.push(HydroNode(spill_z, ni));
            hydro_order.push_back(ni);
        }
    }
    for (int i = 0; i < n; ++i) {
        HPARENT_OUT[i] = hydro_parent[size_t(i)];
    }

    auto reclassify_drained_land = [&](int i) {
        const double eff_e = std::max(double(E[i]), sea_level + 0.012);
        const double eff_m = std::max(double(M[i]), 0.38);
        uint8_t nt = pk_decide_terrain_ex(eff_e, gen_temp(i),
                                          eff_m, sea_level, true);
        if (pk_is_water_terrain(nt)) nt = 2; // PLAIN fallback; drained tiny pits should not stay blue.
        TERR[i] = nt;
    };

    std::vector<uint8_t> lake_candidate(size_t(n), 0);
    for (int i = 0; i < n; ++i) {
        if (connected[size_t(i)] != 0) continue;
        const double depth = double(hydro_fill[size_t(i)]) - double(E[i]);
        if (depth >= hydro_lake_min_depth) lake_candidate[size_t(i)] = 1;
        if (pk_is_ocean_connected_seed_terrain(TERR[i]) && !connected[size_t(i)] && depth > 0.001) {
            lake_candidate[size_t(i)] = 1;
        }
    }

    int lake_count = 0;
    int lake_component_count = 0;
    int drained_tiny_lake_count = 0;
    std::vector<uint8_t> lake_seen(size_t(n), 0);
    std::vector<int> comp;
    comp.reserve(256);
    for (int i = 0; i < n; ++i) {
        if (lake_seen[size_t(i)] != 0 || lake_candidate[size_t(i)] == 0) continue;
        comp.clear();
        queue.clear();
        queue.push_back(i);
        lake_seen[size_t(i)] = 1;
        double volume = 0.0;
        double max_depth = 0.0;
        for (size_t qi = 0; qi < queue.size(); ++qi) {
            const int cur = queue[qi];
            comp.push_back(cur);
            const double depth = std::max(0.0, double(hydro_fill[size_t(cur)]) - double(E[cur]));
            volume += depth;
            max_depth = std::max(max_depth, depth);
            for (int d = 0; d < 6; ++d) {
                const int ni = NB[size_t(cur) * 6 + d];
                if (ni < 0 || lake_seen[size_t(ni)] != 0 || lake_candidate[size_t(ni)] == 0) continue;
                lake_seen[size_t(ni)] = 1;
                queue.push_back(ni);
            }
        }
        const bool keep_lake = int(comp.size()) >= hydro_lake_min_cells ||
                (int(comp.size()) >= 4 && volume >= hydro_lake_min_volume && max_depth >= hydro_lake_min_depth * 1.5);
        if (keep_lake) {
            ++lake_component_count;
            for (int v : comp) {
                TERR[v] = 18; // LAKE
                ++lake_count;
            }
        } else {
            for (int v : comp) {
                if (pk_is_water_terrain(TERR[v])) {
                    reclassify_drained_land(v);
                    ++drained_tiny_lake_count;
                }
            }
        }
    }
    for (int i = 0; i < n; ++i) {
        if (pk_is_ocean_connected_seed_terrain(TERR[i]) && !connected[size_t(i)]) {
            reclassify_drained_land(i);
            ++drained_tiny_lake_count;
        }
        IW[i] = pk_is_water_terrain(TERR[i]) ? uint8_t(1) : uint8_t(0);
    }

    // Snapshot base moisture before rain shadow / river ecology.
    for (int i = 0; i < n; ++i) BM[i] = M[i];

    // 复刻 _apply_rain_shadow_per_cell(season_phase=1.0)：
    //   1) jitter 来自 _height_warp.get_noise_2d(q*8, r*8)*0.04（需重建同款 FastNoiseLite）；
    //   2) upwind 目标是 cell + best_dir*lookback 的直接 cube 跳转（== get_cell_by_cube），
    //      而非逐步 NB 走步——后者在地图边缘对角方向会与 GDScript 差 1 格。
    Ref<FastNoiseLite> rs_warp;  rs_warp.instantiate();
    if (rs_warp.is_valid()) {
        rs_warp->set_noise_type(FastNoiseLite::TYPE_SIMPLEX_SMOOTH);
        rs_warp->set_seed(seed + 13);
        rs_warp->set_frequency(0.025);
        rs_warp->set_fractal_type(FastNoiseLite::FRACTAL_FBM);
        rs_warp->set_fractal_octaves(3);
    }
    int rain_shadow_touched = 0;
    if (lookback > 0 && rs_warp.is_valid()) {
        for (int i = 0; i < n; ++i) {
            if (pk_is_water_terrain(TERR[i])) continue;
            // [cylindrical-earth-daylight] 雨影 jitter 经度环绕：把原 Q*8 的经度轴换成周长 8*width
            // 的圆环(每 col 弧长≈8，特征尺度不变)，纬度仍 R*8 → 接缝处风扰动连续；配合下方
            // index_for_qr 的 upwind 探针(已环绕)，雨影在东西方向无缝、不再有边缘断层。
            const int rs_col = i % width;
            const double rs_rc = 8.0 * double(width) / PK_TWO_PI;
            const double rs_theta = PK_TWO_PI * (double(rs_col) / double(width));
            const double jitter = double(rs_warp->get_noise_3d(std::cos(rs_theta) * rs_rc,
                                                               std::sin(rs_theta) * rs_rc,
                                                               double(R[i]) * 8.0)) * 0.04;
            const PkWind2 wind = pk_wind_belt_wind_at(row_norm(i), 1.0, jitter);
            const int dir = pk_upwind_dir_index_from_wind(wind.x, wind.y);
            if (dir < 0) continue;
            const int probe = index_for_qr(Q[i] + DQ[dir] * lookback, R[i] + DR[dir] * lookback);
            if (probe < 0) continue;
            if (double(E[probe]) > double(E[i]) + rain_threshold) {
                M[i] = float(double(M[i]) * rain_factor);
                ++rain_shadow_touched;
            }
        }
    }

    int redecide_touched = 0;
    for (int i = 0; i < n; ++i) {
        const uint8_t t = TERR[i];
        if (pk_is_water_terrain(t) || t == 6 || t == 9 || t == 8) continue;
        // 用统一气候场温度(gen_temp，含海洋调节)重判 biome，与 base pass 同源。
        const uint8_t nt = pk_decide_terrain_ex(double(E[i]), gen_temp(i),
                                                double(M[i]), sea_level, true);
        // [破碎湖修复 2026-06-19] 绝不把陆地重新判回水：内陆低于海平面但已被 reclassify_
        // drained_land 排干成陆(PLAIN)的格，其原始 E 仍 < sea_level，若用原始 E 重判会被重新
        // 判成 COAST/OCEAN → 内陆遍布"碎水/破碎湖"(实测 ~144 内陆 COAST 格)。陆→水一律跳过；
        // 真正的内陆湖由上方基于洼地深度的 LAKE 检测专门生成。
        if (pk_is_water_terrain(nt) && !pk_is_water_terrain(t)) continue;
        if (nt != t) {
            TERR[i] = nt;
            ++redecide_touched;
        }
    }

    std::vector<int> land;
    land.reserve(size_t(n));
    for (int i = 0; i < n; ++i) {
        if (!pk_is_water_terrain(TERR[i])) land.push_back(i);
    }
    // Flow accumulation on the hydrologically corrected parent graph.
    std::vector<float> flow(size_t(n), 0.0f);
    const double inv_above_sea = 1.0 / std::max(1.0 - sea_level, 0.001);
    for (int i = 0; i < n; ++i) {
        if (connected[size_t(i)] != 0 && pk_is_water_terrain(TERR[i])) continue;
        if (pk_is_water_terrain(TERR[i]) && TERR[i] != 18) continue;
        const double base_rain = 0.4 + (1.6 - 0.4) * double(M[i]);
        const double lh = (double(hydro_fill[size_t(i)]) - sea_level) * inv_above_sea;
        const double oro = 1.0 + std::max(lh - 0.30, 0.0) * orographic_boost;
        flow[size_t(i)] = pk_is_water_terrain(TERR[i]) ? 0.0f : float(base_rain * oro);
    }
    for (auto it = hydro_order.rbegin(); it != hydro_order.rend(); ++it) {
        const int i = *it;
        const int p = hydro_parent[size_t(i)];
        if (p < 0) continue;
        if (connected[size_t(i)] != 0 && pk_is_water_terrain(TERR[i])) continue;
        flow[size_t(p)] += flow[size_t(i)];
    }
    // ── 河道起始：按"上游汇水面积(汇水格数)"有效阈值取河道 ───────────────────────
    // [river-rework 2026-06-19] 旧法按 flow 分位选 top-X% 地块为源头再向下追踪 → 标出 land 的
    // 固定比例(实测分位 0.72→占全图 ~10% 成"填满大陆的网"；调高分位又退化成贴海岸的短段)。
    // 改用地貌学经典 channel-initiation：汇水面积≥阈值才成河 → 天然稀疏树状网：上游细流在累积
    // 足够汇水后出现，向下汇成干流。大图会按 cell 数温和放大阈值，避免固定格数阈值把超大
    // 流域切出过密支流，同时保留 profile slider 的相对密度含义。
    std::vector<int> up_count(size_t(n), 0);
    for (int i : land) up_count[size_t(i)] = 1;
    for (auto it = hydro_order.rbegin(); it != hydro_order.rend(); ++it) {
        const int i = *it;
        if (up_count[size_t(i)] == 0) continue;
        const int p = hydro_parent[size_t(i)];
        if (p < 0) continue;
        up_count[size_t(p)] += up_count[size_t(i)];
    }
    float river_threshold = std::numeric_limits<float>::infinity();
    for (int i : land) {
        if (up_count[size_t(i)] >= channel_init) {
            RIV[i] = 1;
            river_threshold = std::min(river_threshold, flow[size_t(i)]);
        }
    }
    int headwater_touched = 0;
    if (river_headwater_init < channel_init) {
        for (int i : land) {
            if (RIV[i] != 0) continue;
            if (land_h(i) < river_headwater_min_land_h) continue;
            if (up_count[size_t(i)] < river_headwater_init) continue;
            std::vector<int> path;
            path.reserve(24);
            bool connects = false;
            int cur = i;
            for (int step = 0; step < 24 && cur >= 0 && cur < n; ++step) {
                if (pk_is_water_terrain(TERR[cur])) { connects = true; break; }
                path.push_back(cur);
                const int p = hydro_parent[size_t(cur)];
                if (p < 0 || p == cur) break;
                if (RIV[p] != 0 || pk_is_water_terrain(TERR[p])) { connects = true; break; }
                cur = p;
            }
            if (!connects || path.size() < 2) continue;
            for (int v : path) {
                if (RIV[v] == 0) {
                    RIV[v] = 1;
                    ++headwater_touched;
                }
                river_threshold = std::min(river_threshold, flow[size_t(v)]);
            }
        }
    }
    if (!std::isfinite(river_threshold)) river_threshold = 0.0f;
    (void)river_percentile;  // 旧分位参数保留读取以兼容，不再用于河道选择。
    // 清理：移除不接触水体或过短的孤立河段(channel-init 一般已连通到海/湖，此为安全网)。
    {
        std::vector<uint8_t> riv_seen(size_t(n), 0);
        for (int i : land) {
            if (RIV[i] == 0 || riv_seen[size_t(i)]) continue;
            std::vector<int> comp;
            comp.push_back(i);
            riv_seen[size_t(i)] = 1;
            bool touches_water = false;
            for (size_t qi = 0; qi < comp.size(); ++qi) {
                const int cur = comp[qi];
                for (int d = 0; d < 6; ++d) {
                    const int ni = NB[size_t(cur) * 6 + d];
                    if (ni < 0) continue;
                    if (pk_is_water_terrain(TERR[ni])) touches_water = true;
                    if (riv_seen[size_t(ni)] || RIV[ni] == 0) continue;
                    riv_seen[size_t(ni)] = 1;
                    comp.push_back(ni);
                }
            }
            if (!touches_water || int(comp.size()) < hydro_river_min_length) {
                for (int v : comp) RIV[v] = 0;
            }
        }
    }
    std::vector<int> unmark;
    for (int i : land) {
        if (RIV[i] == 0) continue;
        bool has_river_or_water = false;
        for (int d = 0; d < 6; ++d) {
            const int ni = NB[size_t(i) * 6 + d];
            if (ni >= 0 && (RIV[ni] != 0 || pk_is_water_terrain(TERR[ni]))) {
                has_river_or_water = true;
                break;
            }
        }
        if (!has_river_or_water) unmark.push_back(i);
    }
    for (int i : unmark) RIV[i] = 0;

    // [scale-fix 2026-07-30] RFLOW 归一化改用"基准等效流量" flow_eq = flow × (15000/N)。
    // 同源点汇流量 ∝ N（单位面积产流率 size-invariant × 流域格数 ∝ N）→ flow_eq 跨分辨率
    // 不变；min(≈channel-init 处流量)与 max(最大流域出口)同乘该系数，log min-max 两端不再
    // 缩放不一致（旧法大图 log 区间更宽、中流归一流量系统性偏高 → 同一条河在大图偏宽）。
    // 等效流量仍是 15000 格量级，log1p 的动态压缩特性不受影响。
    const double flow_eq_scale = river_map_reference_cells / std::max(1.0, double(n));
    float max_river_flow = 0.0f;
    for (int i = 0; i < n; ++i) {
        if (RIV[i] != 0) max_river_flow = std::max(max_river_flow, flow[size_t(i)] * float(flow_eq_scale));
    }
    const double river_threshold_eq = double(river_threshold) * flow_eq_scale;
    const double log_min_flow = std::log1p(std::max(river_threshold_eq, 0.0));
    const double log_max_flow = std::log1p(std::max(double(max_river_flow), river_threshold_eq + 0.001));
    const double inv_log_range = 1.0 / std::max(log_max_flow - log_min_flow, 0.001);
    // 生态保留旧归一标尺，视觉河宽调参不得静默改变大河、三角洲和泛滥平原阈值。
    std::vector<float> river_ecology_flow(size_t(n), 0.0f);
    int river_lake_snap_touched = 0;
    for (int i = 0; i < n; ++i) {
        if (RIV[i] == 0) continue;
        const int p = hydro_parent[size_t(i)];
        if (p >= 0 && (RIV[p] != 0 || pk_is_water_terrain(TERR[p]))) {
            RDOWN[i] = p;
        }
        // [river-hierarchy 2026-07-31] 地板 0.15→0.06、跨度 0.85→0.94：旧地板把大量
        // 近阈值支流顶到同一宽度带，再经 stamp 幂律后视觉几乎无差。压低地板后小支流
        // 真正变细，干流仍可顶到 1.0。
        const double raw_norm = (std::log1p(std::max(double(flow[size_t(i)]) * flow_eq_scale, 0.0)) - log_min_flow) * inv_log_range;
        river_ecology_flow[size_t(i)] = float(std::clamp(0.15 + raw_norm * 0.85, 0.15, 1.0));
        RFLOW_OUT[i] = float(std::clamp(0.06 + raw_norm * 0.94, 0.06, 1.0));
    }
    for (int i : land) {
        if (RIV[i] == 0) continue;
        const int cur_down = RDOWN[i];
        if (cur_down >= 0 && cur_down < n && pk_is_water_terrain(TERR[cur_down])) continue;
        int best_lake = -1;
        float best_e = std::numeric_limits<float>::infinity();
        for (int d = 0; d < 6; ++d) {
            const int ni = NB[size_t(i) * 6 + d];
            if (ni < 0 || TERR[ni] != 18) continue; // LAKE
            if (E[ni] < best_e) {
                best_e = E[ni];
                best_lake = ni;
            }
        }
        if (best_lake >= 0) {
            RDOWN[i] = best_lake;
            ++river_lake_snap_touched;
        }
    }

    // [river-confluence-snap 2026-06-26] 相邻河末端可视合并 ─────────────────────────────
    // 现象：河流线只沿"下游父边"(RDOWN)逐段 stamp(run_bake_river_sdf_pass / _bake_river_sdf)，
    // 六边形网格相邻 ≠ 会画连接线。两个直接相邻的 river cell 若不构成父子关系，中间不绘段 →
    // 渲染出"末端/起点贴边却不合并"的干缝。此处只缝合"可视悬空末端"：某 river cell 的 RDOWN<0
    // (其水文父非河/水 → trace 在它处断链)，若 1 格邻居存在 river cell 且接它不成环，就把 RDOWN
    // 接到最佳邻居(优先：其链能抵达终端水体 > 流量更大 > 高程更低)，让 trace 多画一段把两条链缝合。
    // 仅对 RDOWN<0 的悬空末端动手：不重路由已有正常下游的河格 → 不改动既有河链/流域。
    // RDOWN 仅供 SDF trace + cell.river_downstream(可视)消费；运行期汇流走 hydro_parent(HP，独立
    // 无环)，本 snap 完全不触碰运行期语义。成环检测：沿邻居 RDOWN 走 ≤64 步若回到自身则跳过；
    // 因只给原本 RDOWN<0(无出边)的 cell 添加唯一出边、且添加前已验证目标不可达自身，RDOWN 始终保持无环。
    int river_confluence_snap_touched = 0;
    {
        // 从 start 沿 RDOWN 行走：命中 target 返回 true(成环)；中途遇终端水体置 hits_water=true 返回 false。
        auto reaches = [&](int start, int target, bool &hits_water) -> bool {
            hits_water = false;
            int cur = start;
            for (int step = 0; step < 64 && cur >= 0 && cur < n; ++step) {
                if (cur == target) return true;
                if (pk_is_water_terrain(TERR[cur])) { hits_water = true; return false; }
                cur = RDOWN[cur];
            }
            return false;
        };
        for (int i : land) {
            if (RIV[i] == 0 || pk_is_water_terrain(TERR[i])) continue;
            if (RDOWN[i] >= 0) continue;  // 已有下游：保留既有河链，不重路由
            int best = -1;
            bool best_water = false;
            float best_flow = -1.0f;
            float best_e = std::numeric_limits<float>::infinity();
            for (int d = 0; d < 6; ++d) {
                const int ni = NB[size_t(i) * 6 + d];
                if (ni < 0 || RIV[ni] == 0 || pk_is_water_terrain(TERR[ni])) continue;
                bool ni_water = false;
                if (reaches(ni, i, ni_water)) continue;  // 接它会成环 → 跳过
                const bool better =
                    (best < 0) ||
                    (ni_water && !best_water) ||
                    (ni_water == best_water && RFLOW_OUT[ni] > best_flow) ||
                    (ni_water == best_water && RFLOW_OUT[ni] == best_flow && E[ni] < best_e);
                if (better) {
                    best = ni;
                    best_water = ni_water;
                    best_flow = RFLOW_OUT[ni];
                    best_e = E[ni];
                }
            }
            if (best >= 0) {
                RDOWN[i] = best;
                ++river_confluence_snap_touched;
            }
        }
    }

    // [river-incision 2026-06-25] #2b 河流切进仿真高程 E（cell 粒度）──────────────────
    // 现状：河流是独立 SDF overlay，从不进高度场 → 河岸/护岸在地形法线里完全无落差(平地上画线)。
    // 此处在河网最终化 + lake-snap 之后、河岸生态/floodplain 分类之前，沿河道下切 E + 两侧陆地邻居
    // 抬升成堤岸：① 给出河岸的宏观高程落差(coarse 法线/relief/height_tex 都看得到)；② 下切后 land_h
    // 降低 → 下游 floodplain/canyon/delta 分类自洽地在河谷成形(C 选项要的"影响分类")。下切按 RFLOW
    // 缩放(大河更深)；河道始终保持 land(>= sea_level+余量)不反转成海；堤岸抬 clamp≤1。crisp 像素级
    // 河岸由 bake 层(#2a，按 flow SDF 逐像素 V 形)叠加。base pass 已 100% C++ → 无 GDScript 镜像。
    {
        constexpr double PK_RIVER_INCISE   = 0.018;  // 河道最大下切(E 单位，× RFLOW)
        constexpr double PK_RIVER_BANK     = 0.008;  // 河岸最大抬升(堤)(E 单位，× RFLOW)
        constexpr double PK_RIVER_MIN_LAND = 0.004;  // 河道保留在 sea_level 之上的最小余量
        std::vector<float> e_bank(size_t(n), 0.0f);  // 堤岸抬升累积(读原始 RFLOW 计算，避免顺序依赖)
        const double floor_e = sea_level + PK_RIVER_MIN_LAND;
        for (int i : land) {
            if (RIV[i] == 0 || pk_is_water_terrain(TERR[i])) continue;
            const double rw = double(RFLOW_OUT[i]);
            double e = double(E[i]) - PK_RIVER_INCISE * rw;
            if (e < floor_e) e = floor_e;
            E[i] = float(e);
            const float bank = float(PK_RIVER_BANK * rw);
            for (int d = 0; d < 6; ++d) {
                const int ni = NB[size_t(i) * 6 + d];
                if (ni < 0 || RIV[ni] != 0 || pk_is_water_terrain(TERR[ni])) continue;
                if (bank > e_bank[size_t(ni)]) e_bank[size_t(ni)] = bank;  // 多河相邻取最强
            }
        }
        for (int i = 0; i < n; ++i) {
            if (e_bank[size_t(i)] <= 0.0f) continue;
            double e = double(E[i]) + double(e_bank[size_t(i)]);
            if (e > 1.0) e = 1.0;
            E[i] = float(e);
        }
    }

    // [coast-erosion 2026-06-26] #2c 水域波蚀：让水体(海/湖)像河流一样介入地形侵蚀——近岸陆地被
    // 邻接水体的波浪能量侵蚀，向"海蚀台地"下蚀(高处海崖蚀得快、渐近水线平台)。与河流下切 #2b 并列：
    // 河流沿河道切，水域沿岸线切。波能 ∝ 邻接水体的开阔/深度(深海邻居=大风区=强浪，浅滩/小湖弱) ×
    // 岸线包围度。只下蚀、clamp 在 sea_level 之上(不把陆地翻成海、不引发海岸级联);仅读邻居水体 E
    // (本 pass 不改水格)→ 顺序无关。下蚀后 land_h 降低 → 下游 floodplain/beach 分类自洽。base pass
    // 已 100% C++ → 无 GDScript 镜像。一键回退：profile coast_wave_erosion=0。
    int coast_erosion_touched = 0;
    {
        const double coast_wave_erosion = std::max(0.0, getd(profile, "coast_wave_erosion", 0.30));
        if (coast_wave_erosion > 0.0) {
            constexpr double PK_WAVE_MIN_LAND = 0.004;  // 蚀后保留在 sea_level 之上的最小余量
            constexpr double PK_LAKE_WAVE_MUL = 0.35;   // 湖泊波能(风区小)相对海洋折减
            const double floor_e = sea_level + PK_WAVE_MIN_LAND;
            const double inv_sea = 1.0 / std::max(sea_level, 0.001);
            for (int i : land) {
                if (pk_is_water_terrain(TERR[i])) continue;
                if (double(E[i]) <= floor_e) continue;  // 已贴水线的低地无可蚀
                double energy = 0.0;
                int wn = 0;
                for (int d = 0; d < 6; ++d) {
                    const int ni = NB[size_t(i) * 6 + d];
                    if (ni < 0 || !pk_is_water_terrain(TERR[ni])) continue;
                    ++wn;
                    // 深度代理：水体越深(离水线越远)风区越大、浪能越强；浅滩/海岸弱。
                    double depth_proxy = (sea_level - double(E[ni])) * inv_sea;
                    if (depth_proxy < 0.0) depth_proxy = 0.0; else if (depth_proxy > 1.0) depth_proxy = 1.0;
                    const double type_mul = (TERR[ni] == 18) ? PK_LAKE_WAVE_MUL : 1.0;  // 18=LAKE
                    energy += type_mul * (0.30 + 0.70 * depth_proxy);
                }
                if (wn == 0) continue;
                const double e_avg = energy / double(wn);
                const double coverage = double(wn) / 6.0;  // 被水包围越多蚀得越强
                double wave = e_avg * (0.45 + 0.55 * coverage);
                if (wave < 0.0) wave = 0.0; else if (wave > 1.0) wave = 1.0;
                // 海蚀台地：下蚀量 ∝ 高于水线的高度 → 高处海崖蚀得快、渐近水线成平台。
                double e = double(E[i]);
                e -= coast_wave_erosion * wave * (e - sea_level);
                if (e < floor_e) e = floor_e;
                E[i] = float(e);
                ++coast_erosion_touched;
            }
        }
    }

    int river_count = 0;
    for (int i = 0; i < n; ++i) river_count += int(RIV[i] != 0);

    int river_ecology_touched = 0;
    int river_desert_repaired = 0;
    int river_floodplain_channel_touched = 0;
    for (int i : land) {
        if (RIV[i] == 0 || pk_is_water_terrain(TERR[i])) continue;
        const uint8_t t = TERR[i];
        const double temp = gen_temp(i);
        const double lh = land_h(i);
        const float river_w = river_ecology_flow[size_t(i)];
        const bool strong_river = river_w >= 0.55f || flow[size_t(i)] >= river_threshold * 1.8f;
        const bool desert_like = (t == 7 || t == 24 || t == 25 || t == 26 || t == 30);
        const bool lowland_river = lh <= 0.18 || (strong_river && lh <= 0.28);
        const float target_m = strong_river ? 0.74f : 0.66f;
        if (M[i] < target_m) M[i] = target_m;
        if (t == 22 || t == 23 || t == 29) {
            ++river_ecology_touched;
            continue;
        }
        if (desert_like) {
            uint8_t nt = t;
            if (lowland_river) {
                nt = (temp > 0.45 && M[i] >= 0.78f) ? uint8_t(10) : uint8_t(29); // SWAMP/FLOODPLAIN
            } else if (strong_river && temp > 0.35) {
                nt = 23; // OASIS on arid upland channels
            } else if (temp > 0.30) {
                nt = 14; // STEPPE buffer around smaller arid channels
            } else {
                nt = 13; // TAIGA：寒冷河谷已有高湿地板，不应继续保持 COLD_DESERT
            }
            if (nt != t) {
                TERR[i] = nt;
                ++river_ecology_touched;
                ++river_desert_repaired;
            }
            continue;
        }
        if (pk_is_permanent_landform(t)) {
            ++river_ecology_touched;
            continue;
        }
        if (lowland_river && (t == 2 || t == 3 || t == 12 || t == 14 || t == 15)) {
            TERR[i] = 29; // FLOODPLAIN
            ++river_ecology_touched;
            ++river_floodplain_channel_touched;
            continue;
        }
        if (t == 2) {
            uint8_t nt = t;
            if (temp > 0.55) nt = strong_river ? uint8_t(11) : uint8_t(4); // JUNGLE/FOREST
            else if (temp > 0.30) nt = strong_river ? uint8_t(29) : uint8_t(3); // FLOODPLAIN/GRASSLAND
            if (nt != t) {
                TERR[i] = nt;
                ++river_ecology_touched;
            }
        }
    }

    // terrain-overhaul Phase 4：删除旧 vegetation-feedback 单向加湿棘轮 + 不一致温度
    // (纬度-only、permanent_only=false)的二次重判——它会把统一气候场重新抹湿、与 gen_temp
    // 判定打架，并是"陆地普遍过湿、沙漠消失"的元凶之一。biome 现在只在上方 redecide
    // (gen_temp + 风输送湿度)判一次，再叠 river_ecology 河岸微调，单遍联立、内陆干旱得以保留。
    (void)veg_elev_decay;
    int vegetation_feedback_touched = 0;

    // ─── 统一距水场（water-bodies systemic, dots-total-cpp）────────────────────
    // 海/湖/河流多源 BFS（lake/river 此处均已最终判定）：
    //   water_dist[i]      = 到最近水体的格距（-1 = 未达 / 远内陆，截断于 water_dist_max）
    //   water_src_kind[i]  = 最近水源类型（0=海洋性 / 1=湖 / 2=河流；255=无）
    // 海洋 source = ocean-connected 水格（OCEAN/COAST/REEF/SEA_ICE/KELP）；湖 = LAKE(18)；
    // 河流 = 所有 RIV；流量仅缩放局地增益。纯内部中间场：仅供下方气候回灌 / 水缘生态消费，
    // 不出境（架构铁律：O(n) 中间数据留 C++；M[]/TERR[] 的改动经既有导出自然下传）。
    const int   water_dist_max     = std::max(1, geti(cfg, "water_dist_max", 8));
    const float water_big_river_min = float(getd(cfg, "water_big_river_flow_min", 0.55));
    std::vector<int32_t> water_dist(size_t(n), -1);
    std::vector<uint8_t> water_src_kind(size_t(n), 255);
    std::vector<float> water_src_flow(size_t(n), 0.0f);
    int water_src_sea = 0, water_src_lake = 0, water_src_river = 0;
    {
        std::vector<int> wq;
        wq.reserve(size_t(n));
        for (int i = 0; i < n; ++i) {
            const uint8_t t = TERR[i];
            uint8_t kind = 255;
            if (t == 18) { kind = 1; ++water_src_lake; }                 // LAKE → 湖泊效应
            else if (pk_is_water_terrain(t)) { kind = 0; ++water_src_sea; } // 海洋性
            // 所有成形河道都维持窄河岸带；water_big_river_min 只控制流量加成，
            // 不再把多数支流排除在生态水源之外。
            else if (RIV[i] != 0) { kind = 2; ++water_src_river; }
            if (kind != 255) {
                water_dist[size_t(i)] = 0;
                water_src_kind[size_t(i)] = kind;
                if (kind == 2) water_src_flow[size_t(i)] = river_ecology_flow[size_t(i)];
                wq.push_back(i);
            }
        }
        for (size_t qi = 0; qi < wq.size(); ++qi) {
            const int cur = wq[qi];
            const int cd = water_dist[size_t(cur)];
            if (cd >= water_dist_max) continue;                          // 半径截断（控开销 + 仅近邻带回灌）
            for (int d = 0; d < 6; ++d) {
                const int ni = NB[size_t(cur) * 6 + d];
                if (ni < 0 || water_dist[size_t(ni)] >= 0) continue;     // 越界 / 已访问
                water_dist[size_t(ni)]     = cd + 1;
                water_src_kind[size_t(ni)] = water_src_kind[size_t(cur)];
                water_src_flow[size_t(ni)] = water_src_flow[size_t(cur)];
                wq.push_back(ni);
            }
        }
    }

    // ─── 水体气候回灌（仅新增 base 阶段不存在的湖/河项；海洋项不重做）──────────────
    // 职责收紧：海洋调温 / 沿海湿度地板 / land_continentality 由 base pass 维持，
    // 这里只补 post_base 才判定的湖泊与窄河岸湿润带。全部 floor(max)/additive 语义 +
    // 指数衰减 + water_dist_max 截断，不全局抬湿；回灌后由下方受保护的最终重判统一消费。
    // 改动写入 M[]，经既有 moisture_arr 导出自然下传给 HexCell / bake terrain-index。
    // 注：大河河道格(RIV)本身已在 river_ecology(上方)被 floor 到 0.66/0.74；这里把湿润带
    // 外扩到河道近邻的非河道陆地，与上方不冲突（仍是 floor，取较大值）。
    // [延后] 湖泊局地温度调节：TEMP[] 为只读、且 bind 后 republish 会重算温度场，
    // 在此写温度无持久收益，需要专门的 temp-adjust 通道后再做，本期只做湿度。
    int lakeshore_moist_touched = 0;
    int riparian_moist_touched = 0;
    {
        const float lake_moist_floor    = float(getd(cfg, "lake_moist_floor", 0.55));
        const float lake_moist_scale    = float(std::max(0.25, getd(cfg, "lake_moist_scale", 2.5)));
        const float river_riparian_floor= float(std::clamp(getd(cfg, "river_riparian_floor", 0.36), 0.0, 1.0));
        const float river_riparian_gain = float(getd(cfg, "river_riparian_gain", 0.12));
        const float river_riparian_scale= float(std::max(0.25, getd(cfg, "river_riparian_scale", 2.0)));
        for (int i : land) {
            const int wd = water_dist[size_t(i)];
            if (wd <= 0) continue;                                   // 0=水体自身/无效；只回灌陆地近邻带
            const uint8_t kind = water_src_kind[size_t(i)];
            if (kind == 1) {                                         // 湖滨增湿带（floor）
                const float decay = std::exp(-float(wd) / lake_moist_scale);
                const float floor_m = lake_moist_floor * decay;
                if (M[i] < floor_m) { M[i] = floor_m; ++lakeshore_moist_touched; }
            } else if (kind == 2) {                                 // 河谷 riparian 地板 + 增湿（封顶）
                if (wd > 2) continue;                               // 河岸带保持窄，不把整个流域抬湿
                const float flow_scale = std::max(0.01f, water_big_river_min);
                const float flow_strength = std::clamp(water_src_flow[size_t(i)] / flow_scale, 0.0f, 1.0f);
                if (wd == 1) {
                    const float floor_m = river_riparian_floor + 0.06f * flow_strength;
                    if (M[i] < floor_m) { M[i] = floor_m; ++riparian_moist_touched; }
                }
                const float add = river_riparian_gain * std::exp(-float(wd) / river_riparian_scale);
                if (add > 0.0f) {
                    float m = M[i] + add;
                    if (m > 1.0f) m = 1.0f;
                    if (m > M[i]) { M[i] = m; ++riparian_moist_touched; }
                }
            }
            // kind==0（海洋性）：base pass 已处理，这里不动，避免双重计算。
        }
    }

    // 所有静态水分驱动完成后，用同一 gen_temp + 分类器做唯一一次最终气候重判。
    // 河道和特征地形保留给专用覆盖 pass，避免恢复旧 vegetation-feedback 正反馈或抹掉绿洲/河漫滩。
    int final_climate_redecide_evaluated = 0;
    int final_climate_redecide_touched = 0;
    for (int i : land) {
        const uint8_t t = TERR[i];
        if (RIV[i] != 0 || pk_is_water_terrain(t) || pk_is_permanent_landform(t)) continue;
        if (t == 6 || t == 9 || t == 8) continue; // MOUNTAIN/SNOW/TUNDRA 保持生成期稳定边界
        ++final_climate_redecide_evaluated;
        const uint8_t nt = pk_decide_terrain_ex(double(E[i]), gen_temp(i),
                                                double(M[i]), sea_level, true);
        if (pk_is_water_terrain(nt)) continue; // 排干的 below-sea 陆地不得重新变回水体
        if (nt != t) {
            TERR[i] = nt;
            ++final_climate_redecide_touched;
        }
    }

    int shrubland_touched = 0;
    for (int i : land) {
        const uint8_t t = TERR[i];
        if (pk_is_water_terrain(t)) continue;
        if (!(t == 3 || t == 14 || t == 12 || t == 2)) continue;
        if (pk_is_permanent_landform(t)) continue;
        const double lh = land_h(i);
        if (lh > 0.45) continue;
        const double temp = gen_temp(i);
        // [climate-zone-fix P1] 限制为真·暖温带地中海生态位：加温度上限(0.58)排除热带/亚热带
        // 沿海格（原仅 temp>=0.42 无上限→把任意暖区沿海中湿格刷成 MEDIT，占陆地 21%、远超
        // 真地中海气候 ~6%），并收窄湿度上沿（地中海半干 moist≈0.35）。
        if (temp < 0.42 || temp > 0.58) continue;
        if (M[i] < 0.20f || M[i] > 0.44f) continue;
        bool has_sea = false;
        const int dd = dist_ocean[size_t(i)];
        if (dd >= 0 && dd <= 4) has_sea = true;
        for (int d = 0; d < 6; ++d) {
            const int ni = NB[size_t(i) * 6 + d];
            if (ni >= 0 && (TERR[ni] == 0 || TERR[ni] == 1)) { has_sea = true; break; }
        }
        if (has_sea) {
            TERR[i] = 15;
            ++shrubland_touched;
        }
    }

    int mangrove_touched = 0;
    for (int i : land) {
        const uint8_t t = TERR[i];
        if (pk_is_water_terrain(t)) continue;
        if (t == 6 || t == 9 || t == 8 || t == 10) continue;
        if (pk_is_permanent_landform(t)) continue;
        if (land_h(i) > 0.08) continue;
        const double temp = gen_temp(i);
        if (temp < 0.60) continue;
        bool coast_nb = false;
        bool swamp_nb = false;
        for (int d = 0; d < 6; ++d) {
            const int ni = NB[size_t(i) * 6 + d];
            if (ni < 0) continue;
            if (TERR[ni] == 1) coast_nb = true;
            else if (TERR[ni] == 10) swamp_nb = true;
        }
        if (coast_nb && (RIV[i] != 0 || swamp_nb || M[i] >= 0.70f)) {
            TERR[i] = 16;
            ++mangrove_touched;
        }
    }

    int glacier_touched = 0;
    for (int i : land) {
        const uint8_t t = TERR[i];
        if (!(t == 9 || t == 8)) continue;
        const double temp = gen_temp(i);
        if (temp >= 0.05) continue;
        bool coastal = false;
        if (land_h(i) < 0.20) {
            for (int d = 0; d < 6; ++d) {
                const int ni = NB[size_t(i) * 6 + d];
                if (ni >= 0 && (TERR[ni] == 0 || TERR[ni] == 1 || TERR[ni] == 20)) {
                    coastal = true;
                    break;
                }
            }
        }
        if (coastal || land_h(i) > 0.65) {
            TERR[i] = 17;
            ++glacier_touched;
        }
    }

    int swamp_touched = 0;
    const int swamp_water_band = std::max(0, geti(cfg, "swamp_water_band", 2));
    for (int i : land) {
        const uint8_t t = TERR[i];
        if (pk_is_water_terrain(t) || t == 6 || t == 9 || t == 8) continue;
        if (pk_is_permanent_landform(t)) continue;
        if (land_h(i) > 0.10 || M[i] < 0.75f) continue;
        const double temp = pk_clamp01(pk_lat_temp_bell((row_norm(i) - 0.5) * 2.0) - pk_alt_penalty(E[i], sea_level));
        if (temp < 0.30) continue;
        bool has_water = (RIV[i] != 0);
        if (!has_water) {
            for (int d = 0; d < 6; ++d) {
                const int ni = NB[size_t(i) * 6 + d];
                if (ni >= 0 && pk_is_water_terrain(TERR[ni])) { has_water = true; break; }
            }
        }
        // [water-bodies] 统一距水场：湖/大河近邻带(不止 1 格邻接)也算"近水"，让湿地沿
        // 湖滨/河谷成有宽度的连续带（与上方湿度回灌同源、graded）。高 M(0.75)+低地+暖温
        // 三道既有闸门仍在，故不会因放宽近水判定而泛滥。
        if (!has_water && swamp_water_band > 0) {
            const int wd = water_dist[size_t(i)];
            const uint8_t wk = water_src_kind[size_t(i)];
            if (wd > 0 && wd <= swamp_water_band && (wk == 1 || wk == 2)) has_water = true;
        }
        if (has_water) {
            TERR[i] = 10;
            ++swamp_touched;
        }
    }

    // 火山候选：镜像 _apply_volcano_pass —— 行主序（cell 索引升序）遍历 MOUNTAIN 且
    // land_h>=阈值，再用 Godot RandomNumberGenerator(seed+7717) Fisher-Yates 洗牌
    // （与 GDScript 逐位同源，不能用 xorshift 替代，否则洗牌序列不一致）。
    // 注意：必须用 0..n 索引序，不能用 `land`——`land` 已被 flow-accumulation 按高程
    // 降序排过序（见上方 std::sort），而 GDScript `_apply_volcano_pass` 遍历的
    // `map.all_cells()` = _cells.values() 是 set_cell 的 row-major 插入序。两者顺序
    // 不一致会让洗牌前的候选数组次序错位，导致火山落点分歧（parity FAIL）。
    std::vector<int> volcano_candidates;
    for (int i = 0; i < n; ++i) {
        if (TERR[i] != 6) continue;
        if (geomorph_h(i) < volcano_min_land_h) continue;
        volcano_candidates.push_back(i);
    }
    Ref<RandomNumberGenerator> volc_rng;  volc_rng.instantiate();
    if (volc_rng.is_valid()) {
        volc_rng->set_seed(uint64_t(seed + 7717));
        for (int i = int(volcano_candidates.size()) - 1; i > 0; --i) {
            const int j = volc_rng->randi_range(0, i);
            std::swap(volcano_candidates[size_t(i)], volcano_candidates[size_t(j)]);
        }
    }
    std::vector<int> volcano_placed;
    for (int cand : volcano_candidates) {
        if (int(volcano_placed.size()) >= max_volcanoes) break;
        bool ok = true;
        for (int p : volcano_placed) {
            if (cube_distance(cand, p) < volcano_min_dist) { ok = false; break; }
        }
        if (!ok) continue;
        VOLC[cand] = 1;
        LF[cand] = 12;   // VOLCANO
        BLF[cand] = 12;
        volcano_placed.push_back(cand);

        // [volcano-crater 2026-06-25] 生成期把火山塑成环形山高度场：中心 cell 下凹成火山口(caldera)，
        // 第一环 6 邻居抬升成环形山脊(rim)。map_baker 的 barycentric 高度插值(self+2 邻居)会把这组
        // per-cell 高差平滑烘进 height_tex，靠 hillshade 自然成形——取代旧 shader 的密集橙点。
        // 幅度以归一化高程(0..1)计；volcano_min_dist 默认 6 → 不同火山的环脊邻域不会重叠。
        E[cand] = float(pk_clamp01(double(E[cand]) - volcano_crater_depth));
        for (int d = 0; d < 6; ++d) {
            const int ni = NB[size_t(cand) * 6 + d];
            if (ni < 0) continue;
            if (pk_is_water_terrain(TERR[ni])) continue;   // 不抬海/湖/海岸，避免环山探进水里
            if (VOLC[ni]) continue;                         // 邻居自身是火山则不二次抬升
            // 方位抖动破除完美圆环 artifact（确定性 hash，无 RNG → 不影响落点 parity）。
            const double hv = std::sin(double(cand) * 12.9898 + double(d) * 78.233) * 43758.5453;
            const double jitter = 0.80 + 0.40 * (hv - std::floor(hv));
            E[ni] = float(pk_clamp01(double(E[ni]) + volcano_rim_height * jitter));
        }
    }

    int delta_touched = 0;
    for (int i : land) {
        if (pk_is_water_terrain(TERR[i]) || RIV[i] == 0 || pk_is_permanent_landform(TERR[i])) continue;
        if (land_h(i) > 0.20) continue;
        if (river_ecology_flow[size_t(i)] < 0.35f) continue;
        bool ocean_nb = false;
        bool coast_nb = false;
        for (int d = 0; d < 6; ++d) {
            const int ni = NB[size_t(i) * 6 + d];
            if (ni >= 0 && (TERR[ni] == 0 || TERR[ni] == 1)) { ocean_nb = true; coast_nb = TERR[ni] == 1; break; }
        }
        if (ocean_nb && (coast_nb || river_ecology_flow[size_t(i)] >= 0.55f)) {
            TERR[i] = 22;
            if (M[i] < 0.78f) M[i] = 0.78f;
            ++delta_touched;
        }
    }

    int oasis_touched = 0;
    for (int i : land) {
        const uint8_t t = TERR[i];
        if (pk_is_water_terrain(t) || pk_is_permanent_landform(t)) continue;
        // 回归修复(2026-06-18)：绿洲仅在真正的暖沙漠(DESERT)中生成，避免对任意干暖陆地
        // 滥铺(此前 698 格/5.5%)。寒漠/草原/灌丛不结绿洲。
        if (t != 7) continue;
        if (BM[i] > 0.38f && M[i] > 0.45f) continue;
        if (gen_temp(i) < 0.40) continue;
        bool has_water = (RIV[i] != 0);
        if (!has_water) {
            for (int d = 0; d < 6; ++d) {
                const int ni = NB[size_t(i) * 6 + d];
                if (ni >= 0 && TERR[ni] == 18) { has_water = true; break; }
            }
        }
        if (has_water) {
            if (M[i] < 0.55f) M[i] = 0.55f;
            TERR[i] = 23;
            ++oasis_touched;
        }
    }

    // terrain-overhaul Phase 5：盐滩收紧——仅真正内陆(距海 ≥ salt_flat_min_dist)的内流盆地
    // 底部(局部洼地)才结盐，消除沿海/坡地"错位盐滩" artifact。
    const int salt_flat_min_dist = std::max(0, geti(profile, "salt_flat_min_dist_ocean", 4));
    int salt_flat_touched = 0;
    for (int i : land) {
        if (TERR[i] != 7 && TERR[i] != 26) continue;
        if (land_h(i) > 0.18) continue;
        const int dd = dist_ocean[size_t(i)];
        if (dd >= 0 && dd < salt_flat_min_dist) continue; // 离海太近 → 非内流盐碱
        bool endorheic = (RIV[i] == 0);
        float min_nb = E[i];
        for (int d = 0; d < 6; ++d) {
            const int ni = NB[size_t(i) * 6 + d];
            if (ni < 0) continue;
            min_nb = std::min(min_nb, E[ni]);
            if (endorheic && (RIV[ni] != 0 || pk_is_water_terrain(TERR[ni]))) endorheic = false;
        }
        // 必须位于盆地底部（≤ 最低邻居 + 微容差），避免坡面误判。
        const bool basin_floor = (double(E[i]) <= double(min_nb) + 0.02);
        if (endorheic && basin_floor) {
            TERR[i] = 24;
            ++salt_flat_touched;
        }
    }

    int badlands_touched = 0;
    int badlands_candidate_count = 0;
    int badlands_candidate_components = 0;
    int badlands_budget_rejected = 0;
    int badlands_largest_component = 0;
    int badlands_budget = 0;
    int mesa_touched = 0;
    int arid_source_count = 0;
    for (int i : land) {
        if (TERR[i] == 7 || TERR[i] == 24 || TERR[i] == 26) ++arid_source_count;
    }

    std::vector<uint8_t> badlands_candidate_mask(size_t(n), 0);
    std::vector<double> badlands_score(size_t(n), 0.0);
    for (int i : land) {
        if (TERR[i] != 7 && TERR[i] != 26) continue;
        float min_e = E[i];
        float max_e = E[i];
        float max_nb = -1.0e9f;
        bool water_nb = false;
        int rugged_neighbors = 0;
        for (int d = 0; d < 6; ++d) {
            const int ni = NB[size_t(i) * 6 + d];
            if (ni < 0) continue;
            min_e = std::min(min_e, E[ni]);
            max_e = std::max(max_e, E[ni]);
            max_nb = std::max(max_nb, E[ni]);
            if (pk_is_water_terrain(TERR[ni]) || RIV[ni] != 0) water_nb = true;
            if (std::abs(double(E[ni]) - double(E[i])) >= badlands_min_relief * 0.35) {
                ++rugged_neighbors;
            }
        }
        // 荒原/方山是干旱侵蚀地貌，不应占用河道或紧贴海、湖、河岸。
        if (water_nb || RIV[i] != 0) continue;
        const double relief = double(max_e) - double(min_e);
        if (relief < badlands_min_relief) continue;
        // 方山(MESA)：高差地貌中本格为局部高点(平顶台地)且海拔够高；
        // 否则为侵蚀沟壑恶地(BADLANDS)。
        const bool flat_top = (double(E[i]) >= double(max_nb) - 0.004) && (geomorph_h(i) > 0.18);
        if (flat_top) {
            TERR[i] = 30; // MESA
            ++mesa_touched;
            continue;
        }
        if (rugged_neighbors < badlands_min_rugged_neighbors) continue;
        badlands_candidate_mask[size_t(i)] = 1;
        badlands_score[size_t(i)] = relief * 3.0
                + (1.0 - double(M[i])) * 0.15
                + double(rugged_neighbors) * 0.02;
        ++badlands_candidate_count;
    }

    // 荒原是沙漠中的局地侵蚀斑块，而不是所有崎岖沙漠的默认分类。候选区按
    // 连通分量处理，从最高分格向邻格生长；默认让候选区自身决定斑块大小，
    // 只有显式配置安全阀时才按总量/斑块格数截断。
    struct BadlandsComponent {
        std::vector<int> cells;
        int seed = -1;
        double best_score = -1.0;
    };
    std::vector<uint8_t> badlands_seen(size_t(n), 0);
    std::vector<BadlandsComponent> badlands_components;
    for (int i : land) {
        if (!badlands_candidate_mask[size_t(i)] || badlands_seen[size_t(i)]) continue;
        BadlandsComponent comp;
        comp.cells.push_back(i);
        badlands_seen[size_t(i)] = 1;
        for (size_t qi = 0; qi < comp.cells.size(); ++qi) {
            const int cur = comp.cells[qi];
            const double score = badlands_score[size_t(cur)];
            if (score > comp.best_score || (score == comp.best_score && cur < comp.seed)) {
                comp.best_score = score;
                comp.seed = cur;
            }
            for (int d = 0; d < 6; ++d) {
                const int ni = NB[size_t(cur) * 6 + d];
                if (ni < 0 || badlands_seen[size_t(ni)]
                        || !badlands_candidate_mask[size_t(ni)]) continue;
                badlands_seen[size_t(ni)] = 1;
                comp.cells.push_back(ni);
            }
        }
        badlands_components.push_back(std::move(comp));
    }
    badlands_candidate_components = int(badlands_components.size());
    std::sort(badlands_components.begin(), badlands_components.end(),
            [](const BadlandsComponent &a, const BadlandsComponent &b) {
                if (a.best_score == b.best_score) return a.seed < b.seed;
                return a.best_score > b.best_score;
            });

    const int land_budget = int(std::floor(double(land.size()) * badlands_max_land_ratio));
    const int arid_budget = int(std::floor(double(arid_source_count) * badlands_max_arid_ratio));
    badlands_budget = std::max(0, std::min(land_budget, arid_budget));
    std::vector<uint8_t> badlands_selected(size_t(n), 0);
    std::vector<uint8_t> badlands_queued(size_t(n), 0);
    for (const BadlandsComponent &comp : badlands_components) {
        if (badlands_touched >= badlands_budget) break;
        int patch_quota = std::min(int(comp.cells.size()), badlands_budget - badlands_touched);
        if (badlands_max_patch_cells > 0) {
            patch_quota = std::min(patch_quota, badlands_max_patch_cells);
        }
        if (patch_quota <= 0 || comp.seed < 0) continue;

        std::priority_queue<std::pair<double, int>> frontier;
        frontier.push({badlands_score[size_t(comp.seed)], -comp.seed});
        badlands_queued[size_t(comp.seed)] = 1;
        int patch_size = 0;
        while (!frontier.empty() && patch_size < patch_quota) {
            const int cur = -frontier.top().second;
            frontier.pop();
            if (badlands_selected[size_t(cur)]) continue;
            badlands_selected[size_t(cur)] = 1;
            TERR[cur] = 25; // BADLANDS
            ++patch_size;
            ++badlands_touched;
            for (int d = 0; d < 6; ++d) {
                const int ni = NB[size_t(cur) * 6 + d];
                if (ni < 0 || badlands_queued[size_t(ni)]
                        || !badlands_candidate_mask[size_t(ni)]) continue;
                badlands_queued[size_t(ni)] = 1;
                frontier.push({badlands_score[size_t(ni)], -ni});
            }
        }
        badlands_largest_component = std::max(badlands_largest_component, patch_size);
    }
    badlands_budget_rejected = badlands_candidate_count - badlands_touched;

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

    // ── 最终孤立水体清理（修复"大陆内部单格海洋"）──────────────────────────
    // 根因：connected[] 在湖泊/排水改写地形后变 stale，孤立残留的 OCEAN/COAST 又被
    // 升级成 REEF/KELP。这里在所有地形改写之后、最终轴派生之前，按当前地形重算一次
    // 海洋连通性：从地图边缘的水格 BFS。任何未连通主海洋的水体——达到湖泊最小面积者
    // 视作内陆湖(LAKE)，否则排干回收为陆地(reclassify_drained_land)。这样单格/碎小海洋
    // 不再出现在大陆内部，同时合法内陆湖/内海得以保留。
    int isolated_water_drained = 0;
    int isolated_water_to_lake = 0;
    {
        std::vector<uint8_t> ocean_conn(size_t(n), 0);
        std::vector<int> bfs;
        bfs.reserve(size_t(n));
        for (int i = 0; i < n; ++i) {
            if (!pk_is_water_terrain(TERR[i])) continue;
            // [cylindrical-earth-daylight] 仅南北极(row)作海洋种子；东西经度环绕由 NB 处理。
            const int row = R[i];
            if (row == 0 || row == height - 1) {
                ocean_conn[size_t(i)] = 1;
                bfs.push_back(i);
            }
        }
        for (size_t bi = 0; bi < bfs.size(); ++bi) {
            const int cur = bfs[bi];
            for (int d = 0; d < 6; ++d) {
                const int ni = NB[size_t(cur) * 6 + d];
                if (ni < 0 || ocean_conn[size_t(ni)]) continue;
                if (!pk_is_water_terrain(TERR[ni])) continue;
                ocean_conn[size_t(ni)] = 1;
                bfs.push_back(ni);
            }
        }
        // 安全阀：地图边缘必须存在主海洋；否则(全封闭水世界)跳过清理，避免误排干整片海。
        if (!bfs.empty()) {
            std::vector<uint8_t> visited_cl(size_t(n), 0);
            std::vector<int> comp_cl;
            comp_cl.reserve(256);
            for (int i = 0; i < n; ++i) {
                if (!pk_is_water_terrain(TERR[i]) || ocean_conn[size_t(i)] || visited_cl[size_t(i)]) continue;
                comp_cl.clear();
                comp_cl.push_back(i);
                visited_cl[size_t(i)] = 1;
                for (size_t qi = 0; qi < comp_cl.size(); ++qi) {
                    const int cur = comp_cl[qi];
                    for (int d = 0; d < 6; ++d) {
                        const int ni = NB[size_t(cur) * 6 + d];
                        if (ni < 0 || visited_cl[size_t(ni)]) continue;
                        if (!pk_is_water_terrain(TERR[ni]) || ocean_conn[size_t(ni)]) continue;
                        visited_cl[size_t(ni)] = 1;
                        comp_cl.push_back(ni);
                    }
                }
                const bool keep_as_lake = int(comp_cl.size()) >= hydro_lake_min_cells;
                for (int v : comp_cl) {
                    if (keep_as_lake) {
                        TERR[v] = 18; // LAKE
                        ++isolated_water_to_lake;
                    } else {
                        reclassify_drained_land(v);
                        ++isolated_water_drained;
                    }
                }
            }
            for (int i = 0; i < n; ++i) {
                IW[i] = pk_is_water_terrain(TERR[i]) ? uint8_t(1) : uint8_t(0);
            }
        }
    }



    // ── [water-depth-tex 2026-06-26] 统一水深信号 water_depth01 ∈ [0,1]（海/湖共用一张 R8 图）──────
    // 取代 shader 端"海洋 5×5 height 邻域 + 湖泊 16× biome-atlas 多半径"两套深浅估算：C++ 在此算好
    // 每格归一水深，bake 经 pixel_to_cell_index 扇出成 R8 water_depth_tex，shader 每水像素仅 1 次采样。
    // 海洋/海岸/礁/海草/海冰用 1-E/sea_level（E 已含洋底距岸 BFS 梯度）；湖泊用下方 bathymetry 的碗形
    // ramp × 湖体尺寸因子（小塘浅、大湖深）；非水格 0（shader 仅水像素读）。
    PackedFloat32Array water_depth_arr;
    water_depth_arr.resize(n);
    float * const WDEPTH = water_depth_arr.ptrw();
    for (int i = 0; i < n; ++i) WDEPTH[i] = 0.0f;

    // ── [lake-bathymetry 2026-06-26] 湖泊水下深度场（湖岸浅→湖心深，对标海洋距岸 BFS）──────────
    // 根因：海洋洋底由 base pass 两段距岸 BFS（§2.55 + water-tuning）刻出"大陆架→坡→深渊"的真实
    // 高程梯度，而湖泊只在 post_base 被打 TERR=18 标志、湖底高程仍是洼地填充后的近似平面 → 渲染端
    // 只能用 shader 邻域代理(compute_lake_shore_proxy)凑深浅，大湖中央一片均一（用户反馈"湖泊没有
    // 像海洋那样的深度/海拔变化"）。这里在所有 LAKE 最终确定后、sync_axes 之前，对每个湖泊连通域：
    // 从湖岸向湖心做多源 BFS 得每格离岸 hex 距离，按距离把湖底高程压向"以该湖水面(hydro_fill)为
    // 深度=0 基准的碗形梯度"。仅下切(min)、绝不抬升 → 不会把水翻到陆上；TERR 不改 → LAKE 分类/
    // landform 不受影响（pk_derive_landform 对 terrain==18 恒返回 LAKE）。湖深随湖体半径自适应（大湖
    // 更深）并叠低频噪声造湖底起伏。下游：HexCell.elevation→height 纹理→shader lake_bathy / relief /
    // hillshade 全部拿到真实湖盆深度。一键回退：profile lake_bathymetry_scale=0。
    {
        constexpr double PK_LAKE_SHELF_CELLS = 1.5;   // 近岸浅滩宽度(hex)：绝对离岸距离，不按湖半径归一
        constexpr double PK_LAKE_DEEP_CELLS  = 7.0;    // 到此离岸距离(hex)达满深 → 大湖内部整体判深水（关键修复）
        constexpr double PK_LAKE_MIN_DEPTH      = 0.050; // 物理碗形最小中心下切（height 单位）
        constexpr double PK_LAKE_MAX_DEPTH      = 0.240; // 物理下切上限（防穿到极端低高程）
        constexpr double PK_LAKE_BASIN_AMP      = 0.18;  // 湖底低频起伏幅度（×深度，仅深区生效）
        const double lake_bathy_scale = getd(profile, "lake_bathymetry_scale", 1.0); // 0=关闭

        if (lake_bathy_scale > 1e-4) {
            // 湖底起伏噪声（确定性，按 seed）：让湖盆不是完美碗形，出现水下浅丘/深潭。
            Ref<FastNoiseLite> lake_floor_noise;  lake_floor_noise.instantiate();
            if (lake_floor_noise.is_valid()) {
                lake_floor_noise->set_noise_type(FastNoiseLite::TYPE_SIMPLEX_SMOOTH);
                lake_floor_noise->set_seed(seed + 7757);
                lake_floor_noise->set_frequency(0.06);
                lake_floor_noise->set_fractal_type(FastNoiseLite::FRACTAL_FBM);
                lake_floor_noise->set_fractal_octaves(3);
            }
            std::vector<uint8_t> lb_seen(size_t(n), 0);
            std::vector<int32_t> sdist(size_t(n), -1);   // 离岸 hex 距离（仅湖内有效，逐域复位）
            std::vector<int> comp;  comp.reserve(256);
            std::vector<int> bfs;   bfs.reserve(256);
            int lake_bathy_components = 0;
            int lake_bathy_cells = 0;
            for (int s0 = 0; s0 < n; ++s0) {
                if (lb_seen[size_t(s0)] || TERR[s0] != 18) continue;
                // ① 收集该湖连通域。
                comp.clear();
                comp.push_back(s0);
                lb_seen[size_t(s0)] = 1;
                for (size_t qi = 0; qi < comp.size(); ++qi) {
                    const int cur = comp[qi];
                    for (int d = 0; d < 6; ++d) {
                        const int ni = NB[size_t(cur) * 6 + d];
                        if (ni < 0 || lb_seen[size_t(ni)] || TERR[ni] != 18) continue;
                        lb_seen[size_t(ni)] = 1;
                        comp.push_back(ni);
                    }
                }
                ++lake_bathy_components;
                // ② 多源 BFS：湖内紧邻非湖(或出界)的格 = 岸(dist=0)，向湖心逐 hex 递增。
                bfs.clear();
                for (int c : comp) {
                    bool on_shore = false;
                    for (int d = 0; d < 6; ++d) {
                        const int ni = NB[size_t(c) * 6 + d];
                        if (ni < 0 || TERR[ni] != 18) { on_shore = true; break; }
                    }
                    if (on_shore) { sdist[size_t(c)] = 0; bfs.push_back(c); }
                }
                int max_dist = 0;
                for (size_t bi = 0; bi < bfs.size(); ++bi) {
                    const int cur = bfs[bi];
                    const int cd = sdist[size_t(cur)];
                    for (int d = 0; d < 6; ++d) {
                        const int ni = NB[size_t(cur) * 6 + d];
                        if (ni < 0 || TERR[ni] != 18 || sdist[size_t(ni)] >= 0) continue;
                        sdist[size_t(ni)] = cd + 1;
                        if (cd + 1 > max_dist) max_dist = cd + 1;
                        bfs.push_back(ni);
                    }
                }
                // ③ 湖深（物理碗形下切幅度）随湖体半径自适应：小塘浅、大湖到上限。
                double depth_amp = (double(max_dist) / PK_LAKE_DEEP_CELLS) * PK_LAKE_MAX_DEPTH * lake_bathy_scale;
                if (depth_amp < PK_LAKE_MIN_DEPTH) depth_amp = PK_LAKE_MIN_DEPTH;
                if (depth_amp > PK_LAKE_MAX_DEPTH) depth_amp = PK_LAKE_MAX_DEPTH;
                const double inv_deep = 1.0 / std::max(1.0, PK_LAKE_DEEP_CELLS - PK_LAKE_SHELF_CELLS);
                // ④ 逐格压湖底：以该格水面 hydro_fill 为深度=0 基准，按归一离岸距离刻碗形（仅下切）。
                for (int c : comp) {
                    const double surface = std::isfinite(hydro_fill[size_t(c)])
                                         ? double(hydro_fill[size_t(c)])
                                         : double(E[c]);
                    // 绝对离岸距离 ramp（对标海洋 shelf→deep，不按湖半径归一 → 大湖内部整体判深水）。
                    const double sd = (sdist[size_t(c)] >= 0) ? double(sdist[size_t(c)]) : 0.0;
                    double ramp = (sd - PK_LAKE_SHELF_CELLS) * inv_deep;
                    if (ramp < 0.0) ramp = 0.0; else if (ramp > 1.0) ramp = 1.0;
                    double depth01 = pk_smoothstep(0.0, 1.0, ramp);
                    if (lake_floor_noise.is_valid() && depth01 > 0.0) {
                        // [cylindrical-earth-daylight] 经度环绕采样，接缝处湖底连续。
                        const int col = c % width;
                        const double th = PK_TWO_PI * (double(col) / double(width));
                        const double rc = double(width) / PK_TWO_PI;
                        const double bn = double(lake_floor_noise->get_noise_3d(
                            std::cos(th) * rc, std::sin(th) * rc, double(R[c])));
                        depth01 += bn * PK_LAKE_BASIN_AMP * depth01;
                        if (depth01 < 0.0) depth01 = 0.0; else if (depth01 > 1.0) depth01 = 1.0;
                    }
                    double floor_e = surface - depth01 * depth_amp;
                    if (floor_e < 0.0) floor_e = 0.0;
                    if (floor_e < double(E[c])) { E[c] = float(floor_e); ++lake_bathy_cells; }
                    // [water-depth-tex] per-cell 只存"水面高度"（湖=该湖 hydro_fill 水位）；真实逐像素
                    // 水深由 bake 用 surface - height_tex(像素) 算（见 world_ext_bake），直接吃生成的高程图。
                    WDEPTH[c] = float(surface);
                    sdist[size_t(c)] = -1; // 复位供下一连通域复用
                }
            }
            out["lake_bathymetry_components"] = lake_bathy_components;
            out["lake_bathymetry_cells_carved"] = lake_bathy_cells;
        }
    }

    // water_depth01 现承载 per-cell "水面高度"：湖泊已在上面存其 hydro_fill 水位；这里补海洋/海岸/
    // 礁/海草/海冰 = sea_level；陆地 = 0。真实逐像素水深由 bake 用 surface - height_tex 算。
    {
        for (int i = 0; i < n; ++i) {
            if (TERR[i] == 18) continue;                 // 湖：上面已存其水面
            if (!pk_is_water_terrain(TERR[i])) { WDEPTH[i] = 0.0f; continue; }  // 陆地 = 0
            WDEPTH[i] = float(sea_level);                // 海洋/海岸/礁/海草/海冰水面 = sea_level
        }
    }

    for (int i = 0; i < n; ++i) {
        sync_axes(i);
    }

    // ── 高原(PLATEAU) landform override：高海拔、低局部起伏、连通成片的陆地 ──
    // 不新增 terrain；只把三轴 landform 覆写为 PLATEAU，保留原 biome/vegetation。
    std::vector<uint8_t> plateau_candidate(size_t(n), 0);
    int plateau_candidate_count = 0;
    for (int i : land) {
        if (pk_is_water_terrain(TERR[i]) || VOLC[i] != 0) continue;
        if (pk_is_permanent_landform(TERR[i])) continue;
        const double lh = geomorph_h(i);
        if (lh < plateau_min_land_h || lh > 0.90) continue;
        float min_e = E[i], max_e = E[i];
        int land_nb = 0;
        for (int d = 0; d < 6; ++d) {
            const int ni = NB[size_t(i) * 6 + d];
            if (ni < 0 || pk_is_water_terrain(TERR[ni])) continue;
            ++land_nb;
            min_e = std::min(min_e, E[ni]);
            max_e = std::max(max_e, E[ni]);
        }
        if (land_nb < 2) continue;
        const double relief = double(max_e) - double(min_e);
        const bool broad_bench = lh >= plateau_min_land_h && relief <= plateau_max_relief;
        const bool high_bench = lh >= plateau_min_land_h + 0.10 && relief <= plateau_max_relief * 1.35;
        if (broad_bench || high_bench) {
            plateau_candidate[size_t(i)] = 1;
            ++plateau_candidate_count;
        }
    }
    int plateau_touched = 0;
    std::vector<uint8_t> plateau_seen(size_t(n), 0);
    for (int i : land) {
        if (!plateau_candidate[size_t(i)] || plateau_seen[size_t(i)]) continue;
        std::vector<int> comp;
        comp.push_back(i);
        plateau_seen[size_t(i)] = 1;
        for (size_t qi = 0; qi < comp.size(); ++qi) {
            const int cur = comp[qi];
            for (int d = 0; d < 6; ++d) {
                const int ni = NB[size_t(cur) * 6 + d];
                if (ni < 0 || plateau_seen[size_t(ni)] || !plateau_candidate[size_t(ni)]) continue;
                plateau_seen[size_t(ni)] = 1;
                comp.push_back(ni);
            }
        }
        const bool high_small_plateau = int(comp.size()) >= 2 && geomorph_h(comp[0]) >= plateau_min_land_h + 0.12;
        if (int(comp.size()) < plateau_min_cells && !high_small_plateau) continue;
        for (int v : comp) {
            LF[v] = 13;  // PLATEAU
            BLF[v] = 13;
            ++plateau_touched;
        }
    }

    // ── 山地(MOUNTAIN)瘦身：山脉应是高起伏地带，高海拔平缓面应落到 PLATEAU/HILL ──
    int mountain_demoted = 0;
    int mountain_to_plateau = 0;
    int mountain_height_candidates = 0;
    int mountain_relief_candidates = 0;
    int mountain_kept = 0;
    for (int i : land) {
        if (LF[i] != 7 || pk_is_water_terrain(TERR[i]) || VOLC[i] != 0) continue;
        if (TERR[i] == 22 || TERR[i] == 24 || TERR[i] == 25 || TERR[i] == 30) continue;
        const double lh = geomorph_h(i);
        float min_e = E[i], max_e = E[i];
        int land_nb = 0;
        for (int d = 0; d < 6; ++d) {
            const int ni = NB[size_t(i) * 6 + d];
            if (ni < 0 || pk_is_water_terrain(TERR[ni])) continue;
            ++land_nb;
            min_e = std::min(min_e, E[ni]);
            max_e = std::max(max_e, E[ni]);
        }
        if (land_nb < 3) continue;
        const double relief = double(max_e) - double(min_e);
        const bool summit_rugged = lh >= peak_min_land_h && relief >= mountain_min_relief * 0.65;
        const bool keep_mountain = lh >= mountain_min_land_h && (relief >= mountain_min_relief || summit_rugged);
        if (lh >= mountain_min_land_h) ++mountain_height_candidates;
        if (lh >= mountain_min_land_h && (relief >= mountain_min_relief || summit_rugged)) {
            ++mountain_relief_candidates;
        }
        if (keep_mountain) {
            ++mountain_kept;
            continue;
        }

        if (lh >= plateau_min_land_h && lh <= 0.90 && relief <= plateau_max_relief * 1.10) {
            LF[i] = 13;  // PLATEAU
            BLF[i] = 13;
            ++mountain_to_plateau;
        } else {
            LF[i] = 6;   // HILL
            BLF[i] = 6;
            ++mountain_demoted;
        }
    }

    // ── [density-fix 2026-06-30] PLATEAU 面积占比上限剪裁 ──
    // 高原此前无任何密度上限（PEAK 按 land/N 限量、RIFT 按 land/N 限量，唯独 PLATEAU 没有），
    // 导致大地图上所有满足 land_h/relief 条件的平坦中高海拔区全部标为 PLATEAU。
    // 现按连通分量面积从大到小累计，保留至 plateau_max_land_ratio × land 为止，
    // 其余较小连通分量整体降级为 HILL（保留大高原、清理碎片）。
    int plateau_demoted_to_hill = 0;
    if (plateau_max_land_ratio < 1.0) {
        std::vector<uint8_t> plat_seen(size_t(n), 0);
        std::vector<std::vector<int>> plat_comps;
        for (int i : land) {
            if (LF[i] != 13 || plat_seen[size_t(i)]) continue;
            std::vector<int> comp;
            comp.push_back(i);
            plat_seen[size_t(i)] = 1;
            for (size_t qi = 0; qi < comp.size(); ++qi) {
                const int cur = comp[qi];
                for (int d = 0; d < 6; ++d) {
                    const int ni = NB[size_t(cur) * 6 + d];
                    if (ni < 0 || plat_seen[size_t(ni)] || LF[ni] != 13) continue;
                    plat_seen[size_t(ni)] = 1;
                    comp.push_back(ni);
                }
            }
            plat_comps.push_back(std::move(comp));
        }
        std::sort(plat_comps.begin(), plat_comps.end(),
                [](const std::vector<int> &a, const std::vector<int> &b){ return a.size() > b.size(); });
        const int plateau_cap = std::max(0, int(double(land.size()) * plateau_max_land_ratio));
        int plateau_kept = 0;
        for (const auto &comp : plat_comps) {
            if (plateau_kept < plateau_cap) {
                plateau_kept += int(comp.size());
            } else {
                for (int v : comp) {
                    LF[v] = 6;   // HILL
                    BLF[v] = 6;
                    ++plateau_demoted_to_hill;
                }
            }
        }
    }

    // ── 峰顶(PEAK) landform sparsify：山脉是主体，高峰只保留局部 summit ──
    // 基础 landform helper 只能按单格海拔分段，容易把高海拔山原整片判成 PEAK。
    // 这里先退回为 MOUNTAIN，再按局部相对高度、邻域落差和最小间距选出少量真正峰顶。
    int peak_demoted = 0;
    for (int i : land) {
        if (LF[i] == 8) {
            LF[i] = 7;
            BLF[i] = 7;
            ++peak_demoted;
        }
    }
    struct PeakCandidate {
        int idx;
        double score;
    };
    std::vector<PeakCandidate> peak_candidates;
    peak_candidates.reserve(64);
    for (int i : land) {
        if (pk_is_water_terrain(TERR[i]) || VOLC[i] != 0) continue;
        if (TERR[i] == 22 || TERR[i] == 24 || TERR[i] == 25 || TERR[i] == 30) continue;
        const double lh = geomorph_h(i);
        if (lh < peak_min_land_h) continue;
        float min_nb = E[i];
        float max_nb = -1.0e9f;
        int land_nb = 0;
        int lower_prominent = 0;
        for (int d = 0; d < 6; ++d) {
            const int ni = NB[size_t(i) * 6 + d];
            if (ni < 0 || pk_is_water_terrain(TERR[ni])) continue;
            ++land_nb;
            min_nb = std::min(min_nb, E[ni]);
            max_nb = std::max(max_nb, E[ni]);
            if (double(E[i]) - double(E[ni]) >= peak_min_prominence) ++lower_prominent;
        }
        if (land_nb < 3) continue;
        const double relief = double(E[i]) - double(min_nb);
        const bool local_cap = double(E[i]) >= double(max_nb) - 0.006;
        if (!local_cap || lower_prominent < 2 || relief < peak_min_prominence) continue;
        peak_candidates.push_back({i, lh + relief * 2.0 + 0.01 * double(lower_prominent)});
    }
    std::sort(peak_candidates.begin(), peak_candidates.end(),
              [](const PeakCandidate &a, const PeakCandidate &b) {
                  if (a.score == b.score) return a.idx < b.idx;
                  return a.score > b.score;
              });
    const int peak_limit = std::max(1, int(land.size()) / peak_land_cells_per_peak);
    int peak_touched = 0;
    std::vector<int> peak_placed;
    peak_placed.reserve(size_t(peak_limit));
    for (const PeakCandidate &cand : peak_candidates) {
        if (peak_touched >= peak_limit) break;
        bool far_enough = true;
        for (int p : peak_placed) {
            if (cube_distance(cand.idx, p) < 3) { far_enough = false; break; }
        }
        if (!far_enough) continue;
        LF[cand.idx] = 8;
        BLF[cand.idx] = 8;
        peak_placed.push_back(cand.idx);
        ++peak_touched;
    }

    // ── 裂谷地貌(RIFT_VALLEY) override：两侧抬升夹住的连续线状洼地 ──
    // 局部剖面先确定两侧断崖方向，再只沿断崖之间的谷轴连接候选。裂谷是连续构造带，
    // 不使用全图数量、面积或格间距配额；最小物理长度仅过滤孤立洼点和短沟槽。
    int rift_touched = 0;
    int rift_candidate_count = 0;
    int rift_component_count = 0;
    int rift_rejected_fragment_count = 0;
    int rift_largest_component = 0;
    std::vector<uint8_t> rift_candidate(size_t(n), 0);
    std::vector<int8_t> rift_cross_axis(size_t(n), -1);
    for (int i = 0; i < n; ++i) {
        if (pk_is_water_terrain(TERR[i])) continue;
        if (LF[i] == 8 || LF[i] == 12 || LF[i] == 13) continue; // 高峰/火山/高原保留
        const double lh = geomorph_h(i);
        if (lh < 0.03 || lh > 0.72) continue;
        int higher = 0, land_nb = 0;
        double max_raise = 0.0;
        for (int d = 0; d < 6; ++d) {
            const int ni = NB[size_t(i) * 6 + d];
            if (ni < 0 || pk_is_water_terrain(TERR[ni])) continue;
            ++land_nb;
            const double raise = double(E[ni]) - double(E[i]);
            if (raise > rift_min_wall * (4.0 / 3.0)) ++higher;
            if (raise > max_raise) max_raise = raise;
        }
        if (land_nb < 3 || higher < 2 || max_raise < rift_min_wall * 1.875) continue;
        double best_axis = 0.0;
        int best_cross_axis = -1;
        for (int d = 0; d < 3; ++d) {
            const int a = NB[size_t(i) * 6 + d];
            const int b = NB[size_t(i) * 6 + ((d + 3) % 6)];
            if (a < 0 || b < 0 || pk_is_water_terrain(TERR[a]) || pk_is_water_terrain(TERR[b])) continue;
            const double ra = double(E[a]) - double(E[i]);
            const double rb = double(E[b]) - double(E[i]);
            if (ra <= rift_min_wall || rb <= rift_min_wall) continue;
            const double axis_score = std::min(ra, rb) + 0.35 * std::max(ra, rb);
            if (axis_score > best_axis) {
                best_axis = axis_score;
                best_cross_axis = d;
            }
        }
        if (best_axis < rift_min_axis || best_cross_axis < 0) continue;
        rift_candidate[size_t(i)] = 1;
        rift_cross_axis[size_t(i)] = int8_t(best_cross_axis);
        ++rift_candidate_count;
    }

    auto follows_rift_axis = [&](int cell, int dir) -> bool {
        const int cross = int(rift_cross_axis[size_t(cell)]);
        return cross >= 0 && dir != cross && dir != cross + 3;
    };
    std::vector<uint8_t> rift_seen(size_t(n), 0);
    for (int seed_cell : land) {
        if (!rift_candidate[size_t(seed_cell)] || rift_seen[size_t(seed_cell)]) continue;
        std::vector<int> component;
        component.push_back(seed_cell);
        rift_seen[size_t(seed_cell)] = 1;
        for (size_t qi = 0; qi < component.size(); ++qi) {
            const int cur = component[qi];
            for (int d = 0; d < 6; ++d) {
                const int ni = NB[size_t(cur) * 6 + d];
                if (ni < 0 || !rift_candidate[size_t(ni)] || rift_seen[size_t(ni)]) continue;
                if (!follows_rift_axis(cur, d) || !follows_rift_axis(ni, (d + 3) % 6)) continue;
                rift_seen[size_t(ni)] = 1;
                component.push_back(ni);
            }
        }
        ++rift_component_count;
        rift_largest_component = std::max(rift_largest_component, int(component.size()));

        int endpoint = component.front();
        int farthest_dist = -1;
        for (int cell : component) {
            const int dist = cube_distance(component.front(), cell);
            if (dist > farthest_dist) {
                farthest_dist = dist;
                endpoint = cell;
            }
        }
        int span_cells = 1;
        for (int cell : component) {
            span_cells = std::max(span_cells, cube_distance(endpoint, cell) + 1);
        }
        if (int(component.size()) < rift_min_length || span_cells < rift_min_length) {
            rift_rejected_fragment_count += int(component.size());
            continue;
        }
        for (int cell : component) {
            LF[cell] = 14;  // RIFT_VALLEY
            BLF[cell] = 14;
            ++rift_touched;
        }
    }

    // ── 峡谷(CANYON) override：河流深切、两壁陡立的线状侵蚀峡谷 ──
    // 与 BADLANDS(干旱软岩片状恶地)、RIFT_VALLEY(构造离散边界裂谷) 三者区分：
    //   * CANYON 必须有河道穿过(RIV != 0)，且对置两侧都有明显陡壁(河流下切成 gorge)；
    //   * 不限定干旱，湿润山区的深切河谷(如长江三峡型)也成峡谷；
    //   * 跑在 rift 之后并跳过已写入的结构性地貌，避免与裂谷/高原/高峰重复占用。
    const double canyon_min_wall = getd(profile, "canyon_min_wall", 0.05);
    const double canyon_min_axis = getd(profile, "canyon_min_axis", 0.06);
    int canyon_touched = 0;
    for (int i : land) {
        if (pk_is_water_terrain(TERR[i])) continue;
        if (RIV[i] == 0) continue;                                   // 必须有河道穿过
        if (LF[i] == 8 || LF[i] == 12 || LF[i] == 13 || LF[i] == 14) continue; // 峰/火山/高原/裂谷保留
        const double lh = geomorph_h(i);
        if (lh < 0.05 || lh > 0.85) continue;
        int land_nb = 0, higher = 0;
        double max_raise = 0.0;
        for (int d = 0; d < 6; ++d) {
            const int ni = NB[size_t(i) * 6 + d];
            if (ni < 0 || pk_is_water_terrain(TERR[ni])) continue;
            ++land_nb;
            const double raise = double(E[ni]) - double(E[i]);
            if (raise > canyon_min_wall) ++higher;
            if (raise > max_raise) max_raise = raise;
        }
        if (land_nb < 3 || higher < 2 || max_raise < canyon_min_wall) continue;
        // 对置轴：河谷两壁都明显抬升 → gorge（区别于单侧山坡上的河道）。
        double best_axis = 0.0;
        for (int d = 0; d < 3; ++d) {
            const int a = NB[size_t(i) * 6 + d];
            const int b = NB[size_t(i) * 6 + ((d + 3) % 6)];
            if (a < 0 || b < 0 || pk_is_water_terrain(TERR[a]) || pk_is_water_terrain(TERR[b])) continue;
            const double ra = double(E[a]) - double(E[i]);
            const double rb = double(E[b]) - double(E[i]);
            if (ra <= canyon_min_wall * 0.5 || rb <= canyon_min_wall * 0.5) continue;
            best_axis = std::max(best_axis, std::min(ra, rb) + 0.35 * std::max(ra, rb));
        }
        if (best_axis < canyon_min_axis) continue;
        LF[i] = 15;  // CANYON
        BLF[i] = 15;
        ++canyon_touched;
    }

    const PackedFloat32Array ideal_t_arr = profile.get("veg_ideal_temp", PackedFloat32Array());
    const PackedFloat32Array ideal_m_arr = profile.get("veg_ideal_moist", PackedFloat32Array());
    const PackedFloat32Array tol_t_arr = profile.get("veg_temp_tol", PackedFloat32Array());
    const PackedFloat32Array tol_m_arr = profile.get("veg_moist_tol", PackedFloat32Array());
    const bool have_veg_profiles = ideal_t_arr.size() >= 28 && ideal_m_arr.size() >= 28 &&
                                   tol_t_arr.size() >= 28 && tol_m_arr.size() >= 28;
    const float min_suitability = float(std::clamp(getd(profile, "vegetation_min_suitability", 0.18), 0.0, 1.0));
    const float tie_epsilon = float(std::max(0.0, getd(profile, "vegetation_tie_epsilon", 1e-6)));
    const float water_balance_weight = float(std::max(0.01, getd(profile, "plant_water_balance_weight", 0.35)));
    const float soil_buffer_weight = float(std::max(0.01, getd(profile, "plant_soil_buffer_weight", 0.30)));
    const float drought_penalty = float(std::max(0.01, getd(profile, "plant_drought_penalty", 0.25)));
    int vegetation_candidate_count = 0;
    int vegetation_none_count = 0;
    int vegetation_biome_reconciled_count = 0;
    int plant_water_nonzero_land_count = 0;
    int river_adjacent_desert_count = 0;
    int coastal_highland_desert_count = 0;
    double vegetation_score_sum = 0.0;
    float vegetation_score_min = 1.0f;
    float vegetation_score_max = 0.0f;
    float terrain_soft_weight_min = 1.25f;
    float terrain_soft_weight_max = 0.35f;
    const auto vegetation_t0 = std::chrono::high_resolution_clock::now();

    for (int i = 0; i < n; ++i) {
        const double temp_gen = gen_temp(i);
        TEMP[i] = float(temp_gen); // The same coastal-adjusted source used by terrain.
        T30[i] = TEMP[i];
        T365[i] = TEMP[i];
        const float delta = std::clamp(M[i] - BM[i], -0.5f, 0.5f);
        float wb30 = 0.0f;
        float soil = 0.0f;
        if (delta >= 0.0f) {
            wb30 = std::clamp(delta * 0.60f / water_balance_weight, 0.0f, 0.5f);
            soil = std::clamp(delta * 0.40f / soil_buffer_weight, 0.0f, 0.5f);
        } else {
            wb30 = std::clamp(delta / drought_penalty, -0.5f, 0.0f);
        }
        const float plant_water = std::clamp(
            BM[i] + std::max(wb30, 0.0f) * water_balance_weight +
            std::max(soil, 0.0f) * soil_buffer_weight +
            std::min(wb30, 0.0f) * drought_penalty, 0.0f, 1.0f);
        WB30[i] = wb30;
        SOIL[i] = soil;
        PLANT_WATER[i] = plant_water;
        if (IW[i] == 0 && plant_water > 0.01f) ++plant_water_nonzero_land_count;

        uint8_t selected = 0;
        float best_score = 0.0f;
        float current_score = 0.0f;
        if (IW[i] != 0) {
            // Water vegetation is a physical substrate constraint.
            if (TERR[i] == 1 && temp_gen > 0.42 && temp_gen < 0.74) selected = 26; // seagrass
            else if (TERR[i] == 19) selected = 23; // coral reef
            else if (TERR[i] == 21) selected = 22; // kelp forest
        } else if (TERR[i] != 17 && TERR[i] != 24 && have_veg_profiles) {
            for (uint8_t v = 1; v < 28; ++v) {
                if (!pk_vegetation_candidate_allowed(TERR[i], v)) continue;
                const float climate = pk_vegetation_climate_score_for_type(
                    v, TEMP[i], plant_water, ideal_t_arr[v], ideal_m_arr[v], tol_t_arr[v], tol_m_arr[v]);
                const float terrain_weight = pk_vegetation_terrain_weight(TERR[i], LF[i], v, plant_water);
                terrain_soft_weight_min = std::min(terrain_soft_weight_min, terrain_weight);
                terrain_soft_weight_max = std::max(terrain_soft_weight_max, terrain_weight);
                const float score = climate * terrain_weight;
                if (score > best_score + tie_epsilon) {
                    best_score = score;
                    selected = v;
                }
            }
            if (best_score < min_suitability) selected = 0;
            ++vegetation_candidate_count;
        } else if (IW[i] == 0) {
            selected = pk_derive_vegetation(TERR[i], LF[i], TEMP[i], M[i]);
            best_score = selected == 0 ? 0.0f : 0.5f;
        }

        // Keep ecological lag for compatible transitions, but repair an
        // obviously cross-biome winner before publishing the initial state.
        if (selected != 0 && pk_vegetation_needs_biome_reconcile(TERR[i], selected)) {
            const uint8_t repaired = pk_derive_vegetation(TERR[i], LF[i], TEMP[i], M[i]);
            if (repaired != selected) {
                selected = repaired;
                ++vegetation_biome_reconciled_count;
            }
        }

        if (have_veg_profiles && selected > 0 && selected < 28) {
            best_score = pk_vegetation_climate_score_for_type(
                selected, TEMP[i], plant_water, ideal_t_arr[selected], ideal_m_arr[selected],
                tol_t_arr[selected], tol_m_arr[selected]) *
                pk_vegetation_terrain_weight(TERR[i], LF[i], selected, plant_water);
            const uint8_t previous = BVEG[i];
            if (previous > 0 && previous < 28 && previous != 22 && previous != 23 && previous != 26) {
                current_score = pk_vegetation_climate_score_for_type(
                    previous, TEMP[i], plant_water, ideal_t_arr[previous], ideal_m_arr[previous],
                    tol_t_arr[previous], tol_m_arr[previous]) *
                    pk_vegetation_terrain_weight(TERR[i], LF[i], previous, plant_water);
            }
        }
        VEG[i] = selected;
        BVEG[i] = selected;
        if (selected == 0) ++vegetation_none_count;

        if (selected > 0) {
            const float vitality = std::clamp(0.15f + 0.85f * best_score, 0.0f, 1.0f);
            VITALITY[i] = vitality;
            VREGEN[i] = std::clamp(best_score, 0.0f, 1.0f);
            VG_PRESSURE[i] = std::clamp(best_score - current_score, 0.0f, 1.0f);
            if (have_veg_profiles && selected < 28) {
                const float tt = std::max(tol_t_arr[selected], 0.05f);
                const float tm = std::max(tol_m_arr[selected], 0.05f);
                VHEAT[i] = std::clamp((TEMP[i] - ideal_t_arr[selected] - tt) / tt, 0.0f, 1.0f);
                VCOLD[i] = std::clamp((ideal_t_arr[selected] - tt - TEMP[i]) / tt, 0.0f, 1.0f);
                VDROUGHT[i] = std::clamp((ideal_m_arr[selected] - tm - plant_water) / tm, 0.0f, 1.0f);
            } else {
                VHEAT[i] = 0.0f;
                VCOLD[i] = 0.0f;
                VDROUGHT[i] = 0.0f;
            }
            vegetation_score_sum += best_score;
            vegetation_score_min = std::min(vegetation_score_min, best_score);
            vegetation_score_max = std::max(vegetation_score_max, best_score);
        } else {
            VITALITY[i] = 0.0f;
            VG_PRESSURE[i] = 0.0f;
            VHEAT[i] = 0.0f;
            VDROUGHT[i] = 0.0f;
            VCOLD[i] = 0.0f;
            VREGEN[i] = 0.0f;
        }
        if (selected == 17 && (RIV[i] != 0 || [&]() {
                for (int d = 0; d < 6; ++d) { const int ni = NB[size_t(i) * 6 + d]; if (ni >= 0 && RIV[ni] != 0) return true; }
                return false;
            }())) {
            ++river_adjacent_desert_count;
        }
        if ((LF[i] == 6 || LF[i] == 7 || LF[i] == 8 || LF[i] == 13) &&
            !dist_ocean.empty() && dist_ocean[size_t(i)] >= 0 && dist_ocean[size_t(i)] <= 2 &&
            (selected == 16 || selected == 17)) {
            ++coastal_highland_desert_count;
        }
    }
    const auto vegetation_t1 = std::chrono::high_resolution_clock::now();
    const double vegetation_native_ms =
        std::chrono::duration<double, std::milli>(vegetation_t1 - vegetation_t0).count();

    int water_count = 0;
    int volcano_count = 0;
    int desert_class_count = 0;
    int cold_desert_count = 0;
    int plateau_count = 0;
    int peak_count = 0;
    int rift_count = 0;
    int highland_river_count = 0;
    int mountain_peak_river_count = 0;
    int xeric_desert_count = 0;
    int shrubland_count = 0;
    int mangrove_count = 0;
    int moor_count = 0;
    for (int i = 0; i < n; ++i) {
        if (IW[i]) ++water_count;
        if (VOLC[i]) ++volcano_count;
        if (TERR[i] == 7 || TERR[i] == 24 || TERR[i] == 25 || TERR[i] == 30 || TERR[i] == 26) ++desert_class_count;
        if (TERR[i] == 26) ++cold_desert_count;
        if (LF[i] == 13) ++plateau_count;
        if (LF[i] == 8) ++peak_count;
        if (LF[i] == 14) ++rift_count;
        if (RIV[i] != 0 && (LF[i] == 6 || LF[i] == 7 || LF[i] == 8 || LF[i] == 13)) ++highland_river_count;
        if (RIV[i] != 0 && (LF[i] == 7 || LF[i] == 8)) ++mountain_peak_river_count;
        if (VEG[i] == 17) ++xeric_desert_count;
        if (TERR[i] == 15) ++shrubland_count;
        if (TERR[i] == 16) ++mangrove_count;
        if (TERR[i] == 28) ++moor_count;
    }

    const auto t1 = std::chrono::high_resolution_clock::now();
    const double elapsed_ms = std::chrono::duration<double, std::milli>(t1 - t0).count();

    out["rc"] = 0;
    out["status"] = String("completed");
    out["path"] = String("gdext");
    out["fallback"] = false;
    out["fallback_reason"] = String();
    out["reason"] = String();
    out["fail_stage"] = String();
    out["published_to_slot"] = false;
    out["n_cells"] = n;
    out["width"] = width;
    out["height"] = height;
    out["seed"] = seed;
    out["water_count"] = water_count;
    out["land_count"] = n - water_count;
    out["lake_count"] = lake_count;
    out["river_count"] = river_count;
    out["volcano_count"] = volcano_count;
    out["elapsed_ms"] = elapsed_ms;
    out["native_ms"] = elapsed_ms;
    out["compute_ms"] = elapsed_ms;
    out["generation_progress"] = 1.0;

    // ── QA 度量（生成诊断，无行为副作用，t1 之后计算不计入 native_ms）──
    // 连通分量分析最终水体 → 抓单格海洋；陆地低于海平面比例；biome 香农熵；河流占比。
    // 作为每阶段改造的回归基线（GDScript 端会 print 出来）。
    Dictionary qa_metrics;
    {
        std::vector<uint8_t> seen_qa(size_t(n), 0);
        std::vector<int> stack_qa;
        stack_qa.reserve(256);
        int single_water = 0;   // size == 1
        int tiny_water = 0;     // size <= 3
        int small_water = 0;    // size <= 5
        int water_bodies = 0;
        int largest_water = 0;
        for (int i = 0; i < n; ++i) {
            if (IW[i] == 0 || seen_qa[size_t(i)]) continue;
            stack_qa.clear();
            stack_qa.push_back(i);
            seen_qa[size_t(i)] = 1;
            int sz = 0;
            while (!stack_qa.empty()) {
                const int cur = stack_qa.back();
                stack_qa.pop_back();
                ++sz;
                for (int d = 0; d < 6; ++d) {
                    const int ni = NB[size_t(cur) * 6 + d];
                    if (ni >= 0 && IW[ni] != 0 && !seen_qa[size_t(ni)]) {
                        seen_qa[size_t(ni)] = 1;
                        stack_qa.push_back(ni);
                    }
                }
            }
            ++water_bodies;
            if (sz == 1) ++single_water;
            if (sz <= 3) ++tiny_water;
            if (sz <= 5) ++small_water;
            if (sz > largest_water) largest_water = sz;
        }
        int land_below_sea = 0;
        int terr_hist[64] = {0};
        for (int i = 0; i < n; ++i) {
            if (IW[i] == 0 && double(E[i]) < sea_level) ++land_below_sea;
            const uint8_t t = TERR[i];
            if (t < 64) ++terr_hist[t];
        }
        double entropy = 0.0;
        int distinct_terr = 0;
        for (int t = 0; t < 64; ++t) {
            if (terr_hist[t] <= 0) continue;
            ++distinct_terr;
            const double p = double(terr_hist[t]) / double(n);
            entropy -= p * std::log2(p);
        }
        const int land_count_qa = n - water_count;
        qa_metrics["water_bodies"] = water_bodies;
        qa_metrics["single_tile_water"] = single_water;
        qa_metrics["tiny_water_le3"] = tiny_water;
        qa_metrics["small_water_le5"] = small_water;
        qa_metrics["largest_water_body"] = largest_water;
        qa_metrics["land_below_sealevel"] = land_below_sea;
        qa_metrics["land_below_sealevel_ratio"] = (land_count_qa > 0) ? double(land_below_sea) / double(land_count_qa) : 0.0;
        qa_metrics["terrain_entropy_bits"] = entropy;
        qa_metrics["terrain_distinct"] = distinct_terr;
        qa_metrics["river_ratio"] = (n > 0) ? double(river_count) / double(n) : 0.0;
        qa_metrics["badlands_land_ratio"] = (land_count_qa > 0)
                ? double(badlands_touched) / double(land_count_qa) : 0.0;
        qa_metrics["badlands_arid_ratio"] = (arid_source_count > 0)
                ? double(badlands_touched) / double(arid_source_count) : 0.0;
        qa_metrics["badlands_largest_component"] = badlands_largest_component;
    }
    out["qa_metrics"] = qa_metrics;

    Dictionary stage_counts;
    stage_counts["rain_shadow"] = rain_shadow_touched;
    stage_counts["redecide"] = redecide_touched;
    stage_counts["final_climate_redecide"] = final_climate_redecide_touched;
    stage_counts["headwater_river"] = headwater_touched;
    stage_counts["river_lake_snap"] = river_lake_snap_touched;
    stage_counts["river_confluence_snap"] = river_confluence_snap_touched;
    stage_counts["coast_wave_erosion"] = coast_erosion_touched;
    stage_counts["river_ecology"] = river_ecology_touched;
    stage_counts["river_desert_repaired"] = river_desert_repaired;
    stage_counts["river_floodplain_channel"] = river_floodplain_channel_touched;
    stage_counts["vegetation_feedback"] = vegetation_feedback_touched;
    stage_counts["shrubland"] = shrubland_touched;
    stage_counts["mangrove"] = mangrove_touched;
    stage_counts["glacier"] = glacier_touched;
    stage_counts["swamp"] = swamp_touched;
    stage_counts["delta"] = delta_touched;
    stage_counts["oasis"] = oasis_touched;
    stage_counts["salt_flat"] = salt_flat_touched;
    stage_counts["badlands"] = badlands_touched;
    stage_counts["badlands_candidates"] = badlands_candidate_count;
    stage_counts["badlands_budget_rejected"] = badlands_budget_rejected;
    stage_counts["mesa"] = mesa_touched;
    stage_counts["floodplain"] = floodplain_touched;
    stage_counts["moor"] = moor_touched;
    stage_counts["chaparral"] = chaparral_touched;
    stage_counts["plateau"] = plateau_touched;
    stage_counts["plateau_candidates"] = plateau_candidate_count;
    stage_counts["plateau_demoted_to_hill"] = plateau_demoted_to_hill;
    stage_counts["mountain_demoted"] = mountain_demoted;
    stage_counts["mountain_to_plateau"] = mountain_to_plateau;
    stage_counts["mountain_height_candidates"] = mountain_height_candidates;
    stage_counts["mountain_relief_candidates"] = mountain_relief_candidates;
    stage_counts["mountain_kept"] = mountain_kept;
    stage_counts["peak_summit"] = peak_touched;
    stage_counts["peak_candidates"] = int(peak_candidates.size());
    stage_counts["peak_demoted"] = peak_demoted;
    stage_counts["rift_valley"] = rift_touched;
    stage_counts["canyon"] = canyon_touched;
    stage_counts["reef"] = reef_touched;
    stage_counts["kelp"] = kelp_touched;
    stage_counts["pelagic_bloom"] = pelagic_touched;
    stage_counts["isolated_water_drained"] = isolated_water_drained;
    stage_counts["isolated_water_to_lake"] = isolated_water_to_lake;
    out["stage_counts"] = stage_counts;


    out["river_map_reference_cells"] = river_map_reference_cells;
    out["river_map_scale"] = river_map_scale;
    out["river_map_scale_exponent"] = river_map_scale_exponent;
    // [scale-fix 2026-07-30] 分辨率归一诊断：验证时核对 s / relief 阈值缩放 / 等效流量系数
    out["gen_dist_scale"] = gen_dist_scale;
    out["relief_thresh_scale"] = relief_thresh_scale;
    out["relief_thresh_scale_exp"] = relief_thresh_scale_exp;
    out["mountain_min_relief_effective"] = mountain_min_relief;
    out["badlands_min_relief_effective"] = badlands_min_relief;
    out["flow_eq_scale"] = flow_eq_scale;
    out["rain_shadow_lookback_effective"] = lookback;
    out["river_channel_init_base"] = river_channel_init_base;
    out["river_channel_init_effective"] = channel_init;
    out["river_headwater_init_base"] = river_headwater_init_base;
    out["river_headwater_init_effective"] = river_headwater_init;
    out["hydro_river_min_length_base"] = hydro_river_min_length_base;
    out["hydro_river_min_length_effective"] = hydro_river_min_length;
    out["river_flow_threshold"] = double(river_threshold);
    out["river_ecology_source_count"] = water_src_river;
    out["lakeshore_moist_touched"] = lakeshore_moist_touched;
    out["riparian_moist_touched"] = riparian_moist_touched;
    out["final_climate_redecide_evaluated"] = final_climate_redecide_evaluated;
    out["final_climate_redecide_touched"] = final_climate_redecide_touched;
    out["river_lake_snap_count"] = river_lake_snap_touched;
    out["river_confluence_snap_count"] = river_confluence_snap_touched;
    out["desert_class_count"] = desert_class_count;
    out["rift_candidate_count"] = rift_candidate_count;
    out["mountain_height_candidates"] = mountain_height_candidates;
    out["mountain_relief_candidates"] = mountain_relief_candidates;
    out["mountain_kept"] = mountain_kept;
    out["peak_candidate_count"] = int(peak_candidates.size());
    out["plateau_candidate_count"] = plateau_candidate_count;
    out["rift_component_count"] = rift_component_count;
    out["rift_rejected_fragment_count"] = rift_rejected_fragment_count;
    out["rift_largest_component"] = rift_largest_component;
    out["rift_min_length_effective"] = rift_min_length;
    out["badlands_arid_source_count"] = arid_source_count;
    out["badlands_candidate_count"] = badlands_candidate_count;
    out["badlands_candidate_components"] = badlands_candidate_components;
    out["badlands_selected_count"] = badlands_touched;
    out["badlands_budget"] = badlands_budget;
    out["badlands_budget_rejected"] = badlands_budget_rejected;
    out["badlands_largest_component"] = badlands_largest_component;
    out["cold_desert_count"] = cold_desert_count;
    out["plateau_count"] = plateau_count;
    out["peak_count"] = peak_count;
    out["rift_valley_count"] = rift_count;
    out["highland_river_count"] = highland_river_count;
    out["mountain_peak_river_count"] = mountain_peak_river_count;
    out["xeric_desert_count"] = xeric_desert_count;
    out["shrubland_count"] = shrubland_count;
    out["mangrove_count"] = mangrove_count;
    out["moor_count"] = moor_count;
    out["vegetation_candidate_count"] = vegetation_candidate_count;
    out["vegetation_biome_reconciled_count"] = vegetation_biome_reconciled_count;
    out["vegetation_native_ms"] = vegetation_native_ms;
    out["vegetation_none_count"] = vegetation_none_count;
    out["vegetation_score_min"] = vegetation_candidate_count > vegetation_none_count ? vegetation_score_min : 0.0f;
    out["vegetation_score_mean"] = vegetation_candidate_count > 0
        ? float(vegetation_score_sum / double(std::max(1, vegetation_candidate_count))) : 0.0f;
    out["vegetation_score_max"] = vegetation_score_max;
    out["plant_water_nonzero_land_count"] = plant_water_nonzero_land_count;
    out["river_adjacent_desert_count"] = river_adjacent_desert_count;
    out["coastal_highland_desert_count"] = coastal_highland_desert_count;
    out["terrain_soft_weight_min"] = vegetation_candidate_count > 0 ? terrain_soft_weight_min : 0.0f;
    out["terrain_soft_weight_max"] = vegetation_candidate_count > 0 ? terrain_soft_weight_max : 0.0f;

    out["q_arr"] = q_arr;
    out["r_arr"] = r_arr;
    out["s_arr"] = s_arr;
    out["elevation_arr"] = elevation_arr;
    out["moisture_arr"] = moisture_arr;
    out["base_moisture_arr"] = base_moisture_arr;
    out["temp_arr"] = temp_arr;
    out["temp_baseline_arr"] = temp_baseline_arr;
    out["temp_30d_arr"] = temp_30d_arr;
    out["temp_365d_arr"] = temp_365d_arr;
    out["temp_anomaly_arr"] = temp_anomaly_arr;
    out["thermal_energy_arr"] = thermal_energy_arr;
    out["cell_lat_norm_arr"] = cell_lat_norm_arr;
    out["temp_baseline_year_arr"] = temp_baseline_year_arr;
    out["snow_cover_arr"] = snow_cover_arr;
    // 透传 base pass 生成的湖泊种子标记（仅 UI 信息面板用，post_base 不改写）。
    out["is_lake_seed_arr"] = input.get("is_lake_seed_arr", PackedByteArray());
    out["terrain_arr"] = terrain_arr;
    out["base_terrain_arr"] = base_terrain_arr;
    out["landform_arr"] = landform_arr;
    out["base_landform_arr"] = base_landform_arr;
    out["vegetation_arr"] = vegetation_arr;
    out["base_vegetation_arr"] = base_vegetation_arr;
    out["vegetation_vitality_arr"] = vegetation_vitality_arr;
    out["soil_moisture_arr"] = soil_moisture_arr;
    out["water_balance_30d_arr"] = water_balance_30d_arr;
    out["plant_available_water_arr"] = plant_available_water_arr;
    out["vegetation_growth_pressure_arr"] = vegetation_growth_pressure_arr;
    out["vegetation_heat_stress_arr"] = vegetation_heat_stress_arr;
    out["vegetation_drought_stress_arr"] = vegetation_drought_stress_arr;
    out["vegetation_cold_stress_arr"] = vegetation_cold_stress_arr;
    out["vegetation_regen_score_arr"] = vegetation_regen_score_arr;
    out["cover_arr"] = cover_arr;
    out["is_water_arr"] = is_water_arr;
    out["has_river_arr"] = has_river_arr;
    out["river_flow_arr"] = river_flow_arr;
    out["river_downstream_arr"] = river_downstream_arr;
    out["hydro_parent_arr"] = hydro_parent_arr;
    out["has_volcano_arr"] = has_volcano_arr;
    out["ema_initialized_arr"] = ema_initialized_arr;
    out["water_depth_arr"] = water_depth_arr;   // [water-depth-tex] 海/湖统一归一水深 ∈ [0,1]
    if (upwelling_arr.size() == n) out["upwelling_strength_arr"] = upwelling_arr;

    // ─── 暂存河流拓扑到 ext 成员（dots-total-cpp step1）──────────────────
    // 供同一 generation ext 实例的 run_bake_river_sdf_pass 直接 trace（零跨语言再传输）。
    // terrain/elevation/river_flow 此处均为 post_base 最终值；NB 是已建好的 n*6 邻居索引。
    {
        _gen_river_n = n;
        _gen_river_q.assign(size_t(n), 0);
        _gen_river_r.assign(size_t(n), 0);
        _gen_river_terrain.assign(size_t(n), 0);
        _gen_river_elev.assign(size_t(n), 0.0f);
        _gen_river_has.assign(size_t(n), 0);
        _gen_river_flow.assign(size_t(n), 0.0f);
        _gen_river_downstream.assign(size_t(n), -1);
        _gen_river_neighbors.assign(size_t(n) * 6, -1);
        for (int i = 0; i < n; ++i) {
            _gen_river_q[size_t(i)] = Q[i];
            _gen_river_r[size_t(i)] = R[i];
            _gen_river_terrain[size_t(i)] = TERR[i];
            _gen_river_elev[size_t(i)] = E[i];
            _gen_river_has[size_t(i)] = RIV[i];
            _gen_river_flow[size_t(i)] = RFLOW_OUT[i];
            _gen_river_downstream[size_t(i)] = RDOWN[i];
        }
        for (size_t k = 0; k < size_t(n) * 6; ++k) _gen_river_neighbors[k] = NB[k];
    }

    return out;
}

Dictionary DCWorldExt::_run_native_generation_publish_pass(
    int seed,
    const Dictionary &cfg,
    const Dictionary &profile,
    const Dictionary &budget) {
    Dictionary out;
    out["rc"] = -1;
    out["status"] = String("failed");
    out["path"] = String("gdscript_fallback");
    out["fallback"] = true;
    out["fallback_reason"] = String();
    out["reason"] = String();
    out["fail_stage"] = String();
    out["seed"] = seed;
    out["has_config"] = !cfg.is_empty();
    out["has_profile"] = !profile.is_empty();
    out["implemented"] = true;
    out["published_to_slot"] = false;
    out["published_slots"] = Array();
    out["n_cells"] = 0;
    out["elapsed_ms"] = -1.0;
    out["native_ms"] = -1.0;
    out["compute_ms"] = 0.0;
    out["flush_ms"] = 0.0;
    out["generation_progress"] = 0.0;
    if (!budget.is_empty()) {
        out["budget"] = budget.duplicate(true);
    }

    auto fail = [&](const String &why, const String &stage = String("native_generation_publish")) -> Dictionary {
        out["fallback_reason"] = why;
        out["reason"] = why;
        out["fail_stage"] = stage;
        _native_generation_report = out.duplicate(true);
        return out;
    };

    if (!_bound || _map_data == nullptr) {
        return fail("not_bound", "bind_map_data");
    }

    const double sea_level = double(cfg.get("sea_level", 0.5));
    int n_cells = int(cfg.get("cell_count", 0));
    if (n_cells <= 0) {
        n_cells = _native_world_cell_count;
    }
    if (n_cells <= 0) {
        n_cells = _entity_count;
    }

    struct RequiredSlot {
        const char *name;
        SlotDType dtype;
        int sid = -1;
    };
    RequiredSlot req[] = {
        {"cell_lat_norm", SlotDType::F32, -1},
        {"cell_elevation", SlotDType::F32, -1},
        {"cell_temp_baseline_year", SlotDType::F32, -1},
        {"cell_temp", SlotDType::F32, -1},
        {"cell_temp_baseline", SlotDType::F32, -1},
        {"cell_temp_30d", SlotDType::F32, -1},
        {"cell_temp_365d", SlotDType::F32, -1},
        {"cell_base_moisture", SlotDType::F32, -1},
        {"cell_water_balance_30d", SlotDType::F32, -1},
        {"cell_temp_anomaly", SlotDType::F32, -1},
        {"cell_thermal_energy", SlotDType::F32, -1},
        {"cell_terrain", SlotDType::U8, -1},
        {"cell_is_water", SlotDType::U8, -1},
        {"cell_ema_initialized", SlotDType::U8, -1},
    };

    for (RequiredSlot &r : req) {
        r.sid = component_id(StringName(r.name));
        if (r.sid < 0 || r.sid >= _slots.size()) {
            String msg = String("missing_slot: ") + String(r.name);
            return fail(msg, "slot_lookup");
        }
        const Slot &s = _slots.write[r.sid];
        if (s.dtype != r.dtype) {
            String msg = String("slot_dtype_mismatch: ") + String(r.name);
            return fail(msg, "slot_dtype");
        }
        const int sz = (r.dtype == SlotDType::F32) ? s.arr_f32.size() : s.arr_u8.size();
        if (n_cells <= 0) {
            n_cells = sz;
        }
        if (sz != n_cells) {
            String msg = String("slot_size_mismatch: ") + String(r.name)
                + String(" size=") + String::num_int64(sz)
                + String(" expected=") + String::num_int64(n_cells);
            return fail(msg, "slot_size");
        }
    }
    if (n_cells <= 0) {
        return fail("empty_world", "slot_size");
    }

    auto sid_of = [&](const char *name) -> int {
        for (const RequiredSlot &r : req) {
            if (std::strcmp(r.name, name) == 0) {
                return r.sid;
            }
        }
        return -1;
    };

    const int sid_lat = sid_of("cell_lat_norm");
    const int sid_elev = sid_of("cell_elevation");
    const int sid_temp_year = sid_of("cell_temp_baseline_year");
    const int sid_temp = sid_of("cell_temp");
    const int sid_temp_baseline = sid_of("cell_temp_baseline");
    const int sid_temp_30d = sid_of("cell_temp_30d");
    const int sid_temp_365d = sid_of("cell_temp_365d");
    const int sid_temp_anom = sid_of("cell_temp_anomaly");
    const int sid_thermal = sid_of("cell_thermal_energy");
    const int sid_terrain = sid_of("cell_terrain");
    const int sid_is_water = sid_of("cell_is_water");
    const int sid_ema = sid_of("cell_ema_initialized");

    const float * const __restrict LAT = _slots.write[sid_lat].arr_f32.ptr();
    const float * const __restrict ELEV = _slots.write[sid_elev].arr_f32.ptr();
    const uint8_t * const __restrict TERR = _slots.write[sid_terrain].arr_u8.ptr();
    float * const __restrict TEMP_YEAR = _slots.write[sid_temp_year].arr_f32.ptrw();
    float * const __restrict TEMP = _slots.write[sid_temp].arr_f32.ptrw();
    float * const __restrict TEMP_BASE = _slots.write[sid_temp_baseline].arr_f32.ptrw();
    float * const __restrict TEMP_30D = _slots.write[sid_temp_30d].arr_f32.ptrw();
    float * const __restrict TEMP_365D = _slots.write[sid_temp_365d].arr_f32.ptrw();
    float * const __restrict TEMP_ANOM = _slots.write[sid_temp_anom].arr_f32.ptrw();
    float * const __restrict THERMAL = _slots.write[sid_thermal].arr_f32.ptrw();
    uint8_t * const __restrict IS_WATER = _slots.write[sid_is_water].arr_u8.ptrw();
    uint8_t * const __restrict EMA = _slots.write[sid_ema].arr_u8.ptrw();

    const auto t0 = std::chrono::high_resolution_clock::now();
    const auto tc0 = std::chrono::high_resolution_clock::now();
    int water_count = 0;
    for (int i = 0; i < n_cells; ++i) {
        const float ny = LAT[i];
        const float elev = ELEV[i];
        const float year = float(pk_clamp01(pk_lat_temp_bell((double(ny) - 0.5) * 2.0)));
        const float boot_temp = pk_compute_temperature(double(ny), double(elev), sea_level);
        const uint8_t water = pk_is_water_terrain(TERR[i]) ? uint8_t(1) : uint8_t(0);

        TEMP_YEAR[i] = year;
        TEMP[i] = boot_temp;
        TEMP_BASE[i] = boot_temp;
        TEMP_30D[i] = boot_temp;
        TEMP_365D[i] = boot_temp;
        TEMP_ANOM[i] = 0.0f;
        THERMAL[i] = boot_temp;
        EMA[i] = 1;
        IS_WATER[i] = water;
        water_count += int(water);
    }
    const auto tc1 = std::chrono::high_resolution_clock::now();

    Array published_slots;
    auto flush_publish = [&](int sid, const char *name) {
        if (sid >= 0) {
            _flush_slot_to_map(sid);
            published_slots.append(String(name));
        }
    };
    const auto tf0 = std::chrono::high_resolution_clock::now();
    flush_publish(sid_temp_year, "cell_temp_baseline_year");
    flush_publish(sid_temp, "cell_temp");
    flush_publish(sid_temp_baseline, "cell_temp_baseline");
    flush_publish(sid_temp_30d, "cell_temp_30d");
    flush_publish(sid_temp_365d, "cell_temp_365d");
    flush_publish(sid_temp_anom, "cell_temp_anomaly");
    flush_publish(sid_thermal, "cell_thermal_energy");
    flush_publish(sid_ema, "cell_ema_initialized");
    flush_publish(sid_is_water, "cell_is_water");
    const auto tf1 = std::chrono::high_resolution_clock::now();
    const auto t1 = std::chrono::high_resolution_clock::now();

    const double compute_ms = std::chrono::duration<double, std::milli>(tc1 - tc0).count();
    const double flush_ms = std::chrono::duration<double, std::milli>(tf1 - tf0).count();
    const double elapsed_ms = std::chrono::duration<double, std::milli>(t1 - t0).count();

    out["rc"] = 0;
    out["status"] = String("completed");
    out["path"] = String("gdext");
    out["fallback"] = false;
    out["fallback_reason"] = String();
    out["reason"] = String();
    out["fail_stage"] = String();
    out["published_to_slot"] = true;
    out["published_slots"] = published_slots;
    out["published_temp_baseline_year"] = true;
    out["n_cells"] = n_cells;
    out["water_count"] = water_count;
    out["land_count"] = n_cells - water_count;
    out["elapsed_ms"] = elapsed_ms;
    out["native_ms"] = elapsed_ms;
    out["compute_ms"] = compute_ms;
    out["flush_ms"] = flush_ms;
    out["generation_progress"] = 1.0;
    out["cfg_width"] = int(cfg.get("width", 0));
    out["cfg_height"] = int(cfg.get("height", 0));
    out["profile_keys"] = profile.keys();
    _native_generation_report = out.duplicate(true);
    return out;
}

godot::Dictionary DCWorldExt::run_season_refresh_stage(godot::Dictionary knobs) {
    using godot::Dictionary;
    using godot::PackedFloat32Array;
    using godot::String;
    using godot::StringName;

    Dictionary out;
    out["stage"] = int(knobs.get("stage", 8));
    out["elapsed_ms"] = -1.0;
    out["fallback"] = true;
    out["reason"] = String();

    auto fail = [&](const char *why) -> Dictionary {
        out["reason"] = String(why);
        UtilityFunctions::push_warning("[DCWorldExt] run_season_refresh_stage: ", why,
                                       " - fallback to GDScript");
        return out;
    };

    if (!_bound) return fail("not bound");
    const int stage = int(knobs.get("stage", 8));
    // DOTS-Total-CPP（task-item.md 任务 2）：扩展 stage 分发到 0 / 8 / 10。
    // - stage 0 (moisture set)  ：纯 SoA loop，直接 C++。
    // - stage 8 (sync_current_state)：本函数原有实装。
    // - stage 10 (feedback decay)   ：knobs in/out 走 soil_moisture_arr /
    //   veg_growth_pressure_arr（SoA schema 未含），与 run_climate_feedback_pass 同模式。
    // - stage 1/2/3/4/5/6/7/9 ：依赖 terrain decision tree + apply_terrain multi-axis
    //   sync + RenderingServer，按 plan/dots-total-cpp/requirements.md §8.4 标 TODO，
    //   GDScript caller 仍走 fallback。
    // TODO(dots-total-cpp): stage 1/2/3/4/5/6/7 完整 C++ 化（需复刻 WindBelt /
    //                       _decide_terrain / _is_permanent_landform / apply_terrain）。
    if (stage == 0) {
        if (!knobs.has("n_cells") || !knobs.has("moist_scale")) {
            return fail("stage_0 missing required knob (n_cells / moist_scale)");
        }
        const int n_cells = int(knobs["n_cells"]);
        const double moist_scale = double(knobs["moist_scale"]);
        if (n_cells <= 0) return fail("stage_0 n_cells <= 0");

        const int sid_terrain      = component_id(StringName("cell_terrain"));
        const int sid_moist        = component_id(StringName("cell_moisture"));
        const int sid_base_m       = component_id(StringName("cell_base_moisture"));
        if (sid_terrain < 0 || sid_moist < 0 || sid_base_m < 0) {
            return fail("stage_0 missing slot id (terrain/moisture/base_moisture)");
        }
        Slot &s_t = _slots.write[sid_terrain];
        Slot &s_m = _slots.write[sid_moist];
        Slot &s_bm = _slots.write[sid_base_m];
        if (s_t.arr_u8.size() != n_cells || s_m.arr_f32.size() != n_cells ||
            s_bm.arr_f32.size() != n_cells) {
            return fail("stage_0 slot array size mismatch");
        }
        const uint8_t * const __restrict TERR = s_t.arr_u8.ptr();
        const float   * const __restrict BASE = s_bm.arr_f32.ptr();
        float         * const __restrict M    = s_m.arr_f32.ptrw();

        auto t0 = std::chrono::high_resolution_clock::now();
        for (int i = 0; i < n_cells; ++i) {
            if (pk_is_water_terrain(TERR[i])) {
                M[i] = BASE[i];
            } else {
                double m = double(BASE[i]) * moist_scale;
                if (m < 0.0) m = 0.0;
                else if (m > 1.0) m = 1.0;
                M[i] = float(m);
            }
        }
        _flush_slot_to_map(sid_moist);

        auto t1 = std::chrono::high_resolution_clock::now();
        out["elapsed_ms"] = std::chrono::duration<double, std::milli>(t1 - t0).count();
        out["fallback"] = false;
        out["reason"] = String();
        out["touched"] = n_cells;
        return out;
    }
    if (stage == 10) {
        if (!knobs.has("n_cells") || !knobs.has("decay") ||
            !knobs.has("soil_moisture_arr") || !knobs.has("veg_growth_pressure_arr")) {
            return fail("stage_10 missing required knob (n_cells/decay/soil_moisture_arr/veg_growth_pressure_arr)");
        }
        const int n_cells = int(knobs["n_cells"]);
        const double decay = double(knobs["decay"]);
        if (n_cells <= 0) return fail("stage_10 n_cells <= 0");

        const int sid_terrain = component_id(StringName("cell_terrain"));
        const int sid_base_m  = component_id(StringName("cell_base_moisture"));
        if (sid_terrain < 0 || sid_base_m < 0) {
            return fail("stage_10 missing slot id (terrain/base_moisture)");
        }
        Slot &s_t = _slots.write[sid_terrain];
        Slot &s_bm = _slots.write[sid_base_m];
        if (s_t.arr_u8.size() != n_cells || s_bm.arr_f32.size() != n_cells) {
            return fail("stage_10 slot array size mismatch (terrain/base_moisture)");
        }
        PackedFloat32Array soil_arr = knobs["soil_moisture_arr"];
        PackedFloat32Array vg_arr   = knobs["veg_growth_pressure_arr"];
        if (soil_arr.size() != n_cells || vg_arr.size() != n_cells) {
            return fail("stage_10 soil/vg arr size mismatch");
        }

        const uint8_t * const __restrict TERR = s_t.arr_u8.ptr();
        float         * const __restrict BASE = s_bm.arr_f32.ptrw();
        float         * const __restrict SOIL = soil_arr.ptrw();
        float         * const __restrict VG   = vg_arr.ptrw();
        constexpr double FEEDBACK_SOIL_TO_BASE_W = 0.15;

        auto t0 = std::chrono::high_resolution_clock::now();
        int touched = 0;
        for (int i = 0; i < n_cells; ++i) {
            if (pk_is_water_terrain(TERR[i])) continue;
            const double sm = double(SOIL[i]);
            if (sm > 1e-4 || sm < -1e-4) {
                double bm = double(BASE[i]) + FEEDBACK_SOIL_TO_BASE_W * sm;
                if (bm < 0.0) bm = 0.0;
                else if (bm > 1.0) bm = 1.0;
                BASE[i] = float(bm);
                ++touched;
            }
            SOIL[i] = float(sm * decay);
            VG[i]   = float(double(VG[i]) * decay);
        }
        _flush_slot_to_map(sid_base_m);
        // 写回 in/out arrays（让 GDScript caller 看到 decayed 后的值）
        knobs["soil_moisture_arr"] = soil_arr;
        knobs["veg_growth_pressure_arr"] = vg_arr;

        auto t1 = std::chrono::high_resolution_clock::now();
        out["elapsed_ms"] = std::chrono::duration<double, std::milli>(t1 - t0).count();
        out["fallback"] = false;
        out["reason"] = String();
        out["touched"] = touched;
        return out;
    }
    // ─── stage 1：rain_shadow_per_cell ────────────────────────────────────
    // SAME_SOURCE: map_generator.gd::_apply_rain_shadow_per_cell (line 3149).
    // 流程：陆地 cell → wind_vector 优先 / WindBelt fallback → upwind hex dir
    // → lookback N 步 → 若上风 cell 海拔高 threshold → moisture *= factor。
    if (stage == 1) {
        if (!knobs.has("n_cells") || !knobs.has("rain_shadow_lookback") ||
            !knobs.has("rain_shadow_threshold") || !knobs.has("rain_shadow_factor") ||
            !knobs.has("neighbor_indices") || !knobs.has("season_phase") ||
            !knobs.has("jitter_arr")) {
            return fail("stage_1 missing required knob");
        }
        const int n_cells = int(knobs["n_cells"]);
        const int lookback = std::max(0, int(knobs["rain_shadow_lookback"]));
        const float threshold = float(knobs["rain_shadow_threshold"]);
        const float factor = float(knobs["rain_shadow_factor"]);
        const double season_phase = double(knobs["season_phase"]);
        if (n_cells <= 0) return fail("stage_1 n_cells <= 0");

        const int sid_terrain = component_id(StringName("cell_terrain"));
        const int sid_moist   = component_id(StringName("cell_moisture"));
        const int sid_elev    = component_id(StringName("cell_elevation"));
        const int sid_wx      = component_id(StringName("cell_wind_x"));
        const int sid_wy      = component_id(StringName("cell_wind_y"));
        const int sid_lat     = component_id(StringName("cell_lat_norm"));
        if (sid_terrain < 0 || sid_moist < 0 || sid_elev < 0 ||
            sid_wx < 0 || sid_wy < 0 || sid_lat < 0) {
            return fail("stage_1 missing slot id");
        }
        Slot &s_t = _slots.write[sid_terrain];
        Slot &s_m = _slots.write[sid_moist];
        Slot &s_e = _slots.write[sid_elev];
        Slot &s_wx = _slots.write[sid_wx];
        Slot &s_wy = _slots.write[sid_wy];
        Slot &s_lat = _slots.write[sid_lat];
        if (s_t.arr_u8.size() != n_cells || s_m.arr_f32.size() != n_cells ||
            s_e.arr_f32.size() != n_cells || s_wx.arr_f32.size() != n_cells ||
            s_wy.arr_f32.size() != n_cells || s_lat.arr_f32.size() != n_cells) {
            return fail("stage_1 slot size mismatch");
        }
        godot::PackedInt32Array nb_arr = knobs["neighbor_indices"];
        if (nb_arr.size() < n_cells * 6) return fail("stage_1 neighbor_indices size mismatch");
        godot::PackedFloat32Array jitter_arr = knobs["jitter_arr"];
        if (jitter_arr.size() != n_cells) return fail("stage_1 jitter_arr size mismatch");

        const uint8_t * const __restrict TERR = s_t.arr_u8.ptr();
        float         * const __restrict M    = s_m.arr_f32.ptrw();
        const float   * const __restrict ELEV = s_e.arr_f32.ptr();
        const float   * const __restrict WX   = s_wx.arr_f32.ptr();
        const float   * const __restrict WY   = s_wy.arr_f32.ptr();
        const float   * const __restrict LAT  = s_lat.arr_f32.ptr();
        const int32_t * const __restrict NB   = nb_arr.ptr();
        const float   * const __restrict JITTER = jitter_arr.ptr();

        // 6 hex 方向（与 pk_upwind_dir_index_from_wind 内 DIRS 同源），
        // 用于把 wind 向量映射到 0..5 索引。
        constexpr int DIRS[6][3] = {
            { 1,  0, -1}, { 1, -1,  0}, { 0, -1,  1},
            {-1,  0,  1}, {-1,  1,  0}, { 0,  1, -1},
        };
        constexpr double inv_sqrt2 = 0.7071067811865475;

        auto pick_dir_from_wind = [&](double wx, double wy) -> int {
            const double len2 = wx * wx + wy * wy;
            if (len2 <= 0.0001) return -1;
            const double inv_len = 1.0 / std::sqrt(len2);
            const double nx = wx * inv_len;
            const double ny_ = wy * inv_len;
            const double wq = std::sqrt(3.0) / 3.0 * nx - ny_ / 3.0;
            const double wr = 2.0 / 3.0 * ny_;
            const double ws = -wq - wr;
            const double clen = std::sqrt(wq * wq + wr * wr + ws * ws);
            if (clen <= 0.0001) return -1;
            const double uq = -wq / clen;
            const double ur = -wr / clen;
            const double us = -ws / clen;
            int best = 0;
            double best_dot = -std::numeric_limits<double>::infinity();
            for (int d = 0; d < 6; ++d) {
                const double dot = uq * double(DIRS[d][0]) * inv_sqrt2
                                 + ur * double(DIRS[d][1]) * inv_sqrt2
                                 + us * double(DIRS[d][2]) * inv_sqrt2;
                if (dot > best_dot) { best_dot = dot; best = d; }
            }
            return best;
        };

        auto t0 = std::chrono::high_resolution_clock::now();
        int touched = 0;
        for (int i = 0; i < n_cells; ++i) {
            if (pk_is_water_terrain(TERR[i])) continue;
            if (lookback <= 0) continue;
            int dir;
            // 先用 cell.wind_vector（地形扰动后的实际盛行风），与 _pick_upwind_dir 一致。
            const double cell_wx = double(WX[i]);
            const double cell_wy = double(WY[i]);
            const double wv_len2 = cell_wx * cell_wx + cell_wy * cell_wy;
            if (wv_len2 > 0.0001) { // wv.length() > 0.01 等价
                dir = pick_dir_from_wind(cell_wx, cell_wy);
            } else {
                // Fallback：WindBelt.wind_at(ny, season_phase, lat_jitter)
                const double ny = double(LAT[i]);
                const double jitter = double(JITTER[i]);
                const PkWind2 w = pk_wind_belt_wind_at(ny, season_phase, jitter);
                dir = pick_dir_from_wind(double(w.x), double(w.y));
            }
            if (dir < 0) continue;

            int probe = i;
            for (int step = 0; step < lookback; ++step) {
                const int ni = NB[probe * 6 + dir];
                if (ni < 0) { probe = -1; break; }
                probe = ni;
            }
            if (probe < 0) continue;
            if (ELEV[probe] > ELEV[i] + threshold) {
                M[i] = M[i] * factor;
                ++touched;
            }
        }
        _flush_slot_to_map(sid_moist);

        auto t1 = std::chrono::high_resolution_clock::now();
        out["elapsed_ms"] = std::chrono::duration<double, std::milli>(t1 - t0).count();
        out["fallback"] = false;
        out["reason"] = String();
        out["touched"] = touched;
        return out;
    }

    // ─── stage 2：seasonal_redecide_terrain ───────────────────────────────
    // SAME_SOURCE: map_generator.gd::_seasonal_redecide_terrain (line 2474).
    // 流程：非永久气候 / 非永久地标 → 用 temp_365d + base_moisture/water_balance_30d
    //       算慢时间尺度 biome 气候 → _decide_terrain → apply_terrain（写 terrain + 派生 landform）。
    //       瞬时 moisture 只供实时气候；vegetation/cover 由后续慢速演替阶段维护。
    if (stage == 2) {
        if (!knobs.has("n_cells") || !knobs.has("height") || !knobs.has("sea_level") ||
            !knobs.has("lat_temp_rows") || !knobs.has("season_offset_rows") ||
            !knobs.has("row_indices")) {
            return fail("stage_2 missing required knob");
        }
        const int n_cells = int(knobs["n_cells"]);
        const int height = int(knobs["height"]);
        const float sea_level = float(knobs["sea_level"]);
        if (n_cells <= 0 || height <= 0) return fail("stage_2 invalid dims");

        godot::PackedFloat32Array lat_tab = knobs["lat_temp_rows"];
        godot::PackedFloat32Array off_tab = knobs["season_offset_rows"];
        godot::PackedInt32Array row_idx = knobs["row_indices"];
        if (lat_tab.size() < height || off_tab.size() < height) return fail("stage_2 row tables size");
        if (row_idx.size() != n_cells) return fail("stage_2 row_indices size");

        const int sid_terrain   = component_id(StringName("cell_terrain"));
        const int sid_base_t    = component_id(StringName("cell_base_terrain"));
        const int sid_elev      = component_id(StringName("cell_elevation"));
        const int sid_moist     = component_id(StringName("cell_moisture"));
        const int sid_base_m    = component_id(StringName("cell_base_moisture"));
        const int sid_wb30      = component_id(StringName("cell_water_balance_30d"));
        const int sid_landform  = component_id(StringName("cell_landform"));
        const int sid_vegetation= component_id(StringName("cell_vegetation"));
        const int sid_cover     = component_id(StringName("cell_cover"));
        const int sid_snow      = component_id(StringName("cell_snow_cover"));
        const int sid_is_water  = component_id(StringName("cell_is_water"));
        if (sid_terrain < 0 || sid_base_t < 0 || sid_elev < 0 || sid_moist < 0 ||
            sid_base_m < 0 || sid_wb30 < 0 ||
            sid_landform < 0 || sid_vegetation < 0 || sid_cover < 0 || sid_snow < 0 ||
            sid_is_water < 0) {
            return fail("stage_2 missing slot id");
        }
        Slot &s_t  = _slots.write[sid_terrain];
        Slot &s_bt = _slots.write[sid_base_t];
        Slot &s_e  = _slots.write[sid_elev];
        Slot &s_m  = _slots.write[sid_moist];
        Slot &s_bm = _slots.write[sid_base_m];
        Slot &s_wb = _slots.write[sid_wb30];
        Slot &s_lf = _slots.write[sid_landform];
        Slot &s_vg = _slots.write[sid_vegetation];
        Slot &s_cv = _slots.write[sid_cover];
        Slot &s_sn = _slots.write[sid_snow];
        Slot &s_iw = _slots.write[sid_is_water];
        if (s_t.arr_u8.size() != n_cells || s_bt.arr_u8.size() != n_cells ||
            s_e.arr_f32.size() != n_cells || s_m.arr_f32.size() != n_cells ||
            s_bm.arr_f32.size() != n_cells || s_wb.arr_f32.size() != n_cells ||
            s_lf.arr_u8.size() != n_cells || s_vg.arr_u8.size() != n_cells ||
            s_cv.arr_u8.size() != n_cells || s_sn.arr_f32.size() != n_cells ||
            s_iw.arr_u8.size() != n_cells) {
            return fail("stage_2 slot size mismatch");
        }

        uint8_t       * const __restrict TERR  = s_t.arr_u8.ptrw();
        const uint8_t * const __restrict BTERR = s_bt.arr_u8.ptr();
        const float   * const __restrict ELEV  = s_e.arr_f32.ptr();
        const float   * const __restrict MOIST = s_m.arr_f32.ptr();
        const float   * const __restrict BASE_MOIST = s_bm.arr_f32.ptr();
        const float   * const __restrict WB30 = s_wb.arr_f32.ptr();
        const int sid_temp_365d = component_id(StringName("cell_temp_365d"));
        if (sid_temp_365d < 0 || _slots.write[sid_temp_365d].arr_f32.size() != n_cells) {
            return fail("stage_2 temp_365d slot size mismatch");
        }
        const float * const __restrict TEMP365 = _slots.write[sid_temp_365d].arr_f32.ptr();
        uint8_t       * const __restrict LF    = s_lf.arr_u8.ptrw();
        uint8_t       * const __restrict VG    = s_vg.arr_u8.ptrw();
        uint8_t       * const __restrict CV    = s_cv.arr_u8.ptrw();
        uint8_t       * const __restrict IW    = s_iw.arr_u8.ptrw();

        const float   * const __restrict SNOW  = s_sn.arr_f32.ptr();
        const float   * const __restrict LATT  = lat_tab.ptr();
        const float   * const __restrict OFFT  = off_tab.ptr();
        const int32_t * const __restrict ROWI  = row_idx.ptr();
        const float biome_wet_weight = std::max(0.0f, float(knobs.get("biome_water_balance_weight", 0.35)));
        const float biome_dry_penalty = std::max(0.0f, float(knobs.get("biome_drought_penalty", 0.25)));

        auto t0 = std::chrono::high_resolution_clock::now();
        int touched = 0;
        const int max_row = height - 1;
        for (int i = 0; i < n_cells; ++i) {
            const uint8_t cur = TERR[i];
            const uint8_t bt = BTERR[i];
            if (pk_is_water_terrain(cur)) {
                if (!pk_is_water_terrain(bt)) {
                    TERR[i] = bt;
                    LF[i] = pk_derive_landform(bt, ELEV[i], sea_level);
                    IW[i] = pk_is_water_terrain(bt) ? uint8_t(1) : uint8_t(0);
                    ++touched;

                }
                continue;
            }
            uint8_t new_t;

            if (bt == 9) { // SNOW base = 永久 SNOW
                new_t = bt;
            } else if (pk_is_permanent_landform(bt)) {
                new_t = bt;
            } else {
                int row = ROWI[i];
                if (row < 0) row = 0;
                else if (row > max_row) row = max_row;
                const double e = double(ELEV[i]);
                const double temp_year = pk_clamp01(double(TEMP365[i]));
                const double biome_moisture = pk_clamp01(
                    double(BASE_MOIST[i])
                    + std::max(double(WB30[i]), 0.0) * double(biome_wet_weight)
                    + std::min(double(WB30[i]), 0.0) * double(biome_dry_penalty));
                new_t = pk_decide_terrain(e, temp_year, biome_moisture,
                                          double(sea_level));
                // 生成期已排干/回填的内陆低洼陆地仍保留原始 below-sea elevation；
                // runtime 季节重判不得把非水地块重新判回 COAST/OCEAN。
                if (pk_is_water_terrain(new_t) && !pk_is_water_terrain(cur)) {
                    new_t = !pk_is_water_terrain(bt) ? bt : cur;
                }
            }
            if (new_t != cur) ++touched;

            TERR[i] = new_t;
            IW[i] = pk_is_water_terrain(new_t) ? uint8_t(1) : uint8_t(0);
            // apply_terrain multi-axis sync（与 hex_cell.gd::apply_terrain 一致：

            // terrain 写后，三轴派生由 _sync_axes 完成。这里用 stage 8 同款 derive 路径。）
            uint8_t lf_new = pk_derive_landform(new_t, ELEV[i], sea_level);
            // 结构性地貌保留（与 stage 8 sync_current_state 同口径）：生成期通过多格邻域
            // 起伏分析写入的 PEAK(8)/VOLCANO(12)/PLATEAU(13)/RIFT_VALLEY(14)/CANYON(15)
            // 无法由单格 pk_derive_landform 复现，季节重判必须保留，否则首个 refresh round
            // 就会把高原/高峰/裂谷/峡谷整片塌缩成朴素 MOUNTAIN/HILL（见 tile_data 实测）。
            const uint8_t prev_lf = LF[i];
            if (prev_lf == 8 || prev_lf == 12 || prev_lf == 13 || prev_lf == 14 || prev_lf == 15) {
                lf_new = prev_lf;
            }
            LF[i] = lf_new;
            // vegetation 用当前 moisture + 季节温度（temp 由 stage 8 写，这里
            // 用 lat_tab 行温度 + off 近似；与 GDScript _seasonal_redecide_terrain
            // 路径不调用 _sync_axes_for_cell（只 apply_terrain），但下游 stage 9
            // 会 sync）。为保持 bit-equal：仅写 terrain + landform，veg/cover 留给
            // stage 9 (sync_current_state) 统一处理。
            (void)VG; (void)CV; (void)SNOW;
        }
        _flush_slot_to_map(sid_terrain);
        _flush_slot_to_map(sid_landform);
        _flush_slot_to_map(sid_is_water);

        (void)MOIST;
        (void)LATT;
        (void)OFFT;
        (void)ROWI;

        auto t1 = std::chrono::high_resolution_clock::now();
        out["elapsed_ms"] = std::chrono::duration<double, std::milli>(t1 - t0).count();
        out["fallback"] = false;
        out["reason"] = String();
        out["touched"] = touched;
        return out;
    }

    // ─── stage 3：river_ecology ───────────────────────────────────────────

    // SAME_SOURCE: map_generator.gd::_apply_river_ecology (line 3190).
    // 流程：has_river && 非水 → moisture=max(moist, 0.66~0.72)；
    //       河流穿越沙漠/恶地/寒漠时转为 FLOODPLAIN / OASIS / STEPPE；
    //       低地河道优先形成 FLOODPLAIN，避免大河边继续保持荒漠群系。
    if (stage == 3) {
        if (!knobs.has("n_cells") || !knobs.has("height") || !knobs.has("sea_level") ||
            !knobs.has("row_indices")) {
            return fail("stage_3 missing required knob");
        }
        const int n_cells = int(knobs["n_cells"]);
        const int height = int(knobs["height"]);
        const float sea_level = float(knobs["sea_level"]);
        if (n_cells <= 0 || height <= 1) return fail("stage_3 invalid dims");
        godot::PackedInt32Array row_idx = knobs["row_indices"];
        if (row_idx.size() != n_cells) return fail("stage_3 row_indices size");

        const int sid_terrain  = component_id(StringName("cell_terrain"));
        const int sid_moist    = component_id(StringName("cell_moisture"));
        const int sid_elev     = component_id(StringName("cell_elevation"));
        const int sid_river    = component_id(StringName("cell_has_river"));
        const int sid_rflow    = component_id(StringName("cell_river_flow"));
        const int sid_landform = component_id(StringName("cell_landform"));
        if (sid_terrain < 0 || sid_moist < 0 || sid_elev < 0 || sid_river < 0 || sid_rflow < 0 ||
            sid_landform < 0) {
            return fail("stage_3 missing slot id");
        }
        Slot &s_t = _slots.write[sid_terrain];
        Slot &s_m = _slots.write[sid_moist];
        Slot &s_e = _slots.write[sid_elev];
        Slot &s_r = _slots.write[sid_river];
        Slot &s_rf= _slots.write[sid_rflow];
        Slot &s_lf= _slots.write[sid_landform];
        if (s_t.arr_u8.size() != n_cells || s_m.arr_f32.size() != n_cells ||
            s_e.arr_f32.size() != n_cells || s_r.arr_u8.size() != n_cells ||
            s_rf.arr_f32.size() != n_cells ||
            s_lf.arr_u8.size() != n_cells) {
            return fail("stage_3 slot size mismatch");
        }

        uint8_t       * const __restrict TERR = s_t.arr_u8.ptrw();
        float         * const __restrict M    = s_m.arr_f32.ptrw();
        const float   * const __restrict ELEV = s_e.arr_f32.ptr();
        const uint8_t * const __restrict RIV  = s_r.arr_u8.ptr();
        const float   * const __restrict RFLOW= s_rf.arr_f32.ptr();
        uint8_t       * const __restrict LF   = s_lf.arr_u8.ptrw();
        const int32_t * const __restrict ROWI = row_idx.ptr();
        const int max_row = height - 1;
        const double inv_max_row = 1.0 / double(max_row > 0 ? max_row : 1);

        auto t0 = std::chrono::high_resolution_clock::now();
        int touched = 0;
        for (int i = 0; i < n_cells; ++i) {
            if (RIV[i] == 0) continue;
            const uint8_t t = TERR[i];
            if (pk_is_water_terrain(t)) continue;
            int row = ROWI[i];
            if (row < 0) row = 0;
            else if (row > max_row) row = max_row;
            const double ny = double(row) * inv_max_row;
            const double temp = double(pk_compute_temperature(ny, double(ELEV[i]), double(sea_level)));
            const double inv_above_sea = 1.0 / std::max(1.0 - double(sea_level), 0.001);
            const double lh = (double(ELEV[i]) - double(sea_level)) * inv_above_sea;
            const bool strong_river = RFLOW[i] >= 0.55f;
            const bool lowland_river = lh <= 0.18 || (strong_river && lh <= 0.28);
            const float target_m = strong_river ? 0.72f : 0.66f;
            if (M[i] < target_m) { M[i] = target_m; ++touched; }
            if (t == 22 || t == 23 || t == 29) continue;

            uint8_t new_t = t;
            if (t == 7 || t == 24 || t == 25 || t == 26 || t == 30) {
                if (lowland_river) new_t = 29;        // FLOODPLAIN
                else if (strong_river && temp > 0.35) new_t = 23; // OASIS
                else if (temp > 0.30) new_t = 14;     // STEPPE riparian buffer
            } else if (!pk_is_permanent_landform(t)) {
                if (lowland_river && (t == 2 || t == 3 || t == 12 || t == 14 || t == 15)) {
                    new_t = 29; // FLOODPLAIN
                } else if (t == 2) {
                    if (temp > 0.55) new_t = strong_river ? uint8_t(11) : uint8_t(4);
                    else if (temp > 0.30) new_t = strong_river ? uint8_t(29) : uint8_t(3);
                }
            }
            if (new_t != t) {
                TERR[i] = new_t;
                LF[i] = pk_derive_landform_preserve(new_t, ELEV[i], sea_level, LF[i]);
                ++touched;
            }
        }
        _flush_slot_to_map(sid_terrain);
        _flush_slot_to_map(sid_moist);
        _flush_slot_to_map(sid_landform);

        auto t1 = std::chrono::high_resolution_clock::now();
        out["elapsed_ms"] = std::chrono::duration<double, std::milli>(t1 - t0).count();
        out["fallback"] = false;
        out["reason"] = String();
        out["touched"] = touched;
        return out;
    }

    // ─── stage 4：vegetation_feedback ─────────────────────────────────────
    // SAME_SOURCE: map_generator.gd::_apply_vegetation_feedback (line 3269).
    // 流程：1) 累加 donor 邻居 delta（陆地，elev_factor=clamp(1-elev*decay,0.1,1)）
    //       2) 应用 delta 到瞬时 moisture（限幅，供实时气候/vegetation）
    //       3) 重决策非永久 biome（不动 MOUNTAIN/SNOW/permanent_landform），
    //          仍使用 temp_365d + base_moisture/water_balance_30d，避免 donor 短期写入抖动 biome。
    if (stage == 4) {
        if (!knobs.has("n_cells") || !knobs.has("height") || !knobs.has("sea_level") ||
            !knobs.has("lat_temp_rows") || !knobs.has("row_indices") ||
            !knobs.has("neighbor_indices") || !knobs.has("donor_table") ||
            !knobs.has("elev_decay")) {
            return fail("stage_4 missing required knob");
        }
        const int n_cells = int(knobs["n_cells"]);
        const int height = int(knobs["height"]);
        const float sea_level = float(knobs["sea_level"]);
        const double elev_decay = double(knobs["elev_decay"]);
        if (n_cells <= 0 || height <= 0) return fail("stage_4 invalid dims");

        godot::PackedFloat32Array lat_tab = knobs["lat_temp_rows"];
        godot::PackedInt32Array row_idx = knobs["row_indices"];
        godot::PackedInt32Array nb_arr = knobs["neighbor_indices"];
        // donor_table[26]：每种 terrain 的 donor 强度（陆地非 donor=0）。
        godot::PackedFloat32Array donor_tab = knobs["donor_table"];
        if (lat_tab.size() < height) return fail("stage_4 lat_temp_rows size");
        if (row_idx.size() != n_cells) return fail("stage_4 row_indices size");
        if (nb_arr.size() < n_cells * 6) return fail("stage_4 neighbor_indices size");
        if (donor_tab.size() < 26) return fail("stage_4 donor_table size < 26");

        const int sid_terrain  = component_id(StringName("cell_terrain"));
        const int sid_moist    = component_id(StringName("cell_moisture"));
        const int sid_base_m   = component_id(StringName("cell_base_moisture"));
        const int sid_wb30     = component_id(StringName("cell_water_balance_30d"));
        const int sid_temp365  = component_id(StringName("cell_temp_365d"));
        const int sid_elev     = component_id(StringName("cell_elevation"));
        const int sid_landform = component_id(StringName("cell_landform"));
        if (sid_terrain < 0 || sid_moist < 0 || sid_base_m < 0 || sid_wb30 < 0 ||
            sid_temp365 < 0 || sid_elev < 0 || sid_landform < 0) {
            return fail("stage_4 missing slot id");
        }
        Slot &s_t = _slots.write[sid_terrain];
        Slot &s_m = _slots.write[sid_moist];
        Slot &s_bm = _slots.write[sid_base_m];
        Slot &s_wb = _slots.write[sid_wb30];
        Slot &s_t365 = _slots.write[sid_temp365];
        Slot &s_e = _slots.write[sid_elev];
        Slot &s_lf= _slots.write[sid_landform];
        if (s_t.arr_u8.size() != n_cells || s_m.arr_f32.size() != n_cells ||
            s_bm.arr_f32.size() != n_cells || s_wb.arr_f32.size() != n_cells ||
            s_t365.arr_f32.size() != n_cells ||
            s_e.arr_f32.size() != n_cells || s_lf.arr_u8.size() != n_cells) {
            return fail("stage_4 slot size mismatch");
        }

        uint8_t       * const __restrict TERR = s_t.arr_u8.ptrw();
        float         * const __restrict M    = s_m.arr_f32.ptrw();
        const float   * const __restrict BASE_MOIST = s_bm.arr_f32.ptr();
        const float   * const __restrict WB30 = s_wb.arr_f32.ptr();
        const float   * const __restrict TEMP365 = s_t365.arr_f32.ptr();
        const float   * const __restrict ELEV = s_e.arr_f32.ptr();
        uint8_t       * const __restrict LF   = s_lf.arr_u8.ptrw();
        const int32_t * const __restrict NB   = nb_arr.ptr();
        const float   * const __restrict DTAB = donor_tab.ptr();
        const float biome_wet_weight = std::max(0.0f, float(knobs.get("biome_water_balance_weight", 0.35)));
        const float biome_dry_penalty = std::max(0.0f, float(knobs.get("biome_drought_penalty", 0.25)));

        auto t0 = std::chrono::high_resolution_clock::now();
        // pass 1：累加 delta（per-target sum）
        std::vector<float> deltas(size_t(n_cells), 0.0f);
        for (int i = 0; i < n_cells; ++i) {
            const uint8_t t = TERR[i];
            const float donor = (t < 26) ? DTAB[t] : 0.0f;
            if (donor == 0.0f) continue;
            double elev_factor = 1.0 - double(ELEV[i]) * elev_decay;
            if (elev_factor < 0.1) elev_factor = 0.1;
            else if (elev_factor > 1.0) elev_factor = 1.0;
            const float donor_eff = float(double(donor) * elev_factor);
            for (int d = 0; d < 6; ++d) {
                const int ni = NB[i * 6 + d];
                if (ni < 0) continue;
                if (pk_is_water_terrain(TERR[ni])) continue;
                deltas[size_t(ni)] += donor_eff;
            }
        }
        // pass 2：应用 delta（陆地 only，限幅）
        for (int i = 0; i < n_cells; ++i) {
            if (pk_is_water_terrain(TERR[i])) continue;
            const float d = deltas[size_t(i)];
            if (d == 0.0f) continue;
            double m = double(M[i]) + double(d);
            if (m < 0.0) m = 0.0;
            else if (m > 1.0) m = 1.0;
            M[i] = float(m);
        }
        // pass 3：redecide（慢气候输入；不动 MOUNTAIN/SNOW/permanent_landform）
        int touched = 0;
        for (int i = 0; i < n_cells; ++i) {
            const uint8_t cur = TERR[i];
            if (pk_is_water_terrain(cur)) continue;
            if (cur == 6 || cur == 9) continue;            // MOUNTAIN/SNOW
            if (pk_is_permanent_landform(cur)) continue;
            const double e = double(ELEV[i]);
            const double temp = pk_clamp01(double(TEMP365[i]));
            const double biome_moisture = pk_clamp01(
                double(BASE_MOIST[i])
                + std::max(double(WB30[i]), 0.0) * double(biome_wet_weight)
                + std::min(double(WB30[i]), 0.0) * double(biome_dry_penalty));
            uint8_t new_t = pk_decide_terrain(e, temp, biome_moisture,
                                              double(sea_level));
            if (pk_is_water_terrain(new_t) && !pk_is_water_terrain(cur)) {
                new_t = cur;
            }
            if (new_t != cur) {
                TERR[i] = new_t;

                LF[i] = pk_derive_landform_preserve(new_t, ELEV[i], sea_level, LF[i]);
                ++touched;
            }
        }
        _flush_slot_to_map(sid_terrain);
        _flush_slot_to_map(sid_moist);
        _flush_slot_to_map(sid_landform);

        auto t1 = std::chrono::high_resolution_clock::now();
        out["elapsed_ms"] = std::chrono::duration<double, std::milli>(t1 - t0).count();
        out["fallback"] = false;
        out["reason"] = String();
        out["touched"] = touched;
        return out;
    }

    // ─── stage 5：shrubland_pass ──────────────────────────────────────────
    // SAME_SOURCE: map_generator.gd::_apply_shrubland_pass (line 3374).
    // 触发：陆地 + (GRASSLAND/STEPPE/SAVANNA/PLAIN) + !permanent_landform
    //   + land_h<=0.30 + temp>=0.50 + moisture∈[0.25, 0.40]
    //   + 至少 1 个 OCEAN/COAST 邻居 → SHRUBLAND(15)
    if (stage == 5) {
        if (!knobs.has("n_cells") || !knobs.has("height") || !knobs.has("sea_level") ||
            !knobs.has("row_indices") || !knobs.has("neighbor_indices")) {
            return fail("stage_5 missing required knob");
        }
        const int n_cells = int(knobs["n_cells"]);
        const int height = int(knobs["height"]);
        const float sea_level = float(knobs["sea_level"]);
        if (n_cells <= 0 || height <= 1) return fail("stage_5 invalid dims");
        godot::PackedInt32Array row_idx = knobs["row_indices"];
        godot::PackedInt32Array nb_arr = knobs["neighbor_indices"];
        if (row_idx.size() != n_cells) return fail("stage_5 row_indices size");
        if (nb_arr.size() < n_cells * 6) return fail("stage_5 neighbor_indices size");

        const int sid_terrain  = component_id(StringName("cell_terrain"));
        const int sid_moist    = component_id(StringName("cell_moisture"));
        const int sid_elev     = component_id(StringName("cell_elevation"));
        const int sid_landform = component_id(StringName("cell_landform"));
        if (sid_terrain < 0 || sid_moist < 0 || sid_elev < 0 || sid_landform < 0) {
            return fail("stage_5 missing slot id");
        }
        Slot &s_t = _slots.write[sid_terrain];
        Slot &s_m = _slots.write[sid_moist];
        Slot &s_e = _slots.write[sid_elev];
        Slot &s_lf= _slots.write[sid_landform];
        if (s_t.arr_u8.size() != n_cells || s_m.arr_f32.size() != n_cells ||
            s_e.arr_f32.size() != n_cells || s_lf.arr_u8.size() != n_cells) {
            return fail("stage_5 slot size mismatch");
        }

        uint8_t       * const __restrict TERR = s_t.arr_u8.ptrw();
        const float   * const __restrict M    = s_m.arr_f32.ptr();
        const float   * const __restrict ELEV = s_e.arr_f32.ptr();
        uint8_t       * const __restrict LF   = s_lf.arr_u8.ptrw();
        const int32_t * const __restrict NB   = nb_arr.ptr();
        const int32_t * const __restrict ROWI = row_idx.ptr();
        const int max_row = height - 1;
        const double inv_max_row = 1.0 / double(max_row > 0 ? max_row : 1);
        const double inv_above_sea = 1.0 / std::max(1.0 - double(sea_level), 0.001);

        auto t0 = std::chrono::high_resolution_clock::now();
        int touched = 0;
        for (int i = 0; i < n_cells; ++i) {
            const uint8_t t = TERR[i];
            if (pk_is_water_terrain(t)) continue;
            // 仅替换 GRASSLAND(3) / STEPPE(14) / SAVANNA(12) / PLAIN(2)
            if (t != 3 && t != 14 && t != 12 && t != 2) continue;
            if (pk_is_permanent_landform(t)) continue;
            const double e = double(ELEV[i]);
            const double land_h = (e - double(sea_level)) * inv_above_sea;
            if (land_h > 0.45) continue;
            int row = ROWI[i];
            if (row < 0) row = 0;
            else if (row > max_row) row = max_row;
            const double ny = double(row) * inv_max_row;
            const double temp = double(pk_compute_temperature(ny, e, double(sea_level)));
            // [climate-zone-fix P1] 与生成期 shrubland pass 同步：限真·暖温带地中海生态位
            // （temp 上限 0.58 排除热带/亚热带；湿度上沿收窄至 0.44）。
            if (temp < 0.42 || temp > 0.58) continue;
            const float mv = M[i];
            if (mv < 0.20f || mv > 0.44f) continue;
            bool has_sea = false;
            for (int d = 0; d < 6; ++d) {
                const int ni = NB[i * 6 + d];
                if (ni < 0) continue;
                const uint8_t nt = TERR[ni];
                if (nt == 0 || nt == 1) { has_sea = true; break; }
            }
            if (!has_sea) continue;
            TERR[i] = 15; // SHRUBLAND
            LF[i] = pk_derive_landform_preserve(15, ELEV[i], sea_level, LF[i]);
            ++touched;
        }
        _flush_slot_to_map(sid_terrain);
        _flush_slot_to_map(sid_landform);

        auto t1 = std::chrono::high_resolution_clock::now();
        out["elapsed_ms"] = std::chrono::duration<double, std::milli>(t1 - t0).count();
        out["fallback"] = false;
        out["reason"] = String();
        out["touched"] = touched;
        return out;
    }

    // ─── stage 6：mangrove_pass ───────────────────────────────────────────
    // SAME_SOURCE: map_generator.gd::_apply_mangrove_pass (line 3413).
    // 触发：陆地 + !MOUNTAIN/SNOW/TUNDRA/SWAMP + !permanent_landform
    //   + land_h<=0.05 + temp>=0.65 + 紧邻 COAST + (has_river 或 SWAMP 邻接)
    //   → MANGROVE(16)
    if (stage == 6) {
        if (!knobs.has("n_cells") || !knobs.has("height") || !knobs.has("sea_level") ||
            !knobs.has("row_indices") || !knobs.has("neighbor_indices")) {
            return fail("stage_6 missing required knob");
        }
        const int n_cells = int(knobs["n_cells"]);
        const int height = int(knobs["height"]);
        const float sea_level = float(knobs["sea_level"]);
        if (n_cells <= 0 || height <= 1) return fail("stage_6 invalid dims");
        godot::PackedInt32Array row_idx = knobs["row_indices"];
        godot::PackedInt32Array nb_arr = knobs["neighbor_indices"];
        if (row_idx.size() != n_cells) return fail("stage_6 row_indices size");
        if (nb_arr.size() < n_cells * 6) return fail("stage_6 neighbor_indices size");

        const int sid_terrain  = component_id(StringName("cell_terrain"));
        const int sid_elev     = component_id(StringName("cell_elevation"));
        const int sid_moist    = component_id(StringName("cell_moisture"));
        const int sid_river    = component_id(StringName("cell_has_river"));
        const int sid_landform = component_id(StringName("cell_landform"));
        if (sid_terrain < 0 || sid_elev < 0 || sid_moist < 0 || sid_river < 0 || sid_landform < 0) {
            return fail("stage_6 missing slot id");
        }
        Slot &s_t = _slots.write[sid_terrain];
        Slot &s_e = _slots.write[sid_elev];
        Slot &s_m = _slots.write[sid_moist];
        Slot &s_r = _slots.write[sid_river];
        Slot &s_lf= _slots.write[sid_landform];
        if (s_t.arr_u8.size() != n_cells || s_e.arr_f32.size() != n_cells ||
            s_m.arr_f32.size() != n_cells || s_r.arr_u8.size() != n_cells ||
            s_lf.arr_u8.size() != n_cells) {
            return fail("stage_6 slot size mismatch");
        }

        uint8_t       * const __restrict TERR = s_t.arr_u8.ptrw();
        const float   * const __restrict ELEV = s_e.arr_f32.ptr();
        const float   * const __restrict M    = s_m.arr_f32.ptr();
        const uint8_t * const __restrict RIV  = s_r.arr_u8.ptr();
        uint8_t       * const __restrict LF   = s_lf.arr_u8.ptrw();
        const int32_t * const __restrict NB   = nb_arr.ptr();
        const int32_t * const __restrict ROWI = row_idx.ptr();
        const int max_row = height - 1;
        const double inv_max_row = 1.0 / double(max_row > 0 ? max_row : 1);
        const double inv_above_sea = 1.0 / std::max(1.0 - double(sea_level), 0.001);

        auto t0 = std::chrono::high_resolution_clock::now();
        int touched = 0;
        for (int i = 0; i < n_cells; ++i) {
            const uint8_t t = TERR[i];
            if (pk_is_water_terrain(t)) continue;
            if (t == 6 || t == 9 || t == 8 || t == 10) continue; // MOUNTAIN/SNOW/TUNDRA/SWAMP
            if (pk_is_permanent_landform(t)) continue;
            const double e = double(ELEV[i]);
            const double land_h = (e - double(sea_level)) * inv_above_sea;
            if (land_h > 0.08) continue;
            int row = ROWI[i];
            if (row < 0) row = 0;
            else if (row > max_row) row = max_row;
            const double ny = double(row) * inv_max_row;
            const double temp = double(pk_compute_temperature(ny, e, double(sea_level)));
            if (temp < 0.60) continue;
            bool coast_nb = false;
            bool swamp_nb = false;
            for (int d = 0; d < 6; ++d) {
                const int ni = NB[i * 6 + d];
                if (ni < 0) continue;
                const uint8_t nt = TERR[ni];
                if (nt == 1) coast_nb = true;
                else if (nt == 10) swamp_nb = true;
            }
            if (!coast_nb) continue;
            if (!(RIV[i] || swamp_nb || M[i] >= 0.70f)) continue;
            TERR[i] = 16; // MANGROVE
            LF[i] = pk_derive_landform_preserve(16, ELEV[i], sea_level, LF[i]);
            ++touched;
        }
        _flush_slot_to_map(sid_terrain);
        _flush_slot_to_map(sid_landform);

        auto t1 = std::chrono::high_resolution_clock::now();
        out["elapsed_ms"] = std::chrono::duration<double, std::milli>(t1 - t0).count();
        out["fallback"] = false;
        out["reason"] = String();
        out["touched"] = touched;
        return out;
    }

    // ─── stage 7：glacier_pass ────────────────────────────────────────────
    // SAME_SOURCE: map_generator.gd::_apply_glacier_pass (line 3699).
    // 触发：(SNOW/TUNDRA) + temp<0.05 + (沿海冰舌 land_h<0.20 && OCEAN/COAST/SEA_ICE 邻居
    //                                  || alpine land_h>0.65)
    //       → GLACIER(17)
    if (stage == 7) {
        if (!knobs.has("n_cells") || !knobs.has("height") || !knobs.has("sea_level") ||
            !knobs.has("row_indices") || !knobs.has("neighbor_indices")) {
            return fail("stage_7 missing required knob");
        }
        const int n_cells = int(knobs["n_cells"]);
        const int height = int(knobs["height"]);
        const float sea_level = float(knobs["sea_level"]);
        if (n_cells <= 0 || height <= 1) return fail("stage_7 invalid dims");
        godot::PackedInt32Array row_idx = knobs["row_indices"];
        godot::PackedInt32Array nb_arr = knobs["neighbor_indices"];
        if (row_idx.size() != n_cells) return fail("stage_7 row_indices size");
        if (nb_arr.size() < n_cells * 6) return fail("stage_7 neighbor_indices size");

        const int sid_terrain  = component_id(StringName("cell_terrain"));
        const int sid_elev     = component_id(StringName("cell_elevation"));
        const int sid_landform = component_id(StringName("cell_landform"));
        if (sid_terrain < 0 || sid_elev < 0 || sid_landform < 0) {
            return fail("stage_7 missing slot id");
        }
        Slot &s_t = _slots.write[sid_terrain];
        Slot &s_e = _slots.write[sid_elev];
        Slot &s_lf= _slots.write[sid_landform];
        if (s_t.arr_u8.size() != n_cells || s_e.arr_f32.size() != n_cells ||
            s_lf.arr_u8.size() != n_cells) {
            return fail("stage_7 slot size mismatch");
        }

        uint8_t       * const __restrict TERR = s_t.arr_u8.ptrw();
        const float   * const __restrict ELEV = s_e.arr_f32.ptr();
        uint8_t       * const __restrict LF   = s_lf.arr_u8.ptrw();
        const int32_t * const __restrict NB   = nb_arr.ptr();
        const int32_t * const __restrict ROWI = row_idx.ptr();
        const int max_row = height - 1;
        const double inv_max_row = 1.0 / double(max_row > 0 ? max_row : 1);
        const double inv_above_sea = 1.0 / std::max(1.0 - double(sea_level), 0.001);

        auto t0 = std::chrono::high_resolution_clock::now();
        int touched = 0;
        for (int i = 0; i < n_cells; ++i) {
            const uint8_t t = TERR[i];
            if (pk_is_water_terrain(t)) continue;
            if (t != 9 && t != 8) continue; // 仅 SNOW / TUNDRA
            const double e = double(ELEV[i]);
            const double land_h = (e - double(sea_level)) * inv_above_sea;
            int row = ROWI[i];
            if (row < 0) row = 0;
            else if (row > max_row) row = max_row;
            const double ny = double(row) * inv_max_row;
            const double temp = double(pk_compute_temperature(ny, e, double(sea_level)));
            if (temp >= 0.05) continue;
            bool coastal_glacier = false;
            if (land_h < 0.20) {
                for (int d = 0; d < 6; ++d) {
                    const int ni = NB[i * 6 + d];
                    if (ni < 0) continue;
                    const uint8_t nt = TERR[ni];
                    if (nt == 0 || nt == 1 || nt == 20) {
                        coastal_glacier = true;
                        break;
                    }
                }
            }
            const bool alpine_glacier = land_h > 0.65;
            if (!(coastal_glacier || alpine_glacier)) continue;
            TERR[i] = 17; // GLACIER
            LF[i] = pk_derive_landform_preserve(17, ELEV[i], sea_level, LF[i]);
            ++touched;
        }
        _flush_slot_to_map(sid_terrain);
        _flush_slot_to_map(sid_landform);

        auto t1 = std::chrono::high_resolution_clock::now();
        out["elapsed_ms"] = std::chrono::duration<double, std::milli>(t1 - t0).count();
        out["fallback"] = false;
        out["reason"] = String();
        out["touched"] = touched;
        return out;
    }

    // ─── stage 8 was the original sentinel; rename to stage 9: swamp_pass ─
    // 注意：GDScript 的 12-stage 切片 stage 8=swamp_pass、stage 9=sync_current_state；
    // 而 C++ 端历史上把 stage 8 用作 sync_current_state（与 _run_season_refresh_stage8_gdext
    // 同步）。本次新增 swamp 用 stage_id=9 入口避免与已有 stage 8 冲突。GDScript caller
    // 在新 helper _run_season_refresh_stage_swamp_gdext 里发 stage=9。
    // SAME_SOURCE: map_generator.gd::_apply_swamp_pass (line 3330).
    if (stage == 9) {
        if (!knobs.has("n_cells") || !knobs.has("height") || !knobs.has("sea_level") ||
            !knobs.has("lat_temp_rows") || !knobs.has("row_indices") ||
            !knobs.has("neighbor_indices")) {
            return fail("stage_9 missing required knob");
        }
        const int n_cells = int(knobs["n_cells"]);
        const int height = int(knobs["height"]);
        const float sea_level = float(knobs["sea_level"]);
        if (n_cells <= 0 || height <= 0) return fail("stage_9 invalid dims");
        godot::PackedFloat32Array lat_tab = knobs["lat_temp_rows"];
        godot::PackedInt32Array row_idx = knobs["row_indices"];
        godot::PackedInt32Array nb_arr = knobs["neighbor_indices"];
        if (lat_tab.size() < height) return fail("stage_9 lat_temp_rows size");
        if (row_idx.size() != n_cells) return fail("stage_9 row_indices size");
        if (nb_arr.size() < n_cells * 6) return fail("stage_9 neighbor_indices size");

        const int sid_terrain  = component_id(StringName("cell_terrain"));
        const int sid_moist    = component_id(StringName("cell_moisture"));
        const int sid_elev     = component_id(StringName("cell_elevation"));
        const int sid_river    = component_id(StringName("cell_has_river"));
        const int sid_landform = component_id(StringName("cell_landform"));
        if (sid_terrain < 0 || sid_moist < 0 || sid_elev < 0 || sid_river < 0 ||
            sid_landform < 0) {
            return fail("stage_9 missing slot id");
        }
        Slot &s_t = _slots.write[sid_terrain];
        Slot &s_m = _slots.write[sid_moist];
        Slot &s_e = _slots.write[sid_elev];
        Slot &s_r = _slots.write[sid_river];
        Slot &s_lf= _slots.write[sid_landform];
        if (s_t.arr_u8.size() != n_cells || s_m.arr_f32.size() != n_cells ||
            s_e.arr_f32.size() != n_cells || s_r.arr_u8.size() != n_cells ||
            s_lf.arr_u8.size() != n_cells) {
            return fail("stage_9 slot size mismatch");
        }

        uint8_t       * const __restrict TERR = s_t.arr_u8.ptrw();
        const float   * const __restrict M    = s_m.arr_f32.ptr();
        const float   * const __restrict ELEV = s_e.arr_f32.ptr();
        const uint8_t * const __restrict RIV  = s_r.arr_u8.ptr();
        uint8_t       * const __restrict LF   = s_lf.arr_u8.ptrw();
        const int32_t * const __restrict NB   = nb_arr.ptr();
        const float   * const __restrict LATT = lat_tab.ptr();
        const int32_t * const __restrict ROWI = row_idx.ptr();
        const int max_row = height - 1;
        const double inv_above_sea = 1.0 / std::max(1.0 - double(sea_level), 0.001);

        auto t0 = std::chrono::high_resolution_clock::now();
        int touched = 0;
        for (int i = 0; i < n_cells; ++i) {
            const uint8_t t = TERR[i];
            if (pk_is_water_terrain(t)) continue;
            if (t == 6 || t == 9 || t == 8) continue; // MOUNTAIN/SNOW/TUNDRA
            if (pk_is_permanent_landform(t)) continue;
            const double e = double(ELEV[i]);
            const double land_h = (e - double(sea_level)) * inv_above_sea;
            if (land_h > 0.10) continue;
            if (M[i] < 0.75f) continue;
            int row = ROWI[i];
            if (row < 0) row = 0;
            else if (row > max_row) row = max_row;
            const double lat_temp = double(LATT[row]);
            const double temp = pk_clamp01(lat_temp - pk_alt_penalty(e, double(sea_level)));
            if (temp < 0.30) continue;
            bool has_water = (RIV[i] != 0);
            if (!has_water) {
                for (int d = 0; d < 6; ++d) {
                    const int ni = NB[i * 6 + d];
                    if (ni < 0) continue;
                    if (pk_is_water_terrain(TERR[ni])) { has_water = true; break; }
                }
            }
            if (!has_water) continue;
            TERR[i] = 10; // SWAMP
            LF[i] = pk_derive_landform(10, ELEV[i], sea_level);
            ++touched;
        }
        _flush_slot_to_map(sid_terrain);
        _flush_slot_to_map(sid_landform);

        auto t1 = std::chrono::high_resolution_clock::now();
        out["elapsed_ms"] = std::chrono::duration<double, std::milli>(t1 - t0).count();
        out["fallback"] = false;
        out["reason"] = String();
        out["touched"] = touched;
        return out;
    }

    // 历史上的 stage 8 = sync_current_state（_run_season_refresh_stage8_gdext 入口）。
    if (stage != 8) return fail("unsupported stage");
    if (!knobs.has("n_cells") || !knobs.has("height") || !knobs.has("sea_level") ||
        !knobs.has("season_offset_rows")) {
        return fail("missing required knob");
    }

    const int n_cells = int(knobs["n_cells"]);
    const int height = int(knobs["height"]);
    const float sea_level = float(knobs["sea_level"]);
    if (n_cells <= 0) return fail("n_cells <= 0");
    if (height <= 0) return fail("height <= 0");
    PackedFloat32Array season_rows = knobs["season_offset_rows"];
    if (season_rows.size() < height) return fail("season_offset_rows size < height");

    const int sid_temp = component_id(StringName("cell_temp"));
    const int sid_moist = component_id(StringName("cell_moisture"));
    const int sid_snow = component_id(StringName("cell_snow_cover"));
    const int sid_elev = component_id(StringName("cell_elevation"));
    const int sid_temp_year = component_id(StringName("cell_temp_baseline_year"));
    const int sid_lat = component_id(StringName("cell_lat_norm"));
    const int sid_terrain = component_id(StringName("cell_terrain"));
    const int sid_landform = component_id(StringName("cell_landform"));
    const int sid_vegetation = component_id(StringName("cell_vegetation"));
    const int sid_cover = component_id(StringName("cell_cover"));
    if (sid_temp < 0 || sid_moist < 0 || sid_snow < 0 || sid_elev < 0 ||
        sid_temp_year < 0 || sid_lat < 0 || sid_terrain < 0 ||
        sid_landform < 0 || sid_vegetation < 0 || sid_cover < 0) {
        return fail("missing slot id");
    }

    Slot &s_temp = _slots.write[sid_temp];
    Slot &s_moist = _slots.write[sid_moist];
    Slot &s_snow = _slots.write[sid_snow];
    Slot &s_elev = _slots.write[sid_elev];
    Slot &s_temp_year = _slots.write[sid_temp_year];
    Slot &s_lat = _slots.write[sid_lat];
    Slot &s_terrain = _slots.write[sid_terrain];
    Slot &s_landform = _slots.write[sid_landform];
    Slot &s_vegetation = _slots.write[sid_vegetation];
    Slot &s_cover = _slots.write[sid_cover];
    if (s_temp.arr_f32.size() != n_cells || s_moist.arr_f32.size() != n_cells ||
        s_snow.arr_f32.size() != n_cells || s_elev.arr_f32.size() != n_cells ||
        s_temp_year.arr_f32.size() != n_cells || s_lat.arr_f32.size() != n_cells ||
        s_terrain.arr_u8.size() != n_cells || s_landform.arr_u8.size() != n_cells ||
        s_vegetation.arr_u8.size() != n_cells || s_cover.arr_u8.size() != n_cells) {
        return fail("slot array size mismatch");
    }

    const float * const __restrict MOIST = s_moist.arr_f32.ptr();
    const float * const __restrict ELEV = s_elev.arr_f32.ptr();
    const float * const __restrict TEMP_YEAR_BASE = s_temp_year.arr_f32.ptr();
    const float * const __restrict LAT = s_lat.arr_f32.ptr();
    const float * const __restrict ROW_OFF = season_rows.ptr();
    const uint8_t * const __restrict TERR = s_terrain.arr_u8.ptr();
    float * const __restrict TEMP = s_temp.arr_f32.ptrw();
    float * const __restrict SNOW = s_snow.arr_f32.ptrw();
    uint8_t * const __restrict LAND = s_landform.arr_u8.ptrw();
    uint8_t * const __restrict VEG = s_vegetation.arr_u8.ptrw();
    uint8_t * const __restrict COV = s_cover.arr_u8.ptrw();

    auto t0 = std::chrono::high_resolution_clock::now();
    int snow_cells = 0;
    const int max_row = height - 1;
    for (int i = 0; i < n_cells; ++i) {
        int row = int(std::round(pk_clamp01(double(LAT[i])) * double(max_row)));
        if (row < 0) row = 0;
        else if (row > max_row) row = max_row;
        // 2026-07-08：海拔惩罚基于 sea_level 以上 land_h，与 GDScript / shader SAME_SOURCE。
        const double e = double(ELEV[i]);
        const double temp_year = pk_clamp01(double(TEMP_YEAR_BASE[i]) - pk_alt_penalty(e, double(sea_level)));
        const float temp_now = float(pk_clamp01(temp_year + double(ROW_OFF[row])));
        float snow = 0.0f;
        if (!pk_is_water_terrain(TERR[i])) {
            const float land_h = (ELEV[i] - sea_level) / std::max(1.0f - sea_level, 0.001f);
            if (TERR[i] == 9) {
                snow = 1.0f;
            } else if (temp_now < 0.18f) {
                snow = float(pk_clamp01((0.18f - temp_now) / 0.14f)) * 0.95f;
            } else if (land_h > 0.35f && temp_now < 0.45f) {
                const float t1 = float(pk_clamp01((0.45f - temp_now) / 0.25f));
                const float x = float(pk_clamp01((land_h - 0.35f) / (0.80f - 0.35f)));
                const float t2 = x * x * (3.0f - 2.0f * x);
                snow = t1 * t2;
            }
        }
        uint8_t lf = pk_derive_landform(TERR[i], ELEV[i], sea_level);
        const uint8_t prev_lf = LAND[i];
        if (!pk_is_water_terrain(TERR[i]) && (prev_lf == 8 || prev_lf == 12 || prev_lf == 13 || prev_lf == 14 || prev_lf == 15)) {
            lf = prev_lf;
        }
        TEMP[i] = temp_now;
        SNOW[i] = snow;
        LAND[i] = lf;
        // Keep vegetation succession lag where the pair is plausible, but
        // reconcile a clearly cross-biome residue after terrain reclassification.
        if (pk_is_water_terrain(TERR[i]) || VEG[i] == 0 ||
            pk_vegetation_needs_biome_reconcile(TERR[i], VEG[i])) {
            VEG[i] = pk_derive_vegetation(TERR[i], lf, temp_now, MOIST[i]);
        }
        COV[i] = pk_derive_cover(TERR[i], snow);
        if (snow > 0.5f) ++snow_cells;
    }

    _flush_slot_to_map(sid_temp);
    _flush_slot_to_map(sid_snow);
    _flush_slot_to_map(sid_landform);
    _flush_slot_to_map(sid_vegetation);
    _flush_slot_to_map(sid_cover);

    auto t1 = std::chrono::high_resolution_clock::now();
    out["elapsed_ms"] = std::chrono::duration<double, std::milli>(t1 - t0).count();
    out["fallback"] = false;
    out["reason"] = String();
    out["touched"] = n_cells;
    out["snow_cells"] = snow_cells;
    return out;
}

godot::Dictionary DCWorldExt::run_season_refresh_micro_pass(godot::Dictionary knobs) {
    using godot::Dictionary;
    using godot::PackedInt32Array;
    using godot::String;
    using godot::StringName;

    Dictionary out;
    const int stage = int(knobs.get("stage", 1));
    out["stage"] = stage;
    out["stage_name"] = String("unknown");
    out["done"] = false;
    out["next_stage"] = stage;
    out["cursor"] = int(knobs.get("cursor", 0));
    out["elapsed_ms"] = 0.0;
    out["touched"] = 0;
    out["fallback"] = true;
    out["reason"] = String();

    auto fail = [&](const char *why) -> Dictionary {
        out["reason"] = String(why);
        return out;
    };

    if (!_bound) return fail("not bound");
    if (stage != 1) return fail("unsupported stage");
    out["stage_name"] = String("rain_shadow");

    if (!knobs.has("n_cells") || !knobs.has("cursor") || !knobs.has("max_usec") ||
        !knobs.has("rain_shadow_lookback") || !knobs.has("rain_shadow_threshold") ||
        !knobs.has("rain_shadow_factor") || !knobs.has("neighbor_indices")) {
        return fail("stage_1 missing required knobs");
    }

    const int n_cells = int(knobs["n_cells"]);
    int cursor = int(knobs["cursor"]);
    const int max_usec = std::max(50, int(knobs["max_usec"]));
    const int lookback = std::max(0, int(knobs["rain_shadow_lookback"]));
    const float threshold = float(knobs["rain_shadow_threshold"]);
    const float factor = float(knobs["rain_shadow_factor"]);
    if (n_cells <= 0) return fail("n_cells <= 0");
    if (cursor < 0 || cursor > n_cells) return fail("cursor out of range");

    PackedInt32Array nb_arr = knobs["neighbor_indices"];
    if (nb_arr.size() < n_cells * 6) return fail("neighbor_indices size < n_cells * 6");

    const int sid_terrain = component_id(StringName("cell_terrain"));
    const int sid_moist   = component_id(StringName("cell_moisture"));
    const int sid_elev    = component_id(StringName("cell_elevation"));
    const int sid_wx      = component_id(StringName("cell_wind_x"));
    const int sid_wy      = component_id(StringName("cell_wind_y"));
    if (sid_terrain < 0 || sid_moist < 0 || sid_elev < 0 || sid_wx < 0 || sid_wy < 0) {
        return fail("missing slot id (terrain/moisture/elevation/wind)");
    }

    Slot &s_t = _slots.write[sid_terrain];
    Slot &s_m = _slots.write[sid_moist];
    Slot &s_e = _slots.write[sid_elev];
    Slot &s_wx = _slots.write[sid_wx];
    Slot &s_wy = _slots.write[sid_wy];
    if (s_t.arr_u8.size() != n_cells || s_m.arr_f32.size() != n_cells ||
        s_e.arr_f32.size() != n_cells || s_wx.arr_f32.size() != n_cells ||
        s_wy.arr_f32.size() != n_cells) {
        return fail("slot array size mismatch");
    }

    const uint8_t * const __restrict TERR = s_t.arr_u8.ptr();
    float         * const __restrict M    = s_m.arr_f32.ptrw();
    const float   * const __restrict ELEV = s_e.arr_f32.ptr();
    const float   * const __restrict WX   = s_wx.arr_f32.ptr();
    const float   * const __restrict WY   = s_wy.arr_f32.ptr();
    const int32_t * const __restrict NB   = nb_arr.ptr();

    auto t0 = std::chrono::high_resolution_clock::now();
    int touched = 0;
    int processed = 0;
    bool budget_yield = false;

    for (; cursor < n_cells; ++cursor) {
        if (!pk_is_water_terrain(TERR[cursor]) && lookback > 0) {
            const int dir = pk_upwind_dir_index_from_wind(WX[cursor], WY[cursor]);
            if (dir < 0) {
                continue;
            }
            int probe = cursor;
            for (int step = 0; step < lookback; ++step) {
                const int ni = NB[probe * 6 + dir];
                if (ni < 0) {
                    probe = -1;
                    break;
                }
                probe = ni;
            }
            if (probe >= 0 && ELEV[probe] > ELEV[cursor] + threshold) {
                M[cursor] = M[cursor] * factor;
                ++touched;
            }
        }

        ++processed;
        if ((processed & 63) == 0) {
            auto now = std::chrono::high_resolution_clock::now();
            const double elapsed_us = std::chrono::duration<double, std::micro>(now - t0).count();
            if (elapsed_us >= double(max_usec)) {
                ++cursor;
                budget_yield = true;
                break;
            }
        }
    }

    _flush_slot_to_map(sid_moist);

    auto t1 = std::chrono::high_resolution_clock::now();
    const bool done = cursor >= n_cells;
    out["done"] = done;
    out["next_stage"] = done ? stage + 1 : stage;
    out["cursor"] = cursor;
    out["elapsed_ms"] = std::chrono::duration<double, std::milli>(t1 - t0).count();
    out["touched"] = touched;
    out["fallback"] = false;
    out["reason"] = budget_yield ? String("budget_yield") : String();
    return out;
}

// ════════════════════════════════════════════════════════════════════════════
// Phase B+ (2026-05-21)：season refresh round 一次跨界整 round 切片调度
// ════════════════════════════════════════════════════════════════════════════
// 设计要点（决策来自 user 2026-05-21）：
//   1) history push：B+ 路径下 round 末尾 1 次（GDScript 端在 finish 后调
//      _sync_stage8_facade_fields_from_soa 一次；本 round 12 个 stage 内
//      C++ 不调任何 history push）
//   2) chunk 粒度：b1 = stage 边界切片；不在 stage 内 cursor 切片
//   3) 复用现有 run_season_refresh_stage(knobs) 的 stage dispatch；零算法
//      复制。每 stage 把 round.input_knobs 浅拷贝出来 + 改写 stage 字段后
//      调用一次 → run_season_refresh_stage(stage_knobs)。
//
// stage_id 映射（GDScript 12-stage round_stage → C++ stage 字段）：
//   round_stage  cpp_stage  含义
//        0           0      moisture_set
//        1           1      rain_shadow
//        2           2      seasonal_redecide_terrain
//        3           3      river_ecology
//        4           4      vegetation_feedback
//        5           5      shrubland
//        6           6      mangrove
//        7           7      glacier
//        8           9      swamp（C++ 端 id=9，避免与 sync 冲突）
//        9           8      sync_current_state
//       10          —       atlas_queue（render concern → SKIP；GDScript 端
//                          finish 阶段调 _mark_enum_atlas_dirty）
//       11          10      feedback_decay
static int pk_round_stage_to_cpp_stage(int round_stage) {
    switch (round_stage) {
        case 0:  return 0;
        case 1:  return 1;
        case 2:  return 2;
        case 3:  return 3;
        case 4:  return 4;
        case 5:  return 5;
        case 6:  return 6;
        case 7:  return 7;
        case 8:  return 9;   // swamp
        case 9:  return 8;   // sync
        case 10: return -1;  // atlas: SKIP（GDScript 处理）
        case 11: return 10;  // feedback decay
        default: return -1;
    }
}

godot::Dictionary DCWorldExt::start_season_round(godot::Dictionary round_knobs) {
    using godot::Dictionary;
    using godot::String;

    Dictionary out;
    out["handle"] = -1;
    out["fallback"] = true;
    out["reason"] = String();

    auto fail = [&](const char *why) -> Dictionary {
        out["reason"] = String(why);
        UtilityFunctions::push_warning("[DCWorldExt] start_season_round: ", why,
                                       " - fallback to GDScript 12-stage path");
        return out;
    };

    if (!_bound) return fail("not bound");
    if (!round_knobs.has("n_cells")) return fail("missing required knob: n_cells");
    const int n_cells = int(round_knobs["n_cells"]);
    if (n_cells <= 0) return fail("n_cells <= 0");

    // 已存在活跃 round：先 abort 旧的，避免泄漏（fast-restart 容错）。
    // generation 单调递增保证：把旧 generation +=1 后赋给新 SeasonRoundState，
    // 让悬挂的旧 handle 自然失效。
    int next_generation = 1;
    if (_season_round != nullptr) {
        SeasonRoundState *old = static_cast<SeasonRoundState *>(_season_round);
        if (old->active) {
            UtilityFunctions::push_warning(
                "[DCWorldExt] start_season_round: previous round still active "
                "(generation=", old->generation, ", round_stage=", old->round_stage,
                ") - aborting and starting fresh");
        }
        next_generation = old->generation + 1;
        if (next_generation <= 0) next_generation = 1;  // 溢出兜底
        delete old;
        _season_round = nullptr;
    }

    SeasonRoundState *st = new SeasonRoundState();
    st->generation       = next_generation;
    st->active           = true;
    st->round_stage      = 0;
    st->stages_done      = 0;
    st->slices_used      = 0;
    st->total_native_ms  = 0.0;
    st->input_knobs      = round_knobs;  // 浅拷贝；PackedArray CoW 共享
    // 缓存 in/out PackedFloat32Array（stage 11 需要）
    if (round_knobs.has("soil_moisture_arr")) {
        st->soil_moisture_arr = round_knobs["soil_moisture_arr"];
    }
    if (round_knobs.has("veg_growth_pressure_arr")) {
        st->veg_growth_pressure_arr = round_knobs["veg_growth_pressure_arr"];
    }
    _season_round = st;

    out["handle"] = st->generation;
    out["fallback"] = false;
    return out;
}

godot::Dictionary DCWorldExt::run_season_round_slice(int handle, int max_usec) {
    using godot::Dictionary;
    using godot::String;

    Dictionary out;
    out["done"] = false;
    out["stage"] = -1;
    out["stages_done_this_slice"] = 0;
    out["elapsed_ms"] = 0.0;
    out["fallback"] = true;
    out["reason"] = String();

    auto fail = [&](const char *why) -> Dictionary {
        out["reason"] = String(why);
        return out;
    };

    if (!_bound) return fail("not bound");
    if (_season_round == nullptr) return fail("no active round (call start_season_round first)");
    SeasonRoundState *st = static_cast<SeasonRoundState *>(_season_round);
    if (!st->active) return fail("round inactive");
    if (handle != st->generation) return fail("stale handle (generation mismatch)");

    if (max_usec <= 0) max_usec = 550;  // 默认 SUS slice budget
    // 用 steady_clock 算 deadline，与文件其余 perf 计时保持一致，避免引入
    // godot-cpp <classes/os.hpp> 依赖（OS::get_singleton 在本 TU 未 include）。
    auto t_slice0 = std::chrono::steady_clock::now();
    const auto t_deadline = t_slice0 + std::chrono::microseconds(int64_t(max_usec));
    int stages_done_this_slice = 0;
    String last_stage_reason;

    // b1 粒度：每 stage 边界查一次 deadline；不在 stage 内 cursor 切片
    while (st->round_stage < 12) {
        const int round_stage = st->round_stage;
        const int cpp_stage = pk_round_stage_to_cpp_stage(round_stage);

        if (cpp_stage < 0) {
            // SKIP（atlas_queue / unknown）：直接前进
            st->round_stage += 1;
            st->stages_done += 1;
            stages_done_this_slice += 1;
            continue;
        }

        // 浅拷贝 input_knobs + 改写 stage 字段；不污染 round 级 input_knobs
        Dictionary stage_knobs = st->input_knobs.duplicate(false);
        stage_knobs["stage"] = cpp_stage;
        // stage 11 (=cpp 10) 是 in/out array；C++ stage 10 内会 ptrw 写回，
        // 我们持有的 st->soil_moisture_arr 也会同步看到新值（CoW 引用共享）。
        if (round_stage == 11) {
            stage_knobs["soil_moisture_arr"] = st->soil_moisture_arr;
            stage_knobs["veg_growth_pressure_arr"] = st->veg_growth_pressure_arr;
        }

        Dictionary stage_res = run_season_refresh_stage(stage_knobs);
        const bool stage_fb = bool(stage_res.get("fallback", true));
        const double stage_ms = double(stage_res.get("elapsed_ms", -1.0));
        if (stage_fb || stage_ms < 0.0) {
            // 单 stage fallback：整个 round 标记 fallback，由 GDScript 端
            // abort 后走 12-stage 兜底路径。不在 C++ 内自动 retry。
            last_stage_reason = String(stage_res.get("reason", "stage_fallback"));
            out["stage"] = round_stage;
            out["stages_done_this_slice"] = stages_done_this_slice;
            out["fallback"] = true;
            out["reason"] = String("round_stage_") + String::num_int64(round_stage)
                          + String(": ") + last_stage_reason;
            // 注意：不在这里 abort/清空 _season_round，让 caller 看到具体
            // round_stage 后调 abort_season_round 显式清理。
            auto t_slice1 = std::chrono::steady_clock::now();
            out["elapsed_ms"] = std::chrono::duration<double, std::milli>(
                                    t_slice1 - t_slice0).count();
            return out;
        }

        // stage 11 写回（C++ 端在 stage 10 内通过 knobs["soil_moisture_arr"] = soil_arr;
        // 把 decayed 值写回 stage_knobs，但我们持有的 st->soil_moisture_arr 是
        // 旧 ref——重新拉回来）
        if (round_stage == 11) {
            if (stage_knobs.has("soil_moisture_arr")) {
                st->soil_moisture_arr = stage_knobs["soil_moisture_arr"];
            }
            if (stage_knobs.has("veg_growth_pressure_arr")) {
                st->veg_growth_pressure_arr = stage_knobs["veg_growth_pressure_arr"];
            }
        }

        st->total_native_ms += stage_ms;
        st->round_stage += 1;
        st->stages_done += 1;
        stages_done_this_slice += 1;

        // stage 边界查 deadline（b1 粒度）
        if (std::chrono::steady_clock::now() >= t_deadline) {
            break;
        }
    }

    st->slices_used += 1;
    auto t_slice1 = std::chrono::steady_clock::now();
    const double slice_ms = std::chrono::duration<double, std::milli>(
                                t_slice1 - t_slice0).count();
    const bool round_done = st->round_stage >= 12;

    out["done"] = round_done;
    out["stage"] = st->round_stage;
    out["stages_done_this_slice"] = stages_done_this_slice;
    out["elapsed_ms"] = slice_ms;
    out["fallback"] = false;
    out["reason"] = String();
    return out;
}

godot::Dictionary DCWorldExt::finish_season_round(int handle) {
    using godot::Dictionary;
    using godot::String;

    Dictionary out;
    out["total_native_ms"] = 0.0;
    out["slices_used"] = 0;
    out["stages_done"] = 0;
    out["fallback"] = true;
    out["reason"] = String();

    auto fail = [&](const char *why) -> Dictionary {
        out["reason"] = String(why);
        return out;
    };

    if (_season_round == nullptr) return fail("no active round");
    SeasonRoundState *st = static_cast<SeasonRoundState *>(_season_round);
    if (handle != st->generation) return fail("stale handle (generation mismatch)");

    out["total_native_ms"] = st->total_native_ms;
    out["slices_used"] = st->slices_used;
    out["stages_done"] = st->stages_done;
    // 把 stage 11 (feedback_decay) 的 decayed in/out array 回传给 GDScript caller
    out["soil_moisture_arr"] = st->soil_moisture_arr;
    out["veg_growth_pressure_arr"] = st->veg_growth_pressure_arr;
    out["fallback"] = false;
    out["reason"] = String();

    // 清理：generation 不变，下次 start 才 +=1
    delete st;
    _season_round = nullptr;
    return out;
}

void DCWorldExt::abort_season_round() {
    if (_season_round == nullptr) return;
    SeasonRoundState *st = static_cast<SeasonRoundState *>(_season_round);
    delete st;
    _season_round = nullptr;
}

} // namespace pk
