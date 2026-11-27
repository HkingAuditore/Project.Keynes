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
// S3：Climate pass POD buffer + 9 个纯内核的共享定义。
#include "runtime_climate_passes.h"

namespace pk {

using namespace godot;
#include "world_ext_climate_surface_section_water_balance.inc"

// ─── DOTS-Final-Push 任务 2：run_albedo_pass ────────────────────────────
//
// 1:1 mirror of scripts/geography/map_generator.gd::_apply_albedo_pass.
// 算法极简：陆地 cell 上 dt = (ref_alb - alb) * gain，alb 受 SNOW/GLACIER
// cover 上限钳制为 0.75。无邻居访问，无 snapshot —— 单 cell 独立计算。
//
// 与 climate_pass_b 共享 cell_is_water / cell_vegetation 两个 SoA 槽位，
// 同套 albedo_table（按 VegetationType.VEG enum 顺序的 PackedFloat32Array）。
// climate_pass_b 用的是 foliage_table，本 pass 用的是 albedo_table —— 两表
// 在 GDScript caller 端各自缓存，C++ 不做合表。
double DCWorldExt::run_albedo_pass(const Dictionary &knobs) {
    using godot::StringName;
    using godot::PackedFloat32Array;

    auto diag = [&](const char *why) {
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_albedo_pass: ", why,
            " — fallback to GDScript");
    };

    if (!_bound) { diag("not _bound"); return -1.0; }

    // ─── Resolve slot ids ───────────────────────────────────────────────
    const int sid_iswater = component_id(StringName("cell_is_water"));
    const int sid_veg     = component_id(StringName("cell_vegetation"));
    const int sid_cover   = component_id(StringName("cell_cover"));
    const int sid_temp    = component_id(StringName("cell_temp"));
    if (sid_iswater < 0 || sid_veg < 0 || sid_cover < 0 || sid_temp < 0) {
        diag("missing slot id (cell_is_water/vegetation/cover/temp)");
        return -1.0;
    }

    // ─── Pull scalars from knobs ────────────────────────────────────────
    if (!knobs.has("n_cells") || !knobs.has("reference_albedo") ||
        !knobs.has("albedo_temp_gain") || !knobs.has("albedo_table")) {
        diag("knobs missing required keys (n_cells / reference_albedo / albedo_temp_gain / albedo_table)");
        return -1.0;
    }
    const int n_cells = int(knobs["n_cells"]);
    if (n_cells <= 0) { diag("n_cells <= 0"); return -1.0; }
    const float reference_albedo = float(knobs["reference_albedo"]);
    const float albedo_temp_gain = float(knobs["albedo_temp_gain"]);
    const float snow_cover_albedo = float(knobs.get("snow_cover_albedo", 0.75f));
    // CoverType.CV.SNOW = 1, CV.GLACIER = 2 (cover_type.gd:16-24)
    const uint8_t cover_snow_id    = uint8_t(int(knobs.get("cover_snow_id", 1)));
    const uint8_t cover_glacier_id = uint8_t(int(knobs.get("cover_glacier_id", 2)));

    // ─── Pull albedo_table ──────────────────────────────────────────────
    PackedFloat32Array albedo_arr = knobs["albedo_table"];
    const int albedo_size = albedo_arr.size();
    if (albedo_size <= 0) { diag("albedo_table empty"); return -1.0; }

    // ─── Acquire slot arrays + validate sizes ───────────────────────────
    Slot &s_iswater = _slots.write[sid_iswater];
    Slot &s_veg     = _slots.write[sid_veg];
    Slot &s_cover   = _slots.write[sid_cover];
    Slot &s_temp    = _slots.write[sid_temp];
    if (s_iswater.arr_u8.size() != n_cells ||
        s_veg.arr_u8.size()     != n_cells ||
        s_cover.arr_u8.size()   != n_cells ||
        s_temp.arr_f32.size()   != n_cells) {
        diag("slot array size mismatch (re-bind needed?)");
        return -1.0;
    }

    const uint8_t * const __restrict IW    = s_iswater.arr_u8.ptr();
    const uint8_t * const __restrict VG    = s_veg.arr_u8.ptr();
    const uint8_t * const __restrict CV    = s_cover.arr_u8.ptr();
    float         * const __restrict T     = s_temp.arr_f32.ptrw();
    const float   * const __restrict ALB   = albedo_arr.ptr();

    auto t0 = std::chrono::high_resolution_clock::now();

    // ─── Main loop ──────────────────────────────────────────────────────
    // S3：主循环已下沉到 pk_async_climate::albedo_apply_pure。worker 侧调的是同一个
    // 函数，所以这一段不再有第二份实现可分叉。
    pk_async_climate::ClimateAlbedoKnobs alb_knobs;
    alb_knobs.ran = true;
    alb_knobs.reference_albedo = reference_albedo;
    alb_knobs.temp_gain = albedo_temp_gain;
    alb_knobs.snow_cover_albedo = snow_cover_albedo;
    alb_knobs.cover_snow_id = cover_snow_id;
    alb_knobs.cover_glacier_id = cover_glacier_id;
    pk_async_climate::albedo_apply_pure(alb_knobs, IW, VG, CV, ALB,
                                        albedo_size, T, n_cells);

    // 这一天生产确实跑了 albedo，且用的就是这组标量。reference publish 会把它挂到
    // trace 帧上，worker 据此在同一批天里跑同一段。留空 = 生产没跑 → worker 也不跑。
    _production_albedo = alb_knobs;
    _production_stage_mask |= pk_async_climate::CLIMATE_STAGE_BIT_ALBEDO;

    // §11.2 flush: push CoW-detached cell_temp back to MapData
    _flush_slot_to_map(sid_temp);

    auto t1 = std::chrono::high_resolution_clock::now();
    return std::chrono::duration<double, std::milli>(t1 - t0).count();
}


// ─── DOTS-Final-Push 任务 3：run_vegetation_dynamics_pass ────────────────
//
// 1:1 mirror of scripts/geography/map_generator.gd::_apply_vegetation_dynamics
// 主循环（含 vitality / streak 更新）；演替触发本身（写 cell.vegetation /
// base_vegetation / current_state）由 GDScript 后处理（与 sea_ice flip_lists
// 同模式），C++ 仅输出 succession_indices + succession_to_veg。
//
// vitality / low_streak / high_streak 当前未在 SoA schema 中（仍是 HexCell
// 私有字段），所以走 knobs in/out PackedArray 模式：caller pack 进入 → C++
// 写回 → caller unpack 回 cell。N=2400 时 6 个 PackedArray 一进一出的总开销
// 约 0.05ms，远小于跑算法的 ~9ms。

// S3：vegdyn_clamp01 / plant_water / compat_of / best_transition / weather_stress
// 五个 helper 与整段主循环已下沉到 runtime_climate_passes.cpp 的
// pk_async_climate::vegetation_dynamics_apply_pure，生产与 SHADOW worker 共用一份。

double DCWorldExt::run_vegetation_dynamics_pass(Dictionary knobs) {
    using godot::StringName;
    using godot::PackedFloat32Array;
    using godot::PackedInt32Array;
    using godot::PackedByteArray;

    auto diag = [&](const char *why) {
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_vegetation_dynamics_pass: ", why,
            " — fallback to GDScript");
    };

    if (!_bound) { diag("not _bound"); return -1.0; }

    // ─── Resolve slot ids ───────────────────────────────────────────────
    const int sid_iswater  = component_id(StringName("cell_is_water"));
    const int sid_terrain  = component_id(StringName("cell_terrain"));
    const int sid_landform = component_id(StringName("cell_landform"));
    const int sid_veg      = component_id(StringName("cell_vegetation"));
    const int sid_temp     = component_id(StringName("cell_temp"));
    const int sid_temp_30d = component_id(StringName("cell_temp_30d"));
    const int sid_moist    = component_id(StringName("cell_moisture"));
    const int sid_water_bal = component_id(StringName("cell_water_balance_30d"));
    const int sid_plant_water = component_id(StringName("cell_plant_available_water"));
    const int sid_soil     = component_id(StringName("cell_soil_moisture"));
    const int sid_vgp      = component_id(StringName("cell_vegetation_growth_pressure"));
    const int sid_wt_type  = component_id(StringName("cell_weather_type"));
    const int sid_wt_int   = component_id(StringName("cell_weather_intensity"));
    const int sid_wt_init  = component_id(StringName("cell_weather_field_init"));
    if (sid_iswater < 0 || sid_terrain < 0 || sid_landform < 0 || sid_veg < 0 || sid_temp < 0 || sid_temp_30d < 0 ||
        sid_moist < 0 || sid_water_bal < 0 || sid_soil < 0 || sid_plant_water < 0 || sid_vgp < 0 ||
        sid_wt_type < 0 || sid_wt_int < 0 || sid_wt_init < 0) {
        diag("missing slot id (cell_is_water/terrain/landform/vegetation/temp/moisture/weather_type/weather_intensity/weather_field_init)");
        return -1.0;
    }

    // ─── Pull scalars ───────────────────────────────────────────────────
static const char *required_scalars[] = {
        "n_cells", "day_scale", "streak_days",
        "vitality_change_rate", "compat_harshness",
        "plant_water_balance_weight", "plant_soil_buffer_weight",
        "plant_drought_penalty", "succession_min_compat_gain",
        "low_threshold", "high_threshold",
        "succession_degrade_days", "succession_upgrade_days",
        "n_wt", "wt_clear_id", "veg_none_id",
    };
    for (const char *k : required_scalars) {
        if (!knobs.has(k)) { diag("knobs missing required scalar key"); return -1.0; }
    }
    const int   n_cells       = int(knobs["n_cells"]);
    if (n_cells <= 0) { diag("n_cells <= 0"); return -1.0; }
    const float day_scale_raw = float(knobs["day_scale"]);
    const float scale         = day_scale_raw < 1.0f ? 1.0f : day_scale_raw;
    const int   streak_days   = int(knobs["streak_days"]);
    const float rate          = float(knobs["vitality_change_rate"]);
    const float harshness     = float(knobs["compat_harshness"]);
    const float low_thresh    = float(knobs["low_threshold"]);
    const float high_thresh   = float(knobs["high_threshold"]);
    const int   degrade_days  = int(knobs["succession_degrade_days"]);
    const int   upgrade_days  = int(knobs["succession_upgrade_days"]);
    const int   n_wt          = int(knobs["n_wt"]);
    const int   wt_clear_id   = int(knobs["wt_clear_id"]);
    const uint8_t veg_none_id = uint8_t(int(knobs["veg_none_id"]));
    const float weather_penalty_scale = knobs.has("weather_penalty_scale") ? float(knobs["weather_penalty_scale"]) : 1.0f;
    const float plant_water_balance_weight = float(knobs["plant_water_balance_weight"]);
    const float plant_soil_buffer_weight = float(knobs["plant_soil_buffer_weight"]);
    const float plant_drought_penalty = float(knobs["plant_drought_penalty"]);
    const float succession_min_compat_gain = float(knobs["succession_min_compat_gain"]);
    const float low_vitality_damping_threshold = knobs.has("vegetation_low_vitality_damping_threshold")
                                               ? float(knobs["vegetation_low_vitality_damping_threshold"]) : 0.40f;
    const int   succession_cooldown_days = knobs.has("vegetation_succession_cooldown_days")
                                         ? int(knobs["vegetation_succession_cooldown_days"]) : 30;
    if (n_wt <= 0) { diag("n_wt <= 0"); return -1.0; }

    // ─── Pull tables ────────────────────────────────────────────────────
    static const char *required_tables[] = {
        "ideal_temp_table", "ideal_moist_table",
        "temp_tol_table", "moist_tol_table",
        "weather_penalty_table", "resistance_table",
        "next_up_table", "next_down_table",
        "vitality_arr", "low_streak_arr", "high_streak_arr",
    };
    for (const char *k : required_tables) {
        if (!knobs.has(k)) { diag("knobs missing required table key"); return -1.0; }
    }
    PackedFloat32Array ideal_t_arr   = knobs["ideal_temp_table"];
    PackedFloat32Array ideal_m_arr   = knobs["ideal_moist_table"];
    PackedFloat32Array tol_t_arr     = knobs["temp_tol_table"];
    PackedFloat32Array tol_m_arr     = knobs["moist_tol_table"];
    PackedFloat32Array wt_pen_arr    = knobs["weather_penalty_table"];
    PackedFloat32Array resist_arr    = knobs["resistance_table"];
    PackedByteArray    next_up_arr   = knobs["next_up_table"];
    PackedByteArray    next_down_arr = knobs["next_down_table"];
    PackedFloat32Array vitality_arr  = knobs["vitality_arr"];
    PackedInt32Array   low_streak    = knobs["low_streak_arr"];
    PackedInt32Array   high_streak   = knobs["high_streak_arr"];

    const int n_veg = ideal_t_arr.size();
    if (n_veg <= 0) { diag("ideal_temp_table empty"); return -1.0; }
    if (ideal_m_arr.size() != n_veg || tol_t_arr.size() != n_veg ||
        tol_m_arr.size() != n_veg || next_up_arr.size() != n_veg ||
        next_down_arr.size() != n_veg) {
        diag("VEG-indexed table size mismatch");
        return -1.0;
    }
    if (wt_pen_arr.size() < n_wt) { diag("weather_penalty_table size < n_wt"); return -1.0; }
    if (resist_arr.size() != n_veg * n_wt) {
        diag("resistance_table size != n_veg * n_wt");
        return -1.0;
    }
    if (vitality_arr.size() != n_cells || low_streak.size() != n_cells ||
        high_streak.size() != n_cells) {
        diag("vitality/streak in/out array size mismatch");
        return -1.0;
    }

    // ─── Acquire slot arrays + validate sizes ───────────────────────────
    Slot &s_iswater = _slots.write[sid_iswater];
    Slot &s_terrain = _slots.write[sid_terrain];
    Slot &s_landform = _slots.write[sid_landform];
    Slot &s_veg     = _slots.write[sid_veg];
    Slot &s_temp    = _slots.write[sid_temp];
    Slot &s_temp30  = _slots.write[sid_temp_30d];
    Slot &s_moist   = _slots.write[sid_moist];
    Slot &s_wb      = _slots.write[sid_water_bal];
    Slot &s_soil    = _slots.write[sid_soil];
    Slot &s_plant_water = _slots.write[sid_plant_water];
    Slot &s_vgp     = _slots.write[sid_vgp];
    Slot &s_wt_type = _slots.write[sid_wt_type];
    Slot &s_wt_int  = _slots.write[sid_wt_int];
    Slot &s_wt_init = _slots.write[sid_wt_init];
    if (s_iswater.arr_u8.size() != n_cells || s_terrain.arr_u8.size() != n_cells ||
        s_landform.arr_u8.size() != n_cells || s_veg.arr_u8.size()     != n_cells ||
        s_temp.arr_f32.size()   != n_cells || s_temp30.arr_f32.size() != n_cells ||
        s_moist.arr_f32.size()  != n_cells || s_wb.arr_f32.size()     != n_cells ||
        s_soil.arr_f32.size()   != n_cells || s_plant_water.arr_f32.size() != n_cells ||
        s_vgp.arr_f32.size()    != n_cells ||
        s_wt_type.arr_u8.size() != n_cells || s_wt_int.arr_f32.size() != n_cells ||
        s_wt_init.arr_u8.size() != n_cells) {
        diag("slot array size mismatch (re-bind needed?)");
        return -1.0;
    }

    const uint8_t * const __restrict IW   = s_iswater.arr_u8.ptr();
    const uint8_t * const __restrict TERR = s_terrain.arr_u8.ptr();
    const uint8_t * const __restrict LF   = s_landform.arr_u8.ptr();
    const uint8_t * const __restrict VG   = s_veg.arr_u8.ptr();
    const float   * const __restrict T    = s_temp.arr_f32.ptr();
    (void)T;
    const float   * const __restrict T30  = s_temp30.arr_f32.ptr();
    const float   * const __restrict M    = s_moist.arr_f32.ptr();
    const float   * const __restrict WBAL = s_wb.arr_f32.ptr();
    const float   * const __restrict SOILC = s_soil.arr_f32.ptr();
    float         * const __restrict PLANT_WATER = s_plant_water.arr_f32.ptrw();
    float         * const __restrict VGP  = s_vgp.arr_f32.ptrw();
    const uint8_t * const __restrict WTT  = s_wt_type.arr_u8.ptr();
    const float   * const __restrict WTI  = s_wt_int.arr_f32.ptr();
    const uint8_t * const __restrict WTIN = s_wt_init.arr_u8.ptr();
    const float   * const __restrict IDT  = ideal_t_arr.ptr();
    const float   * const __restrict IDM  = ideal_m_arr.ptr();
    const float   * const __restrict TLT  = tol_t_arr.ptr();
    const float   * const __restrict TLM  = tol_m_arr.ptr();
    const float   * const __restrict WPN  = wt_pen_arr.ptr();
    const float   * const __restrict RES  = resist_arr.ptr();
    const uint8_t * const __restrict NXU  = next_up_arr.ptr();
    const uint8_t * const __restrict NXD  = next_down_arr.ptr();
    float   * const __restrict VIT  = vitality_arr.ptrw();
    int32_t * const __restrict LSK  = low_streak.ptrw();
    int32_t * const __restrict HSK  = high_streak.ptrw();

    auto t0 = std::chrono::high_resolution_clock::now();

    // S3：如实上报"生产这一天跑了 stage 9 VEGETATION_DYNAMICS"。见
    // _production_stage_mask 的注释。
    _production_stage_mask |= pk_async_climate::CLIMATE_STAGE_BIT_VEGETATION_DYNAMICS;

    // ─── Output candidate buffers (会大幅小于 n_cells，先 reserve 64) ────
    pk_async_climate::VegetationDynamicsEmit vd_emit;
    vd_emit.indices.reserve(64);
    vd_emit.to_veg.reserve(64);
    std::vector<int32_t> &succ_indices = vd_emit.indices;
    std::vector<uint8_t> &succ_to_veg  = vd_emit.to_veg;

    // ─── Main loop ────────────────────────────────────
    // S3：下沉到共享纯内核。原先这里、run_vegetation_dynamics_pass_thread、
    // run_stage_b_pass ② 段是三份逐字副本，漏同步任一份都会表现成分叉。
    pk_async_climate::VegetationDynamicsKnobs vd_knobs;
    vd_knobs.ran = true;
    vd_knobs.scale = scale;
    vd_knobs.streak_days = streak_days;
    vd_knobs.vitality_change_rate = rate;
    vd_knobs.compat_harshness = harshness;
    vd_knobs.low_threshold = low_thresh;
    vd_knobs.high_threshold = high_thresh;
    vd_knobs.succession_degrade_days = degrade_days;
    vd_knobs.succession_upgrade_days = upgrade_days;
    vd_knobs.n_wt = n_wt;
    vd_knobs.wt_clear_id = wt_clear_id;
    vd_knobs.veg_none_id = veg_none_id;
    vd_knobs.weather_penalty_scale = weather_penalty_scale;
    vd_knobs.plant_water_balance_weight = plant_water_balance_weight;
    vd_knobs.plant_soil_buffer_weight = plant_soil_buffer_weight;
    vd_knobs.plant_drought_penalty = plant_drought_penalty;
    vd_knobs.succession_min_compat_gain = succession_min_compat_gain;
    vd_knobs.low_vitality_damping_threshold = low_vitality_damping_threshold;
    vd_knobs.succession_cooldown_days = succession_cooldown_days;
    // 这条路径走 knobs 的 PackedArray 入口，没有 stress 四条 SoA lane。
    vd_knobs.stress_enabled = false;
    vd_knobs.n_veg = n_veg;
    vd_knobs.wt_pen_size = wt_pen_arr.size();

    pk_async_climate::VegetationDynamicsTables vd_tables;
    vd_tables.ideal_temp      = IDT;
    vd_tables.ideal_moist     = IDM;
    vd_tables.temp_tol        = TLT;
    vd_tables.moist_tol       = TLM;
    vd_tables.weather_penalty = WPN;
    vd_tables.resistance      = RES;
    vd_tables.next_up         = NXU;
    vd_tables.next_down       = NXD;

    pk_async_climate::VegetationDynamicsLanes vd_lanes;
    vd_lanes.is_water              = IW;
    vd_lanes.terrain               = TERR;
    vd_lanes.landform              = LF;
    vd_lanes.vegetation            = VG;
    vd_lanes.temp_30d              = T30;
    vd_lanes.moisture              = M;
    vd_lanes.water_balance_30d     = WBAL;
    vd_lanes.soil_moisture         = SOILC;
    vd_lanes.weather_type          = WTT;
    vd_lanes.weather_intensity     = WTI;
    vd_lanes.weather_field_init    = WTIN;
    vd_lanes.plant_available_water = PLANT_WATER;
    vd_lanes.vegetation_growth_pressure = VGP;
    vd_lanes.vitality              = VIT;
    vd_lanes.low_streak            = LSK;
    vd_lanes.high_streak           = HSK;

    record_production_vegetation_input(vd_knobs, vd_tables, vd_lanes, n_cells);
    pk_async_climate::vegetation_dynamics_apply_pure(
        vd_knobs, vd_tables, vd_lanes, 0, n_cells, vd_emit);
    // ─── Pack succession results back into knobs ────────────────────────
    PackedInt32Array out_indices;
    PackedByteArray  out_to_veg;
    const int n_succ = int(succ_indices.size());
    out_indices.resize(n_succ);
    out_to_veg.resize(n_succ);
    if (n_succ > 0) {
        std::memcpy(out_indices.ptrw(), succ_indices.data(), n_succ * sizeof(int32_t));
        std::memcpy(out_to_veg.ptrw(),  succ_to_veg.data(),  n_succ * sizeof(uint8_t));
    }
    knobs["succession_indices"] = out_indices;
    knobs["succession_to_veg"]  = out_to_veg;
    knobs["stat_succession_count"] = n_succ;
    if (n_succ > 0) {
        const int64_t tick = int64_t(knobs.get("tick", int64_t(knobs.get("day_idx", 0))));
        const int32_t phase = int32_t(knobs.get("event_phase", 0));
        _emit_succession_events(out_indices, out_to_veg, VG, s_veg.arr_u8.size(), tick, phase, 1);
    }

    // 写回 in/out arrays（CoW：caller 保留同一份引用，ptrw 已经写过了）
    knobs["vitality_arr"]   = vitality_arr;
    knobs["low_streak_arr"] = low_streak;
    knobs["high_streak_arr"]= high_streak;
    _flush_slot_to_map(sid_vgp);
    _flush_slot_to_map(sid_plant_water);

    auto t1 = std::chrono::high_resolution_clock::now();
    return std::chrono::duration<double, std::milli>(t1 - t0).count();
}

// ─── DOTS-Final-Push 任务 4：run_climate_feedback_pass ───────────────────
//
// 1:1 mirror of scripts/geography/map_generator.gd::_apply_weather_to_map_feedback_pass.
// 算法两段：
//   ① 长期 ocean→base_moisture 漂移（陆地 cell，邻水均值 anomaly 驱动）
//   ② 当日 weather→soil/veg_growth 累加（小权重，clamp ≤ per_day_clamp）
// 字段 soil_moisture / veg_growth_pressure 当前未在 SoA schema 中，走 in/out
// PackedArray 模式（与 vegetation_dynamics 的 vitality/streak 同模式）。
// base_moisture 已有 cell_base_moisture SoA，C++ 直读直写。
double DCWorldExt::run_climate_feedback_pass(Dictionary knobs) {
    SimTraceWriteGuard sim_trace_guard{this, "run_climate_feedback_pass"};
    using godot::StringName;
    using godot::PackedFloat32Array;
    using godot::PackedInt32Array;

    auto diag = [&](const char *why) {
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_climate_feedback_pass: ", why,
            " — fallback to GDScript");
    };

    if (!_bound) { diag("not _bound"); return -1.0; }

    // ─── Resolve slot ids ───────────────────────────────────────────────
    const int sid_iswater  = component_id(StringName("cell_is_water"));
    const int sid_wt_type  = component_id(StringName("cell_weather_type"));
    const int sid_wt_int   = component_id(StringName("cell_weather_intensity"));
    const int sid_wt_init  = component_id(StringName("cell_weather_field_init"));
    const int sid_base_m   = component_id(StringName("cell_base_moisture"));
    if (sid_iswater < 0 || sid_wt_type < 0 || sid_wt_int < 0 ||
        sid_wt_init < 0 || sid_base_m < 0) {
        diag("missing slot id (cell_is_water/weather_type/weather_intensity/weather_field_init/base_moisture)");
        return -1.0;
    }

    // ─── Pull scalars ───────────────────────────────────────────────────
    static const char *required_scalars[] = {
        "n_cells", "soil_gain", "veg_gain", "scale", "per_day_clamp",
        "ocean_drift_gain", "wt_clear_id",
        "wt_rain_id", "wt_storm_id", "wt_monsoon_id",
        "wt_blizzard_id", "wt_drought_id", "wt_heatwave_id",
    };
    for (const char *k : required_scalars) {
        if (!knobs.has(k)) { diag("knobs missing required scalar key"); return -1.0; }
    }
    const int   n_cells          = int(knobs["n_cells"]);
    if (n_cells <= 0) { diag("n_cells <= 0"); return -1.0; }
    const float soil_gain        = float(knobs["soil_gain"]);
    const float veg_gain         = float(knobs["veg_gain"]);
    const bool  write_weather_veg_pressure = bool(knobs.get("write_weather_veg_pressure", true));
    const float scale            = float(knobs["scale"]);
    const float per_day_clamp    = float(knobs["per_day_clamp"]);
    const float ocean_drift_gain = float(knobs["ocean_drift_gain"]);
    // 让天气流动(2026-06-21)：weather → base_moisture 反馈增益(optional; 缺省 0 = 关闭)。
    const float base_m_gain = float(knobs.has("weather_to_base_moisture_gain") ? double(knobs["weather_to_base_moisture_gain"]) : 0.0);
    const int   wt_rain_id       = int(knobs["wt_rain_id"]);
    const int   wt_storm_id      = int(knobs["wt_storm_id"]);
    const int   wt_monsoon_id    = int(knobs["wt_monsoon_id"]);
    const int   wt_blizzard_id   = int(knobs["wt_blizzard_id"]);
    const int   wt_drought_id    = int(knobs["wt_drought_id"]);
    const int   wt_heatwave_id   = int(knobs["wt_heatwave_id"]);

    // ─── Pull PackedArrays ──────────────────────────────────────────────
    if (!knobs.has("neighbor_indices") || !knobs.has("temp_transport_anomaly") ||
        !knobs.has("soil_moisture_arr") || !knobs.has("veg_growth_pressure_arr")) {
        diag("knobs missing required PackedArray key");
        return -1.0;
    }
    PackedInt32Array   nb_arr        = knobs["neighbor_indices"];
    PackedFloat32Array tta_arr       = knobs["temp_transport_anomaly"];
    PackedFloat32Array soil_arr      = knobs["soil_moisture_arr"];
    PackedFloat32Array vg_arr        = knobs["veg_growth_pressure_arr"];
    if (nb_arr.size() < n_cells * 6)    { diag("neighbor_indices size < n_cells * 6"); return -1.0; }
    if (tta_arr.size() != n_cells)      { diag("temp_transport_anomaly size mismatch"); return -1.0; }
    if (soil_arr.size() != n_cells)     { diag("soil_moisture_arr size mismatch"); return -1.0; }
    if (vg_arr.size() != n_cells)       { diag("veg_growth_pressure_arr size mismatch"); return -1.0; }

    // ─── Acquire slot arrays + validate sizes ───────────────────────────
    Slot &s_iswater = _slots.write[sid_iswater];
    Slot &s_wt_type = _slots.write[sid_wt_type];
    Slot &s_wt_int  = _slots.write[sid_wt_int];
    Slot &s_wt_init = _slots.write[sid_wt_init];
    Slot &s_base_m  = _slots.write[sid_base_m];
    if (s_iswater.arr_u8.size() != n_cells || s_wt_type.arr_u8.size() != n_cells ||
        s_wt_int.arr_f32.size() != n_cells || s_wt_init.arr_u8.size() != n_cells ||
        s_base_m.arr_f32.size()  != n_cells) {
        diag("slot array size mismatch (re-bind needed?)");
        return -1.0;
    }

    const uint8_t * const __restrict IW    = s_iswater.arr_u8.ptr();
    const uint8_t * const __restrict WTT   = s_wt_type.arr_u8.ptr();
    const float   * const __restrict WTI   = s_wt_int.arr_f32.ptr();
    const uint8_t * const __restrict WTIN  = s_wt_init.arr_u8.ptr();
    float         * const __restrict BM    = s_base_m.arr_f32.ptrw();
    const int32_t * const __restrict NB    = nb_arr.ptr();
    const float   * const __restrict TTA   = tta_arr.ptr();
    float         * const __restrict SOIL  = soil_arr.ptrw();
    float         * const __restrict VG    = vg_arr.ptrw();

    auto t0 = std::chrono::high_resolution_clock::now();

    // ─── Main loop ──────────────────────────────────
    // S3：下沉到共享纯内核。原先这里、run_climate_feedback_pass_thread、
    // run_stage_b_pass ③ 段是三份逐字副本，漏同步任一份都会表现成分叉。
    pk_async_climate::ClimateFeedbackKnobs fb_knobs;
    fb_knobs.ran = true;
    fb_knobs.soil_gain = soil_gain;
    fb_knobs.veg_gain = veg_gain;
    fb_knobs.scale = scale;
    fb_knobs.per_day_clamp = per_day_clamp;
    fb_knobs.ocean_drift_gain = ocean_drift_gain;
    fb_knobs.base_moisture_gain = base_m_gain;
    fb_knobs.write_weather_veg_pressure = write_weather_veg_pressure;
    fb_knobs.wt_rain_id = wt_rain_id;
    fb_knobs.wt_storm_id = wt_storm_id;
    fb_knobs.wt_monsoon_id = wt_monsoon_id;
    fb_knobs.wt_blizzard_id = wt_blizzard_id;
    fb_knobs.wt_drought_id = wt_drought_id;
    fb_knobs.wt_heatwave_id = wt_heatwave_id;
    record_production_feedback_input(fb_knobs, n_cells, IW, WTT, WTI, WTIN, TTA,
                                     BM, SOIL);
    pk_async_climate::climate_feedback_apply_pure(
        fb_knobs, IW, WTT, WTI, WTIN, NB, TTA, BM, SOIL, VG, 0, n_cells);

    // §11.2 flush: push CoW-detached cell_base_moisture back to MapData
    _flush_slot_to_map(sid_base_m);

    // 写回 in/out PackedArray (CoW：caller 保留同一份引用，ptrw 已经写过了)
    knobs["soil_moisture_arr"]       = soil_arr;
    knobs["veg_growth_pressure_arr"] = vg_arr;

    auto t1 = std::chrono::high_resolution_clock::now();
    return std::chrono::duration<double, std::milli>(t1 - t0).count();
}
#include "world_ext_climate_surface_section_final_surface_fields.inc"

#include "world_ext_climate_surface_section_wind.inc"

} // namespace pk
