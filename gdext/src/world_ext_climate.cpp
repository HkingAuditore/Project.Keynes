#include "world_ext.h"

#include "component_bind_table.gen.h"  // A1 / dots-migration-roadmap §3 — autogen by tools/codegen/gen_cpp_bind_table.py
#include "system_schedule.h"           // Phase C.1 — 静态 DAG 调度图
#include "parallel_dispatcher.h"       // Phase C.3a — 并行分发 helper（统一 5 个手写 _thread）
#include "modifier_runtime.h"

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

// pk_signed_hydrology_contribution / pk_plant_available_water 已在 S3 搬到
// runtime_climate_pass_math.h（经 world_ext_internal.h 传递可见）。


// Per-cell annual-mean insolation memo. dc_insolation_annual_mean integrates 16
// trig-heavy samples and depends ONLY on (cell latitude, axial_tilt, daylen) — all
// day-invariant — so recomputing it per cell per day was ~1.38ms/round of pure waste
// (the dominant cost of the climate_pass_a round-start slice). We rebuild only when a
// cheap FNV-1a fingerprint over (n, lat bits, axial_tilt, daylen) changes (≈ once, at
// map bind / planet-param change). Returns the cached value for cell i, which is
// bit-identical to the inline dc_insolation_annual_mean(dc_clamp01f(lat[i]), ...).
const float *DCWorldExt::ensure_insol_annual_mean_cache(const float *lat_ptr, int n,
                                                        float axial_tilt_deg, float daylen_amp) {
    uint64_t fp = 1469598103934665603ull; // FNV-1a offset basis
    auto mix = [&fp](uint32_t bits) {
        fp ^= uint64_t(bits);
        fp *= 1099511628211ull; // FNV-1a prime
    };
    mix(uint32_t(n));
    {
        uint32_t b;
        std::memcpy(&b, &axial_tilt_deg, sizeof(b));
        mix(b);
        std::memcpy(&b, &daylen_amp, sizeof(b));
        mix(b);
    }
    for (int i = 0; i < n; ++i) {
        uint32_t b;
        std::memcpy(&b, &lat_ptr[i], sizeof(b));
        mix(b);
    }
    if (_insol_cache_valid && _insol_cache_fingerprint == fp &&
        int(_insol_annual_mean_cache.size()) == n) {
        return _insol_annual_mean_cache.data();
    }
    _insol_annual_mean_cache.resize(n);
    for (int i = 0; i < n; ++i) {
        _insol_annual_mean_cache[i] =
            dc_insolation_annual_mean(dc_clamp01f(lat_ptr[i]), axial_tilt_deg, daylen_amp);
    }
    _insol_cache_fingerprint = fp;
    _insol_cache_valid = true;
    return _insol_annual_mean_cache.data();
}


double DCWorldExt::run_climate_pass_a(const Dictionary &cp_struct, double phase, double season_phase) {
    SimTraceWriteGuard sim_trace_guard{this, "run_climate_pass_a"};
    _production_stage_mask |= pk_async_climate::CLIMATE_STAGE_BIT_PASS_A;
    (void)phase; // current contract: phase == season_phase (same fast tick)

    // [Step 3b-1 DIAG] one-shot fallback-reason probe — prints exactly once
    // per process the FIRST time C++ rejects a call. Remove after the
    // mismatch is fixed and A= drops to <1ms.
    static bool _diag_printed = false;
    auto diag = [&](const char *reason) {
        if (!_diag_printed) {
            _diag_printed = true;
            UtilityFunctions::print(String("[DCWorldExt][diag] run_climate_pass_a fallback: ") + String(reason));
        }
    };

    // ─── 1. Hard preconditions ──────────────────────────────────────────
    if (!_bound) {
        diag("not _bound");
        return -1.0; // bind_map_data not yet called → GDScript legacy
    }

    // ─── 2. Resolve all 13 slot ids by StringName (BIND_TABLE keys) ─────
    // We resolve once per call (not per cell). If ANY of these is missing
    // we fall back: it means GDScript hasn't registered the climate SoA
    // yet, or the BIND_TABLE diverged.
    const int sid_temp           = component_id(StringName("cell_temp"));
    const int sid_moisture       = component_id(StringName("cell_moisture"));
    const int sid_temp_baseline  = component_id(StringName("cell_temp_baseline"));
    const int sid_temp_30d       = component_id(StringName("cell_temp_30d"));
    const int sid_temp_365d      = component_id(StringName("cell_temp_365d"));
    const int sid_temp_anom      = component_id(StringName("cell_temp_anomaly"));
    const int sid_temp_seas_off  = component_id(StringName("cell_temp_season_offset"));
    const int sid_elev           = component_id(StringName("cell_elevation"));
    const int sid_base_moist     = component_id(StringName("cell_base_moisture"));
    const int sid_lat_norm       = component_id(StringName("cell_lat_norm"));
    const int sid_temp_year      = component_id(StringName("cell_temp_baseline_year"));
    const int sid_is_water       = component_id(StringName("cell_is_water"));
    const int sid_terrain        = component_id(StringName("cell_terrain"));
    const int sid_cover          = component_id(StringName("cell_cover"));
    const int sid_ema_init       = component_id(StringName("cell_ema_initialized"));
    const int sid_insol_now      = component_id(StringName("cell_insolation_now"));
    const int sid_insol_dev      = component_id(StringName("cell_insolation_dev"));
    const int sid_day_length     = component_id(StringName("cell_day_length"));
    const int sid_heat_input     = component_id(StringName("cell_heat_input"));
    const int sid_thermal_energy = component_id(StringName("cell_thermal_energy"));
    const int sid_snowpack       = component_id(StringName("cell_snowpack"));
    // A 修复（2026-06）：anomaly 合成的两条新 slot；pass_a 末尾把它们置 0，
    // 由本日的 ocean/pass_b 后续累加，wind_surface 末端合成回 cell_temp。
    const int sid_ocean_anom     = component_id(StringName("cell_ocean_thermal_anomaly"));
    const int sid_local_anom     = component_id(StringName("cell_local_thermal_anomaly"));
    const int sid_weather_vapor   = component_id(StringName("cell_weather_vapor"));
    const int sid_weather_precip  = component_id(StringName("cell_weather_precip"));
    const int sid_soil_moisture   = component_id(StringName("cell_soil_moisture"));
    const int sid_water_balance   = component_id(StringName("cell_water_balance_30d"));

    if (sid_temp           < 0 || sid_moisture      < 0 ||
        sid_temp_baseline  < 0 || sid_temp_30d      < 0 || sid_temp_365d < 0 ||
        sid_temp_anom      < 0 || sid_temp_seas_off < 0 ||
        sid_elev           < 0 || sid_base_moist    < 0 ||
        sid_lat_norm       < 0 || sid_temp_year     < 0 ||
        sid_is_water       < 0 || sid_terrain       < 0 || sid_cover     < 0 ||
        sid_ema_init       < 0 || sid_insol_now     < 0 || sid_insol_dev < 0 ||
        sid_day_length     < 0 || sid_heat_input    < 0 ||
        sid_thermal_energy < 0 || sid_snowpack      < 0 ||
        sid_ocean_anom     < 0 || sid_local_anom    < 0) {
        diag("slot id <0 (some BIND_TABLE component missing)");
        return -1.0;
    }

    // ─── 3. Pull cp_struct scalars (with conservative defaults) ─────────
    if (!cp_struct.has("season_phase")) {
        diag("cp_struct missing season_phase");
        return -1.0;
    }
    const float  insol_amp      = cp_struct.has("insol_amp")
                                    ? float(cp_struct["insol_amp"]) : 0.20f;
    const float  insol_gain     = cp_struct.has("insol_gain")
                                    ? float(cp_struct["insol_gain"]) : 1.0f;
    const float  insol_amp_gain = insol_amp * insol_gain;
    const float  land_continentality = cp_struct.has("temp_land_continentality")
                                    ? float(cp_struct["temp_land_continentality"]) : 1.0f;
    const float  axial_tilt_deg = cp_struct.has("axial_tilt_deg")
                                    ? float(cp_struct["axial_tilt_deg"]) : 23.5f;
    const float  daylen_amp     = cp_struct.has("day_length_gain")
                                    ? float(cp_struct["day_length_gain"])
                                    : (cp_struct.has("insolation_daylen_amp")
                                        ? float(cp_struct["insolation_daylen_amp"]) : 0.35f);
    const float  solar_gain     = cp_struct.has("solar_gain")
                                    ? float(cp_struct["solar_gain"]) : 1.0f;
    const float  insol_dev_min  = cp_struct.has("insol_dev_min")
                                    ? float(cp_struct["insol_dev_min"]) : -1.0f;
    const float  insol_dev_max  = cp_struct.has("insol_dev_max")
                                    ? float(cp_struct["insol_dev_max"]) : 1.0f;
    const float  thermal_land   = cp_struct.has("thermal_inertia_land")
                                    ? float(cp_struct["thermal_inertia_land"]) : 0.35f;
    const float  thermal_water  = cp_struct.has("thermal_inertia_water")
                                    ? float(cp_struct["thermal_inertia_water"]) : 0.045f;
    const float  thermal_snow   = cp_struct.has("thermal_inertia_snow")
                                    ? float(cp_struct["thermal_inertia_snow"]) : 0.09f;
    const float  thermal_high   = cp_struct.has("thermal_inertia_high_mountain")
                                    ? float(cp_struct["thermal_inertia_high_mountain"]) : 0.16f;
    const float  thermal_delta_cap = cp_struct.has("thermal_daily_delta_cap")
                                    ? float(cp_struct["thermal_daily_delta_cap"]) : 0.15f;
    // 加速/跳日补偿：α 与 delta_cap 按经过天数积分（dt<=1 退化为原值）。
    float thermal_dt = cp_struct.has("thermal_dt_days")
                                    ? float(cp_struct["thermal_dt_days"]) : 1.0f;
    if (thermal_dt < 1.0f) thermal_dt = 1.0f;
    else if (thermal_dt > 30.0f) thermal_dt = 30.0f;
    const float  thermal_land_eff  = pk_thermal_alpha_eff(thermal_land,  thermal_dt);
    const float  thermal_water_eff = pk_thermal_alpha_eff(thermal_water, thermal_dt);
    const float  thermal_snow_eff  = pk_thermal_alpha_eff(thermal_snow,  thermal_dt);
    const float  thermal_high_eff  = pk_thermal_alpha_eff(thermal_high,  thermal_dt);
    const float  thermal_delta_cap_eff = thermal_delta_cap * thermal_dt;
    float moisture_relax = cp_struct.has("runtime_moisture_base_relax_rate")
                                    ? float(cp_struct["runtime_moisture_base_relax_rate"]) : 0.24f;
    if (moisture_relax < 0.0f) moisture_relax = 0.0f;
    else if (moisture_relax > 1.0f) moisture_relax = 1.0f;
    const float moisture_relax_eff = 1.0f - std::pow(1.0f - moisture_relax, thermal_dt);
    float moisture_vapor_w = cp_struct.has("runtime_moisture_weather_vapor_weight")
                                    ? float(cp_struct["runtime_moisture_weather_vapor_weight"]) : 0.12f;
    if (moisture_vapor_w < 0.0f) moisture_vapor_w = 0.0f;
    else if (moisture_vapor_w > 1.0f) moisture_vapor_w = 1.0f;
    float moisture_precip_w = cp_struct.has("runtime_moisture_precip_weight")
                                    ? float(cp_struct["runtime_moisture_precip_weight"]) : 0.78f;
    if (moisture_precip_w < 0.0f) moisture_precip_w = 0.0f;
    else if (moisture_precip_w > 2.5f) moisture_precip_w = 2.5f;
    float moisture_soil_w = cp_struct.has("runtime_moisture_soil_weight")
                                    ? float(cp_struct["runtime_moisture_soil_weight"]) : 1.82f;
    if (moisture_soil_w < 0.0f) moisture_soil_w = 0.0f;
    else if (moisture_soil_w > 2.5f) moisture_soil_w = 2.5f;
    float moisture_soil_dry_w = cp_struct.has("runtime_moisture_soil_dry_weight")
                                    ? float(cp_struct["runtime_moisture_soil_dry_weight"]) : 2.21f;
    if (moisture_soil_dry_w < 0.0f) moisture_soil_dry_w = 0.0f;
    else if (moisture_soil_dry_w > 2.5f) moisture_soil_dry_w = 2.5f;
    float moisture_wb_w = cp_struct.has("runtime_moisture_water_balance_weight")
                                    ? float(cp_struct["runtime_moisture_water_balance_weight"]) : 1.04f;
    if (moisture_wb_w < 0.0f) moisture_wb_w = 0.0f;
    else if (moisture_wb_w > 2.5f) moisture_wb_w = 2.5f;
    float moisture_wb_dry_w = cp_struct.has("runtime_moisture_water_balance_dry_weight")
                                    ? float(cp_struct["runtime_moisture_water_balance_dry_weight"]) : 1.30f;
    if (moisture_wb_dry_w < 0.0f) moisture_wb_dry_w = 0.0f;
    else if (moisture_wb_dry_w > 2.5f) moisture_wb_dry_w = 2.5f;
    const float  snowpack_cover_low = cp_struct.has("snowpack_cover_low")
                                    ? float(cp_struct["snowpack_cover_low"]) : 0.05f;
    // [climate-zone-fix P2] 沿海陆地海洋性调温：season_offset *= (1 - damp*maritime_factor)。
    // maritime_factor 为静态 per-cell 数组（cp_struct 传入，CoW 零拷贝）；damp=0→关闭=原行为。
    const float  maritime_damp  = cp_struct.has("maritime_season_damp")
                                    ? float(cp_struct["maritime_season_damp"]) : 0.0f;
    PackedFloat32Array maritime_arr;
    if (cp_struct.has("maritime_factor")) maritime_arr = cp_struct["maritime_factor"];
    const float  sea_level      = cp_struct.has("sea_level")
                                    ? float(cp_struct["sea_level"]) : 0.0f;
    int days_per_year = cp_struct.has("days_per_year") ? int(cp_struct["days_per_year"]) : 365;
    if (days_per_year < 1) days_per_year = 1;
    else if (days_per_year > 3660) days_per_year = 3660;
    const float annual_ema_alpha = 1.0f / float(days_per_year);
    // [dt-aware EMA 2026-06-28] temp_30d/365d 的 EMA alpha 按 thermal_dt(=本次经过游戏天数)等效缩放。
    // 旧实现固定用 1/30、1/365 的"每日"alpha，但 pass_a 在加速档下每次只调一次却推进 ~dt 天→两个 EMA
    // 窗口实际膨胀到 30·dt / 365·dt 天，m30 跟不上季节循环、与 m365 一起趋近年均→temp_anomaly 坍缩到≈0
    // →DROUGHT/HEATWAVE 结构性不可达。等效多日 alpha=1-(1-base)^dt；dt<=1 时恰为 base（逐位无回归）。
    const float ema_alpha_30  = (thermal_dt <= 1.0f) ? (1.0f / 30.0f)
                                    : (1.0f - std::pow(1.0f - 1.0f / 30.0f, thermal_dt));
    const float ema_alpha_365 = (thermal_dt <= 1.0f) ? annual_ema_alpha
                                    : (1.0f - std::pow(1.0f - annual_ema_alpha, thermal_dt));
    // ─── 5. Acquire array views & validate sizes ────────────────────────
    // arr_*.ptrw() on the *internal* slot data is the legitimate write
    // path — bind_map_data shared CoW with GDScript so writes propagate.
    PackedFloat32Array &temp_a          = _slots.write[sid_temp].arr_f32;
    PackedFloat32Array &moist_a         = _slots.write[sid_moisture].arr_f32;
    PackedFloat32Array &temp_baseline_a = _slots.write[sid_temp_baseline].arr_f32;
    PackedFloat32Array &temp_30d_a      = _slots.write[sid_temp_30d].arr_f32;
    PackedFloat32Array &temp_365d_a     = _slots.write[sid_temp_365d].arr_f32;
    PackedFloat32Array &temp_anom_a     = _slots.write[sid_temp_anom].arr_f32;
    PackedFloat32Array &season_off_a    = _slots.write[sid_temp_seas_off].arr_f32;
    PackedFloat32Array &elev_a          = _slots.write[sid_elev].arr_f32;
    PackedFloat32Array &base_moist_a    = _slots.write[sid_base_moist].arr_f32;
    PackedFloat32Array &lat_a           = _slots.write[sid_lat_norm].arr_f32;
    PackedFloat32Array &temp_year_a     = _slots.write[sid_temp_year].arr_f32;
    PackedByteArray    &is_water_a      = _slots.write[sid_is_water].arr_u8;
    PackedByteArray    &terrain_a       = _slots.write[sid_terrain].arr_u8;
    PackedByteArray    &cover_a         = _slots.write[sid_cover].arr_u8;
    PackedByteArray    &ema_init_a      = _slots.write[sid_ema_init].arr_u8;
    PackedFloat32Array &insol_now_a     = _slots.write[sid_insol_now].arr_f32;
    PackedFloat32Array &insol_dev_a     = _slots.write[sid_insol_dev].arr_f32;
    PackedFloat32Array &day_length_a    = _slots.write[sid_day_length].arr_f32;
    PackedFloat32Array &heat_input_a    = _slots.write[sid_heat_input].arr_f32;
    PackedFloat32Array &thermal_a       = _slots.write[sid_thermal_energy].arr_f32;
    PackedFloat32Array &snowpack_a      = _slots.write[sid_snowpack].arr_f32;
    // A 修复：anomaly 合成 slot — pass_a 末尾 fill 0，开启新一日累加。
    PackedFloat32Array &ocean_anom_a    = _slots.write[sid_ocean_anom].arr_f32;
    PackedFloat32Array &local_anom_a    = _slots.write[sid_local_anom].arr_f32;
    const PackedFloat32Array *weather_vapor_a = nullptr;
    const PackedFloat32Array *weather_precip_a = nullptr;
    const PackedFloat32Array *soil_moisture_a = nullptr;
    const PackedFloat32Array *water_balance_a = nullptr;

    const int n = temp_a.size();
    if (n <= 0) { diag("temp_a empty (n<=0)"); return -1.0; }

    // All cell-level arrays MUST be the same length. Anything mismatched
    // means the bind has gone stale (e.g. world resize without re-bind).
    if (moist_a.size()         != n ||
        temp_baseline_a.size() != n || temp_30d_a.size()  != n ||
        temp_365d_a.size()     != n || temp_anom_a.size() != n ||
        season_off_a.size()    != n || elev_a.size()      != n ||
        base_moist_a.size()    != n || lat_a.size()       != n ||
        temp_year_a.size()     != n || is_water_a.size()  != n ||
        terrain_a.size()       != n || cover_a.size()     != n ||
        ema_init_a.size()      != n || insol_now_a.size() != n ||
        insol_dev_a.size()     != n || day_length_a.size()!= n ||
        heat_input_a.size()    != n || thermal_a.size()   != n ||
        snowpack_a.size()      != n ||
        ocean_anom_a.size()    != n || local_anom_a.size() != n) {
        diag("slot array size mismatch (re-bind needed?)");
        return -1.0;
    }
    if (sid_weather_vapor >= 0 && _slots.write[sid_weather_vapor].arr_f32.size() == n) {
        weather_vapor_a = &_slots.write[sid_weather_vapor].arr_f32;
    }
    if (sid_weather_precip >= 0 && _slots.write[sid_weather_precip].arr_f32.size() == n) {
        weather_precip_a = &_slots.write[sid_weather_precip].arr_f32;
    }
    if (sid_soil_moisture >= 0 && _slots.write[sid_soil_moisture].arr_f32.size() == n) {
        soil_moisture_a = &_slots.write[sid_soil_moisture].arr_f32;
    }
    if (sid_water_balance >= 0 && _slots.write[sid_water_balance].arr_f32.size() == n) {
        water_balance_a = &_slots.write[sid_water_balance].arr_f32;
    }

    // ─── 6. Hot pointers (cached outside the loop) ──────────────────────
    float * const __restrict pt   = temp_a.ptrw();
    float * const __restrict pm   = moist_a.ptrw();
    float * const __restrict ptb  = temp_baseline_a.ptrw();
    float * const __restrict p30  = temp_30d_a.ptrw();
    float * const __restrict p365 = temp_365d_a.ptrw();
    float * const __restrict pa   = temp_anom_a.ptrw();
    float * const __restrict pso  = season_off_a.ptrw();
    const float * const      pe   = elev_a.ptr();
    const float * const      pbm  = base_moist_a.ptr();
    const float * const      pln  = lat_a.ptr();
    const float * const      pty  = temp_year_a.ptr();
    const uint8_t * const    piw  = is_water_a.ptr();
    const uint8_t * const    pterr= terrain_a.ptr();
    const uint8_t * const    pcov = cover_a.ptr();
    uint8_t * const __restrict pei = ema_init_a.ptrw();
    float * const __restrict pinsol = insol_now_a.ptrw();
    float * const __restrict pdev   = insol_dev_a.ptrw();
    float * const __restrict pday   = day_length_a.ptrw();
    float * const __restrict pheat  = heat_input_a.ptrw();
    float * const __restrict pthermal = thermal_a.ptrw();
    float * const __restrict psnowpack = snowpack_a.ptrw();
    // A 修复：anomaly 合成 slot 的写指针；pass_a 末尾全图清 0（开启新一日累加）。
    float * const __restrict poanom = ocean_anom_a.ptrw();
    float * const __restrict planom = local_anom_a.ptrw();
    const float * const pweatherv = weather_vapor_a != nullptr ? weather_vapor_a->ptr() : nullptr;
    const float * const pprecip = weather_precip_a != nullptr ? weather_precip_a->ptr() : nullptr;
    const float * const psoil = soil_moisture_a != nullptr ? soil_moisture_a->ptr() : nullptr;
    const float * const pwb = water_balance_a != nullptr ? water_balance_a->ptr() : nullptr;
    // [climate-zone-fix P2] 海洋性因子指针（缺省/关闭→nullptr，热循环跳过缩放）。
    const float * const pmar = (maritime_arr.size() == n && maritime_damp > 0.0f) ? maritime_arr.ptr() : nullptr;

    // Per-cell annual-mean insolation: memoized (day-invariant). See
    // ensure_insol_annual_mean_cache — bit-equal to recomputing it inline per cell.
    const float * const __restrict pinsol_mean =
        ensure_insol_annual_mean_cache(pln, n, axial_tilt_deg, daylen_amp);

    (void)pterr;
    (void)land_continentality; // season_offset_continental 按契约忽略它（见 runtime_climate_formulas.h）
    // 下面这些标量在 S3 之前由本函数自己的主循环消费；现在它们统一进 scalars，
    // 由共享内核使用。保留局部变量是为了让上面的 cp_struct 解析段一行不改。
    (void)insol_amp_gain;
    (void)thermal_land_eff;
    (void)thermal_water_eff;
    (void)thermal_snow_eff;
    (void)thermal_high_eff;
    (void)thermal_delta_cap_eff;
    (void)moisture_relax_eff;
    (void)ema_alpha_30;
    (void)ema_alpha_365;
    (void)annual_ema_alpha;

    // ─── 7. 委托给共享纯内核（S3，断点 2 的解法）─────────────────────────
    //
    // 这里原本是一份与 _async_pass_a_kernel_pure 逐行同形的主循环。两份"同形"
    // 的 float 代码不等于逐位相同结果：编译器对两个 TU 可以做不同的 FMA 收缩与
    // 寄存器分配，实测 SHADOW 对拍第 1 日就在 temp_baseline 上差 ~9e-8（1 ULP），
    // 30 日累积到 4.9e-2。parity_hash 是逐位归约，ULP 差就是不通过。
    //
    // 所以生产路径不再保留第二份实现：把 _slots 快照进 POD buffer，调与 async
    // round / SHADOW worker 完全同一个函数，再把输出散回 _slots。等价性从"逐公式
    // 论证"变成"同一份代码"，且生产侧以后改 pass-A 不需要再同步 worker。
    using namespace pk_async_climate;
    ClimateInputBuf &kin = _pass_a_sync_input_buf;
    ClimateOutputBuf &kout = _pass_a_sync_output_buf;
    kin.n_cells = n;
    kout.n_cells = n;

    auto snap_f32 = [n](const float *src, std::vector<float> &dst) {
        dst.resize(size_t(n));
        std::memcpy(dst.data(), src, size_t(n) * sizeof(float));
    };
    auto snap_u8 = [n](const uint8_t *src, std::vector<uint8_t> &dst) {
        dst.resize(size_t(n));
        std::memcpy(dst.data(), src, size_t(n));
    };

    snap_u8(piw, kin.is_water);
    snap_u8(pcov, kin.cover);
    snap_u8(pei, kin.ema_initialized);
    snap_f32(pe, kin.elevation);
    snap_f32(pbm, kin.base_moisture);
    snap_f32(pln, kin.lat_norm);
    snap_f32(pty, kin.temp_baseline_year);
    snap_f32(pt, kin.temp);
    snap_f32(p30, kin.temp_30d);
    snap_f32(p365, kin.temp_365d);
    snap_f32(pthermal, kin.thermal_energy);
    snap_f32(psnowpack, kin.snowpack);
    snap_f32(pm, kin.moisture);
    // 可选水文列：sync 路径以"slot 存在且长度匹配"为启用条件，内核以"vector 长度
    // == n"为启用条件，两者语义一致 —— 不可用时必须清空而不是留上一次的内容。
    if (pweatherv != nullptr) snap_f32(pweatherv, kin.weather_vapor); else kin.weather_vapor.clear();
    if (pprecip != nullptr) snap_f32(pprecip, kin.weather_precip); else kin.weather_precip.clear();
    if (psoil != nullptr) snap_f32(psoil, kin.soil_moisture); else kin.soil_moisture.clear();
    if (pwb != nullptr) snap_f32(pwb, kin.water_balance_30d); else kin.water_balance_30d.clear();
    // maritime：sync 的启用条件同时含 damp > 0；内核只看长度，damp 由 scalars 带。
    if (pmar != nullptr) snap_f32(pmar, kin.maritime); else kin.maritime.clear();
    // 年均日照：直接交主线程 memo 的内容，内核命中即读 → 与旧主循环逐位相同。
    snap_f32(pinsol_mean, kin.insol_annual_mean);

    // Modifier 冻结项。sync 旧路径逐 cell 调 modifier_climate_radiative_target
    // （Godot/DCWorldExt 依赖，worker 不可用）；共享契约是主线程把 add/factor 冻结成
    // per-cell POD 列，内核只做 (base + add) * factor 再 clamp[0,1]。
    kin.radiative_modifier_add.assign(size_t(n), 0.0f);
    kin.radiative_modifier_factor.assign(size_t(n), 1.0f);
    if (_modifier_runtime != nullptr) {
        const ModifierRuntime *modifier =
            static_cast<const ModifierRuntime *>(_modifier_runtime);
        for (int i = 0; i < n; ++i) {
            double add = 0.0;
            double factor = 1.0;
            modifier->climate_radiative_terms(i, add, factor);
            kin.radiative_modifier_add[size_t(i)] = float(add);
            kin.radiative_modifier_factor[size_t(i)] = float(factor);
        }
    }

    kin.scalars.season_phase = season_phase;
    kin.scalars.axial_tilt_deg = axial_tilt_deg;
    kin.scalars.day_length_gain = daylen_amp;
    kin.scalars.solar_gain = solar_gain;
    kin.scalars.insol_amp = insol_amp;
    kin.scalars.insol_gain = insol_gain;
    kin.scalars.insol_dev_min = insol_dev_min;
    kin.scalars.insol_dev_max = insol_dev_max;
    kin.scalars.thermal_inertia_land = thermal_land;
    kin.scalars.thermal_inertia_water = thermal_water;
    kin.scalars.thermal_inertia_snow = thermal_snow;
    kin.scalars.thermal_inertia_high_mountain = thermal_high;
    kin.scalars.thermal_daily_delta_cap = thermal_delta_cap;
    kin.scalars.thermal_dt_days = thermal_dt;
    kin.scalars.runtime_moisture_base_relax_rate = moisture_relax;
    kin.scalars.runtime_moisture_weather_vapor_weight = moisture_vapor_w;
    kin.scalars.runtime_moisture_precip_weight = moisture_precip_w;
    kin.scalars.runtime_moisture_soil_weight = moisture_soil_w;
    kin.scalars.runtime_moisture_soil_dry_weight = moisture_soil_dry_w;
    kin.scalars.runtime_moisture_water_balance_weight = moisture_wb_w;
    kin.scalars.runtime_moisture_water_balance_dry_weight = moisture_wb_dry_w;
    kin.scalars.snowpack_cover_low = snowpack_cover_low;
    kin.scalars.maritime_season_damp = maritime_damp;
    kin.scalars.sea_level = sea_level;
    kin.scalars.days_per_year = days_per_year;


    if (!_async_pass_a_kernel_pure(kin, kout)) {
        diag("shared pass_a kernel rejected input dimensions");
        return -1.0;
    }

    // 留存这一轮生产真实用过的输入缓冲。reference publish 会把它挂到 trace 帧上，
    // 于是 worker 跑的是"生产这一天用过的那份输入"，而不是 capture 时另建的一份。
    _production_round_input = std::make_shared<const ClimateInputBuf>(kin);
    record_production_pass_a_scalars(kin.scalars);

    // pass_a → reference 边界诊断的留存（见成员注释）。
    if (_pass_a_reference_boundary_reports_left > 0) {
        _pass_a_last_temp_baseline = kout.temp_baseline;
        _pass_a_last_thermal_energy = kout.thermal_energy;
        _pass_a_last_temp_30d = kout.temp_30d;
        _pass_a_last_temp_365d = kout.temp_365d;
    }

    // 散回 _slots。写目标与旧主循环完全一致的 16 条列（含末尾清 0 的两条 anomaly）。
    std::memcpy(ptb, kout.temp_baseline.data(), size_t(n) * sizeof(float));
    std::memcpy(pm, kout.moisture.data(), size_t(n) * sizeof(float));
    std::memcpy(pso, kout.temp_season_offset.data(), size_t(n) * sizeof(float));
    std::memcpy(pinsol, kout.insolation_now.data(), size_t(n) * sizeof(float));
    std::memcpy(pdev, kout.insolation_dev.data(), size_t(n) * sizeof(float));
    std::memcpy(pday, kout.day_length.data(), size_t(n) * sizeof(float));
    std::memcpy(pheat, kout.heat_input.data(), size_t(n) * sizeof(float));
    std::memcpy(pthermal, kout.thermal_energy.data(), size_t(n) * sizeof(float));
    std::memcpy(psnowpack, kout.snowpack.data(), size_t(n) * sizeof(float));
    std::memcpy(poanom, kout.ocean_thermal_anomaly.data(), size_t(n) * sizeof(float));
    std::memcpy(planom, kout.local_thermal_anomaly.data(), size_t(n) * sizeof(float));
    std::memcpy(p30, kout.temp_30d.data(), size_t(n) * sizeof(float));
    std::memcpy(p365, kout.temp_365d.data(), size_t(n) * sizeof(float));
    std::memcpy(pa, kout.temp_anomaly.data(), size_t(n) * sizeof(float));
    std::memcpy(pei, kout.ema_initialized.data(), size_t(n));

    // Step 3b-1.5 will fold dirty mask + drift in here. Step 3b-1 leaves
    // climate_dirty_mask / _dt/_dm/_ds_global_yesterday untouched — Pass-B
    // will temporarily walk the full grid (degraded but correct).

    // §11.2 flush: push CoW-detached output slots back to GDScript MapData
    // A 修复（2026-06）：pass_a 不再 flush cell_temp（不再写）；改 flush 两条
    // 新 anomaly slot（pass_a 末尾 clear 0 也算一次写）。
    if (!bool(cp_struct.get("defer_visible_publish", false))) {
        _flush_slot_to_map(sid_moisture);
    }
    _flush_slot_to_map(sid_temp_baseline);
    _flush_slot_to_map(sid_temp_seas_off);
    _flush_slot_to_map(sid_ema_init);
    _flush_slot_to_map(sid_temp_30d);
    _flush_slot_to_map(sid_temp_365d);
    _flush_slot_to_map(sid_temp_anom);
    _flush_slot_to_map(sid_insol_now);
    _flush_slot_to_map(sid_insol_dev);
    _flush_slot_to_map(sid_day_length);
    _flush_slot_to_map(sid_heat_input);
    _flush_slot_to_map(sid_thermal_energy);
    _flush_slot_to_map(sid_snowpack);
    _flush_slot_to_map(sid_ocean_anom);
    _flush_slot_to_map(sid_local_anom);

    return 0.0;
}

// ─── [Phase C.3c] run_climate_pass_a_thread ──────────────────────────────
//
// run_climate_pass_a 的 WorkerThreadPool 并行版本。
// 主循环纯 cell-local map（每 i 只读自身 + LUT，写自身 8 个 SoA 列） → 完美 Tier-1，
// 无 race，可直接拆 cell range 并行。N=2400 时单线程 ~0.3ms，4 核理论 < 0.1ms。
//
// 与 run_albedo_pass_thread / run_climate_feedback_pass_thread 模板严格一致：
// 完整复制主 pass 的 prelude（_bound 检查 + slot 解析 + cp_struct 拉取 +
// LUT 验证 + 指针缓存），仅末段主循环走 pk::parallel_for_range。
// 算法 body 与 run_climate_pass_a 严格 1:1（共用 lambda 的同形态实现）。
//
// n_tasks=0 → 自适应（ceil(n/1024) 截 [1,16]）；n < 256 || n_tasks==1 → 直接顺序。
// 返回值同语义：≥0 = elapsed_ms（实际语义 0.0，与原 pass 末尾 return 0.0 对齐），
// <0 = 拒绝（GDScript fallback）。
double DCWorldExt::run_climate_pass_a_thread(const Dictionary &cp_struct, double phase, double season_phase, int n_tasks) {
    _production_stage_mask |= pk_async_climate::CLIMATE_STAGE_BIT_PASS_A;
    // S3：这里原本是 run_climate_pass_a 的第三份 pass-A 实现（prelude 全量复制 +
    // 主循环走 pk::parallel_for_range）。断点 2 的教训正是"同形的第二份 float 代码
    // 不等于逐位相同的结果"——两个循环体在不同 TU/不同向量化下会差 1 ULP，而
    // parity_hash 是逐位归约。pass-A 在 N=2400 时单线程约 0.3ms，并行收益不足以
    // 换一份必须永久手工同步的算法副本。
    //
    // 现在统一转发到 run_climate_pass_a，由它调共享纯内核
    // pk_async_climate::_async_pass_a_kernel_pure —— 生产 sync、生产 async round、
    // SHADOW worker 三条驱动路径共用同一份代码。
    (void)n_tasks;
    return run_climate_pass_a(cp_struct, phase, season_phase);
}

// ─── F.2a: ocean water pass ─────────────────────────────────────────────────
//
// Single-shot full sweep over [0, n_cells). 1:1 mirror of
// _ocean_water_pass_soa (map_generator.gd:4679+) hot loop:
//   for each WATER cell i with non-zero current:
//     advect upstream `advect_steps` times (pick best dot vs -current dir)
//     temp_mixed = lerp(temp_before[i], temp_before[upstream], heat_mix)
//     temp_a[i] = clamp(temp_mixed, 0, 1)
//     anomaly_out[i] = lerp(prev_tta, clamp(temp_mixed - baseline[i], source_cap), blend)
//   for each WATER cell i with zero current OR advect_steps==0:
//     anomaly_out[i] = prev_tta * (1 - zero_current_decay)
//
// Caller-side responsibility (与 GDScript path 一致)：
//   * pre-compute baseline[]  (ema_init=true → temp_baseline_a, else compute_temperature)
//   * pre-compute temp_before[] (temp_a > 0 → temp_a, else baseline)
//   * pass anomaly_out as scratch buffer (water cells written; land cells preserved
//     for subsequent run_ocean_land_pass call)
//   * after both passes return, copy anomaly_out → cells[i].temperature_transport_anomaly
// pk_limit_cold_water_positive_transport_source 已在 S3 搬到 runtime_climate_pass_math.h。

void DCWorldExt::_ensure_enso_basin_cache(
        int n_cells, const uint8_t *is_water, const uint8_t *terrain,
        const float *lat_norm, const float *pos_x, const int32_t *neighbors,
        const PackedByteArray &ocean_terrain_ids, float tropical_lat_limit,
        int max_basins, float wrap_period_x, int world_seed) {
    const auto t0 = std::chrono::high_resolution_clock::now();
    uint64_t fp = 1469598103934665603ull;
    auto mix = [&fp](uint64_t v) { fp ^= v; fp *= 1099511628211ull; };
    mix(uint64_t(n_cells));
    mix(uint64_t(std::lround(tropical_lat_limit * 10000.0f)));
    mix(uint64_t(max_basins));
    mix(uint64_t(std::lround(wrap_period_x * 1000.0f)));
    for (int i = 0; i < n_cells; ++i) {
        mix(uint64_t(is_water[i]));
        mix(uint64_t(std::lround(lat_norm[i] * 10000.0f)));
    }
    for (int i = 0; i < n_cells * 6; ++i) mix(uint64_t(uint32_t(neighbors[i])));
    if (_enso_cache_valid && _enso_cache_fp == fp) {
        _enso_cache_last_hit = true;
        return;
    }
    _enso_cache_last_hit = false;

    bool terrain_lut[256] = {};
    for (int i = 0; i < ocean_terrain_ids.size(); ++i) {
        terrain_lut[uint8_t(ocean_terrain_ids[i])] = true;
    }
    const bool filter_terrain = terrain != nullptr && !ocean_terrain_ids.is_empty();
    auto eligible = [&](int i) {
        const float signed_lat = std::abs((lat_norm[i] - 0.5f) * 2.0f);
        return is_water[i] != 0 && signed_lat <= tropical_lat_limit &&
               (!filter_terrain || terrain_lut[terrain[i]]);
    };

    struct Candidate { std::vector<int32_t> cells; uint64_t signature = 0; };
    std::vector<Candidate> candidates;
    std::vector<uint8_t> seen(static_cast<size_t>(n_cells), 0);
    std::vector<int32_t> queue;
    queue.reserve(static_cast<size_t>(n_cells));
    const int min_cells = std::max(24, int(std::sqrt(double(n_cells)) * 0.45));
    for (int seed = 0; seed < n_cells; ++seed) {
        if (seen[seed] || !eligible(seed)) continue;
        queue.clear();
        queue.push_back(seed);
        seen[seed] = 1;
        for (size_t head = 0; head < queue.size(); ++head) {
            const int cur = queue[head];
            for (int d = 0; d < 6; ++d) {
                const int ni = neighbors[cur * 6 + d];
                if (ni < 0 || ni >= n_cells || seen[ni] || !eligible(ni)) continue;
                seen[ni] = 1;
                queue.push_back(ni);
            }
        }
        if (int(queue.size()) < min_cells) continue;
        Candidate c;
        c.cells = queue;
        std::sort(c.cells.begin(), c.cells.end());
        uint64_t sig = 1469598103934665603ull;
        for (int32_t idx : c.cells) { sig ^= uint64_t(uint32_t(idx)); sig *= 1099511628211ull; }
        c.signature = sig;
        candidates.push_back(std::move(c));
    }
    std::sort(candidates.begin(), candidates.end(), [](const Candidate &a, const Candidate &b) {
        if (a.cells.size() != b.cells.size()) return a.cells.size() > b.cells.size();
        return a.signature < b.signature;
    });
    if (int(candidates.size()) > max_basins) candidates.resize(static_cast<size_t>(max_basins));

    const std::vector<EnsoBasinState> old_states = _enso_states;
    _enso_basin_id.assign(static_cast<size_t>(n_cells), int8_t(-1));
    _enso_eastness.assign(static_cast<size_t>(n_cells), 0.0f);
    _enso_prev_forcing.assign(static_cast<size_t>(n_cells), 0.0f);
    _enso_members.clear();
    _enso_basins.clear();
    _enso_states.clear();
    for (int bi = 0; bi < int(candidates.size()); ++bi) {
        const Candidate &c = candidates[bi];
        EnsoBasinMeta meta;
        meta.signature = c.signature;
        meta.member_begin = int(_enso_members.size());
        meta.member_count = int(c.cells.size());
        double cx = 0.0;
        if (wrap_period_x > 0.0f) {
            double sx = 0.0, sy = 0.0;
            for (int idx : c.cells) {
                const double a = 2.0 * M_PI * double(pos_x[idx]) / double(wrap_period_x);
                sx += std::cos(a); sy += std::sin(a);
            }
            cx = std::atan2(sy, sx) * double(wrap_period_x) / (2.0 * M_PI);
        } else {
            for (int idx : c.cells) cx += pos_x[idx];
            cx /= std::max<size_t>(1, c.cells.size());
        }
        double max_abs_dx = 1e-6;
        for (int idx : c.cells) {
            const double dx = pk_wrap_min_image_dx(float(double(pos_x[idx]) - cx), wrap_period_x);
            max_abs_dx = std::max(max_abs_dx, std::abs(dx));
        }
        meta.span_x = float(max_abs_dx * 2.0);
        for (int idx : c.cells) {
            _enso_members.push_back(idx);
            _enso_basin_id[static_cast<size_t>(idx)] = int8_t(bi);
            const float dx = pk_wrap_min_image_dx(float(double(pos_x[idx]) - cx), wrap_period_x);
            _enso_eastness[static_cast<size_t>(idx)] = dc_clampf(dx / float(max_abs_dx), -1.0f, 1.0f);
        }
        _enso_basins.push_back(meta);
        EnsoBasinState state;
        state.signature = c.signature;
        bool restored = false;
        for (const EnsoBasinState &old : old_states) {
            if (old.signature == c.signature) { state = old; restored = true; break; }
        }
        if (!restored) {
            uint64_t h = c.signature ^ (uint64_t(uint32_t(world_seed)) * 0x9e3779b97f4a7c15ull);
            state.temp_index = ((h >> 11) & 1ull) ? 0.018f : -0.018f;
            state.recharge_index = ((h >> 17) & 1ull) ? -0.010f : 0.010f;
        }
        _enso_states.push_back(state);
    }
    _enso_wind_sum.assign(_enso_states.size(), 0.0);
    _enso_wind_count.assign(_enso_states.size(), 0);

    if (!_climate_modes_pending_restore.is_empty()) {
        Array saved = _climate_modes_pending_restore.get("enso_basins", Array());
        for (int si = 0; si < saved.size(); ++si) {
            Dictionary d = saved[si];
            const uint64_t sig = uint64_t(int64_t(d.get("signature", int64_t(0))));
            for (EnsoBasinState &state : _enso_states) {
                if (state.signature != sig) continue;
                state.temp_index = dc_clampf(float(d.get("temp_index", state.temp_index)), -1.0f, 1.0f);
                state.recharge_index = dc_clampf(float(d.get("recharge_index", state.recharge_index)), -1.0f, 1.0f);
                state.wind_ema = float(d.get("wind_ema", 0.0));
                state.wind_anomaly = float(d.get("wind_anomaly", 0.0));
                state.last_update_tick = int64_t(d.get("last_update_tick", -1));
            }
        }
        _climate_modes_pending_restore.erase("enso_basins");
        const float restored_cap = dc_clampf(float(_native_runtime_config.get(
            "enso_temp_anomaly_cap", 0.06)), 0.0f, 0.12f);
        for (int i = 0; i < n_cells; ++i) {
            const int bi = int(_enso_basin_id[static_cast<size_t>(i)]);
            if (bi < 0 || bi >= int(_enso_states.size())) continue;
            const float east = _enso_eastness[static_cast<size_t>(i)];
            const float shape = east >= 0.0f ? east : 0.35f * east;
            _enso_prev_forcing[static_cast<size_t>(i)] =
                restored_cap * _enso_states[static_cast<size_t>(bi)].temp_index * shape;
        }
    }
    _enso_cache_fp = fp;
    _enso_cache_valid = true;
    const auto t1 = std::chrono::high_resolution_clock::now();
    _enso_cache_build_ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
}

void DCWorldExt::_apply_enso_ocean_slice(
        Dictionary &knobs, int n_cells, int start_idx, int end_idx,
        const uint8_t *is_water, const uint8_t *terrain, const float *lat_norm,
        const float *pos_x, const int32_t *neighbors, const float *wind_x,
        const float *wind_speed, float *ocean_anomaly, float *transport_anomaly) {
    const bool enabled = bool(knobs.get("enso_basin_modes_enabled",
        _native_runtime_config.get("enso_basin_modes_enabled", false)));
    if (!enabled || lat_norm == nullptr || wind_x == nullptr || wind_speed == nullptr) return;
    const int max_basins = std::clamp(int(knobs.get("enso_max_basins",
        _native_runtime_config.get("enso_max_basins", 3))), 1, 3);
    const float lat_limit = dc_clampf(float(knobs.get("enso_tropical_lat_limit",
        _native_runtime_config.get("enso_tropical_lat_limit", 0.33))), 0.10f, 0.50f);
    const float wrap_x = float(knobs.get("wrap_period_x", _native_wrap_period_x));
    PackedByteArray ocean_ids = knobs.get("enso_ocean_terrain_ids", PackedByteArray());
    const int world_seed = int(knobs.get("world_seed", _native_runtime_config.get("world_seed", 0)));
    _ensure_enso_basin_cache(n_cells, is_water, terrain, lat_norm, pos_x, neighbors,
                             ocean_ids, lat_limit, max_basins, wrap_x, world_seed);
    if (_enso_states.empty()) return;

    if (start_idx == 0) {
        const float period = std::max(730.0f, float(knobs.get("enso_period_days",
            _native_runtime_config.get("enso_period_days", 1460.0))));
        const float dt_total = std::max(0.0f, float(knobs.get("dt_days", 1.0)));
        const float substep = std::max(1.0f, float(knobs.get("enso_integration_substep_days",
            _native_runtime_config.get("enso_integration_substep_days", 10.0))));
        const float coupling = std::max(0.0f, float(knobs.get("enso_wind_coupling",
            _native_runtime_config.get("enso_wind_coupling", 0.0008))));
        const int steps = std::max(1, int(std::ceil(dt_total / substep)));
        const float dt = dt_total / float(steps);
        const float omega = float(2.0 * M_PI) / period;
        for (EnsoBasinState &s : _enso_states) {
            for (int k = 0; k < steps; ++k) {
                const float t0 = s.temp_index, h0 = s.recharge_index;
                const float d_t0 = omega * h0 + 0.0012f * (1.0f - t0 * t0) * t0
                    + coupling * s.wind_anomaly;
                const float d_h0 = -omega * t0 - 0.00025f * h0;
                const float tp = t0 + dt * d_t0, hp = h0 + dt * d_h0;
                const float d_t1 = omega * hp + 0.0012f * (1.0f - tp * tp) * tp
                    + coupling * s.wind_anomaly;
                const float d_h1 = -omega * tp - 0.00025f * hp;
                s.temp_index = dc_clampf(t0 + 0.5f * dt * (d_t0 + d_t1), -1.0f, 1.0f);
                s.recharge_index = dc_clampf(h0 + 0.5f * dt * (d_h0 + d_h1), -1.0f, 1.0f);
            }
            s.last_update_tick = int64_t(knobs.get("day_index", _native_daily_tick_count));
        }
        std::fill(_enso_wind_sum.begin(), _enso_wind_sum.end(), 0.0);
        std::fill(_enso_wind_count.begin(), _enso_wind_count.end(), 0);
    }
    const float cap = dc_clampf(float(knobs.get("enso_temp_anomaly_cap",
        _native_runtime_config.get("enso_temp_anomaly_cap", 0.06))), 0.0f, 0.12f);
    for (int i = start_idx; i < end_idx; ++i) {
        const int bi = (i < int(_enso_basin_id.size())) ? int(_enso_basin_id[static_cast<size_t>(i)]) : -1;
        if (bi < 0 || bi >= int(_enso_states.size()) || is_water[i] == 0) continue;
        const float previous = _enso_prev_forcing[static_cast<size_t>(i)];
        const float east = _enso_eastness[static_cast<size_t>(i)];
        const float shape = east >= 0.0f ? east : 0.35f * east;
        const float forcing = cap * _enso_states[static_cast<size_t>(bi)].temp_index * shape;
        ocean_anomaly[i] = dc_clampf(ocean_anomaly[i] - previous + forcing, -0.12f, 0.12f);
        transport_anomaly[i] = dc_clampf(transport_anomaly[i] - previous + forcing, -0.5f, 0.5f);
        _enso_prev_forcing[static_cast<size_t>(i)] = forcing;
        _enso_wind_sum[static_cast<size_t>(bi)] += double(wind_x[i] * wind_speed[i]);
        ++_enso_wind_count[static_cast<size_t>(bi)];
    }
    if (end_idx == n_cells) {
        for (size_t bi = 0; bi < _enso_states.size(); ++bi) {
            if (_enso_wind_count[bi] <= 0) continue;
            const float mean = float(_enso_wind_sum[bi] / double(_enso_wind_count[bi]));
            EnsoBasinState &s = _enso_states[bi];
            const float old = s.wind_ema;
            s.wind_ema += 0.05f * (mean - s.wind_ema);
            s.wind_anomaly = s.wind_ema - old;
        }
    }
    knobs["enso_basin_count"] = int(_enso_states.size());
    knobs["enso_cache_hit"] = _enso_cache_last_hit;
    knobs["enso_cache_build_ms"] = _enso_cache_build_ms;
}

double DCWorldExt::run_climate_pass_b(const Dictionary &knobs) {
    using godot::StringName;
    using godot::PackedFloat32Array;
    using godot::PackedInt32Array;
    using godot::PackedByteArray;

    auto diag = [&](const char *why) {
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_climate_pass_b: ", why,
            " — fallback to GDScript");
    };

    if (!_bound) { diag("not _bound"); return -1.0; }

    // ─── Resolve all 10 slot ids ONCE ───────────────────────────────────
    const int sid_temp     = component_id(StringName("cell_temp"));
    const int sid_moist    = component_id(StringName("cell_moisture"));
    const int sid_snowpack = component_id(StringName("cell_snowpack"));
    const int sid_iswater  = component_id(StringName("cell_is_water"));
    const int sid_landform = component_id(StringName("cell_landform"));
    const int sid_veg      = component_id(StringName("cell_vegetation"));
    const int sid_elev     = component_id(StringName("cell_elevation"));
    const int sid_lat      = component_id(StringName("cell_lat_norm"));
    const int sid_pos_x    = component_id(StringName("cell_pos_x"));
    const int sid_pos_y    = component_id(StringName("cell_pos_y"));
    const int sid_insol_dev= component_id(StringName("cell_insolation_dev"));
    // A 修复（2026-06）：pass_b 不再写 cell_temp，改累加到 cell_local_thermal_anomaly。
    const int sid_lanom    = component_id(StringName("cell_local_thermal_anomaly"));
    if (sid_temp < 0 || sid_moist < 0 || sid_snowpack < 0 || sid_iswater < 0 ||
        sid_landform < 0 || sid_veg < 0 || sid_elev < 0 || sid_lat < 0 ||
        sid_pos_x < 0 || sid_pos_y < 0 || sid_insol_dev < 0 || sid_lanom < 0) {
        diag("missing slot id (cell_temp/moisture/snowpack/is_water/landform/vegetation/elevation/lat_norm/pos_x/pos_y/insolation_dev/local_thermal_anomaly)");
        return -1.0;
    }

    // ─── Pull scalars from knobs ────────────────────────────────────────
    if (!knobs.has("n_cells") || !knobs.has("winter_boost") ||
        !knobs.has("snow_cool") || !knobs.has("veg_cool") ||
        !knobs.has("diurnal_amp") || !knobs.has("evap_gain") ||
        !knobs.has("rs_threshold") || !knobs.has("rs_factor") ||
        !knobs.has("rs_lookback") || !knobs.has("t_freeze") ||
        !knobs.has("coupling_gain") || !knobs.has("coast_leak") ||
        !knobs.has("season_phase") ||
        !knobs.has("neighbor_indices") || !knobs.has("temp_transport_anomaly") ||
        !knobs.has("foliage_table")) {
        diag("knobs missing required keys");
        return -1.0;
    }
    const int n_cells = int(knobs["n_cells"]);
    if (n_cells <= 0) { diag("n_cells <= 0"); return -1.0; }
    if (knobs.has("go_sparse") && bool(knobs["go_sparse"])) {
        diag("go_sparse=true — sparse path not yet supported in C++");
        return -1.0;
    }
    const float winter_boost          = float(knobs["winter_boost"]);
    const float snow_cool             = float(knobs["snow_cool"]);
    const float veg_cool              = float(knobs["veg_cool"]);
    const float diurnal_amp           = float(knobs["diurnal_amp"]);
    const float evap_gain             = float(knobs["evap_gain"]);
    const float rs_threshold          = float(knobs["rs_threshold"]);
    const float rs_factor             = float(knobs["rs_factor"]);
    const int   rs_lookback           = int(knobs["rs_lookback"]);
    // seam-advection-fix：雨影上风探测的经度环绕周期，缺省取常驻值。
    const double wrap_period_x        = knobs.has("wrap_period_x")
        ? double(knobs["wrap_period_x"]) : _native_wrap_period_x;
    const float t_freeze              = float(knobs["t_freeze"]);
    const float coupling_gain         = float(knobs["coupling_gain"]);
    const float coast_leak            = float(knobs["coast_leak"]);
    const double season_phase         = double(knobs["season_phase"]);
    const float snowpack_cover_low    = knobs.has("snowpack_cover_low") ? float(knobs["snowpack_cover_low"]) : 0.05f;
    const float snowpack_cover_full   = knobs.has("snowpack_cover_full") ? float(knobs["snowpack_cover_full"]) : 0.32f;

    // S3: 留存生产这一轮真实用过的标量，reference publish 时发布给 worker。
    // 不写的后果是 worker 跑同一份内核但吃结构默认 knobs。
    record_production_round_scalars(0x02, knobs);
    // ─── Pull PackedArrays ──────────────────────────────────────────────
    PackedInt32Array nb_arr = knobs["neighbor_indices"];
    PackedFloat32Array tta_arr = knobs["temp_transport_anomaly"];
    PackedFloat32Array foliage_arr = knobs["foliage_table"];
    if (nb_arr.size() < n_cells * 6) { diag("neighbor_indices size < n_cells * 6"); return -1.0; }
    if (tta_arr.size() != n_cells)   { diag("temp_transport_anomaly size mismatch"); return -1.0; }
    const int foliage_size = foliage_arr.size();
    if (foliage_size <= 0) { diag("foliage_table empty"); return -1.0; }

    // climate-loop-closure Phase 4.1：海冰反照率→温度反馈（可选 knobs；缺省 0 = 关闭）。
    const float sea_ice_albedo_cooling = knobs.has("sea_ice_albedo_cooling") ? float(knobs["sea_ice_albedo_cooling"]) : 0.0f;
    PackedFloat32Array sif_arr_pb;
    if (knobs.has("sea_ice_frac")) sif_arr_pb = knobs["sea_ice_frac"];
    const float * const __restrict SIF_PB = (sif_arr_pb.size() == n_cells) ? sif_arr_pb.ptr() : nullptr;
    record_production_pass_b_input(n_cells, SIF_PB, tta_arr.ptr());

    // ─── Acquire slot arrays + validate sizes ───────────────────────────
    Slot &s_temp     = _slots.write[sid_temp];
    Slot &s_moist    = _slots.write[sid_moist];
    Slot &s_snowpack = _slots.write[sid_snowpack];
    Slot &s_iswater  = _slots.write[sid_iswater];
    Slot &s_landform = _slots.write[sid_landform];
    Slot &s_veg      = _slots.write[sid_veg];
    Slot &s_elev     = _slots.write[sid_elev];
    Slot &s_lat      = _slots.write[sid_lat];
    Slot &s_pos_x    = _slots.write[sid_pos_x];
    Slot &s_pos_y    = _slots.write[sid_pos_y];
    Slot &s_insol_dev= _slots.write[sid_insol_dev];
    Slot &s_lanom    = _slots.write[sid_lanom];
    if (s_temp.arr_f32.size()  != n_cells || s_moist.arr_f32.size()    != n_cells ||
        s_snowpack.arr_f32.size() != n_cells || s_iswater.arr_u8.size() != n_cells ||
        s_landform.arr_u8.size() != n_cells || s_veg.arr_u8.size()     != n_cells ||
        s_elev.arr_f32.size()  != n_cells || s_lat.arr_f32.size()      != n_cells ||
        s_pos_x.arr_f32.size() != n_cells || s_pos_y.arr_f32.size()    != n_cells ||
        s_insol_dev.arr_f32.size() != n_cells ||
        s_lanom.arr_f32.size() != n_cells) {
        diag("slot array size mismatch (re-bind needed?)");
        return -1.0;
    }

    // ─── Hot pointers ───────────────────────────────────────────────────
    // A 修复（2026-06）：T 只读快照（用于 evap 的 t_eff）。pass_b 写 local anomaly，
    // 由 wind_surface 末端合成回 cell_temp。
    const float * const __restrict T_RO = s_temp.arr_f32.ptr();
    float       * const __restrict LANOM = s_lanom.arr_f32.ptrw();
    float       * const __restrict M    = s_moist.arr_f32.ptrw();
    const float * const __restrict SNOWPACK = s_snowpack.arr_f32.ptr();
    const uint8_t * const __restrict IW = s_iswater.arr_u8.ptr();
    const uint8_t * const __restrict LF = s_landform.arr_u8.ptr();
    const uint8_t * const __restrict VG = s_veg.arr_u8.ptr();
    const float * const __restrict ELEV = s_elev.arr_f32.ptr();
    const float * const __restrict LAT  = s_lat.arr_f32.ptr();
    const float * const __restrict POSX = s_pos_x.arr_f32.ptr();
    const float * const __restrict POSY = s_pos_y.arr_f32.ptr();
    const float * const __restrict INSOL_DEV = s_insol_dev.arr_f32.ptr();
    const int32_t * const __restrict NB = nb_arr.ptr();
    const float * const __restrict TTA  = tta_arr.ptr();
    const float * const __restrict FOL  = foliage_arr.ptr();

    auto t0 = std::chrono::high_resolution_clock::now();

    // ─── Snapshot temp BEFORE any writes ────────────────────────────────
    // A 修复（2026-06）：TS 是 yesterday's composed cell_temp（pass_b 不再就地写 T）。
    // d_albedo / d_coastal / d_landform 仍然以 TS 为基准计算（与 GDScript bit-equal）。
    std::vector<float> temp_snapshot(n_cells);
    std::memcpy(temp_snapshot.data(), T_RO, n_cells * sizeof(float));
    const float * const __restrict TS = temp_snapshot.data();

    // S3 P3：主循环已提取为 pk_async_climate::climate_pass_b_pure，worker 侧吃同一份。
    pk_async_climate::ClimatePassBKnobs pbk;
    pbk.n_cells                = n_cells;
    pbk.winter_boost           = winter_boost;
    pbk.snow_cool              = snow_cool;
    pbk.veg_cool               = veg_cool;
    pbk.diurnal_amp            = diurnal_amp;
    pbk.evap_gain              = evap_gain;
    pbk.rs_threshold           = rs_threshold;
    pbk.rs_factor              = rs_factor;
    pbk.rs_lookback            = rs_lookback;
    pbk.wrap_period_x          = wrap_period_x;
    pbk.t_freeze               = t_freeze;
    pbk.coupling_gain          = coupling_gain;
    pbk.coast_leak             = coast_leak;
    pbk.sea_ice_albedo_cooling = sea_ice_albedo_cooling;
    pbk.season_phase           = season_phase;
    pbk.snowpack_cover_low     = snowpack_cover_low;
    pbk.snowpack_cover_full    = snowpack_cover_full;
    pbk.foliage_size           = foliage_size;

    pk_async_climate::ClimatePassBLanes pbl;
    pbl.temp_snapshot           = TS;
    pbl.snowpack                = SNOWPACK;
    pbl.elevation               = ELEV;
    pbl.lat_norm                = LAT;
    pbl.pos_x                   = POSX;
    pbl.pos_y                   = POSY;
    pbl.insolation_dev          = INSOL_DEV;
    pbl.temp_transport_anomaly  = TTA;
    pbl.is_water                = IW;
    pbl.landform                = LF;
    pbl.vegetation              = VG;
    pbl.sea_ice_frac            = SIF_PB;
    pbl.neighbor_indices        = NB;
    pbl.foliage_table           = FOL;
    pbl.local_thermal_anomaly   = LANOM;
    pbl.moisture                = M;

    pk_async_climate::climate_pass_b_pure(pbk, pbl);

    // §11.2 flush: A 修复（2026-06）— pass_b 不再 flush cell_temp，改 flush local anomaly。
    _flush_slot_to_map(sid_lanom);
    if (!bool(knobs.get("defer_visible_publish", false))) {
        _flush_slot_to_map(sid_moist);
    }

    auto t1 = std::chrono::high_resolution_clock::now();
    return std::chrono::duration<double, std::milli>(t1 - t0).count();
}

// ════════════════════════════════════════════════════════════════════════════
// plan/sim-2ms-simd-dirty-budget — climate Pass-B SIMD / Thread variants
// ════════════════════════════════════════════════════════════════════════════
//
// 策略：pass_b 的 5 段计算（albedo / coastal / landform / write / evap +
// rain-shadow）全部是 `if (!is_water) { ... }` 嵌套。原 scalar 实现按 cell
// 顺序串行迭代，每个 cell 命中 5 个分支预测槽位。改造路径：
//   1. 一次性 scan IW[]，构建 PackedInt32-equivalent `land_idx` 列表；
//   2. land-cell 主段按 land_idx 直线迭代——5 段去 if 后 MSVC /O2 /arch:AVX2
//      能自动向量化最简单的 albedo + write 段；
//   3. rain-shadow 串行 probe 段对每个 land cell 单独走，因为算法需要沿
//      wind direction 沿 6-邻居最佳方向多步追踪，无 SIMD-able 模式；
//   4. water cell 不需要任何 hot 计算（pass_b 对 water cell 完全 no-op）。
//
// 与原 scalar 的语义差异（plan §risk = B 已接受 ulp ≤ 4）：
//   - 内存访问顺序变为 land-first（按 land_idx 顺序），cache 命中模式不同；
//   - 浮点重排：FMA / 编译器 vectorize 引入 ulp 差异（≤ 4）；
//   - water cell 的 T/M 完全未写——与原 scalar 完全一致（原 scalar 也只
//     在 land 分支写 T，水 cell 走 `T[i] = clamp(temp_now)`，但 temp_now =
//     TS[i] = T[i]，等价于不写）；为安全起见 land-mask 路径下仍保持 water
//     cell T/M 不变。
//   - moisture 同理：water cell 在原 scalar 中也走 `(M[i] + 0) * 1 = M[i]`，
//     等价不写。
//
// 显式 AVX2 fast block 仅用于 albedo 段（最简单 = 单 ld + 1 fmul + 1 fsub）；
// 其余段直线代码交给编译器 auto-vectorize 即可（pass_b 复杂度远高于 pass_a
// 的纯 stencil，手写 6-邻居 mask gather 收益 < 30%、维护成本高）。
//
// run_climate_pass_b_simd / _thread 的 ulp 差异不会比原 scalar 在不同编译
// 器版本间的差异更大；A/B 验收（sim_2ms_ulp_tolerant_test）应通过。

namespace {

// Inline LandformType ordinals — 与 run_climate_pass_b 内 constexpr 同源。
constexpr uint8_t kLF_LOWLAND   = 5;
constexpr uint8_t kLF_MOUNTAIN  = 7;
constexpr uint8_t kLF_PEAK      = 8;
constexpr uint8_t kLF_DELTA     = 9;
constexpr uint8_t kLF_SALT_FLAT = 11;

// pass_b 共享输入指针 + 标量 knobs 的不变 view，避免重复传 20+ 参数。
struct PassBCtx {
    // 输出
    // A 修复（2026-06）：pass_b 不再写 cell_temp；T 字段保留为只读快照入口，
    // 改写 LANOM（cell_local_thermal_anomaly）。M（cell_moisture）写权不变。
    const float * __restrict T;
    float       * __restrict LANOM;
    float       * __restrict M;
    // 只读
    const float * __restrict TS;       // temp snapshot (pre-write)
    const float * __restrict SNOWPACK;
    const uint8_t * __restrict IW;
    const uint8_t * __restrict LF;
    const uint8_t * __restrict VG;
    const float * __restrict ELEV;
    const float * __restrict LAT;
    const float * __restrict POSX;
    const float * __restrict POSY;
    const float * __restrict INSOL_DEV;
    const int32_t * __restrict NB;
    const float * __restrict TTA;
    const float * __restrict FOL;
    int foliage_size;
    // 标量
    float winter_boost, snow_cool, veg_cool, diurnal_amp, evap_gain;
    float rs_threshold, rs_factor, t_freeze, coupling_gain, coast_leak;
    float snowpack_cover_low, snowpack_cover_full;
    double season_phase;
    int rs_lookback;
    // seam-advection-fix：雨影上风探测的经度环绕周期，0 = 无环绕域。
    double wrap_period_x;
    // 海冰反照率尾循环所需（0 / nullptr = 关闭）。原先三个变体各写一份尾循环，
    // 收进 ctx 后统一交给 climate_pass_b_sea_ice_tail_pure。
    int n_cells = 0;
    float sea_ice_albedo_cooling = 0.0f;
    const float * __restrict SIF = nullptr;
};

// PassBCtx → 共享内核的 knobs/lanes。生产 _simd / _thread 与 worker 现在跑同一份
// per-cell body，pass_b 不再有第二份实现可以偏移。
inline void pass_b_ctx_to_kernel(const PassBCtx &c,
                                 pk_async_climate::ClimatePassBKnobs &k,
                                 pk_async_climate::ClimatePassBLanes &l) {
    k.n_cells                = c.n_cells;
    k.winter_boost           = c.winter_boost;
    k.snow_cool              = c.snow_cool;
    k.veg_cool               = c.veg_cool;
    k.diurnal_amp            = c.diurnal_amp;
    k.evap_gain              = c.evap_gain;
    k.rs_threshold           = c.rs_threshold;
    k.rs_factor              = c.rs_factor;
    k.rs_lookback            = c.rs_lookback;
    k.wrap_period_x          = c.wrap_period_x;
    k.t_freeze               = c.t_freeze;
    k.coupling_gain          = c.coupling_gain;
    k.coast_leak             = c.coast_leak;
    k.sea_ice_albedo_cooling = c.sea_ice_albedo_cooling;
    k.season_phase           = c.season_phase;
    k.snowpack_cover_low     = c.snowpack_cover_low;
    k.snowpack_cover_full    = c.snowpack_cover_full;
    k.foliage_size           = c.foliage_size;

    l.temp_snapshot          = c.TS;
    l.snowpack               = c.SNOWPACK;
    l.elevation              = c.ELEV;
    l.lat_norm               = c.LAT;
    l.pos_x                  = c.POSX;
    l.pos_y                  = c.POSY;
    l.insolation_dev         = c.INSOL_DEV;
    l.temp_transport_anomaly = c.TTA;
    l.is_water               = c.IW;
    l.landform               = c.LF;
    l.vegetation             = c.VG;
    l.sea_ice_frac           = c.SIF;
    l.neighbor_indices       = c.NB;
    l.foliage_table          = c.FOL;
    l.local_thermal_anomaly  = c.LANOM;
    l.moisture               = c.M;
}

// land-only main pass：把 land_idx[begin..end) 交给共享内核。
// 原先这里还有 pass_b_land_compute_temp / _evap / _rain_shadow 三个 helper，
// 与 worker 侧那份平行实现逐行重复；已并入 pk_async_climate::climate_pass_b_pure。
inline void pass_b_run_land_range(const PassBCtx &c,
                                  const int *land_idx,
                                  int begin, int end) {
    pk_async_climate::ClimatePassBKnobs k;
    pk_async_climate::ClimatePassBLanes l;
    pass_b_ctx_to_kernel(c, k, l);
    pk_async_climate::climate_pass_b_land_range_pure(k, l, land_idx, begin, end);
}

// [Phase C.3b] 原 PassBLandTask + pass_b_land_worker 已由 parallel_dispatcher.h
// 内的 parallel_for_range 取代（统一所有 _thread 并行模板）。
} // namespace

// ─── pass-B SIMD（land-mask 预筛 + 直线 hot kernel） ────────────────────
//
// 与 run_climate_pass_b 同输入 / 同输出语义；改造点：
//   1. 主循环前一次性 scan IW[] 提取 land_idx；
//   2. land-only loop 走 helper（直线代码无 if (!is_water) 分支）；
//   3. 编译器在 albedo / write 段自动向量化（MSVC /O2 /arch:AVX2 等价）；
//   4. evap / rain-shadow 段保持 scalar 串行（算法本身不 SIMD-able）。
//
// fallback：任何 sanity check 失败返回 -1.0，调用方走原 run_climate_pass_b。
double DCWorldExt::run_climate_pass_b_simd(const Dictionary &knobs) {
    using godot::StringName;
    using godot::PackedFloat32Array;
    using godot::PackedInt32Array;

    auto diag = [&](const char *why) {
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_climate_pass_b_simd: ", why,
            " — fallback to GDScript");
    };

    if (!_bound) { diag("not _bound"); return -1.0; }

    const int sid_temp     = component_id(StringName("cell_temp"));
    const int sid_moist    = component_id(StringName("cell_moisture"));
    const int sid_snowpack = component_id(StringName("cell_snowpack"));
    const int sid_iswater  = component_id(StringName("cell_is_water"));
    const int sid_landform = component_id(StringName("cell_landform"));
    const int sid_veg      = component_id(StringName("cell_vegetation"));
    const int sid_elev     = component_id(StringName("cell_elevation"));
    const int sid_lat      = component_id(StringName("cell_lat_norm"));
    const int sid_pos_x    = component_id(StringName("cell_pos_x"));
    const int sid_pos_y    = component_id(StringName("cell_pos_y"));
    const int sid_insol_dev= component_id(StringName("cell_insolation_dev"));
    // A 修复（2026-06）：pass_b SIMD 同样不再写 cell_temp。
    const int sid_lanom    = component_id(StringName("cell_local_thermal_anomaly"));
    if (sid_temp < 0 || sid_moist < 0 || sid_snowpack < 0 || sid_iswater < 0 ||
        sid_landform < 0 || sid_veg < 0 || sid_elev < 0 || sid_lat < 0 ||
        sid_pos_x < 0 || sid_pos_y < 0 || sid_insol_dev < 0 || sid_lanom < 0) {
        diag("missing slot id");
        return -1.0;
    }

    if (!knobs.has("n_cells") || !knobs.has("winter_boost") ||
        !knobs.has("snow_cool") || !knobs.has("veg_cool") ||
        !knobs.has("diurnal_amp") || !knobs.has("evap_gain") ||
        !knobs.has("rs_threshold") || !knobs.has("rs_factor") ||
        !knobs.has("rs_lookback") || !knobs.has("t_freeze") ||
        !knobs.has("coupling_gain") || !knobs.has("coast_leak") ||
        !knobs.has("season_phase") ||
        !knobs.has("neighbor_indices") || !knobs.has("temp_transport_anomaly") ||
        !knobs.has("foliage_table")) {
        diag("knobs missing required keys");
        return -1.0;
    }
    const int n_cells = int(knobs["n_cells"]);
    if (n_cells <= 0) { diag("n_cells <= 0"); return -1.0; }
    if (knobs.has("go_sparse") && bool(knobs["go_sparse"])) {
        diag("go_sparse=true — sparse path not supported in SIMD variant");
        return -1.0;
    }

    PassBCtx ctx;
    ctx.winter_boost          = float(knobs["winter_boost"]);
    ctx.snow_cool             = float(knobs["snow_cool"]);
    ctx.veg_cool              = float(knobs["veg_cool"]);
    ctx.diurnal_amp           = float(knobs["diurnal_amp"]);
    ctx.evap_gain             = float(knobs["evap_gain"]);
    ctx.rs_threshold          = float(knobs["rs_threshold"]);
    ctx.rs_factor             = float(knobs["rs_factor"]);
    ctx.rs_lookback           = int(knobs["rs_lookback"]);
    ctx.wrap_period_x         = knobs.has("wrap_period_x")
        ? double(knobs["wrap_period_x"]) : _native_wrap_period_x;  // seam-advection-fix
    ctx.t_freeze              = float(knobs["t_freeze"]);
    ctx.coupling_gain         = float(knobs["coupling_gain"]);
    ctx.coast_leak            = float(knobs["coast_leak"]);
    ctx.season_phase          = double(knobs["season_phase"]);
    ctx.snowpack_cover_low    = knobs.has("snowpack_cover_low") ? float(knobs["snowpack_cover_low"]) : 0.05f;
    ctx.snowpack_cover_full   = knobs.has("snowpack_cover_full") ? float(knobs["snowpack_cover_full"]) : 0.32f;

    PackedInt32Array nb_arr = knobs["neighbor_indices"];
    PackedFloat32Array tta_arr = knobs["temp_transport_anomaly"];
    PackedFloat32Array foliage_arr = knobs["foliage_table"];
    if (nb_arr.size() < n_cells * 6) { diag("neighbor_indices size < n_cells * 6"); return -1.0; }
    if (tta_arr.size() != n_cells)   { diag("temp_transport_anomaly size mismatch"); return -1.0; }
    ctx.foliage_size = foliage_arr.size();
    if (ctx.foliage_size <= 0) { diag("foliage_table empty"); return -1.0; }

    // climate-loop-closure Phase 4.1：海冰反照率→温度反馈（可选 knobs；缺省 0 = 关闭）。
    const float sea_ice_albedo_cooling = knobs.has("sea_ice_albedo_cooling") ? float(knobs["sea_ice_albedo_cooling"]) : 0.0f;
    PackedFloat32Array sif_arr_pb;
    if (knobs.has("sea_ice_frac")) sif_arr_pb = knobs["sea_ice_frac"];
    const float * const __restrict SIF_PB = (sif_arr_pb.size() == n_cells) ? sif_arr_pb.ptr() : nullptr;
    record_production_pass_b_input(n_cells, SIF_PB, tta_arr.ptr());

    Slot &s_temp     = _slots.write[sid_temp];
    Slot &s_moist    = _slots.write[sid_moist];
    Slot &s_snowpack = _slots.write[sid_snowpack];
    Slot &s_iswater  = _slots.write[sid_iswater];
    Slot &s_landform = _slots.write[sid_landform];
    Slot &s_veg      = _slots.write[sid_veg];
    Slot &s_elev     = _slots.write[sid_elev];
    Slot &s_lat      = _slots.write[sid_lat];
    Slot &s_pos_x    = _slots.write[sid_pos_x];
    Slot &s_pos_y    = _slots.write[sid_pos_y];
    Slot &s_insol_dev= _slots.write[sid_insol_dev];
    Slot &s_lanom    = _slots.write[sid_lanom];
    if (s_temp.arr_f32.size()  != n_cells || s_moist.arr_f32.size()    != n_cells ||
        s_snowpack.arr_f32.size() != n_cells || s_iswater.arr_u8.size() != n_cells ||
        s_landform.arr_u8.size() != n_cells || s_veg.arr_u8.size()     != n_cells ||
        s_elev.arr_f32.size()  != n_cells || s_lat.arr_f32.size()      != n_cells ||
        s_pos_x.arr_f32.size() != n_cells || s_pos_y.arr_f32.size()    != n_cells ||
        s_insol_dev.arr_f32.size() != n_cells ||
        s_lanom.arr_f32.size() != n_cells) {
        diag("slot array size mismatch (re-bind needed?)");
        return -1.0;
    }

    // S3: 留存生产这一轮真实用过的标量。漏记的后果不只是 worker 吃默认 knobs ——
    // prod_knobs 诊断位也不会置，于是看起来像“这个 pass 根本没跑”。
    // native daily graph 默认走的就是 thread 变体，所以漏在这里最隐蔽。
    record_production_round_scalars(0x02, knobs);

    auto t0 = std::chrono::high_resolution_clock::now();

    // A 修复（2026-06）：pass_b SIMD 不再写 T；改写 LANOM。T 只读供 TS snapshot。
    ctx.T     = s_temp.arr_f32.ptr();
    ctx.LANOM = s_lanom.arr_f32.ptrw();
    ctx.M    = s_moist.arr_f32.ptrw();
    ctx.SNOWPACK = s_snowpack.arr_f32.ptr();
    ctx.IW   = s_iswater.arr_u8.ptr();
    ctx.LF   = s_landform.arr_u8.ptr();
    ctx.VG   = s_veg.arr_u8.ptr();
    ctx.ELEV = s_elev.arr_f32.ptr();
    ctx.LAT  = s_lat.arr_f32.ptr();
    ctx.POSX = s_pos_x.arr_f32.ptr();
    ctx.POSY = s_pos_y.arr_f32.ptr();
    ctx.INSOL_DEV = s_insol_dev.arr_f32.ptr();
    ctx.NB   = nb_arr.ptr();
    ctx.TTA  = tta_arr.ptr();
    ctx.FOL  = foliage_arr.ptr();
    ctx.n_cells = n_cells;
    ctx.sea_ice_albedo_cooling = sea_ice_albedo_cooling;
    ctx.SIF  = SIF_PB;

    // Snapshot temp BEFORE writes（与原 scalar 等价；coastal/evap 段读 TS/TTA）
    std::vector<float> temp_snapshot(n_cells);
    std::memcpy(temp_snapshot.data(), ctx.T, n_cells * sizeof(float));
    ctx.TS = temp_snapshot.data();

    // Land-cell index 预筛：reserve 上界 n_cells，append-only。
    // 后续 land hot path 直接迭代该向量，省去 if (!is_water) 分支。
    std::vector<int> land_idx;
    land_idx.reserve(n_cells);
    for (int i = 0; i < n_cells; ++i) {
        if (ctx.IW[i] == 0) land_idx.push_back(i);
    }
    const int n_land = static_cast<int>(land_idx.size());

    // Hot loop：仅遍历 land cells，直线代码无 if-water 分支。
    pass_b_run_land_range(ctx, land_idx.data(), 0, n_land);

    // climate-loop-closure Phase 4.1：海冰反照率→温度反馈尾循环（仅水域；与 scalar 同形态）。
    // A 修复（2026-06）：写入 LANOM 而非 T。
    {
        // 海冰反照率→水域 LANOM：与 scalar / worker 同一份 climate_pass_b_sea_ice_tail_pure。
        pk_async_climate::ClimatePassBKnobs tk;
        pk_async_climate::ClimatePassBLanes tl;
        pass_b_ctx_to_kernel(ctx, tk, tl);
        pk_async_climate::climate_pass_b_sea_ice_tail_pure(tk, tl);
    }

    _flush_slot_to_map(sid_lanom);
    if (!bool(knobs.get("defer_visible_publish", false))) {
        _flush_slot_to_map(sid_moist);
    }

    auto t1 = std::chrono::high_resolution_clock::now();
    return std::chrono::duration<double, std::milli>(t1 - t0).count();
}

// ─── pass-B Thread（land 段分块 WorkerThreadPool） ──────────────────────
double DCWorldExt::run_climate_pass_b_thread(const Dictionary &knobs, int n_tasks) {
    using godot::StringName;
    using godot::PackedFloat32Array;
    using godot::PackedInt32Array;

    auto diag = [&](const char *why) {
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_climate_pass_b_thread: ", why,
            " — fallback to GDScript");
    };

    if (!_bound) { diag("not _bound"); return -1.0; }
    // n_tasks <= 0 → 自适应分块（交给 parallel_for_range / parallel_default_n_tasks，
    //   公式 ceil(n_land/1024) clamp[1,16]）；与 pass_a_thread 约定一致，便于 daily
    //   graph 直接传 0 取自适应多核。显式 >0 仍按 caller 指定（bench 用）。
    if (n_tasks < 0) n_tasks = 0;

    const int sid_temp     = component_id(StringName("cell_temp"));
    const int sid_moist    = component_id(StringName("cell_moisture"));
    const int sid_snowpack = component_id(StringName("cell_snowpack"));
    const int sid_iswater  = component_id(StringName("cell_is_water"));
    const int sid_landform = component_id(StringName("cell_landform"));
    const int sid_veg      = component_id(StringName("cell_vegetation"));
    const int sid_elev     = component_id(StringName("cell_elevation"));
    const int sid_lat      = component_id(StringName("cell_lat_norm"));
    const int sid_pos_x    = component_id(StringName("cell_pos_x"));
    const int sid_pos_y    = component_id(StringName("cell_pos_y"));
    const int sid_insol_dev= component_id(StringName("cell_insolation_dev"));
    // A 修复（2026-06）：pass_b thread 同样不再写 cell_temp。
    const int sid_lanom    = component_id(StringName("cell_local_thermal_anomaly"));
    if (sid_temp < 0 || sid_moist < 0 || sid_snowpack < 0 || sid_iswater < 0 ||
        sid_landform < 0 || sid_veg < 0 || sid_elev < 0 || sid_lat < 0 ||
        sid_pos_x < 0 || sid_pos_y < 0 || sid_insol_dev < 0 || sid_lanom < 0) {
        diag("missing slot id");
        return -1.0;
    }

    if (!knobs.has("n_cells") || !knobs.has("neighbor_indices") ||
        !knobs.has("temp_transport_anomaly") || !knobs.has("foliage_table")) {
        diag("knobs missing required keys");
        return -1.0;
    }
    const int n_cells = int(knobs["n_cells"]);
    if (n_cells <= 0) { diag("n_cells <= 0"); return -1.0; }
    if (knobs.has("go_sparse") && bool(knobs["go_sparse"])) {
        diag("go_sparse=true — sparse path not supported in thread variant");
        return -1.0;
    }

    PassBCtx ctx;
    ctx.winter_boost          = float(knobs["winter_boost"]);
    ctx.snow_cool             = float(knobs["snow_cool"]);
    ctx.veg_cool              = float(knobs["veg_cool"]);
    ctx.diurnal_amp           = float(knobs["diurnal_amp"]);
    ctx.evap_gain             = float(knobs["evap_gain"]);
    ctx.rs_threshold          = float(knobs["rs_threshold"]);
    ctx.rs_factor             = float(knobs["rs_factor"]);
    ctx.rs_lookback           = int(knobs["rs_lookback"]);
    ctx.wrap_period_x         = knobs.has("wrap_period_x")
        ? double(knobs["wrap_period_x"]) : _native_wrap_period_x;  // seam-advection-fix
    ctx.t_freeze              = float(knobs["t_freeze"]);
    ctx.coupling_gain         = float(knobs["coupling_gain"]);
    ctx.coast_leak            = float(knobs["coast_leak"]);
    ctx.season_phase          = double(knobs["season_phase"]);
    ctx.snowpack_cover_low    = knobs.has("snowpack_cover_low") ? float(knobs["snowpack_cover_low"]) : 0.05f;
    ctx.snowpack_cover_full   = knobs.has("snowpack_cover_full") ? float(knobs["snowpack_cover_full"]) : 0.32f;

    PackedInt32Array nb_arr = knobs["neighbor_indices"];
    PackedFloat32Array tta_arr = knobs["temp_transport_anomaly"];
    PackedFloat32Array foliage_arr = knobs["foliage_table"];
    if (nb_arr.size() < n_cells * 6) { diag("neighbor_indices size < n_cells * 6"); return -1.0; }
    if (tta_arr.size() != n_cells)   { diag("temp_transport_anomaly size mismatch"); return -1.0; }
    ctx.foliage_size = foliage_arr.size();
    if (ctx.foliage_size <= 0) { diag("foliage_table empty"); return -1.0; }

    // [climate-mt 2026-07 bug-parity] 海冰反照率→温度水域尾循环：scalar / _simd 都有，
    //   thread 变体此前漏写（sea_ice_albedo_cooling>0 时 water LANOM 与 scalar 分叉，
    //   被 sim_2ms_ulp_tolerant_test A/B 捕获）。补齐以保证 thread 逐位等价。
    const float sea_ice_albedo_cooling = knobs.has("sea_ice_albedo_cooling") ? float(knobs["sea_ice_albedo_cooling"]) : 0.0f;
    PackedFloat32Array sif_arr_pb;
    if (knobs.has("sea_ice_frac")) sif_arr_pb = knobs["sea_ice_frac"];
    const float * const __restrict SIF_PB = (sif_arr_pb.size() == n_cells) ? sif_arr_pb.ptr() : nullptr;
    record_production_pass_b_input(n_cells, SIF_PB, tta_arr.ptr());

    Slot &s_temp     = _slots.write[sid_temp];
    Slot &s_moist    = _slots.write[sid_moist];
    Slot &s_snowpack = _slots.write[sid_snowpack];
    Slot &s_iswater  = _slots.write[sid_iswater];
    Slot &s_landform = _slots.write[sid_landform];
    Slot &s_veg      = _slots.write[sid_veg];
    Slot &s_elev     = _slots.write[sid_elev];
    Slot &s_lat      = _slots.write[sid_lat];
    Slot &s_pos_x    = _slots.write[sid_pos_x];
    Slot &s_pos_y    = _slots.write[sid_pos_y];
    Slot &s_insol_dev= _slots.write[sid_insol_dev];
    Slot &s_lanom    = _slots.write[sid_lanom];
    if (s_temp.arr_f32.size()  != n_cells || s_moist.arr_f32.size()    != n_cells ||
        s_snowpack.arr_f32.size() != n_cells || s_iswater.arr_u8.size() != n_cells ||
        s_landform.arr_u8.size() != n_cells || s_veg.arr_u8.size()     != n_cells ||
        s_elev.arr_f32.size()  != n_cells || s_lat.arr_f32.size()      != n_cells ||
        s_pos_x.arr_f32.size() != n_cells || s_pos_y.arr_f32.size()    != n_cells ||
        s_insol_dev.arr_f32.size() != n_cells ||
        s_lanom.arr_f32.size() != n_cells) {
        diag("slot array size mismatch");
        return -1.0;
    }

    // S3: 留存生产这一轮真实用过的标量，reference publish 时随 reference 发布给 worker。
    // 不写的后果是 worker 跑同一份共享内核、却吃结构默认 knobs。
    record_production_round_scalars(0x02, knobs);

    auto t0 = std::chrono::high_resolution_clock::now();

    // A 修复（2026-06）：thread 变体不再写 T；ctx.T 只读供 TS snapshot。
    ctx.T     = s_temp.arr_f32.ptr();
    ctx.LANOM = s_lanom.arr_f32.ptrw();
    ctx.M    = s_moist.arr_f32.ptrw();
    ctx.SNOWPACK = s_snowpack.arr_f32.ptr();
    ctx.IW   = s_iswater.arr_u8.ptr();
    ctx.LF   = s_landform.arr_u8.ptr();
    ctx.VG   = s_veg.arr_u8.ptr();
    ctx.ELEV = s_elev.arr_f32.ptr();
    ctx.LAT  = s_lat.arr_f32.ptr();
    ctx.POSX = s_pos_x.arr_f32.ptr();
    ctx.POSY = s_pos_y.arr_f32.ptr();
    ctx.INSOL_DEV = s_insol_dev.arr_f32.ptr();
    ctx.NB   = nb_arr.ptr();
    ctx.TTA  = tta_arr.ptr();
    ctx.FOL  = foliage_arr.ptr();
    ctx.n_cells = n_cells;
    ctx.sea_ice_albedo_cooling = sea_ice_albedo_cooling;
    ctx.SIF  = SIF_PB;

    std::vector<float> temp_snapshot(n_cells);
    std::memcpy(temp_snapshot.data(), ctx.T, n_cells * sizeof(float));
    ctx.TS = temp_snapshot.data();

    std::vector<int> land_idx;
    land_idx.reserve(n_cells);
    for (int i = 0; i < n_cells; ++i) {
        if (ctx.IW[i] == 0) land_idx.push_back(i);
    }
    const int n_land = static_cast<int>(land_idx.size());

    if (n_land == 0) {
        // 全水图：跳过 land hot loop，但海冰反照率水域尾循环仍需执行（与 scalar / _simd 等价）。
    {
        // 海冰反照率→水域 LANOM：与 scalar / worker 同一份 climate_pass_b_sea_ice_tail_pure。
        pk_async_climate::ClimatePassBKnobs tk;
        pk_async_climate::ClimatePassBLanes tl;
        pass_b_ctx_to_kernel(ctx, tk, tl);
        pk_async_climate::climate_pass_b_sea_ice_tail_pure(tk, tl);
    }
        // A 修复（2026-06）：不再 flush cell_temp，改 flush local_anom。
        _flush_slot_to_map(sid_lanom);
        if (!bool(knobs.get("defer_visible_publish", false))) {
            _flush_slot_to_map(sid_moist);
        }
        auto t1 = std::chrono::high_resolution_clock::now();
        return std::chrono::duration<double, std::milli>(t1 - t0).count();
    }

    // 任务粒度兜底：n_land 很小时（< 256），分块开销 > 收益，直接单线程跑。
    // [Phase C.3b] 整段 chunk + WTP gate + wait 由 parallel_for_range 统一封装；
    // 行为与原手写 PassBLandTask + native executor 模板严格一致：
    //   - n < 256 || n_tasks == 1 直接 run_range(0, n_land)
    //   - WTP 缺失 in-thread 顺序按 task_idx 跑（保持调度等价）
    //   - 否则 NativeParallelExecutor group + wait
    pk::parallel_for_range(
        "pk_pass_b_land", n_land, n_tasks, /*seq_threshold=*/256,
        [&](int begin, int end) {
            pass_b_run_land_range(ctx, land_idx.data(), begin, end);
        });

    // [climate-mt 2026-07 bug-parity] 海冰反照率→温度水域尾循环（仅水域，无跨 cell 依赖，
    //   串行即可；与 scalar / _simd lines 2065-2073 逐位等价）。
    {
        // 海冰反照率→水域 LANOM：与 scalar / worker 同一份 climate_pass_b_sea_ice_tail_pure。
        pk_async_climate::ClimatePassBKnobs tk;
        pk_async_climate::ClimatePassBLanes tl;
        pass_b_ctx_to_kernel(ctx, tk, tl);
        pk_async_climate::climate_pass_b_sea_ice_tail_pure(tk, tl);
    }

    _flush_slot_to_map(sid_lanom);
    if (!bool(knobs.get("defer_visible_publish", false))) {
        _flush_slot_to_map(sid_moist);
    }

    auto t1 = std::chrono::high_resolution_clock::now();
    return std::chrono::duration<double, std::milli>(t1 - t0).count();
}

// ─── sim-2ms-perf-push（plan/ocean-water-land-simd）─────────────────────────
//
// 复用 pass_b 模板：Ctx + idx 预筛 + run_range helper + WorkerThreadPool worker。
// 算法与 run_ocean_water_pass / run_ocean_land_pass 一一对应；区别仅在：
//   1. 主循环外层不再有 if(IW[i]==0)/if(IW[i]!=0) 分支——预筛后只迭代 water/land。
//   2. ptr() 一次性取到全部基址，每 i 内只剩内层 6 邻居 + advect 链路。
//   3. 内层"邻居是否合格"分支保留（gather 无收益，charter §risk=B 接受）。
// 数值容差：ulp ≤ 4（仅浮点重排，无算法变更）。
} // namespace pk
