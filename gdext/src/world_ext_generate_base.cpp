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

    // 地台起伏 / 造山带 / 山脊噪声按格距定义：大图得到更多、同等格尺寸的山系，而不是把
    // 参考图的山系整体放大（放大后格间高差 ∝ 1/s，内陆读成平地）。大陆轮廓仍按整图定义。
    // N <= feature_ref_cells 时 feature_scale=1，与旧行为逐位一致。
    const double feature_ref_cells = std::max(100.0, getd(profile, "feature_ref_cells", 2400.0));
    const double feature_scale = std::pow(std::max(1.0, std::sqrt(double(width) * double(height) / feature_ref_cells)),
                                          std::clamp(getd(profile, "feature_scale_exp", 1.0), 0.0, 1.0));

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
            const double macro = cyl_noise(height_noise.ptr(), ct, st, ny, 95.0 * feature_scale, 701.0, -419.0, 0.0);   // 大尺度起伏
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
                const double ro1 = cyl_noise(height_noise.ptr(), ct, st, ny, 115.0 * feature_scale, 313.0, -271.0, 0.0);
                const double ro2 = cyl_noise(detail_noise.ptr(), ct, st, ny, 57.0 * feature_scale, -191.0, 421.0, 0.0);
                double ridge = (1.0 - std::fabs(ro1)) * 0.7 + (1.0 - std::fabs(ro2)) * 0.3;
                ridge = pk_clamp01(ridge);
                const double belt_n = cyl_noise(detail_noise.ptr(), ct, st, ny, 70.0 * feature_scale, 137.0, -91.0, 0.0);
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
        // [spl-scale 2026-10-12] 准平衡满足 E[i] = E[down] + U/C，逐格成立 → 内陆高度 ≈ 海岸起
        // 格数 × U/C。格数 ∝ sqrt(N)，不缩放时 200x150 内陆整片顶到 land_elev_cap 成纯平高原。
        // 物理一致：每格高差 ∝ 1/s，故 C ×s；汇水面积 A∝s²、均值 Ā∝s，(A/Ā)/s 换回参考格距。
        // N <= spl_ref_cells 时 s=1，与旧行为逐位一致。
        const double spl_ref_cells = std::max(100.0, getd(profile, "spl_ref_cells", 2400.0));
        const double spl_res_scale = std::max(1.0, std::sqrt(double(n) / spl_ref_cells));
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
                    const double C = spl_k * spl_res_scale
                            * std::pow(area[size_t(i)] * inv_area_mean / spl_res_scale, spl_m);
                    const double U = spl_uplift_rate * double(relief0[size_t(i)]);
                    double z = (double(E[i]) + U + C * double(E[d])) / (1.0 + C);
                    if (z < double(E[d])) z = double(E[d]);
                    E[i] = float(z);
                }
            }
            // 内陆高度沿流路逐格累加，高海平面 + 大陆地图上会冲出 1.0，硬截后内陆成整片平顶。
            // 超出余量时把膝点以上的陆地高度线性压进 [knee, headroom]，p99 落在 headroom；
            // 膝点以下（低地/中山的群系分布）不动，未超出的地图逐位不变。
            {
                std::vector<float> land_h;
                land_h.reserve(size_t(n));
                for (int i = 0; i < n; ++i) {
                    const double e = double(E[i]);
                    if (e >= sea_level) land_h.push_back(float(e - sea_level));
                }
                // 大图对齐山脊 pass 的 land_elev_cap(0.93)，否则 SPL 已占满上限、山脊无处可加。
                const double spl_top = spl_res_scale > 1.0 ? 0.93 : 1.0;
                const double headroom = (spl_top - sea_level) * std::clamp(getd(profile, "spl_headroom_frac", 0.97), 0.5, 1.0);
                if (!land_h.empty() && headroom > 1e-4) {
                    const size_t k99 = std::min(land_h.size() - 1, size_t(double(land_h.size()) * 0.99));
                    std::nth_element(land_h.begin(), land_h.begin() + std::ptrdiff_t(k99), land_h.end());
                    const double p99 = double(land_h[k99]);
                    const double knee = headroom * std::clamp(getd(profile, "spl_headroom_knee", 0.7), 0.0, 0.95);
                    if (p99 > headroom) {
                        const double f = (headroom - knee) / (p99 - knee);
                        for (int i = 0; i < n; ++i) {
                            const double h = double(E[i]) - sea_level;
                            if (h > knee) E[i] = float(sea_level + knee + (h - knee) * f);
                        }
                    }
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

    // ── 5. 山脊高度预算：先冻结基底，再按同一比例分配增量，最后只收尾极少数尖峰。──
    if (ridge_boost_amp > 0.0) {
        const double denom_lf = std::max(1.0 - sea_level, 0.001);
        const double land_elev_cap = std::max(0.93, sea_level + (1.0 - sea_level) * 0.94);
        // 顶部只预留 6% 高度空间作 C1 收尾；99% 陆地使用线性预算，不压缩峰肩高差。
        const double soft_max = land_elev_cap - (land_elev_cap - sea_level) * 0.06;
        // 所有尺寸统一使用冻结输入，避免按扫描顺序读到已抬升邻格。
        std::vector<float> ridge_pre(size_t(n), -1.0f);
        std::vector<float> ridge_frozen(size_t(n), 0.0f);
        std::copy(E, E + n, ridge_frozen.begin());
        std::vector<float> ridge_add(ridge_pre.size(), 0.0f);
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
                const double ridge_a = 1.0 - std::fabs(cyl_noise(detail_noise.ptr(), ct2, st2, ny2, 180.0 * feature_scale, 71.3, -33.7, 0.0));
                const double ridge_b = 1.0 - std::fabs(cyl_noise(detail_noise.ptr(), ct2, st2, ny2, 220.0 * feature_scale, -50.7, 91.1, 0.0));
                const double ridge_signal = std::pow(std::max(ridge_a, ridge_b), 1.4);
                double lowest = double(ridge_frozen[size_t(idx)]);
                for (int d = 0; d < 6; ++d) {
                    const int ni = index_for_qr(Q[idx] + DQ[d], R[idx] + DR[d]);
                    if (ni >= 0 && double(ridge_frozen[size_t(ni)]) < lowest) lowest = double(ridge_frozen[size_t(ni)]);
                }
                const double slope = double(ridge_frozen[size_t(idx)]) - lowest;
                double slope_gate = slope * 8.0;
                if (slope_gate < 0.30) slope_gate = 0.30;
                else if (slope_gate > 1.0) slope_gate = 1.0;
                double land_factor = (double(E[idx]) - sea_level) / denom_lf;
                land_factor = std::pow(land_factor, 1.5);
                const double addition = ridge_signal * land_factor * slope_gate * ridge_boost_amp;
                ridge_pre[size_t(idx)] = E[idx];
                ridge_add[size_t(idx)] = float(addition);
            }
        }
        if (!ridge_pre.empty()) {
            std::vector<int> land_idx;
            land_idx.reserve(size_t(n));
            for (int i = 0; i < n; ++i) {
                if (ridge_pre[size_t(i)] >= 0.0f) land_idx.push_back(i);
            }
            if (!land_idx.empty()) {
                std::vector<float> scratch(land_idx.size());
                const size_t k99 = std::min(land_idx.size() - 1, size_t(double(land_idx.size()) * 0.99));
                // 极端配置中基底先按海平面锚定的统一比例留出空间，保留高程序。
                for (size_t j = 0; j < land_idx.size(); ++j) scratch[j] = ridge_pre[size_t(land_idx[j])];
                std::nth_element(scratch.begin(), scratch.begin() + std::ptrdiff_t(k99), scratch.end());
                const double base_p99 = double(scratch[k99]);
                const double base_target = sea_level + (soft_max - sea_level) * 0.94;
                const double base_scale = base_p99 > base_target
                    ? (base_target - sea_level) / std::max(base_p99 - sea_level, 1e-6) : 1.0;
                for (int i : land_idx) ridge_pre[size_t(i)] = float(sea_level +
                    (double(ridge_pre[size_t(i)]) - sea_level) * base_scale);
                auto p99_at = [&](double g) -> double {
                    for (size_t j = 0; j < land_idx.size(); ++j) {
                        const size_t i = size_t(land_idx[j]);
                        scratch[j] = float(double(ridge_pre[i]) + g * double(ridge_add[i]));
                    }
                    std::nth_element(scratch.begin(), scratch.begin() + std::ptrdiff_t(k99), scratch.end());
                    return double(scratch[k99]);
                };
                double g = 1.0;
                if (p99_at(1.0) > soft_max) {
                    double lo = 0.0, hi = 1.0;
                    for (int it = 0; it < 24; ++it) {
                        const double mid = 0.5 * (lo + hi);
                        if (p99_at(mid) > soft_max) hi = mid; else lo = mid;
                    }
                    g = lo;
                }
                int tail_count = 0;
                for (const int i : land_idx) {
                    double h = double(ridge_pre[size_t(i)]) + g * double(ridge_add[size_t(i)]);
                    if (h > soft_max) {
                        const double span = land_elev_cap - soft_max;
                        h = soft_max + span * (1.0 - std::exp(-(h - soft_max) / span));
                        ++tail_count;
                    }
                    E[i] = float(h);
                }
                out["ridge_budget_scale"] = g;
                out["ridge_base_scale"] = base_scale;
                out["ridge_tail_cells"] = tail_count;
                out["ridge_land_cells"] = int(land_idx.size());
                out["ridge_elevation_cap"] = land_elev_cap;
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


} // namespace pk
