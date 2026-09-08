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

double DCWorldExt::run_ocean_land_pass_simd(Dictionary knobs) {
    using godot::StringName;
    using godot::PackedFloat32Array;
    using godot::PackedInt32Array;

    auto diag = [&](const char *why) {
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_ocean_land_pass_simd: ", why,
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

    // CoW fix: duplicate anomaly_inout 以独占 ptrw（同 scalar 路径）
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

    pk_run_ocean_land_pure(
        n_cells, effective_leak, wrap_period_x,
        tta_source_cap, tta_blend_rate, tta_decay_rate,
        ctx.IW, ctx.POSX, ctx.POSY, ctx.OCX, ctx.OCY, ctx.NB,
        ctx.A, ctx.OANOM_SLOT);

    knobs["anomaly_inout"] = anomaly_inout;
    // A 修复（2026-06）：flush ocean anomaly slot 而非 cell_temp。
    _flush_slot_to_map(sid_oanom);

    auto t1 = std::chrono::high_resolution_clock::now();
    return std::chrono::duration<double, std::milli>(t1 - t0).count();
}

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
double DCWorldExt::run_transpiration_pass(Dictionary knobs) {
    _production_stage_mask |= pk_async_climate::CLIMATE_STAGE_BIT_TRANSPIRATION;
    using godot::StringName;
    using godot::PackedFloat32Array;
    using godot::PackedInt32Array;

    auto diag = [&](const char *why) {
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_transpiration_pass: ", why,
            " — fallback to GDScript");
    };

    if (!_bound) { diag("not _bound"); return -1.0; }

    const int sid_landform   = component_id(StringName("cell_landform"));
    const int sid_vegetation = component_id(StringName("cell_vegetation"));
    const int sid_moisture   = component_id(StringName("cell_moisture"));
    if (sid_landform < 0 || sid_vegetation < 0 || sid_moisture < 0) {
        diag("missing slot id (cell_landform / cell_vegetation / cell_moisture)");
        return -1.0;
    }

    if (!knobs.has("n_cells") || !knobs.has("outflow_rate") ||
        !knobs.has("self_rate") || !knobs.has("neighbor_indices") ||
        !knobs.has("donor_table")) {
        diag("knobs missing required keys");
        return -1.0;
    }
    const int   n_cells     = int(knobs["n_cells"]);
    const float outflow_rate = float(knobs["outflow_rate"]);
    const float self_rate    = float(knobs["self_rate"]);
    if (n_cells <= 0) { diag("n_cells <= 0"); return -1.0; }

    PackedInt32Array   nb_arr     = knobs["neighbor_indices"];
    PackedFloat32Array donor_arr  = knobs["donor_table"];
    if (nb_arr.size() < n_cells * 6) {
        diag("neighbor_indices size < n_cells * 6");
        return -1.0;
    }
    const int donor_size = donor_arr.size();
    if (donor_size <= 0) { diag("donor_table empty"); return -1.0; }

    Slot &s_landform = _slots.write[sid_landform];
    Slot &s_veg      = _slots.write[sid_vegetation];
    Slot &s_moist    = _slots.write[sid_moisture];
    if (s_landform.arr_u8.size() != n_cells ||
        s_veg.arr_u8.size()      != n_cells ||
        s_moist.arr_f32.size()   != n_cells) {
        diag("slot array size mismatch (re-bind needed?)");
        return -1.0;
    }

    auto t0 = std::chrono::high_resolution_clock::now();

    // S3：算法体是共享纯内核，与 async round 和 SHADOW worker 完全同一份代码。
    // 这里只负责 slot → buffer → slot 的搬运；transpiration 不再有第二份实现。
    using namespace pk_async_climate;
    ClimateInputBuf &tin = _transp_sync_input_buf;
    ClimateOutputBuf &tout = _transp_sync_output_buf;
    ClimateRoundStaticKnobs tknobs;
    tin.n_cells = n_cells;
    tin.landform.assign(s_landform.arr_u8.ptr(), s_landform.arr_u8.ptr() + n_cells);
    tin.vegetation.assign(s_veg.arr_u8.ptr(), s_veg.arr_u8.ptr() + n_cells);
    tin.moisture.assign(s_moist.arr_f32.ptr(), s_moist.arr_f32.ptr() + n_cells);
    tin.scalars.transp_outflow_rate = outflow_rate;
    tin.scalars.transp_self_rate = self_rate;
    tknobs.n_cells = n_cells;
    tknobs.neighbor_indices.assign(nb_arr.ptr(), nb_arr.ptr() + n_cells * 6);
    tknobs.donor_table.assign(donor_arr.ptr(), donor_arr.ptr() + donor_size);

    if (!_async_transp_kernel_pure(tin, tknobs, _transp_sync_work_buf, tout)) {
        diag("shared transp kernel rejected input dimensions");
        return -1.0;
    }
    auto t_compute = std::chrono::high_resolution_clock::now();

    // 内核的 dirty 列表就是"哪些 cell 真的变了"，直接转成 Godot 侧的两条数组，
    // 不再重新扫一遍。
    float * const __restrict M = s_moist.arr_f32.ptrw();
    const int dirty_count = (int)tout.moisture_dirty_indices.size();
    PackedInt32Array dirty_indices;
    PackedFloat32Array dirty_values;
    dirty_indices.resize(dirty_count);
    dirty_values.resize(dirty_count);
    for (int k = 0; k < dirty_count; ++k) {
        const int32_t idx = tout.moisture_dirty_indices[k];
        const float value = tout.moisture_dirty_values[k];
        M[idx] = value;
        dirty_indices.set(k, idx);
        dirty_values.set(k, value);
    }
    knobs["dirty_indices"] = dirty_indices;
    knobs["dirty_values"] = dirty_values;
    knobs["dirty_count"] = dirty_count;
    auto t_apply = std::chrono::high_resolution_clock::now();

    // §11.2 flush: push CoW-detached cell_moisture back to MapData
    if (!bool(knobs.get("defer_visible_publish", false))) {
        _flush_slot_to_map(sid_moisture);
    }

    auto t1 = std::chrono::high_resolution_clock::now();
    knobs["compute_ms"] = std::chrono::duration<double, std::milli>(t_compute - t0).count();
    knobs["apply_ms"] = std::chrono::duration<double, std::milli>(t_apply - t_compute).count();
    knobs["flush_ms"] = std::chrono::duration<double, std::milli>(t1 - t_apply).count();
    return std::chrono::duration<double, std::milli>(t1 - t0).count();
}

Dictionary DCWorldExt::run_runtime_hydrology_pass(const Dictionary &knobs) {
    using godot::PackedFloat32Array;
    using godot::StringName;

    Dictionary out;
    const auto t0 = std::chrono::high_resolution_clock::now();
    auto fail = [&](const char *why) -> Dictionary {
        const auto t1 = std::chrono::high_resolution_clock::now();
        out["done"] = true;
        out["path"] = "gdext";
        out["fallback_reason"] = why;
        out["published_to_slot"] = false;
        out["native_ms"] = std::chrono::duration<double, std::milli>(t1 - t0).count();
        out["compute_ms"] = 0.0;
        out["flush_ms"] = 0.0;
        out["n_cells"] = 0;
        out["water_budget_error"] = 0.0;
        out["river_discharge_p95"] = 0.0;
        out["river_discharge_max"] = 0.0;
        out["moisture_response_alpha"] = 0.0;
        out["river_moisture_max_delta"] = 0.0;
        out["riparian_moisture_max_delta"] = 0.0;
        out["flood_candidate_count"] = 0;
        return out;
    };

    if (!_bound) return fail("world_ext_not_bound");

    const int sid_hparent = component_id(StringName("cell_hydro_parent"));
    const int sid_has_riv = component_id(StringName("cell_has_river"));
    const int sid_terrain = component_id(StringName("cell_terrain"));
    const int sid_landform = component_id(StringName("cell_landform"));
    const int sid_elev = component_id(StringName("cell_elevation"));
    const int sid_veg = component_id(StringName("cell_vegetation"));
    const int sid_cover = component_id(StringName("cell_cover"));
    const int sid_precip = component_id(StringName("cell_weather_precip"));
    const int sid_intensity = component_id(StringName("cell_weather_intensity"));
    const int sid_wtype = component_id(StringName("cell_weather_type"));
    const int sid_temp = component_id(StringName("cell_temp"));
    const int sid_heat = component_id(StringName("cell_heat_input"));
    const int sid_snowpack = component_id(StringName("cell_snowpack"));
    const int sid_moist = component_id(StringName("cell_moisture"));
    const int sid_base_m = component_id(StringName("cell_base_moisture"));
    const int sid_soil = component_id(StringName("cell_soil_moisture"));
    const int sid_wb30 = component_id(StringName("cell_water_balance_30d"));
    const int sid_plant_water = component_id(StringName("cell_plant_available_water"));
    const int sid_is_water = component_id(StringName("cell_is_water"));
    const int sid_vital = component_id(StringName("cell_vegetation_vitality"));
    const int sid_q = component_id(StringName("cell_river_discharge"));
    const int sid_q30 = component_id(StringName("cell_river_discharge_30d"));
    const int sid_storage = component_id(StringName("cell_river_storage"));
    const int sid_gw = component_id(StringName("cell_groundwater_storage"));
    const int sid_runoff = component_id(StringName("cell_surface_runoff"));
    const int sid_canal_mask = component_id(StringName("cell_canal_edge_mask"));
    const int sid_canal_water = component_id(StringName("cell_canal_water"));

    const int required[] = {
        sid_hparent, sid_has_riv, sid_terrain, sid_landform, sid_elev, sid_veg, sid_cover,
        sid_precip, sid_intensity, sid_wtype, sid_temp, sid_heat, sid_snowpack, sid_moist,
        sid_base_m, sid_soil, sid_wb30, sid_plant_water, sid_is_water, sid_vital,
        sid_q, sid_q30, sid_storage, sid_gw, sid_runoff,
        sid_canal_mask, sid_canal_water
    };
    for (int sid : required) {
        if (sid < 0 || sid >= int(_slots.size())) return fail("missing_required_slot");
    }

    const int n_cells = knobs.has("n_cells") ? int(knobs["n_cells"]) : int(_entity_archetype.size());
    if (n_cells <= 0) return fail("empty_world");

    auto slot_ok_f32 = [&](int sid) -> bool { return int(_slots.write[sid].arr_f32.size()) >= n_cells; };
    auto slot_ok_i32 = [&](int sid) -> bool { return int(_slots.write[sid].arr_i32.size()) >= n_cells; };
    auto slot_ok_u8 = [&](int sid) -> bool { return int(_slots.write[sid].arr_u8.size()) >= n_cells; };
    if (!slot_ok_i32(sid_hparent) || !slot_ok_u8(sid_has_riv) || !slot_ok_u8(sid_terrain) ||
        !slot_ok_u8(sid_landform) || !slot_ok_f32(sid_elev) || !slot_ok_u8(sid_veg) ||
        !slot_ok_u8(sid_cover) || !slot_ok_f32(sid_precip) || !slot_ok_f32(sid_intensity) ||
        !slot_ok_u8(sid_wtype) || !slot_ok_f32(sid_temp) || !slot_ok_f32(sid_heat) ||
        !slot_ok_f32(sid_snowpack) || !slot_ok_f32(sid_moist) || !slot_ok_f32(sid_base_m) ||
        !slot_ok_f32(sid_soil) || !slot_ok_f32(sid_wb30) ||
        !slot_ok_f32(sid_plant_water) || !slot_ok_u8(sid_is_water) ||
        !slot_ok_f32(sid_vital) ||
        !slot_ok_f32(sid_q) || !slot_ok_f32(sid_q30) || !slot_ok_f32(sid_storage) ||
        !slot_ok_f32(sid_gw) || !slot_ok_f32(sid_runoff) ||
        !slot_ok_u8(sid_canal_mask) || !slot_ok_f32(sid_canal_water)) {
        return fail("slot_size_mismatch");
    }

    // 标量收进 POD 结构体。派生系数（*_eff / *_alpha）不在这里算 —— 它们由
    // hydrology_pass_pure 按 dt_days 自己推，避免生产与 worker 各写一份公式。
    pk_async_climate::HydrologyKnobs hk;
    hk.n_cells = n_cells;
    const auto knob_f = [&knobs](const char *key, float fallback) {
        return knobs.has(key) ? float(knobs[key]) : fallback;
    };
    hk.precip_scale = knob_f("hydro_precip_scale", 1.0f);
    hk.snowmelt_scale = knob_f("hydro_snowmelt_scale", 0.55f);
    hk.soil_capacity = knobs.has("hydro_soil_capacity")
        ? std::max(0.05f, float(knobs["hydro_soil_capacity"])) : 0.75f;
    hk.infiltration_rate = knobs.has("hydro_infiltration_rate")
        ? dc_clampf(float(knobs["hydro_infiltration_rate"]), 0.0f, 1.0f) : 0.52f;
    hk.quickflow_fraction = knobs.has("hydro_quickflow_fraction")
        ? dc_clampf(float(knobs["hydro_quickflow_fraction"]), 0.0f, 1.0f) : 0.36f;
    hk.baseflow_recession = knobs.has("hydro_baseflow_recession")
        ? dc_clampf(float(knobs["hydro_baseflow_recession"]), 0.0f, 1.0f) : 0.035f;
    hk.channel_release = knobs.has("hydro_channel_release_rate")
        ? dc_clampf(float(knobs["hydro_channel_release_rate"]), 0.01f, 1.0f) : 0.62f;
    hk.lake_release = knobs.has("hydro_lake_release_rate")
        ? dc_clampf(float(knobs["hydro_lake_release_rate"]), 0.005f, 1.0f) : 0.18f;
    hk.discharge_ema = knobs.has("hydro_discharge_ema")
        ? dc_clampf(float(knobs["hydro_discharge_ema"]), 0.01f, 1.0f) : 0.08f;
    hk.bank_moisture_gain = knobs.has("hydro_bank_moisture_gain")
        ? dc_clampf(float(knobs["hydro_bank_moisture_gain"]), 0.0f, 0.25f) : 0.035f;
    hk.river_moisture_floor = knobs.has("hydro_river_moisture_floor")
        ? dc_clampf(float(knobs["hydro_river_moisture_floor"]), 0.0f, 1.0f) : 0.66f;
    hk.riparian_moisture_floor = knobs.has("hydro_riparian_moisture_floor")
        ? dc_clampf(float(knobs["hydro_riparian_moisture_floor"]), 0.0f, 1.0f) : 0.38f;
    hk.river_evap_gain = knobs.has("hydro_river_evap_gain")
        ? dc_clampf(float(knobs["hydro_river_evap_gain"]), 0.0f, 1.0f) : 0.12f;
    hk.moisture_response_rate = knobs.has("hydro_moisture_response_rate")
        ? dc_clampf(float(knobs["hydro_moisture_response_rate"]), 0.0f, 1.0f) : 0.08f;
    hk.flood_threshold = knobs.has("hydro_flood_threshold")
        ? std::max(0.01f, float(knobs["hydro_flood_threshold"])) : 2.2f;
    hk.snowpack_melt_temp_gain = knob_f("snowpack_melt_temp_gain", 0.22f);
    hk.snowpack_melt_sun_gain = knob_f("snowpack_melt_sun_gain", 0.12f);
    hk.plant_water_balance_weight = knob_f("plant_water_balance_weight", 0.35f);
    hk.plant_soil_buffer_weight = knob_f("plant_soil_buffer_weight", 0.25f);
    hk.plant_drought_penalty = knob_f("plant_drought_penalty", 0.65f);
    hk.dt_days = knobs.has("dt_days")
        ? dc_clampf(float(knobs["dt_days"]), 1.0f, 30.0f) : 1.0f;
    const float moisture_response_alpha =
        1.0f - std::pow(1.0f - hk.moisture_response_rate, hk.dt_days);
    PackedInt32Array neighbor_indices;
    if (knobs.has("neighbor_indices")) {
        neighbor_indices = knobs["neighbor_indices"];
    }
    const bool has_neighbor_indices = neighbor_indices.size() >= n_cells * 6;

    pk_async_climate::HydrologyLanes hl;
    hl.hydro_parent = _slots.write[sid_hparent].arr_i32.ptr();
    hl.has_river = _slots.write[sid_has_riv].arr_u8.ptr();
    hl.terrain = _slots.write[sid_terrain].arr_u8.ptr();
    hl.landform = _slots.write[sid_landform].arr_u8.ptr();
    hl.vegetation = _slots.write[sid_veg].arr_u8.ptr();
    hl.cover = _slots.write[sid_cover].arr_u8.ptr();
    hl.elevation = _slots.write[sid_elev].arr_f32.ptr();
    hl.precip = _slots.write[sid_precip].arr_f32.ptr();
    hl.intensity = _slots.write[sid_intensity].arr_f32.ptr();
    hl.weather_type = _slots.write[sid_wtype].arr_u8.ptr();
    hl.temp = _slots.write[sid_temp].arr_f32.ptr();
    hl.heat = _slots.write[sid_heat].arr_f32.ptr();
    hl.snowpack = _slots.write[sid_snowpack].arr_f32.ptr();
    hl.base_moisture = _slots.write[sid_base_m].arr_f32.ptr();
    hl.is_water = _slots.write[sid_is_water].arr_u8.ptr();
    hl.vitality = _slots.write[sid_vital].arr_f32.ptr();
    hl.canal_mask = _slots.write[sid_canal_mask].arr_u8.ptr();
    hl.neighbor_indices = has_neighbor_indices ? neighbor_indices.ptr() : nullptr;
    hl.moisture = _slots.write[sid_moist].arr_f32.ptrw();
    hl.soil_moisture = _slots.write[sid_soil].arr_f32.ptrw();
    hl.water_balance_30d = _slots.write[sid_wb30].arr_f32.ptrw();
    hl.plant_water = _slots.write[sid_plant_water].arr_f32.ptrw();
    hl.discharge = _slots.write[sid_q].arr_f32.ptrw();
    hl.discharge_30d = _slots.write[sid_q30].arr_f32.ptrw();
    hl.river_storage = _slots.write[sid_storage].arr_f32.ptrw();
    hl.groundwater = _slots.write[sid_gw].arr_f32.ptrw();
    hl.runoff = _slots.write[sid_runoff].arr_f32.ptrw();
    hl.canal_water = _slots.write[sid_canal_water].arr_f32.ptrw();

    const auto tc0 = std::chrono::high_resolution_clock::now();

    // S3：如实上报"生产这一天跑了 stage 12 RUNTIME_HYDROLOGY"。放在所有守卫之后，
    // 因为上面的 fail() 分支属于"这一天没算"。
    _production_stage_mask |= pk_async_climate::CLIMATE_STAGE_BIT_RUNTIME_HYDROLOGY;

    // stage 12 的数值核心已抽成共享纯内核 pk_async_climate::hydrology_pass_pure。
    // 运河编译态整组抬进 HydrologyCanalState：以前它是五个 DCWorldExt 成员，worker
    // 拿不到，于是水文根本没法在 worker 侧跑。现在主线程与 worker 各持一份、各自按
    // topology_generation 失效。
    _hydrology_canal.topology_generation = _canal_topology_generation;
    pk_async_climate::HydrologyStats hs;
    // 记录给 worker 对拍用的输入。必须在内核之前：MOIST / SOIL / WB30 / Q / Q30 /
    // STORAGE / GW / CANAL_WATER 都是 in/out，跑完再记就变成记结果。
    record_production_hydrology_input(hk, hl, has_neighbor_indices,
                                     _canal_topology_generation, n_cells);
    pk_async_climate::hydrology_pass_pure(hk, hl, _hydrology_canal,
                                        _hydrology_scratch, hs);

    const double water_in_total = hs.water_in_total;
    const double outlet_total = hs.outlet_total;
    const int runoff_source_cells = hs.runoff_source_cells;
    const int river_cells_processed = hs.river_cells_processed;
    const int riparian_neighbor_touches = hs.riparian_neighbor_touches;
    const int river_moisture_floor_touches = hs.river_moisture_floor_touches;
    const int riparian_moisture_floor_touches = hs.riparian_moisture_floor_touches;
    const float river_moisture_max_delta = hs.river_moisture_max_delta;
    const float riparian_moisture_max_delta = hs.riparian_moisture_max_delta;
    const int flood_candidate_count = hs.flood_candidate_count;
    const int canal_cells_processed = hs.canal_cells_processed;
    const int canal_edges_processed = hs.canal_edges_processed;
    const int canal_freshwater_cells = hs.canal_freshwater_cells;
    const int canal_saline_cells = hs.canal_saline_cells;
    const float q_max = hs.q_max;
    const float q_p95 = hs.q_p95;

    const auto tc1 = std::chrono::high_resolution_clock::now();
    const auto tf0 = std::chrono::high_resolution_clock::now();
    _flush_slot_to_map(sid_q);
    _flush_slot_to_map(sid_q30);
    _flush_slot_to_map(sid_storage);
    _flush_slot_to_map(sid_gw);
    _flush_slot_to_map(sid_runoff);
    const bool defer_visual_publish =
        _native_daily_visual_commit_pending || bool(knobs.get("defer_visible_publish", false));
    if (!defer_visual_publish) {
        _flush_slot_to_map(sid_moist);
    }
    _flush_slot_to_map(sid_soil);
    _flush_slot_to_map(sid_wb30);
    _flush_slot_to_map(sid_plant_water);
    _flush_slot_to_map(sid_canal_water);
    const auto tf1 = std::chrono::high_resolution_clock::now();
    const auto t1 = std::chrono::high_resolution_clock::now();

    const double compute_ms = std::chrono::duration<double, std::milli>(tc1 - tc0).count();
    const double flush_ms = std::chrono::duration<double, std::milli>(tf1 - tf0).count();
    const double native_ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
    out["done"] = true;
    out["path"] = "gdext";
    out["fallback_reason"] = "";
    out["published_to_slot"] = true;
    out["visible_publish_deferred"] = defer_visual_publish;
    out["native_ms"] = native_ms;
    out["compute_ms"] = compute_ms;
    out["kernel_ms"] = compute_ms;
    out["flush_ms"] = flush_ms;
    out["n_cells"] = n_cells;
    out["processed_cells"] = n_cells;
    out["dt_days"] = hk.dt_days;
    out["runoff_source_cells"] = runoff_source_cells;
    out["river_cells_processed"] = river_cells_processed;
    out["riparian_neighbor_touches"] = riparian_neighbor_touches;
    out["river_moisture_floor_touches"] = river_moisture_floor_touches;
    out["riparian_moisture_floor_touches"] = riparian_moisture_floor_touches;
    out["moisture_response_rate"] = hk.moisture_response_rate;
    out["moisture_response_alpha"] = moisture_response_alpha;
    out["river_moisture_max_delta"] = river_moisture_max_delta;
    out["riparian_moisture_max_delta"] = riparian_moisture_max_delta;
    out["water_budget_error"] = water_in_total > 0.000001 ? std::abs(water_in_total - outlet_total) / water_in_total : 0.0;
    out["river_discharge_p95"] = q_p95;
    out["river_discharge_max"] = q_max;
    out["flood_candidate_count"] = flood_candidate_count;
    out["flood_count"] = flood_candidate_count;
    out["canal_cells_processed"] = canal_cells_processed;
    out["canal_edges_processed"] = canal_edges_processed;
    out["canal_freshwater_cells"] = canal_freshwater_cells;
    out["canal_saline_cells"] = canal_saline_cells;
    return out;
}

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

// ─── [Phase C.3c] run_albedo_pass_thread ─────────────────────────────────
//
// run_albedo_pass 的 WorkerThreadPool 并行版本。
// 主循环纯 cell-local map（IW 跳水后只 read VG/CV/ALB，write 自身 T[i]）→ 完美 Tier-1，
// 无 race，可直接拆 cell range 并行。
//
// 与 run_ocean_water_pass_thread (line 4511) / run_ocean_land_pass_thread (line 4776)
// 模板严格一致：完整复制 prelude + 仅末段主循环改 pk::parallel_for_range。
// n_tasks=0 → 自适应（ceil(n/1024) 截 [1,16]）；n_cells < 256 || n_tasks==1 → 直接顺序。
double DCWorldExt::run_albedo_pass_thread(const Dictionary &knobs, int n_tasks) {
    // S3：这里原本是 albedo 的第二份实现（prelude 全量复制 + 主循环走
    // pk::parallel_for_range）。与 run_climate_pass_a_thread 同理：albedo 主循环在
    // N=2400 时是微秒级，并行收益不足以换一份必须永久手工同步的副本，
    // 而 parity_hash 是逐位归约——同形的 float 循环在不同向量化下会差 1 ULP。
    //
    // 现在统一转发到 run_albedo_pass，由它调共享纯内核
    // pk_async_climate::albedo_apply_pure。
    (void)n_tasks;
    return run_albedo_pass(knobs);
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
// ─── [Phase C.3d] vegetation_dynamics 并行变体 ───────────────────────
double DCWorldExt::run_vegetation_dynamics_pass_thread(Dictionary knobs, int n_tasks) {
    // S3：这里原本是 vegetation_dynamics 的第二份实现（prelude 全量复制 +
    // 主循环走 pk::parallel_for_range_with_emit）。与 run_albedo_pass_thread /
    // run_climate_feedback_pass_thread 同理：共享纯内核已经支持 [begin, end)
    // 分段，但 parity_hash 是逐位归约 —— 同形的 float 循环在不同向量化下会差
    // 1 ULP，而 N=2400 时并行收益不足以换一份必须永久手工同步的副本。
    (void)n_tasks;
    return run_vegetation_dynamics_pass(knobs);
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

// ─── [Phase C.3c] run_climate_feedback_pass_thread ───────────────────────
//
// run_climate_feedback_pass 的 WorkerThreadPool 并行版本。
// 主循环：read NB+TTA+IW+WTT+WTI+WTIN，gather 邻居 TTA，但**只 write self**
// （BM[i]+SOIL[i]+VG[i]）→ 无 race，可直接拆 cell range 并行。
//
// 与 run_albedo_pass_thread 模板严格一致：完整复制 prelude + 主循环走 parallel_for_range。
// n_tasks=0 → 自适应；n_cells < 256 || n_tasks==1 → 直接顺序。
double DCWorldExt::run_climate_feedback_pass_thread(Dictionary knobs, int n_tasks) {
    // S3：这里原本是 feedback 的第二份实现（prelude 全量复制 + 主循环走
    // pk::parallel_for_range）。与 run_albedo_pass_thread / run_climate_pass_a_thread 同理：
    // N=2400 时这个循环是微秒级，并行收益不足以换一份必须永久手工同步的
    // 副本；而 parity_hash 是逐位归约 —— 同形的 float 循环在不同向量化下会差 1 ULP。
    (void)n_tasks;
    return run_climate_feedback_pass(knobs);
}

// ─── 方案 B：stage_b 三段合并 run_stage_b_pass ────────────────────────────
//
// 生产热路径只跑这一份 fused loop。独立的 run_albedo_pass /
// run_vegetation_dynamics_pass / run_climate_feedback_pass 仍保留 1:1 拷贝，
// 仅供 SHADOW / 缺 stage_b_knobs 的 helper；slice graph 在已有 stage_b_knobs
// 时跳过拆开节点，避免双跑。
//
// 这是 run_albedo_pass + run_vegetation_dynamics_pass +
// run_climate_feedback_pass 的顺序内联合并版本。三段主循环算法**完全 1:1
// 拷贝**自原三个独立函数，仅做以下结构合并：
//
//   1. 单一 prelude：_bound 检查 + slot id resolve + size validate（合并需要
//      的 9 个 SoA slot：cell_is_water / cell_vegetation / cell_cover /
//      cell_temp / cell_moisture / cell_weather_type / cell_weather_intensity /
//      cell_weather_field_init / cell_base_moisture）。
//   2. 三个 run_* bool 控制是否跑（保留 GDScript 端 stride 语义；
//      false 时整段连入参验证都跳过，避免把 false 段的 knobs 设为必填）。
//   3. cross-pass 依赖：albedo 写 cell_temp、veg_dyn 读 cell_temp。合并版本里
//      两段共享同一份 s_temp.arr_f32 ptrw，**无需中间 _flush_slot_to_map** ——
//      这是合并相对于"GDScript 跑三次 cpp call 各自 flush + GDScript 端
//      refresh_slots_from_map 各自一次"的核心收益之一。
//   4. 末尾批量 flush（仅 cell_temp + cell_base_moisture 两个 SoA 写出 slot）；
//      _flush_slot_to_map 是 O(1) Variant 引用交换，开销可忽略（参见 §11.2 注释）。
//   5. 计时：每段独立 chrono → ms 写回 knobs（albedo_ms / veg_dyn_ms /
//      feedback_ms），caller 端用作 _last_weather_breakdown 沿用打点。
//
// **不修改任何算法逻辑**。如果发现 SAME_SOURCE A/B 漂移，回头去改这里就是
// 合并破坏了语义；目标是字节级一致。
double DCWorldExt::run_stage_b_pass(Dictionary knobs) {
    using godot::StringName;
    using godot::PackedFloat32Array;
    using godot::PackedInt32Array;
    using godot::PackedByteArray;

    auto diag = [&](const char *why) {
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_stage_b_pass: ", why,
            " — fallback to GDScript");
    };

    if (!_bound) { diag("not _bound"); return -1.0; }

    // ─── 总开关 + n_cells ───────────────────────────────────────────────
    if (!knobs.has("n_cells")) { diag("knobs missing n_cells"); return -1.0; }
    const int n_cells = int(knobs["n_cells"]);
    if (n_cells <= 0) { diag("n_cells <= 0"); return -1.0; }
    const bool run_albedo   = bool(knobs.get("run_albedo",   false));
    const bool run_veg_dyn  = bool(knobs.get("run_veg_dyn",  false));
    const bool run_feedback = bool(knobs.get("run_feedback", false));
    if (!run_albedo && !run_veg_dyn && !run_feedback) {
        // 三个 stride 同 tick 都跳过 —— 也算合法，返回 0ms 让 caller 走快路径
        knobs["albedo_ms"]   = 0.0;
        knobs["veg_dyn_ms"]  = 0.0;
        knobs["feedback_ms"] = 0.0;
        return 0.0;
    }

    // ─── Resolve 所有 slot id（即使某段不跑也 resolve，便于一次性失败诊断） ──
    const int sid_iswater  = component_id(StringName("cell_is_water"));
    const int sid_veg      = component_id(StringName("cell_vegetation"));
    const int sid_cover    = component_id(StringName("cell_cover"));
    const int sid_terrain  = component_id(StringName("cell_terrain"));
    const int sid_landform = component_id(StringName("cell_landform"));
    const int sid_temp     = component_id(StringName("cell_temp"));
    const int sid_temp_30d = component_id(StringName("cell_temp_30d"));
    const int sid_moist    = component_id(StringName("cell_moisture"));
    const int sid_water_bal = component_id(StringName("cell_water_balance_30d"));
    const int sid_plant_water = component_id(StringName("cell_plant_available_water"));
    const int sid_wt_type  = component_id(StringName("cell_weather_type"));
    const int sid_wt_int   = component_id(StringName("cell_weather_intensity"));
    const int sid_wt_init  = component_id(StringName("cell_weather_field_init"));
    const int sid_base_m   = component_id(StringName("cell_base_moisture"));
    if (sid_iswater < 0 || sid_veg < 0 || sid_cover < 0 || sid_terrain < 0 || sid_landform < 0 || sid_temp < 0 ||
        sid_temp_30d < 0 || sid_moist < 0 || sid_water_bal < 0 || sid_plant_water < 0 ||
        sid_wt_type < 0 || sid_wt_int < 0 ||
        sid_wt_init < 0 || sid_base_m < 0) {
        diag("missing slot id (one of cell_is_water/vegetation/cover/temp/moisture/"
             "weather_type/weather_intensity/weather_field_init/base_moisture)");
        return -1.0;
    }

    // ─── B3b：6 个植被动力学新 slot（vit/low/high/soil/vg/tta） ────────────
    // use_soa = true 时，veg_dyn / feedback 段直接读写这 6 个 slot 的 _slots 后端，
    // 不再从 knobs 取 PackedArray（消除 GDScript 端 pack/unpack ~7ms wall）。
    // use_soa = false 时（向后兼容），仍走 knobs PackedArray 路径，slot id 仅做
    // 一次性 resolve 不消费——保证老 caller 的 SAME_SOURCE A/B 不破坏。
    const bool use_soa = bool(knobs.get("use_soa", false));
    const bool vegetation_stress_enabled_stage_b = bool(knobs.get("vegetation_stress_enabled", false));
    const int sid_vit       = component_id(StringName("cell_vegetation_vitality"));
    const int sid_low_streak  = component_id(StringName("cell_vitality_low_streak"));
    const int sid_high_streak = component_id(StringName("cell_vitality_high_streak"));
    const int sid_soil      = component_id(StringName("cell_soil_moisture"));
    const int sid_vgp       = component_id(StringName("cell_vegetation_growth_pressure"));
    const int sid_tta       = component_id(StringName("cell_temperature_transport_anomaly"));
    const int sid_v_heat    = component_id(StringName("cell_vegetation_heat_stress"));
    const int sid_v_drought = component_id(StringName("cell_vegetation_drought_stress"));
    const int sid_v_cold    = component_id(StringName("cell_vegetation_cold_stress"));
    const int sid_v_regen   = component_id(StringName("cell_vegetation_regen_score"));
    if (use_soa) {
        if (sid_vit < 0 || sid_low_streak < 0 || sid_high_streak < 0 ||
            sid_soil < 0 || sid_vgp < 0 || sid_tta < 0) {
            diag("[use_soa] missing one of cell_vegetation_vitality / "
                 "cell_vitality_low_streak / cell_vitality_high_streak / "
                 "cell_soil_moisture / cell_vegetation_growth_pressure / "
                 "cell_temperature_transport_anomaly — did bind_map_data run after schema update?");
            return -1.0;
        }
        if (vegetation_stress_enabled_stage_b &&
            (sid_v_heat < 0 || sid_v_drought < 0 || sid_v_cold < 0 || sid_v_regen < 0)) {
            diag("[use_soa] missing vegetation stress slots "
                 "(cell_vegetation_heat_stress / drought / cold / regen_score)");
            return -1.0;
        }
    }

    // ─── Acquire all slot arrays + validate sizes ───────────────────────
    Slot &s_iswater = _slots.write[sid_iswater];
    Slot &s_veg     = _slots.write[sid_veg];
    Slot &s_cover   = _slots.write[sid_cover];
    Slot &s_terrain = _slots.write[sid_terrain];
    Slot &s_landform = _slots.write[sid_landform];
    Slot &s_temp    = _slots.write[sid_temp];
    Slot &s_temp30  = _slots.write[sid_temp_30d];
    Slot &s_moist   = _slots.write[sid_moist];
    Slot &s_wb      = _slots.write[sid_water_bal];
    Slot &s_plant_water = _slots.write[sid_plant_water];
    Slot &s_wt_type = _slots.write[sid_wt_type];
    Slot &s_wt_int  = _slots.write[sid_wt_int];
    Slot &s_wt_init = _slots.write[sid_wt_init];
    Slot &s_base_m  = _slots.write[sid_base_m];
    if (s_iswater.arr_u8.size() != n_cells || s_veg.arr_u8.size()    != n_cells ||
        s_cover.arr_u8.size()   != n_cells || s_terrain.arr_u8.size() != n_cells ||
        s_landform.arr_u8.size() != n_cells || s_temp.arr_f32.size()  != n_cells ||
        s_temp30.arr_f32.size() != n_cells || s_moist.arr_f32.size() != n_cells ||
        s_wb.arr_f32.size()     != n_cells || s_plant_water.arr_f32.size() != n_cells ||
        s_wt_type.arr_u8.size()!= n_cells ||
        s_wt_int.arr_f32.size() != n_cells || s_wt_init.arr_u8.size()!= n_cells ||
        s_base_m.arr_f32.size() != n_cells) {
        diag("slot array size mismatch (re-bind needed?)");
        return -1.0;
    }

    // 通用 SoA pointer
    const uint8_t * const __restrict IW    = s_iswater.arr_u8.ptr();
    const uint8_t * const __restrict VG    = s_veg.arr_u8.ptr();
    const uint8_t * const __restrict CV    = s_cover.arr_u8.ptr();
    const uint8_t * const __restrict TERR  = s_terrain.arr_u8.ptr();
    const uint8_t * const __restrict LF    = s_landform.arr_u8.ptr();
    float         * const __restrict T     = s_temp.arr_f32.ptrw();   // albedo 写、veg_dyn 读
    const float   * const __restrict T30   = s_temp30.arr_f32.ptr();
    const float   * const __restrict M     = s_moist.arr_f32.ptr();
    const float   * const __restrict WBAL  = s_wb.arr_f32.ptr();
    float         * const __restrict PLANT_WATER = s_plant_water.arr_f32.ptrw();
    const uint8_t * const __restrict WTT   = s_wt_type.arr_u8.ptr();
    const float   * const __restrict WTI   = s_wt_int.arr_f32.ptr();
    const uint8_t * const __restrict WTIN  = s_wt_init.arr_u8.ptr();
    float         * const __restrict BM    = s_base_m.arr_f32.ptrw();
    const float   *SOIL_COMP = nullptr;
    float         *VGP_COMP = nullptr;
    if (use_soa) {
        const Slot &s_soil_comp = _slots[sid_soil];
        Slot &s_vgp_comp = _slots.write[sid_vgp];
        if (s_soil_comp.arr_f32.size() != n_cells || s_vgp_comp.arr_f32.size() != n_cells) {
            diag("[use_soa] soil_moisture/vegetation_growth_pressure slot size != n_cells");
            return -1.0;
        }
        SOIL_COMP = s_soil_comp.arr_f32.ptr();
        VGP_COMP = s_vgp_comp.arr_f32.ptrw();
    }

    auto t_total_0 = std::chrono::high_resolution_clock::now();
    bool flush_temp = false;     // albedo 跑了才需要 flush
    bool flush_base_m = false;   // feedback 跑了才需要 flush
    double albedo_ms = 0.0;
    double veg_dyn_ms = 0.0;
    double feedback_ms = 0.0;

    // ════════════════════════════════════════════════════════════════════
    // ① ALBEDO 段（1:1 复制 run_albedo_pass 主循环）
    // ════════════════════════════════════════════════════════════════════
    if (run_albedo) {
        if (!knobs.has("reference_albedo") || !knobs.has("albedo_temp_gain") ||
            !knobs.has("albedo_table")) {
            diag("[albedo] knobs missing required keys (reference_albedo / albedo_temp_gain / albedo_table)");
            return -1.0;
        }
        const float reference_albedo  = float(knobs["reference_albedo"]);
        const float albedo_temp_gain  = float(knobs["albedo_temp_gain"]);
        const float snow_cover_albedo = float(knobs.get("snow_cover_albedo", 0.75f));
        const uint8_t cover_snow_id    = uint8_t(int(knobs.get("cover_snow_id", 1)));
        const uint8_t cover_glacier_id = uint8_t(int(knobs.get("cover_glacier_id", 2)));

        PackedFloat32Array albedo_arr = knobs["albedo_table"];
        const int albedo_size = albedo_arr.size();
        if (albedo_size <= 0) { diag("[albedo] albedo_table empty"); return -1.0; }
        const float * const __restrict ALB = albedo_arr.ptr();

        auto t0 = std::chrono::high_resolution_clock::now();

        // ─── Main loop ──────────────────────────────────────────────────
        // S3：与 run_albedo_pass 一同下沉到共享纯 kernel。这里原先是第三份逐字副本
        // （run_albedo_pass / run_albedo_pass_thread / 本段），任何一份改动漏同步都
        // 会表现成"温度场在某些天分叉"。
        pk_async_climate::ClimateAlbedoKnobs alb_knobs;
        alb_knobs.ran = true;
        alb_knobs.reference_albedo = reference_albedo;
        alb_knobs.temp_gain = albedo_temp_gain;
        alb_knobs.snow_cover_albedo = snow_cover_albedo;
        alb_knobs.cover_snow_id = cover_snow_id;
        alb_knobs.cover_glacier_id = cover_glacier_id;
        pk_async_climate::albedo_apply_pure(alb_knobs, IW, VG, CV, ALB,
                                            albedo_size, T, n_cells);
        _production_albedo = alb_knobs;
        _production_stage_mask |= pk_async_climate::CLIMATE_STAGE_BIT_ALBEDO;

        auto t1 = std::chrono::high_resolution_clock::now();
        albedo_ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
        flush_temp = true;
    }

    // ════════════════════════════════════════════════════════════════════
    // ② VEGETATION_DYNAMICS 段（1:1 复制 run_vegetation_dynamics_pass 主循环）
    //    注意：读最新 T[]（如果 albedo 段刚写过，这里直接读到——共享 SoA）
    // ════════════════════════════════════════════════════════════════════
    PackedInt32Array out_indices_vd;     // 留到末尾写回 knobs
    PackedByteArray  out_to_veg_vd;
    int n_succ_vd = 0;
    if (run_veg_dyn) {
        // 标量
        static const char *required_scalars[] = {
            "day_scale", "streak_days",
            "vitality_change_rate", "compat_harshness",
            "plant_water_balance_weight", "plant_soil_buffer_weight",
            "plant_drought_penalty", "succession_min_compat_gain",
            "low_threshold", "high_threshold",
            "succession_degrade_days", "succession_upgrade_days",
            "n_wt", "wt_clear_id", "veg_none_id",
        };
        for (const char *k : required_scalars) {
            if (!knobs.has(k)) { diag("[veg_dyn] knobs missing required scalar key"); return -1.0; }
        }
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
        const bool  vegetation_stress_enabled = vegetation_stress_enabled_stage_b;
        const float vegetation_stress_memory_days = std::max(1.0f, float(knobs.get("vegetation_stress_memory_days", 30.0f)));
        const float vegetation_stress_blend = std::clamp(scale / vegetation_stress_memory_days, 0.0f, 1.0f);
        const int   wt_blizzard_id = int(knobs.get("wt_blizzard_id", 3));
        const int   wt_drought_id  = int(knobs.get("wt_drought_id", 4));
        const int   wt_heatwave_id = int(knobs.get("wt_heatwave_id", 6));
        if (n_wt <= 0) { diag("[veg_dyn] n_wt <= 0"); return -1.0; }

        // 表
        static const char *required_tables[] = {
            "ideal_temp_table", "ideal_moist_table",
            "temp_tol_table", "moist_tol_table",
            "weather_penalty_table", "resistance_table",
            "next_up_table", "next_down_table",
        };
        for (const char *k : required_tables) {
            if (!knobs.has(k)) { diag("[veg_dyn] knobs missing required table key"); return -1.0; }
        }
        // 老路径（use_soa=false）：vit/streak 通过 knobs 传入 PackedArray
        // 新路径（use_soa=true）： vit/streak 直接走 _slots[sid_*].arr_*
        if (!use_soa) {
            if (!knobs.has("vitality_arr") || !knobs.has("low_streak_arr") || !knobs.has("high_streak_arr")) {
                diag("[veg_dyn] knobs missing vitality_arr/low_streak_arr/high_streak_arr (use_soa=false path)");
                return -1.0;
            }
        }
        PackedFloat32Array ideal_t_arr   = knobs["ideal_temp_table"];
        PackedFloat32Array ideal_m_arr   = knobs["ideal_moist_table"];
        PackedFloat32Array tol_t_arr     = knobs["temp_tol_table"];
        PackedFloat32Array tol_m_arr     = knobs["moist_tol_table"];
        PackedFloat32Array wt_pen_arr    = knobs["weather_penalty_table"];
        PackedFloat32Array resist_arr    = knobs["resistance_table"];
        PackedByteArray    next_up_arr   = knobs["next_up_table"];
        PackedByteArray    next_down_arr = knobs["next_down_table"];

        // VIT / LSK / HSK ptrw —— 二选一来源
        float   *VIT = nullptr;
        int32_t *LSK = nullptr;
        int32_t *HSK = nullptr;
        float   *VHEAT = nullptr;
        float   *VDROUGHT = nullptr;
        float   *VCOLD = nullptr;
        float   *VREGEN = nullptr;
        // 持有引用确保 ptrw 生命周期跨越整个 loop（老路径用 knobs 入口的 PackedArray，
        // 新路径用 _slots 内部的 PackedArray —— 后者由 _slots 持有）
        PackedFloat32Array vitality_arr;  // 老路径用
        PackedInt32Array   low_streak;    // 老路径用
        PackedInt32Array   high_streak;   // 老路径用
        if (use_soa) {
            Slot &s_vit  = _slots.write[sid_vit];
            Slot &s_lsk  = _slots.write[sid_low_streak];
            Slot &s_hsk  = _slots.write[sid_high_streak];
            if (s_vit.arr_f32.size() != n_cells ||
                s_lsk.arr_i32.size() != n_cells ||
                s_hsk.arr_i32.size() != n_cells) {
                diag("[veg_dyn] use_soa: vit/streak slot size != n_cells (bind_map_data missing?)");
                return -1.0;
            }
            VIT = s_vit.arr_f32.ptrw();
            LSK = s_lsk.arr_i32.ptrw();
            HSK = s_hsk.arr_i32.ptrw();
            if (vegetation_stress_enabled) {
                Slot &s_v_heat    = _slots.write[sid_v_heat];
                Slot &s_v_drought = _slots.write[sid_v_drought];
                Slot &s_v_cold    = _slots.write[sid_v_cold];
                Slot &s_v_regen   = _slots.write[sid_v_regen];
                if (s_v_heat.arr_f32.size() != n_cells ||
                    s_v_drought.arr_f32.size() != n_cells ||
                    s_v_cold.arr_f32.size() != n_cells ||
                    s_v_regen.arr_f32.size() != n_cells) {
                    diag("[veg_dyn] use_soa: vegetation stress slot size != n_cells");
                    return -1.0;
                }
                VHEAT = s_v_heat.arr_f32.ptrw();
                VDROUGHT = s_v_drought.arr_f32.ptrw();
                VCOLD = s_v_cold.arr_f32.ptrw();
                VREGEN = s_v_regen.arr_f32.ptrw();
            }
        } else {
            if (vegetation_stress_enabled) {
                diag("[veg_dyn] vegetation_stress_enabled requires use_soa=true");
                return -1.0;
            }
            vitality_arr = knobs["vitality_arr"];
            low_streak   = knobs["low_streak_arr"];
            high_streak  = knobs["high_streak_arr"];
            if (vitality_arr.size() != n_cells || low_streak.size() != n_cells ||
                high_streak.size() != n_cells) {
                diag("[veg_dyn] vitality/streak in/out array size mismatch");
                return -1.0;
            }
            VIT = vitality_arr.ptrw();
            LSK = low_streak.ptrw();
            HSK = high_streak.ptrw();
        }

        const int n_veg = ideal_t_arr.size();
        if (n_veg <= 0) { diag("[veg_dyn] ideal_temp_table empty"); return -1.0; }
        if (ideal_m_arr.size() != n_veg || tol_t_arr.size() != n_veg ||
            tol_m_arr.size() != n_veg || next_up_arr.size() != n_veg ||
            next_down_arr.size() != n_veg) {
            diag("[veg_dyn] VEG-indexed table size mismatch");
            return -1.0;
        }
        if (wt_pen_arr.size() < n_wt) { diag("[veg_dyn] weather_penalty_table size < n_wt"); return -1.0; }
        if (resist_arr.size() != n_veg * n_wt) {
            diag("[veg_dyn] resistance_table size != n_veg * n_wt");
            return -1.0;
        }

        const float   * const __restrict IDT  = ideal_t_arr.ptr();
        const float   * const __restrict IDM  = ideal_m_arr.ptr();
        const float   * const __restrict TLT  = tol_t_arr.ptr();
        const float   * const __restrict TLM  = tol_m_arr.ptr();
        const float   * const __restrict WPN  = wt_pen_arr.ptr();
        const float   * const __restrict RES  = resist_arr.ptr();
        const uint8_t * const __restrict NXU  = next_up_arr.ptr();
        const uint8_t * const __restrict NXD  = next_down_arr.ptr();

        auto t0 = std::chrono::high_resolution_clock::now();

        // S3：如实上报"生产这一天跑了 stage 9 VEGETATION_DYNAMICS"。native_daily
        // 路径真正跑的是这一份（stage_b ② 段），不是 run_vegetation_dynamics_pass。
        _production_stage_mask |= pk_async_climate::CLIMATE_STAGE_BIT_VEGETATION_DYNAMICS;

        pk_async_climate::VegetationDynamicsEmit vd_emit;
        vd_emit.indices.reserve(64);
        vd_emit.to_veg.reserve(64);
        std::vector<int32_t> &succ_indices = vd_emit.indices;
        std::vector<uint8_t> &succ_to_veg  = vd_emit.to_veg;

        // ─── Main loop ─────────────────────────────────────
        // S3：下沉到共享纯内核。native_daily 生产热路径跑的就是这一处，
        // 所以 record_production_vegetation_input 也必须在这里取读当日真实输入：
        // weather_type / weather_intensity 已经被本 tick 的 weather pass 整场重写过，
        // environment 快照那份是 tick 起始拍的，用它等于拿昨天的天气算今天的植被。
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
        vd_knobs.stress_enabled = vegetation_stress_enabled;
        vd_knobs.stress_blend = vegetation_stress_blend;
        vd_knobs.wt_blizzard_id = wt_blizzard_id;
        vd_knobs.wt_drought_id = wt_drought_id;
        vd_knobs.wt_heatwave_id = wt_heatwave_id;
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
        vd_lanes.soil_moisture         = SOIL_COMP;
        vd_lanes.weather_type          = WTT;
        vd_lanes.weather_intensity     = WTI;
        vd_lanes.weather_field_init    = WTIN;
        vd_lanes.plant_available_water = PLANT_WATER;
        vd_lanes.vegetation_growth_pressure = VGP_COMP;
        vd_lanes.vitality              = VIT;
        vd_lanes.low_streak            = LSK;
        vd_lanes.high_streak           = HSK;
        vd_lanes.heat_stress           = VHEAT;
        vd_lanes.drought_stress        = VDROUGHT;
        vd_lanes.cold_stress           = VCOLD;
        vd_lanes.regen_score           = VREGEN;

        record_production_vegetation_input(vd_knobs, vd_tables, vd_lanes, n_cells);
        pk_async_climate::vegetation_dynamics_apply_pure(
            vd_knobs, vd_tables, vd_lanes, 0, n_cells, vd_emit);

        // 演替输出 → out_*_vd（最后统一写回 knobs）
        n_succ_vd = int(succ_indices.size());
        out_indices_vd.resize(n_succ_vd);
        out_to_veg_vd.resize(n_succ_vd);
        if (n_succ_vd > 0) {
            std::memcpy(out_indices_vd.ptrw(), succ_indices.data(), n_succ_vd * sizeof(int32_t));
            std::memcpy(out_to_veg_vd.ptrw(),  succ_to_veg.data(),  n_succ_vd * sizeof(uint8_t));
        }

        // 写回 in/out arrays —— 仅老路径（use_soa=false）需要把 vit/streak
        // PackedArray 重新塞回 knobs 让 GDScript caller unpack。新路径下
        // _slots 已经被 ptrw 直接修改，末尾 _flush_slot_to_map 会 ref-swap
        // 推回 MapData，GDScript 不需要 unpack。
        if (!use_soa) {
            knobs["vitality_arr"]    = vitality_arr;
            knobs["low_streak_arr"]  = low_streak;
            knobs["high_streak_arr"] = high_streak;
        }

        auto t1 = std::chrono::high_resolution_clock::now();
        veg_dyn_ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
    }
    // 即使 run_veg_dyn=false，也写空的演替结果保证 caller 端 unpack 安全
    knobs["succession_indices"]    = out_indices_vd;
    knobs["succession_to_veg"]     = out_to_veg_vd;
    knobs["stat_succession_count"] = n_succ_vd;
    if (n_succ_vd > 0) {
        const int64_t tick = int64_t(knobs.get("tick", int64_t(knobs.get("day_idx", 0))));
        const int32_t phase = int32_t(knobs.get("event_phase", 0));
        _emit_succession_events(out_indices_vd, out_to_veg_vd, VG, s_veg.arr_u8.size(), tick, phase, 1);
    }

    // ════════════════════════════════════════════════════════════════════
    // ③ FEEDBACK 段（1:1 复制 run_climate_feedback_pass 主循环）
    // ════════════════════════════════════════════════════════════════════
    if (run_feedback) {
        static const char *required_scalars[] = {
            "soil_gain", "veg_gain", "scale", "per_day_clamp",
            "ocean_drift_gain",
            "wt_rain_id", "wt_storm_id", "wt_monsoon_id",
            "wt_blizzard_id", "wt_drought_id", "wt_heatwave_id",
        };
        for (const char *k : required_scalars) {
            if (!knobs.has(k)) { diag("[feedback] knobs missing required scalar key"); return -1.0; }
        }
        const float soil_gain        = float(knobs["soil_gain"]);
        const float veg_gain         = float(knobs["veg_gain"]);
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
        const bool  write_weather_veg_pressure = bool(knobs.get("write_weather_veg_pressure", true));

        if (!knobs.has("neighbor_indices")) {
            diag("[feedback] knobs missing neighbor_indices");
            return -1.0;
        }
        // 老路径（use_soa=false）：tta/soil/vg 通过 knobs 传入 PackedArray
        // 新路径（use_soa=true）： 直接走 _slots[sid_*].arr_f32
        if (!use_soa) {
            if (!knobs.has("temp_transport_anomaly") ||
                !knobs.has("soil_moisture_arr") || !knobs.has("veg_growth_pressure_arr")) {
                diag("[feedback] knobs missing required PackedArray key (use_soa=false path)");
                return -1.0;
            }
        }
        PackedInt32Array   nb_arr   = knobs["neighbor_indices"];
        if (nb_arr.size() < n_cells * 6) { diag("[feedback] neighbor_indices size < n_cells * 6"); return -1.0; }
        const int32_t * const __restrict NB    = nb_arr.ptr();

        // tta（read）/ soil（read+write）/ vg（read+write）—— 二选一来源
        const float *TTA  = nullptr;
        float       *SOIL = nullptr;
        float       *VGP  = nullptr;
        // 老路径下持有 PackedArray 引用确保 ptrw 生命周期
        PackedFloat32Array tta_arr;
        PackedFloat32Array soil_arr;
        PackedFloat32Array vg_arr;
        if (use_soa) {
            Slot &s_tta  = _slots.write[sid_tta];
            Slot &s_soil = _slots.write[sid_soil];
            Slot &s_vgp  = _slots.write[sid_vgp];
            if (s_tta.arr_f32.size()  != n_cells ||
                s_soil.arr_f32.size() != n_cells ||
                s_vgp.arr_f32.size()  != n_cells) {
                diag("[feedback] use_soa: tta/soil/vg slot size != n_cells (bind_map_data missing?)");
                return -1.0;
            }
            TTA  = s_tta.arr_f32.ptr();
            SOIL = s_soil.arr_f32.ptrw();
            VGP  = s_vgp.arr_f32.ptrw();
        } else {
            tta_arr  = knobs["temp_transport_anomaly"];
            soil_arr = knobs["soil_moisture_arr"];
            vg_arr   = knobs["veg_growth_pressure_arr"];
            if (tta_arr.size() != n_cells)   { diag("[feedback] temp_transport_anomaly size mismatch"); return -1.0; }
            if (soil_arr.size() != n_cells)  { diag("[feedback] soil_moisture_arr size mismatch"); return -1.0; }
            if (vg_arr.size() != n_cells)    { diag("[feedback] veg_growth_pressure_arr size mismatch"); return -1.0; }
            TTA  = tta_arr.ptr();
            SOIL = soil_arr.ptrw();
            VGP  = vg_arr.ptrw();
        }

        auto t0 = std::chrono::high_resolution_clock::now();

        // ─── Main loop ────────────────────────────────
        // S3：与 run_climate_feedback_pass 一同下沉到共享纯 kernel。这里原先是第三份
        // 逐字副本，而它才是生产 native_daily 路径上真正跑的那一份。
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
        record_production_feedback_input(fb_knobs, n_cells, IW, WTT, WTI, WTIN,
                                        TTA, BM, SOIL);
        pk_async_climate::climate_feedback_apply_pure(
            fb_knobs, IW, WTT, WTI, WTIN, NB, TTA, BM, SOIL, VGP, 0, n_cells);

        // 写回 in/out arrays —— 仅老路径需要把 soil/vg 重新塞回 knobs；
        // 新路径下 _slots 已被 ptrw 直接修改，末尾 _flush_slot_to_map 推回。
        if (!use_soa) {
            knobs["soil_moisture_arr"]       = soil_arr;
            knobs["veg_growth_pressure_arr"] = vg_arr;
        }

        auto t1 = std::chrono::high_resolution_clock::now();
        feedback_ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
        flush_base_m = true;
    }

    // ════════════════════════════════════════════════════════════════════
    // 末尾批量 flush（仅推 SoA 写出过的 slot；Variant 引用交换 O(1)）
    // ════════════════════════════════════════════════════════════════════
    if (flush_temp)   _flush_slot_to_map(sid_temp);
    if (flush_base_m) _flush_slot_to_map(sid_base_m);
    // B3b：use_soa 路径下，veg_dyn 段写过 vit/low/high，feedback 段写过 soil/vg。
    // 这些 slot 的 arr_f32 / arr_i32 已经被 ptrw 直接修改，需要 _flush_slot_to_map
    // 把 _slots[].arr_* 推回 MapData.<map_field>（CoW 引用交换 O(1)）。
    // 老路径下这些 slot 没人写，flush 无害，但为了代码简洁仅在 use_soa=true 时 flush。
    if (use_soa) {
        if (run_veg_dyn) {
            _flush_slot_to_map(sid_vit);
            _flush_slot_to_map(sid_low_streak);
            _flush_slot_to_map(sid_high_streak);
            _flush_slot_to_map(sid_vgp);
            _flush_slot_to_map(sid_plant_water);
            if (vegetation_stress_enabled_stage_b) {
                _flush_slot_to_map(sid_v_heat);
                _flush_slot_to_map(sid_v_drought);
                _flush_slot_to_map(sid_v_cold);
                _flush_slot_to_map(sid_v_regen);
            }
        }
        if (run_feedback) {
            _flush_slot_to_map(sid_soil);
            _flush_slot_to_map(sid_vgp);
        }
    }

    // 计时回填
    knobs["albedo_ms"]   = albedo_ms;
    knobs["veg_dyn_ms"]  = veg_dyn_ms;
    knobs["feedback_ms"] = feedback_ms;

    auto t_total_1 = std::chrono::high_resolution_clock::now();
    return std::chrono::duration<double, std::milli>(t_total_1 - t_total_0).count();
}

// ───────────────────────────────────────────────────────────────────────────
// EXPERIMENTAL: D-async — long-lived worker thread + double buffering
// ───────────────────────────────────────────────────────────────────────────
//
// IMPORTANT THREAD-SAFETY CONTRACT:
//   * Worker threads run in the anonymous namespace below and only touch
//     std::vector<float> / atomics / std::mutex / std::condition_variable.
//   * They MUST NOT call any Godot API. The kernel `_demo_complex_kernel_pure`
//     is a verbatim port of `run_demo_complex_pass` algorithm with all
//     PackedFloat32Array / push_warning / etc. replaced by std::vector and
//     silent clamps.
//   * Errors are reported via atomic int `error_code`; the main thread
//     translates them to push_warning inside async_climate_poll().

namespace {

// Error codes set by the worker (read by main thread in poll).
// 0 = ok. Values must be stable — main thread translates them by switch.
constexpr int PK_ASYNC_ERR_OK              = 0;
constexpr int PK_ASYNC_ERR_INVALID_GRID    = 1;
constexpr int PK_ASYNC_ERR_INPUT_SIZE      = 2;

struct AsyncTask {
    int task_id = 0;
    std::thread worker;

    // Inputs (main thread writes under mtx; worker copies to private buffers).
    std::vector<float> in_temp;
    std::vector<float> in_elev;

    // Worker-private buffers (only touched on the worker thread).
    std::vector<float> w_in_temp;
    std::vector<float> w_in_elev;
    std::vector<double> w_buf_a;
    std::vector<double> w_buf_b;
    std::vector<float>  w_out;

    // Result buffer that main thread will memcpy out of in poll().
    std::vector<float> result_buf;

    // Pending request parameters (main writes under mtx; worker reads under mtx).
    int   r_grid_w = 0, r_grid_h = 0;
    int   r_iterations = 16, r_kernel_radius = 2;
    float r_coriolis = 0.5f, r_drag = 0.6f, r_gain = 1.5f, r_k = 0.5f;

    std::mutex mtx;
    std::condition_variable cv;
    std::atomic<bool> request_pending{false};
    std::atomic<bool> result_ready{false};
    std::atomic<bool> should_exit{false};

    // Stats.
    std::atomic<int64_t> last_worker_compute_us{0};
    std::atomic<int64_t> last_worker_total_us{0};
    std::atomic<int64_t> total_ticks{0};
    std::atomic<int64_t> total_reused{0};
    std::atomic<int>     error_code{PK_ASYNC_ERR_OK};
};

struct AsyncState {
    std::unordered_map<int, std::unique_ptr<AsyncTask>> tasks;
    std::mutex tasks_mtx;
};

// ── Pure-C++ kernel — algorithm verbatim from run_demo_complex_pass ────────
// Inputs and outputs are std::vector<float>. Returns false on invalid inputs.
// Knob clamps mirror the synchronous path silently (no push_warning here —
// worker thread cannot call Godot API).
static bool _demo_complex_kernel_pure(int grid_w, int grid_h,
                                      int iterations, int kernel_radius,
                                      float coriolis_strength,
                                      float terrain_drag,
                                      float elevation_gain,
                                      float normalize_k,
                                      const std::vector<float> &T_in_v,
                                      const std::vector<float> &E_v,
                                      std::vector<double> &buf_a,
                                      std::vector<double> &buf_b,
                                      std::vector<float>  &out_v) {
    if (grid_w <= 0 || grid_h <= 0) return false;
    const int n = grid_w * grid_h;
    if ((int)T_in_v.size() != n || (int)E_v.size() != n) return false;

    if (iterations < 1) iterations = 1;
    if (iterations > 64) iterations = 64;
    if (kernel_radius < 1) kernel_radius = 1;
    if (kernel_radius > 5) kernel_radius = 5;
    if (coriolis_strength < -1.0f) coriolis_strength = -1.0f;
    if (coriolis_strength >  1.0f) coriolis_strength =  1.0f;
    if (terrain_drag < 0.0f) terrain_drag = 0.0f;
    if (terrain_drag > 1.0f) terrain_drag = 1.0f;

    if ((int)buf_a.size() != n) buf_a.assign(n, 0.0);
    if ((int)buf_b.size() != n) buf_b.assign(n, 0.0);
    if ((int)out_v.size() != n) out_v.assign(n, 0.0f);

    const float *__restrict T_in = T_in_v.data();
    const float *__restrict E    = E_v.data();

    const int kr   = kernel_radius;
    const int ksz  = 2 * kr + 1;
    double kernel[121];
    double kernel_sum = 0.0;
    for (int dy = -kr; dy <= kr; ++dy) {
        for (int dx = -kr; dx <= kr; ++dx) {
            const double w = std::exp(-(double)(dx*dx + dy*dy) * 0.5);
            kernel[(dy+kr)*ksz + (dx+kr)] = w;
            kernel_sum += w;
        }
    }
    const double kernel_inv_sum = (kernel_sum > 0.0) ? (1.0 / kernel_sum) : 0.0;

    for (int i = 0; i < n; ++i) buf_a[i] = (double)T_in[i];

    const double step_size = 0.05;
    const double cor  = (double)coriolis_strength;
    const double drag = (double)terrain_drag;

    for (int it = 0; it < iterations; ++it) {
        const std::vector<double> &src = (it & 1) ? buf_b : buf_a;
        std::vector<double>       &dst = (it & 1) ? buf_a : buf_b;
        const double *__restrict S = src.data();
        double       *__restrict D = dst.data();

        for (int y = 0; y < grid_h; ++y) {
            const double cor_sign = (y < grid_h / 2) ? -1.0 : 1.0;
            const double rot_rad  = cor * cor_sign * 1.5707963267948966;

            for (int x = 0; x < grid_w; ++x) {
                const int i = y * grid_w + x;

                double accum = 0.0;
                for (int dy = -kr; dy <= kr; ++dy) {
                    int ny = y + dy;
                    if (ny < 0)         ny = 0;
                    else if (ny >= grid_h) ny = grid_h - 1;
                    const int row = ny * grid_w;
                    const double *kw_row = &kernel[(dy + kr) * ksz];
                    for (int dx = -kr; dx <= kr; ++dx) {
                        int nx = x + dx;
                        if (nx < 0)         nx = 0;
                        else if (nx >= grid_w) nx = grid_w - 1;
                        accum += S[row + nx] * kw_row[dx + kr];
                    }
                }
                const double smooth = accum * kernel_inv_sum;

                const int xw = (x > 0)            ? (x - 1) : x;
                const int xe = (x < grid_w - 1)   ? (x + 1) : x;
                const int yn = (y > 0)            ? (y - 1) : y;
                const int ys = (y < grid_h - 1)   ? (y + 1) : y;
                const int row_n = yn * grid_w;
                const int row_c = y  * grid_w;
                const int row_s = ys * grid_w;
                const double gx = (S[row_n + xe] + 2.0*S[row_c + xe] + S[row_s + xe]
                                  - S[row_n + xw] - 2.0*S[row_c + xw] - S[row_s + xw]) * 0.125;
                const double gy = (S[row_s + xw] + 2.0*S[row_s + x ] + S[row_s + xe]
                                  - S[row_n + xw] - 2.0*S[row_n + x ] - S[row_n + xe]) * 0.125;

                const double cs = std::cos(rot_rad);
                const double sn = std::sin(rot_rad);
                const double gx_p = gx * cs - gy * sn;
                const double gy_p = gx * sn + gy * cs;

                const double damp = 1.0 - drag * (double)E[i];
                const double flux = gx_p + gy_p;
                D[i] = smooth + flux * damp * step_size;
            }
        }
    }

    const std::vector<double> &last = (iterations & 1) ? buf_b : buf_a;

    double out_min =  std::numeric_limits<double>::infinity();
    double out_max = -std::numeric_limits<double>::infinity();
    for (int i = 0; i < n; ++i) {
        const double v = last[i];
        if (v < out_min) out_min = v;
        if (v > out_max) out_max = v;
    }
    const double denom = (out_max - out_min) > 1.0e-6
                       ? (out_max - out_min) : 1.0e-6;
    const double inv_denom = 1.0 / denom;

    const double gain = (double)elevation_gain;
    const double k    = (double)normalize_k;
    for (int i = 0; i < n; ++i) {
        const double norm = (last[i] - out_min) * inv_denom;
        const double amp  = 1.0 + gain * (double)E[i];
        double v = norm * amp * k;
        if (v < 0.0) v = 0.0;
        else if (v > 1.0) v = 1.0;
        out_v[i] = (float)v;
    }
    return true;
}

// ── Worker thread main loop ────────────────────────────────────────────────
static void _async_worker_main(AsyncTask *t) {
    using clock = std::chrono::steady_clock;

    while (true) {
        // Snapshot params under the lock, then release it during compute.
        int   grid_w, grid_h, iters, kr;
        float coriolis, drag, gain, k;
        {
            std::unique_lock<std::mutex> lk(t->mtx);
            t->cv.wait(lk, [t]{
                return t->request_pending.load(std::memory_order_acquire)
                    || t->should_exit.load(std::memory_order_acquire);
            });
            if (t->should_exit.load(std::memory_order_acquire)) return;

            // Copy inputs into worker-private buffers (cheap; ~9.6 KB at 60×40).
            t->w_in_temp = t->in_temp;
            t->w_in_elev = t->in_elev;
            grid_w = t->r_grid_w;
            grid_h = t->r_grid_h;
            iters  = t->r_iterations;
            kr     = t->r_kernel_radius;
            coriolis = t->r_coriolis;
            drag     = t->r_drag;
            gain     = t->r_gain;
            k        = t->r_k;
        }

        const auto t0 = clock::now();
        const auto t_compute_start = clock::now();

        const bool ok = _demo_complex_kernel_pure(
            grid_w, grid_h, iters, kr,
            coriolis, drag, gain, k,
            t->w_in_temp, t->w_in_elev,
            t->w_buf_a, t->w_buf_b, t->w_out);

        const auto t_compute_end = clock::now();

        if (!ok) {
            // Set error code; do not modify result_buf (keep last good result).
            t->error_code.store(PK_ASYNC_ERR_INPUT_SIZE,
                                std::memory_order_release);
        } else {
            // Publish: copy w_out → result_buf under lock (so main-thread poll
            // never sees a partially-written buffer).
            std::lock_guard<std::mutex> lk(t->mtx);
            t->result_buf.resize(t->w_out.size());
            std::memcpy(t->result_buf.data(), t->w_out.data(),
                        t->w_out.size() * sizeof(float));
            t->error_code.store(PK_ASYNC_ERR_OK, std::memory_order_release);
        }

        const auto t1 = clock::now();
        t->last_worker_compute_us.store(
            (int64_t)std::chrono::duration_cast<std::chrono::microseconds>(
                t_compute_end - t_compute_start).count(),
            std::memory_order_relaxed);
        t->last_worker_total_us.store(
            (int64_t)std::chrono::duration_cast<std::chrono::microseconds>(
                t1 - t0).count(),
            std::memory_order_relaxed);
        t->total_ticks.fetch_add(1, std::memory_order_relaxed);

        t->request_pending.store(false, std::memory_order_release);
        t->result_ready.store(true, std::memory_order_release);
    }
}

inline AsyncState *_get_or_create_async_state(void *&slot) {
    if (!slot) slot = new AsyncState();
    return reinterpret_cast<AsyncState*>(slot);
}

inline AsyncState *_get_async_state(void *slot) {
    return reinterpret_cast<AsyncState*>(slot);
}

} // namespace (anonymous)

// ── Public API ────────────────────────────────────────────────────────────

void DCWorldExt::async_climate_register_task(int task_id, int n_workers) {
    (void)n_workers; // currently always 1 — multi-worker per task left for future
    AsyncState *st = _get_or_create_async_state(_async_state);
    std::lock_guard<std::mutex> g(st->tasks_mtx);
    auto it = st->tasks.find(task_id);
    if (it != st->tasks.end()) {
        UtilityFunctions::push_warning(
            "[DCWorldExt][async] task ", task_id,
            " already registered; ignoring duplicate register");
        return;
    }
    auto t = std::make_unique<AsyncTask>();
    t->task_id = task_id;
    AsyncTask *raw = t.get();
    st->tasks.emplace(task_id, std::move(t));
    raw->worker = std::thread(&_async_worker_main, raw);
}

void DCWorldExt::async_climate_set_inputs(int task_id,
                                          const PackedFloat32Array &temp,
                                          const PackedFloat32Array &elev) {
    AsyncState *st = _get_async_state(_async_state);
    if (!st) {
        UtilityFunctions::push_warning("[DCWorldExt][async] set_inputs: no async state");
        return;
    }
    AsyncTask *t = nullptr;
    {
        std::lock_guard<std::mutex> g(st->tasks_mtx);
        auto it = st->tasks.find(task_id);
        if (it == st->tasks.end()) {
            UtilityFunctions::push_warning(
                "[DCWorldExt][async] set_inputs: task ", task_id, " not registered");
            return;
        }
        t = it->second.get();
    }
    const int n_t = temp.size();
    const int n_e = elev.size();
    std::lock_guard<std::mutex> lk(t->mtx);
    t->in_temp.resize(n_t);
    if (n_t > 0) std::memcpy(t->in_temp.data(), temp.ptr(), n_t * sizeof(float));
    t->in_elev.resize(n_e);
    if (n_e > 0) std::memcpy(t->in_elev.data(), elev.ptr(), n_e * sizeof(float));
}

void DCWorldExt::async_climate_request(int task_id,
                                       int grid_w, int grid_h,
                                       int iterations, int kernel_radius,
                                       float coriolis_strength,
                                       float terrain_drag,
                                       float elevation_gain,
                                       float normalize_k) {
    AsyncState *st = _get_async_state(_async_state);
    if (!st) {
        UtilityFunctions::push_warning("[DCWorldExt][async] request: no async state");
        return;
    }
    AsyncTask *t = nullptr;
    {
        std::lock_guard<std::mutex> g(st->tasks_mtx);
        auto it = st->tasks.find(task_id);
        if (it == st->tasks.end()) {
            UtilityFunctions::push_warning(
                "[DCWorldExt][async] request: task ", task_id, " not registered");
            return;
        }
        t = it->second.get();
    }
    {
        std::lock_guard<std::mutex> lk(t->mtx);
        // If a previous request is still in flight or unread, count this main
        // thread tick as a "reuse" frame (worker not keeping up). The main
        // thread will keep using the last-published result until poll picks it.
        if (t->request_pending.load(std::memory_order_acquire)) {
            t->total_reused.fetch_add(1, std::memory_order_relaxed);
            return;
        }
        t->r_grid_w = grid_w;
        t->r_grid_h = grid_h;
        t->r_iterations = iterations;
        t->r_kernel_radius = kernel_radius;
        t->r_coriolis = coriolis_strength;
        t->r_drag = terrain_drag;
        t->r_gain = elevation_gain;
        t->r_k    = normalize_k;
        t->request_pending.store(true, std::memory_order_release);
    }
    t->cv.notify_one();
}

bool DCWorldExt::async_climate_poll(int task_id) {
    AsyncState *st = _get_async_state(_async_state);
    if (!st) return false;
    AsyncTask *t = nullptr;
    {
        std::lock_guard<std::mutex> g(st->tasks_mtx);
        auto it = st->tasks.find(task_id);
        if (it == st->tasks.end()) return false;
        t = it->second.get();
    }
    if (!t->result_ready.load(std::memory_order_acquire)) return false;

    // Translate any pending error from the worker into a single push_warning
    // (called on the main thread → safe to call Godot API).
    const int ec = t->error_code.exchange(PK_ASYNC_ERR_OK, std::memory_order_acq_rel);
    if (ec != PK_ASYNC_ERR_OK) {
        UtilityFunctions::push_warning(
            "[DCWorldExt][async] worker error code=", ec, " (task ", task_id, ")");
        // Do NOT consume result_ready on error; main thread sees stale result.
        return false;
    }

    // Snapshot result_buf under lock; copy into _slots[CELL_DEMO_THERMAL_GRADIENT].
    std::vector<float> snapshot;
    {
        std::lock_guard<std::mutex> lk(t->mtx);
        snapshot = t->result_buf;
    }
    t->result_ready.store(false, std::memory_order_release);

    const int sid_out = component_id(StringName("cell_demo_thermal_gradient"));
    if (sid_out < 0) return true; // no output slot — client just got the timing info
    Slot &s_out = _slots.write[sid_out];
    if (s_out.dtype != SlotDType::F32) return true;
    const int n_slot = s_out.arr_f32.size();
    const int n_snap = (int)snapshot.size();
    if (n_slot != n_snap || n_slot <= 0) return true;
    float *p = s_out.arr_f32.ptrw();
    std::memcpy(p, snapshot.data(), n_slot * sizeof(float));
    return true;
}

Dictionary DCWorldExt::async_climate_stats(int task_id) {
    Dictionary d;
    AsyncState *st = _get_async_state(_async_state);
    if (!st) {
        d["registered"] = false;
        return d;
    }
    AsyncTask *t = nullptr;
    {
        std::lock_guard<std::mutex> g(st->tasks_mtx);
        auto it = st->tasks.find(task_id);
        if (it == st->tasks.end()) {
            d["registered"] = false;
            return d;
        }
        t = it->second.get();
    }
    d["registered"] = true;
    d["worker_compute_us"] = (int64_t)t->last_worker_compute_us.load(std::memory_order_relaxed);
    d["worker_total_us"]   = (int64_t)t->last_worker_total_us.load(std::memory_order_relaxed);
    d["total_ticks"]       = (int64_t)t->total_ticks.load(std::memory_order_relaxed);
    d["total_reused"]      = (int64_t)t->total_reused.load(std::memory_order_relaxed);
    d["request_pending"]   = t->request_pending.load(std::memory_order_acquire);
    d["result_ready"]      = t->result_ready.load(std::memory_order_acquire);
    return d;
}

void DCWorldExt::async_climate_shutdown_task(int task_id) {
    AsyncState *st = _get_async_state(_async_state);
    if (!st) return;
    std::unique_ptr<AsyncTask> owned;
    {
        std::lock_guard<std::mutex> g(st->tasks_mtx);
        auto it = st->tasks.find(task_id);
        if (it == st->tasks.end()) return;
        owned = std::move(it->second);
        st->tasks.erase(it);
    }
    // Signal the worker to exit then join. cv.notify_one BEFORE join.
    owned->should_exit.store(true, std::memory_order_release);
    owned->cv.notify_all();
    if (owned->worker.joinable()) owned->worker.join();
}

void DCWorldExt::async_climate_shutdown_all() {
    AsyncState *st = _get_async_state(_async_state);
    if (!st) return;
    // Move out all tasks under lock so the destructors run unlocked.
    std::vector<std::unique_ptr<AsyncTask>> dead;
    {
        std::lock_guard<std::mutex> g(st->tasks_mtx);
        dead.reserve(st->tasks.size());
        for (auto &kv : st->tasks) dead.push_back(std::move(kv.second));
        st->tasks.clear();
    }
    for (auto &t : dead) {
        t->should_exit.store(true, std::memory_order_release);
        t->cv.notify_all();
    }
    for (auto &t : dead) {
        if (t->worker.joinable()) t->worker.join();
    }
    delete st;
    _async_state = nullptr;
}

// ───────────────────────────────────────────────────────────────────────────
// Async Climate Round（plan §async-stage-1，2026-06-14）
// ───────────────────────────────────────────────────────────────────────────
//
// 整 round 异步：worker thread 跑完整 8 pass round，主线程 kick + poll。
// 设计要点见 world_ext.h 中 async_climate_round_register 上方的契约说明。
//
// Stage 1 范围：
//   - 框架完整：input/output/work buf + worker thread + cv 唤醒 + 序列化
//   - transp 实现 pure std::vector kernel（移植自 run_transpiration_pass，
//     算法逐行 1:1，但不调任何 Godot API，不写 _slots，只读写 std::vector）
//   - 7 个其它 pass 留 stub（input → output 直传，不修改）。后续 Stage 2
//     逐个移植到 pure kernel
//   - 主线程 poll 时把 output 写回 _slots，调 _flush_slot_to_map 推到
//     MapData，复用现有 dirty_world.mark_dirty_all() 信号
//
// 单元测试 / A-B 验证策略：见 docs/cpp-dots-runtime/computation-pipelines.md
// 中 transpiration 段落新增的 "async parity" 描述（Stage 1 写文档时补）。

namespace pk_async_climate {
// ClimateRoundScalars / ClimateInputBuf / ClimateOutputBuf / ClimateWorkBuf /
// ClimateRoundStaticKnobs 与 9 个 _async_*_kernel_pure 已在 S3 搬到
// runtime_climate_passes.h/.cpp（Godot 无依赖，生产与 SHADOW worker 共用）。
// 本文件保留 AsyncClimateRoundTask / AsyncClimateRoundState 与 worker 线程驱动，
// 它们属于主线程侧的 async round 生命周期，不属于共享算法层。

// Round async task。本设计只支持单 round 任务（不需要 task_id 多路），
// 全局只有一个实例，由 _async_climate_round_state 持有。
struct AsyncClimateRoundTask {
    std::thread worker;
    std::mutex  mtx;
    std::condition_variable cv;
    std::atomic<bool> request_pending{false};
    std::atomic<bool> result_ready{false};
    std::atomic<bool> should_exit{false};

    // 主线程写 in_buf，worker copy 到 w_in_buf。kick 时整体 vector assignment
    // 拷贝，约 220 KB（Stage 1 只用了 transp 三个 field 共 ~12 KB）。
    ClimateInputBuf in_buf;
    ClimateInputBuf w_in_buf;
    ClimateWorkBuf  w_work_buf;
    ClimateOutputBuf w_out_buf;
    ClimateOutputBuf result_buf;

    // round-invariant：bind 后填一次，所有 round 共享。worker 直接 read-only
    // 引用，不需要拷贝（worker 跑期间主线程不会改它）。
    ClimateRoundStaticKnobs static_knobs;

    // Stats
    std::atomic<int64_t> last_worker_total_us{0};
    std::atomic<int64_t> last_worker_compute_us{0};
    std::atomic<int64_t> total_rounds{0};
    std::atomic<int64_t> total_reused{0};      // request 被 pending block 的次数
    std::atomic<int>     error_code{PK_ASYNC_ROUND_ERR_OK};

    // 上次 round 的 per-pass 耗时（worker 写，主线程在 stats 里读）。
    // Stage 1 只填 transp_us，其它留 0。
    std::atomic<int64_t> last_pass_a_us{0};
    std::atomic<int64_t> last_pass_b_us{0};
    std::atomic<int64_t> last_ocean_water_us{0};
    std::atomic<int64_t> last_ocean_land_us{0};
    std::atomic<int64_t> last_wind_air_us{0};
    std::atomic<int64_t> last_wind_surface_us{0};
    std::atomic<int64_t> last_sea_ice_us{0};
    std::atomic<int64_t> last_transp_us{0};
    // Stage 9（2026-06-16）finalizer pass timing
    std::atomic<int64_t> last_finalizer_us{0};
};

struct AsyncClimateRoundState {
    std::unique_ptr<AsyncClimateRoundTask> task;
    std::mutex state_mtx;  // 保护 task 创建/销毁
    bool lifecycle_round_active = false;
    bool lifecycle_async_kicked = false;
    int lifecycle_pass_cursor = 0;
    int64_t lifecycle_round_id = 0;
    int64_t lifecycle_tick_index = -1;
    int64_t lifecycle_poll_attempts = 0;
    double lifecycle_phase_locked = 0.0;
    std::string lifecycle_stage = "idle";
    std::string lifecycle_owner = "native_probe_lifecycle";
    std::vector<std::string> lifecycle_start_state_intents;
    std::vector<std::string> lifecycle_boundary_intents;
    std::vector<std::string> lifecycle_finish_boundary_intents;
    std::vector<std::string> lifecycle_finalize_tail_boundary_intents;
};

// ─── 7 个 stub kernel（Stage 2 替换为 pure kernel） ─────────────────────────
// 当前行为：直接把 input 拷贝到 output（如果 output 字段存在），不修改 climate
// 状态。GDScript 端在 cp.use_climate_round_async=true 时，仍然走原 sync sub-pass
// 路径跑这 7 个 pass，async 路径只接管 transpiration（验证框架可行性）。

// 未来 Stage 2 各 pass 移植成 pure kernel 时，把对应 stub 替换即可。每个 pass
// 应接受 (in, knobs, work, out) 参数，返回 bool。

// ─── Worker thread main loop ─────────────────────────────────────────────
//
// 与 demo async 模式严格对齐：cv.wait → snapshot inputs under lock → 释放锁
// 跑算法 → 锁住 publish → mark result_ready。should_exit 时直接 return。

static void _async_climate_round_worker_main(AsyncClimateRoundTask *t) {
    using clock = std::chrono::steady_clock;
    while (true) {
        // Snapshot inputs under lock, then release for compute.
        {
            std::unique_lock<std::mutex> lk(t->mtx);
            t->cv.wait(lk, [t]{
                return t->request_pending.load(std::memory_order_acquire)
                    || t->should_exit.load(std::memory_order_acquire);
            });
            if (t->should_exit.load(std::memory_order_acquire)) return;
            // Vector assignment（~12 KB Stage 1，~220 KB Stage 2）
            t->w_in_buf = t->in_buf;
        }

        const auto t0 = clock::now();
        const auto compute_t0 = clock::now();

        // Stage 2：根据 passes_mask 选择性跑 pass_a + transp pure kernel。
        // 其它 6 pass 仍是 stub（即使 mask 启用也不修改 output）。
        // 主线程 poll 时把 output 字段写回 _slots + flush 到 MapData。
        // Stage 3 stub 全部实装后，passes_mask 默认 0xFF 即整 round async。
        // S3：9-pass 编排已搬到共享 TU（runtime_climate_passes.cpp），runtime
        // worker 调的是同一份。这里只负责把逐 pass 耗时搬回 atomic 供 poll 读。
        pk_async_climate::ClimateRoundPassTiming timing;
        const bool ok = pk_async_climate::run_climate_round_passes(
            t->w_in_buf, t->static_knobs, t->w_work_buf, t->w_out_buf, &timing);
        t->last_pass_a_us.store(timing.pass_us[0], std::memory_order_relaxed);
        t->last_pass_b_us.store(timing.pass_us[1], std::memory_order_relaxed);
        t->last_ocean_water_us.store(timing.pass_us[2], std::memory_order_relaxed);
        t->last_ocean_land_us.store(timing.pass_us[3], std::memory_order_relaxed);
        t->last_wind_air_us.store(timing.pass_us[4], std::memory_order_relaxed);
        t->last_wind_surface_us.store(timing.pass_us[5], std::memory_order_relaxed);
        t->last_sea_ice_us.store(timing.pass_us[6], std::memory_order_relaxed);
        t->last_transp_us.store(timing.pass_us[7], std::memory_order_relaxed);
        t->last_finalizer_us.store(timing.pass_us[8], std::memory_order_relaxed);

        const auto compute_t1 = clock::now();
        t->w_out_buf.n_cells = t->w_in_buf.n_cells;

        if (!ok) {
            // 不 publish output，保留上一次结果
            t->error_code.store(PK_ASYNC_ROUND_ERR_KERNEL_FAILED,
                                std::memory_order_release);
        } else {
            // Publish: vector assignment 把 w_out_buf 拷到 result_buf 让主线程读。
            std::lock_guard<std::mutex> lk(t->mtx);
            t->result_buf = t->w_out_buf;
            t->error_code.store(PK_ASYNC_ROUND_ERR_OK, std::memory_order_release);
        }

        const auto t1 = clock::now();
        t->last_worker_compute_us.store(
            (int64_t)std::chrono::duration_cast<std::chrono::microseconds>(
                compute_t1 - compute_t0).count(),
            std::memory_order_relaxed);
        t->last_worker_total_us.store(
            (int64_t)std::chrono::duration_cast<std::chrono::microseconds>(
                t1 - t0).count(),
            std::memory_order_relaxed);
        t->total_rounds.fetch_add(1, std::memory_order_relaxed);

        t->request_pending.store(false, std::memory_order_release);
        t->result_ready.store(true, std::memory_order_release);
    }
}

// 帮助函数：从 Godot Dictionary 提取 PackedFloat32Array → std::vector<float>。
// 不存在时填默认值 default_v 长度为 expect_n 的 zero vector。
inline void _read_pf32_to_vec(const godot::Dictionary &dict, const char *key,
                              std::vector<float> &out, int expect_n) {
    using godot::PackedFloat32Array;
    using godot::Variant;
    if (!dict.has(key)) {
        out.assign(expect_n, 0.0f);
        return;
    }
    Variant v = dict[key];
    if (v.get_type() != Variant::PACKED_FLOAT32_ARRAY) {
        out.assign(expect_n, 0.0f);
        return;
    }
    PackedFloat32Array p = v;
    const int n = p.size();
    out.resize(n);
    if (n > 0) std::memcpy(out.data(), p.ptr(), n * sizeof(float));
}

inline void _read_pu8_to_vec(const godot::Dictionary &dict, const char *key,
                             std::vector<uint8_t> &out, int expect_n) {
    using godot::PackedByteArray;
    using godot::Variant;
    if (!dict.has(key)) {
        out.assign(expect_n, 0);
        return;
    }
    Variant v = dict[key];
    if (v.get_type() != Variant::PACKED_BYTE_ARRAY) {
        out.assign(expect_n, 0);
        return;
    }
    PackedByteArray p = v;
    const int n = p.size();
    out.resize(n);
    if (n > 0) std::memcpy(out.data(), p.ptr(), n);
}

inline void _read_pi32_to_vec(const godot::Dictionary &dict, const char *key,
                              std::vector<int32_t> &out) {
    using godot::PackedInt32Array;
    using godot::Variant;
    if (!dict.has(key)) {
        out.clear();
        return;
    }
    Variant v = dict[key];
    if (v.get_type() != Variant::PACKED_INT32_ARRAY) {
        out.clear();
        return;
    }
    PackedInt32Array p = v;
    const int n = p.size();
    out.resize(n);
    if (n > 0) std::memcpy(out.data(), p.ptr(), n * sizeof(int32_t));
}

inline AsyncClimateRoundState *_get_or_create_round_state(void *&slot) {
    if (!slot) slot = new AsyncClimateRoundState();
    return reinterpret_cast<AsyncClimateRoundState*>(slot);
}

inline AsyncClimateRoundState *_get_round_state(void *slot) {
    return reinterpret_cast<AsyncClimateRoundState*>(slot);
}

}  // namespace pk_async_climate

// ─── Public API: async climate round ─────────────────────────────────────

void DCWorldExt::async_climate_round_register() {
    using namespace pk_async_climate;
    AsyncClimateRoundState *st = _get_or_create_round_state(_async_climate_round_state);
    std::lock_guard<std::mutex> g(st->state_mtx);
    if (st->task != nullptr) {
        // 幂等：已注册过直接返回，不打 warning（GDScript 可能多次重 bind 调本函数）。
        return;
    }
    st->task = std::make_unique<AsyncClimateRoundTask>();
    AsyncClimateRoundTask *raw = st->task.get();
    raw->worker = std::thread(&_async_climate_round_worker_main, raw);
    UtilityFunctions::print(String("[async_climate_round] worker thread started"));
}

void DCWorldExt::async_climate_round_set_static_knobs(const Dictionary &knobs) {
    using namespace pk_async_climate;
    AsyncClimateRoundState *st = _get_round_state(_async_climate_round_state);
    if (!st || st->task == nullptr) {
        UtilityFunctions::push_warning(
            "[async_climate_round] set_static_knobs called before register; ignoring");
        return;
    }
    AsyncClimateRoundTask *t = st->task.get();
    // worker 跑 round 时不会读 static_knobs（worker 只在 cv.wait 唤醒后跑算法），
    // 但写 static_knobs 应在 worker idle 时（kick 之间）。保守：抓 mtx 防御。
    std::lock_guard<std::mutex> lk(t->mtx);
    t->static_knobs.n_cells = int(knobs.get("n_cells", 0));
    _read_pi32_to_vec(knobs, "neighbor_indices", t->static_knobs.neighbor_indices);
    _read_pf32_to_vec(knobs, "donor_table",    t->static_knobs.donor_table, 0);
    _read_pf32_to_vec(knobs, "foliage_table",  t->static_knobs.foliage_table, 0);
    _read_pf32_to_vec(knobs, "albedo_table",   t->static_knobs.albedo_table, 0);
}

// ─── Dictionary → ClimateInputBuf 提取（生产 kick 与 SHADOW capture 共用）────
//
// S3：原来这段只存在于 async_climate_round_kick 的锁内。SHADOW worker 需要拿到
// **与生产 round 完全相同的输入缓冲**才谈得上对拍——如果 worker 自己另写一套
// snapshot→buf 映射，就等于把断点 1 的"两套实现比结果"从算法层挪到了输入层。
// 所以把提取逻辑收成一个方法：生产 kick 与 capture_runtime_inputs 都调它，
// 输入侧差异被消除，剩下的分叉只可能来自执行顺序与状态所有权。
//
// 调用方负责持锁（kick 在 task mtx 内调用）。radiative modifier 与 insol 年均
// LUT 都在这里就地烘焙，因为它们必须由主线程算（worker 不能触 member 缓存）。
bool DCWorldExt::override_climate_round_input_from_slots(int n_cells,
        pk_async_climate::ClimateInputBuf &buf) {
    if (!_bound || n_cells <= 0) return false;

    // 只覆盖 pass_a 真正读的 slot-backed lane。maritime_factor 不是 slot（由
    // cp_struct 侧携带），radiative modifier 与 insol LUT 由调用方烘焙。
    struct F32Lane { const char *component; std::vector<float> *dst; bool required; };
    struct U8Lane  { const char *component; std::vector<uint8_t> *dst; bool required; };
    const F32Lane f32_lanes[] = {
        {"cell_elevation",          &buf.elevation,         true},
        {"cell_base_moisture",      &buf.base_moisture,     true},
        {"cell_lat_norm",           &buf.lat_norm,          true},
        {"cell_temp_baseline_year", &buf.temp_baseline_year, true},
        {"cell_temp",               &buf.temp,              true},
        {"cell_temp_30d",           &buf.temp_30d,          true},
        {"cell_temp_365d",          &buf.temp_365d,         true},
        {"cell_thermal_energy",     &buf.thermal_energy,    true},
        {"cell_snowpack",           &buf.snowpack,          true},
        {"cell_moisture",           &buf.moisture,          true},
        // 可选水文列：slot 缺失时清空，让内核走"这条 lane 不参与"的分支——与
        // run_climate_pass_a 里 nullptr 指针的语义一致。
        {"cell_weather_vapor",      &buf.weather_vapor,     false},
        {"cell_weather_precip",     &buf.weather_precip,    false},
        {"cell_soil_moisture",      &buf.soil_moisture,     false},
        {"cell_water_balance_30d",  &buf.water_balance_30d, false},
    };
    const U8Lane u8_lanes[] = {
        {"cell_is_water",        &buf.is_water,        true},
        {"cell_terrain",         &buf.terrain,         true},
        {"cell_cover",           &buf.cover,           true},
        {"cell_ema_initialized", &buf.ema_initialized, true},
    };

    // 先整体校验，避免只覆盖一半 lane 留下混合来源的 buffer。
    for (const F32Lane &lane : f32_lanes) {
        const int sid = component_id(StringName(lane.component));
        const bool ok = sid >= 0 && _slots.write[sid].arr_f32.size() == n_cells;
        if (!ok && lane.required) return false;
    }
    for (const U8Lane &lane : u8_lanes) {
        const int sid = component_id(StringName(lane.component));
        const bool ok = sid >= 0 && _slots.write[sid].arr_u8.size() == n_cells;
        if (!ok && lane.required) return false;
    }

    for (const F32Lane &lane : f32_lanes) {
        const int sid = component_id(StringName(lane.component));
        if (sid < 0 || _slots.write[sid].arr_f32.size() != n_cells) {
            lane.dst->clear();
            continue;
        }
        lane.dst->resize(size_t(n_cells));
        std::memcpy(lane.dst->data(), _slots.write[sid].arr_f32.ptr(),
                    size_t(n_cells) * sizeof(float));
    }
    for (const U8Lane &lane : u8_lanes) {
        const int sid = component_id(StringName(lane.component));
        if (sid < 0 || _slots.write[sid].arr_u8.size() != n_cells) {
            lane.dst->clear();
            continue;
        }
        lane.dst->resize(size_t(n_cells));
        std::memcpy(lane.dst->data(), _slots.write[sid].arr_u8.ptr(), size_t(n_cells));
    }

    // ─── pass_b..sea_ice 读的 slot-backed lane ────────────────────────────
    //
    // 这些 lane 此前只从 GDScript 的 round-input Dictionary 取，而那份 Dictionary
    // 走的是 MapData 镜像。风场是纯 slot 产物（physics 只写 DCWorldExt slot，从不
    // 回灌 MapData），于是 worker 拿到的 wind_x/wind_y/wind_speed 是长度对、内容
    // 全零的数组 —— 长度对所以 pass 守卫全过、不报 starve，但 wind_air 每个 cell
    // 都在 wind_len2 < 1e-6 处 continue，wind_surface 的平流权重全被跳过，weather
    // solve 也拿不到风。分叉矩阵里 temperature 的 2266 格、vapor 的全图偏移、
    // precipitation 归零，都是这一条。
    //
    // 与上面两组的区别：slot 不可用时**保留** Dictionary 给的内容而不是清空。
    // 清空会把当前唯一的来源也一并抹掉，比拿到零值更糟。
    struct OverlayF32 { const char *component; std::vector<float> *dst; };
    struct OverlayU8  { const char *component; std::vector<uint8_t> *dst; };
    const OverlayF32 overlay_f32[] = {
        // wind_air / wind_surface / weather solve
        {"cell_wind_x",                        &buf.wind_x},
        {"cell_wind_y",                        &buf.wind_y},
        {"cell_wind_speed",                    &buf.wind_speed},
        // 邻居方向几何（pass_b / ocean_* / wind_* 都用）
        {"cell_pos_x",                         &buf.pos_x},
        {"cell_pos_y",                         &buf.pos_y},
        // pass_b
        {"cell_insolation_dev",                &buf.insolation_dev},
        {"cell_temperature_transport_anomaly", &buf.temp_transport_anomaly},
        // wind_surface 的合成 baseline 与 air anomaly 快照
        {"cell_temp_baseline",                 &buf.temp_baseline},
        {"cell_air_mass_temp_anomaly",         &buf.air_mass_temp_anomaly},
        // ocean_water / ocean_land
        {"cell_ocean_current_x",               &buf.ocean_current_x},
        {"cell_ocean_current_y",               &buf.ocean_current_y},
        {"cell_ocean_thermal_anomaly",         &buf.ocean_thermal_anomaly},
        // sea_ice
        {"cell_upwelling_strength",            &buf.upwelling_strength},
        {"cell_insolation_now",                &buf.insolation_now},
        {"cell_sea_ice_frac",                  &buf.sea_ice_frac_inout},
    };
    const OverlayU8 overlay_u8[] = {
        {"cell_landform",     &buf.landform},
        {"cell_vegetation",   &buf.vegetation},
        {"cell_base_terrain", &buf.base_terrain},
    };
    for (const OverlayF32 &lane : overlay_f32) {
        const int sid = component_id(StringName(lane.component));
        if (sid < 0 || _slots.write[sid].arr_f32.size() != n_cells) continue;
        lane.dst->resize(size_t(n_cells));
        std::memcpy(lane.dst->data(), _slots.write[sid].arr_f32.ptr(),
                    size_t(n_cells) * sizeof(float));
    }
    for (const OverlayU8 &lane : overlay_u8) {
        const int sid = component_id(StringName(lane.component));
        if (sid < 0 || _slots.write[sid].arr_u8.size() != n_cells) continue;
        lane.dst->resize(size_t(n_cells));
        std::memcpy(lane.dst->data(), _slots.write[sid].arr_u8.ptr(), size_t(n_cells));
    }
    return true;
}

void DCWorldExt::record_production_feedback_input(
        const pk_async_climate::ClimateFeedbackKnobs &knobs, int n_cells,
        const uint8_t *is_water, const uint8_t *weather_type,
        const float *weather_intensity, const uint8_t *weather_field_init,
        const float *temp_transport_anomaly, const float *base_moisture,
        const float *soil_moisture) {
    if (n_cells <= 0 || is_water == nullptr || weather_type == nullptr ||
        weather_intensity == nullptr || weather_field_init == nullptr ||
        temp_transport_anomaly == nullptr || base_moisture == nullptr ||
        soil_moisture == nullptr) {
        return;
    }
    auto rec = std::make_shared<pk_async_climate::ClimateFeedbackInput>();
    rec->knobs = knobs;
    rec->n_cells = n_cells;
    const size_t n = size_t(n_cells);
    const auto copy_f32 = [n](std::vector<float> &dst, const float *src) {
        dst.resize(n);
        std::memcpy(dst.data(), src, n * sizeof(float));
    };
    const auto copy_u8 = [n](std::vector<uint8_t> &dst, const uint8_t *src) {
        dst.resize(n);
        std::memcpy(dst.data(), src, n);
    };
    copy_u8(rec->is_water, is_water);
    copy_u8(rec->weather_type, weather_type);
    copy_f32(rec->weather_intensity, weather_intensity);
    copy_u8(rec->weather_field_init, weather_field_init);
    copy_f32(rec->temp_transport_anomaly, temp_transport_anomaly);
    // base_moisture / soil_moisture 是 in/out：这里必须在 kernel 跑之前调用，记的是
    // 生产读到的初值。调用点就在 apply 之前一行。
    copy_f32(rec->base_moisture, base_moisture);
    copy_f32(rec->soil_moisture, soil_moisture);
    _production_feedback = std::move(rec);
    _production_stage_mask |= pk_async_climate::CLIMATE_STAGE_BIT_CLIMATE_FEEDBACK;
}

void DCWorldExt::record_production_vegetation_input(
        const pk_async_climate::VegetationDynamicsKnobs &knobs,
        const pk_async_climate::VegetationDynamicsTables &tables,
        const pk_async_climate::VegetationDynamicsLanes &lanes,
        int n_cells) {
    if (n_cells <= 0 || knobs.n_veg <= 0 || knobs.n_wt <= 0) return;
    if (tables.ideal_temp == nullptr || tables.ideal_moist == nullptr ||
        tables.temp_tol == nullptr || tables.moist_tol == nullptr ||
        tables.weather_penalty == nullptr || tables.resistance == nullptr ||
        tables.next_up == nullptr || tables.next_down == nullptr) {
        return;
    }
    if (lanes.is_water == nullptr || lanes.terrain == nullptr ||
        lanes.landform == nullptr || lanes.vegetation == nullptr ||
        lanes.temp_30d == nullptr || lanes.moisture == nullptr ||
        lanes.water_balance_30d == nullptr || lanes.weather_type == nullptr ||
        lanes.weather_intensity == nullptr || lanes.weather_field_init == nullptr) {
        return;
    }
    auto rec = std::make_shared<pk_async_climate::VegetationDynamicsInput>();
    rec->knobs = knobs;
    rec->n_cells = n_cells;
    const size_t n = size_t(n_cells);
    const auto copy_f32 = [](std::vector<float> &dst, const float *src, size_t count) {
        dst.resize(count);
        if (count > 0) std::memcpy(dst.data(), src, count * sizeof(float));
    };
    const auto copy_u8 = [](std::vector<uint8_t> &dst, const uint8_t *src, size_t count) {
        dst.resize(count);
        if (count > 0) std::memcpy(dst.data(), src, count);
    };
    const size_t nv = size_t(knobs.n_veg);
    copy_f32(rec->ideal_temp, tables.ideal_temp, nv);
    copy_f32(rec->ideal_moist, tables.ideal_moist, nv);
    copy_f32(rec->temp_tol, tables.temp_tol, nv);
    copy_f32(rec->moist_tol, tables.moist_tol, nv);
    copy_f32(rec->weather_penalty, tables.weather_penalty, size_t(std::max(knobs.wt_pen_size, 0)));
    copy_f32(rec->resistance, tables.resistance, nv * size_t(knobs.n_wt));
    copy_u8(rec->next_up, tables.next_up, nv);
    copy_u8(rec->next_down, tables.next_down, nv);
    copy_u8(rec->is_water, lanes.is_water, n);
    copy_u8(rec->terrain, lanes.terrain, n);
    copy_u8(rec->landform, lanes.landform, n);
    copy_u8(rec->vegetation, lanes.vegetation, n);
    copy_f32(rec->temp_30d, lanes.temp_30d, n);
    copy_f32(rec->moisture, lanes.moisture, n);
    copy_f32(rec->water_balance_30d, lanes.water_balance_30d, n);
    copy_u8(rec->weather_type, lanes.weather_type, n);
    copy_f32(rec->weather_intensity, lanes.weather_intensity, n);
    copy_u8(rec->weather_field_init, lanes.weather_field_init, n);
    // soil_moisture 与 regen_score 都不是 worker store 的成员：记生产读到的初值，
    // worker 侧用 scratch 承接，输出丢弃（与 feedback 的 soil_moisture 同处理）。
    rec->has_soil_moisture = lanes.soil_moisture != nullptr;
    if (rec->has_soil_moisture) copy_f32(rec->soil_moisture, lanes.soil_moisture, n);
    if (lanes.regen_score != nullptr) copy_f32(rec->regen_score, lanes.regen_score, n);
    rec->has_growth_pressure = lanes.vegetation_growth_pressure != nullptr;
    _production_vegetation = std::move(rec);
    _production_stage_mask |= pk_async_climate::CLIMATE_STAGE_BIT_VEGETATION_DYNAMICS;
}

void DCWorldExt::record_production_weather_input(
        const pk_async_climate::WeatherFieldKnobs &knobs,
        const pk_async_climate::SynopticAdvanceKnobs &synoptic,
        bool synoptic_enabled,
        const pk_async_climate::WeatherFieldLanes &lanes,
        const pk_async_climate::WeatherFieldState &state,
        int n_cells,
        const uint8_t *field_init) {
    if (n_cells <= 0) return;
    // 必需 lane 缺任何一条就不记：半份记录会让 worker 侧的长度校验静默跳过整个
    // stage，而那在分叉矩阵里和"生产这天没跑 weather"长得一样。
    if (lanes.temp_read == nullptr || lanes.moisture_read == nullptr ||
        lanes.air_anomaly == nullptr || lanes.wind_x == nullptr ||
        lanes.wind_y == nullptr || lanes.wind_speed == nullptr ||
        lanes.terrain == nullptr || lanes.has_river == nullptr ||
        lanes.elevation == nullptr || lanes.vegetation == nullptr ||
        lanes.pos_x == nullptr || lanes.pos_y == nullptr ||
        lanes.temp_transport_anomaly == nullptr) {
        return;
    }
    auto rec = std::make_shared<pk_async_climate::WeatherFieldInput>();
    rec->knobs = knobs;
    rec->synoptic = synoptic;
    rec->synoptic_enabled = synoptic_enabled;
    rec->n_cells = n_cells;
    rec->ran = true;
    const size_t n = size_t(n_cells);
    const auto cp_f32 = [n](std::vector<float> &dst, const float *src) {
        if (src == nullptr) { dst.clear(); return; }
        dst.resize(n);
        std::memcpy(dst.data(), src, n * sizeof(float));
    };
    const auto cp_u8 = [n](std::vector<uint8_t> &dst, const uint8_t *src) {
        if (src == nullptr) { dst.clear(); return; }
        dst.resize(n);
        std::memcpy(dst.data(), src, n);
    };
    cp_f32(rec->temp_read, lanes.temp_read);
    cp_f32(rec->moisture_read, lanes.moisture_read);
    cp_f32(rec->air_anomaly, lanes.air_anomaly);
    cp_f32(rec->wind_x, lanes.wind_x);
    cp_f32(rec->wind_y, lanes.wind_y);
    cp_f32(rec->wind_speed, lanes.wind_speed);
    cp_u8(rec->terrain, lanes.terrain);
    cp_u8(rec->has_river, lanes.has_river);
    cp_f32(rec->river_q30, lanes.river_q30);
    cp_f32(rec->elevation, lanes.elevation);
    cp_u8(rec->vegetation, lanes.vegetation);
    cp_f32(rec->soil_moisture, lanes.soil_moisture);
    cp_f32(rec->vitality, lanes.vitality);
    cp_f32(rec->sea_ice, lanes.sea_ice);
    cp_f32(rec->pos_x, lanes.pos_x);
    cp_f32(rec->pos_y, lanes.pos_y);
    cp_f32(rec->temp_anomaly, lanes.temp_anomaly);
    cp_f32(rec->snow_cover, lanes.snow_cover);
    cp_f32(rec->temp_transport_anomaly, lanes.temp_transport_anomaly);

    // 跨 tick 状态：这里记的是生产这一轮【读到的】初值，所以调用点必须在 solve
    // 之前 —— conv_inhib 与 ψ 都是 in/out。
    cp_f32(rec->conv_inhib, state.conv_inhib);
    if (synoptic_enabled) rec->psi = _wx_synoptic;
    if (state.cyclone_tag != nullptr &&
        state.cyclone_tag_count == n_cells) {
        rec->cyclone_tag.resize(n);
        std::memcpy(rec->cyclone_tag.data(), state.cyclone_tag,
                    n * sizeof(uint32_t));
        rec->cyclone_generation = state.cyclone_generation;
        cp_f32(rec->cyclone_lift, state.cyclone_lift);
        cp_f32(rec->cyclone_x, state.cyclone_x);
        cp_f32(rec->cyclone_y, state.cyclone_y);
    }
    if (state.monsoon_thermal != nullptr &&
        state.monsoon_thermal_count == n_cells) {
        cp_f32(rec->monsoon_thermal, state.monsoon_thermal);
    }
    if (state.traj_idx != nullptr && state.traj_w != nullptr) {
        rec->traj_idx.resize(n * 3);
        rec->traj_w.resize(n * 3);
        std::memcpy(rec->traj_idx.data(), state.traj_idx, n * 3 * sizeof(int32_t));
        std::memcpy(rec->traj_w.data(), state.traj_w, n * 3 * sizeof(float));
    }
    if (field_init != nullptr) {
        rec->field_init.resize(n);
        std::memcpy(rec->field_init.data(), field_init, n);
    }
    _production_weather = std::move(rec);
    // stage bit 由 solve pass 自己置位（它在 sliced 路径上可能被多次调用，而记录只
    // 在 start_idx == 0 那次做）。
}

void DCWorldExt::record_production_weather_distribute_input(
        const pk_async_climate::WeatherDistributeKnobs &knobs,
        const pk_async_climate::WeatherDistributeLanes &lanes,
        const pk_async_climate::WeatherDistributeState &state,
        int n_cells) {
    if (n_cells <= 0) return;
    if (lanes.heat == nullptr || lanes.elevation == nullptr ||
        lanes.landform == nullptr || lanes.terrain == nullptr ||
        lanes.weather_intensity == nullptr || lanes.weather_precip == nullptr ||
        lanes.weather_type == nullptr || lanes.weather_field_init == nullptr ||
        lanes.cover == nullptr || lanes.soil_moisture == nullptr ||
        state.accumulated_snow_days == nullptr ||
        state.pre_snow_cover == nullptr) {
        return;
    }
    auto rec = std::make_shared<pk_async_climate::WeatherDistributeInput>();
    rec->knobs = knobs;
    rec->n_cells = n_cells;
    rec->ran = true;
    const size_t n = size_t(n_cells);
    const auto cp_f32 = [n](std::vector<float> &dst, const float *src) {
        dst.resize(n);
        std::memcpy(dst.data(), src, n * sizeof(float));
    };
    const auto cp_u8 = [n](std::vector<uint8_t> &dst, const uint8_t *src) {
        dst.resize(n);
        std::memcpy(dst.data(), src, n);
    };
    const auto cp_i32 = [n](std::vector<int32_t> &dst, const int32_t *src) {
        dst.resize(n);
        std::memcpy(dst.data(), src, n * sizeof(int32_t));
    };
    cp_f32(rec->heat, lanes.heat);
    cp_f32(rec->elevation, lanes.elevation);
    cp_u8(rec->landform, lanes.landform);
    cp_u8(rec->terrain, lanes.terrain);
    cp_f32(rec->weather_intensity, lanes.weather_intensity);
    cp_f32(rec->weather_precip, lanes.weather_precip);
    cp_u8(rec->weather_type, lanes.weather_type);
    cp_u8(rec->weather_field_init, lanes.weather_field_init);
    cp_u8(rec->cover, lanes.cover);
    cp_f32(rec->soil_moisture, lanes.soil_moisture);
    cp_i32(rec->accumulated_snow_days, state.accumulated_snow_days);
    cp_i32(rec->pre_snow_cover, state.pre_snow_cover);
    _production_weather_distribute = std::move(rec);
    // stage bit 由 WEATHER 那一位代表：distribute 与 field solve 同属 stage 11，
    // 分开置位会让分叉矩阵多出一个没有对应字段的 stage。
    _production_stage_mask |= pk_async_climate::CLIMATE_STAGE_BIT_WEATHER;
}

void DCWorldExt::record_production_hydrology_input(
        const pk_async_climate::HydrologyKnobs &knobs,
        const pk_async_climate::HydrologyLanes &lanes,
        bool has_neighbors, uint64_t canal_topology_generation,
        int n_cells) {
    if (n_cells <= 0) return;
    if (lanes.has_river == nullptr || lanes.terrain == nullptr ||
        lanes.landform == nullptr || lanes.vegetation == nullptr ||
        lanes.cover == nullptr || lanes.elevation == nullptr ||
        lanes.precip == nullptr || lanes.intensity == nullptr ||
        lanes.weather_type == nullptr || lanes.temp == nullptr ||
        lanes.heat == nullptr || lanes.snowpack == nullptr ||
        lanes.base_moisture == nullptr || lanes.is_water == nullptr ||
        lanes.vitality == nullptr || lanes.canal_mask == nullptr ||
        lanes.soil_moisture == nullptr || lanes.discharge_30d == nullptr) {
        return;
    }
    auto rec = std::make_shared<pk_async_climate::HydrologyInput>();
    rec->knobs = knobs;
    rec->n_cells = n_cells;
    rec->ran = true;
    rec->has_neighbors = has_neighbors;
    rec->canal_topology_generation = canal_topology_generation;
    const size_t n = size_t(n_cells);
    const auto cp_f32 = [n](std::vector<float> &dst, const float *src) {
        dst.resize(n);
        std::memcpy(dst.data(), src, n * sizeof(float));
    };
    const auto cp_u8 = [n](std::vector<uint8_t> &dst, const uint8_t *src) {
        dst.resize(n);
        std::memcpy(dst.data(), src, n);
    };
    cp_u8(rec->has_river, lanes.has_river);
    cp_u8(rec->terrain, lanes.terrain);
    cp_u8(rec->landform, lanes.landform);
    cp_u8(rec->vegetation, lanes.vegetation);
    cp_u8(rec->cover, lanes.cover);
    cp_f32(rec->elevation, lanes.elevation);
    cp_f32(rec->precip, lanes.precip);
    cp_f32(rec->intensity, lanes.intensity);
    cp_u8(rec->weather_type, lanes.weather_type);
    cp_f32(rec->temp, lanes.temp);
    cp_f32(rec->heat, lanes.heat);
    cp_f32(rec->snowpack, lanes.snowpack);
    cp_f32(rec->base_moisture, lanes.base_moisture);
    cp_u8(rec->is_water, lanes.is_water);
    cp_f32(rec->vitality, lanes.vitality);
    cp_u8(rec->canal_mask, lanes.canal_mask);
    cp_f32(rec->soil_moisture, lanes.soil_moisture);
    cp_f32(rec->discharge_30d, lanes.discharge_30d);
    if (lanes.canal_water != nullptr) cp_f32(rec->canal_water, lanes.canal_water);
    // hydro_parent 不在这里记：它只在地图生成/regen 时重建，属于 round static
    // knobs 的范畴，每天再抄一份 int32 全图纯属浪费。
    _production_hydrology = std::move(rec);
}

// 生产 pass_b 用的海冰浓度 lane。三个变体（scalar / simd / thread）都调这里，最后
// 一个覆盖前面的，内容相同所以结果一致。SIF 为空（cp 没配 sea_ice_albedo_cooling
// 或 knobs 没带 sea_ice_frac）时也要如实记一个空的 —— 留着上一天那份会让 worker
// 在生产本来跳过尾循环的那一天照跑。
void DCWorldExt::record_production_pass_b_input(int n_cells, const float *sea_ice_frac,
                                               const float *temp_transport_anomaly) {
    if (n_cells <= 0) return;
    auto in = std::make_shared<pk_async_climate::ClimatePassBInput>();
    in->n_cells = n_cells;
    if (sea_ice_frac != nullptr) {
        in->sea_ice_frac.assign(sea_ice_frac, sea_ice_frac + n_cells);
    }
    if (temp_transport_anomaly != nullptr) {
        in->temp_transport_anomaly.assign(temp_transport_anomaly,
                                          temp_transport_anomaly + n_cells);
    }
    _production_pass_b = std::move(in);
}

// 生产 sea_ice 用的温度 lane。scalar / thread 两个变体都调这里。
void DCWorldExt::record_production_sea_ice_input(
        const pk_async_climate::SeaIceLanes &lanes, int n_cells) {
    if (n_cells <= 0) return;
    auto in = std::make_shared<pk_async_climate::SeaIceInput>();
    in->n_cells = n_cells;
    const auto cp_f32 = [n_cells](std::vector<float> &dst, const float *src) {
        if (src == nullptr) return;
        dst.assign(src, src + n_cells);
    };
    const auto cp_u8 = [n_cells](std::vector<uint8_t> &dst, const uint8_t *src) {
        if (src == nullptr) return;
        dst.assign(src, src + n_cells);
    };
    cp_f32(in->cell_temperature, lanes.cell_temperature);
    cp_f32(in->upwelling_strength, lanes.upwelling_strength);
    cp_f32(in->insolation_now, lanes.insolation_now);
    cp_f32(in->ocean_thermal_anomaly, lanes.ocean_thermal_anomaly);
    cp_f32(in->temp_transport_anomaly, lanes.temp_transport_anomaly);
    cp_u8(in->terrain, lanes.terrain);
    cp_u8(in->base_terrain, lanes.base_terrain);
    cp_f32(in->sea_ice_frac, lanes.sea_ice_frac);
    if (lanes.water_terrain_ids != nullptr && lanes.water_terrain_ids_size > 0) {
        in->water_terrain_ids.assign(
            lanes.water_terrain_ids,
            lanes.water_terrain_ids + lanes.water_terrain_ids_size);
    }
    _production_sea_ice = std::move(in);
}

// 生产 wind_surface 读到的 oanom。空记录会让 worker 退回自己 pass_a 的清零，
// 而不是错吃上一天的值，所以守住 nullptr 而不是记一个空的。
// 生产 ocean_water 用的 baseline / temp_before。两条都不是 slot，只在这个调用点
// 才抽得到真值 —— 见 pk_async_climate::OceanWaterInput 的注释。
void DCWorldExt::record_production_ocean_water_input(int n_cells, const float *baseline,
                                                    const float *temp_before) {
    if (n_cells <= 0) return;
    auto in = std::make_shared<pk_async_climate::OceanWaterInput>();
    in->n_cells = n_cells;
    if (baseline != nullptr) in->baseline.assign(baseline, baseline + n_cells);
    if (temp_before != nullptr) in->temp_before.assign(temp_before, temp_before + n_cells);
    _production_ocean_water = std::move(in);
}

void DCWorldExt::record_production_wind_surface_input(int n_cells, const float *ocean_anomaly) {
    if (n_cells <= 0 || ocean_anomaly == nullptr) return;
    auto in = std::make_shared<pk_async_climate::WindSurfaceInput>();
    in->n_cells = n_cells;
    in->ocean_anomaly.assign(ocean_anomaly, ocean_anomaly + n_cells);
    _production_wind_surface = std::move(in);
}

void DCWorldExt::record_production_pass_a_scalars(
        const pk_async_climate::ClimateRoundScalars &src) {
    _production_round_scalar_mask |= 0x01;
    _production_stage_mask |= pk_async_climate::CLIMATE_STAGE_BIT_PASS_A;
    pk_async_climate::ClimateRoundScalars &s = _production_round_scalars;
    s.season_phase = src.season_phase;
    s.axial_tilt_deg = src.axial_tilt_deg;
    s.day_length_gain = src.day_length_gain;
    s.solar_gain = src.solar_gain;
    s.insol_amp = src.insol_amp;
    s.insol_gain = src.insol_gain;
    s.insol_dev_min = src.insol_dev_min;
    s.insol_dev_max = src.insol_dev_max;
    s.thermal_inertia_land = src.thermal_inertia_land;
    s.thermal_inertia_water = src.thermal_inertia_water;
    s.thermal_inertia_snow = src.thermal_inertia_snow;
    s.thermal_inertia_high_mountain = src.thermal_inertia_high_mountain;
    s.thermal_daily_delta_cap = src.thermal_daily_delta_cap;
    s.thermal_dt_days = src.thermal_dt_days;
    s.runtime_moisture_base_relax_rate = src.runtime_moisture_base_relax_rate;
    s.runtime_moisture_weather_vapor_weight = src.runtime_moisture_weather_vapor_weight;
    s.runtime_moisture_precip_weight = src.runtime_moisture_precip_weight;
    s.runtime_moisture_soil_weight = src.runtime_moisture_soil_weight;
    s.runtime_moisture_soil_dry_weight = src.runtime_moisture_soil_dry_weight;
    s.runtime_moisture_water_balance_weight = src.runtime_moisture_water_balance_weight;
    s.runtime_moisture_water_balance_dry_weight = src.runtime_moisture_water_balance_dry_weight;
    s.snowpack_cover_low = src.snowpack_cover_low;
    s.maritime_season_damp = src.maritime_season_damp;
    s.sea_level = src.sea_level;
    s.days_per_year = src.days_per_year;
}

void DCWorldExt::record_production_round_scalars(int pass_bit,
                                                 const Dictionary &knobs) {
    using namespace pk_async_climate;
    // pass_bit 与 RuntimeClimateStage 的低八位同源（见 CLIMATE_STAGE_BIT_PASS_A 处
    // 的注释）。每个生产 round pass 都会调到这里，所以这一句就是低八位 stage 掩码的
    // 唯一记录点；漏了它，分叉矩阵会把"生产跑了但没记"误报成"生产没跑"。
    _production_stage_mask |= pass_bit;
    ClimateRoundScalars &s = _production_round_scalars;
    // wrap_period_x 的兜底必须是 _native_wrap_period_x（生产各 pass 缺这个键时用
    // 的就是它），而不是结构默认 0。GDScript 的 wind/ocean knobs 里根本不带这个
    // 键，所以按结构默认记等于告诉 worker"域宽是 0"——所有 advect 类 pass 的接缝
    // 折叠因此在两边不一致。
    const auto f = [&knobs](const char *key, float fallback) {
        return knobs.has(key) ? float(knobs[key]) : fallback;
    };
    const auto d = [&knobs](const char *key, double fallback) {
        return knobs.has(key) ? double(knobs[key]) : fallback;
    };
    const auto i32 = [&knobs](const char *key, int fallback) {
        return knobs.has(key) ? int(knobs[key]) : fallback;
    };
    const auto b = [&knobs](const char *key, bool fallback) {
        return knobs.has(key) ? bool(knobs[key]) : fallback;
    };
    switch (pass_bit) {
    case 0x02:  // pass_b
        s.pb_winter_boost = f("winter_boost", s.pb_winter_boost);
        s.pb_snow_cool = f("snow_cool", s.pb_snow_cool);
        s.pb_veg_cool = f("veg_cool", s.pb_veg_cool);
        s.pb_diurnal_amp = f("diurnal_amp", s.pb_diurnal_amp);
        s.pb_evap_gain = f("evap_gain", s.pb_evap_gain);
        s.pb_rs_threshold = f("rs_threshold", s.pb_rs_threshold);
        s.pb_rs_factor = f("rs_factor", s.pb_rs_factor);
        s.pb_rs_lookback = i32("rs_lookback", s.pb_rs_lookback);
        s.pb_t_freeze = f("t_freeze", s.pb_t_freeze);
        s.pb_coupling_gain = f("coupling_gain", s.pb_coupling_gain);
        s.pb_coast_leak = f("coast_leak", s.pb_coast_leak);
        s.pb_sea_ice_albedo_cooling =
            f("sea_ice_albedo_cooling", s.pb_sea_ice_albedo_cooling);
        // snowpack_cover_* 与 wrap_period_x 是 pass_a/pass_b 共用的，pass_b 的 knobs
        // 里带的是生产 pass_b 实际用的那一份，照抄。
        s.snowpack_cover_low = d("snowpack_cover_low", s.snowpack_cover_low);
        s.snowpack_cover_full = d("snowpack_cover_full", s.snowpack_cover_full);
        s.wrap_period_x = f("wrap_period_x", float(_native_wrap_period_x));
        break;
    case 0x04:  // ocean_water
        s.ow_advect_steps = i32("advect_steps", s.ow_advect_steps);
        s.ow_heat_mix = f("heat_mix", s.ow_heat_mix);
        s.ow_tta_source_cap = f("tta_source_cap", s.ow_tta_source_cap);
        s.ow_tta_blend_rate = f("tta_blend_rate", s.ow_tta_blend_rate);
        s.ow_tta_zero_current_decay =
            f("tta_zero_current_decay", s.ow_tta_zero_current_decay);
        s.ow_cold_transport_form =
            f("cold_transport_form_threshold", s.ow_cold_transport_form);
        s.ow_cold_transport_melt =
            f("cold_transport_melt_threshold", s.ow_cold_transport_melt);
        s.wrap_period_x = f("wrap_period_x", float(_native_wrap_period_x));
        break;
    case 0x08:  // ocean_land
        s.ol_effective_leak = f("effective_leak", s.ol_effective_leak);
        s.ol_tta_source_cap = f("tta_source_cap", s.ol_tta_source_cap);
        s.ol_tta_blend_rate = f("tta_blend_rate", s.ol_tta_blend_rate);
        s.ol_tta_decay_rate = f("tta_decay_rate", s.ol_tta_decay_rate);
        s.wrap_period_x = f("wrap_period_x", float(_native_wrap_period_x));
        break;
    case 0x10:  // wind_air（生产入口是 run_wind_air_mass_pass）
        s.wa_advect_steps = i32("advect_steps", s.wa_advect_steps);
        s.wa_heat_mix = f("heat_mix", s.wa_heat_mix);
        s.wrap_period_x = f("wrap_period_x", float(_native_wrap_period_x));
        break;
    case 0x20:  // wind_surface
        s.ws_air_leak = f("air_leak", s.ws_air_leak);
        s.ws_cold_transport_form =
            f("cold_transport_form_threshold", s.ws_cold_transport_form);
        s.ws_cold_transport_melt =
            f("cold_transport_melt_threshold", s.ws_cold_transport_melt);
        s.wrap_period_x = f("wrap_period_x", float(_native_wrap_period_x));
        break;
    case 0x40:  // sea_ice
        s.si_k_freeze = f("k_freeze", s.si_k_freeze);
        s.si_k_melt = f("k_melt", s.si_k_melt);
        s.si_t_form = f("t_form", s.si_t_form);
        s.si_t_melt = f("t_melt", s.si_t_melt);
        s.si_contagion = f("contagion", s.si_contagion);
        s.si_threshold = f("threshold", s.si_threshold);
        s.si_hysteresis = f("hysteresis", s.si_hysteresis);
        s.si_ice_delay = f("ice_delay", s.si_ice_delay);
        s.si_enable_oht = b("enable_ocean_heat_transport", s.si_enable_oht);
        s.si_solar_gate_enabled = b("solar_gate_enabled", s.si_solar_gate_enabled);
        s.si_freeze_insol_low = f("freeze_insol_low", s.si_freeze_insol_low);
        s.si_freeze_insol_high = f("freeze_insol_high", s.si_freeze_insol_high);
        s.si_solar_melt_start = f("solar_melt_start", s.si_solar_melt_start);
        s.si_solar_melt_gain = f("solar_melt_gain", s.si_solar_melt_gain);
        s.si_min_thick_ice_solar_exposure =
            f("min_thick_ice_solar_exposure", s.si_min_thick_ice_solar_exposure);
        s.si_daily_delta_cap = f("daily_delta_cap", s.si_daily_delta_cap);
        s.si_edge_mix_rate = f("edge_mix_rate", s.si_edge_mix_rate);
        s.si_dt_days = f("dt_days", s.si_dt_days);
        s.si_terrain_lake_id = i32("terrain_lake_id", s.si_terrain_lake_id);
        s.si_terrain_sea_ice_id = i32("terrain_sea_ice_id", s.si_terrain_sea_ice_id);
        s.si_terrain_ocean_id = i32("terrain_ocean_id", s.si_terrain_ocean_id);
        break;
    default:
        return;
    }
    _production_round_scalar_mask |= pass_bit;
}

void DCWorldExt::fill_climate_round_input(const Dictionary &input, int n_cells,
                                          pk_async_climate::ClimateInputBuf &buf,
                                          bool prefer_slot_lanes) {
    using namespace pk_async_climate;
    if (n_cells <= 0) {
        buf = ClimateInputBuf{};
        return;
    }
    buf.n_cells = n_cells;

    // Stage 1 字段（transp 读）
    _read_pu8_to_vec(input,  "landform",   buf.landform,   n_cells);
    _read_pu8_to_vec(input,  "vegetation", buf.vegetation, n_cells);
    _read_pf32_to_vec(input, "moisture",   buf.moisture,   n_cells);

    // Stage 2 字段（pass_a 读）。如不提供则填空（0）；worker 内的 pass_a
    // 维度校验会拒绝跑（passes_mask & 0x01 但 is_water.size() != n_cells）。
    _read_pu8_to_vec(input,  "is_water",            buf.is_water,            n_cells);
    _read_pu8_to_vec(input,  "terrain",             buf.terrain,             n_cells);
    _read_pu8_to_vec(input,  "cover",               buf.cover,               n_cells);
    _read_pu8_to_vec(input,  "ema_initialized",     buf.ema_initialized,     n_cells);
    _read_pf32_to_vec(input, "elevation",           buf.elevation,           n_cells);
    _read_pf32_to_vec(input, "base_moisture",       buf.base_moisture,       n_cells);
    _read_pf32_to_vec(input, "weather_vapor",       buf.weather_vapor,       n_cells);
    _read_pf32_to_vec(input, "weather_precip",      buf.weather_precip,      n_cells);
    _read_pf32_to_vec(input, "soil_moisture",       buf.soil_moisture,       n_cells);
    _read_pf32_to_vec(input, "water_balance_30d",   buf.water_balance_30d,   n_cells);
    _read_pf32_to_vec(input, "lat_norm",            buf.lat_norm,            n_cells);
    // [climate-zone-fix P2] 海洋性调温因子（静态 per-cell；缺省空→不调温）
    _read_pf32_to_vec(input, "maritime_factor",     buf.maritime,            n_cells);
    _read_pf32_to_vec(input, "temp_baseline_year",  buf.temp_baseline_year,  n_cells);
    _read_pf32_to_vec(input, "temp",                buf.temp,                n_cells);
    _read_pf32_to_vec(input, "temp_30d",            buf.temp_30d,            n_cells);
    _read_pf32_to_vec(input, "temp_365d",           buf.temp_365d,           n_cells);
    _read_pf32_to_vec(input, "thermal_energy",      buf.thermal_energy,      n_cells);
    _read_pf32_to_vec(input, "snowpack",            buf.snowpack,            n_cells);
    buf.radiative_modifier_add.assign(
        static_cast<size_t>(n_cells), 0.0f);
    buf.radiative_modifier_factor.assign(
        static_cast<size_t>(n_cells), 1.0f);
    if (_modifier_runtime != nullptr) {
        const ModifierRuntime *modifier =
            static_cast<const ModifierRuntime *>(_modifier_runtime);
        for (int cell = 0; cell < n_cells; ++cell) {
            double add = 0.0;
            double factor = 1.0;
            modifier->climate_radiative_terms(cell, add, factor);
            buf.radiative_modifier_add[static_cast<size_t>(cell)] =
                static_cast<float>(add);
            buf.radiative_modifier_factor[static_cast<size_t>(cell)] =
                static_cast<float>(factor);
        }
    }

    // Stage 2 字段（pass_b 读）。snow_cover/moisture 与 pass_a 共享。
    _read_pf32_to_vec(input, "pos_x",                     buf.pos_x,                     n_cells);
    _read_pf32_to_vec(input, "pos_y",                     buf.pos_y,                     n_cells);
    _read_pf32_to_vec(input, "insolation_dev",            buf.insolation_dev,            n_cells);
    _read_pf32_to_vec(input, "temp_transport_anomaly",    buf.temp_transport_anomaly,    n_cells);
    _read_pf32_to_vec(input, "local_thermal_anomaly",     buf.local_thermal_anomaly,     n_cells);
    _read_pf32_to_vec(input, "sea_ice_frac",              buf.sea_ice_frac,              n_cells);

    // Stage 2 字段（ocean_water/ocean_land 读）
    _read_pf32_to_vec(input, "ocean_current_x",           buf.ocean_current_x,           n_cells);
    _read_pf32_to_vec(input, "ocean_current_y",           buf.ocean_current_y,           n_cells);
    _read_pf32_to_vec(input, "ocean_thermal_anomaly",     buf.ocean_thermal_anomaly,     n_cells);

    // Stage 2 字段（wind_air/wind_surface 读）
    _read_pf32_to_vec(input, "wind_x",                    buf.wind_x,                    n_cells);
    _read_pf32_to_vec(input, "wind_y",                    buf.wind_y,                    n_cells);
    _read_pf32_to_vec(input, "wind_speed",                buf.wind_speed,                n_cells);
    _read_pf32_to_vec(input, "temp_baseline",             buf.temp_baseline,             n_cells);
    _read_pf32_to_vec(input, "air_mass_temp_anomaly",     buf.air_mass_temp_anomaly,     n_cells);

    // Stage 2 字段（sea_ice 读）
    _read_pu8_to_vec(input,  "base_terrain",              buf.base_terrain,              n_cells);
    _read_pf32_to_vec(input, "upwelling_strength",        buf.upwelling_strength,        n_cells);
    _read_pf32_to_vec(input, "insolation_now",            buf.insolation_now,            n_cells);
    _read_pf32_to_vec(input, "cell_temperature_arr",      buf.cell_temperature_arr,      n_cells);
    _read_pf32_to_vec(input, "sea_ice_frac_inout",        buf.sea_ice_frac_inout,        n_cells);
    _read_pu8_to_vec(input,  "water_terrain_ids",         buf.water_terrain_ids,         0);

    // Round-level scalars
    buf.scalars.season_phase     = double(input.get("season_phase", 0.0));
    buf.scalars.axial_tilt_deg   = double(input.get("axial_tilt_deg", 23.5));
    buf.scalars.day_length_gain  = double(input.get("day_length_gain", 0.35));
    buf.scalars.solar_gain       = double(input.get("solar_gain", 1.0));
    buf.scalars.insol_amp        = double(input.get("insol_amp", 0.20));
    buf.scalars.insol_gain       = double(input.get("insol_gain", 1.0));
    buf.scalars.moist_scale_now  = double(input.get("moist_scale_now", 1.0));
    buf.scalars.runtime_moisture_base_relax_rate = float(input.get("runtime_moisture_base_relax_rate", 0.24));
    buf.scalars.runtime_moisture_weather_vapor_weight = float(input.get("runtime_moisture_weather_vapor_weight", 0.12));
    buf.scalars.runtime_moisture_precip_weight = float(input.get("runtime_moisture_precip_weight", 0.78));
    buf.scalars.runtime_moisture_soil_weight = float(input.get("runtime_moisture_soil_weight", 1.82));
    buf.scalars.runtime_moisture_soil_dry_weight = float(input.get("runtime_moisture_soil_dry_weight", 2.21));
    buf.scalars.runtime_moisture_water_balance_weight = float(input.get("runtime_moisture_water_balance_weight", 1.04));
    buf.scalars.runtime_moisture_water_balance_dry_weight = float(input.get("runtime_moisture_water_balance_dry_weight", 1.30));
    buf.scalars.days_per_year    = int(input.get("days_per_year", 365));
    buf.scalars.sea_level        = double(input.get("sea_level", 0.5));
    // pass_a 扩展 scalars
    buf.scalars.insol_dev_min               = double(input.get("insol_dev_min", -1.0));
    buf.scalars.insol_dev_max               = double(input.get("insol_dev_max", 1.0));
    buf.scalars.thermal_inertia_land        = double(input.get("thermal_inertia_land", 0.35));
    buf.scalars.thermal_inertia_water       = double(input.get("thermal_inertia_water", 0.045));
    buf.scalars.thermal_inertia_snow        = double(input.get("thermal_inertia_snow", 0.09));
    buf.scalars.thermal_inertia_high_mountain = double(input.get("thermal_inertia_high_mountain", 0.16));
    buf.scalars.thermal_daily_delta_cap     = double(input.get("thermal_daily_delta_cap", 0.15));
    buf.scalars.thermal_dt_days             = double(input.get("thermal_dt_days", 1.0));
    buf.scalars.snowpack_cover_low          = double(input.get("snowpack_cover_low", 0.05));
    buf.scalars.snowpack_cover_full         = double(input.get("snowpack_cover_full", 0.32));
    buf.scalars.maritime_season_damp        = double(input.get("maritime_season_damp", 0.0));
    // transp scalars
    buf.scalars.transp_outflow_rate = float(input.get("transp_outflow_rate", 0.025));
    buf.scalars.transp_self_rate    = float(input.get("transp_self_rate", 0.015));

    // pass_b scalars（Stage 2）
    buf.scalars.pb_winter_boost  = float(input.get("pb_winter_boost", 1.0));
    buf.scalars.pb_snow_cool     = float(input.get("pb_snow_cool", 0.0));
    buf.scalars.pb_veg_cool      = float(input.get("pb_veg_cool", 0.0));
    buf.scalars.pb_diurnal_amp   = float(input.get("pb_diurnal_amp", 0.0));
    buf.scalars.pb_evap_gain     = float(input.get("pb_evap_gain", 0.0));
    buf.scalars.pb_rs_threshold  = float(input.get("pb_rs_threshold", 0.0));
    buf.scalars.pb_rs_factor     = float(input.get("pb_rs_factor", 1.0));
    buf.scalars.pb_rs_lookback   = int(input.get("pb_rs_lookback", 0));
    buf.scalars.pb_t_freeze      = float(input.get("pb_t_freeze", 0.0));
    buf.scalars.pb_coupling_gain = float(input.get("pb_coupling_gain", 0.0));
    buf.scalars.pb_coast_leak    = float(input.get("pb_coast_leak", 0.0));
    buf.scalars.pb_sea_ice_albedo_cooling = float(input.get("pb_sea_ice_albedo_cooling", 0.01));

    // seam-advection-fix：环绕周期。常驻值优先，input 显式给了才覆盖（单测用）。
    buf.scalars.wrap_period_x = float(input.get("wrap_period_x", _native_wrap_period_x));

    // ocean_water / ocean_land scalars（Stage 2）
    buf.scalars.ow_advect_steps  = int(input.get("ow_advect_steps", 3));
    buf.scalars.ow_heat_mix      = float(input.get("ow_heat_mix", 0.55));
    buf.scalars.ow_tta_source_cap = float(input.get("ow_tta_source_cap", 0.22));
    buf.scalars.ow_cold_transport_form =
        float(input.get("ow_cold_transport_form", 0.06));
    buf.scalars.ow_cold_transport_melt =
        float(input.get("ow_cold_transport_melt", 0.11));
    buf.scalars.ow_tta_blend_rate = float(input.get("ow_tta_blend_rate", 0.70));
    buf.scalars.ow_tta_zero_current_decay = float(input.get("ow_tta_zero_current_decay", 0.06));
    buf.scalars.ol_effective_leak = float(input.get("ol_effective_leak", 0.55));
    buf.scalars.ol_tta_source_cap = float(input.get("ol_tta_source_cap", 0.22));
    buf.scalars.ol_tta_blend_rate = float(input.get("ol_tta_blend_rate", 0.70));
    buf.scalars.ol_tta_decay_rate = float(input.get("ol_tta_decay_rate", 0.04));

    // wind_air / wind_surface scalars（Stage 2）
    buf.scalars.wa_advect_steps = int(input.get("wa_advect_steps", 3));
    buf.scalars.wa_heat_mix     = float(input.get("wa_heat_mix", 0.25));
    buf.scalars.ws_air_leak     = float(input.get("ws_air_leak", 0.35));
    buf.scalars.ws_cold_transport_form = float(input.get("ws_cold_transport_form", 0.06));
    buf.scalars.ws_cold_transport_melt = float(input.get("ws_cold_transport_melt", 0.11));

    // sea_ice scalars（Stage 2）
    buf.scalars.si_k_freeze     = float(input.get("si_k_freeze", 0.40));
    buf.scalars.si_k_melt       = float(input.get("si_k_melt", 1.45));
    buf.scalars.si_t_form       = float(input.get("si_t_form", 0.06));
    buf.scalars.si_t_melt       = float(input.get("si_t_melt", 0.11));
    buf.scalars.si_contagion    = float(input.get("si_contagion", 0.035));
    buf.scalars.si_threshold    = float(input.get("si_threshold", 0.68));
    buf.scalars.si_hysteresis   = float(input.get("si_hysteresis", 0.12));
    buf.scalars.si_ice_delay    = float(input.get("si_ice_delay", 1.0));
    buf.scalars.si_enable_oht   = bool(input.get("si_enable_oht", true));
    buf.scalars.si_apply_terrain_flips = bool(input.get("si_apply_terrain_flips", false));
    buf.scalars.si_solar_gate_enabled = bool(input.get("si_solar_gate_enabled", true));
    buf.scalars.si_freeze_insol_low  = float(input.get("si_freeze_insol_low", 0.22));
    buf.scalars.si_freeze_insol_high = float(input.get("si_freeze_insol_high", 0.45));
    buf.scalars.si_solar_melt_start  = float(input.get("si_solar_melt_start", 0.28));
    buf.scalars.si_solar_melt_gain   = float(input.get("si_solar_melt_gain", 1.35));
    buf.scalars.si_min_thick_ice_solar_exposure = float(input.get("si_min_thick_ice_solar_exposure", 0.32));
    buf.scalars.si_daily_delta_cap   = float(input.get("si_daily_delta_cap", 0.070));
    buf.scalars.si_edge_mix_rate     = float(input.get("si_edge_mix_rate", 0.035));
    buf.scalars.si_dt_days           = float(input.get("si_dt_days", 1.0));
    buf.scalars.si_terrain_lake_id    = int(input.get("si_terrain_lake_id", -1));
    buf.scalars.si_terrain_sea_ice_id = int(input.get("si_terrain_sea_ice_id", -1));
    buf.scalars.si_terrain_ocean_id   = int(input.get("si_terrain_ocean_id", -1));

    // ─── finalizer pass fields（Stage 9，2026-06-16） ─────────────────
    // _temp_start_of_day_arr / _tta_start_of_day_arr / sea_ice_frac_prev /
    // weather_precip 由 GDScript 主线程在 begin_round 时打快照传入。
    _read_pf32_to_vec(input, "fin_temp_start_of_day",   buf.temp_start_of_day,   n_cells);
    _read_pf32_to_vec(input, "fin_tta_start_of_day",    buf.tta_start_of_day,    n_cells);
    _read_pf32_to_vec(input, "fin_sea_ice_frac_prev",   buf.sea_ice_frac_prev,   n_cells);
    _read_pf32_to_vec(input, "fin_weather_precip",      buf.weather_precip,      n_cells);
    buf.scalars.fin_temp_cap_enabled = bool(input.get("fin_temp_cap_enabled", true));
    buf.scalars.fin_temp_cap         = float(input.get("fin_temp_cap", 0.15));
    buf.scalars.fin_tta_cap          = float(input.get("fin_tta_cap", 0.12));
    buf.scalars.fin_has_temp_start   = bool(input.get("fin_has_temp_start", false));
    buf.scalars.fin_has_tta_start    = bool(input.get("fin_has_tta_start", false));

    // passes_mask（默认 0x1FF 含 finalizer bit）
    buf.scalars.passes_mask = int(input.get("passes_mask", 0x1FF));

    // ─── S3：把 pass_a 的 per-cell lane 换成 _slots 的内容 ─────────────────
    // 必须在下面烘焙 insol LUT 之前做，因为 LUT 由 buf.lat_norm 导出。
    if (prefer_slot_lanes) {
        override_climate_round_input_from_slots(n_cells, buf);
    }

    // ─── Item 4 (perf 2026-07-05)：主线程预烘焙年均日照 LUT ────────────────
    // pass_a worker 每 cell 需 dc_insolation_annual_mean(clamp01(ny), axial_tilt, daylen)，
    // 该值 season-无关（16×9 trig/cell）。async kernel 跑在 worker thread、无法安全用 member
    // 缓存，故在此（持锁、主线程）按 lat_norm 逐 cell 预算好，worker 直接读 → bit-equal。
    // 仅 pass_a 参与时（passes_mask & 0x01）才烘焙，省无谓开销；否则清空退回 inline。
    if ((buf.scalars.passes_mask & 0x01) != 0 &&
        (int)buf.lat_norm.size() == n_cells) {
        const float ax_tilt = float(buf.scalars.axial_tilt_deg);
        const float dl_amp  = float(buf.scalars.day_length_gain);
        buf.insol_annual_mean.resize(static_cast<size_t>(n_cells));
        for (int i = 0; i < n_cells; ++i) {
            buf.insol_annual_mean[static_cast<size_t>(i)] =
                dc_insolation_annual_mean(dc_clamp01f(buf.lat_norm[static_cast<size_t>(i)]),
                                          ax_tilt, dl_amp);
        }
    } else {
        buf.insol_annual_mean.clear();
    }

    // 输入边界诊断：只留存 SHADOW capture 交给 worker 的那一份。
    if (prefer_slot_lanes) {
        _captured_climate_round_input = buf;
        _captured_climate_round_input_valid = true;
        ++_capture_call_count;
    }
}

bool DCWorldExt::async_climate_round_kick(const Dictionary &input) {
    using namespace pk_async_climate;
    AsyncClimateRoundState *st = _get_round_state(_async_climate_round_state);
    if (!st || st->task == nullptr) {
        UtilityFunctions::push_warning(
            "[async_climate_round] kick called before register; returning false");
        return false;
    }
    AsyncClimateRoundTask *t = st->task.get();

    // worker 还没消费上一次 request → 跳过本次 kick，主线程沿用上次 result_buf。
    // 这是 x20 速度下追不上的自然降频 fallback。
    if (t->request_pending.load(std::memory_order_acquire)) {
        t->total_reused.fetch_add(1, std::memory_order_relaxed);
        return false;
    }

    const int n_cells = int(input.get("n_cells", 0));
    if (n_cells <= 0) {
        UtilityFunctions::push_warning(
            "[async_climate_round] kick: n_cells <= 0, refusing");
        return false;
    }

    // Snapshot inputs into in_buf under lock.
    {
        std::lock_guard<std::mutex> lk(t->mtx);
        fill_climate_round_input(input, n_cells, t->in_buf);

        t->request_pending.store(true, std::memory_order_release);
    }
    t->cv.notify_one();
    return true;
}

Dictionary DCWorldExt::async_climate_round_poll() {
    using namespace pk_async_climate;
    Dictionary out;
    AsyncClimateRoundState *st = _get_round_state(_async_climate_round_state);
    if (!st || st->task == nullptr) {
        return out;
    }
    AsyncClimateRoundTask *t = st->task.get();
    if (!t->result_ready.load(std::memory_order_acquire)) {
        return out;
    }

    // 错误时不消费 result_ready（保留上一次成功结果），主线程仍能继续。
    const int ec = t->error_code.exchange(PK_ASYNC_ROUND_ERR_OK,
                                          std::memory_order_acq_rel);
    if (ec != PK_ASYNC_ROUND_ERR_OK) {
        UtilityFunctions::push_warning(
            "[async_climate_round] worker error code=", ec);
        return out;
    }

    // 把 result_buf 内容 snapshot 出来 + 立刻 flip result_ready，让 worker
    // 准备好下一轮（如果主线程下一帧立刻 kick）。
    ClimateOutputBuf snapshot;
    {
        std::lock_guard<std::mutex> lk(t->mtx);
        snapshot = t->result_buf;
    }
    t->result_ready.store(false, std::memory_order_release);

    // ─── Sync output → _slots[]，同 sync 路径调 _flush_slot_to_map 推到 MapData ───
    // Stage 2：transp 输出 moisture；pass_a 输出 16 字段（与 run_climate_pass_a
    // 末尾 16 个 _flush_slot_to_map 一一对应）。worker 只在 mask 启用且输入完整时
    // 才填充对应 output 字段；poll 端按 size() != n_cells 来判断是否要写。
    const int n = snapshot.n_cells;
    Array published_slots;
    Array visual_dirty_intents;
    auto append_published_slot = [&](const char *slot_name) {
        const String name(slot_name);
        if (!published_slots.has(name)) {
            published_slots.push_back(name);
        }
    };
    if (n > 0) {
        // 通用 helper：把 vector<float> 写回 _slots[slot_name] + flush。
        auto write_f32_slot = [&](const char *slot_name, const std::vector<float> &src) {
            if ((int)src.size() != n) return;
            const int sid = component_id(StringName(slot_name));
            if (sid < 0 || sid >= _slots.size()) return;
            Slot &s = _slots.write[sid];
            if (s.dtype != SlotDType::F32 || s.arr_f32.size() != n) return;
            std::memcpy(s.arr_f32.ptrw(), src.data(), n * sizeof(float));
            _flush_slot_to_map(sid);
            append_published_slot(slot_name);
        };
        auto write_u8_slot = [&](const char *slot_name, const std::vector<uint8_t> &src) {
            if ((int)src.size() != n) return;
            const int sid = component_id(StringName(slot_name));
            if (sid < 0 || sid >= _slots.size()) return;
            Slot &s = _slots.write[sid];
            if (s.dtype != SlotDType::U8 || s.arr_u8.size() != n) return;
            std::memcpy(s.arr_u8.ptrw(), src.data(), n);
            _flush_slot_to_map(sid);
            append_published_slot(slot_name);
        };

        // pass_a 输出（16 字段，sync 路径同样 16 个 _flush_slot_to_map）
        write_f32_slot("cell_moisture",                snapshot.moisture);
        write_f32_slot("cell_temp_baseline",           snapshot.temp_baseline);
        write_f32_slot("cell_temp_season_offset",      snapshot.temp_season_offset);
        write_u8_slot ("cell_ema_initialized",         snapshot.ema_initialized);
        write_f32_slot("cell_temp_30d",                snapshot.temp_30d);
        write_f32_slot("cell_temp_365d",               snapshot.temp_365d);
        write_f32_slot("cell_temp_anomaly",            snapshot.temp_anomaly);
        write_f32_slot("cell_insolation_now",          snapshot.insolation_now);
        write_f32_slot("cell_insolation_dev",          snapshot.insolation_dev);
        write_f32_slot("cell_day_length",              snapshot.day_length);
        write_f32_slot("cell_heat_input",              snapshot.heat_input);
        write_f32_slot("cell_thermal_energy",          snapshot.thermal_energy);
        write_f32_slot("cell_snowpack",                snapshot.snowpack);
        write_f32_slot("cell_ocean_thermal_anomaly",   snapshot.ocean_thermal_anomaly);
        write_f32_slot("cell_local_thermal_anomaly",   snapshot.local_thermal_anomaly);
        // wind pass 输出（Stage 2）
        write_f32_slot("cell_air_mass_temp_anomaly",   snapshot.air_mass_temp_anomaly);
        write_f32_slot("cell_temp",                    snapshot.temp);  // wind_surface 最终温度
        // sea_ice 输出（Stage 2）。terrain 翻转 sync 路径在 apply_terrain_flips=true
        // 时由 C++ ptrw + flush；async 模式下 worker 已把翻转写入 out.terrain。
        write_f32_slot("cell_sea_ice_frac",            snapshot.sea_ice_frac);
        write_u8_slot ("cell_terrain",                 snapshot.terrain);
        // transp 的 moisture 输出（若 transp 跑过会覆盖 pass_a 的 moisture）。
        // write_f32_slot 是幂等的；如果 transp 没跑 moisture 用 pass_a 的值。

        // ─── finalizer 输出（Stage 9，2026-06-16） ────────────────────────
        // finalizer 写 cell_temp / cell_temperature_transport_anomaly / cell_thermal_energy。
        // cell_temp 已经被 wind_surface 写过（snapshot.temp 上面写过了），finalizer
        // 在 kernel 内对 out.temp in-place clamp。再 write_f32_slot 即覆盖之前的非 clamped 值。
        // TTA 是 finalizer 独有 buffer（tta_final）。thermal_energy 在 kernel 里 init NaN/inf 后写出。
        if (snapshot.fin_applied) {
            write_f32_slot("cell_temp",                         snapshot.temp);          // 已 clamp 后版本
            write_f32_slot("cell_temperature_transport_anomaly", snapshot.tta_final);    // 已 clamp
            write_f32_slot("cell_thermal_energy",                snapshot.thermal_energy); // 已 init
        }
    }

    // 返回 round-level metrics + dirty info 供 GDScript 后处理。
    const int64_t worker_compute_us = (int64_t)t->last_worker_compute_us.load(std::memory_order_relaxed);
    const int64_t worker_total_us = (int64_t)t->last_worker_total_us.load(std::memory_order_relaxed);
    const int64_t transp_us = (int64_t)t->last_transp_us.load(std::memory_order_relaxed);
    const int64_t finalizer_us = (int64_t)t->last_finalizer_us.load(std::memory_order_relaxed);
    const int64_t pass_a_us = (int64_t)t->last_pass_a_us.load(std::memory_order_relaxed);
    const int64_t pass_b_us = (int64_t)t->last_pass_b_us.load(std::memory_order_relaxed);
    const int64_t ocean_water_us = (int64_t)t->last_ocean_water_us.load(std::memory_order_relaxed);
    const int64_t ocean_land_us = (int64_t)t->last_ocean_land_us.load(std::memory_order_relaxed);
    const int64_t wind_air_us = (int64_t)t->last_wind_air_us.load(std::memory_order_relaxed);
    const int64_t wind_surface_us = (int64_t)t->last_wind_surface_us.load(std::memory_order_relaxed);
    const int64_t sea_ice_us = (int64_t)t->last_sea_ice_us.load(std::memory_order_relaxed);
    out["n_cells"]            = snapshot.n_cells;
    out["worker_compute_us"]  = worker_compute_us;
    out["worker_total_us"]    = worker_total_us;
    out["transp_us"]          = transp_us;
    out["finalizer_us"]       = finalizer_us;
    out["pass_a_us"]          = pass_a_us;
    out["pass_b_us"]          = pass_b_us;
    out["ocean_water_us"]     = ocean_water_us;
    out["ocean_land_us"]      = ocean_land_us;
    out["wind_air_us"]        = wind_air_us;
    out["wind_surface_us"]    = wind_surface_us;
    out["sea_ice_us"]         = sea_ice_us;
    out["moisture_dirty_count"] = (int64_t)snapshot.moisture_dirty_indices.size();
    out["published_slots"] = published_slots;
    out["published_slot_count"] = (int64_t)published_slots.size();
    out["visual_dirty_intents"] = visual_dirty_intents;
    Dictionary breakdown;
    breakdown["path"] = String("native_climate_round_poll");
    breakdown["pass_a_ms"] = double(pass_a_us) / 1000.0;
    breakdown["pass_b_ms"] = double(pass_b_us) / 1000.0;
    breakdown["ocean_water_ms"] = double(ocean_water_us) / 1000.0;
    breakdown["ocean_land_ms"] = double(ocean_land_us) / 1000.0;
    breakdown["ocean_ms"] = double(ocean_water_us + ocean_land_us) / 1000.0;
    breakdown["wind_air_ms"] = double(wind_air_us) / 1000.0;
    breakdown["wind_surface_ms"] = double(wind_surface_us) / 1000.0;
    breakdown["wind_ms"] = double(wind_air_us + wind_surface_us) / 1000.0;
    breakdown["sea_ice_ms"] = double(sea_ice_us) / 1000.0;
    breakdown["transp_ms"] = double(transp_us) / 1000.0;
    breakdown["finalizer_ms"] = double(finalizer_us) / 1000.0;
    breakdown["worker_compute_ms"] = double(worker_compute_us) / 1000.0;
    breakdown["worker_total_ms"] = double(worker_total_us) / 1000.0;
    breakdown["published_slot_count"] = (int64_t)published_slots.size();
    breakdown["visual_dirty_intent_count"] = (int64_t)visual_dirty_intents.size();
    out["breakdown"] = breakdown;
    // ─── finalizer diag（Stage 9，2026-06-16） ───────────────────────────
    // 一一对应 GDScript _apply_daily_climate_finalizer 返回 diag 的字段名。
    // GDScript 端 _finalize_round 优先用这些 worker 算好的值，跳过 _apply_*_finalizer。
    out["fin_applied"]                  = snapshot.fin_applied;
    out["fin_max_temp_delta"]           = double(snapshot.fin_max_temp_delta);
    out["fin_p95_temp_delta"]           = double(snapshot.fin_p95_temp_delta);
    out["fin_p99_temp_delta"]           = double(snapshot.fin_p99_temp_delta);
    out["fin_preclamp_max_temp_delta"]  = double(snapshot.fin_preclamp_max_temp_delta);
    out["fin_preclamp_p99_temp_delta"]  = double(snapshot.fin_preclamp_p99_temp_delta);
    out["fin_temp_delta_gt_005_count"]  = (int64_t)snapshot.fin_temp_delta_gt_005_count;
    out["fin_temp_delta_gt_010_count"]  = (int64_t)snapshot.fin_temp_delta_gt_010_count;
    out["fin_temp_delta_gt_020_count"]  = (int64_t)snapshot.fin_temp_delta_gt_020_count;
    out["fin_temp_delta_clamped_count"] = (int64_t)snapshot.fin_temp_delta_clamped_count;
    out["fin_max_transport_anomaly"]    = double(snapshot.fin_max_transport_anomaly);
    out["fin_tta_clamped_count"]        = (int64_t)snapshot.fin_tta_clamped_count;
    out["fin_thermal_init_count"]       = (int64_t)snapshot.fin_thermal_init_count;
    out["fin_sea_ice_delta_max"]        = double(snapshot.fin_sea_ice_delta_max);
    out["fin_precip_p95"]               = double(snapshot.fin_precip_p95);
    out["fin_cells_seen"]               = (int64_t)snapshot.fin_cells_seen;
    // sea_ice flip events（Stage 2）：主线程 poll 后可据此做 atlas dirty mark /
    // map.terrain mirror sync。GDScript 端把它当 PackedInt32Array / PackedByteArray
    // 消费即可。
    if (!snapshot.flipped_cell_indices.empty()) {
        PackedInt32Array flipped_idx;
        flipped_idx.resize((int)snapshot.flipped_cell_indices.size());
        std::memcpy(flipped_idx.ptrw(),
                    snapshot.flipped_cell_indices.data(),
                    snapshot.flipped_cell_indices.size() * sizeof(int32_t));
        PackedByteArray flipped_terr;
        flipped_terr.resize((int)snapshot.flipped_new_terrain.size());
        std::memcpy(flipped_terr.ptrw(),
                    snapshot.flipped_new_terrain.data(),
                    snapshot.flipped_new_terrain.size());
        out["flipped_cell_indices"] = flipped_idx;
        out["flipped_new_terrain"]  = flipped_terr;
        Dictionary intent;
        intent["kind"] = String("sea_ice_terrain_flips");
        intent["dirty_cells"] = (int64_t)snapshot.flipped_cell_indices.size();
        intent["source"] = String("native_climate_round_poll");
        visual_dirty_intents.push_back(intent);
        out["visual_dirty_intents"] = visual_dirty_intents;
        breakdown["visual_dirty_intent_count"] = (int64_t)visual_dirty_intents.size();
        out["breakdown"] = breakdown;
    }
    return out;
}

Dictionary DCWorldExt::async_climate_round_stats() {
    using namespace pk_async_climate;
    Dictionary out;
    AsyncClimateRoundState *st = _get_round_state(_async_climate_round_state);
    if (!st || st->task == nullptr) {
        out["registered"] = false;
        return out;
    }
    AsyncClimateRoundTask *t = st->task.get();
    out["registered"]      = true;
    out["total_rounds"]    = (int64_t)t->total_rounds.load(std::memory_order_relaxed);
    out["total_reused"]    = (int64_t)t->total_reused.load(std::memory_order_relaxed);
    out["request_pending"] = t->request_pending.load(std::memory_order_acquire);
    out["result_ready"]    = t->result_ready.load(std::memory_order_acquire);
    out["worker_compute_us"] = (int64_t)t->last_worker_compute_us.load(std::memory_order_relaxed);
    out["worker_total_us"]   = (int64_t)t->last_worker_total_us.load(std::memory_order_relaxed);
    out["transp_us"]         = (int64_t)t->last_transp_us.load(std::memory_order_relaxed);
    return out;
}

Dictionary DCWorldExt::native_climate_round_begin(const Dictionary &static_knobs) {
    Dictionary out;
    async_climate_round_register();
    if (!static_knobs.is_empty()) {
        async_climate_round_set_static_knobs(static_knobs);
    }
    out["rc"] = 0;
    out["path"] = String("native_climate_round_begin");
    out["authority"] = String("probe_native_state");
    out["simulation_authority"] = false;
    out["state"] = get_native_climate_round_state_report();
    return out;
}

Dictionary DCWorldExt::native_climate_round_begin_round(const Dictionary &ctx) {
    using namespace pk_async_climate;
    async_climate_round_register();
    AsyncClimateRoundState *st = _get_or_create_round_state(_async_climate_round_state);
    {
        std::lock_guard<std::mutex> g(st->state_mtx);
        st->lifecycle_round_id += 1;
        st->lifecycle_round_active = true;
        st->lifecycle_async_kicked = false;
        st->lifecycle_pass_cursor = int(ctx.get("pass_cursor", 0));
        st->lifecycle_tick_index = (int64_t)ctx.get("tick_index", (int64_t)-1);
        st->lifecycle_poll_attempts = 0;
        st->lifecycle_phase_locked = double(ctx.get("phase_locked", 0.0));
        st->lifecycle_stage = "round_started";
        st->lifecycle_owner = "native_probe_lifecycle";
        st->lifecycle_start_state_intents.clear();
        st->lifecycle_start_state_intents.push_back("set_round_active");
        st->lifecycle_start_state_intents.push_back("set_phase_locked");
        st->lifecycle_start_state_intents.push_back("set_pass_cursor");
        st->lifecycle_start_state_intents.push_back("reset_async_kicked");
        st->lifecycle_start_state_intents.push_back("reset_poll_attempts");
        st->lifecycle_start_state_intents.push_back("record_tick_index");
        st->lifecycle_boundary_intents.clear();
        st->lifecycle_boundary_intents.push_back("sync_runtime_terrain_views");
        st->lifecycle_boundary_intents.push_back("begin_round_pass_state");
        st->lifecycle_boundary_intents.push_back("soa_begin_climate_transaction");
        st->lifecycle_finish_boundary_intents.clear();
        st->lifecycle_finalize_tail_boundary_intents.clear();
    }
    Dictionary out;
    out["rc"] = 0;
    out["path"] = String("native_climate_round_begin_round");
    out["authority"] = String("probe_native_lifecycle");
    out["simulation_authority"] = false;
    out["boundary_intent_owner"] = String("native_probe_lifecycle");
    Dictionary state = get_native_climate_round_state_report();
    out["state"] = state;
    out["start_state_intents"] = state.get("start_state_intents", Array());
    out["start_state_intent_owner"] = state.get("start_state_intent_owner", String("native_probe_lifecycle"));
    out["boundary_intents"] = state.get("boundary_intents", Array());
    return out;
}

Dictionary DCWorldExt::native_climate_round_kick(const Dictionary &input) {
    using namespace pk_async_climate;
    Dictionary out;
    async_climate_round_register();
    const bool kicked = async_climate_round_kick(input);
    AsyncClimateRoundState *st = _get_round_state(_async_climate_round_state);
    if (st) {
        std::lock_guard<std::mutex> g(st->state_mtx);
        if (kicked) {
            st->lifecycle_async_kicked = true;
            st->lifecycle_stage = "worker_kicked";
        } else if (st->lifecycle_round_active) {
            st->lifecycle_stage = "worker_busy_or_rejected";
        }
    }
    Dictionary state = get_native_climate_round_state_report();
    out["rc"] = 0;
    out["path"] = String("native_climate_round_kick");
    out["authority"] = String("probe_native_state");
    out["simulation_authority"] = false;
    out["kicked"] = kicked;
    out["substage"] = kicked ? String("kicked") : String("worker_busy_or_rejected");
    out["state"] = state;
    return out;
}

Dictionary DCWorldExt::native_climate_round_poll() {
    using namespace pk_async_climate;
    Dictionary out;
    Dictionary result = async_climate_round_poll();
    const bool done = !result.is_empty();
    AsyncClimateRoundState *st = _get_round_state(_async_climate_round_state);
    if (st) {
        std::lock_guard<std::mutex> g(st->state_mtx);
        if (st->lifecycle_round_active && st->lifecycle_async_kicked) {
            st->lifecycle_poll_attempts += 1;
        }
        st->lifecycle_stage = done ? "poll_done" : "poll_pending";
        if (done) {
            st->lifecycle_finish_boundary_intents.clear();
            st->lifecycle_finish_boundary_intents.push_back("apply_sea_ice_flips");
            st->lifecycle_finish_boundary_intents.push_back("finalize_round");
            st->lifecycle_finish_boundary_intents.push_back("finish_native_lifecycle");
            st->lifecycle_finalize_tail_boundary_intents.clear();
            st->lifecycle_finalize_tail_boundary_intents.push_back(bool(result.get("fin_applied", false)) ? "use_worker_finalizer_diag" : "apply_gdscript_finalizer_fallback");
            st->lifecycle_finalize_tail_boundary_intents.push_back("advance_full_sweep_counter");
            st->lifecycle_finalize_tail_boundary_intents.push_back("publish_climate_breakdown");
            st->lifecycle_finalize_tail_boundary_intents.push_back("annual_log");
            st->lifecycle_finalize_tail_boundary_intents.push_back("soa_noop");
            st->lifecycle_finalize_tail_boundary_intents.push_back("soak_dump");
            st->lifecycle_finalize_tail_boundary_intents.push_back("integrity_check");
            st->lifecycle_finalize_tail_boundary_intents.push_back("finish_active_pass");
            st->lifecycle_finalize_tail_boundary_intents.push_back("reset_transpiration_state");
            st->lifecycle_finalize_tail_boundary_intents.push_back("reset_round_local_state");
            st->lifecycle_finalize_tail_boundary_intents.push_back("flush_pending_mark_dirty_all");
            st->lifecycle_finalize_tail_boundary_intents.push_back("mark_round_slots_stale");
            st->lifecycle_finalize_tail_boundary_intents.push_back("dump_round_slot_stats");
        }
    }
    Dictionary state = get_native_climate_round_state_report();
    out["rc"] = 0;
    out["path"] = String("native_climate_round_poll");
    out["authority"] = String("probe_native_state");
    out["simulation_authority"] = false;
    out["done"] = done;
    out["result"] = result;
    out["published_slots"] = result.get("published_slots", Array());
    out["published_slot_count"] = result.get("published_slot_count", (int64_t)0);
    out["visual_dirty_intents"] = result.get("visual_dirty_intents", Array());
    out["breakdown"] = result.get("breakdown", Dictionary());
    out["finish_boundary_intents"] = state.get("finish_boundary_intents", Array());
    out["finish_boundary_intent_owner"] = state.get("finish_boundary_intent_owner", String("native_probe_lifecycle"));
    out["finalize_tail_boundary_intents"] = state.get("finalize_tail_boundary_intents", Array());
    out["finalize_tail_boundary_intent_owner"] = state.get("finalize_tail_boundary_intent_owner", String("native_probe_lifecycle"));
    out["worker_total_us"] = result.get("worker_total_us", (int64_t)0);
    out["worker_compute_us"] = result.get("worker_compute_us", (int64_t)0);
    out["finalizer_us"] = result.get("finalizer_us", (int64_t)0);
    out["state"] = state;
    return out;
}

Dictionary DCWorldExt::native_climate_round_finish_round(const Dictionary &ctx) {
    using namespace pk_async_climate;
    Dictionary out;
    AsyncClimateRoundState *st = _get_round_state(_async_climate_round_state);
    if (!st) {
        out["rc"] = -1;
        out["path"] = String("native_climate_round_finish_round");
        out["fallback_reason"] = String("native_climate_round_state_missing");
        out["authority"] = String("probe_native_lifecycle");
        out["simulation_authority"] = false;
        out["state"] = get_native_climate_round_state_report();
        return out;
    }
    {
        std::lock_guard<std::mutex> g(st->state_mtx);
        st->lifecycle_round_active = false;
        st->lifecycle_async_kicked = false;
        st->lifecycle_pass_cursor = int(ctx.get("pass_cursor", st->lifecycle_pass_cursor));
        st->lifecycle_stage = String(ctx.get("stage", String("round_finished"))).utf8().get_data();
    }
    out["rc"] = 0;
    out["path"] = String("native_climate_round_finish_round");
    out["authority"] = String("probe_native_lifecycle");
    out["simulation_authority"] = false;
    out["state"] = get_native_climate_round_state_report();
    return out;
}

Dictionary DCWorldExt::get_native_climate_round_hot_state() {
    using namespace pk_async_climate;
    Dictionary out;
    out["owner"] = String("DCWorldExt.AsyncClimateRoundState");
    out["authority"] = String("native_ready_capsule");
    out["simulation_authority"] = false;
    out["climate_round_authority_ready"] = true;
    out["compact_state_capsule"] = true;
    AsyncClimateRoundState *st = _get_round_state(_async_climate_round_state);
    if (!st) {
        out["ready"] = false;
        out["round_active"] = false;
        out["pass_cursor"] = 0;
        out["generation"] = int64_t(0);
        out["boundary_intent_mask"] = int64_t(0);
        return out;
    }
    std::lock_guard<std::mutex> g(st->state_mtx);
    int64_t boundary_intent_mask = 0;
    if (!st->lifecycle_start_state_intents.empty())
        boundary_intent_mask |= 1;
    if (!st->lifecycle_boundary_intents.empty())
        boundary_intent_mask |= 2;
    if (!st->lifecycle_finish_boundary_intents.empty())
        boundary_intent_mask |= 4;
    if (!st->lifecycle_finalize_tail_boundary_intents.empty())
        boundary_intent_mask |= 8;
    out["ready"] = st->task != nullptr;
    out["round_active"] = st->lifecycle_round_active;
    out["async_kicked"] = st->lifecycle_async_kicked;
    out["pass_cursor"] = st->lifecycle_pass_cursor;
    out["round_id"] = st->lifecycle_round_id;
    out["generation"] = st->lifecycle_round_id;
    out["tick_index"] = st->lifecycle_tick_index;
    out["phase_locked"] = st->lifecycle_phase_locked;
    out["stage"] = String(st->lifecycle_stage.c_str());
    out["dirty"] = boundary_intent_mask != 0;
    out["boundary_intent_mask"] = boundary_intent_mask;
    return out;
}

Dictionary DCWorldExt::get_native_climate_round_state_report() {
    using namespace pk_async_climate;
    Dictionary out;
    out["owner"] = String("DCWorldExt.AsyncClimateRoundState");
    out["authority"] = String("probe_native_state");
    out["simulation_authority"] = false;
    out["registered"] = false;
    out["lifecycle_state"] = String("unregistered");
    out["reset_owner"] = String("DCWorldExt.reset_native_climate_round_state");
    out["gdscript_authority_expected"] = false;
    out["climate_round_state_owner_candidate"] = String("DCWorldExt.AsyncClimateRoundState");
    out["climate_round_authority_ready"] = true;
    out["climate_round_authority_phase"] = String("native_ready_probe");
    Array authority_blockers;
    out["climate_round_authority_blockers"] = authority_blockers;
    Array remaining_gdscript_authority;
    remaining_gdscript_authority.push_back(String("should_run_stride_policy"));
    remaining_gdscript_authority.push_back(String("godot_mapdata_boundary_execution"));
    remaining_gdscript_authority.push_back(String("reset_abort_boundary_execution"));
    remaining_gdscript_authority.push_back(String("sync_sliced_fallback"));
    out["remaining_gdscript_authority"] = remaining_gdscript_authority;
    out["remaining_gdscript_simulation_authority"] =
        Array::make(String("should_run_stride_policy"),
                    String("sync_sliced_fallback"));
    out["remaining_godot_boundary_authority"] =
        Array::make(String("godot_mapdata_boundary_execution"),
                    String("reset_abort_boundary_execution"));
    out["native_owned_lifecycle_authority"] =
        Array::make(String("round_active"),
                    String("phase_locked"),
                    String("pass_cursor"),
                    String("async_kick_poll"),
                    String("pass_token"),
                    String("finalizer_source_intent"));

    AsyncClimateRoundState *st = _get_round_state(_async_climate_round_state);
    if (!st) {
        return out;
    }

    std::lock_guard<std::mutex> g(st->state_mtx);
    out["lifecycle_owner"] = String(st->lifecycle_owner.c_str());
    out["lifecycle_round_active"] = st->lifecycle_round_active;
    out["lifecycle_async_kicked"] = st->lifecycle_async_kicked;
    out["lifecycle_pass_cursor"] = st->lifecycle_pass_cursor;
    out["lifecycle_round_id"] = st->lifecycle_round_id;
    out["lifecycle_tick_index"] = st->lifecycle_tick_index;
    out["lifecycle_poll_attempts"] = st->lifecycle_poll_attempts;
    out["phase_locked"] = st->lifecycle_phase_locked;
    out["phase_lock_owner"] = String("native_probe_lifecycle");
    out["lifecycle_stage"] = String(st->lifecycle_stage.c_str());
    Array start_state_intents;
    for (const std::string &intent : st->lifecycle_start_state_intents) {
        start_state_intents.push_back(String(intent.c_str()));
    }
    out["start_state_intents"] = start_state_intents;
    out["start_state_intent_owner"] = String("native_probe_lifecycle");
    Array boundary_intents;
    for (const std::string &intent : st->lifecycle_boundary_intents) {
        boundary_intents.push_back(String(intent.c_str()));
    }
    out["boundary_intents"] = boundary_intents;
    out["boundary_intent_owner"] = String("native_probe_lifecycle");
    Array finish_boundary_intents;
    for (const std::string &intent : st->lifecycle_finish_boundary_intents) {
        finish_boundary_intents.push_back(String(intent.c_str()));
    }
    out["finish_boundary_intents"] = finish_boundary_intents;
    out["finish_boundary_intent_owner"] = String("native_probe_lifecycle");
    Array finalize_tail_boundary_intents;
    for (const std::string &intent : st->lifecycle_finalize_tail_boundary_intents) {
        finalize_tail_boundary_intents.push_back(String(intent.c_str()));
    }
    out["finalize_tail_boundary_intents"] = finalize_tail_boundary_intents;
    out["finalize_tail_boundary_intent_owner"] = String("native_probe_lifecycle");
    if (st->task == nullptr) {
        out["lifecycle_state"] = String("state_allocated_without_task");
        return out;
    }

    AsyncClimateRoundTask *t = st->task.get();
    const bool request_pending = t->request_pending.load(std::memory_order_acquire);
    const bool result_ready = t->result_ready.load(std::memory_order_acquire);
    const bool should_exit = t->should_exit.load(std::memory_order_acquire);
    out["registered"] = true;
    out["request_pending"] = request_pending;
    out["result_ready"] = result_ready;
    out["should_exit"] = should_exit;
    out["lifecycle_state"] = should_exit
        ? String("shutting_down")
        : (request_pending ? String("request_pending")
                           : (result_ready ? String("result_ready") : String("idle")));
    out["total_rounds"] = (int64_t)t->total_rounds.load(std::memory_order_relaxed);
    out["total_reused"] = (int64_t)t->total_reused.load(std::memory_order_relaxed);
    out["error_code"] = t->error_code.load(std::memory_order_relaxed);
    out["worker_compute_us"] = (int64_t)t->last_worker_compute_us.load(std::memory_order_relaxed);
    out["worker_total_us"] = (int64_t)t->last_worker_total_us.load(std::memory_order_relaxed);
    out["pass_a_us"] = (int64_t)t->last_pass_a_us.load(std::memory_order_relaxed);
    out["pass_b_us"] = (int64_t)t->last_pass_b_us.load(std::memory_order_relaxed);
    out["ocean_water_us"] = (int64_t)t->last_ocean_water_us.load(std::memory_order_relaxed);
    out["ocean_land_us"] = (int64_t)t->last_ocean_land_us.load(std::memory_order_relaxed);
    out["wind_air_us"] = (int64_t)t->last_wind_air_us.load(std::memory_order_relaxed);
    out["wind_surface_us"] = (int64_t)t->last_wind_surface_us.load(std::memory_order_relaxed);
    out["sea_ice_us"] = (int64_t)t->last_sea_ice_us.load(std::memory_order_relaxed);
    out["transp_us"] = (int64_t)t->last_transp_us.load(std::memory_order_relaxed);
    out["finalizer_us"] = (int64_t)t->last_finalizer_us.load(std::memory_order_relaxed);
    {
        std::lock_guard<std::mutex> lk(t->mtx);
        out["static_n_cells"] = t->static_knobs.n_cells;
        out["input_n_cells"] = t->in_buf.n_cells;
    }
    return out;
}

Dictionary DCWorldExt::reset_native_climate_round_state(const String &reason) {
    Dictionary before = get_native_climate_round_state_report();
    async_climate_round_shutdown();
    Dictionary out;
    out["rc"] = 0;
    out["reason"] = reason;
    out["reset_owner"] = String("DCWorldExt.reset_native_climate_round_state");
    out["authority"] = String("probe_native_state");
    out["simulation_authority"] = false;
    out["previous_state"] = before;
    out["current_state"] = get_native_climate_round_state_report();
    Array reset_boundary_intents;
    reset_boundary_intents.push_back(String("abort_active_pass"));
    reset_boundary_intents.push_back(String("abort_all_climate_passes"));
    reset_boundary_intents.push_back(String("reset_round_local_state"));
    reset_boundary_intents.push_back(String("reset_async_lifecycle_local_state"));
    reset_boundary_intents.push_back(String("reset_round_timings"));
    reset_boundary_intents.push_back(String("reset_start_snapshots"));
    reset_boundary_intents.push_back(String("reset_last_diagnostics"));
    reset_boundary_intents.push_back(String("reset_transpiration_state"));
    reset_boundary_intents.push_back(String("reset_dirty_season_state"));
    reset_boundary_intents.push_back(String("seed_full_sweep_counter"));
    out["reset_boundary_intents"] = reset_boundary_intents;
    out["reset_boundary_intent_owner"] = String("native_probe_lifecycle");
    return out;
}

void DCWorldExt::async_climate_round_shutdown() {
    using namespace pk_async_climate;
    AsyncClimateRoundState *st = _get_round_state(_async_climate_round_state);
    if (!st) return;
    std::unique_ptr<AsyncClimateRoundTask> dead;
    {
        std::lock_guard<std::mutex> g(st->state_mtx);
        dead = std::move(st->task);
    }
    if (dead) {
        dead->should_exit.store(true, std::memory_order_release);
        dead->cv.notify_all();
        if (dead->worker.joinable()) dead->worker.join();
    }
    delete st;
    _async_climate_round_state = nullptr;
}

} // namespace pk
