#include "world_ext.h"

#include "component_bind_table.gen.h"  // A1 / dots-migration-roadmap §3 — autogen by tools/codegen/gen_cpp_bind_table.py
#include "system_schedule.h"           // Phase C.1 — 静态 DAG 调度图
#include "parallel_dispatcher.h"       // Phase C.3a — 并行分发 helper（统一 5 个手写 _thread）
#include "runtime_climate_physics.h"   // B8 P2：物理环流共享纯内核（SLP Pass A/B）

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


// ─── Block B helpers ────────────────────────────────────────────────────────
//
// B8 P2：几何常量与风带常量已搬到 runtime_climate_physics.h（唯一来源），
// 这里用 using 声明保持原有非限定调用点不变。风场主循环本身也已迁到
// pk_async_physics::wind_field_range。
using pk_async_physics::COAST_INF;
using pk_async_physics::NB_DIR_X;
using pk_async_physics::NB_DIR_Y;
using pk_async_physics::WIND_W_LAT;
using pk_async_physics::WIND_W_GRAD;
using pk_async_physics::WIND_W_COAST_THERMAL;
using pk_async_physics::WIND_COAST_THERMAL_MAX_DIST;
using pk_async_physics::WIND_CORIOLIS_MAX_RAD;
using pk_async_physics::WIND_PRESSURE_GRAD_WEAK;
using pk_async_physics::WIND_PRESSURE_GRAD_STRONG;
using pk_async_physics::WIND_PRESSURE_BASE_W;
using pk_async_physics::WIND_PRESSURE_GRAD_W;
using pk_async_physics::WIND_LAT_GRAD_SUPPRESS;
using pk_async_physics::WIND_TERRAIN_MOUNTAIN_DAMP;
using pk_async_physics::WIND_TERRAIN_HILL_DAMP;
using pk_async_physics::WIND_LAND_FRICTION;
using pk_async_physics::WIND_MOUNTAIN_DEFLECT_W;
using pk_async_physics::WIND_MOUNTAIN_UPSTREAM_DAMP;
using pk_async_physics::WIND_SEA_BREEZE_W;
using pk_async_physics::SEA_BREEZE_SEA_MAX_DIST;

namespace {

inline double wind_clamp(double v, double lo, double hi) {
    return v < lo ? lo : (v > hi ? hi : v);
}

inline double physical_wrap01(double world_x, double wrap_origin_x, double wrap_period_x) {
    double phase = std::fmod((world_x - wrap_origin_x) / wrap_period_x, 1.0);
    if (phase < 0.0) phase += 1.0;
    return phase;
}

// 单位护栏：wrap_period_x 必须与 POSX(cell_pos_x) 同单位 —— 即 size=1.0 单位六边形空间，
// 周期 = map_width * sqrt(3)，与 hex_size 无关（map_data.gd 用 cube_to_world(q, r, 1.0) 填该 slot）。
//
// 历史 bug（2026-08-03）：map_baker.gd 传的是世界单位 wrap_period_x(map_width, hex_size)，
// 比 POSX 跨度大 hex_size 倍 → physical_wrap01 归一化经度只走完 1/hex_size 个周期，永不环绕
// → 东西接缝处 synoptic 波与移动低压相位硬跳 → 伪 ∇SLP 把风向钉死 → 风应力涡度再把洋流锁死，
// 表现为"东西边界有一堵墙"。该错配连续两轮静默逃逸，故在此出声而不是默默算错。
inline void physical_warn_wrap_units(const char *pass_name, double wrap_period_x, double posx_span, bool &warned) {
    if (warned || wrap_period_x <= 0.001 || posx_span <= 0.001) return;
    // 正确时 period 只比跨度多一个列距(√3/2)，比值≈1.005；世界单位错配下比值≈hex_size。
    if (wrap_period_x < posx_span || wrap_period_x > posx_span * 1.5) {
        warned = true;
        godot::UtilityFunctions::push_warning(
            godot::String("[physical] {0}: wrap_period_x={1} 与 cell_pos_x 跨度={2} 单位不符"
                          "(比值={3})。物理 pass 的 wrap_period_x 应为 map_width*sqrt(3)"
                          "(HexUtils.wrap_period_cell_pos_x)，不是世界单位。东西接缝将出现不连续阶跃。")
                    .format(godot::Array::make(pass_name, wrap_period_x, posx_span,
                                               wrap_period_x / posx_span)));
    }
}

// ─── 纬度归一化的单一权威 ────────────────────────────────────────────────
// ny ∈ [0,1]：0 = 第 0 行, 1 = 最后一行, 0.5 = 赤道。lat_signed = (ny-0.5)*2。
//
// 历史 bug（2026-08-03）：本文件 4 处曾这样重算纬度
//     ny = (POSY[i] - world_bounds_pos_y) / world_bounds_size_y
// 但 POSY 是 `cell_pos_y`（size=1.0 单位六边形空间，行距 1.5，100x64 图值域 0..94.5），
// 而 `world_bounds_*` 来自 map_baker.gd::compute_world_bounds() 的世界单位
// （含 hex_size；hex_size=22 时 pos_y=-44、size_y≈2211）。两者相差 hex_size 倍，
// 于是 ny 被压缩到 0.02~0.06、abs_lat 恒为 0.87~0.96，全图每个 cell 都被当成极地：
//   · wind_belt_at → 处处极地东风，信风带/西风带/ITCZ 完全不存在
//   · wind_belt_speed_at → 恒为 SPEED_POLAR(0.65)（实测风速下限 0.649 即由此而来）
//   · 科氏角恒 ~65°、ageo_w 恒为 0（赤道也全地转），且 ls<0 恒成立 → 偏转符号永不翻转
//   · wind_shifted_lat_signed 的 ITCZ 季节迁移上限 ±0.18，动不出极地带 → 季节通路失效
// 表现为：风带不沿纬线而沿大陆经度成条带（唯一塑形者退化为 ∇SLP + 海岸几何），
// 且风向常年不变。`world_ext_climate.cpp` 一直直接读 `cell_lat_norm` slot，所以温度场是对的，
// 两个域因此长期静默分歧。
//
// 现在以 `cell_lat_norm` slot 为唯一权威（与 climate 同源，等于 map_generator.gd
// `_cube_row_norm` = row/(height-1)）。slot 缺失时退化为「用 POSY 自身值域自归一化」，
// 与本文件 slp_bounds_pos_x 对 POSX 的做法一致 —— 不依赖任何外部单位，无法再次错配。
struct PhysLatNorm {
    const float *lat = nullptr;   // cell_lat_norm slot（首选）
    const float *posy = nullptr;  // 退化路径：cell_pos_y 自归一化
    double origin = 0.0;
    double inv_span = 1.0;

    inline double at(int i) const {
        double ny = (lat != nullptr)
            ? double(lat[i])
            : ((double(posy[i]) - origin) * inv_span);
        return (ny < 0.0) ? 0.0 : ((ny > 1.0) ? 1.0 : ny);
    }
};

inline PhysLatNorm phys_make_lat_norm(const float *lat, const float *posy, int n_cells) {
    PhysLatNorm o;
    if (lat != nullptr) {
        o.lat = lat;
        return o;
    }
    o.posy = posy;
    if (posy == nullptr || n_cells <= 0) return o;
    double lo = double(posy[0]), hi = lo;
    for (int i = 1; i < n_cells; ++i) {
        const double v = double(posy[i]);
        if (v < lo) lo = v;
        else if (v > hi) hi = v;
    }
    o.origin = lo;
    o.inv_span = 1.0 / std::max(0.001, hi - lo);
    return o;
}

inline float wind_speed_norm(float dir_x, float dir_y, float speed) {
    if (speed > 0.0001f) return speed;
    const float len2 = dir_x * dir_x + dir_y * dir_y;
    return (len2 > 0.0001f) ? std::sqrt(len2) : 0.0f;
}

// B8 P2：wind_orbital_progress / wind_subsolar_signed / wind_shifted_lat_signed /
// wind_belt_speed_at 已搬到 runtime_climate_physics.h（唯一来源，生产与 worker
// 共用）。风场主循环也已迁到 pk_async_physics::wind_field_range。

} // anonymous namespace (Block B helpers)

// ─── Block B main pass ──────────────────────────────────────────────────────
//
// Single-shot full sweep over [0, n_cells). 1:1 mirror of
// physical_circulation_solver.gd::solve_wind_field (line 246-454).
//
// 性能预算（charter §7 / dots-wind-validation.md）：
//   GDScript baseline: solve_wind_field 单次 ~35ms（n=2400）
//   C++ 目标:           < 5ms 单次（含 BFS + 主循环 + flush）
//
// 算法（详见 gdscript 同名函数）：
//   Pass 0 — coast BFS (≤ MAX_DIST=5)：
//     coast_dist[i]    = i 到最近海岸的格数（仅陆地 cell；inf 表示远内陆）
//     coast_sea_x/y[i] = 朝海洋的单位向量（从最近海岸继承）
//   主循环：
//     v_base = three-cell background with solar-declination belt migration
//     grad_slp = (1/3) * Σ_d (slp[nb] - slp[self]) * NB_DIR[d]
//     v_grad   = -grad_slp 经科氏偏转（北半球右偏 / 南半球左偏，幅度 0..0.78 rad）
//     coastal sea/land pressure contrast comes from SLP; no direct season sign
//     v_sum    = W_LAT*v_base + W_GRAD*v_grad
//     dir      = normalize(v_sum)
//     spd      = wind_belt_speed_at(ny, orbital_phase, axial_tilt) * land_friction
//                * (mountain_damp / hill_damp 按 landform)
//     terrain_aware：山脉绕流 + 山脉迎风减速
//     write wind_x_arr[i], wind_y_arr[i], wind_speed_out[i]
double DCWorldExt::run_wind_field_pass(godot::Dictionary knobs) {
    using godot::StringName;
    using godot::PackedFloat32Array;
    using godot::PackedInt32Array;
    using godot::PackedByteArray;

    auto diag = [&](const char *why) {
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_wind_field_pass: ", why,
            " — fallback to GDScript");
    };

    if (!_bound) { diag("not _bound"); return -1.0; }

    // ─── slot id resolution moved below (after water_ids, via _phys_resolve_static cache) ──

    // ─── knobs validation ──────────────────────────────────────────────
    static const char *required_keys[] = {
        "n_cells", "hex_size", "season_phase", "terrain_aware",
        "world_bounds_pos_y", "world_bounds_size_y",
        "neighbor_indices", "slp_arr", "water_terrain_ids",
        "land_lf_mountain", "land_lf_peak", "land_lf_hill",
        nullptr,
    };
    for (int k = 0; required_keys[k] != nullptr; ++k) {
        if (!knobs.has(required_keys[k])) {
            UtilityFunctions::push_warning(
                "[DCWorldExt] run_wind_field_pass: missing knob '",
                required_keys[k], "' — fallback to GDScript");
            return -1.0;
        }
    }

    const int    n_cells       = int(knobs["n_cells"]);
    const double season_phase  = double(knobs["season_phase"]);
    const bool   terrain_aware = (int(knobs["terrain_aware"]) != 0);
    const double bounds_pos_y  = double(knobs["world_bounds_pos_y"]);
    const double bounds_size_y = double(knobs["world_bounds_size_y"]);
    const int    lf_mountain   = int(knobs["land_lf_mountain"]);
    const int    lf_peak       = int(knobs["land_lf_peak"]);
    const int    lf_hill       = int(knobs["land_lf_hill"]);
    const bool   wind_belt_only = bool(knobs.has("wind_belt_only_debug") ? bool(knobs["wind_belt_only_debug"]) : false);
    float response_rate = float(knobs.has("wind_response_rate") ? double(knobs["wind_response_rate"]) : 0.25);
    if (response_rate < 0.0f) response_rate = 0.0f;
    else if (response_rate > 1.0f) response_rate = 1.0f;
    const double synoptic_amp = double(knobs.has("wind_synoptic_amp") ? double(knobs["wind_synoptic_amp"]) : 0.055);
    double synoptic_period_days = double(knobs.has("wind_synoptic_period_days") ? double(knobs["wind_synoptic_period_days"]) : 6.0);
    if (synoptic_period_days < 0.5) synoptic_period_days = 0.5;
    const double axial_tilt_deg = double(knobs.has("axial_tilt_deg") ? double(knobs["axial_tilt_deg"]) : 23.5);
    // 转向速率限幅。knob 语义是「每游戏日」，但本 pass 不是每日调用：
    // earth_like.tres 的 ocean_daily_wind_period_ticks=6 配合 daily_wind_split_passes 交替
    // slp/wind → wind 段每 24 tick 才跑一次。若不按经过天数缩放，名义 32°/日会退化成
    // 32°/24日 ≈ 1.33°/日，风向被硬性钉死（实测方向恒定度中位 0.958、中纬度反而最稳）。
    // caller 传 wind_elapsed_days（缺省 1.0 = 旧行为）。
    double wind_elapsed_days = double(knobs.has("wind_elapsed_days") ? double(knobs["wind_elapsed_days"]) : 1.0);
    if (wind_elapsed_days < 0.0) wind_elapsed_days = 0.0;
    else if (wind_elapsed_days > 60.0) wind_elapsed_days = 60.0;
    double max_turn_rad = double(knobs.has("wind_max_turn_deg_per_day") ? double(knobs["wind_max_turn_deg_per_day"]) : 32.0)
        * (3.14159265358979323846 / 180.0) * wind_elapsed_days;
    if (max_turn_rad < 0.0) max_turn_rad = 0.0;
    else if (max_turn_rad > 3.14159265358979323846) max_turn_rad = 3.14159265358979323846;
    double min_flux_for_dir_update = double(knobs.has("wind_min_flux_for_dir_update") ? double(knobs["wind_min_flux_for_dir_update"]) : 0.035);
    if (min_flux_for_dir_update < 0.0) min_flux_for_dir_update = 0.0;
    const double min_flux_len2 = min_flux_for_dir_update * min_flux_for_dir_update;
    int days_per_year = int(knobs.has("days_per_year") ? int(knobs["days_per_year"]) : 365);
    if (days_per_year < 1) days_per_year = 1;
    else if (days_per_year > 3660) days_per_year = 3660;
    double year_phase = std::fmod(season_phase, 4.0);
    if (year_phase < 0.0) year_phase += 4.0;
    const int sim_day = int(knobs.has("sim_day") ? int(knobs["sim_day"]) : int(std::floor((year_phase / 4.0) * double(days_per_year))));
    const int world_seed = int(knobs.has("world_seed") ? int(knobs["world_seed"]) : 0);
    const double wrap_origin_x = double(knobs.has("wrap_origin_x") ? double(knobs["wrap_origin_x"]) : 0.0);
    const double wrap_period_x = double(knobs.has("wrap_period_x") ? double(knobs["wrap_period_x"]) : 0.0);
    // ─── NS 化旋钮(plan/NS化气候动力学四方向深化,2026-08-04)──────────────
    // 全部默认 0/关 → 缺省时与旧诊断风逐位一致。分 Phase 独立 gate,便于 A/B。
    // 方向 A:动量自平流权重(≤0.5,读上一轮轨迹表;首跑无表退化为 own-cell)
    double momentum_advect_w = double(knobs.has("wind_momentum_advect_w") ? double(knobs["wind_momentum_advect_w"]) : 0.0);
    momentum_advect_w = wind_clamp(momentum_advect_w, 0.0, 0.5);
    // 方向 A:动量扩散日权重(6 邻居 Laplacian 松弛;dt 与格距归一在主循环前换算)
    double momentum_diffuse_w_daily = double(knobs.has("wind_momentum_diffuse_w_daily") ? double(knobs["wind_momentum_diffuse_w_daily"]) : 0.0);
    momentum_diffuse_w_daily = wind_clamp(momentum_diffuse_w_daily, 0.0, 0.5);
    // Phase 0:轨迹表构建 gate(动量自平流开启时强制构建,供下一轮消费)
    const bool traj_table_enabled = bool(knobs.has("wind_traj_table_enabled") ? bool(knobs["wind_traj_table_enabled"]) : false);
    // 回溯长度 = |flux|·traj_pos_scale·s·traj_dt_days(pos 单位;s=√(N/15000) 格距归一)
    double traj_pos_scale = double(knobs.has("wind_traj_pos_scale") ? double(knobs["wind_traj_pos_scale"]) : 0.65);
    traj_pos_scale = wind_clamp(traj_pos_scale, 0.0, 4.0);
    double traj_dt_days = double(knobs.has("wind_traj_dt_days") ? double(knobs["wind_traj_dt_days"]) : 10.0);
    traj_dt_days = wind_clamp(traj_dt_days, 0.25, 60.0);
    // 消费端总闸(weather field solve / wind_air):false 时仅构建不共享(A/B 隔离)
    _phys_wind_traj_consume_enabled = bool(knobs.has("wind_traj_weather_share") ? bool(knobs["wind_traj_weather_share"]) : true);
    // 方向 B:散度阻尼 L1 强度(格单位,硬上限 0.3;超出 push_warning 并 clamp)
    double div_damp_alpha = double(knobs.has("wind_div_damp_alpha") ? double(knobs["wind_div_damp_alpha"]) : 0.0);
    if (div_damp_alpha > 0.3) {
        static bool s_warned_div_alpha = false;
        if (!s_warned_div_alpha) {
            s_warned_div_alpha = true;
            UtilityFunctions::push_warning(
                "[DCWorldExt] run_wind_field_pass: wind_div_damp_alpha > 0.3 clamped "
                "(散度阻尼硬上限,防误杀天气尺度辐合)");
        }
        div_damp_alpha = 0.3;
    }
    if (div_damp_alpha < 0.0) div_damp_alpha = 0.0;
    const bool thermal_monsoon_enabled = bool(knobs.has("thermal_monsoon_enabled")
        ? bool(knobs["thermal_monsoon_enabled"]) : false);
    const double monsoon_lat_limit = wind_clamp(double(knobs.get(
        "thermal_monsoon_lat_limit", 0.45)), 0.0, 1.0);
    const double monsoon_deadband = wind_clamp(double(knobs.get(
        "thermal_monsoon_deadband", 0.015)), 0.0, 0.10);
    const double monsoon_full_contrast = std::max(
        monsoon_deadband + 0.001,
        wind_clamp(double(knobs.get("thermal_monsoon_full_contrast", 0.08)),
                   0.01, 0.25));
    const double monsoon_gain = wind_clamp(double(knobs.get(
        "thermal_monsoon_gain", 0.85)), 0.0, 1.5);
    const double monsoon_breeze_floor = wind_clamp(double(knobs.get(
        "thermal_monsoon_breeze_floor", 0.20)), 0.0, 0.5);
    if (n_cells <= 0)         { diag("n_cells <= 0"); return -1.0; }
    if (bounds_size_y <= 0.001) { diag("world_bounds_size_y <= 0.001"); return -1.0; }

    PackedInt32Array  nb_arr     = knobs["neighbor_indices"];
    PackedFloat32Array slp_arr   = knobs["slp_arr"];
    PackedByteArray   water_ids  = knobs["water_terrain_ids"];
    if (nb_arr.size()  < n_cells * 6) { diag("neighbor_indices size < n_cells * 6"); return -1.0; }
    if (slp_arr.size() < n_cells)     { diag("slp_arr size < n_cells");              return -1.0; }
    if (water_ids.size() <= 0)        { diag("water_terrain_ids empty");             return -1.0; }

    // Slot id resolution (cached via _phys_resolve_static; FNV 指纹失效，地图 regen 自动重建)。
    _phys_resolve_static(n_cells, water_ids);
    const int sid_pos_x    = _phys_sid_pos_x;
    const int sid_pos_y    = _phys_sid_pos_y;
    const int sid_terrain  = _phys_sid_terrain;
    const int sid_landform = _phys_sid_landform;
    const int sid_wind_x   = _phys_sid_wind_x;
    const int sid_wind_y   = _phys_sid_wind_y;
    const int sid_wind_spd = _phys_sid_wind_spd;
    const int sid_temp      = _phys_sid_temp;
    if (sid_pos_x < 0 || sid_pos_y < 0 || sid_terrain < 0 || sid_landform < 0 ||
        sid_wind_x < 0 || sid_wind_y < 0 || sid_wind_spd < 0 ||
        (thermal_monsoon_enabled && sid_temp < 0)) {
        diag("missing slot id (cell_pos_x/cell_pos_y/terrain/landform/wind_x/wind_y/wind_speed/temp)");
        return -1.0;
    }

    // 256-entry is_water LUT（cached via _phys_resolve_static, 同指纹随 slot 一起重建）。
    const bool *is_water_lut = _phys_is_water_lut;

    // Item 2: cell-range 切片（默认全量，逐位等价；GDScript 游标驱动时传 start_idx/end_idx）。
    int start_idx = knobs.has("start_idx") ? int(knobs["start_idx"]) : 0;
    int end_idx   = knobs.has("end_idx")   ? int(knobs["end_idx"])   : n_cells;
    if (start_idx < 0)       start_idx = 0;
    if (end_idx > n_cells)   end_idx = n_cells;
    if (start_idx > end_idx) start_idx = end_idx;
    const int slice_n = end_idx - start_idx;

    // ─── Acquire slot arrays + validate sizes ───────────────────────────
    Slot &s_pos_x    = _slots.write[sid_pos_x];
    Slot &s_pos_y    = _slots.write[sid_pos_y];
    Slot &s_terrain  = _slots.write[sid_terrain];
    Slot &s_landform = _slots.write[sid_landform];
    Slot &s_wind_x   = _slots.write[sid_wind_x];
    Slot &s_wind_y   = _slots.write[sid_wind_y];
    Slot &s_wind_spd = _slots.write[sid_wind_spd];
    Slot *s_temp      = sid_temp >= 0 ? &_slots.write[sid_temp] : nullptr;
    if (s_pos_x.arr_f32.size()    != n_cells ||
        s_pos_y.arr_f32.size()    != n_cells ||
        s_terrain.arr_u8.size()   != n_cells ||
        s_landform.arr_u8.size()  != n_cells ||
        s_wind_x.arr_f32.size()   != n_cells ||
        s_wind_y.arr_f32.size()   != n_cells ||
        s_wind_spd.arr_f32.size() != n_cells ||
        (thermal_monsoon_enabled &&
         (s_temp == nullptr || s_temp->arr_f32.size() != n_cells))) {
        diag("slot array size mismatch (re-bind needed?)");
        return -1.0;
    }

    // ─── Hot pointers ──────────────────────────────────────────────────
    const float   * const __restrict POSX = s_pos_x.arr_f32.ptr();
    const float   * const __restrict POSY = s_pos_y.arr_f32.ptr();
    const uint8_t * const __restrict TR   = s_terrain.arr_u8.ptr();
    const uint8_t * const __restrict LF   = s_landform.arr_u8.ptr();
    float         * const __restrict WX   = s_wind_x.arr_f32.ptrw();
    float         * const __restrict WY   = s_wind_y.arr_f32.ptrw();
    float         * const __restrict WSP_SLOT = s_wind_spd.arr_f32.ptrw();
    const float   * const __restrict TEMP = (s_temp != nullptr &&
        s_temp->arr_f32.size() == n_cells) ? s_temp->arr_f32.ptr() : nullptr;
    const int32_t * const __restrict NB   = nb_arr.ptr();
    const float   * const __restrict SLP  = slp_arr.ptr();

    auto t0 = std::chrono::high_resolution_clock::now();

    // ─── Pass 0 / 0b: coast/sea BFS（缓存到成员，指纹失配才重建；见 _phys_ensure_wind_coast）──
    // 主循环读 coast_dist/sea_dist 等指针（指向成员缓存），不再每调用重建全图 vector。
    _phys_ensure_wind_coast(n_cells, TR, NB, is_water_lut, water_ids);
    const int8_t  *coast_dist  = _phys_wind_coast_dist.data();
    const float   *coast_sea_x = _phys_wind_coast_sea_x.data();
    const float   *coast_sea_y = _phys_wind_coast_sea_y.data();
    const int8_t  *sea_dist    = _phys_wind_sea_dist.data();
    const float   *sea_land_x  = _phys_wind_sea_land_x.data();
    const float   *sea_land_y  = _phys_wind_sea_land_y.data();
    const int32_t *coast_sea_anchor = _phys_wind_coast_sea_anchor.data();
    const int32_t *sea_land_anchor = _phys_wind_sea_land_anchor.data();
    if (_phys_monsoon_thermal.size() != static_cast<size_t>(n_cells)) {
        _phys_monsoon_thermal.assign(static_cast<size_t>(n_cells), 0.0f);
    }

    // ─── 主循环 ────────────────────────────────────────────────────────
    // wind_speed_out 写入 knobs；caller 拿来同步到 cell.wind_speed
    PackedFloat32Array wind_speed_out;
    wind_speed_out.resize(n_cells);
    float * const __restrict WSPD = wind_speed_out.ptrw();
    std::vector<float> wind_delta(static_cast<size_t>(n_cells), 0.0f);
    std::vector<float> wind_dir_delta(static_cast<size_t>(n_cells), 0.0f);
    int wind_flip_count = 0;
    // perf (2A): wind 逐 cell 独立（邻居只读 SLP/LF/TR，自身读写 WX/WY/WSP_SLOT/WSPD/
    // wind_delta/wind_dir_delta[i]，唯一 cross-cell 共享是 flip 计数标量）→ thread-local
    // emit + 串行 reduce 并行；flip 为整数加法、task 顺序无关 → bit-equal。
    struct WindFlipEmit {
        int flip = 0;
        int monsoon_eligible = 0;
        int monsoon_onshore = 0;
        int monsoon_offshore = 0;
        float monsoon_abs_max = 0.0f;
        void merge_into(WindFlipEmit &dst) const {
            dst.flip += flip;
            dst.monsoon_eligible += monsoon_eligible;
            dst.monsoon_onshore += monsoon_onshore;
            dst.monsoon_offshore += monsoon_offshore;
            if (monsoon_abs_max > dst.monsoon_abs_max) {
                dst.monsoon_abs_max = monsoon_abs_max;
            }
        }
    };
    WindFlipEmit wind_flip_emit;

    // 纬度权威：cell_lat_norm slot（见 phys_make_lat_norm 注释）。world_bounds_* 不再参与
    // 纬度归一化，仅保留 knob 契约校验。
    const PhysLatNorm LATN = phys_make_lat_norm(_phys_lat_norm_ptr(n_cells), POSY, n_cells);
    (void)bounds_pos_y;
    (void)bounds_size_y;
    const bool   ta = terrain_aware;
    double bounds_pos_x = double(POSX[0]);
    double bounds_max_x = bounds_pos_x;
    for (int i = 1; i < n_cells; ++i) {
        const double px_i = double(POSX[i]);
        if (px_i < bounds_pos_x) bounds_pos_x = px_i;
        else if (px_i > bounds_max_x) bounds_max_x = px_i;
    }
    const double inv_bounds_w = 1.0 / std::max(0.001, bounds_max_x - bounds_pos_x);
    const bool has_wrap_domain = wrap_period_x > 0.001;
    {
        static bool s_warned_wind_wrap = false;
        physical_warn_wrap_units("wind_field", wrap_period_x, bounds_max_x - bounds_pos_x,
                                 s_warned_wind_wrap);
    }
    const uint32_t seed_bits = static_cast<uint32_t>(world_seed);

    // ─── NS 化 Phase 1:旧通量快照 + 有效权重换算(动量关闭时零成本零数值差)──
    // 快照是并行安全的唯一前提:主循环内邻居的旧通量必须读快照而非 slot(slot 在
    // 并行写回中)。内存 ≈0.9MB@110k,内存换耗时(与 coast BFS 缓存同策)。
    // 切片兼容:快照驻留成员,只在首切片(start_idx==0)或换图(size 失配)重建;
    // 后续切片复用 → 切片执行与全量执行逐位一致(每切片各拍会读到前序切片已写回
    // 的新风,污染"旧值"语义)。
    const bool momentum_active = (momentum_advect_w > 0.0 || momentum_diffuse_w_daily > 0.0);
    if (momentum_active
            && (start_idx == 0 || int(_phys_wind_snap_fx.size()) != n_cells)) {
        _phys_wind_snap_fx.resize(static_cast<size_t>(n_cells));
        _phys_wind_snap_fy.resize(static_cast<size_t>(n_cells));
        for (int i = 0; i < n_cells; ++i) {
            _phys_wind_snap_fx[static_cast<size_t>(i)] = WX[i] * WSP_SLOT[i];
            _phys_wind_snap_fy[static_cast<size_t>(i)] = WY[i] * WSP_SLOT[i];
        }
    }
    const float * const __restrict SNAP_FX = momentum_active ? _phys_wind_snap_fx.data() : nullptr;
    const float * const __restrict SNAP_FY = momentum_active ? _phys_wind_snap_fy.data() : nullptr;
    // 扩散权重:日权重按 wind_elapsed_days 换算(沿用 max_turn_rad 的 rate 语义),
    // 再乘 s² 格距归一(w=ν·dt/h²,h∝1/√N);上限 0.5 = 6 邻居显式扩散无条件稳定域。
    const double grid_s = std::sqrt(double(n_cells) / 15000.0);
    double diffuse_w = 0.0;
    if (momentum_diffuse_w_daily > 0.0) {
        diffuse_w = 1.0 - std::pow(1.0 - momentum_diffuse_w_daily, wind_elapsed_days);
        diffuse_w *= grid_s * grid_s;
        if (diffuse_w > 0.5) diffuse_w = 0.5;
    }
    // 自平流读上一轮轨迹表(几何冻结系数,滞后一次 wind 更新);首跑无表 → 跳过。
    const int32_t * const __restrict TRAJ_IDX =
        (momentum_advect_w > 0.0 && _phys_wind_traj_valid
         && int(_phys_wind_traj_idx.size()) == n_cells * 3
         && pk_wind_state_fp(n_cells, WX, WY, WSP_SLOT) == _phys_wind_traj_fp)
            ? _phys_wind_traj_idx.data() : nullptr;
    const float * const __restrict TRAJ_W = (TRAJ_IDX != nullptr) ? _phys_wind_traj_w.data() : nullptr;
    std::vector<float> momentum_delta;
    if (momentum_active) momentum_delta.assign(static_cast<size_t>(n_cells), 0.0f);

    // B8 P2：主循环体已搬到 pk_async_physics::wind_field_range（worker 与生产
    // 共用同一份）。这里只负责组装 POD 与把分段统计合并回 WindFlipEmit。
    pk_async_physics::WindFieldKnobs wind_k;
    wind_k.season_phase = season_phase;
    wind_k.axial_tilt_deg = axial_tilt_deg;
    wind_k.terrain_aware = terrain_aware;
    wind_k.wind_belt_only = wind_belt_only;
    wind_k.response_rate = double(response_rate);
    wind_k.synoptic_amp = synoptic_amp;
    wind_k.synoptic_period_days = synoptic_period_days;
    wind_k.max_turn_rad = max_turn_rad;
    wind_k.min_flux_len2 = min_flux_len2;
    wind_k.sim_day = sim_day;
    wind_k.world_seed = world_seed;
    wind_k.bounds_pos_x = bounds_pos_x;
    wind_k.inv_bounds_w = inv_bounds_w;
    wind_k.has_wrap_domain = has_wrap_domain;
    wind_k.wrap_origin_x = wrap_origin_x;
    wind_k.wrap_period_x = wrap_period_x;
    wind_k.lf_mountain = lf_mountain;
    wind_k.lf_peak = lf_peak;
    wind_k.lf_hill = lf_hill;
    wind_k.thermal_monsoon_enabled = thermal_monsoon_enabled;
    wind_k.monsoon_lat_limit = monsoon_lat_limit;
    wind_k.monsoon_deadband = monsoon_deadband;
    wind_k.monsoon_full_contrast = monsoon_full_contrast;
    wind_k.monsoon_gain = monsoon_gain;
    wind_k.monsoon_breeze_floor = monsoon_breeze_floor;
    wind_k.momentum_active = momentum_active;
    wind_k.momentum_advect_w = momentum_advect_w;
    wind_k.diffuse_w = diffuse_w;
    wind_k.traj_idx = TRAJ_IDX;
    wind_k.traj_w = TRAJ_W;
    wind_k.snap_fx = SNAP_FX;
    wind_k.snap_fy = SNAP_FY;
    pk_async_physics::WindFieldLanes wind_l;
    wind_l.lat_norm = LATN.lat;
    wind_l.pos_y = LATN.posy;
    wind_l.lat_origin = LATN.origin;
    wind_l.lat_inv_span = LATN.inv_span;
    wind_l.pos_x = POSX;
    wind_l.slp = SLP;
    wind_l.neighbors = NB;
    wind_l.terrain = TR;
    wind_l.landform = LF;
    wind_l.is_water_lut = is_water_lut;
    wind_l.coast_dist = _phys_wind_coast_dist.data();
    wind_l.coast_sea_x = _phys_wind_coast_sea_x.data();
    wind_l.coast_sea_y = _phys_wind_coast_sea_y.data();
    wind_l.coast_sea_anchor = _phys_wind_coast_sea_anchor.data();
    wind_l.sea_dist = _phys_wind_sea_dist.data();
    wind_l.sea_land_x = _phys_wind_sea_land_x.data();
    wind_l.sea_land_y = _phys_wind_sea_land_y.data();
    wind_l.sea_land_anchor = _phys_wind_sea_land_anchor.data();
    wind_l.temp = TEMP;
    wind_l.wind_x = WX;
    wind_l.wind_y = WY;
    wind_l.wind_speed = WSP_SLOT;
    wind_l.wind_speed_out = WSPD;
    wind_l.wind_delta = wind_delta.data();
    wind_l.wind_dir_delta = wind_dir_delta.data();
    wind_l.momentum_delta = momentum_delta.empty() ? nullptr : momentum_delta.data();
    wind_l.monsoon_thermal = _phys_monsoon_thermal.data();
    pk::parallel_for_range_with_emit<WindFlipEmit>(
        "pk_wind_field", slice_n, wind_flip_emit,
        [&](int __wrb, int __wre, WindFlipEmit &__we) {
            pk_async_physics::WindFieldStats wind_stats;
            pk_async_physics::wind_field_range(
                n_cells, start_idx + __wrb, start_idx + __wre,
                wind_k, wind_l, wind_stats);
            // 逐字段合并（emit 类型归生产所有，内核只给统计 POD）。
            __we.flip += wind_stats.flip;
            __we.monsoon_eligible += wind_stats.monsoon_eligible;
            __we.monsoon_onshore += wind_stats.monsoon_onshore;
            __we.monsoon_offshore += wind_stats.monsoon_offshore;
            if (wind_stats.monsoon_abs_max > __we.monsoon_abs_max) {
                __we.monsoon_abs_max = wind_stats.monsoon_abs_max;
            }
        }); // pk_wind_field parallel_for_range_with_emit
    wind_flip_count = wind_flip_emit.flip;
    if (start_idx == 0) {
        _monsoon_eligible_cells = 0;
        _monsoon_onshore_cells = 0;
        _monsoon_offshore_cells = 0;
        _monsoon_contrast_abs_max = 0.0f;
    }
    _monsoon_eligible_cells += wind_flip_emit.monsoon_eligible;
    _monsoon_onshore_cells += wind_flip_emit.monsoon_onshore;
    _monsoon_offshore_cells += wind_flip_emit.monsoon_offshore;
    if (wind_flip_emit.monsoon_abs_max > _monsoon_contrast_abs_max) {
        _monsoon_contrast_abs_max = wind_flip_emit.monsoon_abs_max;
    }

    // ─── NS 化 Phase 3:散度阻尼 L1(仅末切片/全量,对完整新风场执行)─────────
    // div = ∇·V 与 grad(div) 用与 (b) 段相同的 (1/3)Σ_d Δ·NB_DIR 离散(内洽):
    // V += α_eff·∇div —— 符号取 +:∂E/∂t = -α∫|∇div|² ≤ 0(E=½∫div²),
    // 即 div 的扩散(阻尼);取 - 则是反扩散,放大散度模态(2026-08-04 DIV-only
    // A/B 实测证实:div p95 +10%、风速 +3.8%,已据此翻转符号)。
    // α 按 s² 格距归一、硬上限 0.3 → 谱选择性压制网格级散度噪声,
    // 几乎不触行星尺度辐合(NWP 标准散度阻尼)。两趟只读/写分离 sweep,bit-equal 并行。
    // 不复用 turn-limit(α 小,增量远低于 32°/日帽);div_damp_alpha==0 时零成本。
    double div_damp_applied = 0.0;
    if (div_damp_alpha > 0.0 && end_idx == n_cells && n_cells > 0) {
        double a_eff = div_damp_alpha * grid_s * grid_s;
        if (a_eff > 0.3) a_eff = 0.3;
        std::vector<float> div_f(static_cast<size_t>(n_cells), 0.0f);
        float * const __restrict DIV = div_f.data();
        pk::parallel_for_range("pk_wind_div1", n_cells, [&](int rb, int re) {
            pk_async_physics::wind_divergence_range(n_cells, rb, re, NB, WX, WY, WSP_SLOT, DIV);
        });
        pk::parallel_for_range("pk_wind_div2", n_cells, [&](int rb, int re) {
            pk_async_physics::wind_divergence_apply_range(n_cells, rb, re, NB, DIV, a_eff, WX, WY, WSP_SLOT);
        });
        div_damp_applied = a_eff;
    }

    // ─── NS 化 Phase 0/2:回溯轨迹表(消费端 weather/wind_air 指纹校验共享)────
    // 动量自平流开启时强制构建(下一轮 wind pass 读本表);只在末切片对完整新风场
    // 构建,保证表与发布风严格一致。构建于 div 阻尼之后 → 表反映最终风。
    if ((traj_table_enabled || momentum_active) && end_idx == n_cells && n_cells > 0) {
        _phys_build_wind_traj(n_cells, POSX, POSY, NB, WX, WY, WSP_SLOT,
                              wrap_period_x, traj_pos_scale, traj_dt_days);
        knobs["wind_traj_gen"] = int(_phys_wind_traj_gen);
    }

    // Item 2: 重建完整 wind_speed_out（GDScript 整图写回 cell.wind_speed；切片外 cell
    // 取 slot 上一 tick 值，切片内 cell 取本 tick 新值 → 整图一致、无 0 污染）。
    {
        const float *src = s_wind_spd.arr_f32.ptr();
        float *dst = wind_speed_out.ptrw();
        for (int i = 0; i < n_cells; ++i) dst[i] = src[i];
    }

    // §11.2 flush: push CoW-detached cell_wind_x/y back to MapData
    _flush_slot_to_map(sid_wind_x);
    _flush_slot_to_map(sid_wind_y);
    _flush_slot_to_map(sid_wind_spd);

    // 输出回填到 knobs（让 GDScript caller 拿到 wind_speed_out 写每 cell.wind_speed）
    knobs["wind_speed_out"] = wind_speed_out;
    if (!wind_delta.empty()) {
        std::sort(wind_delta.begin(), wind_delta.end());
        const size_t p95_i = std::min(wind_delta.size() - 1, size_t(std::floor(double(wind_delta.size() - 1) * 0.95)));
        knobs["wind_delta_p95"] = double(wind_delta[p95_i]);
    }
    if (!wind_dir_delta.empty()) {
        std::sort(wind_dir_delta.begin(), wind_dir_delta.end());
        const size_t p95_i = std::min(wind_dir_delta.size() - 1, size_t(std::floor(double(wind_dir_delta.size() - 1) * 0.95)));
        knobs["wind_dir_delta_p95"] = double(wind_dir_delta[p95_i]);
        knobs["wind_dir_flip_count"] = wind_flip_count;
    }
    // NS 化诊断键(进现有 slow-dump 链;momentum/div_damp 关闭时恒 0,键始终存在)。
    if (!momentum_delta.empty()) {
        std::sort(momentum_delta.begin(), momentum_delta.end());
        const size_t p95_i = std::min(momentum_delta.size() - 1, size_t(std::floor(double(momentum_delta.size() - 1) * 0.95)));
        knobs["momentum_advect_diffuse_delta_p95"] = double(momentum_delta[p95_i]);
    }
    knobs["momentum_advect_w_eff"] = momentum_advect_w;
    knobs["momentum_diffuse_w_eff"] = diffuse_w;
    knobs["div_damp_alpha_eff"] = div_damp_applied;
    knobs["wind_traj_stale_count"] = _phys_wind_traj_stale_count;
    knobs["monsoon_eligible_cells"] = _monsoon_eligible_cells;
    knobs["monsoon_onshore_cells"] = _monsoon_onshore_cells;
    knobs["monsoon_offshore_cells"] = _monsoon_offshore_cells;
    knobs["monsoon_contrast_abs_max"] = _monsoon_contrast_abs_max;
    knobs["monsoon_coast_cache_hit"] = _phys_wind_coast_last_hit;
    knobs["monsoon_coast_cache_build_ms"] = _phys_wind_coast_build_ms;

    auto t1 = std::chrono::high_resolution_clock::now();
    return std::chrono::duration<double, std::milli>(t1 - t0).count();
}

// DOTS-Total-CPP（plan/dots-total-cpp 任务 4）：
// run_ocean_field_rasterize — hex→pixel rasterize 一次性 C++ 直出。
// 替代 GDScript _rasterize_ocean_current_slice_from_hex + _rasterize_upwelling_slice_from_hex
// 的 17 个 pixel slice，消除 ocean_currents 25ms slow slice 源头。
godot::Dictionary DCWorldExt::run_ocean_field_rasterize(godot::Dictionary knobs) {
    using godot::Dictionary;
    using godot::PackedByteArray;
    using godot::PackedInt32Array;
    using godot::String;
    using godot::StringName;

    Dictionary out;
    out["elapsed_ms"] = -1.0;
    out["fallback"] = true;
    out["reason"] = String();
    out["pixels"] = 0;
    out["atlas_updated"] = false;

    auto fail = [&](const char *why) -> Dictionary {
        out["reason"] = String(why);
        UtilityFunctions::push_warning("[DCWorldExt] run_ocean_field_rasterize: ", why,
                                       " - fallback to GDScript");
        return out;
    };

    if (!_bound) return fail("not bound");
    if (!knobs.has("n_cells") || !knobs.has("w") || !knobs.has("h") ||
        !knobs.has("pixel_to_cell_idx") ||
        !knobs.has("dst_currents") || !knobs.has("dst_upwelling")) {
        return fail("missing required knob");
    }

    const int n_cells = int(knobs["n_cells"]);
    const int W = int(knobs["w"]);
    const int H = int(knobs["h"]);
    if (n_cells <= 0 || W <= 0 || H <= 0) return fail("invalid dims");
    const int n_px = W * H;

    PackedInt32Array px2cell = knobs["pixel_to_cell_idx"];
    PackedByteArray  dst_cur = knobs["dst_currents"];
    PackedByteArray  dst_up  = knobs["dst_upwelling"];
    if (px2cell.size() != n_px) return fail("pixel_to_cell_idx size mismatch");
    if (dst_cur.size() != n_px * 2) return fail("dst_currents size mismatch");
    if (dst_up.size() != n_px) return fail("dst_upwelling size mismatch");

    // ─── Sub-slice 像素区间（plan/ocean-raster-subslice 2026-05-22）──────────
    // 可选 knobs：start_idx / end_idx（缺省 = 全图 [0, n_px)），用于把 4.7ms
    // 整图 raster 拆成 N 个 sub-tick 各 ~1.2ms，复用 commit-defer 框架。
    // hot loop per-pixel 完全独立（只读 P2C[i] / SoA[ci] + 写 DCUR/DUP/ATLAS[i]），
    // 任意 [start, end) 切片 bit-equal。pending buffer / atlas_data 长度仍按 n_px
    // 校验 — caller 必须保证整轮 round 复用同一组缓冲。
    int start_idx = 0;
    int end_idx = n_px;
    if (knobs.has("start_idx")) start_idx = int(knobs["start_idx"]);
    if (knobs.has("end_idx"))   end_idx   = int(knobs["end_idx"]);
    if (start_idx < 0) start_idx = 0;
    if (end_idx > n_px) end_idx = n_px;
    if (start_idx > end_idx) start_idx = end_idx;

    const int sid_terrain = component_id(StringName("cell_terrain"));
    const int sid_ocx     = component_id(StringName("cell_ocean_current_x"));
    const int sid_ocy     = component_id(StringName("cell_ocean_current_y"));
    const int sid_up      = component_id(StringName("cell_upwelling_strength"));
    if (sid_terrain < 0 || sid_ocx < 0 || sid_ocy < 0 || sid_up < 0) {
        return fail("missing slot id");
    }
    Slot &s_terr = _slots.write[sid_terrain];
    Slot &s_ocx  = _slots.write[sid_ocx];
    Slot &s_ocy  = _slots.write[sid_ocy];
    Slot &s_up   = _slots.write[sid_up];
    if (s_terr.arr_u8.size()  != n_cells ||
        s_ocx.arr_f32.size()  != n_cells ||
        s_ocy.arr_f32.size()  != n_cells ||
        s_up.arr_f32.size()   != n_cells) {
        return fail("slot array size mismatch");
    }

    PackedFloat32Array visual_x = s_ocx.arr_f32, visual_y = s_ocy.arr_f32, visual_up = s_up.arr_f32;
    if (knobs.has("physics_read_view")) {
        if (knobs["physics_read_view"].get_type() != Variant::DICTIONARY) return fail("physics_view_type");
        const Dictionary view = knobs["physics_read_view"];
        for (const char *key : {"ocean_current_x", "ocean_current_y", "upwelling"}) {
            if (!view.has(key) || view[key].get_type() != Variant::PACKED_FLOAT32_ARRAY ||
                PackedFloat32Array(view[key]).size() != n_cells) return fail("physics_view_shape");
            const PackedFloat32Array lane = view[key];
            for (int i = 0; i < n_cells; ++i) if (!std::isfinite(lane[i])) return fail("physics_view_nonfinite");
        }
        visual_x = view["ocean_current_x"]; visual_y = view["ocean_current_y"]; visual_up = view["upwelling"];
    }
    const uint8_t * const __restrict TERR = s_terr.arr_u8.ptr();
    const float   * const __restrict OCX  = visual_x.ptr();
    const float   * const __restrict OCY  = visual_y.ptr();
    const float   * const __restrict UP   = visual_up.ptr();
    const int32_t * const __restrict P2C  = px2cell.ptr();
    uint8_t       * const __restrict DCUR = dst_cur.ptrw();
    uint8_t       * const __restrict DUP  = dst_up.ptrw();

    // 可选 atlas_data 同步（与 GDScript _vector_atlas_data 共享）
    bool atlas_ok = false;
    uint8_t *ATLAS = nullptr;
    PackedByteArray atlas_data;
    const bool update_atlas = bool(knobs.get("update_atlas_data", false));
    if (update_atlas && knobs.has("atlas_data")) {
        atlas_data = knobs["atlas_data"];
        if (atlas_data.size() == n_px * 4) {
            atlas_ok = true;
            ATLAS = atlas_data.ptrw();
        }
    }

    auto t0 = std::chrono::high_resolution_clock::now();
    int written = 0;

    // ─── Hot loop 优化（25ns/pixel → 目标 ~3-5ns/pixel） ──────────────────
    // 1. 干掉 std::round（MSVC 不内联，每次函数调用 + double 转换）。
    //    替换为 `(int)(v * 127.5f + 128.5f)` —— round-half-up 的纯 float
    //    形式，编译器会发成单条 cvttss2si。误差仅在 v 正负边界的 0.5ULP，
    //    与原 GDScript round 行为一致（_quantize_to_byte_signed 也是 round_half）。
    // 2. 全 float 流水线，零 f32→f64→f32 来回转。
    // 3. clamp 改用三元 / std::min-max，向量化友好。
    // 4. atlas_ok 分支按整循环静态分流，避免每像素 if。
    auto quantize_signed = [](float v) -> uint8_t {
        // v ∈ [-1,1] → byte ∈ [0,255]，128 ≈ 0
        // 原 round((v*0.5+0.5)*255) = round(v*127.5+127.5)。round-half-up
        // 用 truncation 等价：trunc(x+0.5)。即 trunc(v*127.5 + 128.0)。
        // 与原 GDScript / C++ std::round 行为完全一致（误差 0 ULP）。
        float q = v * 127.5f + 128.0f;
        if (q <= 0.0f) return 0;
        if (q >= 255.0f) return 255;
        return uint8_t(int(q));  // trunc
    };
    // upwelling 用专门量化（原版 round(128 + 127*up)，比 currents 窄 1）
    auto quantize_upwelling = [](float v) -> uint8_t {
        if (v < -1.0f) v = -1.0f;
        else if (v > 1.0f) v = 1.0f;
        // round(128 + 127*v) → trunc(128 + 127*v + 0.5) = trunc(128.5 + 127*v)
        float q = 128.5f + 127.0f * v;
        if (q <= 0.0f) return 0;
        if (q >= 255.0f) return 255;
        return uint8_t(int(q));
    };

    // perf (2B): per-pixel 完全独立（只读 P2C[i]/SoA[ci]，写 DCUR/DUP/ATLAS[i] 互不相交，
    // 无标量累加器）→ 按像素区间并行、逐字节 bit-equal、无需 reduce。像素工作极轻
    // (~3-5ns)，seq_threshold 设高，仅大 raster 切片才并行（小切片走串行免线程开销）。
    auto raster_atlas = [&](int b, int e) {
        for (int i = b; i < e; ++i) {
            const int32_t ci = P2C[i];
            float cur_x = 0.0f;
            float cur_y = 0.0f;
            float up_v  = 0.0f;
            bool is_water = false;
            if (uint32_t(ci) < uint32_t(n_cells)) {  // unsigned cmp 同时排除 ci<0
                is_water = pk_is_water_terrain(TERR[ci]);
                if (is_water) {
                    cur_x = OCX[ci];
                    cur_y = OCY[ci];
                    up_v  = UP[ci];
                }
            }
            const uint8_t bx = quantize_signed(cur_x);
            const uint8_t by = quantize_signed(cur_y);
            DCUR[i * 2]     = bx;
            DCUR[i * 2 + 1] = by;
            DUP[i] = is_water ? quantize_upwelling(up_v) : uint8_t(128);
            ATLAS[i * 4]     = bx;
            ATLAS[i * 4 + 1] = by;
            // ATLAS[i*4+2..+3] 由 wind 通道写，rasterize 不动
        }
    };
    auto raster_plain = [&](int b, int e) {
        for (int i = b; i < e; ++i) {
            const int32_t ci = P2C[i];
            float cur_x = 0.0f;
            float cur_y = 0.0f;
            float up_v  = 0.0f;
            bool is_water = false;
            if (uint32_t(ci) < uint32_t(n_cells)) {
                is_water = pk_is_water_terrain(TERR[ci]);
                if (is_water) {
                    cur_x = OCX[ci];
                    cur_y = OCY[ci];
                    up_v  = UP[ci];
                }
            }
            DCUR[i * 2]     = quantize_signed(cur_x);
            DCUR[i * 2 + 1] = quantize_signed(cur_y);
            DUP[i] = is_water ? quantize_upwelling(up_v) : uint8_t(128);
        }
    };
    const int range_n = end_idx - start_idx;
    if (atlas_ok) {
        pk::parallel_for_range("pk_ocean_raster_a", range_n, /*n_tasks_hint=*/0,
            /*seq_threshold=*/16384,
            [&](int b, int e) { raster_atlas(start_idx + b, start_idx + e); });
    } else {
        pk::parallel_for_range("pk_ocean_raster", range_n, /*n_tasks_hint=*/0,
            /*seq_threshold=*/16384,
            [&](int b, int e) { raster_plain(start_idx + b, start_idx + e); });
    }
    written = end_idx - start_idx;

    knobs["dst_currents"]   = dst_cur;
    knobs["dst_upwelling"]  = dst_up;
    if (atlas_ok) {
        knobs["atlas_data"] = atlas_data;
    }

    auto t1 = std::chrono::high_resolution_clock::now();
    out["elapsed_ms"] = std::chrono::duration<double, std::milli>(t1 - t0).count();
    out["fallback"] = false;
    out["reason"] = String();
    out["pixels"] = written;
    out["atlas_updated"] = atlas_ok;
    out["start_idx"] = start_idx;
    out["end_idx"] = end_idx;
    return out;
}

// DOTS-Total-CPP（A 方案 / wind raster 孪生）：
// run_wind_field_rasterize — wind_x/wind_y SoA → hex→pixel byte 一次性直出。
// 替代 GDScript map_baker.gd::_rasterize_wind_slice_from_hex 的 21 片 × ~87ms 循环。
godot::Dictionary DCWorldExt::run_wind_field_rasterize(godot::Dictionary knobs) {
    using godot::Dictionary;
    using godot::PackedByteArray;
    using godot::PackedInt32Array;
    using godot::String;
    using godot::StringName;

    Dictionary out;
    out["elapsed_ms"] = -1.0;
    out["fallback"] = true;
    out["reason"] = String();
    out["pixels"] = 0;
    out["atlas_updated"] = false;

    auto fail = [&](const char *why) -> Dictionary {
        out["reason"] = String(why);
        UtilityFunctions::push_warning("[DCWorldExt] run_wind_field_rasterize: ", why,
                                       " - fallback to GDScript");
        return out;
    };

    if (!_bound) return fail("not bound");
    if (!knobs.has("n_cells") || !knobs.has("w") || !knobs.has("h") ||
        !knobs.has("pixel_to_cell_idx") || !knobs.has("dst_wind")) {
        return fail("missing required knob");
    }

    const int n_cells = int(knobs["n_cells"]);
    const int W = int(knobs["w"]);
    const int H = int(knobs["h"]);
    if (n_cells <= 0 || W <= 0 || H <= 0) return fail("invalid dims");
    const int n_px = W * H;

    PackedInt32Array px2cell = knobs["pixel_to_cell_idx"];
    PackedByteArray  dst_wind = knobs["dst_wind"];
    if (px2cell.size() != n_px) return fail("pixel_to_cell_idx size mismatch");
    if (dst_wind.size() != n_px * 2) return fail("dst_wind size mismatch");

    const int sid_wind_x = component_id(StringName("cell_wind_x"));
    const int sid_wind_y = component_id(StringName("cell_wind_y"));
    const int sid_wind_spd = component_id(StringName("cell_wind_speed"));
    if (sid_wind_x < 0 || sid_wind_y < 0 || sid_wind_spd < 0) return fail("missing slot id");
    Slot &s_wx = _slots.write[sid_wind_x];
    Slot &s_wy = _slots.write[sid_wind_y];
    Slot &s_wsp = _slots.write[sid_wind_spd];
    if (s_wx.arr_f32.size() != n_cells || s_wy.arr_f32.size() != n_cells ||
        s_wsp.arr_f32.size() != n_cells) {
        return fail("slot array size mismatch");
    }

    PackedFloat32Array visual_x = s_wx.arr_f32, visual_y = s_wy.arr_f32, visual_speed = s_wsp.arr_f32;
    if (knobs.has("physics_read_view")) {
        if (knobs["physics_read_view"].get_type() != Variant::DICTIONARY) return fail("physics_view_type");
        const Dictionary view = knobs["physics_read_view"];
        for (const char *key : {"wind_x", "wind_y", "wind_speed"}) {
            if (!view.has(key) || view[key].get_type() != Variant::PACKED_FLOAT32_ARRAY ||
                PackedFloat32Array(view[key]).size() != n_cells) return fail("physics_view_shape");
            const PackedFloat32Array lane = view[key];
            for (int i = 0; i < n_cells; ++i) if (!std::isfinite(lane[i])) return fail("physics_view_nonfinite");
        }
        visual_x = view["wind_x"]; visual_y = view["wind_y"]; visual_speed = view["wind_speed"];
    }
    const float   * const __restrict WX  = visual_x.ptr();
    const float   * const __restrict WY  = visual_y.ptr();
    const float   * const __restrict WSP = visual_speed.ptr();
    const int32_t * const __restrict P2C = px2cell.ptr();
    uint8_t       * const __restrict DW  = dst_wind.ptrw();

    // 可选 atlas_data 同步（与 GDScript _vector_atlas_data 共享，wind 写 [+2]/[+3]）
    bool atlas_ok = false;
    uint8_t *ATLAS = nullptr;
    PackedByteArray atlas_data;
    const bool update_atlas = bool(knobs.get("update_atlas_data", false));
    if (update_atlas && knobs.has("atlas_data")) {
        atlas_data = knobs["atlas_data"];
        if (atlas_data.size() == n_px * 4) {
            atlas_ok = true;
            ATLAS = atlas_data.ptrw();
        }
    }

    auto t0 = std::chrono::high_resolution_clock::now();
    int written = 0;

    // ─── Hot loop 优化（同 ocean rasterize：干掉 std::round + double 转换）。
    auto quantize_signed = [](float v) -> uint8_t {
        float q = v * 127.5f + 128.0f;
        if (q <= 0.0f) return 0;
        if (q >= 255.0f) return 255;
        return uint8_t(int(q));
    };

    if (atlas_ok) {
        for (int i = 0; i < n_px; ++i) {
            const int32_t ci = P2C[i];
            // 与 GDScript _rasterize_wind_slice_from_hex 一致：cell 缺失时默认 (1,0)
            float wx = 1.0f;
            float wy = 0.0f;
            if (uint32_t(ci) < uint32_t(n_cells)) {
                const float speed_norm = std::min(std::max(WSP[ci] / 1.7f, 0.0f), 1.0f);
                wx = WX[ci] * speed_norm;
                wy = WY[ci] * speed_norm;
            }
            const uint8_t bx = quantize_signed(wx);
            const uint8_t by = quantize_signed(wy);
            DW[i * 2]     = bx;
            DW[i * 2 + 1] = by;
            // ATLAS[i*4+0..+1] 由 ocean rasterize 写，wind 不动
            ATLAS[i * 4 + 2] = bx;
            ATLAS[i * 4 + 3] = by;
        }
    } else {
        for (int i = 0; i < n_px; ++i) {
            const int32_t ci = P2C[i];
            float wx = 1.0f;
            float wy = 0.0f;
            if (uint32_t(ci) < uint32_t(n_cells)) {
                const float speed_norm = std::min(std::max(WSP[ci] / 1.7f, 0.0f), 1.0f);
                wx = WX[ci] * speed_norm;
                wy = WY[ci] * speed_norm;
            }
            DW[i * 2]     = quantize_signed(wx);
            DW[i * 2 + 1] = quantize_signed(wy);
        }
    }
    written = n_px;

    knobs["dst_wind"] = dst_wind;
    if (atlas_ok) {
        knobs["atlas_data"] = atlas_data;
    }

    auto t1 = std::chrono::high_resolution_clock::now();
    out["elapsed_ms"] = std::chrono::duration<double, std::milli>(t1 - t0).count();
    out["fallback"] = false;
    out["reason"] = String();
    out["pixels"] = written;
    out["atlas_updated"] = atlas_ok;
    return out;
}

// DOTS-Total-CPP（A 方案 / phys nan_guard 孪生）：
// phys_field_nan_guard — 扫 6 个物理字段 SoA，统计 NaN/Inf 数。
// 替代 GDScript map_baker.gd::_physical_solve_step_one 第一帧的 22ms 检测循环。
//
// 实现要点：
//   - 直接走 BIND_TABLE Slot.arr_f32.ptr() 顺序扫，零 Variant 开销。
//   - 用位运算判 NaN/Inf：(bits & 0x7F800000) == 0x7F800000 即 IEEE-754
//     的"指数位全 1"，覆盖 +Inf/-Inf/NaN/sNaN 全部情况。比 std::isfinite
//     的两次比较 + branch 快 3x，且编译器会自动 SSE/AVX2 向量化。
//   - 6 个字段共 ~56KB，全部命中 L1。预计 << 0.1ms。
int DCWorldExt::phys_field_nan_guard() {
    if (!_bound) return -1;

    const int sid_wx    = component_id(godot::StringName("cell_wind_x"));
    const int sid_wy    = component_id(godot::StringName("cell_wind_y"));
    const int sid_wspd  = component_id(godot::StringName("cell_wind_speed"));
    const int sid_ocx   = component_id(godot::StringName("cell_ocean_current_x"));
    const int sid_ocy   = component_id(godot::StringName("cell_ocean_current_y"));
    const int sid_up    = component_id(godot::StringName("cell_upwelling_strength"));
    if (sid_wx < 0 || sid_wy < 0 || sid_wspd < 0 ||
        sid_ocx < 0 || sid_ocy < 0 || sid_up < 0) {
        return -1;
    }

    Slot &s_wx   = _slots.write[sid_wx];
    Slot &s_wy   = _slots.write[sid_wy];
    Slot &s_wspd = _slots.write[sid_wspd];
    Slot &s_ocx  = _slots.write[sid_ocx];
    Slot &s_ocy  = _slots.write[sid_ocy];
    Slot &s_up   = _slots.write[sid_up];

    const int n = s_wx.arr_f32.size();
    if (n == 0) return 0;
    if (s_wy.arr_f32.size()   != n || s_wspd.arr_f32.size() != n ||
        s_ocx.arr_f32.size()  != n || s_ocy.arr_f32.size()  != n ||
        s_up.arr_f32.size()   != n) {
        return -1;
    }

    const float *WX  = s_wx.arr_f32.ptr();
    const float *WY  = s_wy.arr_f32.ptr();
    const float *WS  = s_wspd.arr_f32.ptr();
    const float *OCX = s_ocx.arr_f32.ptr();
    const float *OCY = s_ocy.arr_f32.ptr();
    const float *UP  = s_up.arr_f32.ptr();

    // IEEE-754 binary32：指数位全 1 ⇔ NaN/Inf。
    // (bits & 0x7F800000) == 0x7F800000 等价 !std::isfinite(v)。
    auto bad = [](float v) -> uint32_t {
        uint32_t b;
        std::memcpy(&b, &v, sizeof(b));
        return ((b & 0x7F800000u) == 0x7F800000u) ? 1u : 0u;
    };

    int n_bad = 0;
    for (int i = 0; i < n; ++i) {
        // 任一字段 bad 即整 cell 算 bad（与 GDScript 行为一致：or 短路）。
        const uint32_t any_bad = bad(WX[i]) | bad(WY[i]) | bad(WS[i]) |
                                 bad(OCX[i]) | bad(OCY[i]) | bad(UP[i]);
        n_bad += int(any_bad);
    }
    return n_bad;
}

// ─────────────────────────────────────────────────────────────────────────
// run_physical_solve_pass — 物理环流编排下沉 C++（dots-total-cpp step3，生成期一次性路径）
// 在进程内按序串起 SLP → wind → PSI → upwelling 四个已验证 kernel（均读 bound slot +
// publish_to_slot），中间量经 slp_out / 读 wind slot 串联，不跨语言往返。
// ─────────────────────────────────────────────────────────────────────────
godot::Dictionary DCWorldExt::run_physical_solve_pass(godot::Dictionary knobs) {
    using godot::Dictionary;
    using godot::PackedFloat32Array;
    using godot::String;
    using godot::StringName;

    Dictionary out;
    out["fallback"] = true;
    out["reason"] = String();
    out["psi_ran"] = false;
    out["slp_ms"] = -1.0;
    out["wind_ms"] = -1.0;
    out["psi_ms"] = -1.0;
    out["upwelling_ms"] = -1.0;
    out["elapsed_ms"] = -1.0;

    auto fail = [&](const char *why) -> Dictionary {
        out["reason"] = String(why);
        return out;
    };

    if (!_bound) return fail("not _bound");
    const int n_cells = int(knobs.get("n_cells", 0));
    if (n_cells <= 0) return fail("n_cells <= 0");

    const bool heat_transport = bool(knobs.get("heat_transport", true));
    const bool solve_ocean = bool(knobs.get("solve_ocean", true));

    auto t0 = std::chrono::high_resolution_clock::now();

    // ── ① SLP（publish cell_slp slot；返回 slp_out 供 wind 串联）──
    Dictionary slp_ret = run_slp_field_pass(knobs);
    if (bool(slp_ret.get("fallback", true))) return fail("slp_fallback");
    PackedFloat32Array slp_out = slp_ret.get("slp_out", PackedFloat32Array());
    if (slp_out.size() != n_cells) return fail("slp_out size mismatch");
    out["slp_ms"] = slp_ret.get("elapsed_ms", -1.0);

    // ── ② wind（注入 slp_arr=slp_out；读 slp/terrain/landform/pos slot，写 wind slot）──
    knobs["slp_arr"] = slp_out;
    const double wind_ms = run_wind_field_pass(knobs);
    if (wind_ms < 0.0) return fail("wind_fallback");
    out["wind_ms"] = wind_ms;

    if (!solve_ocean) {
        // 与 GDScript step_one 一致：!solve_ocean 时风场算完即结束（无 PSI / upwelling）。
        out["fallback"] = false;
        out["reason"] = String();
        out["elapsed_ms"] = std::chrono::duration<double, std::milli>(
            std::chrono::high_resolution_clock::now() - t0).count();
        return out;
    }

    // ── ③ PSI（仅 heat_transport；从 wind slot 提取 wind_*_arr 注入 knobs）──
    if (heat_transport) {
        const int sid_wx  = component_id(StringName("cell_wind_x"));
        const int sid_wy  = component_id(StringName("cell_wind_y"));
        const int sid_wsp = component_id(StringName("cell_wind_speed"));
        if (sid_wx < 0 || sid_wy < 0 || sid_wsp < 0) return fail("wind slot id missing");
        Slot &s_wx  = _slots.write[sid_wx];
        Slot &s_wy  = _slots.write[sid_wy];
        Slot &s_wsp = _slots.write[sid_wsp];
        if (s_wx.arr_f32.size() != n_cells || s_wy.arr_f32.size() != n_cells
                || s_wsp.arr_f32.size() != n_cells) {
            return fail("wind slot size mismatch");
        }
        PackedFloat32Array wx;  wx.resize(n_cells);
        PackedFloat32Array wy;  wy.resize(n_cells);
        PackedFloat32Array wsp; wsp.resize(n_cells);
        {
            const float * const __restrict SWX = s_wx.arr_f32.ptr();
            const float * const __restrict SWY = s_wy.arr_f32.ptr();
            const float * const __restrict SWS = s_wsp.arr_f32.ptr();
            float * const __restrict DWX = wx.ptrw();
            float * const __restrict DWY = wy.ptrw();
            float * const __restrict DWS = wsp.ptrw();
            for (int i = 0; i < n_cells; ++i) { DWX[i] = SWX[i]; DWY[i] = SWY[i]; DWS[i] = SWS[i]; }
        }
        knobs["wind_x_arr"] = wx;
        knobs["wind_y_arr"] = wy;
        knobs["wind_speed_arr"] = wsp;
        Dictionary psi_ret = run_psi_solver_pass(knobs);
        if (bool(psi_ret.get("fallback", true))) return fail("psi_fallback");
        out["psi_ms"] = psi_ret.get("elapsed_ms", -1.0);
        out["psi_iters_run"] = psi_ret.get("psi_iters_run", -1);
        out["psi_residual_final"] = psi_ret.get("psi_residual_final", -1.0);
        out["psi_early_exit"] = psi_ret.get("psi_early_exit", false);
        out["psi_mode"] = psi_ret.get("psi_mode", String());
        out["psi_ran"] = true;
    } else {
        // !heat_transport：GDScript 走 solve_ocean_current_fallback（纯 GDScript，无 C++ 等价），
        // 故一次性路径无法完成 → 整体 fallback，交回 GDScript step_one loop 处理。
        return fail("no_heat_transport_needs_gdscript_ocean_fallback");
    }

    // ── ④ upwelling（读 wind slot；注入 stage=upwelling）──
    {
        Dictionary up_knobs = knobs;
        up_knobs["stage"] = String("upwelling");
        Dictionary up_ret = run_physical_circulation_pass(up_knobs);
        if (bool(up_ret.get("fallback", true))) return fail("upwelling_fallback");
        out["upwelling_ms"] = up_ret.get("elapsed_ms", -1.0);
    }

    out["fallback"] = false;
    out["reason"] = String();
    out["elapsed_ms"] = std::chrono::duration<double, std::milli>(
        std::chrono::high_resolution_clock::now() - t0).count();
    return out;
}

godot::Dictionary DCWorldExt::run_physical_circulation_pass(godot::Dictionary knobs) {
    using godot::Dictionary;
    using godot::PackedByteArray;
    using godot::PackedInt32Array;
    using godot::String;
    using godot::StringName;

    Dictionary out;
    out["stage"] = knobs.get("stage", String("upwelling"));
    out["elapsed_ms"] = -1.0;
    out["fallback"] = true;
    out["reason"] = String();

    auto fail = [&](const char *why) -> Dictionary {
        out["reason"] = String(why);
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_physical_circulation_pass: ", why,
            " - fallback to GDScript");
        return out;
    };

    if (!_bound) return fail("not bound");
    const String stage = String(knobs.get("stage", String("upwelling")));
    if (stage != String("upwelling")) return fail("unsupported stage");
    if (!knobs.has("n_cells") || !knobs.has("neighbor_indices") ||
        !knobs.has("water_terrain_ids") ||
        !knobs.has("world_bounds_pos_y") || !knobs.has("world_bounds_size_y")) {
        return fail("missing required knob");
    }

    const int n_cells = int(knobs["n_cells"]);
    const double bounds_pos_y = double(knobs["world_bounds_pos_y"]);
    const double bounds_size_y = double(knobs["world_bounds_size_y"]);
    const double cold_sink_temp = double(knobs.get("cold_sink_temp", -0.05));
    if (n_cells <= 0) return fail("n_cells <= 0");
    if (bounds_size_y <= 0.001) return fail("world_bounds_size_y <= 0.001");

    PackedInt32Array nb_arr = knobs["neighbor_indices"];
    PackedByteArray water_ids = knobs["water_terrain_ids"];
    if (nb_arr.size() < n_cells * 6) return fail("neighbor_indices size < n_cells * 6");
    if (water_ids.size() <= 0) return fail("water_terrain_ids empty");

    _phys_resolve_static(n_cells, water_ids);
    const int sid_pos_y = _phys_sid_pos_y;
    const int sid_terrain = _phys_sid_terrain;
    const int sid_wind_x = _phys_sid_wind_x;
    const int sid_wind_y = _phys_sid_wind_y;
    const int sid_wind_speed = _phys_sid_wind_spd;
    const int sid_upwelling = _phys_sid_upwelling;
    if (sid_pos_y < 0 || sid_terrain < 0 || sid_wind_x < 0 || sid_wind_y < 0 ||
        sid_wind_speed < 0 || sid_upwelling < 0) {
        return fail("missing slot id (pos_y/terrain/wind/upwelling)");
    }

    Slot &s_pos_y = _slots.write[sid_pos_y];
    Slot &s_terrain = _slots.write[sid_terrain];
    Slot &s_wind_x = _slots.write[sid_wind_x];
    Slot &s_wind_y = _slots.write[sid_wind_y];
    Slot &s_wind_speed = _slots.write[sid_wind_speed];
    Slot &s_upwelling = _slots.write[sid_upwelling];
    if (s_pos_y.arr_f32.size() != n_cells ||
        s_terrain.arr_u8.size() != n_cells ||
        s_wind_x.arr_f32.size() != n_cells ||
        s_wind_y.arr_f32.size() != n_cells ||
        s_wind_speed.arr_f32.size() != n_cells ||
        s_upwelling.arr_f32.size() != n_cells) {
        return fail("slot array size mismatch");
    }

    const bool *is_water_lut = _phys_is_water_lut;

    // Item 2: cell-range 切片（默认全量，逐位等价；GDScript 游标驱动时传 start_idx/end_idx）。
    int start_idx = knobs.has("start_idx") ? int(knobs["start_idx"]) : 0;
    int end_idx   = knobs.has("end_idx")   ? int(knobs["end_idx"])   : n_cells;
    if (start_idx < 0)       start_idx = 0;
    if (end_idx > n_cells)   end_idx = n_cells;
    if (start_idx > end_idx) start_idx = end_idx;
    const int slice_n = end_idx - start_idx;

    const float * const __restrict POSY = s_pos_y.arr_f32.ptr();
    const uint8_t * const __restrict TERR = s_terrain.arr_u8.ptr();
    const float * const __restrict WX = s_wind_x.arr_f32.ptr();
    const float * const __restrict WY = s_wind_y.arr_f32.ptr();
    const float * const __restrict WSPD = s_wind_speed.arr_f32.ptr();
    float * const __restrict UP = s_upwelling.arr_f32.ptrw();
    const int32_t * const __restrict NB = nb_arr.ptr();

    auto t0 = std::chrono::high_resolution_clock::now();

    const PhysLatNorm LATN = phys_make_lat_norm(_phys_lat_norm_ptr(n_cells), POSY, n_cells);
    (void)bounds_pos_y;
    (void)bounds_size_y;

    // perf (2A): upwelling 逐 cell 独立（只读 POSY/TERR/WX/WY/WSPD/NB + 常量方向表，
    // 写 UP[i]，无标量累加器）→ 按 cell 区间并行、bit-equal、无需 reduce。
    // B8 P2：循环体已抽到 pk_async_physics::upwelling_range（worker 走同一份）。
    pk_async_physics::UpwellingKnobs up_k;
    up_k.ekman_gain = float(knobs.get("upwelling_ekman_gain", up_k.ekman_gain));
    up_k.cold_sink_gain = float(knobs.get("upwelling_cold_sink_gain", up_k.cold_sink_gain));
    up_k.highlat_abs = float(knobs.get("upwelling_highlat_abs", up_k.highlat_abs));
    up_k.cold_sink_temp = float(cold_sink_temp);
    pk_async_physics::UpwellingLanes up_l;
    up_l.lat_norm = LATN.lat;
    up_l.pos_y = LATN.posy;
    up_l.lat_origin = LATN.origin;
    up_l.lat_inv_span = LATN.inv_span;
    up_l.terrain = TERR;
    up_l.neighbors = NB;
    up_l.is_water_lut = is_water_lut;
    up_l.wind_x = WX;
    up_l.wind_y = WY;
    up_l.wind_speed = WSPD;
    up_l.upwelling = UP;
    auto upwelling_range = [&](int rb, int re) {
        pk_async_physics::upwelling_range(
            n_cells, start_idx + rb, start_idx + re, up_k, up_l);
    };
    pk::parallel_for_range("pk_ocean_upwelling", slice_n, upwelling_range);

    _flush_slot_to_map(sid_upwelling);

    auto t1 = std::chrono::high_resolution_clock::now();
    out["elapsed_ms"] = std::chrono::duration<double, std::milli>(t1 - t0).count();
    out["fallback"] = false;
    out["reason"] = String();
    return out;
}

// ═══════════════════════════════════════════════════════════════════════════
// plan/dots-slp-psi-cpp — SLP field solver (stage 1)
// ═══════════════════════════════════════════════════════════════════════════
//
// PhysicalCirculationSolver.solve_slp_field native authority:
//   Pass A writes the per-cell SLP target from:
//     - three-cell latitude pressure belts,
//     - current solar-insolation anomaly from orbital phase + axial tilt,
//     - land/sea thermal inertia and continentality,
//     - optional temp anomaly, ice/snow highs, moist/cloud lows, synoptic waves.
//   `season_phase` is only the year/orbital phase used to compute solar
//   declination/insolation; it is not used as an independent season sign.
//   Pass B applies smooth_passes rounds of 6-neighbor Jacobi smoothing.

// ─── perf 2026-07-08, Item 1：phys pass 每调用固定开销缓存 ───────────
// 解析四个 phys pass 共用的 cell_* slot id + 重建 is_water_lut，按
// FNV-1a(n_cells, water_terrain_ids) 指纹失效（地图 regen / 水掩膜变化即重建，
// 不挂 _bound 钩子，仿 PSI 拓扑缓存 line 2228）。命中后各 pass 直接读成员，
// 省掉重复 component_id(StringName) 与 256 字节 LUT 重建。邻居索引仍由 knob
// 传入（保留 fallback）。slot 缺失时 _phys_sid_* 为 -1，pass 内 sid<0 守卫仍触发。
const float *DCWorldExt::_phys_lat_norm_ptr(int n_cells) {
    if (_phys_sid_lat_norm < 0 || _phys_sid_lat_norm >= _slots.size()) return nullptr;
    Slot &s = _slots.write[_phys_sid_lat_norm];
    if (s.arr_f32.size() != n_cells) return nullptr;
    return s.arr_f32.ptr();
}

void DCWorldExt::_phys_resolve_static(int n_cells, const godot::PackedByteArray &water_ids) {
    uint64_t fp = 1469598103934665603ull; // FNV-1a offset basis
    auto mix = [&fp](uint32_t bits) {
        fp ^= uint64_t(bits);
        fp *= 1099511628211ull; // FNV-1a prime
    };
    mix(uint32_t(n_cells));
    for (int k = 0; k < water_ids.size(); ++k) {
        mix(uint32_t(int(water_ids[k])));
    }
    if (_phys_static_valid && _phys_static_fp == fp) return;

    _phys_sid_pos_x     = component_id(StringName("cell_pos_x"));
    _phys_sid_pos_y     = component_id(StringName("cell_pos_y"));
    _phys_sid_lat_norm  = component_id(StringName("cell_lat_norm"));
    _phys_sid_terrain   = component_id(StringName("cell_terrain"));
    _phys_sid_landform  = component_id(StringName("cell_landform"));
    _phys_sid_wind_x    = component_id(StringName("cell_wind_x"));
    _phys_sid_wind_y    = component_id(StringName("cell_wind_y"));
    _phys_sid_wind_spd  = component_id(StringName("cell_wind_speed"));
    _phys_sid_slp       = component_id(StringName("cell_slp"));
    _phys_sid_temp      = component_id(StringName("cell_temp"));
    _phys_sid_temp_an   = component_id(StringName("cell_temp_anomaly"));
    _phys_sid_snow      = component_id(StringName("cell_snow_cover"));
    _phys_sid_ice       = component_id(StringName("cell_sea_ice_frac"));
    _phys_sid_wvap      = component_id(StringName("cell_weather_vapor"));
    _phys_sid_wcld      = component_id(StringName("cell_weather_cloud"));
    _phys_sid_ocx       = component_id(StringName("cell_ocean_current_x"));
    _phys_sid_ocy       = component_id(StringName("cell_ocean_current_y"));
    _phys_sid_psi_prev  = component_id(StringName("cell_ocean_psi"));
    _phys_sid_upwelling = component_id(StringName("cell_upwelling_strength"));
    _phys_sid_elev      = component_id(StringName("cell_elevation"));

    for (int i = 0; i < 256; ++i) _phys_is_water_lut[i] = false;
    for (int k = 0; k < water_ids.size(); ++k) {
        const int wid = int(water_ids[k]);
        if (wid >= 0 && wid < 256) _phys_is_water_lut[wid] = true;
    }

    _phys_static_fp = fp;
    _phys_static_valid = true;
}

// ─── perf 2026-07-08, Item 2：WIND coast/sea BFS 缓存 ──────────────────
// run_wind_field_pass 每调用重建 coast_dist/sea_dist 全图 vector（Pass 0 + 0b），是全局
// 状态、与 cell 内容无关、对静态地图逐调用恒等。缓存进成员，指纹 = FNV(TR 字节 +
// water_ids + NB 整型) —— 地图 regen / 地形 flip 即失配自动重建（≈地图期一次）。
// 命中即 coast_dist/sea_dist 等逐位复用 → bit-equal；主线程同步调用，成员存储线程安全。
// 注：NB_DIR_X/Y、WIND_COAST_THERMAL_MAX_DIST、SEA_BREEZE_SEA_MAX_DIST 为本 TU 常量。
void DCWorldExt::_phys_ensure_wind_coast(int n_cells, const uint8_t *TR, const int32_t *NB,
                                         const bool *is_water_lut, const godot::PackedByteArray &water_ids) {
    const auto build_t0 = std::chrono::high_resolution_clock::now();
    uint64_t fp = 1469598103934665603ull; // FNV-1a offset basis
    auto mix = [&fp](uint32_t bits) {
        fp ^= uint64_t(bits);
        fp *= 1099511628211ull; // FNV-1a prime
    };
    mix(uint32_t(n_cells));
    for (int i = 0; i < n_cells; ++i) mix(uint32_t(TR[i]));
    mix(uint32_t(water_ids.size()));
    for (int k = 0; k < water_ids.size(); ++k) mix(uint32_t(int(water_ids[k])));
    for (int i = 0; i < n_cells * 6; ++i) mix(uint32_t(NB[i]));
    if (_phys_wind_coast_valid && _phys_wind_coast_fp == fp) {
        _phys_wind_coast_last_hit = true;
        return;
    }
    _phys_wind_coast_last_hit = false;

    // B8 P2：两次 BFS 已抽到 pk_async_physics::wind_coast_build_pure（worker 走同一份）。
    // 生产仍持有缓存与指纹外壳 —— 命中即整段跳过。
    _phys_wind_coast_dist.assign(static_cast<size_t>(n_cells), COAST_INF);
    _phys_wind_coast_sea_x.assign(static_cast<size_t>(n_cells), 0.0f);
    _phys_wind_coast_sea_y.assign(static_cast<size_t>(n_cells), 0.0f);
    _phys_wind_coast_sea_anchor.assign(static_cast<size_t>(n_cells), -1);
    _phys_wind_sea_dist.assign(static_cast<size_t>(n_cells), COAST_INF);
    _phys_wind_sea_land_x.assign(static_cast<size_t>(n_cells), 0.0f);
    _phys_wind_sea_land_y.assign(static_cast<size_t>(n_cells), 0.0f);
    _phys_wind_sea_land_anchor.assign(static_cast<size_t>(n_cells), -1);
    std::vector<int32_t> bfs_scratch(static_cast<size_t>(n_cells) * 2u, 0);
    pk_async_physics::WindCoastKnobs coast_k;
    coast_k.coast_max_dist = WIND_COAST_THERMAL_MAX_DIST;
    coast_k.sea_max_dist = SEA_BREEZE_SEA_MAX_DIST;
    pk_async_physics::WindCoastLanes coast_l;
    coast_l.terrain = TR;
    coast_l.neighbors = NB;
    coast_l.is_water_lut = is_water_lut;
    coast_l.coast_dist = _phys_wind_coast_dist.data();
    coast_l.coast_sea_x = _phys_wind_coast_sea_x.data();
    coast_l.coast_sea_y = _phys_wind_coast_sea_y.data();
    coast_l.coast_sea_anchor = _phys_wind_coast_sea_anchor.data();
    coast_l.sea_dist = _phys_wind_sea_dist.data();
    coast_l.sea_land_x = _phys_wind_sea_land_x.data();
    coast_l.sea_land_y = _phys_wind_sea_land_y.data();
    coast_l.sea_land_anchor = _phys_wind_sea_land_anchor.data();
    coast_l.scratch_queue = bfs_scratch.data();
    pk_async_physics::wind_coast_build_pure(n_cells, coast_k, coast_l);

    _phys_wind_coast_fp = fp;
    _phys_wind_coast_valid = true;
    const auto build_t1 = std::chrono::high_resolution_clock::now();
    _phys_wind_coast_build_ms =
        std::chrono::duration<double, std::milli>(build_t1 - build_t0).count();
}

// ─── NS 化 Phase 0：风场回溯轨迹表构建 ─────────────────────────────────
// 每 cell 沿 -通量 回溯 dist = |flux|·traj_pos_scale·s·traj_dt_days（s=√(N/15000)
// 格距归一：世界是固定大小行星，格距∝1/√N，同一物理距离在高分辨率图上跨更多格），
// 上限 12 pos 单位（≈7 格）防御异常风速。回溯终点用直线近似（低速大 dt 下与
// RK2 差异 < 亚格级），随后按最对齐邻居逐格 walk（≤12 跳）推进宿主 cell，
// 保证宿主与终点一致，再交 pk_hex_sextant_barycentric 求三点权重。
// 只读 wind slots（已写完，稳定）、写 own-row → parallel_for_range bit-equal。
void DCWorldExt::_phys_build_wind_traj(int n_cells, const float *POSX, const float *POSY,
                                       const int32_t *NB, const float *WX, const float *WY,
                                       const float *WSP, double wrap_period_x,
                                       double traj_pos_scale, double traj_dt_days) {
    if (int(_phys_wind_traj_idx.size()) != n_cells * 3) {
        _phys_wind_traj_idx.assign(static_cast<size_t>(n_cells) * 3, 0);
        _phys_wind_traj_w.assign(static_cast<size_t>(n_cells) * 3, 0.0f);
    }
    const double grid_s = std::sqrt(double(n_cells) / 15000.0);
    // B8 P2：回溯轨迹构建已抽到 pk_async_physics::wind_traj_build_range。
    pk_async_physics::WindTrajKnobs traj_k;
    traj_k.wrap_period_x = wrap_period_x;
    traj_k.traj_pos_scale = traj_pos_scale;
    traj_k.traj_dt_days = traj_dt_days;
    pk_async_physics::WindTrajLanes traj_l;
    traj_l.pos_x = POSX;
    traj_l.pos_y = POSY;
    traj_l.neighbors = NB;
    traj_l.wind_x = WX;
    traj_l.wind_y = WY;
    traj_l.wind_speed = WSP;
    traj_l.traj_idx = _phys_wind_traj_idx.data();
    traj_l.traj_w = _phys_wind_traj_w.data();
    pk::parallel_for_range("pk_wind_traj", n_cells, [&](int rb, int re) {
        pk_async_physics::wind_traj_build_range(n_cells, rb, re, traj_k, traj_l);
    });
    _phys_wind_traj_fp = pk_wind_state_fp(n_cells, WX, WY, WSP);
    ++_phys_wind_traj_gen;
    _phys_wind_traj_valid = true;
}

godot::Dictionary DCWorldExt::run_slp_field_pass(godot::Dictionary knobs) {
    using godot::Dictionary;
    using godot::PackedByteArray;
    using godot::PackedFloat32Array;
    using godot::PackedInt32Array;
    using godot::String;
    using godot::StringName;

    Dictionary out;
    out["elapsed_ms"] = -1.0;
    out["fallback"] = true;
    out["reason"] = String();
    out["published_to_slot"] = false;
    out["slice_start"] = -1;
    out["slice_end"] = -1;
    out["slice_final"] = false;
    out["slot_id"] = -1;
    out["slot_size"] = 0;
    out["slot_publish_reason"] = String("not_evaluated");

    auto fail = [&](const char *why) -> Dictionary {
        out["reason"] = String(why);
        out["slot_publish_reason"] = String("pass_fallback");
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_slp_field_pass: ", why,
            " — fallback to GDScript");
        return out;
    };

    if (!_bound) return fail("not _bound");

    static const char *required_keys[] = {
        "n_cells", "hex_size", "season_phase", "smooth_passes",
        "world_bounds_pos_y", "world_bounds_size_y",
        "neighbor_indices", "water_terrain_ids",
        nullptr,
    };
    for (int k = 0; required_keys[k] != nullptr; ++k) {
        if (!knobs.has(required_keys[k])) {
            String s = String("missing knob '") + String(required_keys[k]) + String("'");
            return fail(s.utf8().get_data());
        }
    }

    const int    n_cells       = int(knobs["n_cells"]);
    const double season_phase  = double(knobs["season_phase"]);
    const int    smooth_passes = int(knobs["smooth_passes"]);
    const double bounds_pos_y  = double(knobs["world_bounds_pos_y"]);
    const double bounds_size_y = double(knobs["world_bounds_size_y"]);
    if (n_cells <= 0)            return fail("n_cells <= 0");
    if (bounds_size_y <= 0.001)  return fail("world_bounds_size_y <= 0.001");

    // Tunables (defaults match GDScript constants; allow override via knobs).
    const float A_LAT          = float(knobs.has("slp_lat_amp")        ? double(knobs["slp_lat_amp"])        : 0.16);
    const float A_LAND         = float(knobs.has("slp_land_amp")       ? double(knobs["slp_land_amp"])       : 0.55);
    const float WATER_DAMP     = float(knobs.has("slp_water_damp")     ? double(knobs["slp_water_damp"])     : 0.20);
    const float INTERIOR_BOOST = float(knobs.has("slp_interior_boost") ? double(knobs["slp_interior_boost"]) : 1.30);
    const float COAST_DAMP     = float(knobs.has("slp_coast_damp")     ? double(knobs["slp_coast_damp"])     : 0.60);
    const float THERMAL_WEIGHT = float(knobs.has("wind_thermal_slp_weight") ? double(knobs["wind_thermal_slp_weight"]) : 0.0);
    const float ICE_HIGH_WEIGHT = float(knobs.has("slp_ice_high_weight") ? double(knobs["slp_ice_high_weight"]) : 0.0);
    const float SNOW_HIGH_WEIGHT = float(knobs.has("slp_snow_high_weight") ? double(knobs["slp_snow_high_weight"]) : 0.0);
    float slp_response_rate = float(knobs.has("slp_response_rate") ? double(knobs["slp_response_rate"]) : 0.55);
    if (slp_response_rate < 0.0f) slp_response_rate = 0.0f;
    else if (slp_response_rate > 1.0f) slp_response_rate = 1.0f;
    const float SLP_SYNOPTIC_AMP = float(knobs.has("slp_synoptic_amp") ? double(knobs["slp_synoptic_amp"]) : 0.075);
    // 让天气流动(2026-06-21 阶段1)：移动低压系统 knobs（hot loop 外解析）。count=0 或 amp=0 关闭。
    int mobile_low_count = knobs.has("slp_mobile_low_count") ? int(knobs["slp_mobile_low_count"]) : 0;
    if (mobile_low_count < 0) mobile_low_count = 0;
    else if (mobile_low_count > 8) mobile_low_count = 8;
    float mobile_low_amp = float(knobs.has("slp_mobile_low_amp") ? double(knobs["slp_mobile_low_amp"]) : 0.0);
    if (mobile_low_amp < 0.0f) mobile_low_amp = 0.0f;
    float mobile_low_sigma = float(knobs.has("slp_mobile_low_sigma") ? double(knobs["slp_mobile_low_sigma"]) : 0.16);
    if (mobile_low_sigma < 0.02f) mobile_low_sigma = 0.02f;
    double mobile_low_period = knobs.has("slp_mobile_low_period_days") ? double(knobs["slp_mobile_low_period_days"]) : 38.0;
    if (mobile_low_period < 1.0) mobile_low_period = 1.0;
    const float MOIST_LOW_WEIGHT = float(knobs.has("slp_moist_low_weight") ? double(knobs["slp_moist_low_weight"]) : 0.12);
    const bool SLP_RECENTER = bool(knobs.has("slp_recenter") ? bool(knobs["slp_recenter"]) : true);
    const float SLP_TARGET_P95 = float(knobs.has("slp_target_p95") ? double(knobs["slp_target_p95"]) : 0.18);
    int days_per_year = int(knobs.has("days_per_year") ? int(knobs["days_per_year"]) : 365);
    if (days_per_year < 1) days_per_year = 1;
    else if (days_per_year > 3660) days_per_year = 3660;
    double year_phase = std::fmod(season_phase, 4.0);
    if (year_phase < 0.0) year_phase += 4.0;
    const int sim_day = int(knobs.has("sim_day") ? int(knobs["sim_day"]) : int(std::floor((year_phase / 4.0) * double(days_per_year))));
    const int world_seed = int(knobs.has("world_seed") ? int(knobs["world_seed"]) : 0);
    const double wrap_origin_x = double(knobs.has("wrap_origin_x") ? double(knobs["wrap_origin_x"]) : 0.0);
    const double wrap_period_x = double(knobs.has("wrap_period_x") ? double(knobs["wrap_period_x"]) : 0.0);
    // 天气尺度修复(2026-06-19)：SLP synoptic 时间项原先 sim_day*0.071(≈88 天/周期)，在日/月尺度上
    // 准静止。改用 synoptic 角速率 2π/period(~6 天/周期)，让压力距平逐日漂移，与风场 synoptic 协同
    // 推动天气系统移动。共用 wind_synoptic_period_days knob。在循环外提升为常量。镜像见 run_wind_field_pass。
    double slp_synoptic_period_days = double(knobs.has("wind_synoptic_period_days") ? double(knobs["wind_synoptic_period_days"]) : 6.0);
    if (slp_synoptic_period_days < 0.5) slp_synoptic_period_days = 0.5;

    PackedInt32Array nb_arr   = knobs["neighbor_indices"];
    PackedByteArray  water_ids = knobs["water_terrain_ids"];
    PackedFloat32Array prev_slp_arr;
    if (knobs.has("prev_slp_arr")) {
        prev_slp_arr = knobs["prev_slp_arr"];
    }
    if (nb_arr.size()  < n_cells * 6) return fail("neighbor_indices size < n_cells * 6");
    if (water_ids.size() <= 0)         return fail("water_terrain_ids empty");
    if (prev_slp_arr.size() != 0 && prev_slp_arr.size() != n_cells) {
        return fail("prev_slp_arr size mismatch");
    }

    // Slot resolution (cached via _phys_resolve_static; FNV 指纹失效，地图 regen 自动重建)。
    _phys_resolve_static(n_cells, water_ids);
    const int sid_pos_y   = _phys_sid_pos_y;
    const int sid_pos_x   = _phys_sid_pos_x;  // 让天气流动: SLP synoptic 二维空间波(optional)
    const int sid_terrain = _phys_sid_terrain;
    const int sid_temp_an = _phys_sid_temp_an;
    const int sid_snow    = _phys_sid_snow;
    const int sid_ice     = _phys_sid_ice;
    const int sid_w_vapor = _phys_sid_wvap;
    const int sid_w_cloud = _phys_sid_wcld;
    if (sid_pos_y < 0 || sid_terrain < 0) {
        return fail("missing slot id (cell_pos_y/cell_terrain)");
    }
    Slot &s_pos_y   = _slots.write[sid_pos_y];
    Slot &s_terrain = _slots.write[sid_terrain];
    if (s_pos_y.arr_f32.size()  != n_cells ||
        s_terrain.arr_u8.size() != n_cells) {
        return fail("slot array size mismatch (re-bind needed?)");
    }

    // is_water LUT (cached via _phys_resolve_static, 同指纹随 slot 一起重建)。
    const bool *is_water_lut = _phys_is_water_lut;

    // perf (Item 2a, 2026-07-07): cell-range 切片旋钮。默认 start_idx=0 / end_idx=n_cells
    // → 单次全量 pass（与历史逐位等价，向后兼容）。GDScript 游标可传子区间把 Pass A 拆成
    // 多次调用；Pass B/norm/融合/发布只在末切片 end_idx==n_cells 跑，跨切片靠 _phys_slp_buf
    // 累积 Pass A 结果。切片外不触碰 slot，避免部分数据污染 cell_slp。
    int start_idx = knobs.has("start_idx") ? int(knobs["start_idx"]) : 0;
    int end_idx   = knobs.has("end_idx")   ? int(knobs["end_idx"])   : n_cells;
    if (start_idx < 0)            start_idx = 0;
    if (end_idx > n_cells)        end_idx   = n_cells;
    if (start_idx > end_idx)      start_idx = end_idx;
    const int slice_n = end_idx - start_idx;
    const bool slice_final = end_idx == n_cells;
    const int sid_slp = component_id(StringName("cell_slp"));
    const int slp_slot_size = sid_slp >= 0 ? _slots.write[sid_slp].arr_f32.size() : 0;
    out["slice_start"] = start_idx;
    out["slice_end"] = end_idx;
    out["slice_final"] = slice_final;
    out["slot_id"] = sid_slp;
    out["slot_size"] = slp_slot_size;
    out["slot_publish_reason"] = slice_final
        ? (sid_slp < 0 ? String("slot_missing")
                       : (slp_slot_size != n_cells ? String("slot_size_mismatch")
                                                   : String("slot_ready")))
        : String("intermediate_slice");

    const float   * const __restrict POSY = s_pos_y.arr_f32.ptr();
    const uint8_t * const __restrict TR   = s_terrain.arr_u8.ptr();
    const int32_t * const __restrict NB   = nb_arr.ptr();
    const float *POSX = nullptr;  // 让天气流动: SLP synoptic 改地理坐标二维波(无则退回 i 索引)
    if (sid_pos_x >= 0 && _slots.write[sid_pos_x].arr_f32.size() == n_cells) {
        POSX = _slots.write[sid_pos_x].arr_f32.ptr();
    }
    const float *TEMP_AN = nullptr;
    const float *SNOW = nullptr;
    const float *ICE = nullptr;
    const float *WVAP = nullptr;
    const float *WCLD = nullptr;
    const float *PREV_SLP = (prev_slp_arr.size() == n_cells) ? prev_slp_arr.ptr() : nullptr;
    if (sid_temp_an >= 0 && _slots.write[sid_temp_an].arr_f32.size() == n_cells) {
        TEMP_AN = _slots.write[sid_temp_an].arr_f32.ptr();
    }
    if (sid_snow >= 0 && _slots.write[sid_snow].arr_f32.size() == n_cells) {
        SNOW = _slots.write[sid_snow].arr_f32.ptr();
    }
    if (sid_ice >= 0 && _slots.write[sid_ice].arr_f32.size() == n_cells) {
        ICE = _slots.write[sid_ice].arr_f32.ptr();
    }
    if (sid_w_vapor >= 0 && _slots.write[sid_w_vapor].arr_f32.size() == n_cells) {
        WVAP = _slots.write[sid_w_vapor].arr_f32.ptr();
    }
    if (sid_w_cloud >= 0 && _slots.write[sid_w_cloud].arr_f32.size() == n_cells) {
        WCLD = _slots.write[sid_w_cloud].arr_f32.ptr();
    }

    auto t0 = std::chrono::high_resolution_clock::now();

    const float axial_tilt_deg = float(knobs.has("axial_tilt_deg") ? double(knobs["axial_tilt_deg"]) : 23.5);
    const float daylen_amp = float(knobs.has("insolation_daylen_amp") ? double(knobs["insolation_daylen_amp"]) : 0.35);

    // Output buffer (n_cells floats); will become slp_out PackedFloat32Array.
    // perf (Item 2a, 2026-07-07): slp_buf 改为 _phys_slp_buf 引用——持久、跨切片累积 Pass A。
    // Pass A 对每 cell 用 '=' 全量覆写，切片区间外无依赖，故无需清零；仅 size 失配时 resize。
    if (_phys_slp_buf.size() != static_cast<size_t>(n_cells)) {
        _phys_slp_buf.assign(static_cast<size_t>(n_cells), 0.0f);
    }
    std::vector<float> &slp_buf = _phys_slp_buf;
    std::vector<float> slp_delta(static_cast<size_t>(n_cells), 0.0f);
    // perf (Item 2a): thermal_abs 同样持久化（仅在权重非 0 时保留 size，否则 clear），
    // 使末切片 slp_thermal_p95 基于完整场（各切片 Pass A 均已写入其区间）。
    std::vector<float> &thermal_abs = _phys_slp_thermal_abs;
    if (A_LAND != 0.0f || THERMAL_WEIGHT != 0.0f || ICE_HIGH_WEIGHT != 0.0f || SNOW_HIGH_WEIGHT != 0.0f) {
        if (thermal_abs.size() != static_cast<size_t>(n_cells)) {
            thermal_abs.assign(static_cast<size_t>(n_cells), 0.0f);
        }
    } else {
        thermal_abs.clear();
    }

    // ─── Latitude LUT (plan/slp-lat-lut, 2026-06-17) ──────────────────────
    // base_lat 与 solar_heat 只依赖纬度 ny（固定 season/axial_tilt 的一次 pass 内）。
    // 旧实现每 cell 重算 base_lat(cos) + s_lat(sin) + dc_insolation_now(~9 trig) +
    // dc_insolation_annual_mean(16×9=144 trig) ≈ 155 次超越函数；6400 cell ≈ 100 万次。
    // 这里改成：pass 内按 ny 预建 B 档 LUT（B×155 次），cell 循环只做一次线性插值。
    // dc_insolation_annual_mean 是年均、与 season 无关，本就对所有同纬度 cell 恒等，
    // 预建后冗余完全消除。B 默认 1024（≈0.18° 纬度分辨率，足以分辨极昼/极夜 acos 拐点）。
    int slp_lat_lut_bins = int(knobs.has("slp_lat_lut_bins") ? int(knobs["slp_lat_lut_bins"]) : 1024);
    if (slp_lat_lut_bins < 16) slp_lat_lut_bins = 16;
    else if (slp_lat_lut_bins > 8192) slp_lat_lut_bins = 8192;
    const int LUT_BINS = slp_lat_lut_bins;
    std::vector<float> lut_base_lat(static_cast<size_t>(LUT_BINS), 0.0f);
    std::vector<float> lut_solar_heat(static_cast<size_t>(LUT_BINS), 0.0f);
    // perf (Item 5b, 2026-07-05): dc_insolation_annual_mean(ny_b, axial_tilt, daylen)
    // 是本 LUT 里唯一 season-无关的项（16×9 trig/bin），每 pass 重算纯冗余。缓存该年均
    // 子 LUT，指纹 = FNV-1a(LUT_BINS, axial_tilt bits, daylen bits)。命中即逐位复用
    // → bit-equal（insol_now/solar_dev/base_lat 仍每 pass 重建，因 season_phase 变化）。
    {
        uint64_t fp = 1469598103934665603ull; // FNV-1a offset basis
        auto mix = [&fp](uint32_t bits) {
            fp ^= uint64_t(bits);
            fp *= 1099511628211ull; // FNV-1a prime
        };
        mix(uint32_t(LUT_BINS));
        {
            uint32_t b;
            std::memcpy(&b, &axial_tilt_deg, sizeof(b));
            mix(b);
            std::memcpy(&b, &daylen_amp, sizeof(b));
            mix(b);
        }
        if (!(_slp_insol_mean_lut_valid && _slp_insol_mean_lut_fp == fp &&
              int(_slp_insol_mean_lut.size()) == LUT_BINS)) {
            _slp_insol_mean_lut.resize(static_cast<size_t>(LUT_BINS));
            for (int b = 0; b < LUT_BINS; ++b) {
                const float ny_b = float(b) / float(LUT_BINS - 1);
                _slp_insol_mean_lut[static_cast<size_t>(b)] =
                    dc_insolation_annual_mean(ny_b, axial_tilt_deg, daylen_amp);
            }
            _slp_insol_mean_lut_fp = fp;
            _slp_insol_mean_lut_valid = true;
        }
    }
    // 年均缓存仍由主线程持有；逐轮 LUT 与空间强迫统一由 prepare_slp_forcing 生成。

    // 让天气流动(2026-06-21)：SLP synoptic 由 cell 索引 i 改地理坐标 (px,py) 二维低频空间波。
    // 原 sin(i*4.886) 在索引空间周期≈1.3 格 → 高频碎压差 → 6 邻域 ∇ 放大成碎风向 → 平流相互
    // 抵消而非整团输送(用户反馈"风场太细")。改大尺度 (px,py) 波 → 平滑压差 → 风带成片、整团
    // 输送云系。bounds_x 自 POSX 求取(沿用 wind synoptic 同款归一化)。
    double slp_bounds_pos_x = 0.0, slp_inv_bounds_w = 1.0;
    if (POSX != nullptr && n_cells > 0) {
        double bx_min = double(POSX[0]); double bx_max = bx_min;
        for (int i = 1; i < n_cells; ++i) {
            const double v = double(POSX[i]);
            if (v < bx_min) bx_min = v;
            if (v > bx_max) bx_max = v;
        }
        slp_bounds_pos_x = bx_min;
        slp_inv_bounds_w = 1.0 / std::max(0.001, bx_max - bx_min);
        static bool s_warned_slp_wrap = false;
        physical_warn_wrap_units("slp_field", wrap_period_x, bx_max - bx_min, s_warned_slp_wrap);
    }
    const bool slp_has_wrap_domain = wrap_period_x > 0.001;
    // 纬度权威：cell_lat_norm slot（见 phys_make_lat_norm）。world_bounds_* 不再参与纬度归一化。
    const PhysLatNorm LATN = phys_make_lat_norm(_phys_lat_norm_ptr(n_cells), POSY, n_cells);
    (void)bounds_pos_y;
    (void)bounds_size_y;

    // 让天气流动(2026-06-21 阶段1)：移动低压中心（循环外预计算；hot loop 仅做 exp 距离衰减）。
    // 每个低压由 (world_seed, j) 哈希出确定性初始相位/纬度，随 sim_day 自西向东平移（中纬西风带
    // 主导）并在归一化 x∈[0,1) 环绕（到东缘从西缘重入 → 源源不断的过境系统），纬度叠加慢摆动。
    // 无 cell_pos_x slot（POSX==nullptr）或 amp<=0 时无法/无需定位中心 → 退化关闭，向后兼容。
    const int n_mlow = (POSX != nullptr && mobile_low_amp > 0.0f) ? mobile_low_count : 0;

    // ─── Pass A: per-cell baseline ────────────────────────────────────────
    // perf (2A): 逐 cell 独立（读 POSY/TR/NB/LUT/可选场 slot，写 slp_buf[i]/thermal_abs[i]，
    // 无标量累加器；mobile_low/synoptic 均 cell-local）→ 按 cell 区间并行、bit-equal。
    // perf (Item 5a, 2026-07-05): synoptic 波数 sa/sb/k1x..k2y 只依赖 world_seed，
    // 原在 cell 循环内每 cell 重算 4 次 sin/cos。外提到循环外一次算好 → bit-equal
    // (逐 cell 值不变，只是不再重复 6400 次三角)。
    // 经向必须采用整数谐波，才能同时保证场值与经向导数在圆柱接缝连续。
    // 波数标定(wind-variability 2026-08-03)：k1x∈{1,2} 时本项经向梯度只有
    // AMP·0.65·2π·k1x/100 ≈ 0.011/格，而静态纬向基线约 0.030/格 → 天气扭不动风向。
    // 改 {3..6}（均值 4.5）后约 0.033/格，与静态基线同量级：竞争得起但不压倒。
    // k1y 只温和提高（[0.9,1.7]，约 0.015/行 = 静态基线一半）—— 纬向 SLP 梯度正是
    // 三圈环流风带的定义者，经向涟漪过强会把风带打碎成涡群而非「会蜿蜒的带」。
    // B8 P2：Pass A 已抽成 Godot 无依赖的共享内核（worker 走同一份）。
    // 生产保留 parallel_for_range 分段：逐 cell 独立 → 分段 bit-equal。
    pk_async_physics::SlpPassAKnobs slp_a;
    slp_a.lat_amp = A_LAT;
    slp_a.land_amp = A_LAND;
    slp_a.water_damp = WATER_DAMP;
    slp_a.interior_boost = INTERIOR_BOOST;
    slp_a.coast_damp = COAST_DAMP;
    slp_a.thermal_weight = THERMAL_WEIGHT;
    slp_a.ice_high_weight = ICE_HIGH_WEIGHT;
    slp_a.snow_high_weight = SNOW_HIGH_WEIGHT;
    slp_a.moist_low_weight = MOIST_LOW_WEIGHT;
    slp_a.synoptic_amp = SLP_SYNOPTIC_AMP;
    slp_a.bounds_pos_x = float(slp_bounds_pos_x);
    slp_a.inv_bounds_w = float(slp_inv_bounds_w);
    slp_a.has_wrap_domain = slp_has_wrap_domain;
    slp_a.wrap_origin_x = wrap_origin_x;
    slp_a.wrap_period_x = wrap_period_x;
    slp_a.world_seed = world_seed;
    pk_async_physics::prepare_slp_forcing(slp_a, LUT_BINS, float(season_phase),
        axial_tilt_deg, daylen_amp, sim_day, slp_synoptic_period_days,
        n_mlow, mobile_low_amp, mobile_low_sigma, mobile_low_period,
        lut_base_lat, lut_solar_heat, _slp_insol_mean_lut.data());
    pk_async_physics::SlpPassALanes slp_lanes;
    slp_lanes.lat_norm = LATN.lat;
    slp_lanes.pos_y = LATN.posy;
    slp_lanes.lat_origin = LATN.origin;
    slp_lanes.lat_inv_span = LATN.inv_span;
    slp_lanes.terrain = TR;
    slp_lanes.neighbors = NB;
    slp_lanes.pos_x = POSX;
    slp_lanes.temp_anomaly = TEMP_AN;
    slp_lanes.ice = ICE;
    slp_lanes.snow = SNOW;
    slp_lanes.vapor = WVAP;
    slp_lanes.cloud = WCLD;
    slp_lanes.is_water_lut = is_water_lut;
    auto slp_passA_range = [&](int rb, int re) {
        pk_async_physics::slp_pass_a_range(
            n_cells, start_idx + rb, start_idx + re, slp_a, slp_lanes,
            slp_buf.data(),
            thermal_abs.empty() ? nullptr : thermal_abs.data());
    };
    pk::parallel_for_range("pk_slp_passA", slice_n, slp_passA_range);

    // 埋点（plan/daily-wind-stage-split）：Pass A（逐 cell 三角/insolation/synoptic）
    // 通常是 SLP 的大头；t_slp_pa 标记 Pass A 结束。
    auto t_slp_pa = std::chrono::high_resolution_clock::now();

    // ─── 全图归约段：仅最终切片(end_idx==n_cells)执行 ───────────────────────
    // Pass B 平滑 / recenter+p95 / 融合 / slot 发布 均依赖完整 slp_buf 才能逐位等价；
    // 中间切片只把 Pass A 结果累积进 _phys_slp_buf，构造 full-size slp_out 供 GDScript
    // size-gate 通过（但不会被用作地图值），且不触碰 cell_slp slot。GDScript 游标须保证
    // 末切片 end_idx==n_cells 覆盖全图，使 _phys_slp_buf 在末切片时已是完整 Pass A 场。
    bool published_to_slot = false;
    PackedFloat32Array slp_out;
    slp_out.resize(n_cells);
    auto t_slp_pb   = t_slp_pa;
    auto t_slp_norm = t_slp_pa;
    if (end_idx == n_cells) {
    // ─── Pass B: 6-neighbor Jacobi smoothing ──────────────────────────────
    // B8 P2：平滑 + recenter/p95 + 响应混合 + delta 全部走共享内核
    // （pk_async_physics::slp_pass_b_pure）。生产侧只负责准备 scratch 与参数。
    std::vector<float> tmp(static_cast<size_t>(n_cells), 0.0f);
    {
        // 段 1：只做 Jacobi 平滑（保持 slp_passB_ms 的原有口径）。
        pk_async_physics::SlpPassBKnobs slp_b;
        slp_b.smooth_passes = smooth_passes;
        slp_b.recenter = false;
        slp_b.response_rate = -1.0f;
        pk_async_physics::slp_pass_b_pure(
            n_cells, slp_b, NB, nullptr, slp_buf.data(),
            (smooth_passes > 0) ? tmp.data() : nullptr,
            nullptr);
    }

    // 埋点：t_slp_pb 标记 Pass B（邻域平滑）结束。
    t_slp_pb = std::chrono::high_resolution_clock::now();

    {
        // 段 2：recenter + p95 缩放（slp_norm_ms 的原有口径）。
        pk_async_physics::SlpPassBKnobs slp_b;
        slp_b.smooth_passes = 0;
        slp_b.recenter = SLP_RECENTER;
        slp_b.target_p95 = SLP_TARGET_P95;
        slp_b.response_rate = -1.0f;
        pk_async_physics::slp_pass_b_pure(
            n_cells, slp_b, nullptr, nullptr, slp_buf.data(),
            (n_cells > 0) ? tmp.data() : nullptr, nullptr);
    }

    // 埋点：t_slp_norm 标记 recenter + p95 排序 + 缩放（norm 段）结束。
    t_slp_norm = std::chrono::high_resolution_clock::now();

    // ─── Marshall slp_out ─────────────────────────────────────────────────
    {
        // 段 3：响应混合（prev → cur）+ 再 recenter + delta。这三步原先就落在
        // marshall 段（t_slp_norm 之后），所以计时口径不变。
        pk_async_physics::SlpPassBKnobs slp_b;
        slp_b.smooth_passes = 0;
        slp_b.recenter = SLP_RECENTER;
        slp_b.target_p95 = 0.0f;   // 段 3 不再做 p95 缩放
        slp_b.response_rate = (PREV_SLP != nullptr) ? slp_response_rate : -1.0f;
        pk_async_physics::slp_pass_b_pure(
            n_cells, slp_b, nullptr, PREV_SLP, slp_buf.data(), nullptr,
            slp_delta.empty() ? nullptr : slp_delta.data());
    }
    {
        float *dst = slp_out.ptrw();
        std::memcpy(dst, slp_buf.data(), sizeof(float) * static_cast<size_t>(n_cells));
    }

    if (sid_slp >= 0 && slp_slot_size == n_cells) {
        float *dst = _slots.write[sid_slp].arr_f32.ptrw();
        std::memcpy(dst, slp_buf.data(), sizeof(float) * static_cast<size_t>(n_cells));
        _flush_slot_to_map(sid_slp);
        published_to_slot = true;
        out["slot_publish_reason"] = String("slot_published");
    }
    } else {
        // 中间切片：仅构造 full-size slp_out（GDScript size-gate 通过；不会被用作地图值），
        // 不发布到 cell_slp slot、不计算 stats。Pass A 结果已写入 _phys_slp_buf 对应区间。
        float *dst = slp_out.ptrw();
        std::memcpy(dst, slp_buf.data(), sizeof(float) * static_cast<size_t>(n_cells));
    }

    auto t1 = std::chrono::high_resolution_clock::now();
    out["elapsed_ms"] = std::chrono::duration<double, std::milli>(t1 - t0).count();
    out["fallback"]   = false;
    out["reason"]     = String();
    out["slp_out"]    = slp_out;
    out["published_to_slot"] = published_to_slot;
    knobs["slp_out"]  = slp_out;
    // 埋点 surface（plan/daily-wind-stage-split）：把 SLP 内部 4 段耗时返回给
    // GDScript，定位每日 ~3ms 花在 Pass A(三角)/Pass B(平滑)/norm(排序)/marshall(发布)。
    // 注意 elapsed_ms = t1-t0 不含末尾 stats 排序段（与历史一致）。
    out["slp_passA_ms"]    = std::chrono::duration<double, std::milli>(t_slp_pa - t0).count();
    out["slp_passB_ms"]    = std::chrono::duration<double, std::milli>(t_slp_pb - t_slp_pa).count();
    out["slp_norm_ms"]     = std::chrono::duration<double, std::milli>(t_slp_norm - t_slp_pb).count();
    out["slp_marshall_ms"] = std::chrono::duration<double, std::milli>(t1 - t_slp_norm).count();
    // stats 仅在末切片（完整场）计算；中间切片跳过，避免发出误导性的 partial 统计量。
    if (end_idx == n_cells) {
    if (!thermal_abs.empty()) {
        std::sort(thermal_abs.begin(), thermal_abs.end());
        const size_t p95_i = thermal_abs.empty() ? 0 : std::min(thermal_abs.size() - 1, size_t(std::floor(double(thermal_abs.size() - 1) * 0.95)));
        out["slp_thermal_p95"] = double(thermal_abs[p95_i]);
    }
    if (n_cells > 0) {
        double mean = 0.0;
        for (int i = 0; i < n_cells; ++i) {
            mean += double(slp_buf[i]);
        }
        mean /= double(n_cells);
        double var = 0.0;
        std::vector<float> slp_abs(static_cast<size_t>(n_cells), 0.0f);
        for (int i = 0; i < n_cells; ++i) {
            const double d = double(slp_buf[i]) - mean;
            var += d * d;
            slp_abs[static_cast<size_t>(i)] = std::fabs(slp_buf[i]);
        }
        std::sort(slp_abs.begin(), slp_abs.end());
        const size_t p95_i = std::min(slp_abs.size() - 1, size_t(std::floor(double(slp_abs.size() - 1) * 0.95)));
        out["slp_mean"] = mean;
        out["slp_std"] = std::sqrt(var / double(n_cells));
        out["slp_abs_p95"] = double(slp_abs[p95_i]);
    }
    if (!slp_delta.empty()) {
        std::sort(slp_delta.begin(), slp_delta.end());
        const size_t p95_i = std::min(slp_delta.size() - 1, size_t(std::floor(double(slp_delta.size() - 1) * 0.95)));
        out["slp_delta_p95"] = double(slp_delta[p95_i]);
    }
    }
    return out;
}

// ═══════════════════════════════════════════════════════════════════════════
// plan/dots-slp-psi-cpp — PSI ocean stream-function solver (stage 3+4+5)
// ═══════════════════════════════════════════════════════════════════════════
//
// Fused init + SOR iters + finalize, 1:1 mirror of GDScript:
//   PhysicalCirculationSolver.init_psi_solver  (stage 3 PSI_INIT)
//   PhysicalCirculationSolver.step_psi_solver  (stage 4 PSI_ITERS, n_iters)
//   PhysicalCirculationSolver.psi_to_ocean_current + commit_psi_to_cells
//                                              (stage 5 PSI_FINALIZE)
//
// Water-cell ordering MUST match GDScript: enumerate all cells in cell-index
// ascending order, push back to water_to_cell[] when terrain is water. This
// matches the GDScript loop "for cell in cells" since cells are indexed
// linearly. Mismatch here would cause SOR to converge to a different shape.
//
// Algorithmic choices kept identical to GDScript:
//   - 6-neighbor curl tau (z component): a.x * b.y - a.y * b.x
//   - PSI source = source_scale * curl_tau / max(beta_abs, beta_floor)
//   - r_factor   = r_base / max(beta_abs, beta_floor)
//   - SOR sweep: in-place Gauss-Seidel; psi_e = nb[d=0], psi_w = nb[d=3];
//                advection term r_factor * (psi_e - psi_w) * 0.5
//                target  = sum_nb / 6 - adv + source
//                psi[k]  = (1 - omega) * old + omega * target
//   - Finalize : grad_psi = (1/3) * sum_d (psi[nb] - psi[self]) * NB_DIR_d
//                cur = (-grad.y, grad.x) * ocean_current_scale
//                if |ls| > UPWELLING_HIGHLAT_ABS && temp_rel < cold_sink_temp:
//                    cur.y += sign(ls) * sin(|ls| * pi) * thermohaline_weight
//                cur.x = clamp(cur.x, -1, 1); cur.y = clamp(cur.y, -1, 1);
//
// NEIGHBOR_DIRS (match physical_circulation_solver.gd::NEIGHBOR_DIRS exactly,
// which is the order the GDScript map_data stores _neighbor_indices in,
// i.e. HexUtils.CUBE_DIRECTIONS: E, NE, NW, W, SW, SE; screen +y = south):
//   d=0 ( sqrt3,    0  )  east
//   d=1 ( sqrt3/2, -1.5)  north-east
//   d=2 (-sqrt3/2, -1.5)  north-west
//   d=3 (-sqrt3,    0  )  west
//   d=4 (-sqrt3/2, +1.5)  south-west
//   d=5 ( sqrt3/2, +1.5)  south-east
godot::Dictionary DCWorldExt::run_psi_solver_pass(godot::Dictionary knobs) {
    using godot::Dictionary;
    using godot::PackedByteArray;
    using godot::PackedFloat32Array;
    using godot::PackedInt32Array;
    using godot::String;
    using godot::StringName;

    Dictionary out;
    out["elapsed_ms"] = -1.0;
    out["fallback"] = true;
    out["reason"] = String();

    auto fail = [&](const char *why) -> Dictionary {
        out["reason"] = String(why);
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_psi_solver_pass: ", why,
            " — fallback to GDScript");
        return out;
    };

    if (!_bound) return fail("not _bound");

    static const char *required_keys[] = {
        "n_cells", "hex_size",
        "world_bounds_pos_y", "world_bounds_size_y",
        "neighbor_indices", "water_terrain_ids",
        "wind_x_arr", "wind_y_arr", "wind_speed_arr",
        nullptr,
    };
    for (int k = 0; required_keys[k] != nullptr; ++k) {
        if (!knobs.has(required_keys[k])) {
            String s = String("missing knob '") + String(required_keys[k]) + String("'");
            return fail(s.utf8().get_data());
        }
    }

    const int    n_cells       = int(knobs["n_cells"]);
    const double bounds_pos_y  = double(knobs["world_bounds_pos_y"]);
    const double bounds_size_y = double(knobs["world_bounds_size_y"]);
    if (n_cells <= 0)            return fail("n_cells <= 0");
    if (bounds_size_y <= 0.001)  return fail("world_bounds_size_y <= 0.001");

    // Numeric constants (defaults must mirror physical_circulation_solver.gd).
    const int   PSI_TOTAL_ITERS = int(knobs.has("psi_total_iters")     ? int(knobs["psi_total_iters"])     : 40);
    const float PSI_OMEGA       = float(knobs.has("psi_sor_omega")     ? double(knobs["psi_sor_omega"])    : 1.40);
    const float PSI_R_BASE      = float(knobs.has("psi_r_base")        ? double(knobs["psi_r_base"])       : 0.18);
    const float PSI_BETA_FLOOR  = float(knobs.has("psi_beta_floor")    ? double(knobs["psi_beta_floor"])   : 0.05);
    const float PSI_SRC_SCALE   = float(knobs.has("psi_source_scale")  ? double(knobs["psi_source_scale"]) : 0.06);
    const float OC_SCALE        = float(knobs.has("ocean_current_scale")    ? double(knobs["ocean_current_scale"])    : 0.13);
    float OC_MAX_MAG            = float(knobs.has("ocean_current_max_magnitude") ? double(knobs["ocean_current_max_magnitude"]) : 0.65);
    if (OC_MAX_MAG < 0.01f) OC_MAX_MAG = 0.01f;
    else if (OC_MAX_MAG > 1.4142136f) OC_MAX_MAG = 1.4142136f;
    const float TH_WEIGHT       = float(knobs.has("thermohaline_weight")    ? double(knobs["thermohaline_weight"])    : 0.12);
    const float UPW_HIGHLAT_ABS = float(knobs.has("upwelling_highlat_abs")  ? double(knobs["upwelling_highlat_abs"])  : 0.75);
    const float COLD_SINK_TEMP  = float(knobs.has("cold_sink_temp")         ? double(knobs["cold_sink_temp"])         : -0.05);
    float response_rate = float(knobs.has("ocean_current_response_rate") ? double(knobs["ocean_current_response_rate"]) : 1.0);
    if (response_rate < 0.0f) response_rate = 0.0f;
    else if (response_rate > 1.0f) response_rate = 1.0f;
    const float THERMAL_CURRENT_WEIGHT = float(knobs.has("ocean_thermal_current_weight") ? double(knobs["ocean_thermal_current_weight"]) : TH_WEIGHT);
    const float DENSITY_COLD_WEIGHT = float(knobs.has("ocean_density_cold_weight") ? double(knobs["ocean_density_cold_weight"]) : 0.22);
    const float DENSITY_ICE_WEIGHT = float(knobs.has("ocean_density_ice_weight") ? double(knobs["ocean_density_ice_weight"]) : 0.12);
    // ─── NS 化 Phase 4:洋流深度耦合 + 地形转向(默认 0 → 旧行为逐位不变)─────
    // 风应力旋度源项按深度衰减:陆架上旋度效率降低(浅水底摩擦耗散)。
    // depth = sea_level - elev(归一化单位),depth_ref 参考水深,damp=0 关闭。
    float DEPTH_CURL_DAMP = float(knobs.has("ocean_depth_curl_damp") ? double(knobs["ocean_depth_curl_damp"]) : 0.0);
    if (DEPTH_CURL_DAMP < 0.0f) DEPTH_CURL_DAMP = 0.0f;
    else if (DEPTH_CURL_DAMP > 1.0f) DEPTH_CURL_DAMP = 1.0f;
    float SEA_LEVEL = float(knobs.has("sea_level") ? double(knobs["sea_level"]) : 0.42);
    if (SEA_LEVEL < 0.05f) SEA_LEVEL = 0.05f;
    else if (SEA_LEVEL > 0.95f) SEA_LEVEL = 0.95f;
    float DEPTH_REF = float(knobs.has("ocean_depth_ref") ? double(knobs["ocean_depth_ref"]) : 0.12);
    if (DEPTH_REF < 0.01f) DEPTH_REF = 0.01f;
    // current-from-PSI 步加地形等深线偏转分量 k_topo·(∇h × k)(洋流被等深线引导,
    // 陆架/海山绕流);k_topo 默认 0 关闭。
    float TOPO_STEER_W = float(knobs.has("ocean_topo_steer_w") ? double(knobs["ocean_topo_steer_w"]) : 0.0);
    if (TOPO_STEER_W < 0.0f) TOPO_STEER_W = 0.0f;
    else if (TOPO_STEER_W > 0.5f) TOPO_STEER_W = 0.5f;
    // warm-start（plan/psi-warm-start 2026-06-17）：SOR 用上一轮发布在 cell_ocean_psi
    // slot 的 ψ 作初值，而非每轮从 0 冷启动。洋流流函数日间变化极小，warm-start 后
    // 残差很小，少量迭代即可收敛（配合 psi_total_iters 下调）。默认 true；A/B 对照
    // 时传 psi_warm_start=false 退回冷启动。
    const bool PSI_WARM_START = bool(knobs.has("psi_warm_start") ? bool(knobs["psi_warm_start"]) : true);
    const String PSI_EARLY_EXIT_MODE = String(knobs.has("psi_early_exit_mode")
        ? String(knobs["psi_early_exit_mode"])
        : String("perf"));
    bool psi_early_exit_enabled = false;
    int psi_min_iters = PSI_TOTAL_ITERS;
    int psi_check_every = 2;
    float psi_residual_epsilon = 0.0f;
    if (PSI_EARLY_EXIT_MODE == String("balanced")) {
        psi_early_exit_enabled = true;
        psi_min_iters = 8;
        psi_residual_epsilon = 0.00035f;
    } else if (PSI_EARLY_EXIT_MODE == String("perf")) {
        psi_early_exit_enabled = true;
        psi_min_iters = 6;
        psi_residual_epsilon = 0.00075f;
    }
    if (!PSI_WARM_START && psi_early_exit_enabled) {
        psi_min_iters += 4;
    }
    if (psi_min_iters < 1) psi_min_iters = 1;
    if (psi_min_iters > PSI_TOTAL_ITERS) psi_min_iters = PSI_TOTAL_ITERS;
    if (psi_check_every < 1) psi_check_every = 1;

    PackedInt32Array nb_arr     = knobs["neighbor_indices"];
    PackedByteArray  water_ids  = knobs["water_terrain_ids"];
    PackedFloat32Array wind_x   = knobs["wind_x_arr"];
    PackedFloat32Array wind_y   = knobs["wind_y_arr"];
    PackedFloat32Array wind_spd = knobs["wind_speed_arr"];
    if (nb_arr.size()   < n_cells * 6) return fail("neighbor_indices size < n_cells * 6");
    if (water_ids.size() <= 0)          return fail("water_terrain_ids empty");
    if (wind_x.size()   < n_cells)      return fail("wind_x_arr size < n_cells");
    if (wind_y.size()   < n_cells)      return fail("wind_y_arr size < n_cells");
    if (wind_spd.size() < n_cells)      return fail("wind_speed_arr size < n_cells");

    _phys_resolve_static(n_cells, water_ids);
    const int sid_pos_y   = _phys_sid_pos_y;
    const int sid_terrain = _phys_sid_terrain;
    const int sid_temp    = _phys_sid_temp;
    const int sid_temp_an = _phys_sid_temp_an;
    const int sid_ice     = _phys_sid_ice;
    const int sid_ocx     = _phys_sid_ocx;
    const int sid_ocy     = _phys_sid_ocy;
    if (sid_pos_y < 0 || sid_terrain < 0) {
        return fail("missing slot id (cell_pos_y/cell_terrain)");
    }
    Slot &s_pos_y   = _slots.write[sid_pos_y];
    Slot &s_terrain = _slots.write[sid_terrain];
    if (s_pos_y.arr_f32.size()  != n_cells ||
        s_terrain.arr_u8.size() != n_cells) {
        return fail("slot array size mismatch (re-bind needed?)");
    }

    const bool *is_water_lut = _phys_is_water_lut;

    const float   * const __restrict POSY = s_pos_y.arr_f32.ptr();
    const uint8_t * const __restrict TR   = s_terrain.arr_u8.ptr();
    const int32_t * const __restrict NB   = nb_arr.ptr();
    const float   * const __restrict WX   = wind_x.ptr();
    const float   * const __restrict WY   = wind_y.ptr();
    const float   * const __restrict WSP  = wind_spd.ptr();
    const float *TEMP = nullptr;
    const float *TEMP_AN = nullptr;
    const float *ICE = nullptr;
    const float *OLD_OCX = nullptr;
    const float *OLD_OCY = nullptr;
    if (sid_temp >= 0 && _slots.write[sid_temp].arr_f32.size() == n_cells) {
        TEMP = _slots.write[sid_temp].arr_f32.ptr();
    }
    if (sid_temp_an >= 0 && _slots.write[sid_temp_an].arr_f32.size() == n_cells) {
        TEMP_AN = _slots.write[sid_temp_an].arr_f32.ptr();
    }
    if (sid_ice >= 0 && _slots.write[sid_ice].arr_f32.size() == n_cells) {
        ICE = _slots.write[sid_ice].arr_f32.ptr();
    }
    if (sid_ocx >= 0 && _slots.write[sid_ocx].arr_f32.size() == n_cells) {
        OLD_OCX = _slots.write[sid_ocx].arr_f32.ptr();
    }
    if (sid_ocy >= 0 && _slots.write[sid_ocy].arr_f32.size() == n_cells) {
        OLD_OCY = _slots.write[sid_ocy].arr_f32.ptr();
    }
    // NS 化 Phase 4:elevation slot(深度耦合/地形转向的数据源);缺失时两项自动失效,
    // 与 knob=0 等价(旧行为),由 out["ocean_topo_active"] 上报实际状态。
    const int sid_elev = _phys_sid_elev;
    const float *ELEV = nullptr;
    if (sid_elev >= 0 && _slots.write[sid_elev].arr_f32.size() == n_cells) {
        ELEV = _slots.write[sid_elev].arr_f32.ptr();
    }
    // warm-start：上一轮 ψ 已发布到 cell_ocean_psi slot；读它作 SOR 初值。
    // 冷启动 / slot 不可用 / 显式关闭时为 null → 退回 0 初值。
    const int sid_psi_prev = _phys_sid_psi_prev;
    const float *PSI_PREV = nullptr;
    if (PSI_WARM_START && sid_psi_prev >= 0 && _slots.write[sid_psi_prev].arr_f32.size() == n_cells) {
        PSI_PREV = _slots.write[sid_psi_prev].arr_f32.ptr();
    }

    auto t0 = std::chrono::high_resolution_clock::now();

    // ─── PSI init ─────────────────────────────────────────────────────────
    // Build water_to_cell[] in cell-index ascending order; cell_to_water[] is
    // the inverse map (-1 for land cells); nb_w[] maps each water cell's 6
    // neighbors to water-domain indices (-1 = land/out-of-domain).
    // perf (Item 6, 2026-07-05): 这三者纯由水掩膜(TR+water_ids)与邻接(NB)决定，与风/温
    // 无关，对静态地图逐 tick 恒等。海冰是独立 slot，不改 terrain id → 掩膜生成后静态。
    // 缓存进成员，自校验指纹 = FNV-1a(n_cells, water_ids, 全 TR, 全 NB)；命中即逐位复用
    // (nb_w/water_to_cell/cell_to_water bit-identical)，跳过重建与三次堆分配。地形/邻接
    // 任何变化指纹即失配、自动重建 → 无需外部失效钩子（消除最易漏的失效点）。
    {
        uint64_t fp = 1469598103934665603ull; // FNV-1a offset basis
        auto mix = [&fp](uint32_t bits) {
            fp ^= uint64_t(bits);
            fp *= 1099511628211ull; // FNV-1a prime
        };
        mix(uint32_t(n_cells));
        for (int k = 0; k < water_ids.size(); ++k) {
            mix(uint32_t(int(water_ids[k])));
        }
        for (int i = 0; i < n_cells; ++i) {
            mix(uint32_t(TR[i]));
        }
        for (int i = 0; i < n_cells * 6; ++i) {
            mix(uint32_t(NB[i]));
        }
        if (!(_psi_topo_valid && _psi_topo_fp == fp &&
              int(_psi_cell_to_water.size()) == n_cells)) {
            _psi_cell_to_water.assign(static_cast<size_t>(n_cells), -1);
            _psi_water_to_cell.assign(static_cast<size_t>(n_cells), 0);
            _psi_nb_w.assign(static_cast<size_t>(n_cells) * 6, -1);
            // B8 P2：CSR 拓扑构建已抽成共享纯内核（worker 走同一份）。
            _psi_topo_n_water = pk_async_physics::psi_topology_build_pure(
                n_cells, TR, NB, is_water_lut,
                _psi_cell_to_water.data(), _psi_water_to_cell.data(),
                _psi_nb_w.data());
            _psi_water_to_cell.resize(static_cast<size_t>(_psi_topo_n_water));
            _psi_topo_fp = fp;
            _psi_topo_valid = true;
        }
    }
    const std::vector<int> &cell_to_water = _psi_cell_to_water;
    const std::vector<int> &water_to_cell = _psi_water_to_cell;
    const std::vector<int> &nb_w = _psi_nb_w;
    const int n_water = _psi_topo_n_water;

    // Per-water-cell: nb_idx (to water-domain index, -1 = land/out-of-domain),
    // wind stress (= wind_vector * wind_speed), curl_tau, beta_abs, r_factor,
    // source, psi.
    // 注：nb_w 已在上方拓扑缓存块构建（member 别名），此处不再声明。
    std::vector<float> tau_x(static_cast<size_t>(n_water), 0.0f);
    std::vector<float> tau_y(static_cast<size_t>(n_water), 0.0f);
    std::vector<float> ny_w(static_cast<size_t>(n_water), 0.5f);
    std::vector<float> ls_w(static_cast<size_t>(n_water), 0.0f);
    std::vector<float> curl(static_cast<size_t>(n_water), 0.0f);
    std::vector<float> beta_abs(static_cast<size_t>(n_water), PSI_BETA_FLOOR);
    std::vector<float> r_factor(static_cast<size_t>(n_water), 0.0f);
    std::vector<float> source(static_cast<size_t>(n_water), 0.0f);
    std::vector<float> psi(static_cast<size_t>(n_water), 0.0f);
    // warm-start 与 NEIGHBOR_DIRS 都已在共享内核里（psi_solve_pure 自带清零 +
    // prev_psi 播种与同源的邻居方向表），生产侧不再重复。

    // B8 P2：tau/curl/源项 → SOR → finalize 三段已抽到 pk_async_physics::psi_solve_pure
    // （worker 走同一份）。生产侧只保留拓扑缓存、scratch 与诊断输出。
    // 纬度权威：cell_lat_norm slot（见 phys_make_lat_norm）。
    const PhysLatNorm LATN = phys_make_lat_norm(_phys_lat_norm_ptr(n_cells), POSY, n_cells);
    (void)bounds_pos_y;
    (void)bounds_size_y;

    // ─── PSI finalize + SOR（共享内核）────────────────────────────────────
    PackedFloat32Array curl_out, psi_out, ocx_out, ocy_out;
    curl_out.resize(n_cells);
    psi_out.resize(n_cells);
    ocx_out.resize(n_cells);
    ocy_out.resize(n_cells);
    std::vector<float> ocean_delta(static_cast<size_t>(n_cells), 0.0f);
    std::vector<float> ocean_preclamp_mag(static_cast<size_t>(n_water), 0.0f);
    std::vector<float> thermal_current_mag(static_cast<size_t>(n_water), 0.0f);

    pk_async_physics::PsiSolveKnobs psi_k;
    psi_k.total_iters = PSI_TOTAL_ITERS;
    psi_k.omega = PSI_OMEGA;
    psi_k.r_base = PSI_R_BASE;
    psi_k.beta_floor = PSI_BETA_FLOOR;
    psi_k.source_scale = PSI_SRC_SCALE;
    psi_k.oc_scale = OC_SCALE;
    psi_k.oc_max_mag = OC_MAX_MAG;
    psi_k.thermohaline_weight = TH_WEIGHT;
    psi_k.upwelling_highlat_abs = UPW_HIGHLAT_ABS;
    psi_k.cold_sink_temp = COLD_SINK_TEMP;
    psi_k.response_rate = response_rate;
    psi_k.thermal_current_weight = THERMAL_CURRENT_WEIGHT;
    psi_k.density_cold_weight = DENSITY_COLD_WEIGHT;
    psi_k.density_ice_weight = DENSITY_ICE_WEIGHT;
    psi_k.depth_curl_damp = DEPTH_CURL_DAMP;
    psi_k.sea_level = SEA_LEVEL;
    psi_k.depth_ref = DEPTH_REF;
    psi_k.topo_steer_w = TOPO_STEER_W;
    psi_k.early_exit = psi_early_exit_enabled;
    psi_k.min_iters = psi_min_iters;
    psi_k.check_every = psi_check_every;
    psi_k.residual_epsilon = psi_residual_epsilon;

    pk_async_physics::PsiSolveLanes psi_l;
    psi_l.n_cells = n_cells;
    psi_l.n_water = n_water;
    psi_l.neighbors = NB;
    psi_l.terrain = TR;
    psi_l.is_water_lut = is_water_lut;
    psi_l.cell_to_water = cell_to_water.data();
    psi_l.water_to_cell = water_to_cell.data();
    psi_l.nb_w = nb_w.data();
    psi_l.wind_x = WX;
    psi_l.wind_y = WY;
    psi_l.wind_speed = WSP;
    psi_l.lat_norm = LATN.lat;
    psi_l.pos_y = LATN.posy;
    psi_l.lat_origin = LATN.origin;
    psi_l.lat_inv_span = LATN.inv_span;
    psi_l.temp = TEMP;
    psi_l.temp_anomaly = TEMP_AN;
    psi_l.ice = ICE;
    psi_l.elevation = ELEV;
    psi_l.prev_psi = PSI_PREV;
    psi_l.old_ocean_x = OLD_OCX;
    psi_l.old_ocean_y = OLD_OCY;
    psi_l.out_curl = curl_out.ptrw();
    psi_l.out_psi = psi_out.ptrw();
    psi_l.out_ocean_x = ocx_out.ptrw();
    psi_l.out_ocean_y = ocy_out.ptrw();
    psi_l.ocean_delta = ocean_delta.data();
    psi_l.out_preclamp_mag = ocean_preclamp_mag.data();
    psi_l.out_thermal_mag = thermal_current_mag.data();

    pk_async_physics::PsiSolveScratch psi_s;
    psi_s.tau_x = tau_x.data();
    psi_s.tau_y = tau_y.data();
    psi_s.ny_w = ny_w.data();
    psi_s.ls_w = ls_w.data();
    psi_s.curl = curl.data();
    psi_s.beta_abs = beta_abs.data();
    psi_s.r_factor = r_factor.data();
    psi_s.source = source.data();
    psi_s.psi = psi.data();

    pk_async_physics::PsiSolveStats psi_stats;
    if (!pk_async_physics::psi_solve_pure(psi_k, psi_l, psi_s, psi_stats)) {
        return fail("psi_solve_pure rejected inputs");
    }
    const int   psi_iters_run = psi_stats.iters_run;
    const float psi_residual_final = psi_stats.residual_final;
    const bool  psi_early_exit = psi_stats.early_exit;
    const int   ocean_current_clamp_count = psi_stats.clamp_count;
    const float ocean_preclamp_max = psi_stats.preclamp_max;

    knobs["wind_stress_curl_out"] = curl_out;
    knobs["ocean_psi_out"]        = psi_out;
    knobs["ocean_current_x_out"]  = ocx_out;
    knobs["ocean_current_y_out"]  = ocy_out;

    bool published_to_slot = false;
    if (sid_ocx >= 0 && sid_ocy >= 0 &&
        _slots.write[sid_ocx].arr_f32.size() == n_cells &&
        _slots.write[sid_ocy].arr_f32.size() == n_cells) {
        std::memcpy(
            _slots.write[sid_ocx].arr_f32.ptrw(),
            ocx_out.ptr(),
            sizeof(float) * static_cast<size_t>(n_cells));
        std::memcpy(
            _slots.write[sid_ocy].arr_f32.ptrw(),
            ocy_out.ptr(),
            sizeof(float) * static_cast<size_t>(n_cells));
        _flush_slot_to_map(sid_ocx);
        _flush_slot_to_map(sid_ocy);
        // Fix #11 (2026-06-15): wind_stress_curl + ocean_psi 加入 schema 后也 publish。
        // 之前 GDScript caller 必须 2400-loop 写 map.wind_stress_curl_arr / ocean_psi_arr，
        // 这两个 slot 化后 caller 完全跳过 unpack（节省 2400 × 2 = 4800 GDScript array writes）。
        // 仅 tile_data_recorder 读 PackedArray，flush_slot 后 map.* 仍是同步的。
        const int sid_curl = component_id(StringName("cell_wind_stress_curl"));
        const int sid_psi  = component_id(StringName("cell_ocean_psi"));
        if (sid_curl >= 0 && _slots.write[sid_curl].arr_f32.size() == n_cells) {
            std::memcpy(
                _slots.write[sid_curl].arr_f32.ptrw(),
                curl_out.ptr(),
                sizeof(float) * static_cast<size_t>(n_cells));
            _flush_slot_to_map(sid_curl);
        }
        if (sid_psi >= 0 && _slots.write[sid_psi].arr_f32.size() == n_cells) {
            std::memcpy(
                _slots.write[sid_psi].arr_f32.ptrw(),
                psi_out.ptr(),
                sizeof(float) * static_cast<size_t>(n_cells));
            _flush_slot_to_map(sid_psi);
        }
        published_to_slot = true;
    }

    auto t1 = std::chrono::high_resolution_clock::now();
    out["elapsed_ms"] = std::chrono::duration<double, std::milli>(t1 - t0).count();
    out["fallback"]   = false;
    out["reason"]     = String();
    out["n_water"]    = n_water;
    out["wind_stress_curl_out"] = curl_out;
    out["ocean_psi_out"]        = psi_out;
    out["ocean_current_x_out"]  = ocx_out;
    out["ocean_current_y_out"]  = ocy_out;
    out["published_to_slot"]    = published_to_slot;
    out["psi_iters_run"] = psi_iters_run;
    out["psi_residual_final"] = double(psi_residual_final);
    out["psi_early_exit"] = psi_early_exit;
    out["psi_mode"] = PSI_EARLY_EXIT_MODE;
    // NS 化 Phase 4 诊断键:knob 回显 + elevation slot 实际可用状态。
    out["ocean_topo_steer_w"] = double(TOPO_STEER_W);
    out["ocean_depth_curl_damp"] = double(DEPTH_CURL_DAMP);
    out["ocean_topo_active"] = (ELEV != nullptr);
    if (!ocean_delta.empty()) {
        std::sort(ocean_delta.begin(), ocean_delta.end());
        const size_t p95_i = std::min(ocean_delta.size() - 1, size_t(std::floor(double(ocean_delta.size() - 1) * 0.95)));
        out["ocean_delta_p95"] = double(ocean_delta[p95_i]);
    }
    if (!thermal_current_mag.empty()) {
        std::sort(thermal_current_mag.begin(), thermal_current_mag.end());
        const size_t p95_t = std::min(thermal_current_mag.size() - 1, size_t(std::floor(double(thermal_current_mag.size() - 1) * 0.95)));
        out["thermal_current_p95"] = double(thermal_current_mag[p95_t]);
    }
    if (!ocean_preclamp_mag.empty()) {
        std::sort(ocean_preclamp_mag.begin(), ocean_preclamp_mag.end());
        const size_t p95_pre = std::min(ocean_preclamp_mag.size() - 1, size_t(std::floor(double(ocean_preclamp_mag.size() - 1) * 0.95)));
        out["ocean_current_preclamp_p95"] = double(ocean_preclamp_mag[p95_pre]);
        out["ocean_current_preclamp_max"] = double(ocean_preclamp_max);
        out["ocean_current_clamp_count"] = ocean_current_clamp_count;
        out["ocean_current_clamp_ratio"] = double(ocean_current_clamp_count) / double(ocean_preclamp_mag.size());
        out["ocean_current_max_magnitude"] = double(OC_MAX_MAG);
    }
    return out;
}

} // namespace pk
