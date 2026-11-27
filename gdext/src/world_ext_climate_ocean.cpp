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
#include "world_ext_climate_ocean_section_water_kernels.inc"

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

#include "world_ext_climate_ocean_section_sea_ice.inc"

#include "world_ext_climate_ocean_section_raster_atlas.inc"

} // namespace pk
