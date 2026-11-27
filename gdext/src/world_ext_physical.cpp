#include "world_ext.h"
#include "simulation_math.h"

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
#include "world_ext_physical_section_wind_solver.inc"

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
#include "world_ext_physical_section_sea_level_pressure.inc"

// ═══════════════════════════════════════════════════════════════════════════
#include "world_ext_physical_section_stream_function.inc"

} // namespace pk
