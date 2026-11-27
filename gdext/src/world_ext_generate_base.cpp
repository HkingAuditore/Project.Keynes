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
    // [P5-0 诊断 2026-11-18] 可选导出脊信号场，供 ridge_drainage_metrics_test.gd 计算 M1
    // （陆地格 Spearman(ridge_add, log 汇水面积)）。**纯诊断**：只在 profile 传 ridge_debug_dump=1 时
    // 分配并返回，不参与任何计算、不改变任何输出数组 → 不设此键时行为逐位不变（有 hash 门禁验证）。
    // 生产与 perf-validation 都不传该键。
    const bool ridge_debug_dump = geti(profile, "ridge_debug_dump", 0) != 0;
    PackedFloat32Array ridge_add_diag;
    // [S7-T1 诊断 2026-11-18] `debug_dump_ridge_e0`（bool，默认 false）：导出 E0 与 E0 版 ridge_add（见 §R 之后）。
    const bool ridge_debug_e0_dump = geti(profile, "debug_dump_ridge_e0", 0) != 0;
    PackedFloat32Array e0_diag;
    PackedFloat32Array ridge_e0_diag;
    // [S7-T1 消融开关 2026-11-18] `spl_steepest_receiver`（bool，默认 true）：
    //   false ⇒ §2.4' 用 Priority-Flood 的「关闭者」当受体，复刻 P5-3 之前的旧行为。
    //   仅供 §4「收益消融」把 M2/M4 的收益拆到「扩散 / 最陡受体 / 脊抬升」三者身上；
    //   默认 true 时与现状逐位一致（有指纹门禁证明）。实验结束后按计划 T12 决定去留。
    const bool spl_steepest_receiver = geti(profile, "spl_steepest_receiver", 1) != 0;
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
    const double moisture_rainout_base_eff = 1.0 - simulation_math::pow(1.0 - moisture_rainout_base, inv_hydro_dist_scale);
    const double moisture_continental_dry_eff = 1.0 - simulation_math::pow(1.0 - moisture_continental_dry, inv_hydro_dist_scale);
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

#include "world_ext_generate_base_section_continents_and_elevation.inc"
#include "world_ext_generate_base_section_bathymetry_and_erosion.inc"
#include "world_ext_generate_base_section_lake_seeds_and_depressions.inc"
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
        return simulation_math::exp(-double(dd) / coastal_temp_scale_eff);  // [scale-fix] ×s，见 knobs 区
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
        return simulation_math::exp(-0.5 * z * z);
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
                const double jitter = cyl_noise(moisture_noise.ptr(), simulation_math::cos(mth), simulation_math::sin(mth), ny, 100.0, 0.0, 0.0, 0.0) * moisture_noise_amp;
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
        const double prox = simulation_math::exp(-double(dd) / coastal_moist_scale_eff);
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
        const double prox = simulation_math::exp(-double(dd) / coastal_moist_scale_eff);
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
            const double dry_belt = simulation_math::exp(-0.5 * z * z);
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
    // [P5-0 诊断] 仅在 profile.ridge_debug_dump=1 时返回（见上方 ridge_debug_dump 注释）。
    if (ridge_debug_dump && ridge_add_diag.size() == n) out["ridge_add_arr"] = ridge_add_diag;
    // [S7-T1 诊断] 仅在 profile.debug_dump_ridge_e0=1 时返回（E0 + E0 版 ridge_add，供同口径新旧对比）。
    if (ridge_debug_e0_dump && e0_diag.size() == n) {
        out["e0_arr"] = e0_diag;
        out["ridge_e0_arr"] = ridge_e0_diag;
    }
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
