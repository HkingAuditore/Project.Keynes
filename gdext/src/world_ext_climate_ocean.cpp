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
double DCWorldExt::run_ocean_water_pass(Dictionary knobs) {
    using godot::StringName;
    using godot::PackedFloat32Array;
    using godot::PackedInt32Array;
    using godot::PackedByteArray;

    auto diag = [&](const char *why) {
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_ocean_water_pass: ", why,
            " — fallback to GDScript");
    };

    if (!_bound) { diag("not _bound"); return -1.0; }

    const int sid_temp     = component_id(StringName("cell_temp"));
    const int sid_iswater  = component_id(StringName("cell_is_water"));
    const int sid_pos_x    = component_id(StringName("cell_pos_x"));
    const int sid_pos_y    = component_id(StringName("cell_pos_y"));
    // A 修复（2026-06）：ocean_water 不再写 cell_temp，改写 cell_ocean_thermal_anomaly。
    const int sid_oanom    = component_id(StringName("cell_ocean_thermal_anomaly"));
    const int sid_sea_ice  = component_id(StringName("cell_sea_ice_frac"));
    const int sid_terrain  = component_id(StringName("cell_terrain"));
    const int sid_lat      = component_id(StringName("cell_lat_norm"));
    const int sid_wind_x   = component_id(StringName("cell_wind_x"));
    const int sid_wind_spd = component_id(StringName("cell_wind_speed"));
    if (sid_temp < 0 || sid_iswater < 0 || sid_pos_x < 0 || sid_pos_y < 0 ||
        sid_oanom < 0 || sid_sea_ice < 0) {
        diag("missing slot id (cell_temp/is_water/pos_x/pos_y/ocean_thermal_anomaly/sea_ice_frac)");
        return -1.0;
    }

    if (!knobs.has("n_cells") || !knobs.has("advect_steps") ||
        !knobs.has("heat_mix") || !knobs.has("neighbor_indices") ||
        !knobs.has("baseline_arr") || !knobs.has("temp_before_arr") ||
        !knobs.has("anomaly_out") ||
        !knobs.has("ocean_current_x_arr") || !knobs.has("ocean_current_y_arr")) {
        diag("knobs missing required keys (need ocean_current_x/y_arr from cells)");
        return -1.0;
    }
    const int   n_cells      = int(knobs["n_cells"]);
    const int   advect_steps = int(knobs["advect_steps"]);
    // seam-advection-fix：经度环绕周期，缺省取 configure_native_world 常驻值。
    const float wrap_period_x = knobs.has("wrap_period_x")
        ? float(knobs["wrap_period_x"]) : float(_native_wrap_period_x);
    const float heat_mix     = float(knobs["heat_mix"]);
    float tta_source_cap = knobs.has("tta_source_cap") ? float(knobs["tta_source_cap"]) : 0.22f;
    float tta_blend_rate = knobs.has("tta_blend_rate") ? float(knobs["tta_blend_rate"]) : 0.70f;
    float tta_zero_current_decay = knobs.has("tta_zero_current_decay") ? float(knobs["tta_zero_current_decay"]) : 0.06f;
    const float cold_transport_form = knobs.has("cold_transport_form_threshold")
        ? float(knobs["cold_transport_form_threshold"]) : 0.06f;
    const float cold_transport_melt = knobs.has("cold_transport_melt_threshold")
        ? float(knobs["cold_transport_melt_threshold"]) : 0.11f;
    tta_source_cap = dc_clampf(tta_source_cap, 0.0f, 0.5f);
    tta_blend_rate = dc_clampf(tta_blend_rate, 0.0f, 1.0f);
    tta_zero_current_decay = dc_clampf(tta_zero_current_decay, 0.0f, 1.0f);
    if (n_cells <= 0) { diag("n_cells <= 0"); return -1.0; }
    const int start_idx = knobs.has("start_idx") ? int(knobs["start_idx"]) : 0;
    const int end_idx_raw = knobs.has("end_idx") ? int(knobs["end_idx"]) : n_cells;
    const int end_idx = std::min(std::max(end_idx_raw, start_idx), n_cells);
    if (start_idx < 0 || start_idx > n_cells) { diag("invalid start_idx"); return -1.0; }

    PackedInt32Array   nb_arr = knobs["neighbor_indices"];
    PackedFloat32Array baseline_arr = knobs["baseline_arr"];
    PackedFloat32Array temp_before_arr = knobs["temp_before_arr"];
    PackedFloat32Array ocx_arr = knobs["ocean_current_x_arr"];
    PackedFloat32Array ocy_arr = knobs["ocean_current_y_arr"];
    if (nb_arr.size() < n_cells * 6) { diag("neighbor_indices size < n_cells*6"); return -1.0; }
    if (baseline_arr.size()    != n_cells) { diag("baseline_arr size mismatch"); return -1.0; }
    if (temp_before_arr.size() != n_cells) { diag("temp_before_arr size mismatch"); return -1.0; }
    if (ocx_arr.size()         != n_cells) { diag("ocean_current_x_arr size mismatch"); return -1.0; }
    if (ocy_arr.size()         != n_cells) { diag("ocean_current_y_arr size mismatch"); return -1.0; }

    // §11 CoW fix: duplicate the caller buffer when chunking, preserving
    // previous chunks while still obtaining a refcount=1 ptrw() target.
    PackedFloat32Array anomaly_src = knobs["anomaly_out"];
    PackedFloat32Array anomaly_out = anomaly_src.size() == n_cells
        ? anomaly_src.duplicate()
        : PackedFloat32Array();
    if (anomaly_out.size() != n_cells) {
        anomaly_out.resize(n_cells);
    }

    Slot &s_temp    = _slots.write[sid_temp];
    Slot &s_iswater = _slots.write[sid_iswater];
    Slot &s_pos_x   = _slots.write[sid_pos_x];
    Slot &s_pos_y   = _slots.write[sid_pos_y];
    Slot &s_oanom   = _slots.write[sid_oanom];
    Slot &s_sea_ice = _slots.write[sid_sea_ice];
    if (s_temp.arr_f32.size()  != n_cells || s_iswater.arr_u8.size() != n_cells ||
        s_pos_x.arr_f32.size() != n_cells || s_pos_y.arr_f32.size()  != n_cells ||
        s_oanom.arr_f32.size() != n_cells || s_sea_ice.arr_f32.size() != n_cells) {
        diag("slot array size mismatch");
        return -1.0;
    }

    // A 修复（2026-06）：T 不再被写，只读 — 实际未使用，留 (void) 以备后续诊断。
    (void)s_temp;
    float       * const __restrict OANOM_SLOT = s_oanom.arr_f32.ptrw();
    const uint8_t * const __restrict IW = s_iswater.arr_u8.ptr();
    const float * const __restrict POSX = s_pos_x.arr_f32.ptr();
    const float * const __restrict POSY = s_pos_y.arr_f32.ptr();
    // OCX/OCY 从 knobs 拿（cells 提取的最新值，规避 SoA stale 问题）
    const float * const __restrict OCX  = ocx_arr.ptr();
    const float * const __restrict OCY  = ocy_arr.ptr();
    const int32_t * const __restrict NB = nb_arr.ptr();
    const float * const __restrict BL   = baseline_arr.ptr();
    const float * const __restrict TB   = temp_before_arr.ptr();
    const float * const __restrict SIF  = s_sea_ice.arr_f32.ptr();
    float       * const __restrict AOUT = anomaly_out.ptrw();

    // S3: 留存生产这一轮真实用过的标量，reference publish 时随 reference 发布给 worker。
    // 不写的后果是 worker 跑同一份共享内核、却吃结构默认 knobs。
    record_production_round_scalars(0x04, knobs);
    record_production_ocean_water_input(n_cells, baseline_arr.ptr(), temp_before_arr.ptr());

    auto t0 = std::chrono::high_resolution_clock::now();

    // 主循环已下沉到共享内核（见 pk_async_climate::OceanWaterKnobs 注释）。
    // worker 跑同一份，不再有第二份零覆盖的拄本。
    {
        pk_async_climate::OceanWaterKnobs ok;
        ok.n_cells = n_cells;
        ok.start_idx = start_idx;
        ok.end_idx = end_idx;
        ok.advect_steps = advect_steps;
        ok.heat_mix = heat_mix;
        ok.wrap_period_x = wrap_period_x;
        ok.tta_source_cap = tta_source_cap;
        ok.tta_blend_rate = tta_blend_rate;
        ok.tta_zero_current_decay = tta_zero_current_decay;
        ok.cold_transport_form = cold_transport_form;
        ok.cold_transport_melt = cold_transport_melt;

        pk_async_climate::OceanWaterLanes ol;
        ol.is_water = IW;
        ol.pos_x = POSX;
        ol.pos_y = POSY;
        ol.ocean_current_x = OCX;
        ol.ocean_current_y = OCY;
        ol.baseline = BL;
        ol.temp_before = TB;
        ol.sea_ice_frac = SIF;
        ol.neighbors = NB;
        ol.ocean_anomaly = OANOM_SLOT;
        ol.tta_inout = AOUT;

        pk_async_climate::ocean_water_pure(ok, ol);
    }

    const uint8_t *enso_terrain = sid_terrain >= 0 && _slots.write[sid_terrain].arr_u8.size() == n_cells
        ? _slots.write[sid_terrain].arr_u8.ptr() : nullptr;
    const float *enso_lat = sid_lat >= 0 && _slots.write[sid_lat].arr_f32.size() == n_cells
        ? _slots.write[sid_lat].arr_f32.ptr() : nullptr;
    const float *enso_wx = sid_wind_x >= 0 && _slots.write[sid_wind_x].arr_f32.size() == n_cells
        ? _slots.write[sid_wind_x].arr_f32.ptr() : nullptr;
    const float *enso_wspd = sid_wind_spd >= 0 && _slots.write[sid_wind_spd].arr_f32.size() == n_cells
        ? _slots.write[sid_wind_spd].arr_f32.ptr() : nullptr;
    _apply_enso_ocean_slice(knobs, n_cells, start_idx, end_idx, IW, enso_terrain,
                            enso_lat, POSX, NB, enso_wx, enso_wspd,
                            OANOM_SLOT, AOUT);

    // §11 CoW fix: write the freshly-computed anomaly back into the
    // Dictionary so GDScript can read it after the call.
    knobs["anomaly_out"] = anomaly_out;
    knobs["cursor_start"] = start_idx;
    knobs["cursor_end"] = end_idx;
    knobs["processed_cells"] = end_idx - start_idx;

    // §11.2 flush: A 修复后只 flush ocean anomaly slot（不再写 cell_temp）。
    // Native daily node-range slicing keeps intermediate chunks inside C++ slots; only
    // the last chunk publishes to MapData so we do not pay the boundary cost per chunk.
    if (!bool(knobs.get("defer_flush", false))) {
        _flush_slot_to_map(sid_oanom);
    }

    auto t1 = std::chrono::high_resolution_clock::now();
    return std::chrono::duration<double, std::milli>(t1 - t0).count();
}

// ─── F.2b: ocean land pass ──────────────────────────────────────────────────
//
// Single-shot full sweep over [0, n_cells). 1:1 mirror of
// _ocean_land_pass_soa (map_generator.gd:4762+) hot loop:
//   for each LAND cell i:
//     sum of (water-nb anomaly × dot(self→nb, nb_current)) over 6 neighbors
//     anomaly_in = (weighted_sum / weight_total) * effective_leak
//     anomaly_inout[i] = anomaly_in
//     if |anomaly_in| > 1e-5: temp_a[i] = clamp(temp_a[i] + anomaly_in, 0, 1)
//
// 注意：anomaly_inout 既读（water 邻居 by water pass 写入的 anomaly）也写
// （本 cell 的 anomaly）。GDScript side 必须先调 water pass 再调 land pass。
double DCWorldExt::run_ocean_land_pass(Dictionary knobs) {
    using godot::StringName;
    using godot::PackedFloat32Array;
    using godot::PackedInt32Array;
    using godot::PackedByteArray;

    auto diag = [&](const char *why) {
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_ocean_land_pass: ", why,
            " — fallback to GDScript");
    };

    if (!_bound) { diag("not _bound"); return -1.0; }

    const int sid_temp     = component_id(StringName("cell_temp"));
    const int sid_iswater  = component_id(StringName("cell_is_water"));
    const int sid_pos_x    = component_id(StringName("cell_pos_x"));
    const int sid_pos_y    = component_id(StringName("cell_pos_y"));
    // A 修复（2026-06）：ocean_land 不再写 cell_temp，累加到 cell_ocean_thermal_anomaly。
    const int sid_oanom    = component_id(StringName("cell_ocean_thermal_anomaly"));
    if (sid_temp < 0 || sid_iswater < 0 || sid_pos_x < 0 || sid_pos_y < 0 || sid_oanom < 0) {
        diag("missing slot id (cell_temp/is_water/pos_x/pos_y/ocean_thermal_anomaly)");
        return -1.0;
    }

    if (!knobs.has("n_cells") || !knobs.has("effective_leak") ||
        !knobs.has("neighbor_indices") || !knobs.has("anomaly_inout") ||
        !knobs.has("fallback_baseline_arr") ||
        !knobs.has("ocean_current_x_arr") || !knobs.has("ocean_current_y_arr")) {
        diag("knobs missing required keys (need ocean_current_x/y_arr from cells)");
        return -1.0;
    }
    const int   n_cells        = int(knobs["n_cells"]);
    const float effective_leak = float(knobs["effective_leak"]);
    // seam-advection-fix：经度环绕周期，缺省取 configure_native_world 常驻值。
    const float wrap_period_x = knobs.has("wrap_period_x")
        ? float(knobs["wrap_period_x"]) : float(_native_wrap_period_x);
    float tta_source_cap = knobs.has("tta_source_cap") ? float(knobs["tta_source_cap"]) : 0.22f;
    float tta_blend_rate = knobs.has("tta_blend_rate") ? float(knobs["tta_blend_rate"]) : 0.70f;
    float tta_decay_rate = knobs.has("tta_decay_rate") ? float(knobs["tta_decay_rate"]) : 0.04f;
    tta_source_cap = dc_clampf(tta_source_cap, 0.0f, 0.5f);
    tta_blend_rate = dc_clampf(tta_blend_rate, 0.0f, 1.0f);
    tta_decay_rate = dc_clampf(tta_decay_rate, 0.0f, 1.0f);
    if (n_cells <= 0) { diag("n_cells <= 0"); return -1.0; }
    const int start_idx = knobs.has("start_idx") ? int(knobs["start_idx"]) : 0;
    const int end_idx_raw = knobs.has("end_idx") ? int(knobs["end_idx"]) : n_cells;
    const int end_idx = std::min(std::max(end_idx_raw, start_idx), n_cells);
    if (start_idx < 0 || start_idx > n_cells) { diag("invalid start_idx"); return -1.0; }

    PackedInt32Array nb_arr = knobs["neighbor_indices"];
    PackedFloat32Array fallback_baseline = knobs["fallback_baseline_arr"];
    PackedFloat32Array ocx_arr = knobs["ocean_current_x_arr"];
    PackedFloat32Array ocy_arr = knobs["ocean_current_y_arr"];
    if (nb_arr.size() < n_cells * 6)         { diag("neighbor_indices size < n_cells*6"); return -1.0; }
    if (fallback_baseline.size() != n_cells) { diag("fallback_baseline_arr size mismatch"); return -1.0; }
    if (ocx_arr.size()       != n_cells)     { diag("ocean_current_x_arr size mismatch"); return -1.0; }
    if (ocy_arr.size()       != n_cells)     { diag("ocean_current_y_arr size mismatch"); return -1.0; }

    // §11 CoW fix: duplicate the input anomaly into a fresh array
    // (refcount=1) so ptrw() does not CoW-detach. We read water
    // neighbors' anomaly (written by water pass) and write land cells'
    // anomaly, then push the result back into the Dictionary.
    PackedFloat32Array anomaly_src = knobs["anomaly_inout"];
    if (anomaly_src.size() != n_cells) { diag("anomaly_inout size mismatch"); return -1.0; }
    PackedFloat32Array anomaly_inout = anomaly_src.duplicate();

    Slot &s_temp    = _slots.write[sid_temp];
    Slot &s_iswater = _slots.write[sid_iswater];
    Slot &s_pos_x   = _slots.write[sid_pos_x];
    Slot &s_pos_y   = _slots.write[sid_pos_y];
    Slot &s_oanom   = _slots.write[sid_oanom];
    if (s_temp.arr_f32.size()  != n_cells || s_iswater.arr_u8.size() != n_cells ||
        s_pos_x.arr_f32.size() != n_cells || s_pos_y.arr_f32.size()  != n_cells ||
        s_oanom.arr_f32.size() != n_cells) {
        diag("slot array size mismatch");
        return -1.0;
    }

    // A 修复（2026-06）：T 不再被写。
    (void)s_temp;
    float       * const __restrict OANOM_SLOT = s_oanom.arr_f32.ptrw();
    const uint8_t * const __restrict IW = s_iswater.arr_u8.ptr();
    const float * const __restrict POSX = s_pos_x.arr_f32.ptr();
    const float * const __restrict POSY = s_pos_y.arr_f32.ptr();
    // OCX/OCY 从 knobs 拿（cells 最新值，规避 SoA stale）
    const float * const __restrict OCX  = ocx_arr.ptr();
    const float * const __restrict OCY  = ocy_arr.ptr();
    const int32_t * const __restrict NB = nb_arr.ptr();
    float       * const __restrict A    = anomaly_inout.ptrw();
    const float * const __restrict FBL  = fallback_baseline.ptr();
    (void)FBL;

    // S3: 留存生产这一轮真实用过的标量，reference publish 时随 reference 发布给 worker。
    // 不写的后果是 worker 跑同一份共享内核、却吃结构默认 knobs。
    record_production_round_scalars(0x08, knobs);

    auto t0 = std::chrono::high_resolution_clock::now();

    // 注意：land 写入的是 LAND cell 的 anomaly，读 WATER 邻居的 anomaly
    // （water pass 已经在 anomaly_inout 里写好）。所以读写不冲突——所有 land
    // i 都不在自身 6 邻居读到的 water cell 集合里（water cell 的 anomaly 在
    // water pass 已 finalized）。可以安全用同一个数组 in-place。
    {
        pk_async_climate::OceanLandKnobs ok;
        ok.n_cells = n_cells;
        ok.start_idx = start_idx;
        ok.end_idx = end_idx;
        ok.effective_leak = effective_leak;
        ok.wrap_period_x = wrap_period_x;
        ok.tta_source_cap = tta_source_cap;
        ok.tta_blend_rate = tta_blend_rate;
        ok.tta_decay_rate = tta_decay_rate;

        pk_async_climate::OceanLandLanes ol;
        ol.is_water = IW;
        ol.pos_x = POSX;
        ol.pos_y = POSY;
        ol.ocean_current_x = OCX;
        ol.ocean_current_y = OCY;
        ol.neighbors = NB;
        ol.tta_inout = A;
        ol.ocean_anomaly = OANOM_SLOT;

        pk_async_climate::ocean_land_pure(ok, ol);
    }

    // §11 CoW fix: write the modified anomaly back into the Dictionary
    knobs["anomaly_inout"] = anomaly_inout;
    knobs["cursor_start"] = start_idx;
    knobs["cursor_end"] = end_idx;
    knobs["processed_cells"] = end_idx - start_idx;

    // §11.2 flush: A 修复后只 flush ocean anomaly slot（不再写 cell_temp）。
    if (!bool(knobs.get("defer_flush", false))) {
        _flush_slot_to_map(sid_oanom);
    }

    auto t1 = std::chrono::high_resolution_clock::now();
    return std::chrono::duration<double, std::milli>(t1 - t0).count();
}

// pk_snowpack_cover_for_albedo 已在 S3 搬到 runtime_climate_pass_math.h。

// ─── F.3 main pass ──────────────────────────────────────────────────────────
//
// Single-shot full sweep over [0, n_cells). 1:1 mirror of
// _climate_pass_b_soa (map_generator.gd:4311+) with these scope cuts:
//   * sparse path (go_sparse=true) → return -1.0 fallback
//   * cell.temperature_breakdown UI dict writes → SKIP
//   * [DIAG pass_b_end] end-of-pass stat print → SKIP (caller can dump SoA)
//
// Algorithm (mirror lines 4396-4523):
//   temp_snapshot = temp_a.duplicate()
//   for each cell i:
//     temp_now = temp_snapshot[i]; moisture_now = moist_a[i]
//     d_albedo = (-snow_cool * SNOW + -veg_cool * foliage)  if !is_water
//     d_coastal = coast_leak * avg(water-nb anomaly) * winter_boost  if !is_water
//     d_landform = +/- diurnal by landform * cell_insolation_dev       if !is_water
//     temp_a[i] = clamp(temp_now + d_albedo + d_coastal + d_landform, 0, 1)
//     d_evap = evap_gain * (t_eff - t_freeze) * nb_water_norm * (1 + coupling*avg_anom)  if !is_water
//     d_rain_shadow = rs_factor if max-upwind-elev - elev[i] >= rs_threshold  if !is_water
//     moist_a[i] = clamp((moisture_now + d_evap) * d_rain_shadow, 0, 1)
namespace {

struct OceanWaterCtx {
    int             n_cells;
    int             advect_steps;
    float           heat_mix;
    // seam-advection-fix：经度环绕周期，0 = 无环绕域（退化为裸差分）。
    float           wrap_period_x;
    float           tta_source_cap;
    float           tta_blend_rate;
    float           tta_zero_current_decay;
    float           cold_transport_form;
    float           cold_transport_melt;
    const int32_t  *NB;        // n_cells * 6
    const uint8_t  *IW;        // n_cells
    const float    *POSX;      // n_cells
    const float    *POSY;      // n_cells
    const float    *OCX;       // n_cells
    const float    *OCY;       // n_cells
    const float    *BL;        // baseline, n_cells
    const float    *TB;        // temp_before, n_cells
    const float    *SIF;       // sea_ice_frac, n_cells
    // A 修复（2026-06）：T 已不再被写；保留只读指针仅作未来诊断。
    const float    *T_RO;
    float          *OANOM_SLOT;// cell_ocean_thermal_anomaly out
    float          *AOUT;      // anomaly_out, n_cells (water cells written)
};

// 单 cell hot kernel：完整复刻 run_ocean_water_pass 主循环 body（line 3160-3206）。
// IW[i]==1 已由 idx 预筛保证，外层无分支。
inline void ocean_water_compute_one(const OceanWaterCtx &c, int i) {
    const float cur_x = c.OCX[i];
    const float cur_y = c.OCY[i];
    const float cur_len2 = cur_x * cur_x + cur_y * cur_y;
    if (cur_len2 < 1e-6f || c.advect_steps == 0) {
        c.AOUT[i] = dc_decay_tta(c.AOUT[i], c.tta_zero_current_decay);
        // A 修复：current 不足时 ocean anomaly 也朝 0 衰减。
        c.OANOM_SLOT[i] = c.OANOM_SLOT[i] * (1.0f - c.tta_zero_current_decay);
        return;
    }
    const float inv_cur = 1.0f / std::sqrt(cur_len2);
    const float up_dx = -cur_x * inv_cur;
    const float up_dy = -cur_y * inv_cur;

    int upstream_idx = i;
    for (int step = 0; step < c.advect_steps; ++step) {
        int   best_idx = -1;
        float best_dot = 0.1f;
        const float swx = c.POSX[upstream_idx];
        const float swy = c.POSY[upstream_idx];
        const int ub = upstream_idx * 6;
        for (int d = 0; d < 6; ++d) {
            const int32_t ni = c.NB[ub + d];
            if (ni < 0) continue;
            if (c.IW[ni] == 0) continue;
            const float dx = pk_wrap_min_image_dx(c.POSX[ni] - swx, c.wrap_period_x);
            const float dy = c.POSY[ni] - swy;
            const float len2 = dx * dx + dy * dy;
            if (len2 < 1e-6f) continue;
            const float inv_len = 1.0f / std::sqrt(len2);
            const float dot_v = (dx * up_dx + dy * up_dy) * inv_len;
            if (dot_v > best_dot) {
                best_dot = dot_v;
                best_idx = ni;
            }
        }
        if (best_idx < 0) break;
        upstream_idx = best_idx;
    }

    const float temp_self = c.TB[i];
    const float temp_up   = c.TB[upstream_idx];
    float temp_mixed = temp_self + (temp_up - temp_self) * c.heat_mix; // = lerpf
    if (temp_mixed < 0.0f) temp_mixed = 0.0f;
    else if (temp_mixed > 1.0f) temp_mixed = 1.0f;
    float source = temp_mixed - c.BL[i];
    source = pk_limit_cold_water_positive_transport_source(
        source, c.BL[i], c.SIF[i], c.cold_transport_form, c.cold_transport_melt);
    // A 修复（2026-06）：不再写 T；写入 ocean thermal anomaly slot。
    float oanom = source;
    if (oanom < -0.08f) oanom = -0.08f;
    else if (oanom > 0.08f) oanom = 0.08f;
    c.OANOM_SLOT[i] = oanom;
    c.AOUT[i] = dc_stabilize_tta(c.AOUT[i], source, c.tta_source_cap, c.tta_blend_rate);
}

inline void ocean_water_run_water_range(const OceanWaterCtx &c,
                                        const int *water_idx,
                                        int begin, int end) {
    for (int k = begin; k < end; ++k) {
        ocean_water_compute_one(c, water_idx[k]);
    }
}

// [Phase C.3b] 原 OceanWaterTask + ocean_water_worker 已由 parallel_dispatcher.h
// 内的 parallel_for_range 取代。

} // anonymous namespace (ocean water helpers)

static void pk_run_ocean_water_pure(
        int n_cells,
        int advect_steps,
        float heat_mix,
        float wrap_period_x,
        float tta_source_cap,
        float tta_blend_rate,
        float tta_zero_current_decay,
        float cold_transport_form,
        float cold_transport_melt,
        const uint8_t *is_water,
        const float *pos_x,
        const float *pos_y,
        const float *ocean_current_x,
        const float *ocean_current_y,
        const float *baseline,
        const float *temp_before,
        const float *sea_ice_frac,
        const int32_t *neighbors,
        float *ocean_anomaly,
        float *tta_inout) {
    pk_async_climate::OceanWaterKnobs ok;
    ok.n_cells = n_cells;
    ok.start_idx = 0;
    ok.end_idx = n_cells;
    ok.advect_steps = advect_steps;
    ok.heat_mix = heat_mix;
    ok.wrap_period_x = wrap_period_x;
    ok.tta_source_cap = tta_source_cap;
    ok.tta_blend_rate = tta_blend_rate;
    ok.tta_zero_current_decay = tta_zero_current_decay;
    ok.cold_transport_form = cold_transport_form;
    ok.cold_transport_melt = cold_transport_melt;

    pk_async_climate::OceanWaterLanes ol;
    ol.is_water = is_water;
    ol.pos_x = pos_x;
    ol.pos_y = pos_y;
    ol.ocean_current_x = ocean_current_x;
    ol.ocean_current_y = ocean_current_y;
    ol.baseline = baseline;
    ol.temp_before = temp_before;
    ol.sea_ice_frac = sea_ice_frac;
    ol.neighbors = neighbors;
    ol.ocean_anomaly = ocean_anomaly;
    ol.tta_inout = tta_inout;
    pk_async_climate::ocean_water_pure(ok, ol);
}

static void pk_run_ocean_land_pure(
        int n_cells,
        float effective_leak,
        float wrap_period_x,
        float tta_source_cap,
        float tta_blend_rate,
        float tta_decay_rate,
        const uint8_t *is_water,
        const float *pos_x,
        const float *pos_y,
        const float *ocean_current_x,
        const float *ocean_current_y,
        const int32_t *neighbors,
        float *tta_inout,
        float *ocean_anomaly) {
    pk_async_climate::OceanLandKnobs ok;
    ok.n_cells = n_cells;
    ok.start_idx = 0;
    ok.end_idx = n_cells;
    ok.effective_leak = effective_leak;
    ok.wrap_period_x = wrap_period_x;
    ok.tta_source_cap = tta_source_cap;
    ok.tta_blend_rate = tta_blend_rate;
    ok.tta_decay_rate = tta_decay_rate;

    pk_async_climate::OceanLandLanes ol;
    ol.is_water = is_water;
    ol.pos_x = pos_x;
    ol.pos_y = pos_y;
    ol.ocean_current_x = ocean_current_x;
    ol.ocean_current_y = ocean_current_y;
    ol.neighbors = neighbors;
    ol.tta_inout = tta_inout;
    ol.ocean_anomaly = ocean_anomaly;
    pk_async_climate::ocean_land_pure(ok, ol);
}

// fallback：任何 sanity check 失败返回 -1.0，调用方走原 run_ocean_water_pass。
double DCWorldExt::run_ocean_water_pass_simd(Dictionary knobs) {
    using godot::StringName;
    using godot::PackedFloat32Array;
    using godot::PackedInt32Array;

    auto diag = [&](const char *why) {
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_ocean_water_pass_simd: ", why,
            " — fallback to GDScript");
    };

    if (!_bound) { diag("not _bound"); return -1.0; }

    const int sid_temp     = component_id(StringName("cell_temp"));
    const int sid_iswater  = component_id(StringName("cell_is_water"));
    const int sid_pos_x    = component_id(StringName("cell_pos_x"));
    const int sid_pos_y    = component_id(StringName("cell_pos_y"));
    // A 修复（2026-06）：ocean_water SIMD 改写 ocean thermal anomaly slot。
    const int sid_oanom    = component_id(StringName("cell_ocean_thermal_anomaly"));
    const int sid_sea_ice  = component_id(StringName("cell_sea_ice_frac"));
    const int sid_terrain  = component_id(StringName("cell_terrain"));
    const int sid_lat      = component_id(StringName("cell_lat_norm"));
    const int sid_wind_x   = component_id(StringName("cell_wind_x"));
    const int sid_wind_spd = component_id(StringName("cell_wind_speed"));
    if (sid_temp < 0 || sid_iswater < 0 || sid_pos_x < 0 || sid_pos_y < 0 ||
        sid_oanom < 0 || sid_sea_ice < 0) {
        diag("missing slot id");
        return -1.0;
    }

    if (!knobs.has("n_cells") || !knobs.has("advect_steps") ||
        !knobs.has("heat_mix") || !knobs.has("neighbor_indices") ||
        !knobs.has("baseline_arr") || !knobs.has("temp_before_arr") ||
        !knobs.has("anomaly_out") ||
        !knobs.has("ocean_current_x_arr") || !knobs.has("ocean_current_y_arr")) {
        diag("knobs missing required keys");
        return -1.0;
    }
    const int   n_cells      = int(knobs["n_cells"]);
    const int   advect_steps = int(knobs["advect_steps"]);
    // seam-advection-fix：经度环绕周期，缺省取 configure_native_world 常驻值。
    const float wrap_period_x = knobs.has("wrap_period_x")
        ? float(knobs["wrap_period_x"]) : float(_native_wrap_period_x);
    const float heat_mix     = float(knobs["heat_mix"]);
    float tta_source_cap = knobs.has("tta_source_cap") ? float(knobs["tta_source_cap"]) : 0.22f;
    float tta_blend_rate = knobs.has("tta_blend_rate") ? float(knobs["tta_blend_rate"]) : 0.70f;
    float tta_zero_current_decay = knobs.has("tta_zero_current_decay") ? float(knobs["tta_zero_current_decay"]) : 0.06f;
    const float cold_transport_form = knobs.has("cold_transport_form_threshold")
        ? float(knobs["cold_transport_form_threshold"]) : 0.06f;
    const float cold_transport_melt = knobs.has("cold_transport_melt_threshold")
        ? float(knobs["cold_transport_melt_threshold"]) : 0.11f;
    tta_source_cap = dc_clampf(tta_source_cap, 0.0f, 0.5f);
    tta_blend_rate = dc_clampf(tta_blend_rate, 0.0f, 1.0f);
    tta_zero_current_decay = dc_clampf(tta_zero_current_decay, 0.0f, 1.0f);
    if (n_cells <= 0) { diag("n_cells <= 0"); return -1.0; }

    PackedInt32Array   nb_arr = knobs["neighbor_indices"];
    PackedFloat32Array baseline_arr = knobs["baseline_arr"];
    PackedFloat32Array temp_before_arr = knobs["temp_before_arr"];
    PackedFloat32Array ocx_arr = knobs["ocean_current_x_arr"];
    PackedFloat32Array ocy_arr = knobs["ocean_current_y_arr"];
    if (nb_arr.size() < n_cells * 6)         { diag("neighbor_indices size"); return -1.0; }
    if (baseline_arr.size()    != n_cells)   { diag("baseline_arr size"); return -1.0; }
    if (temp_before_arr.size() != n_cells)   { diag("temp_before_arr size"); return -1.0; }
    if (ocx_arr.size()         != n_cells)   { diag("ocx_arr size"); return -1.0; }
    if (ocy_arr.size()         != n_cells)   { diag("ocy_arr size"); return -1.0; }

    // CoW fix: duplicate caller state so unchanged cells keep previous TTA.
    PackedFloat32Array anomaly_src = knobs["anomaly_out"];
    PackedFloat32Array anomaly_out = anomaly_src.size() == n_cells
        ? anomaly_src.duplicate()
        : PackedFloat32Array();
    if (anomaly_out.size() != n_cells) {
        anomaly_out.resize(n_cells);
    }

    Slot &s_temp    = _slots.write[sid_temp];
    Slot &s_iswater = _slots.write[sid_iswater];
    Slot &s_pos_x   = _slots.write[sid_pos_x];
    Slot &s_pos_y   = _slots.write[sid_pos_y];
    Slot &s_oanom   = _slots.write[sid_oanom];
    Slot &s_sea_ice = _slots.write[sid_sea_ice];
    if (s_temp.arr_f32.size()  != n_cells || s_iswater.arr_u8.size() != n_cells ||
        s_pos_x.arr_f32.size() != n_cells || s_pos_y.arr_f32.size()  != n_cells ||
        s_oanom.arr_f32.size() != n_cells || s_sea_ice.arr_f32.size() != n_cells) {
        diag("slot array size");
        return -1.0;
    }

    OceanWaterCtx ctx{};
    ctx.n_cells      = n_cells;
    ctx.advect_steps = advect_steps;
    ctx.heat_mix     = heat_mix;
    ctx.wrap_period_x = wrap_period_x;
    ctx.tta_source_cap = tta_source_cap;
    ctx.tta_blend_rate = tta_blend_rate;
    ctx.tta_zero_current_decay = tta_zero_current_decay;
    ctx.cold_transport_form = cold_transport_form;
    ctx.cold_transport_melt = cold_transport_melt;
    ctx.NB           = nb_arr.ptr();
    ctx.IW           = s_iswater.arr_u8.ptr();
    ctx.POSX         = s_pos_x.arr_f32.ptr();
    ctx.POSY         = s_pos_y.arr_f32.ptr();
    ctx.OCX          = ocx_arr.ptr();
    ctx.OCY          = ocy_arr.ptr();
    ctx.BL           = baseline_arr.ptr();
    ctx.TB           = temp_before_arr.ptr();
    ctx.SIF          = s_sea_ice.arr_f32.ptr();
    ctx.T_RO         = s_temp.arr_f32.ptr();
    ctx.OANOM_SLOT   = s_oanom.arr_f32.ptrw();
    ctx.AOUT         = anomaly_out.ptrw();

    // S3: 留存生产这一轮真实用过的标量。漏记的后果不只是 worker 吃默认 knobs ——
    // prod_knobs 诊断位也不会置，于是看起来像“这个 pass 根本没跑”。
    // native daily graph 默认走的就是 thread 变体，所以漏在这里最隐蔽。
    record_production_round_scalars(0x04, knobs);
    record_production_ocean_water_input(n_cells, baseline_arr.ptr(), temp_before_arr.ptr());

    auto t0 = std::chrono::high_resolution_clock::now();

    // native daily 默认走 thread 变体；simd 也必须吃同一份内核，否则
    // SHADOW 对拍的是两套 ocean 物理。并行只是调度，不再是第二套公式。
    pk_run_ocean_water_pure(
        n_cells, advect_steps, heat_mix, wrap_period_x,
        tta_source_cap, tta_blend_rate, tta_zero_current_decay,
        cold_transport_form, cold_transport_melt,
        ctx.IW, ctx.POSX, ctx.POSY, ctx.OCX, ctx.OCY,
        ctx.BL, ctx.TB, ctx.SIF, ctx.NB, ctx.OANOM_SLOT, ctx.AOUT);

    const uint8_t *enso_terrain = sid_terrain >= 0 && _slots.write[sid_terrain].arr_u8.size() == n_cells
        ? _slots.write[sid_terrain].arr_u8.ptr() : nullptr;
    const float *enso_lat = sid_lat >= 0 && _slots.write[sid_lat].arr_f32.size() == n_cells
        ? _slots.write[sid_lat].arr_f32.ptr() : nullptr;
    const float *enso_wx = sid_wind_x >= 0 && _slots.write[sid_wind_x].arr_f32.size() == n_cells
        ? _slots.write[sid_wind_x].arr_f32.ptr() : nullptr;
    const float *enso_wspd = sid_wind_spd >= 0 && _slots.write[sid_wind_spd].arr_f32.size() == n_cells
        ? _slots.write[sid_wind_spd].arr_f32.ptr() : nullptr;
    _apply_enso_ocean_slice(knobs, n_cells, 0, n_cells, ctx.IW, enso_terrain,
                            enso_lat, ctx.POSX, ctx.NB, enso_wx, enso_wspd,
                            ctx.OANOM_SLOT, ctx.AOUT);

    knobs["anomaly_out"] = anomaly_out;
    // A 修复（2026-06）：不再 flush cell_temp，改 flush ocean anomaly slot。
    _flush_slot_to_map(sid_oanom);

    auto t1 = std::chrono::high_resolution_clock::now();
    return std::chrono::duration<double, std::milli>(t1 - t0).count();
}

double DCWorldExt::run_ocean_water_pass_thread(Dictionary knobs, int n_tasks) {
    using godot::StringName;
    using godot::PackedFloat32Array;
    using godot::PackedInt32Array;

    auto diag = [&](const char *why) {
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_ocean_water_pass_thread: ", why,
            " — fallback to GDScript");
    };

    if (!_bound) { diag("not _bound"); return -1.0; }

    const int sid_temp     = component_id(StringName("cell_temp"));
    const int sid_iswater  = component_id(StringName("cell_is_water"));
    const int sid_pos_x    = component_id(StringName("cell_pos_x"));
    const int sid_pos_y    = component_id(StringName("cell_pos_y"));
    // A 修复（2026-06）：ocean_water thread 改写 ocean thermal anomaly slot。
    const int sid_oanom    = component_id(StringName("cell_ocean_thermal_anomaly"));
    const int sid_sea_ice  = component_id(StringName("cell_sea_ice_frac"));
    const int sid_terrain  = component_id(StringName("cell_terrain"));
    const int sid_lat      = component_id(StringName("cell_lat_norm"));
    const int sid_wind_x   = component_id(StringName("cell_wind_x"));
    const int sid_wind_spd = component_id(StringName("cell_wind_speed"));
    if (sid_temp < 0 || sid_iswater < 0 || sid_pos_x < 0 || sid_pos_y < 0 ||
        sid_oanom < 0 || sid_sea_ice < 0) {
        diag("missing slot id"); return -1.0;
    }

    if (!knobs.has("n_cells") || !knobs.has("advect_steps") ||
        !knobs.has("heat_mix") || !knobs.has("neighbor_indices") ||
        !knobs.has("baseline_arr") || !knobs.has("temp_before_arr") ||
        !knobs.has("anomaly_out") ||
        !knobs.has("ocean_current_x_arr") || !knobs.has("ocean_current_y_arr")) {
        diag("knobs missing"); return -1.0;
    }
    const int   n_cells      = int(knobs["n_cells"]);
    const int   advect_steps = int(knobs["advect_steps"]);
    // seam-advection-fix：经度环绕周期，缺省取 configure_native_world 常驻值。
    const float wrap_period_x = knobs.has("wrap_period_x")
        ? float(knobs["wrap_period_x"]) : float(_native_wrap_period_x);
    const float heat_mix     = float(knobs["heat_mix"]);
    float tta_source_cap = knobs.has("tta_source_cap") ? float(knobs["tta_source_cap"]) : 0.22f;
    float tta_blend_rate = knobs.has("tta_blend_rate") ? float(knobs["tta_blend_rate"]) : 0.70f;
    float tta_zero_current_decay = knobs.has("tta_zero_current_decay") ? float(knobs["tta_zero_current_decay"]) : 0.06f;
    const float cold_transport_form = knobs.has("cold_transport_form_threshold")
        ? float(knobs["cold_transport_form_threshold"]) : 0.06f;
    const float cold_transport_melt = knobs.has("cold_transport_melt_threshold")
        ? float(knobs["cold_transport_melt_threshold"]) : 0.11f;
    tta_source_cap = dc_clampf(tta_source_cap, 0.0f, 0.5f);
    tta_blend_rate = dc_clampf(tta_blend_rate, 0.0f, 1.0f);
    tta_zero_current_decay = dc_clampf(tta_zero_current_decay, 0.0f, 1.0f);
    if (n_cells <= 0) { diag("n_cells <= 0"); return -1.0; }

    PackedInt32Array   nb_arr = knobs["neighbor_indices"];
    PackedFloat32Array baseline_arr = knobs["baseline_arr"];
    PackedFloat32Array temp_before_arr = knobs["temp_before_arr"];
    PackedFloat32Array ocx_arr = knobs["ocean_current_x_arr"];
    PackedFloat32Array ocy_arr = knobs["ocean_current_y_arr"];
    if (nb_arr.size() < n_cells * 6)         { diag("nb size"); return -1.0; }
    if (baseline_arr.size()    != n_cells)   { diag("baseline size"); return -1.0; }
    if (temp_before_arr.size() != n_cells)   { diag("temp_before size"); return -1.0; }
    if (ocx_arr.size()         != n_cells)   { diag("ocx size"); return -1.0; }
    if (ocy_arr.size()         != n_cells)   { diag("ocy size"); return -1.0; }

    PackedFloat32Array anomaly_src = knobs["anomaly_out"];
    PackedFloat32Array anomaly_out = anomaly_src.size() == n_cells
        ? anomaly_src.duplicate()
        : PackedFloat32Array();
    if (anomaly_out.size() != n_cells) {
        anomaly_out.resize(n_cells);
    }

    Slot &s_temp    = _slots.write[sid_temp];
    Slot &s_iswater = _slots.write[sid_iswater];
    Slot &s_pos_x   = _slots.write[sid_pos_x];
    Slot &s_pos_y   = _slots.write[sid_pos_y];
    Slot &s_oanom   = _slots.write[sid_oanom];
    Slot &s_sea_ice = _slots.write[sid_sea_ice];
    if (s_temp.arr_f32.size()  != n_cells || s_iswater.arr_u8.size() != n_cells ||
        s_pos_x.arr_f32.size() != n_cells || s_pos_y.arr_f32.size()  != n_cells ||
        s_oanom.arr_f32.size() != n_cells || s_sea_ice.arr_f32.size() != n_cells) {
        diag("slot size"); return -1.0;
    }

    OceanWaterCtx ctx{};
    ctx.n_cells      = n_cells;
    ctx.advect_steps = advect_steps;
    ctx.heat_mix     = heat_mix;
    ctx.wrap_period_x = wrap_period_x;
    ctx.tta_source_cap = tta_source_cap;
    ctx.tta_blend_rate = tta_blend_rate;
    ctx.tta_zero_current_decay = tta_zero_current_decay;
    ctx.cold_transport_form = cold_transport_form;
    ctx.cold_transport_melt = cold_transport_melt;
    ctx.NB           = nb_arr.ptr();
    ctx.IW           = s_iswater.arr_u8.ptr();
    ctx.POSX         = s_pos_x.arr_f32.ptr();
    ctx.POSY         = s_pos_y.arr_f32.ptr();
    ctx.OCX          = ocx_arr.ptr();
    ctx.OCY          = ocy_arr.ptr();
    ctx.BL           = baseline_arr.ptr();
    ctx.TB           = temp_before_arr.ptr();
    ctx.SIF          = s_sea_ice.arr_f32.ptr();
    ctx.T_RO         = s_temp.arr_f32.ptr();
    ctx.OANOM_SLOT   = s_oanom.arr_f32.ptrw();
    ctx.AOUT         = anomaly_out.ptrw();

    // S3: 留存生产这一轮真实用过的标量。漏记的后果不只是 worker 吃默认 knobs ——
    // prod_knobs 诊断位也不会置，于是看起来像“这个 pass 根本没跑”。
    // native daily graph 默认走的就是 thread 变体，所以漏在这里最隐蔽。
    record_production_round_scalars(0x04, knobs);
    record_production_ocean_water_input(n_cells, baseline_arr.ptr(), temp_before_arr.ptr());

    auto t0 = std::chrono::high_resolution_clock::now();
    (void)n_tasks;

    // 与 scalar / worker 同一份内核。thread 变体此前走 ocean_water_compute_one
    // 平行实现；公式已经对齐，但任何后续改动都会再次分叉。并行只留在 ENSO 之外。
    pk_run_ocean_water_pure(
        n_cells, advect_steps, heat_mix, wrap_period_x,
        tta_source_cap, tta_blend_rate, tta_zero_current_decay,
        cold_transport_form, cold_transport_melt,
        ctx.IW, ctx.POSX, ctx.POSY, ctx.OCX, ctx.OCY,
        ctx.BL, ctx.TB, ctx.SIF, ctx.NB, ctx.OANOM_SLOT, ctx.AOUT);

    const uint8_t *enso_terrain = sid_terrain >= 0 && _slots.write[sid_terrain].arr_u8.size() == n_cells
        ? _slots.write[sid_terrain].arr_u8.ptr() : nullptr;
    const float *enso_lat = sid_lat >= 0 && _slots.write[sid_lat].arr_f32.size() == n_cells
        ? _slots.write[sid_lat].arr_f32.ptr() : nullptr;
    const float *enso_wx = sid_wind_x >= 0 && _slots.write[sid_wind_x].arr_f32.size() == n_cells
        ? _slots.write[sid_wind_x].arr_f32.ptr() : nullptr;
    const float *enso_wspd = sid_wind_spd >= 0 && _slots.write[sid_wind_spd].arr_f32.size() == n_cells
        ? _slots.write[sid_wind_spd].arr_f32.ptr() : nullptr;
    _apply_enso_ocean_slice(knobs, n_cells, 0, n_cells, ctx.IW, enso_terrain,
                            enso_lat, ctx.POSX, ctx.NB, enso_wx, enso_wspd,
                            ctx.OANOM_SLOT, ctx.AOUT);

    knobs["anomaly_out"] = anomaly_out;
    _flush_slot_to_map(sid_oanom);

    auto t1 = std::chrono::high_resolution_clock::now();
    return std::chrono::duration<double, std::milli>(t1 - t0).count();
}

// ─── ocean_land SIMD + Thread ───────────────────────────────────────────────
namespace {

struct OceanLandCtx {
    int             n_cells;
    float           effective_leak;
    // seam-advection-fix：经度环绕周期，0 = 无环绕域（退化为裸差分）。
    float           wrap_period_x;
    float           tta_source_cap;
    float           tta_blend_rate;
    float           tta_decay_rate;
    const int32_t  *NB;        // n_cells * 6
    const uint8_t  *IW;        // n_cells
    const float    *POSX;      // n_cells
    const float    *POSY;      // n_cells
    const float    *OCX;       // n_cells
    const float    *OCY;       // n_cells
    const float    *FBL;       // fallback_baseline, n_cells
    // A 修复（2026-06）：T 已不再被写；保留只读供未来诊断。
    const float    *T_RO;
    float          *OANOM_SLOT;// cell_ocean_thermal_anomaly inout
    float          *A;         // anomaly_inout, n_cells (land cells written, read water nbs)
};

// 单 cell hot kernel：完整复刻 run_ocean_land_pass 主循环 body（line 3309-3355）。
// IW[i]==0 已由 idx 预筛保证，外层无分支。
inline void ocean_land_compute_one(const OceanLandCtx &c, int i) {
    const float swx = c.POSX[i];
    const float swy = c.POSY[i];
    float weighted_sum = 0.0f;
    float weight_total = 0.0f;
    const int b = i * 6;
    for (int d = 0; d < 6; ++d) {
        const int32_t ni = c.NB[b + d];
        if (ni < 0) continue;
        if (c.IW[ni] == 0) continue; // only water nb contributes
        const float cx = c.OCX[ni];
        const float cy = c.OCY[ni];
        if (cx * cx + cy * cy < 1e-6f) continue;
        const float dx = pk_wrap_min_image_dx(swx - c.POSX[ni], c.wrap_period_x);
        const float dy = swy - c.POSY[ni];
        const float dlen2 = dx * dx + dy * dy;
        if (dlen2 < 1e-6f) continue;
        const float inv_len = 1.0f / std::sqrt(dlen2);
        const float dot_v = (dx * cx + dy * cy) * inv_len;
        if (dot_v <= 0.0f) continue;
        weighted_sum += c.A[ni] * dot_v;
        weight_total += dot_v;
    }
    const float prev_anomaly = c.A[i];
    float anomaly_in = dc_decay_tta(prev_anomaly, c.tta_decay_rate);
    if (weight_total > 0.0f) {
        anomaly_in = dc_stabilize_tta(
            prev_anomaly, (weighted_sum / weight_total) * c.effective_leak,
            c.tta_source_cap, c.tta_blend_rate);
    }
    c.A[i] = anomaly_in;
    // A 修复（2026-06）：land cell 累加 anomaly_in 到 ocean thermal anomaly slot；不再改写 cell_temp。
    const float abs_anom = (anomaly_in < 0.0f) ? -anomaly_in : anomaly_in;
    if (abs_anom > 1e-5f) {
        float oanom = c.OANOM_SLOT[i] + anomaly_in;
        if (oanom < -0.08f) oanom = -0.08f;
        else if (oanom > 0.08f) oanom = 0.08f;
        c.OANOM_SLOT[i] = oanom;
    }
}

inline void ocean_land_run_land_range(const OceanLandCtx &c,
                                      const int *land_idx,
                                      int begin, int end) {
    for (int k = begin; k < end; ++k) {
        ocean_land_compute_one(c, land_idx[k]);
    }
}

// [Phase C.3b] 原 OceanLandTask + ocean_land_worker 已由 parallel_dispatcher.h
// 内的 parallel_for_range 取代。

} // anonymous namespace (ocean land helpers)


double DCWorldExt::run_ocean_land_pass_thread(Dictionary knobs, int n_tasks) {
    using godot::StringName;
    using godot::PackedFloat32Array;
    using godot::PackedInt32Array;

    auto diag = [&](const char *why) {
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_ocean_land_pass_thread: ", why,
            " — fallback to GDScript");
    };

    if (!_bound) { diag("not _bound"); return -1.0; }

    const int sid_temp     = component_id(StringName("cell_temp"));
    const int sid_iswater  = component_id(StringName("cell_is_water"));
    const int sid_pos_x    = component_id(StringName("cell_pos_x"));
    const int sid_pos_y    = component_id(StringName("cell_pos_y"));
    // A 修复（2026-06）：ocean_land SIMD 改累加 ocean thermal anomaly slot。
    const int sid_oanom    = component_id(StringName("cell_ocean_thermal_anomaly"));
    if (sid_temp < 0 || sid_iswater < 0 || sid_pos_x < 0 || sid_pos_y < 0 || sid_oanom < 0) {
        diag("missing slot id"); return -1.0;
    }

    if (!knobs.has("n_cells") || !knobs.has("effective_leak") ||
        !knobs.has("neighbor_indices") || !knobs.has("anomaly_inout") ||
        !knobs.has("fallback_baseline_arr") ||
        !knobs.has("ocean_current_x_arr") || !knobs.has("ocean_current_y_arr")) {
        diag("knobs missing"); return -1.0;
    }
    const int   n_cells        = int(knobs["n_cells"]);
    const float effective_leak = float(knobs["effective_leak"]);
    // seam-advection-fix：经度环绕周期，缺省取 configure_native_world 常驻值。
    const float wrap_period_x = knobs.has("wrap_period_x")
        ? float(knobs["wrap_period_x"]) : float(_native_wrap_period_x);
    float tta_source_cap = knobs.has("tta_source_cap") ? float(knobs["tta_source_cap"]) : 0.22f;
    float tta_blend_rate = knobs.has("tta_blend_rate") ? float(knobs["tta_blend_rate"]) : 0.70f;
    float tta_decay_rate = knobs.has("tta_decay_rate") ? float(knobs["tta_decay_rate"]) : 0.04f;
    tta_source_cap = dc_clampf(tta_source_cap, 0.0f, 0.5f);
    tta_blend_rate = dc_clampf(tta_blend_rate, 0.0f, 1.0f);
    tta_decay_rate = dc_clampf(tta_decay_rate, 0.0f, 1.0f);
    if (n_cells <= 0) { diag("n_cells <= 0"); return -1.0; }

    PackedInt32Array nb_arr = knobs["neighbor_indices"];
    PackedFloat32Array fallback_baseline = knobs["fallback_baseline_arr"];
    PackedFloat32Array ocx_arr = knobs["ocean_current_x_arr"];
    PackedFloat32Array ocy_arr = knobs["ocean_current_y_arr"];
    if (nb_arr.size() < n_cells * 6)         { diag("nb size"); return -1.0; }
    if (fallback_baseline.size() != n_cells) { diag("fbl size"); return -1.0; }
    if (ocx_arr.size()       != n_cells)     { diag("ocx size"); return -1.0; }
    if (ocy_arr.size()       != n_cells)     { diag("ocy size"); return -1.0; }

    PackedFloat32Array anomaly_src = knobs["anomaly_inout"];
    if (anomaly_src.size() != n_cells) { diag("anomaly size"); return -1.0; }
    PackedFloat32Array anomaly_inout = anomaly_src.duplicate();

    Slot &s_temp    = _slots.write[sid_temp];
    Slot &s_iswater = _slots.write[sid_iswater];
    Slot &s_pos_x   = _slots.write[sid_pos_x];
    Slot &s_pos_y   = _slots.write[sid_pos_y];
    Slot &s_oanom   = _slots.write[sid_oanom];
    if (s_temp.arr_f32.size()  != n_cells || s_iswater.arr_u8.size() != n_cells ||
        s_pos_x.arr_f32.size() != n_cells || s_pos_y.arr_f32.size()  != n_cells ||
        s_oanom.arr_f32.size() != n_cells) {
        diag("slot size"); return -1.0;
    }

    OceanLandCtx ctx{};
    ctx.n_cells        = n_cells;
    ctx.effective_leak = effective_leak;
    ctx.wrap_period_x  = wrap_period_x;
    ctx.tta_source_cap = tta_source_cap;
    ctx.tta_blend_rate = tta_blend_rate;
    ctx.tta_decay_rate = tta_decay_rate;
    ctx.NB             = nb_arr.ptr();
    ctx.IW             = s_iswater.arr_u8.ptr();
    ctx.POSX           = s_pos_x.arr_f32.ptr();
    ctx.POSY           = s_pos_y.arr_f32.ptr();
    ctx.OCX            = ocx_arr.ptr();
    ctx.OCY            = ocy_arr.ptr();
    ctx.FBL            = fallback_baseline.ptr();
    ctx.T_RO           = s_temp.arr_f32.ptr();
    ctx.OANOM_SLOT     = s_oanom.arr_f32.ptrw();
    ctx.A              = anomaly_inout.ptrw();

    // S3: 留存生产这一轮真实用过的标量。漏记的后果不只是 worker 吃默认 knobs ——
    // prod_knobs 诊断位也不会置，于是看起来像“这个 pass 根本没跑”。
    // native daily graph 默认走的就是 thread 变体，所以漏在这里最隐蔽。
    record_production_round_scalars(0x08, knobs);

    auto t0 = std::chrono::high_resolution_clock::now();
    (void)n_tasks;

    pk_run_ocean_land_pure(
        n_cells, effective_leak, wrap_period_x,
        tta_source_cap, tta_blend_rate, tta_decay_rate,
        ctx.IW, ctx.POSX, ctx.POSY, ctx.OCX, ctx.OCY, ctx.NB,
        ctx.A, ctx.OANOM_SLOT);

    knobs["anomaly_inout"] = anomaly_inout;
    _flush_slot_to_map(sid_oanom);

    auto t1 = std::chrono::high_resolution_clock::now();
    return std::chrono::duration<double, std::milli>(t1 - t0).count();
}

// ─── F.4 main pass ──────────────────────────────────────────────────────────
//
// 1:1 mirror of map_generator.gd::_apply_sea_ice_daily_pass (line 3856-3980).
// 2-phase: (A) has_cold_neighbor snapshot using prev-day sea_ice_fraction;
//          (B) fraction increment + flip-list collection.
//
// terrain 翻转**不**在 C++ 端写——只输出 flip lists，由 GDScript apply_terrain
// 维护 multi-axis 同步（passable_land / passable_sea / landform 等派生字段）。
// 这是 charter §2.5 STRUCT-001 反模式规避：C++ 不应直接改 multi-axis enum。
// sea_ice_smoothstep / sea_ice_freeze_gate / sea_ice_solar_melt /
// sea_ice_solar_exposure / sea_ice_positive_tta_residual 已在 S3 搬到
// runtime_climate_pass_math.h。

double DCWorldExt::run_sea_ice_daily_pass(Dictionary knobs, float season_phase) {
    using godot::StringName;
    using godot::PackedFloat32Array;
    using godot::PackedInt32Array;
    using godot::PackedByteArray;

    auto diag = [&](const char *why) {
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_sea_ice_daily_pass: ", why,
            " — fallback to GDScript");
    };

    if (!_bound) { diag("not _bound"); return -1.0; }
    (void) season_phase; // 当前算法未直接使用，仅 GDScript 端 throttled print 用

    // 注意：cell_temp slot **不**能直接读——pass_b/ocean_water/ocean_land 是
    // C++ 跑、写 SoA 不回写 cell.temperature；GDScript 1:1 mirror 读 cell.temperature
    // 拿到的是 pass_a 之后的"基线温度"（更暖），SoA cell_temp 是 ocean_land 之后
    // 的"修正温度"（更冷）。读错温度 → sea_ice 算冰过多 → 全图下雪。
    // 修复：GDScript fast-path 必须从 cell.temperature 打包成 cell_temperature_arr
    // 传入 knobs，C++ 读这个 PackedArray 而非 SoA。
    const int sid_sea_ice  = component_id(StringName("cell_sea_ice_frac"));
    const int sid_terrain  = component_id(StringName("cell_terrain"));
    const int sid_oanom    = component_id(StringName("cell_ocean_thermal_anomaly"));
    if (sid_sea_ice < 0 || sid_terrain < 0 || sid_oanom < 0) {
        diag("missing slot id (cell_sea_ice_frac / cell_terrain / cell_ocean_thermal_anomaly)");
        return -1.0;
    }

    static const char *required_keys[] = {
        "n_cells", "k_freeze", "k_melt", "t_form", "t_melt", "contagion",
        "threshold", "hysteresis", "ice_delay", "enable_ocean_heat_transport",
        "terrain_lake_id", "terrain_sea_ice_id", "terrain_ocean_id",
        "water_terrain_ids", // PackedByteArray，与 GDScript _is_water 1:1 对齐
        "neighbor_indices", "base_terrain_arr",
        "temp_transport_anomaly", "upwelling_strength",
        "insolation_now_arr", "solar_gate_enabled",
        "freeze_insol_low", "freeze_insol_high",
        "solar_melt_start", "solar_melt_gain",
        "cell_temperature_arr", // climate/ocean-adjusted temperature; no direct season signal here
    };
    for (const char *k : required_keys) {
        if (!knobs.has(k)) {
            UtilityFunctions::push_warning(
                "[DCWorldExt] run_sea_ice_daily_pass: knobs missing key '", k,
                "' — fallback to GDScript");
            return -1.0;
        }
    }

    const int   n_cells     = int(knobs["n_cells"]);
    const float k_freeze    = float(knobs["k_freeze"]);
    const float k_melt      = float(knobs["k_melt"]);
    const float t_form      = float(knobs["t_form"]);
    const float t_melt      = float(knobs["t_melt"]);
    const float contagion   = float(knobs["contagion"]);
    const float threshold   = float(knobs["threshold"]);
    const float hysteresis  = float(knobs["hysteresis"]);
    const float ice_delay   = float(knobs["ice_delay"]);
    const bool  enable_oht  = bool(knobs["enable_ocean_heat_transport"]);
    const bool  apply_terrain_flips = bool(knobs.get("apply_terrain_flips", false));
    const bool  solar_gate_enabled = bool(knobs["solar_gate_enabled"]);
    const float freeze_insol_low = float(knobs["freeze_insol_low"]);
    const float freeze_insol_high = float(knobs["freeze_insol_high"]);
    const float solar_melt_start = float(knobs["solar_melt_start"]);
    const float solar_melt_gain = float(knobs["solar_melt_gain"]);
    const float min_thick_ice_solar_exposure = knobs.has("min_thick_ice_solar_exposure") ? float(knobs["min_thick_ice_solar_exposure"]) : 0.32f;
    const float daily_delta_cap = knobs.has("daily_delta_cap") ? float(knobs["daily_delta_cap"]) : 0.070f;
    float edge_mix_rate = knobs.has("edge_mix_rate") ? float(knobs["edge_mix_rate"]) : 0.035f;
    if (edge_mix_rate < 0.0f) edge_mix_rate = 0.0f;
    else if (edge_mix_rate > 0.20f) edge_mix_rate = 0.20f;
    const int   id_lake     = int(knobs["terrain_lake_id"]);
    const int   id_sea_ice  = int(knobs["terrain_sea_ice_id"]);
    const int   id_ocean    = int(knobs["terrain_ocean_id"]);
    if (n_cells <= 0) { diag("n_cells <= 0"); return -1.0; }

    // [S2 fix 2026-05-23] dt_days：optional knob。缺省 1.0 → 与历史 1:1 兼容；
    // GDScript 端用 WorldClock.current_day 算"上次到本次的真实游戏天数差"。
    // clamp [0, 30] 与 GDScript 端一致，防意外越界。详见 GDScript 入口注释。
    float dt_days = 1.0f;
    if (knobs.has("dt_days")) {
        dt_days = float(knobs["dt_days"]);
        if (dt_days < 0.0f) dt_days = 0.0f;
        else if (dt_days > 30.0f) dt_days = 30.0f;
    }

    PackedInt32Array  nb_arr   = knobs["neighbor_indices"];
    PackedByteArray   base_terr_arr = knobs["base_terrain_arr"];
    PackedFloat32Array tta_arr = knobs["temp_transport_anomaly"];
    PackedFloat32Array upw_arr = knobs["upwelling_strength"];
    PackedFloat32Array insol_arr = knobs["insolation_now_arr"];
    PackedByteArray   water_ids_arr = knobs["water_terrain_ids"];
    PackedFloat32Array cell_temp_arr = knobs["cell_temperature_arr"];
    if (nb_arr.size() < n_cells * 6) { diag("neighbor_indices size < n_cells * 6"); return -1.0; }
    if (base_terr_arr.size() < n_cells) { diag("base_terrain_arr size < n_cells"); return -1.0; }
    if (tta_arr.size() < n_cells)       { diag("temp_transport_anomaly size < n_cells"); return -1.0; }
    if (upw_arr.size() < n_cells)       { diag("upwelling_strength size < n_cells"); return -1.0; }
    if (insol_arr.size() < n_cells)     { diag("insolation_now_arr size < n_cells"); return -1.0; }
    if (water_ids_arr.size() <= 0)      { diag("water_terrain_ids empty"); return -1.0; }
    if (cell_temp_arr.size() < n_cells) { diag("cell_temperature_arr size < n_cells"); return -1.0; }

    // Build a 256-entry lookup table for is_water(terrain). Faster than
    // linear scan inside hot loop, and trivially extensible if GDScript
    // _is_water adds more terrain ids.
    bool is_water_lut[256];
    for (int i = 0; i < 256; ++i) is_water_lut[i] = false;
    for (int k = 0; k < water_ids_arr.size(); ++k) {
        const int wid = int(water_ids_arr[k]);
        if (wid >= 0 && wid < 256) is_water_lut[wid] = true;
    }

    Slot &s_sea_ice = _slots.write[sid_sea_ice];
    Slot &s_terrain = _slots.write[sid_terrain];
    Slot &s_oanom   = _slots.write[sid_oanom];
    if (s_sea_ice.arr_f32.size() != n_cells ||
        s_terrain.arr_u8.size()  != n_cells ||
        s_oanom.arr_f32.size()   != n_cells) {
        diag("slot array size mismatch (re-bind needed?)");
        return -1.0;
    }

    const uint8_t * const __restrict TR   = s_terrain.arr_u8.ptr();
    // T 从 knobs["cell_temperature_arr"] 拿（与 GDScript fallback 1:1 mirror）；
    // **不**读 SoA cell_temp slot（ocean_land 之后的修正温度，与 GDScript 看到的不同）。
    const float   * const __restrict T    = cell_temp_arr.ptr();
    float         * const __restrict SIF  = s_sea_ice.arr_f32.ptrw();
    const int32_t * const __restrict NB   = nb_arr.ptr();
    const uint8_t * const __restrict BT   = base_terr_arr.ptr();
    const float   * const __restrict TTA  = tta_arr.ptr();
    const float   * const __restrict OANOM = s_oanom.arr_f32.ptr();
    const float   * const __restrict UPW  = upw_arr.ptr();
    const float   * const __restrict INS  = insol_arr.ptr();

    // S3: 留存生产这一轮真实用过的标量，reference publish 时随 reference 发布给 worker。
    // 不写的后果是 worker 跑同一份共享内核、却吃结构默认 knobs。
    record_production_round_scalars(0x40, knobs);

    auto t0 = std::chrono::high_resolution_clock::now();

    // Phase A/B 都在共享内核里。worker 的 _async_sea_ice_kernel_pure 走同一份实现，
    // flip 列表与统计从 emit 取回后按老契约回填 knobs。
    pk_async_climate::SeaIceKnobs sk;
    sk.n_cells = n_cells;
    sk.k_freeze = k_freeze;
    sk.k_melt = k_melt;
    sk.t_form = t_form;
    sk.t_melt = t_melt;
    sk.contagion = contagion;
    sk.threshold = threshold;
    sk.hysteresis = hysteresis;
    sk.ice_delay = ice_delay;
    sk.enable_ocean_heat_transport = enable_oht;
    sk.solar_gate_enabled = solar_gate_enabled;
    sk.freeze_insol_low = freeze_insol_low;
    sk.freeze_insol_high = freeze_insol_high;
    sk.solar_melt_start = solar_melt_start;
    sk.solar_melt_gain = solar_melt_gain;
    sk.min_thick_ice_solar_exposure = min_thick_ice_solar_exposure;
    sk.daily_delta_cap = daily_delta_cap;
    sk.edge_mix_rate = edge_mix_rate;
    sk.dt_days = dt_days;
    sk.terrain_lake_id = id_lake;
    sk.terrain_sea_ice_id = id_sea_ice;
    sk.terrain_ocean_id = id_ocean;

    pk_async_climate::SeaIceLanes sl;
    sl.terrain = TR;
    sl.base_terrain = BT;
    sl.cell_temperature = T;
    sl.temp_transport_anomaly = TTA;
    sl.ocean_thermal_anomaly = OANOM;
    sl.upwelling_strength = UPW;
    sl.insolation_now = INS;
    sl.water_terrain_ids = water_ids_arr.ptr();
    sl.water_terrain_ids_size = int(water_ids_arr.size());
    sl.neighbor_indices = NB;
    sl.sea_ice_frac = SIF;
    record_production_sea_ice_input(sl, n_cells);

    pk_async_climate::SeaIceScratch scratch;
    pk_async_climate::SeaIceEmit emit;
    pk_async_climate::sea_ice_pure(sk, sl, scratch, emit);

    PackedInt32Array  flip_to_ice;
    PackedInt32Array  flip_to_base;
    PackedByteArray   flip_to_base_terrain;
    flip_to_ice.resize(int(emit.flip_to_ice.size()));
    if (!emit.flip_to_ice.empty()) {
        std::memcpy(flip_to_ice.ptrw(), emit.flip_to_ice.data(),
                    emit.flip_to_ice.size() * sizeof(int32_t));
    }
    flip_to_base.resize(int(emit.flip_to_base.size()));
    flip_to_base_terrain.resize(int(emit.flip_to_base_terrain.size()));
    if (!emit.flip_to_base.empty()) {
        std::memcpy(flip_to_base.ptrw(), emit.flip_to_base.data(),
                    emit.flip_to_base.size() * sizeof(int32_t));
        std::memcpy(flip_to_base_terrain.ptrw(), emit.flip_to_base_terrain.data(),
                    emit.flip_to_base_terrain.size());
    }
    const int water_count   = emit.water_count;
    const int flipped_count = emit.flipped_count;

    // 写 SIF slot（cell_sea_ice_frac CoW-detached buffer 同步回 MapData）
    _flush_slot_to_map(sid_sea_ice);
    if (apply_terrain_flips && flipped_count > 0) {
        uint8_t * const __restrict TRW = s_terrain.arr_u8.ptrw();
        for (int i = 0; i < flip_to_ice.size(); ++i) {
            const int idx = int(flip_to_ice[i]);
            if (idx >= 0 && idx < n_cells) {
                TRW[idx] = uint8_t(id_sea_ice & 0xFF);
            }
        }
        for (int i = 0; i < flip_to_base.size(); ++i) {
            const int idx = int(flip_to_base[i]);
            if (idx >= 0 && idx < n_cells && i < flip_to_base_terrain.size()) {
                TRW[idx] = uint8_t(int(flip_to_base_terrain[i]) & 0xFF);
            }
        }
        _flush_slot_to_map(sid_terrain);
        _native_dirty_report["atlas_dirty"] = true;
        _native_dirty_report["sea_ice_atlas_dirty"] = true;
        _native_dirty_report["sea_ice_terrain_flip_count"] = flipped_count;
    }

    // 输出回填到 knobs（让 GDScript caller 拿到 flip 列表 + 统计）
    knobs["flip_to_ice_list"]     = flip_to_ice;
    knobs["flip_to_base_list"]    = flip_to_base;
    knobs["flip_to_base_terrain"] = flip_to_base_terrain;
    knobs["stat_water_count"]     = water_count;
    knobs["stat_flipped_count"]   = flipped_count;

    auto t1 = std::chrono::high_resolution_clock::now();
    return std::chrono::duration<double, std::milli>(t1 - t0).count();
}

// ─── [Phase C.3d] sea_ice 并行变体 ─────────────────────────────────────────
//
// 完整复制 run_sea_ice_daily_pass 的 prelude，主体两阶段：
//   Phase A: cold_neighbor 快照（cell-local 读写 has_cold_neighbor[i]） →
//            走 pk::parallel_for_range，无 emit。
//   Phase B: 主循环（cell-local 读写 SIF + emit 3 个 flip lists + 2 counter） →
//            走 pk::parallel_for_range_with_emit，thread-local Emit reduce。
//
// emit reduce 顺序：每 task 内部按 cell idx 升序 push → 按 task_idx 升序 merge_into
// global → 全局顺序 == scalar bit-equal。counters 直接累加。
double DCWorldExt::run_sea_ice_daily_pass_thread(Dictionary knobs, float season_phase, int n_tasks) {
    using godot::StringName;
    using godot::PackedFloat32Array;
    using godot::PackedInt32Array;
    using godot::PackedByteArray;

    auto diag = [&](const char *why) {
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_sea_ice_daily_pass_thread: ", why,
            " — fallback to GDScript");
    };

    if (!_bound) { diag("not _bound"); return -1.0; }
    (void) season_phase;

    const int sid_sea_ice = component_id(StringName("cell_sea_ice_frac"));
    const int sid_terrain = component_id(StringName("cell_terrain"));
    const int sid_oanom   = component_id(StringName("cell_ocean_thermal_anomaly"));
    if (sid_sea_ice < 0 || sid_terrain < 0 || sid_oanom < 0) {
        diag("missing slot id (cell_sea_ice_frac / cell_terrain / cell_ocean_thermal_anomaly)");
        return -1.0;
    }

    static const char *required_keys[] = {
        "n_cells", "k_freeze", "k_melt", "t_form", "t_melt", "contagion",
        "threshold", "hysteresis", "ice_delay", "enable_ocean_heat_transport",
        "terrain_lake_id", "terrain_sea_ice_id", "terrain_ocean_id",
        "water_terrain_ids",
        "neighbor_indices", "base_terrain_arr",
        "temp_transport_anomaly", "upwelling_strength",
        "insolation_now_arr", "solar_gate_enabled",
        "freeze_insol_low", "freeze_insol_high",
        "solar_melt_start", "solar_melt_gain",
        "cell_temperature_arr",
    };
    for (const char *k : required_keys) {
        if (!knobs.has(k)) {
            UtilityFunctions::push_warning(
                "[DCWorldExt] run_sea_ice_daily_pass_thread: knobs missing key '", k,
                "' — fallback to GDScript");
            return -1.0;
        }
    }

    const int   n_cells     = int(knobs["n_cells"]);
    const float k_freeze    = float(knobs["k_freeze"]);
    const float k_melt      = float(knobs["k_melt"]);
    const float t_form      = float(knobs["t_form"]);
    const float t_melt      = float(knobs["t_melt"]);
    const float contagion   = float(knobs["contagion"]);
    const float threshold   = float(knobs["threshold"]);
    const float hysteresis  = float(knobs["hysteresis"]);
    const float ice_delay   = float(knobs["ice_delay"]);
    const bool  enable_oht  = bool(knobs["enable_ocean_heat_transport"]);
    const bool  solar_gate_enabled = bool(knobs["solar_gate_enabled"]);
    const float freeze_insol_low = float(knobs["freeze_insol_low"]);
    const float freeze_insol_high = float(knobs["freeze_insol_high"]);
    const float solar_melt_start = float(knobs["solar_melt_start"]);
    const float solar_melt_gain = float(knobs["solar_melt_gain"]);
    const float min_thick_ice_solar_exposure = knobs.has("min_thick_ice_solar_exposure") ? float(knobs["min_thick_ice_solar_exposure"]) : 0.32f;
    const float daily_delta_cap = knobs.has("daily_delta_cap") ? float(knobs["daily_delta_cap"]) : 0.070f;
    float edge_mix_rate = knobs.has("edge_mix_rate") ? float(knobs["edge_mix_rate"]) : 0.035f;
    if (edge_mix_rate < 0.0f) edge_mix_rate = 0.0f;
    else if (edge_mix_rate > 0.20f) edge_mix_rate = 0.20f;
    const int   id_lake     = int(knobs["terrain_lake_id"]);
    const int   id_sea_ice  = int(knobs["terrain_sea_ice_id"]);
    const int   id_ocean    = int(knobs["terrain_ocean_id"]);
    if (n_cells <= 0) { diag("n_cells <= 0"); return -1.0; }

    // [S2 fix 2026-05-23] dt_days：与 scalar 路径同步（optional, default 1.0）。
    float dt_days = 1.0f;
    if (knobs.has("dt_days")) {
        dt_days = float(knobs["dt_days"]);
        if (dt_days < 0.0f) dt_days = 0.0f;
        else if (dt_days > 30.0f) dt_days = 30.0f;
    }

    PackedInt32Array  nb_arr   = knobs["neighbor_indices"];
    PackedByteArray   base_terr_arr = knobs["base_terrain_arr"];
    PackedFloat32Array tta_arr = knobs["temp_transport_anomaly"];
    PackedFloat32Array upw_arr = knobs["upwelling_strength"];
    PackedFloat32Array insol_arr = knobs["insolation_now_arr"];
    PackedByteArray   water_ids_arr = knobs["water_terrain_ids"];
    PackedFloat32Array cell_temp_arr = knobs["cell_temperature_arr"];
    if (nb_arr.size() < n_cells * 6) { diag("neighbor_indices size < n_cells * 6"); return -1.0; }
    if (base_terr_arr.size() < n_cells) { diag("base_terrain_arr size < n_cells"); return -1.0; }
    if (tta_arr.size() < n_cells)       { diag("temp_transport_anomaly size < n_cells"); return -1.0; }
    if (upw_arr.size() < n_cells)       { diag("upwelling_strength size < n_cells"); return -1.0; }
    if (insol_arr.size() < n_cells)     { diag("insolation_now_arr size < n_cells"); return -1.0; }
    if (water_ids_arr.size() <= 0)      { diag("water_terrain_ids empty"); return -1.0; }
    if (cell_temp_arr.size() < n_cells) { diag("cell_temperature_arr size < n_cells"); return -1.0; }

    Slot &s_sea_ice = _slots.write[sid_sea_ice];
    Slot &s_terrain = _slots.write[sid_terrain];
    Slot &s_oanom   = _slots.write[sid_oanom];
    if (s_sea_ice.arr_f32.size() != n_cells ||
        s_terrain.arr_u8.size()  != n_cells ||
        s_oanom.arr_f32.size()   != n_cells) {
        diag("slot array size mismatch (re-bind needed?)");
        return -1.0;
    }

    const uint8_t * const __restrict TR   = s_terrain.arr_u8.ptr();
    const float   * const __restrict T    = cell_temp_arr.ptr();
    float         * const __restrict SIF  = s_sea_ice.arr_f32.ptrw();
    const int32_t * const __restrict NB   = nb_arr.ptr();
    const uint8_t * const __restrict BT   = base_terr_arr.ptr();
    const float   * const __restrict TTA  = tta_arr.ptr();
    const float   * const __restrict OANOM = s_oanom.arr_f32.ptr();
    const float   * const __restrict UPW  = upw_arr.ptr();
    const float   * const __restrict INS  = insol_arr.ptr();

    // S3: 留存生产这一轮真实用过的标量。漏记的后果不只是 worker 吃默认 knobs ——
    // prod_knobs 诊断位也不会置，于是看起来像“这个 pass 根本没跑”。
    // native daily graph 默认走的就是 thread 变体，所以漏在这里最隐蔽。
    record_production_round_scalars(0x40, knobs);

    auto t0 = std::chrono::high_resolution_clock::now();

    // native daily 默认走这个 thread 变体。它此前是 2026-06-16 的单步
    // `d_frac = rate * dt_days` 抄本，而 scalar / worker 已经换成 sea_ice_pure
    // 的按日子步积分。dt_days≈8..10 时两边差一个数量级，sea_ice 因此在每一个
    // 真实对拍日都分叉。接到同一份内核之后，并行只是调度，不再是第二套物理。
    pk_async_climate::SeaIceKnobs sk;
    sk.n_cells = n_cells;
    sk.k_freeze = k_freeze;
    sk.k_melt = k_melt;
    sk.t_form = t_form;
    sk.t_melt = t_melt;
    sk.contagion = contagion;
    sk.threshold = threshold;
    sk.hysteresis = hysteresis;
    sk.ice_delay = ice_delay;
    sk.enable_ocean_heat_transport = enable_oht;
    sk.solar_gate_enabled = solar_gate_enabled;
    sk.freeze_insol_low = freeze_insol_low;
    sk.freeze_insol_high = freeze_insol_high;
    sk.solar_melt_start = solar_melt_start;
    sk.solar_melt_gain = solar_melt_gain;
    sk.min_thick_ice_solar_exposure = min_thick_ice_solar_exposure;
    sk.daily_delta_cap = daily_delta_cap;
    sk.edge_mix_rate = edge_mix_rate;
    sk.dt_days = dt_days;
    sk.terrain_lake_id = id_lake;
    sk.terrain_sea_ice_id = id_sea_ice;
    sk.terrain_ocean_id = id_ocean;

    pk_async_climate::SeaIceLanes sl;
    sl.terrain = TR;
    sl.base_terrain = BT;
    sl.cell_temperature = T;
    sl.temp_transport_anomaly = TTA;
    sl.ocean_thermal_anomaly = OANOM;
    sl.upwelling_strength = UPW;
    sl.insolation_now = INS;
    sl.water_terrain_ids = water_ids_arr.ptr();
    sl.water_terrain_ids_size = int(water_ids_arr.size());
    sl.neighbor_indices = NB;
    sl.sea_ice_frac = SIF;
    record_production_sea_ice_input(sl, n_cells);

    pk_async_climate::SeaIceScratch scratch;
    pk_async_climate::SeaIceEmit emit;
    pk_async_climate::sea_ice_pure(sk, sl, scratch, emit);
    (void)n_tasks;

    _flush_slot_to_map(sid_sea_ice);

    PackedInt32Array flip_to_ice;
    PackedInt32Array flip_to_base;
    PackedByteArray  flip_to_base_terrain;
    flip_to_ice.resize(int(emit.flip_to_ice.size()));
    if (!emit.flip_to_ice.empty()) {
        std::memcpy(flip_to_ice.ptrw(), emit.flip_to_ice.data(),
                    emit.flip_to_ice.size() * sizeof(int32_t));
    }
    flip_to_base.resize(int(emit.flip_to_base.size()));
    flip_to_base_terrain.resize(int(emit.flip_to_base_terrain.size()));
    if (!emit.flip_to_base.empty()) {
        std::memcpy(flip_to_base.ptrw(), emit.flip_to_base.data(),
                    emit.flip_to_base.size() * sizeof(int32_t));
        std::memcpy(flip_to_base_terrain.ptrw(), emit.flip_to_base_terrain.data(),
                    emit.flip_to_base_terrain.size());
    }

    knobs["flip_to_ice_list"]     = flip_to_ice;
    knobs["flip_to_base_list"]    = flip_to_base;
    knobs["flip_to_base_terrain"] = flip_to_base_terrain;
    knobs["stat_water_count"]     = emit.water_count;
    knobs["stat_flipped_count"]   = emit.flipped_count;

    auto t1 = std::chrono::high_resolution_clock::now();
    return std::chrono::duration<double, std::milli>(t1 - t0).count();
}

// ─── F.5 main pass ──────────────────────────────────────────────────────────
//
// Single-shot full sweep over [0, n_cells). 1:1 mirror of
// map_generator.gd::_apply_transpiration_pass (line 4938).
//
// Algorithm structure (2-phase to be order-insensitive):
//   Phase 1 — compute deltas (don't write to moisture yet):
//     for each land cell with veg.transpiration >= 0.01:
//       output      = transpiration[veg] * moisture
//       self_share  = output * self_rate
//       nb_share    = output * outflow_rate / 6
//       deltas[i]  += self_share
//       for each non-water neighbour: deltas[nb_idx] += nb_share
//   Phase 2 — apply deltas:
//     for each cell with delta != 0:
//       moisture = clamp(moisture + delta, 0, 1)
//
// LandformType.LF enum order (landform_type.gd:9-23): DEEP_OCEAN=0, OCEAN=1,
// COAST=2, LAKE=3 are water; PLAIN=4+ are land. So is_water iff lf <= 3.

} // namespace pk
