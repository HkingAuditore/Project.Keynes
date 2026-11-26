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






// ─── 独立全场 ψ(synoptic eddy)推进 pass ──────────────────────────────────────
//
// 「让天气移动」架构改动：把 ψ 从切片化的 solve 热循环里抽出来，由本 pass 在每个
// weather 轮调用一次(全场、不切片)，推进 ψ 一整步。这样 ψ 的有效时间步=每轮(而非被
// 切片稀释)，且用「平滑引导流(风邻域平均)+纯取值半拉格朗日平移」保持空间连贯(修复多格
// 采样打散场的问题)。solve 循环只读 _wx_synoptic 做耦合 → ψ 移动 → 云/雨成片随风平移。
// 返回 elapsed_ms (≥0)；ψ 关闭返回 0；失败返回 -1.0。
//
// S3：数值实现已并入 pk_async_climate::synoptic_advance_pure，本 pass 只做 slot
// 取值与 knob 解析。注意它把 cell_temp slot 直接当斜压门的输入，而内核要求的是
// 归一化温度；solve pass 里的调用点传的是主循环的 TR。这条路径目前没有调用方
// （run_synoptic_advance_pass_native 全库无引用），真要启用得先接一条归一化温度。
double DCWorldExt::run_synoptic_advance_pass(const Dictionary &knobs) {
    using godot::StringName;
    using godot::PackedVector2Array;
    using godot::PackedInt32Array;
    using godot::Vector2;

    auto diag = [&](const char *why) {
        UtilityFunctions::push_warning("[DCWorldExt] run_synoptic_advance_pass: ", why);
    };
    if (!_bound) { diag("not _bound"); return -1.0; }

    const bool syn_enabled = knobs.has("weather_synoptic_enabled")
                                 ? bool(knobs["weather_synoptic_enabled"]) : true;
    if (!syn_enabled) return 0.0;

    const int sid_wind_x = component_id(StringName("cell_wind_x"));
    const int sid_wind_y = component_id(StringName("cell_wind_y"));
    const int sid_temp   = component_id(StringName("cell_temp"));
    if (sid_wind_x < 0 || sid_wind_y < 0 || sid_temp < 0) { diag("missing wind/temp slot"); return -1.0; }

    if (!knobs.has("n_cells") || !knobs.has("cell_pos") || !knobs.has("neighbor_indices")) {
        diag("knobs missing n_cells/cell_pos/neighbor_indices"); return -1.0;
    }
    const int n_cells = int(knobs["n_cells"]);
    if (n_cells <= 0) return -1.0;
    PackedVector2Array cell_pos_arr = knobs["cell_pos"];
    PackedInt32Array   nb_arr       = knobs["neighbor_indices"];
    if (cell_pos_arr.size() != n_cells || nb_arr.size() < n_cells * 6) { diag("pos/nb size mismatch"); return -1.0; }

    const float syn_baroclinic = knobs.has("weather_synoptic_baroclinic") ? float(knobs["weather_synoptic_baroclinic"]) : 0.40f;
    // 默认值与 run_weather_field_solve_pass 的 ψ 段一致。合并前这里是 0.94/0.12/0.05，
    // 于是同一个 knob 缺省时两条路径给出不同的 ψ 演化。
    const float syn_damp       = knobs.has("weather_synoptic_damp")       ? float(knobs["weather_synoptic_damp"])       : 0.90f;
    const float syn_diffuse    = knobs.has("weather_synoptic_diffuse")    ? float(knobs["weather_synoptic_diffuse"])    : 0.05f;
    const float syn_seed_rate  = knobs.has("weather_synoptic_seed_rate")  ? float(knobs["weather_synoptic_seed_rate"])  : 0.015f;
    const float syn_seed_amp   = knobs.has("weather_synoptic_seed_amp")   ? float(knobs["weather_synoptic_seed_amp"])   : 0.42f;
    int         syn_adv_cells  = knobs.has("weather_synoptic_adv_cells")  ? int(knobs["weather_synoptic_adv_cells"])    : 3;
    if (syn_adv_cells < 0) syn_adv_cells = 0; else if (syn_adv_cells > 16) syn_adv_cells = 16;
    const int   syn_tick       = knobs.has("weather_solve_tick")          ? int(knobs["weather_solve_tick"])            : 0;
    float wrap_width_x = knobs.has("weather_wrap_width_x") ? float(knobs["weather_wrap_width_x"]) : 0.0f;
    if (wrap_width_x < 0.0f) wrap_width_x = 0.0f;
    float pos_scale = knobs.has("weather_cell_pos_scale") ? float(knobs["weather_cell_pos_scale"]) : 1.0f;
    if (pos_scale <= 0.001f) pos_scale = 1.0f;

    Slot &s_wx = _slots.write[sid_wind_x];
    Slot &s_wy = _slots.write[sid_wind_y];
    Slot &s_tp = _slots.write[sid_temp];
    if ((int)s_wx.arr_f32.size() != n_cells || (int)s_wy.arr_f32.size() != n_cells ||
        (int)s_tp.arr_f32.size() != n_cells) { diag("wind/temp slot size mismatch"); return -1.0; }
    const float   * const __restrict WX   = s_wx.arr_f32.ptr();
    const float   * const __restrict WY   = s_wy.arr_f32.ptr();
    const float   * const __restrict TEMP = s_tp.arr_f32.ptr();
    const Vector2 * const __restrict POS  = cell_pos_arr.ptr();
    const int32_t * const __restrict NB   = nb_arr.ptr();

    if (_wf_pos_x.size() != (size_t)n_cells) {
        _wf_pos_x.assign((size_t)n_cells, 0.0f);
        _wf_pos_y.assign((size_t)n_cells, 0.0f);
    }
    for (int i = 0; i < n_cells; ++i) {
        _wf_pos_x[(size_t)i] = POS[i].x;
        _wf_pos_y[(size_t)i] = POS[i].y;
    }

    pk_async_climate::SynopticAdvanceKnobs syn;
    syn.baroclinic = syn_baroclinic;
    syn.damp = syn_damp;
    syn.diffuse = syn_diffuse;
    syn.seed_rate = syn_seed_rate;
    syn.seed_amp = syn_seed_amp;
    syn.adv_cells = syn_adv_cells;
    syn.tick = syn_tick;
    syn.cell_pos_scale = pos_scale;
    syn.wrap_width_x = wrap_width_x;

    auto t0 = std::chrono::high_resolution_clock::now();
    pk_async_climate::synoptic_advance_pure(
        n_cells, NB, _wf_pos_x.data(), _wf_pos_y.data(), WX, WY, TEMP, syn,
        _wx_synoptic, _wx_synoptic_prev);
    auto t1 = std::chrono::high_resolution_clock::now();
    return std::chrono::duration<double, std::milli>(t1 - t0).count();
}

// ─── F.1 main pass ──────────────────────────────────────────────────────────
#include "world_ext_weather_section_weather_field_solver.inc"

// ─── F.1b: weather field commit / publish pass ─────────────────────────────
Dictionary DCWorldExt::run_weather_field_commit_pass(Dictionary knobs) {
    using godot::Dictionary;
    using godot::PackedByteArray;
    using godot::PackedFloat32Array;
    using godot::PackedInt32Array;
    using godot::String;
    using godot::StringName;

    Dictionary out;
    out["elapsed_ms"] = -1.0;
    out["commit_loop_ms"] = 0.0;
    out["weather_dirty_count"] = 0;
    out["water_budget_error"] = 0.0;
    out["active_weather_ratio"] = 0.0;
    out["weather_convergence_dirty_count"] = 0;
    out["weather_convergence_deltas"] = PackedFloat32Array();
    out["convergence_published"] = false;
    out["weather_lut"] = PackedByteArray();
    out["weather_lut_changed"] = false;
    out["weather_lut_dirty_count"] = 0;
    out["weather_lut_full_rebuild"] = false;
    out["path"] = String("gdext_commit");
    out["reason"] = String();


    auto fail = [&](const char *why) -> Dictionary {
        out["reason"] = String(why);
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_weather_field_commit_pass: ", why,
            " — fallback to GDScript");
        return out;
    };

    if (!_bound) return fail("not _bound");

    if (!knobs.has("n_cells") || !knobs.has("neighbor_indices") ||
        !knobs.has("prev_vapor") || !knobs.has("out_vapor") ||
        !knobs.has("out_cloud") || !knobs.has("out_precip") ||
        !knobs.has("out_instability") || !knobs.has("out_intensity") ||
        !knobs.has("out_convergence") || !knobs.has("out_type")) {
        return fail("knobs missing required keys");
    }

    const int n_cells = int(knobs["n_cells"]);
    if (n_cells <= 0) return fail("n_cells <= 0");
    const bool refresh_convergence = knobs.has("refresh_convergence")
        ? bool(knobs["refresh_convergence"]) : false;

    const bool weather_transition_enabled = bool(knobs.get("weather_transition_enabled", false));
    float transition_rate = float(knobs.get("weather_transition_alpha_rate", 1.0));
    if (transition_rate < 0.0f) transition_rate = 0.0f;
    else if (transition_rate > 1.0f) transition_rate = 1.0f;
    // [dt-aware transition 2026-06-28] 见 run_weather_field_solve_pass 同名注释：过渡按游戏天数推进，避免加速档吞短暂天气。
    float transition_dt_days = float(knobs.get("weather_transition_dt_days", 1.0));
    if (transition_dt_days < 0.0f) transition_dt_days = 0.0f;
    else if (transition_dt_days > 30.0f) transition_dt_days = 30.0f;
    const int lut_w = int(knobs.get("weather_lut_w", 0));
    const int lut_h = int(knobs.get("weather_lut_h", 0));
    const int lut_slots = (lut_w > 0 && lut_h > 0 && lut_w * lut_h >= n_cells) ? (lut_w * lut_h) : n_cells;

    PackedInt32Array nb_arr = knobs["neighbor_indices"];

    PackedFloat32Array prev_vapor_arr = knobs["prev_vapor"];
    PackedFloat32Array out_vapor_arr = knobs["out_vapor"];
    PackedFloat32Array out_cloud_arr = knobs["out_cloud"];
    PackedFloat32Array out_cloud_water_arr;
    PackedFloat32Array out_precip_arr = knobs["out_precip"];
    PackedFloat32Array out_instability_arr = knobs["out_instability"];
    PackedFloat32Array out_intensity_arr = knobs["out_intensity"];
    PackedFloat32Array out_convergence_arr = knobs["out_convergence"];
    PackedInt32Array out_type_arr = knobs["out_type"];
    if (knobs.has("out_cloud_water")) {
        out_cloud_water_arr = knobs["out_cloud_water"];
    }

    if (nb_arr.size() < n_cells * 6) return fail("neighbor_indices size < n_cells * 6");
    if (prev_vapor_arr.size() != n_cells ||
        out_vapor_arr.size() != n_cells ||
        out_cloud_arr.size() != n_cells ||
        out_precip_arr.size() != n_cells ||
        out_instability_arr.size() != n_cells ||
        out_intensity_arr.size() != n_cells ||
        out_convergence_arr.size() != n_cells ||
        out_type_arr.size() != n_cells) {
        return fail("packed output size mismatch");
    }
    if (out_cloud_water_arr.size() != 0 && out_cloud_water_arr.size() != n_cells) {
        return fail("out_cloud_water size mismatch");
    }

    const int sid_w_intens = component_id(StringName("cell_weather_intensity"));
    const int sid_w_cloud = component_id(StringName("cell_weather_cloud"));
    const int sid_w_cloud_water = component_id(StringName("cell_weather_cloud_water"));
    const int sid_w_precip = component_id(StringName("cell_weather_precip"));
    const int sid_w_type = component_id(StringName("cell_weather_type"));
    const int sid_w_prev_type = component_id(StringName("cell_weather_prev_type"));
    const int sid_w_target_type = component_id(StringName("cell_weather_target_type"));
    const int sid_w_transition_alpha = component_id(StringName("cell_weather_transition_alpha"));
    const int sid_w_vapor = component_id(StringName("cell_weather_vapor"));
    const int sid_w_conv = component_id(StringName("cell_weather_convergence"));
    const int sid_w_inst = component_id(StringName("cell_weather_instability"));
    const int sid_w_finit = component_id(StringName("cell_weather_field_init"));
    const int sid_w_dirty = component_id(StringName("cell_weather_dirty"));

    if (sid_w_intens < 0 || sid_w_cloud < 0 || sid_w_precip < 0 ||
        sid_w_type < 0 || sid_w_vapor < 0 || sid_w_conv < 0 ||
        sid_w_inst < 0 || sid_w_finit < 0 || sid_w_dirty < 0) {
        return fail("missing required weather slot id");
    }

    Slot &s_wint = _slots.write[sid_w_intens];
    Slot &s_wcld = _slots.write[sid_w_cloud];
    Slot *s_wcw = (sid_w_cloud_water >= 0) ? &_slots.write[sid_w_cloud_water] : nullptr;
    Slot &s_wpre = _slots.write[sid_w_precip];
    Slot &s_wtyp = _slots.write[sid_w_type];
    Slot *s_wprev = (sid_w_prev_type >= 0) ? &_slots.write[sid_w_prev_type] : nullptr;
    Slot *s_wtarget = (sid_w_target_type >= 0) ? &_slots.write[sid_w_target_type] : nullptr;
    Slot *s_walpha = (sid_w_transition_alpha >= 0) ? &_slots.write[sid_w_transition_alpha] : nullptr;
    Slot &s_wvap = _slots.write[sid_w_vapor];
    Slot &s_wcnv = _slots.write[sid_w_conv];
    Slot &s_wins = _slots.write[sid_w_inst];
    Slot &s_wfin = _slots.write[sid_w_finit];
    Slot &s_wdirty = _slots.write[sid_w_dirty];

    if (s_wint.arr_f32.size() != n_cells || s_wcld.arr_f32.size() != n_cells ||
        s_wpre.arr_f32.size() != n_cells || s_wtyp.arr_u8.size() != n_cells ||
        s_wvap.arr_f32.size() != n_cells || s_wcnv.arr_f32.size() != n_cells ||
        s_wins.arr_f32.size() != n_cells || s_wfin.arr_u8.size() != n_cells ||
        s_wdirty.arr_u8.size() != n_cells) {
        return fail("slot array size mismatch");
    }
    if (s_wcw != nullptr && s_wcw->arr_f32.size() != n_cells) {
        return fail("cloud_water slot size mismatch");
    }
    if (weather_transition_enabled &&
        (s_wprev == nullptr || s_wtarget == nullptr || s_walpha == nullptr)) {
        return fail("weather transition slot size mismatch");
    }
    if (s_wprev != nullptr && s_wprev->arr_u8.size() != n_cells) {
        return fail("weather prev_type slot size mismatch");
    }
    if (s_wtarget != nullptr && s_wtarget->arr_u8.size() != n_cells) {
        return fail("weather target_type slot size mismatch");
    }
    if (s_walpha != nullptr && s_walpha->arr_f32.size() != n_cells) {
        return fail("weather transition_alpha slot size mismatch");
    }

    const int32_t * const __restrict NB = nb_arr.ptr();
    const float * const __restrict PREV_VAP = prev_vapor_arr.ptr();
    const float * const __restrict NEXT_VAP = out_vapor_arr.ptr();
    const float * const __restrict NEXT_CLD = out_cloud_arr.ptr();
    const float * const __restrict NEXT_CW =
        (out_cloud_water_arr.size() == n_cells) ? out_cloud_water_arr.ptr() : nullptr;
    const float * const __restrict NEXT_PRE = out_precip_arr.ptr();
    const float * const __restrict NEXT_INS = out_instability_arr.ptr();
    const float * const __restrict NEXT_INT = out_intensity_arr.ptr();
    const float * const __restrict NEXT_CNV = out_convergence_arr.ptr();
    const int32_t * const __restrict NEXT_TYP = out_type_arr.ptr();

    PackedByteArray weather_lut;
    weather_lut.resize(lut_slots * 4);
    uint8_t * const __restrict WX = weather_lut.ptrw();
    auto q01_byte_commit = [](float v) -> uint8_t {
        if (v <= 0.0f) return uint8_t(0);
        if (v >= 1.0f) return uint8_t(255);
        return uint8_t(std::clamp(int(std::round(double(v) * 255.0)), 0, 255));
    };

    float * const __restrict W_INT = s_wint.arr_f32.ptrw();

    float * const __restrict W_CLD = s_wcld.arr_f32.ptrw();
    float * const __restrict W_CW = (s_wcw != nullptr) ? s_wcw->arr_f32.ptrw() : nullptr;
    float * const __restrict W_PRE = s_wpre.arr_f32.ptrw();
    uint8_t * const __restrict W_TYP = s_wtyp.arr_u8.ptrw();
    uint8_t * const __restrict W_PREV = (s_wprev != nullptr) ? s_wprev->arr_u8.ptrw() : nullptr;
    uint8_t * const __restrict W_TARGET = (s_wtarget != nullptr) ? s_wtarget->arr_u8.ptrw() : nullptr;
    float * const __restrict W_ALPHA = (s_walpha != nullptr) ? s_walpha->arr_f32.ptrw() : nullptr;
    float * const __restrict W_VAP = s_wvap.arr_f32.ptrw();
    float * const __restrict W_CNV = s_wcnv.arr_f32.ptrw();
    float * const __restrict W_INS = s_wins.arr_f32.ptrw();
    uint8_t * const __restrict W_FIN = s_wfin.arr_u8.ptrw();
    uint8_t * const __restrict W_DIRTY = s_wdirty.arr_u8.ptrw();

    auto t0 = std::chrono::high_resolution_clock::now();

    // S3 P3：计算体已提取为 pk_async_climate::weather_commit_pure，worker 走同一份。
    PackedFloat32Array convergence_deltas;
    if (refresh_convergence) {
        convergence_deltas.resize(n_cells);
    }

    pk_async_climate::WeatherCommitKnobs wck;
    wck.n_cells                    = n_cells;
    wck.refresh_convergence        = refresh_convergence;
    wck.weather_transition_enabled = weather_transition_enabled;
    wck.transition_rate            = transition_rate;
    wck.transition_dt_days         = transition_dt_days;
    wck.lut_slots                  = lut_slots;

    pk_async_climate::WeatherCommitLanes wcl;
    wcl.next_vapor        = NEXT_VAP;
    wcl.next_cloud        = NEXT_CLD;
    wcl.next_cloud_water  = NEXT_CW;
    wcl.next_precip       = NEXT_PRE;
    wcl.next_instability  = NEXT_INS;
    wcl.next_intensity    = NEXT_INT;
    wcl.next_convergence  = NEXT_CNV;
    wcl.next_type         = NEXT_TYP;
    wcl.prev_vapor        = PREV_VAP;
    wcl.neighbor_indices  = NB;
    wcl.intensity         = W_INT;
    wcl.cloud             = W_CLD;
    wcl.cloud_water       = W_CW;
    wcl.precip            = W_PRE;
    wcl.vapor             = W_VAP;
    wcl.convergence       = W_CNV;
    wcl.instability       = W_INS;
    wcl.type              = W_TYP;
    wcl.prev_type         = W_PREV;
    wcl.target_type       = W_TARGET;
    wcl.transition_alpha  = W_ALPHA;
    wcl.field_init        = W_FIN;
    wcl.dirty             = W_DIRTY;
    wcl.lut               = WX;
    wcl.convergence_deltas = refresh_convergence ? convergence_deltas.ptrw() : nullptr;

    pk_async_climate::WeatherCommitStats wcs;
    pk_async_climate::weather_commit_pure(wck, wcl, wcs);
    const int dirty_count = wcs.dirty_count;
    const int convergence_dirty_count = wcs.convergence_dirty_count;
    const double water_budget_error_acc = wcs.water_budget_error_sum;

    _flush_slot_to_map(sid_w_intens);
    _flush_slot_to_map(sid_w_cloud);
    if (sid_w_cloud_water >= 0) _flush_slot_to_map(sid_w_cloud_water);
    _flush_slot_to_map(sid_w_precip);
    _flush_slot_to_map(sid_w_type);
    if (sid_w_prev_type >= 0) _flush_slot_to_map(sid_w_prev_type);
    if (sid_w_target_type >= 0) _flush_slot_to_map(sid_w_target_type);
    if (sid_w_transition_alpha >= 0) _flush_slot_to_map(sid_w_transition_alpha);
    _flush_slot_to_map(sid_w_vapor);
    _flush_slot_to_map(sid_w_conv);
    _flush_slot_to_map(sid_w_inst);
    _flush_slot_to_map(sid_w_finit);
    _flush_slot_to_map(sid_w_dirty);

    auto t1 = std::chrono::high_resolution_clock::now();
    const double elapsed_ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
    out["elapsed_ms"] = elapsed_ms;
    out["commit_loop_ms"] = elapsed_ms;
    out["weather_dirty_count"] = dirty_count;
    out["weather_lut"] = weather_lut;
    out["weather_lut_changed"] = dirty_count > 0;
    out["weather_lut_dirty_count"] = dirty_count;
    out["weather_lut_full_rebuild"] = true;
    if (refresh_convergence && convergence_deltas.size() > convergence_dirty_count) {

        convergence_deltas.resize(convergence_dirty_count);
    }
    out["weather_convergence_dirty_count"] = convergence_dirty_count;
    out["weather_convergence_deltas"] = convergence_deltas;
    out["convergence_published"] = refresh_convergence;
    out["water_budget_error"] = water_budget_error_acc / double(std::max(n_cells, 1));
    out["active_weather_ratio"] = double(dirty_count) / double(std::max(n_cells, 1));
    return out;
}

#include "world_ext_weather_section_front_lifecycle.inc"

// ─── plan/weather-refresh-cpp-all: 顶层一体化 weather refresh pass ───────
//
// 串调 5 段：① field_solve ② distribute ③ summary ④ cyclone_wake ⑤ stage_b
// 任一段失败立即短路返回 { rc:-1, fail_stage:"..." }，caller 走 GDScript fallback。
//
// 子 pass 返回类型不齐：
//   field_solve / stage_b → double (ms; <0 表 fallback)
//   distribute / summary  → Dictionary { elapsed_ms, ... }
// 顶层 pass 统一抽 ms 字段写到 breakdown。
Dictionary DCWorldExt::run_weather_refresh_daily_pass(const Dictionary &knobs) {
    Dictionary br;
    auto t_top0 = std::chrono::high_resolution_clock::now();

    auto fail = [&](const char *stage) -> Dictionary {
        br["rc"] = -1;
        br["fail_stage"] = String(stage);
        auto t_e = std::chrono::high_resolution_clock::now();
        br["total_ms"] = std::chrono::duration<double, std::milli>(t_e - t_top0).count();
        return br;
    };

    // ① field solve（返回 double ms；<0 即失败）
    const double field_ms = run_weather_field_solve_pass(knobs);
    if (field_ms < 0.0) return fail("field_solve");
    br["advance_ms"] = field_ms;

    // ①b visible commit / publish
    //
    // `run_weather_field_solve_pass` has two modes:
    // - without out_* buffers it writes weather slots directly and flushes them;
    // - with out_* buffers it writes the staged next-state arrays only.
    //
    // The combined/native-daily weather facade always uses the staged form built
    // by WeatherSystem.begin_weather_field_solve(). Distribute, summary, and
    // stage-b read weather slots, so running them before this commit leaves the
    // visible field at the previous value (or all-zero on cold start) while the
    // cadence counters still advance.
    if (knobs.has("out_vapor") && knobs.has("out_cloud") &&
        knobs.has("out_precip") && knobs.has("out_instability") &&
        knobs.has("out_intensity") && knobs.has("out_convergence") &&
        knobs.has("out_type")) {
        Dictionary commit = run_weather_field_commit_pass(knobs);
        const double commit_ms = double(commit.get("elapsed_ms", -1.0));
        if (commit_ms < 0.0) return fail("field_commit");
        br["field_commit_total_ms"] = commit_ms;
        br["field_commit_loop_ms"] = double(commit.get("commit_loop_ms", commit_ms));
        br["field_commit_path"] = commit.get("path", String("gdext_commit"));
        br["field_commit_publish_verified"] = true;
        br["field_commit_publish_repaired"] = false;
        br["field_commit_init_count"] = int(knobs.get("n_cells", 0));
        br["field_commit_publish_reason"] = String("ok_native_combined_commit");
        br["weather_dirty_count"] = int(commit.get("weather_dirty_count", 0));
        br["water_budget_error"] = double(commit.get("water_budget_error", 0.0));
        br["active_weather_ratio"] = double(commit.get("active_weather_ratio", 0.0));
        br["weather_convergence_dirty_count"] = int(commit.get("weather_convergence_dirty_count", 0));
        br["weather_convergence_deltas"] = commit.get("weather_convergence_deltas", PackedFloat32Array());
        br["convergence_published"] = bool(commit.get("convergence_published", false));
        br["weather_lut"] = commit.get("weather_lut", PackedByteArray());
        br["weather_lut_changed"] = bool(commit.get("weather_lut_changed", false));
        br["weather_lut_dirty_count"] = int(commit.get("weather_lut_dirty_count", 0));
        br["weather_lut_full_rebuild"] = bool(commit.get("weather_lut_full_rebuild", false));

    } else {
        br["field_commit_path"] = String("direct_solve_publish");
        br["field_commit_publish_verified"] = true;
        br["field_commit_publish_repaired"] = false;
        br["field_commit_init_count"] = int(knobs.get("n_cells", 0));
        br["field_commit_publish_reason"] = String("ok_direct_solve_publish");
    }

    // ② distribute（返回 Dictionary { elapsed_ms, cover_dirty }）
    const Dictionary r_dist = run_weather_distribute_pass(knobs);
    const double dist_ms = double(r_dist.get("elapsed_ms", -1.0));
    if (dist_ms < 0.0) return fail("distribute");
    br["distribute_ms"] = dist_ms;
    br["cover_dirty"]   = r_dist.get("cover_dirty", false);

    // ③ summary fronts（返回 Dictionary { elapsed_ms, fronts: Array[Dictionary] }）
    const Dictionary r_summary = run_weather_summary_fronts_pass(knobs);
    const double summary_ms = double(r_summary.get("elapsed_ms", -1.0));
    if (summary_ms < 0.0) return fail("summary");
    const Array fronts_arr = r_summary.get("fronts", Array());
    br["summary_ms"]   = summary_ms;
    br["fronts_count"] = fronts_arr.size();
    br["fronts"]       = fronts_arr;
    int cold_front_count = 0;
    int warm_front_count = 0;
    for (int i = 0; i < fronts_arr.size(); ++i) {
        const Variant v = fronts_arr[i];
        if (v.get_type() != Variant::DICTIONARY) continue;
        const Dictionary fd = v;
        const int diag_kind = int(fd.get("front_diagnostic_kind", 0));
        if (diag_kind == 1) {
            ++cold_front_count;
        } else if (diag_kind == 2) {
            ++warm_front_count;
        }
    }
    br["weather_cold_front_count"] = cold_front_count;
    br["weather_warm_front_count"] = warm_front_count;

    // ④ cyclone wake（私有 step；只产 ms，副作用维护 _cyclone_perturbations）
    //
    // Phase B.2 细粒度遥测：by-value 复制 knobs 给 cyclone_wake_step（与
    // stage_b_pass 同模式），让它写回 6 个字段：phase1/phase2 ms + 4 个 n_*
    // 计数。caller 提取到 br，map_generator._dump_weather_breakdown_if_slow
    // 触发时可立即定位是衰减循环 vs 注入循环、是大量 evict vs 大量 replace。
    Dictionary cyclone_knobs = knobs;
    const double cyclone_ms = cyclone_wake_step(cyclone_knobs, fronts_arr);
    br["cyclone_ms"] = cyclone_ms;
    br["cyclone_phase1_decay_ms"]  = cyclone_knobs.get("cyclone_phase1_decay_ms",  0.0);
    br["cyclone_phase2_inject_ms"] = cyclone_knobs.get("cyclone_phase2_inject_ms", 0.0);
    br["cyclone_n_decayed"]  = cyclone_knobs.get("cyclone_n_decayed",  0);
    br["cyclone_n_evicted"]  = cyclone_knobs.get("cyclone_n_evicted",  0);
    br["cyclone_n_replaced"] = cyclone_knobs.get("cyclone_n_replaced", 0);
    br["cyclone_n_injected"] = cyclone_knobs.get("cyclone_n_injected", 0);
    br["cyclone_pool_size"]  = int(_cyclone_perturbations.size());

    // ⑤ stage_b（返回 double ms 合计；<0 即失败）。
    // 注：stage_b_pass sig 是 by-value Dictionary（会写回 succession_indices/
    // succession_to_veg/stat_succession_count + 单段 albedo_ms/veg_dyn_ms/
    // feedback_ms）。我们 by-value 复制一份让它写回到 local 副本，再把回写
    // 字段合并到 br。
    Dictionary stage_b_knobs = knobs; // shallow copy；godot Dictionary 写回会
                                       // 在 shared backing 上发生（refcount），
                                       // 这里复制 Variant header 即可。
    const double stage_b_ms = run_stage_b_pass(stage_b_knobs);
    if (stage_b_ms < 0.0) return fail("stage_b");
    br["stage_b_ms"]   = stage_b_ms;
    br["albedo_ms"]    = stage_b_knobs.get("albedo_ms",   0.0);
    br["veg_dyn_ms"]   = stage_b_knobs.get("veg_dyn_ms",  0.0);
    br["feedback_ms"]  = stage_b_knobs.get("feedback_ms", 0.0);
    const int stage_b_call_index = int(stage_b_knobs.get("stage_b_call_index", -1));
    br["stage_b_call_index"] = stage_b_call_index;
    br["albedo_ran"] = bool(stage_b_knobs.get("run_albedo", false));
    br["veg_dyn_ran"] = bool(stage_b_knobs.get("run_veg_dyn", false));
    br["feedback_ran"] = bool(stage_b_knobs.get("run_feedback", false));
    br["stage_b_combined_done"] = true;
    br["stage_b_ext_ok"] = true;
    br["stage_b_total_runs"] = stage_b_call_index >= 0 ? stage_b_call_index + 1 : 0;
    if (stage_b_knobs.has("succession_indices")) {
        br["succession_indices"]    = stage_b_knobs["succession_indices"];
        br["succession_to_veg"]     = stage_b_knobs["succession_to_veg"];
        br["stat_succession_count"] = stage_b_knobs.get("stat_succession_count", 0);
    }

    // 顶层 total
    auto t_top1 = std::chrono::high_resolution_clock::now();
    const double total_ms = std::chrono::duration<double, std::milli>(t_top1 - t_top0).count();
    br["weather_tick_ms"] = total_ms;
    br["total_ms"]        = total_ms;
    br["rc"]              = 0;
    return br;
}

} // namespace pk
