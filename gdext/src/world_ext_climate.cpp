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
#include <godot_cpp/classes/worker_thread_pool.hpp>
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

static inline float pk_signed_hydrology_contribution(float anomaly,
                                                      float wet_weight,
                                                      float dry_weight) {
    return anomaly * (anomaly < 0.0f ? dry_weight : wet_weight);
}


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

    // GDScript constants (architecture.md §G.6 / TERRAIN/CV enums)
    (void)pterr;
    constexpr uint8_t COVER_GLACIER = 2; // CoverType.CV.GLACIER

    // ─── 7. Main loop — 1:1 mirror of _climate_pass_a SoA branch ───────
    // [Phase C.3c] 主循环抽成 lambda，scalar 路径 run_range(0, n)，
    // _thread 变体走 pk::parallel_for_range；body 严格 1:1。
    auto run_range = [&](int begin, int end) {
        for (int i = begin; i < end; ++i) {
            const float ny             = pln[i];
            const float temp_year_lat  = pty[i];
            const float elevation      = pe[i];
            const bool  is_water       = piw[i] != 0;

            // (a) dev_today — absolute deviation with a high-latitude relative
            // blend. Pure absolute insol_now-mean under-amplifies polar seasons;
            // pure fractional deviation explodes near polar-night mean values.
            const float ny_clamped = dc_clamp01f(ny);
            const float insol_now = dc_insolation_now(ny_clamped, float(season_phase), axial_tilt_deg, daylen_amp);
            const float insol_mean = pinsol_mean[i];
            float dev_today = dc_insolation_season_dev(ny_clamped, insol_now, insol_mean);
            if (dev_today < insol_dev_min) dev_today = insol_dev_min;
            else if (dev_today > insol_dev_max) dev_today = insol_dev_max;
            const float day_length = dc_day_length_norm(ny_clamped, float(season_phase), axial_tilt_deg);
            const float heat_input = dc_clamp01f(insol_now * solar_gain);

            // (b) moisture. Insolation affects land moisture only through the
            // existing temperature/evaporation/wind/ocean/precipitation loop.
            // The generated base is a static geographic anchor, not a seasonal driver.
            float moisture_target;
            if (is_water) {
                moisture_target = pbm[i];
            } else {
                float bm = pbm[i];
                if (bm > 1.0f) bm = 1.0f;
                else if (bm < 0.0f) bm = 0.0f;
                moisture_target = bm;
                if (pweatherv != nullptr) {
                    float vapor = pweatherv[i];
                    if (vapor < 0.0f) vapor = 0.0f; else if (vapor > 1.0f) vapor = 1.0f;
                    const float vapor_reference = bm * 0.15f;
                    moisture_target += (vapor - vapor_reference) * moisture_vapor_w;
                }
                if (pprecip != nullptr) {
                    float precip = pprecip[i];
                    if (precip < 0.0f) precip = 0.0f; else if (precip > 1.0f) precip = 1.0f;
                    moisture_target += precip * moisture_precip_w;
                }
                if (psoil != nullptr) {
                    float soil = psoil[i];
                    if (soil < -0.5f) soil = -0.5f; else if (soil > 0.5f) soil = 0.5f;
                    moisture_target += pk_signed_hydrology_contribution(
                        soil, moisture_soil_w, moisture_soil_dry_w);
                }
                if (pwb != nullptr) {
                    float wb = pwb[i];
                    if (wb < -1.0f) wb = -1.0f; else if (wb > 1.0f) wb = 1.0f;
                    moisture_target += pk_signed_hydrology_contribution(
                        wb, moisture_wb_w, moisture_wb_dry_w);
                }
                if (moisture_target > 1.0f) moisture_target = 1.0f;
                else if (moisture_target < 0.0f) moisture_target = 0.0f;
            }
            float moisture_now = moisture_target;
            if (!is_water) {
                float prev_moisture = pm[i];
                if (!std::isfinite(prev_moisture) || prev_moisture < 0.0f || prev_moisture > 1.0f) {
                    prev_moisture = moisture_target;
                }
                moisture_now = prev_moisture + (moisture_target - prev_moisture) * moisture_relax_eff;
                if (moisture_now > 1.0f) moisture_now = 1.0f;
                else if (moisture_now < 0.0f) moisture_now = 0.0f;
            }

            // (c) temperature
            // alt_penalty 输入为 sea_level 以上 land_h，避免海平面附近陆地被绝对 elevation 过度扣温。
            float temp_year = temp_year_lat - float(pk_alt_penalty(double(elevation), double(sea_level)));
            if (temp_year < 0.0f) temp_year = 0.0f;
            else if (temp_year > 1.0f) temp_year = 1.0f;
            // 物理化（2026-06-16）：季节项按吸收短波因子缩放（持久冰封→低吸收）。
            // 用【年均温度 p365[i]】（上一步 temp_365d）作冰封代理，避免夏季融化正反馈失控。
            float season_offset = pk_season_offset_continental(insol_amp_gain, is_water, p365[i], dev_today, land_continentality);
            // [climate-zone-fix P2] 沿海陆地缩小季节振幅（冬暖夏凉）→ 温带海洋性(Cfb)。
            if (!is_water && pmar != nullptr) {
                season_offset *= (1.0f - maritime_damp * pmar[i]);
            }
            float radiative_target = modifier_climate_radiative_target(
                i, temp_year + season_offset);
            if (radiative_target < 0.0f) radiative_target = 0.0f;
            else if (radiative_target > 1.0f) radiative_target = 1.0f;

            // (d) thermal inertia: radiative target updates heat storage first.
            const float current_temp = pt[i];
            float prev_energy = pthermal[i];
            if (pei[i] == 0) {
                prev_energy = current_temp;
            }
            const float prev_temp = prev_energy;
            float alpha = thermal_land_eff;
            if (is_water) alpha = thermal_water_eff;
            else if (pcov[i] == COVER_GLACIER) alpha = thermal_snow_eff;
            else if (psnowpack[i] > snowpack_cover_low) alpha = thermal_snow_eff;
            else if (elevation > 0.70f) alpha = thermal_high_eff;
            const float heat_next = prev_energy + (radiative_target - prev_energy) * alpha;
            float temp_delta = heat_next - prev_temp;
            if (temp_delta > thermal_delta_cap_eff) temp_delta = thermal_delta_cap_eff;
            else if (temp_delta < -thermal_delta_cap_eff) temp_delta = -thermal_delta_cap_eff;
            float temp_now = prev_temp + temp_delta;
            if (temp_now < 0.0f) temp_now = 0.0f;
            else if (temp_now > 1.0f) temp_now = 1.0f;
            pthermal[i] = heat_next;

            // (e) keep snowpack physical state, but do not publish visual snow.
            if (!is_water) {
                if (pcov[i] == COVER_GLACIER && psnowpack[i] < 0.80f) {
                    psnowpack[i] = 0.80f;
                }
            } else {
                psnowpack[i] = 0.0f;
            }

            // (e) write SoA outputs
            // A 修复（2026-06）：pass_a 不再写 cell_temp。把含热惯性的运行时
            // baseline 写入 cell_temp_baseline (ptb)；wind_surface 末端用它做合成基准。
            // cell_temp_baseline_year (pty) 是年级静态 LUT，pass_a 只读不写（与改前一致）。
            // 同时把 ocean / local anomaly 在 pass_a 末尾清 0，开启新一日累加。
            ptb[i]  = temp_now;
            poanom[i] = 0.0f;
            planom[i] = 0.0f;
            pm[i]   = moisture_now;
            pso[i]  = season_offset;
            pinsol[i] = insol_now;
            pdev[i]   = dev_today;
            pday[i]   = day_length;
            pheat[i]  = heat_input;

            // (f) EMA
            float m30, m365;
            if (pei[i] == 0) {
                m30  = temp_now;
                m365 = temp_now;
                pei[i] = 1;
            } else {
                // lerp(a, b, t) = a + (b - a) * t
                m30  = p30[i]  + (temp_now - p30[i])  * ema_alpha_30;
                m365 = p365[i] + (temp_now - p365[i]) * ema_alpha_365;
            }
            p30[i]  = m30;
            p365[i] = m365;
            pa[i]   = m30 - m365;
        }
    };
    run_range(0, n);

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
    (void)phase; (void)season_phase;

    static bool _diag_printed = false;
    auto diag = [&](const char *reason) {
        if (!_diag_printed) {
            _diag_printed = true;
            UtilityFunctions::print(String("[DCWorldExt][diag] run_climate_pass_a_thread fallback: ") + String(reason));
        }
    };

    if (!_bound) { diag("not _bound"); return -1.0; }

    // ─── 2. Resolve all slot ids ─────────────────────────────────────────
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
    // A 修复（2026-06）：见 run_climate_pass_a 同段注释。
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
        diag("slot id <0");
        return -1.0;
    }

    // ─── 3. Pull cp_struct scalars ───────────────────────────────────────
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
    // A 修复（2026-06）：anomaly 合成 slot — pass_a 末尾 fill 0。
    PackedFloat32Array &ocean_anom_a    = _slots.write[sid_ocean_anom].arr_f32;
    PackedFloat32Array &local_anom_a    = _slots.write[sid_local_anom].arr_f32;
    const PackedFloat32Array *weather_vapor_a = nullptr;
    const PackedFloat32Array *weather_precip_a = nullptr;
    const PackedFloat32Array *soil_moisture_a = nullptr;
    const PackedFloat32Array *water_balance_a = nullptr;

    const int n = temp_a.size();
    if (n <= 0) { diag("temp_a empty"); return -1.0; }

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
        diag("size mismatch"); return -1.0;
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

    // ─── 6. Hot pointers ────────────────────────────────────────────────
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
    // A 修复（2026-06）：anomaly 合成 slot 写指针。
    float * const __restrict poanom = ocean_anom_a.ptrw();
    float * const __restrict planom = local_anom_a.ptrw();
    const float * const pweatherv = weather_vapor_a != nullptr ? weather_vapor_a->ptr() : nullptr;
    const float * const pprecip = weather_precip_a != nullptr ? weather_precip_a->ptr() : nullptr;
    const float * const psoil = soil_moisture_a != nullptr ? soil_moisture_a->ptr() : nullptr;
    const float * const pwb = water_balance_a != nullptr ? water_balance_a->ptr() : nullptr;
    // [climate-zone-fix P2] 海洋性因子指针（缺省/关闭→nullptr，热循环跳过缩放）。
    const float * const pmar = (maritime_arr.size() == n && maritime_damp > 0.0f) ? maritime_arr.ptr() : nullptr;

    (void)pterr;
    constexpr uint8_t COVER_GLACIER = 2;

    // Per-cell annual-mean insolation: memoized (day-invariant); rebuilt single-
    // threaded here before the parallel dispatch, then read const in the lambda.
    const float * const __restrict pinsol_mean =
        ensure_insol_annual_mean_cache(pln, n, axial_tilt_deg, daylen_amp);

    // ─── 7. Main loop（与 run_climate_pass_a 主循环 1:1）──────────────────
    auto run_range = [&](int begin, int end) {
        for (int i = begin; i < end; ++i) {
            const float ny             = pln[i];
            const float temp_year_lat  = pty[i];
            const float elevation      = pe[i];
            const bool  is_water       = piw[i] != 0;

            const float ny_clamped = dc_clamp01f(ny);
            const float insol_now = dc_insolation_now(ny_clamped, float(season_phase), axial_tilt_deg, daylen_amp);
            const float insol_mean = pinsol_mean[i];
            float dev_today = dc_insolation_season_dev(ny_clamped, insol_now, insol_mean);
            if (dev_today < insol_dev_min) dev_today = insol_dev_min;
            else if (dev_today > insol_dev_max) dev_today = insol_dev_max;
            const float day_length = dc_day_length_norm(ny_clamped, float(season_phase), axial_tilt_deg);
            const float heat_input = dc_clamp01f(insol_now * solar_gain);

            // Moisture has no direct seasonal multiplier; solar forcing reaches
            // it through the existing water-cycle state sampled below.
            float moisture_target;
            if (is_water) {
                moisture_target = pbm[i];
            } else {
                float bm = pbm[i];
                if (bm > 1.0f) bm = 1.0f;
                else if (bm < 0.0f) bm = 0.0f;
                moisture_target = bm;
                if (pweatherv != nullptr) {
                    float vapor = pweatherv[i];
                    if (vapor < 0.0f) vapor = 0.0f; else if (vapor > 1.0f) vapor = 1.0f;
                    const float vapor_reference = bm * 0.15f;
                    moisture_target += (vapor - vapor_reference) * moisture_vapor_w;
                }
                if (pprecip != nullptr) {
                    float precip = pprecip[i];
                    if (precip < 0.0f) precip = 0.0f; else if (precip > 1.0f) precip = 1.0f;
                    moisture_target += precip * moisture_precip_w;
                }
                if (psoil != nullptr) {
                    float soil = psoil[i];
                    if (soil < -0.5f) soil = -0.5f; else if (soil > 0.5f) soil = 0.5f;
                    moisture_target += pk_signed_hydrology_contribution(
                        soil, moisture_soil_w, moisture_soil_dry_w);
                }
                if (pwb != nullptr) {
                    float wb = pwb[i];
                    if (wb < -1.0f) wb = -1.0f; else if (wb > 1.0f) wb = 1.0f;
                    moisture_target += pk_signed_hydrology_contribution(
                        wb, moisture_wb_w, moisture_wb_dry_w);
                }
                if (moisture_target > 1.0f) moisture_target = 1.0f;
                else if (moisture_target < 0.0f) moisture_target = 0.0f;
            }
            float moisture_now = moisture_target;
            if (!is_water) {
                float prev_moisture = pm[i];
                if (!std::isfinite(prev_moisture) || prev_moisture < 0.0f || prev_moisture > 1.0f) {
                    prev_moisture = moisture_target;
                }
                moisture_now = prev_moisture + (moisture_target - prev_moisture) * moisture_relax_eff;
                if (moisture_now > 1.0f) moisture_now = 1.0f;
                else if (moisture_now < 0.0f) moisture_now = 0.0f;
            }

            float temp_year = temp_year_lat - float(pk_alt_penalty(double(elevation), double(sea_level)));
            if (temp_year < 0.0f) temp_year = 0.0f;
            else if (temp_year > 1.0f) temp_year = 1.0f;
            // 物理化（2026-06-16）：季节项按吸收短波因子缩放（持久冰封→低吸收）。
            // 用【年均温度 p365[i]】（上一步 temp_365d）作冰封代理，避免夏季融化正反馈失控。
            float season_offset = pk_season_offset_continental(insol_amp_gain, is_water, p365[i], dev_today, land_continentality);
            // [climate-zone-fix P2] 沿海陆地缩小季节振幅（冬暖夏凉）→ 温带海洋性(Cfb)。
            if (!is_water && pmar != nullptr) {
                season_offset *= (1.0f - maritime_damp * pmar[i]);
            }
            float radiative_target = modifier_climate_radiative_target(
                i, temp_year + season_offset);
            if (radiative_target < 0.0f) radiative_target = 0.0f;
            else if (radiative_target > 1.0f) radiative_target = 1.0f;

            const float current_temp = pt[i];
            float prev_energy = pthermal[i];
            if (pei[i] == 0) {
                prev_energy = current_temp;
            }
            const float prev_temp = prev_energy;
            float alpha = thermal_land_eff;
            if (is_water) alpha = thermal_water_eff;
            else if (pcov[i] == COVER_GLACIER) alpha = thermal_snow_eff;
            else if (psnowpack[i] > snowpack_cover_low) alpha = thermal_snow_eff;
            else if (elevation > 0.70f) alpha = thermal_high_eff;
            const float heat_next = prev_energy + (radiative_target - prev_energy) * alpha;
            float temp_delta = heat_next - prev_temp;
            if (temp_delta > thermal_delta_cap_eff) temp_delta = thermal_delta_cap_eff;
            else if (temp_delta < -thermal_delta_cap_eff) temp_delta = -thermal_delta_cap_eff;
            float temp_now = prev_temp + temp_delta;
            if (temp_now < 0.0f) temp_now = 0.0f;
            else if (temp_now > 1.0f) temp_now = 1.0f;
            pthermal[i] = heat_next;

            // Runtime visual snow is authored by weather distribute; climate
            // only maintains the persistent snowpack used by physics.
            if (!is_water) {
                if (pcov[i] == COVER_GLACIER && psnowpack[i] < 0.80f) {
                    psnowpack[i] = 0.80f;
                }
            } else {
                psnowpack[i] = 0.0f;
            }

            // A 修复（2026-06）：pass_a 不再写 cell_temp；ptb 承载运行时 baseline，
            // 同时清零 ocean / local anomaly（开启新一日累加）。详见 run_climate_pass_a。
            ptb[i]  = temp_now;
            poanom[i] = 0.0f;
            planom[i] = 0.0f;
            pm[i]   = moisture_now;
            pso[i]  = season_offset;
            pinsol[i] = insol_now;
            pdev[i]   = dev_today;
            pday[i]   = day_length;
            pheat[i]  = heat_input;

            float m30, m365;
            if (pei[i] == 0) {
                m30  = temp_now;
                m365 = temp_now;
                pei[i] = 1;
            } else {
                m30  = p30[i]  + (temp_now - p30[i])  * ema_alpha_30;
                m365 = p365[i] + (temp_now - p365[i]) * ema_alpha_365;
            }
            p30[i]  = m30;
            p365[i] = m365;
            pa[i]   = m30 - m365;
        }
    };

    pk::parallel_for_range("pk_climate_pass_a", n, n_tasks, /*seq_threshold=*/256, run_range);

    // §11.2 flush — 与主 pass 一致。A 修复（2026-06）：不再 flush cell_temp，
    // 改 flush 两条 anomaly slot。
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
static inline float pk_limit_cold_water_positive_transport_source(
        float source, float baseline, float sea_ice_frac, float t_form, float t_melt) {
    if (source <= 0.0f) return source;
    source *= 1.0f - dc_clampf(sea_ice_frac, 0.0f, 1.0f);
    const float span = std::max(0.001f, t_melt - t_form);
    float t = (baseline - t_form) / span;
    if (t < 0.0f) t = 0.0f;
    else if (t > 1.0f) t = 1.0f;
    const float cold_gate = t * t * (3.0f - 2.0f * t);
    source *= cold_gate;
    const float melt_room = t_melt - baseline;
    if (melt_room <= 0.0f) return source;
    return std::min(source, melt_room);
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

    auto t0 = std::chrono::high_resolution_clock::now();

    for (int i = start_idx; i < end_idx; ++i) {
        if (IW[i] == 0) continue; // skip land
        const float cur_x = OCX[i];
        const float cur_y = OCY[i];
        const float cur_len2 = cur_x * cur_x + cur_y * cur_y;
        if (cur_len2 < 1e-6f || advect_steps == 0) {
            AOUT[i] = dc_decay_tta(AOUT[i], tta_zero_current_decay);
            // A 修复：current 不足时 ocean anomaly 也朝 0 衰减（避免上轮残值滞留）。
            OANOM_SLOT[i] = OANOM_SLOT[i] * (1.0f - tta_zero_current_decay);
            continue;
        }
        const float inv_cur = 1.0f / std::sqrt(cur_len2);
        const float up_dx = -cur_x * inv_cur;
        const float up_dy = -cur_y * inv_cur;

        int upstream_idx = i;
        for (int step = 0; step < advect_steps; ++step) {
            int   best_idx = -1;
            float best_dot = 0.1f;
            const float swx = POSX[upstream_idx];
            const float swy = POSY[upstream_idx];
            const int ub = upstream_idx * 6;
            for (int d = 0; d < 6; ++d) {
                const int32_t ni = NB[ub + d];
                if (ni < 0) continue;
                if (IW[ni] == 0) continue;
                const float dx = POSX[ni] - swx;
                const float dy = POSY[ni] - swy;
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

        const float temp_self = TB[i];
        const float temp_up   = TB[upstream_idx];
        float temp_mixed = temp_self + (temp_up - temp_self) * heat_mix; // = lerpf
        if (temp_mixed < 0.0f) temp_mixed = 0.0f;
        else if (temp_mixed > 1.0f) temp_mixed = 1.0f;
        // Sea ice insulates the surface from positive ocean heat anomalies.
        // Keep cold anomalies intact, but reduce warm-current injection by ice cover.
        float source = temp_mixed - BL[i];
        source = pk_limit_cold_water_positive_transport_source(
            source, BL[i], SIF[i], cold_transport_form, cold_transport_melt);
        // A 修复（2026-06）：不再写 T；只写 ocean anomaly slot。
        float oanom = source;
        if (oanom < -0.08f) oanom = -0.08f;
        else if (oanom > 0.08f) oanom = 0.08f;
        OANOM_SLOT[i] = oanom;
        AOUT[i] = dc_stabilize_tta(AOUT[i], source, tta_source_cap, tta_blend_rate);
    }

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

    auto t0 = std::chrono::high_resolution_clock::now();

    // 注意：land 写入的是 LAND cell 的 anomaly，读 WATER 邻居的 anomaly
    // （water pass 已经在 anomaly_inout 里写好）。所以读写不冲突——所有 land
    // i 都不在自身 6 邻居读到的 water cell 集合里（water cell 的 anomaly 在
    // water pass 已 finalized）。可以安全用同一个数组 in-place。
    for (int i = start_idx; i < end_idx; ++i) {
        if (IW[i] != 0) continue; // skip water
        const float swx = POSX[i];
        const float swy = POSY[i];
        float weighted_sum = 0.0f;
        float weight_total = 0.0f;
        const int b = i * 6;
        for (int d = 0; d < 6; ++d) {
            const int32_t ni = NB[b + d];
            if (ni < 0) continue;
            if (IW[ni] == 0) continue; // only water nb contributes
            const float cx = OCX[ni];
            const float cy = OCY[ni];
            if (cx * cx + cy * cy < 1e-6f) continue;
            const float dx = swx - POSX[ni];
            const float dy = swy - POSY[ni];
            const float dlen2 = dx * dx + dy * dy;
            if (dlen2 < 1e-6f) continue;
            const float inv_len = 1.0f / std::sqrt(dlen2);
            const float dot_v = (dx * cx + dy * cy) * inv_len;
            if (dot_v <= 0.0f) continue;
            weighted_sum += A[ni] * dot_v;
            weight_total += dot_v;
        }
        const float prev_anomaly = A[i];
        float anomaly_in = dc_decay_tta(prev_anomaly, tta_decay_rate);
        if (weight_total > 0.0f) {
            anomaly_in = dc_stabilize_tta(
                prev_anomaly, (weighted_sum / weight_total) * effective_leak,
                tta_source_cap, tta_blend_rate);
        }
        A[i] = anomaly_in;
        // A 修复（2026-06）：land cell 累加 anomaly_in 到 ocean thermal anomaly slot；
        // 不再直接改写 cell_temp。anomaly_in 已包含 dc_decay/stabilize，本身有界。
        if ((anomaly_in < 0.0f ? -anomaly_in : anomaly_in) > 1e-5f) {
            float oanom = OANOM_SLOT[i] + anomaly_in;
            if (oanom < -0.08f) oanom = -0.08f;
            else if (oanom > 0.08f) oanom = 0.08f;
            OANOM_SLOT[i] = oanom;
        }
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

static inline float pk_snowpack_cover_for_albedo(float snowpack, float low, float full) {
    const float span = (full - low) > 0.001f ? (full - low) : 0.001f;
    float u = (snowpack - low) / span;
    if (u < 0.0f) u = 0.0f;
    else if (u > 1.0f) u = 1.0f;
    return u * u * (3.0f - 2.0f * u);
}

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
    const float t_freeze              = float(knobs["t_freeze"]);
    const float coupling_gain         = float(knobs["coupling_gain"]);
    const float coast_leak            = float(knobs["coast_leak"]);
    const double season_phase         = double(knobs["season_phase"]);
    const float snowpack_cover_low    = knobs.has("snowpack_cover_low") ? float(knobs["snowpack_cover_low"]) : 0.05f;
    const float snowpack_cover_full   = knobs.has("snowpack_cover_full") ? float(knobs["snowpack_cover_full"]) : 0.32f;

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

    // LandformType.LF: LOWLAND=5, HILL=6, MOUNTAIN=7, PEAK=8, DELTA=9,
    //                  SALT_FLAT=11 (per landform_type.gd:9-23)
    constexpr uint8_t LF_LOWLAND   = 5;
    constexpr uint8_t LF_MOUNTAIN  = 7;
    constexpr uint8_t LF_PEAK      = 8;
    constexpr uint8_t LF_DELTA     = 9;
    constexpr uint8_t LF_SALT_FLAT = 11;

    // ─── Main loop ──────────────────────────────────────────────────────
    for (int i = 0; i < n_cells; ++i) {
        const bool is_water = IW[i] != 0;
        const float temp_now     = TS[i];
        const float moisture_now = M[i];
        const float snow_cover   = pk_snowpack_cover_for_albedo(SNOWPACK[i], snowpack_cover_low, snowpack_cover_full);

        float d_albedo      = 0.0f;
        float d_coastal     = 0.0f;
        float d_landform    = 0.0f;
        float d_evap        = 0.0f;
        float d_rain_shadow = 1.0f;

        // (line 4413-4416) ① albedo (land only)
        if (!is_water) {
            d_albedo = -snow_cool * snow_cover;
            const uint8_t veg_id = VG[i];
            const float foliage = (veg_id < foliage_size) ? FOL[veg_id] : 0.0f;
            d_albedo -= veg_cool * foliage;
        }

        // (line 4419-4431) ② coastal heat leak (land only, using snapshot
        //                   of cells[ni].temperature_transport_anomaly)
        if (!is_water) {
            float sum_anomaly = 0.0f;
            int   n_water     = 0;
            const int base = i * 6;
            for (int d = 0; d < 6; ++d) {
                const int32_t ni = NB[base + d];
                if (ni < 0) continue;
                if (IW[ni] != 0) {
                    sum_anomaly += TTA[ni];
                    n_water += 1;
                }
            }
            if (n_water > 0) {
                d_coastal = coast_leak * (sum_anomaly / float(n_water)) * winter_boost;
            }
        }

        // (line 4434-4440) ③ landform diurnal (land only)
        if (!is_water) {
            const uint8_t lf = LF[i];
            const float solar_factor = std::clamp(INSOL_DEV[i], -1.0f, 1.0f);
            if (lf == LF_LOWLAND || lf == LF_SALT_FLAT || lf == LF_DELTA) {
                d_landform = diurnal_amp * solar_factor;
            } else if (lf == LF_PEAK || lf == LF_MOUNTAIN) {
                d_landform = -diurnal_amp * 0.5f * std::max(0.0f, -solar_factor);
            }
        }

        // (line 4442-4445) A 修复（2026-06）：原 `T[i] = clamp(temp_now + d_*)`
        // 改为累加到 cell_local_thermal_anomaly。temp_final 仍计算用于下面 evap
        // 阶段的 t_eff（保持 GDScript bit-equal 的语义：evap 用 "本日 d_* 注入后" 的 t）。
        float local_anom_contrib = d_albedo + d_coastal + d_landform;
        if (local_anom_contrib < -0.08f) local_anom_contrib = -0.08f;
        else if (local_anom_contrib > 0.08f) local_anom_contrib = 0.08f;
        LANOM[i] = LANOM[i] + local_anom_contrib;
        if (LANOM[i] < -0.08f) LANOM[i] = -0.08f;
        else if (LANOM[i] > 0.08f) LANOM[i] = 0.08f;
        float temp_final = temp_now + local_anom_contrib;
        if (temp_final < 0.0f) temp_final = 0.0f;
        else if (temp_final > 1.0f) temp_final = 1.0f;

        // (line 4456-4481) ④ evap (land only)
        if (!is_water) {
            const float t_eff = temp_final + TTA[i];
            float water_neighbor_w = 0.0f;
            float sum_water_anomaly = 0.0f;
            const int bo = i * 6;
            for (int d = 0; d < 6; ++d) {
                const int32_t ni = NB[bo + d];
                if (ni < 0) continue;
                if (IW[ni] != 0) {
                    water_neighbor_w += 1.0f;
                    sum_water_anomaly += TTA[ni];
                }
            }
            float avg_water_anomaly = 0.0f;
            if (water_neighbor_w > 0.0f) {
                avg_water_anomaly = sum_water_anomaly / water_neighbor_w;
            }
            float nb_w_norm = water_neighbor_w / 6.0f;
            if (nb_w_norm > 1.0f) nb_w_norm = 1.0f;
            if (t_eff > t_freeze && nb_w_norm > 0.0f) {
                d_evap = evap_gain * (t_eff - t_freeze) * nb_w_norm;
                if (coupling_gain > 0.0f && std::fabs(avg_water_anomaly) > 0.001f) {
                    float evap_mul = 1.0f + coupling_gain * avg_water_anomaly;
                    if (evap_mul < 0.0f) evap_mul = 0.0f;
                    else if (evap_mul > 2.0f) evap_mul = 2.0f;
                    d_evap *= evap_mul;
                }
            }
            if (avg_water_anomaly < -0.01f && nb_w_norm > 0.0f && coupling_gain > 0.0f) {
                d_evap += -evap_gain * (-avg_water_anomaly) * nb_w_norm * coupling_gain * 0.5f;
            }
        }

        // (line 4484-4518) ⑤ rain shadow (land only, gated by rs_lookback>0)
        if (!is_water && rs_lookback > 0) {
            const double ny = double(LAT[i]);
            // jitter = sin(q*0.31 + r*0.47) * 0.05；schema 没存 q/r。本实现把
            // jitter 取 0（jitter 仅 ±0.05 ny，对 wind_at 输出方向影响极小，
            // bit-equal 容差 1e-4 内可容忍。后续 PR 加 cell_q/cell_r schema 后
            // 可补 jitter）。
            double w_dx = 0.0, w_dy = 0.0;
            wind_belt_at(ny, season_phase, &w_dx, &w_dy);
            const double wlen2 = w_dx * w_dx + w_dy * w_dy;
            if (wlen2 > 1e-6) {
                float max_upwind_h = ELEV[i];
                int probe_idx = i;
                for (int step = 0; step < rs_lookback; ++step) {
                    int   best_idx = -1;
                    double best_dot = 0.1;
                    const float pwx = POSX[probe_idx];
                    const float pwy = POSY[probe_idx];
                    const int pbase = probe_idx * 6;
                    for (int d3 = 0; d3 < 6; ++d3) {
                        const int32_t ni3 = NB[pbase + d3];
                        if (ni3 < 0) continue;
                        const double dx = double(pwx) - double(POSX[ni3]);
                        const double dy = double(pwy) - double(POSY[ni3]);
                        const double len2 = dx * dx + dy * dy;
                        if (len2 < 1e-6) continue;
                        const double inv_len = 1.0 / std::sqrt(len2);
                        const double dotv = (dx * w_dx + dy * w_dy) * inv_len;
                        if (dotv > best_dot) {
                            best_dot = dotv;
                            best_idx = ni3;
                        }
                    }
                    if (best_idx < 0) break;
                    probe_idx = best_idx;
                    if (ELEV[probe_idx] > max_upwind_h) {
                        max_upwind_h = ELEV[probe_idx];
                    }
                }
                if (max_upwind_h - ELEV[i] >= rs_threshold) {
                    d_rain_shadow = rs_factor;
                }
            }
        }

        // (line 4520-4523) write moisture
        float moisture_final = (moisture_now + d_evap) * d_rain_shadow;
        if (moisture_final < 0.0f) moisture_final = 0.0f;
        else if (moisture_final > 1.0f) moisture_final = 1.0f;
        M[i] = moisture_final;
    }

    // climate-loop-closure Phase 4.1：海冰反照率→温度反馈尾循环（仅水域）。
    // A 修复（2026-06）：水域 cell sea-ice 反照率冷却也作为 local anomaly 贡献，
    // 不再直接改写 cell_temp。LANOM 已被 pass_a 末尾清零，pass_b 主循环对 water cell
    // 也不写（与原 scalar 一致），所以此处直接累加为水域唯一的 LANOM 贡献。
    if (sea_ice_albedo_cooling > 0.0f && SIF_PB != nullptr) {
        for (int i = 0; i < n_cells; ++i) {
            if (IW[i] == 0) continue;
            float water_local = LANOM[i] - sea_ice_albedo_cooling * SIF_PB[i];
            if (water_local < -0.08f) water_local = -0.08f;
            else if (water_local > 0.08f) water_local = 0.08f;
            LANOM[i] = water_local;
        }
    }

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
};

// 对单个 land cell i 跑 pass_b 的 albedo + coastal + landform + write 段。
// 不走 evap / rain-shadow（那两段分别由独立 helper 处理，避免 evap 中
// 第二次邻居扫描污染当前 hot path 的内存访问模式）。返回 temp_final，便于
// 后续 evap 段直接拿用而不重读 T[i]。
inline float pass_b_land_compute_temp(const PassBCtx &c, int i) {
    const float temp_now   = c.TS[i];
    const float snow_cover = pk_snowpack_cover_for_albedo(
        c.SNOWPACK[i],
        c.snowpack_cover_low,
        c.snowpack_cover_full);

    // ① albedo
    float d_albedo = -c.snow_cool * snow_cover;
    const uint8_t veg_id = c.VG[i];
    const float foliage = (veg_id < c.foliage_size) ? c.FOL[veg_id] : 0.0f;
    d_albedo -= c.veg_cool * foliage;

    // ② coastal heat leak（snapshot TTA[]，邻居 sentinel < 0 跳过）
    float d_coastal = 0.0f;
    {
        float sum_anomaly = 0.0f;
        int   n_water     = 0;
        const int base = i * 6;
        for (int d = 0; d < 6; ++d) {
            const int32_t ni = c.NB[base + d];
            if (ni < 0) continue;
            if (c.IW[ni] != 0) {
                sum_anomaly += c.TTA[ni];
                n_water += 1;
            }
        }
        if (n_water > 0) {
            d_coastal = c.coast_leak * (sum_anomaly / float(n_water)) * c.winter_boost;
        }
    }

    // ③ landform diurnal
    float d_landform = 0.0f;
    const uint8_t lf = c.LF[i];
    const float solar_factor = std::clamp(c.INSOL_DEV[i], -1.0f, 1.0f);
    if (lf == kLF_LOWLAND || lf == kLF_SALT_FLAT || lf == kLF_DELTA) {
        d_landform = c.diurnal_amp * solar_factor;
    } else if (lf == kLF_PEAK || lf == kLF_MOUNTAIN) {
        d_landform = -c.diurnal_amp * 0.5f * std::max(0.0f, -solar_factor);
    }

    // ④ A 修复（2026-06）：累加到 cell_local_thermal_anomaly，不再写 cell_temp。
    // temp_final 仍按原公式 = snapshot + d_albedo + d_coastal + d_landform 返回，
    // 供 evap 段做 t_eff（保持 GDScript bit-equal 的"d_* 注入后温度"语义）。
    float local_anom_contrib = d_albedo + d_coastal + d_landform;
    if (local_anom_contrib < -0.08f) local_anom_contrib = -0.08f;
    else if (local_anom_contrib > 0.08f) local_anom_contrib = 0.08f;
    float new_lanom = c.LANOM[i] + local_anom_contrib;
    if (new_lanom < -0.08f) new_lanom = -0.08f;
    else if (new_lanom > 0.08f) new_lanom = 0.08f;
    c.LANOM[i] = new_lanom;
    float temp_final = temp_now + local_anom_contrib;
    if (temp_final < 0.0f) temp_final = 0.0f;
    else if (temp_final > 1.0f) temp_final = 1.0f;
    return temp_final;
}

// 单个 land cell 的 evap 段（与原 scalar 1:1 mirror）。返回 d_evap。
inline float pass_b_land_compute_evap(const PassBCtx &c, int i, float temp_final) {
    const float t_eff = temp_final + c.TTA[i];
    float water_neighbor_w = 0.0f;
    float sum_water_anomaly = 0.0f;
    const int bo = i * 6;
    for (int d = 0; d < 6; ++d) {
        const int32_t ni = c.NB[bo + d];
        if (ni < 0) continue;
        if (c.IW[ni] != 0) {
            water_neighbor_w += 1.0f;
            sum_water_anomaly += c.TTA[ni];
        }
    }
    float avg_water_anomaly = 0.0f;
    if (water_neighbor_w > 0.0f) {
        avg_water_anomaly = sum_water_anomaly / water_neighbor_w;
    }
    float nb_w_norm = water_neighbor_w / 6.0f;
    if (nb_w_norm > 1.0f) nb_w_norm = 1.0f;
    float d_evap = 0.0f;
    if (t_eff > c.t_freeze && nb_w_norm > 0.0f) {
        d_evap = c.evap_gain * (t_eff - c.t_freeze) * nb_w_norm;
        if (c.coupling_gain > 0.0f && std::fabs(avg_water_anomaly) > 0.001f) {
            float evap_mul = 1.0f + c.coupling_gain * avg_water_anomaly;
            if (evap_mul < 0.0f) evap_mul = 0.0f;
            else if (evap_mul > 2.0f) evap_mul = 2.0f;
            d_evap *= evap_mul;
        }
    }
    if (avg_water_anomaly < -0.01f && nb_w_norm > 0.0f && c.coupling_gain > 0.0f) {
        d_evap += -c.evap_gain * (-avg_water_anomaly) * nb_w_norm * c.coupling_gain * 0.5f;
    }
    return d_evap;
}

// 单个 land cell 的 rain-shadow 段（串行 probe，无 SIMD-able 模式）。
inline float pass_b_land_compute_rain_shadow(const PassBCtx &c, int i) {
    if (c.rs_lookback <= 0) return 1.0f;
    const double ny = double(c.LAT[i]);
    double w_dx = 0.0, w_dy = 0.0;
    wind_belt_at(ny, c.season_phase, &w_dx, &w_dy);
    const double wlen2 = w_dx * w_dx + w_dy * w_dy;
    if (wlen2 <= 1e-6) return 1.0f;
    float max_upwind_h = c.ELEV[i];
    int probe_idx = i;
    for (int step = 0; step < c.rs_lookback; ++step) {
        int   best_idx = -1;
        double best_dot = 0.1;
        const float pwx = c.POSX[probe_idx];
        const float pwy = c.POSY[probe_idx];
        const int pbase = probe_idx * 6;
        for (int d3 = 0; d3 < 6; ++d3) {
            const int32_t ni3 = c.NB[pbase + d3];
            if (ni3 < 0) continue;
            const double dx = double(pwx) - double(c.POSX[ni3]);
            const double dy = double(pwy) - double(c.POSY[ni3]);
            const double len2 = dx * dx + dy * dy;
            if (len2 < 1e-6) continue;
            const double inv_len = 1.0 / std::sqrt(len2);
            const double dotv = (dx * w_dx + dy * w_dy) * inv_len;
            if (dotv > best_dot) {
                best_dot = dotv;
                best_idx = ni3;
            }
        }
        if (best_idx < 0) break;
        probe_idx = best_idx;
        if (c.ELEV[probe_idx] > max_upwind_h) {
            max_upwind_h = c.ELEV[probe_idx];
        }
    }
    return (max_upwind_h - c.ELEV[i] >= c.rs_threshold) ? c.rs_factor : 1.0f;
}

// land-only main pass：对 land_idx[begin..end) 逐 cell 跑全部 5 段并写 T/M。
// 抽成 helper 是为了 _thread 变体能按 land_idx 分块复用同一 body。
inline void pass_b_run_land_range(const PassBCtx &c,
                                  const int *land_idx,
                                  int begin, int end) {
    for (int k = begin; k < end; ++k) {
        const int i = land_idx[k];
        const float moisture_now = c.M[i];
        const float temp_final = pass_b_land_compute_temp(c, i);
        const float d_evap = pass_b_land_compute_evap(c, i, temp_final);
        const float d_rs   = pass_b_land_compute_rain_shadow(c, i);
        float moisture_final = (moisture_now + d_evap) * d_rs;
        if (moisture_final < 0.0f) moisture_final = 0.0f;
        else if (moisture_final > 1.0f) moisture_final = 1.0f;
        c.M[i] = moisture_final;
    }
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
    if (sea_ice_albedo_cooling > 0.0f && SIF_PB != nullptr) {
        for (int i = 0; i < n_cells; ++i) {
            if (ctx.IW[i] == 0) continue;
            float water_local = ctx.LANOM[i] - sea_ice_albedo_cooling * SIF_PB[i];
            if (water_local < -0.08f) water_local = -0.08f;
            else if (water_local > 0.08f) water_local = 0.08f;
            ctx.LANOM[i] = water_local;
        }
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
    using godot::WorkerThreadPool;

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
        if (sea_ice_albedo_cooling > 0.0f && SIF_PB != nullptr) {
            for (int i = 0; i < n_cells; ++i) {
                if (ctx.IW[i] == 0) continue;
                float water_local = ctx.LANOM[i] - sea_ice_albedo_cooling * SIF_PB[i];
                if (water_local < -0.08f) water_local = -0.08f;
                else if (water_local > 0.08f) water_local = 0.08f;
                ctx.LANOM[i] = water_local;
            }
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
    // 行为与原手写 PassBLandTask + add_native_group_task 模板严格一致：
    //   - n < 256 || n_tasks == 1 直接 run_range(0, n_land)
    //   - WTP 缺失 in-thread 顺序按 task_idx 跑（保持调度等价）
    //   - 否则 add_native_group_task("pk_pass_b_land") + wait
    pk::parallel_for_range(
        "pk_pass_b_land", n_land, n_tasks, /*seq_threshold=*/256,
        [&](int begin, int end) {
            pass_b_run_land_range(ctx, land_idx.data(), begin, end);
        });

    // [climate-mt 2026-07 bug-parity] 海冰反照率→温度水域尾循环（仅水域，无跨 cell 依赖，
    //   串行即可；与 scalar / _simd lines 2065-2073 逐位等价）。
    if (sea_ice_albedo_cooling > 0.0f && SIF_PB != nullptr) {
        for (int i = 0; i < n_cells; ++i) {
            if (ctx.IW[i] == 0) continue;
            float water_local = ctx.LANOM[i] - sea_ice_albedo_cooling * SIF_PB[i];
            if (water_local < -0.08f) water_local = -0.08f;
            else if (water_local > 0.08f) water_local = 0.08f;
            ctx.LANOM[i] = water_local;
        }
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
            const float dx = c.POSX[ni] - swx;
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

    auto t0 = std::chrono::high_resolution_clock::now();

    // 预筛 water cells：~70% 占比，外层无 if(IW[i]==0) 分支。
    std::vector<int> water_idx;
    water_idx.reserve(static_cast<size_t>(n_cells));
    for (int i = 0; i < n_cells; ++i) {
        if (ctx.IW[i] != 0) water_idx.push_back(i);
    }
    const int n_water = static_cast<int>(water_idx.size());

    ocean_water_run_water_range(ctx, water_idx.data(), 0, n_water);

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

    auto t0 = std::chrono::high_resolution_clock::now();

    std::vector<int> water_idx;
    water_idx.reserve(static_cast<size_t>(n_cells));
    for (int i = 0; i < n_cells; ++i) {
        if (ctx.IW[i] != 0) water_idx.push_back(i);
    }
    const int n_water = static_cast<int>(water_idx.size());

    if (n_tasks <= 0) {
        // 自适应：每 task ~1024 cells，但至少 1，至多 16（保守，charter §C 不动并行总基调）
        n_tasks = std::max(1, std::min(16, (n_water + 1023) / 1024));
    }
    // 小规模降级：~256 阈值与 pass_b 对齐
    if (n_water < 256 || n_tasks == 1) {
        ocean_water_run_water_range(ctx, water_idx.data(), 0, n_water);
        knobs["anomaly_out"] = anomaly_out;
        // A 修复（2026-06）：flush ocean anomaly slot 而非 cell_temp。
        _flush_slot_to_map(sid_oanom);
        auto t1 = std::chrono::high_resolution_clock::now();
        return std::chrono::duration<double, std::milli>(t1 - t0).count();
    }

    // [Phase C.3b] task struct + WTP gate + wait 由 parallel_for_range 统一封装。
    // 注意：上方的 n_water<256 || n_tasks==1 短路保留，因为它在 helper 之外
    //       还要做 knobs["anomaly_out"] 写回 + flush + 计时收尾，行为与原版 1:1。
    pk::parallel_for_range(
        "pk_ocean_water", n_water, n_tasks, /*seq_threshold=*/256,
        [&](int begin, int end) {
            ocean_water_run_water_range(ctx, water_idx.data(), begin, end);
        });

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
        const float dx = swx - c.POSX[ni];
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

    auto t0 = std::chrono::high_resolution_clock::now();

    std::vector<int> land_idx;
    land_idx.reserve(static_cast<size_t>(n_cells));
    for (int i = 0; i < n_cells; ++i) {
        if (ctx.IW[i] == 0) land_idx.push_back(i);
    }
    const int n_land = static_cast<int>(land_idx.size());

    ocean_land_run_land_range(ctx, land_idx.data(), 0, n_land);

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

    auto t0 = std::chrono::high_resolution_clock::now();

    std::vector<int> land_idx;
    land_idx.reserve(static_cast<size_t>(n_cells));
    for (int i = 0; i < n_cells; ++i) {
        if (ctx.IW[i] == 0) land_idx.push_back(i);
    }
    const int n_land = static_cast<int>(land_idx.size());

    if (n_tasks <= 0) {
        n_tasks = std::max(1, std::min(16, (n_land + 1023) / 1024));
    }
    if (n_land < 256 || n_tasks == 1) {
        ocean_land_run_land_range(ctx, land_idx.data(), 0, n_land);
        knobs["anomaly_inout"] = anomaly_inout;
        // A 修复（2026-06）：flush ocean anomaly slot 而非 cell_temp。
        _flush_slot_to_map(sid_oanom);
        auto t1 = std::chrono::high_resolution_clock::now();
        return std::chrono::duration<double, std::milli>(t1 - t0).count();
    }

    // [Phase C.3b] task struct + WTP gate + wait 由 parallel_for_range 统一封装。
    pk::parallel_for_range(
        "pk_ocean_land", n_land, n_tasks, /*seq_threshold=*/256,
        [&](int begin, int end) {
            ocean_land_run_land_range(ctx, land_idx.data(), begin, end);
        });

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
static inline float sea_ice_smoothstep(float edge0, float edge1, float x) {
    const float span = edge1 - edge0;
    if (span == 0.0f) {
        return x < edge0 ? 0.0f : 1.0f;
    }
    float t = (x - edge0) / span;
    if (t < 0.0f) t = 0.0f;
    else if (t > 1.0f) t = 1.0f;
    return t * t * (3.0f - 2.0f * t);
}

static inline float sea_ice_freeze_gate(float insolation_now, float freeze_low, float freeze_high) {
    const float high = std::max(freeze_high, freeze_low + 0.001f);
    const float gate = 1.0f - sea_ice_smoothstep(freeze_low, high, insolation_now);
    if (gate < 0.0f) return 0.0f;
    if (gate > 1.0f) return 1.0f;
    return gate;
}

static inline float sea_ice_solar_melt(float insolation_now, float melt_start, float melt_gain) {
    const float gain = std::max(melt_gain, 0.0f);
    const float excess = insolation_now - melt_start;
    return excess > 0.0f ? gain * excess : 0.0f;
}

static inline float sea_ice_solar_exposure(float sea_ice_frac, float min_thick_ice_exposure = 0.32f) {
    float kMinThickIceExposure = min_thick_ice_exposure;
    if (kMinThickIceExposure < 0.0f) kMinThickIceExposure = 0.0f;
    else if (kMinThickIceExposure > 0.50f) kMinThickIceExposure = 0.50f;
    const float cover = dc_clampf(sea_ice_frac, 0.0f, 1.0f);
    const float shield = sea_ice_smoothstep(0.05f, 0.55f, cover);
    const float exposure = 1.0f - (1.0f - kMinThickIceExposure) * shield;
    return exposure < kMinThickIceExposure ? kMinThickIceExposure : exposure;
}

static inline float sea_ice_positive_tta_residual(float tta, float ocean_thermal_anom) {
    if (tta <= 0.0f) return 0.0f;
    const float realized = ocean_thermal_anom > 0.0f ? ocean_thermal_anom : 0.0f;
    const float residual = tta - realized;
    return residual > 0.0f ? residual : 0.0f;
}

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

    auto t0 = std::chrono::high_resolution_clock::now();

    // ─── Phase A: has_cold_neighbor 快照（前一日 SIF）──────────────────
    // is_water = (terrain == OCEAN || terrain == LAKE || terrain == SEA_ICE)
    // 当前实现按 terrain enum 值判断；GDScript 用 _is_water(cell.terrain)。
    // 为减少 enum 假设，has_cold_neighbor 只检查"邻居 terrain 是 water 且
    // 邻居 SIF >= 0.6"——只关心 SIF 阈值，terrain enum 解析交给 BT/TR 索引。
    //
    // _is_water 在 GDScript 端的语义：terrain ∈ {OCEAN, LAKE, COAST?, SEA_ICE}
    // 这里我们改用 GDScript 写完后的 base_terrain：base in {OCEAN, SEA_ICE}
    // 也算 water；LAKE 单独排除（GDScript Phase B 里会把 LAKE 强制设 0）。
    // 简化：用 prev SIF >= 0.6 做"已结冰邻居" → 满足"邻居 must be water"
    //       的隐含约束（陆地永远 SIF=0，不会满足 0.6 阈值）。
    std::vector<uint8_t> has_cold_neighbor(n_cells, 0);
    std::vector<float> prev_sif(static_cast<size_t>(n_cells), 0.0f);
    for (int i = 0; i < n_cells; ++i) {
        prev_sif[static_cast<size_t>(i)] = SIF[i];
    }

    // is_water 1:1 mirror of map_generator.gd::_is_water:
    //   t ∈ {OCEAN, COAST, LAKE, REEF, KELP, SEA_ICE} → true（6 种）。
    // 用 water_ids_arr 构建的 256-entry LUT 查询，避免硬编码 enum 值且 future-proof。

    for (int i = 0; i < n_cells; ++i) {
        if (!is_water_lut[TR[i]]) continue;
        const int base = i * 6;
        bool any_cold = false;
        for (int d = 0; d < 6; ++d) {
            const int32_t ni = NB[base + d];
            if (ni < 0) continue;
            if (!is_water_lut[TR[ni]]) continue;
            if (prev_sif[static_cast<size_t>(ni)] >= 0.6f) { any_cold = true; break; }
        }
        has_cold_neighbor[i] = any_cold ? 1 : 0;
    }

    // ─── Phase B: 主循环（fraction 增量更新 + flip 候选收集）──────────
    PackedInt32Array  flip_to_ice;
    PackedInt32Array  flip_to_base;
    PackedByteArray   flip_to_base_terrain;
    int water_count   = 0;
    int flipped_count = 0;

    for (int i = 0; i < n_cells; ++i) {
        const uint8_t terr = TR[i];

        // 非 water → 强制 0
        if (!is_water_lut[terr]) {
            SIF[i] = 0.0f;
            continue;
        }
        // LAKE → 强制 0（淡水冻结留给后续 phase；与 GDScript 一致）
        if (int(terr) == id_lake) {
            SIF[i] = 0.0f;
            continue;
        }
        ++water_count;

        // T_eff
        const float temp_now = T[i];
        float t_eff = temp_now;
        if (enable_oht) {
            const float tta_residual = sea_ice_positive_tta_residual(TTA[i], OANOM[i]);
            if (tta_residual > 0.0f) t_eff += ice_delay * tta_residual;
            const float upw = UPW[i];
            if (upw > 0.3f) t_eff -= 0.5f * upw;
        }
        if (t_eff < 0.0f) t_eff = 0.0f;
        else if (t_eff > 1.0f) t_eff = 1.0f;

        // k_freeze 邻居传染
        float k_freeze_eff = k_freeze;
        if (has_cold_neighbor[i]) {
            k_freeze_eff = k_freeze * (1.0f + contagion);
        }

        const float prev_frac = SIF[i];

        // 增量更新
        const float diff_freeze = (t_form > t_eff) ? (t_form - t_eff) : 0.0f;
        const float diff_melt   = (t_eff > t_melt) ? (t_eff - t_melt) : 0.0f;
        float freeze_gate = 1.0f;
        const float insolation_now = solar_gate_enabled ? INS[i] : 0.0f;
        if (solar_gate_enabled) {
            freeze_gate = sea_ice_freeze_gate(insolation_now, freeze_insol_low, freeze_insol_high);
        }
        const float solar_melt_base = solar_gate_enabled
            ? sea_ice_solar_melt(insolation_now, solar_melt_start, solar_melt_gain) : 0.0f;
        const float freeze_term = k_freeze_eff * diff_freeze * freeze_gate;
        // [B2 2026-06-28 子步积分] daily_delta_cap 是"每日"上限。旧实现 d_frac=clamp(rate)*dt_days 单步推进，
        // 加速档(dt_days≫1)下大步长把 melt 过冲 clamp 到 0 → 浪费已累积的冰(0.3 格遇 0.63 融化步丢 0.33
        // "记忆")→极地饱和度随速度档退化(实测 dt=1 最冷桶 0.861,加速档掉到 ~0.42)且单 tick 突变(视觉双稳)。
        // 改为按"每日"子步(各步速率独立 clamp≤cap、各自 clamp[0,1]),使结果与逐日仿真一致、与速度档无关。
        // dt_days=1 时 n_sub=1 → 与旧实现逐位等价(无回归)。solar_exposure 随 frac 逐步重算(厚冰遮蔽随消融变)。
        int n_sub = int(dt_days);
        if (float(n_sub) < dt_days) ++n_sub;   // ceil
        if (n_sub < 1) n_sub = 1;
        else if (n_sub > 30) n_sub = 30;
        const float sub_dt = dt_days / float(n_sub);
        float new_frac = prev_frac;
        for (int sub = 0; sub < n_sub; ++sub) {
            const float solar_melt_s = solar_gate_enabled
                ? solar_melt_base * sea_ice_solar_exposure(new_frac, min_thick_ice_solar_exposure)
                : 0.0f;
            float rate = freeze_term - (k_melt * diff_melt + solar_melt_s);
            if (daily_delta_cap > 0.0f) {
                if (rate > daily_delta_cap) rate = daily_delta_cap;
                else if (rate < -daily_delta_cap) rate = -daily_delta_cap;
            }
            new_frac += rate * sub_dt;
            if (new_frac <= 0.0f) { new_frac = 0.0f; if (rate < 0.0f) break; }
            else if (new_frac >= 1.0f) { new_frac = 1.0f; if (rate > 0.0f) break; }
        }
        if (edge_mix_rate > 0.0f) {
            float sum_nb_frac = 0.0f;
            int nb_water_count = 0;
            const int base = i * 6;
            for (int d = 0; d < 6; ++d) {
                const int32_t ni = NB[base + d];
                if (ni < 0 || !is_water_lut[TR[ni]] || int(TR[ni]) == id_lake) continue;
                sum_nb_frac += prev_sif[static_cast<size_t>(ni)];
                ++nb_water_count;
            }
            if (nb_water_count > 0) {
                const float avg_nb_frac = sum_nb_frac / float(nb_water_count);
                const float contrast = std::abs(avg_nb_frac - new_frac);
                if (contrast > 0.05f && (prev_frac > 0.001f || avg_nb_frac > 0.001f)) {
                    const float mix = std::min(0.12f, edge_mix_rate * std::max(1.0f, dt_days));
                    new_frac += (avg_nb_frac - new_frac) * mix;
                    if (new_frac < 0.0f) new_frac = 0.0f;
                    else if (new_frac > 1.0f) new_frac = 1.0f;
                }
            }
        }
        SIF[i] = new_frac;

        // 翻转候选收集（带迟滞）
        const bool was_ice = (int(terr) == id_sea_ice);
        if (!was_ice && new_frac >= threshold) {
            flip_to_ice.append(i);
            ++flipped_count;
        } else if (was_ice && new_frac < (threshold - hysteresis)) {
            const int base_t_int = int(BT[i]);
            int target_terr = base_t_int;
            if (base_t_int == id_sea_ice) target_terr = id_ocean;
            flip_to_base.append(i);
            flip_to_base_terrain.append(uint8_t(target_terr & 0xFF));
            ++flipped_count;
        }
    }

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
    const float   * const __restrict T    = cell_temp_arr.ptr();
    float         * const __restrict SIF  = s_sea_ice.arr_f32.ptrw();
    const int32_t * const __restrict NB   = nb_arr.ptr();
    const uint8_t * const __restrict BT   = base_terr_arr.ptr();
    const float   * const __restrict TTA  = tta_arr.ptr();
    const float   * const __restrict OANOM = s_oanom.arr_f32.ptr();
    const float   * const __restrict UPW  = upw_arr.ptr();
    const float   * const __restrict INS  = insol_arr.ptr();

    auto t0 = std::chrono::high_resolution_clock::now();

    // ─── Phase A: cold_neighbor 快照（cell-local，纯并行） ──────────────
    std::vector<uint8_t> has_cold_neighbor(n_cells, 0);
    std::vector<float> prev_sif(static_cast<size_t>(n_cells), 0.0f);
    for (int i = 0; i < n_cells; ++i) {
        prev_sif[static_cast<size_t>(i)] = SIF[i];
    }
    {
        uint8_t * const HCN = has_cold_neighbor.data();
        const float * const PSIF = prev_sif.data();
        auto run_a = [&](int begin, int end) {
            for (int i = begin; i < end; ++i) {
                if (!is_water_lut[TR[i]]) { HCN[i] = 0; continue; }
                const int base = i * 6;
                bool any_cold = false;
                for (int d = 0; d < 6; ++d) {
                    const int32_t ni = NB[base + d];
                    if (ni < 0) continue;
                    if (!is_water_lut[TR[ni]]) continue;
                    if (PSIF[ni] >= 0.6f) { any_cold = true; break; }
                }
                HCN[i] = any_cold ? 1 : 0;
            }
        };
        pk::parallel_for_range("pk_sea_ice_phaseA", n_cells, n_tasks, 256, run_a);
    }

    // ─── Phase B: 主循环 + emit (flip lists + counters) ─────────────────
    struct SeaIceEmit {
        std::vector<int32_t> flip_to_ice;
        std::vector<int32_t> flip_to_base;
        std::vector<uint8_t> flip_to_base_terrain;
        int water_count   = 0;
        int flipped_count = 0;

        void merge_into(SeaIceEmit &dst) const {
            // 串行追加 → 与 scalar 升序 1:1
            dst.flip_to_ice.insert(dst.flip_to_ice.end(),
                                   flip_to_ice.begin(), flip_to_ice.end());
            dst.flip_to_base.insert(dst.flip_to_base.end(),
                                    flip_to_base.begin(), flip_to_base.end());
            dst.flip_to_base_terrain.insert(dst.flip_to_base_terrain.end(),
                                            flip_to_base_terrain.begin(),
                                            flip_to_base_terrain.end());
            dst.water_count   += water_count;
            dst.flipped_count += flipped_count;
        }
    };

    SeaIceEmit global_emit;
    {
        const uint8_t * const HCN = has_cold_neighbor.data();
        const float * const PSIF = prev_sif.data();
        auto run_b = [&](int begin, int end, SeaIceEmit &local) {
            for (int i = begin; i < end; ++i) {
                const uint8_t terr = TR[i];

                if (!is_water_lut[terr]) {
                    SIF[i] = 0.0f;
                    continue;
                }
                if (int(terr) == id_lake) {
                    SIF[i] = 0.0f;
                    continue;
                }
                ++local.water_count;

                const float temp_now = T[i];
                float t_eff = temp_now;
                if (enable_oht) {
                    const float tta_residual = sea_ice_positive_tta_residual(TTA[i], OANOM[i]);
                    if (tta_residual > 0.0f) t_eff += ice_delay * tta_residual;
                    const float upw = UPW[i];
                    if (upw > 0.3f) t_eff -= 0.5f * upw;
                }
                if (t_eff < 0.0f) t_eff = 0.0f;
                else if (t_eff > 1.0f) t_eff = 1.0f;

                float k_freeze_eff = k_freeze;
                if (HCN[i]) {
                    k_freeze_eff = k_freeze * (1.0f + contagion);
                }

                const float prev_frac = PSIF[i];

                const float diff_freeze = (t_form > t_eff) ? (t_form - t_eff) : 0.0f;
                const float diff_melt   = (t_eff > t_melt) ? (t_eff - t_melt) : 0.0f;
                float freeze_gate = 1.0f;
                float solar_melt = 0.0f;
                if (solar_gate_enabled) {
                    const float insolation_now = INS[i];
                    freeze_gate = sea_ice_freeze_gate(insolation_now, freeze_insol_low, freeze_insol_high);
                    solar_melt = sea_ice_solar_melt(insolation_now, solar_melt_start, solar_melt_gain)
                        * sea_ice_solar_exposure(prev_frac, min_thick_ice_solar_exposure);
                }
                // [S2 fix 2026-05-23] 乘 dt_days：与 scalar 路径 1:1。
                // [seaice dt 修复 2026-06-16] 见 scalar 路径注释：先裁剪日速率再乘 dt_days。
                float rate = k_freeze_eff * diff_freeze * freeze_gate
                           - (k_melt * diff_melt + solar_melt);
                if (daily_delta_cap > 0.0f) {
                    if (rate > daily_delta_cap) rate = daily_delta_cap;
                    else if (rate < -daily_delta_cap) rate = -daily_delta_cap;
                }
                float d_frac = rate * dt_days;
                float new_frac = prev_frac + d_frac;
                if (new_frac < 0.0f) new_frac = 0.0f;
                else if (new_frac > 1.0f) new_frac = 1.0f;
                if (edge_mix_rate > 0.0f) {
                    float sum_nb_frac = 0.0f;
                    int nb_water_count = 0;
                    const int base = i * 6;
                    for (int d = 0; d < 6; ++d) {
                        const int32_t ni = NB[base + d];
                        if (ni < 0 || !is_water_lut[TR[ni]] || int(TR[ni]) == id_lake) continue;
                        sum_nb_frac += PSIF[ni];
                        ++nb_water_count;
                    }
                    if (nb_water_count > 0) {
                        const float avg_nb_frac = sum_nb_frac / float(nb_water_count);
                        const float contrast = std::abs(avg_nb_frac - new_frac);
                        if (contrast > 0.05f && (prev_frac > 0.001f || avg_nb_frac > 0.001f)) {
                            const float mix = std::min(0.12f, edge_mix_rate * std::max(1.0f, dt_days));
                            new_frac += (avg_nb_frac - new_frac) * mix;
                            if (new_frac < 0.0f) new_frac = 0.0f;
                            else if (new_frac > 1.0f) new_frac = 1.0f;
                        }
                    }
                }
                SIF[i] = new_frac;

                const bool was_ice = (int(terr) == id_sea_ice);
                if (!was_ice && new_frac >= threshold) {
                    local.flip_to_ice.push_back(i);
                    ++local.flipped_count;
                } else if (was_ice && new_frac < (threshold - hysteresis)) {
                    const int base_t_int = int(BT[i]);
                    int target_terr = base_t_int;
                    if (base_t_int == id_sea_ice) target_terr = id_ocean;
                    local.flip_to_base.push_back(i);
                    local.flip_to_base_terrain.push_back(uint8_t(target_terr & 0xFF));
                    ++local.flipped_count;
                }
            }
        };
        pk::parallel_for_range_with_emit<SeaIceEmit>(
            "pk_sea_ice_phaseB", n_cells, n_tasks, 256, global_emit, run_b);
    }

    _flush_slot_to_map(sid_sea_ice);

    // 把 SeaIceEmit 转回 PackedArray（与 scalar 等价）
    PackedInt32Array flip_to_ice;
    PackedInt32Array flip_to_base;
    PackedByteArray  flip_to_base_terrain;
    {
        const int n_a = int(global_emit.flip_to_ice.size());
        const int n_b = int(global_emit.flip_to_base.size());
        flip_to_ice.resize(n_a);
        flip_to_base.resize(n_b);
        flip_to_base_terrain.resize(n_b);
        if (n_a > 0) {
            std::memcpy(flip_to_ice.ptrw(), global_emit.flip_to_ice.data(),
                        n_a * sizeof(int32_t));
        }
        if (n_b > 0) {
            std::memcpy(flip_to_base.ptrw(), global_emit.flip_to_base.data(),
                        n_b * sizeof(int32_t));
            std::memcpy(flip_to_base_terrain.ptrw(),
                        global_emit.flip_to_base_terrain.data(),
                        n_b * sizeof(uint8_t));
        }
    }

    knobs["flip_to_ice_list"]     = flip_to_ice;
    knobs["flip_to_base_list"]    = flip_to_base;
    knobs["flip_to_base_terrain"] = flip_to_base_terrain;
    knobs["stat_water_count"]     = global_emit.water_count;
    knobs["stat_flipped_count"]   = global_emit.flipped_count;

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

    const uint8_t * const __restrict LF   = s_landform.arr_u8.ptr();
    const uint8_t * const __restrict VEG  = s_veg.arr_u8.ptr();
    float         * const __restrict M    = s_moist.arr_f32.ptrw();
    const int32_t * const __restrict NB   = nb_arr.ptr();
    const float   * const __restrict DON  = donor_arr.ptr();

    auto t0 = std::chrono::high_resolution_clock::now();

    // ─── Phase 1: compute deltas (scratch buffer, NOT a slot) ───────────
    // Stack vector keeps allocation off the heap for the whole pass.
    std::vector<float> deltas(n_cells, 0.0f);
    float * const __restrict D = deltas.data();

    for (int i = 0; i < n_cells; ++i) {
        // Skip water cells (LandformType.is_water): LF.{DEEP_OCEAN..LAKE} = 0..3
        if (LF[i] <= 3) continue;
        const uint8_t veg_id = VEG[i];
        if (veg_id >= donor_size) continue; // safety
        const float trans = DON[veg_id];
        if (trans < 0.01f) continue;
        const float moist = M[i];
        const float output      = trans * moist;
        const float self_share = output * self_rate;

        const int base = i * 6;
        int valid_land_neighbors = 0;
        for (int d = 0; d < 6; ++d) {
            const int32_t nb_idx = NB[base + d];
            if (nb_idx < 0) continue;
            // Skip water neighbours (mirror of GDScript "海面邻居不接受陆地蒸腾外溢")
            if (LF[nb_idx] <= 3) continue;
            ++valid_land_neighbors;
        }
        const float transported = valid_land_neighbors > 0 ? output * outflow_rate : 0.0f;
        D[i] += self_share - transported;
        const float nb_share = valid_land_neighbors > 0
            ? transported / float(valid_land_neighbors) : 0.0f;
        for (int d = 0; d < 6; ++d) {
            const int32_t nb_idx = NB[base + d];
            if (nb_idx < 0 || LF[nb_idx] <= 3) continue;
            D[nb_idx] += nb_share;
        }
    }
    auto t_compute = std::chrono::high_resolution_clock::now();

    // ─── Phase 2: apply deltas (clamp to [0,1]) ─────────────────────────
    PackedInt32Array dirty_indices;
    PackedFloat32Array dirty_values;
    dirty_indices.resize(n_cells);
    dirty_values.resize(n_cells);
    int dirty_count = 0;
    for (int i = 0; i < n_cells; ++i) {
        const float d = D[i];
        if (d == 0.0f) continue;
        float v = M[i] + d;
        if (v < 0.0f) v = 0.0f;
        else if (v > 1.0f) v = 1.0f;
        if (M[i] != v) {
            M[i] = v;
            dirty_indices.set(dirty_count, i);
            dirty_values.set(dirty_count, v);
            ++dirty_count;
        }
    }
    dirty_indices.resize(dirty_count);
    dirty_values.resize(dirty_count);
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
    const int sid_vital = component_id(StringName("cell_vegetation_vitality"));
    const int sid_q = component_id(StringName("cell_river_discharge"));
    const int sid_q30 = component_id(StringName("cell_river_discharge_30d"));
    const int sid_storage = component_id(StringName("cell_river_storage"));
    const int sid_gw = component_id(StringName("cell_groundwater_storage"));
    const int sid_runoff = component_id(StringName("cell_surface_runoff"));

    const int required[] = {
        sid_hparent, sid_has_riv, sid_terrain, sid_landform, sid_elev, sid_veg, sid_cover,
        sid_precip, sid_intensity, sid_wtype, sid_temp, sid_heat, sid_snowpack, sid_moist,
        sid_base_m, sid_soil, sid_wb30, sid_vital, sid_q, sid_q30, sid_storage, sid_gw, sid_runoff
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
        !slot_ok_f32(sid_soil) || !slot_ok_f32(sid_wb30) || !slot_ok_f32(sid_vital) ||
        !slot_ok_f32(sid_q) || !slot_ok_f32(sid_q30) || !slot_ok_f32(sid_storage) ||
        !slot_ok_f32(sid_gw) || !slot_ok_f32(sid_runoff)) {
        return fail("slot_size_mismatch");
    }

    const float precip_scale = knobs.has("hydro_precip_scale") ? float(knobs["hydro_precip_scale"]) : 1.0f;
    const float snowmelt_scale = knobs.has("hydro_snowmelt_scale") ? float(knobs["hydro_snowmelt_scale"]) : 0.55f;
    const float soil_capacity = knobs.has("hydro_soil_capacity") ? std::max(0.05f, float(knobs["hydro_soil_capacity"])) : 0.75f;
    const float infiltration_rate = knobs.has("hydro_infiltration_rate") ? dc_clampf(float(knobs["hydro_infiltration_rate"]), 0.0f, 1.0f) : 0.52f;
    const float quickflow_fraction = knobs.has("hydro_quickflow_fraction") ? dc_clampf(float(knobs["hydro_quickflow_fraction"]), 0.0f, 1.0f) : 0.36f;
    const float baseflow_recession = knobs.has("hydro_baseflow_recession") ? dc_clampf(float(knobs["hydro_baseflow_recession"]), 0.0f, 1.0f) : 0.035f;
    const float channel_release = knobs.has("hydro_channel_release_rate") ? dc_clampf(float(knobs["hydro_channel_release_rate"]), 0.01f, 1.0f) : 0.62f;
    const float lake_release = knobs.has("hydro_lake_release_rate") ? dc_clampf(float(knobs["hydro_lake_release_rate"]), 0.005f, 1.0f) : 0.18f;
    const float discharge_ema = knobs.has("hydro_discharge_ema") ? dc_clampf(float(knobs["hydro_discharge_ema"]), 0.01f, 1.0f) : 0.08f;
    const float bank_moisture_gain = knobs.has("hydro_bank_moisture_gain") ? dc_clampf(float(knobs["hydro_bank_moisture_gain"]), 0.0f, 0.25f) : 0.035f;
    const float flood_threshold = knobs.has("hydro_flood_threshold") ? std::max(0.01f, float(knobs["hydro_flood_threshold"])) : 2.2f;
    const float snowpack_melt_temp_gain = knobs.has("snowpack_melt_temp_gain") ? float(knobs["snowpack_melt_temp_gain"]) : 0.22f;
    const float snowpack_melt_sun_gain = knobs.has("snowpack_melt_sun_gain") ? float(knobs["snowpack_melt_sun_gain"]) : 0.12f;
    const float dt_days = knobs.has("dt_days") ? dc_clampf(float(knobs["dt_days"]), 1.0f, 30.0f) : 1.0f;
    const float baseflow_recession_eff = 1.0f - std::pow(1.0f - baseflow_recession, dt_days);
    const float discharge_ema_eff = 1.0f - std::pow(1.0f - discharge_ema, dt_days);
    const float nonriver_discharge_decay = std::pow(1.0f - discharge_ema * 0.5f, dt_days);
    const float soil_decay_eff = std::pow(0.985f, dt_days);
    const float water_balance_ema_eff = 1.0f - std::pow(1.0f - (1.0f / 30.0f), dt_days);
    PackedInt32Array neighbor_indices;
    if (knobs.has("neighbor_indices")) {
        neighbor_indices = knobs["neighbor_indices"];
    }
    const bool has_neighbor_indices = neighbor_indices.size() >= n_cells * 6;
    const int32_t * const NB = has_neighbor_indices ? neighbor_indices.ptr() : nullptr;

    const int32_t * const __restrict HP = _slots.write[sid_hparent].arr_i32.ptr();
    const uint8_t * const __restrict HAS_RIV = _slots.write[sid_has_riv].arr_u8.ptr();
    const uint8_t * const __restrict TERR = _slots.write[sid_terrain].arr_u8.ptr();
    const uint8_t * const __restrict LF = _slots.write[sid_landform].arr_u8.ptr();
    const uint8_t * const __restrict VEG = _slots.write[sid_veg].arr_u8.ptr();
    const uint8_t * const __restrict COV = _slots.write[sid_cover].arr_u8.ptr();
    const float * const __restrict ELEV = _slots.write[sid_elev].arr_f32.ptr();
    const float * const __restrict PREC = _slots.write[sid_precip].arr_f32.ptr();
    const float * const __restrict INTEN = _slots.write[sid_intensity].arr_f32.ptr();
    const uint8_t * const __restrict WTYPE = _slots.write[sid_wtype].arr_u8.ptr();
    const float * const __restrict TEMP = _slots.write[sid_temp].arr_f32.ptr();
    const float * const __restrict HEAT = _slots.write[sid_heat].arr_f32.ptr();
    const float * const __restrict SNOWP = _slots.write[sid_snowpack].arr_f32.ptr();
    const float * const __restrict MOIST = _slots.write[sid_moist].arr_f32.ptr();
    const float * const __restrict BASE_M = _slots.write[sid_base_m].arr_f32.ptr();
    float * const __restrict SOIL = _slots.write[sid_soil].arr_f32.ptrw();
    float * const __restrict WB30 = _slots.write[sid_wb30].arr_f32.ptrw();
    const float * const __restrict VITAL = _slots.write[sid_vital].arr_f32.ptr();
    float * const __restrict Q = _slots.write[sid_q].arr_f32.ptrw();
    float * const __restrict Q30 = _slots.write[sid_q30].arr_f32.ptrw();
    float * const __restrict STORAGE = _slots.write[sid_storage].arr_f32.ptrw();
    float * const __restrict GW = _slots.write[sid_gw].arr_f32.ptrw();
    float * const __restrict RUNOFF = _slots.write[sid_runoff].arr_f32.ptrw();

    const auto tc0 = std::chrono::high_resolution_clock::now();
    std::vector<int32_t> child_count(size_t(n_cells), 0);
    std::vector<float> incoming(size_t(n_cells), 0.0f);
    std::vector<int32_t> queue;
    queue.reserve(size_t(n_cells));
    double water_in_total = 0.0;
    double outlet_total = 0.0;
    int runoff_source_cells = 0;
    int river_cells_processed = 0;
    int riparian_neighbor_touches = 0;
    int flood_candidate_count = 0;

    for (int i = 0; i < n_cells; ++i) {
        const int32_t p = HP[i];
        if (p >= 0 && p < n_cells && p != i) child_count[size_t(p)] += 1;
    }

    for (int i = 0; i < n_cells; ++i) {
        const bool is_water = wf_is_water_terrain(TERR[i]) || LF[i] <= 3;
        const uint8_t wt = WTYPE[i];
        const float hydro_precip = wf_is_precip_weather_type(wt) ? PREC[i] : 0.0f;
        const float wet_event = ((wt == 2 || wt == 3 || wt == 7) ? 0.12f : 0.0f) * INTEN[i];
        const float precip_daily = std::max(0.0f, hydro_precip + wet_event) * precip_scale;
        const float melt_potential = std::max(0.0f, TEMP[i] - 0.24f) * snowpack_melt_temp_gain
            + std::max(0.0f, HEAT[i]) * snowpack_melt_sun_gain;
        const float snowmelt = std::min(std::max(0.0f, SNOWP[i]), melt_potential * dt_days) * snowmelt_scale;
        const float water_in = precip_daily * dt_days + snowmelt;
        water_in_total += double(water_in);

        const float wetness = dc_clampf((SOIL[i] + 0.5f) * 0.55f + BASE_M[i] * 0.25f + MOIST[i] * 0.20f, 0.0f, 1.0f);
        const float veg_absorb = (VEG[i] == 0 ? 0.0f : dc_clampf(VITAL[i], 0.0f, 1.0f)) * 0.14f;
        const float cover_runoff = (COV[i] == 1 || COV[i] == 2) ? 0.18f : ((COV[i] == 3) ? 0.10f : 0.0f);
        const float relief_runoff = dc_clampf((ELEV[i] - 0.55f) * 0.20f, 0.0f, 0.16f);
        const float saturation = dc_clampf((wetness - soil_capacity) / std::max(0.001f, 1.0f - soil_capacity), 0.0f, 1.0f);
        float runoff_coeff = quickflow_fraction + wetness * 0.32f + saturation * 0.35f + cover_runoff + relief_runoff - veg_absorb;
        runoff_coeff = is_water ? 1.0f : dc_clampf(runoff_coeff, 0.04f, 0.96f);
        const float quick_runoff = water_in * runoff_coeff;
        const float infiltration = is_water ? 0.0f : water_in * (1.0f - runoff_coeff) * infiltration_rate;

        GW[i] = std::max(0.0f, GW[i] + infiltration * 0.55f);
        const float baseflow = GW[i] * baseflow_recession_eff;
        GW[i] = std::max(0.0f, GW[i] - baseflow);
        const float local_runoff = quick_runoff + baseflow;
        RUNOFF[i] = local_runoff;
        incoming[size_t(i)] += local_runoff;
        if (local_runoff > 0.0001f) ++runoff_source_cells;

        const float daily_balance = dc_clampf(
            (water_in - quick_runoff - infiltration * 0.35f) / dt_days, -1.0f, 1.0f);
        SOIL[i] = dc_clampf(SOIL[i] * soil_decay_eff + infiltration * 0.16f - quick_runoff * 0.025f, -0.5f, 0.5f);
        WB30[i] = WB30[i] + (daily_balance - WB30[i]) * water_balance_ema_eff;

        if (child_count[size_t(i)] == 0) queue.push_back(i);
    }

    for (size_t qh = 0; qh < queue.size(); ++qh) {
        const int i = queue[qh];
        const bool is_channel = HAS_RIV[i] != 0 || wf_is_water_terrain(TERR[i]) || LF[i] <= 3;
        const bool is_lake = wf_is_water_terrain(TERR[i]) && TERR[i] != 0;
        float outflow = incoming[size_t(i)];
        if (is_channel) {
            const float release_daily = is_lake ? lake_release : channel_release;
            const float release = 1.0f - std::pow(1.0f - release_daily, dt_days);
            STORAGE[i] = std::max(0.0f, STORAGE[i] + incoming[size_t(i)]);
            outflow = STORAGE[i] * release;
            STORAGE[i] = std::max(0.0f, STORAGE[i] - outflow);
            ++river_cells_processed;
        } else {
            STORAGE[i] = 0.0f;
        }
        Q[i] = (HAS_RIV[i] != 0 || wf_is_water_terrain(TERR[i])) ? outflow : 0.0f;
        const int32_t p = HP[i];
        if (p >= 0 && p < n_cells && p != i) {
            incoming[size_t(p)] += outflow;
            child_count[size_t(p)] -= 1;
            if (child_count[size_t(p)] == 0) queue.push_back(p);
        } else {
            outlet_total += double(outflow);
        }
    }

    for (int i = 0; i < n_cells; ++i) {
        if (child_count[size_t(i)] <= 0) continue;
        const int32_t p = HP[i];
        if (p >= 0 && p < n_cells && p != i) incoming[size_t(p)] += incoming[size_t(i)];
        else outlet_total += double(incoming[size_t(i)]);
    }

    float q_max = 0.0f;
    std::vector<float> river_q;
    river_q.reserve(size_t(n_cells));
    for (int i = 0; i < n_cells; ++i) {
        if (HAS_RIV[i] == 0 && !wf_is_water_terrain(TERR[i])) {
            Q[i] = 0.0f;
            Q30[i] = std::max(0.0f, Q30[i] * nonriver_discharge_decay);
            continue;
        }
        q_max = std::max(q_max, Q[i]);
        river_q.push_back(Q[i]);
    }
    const float denom = std::log1p(std::max(q_max, 0.001f));
    for (int i = 0; i < n_cells; ++i) {
        if (HAS_RIV[i] == 0 && !wf_is_water_terrain(TERR[i])) continue;
        const float q_norm = dc_clampf(std::log1p(std::max(0.0f, Q[i])) / denom, 0.0f, 1.0f);
        Q30[i] = dc_clampf(Q30[i] + (q_norm - Q30[i]) * discharge_ema_eff, 0.0f, 1.0f);
        if (HAS_RIV[i] != 0 && Q30[i] > flood_threshold) ++flood_candidate_count;
        if (HAS_RIV[i] != 0) {
            const float bank_gain = Q30[i] * bank_moisture_gain;
            SOIL[i] = dc_clampf(SOIL[i] + bank_gain, -0.5f, 0.5f);
            WB30[i] = dc_clampf(WB30[i] + bank_gain * 0.5f, -1.0f, 1.0f);
            if (NB != nullptr && bank_gain > 0.0f) {
                const float neighbor_gain = bank_gain * 0.45f;
                const int nb_base = i * 6;
                for (int d = 0; d < 6; ++d) {
                    const int ni = NB[nb_base + d];
                    if (ni < 0 || ni >= n_cells || ni == i) continue;
                    const bool nb_is_water = wf_is_water_terrain(TERR[ni]) || LF[ni] <= 3;
                    if (nb_is_water || HAS_RIV[ni] != 0) continue;
                    SOIL[ni] = dc_clampf(SOIL[ni] + neighbor_gain, -0.5f, 0.5f);
                    WB30[ni] = dc_clampf(WB30[ni] + neighbor_gain * 0.5f, -1.0f, 1.0f);
                    ++riparian_neighbor_touches;
                }
            }
        }
    }
    std::sort(river_q.begin(), river_q.end());
    const float q_p95 = river_q.empty() ? 0.0f : river_q[size_t(std::min<int>(int(river_q.size()) - 1, int(std::floor(double(river_q.size() - 1) * 0.95))))];

    const auto tc1 = std::chrono::high_resolution_clock::now();
    const auto tf0 = std::chrono::high_resolution_clock::now();
    _flush_slot_to_map(sid_q);
    _flush_slot_to_map(sid_q30);
    _flush_slot_to_map(sid_storage);
    _flush_slot_to_map(sid_gw);
    _flush_slot_to_map(sid_runoff);
    _flush_slot_to_map(sid_soil);
    _flush_slot_to_map(sid_wb30);
    const auto tf1 = std::chrono::high_resolution_clock::now();
    const auto t1 = std::chrono::high_resolution_clock::now();

    const double compute_ms = std::chrono::duration<double, std::milli>(tc1 - tc0).count();
    const double flush_ms = std::chrono::duration<double, std::milli>(tf1 - tf0).count();
    const double native_ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
    out["done"] = true;
    out["path"] = "gdext";
    out["fallback_reason"] = "";
    out["published_to_slot"] = true;
    out["native_ms"] = native_ms;
    out["compute_ms"] = compute_ms;
    out["kernel_ms"] = compute_ms;
    out["flush_ms"] = flush_ms;
    out["n_cells"] = n_cells;
    out["processed_cells"] = n_cells;
    out["dt_days"] = dt_days;
    out["runoff_source_cells"] = runoff_source_cells;
    out["river_cells_processed"] = river_cells_processed;
    out["riparian_neighbor_touches"] = riparian_neighbor_touches;
    out["water_budget_error"] = water_in_total > 0.000001 ? std::abs(water_in_total - outlet_total) / water_in_total : 0.0;
    out["river_discharge_p95"] = q_p95;
    out["river_discharge_max"] = q_max;
    out["flood_candidate_count"] = flood_candidate_count;
    out["flood_count"] = flood_candidate_count;
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
    // [Phase C.3c] 主循环抽成 lambda，scalar 路径直接 run_range(0,n_cells)，
    // _thread 变体复用同一 lambda 走 pk::parallel_for_range。
    auto run_range = [&](int begin, int end) {
        for (int i = begin; i < end; ++i) {
            if (IW[i] != 0) continue;                           // skip water cells
            const uint8_t veg_id = VG[i];
            float alb = (veg_id < albedo_size) ? ALB[veg_id] : 0.0f;
            const uint8_t cover_id = CV[i];
            if (cover_id == cover_snow_id || cover_id == cover_glacier_id) {
                if (alb < snow_cover_albedo) alb = snow_cover_albedo;
            }
            const float dt = (reference_albedo - alb) * albedo_temp_gain;
            float v = T[i] + dt;
            if (v < 0.0f) v = 0.0f;
            else if (v > 1.0f) v = 1.0f;
            T[i] = v;
        }
    };
    run_range(0, n_cells);

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
    using godot::StringName;
    using godot::PackedFloat32Array;

    auto diag = [&](const char *why) {
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_albedo_pass_thread: ", why,
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

    // ─── Main loop（与 run_albedo_pass 主循环 1:1） ──────────────────────
    auto run_range = [&](int begin, int end) {
        for (int i = begin; i < end; ++i) {
            if (IW[i] != 0) continue;
            const uint8_t veg_id = VG[i];
            float alb = (veg_id < albedo_size) ? ALB[veg_id] : 0.0f;
            const uint8_t cover_id = CV[i];
            if (cover_id == cover_snow_id || cover_id == cover_glacier_id) {
                if (alb < snow_cover_albedo) alb = snow_cover_albedo;
            }
            const float dt = (reference_albedo - alb) * albedo_temp_gain;
            float v = T[i] + dt;
            if (v < 0.0f) v = 0.0f;
            else if (v > 1.0f) v = 1.0f;
            T[i] = v;
        }
    };

    pk::parallel_for_range("pk_albedo", n_cells, n_tasks, /*seq_threshold=*/256, run_range);

    // §11.2 flush
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

static inline float vegdyn_clamp01(float v) {
    if (v < 0.0f) return 0.0f;
    if (v > 1.0f) return 1.0f;
    return v;
}

static inline float vegdyn_plant_water(
        float moisture,
        float water_balance_30d,
        float soil_moisture,
        float water_balance_weight,
        float soil_buffer_weight,
        float drought_penalty) {
    const float wb_pos = water_balance_30d > 0.0f ? water_balance_30d : 0.0f;
    const float wb_neg = water_balance_30d < 0.0f ? water_balance_30d : 0.0f;
    const float soil_pos = soil_moisture > 0.0f ? soil_moisture : 0.0f;
    return vegdyn_clamp01(
        moisture
        + wb_pos * water_balance_weight
        + soil_pos * soil_buffer_weight
        + wb_neg * drought_penalty);
}

static inline float vegdyn_compat_of(
        int vg,
        float temp,
        float plant_water,
        int n_veg,
        const float *IDT,
        const float *IDM,
        const float *TLT,
        const float *TLM) {
    if (vg < 0 || vg >= n_veg) return -1.0f;
    const float tt = TLT[vg] < 0.01f ? 0.01f : TLT[vg];
    const float tm = TLM[vg] < 0.01f ? 0.01f : TLM[vg];
    const float dt = (temp - IDT[vg]) / tt;
    const float dm = (plant_water - IDM[vg]) / tm;
    return std::exp(-0.5f * (dt * dt + dm * dm));
}

static inline uint8_t vegdyn_best_transition(
        uint8_t current,
        float temp,
        float plant_water,
        int n_veg,
        const float *IDT,
        const float *IDM,
        const float *TLT,
        const float *TLM,
        const uint8_t *NXU,
        const uint8_t *NXD,
        float &best_score) {
    uint8_t best = current;
    best_score = -1.0f;
    if (current >= n_veg) return best;
    const uint8_t down = NXD[current];
    const uint8_t up = NXU[current];
    if (down != current) {
        best = down;
        best_score = vegdyn_compat_of(down, temp, plant_water, n_veg, IDT, IDM, TLT, TLM);
    }
    if (up != current) {
        const float score = vegdyn_compat_of(up, temp, plant_water, n_veg, IDT, IDM, TLT, TLM);
        if (score > best_score) {
            best = up;
            best_score = score;
        }
    }
    return best;
}

static inline float vegdyn_weather_stress(
        uint8_t v_id,
        int wt,
        float wi,
        int n_veg,
        int n_wt,
        int wt_pen_size,
        const float *WPN,
        const float *RES,
        float weather_penalty_scale) {
    const float base_pen = (wt >= 0 && wt < wt_pen_size) ? WPN[wt] : 0.0f;
    float resist = 0.0f;
    if (v_id < n_veg && wt >= 0 && wt < n_wt) {
        resist = RES[int(v_id) * n_wt + wt];
    }
    return base_pen * weather_penalty_scale * (wi > 0.0f ? wi : 0.0f) * (1.0f - resist);
}

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
    const int sid_veg      = component_id(StringName("cell_vegetation"));
    const int sid_temp     = component_id(StringName("cell_temp"));
    const int sid_temp_30d = component_id(StringName("cell_temp_30d"));
    const int sid_moist    = component_id(StringName("cell_moisture"));
    const int sid_water_bal = component_id(StringName("cell_water_balance_30d"));
    const int sid_soil     = component_id(StringName("cell_soil_moisture"));
    const int sid_vgp      = component_id(StringName("cell_vegetation_growth_pressure"));
    const int sid_wt_type  = component_id(StringName("cell_weather_type"));
    const int sid_wt_int   = component_id(StringName("cell_weather_intensity"));
    const int sid_wt_init  = component_id(StringName("cell_weather_field_init"));
    if (sid_iswater < 0 || sid_veg < 0 || sid_temp < 0 || sid_temp_30d < 0 ||
        sid_moist < 0 || sid_water_bal < 0 || sid_soil < 0 || sid_vgp < 0 ||
        sid_wt_type < 0 || sid_wt_int < 0 || sid_wt_init < 0) {
        diag("missing slot id (cell_is_water/vegetation/temp/moisture/weather_type/weather_intensity/weather_field_init)");
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
    Slot &s_veg     = _slots.write[sid_veg];
    Slot &s_temp    = _slots.write[sid_temp];
    Slot &s_temp30  = _slots.write[sid_temp_30d];
    Slot &s_moist   = _slots.write[sid_moist];
    Slot &s_wb      = _slots.write[sid_water_bal];
    Slot &s_soil    = _slots.write[sid_soil];
    Slot &s_vgp     = _slots.write[sid_vgp];
    Slot &s_wt_type = _slots.write[sid_wt_type];
    Slot &s_wt_int  = _slots.write[sid_wt_int];
    Slot &s_wt_init = _slots.write[sid_wt_init];
    if (s_iswater.arr_u8.size() != n_cells || s_veg.arr_u8.size()     != n_cells ||
        s_temp.arr_f32.size()   != n_cells || s_temp30.arr_f32.size() != n_cells ||
        s_moist.arr_f32.size()  != n_cells || s_wb.arr_f32.size()     != n_cells ||
        s_soil.arr_f32.size()   != n_cells || s_vgp.arr_f32.size()    != n_cells ||
        s_wt_type.arr_u8.size() != n_cells || s_wt_int.arr_f32.size() != n_cells ||
        s_wt_init.arr_u8.size() != n_cells) {
        diag("slot array size mismatch (re-bind needed?)");
        return -1.0;
    }

    const uint8_t * const __restrict IW   = s_iswater.arr_u8.ptr();
    const uint8_t * const __restrict VG   = s_veg.arr_u8.ptr();
    const float   * const __restrict T    = s_temp.arr_f32.ptr();
    (void)T;
    const float   * const __restrict T30  = s_temp30.arr_f32.ptr();
    const float   * const __restrict M    = s_moist.arr_f32.ptr();
    const float   * const __restrict WBAL = s_wb.arr_f32.ptr();
    const float   * const __restrict SOILC = s_soil.arr_f32.ptr();
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

    // ─── Output candidate buffers (会大幅小于 n_cells，先 reserve 64) ────
    std::vector<int32_t> succ_indices;
    std::vector<uint8_t> succ_to_veg;
    succ_indices.reserve(64);
    succ_to_veg.reserve(64);

    // ─── Main loop ──────────────────────────────────────────────────────
    for (int i = 0; i < n_cells; ++i) {
        const uint8_t v_id = VG[i];
        if (IW[i] != 0 || v_id == veg_none_id) {
            VIT[i] = 0.0f;
            LSK[i] = 0;
            HSK[i] = 0;
            VGP[i] = 0.0f;
            continue;
        }
        const float temp = T30[i];
        const float plant_water = vegdyn_plant_water(
            M[i], WBAL[i], SOILC[i],
            plant_water_balance_weight, plant_soil_buffer_weight, plant_drought_penalty);
        const float compat = vegdyn_compat_of(v_id, temp, plant_water, n_veg, IDT, IDM, TLT, TLM);

        // weather penalty (clamp wt to valid id range; no init → CLEAR)
        int wt = wt_clear_id;
        float wi = 0.0f;
        if (WTIN[i] != 0) {
            wt = int(WTT[i]);
            wi = WTI[i];
        }
        const float weather_stress = vegdyn_weather_stress(
            v_id, wt, wi, n_veg, n_wt, wt_pen_arr.size(), WPN, RES, weather_penalty_scale);
        float water_pressure = WBAL[i] * 0.18f + SOILC[i] * 0.10f;
        if (water_pressure < -0.12f) water_pressure = -0.12f;
        else if (water_pressure > 0.12f) water_pressure = 0.12f;
        const float target = vegdyn_clamp01(compat + water_pressure - weather_stress);
        const float prev_vit = VIT[i];
        float dv = (target - prev_vit) * rate;
        if (dv < 0.0f) {
            dv *= harshness;
            if (low_vitality_damping_threshold > 0.0f && prev_vit < low_vitality_damping_threshold) {
                float damping = prev_vit / low_vitality_damping_threshold;
                if (damping < 0.25f) damping = 0.25f;
                else if (damping > 1.0f) damping = 1.0f;
                dv *= damping;
            }
        }
        VGP[i] = target - prev_vit;

        // vitality update (clamp 0..1)
        float vit = vegdyn_clamp01(prev_vit + dv * scale);
        VIT[i] = vit;

        // streak update
        int ls = LSK[i];
        int hs = HSK[i];
        if (ls < 0 || hs < 0) {
            ls += streak_days; if (ls > 0) ls = 0;
            hs += streak_days; if (hs > 0) hs = 0;
            LSK[i] = ls;
            HSK[i] = hs;
            continue;
        }
        const uint8_t nxt_up_for_streak = (v_id < n_veg) ? NXU[v_id] : v_id;
        const float nxt_up_score_for_streak = (nxt_up_for_streak != v_id)
            ? vegdyn_compat_of(nxt_up_for_streak, temp, plant_water, n_veg, IDT, IDM, TLT, TLM)
            : -1.0f;
        const bool upgrade_candidate =
            nxt_up_for_streak != v_id &&
            nxt_up_score_for_streak >= compat + succession_min_compat_gain &&
            nxt_up_score_for_streak >= high_thresh;
        float best_transition_score = -1.0f;
        const uint8_t best_transition = vegdyn_best_transition(
            v_id, temp, plant_water, n_veg, IDT, IDM, TLT, TLM, NXU, NXD,
            best_transition_score);
        const bool degrade_candidate = best_transition != v_id &&
            best_transition_score >= compat + succession_min_compat_gain;
        if (degrade_candidate && target < low_thresh) {
            ls += streak_days;
            hs = 0;
        } else if (upgrade_candidate && vit > low_thresh && target > low_thresh) {
            hs += streak_days;
            ls = 0;
        } else {
            ls -= streak_days; if (ls < 0) ls = 0;
            hs -= streak_days; if (hs < 0) hs = 0;
        }

        // succession candidate decision (degrade priority — mirror GDScript order)
        bool fired = false;
        if (ls >= degrade_days) {
            // climate-loop-closure Phase 3.2：气候导向退化目标——在 harsher/richer
            // 两候选里挑 compat 更高者(过湿→richer 湿生，过旱→harsher 荒漠)。
            if (degrade_candidate) {
                succ_indices.push_back(i);
                succ_to_veg.push_back(best_transition);
                const int cooldown = succession_cooldown_days > 0 ? -succession_cooldown_days : 0;
                ls = cooldown;
                hs = cooldown;
                fired = true;
            } else {
                // 没有下家：把 ls 清零防止反复触发（与 GDScript 一致）
                ls = 0;
            }
        }
        if (!fired && hs >= upgrade_days) {
            uint8_t nxt = (v_id < n_veg) ? NXU[v_id] : v_id;
            const float nxt_sc = (nxt != v_id) ? vegdyn_compat_of(nxt, temp, plant_water, n_veg, IDT, IDM, TLT, TLM) : -1.0f;
            if (nxt != v_id && nxt_sc >= compat + succession_min_compat_gain) {
                succ_indices.push_back(i);
                succ_to_veg.push_back(nxt);
                const int cooldown = succession_cooldown_days > 0 ? -succession_cooldown_days : 0;
                ls = cooldown;
                hs = cooldown;
            } else {
                hs = 0;
            }
        }
        LSK[i] = ls;
        HSK[i] = hs;
    }

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

    auto t1 = std::chrono::high_resolution_clock::now();
    return std::chrono::duration<double, std::milli>(t1 - t0).count();
}

// ─── [Phase C.3d] vegetation_dynamics 并行变体 ─────────────────────────────
//
// 完整复制 run_vegetation_dynamics_pass 的 prelude，主循环走
// pk::parallel_for_range_with_emit。thread-local Emit 持有 succession_indices
// + succession_to_veg；reduce 按 task_idx 升序串行 merge_into，保持 cell idx
// 升序契约（与 scalar bit-equal）。
//
// 注意：VIT/LSK/HSK 三个 ptrw 是 cell-local 写（每 cell 仅写自己 i 索引），
// 多线程下不同 task 写不同 cell range，无 race。
double DCWorldExt::run_vegetation_dynamics_pass_thread(Dictionary knobs, int n_tasks) {
    using godot::StringName;
    using godot::PackedFloat32Array;
    using godot::PackedInt32Array;
    using godot::PackedByteArray;

    auto diag = [&](const char *why) {
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_vegetation_dynamics_pass_thread: ", why,
            " — fallback to GDScript");
    };

    if (!_bound) { diag("not _bound"); return -1.0; }

    const int sid_iswater  = component_id(StringName("cell_is_water"));
    const int sid_veg      = component_id(StringName("cell_vegetation"));
    const int sid_temp     = component_id(StringName("cell_temp"));
    const int sid_temp_30d = component_id(StringName("cell_temp_30d"));
    const int sid_moist    = component_id(StringName("cell_moisture"));
    const int sid_water_bal = component_id(StringName("cell_water_balance_30d"));
    const int sid_soil     = component_id(StringName("cell_soil_moisture"));
    const int sid_vgp      = component_id(StringName("cell_vegetation_growth_pressure"));
    const int sid_wt_type  = component_id(StringName("cell_weather_type"));
    const int sid_wt_int   = component_id(StringName("cell_weather_intensity"));
    const int sid_wt_init  = component_id(StringName("cell_weather_field_init"));
    if (sid_iswater < 0 || sid_veg < 0 || sid_temp < 0 || sid_temp_30d < 0 ||
        sid_moist < 0 || sid_water_bal < 0 || sid_soil < 0 || sid_vgp < 0 ||
        sid_wt_type < 0 || sid_wt_int < 0 || sid_wt_init < 0) {
        diag("missing slot id");
        return -1.0;
    }

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

    Slot &s_iswater = _slots.write[sid_iswater];
    Slot &s_veg     = _slots.write[sid_veg];
    Slot &s_temp    = _slots.write[sid_temp];
    Slot &s_temp30  = _slots.write[sid_temp_30d];
    Slot &s_moist   = _slots.write[sid_moist];
    Slot &s_wb      = _slots.write[sid_water_bal];
    Slot &s_soil    = _slots.write[sid_soil];
    Slot &s_vgp     = _slots.write[sid_vgp];
    Slot &s_wt_type = _slots.write[sid_wt_type];
    Slot &s_wt_int  = _slots.write[sid_wt_int];
    Slot &s_wt_init = _slots.write[sid_wt_init];
    if (s_iswater.arr_u8.size() != n_cells || s_veg.arr_u8.size()     != n_cells ||
        s_temp.arr_f32.size()   != n_cells || s_temp30.arr_f32.size() != n_cells ||
        s_moist.arr_f32.size()  != n_cells || s_wb.arr_f32.size()     != n_cells ||
        s_soil.arr_f32.size()   != n_cells || s_vgp.arr_f32.size()    != n_cells ||
        s_wt_type.arr_u8.size() != n_cells || s_wt_int.arr_f32.size() != n_cells ||
        s_wt_init.arr_u8.size() != n_cells) {
        diag("slot array size mismatch (re-bind needed?)");
        return -1.0;
    }

    const uint8_t * const __restrict IW   = s_iswater.arr_u8.ptr();
    const uint8_t * const __restrict VG   = s_veg.arr_u8.ptr();
    const float   * const __restrict T    = s_temp.arr_f32.ptr();
    (void)T;
    const float   * const __restrict T30  = s_temp30.arr_f32.ptr();
    const float   * const __restrict M    = s_moist.arr_f32.ptr();
    const float   * const __restrict WBAL = s_wb.arr_f32.ptr();
    const float   * const __restrict SOILC = s_soil.arr_f32.ptr();
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
    const int wt_pen_size = wt_pen_arr.size();

    auto t0 = std::chrono::high_resolution_clock::now();

    struct VegEmit {
        std::vector<int32_t> indices;
        std::vector<uint8_t> to_veg;

        void merge_into(VegEmit &dst) const {
            dst.indices.insert(dst.indices.end(), indices.begin(), indices.end());
            dst.to_veg.insert(dst.to_veg.end(), to_veg.begin(), to_veg.end());
        }
    };
    VegEmit global_emit;
    global_emit.indices.reserve(64);
    global_emit.to_veg.reserve(64);

    auto run = [&](int begin, int end, VegEmit &local) {
        for (int i = begin; i < end; ++i) {
            const uint8_t v_id = VG[i];
            if (IW[i] != 0 || v_id == veg_none_id) {
                VIT[i] = 0.0f;
                LSK[i] = 0;
                HSK[i] = 0;
                VGP[i] = 0.0f;
                continue;
            }
            const float temp = T30[i];
            const float plant_water = vegdyn_plant_water(
                M[i], WBAL[i], SOILC[i],
                plant_water_balance_weight, plant_soil_buffer_weight, plant_drought_penalty);
            const float compat = vegdyn_compat_of(v_id, temp, plant_water, n_veg, IDT, IDM, TLT, TLM);

            int wt = wt_clear_id;
            float wi = 0.0f;
            if (WTIN[i] != 0) {
                wt = int(WTT[i]);
                wi = WTI[i];
            }
            const float weather_stress = vegdyn_weather_stress(
                v_id, wt, wi, n_veg, n_wt, wt_pen_size, WPN, RES, weather_penalty_scale);
            float water_pressure = WBAL[i] * 0.18f + SOILC[i] * 0.10f;
            if (water_pressure < -0.12f) water_pressure = -0.12f;
            else if (water_pressure > 0.12f) water_pressure = 0.12f;
            const float target = vegdyn_clamp01(compat + water_pressure - weather_stress);
            const float prev_vit = VIT[i];
            float dv = (target - prev_vit) * rate;
            if (dv < 0.0f) {
                dv *= harshness;
                if (low_vitality_damping_threshold > 0.0f && prev_vit < low_vitality_damping_threshold) {
                    float damping = prev_vit / low_vitality_damping_threshold;
                    if (damping < 0.25f) damping = 0.25f;
                    else if (damping > 1.0f) damping = 1.0f;
                    dv *= damping;
                }
            }
            VGP[i] = target - prev_vit;

            float vit = vegdyn_clamp01(prev_vit + dv * scale);
            VIT[i] = vit;

            int ls = LSK[i];
            int hs = HSK[i];
            if (ls < 0 || hs < 0) {
                ls += streak_days; if (ls > 0) ls = 0;
                hs += streak_days; if (hs > 0) hs = 0;
                LSK[i] = ls;
                HSK[i] = hs;
                continue;
            }
        const uint8_t nxt_up_for_streak = (v_id < n_veg) ? NXU[v_id] : v_id;
        const float nxt_up_score_for_streak = (nxt_up_for_streak != v_id)
            ? vegdyn_compat_of(nxt_up_for_streak, temp, plant_water, n_veg, IDT, IDM, TLT, TLM)
            : -1.0f;
        const bool upgrade_candidate =
            nxt_up_for_streak != v_id &&
            nxt_up_score_for_streak >= compat + succession_min_compat_gain &&
            nxt_up_score_for_streak >= high_thresh;
        float best_transition_score = -1.0f;
        const uint8_t best_transition = vegdyn_best_transition(
            v_id, temp, plant_water, n_veg, IDT, IDM, TLT, TLM, NXU, NXD,
            best_transition_score);
        const bool degrade_candidate = best_transition != v_id &&
            best_transition_score >= compat + succession_min_compat_gain;
            if (degrade_candidate && target < low_thresh) {
                ls += streak_days;
                hs = 0;
        } else if (upgrade_candidate && vit > low_thresh && target > low_thresh) {
                hs += streak_days;
                ls = 0;
            } else {
                ls -= streak_days; if (ls < 0) ls = 0;
                hs -= streak_days; if (hs < 0) hs = 0;
            }

            bool fired = false;
            if (ls >= degrade_days) {
                if (degrade_candidate) {
                    local.indices.push_back(i);
                    local.to_veg.push_back(best_transition);
                    const int cooldown = succession_cooldown_days > 0 ? -succession_cooldown_days : 0;
                    ls = cooldown;
                    hs = cooldown;
                    fired = true;
                } else {
                    ls = 0;
                }
            }
            if (!fired && hs >= upgrade_days) {
                uint8_t nxt = (v_id < n_veg) ? NXU[v_id] : v_id;
                const float nxt_sc = (nxt != v_id) ? vegdyn_compat_of(nxt, temp, plant_water, n_veg, IDT, IDM, TLT, TLM) : -1.0f;
                if (nxt != v_id && nxt_sc >= compat + succession_min_compat_gain) {
                    local.indices.push_back(i);
                    local.to_veg.push_back(nxt);
                    const int cooldown = succession_cooldown_days > 0 ? -succession_cooldown_days : 0;
                    ls = cooldown;
                    hs = cooldown;
                } else {
                    hs = 0;
                }
            }
            LSK[i] = ls;
            HSK[i] = hs;
        }
    };
    pk::parallel_for_range_with_emit<VegEmit>(
        "pk_veg_dyn", n_cells, n_tasks, 256, global_emit, run);

    PackedInt32Array out_indices;
    PackedByteArray  out_to_veg;
    const int n_succ = int(global_emit.indices.size());
    out_indices.resize(n_succ);
    out_to_veg.resize(n_succ);
    if (n_succ > 0) {
        std::memcpy(out_indices.ptrw(), global_emit.indices.data(), n_succ * sizeof(int32_t));
        std::memcpy(out_to_veg.ptrw(),  global_emit.to_veg.data(),  n_succ * sizeof(uint8_t));
    }
    knobs["succession_indices"] = out_indices;
    knobs["succession_to_veg"]  = out_to_veg;
    knobs["stat_succession_count"] = n_succ;
    if (n_succ > 0) {
        const int64_t tick = int64_t(knobs.get("tick", int64_t(knobs.get("day_idx", 0))));
        const int32_t phase = int32_t(knobs.get("event_phase", 0));
        _emit_succession_events(out_indices, out_to_veg, VG, s_veg.arr_u8.size(), tick, phase, 1);
    }

    knobs["vitality_arr"]   = vitality_arr;
    knobs["low_streak_arr"] = low_streak;
    knobs["high_streak_arr"]= high_streak;
    _flush_slot_to_map(sid_vgp);

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

    // ─── Main loop ──────────────────────────────────────────────────────
    // [Phase C.3c] 主循环抽成 lambda，scalar 路径 run_range(0, n_cells)，
    // _thread 变体走 pk::parallel_for_range；body 严格 1:1 与原循环一致。
    auto run_range = [&](int begin, int end) {
        for (int i = begin; i < end; ++i) {
            if (IW[i] != 0) continue;                              // skip water cells

            // ① ocean → base_moisture drift（年尺度，每日 |Δ| ≤ per_day_clamp）
            if (ocean_drift_gain > 0.0f) {
                float sum_an = 0.0f;
                int   n_water = 0;
                const int base = i * 6;
                for (int d = 0; d < 6; ++d) {
                    const int32_t ni = NB[base + d];
                    if (ni < 0) continue;
                    if (IW[ni] != 0) {
                        sum_an += TTA[ni];
                        n_water += 1;
                    }
                }
                if (n_water > 0) {
                    const float avg_an = sum_an / float(n_water);
                    if (std::fabs(avg_an) > 0.005f) {
                        float coastal_ratio = float(n_water) / 6.0f;
                        if (coastal_ratio > 1.0f) coastal_ratio = 1.0f;
                        float d_base = ocean_drift_gain * avg_an * coastal_ratio * scale;
                        if (d_base < -per_day_clamp) d_base = -per_day_clamp;
                        else if (d_base > per_day_clamp) d_base = per_day_clamp;
                        float bm = BM[i] + d_base;
                        if (bm < 0.0f) bm = 0.0f;
                        else if (bm > 1.0f) bm = 1.0f;
                        BM[i] = bm;
                    }
                }
            }

            // ② weather → soil / vegetation_growth_pressure 累加（小权重）
            const bool init = WTIN[i] != 0;
            const int   wt = init ? int(WTT[i]) : -1;             // -1 = uninit (== CLEAR semantically)
            const float wi = init ? WTI[i] : 0.0f;
            if (wi < 0.01f) continue;

            float precip = 0.0f;
            if      (wt == wt_rain_id)     precip = wi;
            else if (wt == wt_storm_id)    precip = wi * 0.8f;
            else if (wt == wt_monsoon_id)  precip = wi * 1.2f;
            else if (wt == wt_blizzard_id) precip = wi * 0.3f;
            else if (wt == wt_drought_id)  precip = -wi * 0.6f;
            else if (wt == wt_heatwave_id) precip = -wi * 0.4f;
            // else: precip = 0.0 (CLEAR / FOG / etc.)

            // soil_moisture (clamp -0.5..0.5)
            float d_soil = soil_gain * precip * scale;
            if (d_soil < -per_day_clamp) d_soil = -per_day_clamp;
            else if (d_soil > per_day_clamp) d_soil = per_day_clamp;
            float soil = SOIL[i] + d_soil;
            if (soil < -0.5f) soil = -0.5f;
            else if (soil > 0.5f) soil = 0.5f;
            SOIL[i] = soil;

            // 让天气流动(2026-06-21)：weather → base_moisture 直接反馈(镜像 GDScript
            // _apply_weather_to_map_feedback_pass)。降水抬升/干旱压低局地气候湿度 → 闭环。
            if (base_m_gain > 0.0f) {
                float d_bm = base_m_gain * precip * scale;
                if (d_bm < -per_day_clamp) d_bm = -per_day_clamp;
                else if (d_bm > per_day_clamp) d_bm = per_day_clamp;
                float bmw = BM[i] + d_bm;
                if (bmw < 0.0f) bmw = 0.0f;
                else if (bmw > 1.0f) bmw = 1.0f;
                BM[i] = bmw;
            }

            if (write_weather_veg_pressure) {
                // vegetation_growth_pressure (clamp -0.5..0.5)
                float d_veg = veg_gain * precip * scale;
                if (d_veg < -per_day_clamp) d_veg = -per_day_clamp;
                else if (d_veg > per_day_clamp) d_veg = per_day_clamp;
                float vg_v = VG[i] + d_veg;
                if (vg_v < -0.5f) vg_v = -0.5f;
                else if (vg_v > 0.5f) vg_v = 0.5f;
                VG[i] = vg_v;
            }
        }
    };
    run_range(0, n_cells);

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
    using godot::StringName;
    using godot::PackedFloat32Array;
    using godot::PackedInt32Array;

    auto diag = [&](const char *why) {
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_climate_feedback_pass_thread: ", why,
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

    // ─── Main loop（与 run_climate_feedback_pass 主循环 1:1） ────────────
    auto run_range = [&](int begin, int end) {
        for (int i = begin; i < end; ++i) {
            if (IW[i] != 0) continue;

            if (ocean_drift_gain > 0.0f) {
                float sum_an = 0.0f;
                int   n_water = 0;
                const int base = i * 6;
                for (int d = 0; d < 6; ++d) {
                    const int32_t ni = NB[base + d];
                    if (ni < 0) continue;
                    if (IW[ni] != 0) {
                        sum_an += TTA[ni];
                        n_water += 1;
                    }
                }
                if (n_water > 0) {
                    const float avg_an = sum_an / float(n_water);
                    if (std::fabs(avg_an) > 0.005f) {
                        float coastal_ratio = float(n_water) / 6.0f;
                        if (coastal_ratio > 1.0f) coastal_ratio = 1.0f;
                        float d_base = ocean_drift_gain * avg_an * coastal_ratio * scale;
                        if (d_base < -per_day_clamp) d_base = -per_day_clamp;
                        else if (d_base > per_day_clamp) d_base = per_day_clamp;
                        float bm = BM[i] + d_base;
                        if (bm < 0.0f) bm = 0.0f;
                        else if (bm > 1.0f) bm = 1.0f;
                        BM[i] = bm;
                    }
                }
            }

            const bool init = WTIN[i] != 0;
            const int   wt = init ? int(WTT[i]) : -1;
            const float wi = init ? WTI[i] : 0.0f;
            if (wi < 0.01f) continue;

            float precip = 0.0f;
            if      (wt == wt_rain_id)     precip = wi;
            else if (wt == wt_storm_id)    precip = wi * 0.8f;
            else if (wt == wt_monsoon_id)  precip = wi * 1.2f;
            else if (wt == wt_blizzard_id) precip = wi * 0.3f;
            else if (wt == wt_drought_id)  precip = -wi * 0.6f;
            else if (wt == wt_heatwave_id) precip = -wi * 0.4f;

            float d_soil = soil_gain * precip * scale;
            if (d_soil < -per_day_clamp) d_soil = -per_day_clamp;
            else if (d_soil > per_day_clamp) d_soil = per_day_clamp;
            float soil = SOIL[i] + d_soil;
            if (soil < -0.5f) soil = -0.5f;
            else if (soil > 0.5f) soil = 0.5f;
            SOIL[i] = soil;

            // 让天气流动(2026-06-21)：weather → base_moisture 直接反馈(镜像 GDScript
            // _apply_weather_to_map_feedback_pass)。降水抬升/干旱压低局地气候湿度 → 闭环。
            if (base_m_gain > 0.0f) {
                float d_bm = base_m_gain * precip * scale;
                if (d_bm < -per_day_clamp) d_bm = -per_day_clamp;
                else if (d_bm > per_day_clamp) d_bm = per_day_clamp;
                float bmw = BM[i] + d_bm;
                if (bmw < 0.0f) bmw = 0.0f;
                else if (bmw > 1.0f) bmw = 1.0f;
                BM[i] = bmw;
            }

            if (write_weather_veg_pressure) {
                float d_veg = veg_gain * precip * scale;
                if (d_veg < -per_day_clamp) d_veg = -per_day_clamp;
                else if (d_veg > per_day_clamp) d_veg = per_day_clamp;
                float vg_v = VG[i] + d_veg;
                if (vg_v < -0.5f) vg_v = -0.5f;
                else if (vg_v > 0.5f) vg_v = 0.5f;
                VG[i] = vg_v;
            }
        }
    };

    pk::parallel_for_range("pk_climate_feedback", n_cells, n_tasks, /*seq_threshold=*/256, run_range);

    _flush_slot_to_map(sid_base_m);

    knobs["soil_moisture_arr"]       = soil_arr;
    knobs["veg_growth_pressure_arr"] = vg_arr;

    auto t1 = std::chrono::high_resolution_clock::now();
    return std::chrono::duration<double, std::milli>(t1 - t0).count();
}

// ─── 方案 B：stage_b 三段合并 run_stage_b_pass ────────────────────────────
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
    const int sid_temp     = component_id(StringName("cell_temp"));
    const int sid_temp_30d = component_id(StringName("cell_temp_30d"));
    const int sid_moist    = component_id(StringName("cell_moisture"));
    const int sid_water_bal = component_id(StringName("cell_water_balance_30d"));
    const int sid_wt_type  = component_id(StringName("cell_weather_type"));
    const int sid_wt_int   = component_id(StringName("cell_weather_intensity"));
    const int sid_wt_init  = component_id(StringName("cell_weather_field_init"));
    const int sid_base_m   = component_id(StringName("cell_base_moisture"));
    if (sid_iswater < 0 || sid_veg < 0 || sid_cover < 0 || sid_temp < 0 ||
        sid_temp_30d < 0 || sid_moist < 0 || sid_water_bal < 0 ||
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
    Slot &s_temp    = _slots.write[sid_temp];
    Slot &s_temp30  = _slots.write[sid_temp_30d];
    Slot &s_moist   = _slots.write[sid_moist];
    Slot &s_wb      = _slots.write[sid_water_bal];
    Slot &s_wt_type = _slots.write[sid_wt_type];
    Slot &s_wt_int  = _slots.write[sid_wt_int];
    Slot &s_wt_init = _slots.write[sid_wt_init];
    Slot &s_base_m  = _slots.write[sid_base_m];
    if (s_iswater.arr_u8.size() != n_cells || s_veg.arr_u8.size()    != n_cells ||
        s_cover.arr_u8.size()   != n_cells || s_temp.arr_f32.size()  != n_cells ||
        s_temp30.arr_f32.size() != n_cells || s_moist.arr_f32.size() != n_cells ||
        s_wb.arr_f32.size()     != n_cells || s_wt_type.arr_u8.size()!= n_cells ||
        s_wt_int.arr_f32.size() != n_cells || s_wt_init.arr_u8.size()!= n_cells ||
        s_base_m.arr_f32.size() != n_cells) {
        diag("slot array size mismatch (re-bind needed?)");
        return -1.0;
    }

    // 通用 SoA pointer
    const uint8_t * const __restrict IW    = s_iswater.arr_u8.ptr();
    const uint8_t * const __restrict VG    = s_veg.arr_u8.ptr();
    const uint8_t * const __restrict CV    = s_cover.arr_u8.ptr();
    float         * const __restrict T     = s_temp.arr_f32.ptrw();   // albedo 写、veg_dyn 读
    const float   * const __restrict T30   = s_temp30.arr_f32.ptr();
    const float   * const __restrict M     = s_moist.arr_f32.ptr();
    const float   * const __restrict WBAL  = s_wb.arr_f32.ptr();
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

        // ─── Main loop（与 run_albedo_pass:3604-3617 完全一致）──────────
        for (int i = 0; i < n_cells; ++i) {
            if (IW[i] != 0) continue;
            const uint8_t veg_id = VG[i];
            float alb = (veg_id < albedo_size) ? ALB[veg_id] : 0.0f;
            const uint8_t cover_id = CV[i];
            if (cover_id == cover_snow_id || cover_id == cover_glacier_id) {
                if (alb < snow_cover_albedo) alb = snow_cover_albedo;
            }
            const float dt = (reference_albedo - alb) * albedo_temp_gain;
            float v = T[i] + dt;
            if (v < 0.0f) v = 0.0f;
            else if (v > 1.0f) v = 1.0f;
            T[i] = v;
        }

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

        std::vector<int32_t> succ_indices;
        std::vector<uint8_t> succ_to_veg;
        succ_indices.reserve(64);
        succ_to_veg.reserve(64);

        // ─── Main loop（与 run_vegetation_dynamics_pass:3778-3868 完全一致）─
        for (int i = 0; i < n_cells; ++i) {
            const uint8_t v_id = VG[i];
            if (IW[i] != 0 || v_id == veg_none_id) {
                VIT[i] = 0.0f;
                LSK[i] = 0;
                HSK[i] = 0;
                if (VGP_COMP != nullptr) VGP_COMP[i] = 0.0f;
                if (vegetation_stress_enabled) {
                    VHEAT[i] = 0.0f;
                    VDROUGHT[i] = 0.0f;
                    VCOLD[i] = 0.0f;
                    VREGEN[i] = 0.0f;
                }
                continue;
            }
            const float temp = T30[i];
            const float soil_now = SOIL_COMP != nullptr ? SOIL_COMP[i] : 0.0f;
            const float plant_water = vegdyn_plant_water(
                M[i], WBAL[i], soil_now,
                plant_water_balance_weight, plant_soil_buffer_weight, plant_drought_penalty);
            const float compat = vegdyn_compat_of(v_id, temp, plant_water, n_veg, IDT, IDM, TLT, TLM);

            int wt = wt_clear_id;
            float wi = 0.0f;
            if (WTIN[i] != 0) {
                wt = int(WTT[i]);
                wi = WTI[i];
            }
            const float weather_stress = vegdyn_weather_stress(
                v_id, wt, wi, n_veg, n_wt, wt_pen_arr.size(), WPN, RES, weather_penalty_scale);
            float stress_max = 0.0f;
            float regen_score = 0.0f;
            if (vegetation_stress_enabled) {
                float heat_input = 0.0f;
                float cold_input = 0.0f;
                float drought_input = 0.0f;
                if (v_id < n_veg) {
                    const float temp_tol = std::max(TLT[v_id], 0.05f);
                    const float moist_tol = std::max(TLM[v_id], 0.05f);
                    heat_input = vegdyn_clamp01((temp - (IDT[v_id] + temp_tol)) / temp_tol);
                    cold_input = vegdyn_clamp01(((IDT[v_id] - temp_tol) - temp) / temp_tol);
                    const float water_deficit = vegdyn_clamp01(((IDM[v_id] - moist_tol) - plant_water) / moist_tol);
                    drought_input = water_deficit;
                    if (WTIN[i] != 0 && wt == wt_drought_id) {
                        drought_input = std::max(drought_input, water_deficit * vegdyn_clamp01(wi));
                    }
                }
                if (WTIN[i] != 0) {
                    const float wi_clamped = vegdyn_clamp01(wi);
                    if (wt == wt_heatwave_id) {
                        heat_input = std::max(heat_input, wi_clamped);
                    } else if (wt == wt_blizzard_id) {
                        cold_input = std::max(cold_input, wi_clamped);
                    }
                }
                const float regen_input = vegdyn_clamp01(compat * (1.0f - weather_stress) * (0.5f + 0.5f * plant_water));
                const float heat = VHEAT[i] + (heat_input - VHEAT[i]) * vegetation_stress_blend;
                const float drought = VDROUGHT[i] + (drought_input - VDROUGHT[i]) * vegetation_stress_blend;
                const float cold = VCOLD[i] + (cold_input - VCOLD[i]) * vegetation_stress_blend;
                const float regen = VREGEN[i] + (regen_input - VREGEN[i]) * vegetation_stress_blend;
                VHEAT[i] = heat;
                VDROUGHT[i] = drought;
                VCOLD[i] = cold;
                VREGEN[i] = regen;
                stress_max = std::max(heat, std::max(drought, cold));
                regen_score = regen;
            }
            float water_pressure = WBAL[i] * 0.18f + soil_now * 0.10f;
            if (water_pressure < -0.12f) water_pressure = -0.12f;
            else if (water_pressure > 0.12f) water_pressure = 0.12f;
            const float target = vegetation_stress_enabled
                ? vegdyn_clamp01(compat + water_pressure - weather_stress - stress_max * 0.25f + regen_score * 0.10f)
                : vegdyn_clamp01(compat + water_pressure - weather_stress);
            const float prev_vit = VIT[i];
            float dv = (target - prev_vit) * rate;
            if (dv < 0.0f) {
                dv *= harshness;
                if (low_vitality_damping_threshold > 0.0f && prev_vit < low_vitality_damping_threshold) {
                    float damping = prev_vit / low_vitality_damping_threshold;
                    if (damping < 0.25f) damping = 0.25f;
                    else if (damping > 1.0f) damping = 1.0f;
                    dv *= damping;
                }
            }
            if (VGP_COMP != nullptr) VGP_COMP[i] = target - prev_vit;

            float vit = vegdyn_clamp01(prev_vit + dv * scale);
            VIT[i] = vit;

            int ls = LSK[i];
            int hs = HSK[i];
            if (ls < 0 || hs < 0) {
                ls += streak_days; if (ls > 0) ls = 0;
                hs += streak_days; if (hs > 0) hs = 0;
                LSK[i] = ls;
                HSK[i] = hs;
                continue;
            }
            const uint8_t nxt_up_for_streak = (v_id < n_veg) ? NXU[v_id] : v_id;
            const float nxt_up_score_for_streak = (nxt_up_for_streak != v_id)
                ? vegdyn_compat_of(nxt_up_for_streak, temp, plant_water, n_veg, IDT, IDM, TLT, TLM)
                : -1.0f;
            const bool upgrade_candidate =
                nxt_up_for_streak != v_id &&
                nxt_up_score_for_streak >= compat + succession_min_compat_gain &&
                nxt_up_score_for_streak >= high_thresh;
            float best_transition_score = -1.0f;
            const uint8_t best_transition = vegdyn_best_transition(
                v_id, temp, plant_water, n_veg, IDT, IDM, TLT, TLM, NXU, NXD,
                best_transition_score);
            const bool degrade_candidate = best_transition != v_id &&
                best_transition_score >= compat + succession_min_compat_gain;
            if (degrade_candidate && vegetation_stress_enabled && stress_max > 0.65f && target < high_thresh) {
                const int stress_days = std::max(streak_days, int(std::round(float(streak_days) * stress_max)));
                ls += stress_days;
                hs = 0;
            } else if (degrade_candidate && target < low_thresh) {
                ls += streak_days;
                hs = 0;
            } else if (upgrade_candidate && vit > low_thresh && target > low_thresh) {
                hs += streak_days;
                ls = 0;
            } else {
                ls -= streak_days; if (ls < 0) ls = 0;
                hs -= streak_days; if (hs < 0) hs = 0;
            }

            bool fired = false;
            if (ls >= degrade_days) {
                if (degrade_candidate) {
                    succ_indices.push_back(i);
                    succ_to_veg.push_back(best_transition);
                    const int cooldown = succession_cooldown_days > 0 ? -succession_cooldown_days : 0;
                    ls = cooldown;
                    hs = cooldown;
                    fired = true;
                } else {
                    ls = 0;
                }
            }
            if (!fired && hs >= upgrade_days) {
                uint8_t nxt = (v_id < n_veg) ? NXU[v_id] : v_id;
                const float nxt_sc = (nxt != v_id) ? vegdyn_compat_of(nxt, temp, plant_water, n_veg, IDT, IDM, TLT, TLM) : -1.0f;
                if (nxt != v_id && nxt_sc >= compat + succession_min_compat_gain) {
                    succ_indices.push_back(i);
                    succ_to_veg.push_back(nxt);
                    const int cooldown = succession_cooldown_days > 0 ? -succession_cooldown_days : 0;
                    ls = cooldown;
                    hs = cooldown;
                } else {
                    hs = 0;
                }
            }
            LSK[i] = ls;
            HSK[i] = hs;
        }

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

        // ─── Main loop（与 run_climate_feedback_pass:3992-4056 完全一致）─
        for (int i = 0; i < n_cells; ++i) {
            if (IW[i] != 0) continue;

            if (ocean_drift_gain > 0.0f) {
                float sum_an = 0.0f;
                int   n_water = 0;
                const int base = i * 6;
                for (int d = 0; d < 6; ++d) {
                    const int32_t ni = NB[base + d];
                    if (ni < 0) continue;
                    if (IW[ni] != 0) {
                        sum_an += TTA[ni];
                        n_water += 1;
                    }
                }
                if (n_water > 0) {
                    const float avg_an = sum_an / float(n_water);
                    if (std::fabs(avg_an) > 0.005f) {
                        float coastal_ratio = float(n_water) / 6.0f;
                        if (coastal_ratio > 1.0f) coastal_ratio = 1.0f;
                        float d_base = ocean_drift_gain * avg_an * coastal_ratio * scale;
                        if (d_base < -per_day_clamp) d_base = -per_day_clamp;
                        else if (d_base > per_day_clamp) d_base = per_day_clamp;
                        float bm = BM[i] + d_base;
                        if (bm < 0.0f) bm = 0.0f;
                        else if (bm > 1.0f) bm = 1.0f;
                        BM[i] = bm;
                    }
                }
            }

            const bool init = WTIN[i] != 0;
            const int   wt = init ? int(WTT[i]) : -1;
            const float wi = init ? WTI[i] : 0.0f;
            if (wi < 0.01f) continue;

            float precip = 0.0f;
            if      (wt == wt_rain_id)     precip = wi;
            else if (wt == wt_storm_id)    precip = wi * 0.8f;
            else if (wt == wt_monsoon_id)  precip = wi * 1.2f;
            else if (wt == wt_blizzard_id) precip = wi * 0.3f;
            else if (wt == wt_drought_id)  precip = -wi * 0.6f;
            else if (wt == wt_heatwave_id) precip = -wi * 0.4f;

            float d_soil = soil_gain * precip * scale;
            if (d_soil < -per_day_clamp) d_soil = -per_day_clamp;
            else if (d_soil > per_day_clamp) d_soil = per_day_clamp;
            float soil = SOIL[i] + d_soil;
            if (soil < -0.5f) soil = -0.5f;
            else if (soil > 0.5f) soil = 0.5f;
            SOIL[i] = soil;

            // 让天气流动(2026-06-21)：weather → base_moisture 直接反馈(镜像 GDScript
            // _apply_weather_to_map_feedback_pass)。降水抬升/干旱压低局地气候湿度 → 闭环。
            if (base_m_gain > 0.0f) {
                float d_bm = base_m_gain * precip * scale;
                if (d_bm < -per_day_clamp) d_bm = -per_day_clamp;
                else if (d_bm > per_day_clamp) d_bm = per_day_clamp;
                float bmw = BM[i] + d_bm;
                if (bmw < 0.0f) bmw = 0.0f;
                else if (bmw > 1.0f) bmw = 1.0f;
                BM[i] = bmw;
            }

            if (write_weather_veg_pressure) {
                float d_veg = veg_gain * precip * scale;
                if (d_veg < -per_day_clamp) d_veg = -per_day_clamp;
                else if (d_veg > per_day_clamp) d_veg = per_day_clamp;
                float vg_v = VGP[i] + d_veg;
                if (vg_v < -0.5f) vg_v = -0.5f;
                else if (vg_v > 0.5f) vg_v = 0.5f;
                VGP[i] = vg_v;
            }
        }

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

// 错误码（worker 通过 atomic int 传给主线程，主线程 push_warning）。
constexpr int PK_ASYNC_ROUND_ERR_OK              = 0;
constexpr int PK_ASYNC_ROUND_ERR_INPUT_SIZE      = 1;
constexpr int PK_ASYNC_ROUND_ERR_KERNEL_FAILED   = 2;

// Round-level scalars / cp 字段（kick 时主线程从 GDScript Dictionary 提取，
// worker 在 round 内整段使用）。新增字段时同步更新 kick 提取代码 +
// _async_climate_round_run_passes 内 stub。
struct ClimateRoundScalars {
    // round 锁定的相位（kick 时刻的 season_phase）。worker 全程用这个值，
    // 不再因 round 跨多 ticks 而 stale。解决"夏至滞后"。
    double season_phase = 0.0;

    // ── 来自 cp_struct（climate_pass_a 用） ─────────────────────────────
    double axial_tilt_deg = 23.5;
    double day_length_gain = 0.35;
    double solar_gain = 1.0;
    double insol_amp = 0.20;       // sync 路径 default 0.20
    double insol_gain = 1.0;
    double moist_scale_now = 1.0;
    float  runtime_moisture_base_relax_rate = 0.24f;
    float  runtime_moisture_weather_vapor_weight = 0.12f;
    float  runtime_moisture_precip_weight = 0.78f;
    float  runtime_moisture_soil_weight = 1.82f;
    float  runtime_moisture_soil_dry_weight = 2.21f;
    float  runtime_moisture_water_balance_weight = 1.04f;
    float  runtime_moisture_water_balance_dry_weight = 1.30f;
    int    days_per_year = 365;
    double sea_level = 0.5;

    // pass_a 额外字段（cp.thermal_inertia_* / thermal_daily_delta_cap /
    // snowpack_cover_* / insol_dev_min/max）。sync 路径 default 与
    // run_climate_pass_a 顶部一致。
    double insol_dev_min = -1.0;
    double insol_dev_max = 1.0;
    double thermal_inertia_land = 0.35;
    double thermal_inertia_water = 0.045;
    double thermal_inertia_snow = 0.09;
    double thermal_inertia_high_mountain = 0.16;
    double thermal_daily_delta_cap = 0.15;
    // 加速/跳日补偿：本次 pass_a 距上次实际经过的仿真天数（默认 1.0）。
    // 热惯性松弛与 delta_cap 按此天数积分，否则加速档下海洋温度会严重欠积分、
    // 滞后于太阳直射点。见 climate_daily_system._build_async_kick_input。
    double thermal_dt_days = 1.0;
    double snowpack_cover_low = 0.05;
    double snowpack_cover_full = 0.32;
    // [climate-zone-fix P2] 沿海陆地季节振幅最大衰减比（0=关闭=原行为；0.55=海岸格季节
    // 振幅仅余 45%）。与 per-cell maritime 因子相乘后缩放 season_offset。
    double maritime_season_damp = 0.0;

    // transp pass 用（Stage 1 实装）
    float  transp_outflow_rate = 0.025f;
    float  transp_self_rate    = 0.015f;

    // pass_b knobs（Stage 2，与 sync run_climate_pass_b knobs 一一对应）
    float  pb_winter_boost  = 1.0f;
    float  pb_snow_cool     = 0.0f;
    float  pb_veg_cool      = 0.0f;
    float  pb_diurnal_amp   = 0.0f;
    float  pb_evap_gain     = 0.0f;
    float  pb_rs_threshold  = 0.0f;
    float  pb_rs_factor     = 1.0f;
    int    pb_rs_lookback   = 0;
    float  pb_t_freeze      = 0.0f;
    float  pb_coupling_gain = 0.0f;
    float  pb_coast_leak    = 0.0f;
    float  pb_sea_ice_albedo_cooling = 0.01f;

    // ocean_water / ocean_land knobs（Stage 2）
    int    ow_advect_steps = 3;
    float  ow_heat_mix     = 0.55f;
    float  ow_tta_source_cap = 0.22f;
    float  ow_tta_blend_rate = 0.70f;
    float  ow_tta_zero_current_decay = 0.06f;
    float  ol_effective_leak = 0.55f;
    float  ol_tta_source_cap = 0.22f;
    float  ol_tta_blend_rate = 0.70f;
    float  ol_tta_decay_rate = 0.04f;

    // wind_air / wind_surface knobs（Stage 2）
    int    wa_advect_steps = 3;
    float  wa_heat_mix     = 0.25f;
    float  ws_air_leak     = 0.35f;
    float  ws_cold_transport_form = 0.06f;
    float  ws_cold_transport_melt = 0.11f;

    // sea_ice knobs（Stage 2）
    float si_k_freeze      = 0.40f;
    float si_k_melt        = 1.45f;
    float si_t_form        = 0.06f;
    float si_t_melt        = 0.11f;
    float si_contagion     = 0.035f;
    float si_threshold     = 0.72f;
    float si_hysteresis    = 0.18f;
    float si_ice_delay     = 1.0f;
    bool  si_enable_oht    = true;
    bool  si_apply_terrain_flips = false;
    bool  si_solar_gate_enabled = true;
    float si_freeze_insol_low  = 0.22f;
    float si_freeze_insol_high = 0.45f;
    float si_solar_melt_start  = 0.28f;
    float si_solar_melt_gain   = 1.35f;
    float si_min_thick_ice_solar_exposure = 0.32f;
    float si_daily_delta_cap   = 0.070f;
    float si_edge_mix_rate     = 0.035f;
    float si_dt_days           = 1.0f;
    int   si_terrain_lake_id    = -1;
    int   si_terrain_sea_ice_id = -1;
    int   si_terrain_ocean_id   = -1;

    // ─── finalizer pass knobs（Stage 9，2026-06-16） ──────────────────────
    // 与 GDScript _apply_daily_climate_finalizer 一一对应：
    //   temp_cap_enabled = cp.thermal_final_delta_cap_enabled
    //   temp_cap         = cp.thermal_daily_delta_cap (默认 0.15)
    //   tta_cap          = cp.temperature_transport_anomaly_daily_cap (默认 0.12)
    //   has_temp_start   = _temp_start_of_day_arr.size() == n
    //   has_tta_start    = _tta_start_of_day_arr.size() == n
    bool  fin_temp_cap_enabled = true;
    float fin_temp_cap         = 0.15f;
    float fin_tta_cap          = 0.12f;
    bool  fin_has_temp_start   = false;
    bool  fin_has_tta_start    = false;

    // ─── passes_mask（plan §async-stage-2，2026-06-14） ──────────────────
    // bit-mask 控制 worker 跑哪几个 pass。kick 时 GDScript 传入。
    //   bit 0: pass_a
    //   bit 1: pass_b
    //   bit 2: ocean_water
    //   bit 3: ocean_land
    //   bit 4: wind_air
    //   bit 5: wind_surface
    //   bit 6: sea_ice
    //   bit 7: transp
    //   bit 8: finalizer (Stage 9，2026-06-16)
    // 默认 0x1FF 全开（含 finalizer）。Stage 2 A/B 验证时 bench 单独跑一个 pass，
    // 设 mask=0x01（仅 pass_a）或 0x100（仅 finalizer）。
    // Stage 2 期间 stub 的 pass（pass_b/ocean_*/wind_*/sea_ice）即使被 mask
    // 启用，worker 内部仍是 no-op；不会影响 A/B（验证字段不被它们触碰）。
    int    passes_mask = 0x1FF;
};

// 主线程序列化进 input_buf 的字段集合。所有 cell-level 数据都是 std::vector<float>
// 或 std::vector<uint8_t>，长度 = n_cells。
//
// Stage 1 范围内只列了 transpiration 实际读的 3 个字段（landform/vegetation/
// moisture），加上少量后续 stage 会用的字段占位。其余字段 Stage 2 时按需追加。
struct ClimateInputBuf {
    int n_cells = 0;

    // U8 cell-level（transp 用 + pass_a 用 is_water/terrain/cover + pass_b 用 landform/vegetation）
    std::vector<uint8_t> landform;         // transp: is_water iff lf <= 3；pass_b: LF_LOWLAND/PEAK 等判断
    std::vector<uint8_t> vegetation;       // transp: donor_table 索引；pass_b: foliage_table 索引
    std::vector<uint8_t> is_water;         // pass_a / pass_b 都用
    std::vector<uint8_t> terrain;          // pass_a 占位（实际未读，预留）
    std::vector<uint8_t> cover;            // pass_a 用：COVER_GLACIER 判断

    // U8 in/out — pass_a 既读 ema_initialized 又会把 0 置 1。stage 2 起按
    // in_buf 提供初值，pass_a 在 out_buf 里更新（避免 in/out aliasing）。
    std::vector<uint8_t> ema_initialized;

    // F32 cell-level（transp 读 moisture；pass_a 读静态字段 + 上次温度 / 雪 / 热能；
    // pass_b 读 temp 快照 + snow_cover + elev + lat + pos + insol_dev + tta + sif）
    std::vector<float>   moisture;         // transp 输入；pass_b 输入（read + write）
    std::vector<float>   elevation;        // pass_a / pass_b 读
    std::vector<float>   base_moisture;    // pass_a 读
    std::vector<float>   weather_vapor;    // pass_a: atmospheric anomaly source
    std::vector<float>   soil_moisture;    // pass_a: signed hydrology anomaly
    std::vector<float>   water_balance_30d;// pass_a: signed long-window anomaly
    std::vector<float>   lat_norm;         // pass_a / pass_b 读
    // [climate-zone-fix P2] 海洋性因子 ∈[0,1]，1=紧贴海岸/0=深内陆（由 dist_ocean 指数衰减得到）。
    // pass_a 用它对陆地缩小季节振幅，形成沿海小年较差（温带海洋性 Cfb）。缺省空→不调温。
    std::vector<float>   maritime;         // pass_a 读（静态）
    std::vector<float>   temp_baseline_year; // pass_a 读（静态 LUT）
    // pass_a 年均日照缓存（perf 2026-07-05, Item 4）：dc_insolation_annual_mean(clamp01(ny),
    // axial_tilt, daylen) 只依赖 lat + 两个行星常数，与 season 无关，故对每 cell 逐 tick 恒等。
    // async pass_a kernel 是 static free function、跑在 worker thread，无法安全触碰 member
    // 缓存 _insol_annual_mean_cache（会 data race）。改由主线程在 kick 快照时（持锁）预计算填此
    // 字段，worker 直接读 → bit-equal（同一 dc_insolation_annual_mean(dc_clamp01f(ny),...)）。
    // 空 → worker 回退 inline 重算（旧行为，向后兼容）。
    std::vector<float>   insol_annual_mean;  // pass_a 读（主线程预烘焙）
    std::vector<float>   temp;             // pass_a 读 prev_temp；pass_b 读 temp_snapshot
    std::vector<float>   temp_30d;         // pass_a 读：EMA prev
    std::vector<float>   temp_365d;        // pass_a 读：EMA prev
    std::vector<float>   thermal_energy;   // pass_a 读：prev_energy
    std::vector<float>   snowpack;         // pass_a 读：alpha 判断 + 计算 snow_cover
    std::vector<float>   radiative_modifier_add;    // pass_a: frozen Modifier add
    std::vector<float>   radiative_modifier_factor; // pass_a: frozen Modifier factor
    // pass_b 新增字段：
    std::vector<float>   pos_x;            // pass_b: 邻居方向计算；ocean_water/land 也用
    std::vector<float>   pos_y;            // pass_b; ocean_water/land 也用
    std::vector<float>   insolation_dev;   // pass_b: solar_factor
    std::vector<float>   temp_transport_anomaly; // pass_b: TTA 输入 (海岸 leak + evap)
    std::vector<float>   sea_ice_frac;     // pass_b: 海冰反照率冷却尾循环
    // local_thermal_anomaly: pass_b 在 in 上累加（in/out 都用）
    std::vector<float>   local_thermal_anomaly;
    // ocean_water/ocean_land 新增字段
    std::vector<float>   ocean_current_x;        // ocean_water/land: 邻居方向
    std::vector<float>   ocean_current_y;
    std::vector<float>   ocean_thermal_anomaly;  // ocean_water/land 都写（in/out）
    // wind_air / wind_surface 新增字段（Stage 2）
    std::vector<float>   wind_x;                 // wind_*: 邻居 advect direction
    std::vector<float>   wind_y;
    std::vector<float>   wind_speed;             // wind_*: speed_mix
    std::vector<float>   temp_baseline;          // wind_surface: 合成 cell_temp baseline
    std::vector<float>   air_mass_temp_anomaly;  // wind_air write / wind_surface read+write
    // sea_ice 新增字段（Stage 2）
    std::vector<uint8_t> base_terrain;     // sea_ice: 还原 base terrain when ice melts
    std::vector<float>   upwelling_strength; // sea_ice: 海水上涌冷却
    std::vector<float>   insolation_now;   // sea_ice: solar gate
    std::vector<float>   cell_temperature_arr; // sea_ice: 主线程传 climate/ocean-adjusted T
    std::vector<uint8_t> water_terrain_ids; // sea_ice: 256-entry water LUT 源
    std::vector<float>   sea_ice_frac_inout; // sea_ice: in/out（pass_b 也读它）
    // ─── finalizer pass 输入字段（Stage 9，2026-06-16） ─────────────────
    // 主线程在 begin_round 时把 round-start snapshot 传进来。worker finalizer
    // pass 用它做 clamp(temp - start ± temp_cap) + Δ 统计。GDScript 端的
    // _temp_start_of_day_arr / _tta_start_of_day_arr 一一对应。
    std::vector<float>   temp_start_of_day;     // finalizer: temp clamp baseline
    std::vector<float>   tta_start_of_day;      // finalizer: TTA clamp baseline
    std::vector<float>   sea_ice_frac_prev;     // finalizer: sea_ice_delta_max
    std::vector<float>   weather_precip;        // finalizer: precip_p95
    // ─── 后续 pass 占位 ──────────────────────────────────────────────────
    // 全部 9 pass 输入字段已覆盖

    // round-level scalars（在 kick 时设值）
    ClimateRoundScalars scalars;
};

// worker 写入的输出字段集合。同样只列 transp 真正会写的（moisture）+ Stage 2
// 后续追加。output buf 不持有 input copy，节省 220+ KB 内存。
struct ClimateOutputBuf {
    int n_cells = 0;

    // ─── pass_a 输出（Stage 2 实装） ────────────────────────────────────
    // 与 run_climate_pass_a 末尾 16 个 _flush_slot_to_map 一一对应：
    // moisture / snow_cover / temp_baseline / temp_season_offset /
    // ema_initialized / temp_30d / temp_365d / temp_anomaly / insolation_now /
    // insolation_dev / day_length / heat_input / thermal_energy / snowpack /
    // ocean_thermal_anomaly / local_thermal_anomaly
    //
    // 注意：transp 也写 moisture（覆盖 pass_a 的 moisture 输出）。Stage 2
    // 范围内 transp 在 pass_a 之后跑，但当前 worker loop pass_a 是 stub，
    // moisture 还是 transp 唯一写者。Stage 3 stub 替换后顺序自然处理。
    std::vector<float>   moisture;             // transp（Stage 1）& pass_a
    std::vector<float>   temp_baseline;
    std::vector<float>   temp_season_offset;
    std::vector<uint8_t> ema_initialized;
    std::vector<float>   temp_30d;
    std::vector<float>   temp_365d;
    std::vector<float>   temp_anomaly;
    std::vector<float>   insolation_now;
    std::vector<float>   insolation_dev;
    std::vector<float>   day_length;
    std::vector<float>   heat_input;
    std::vector<float>   thermal_energy;
    std::vector<float>   snowpack;
    std::vector<float>   ocean_thermal_anomaly;
    std::vector<float>   local_thermal_anomaly;
    // wind_air / wind_surface 输出（Stage 2）
    std::vector<float>   air_mass_temp_anomaly;   // wind_air write / wind_surface overwrite
    std::vector<float>   temp;                    // wind_surface 最终写 cell_temp (climate round 唯一)
    // sea_ice 输出（Stage 2）
    std::vector<float>   sea_ice_frac;            // sea_ice 写
    std::vector<uint8_t> terrain;                 // sea_ice 翻转写（apply_terrain_flips 时）

    // dirty 索引（transp 已计算过 dirty_indices/dirty_values，
    // 主线程 poll 时可一并取出做 mark_dirty_indexed 优化）
    std::vector<int32_t> moisture_dirty_indices;
    std::vector<float>   moisture_dirty_values;

    // ─── 占位（Stage 2 余下 pass 启用） ───────────────────────────────────
    // pass_b 输出：local_thermal_anomaly（追加）/ moisture（覆盖）
    // ocean_water 输出：ocean_thermal_anomaly
    // ocean_land 输出：ocean_thermal_anomaly（累加）
    // wind_air 输出：air_mass_temp_anomaly
    // wind_surface 输出：temp（最终）/ air_mass_temp_anomaly
    // sea_ice 输出：sea_ice_frac / terrain（flip 事件需要单独输出列表）

    // sea_ice flip events（Stage 2 sea_ice 移植时启用）。主线程 poll 时
    // 据此调用 GDScript 端的 mark_terrain_dirty / atlas update 等钩子。
    std::vector<int32_t> flipped_cell_indices;
    std::vector<uint8_t> flipped_new_terrain;

    // ─── finalizer pass diag（Stage 9，2026-06-16） ─────────────────────
    // 与 GDScript _apply_daily_climate_finalizer 返回的 diag 字段一一对应。
    // worker 写完后主线程 poll 拿来填 _last_finalizer_diag，跳过同名 GDScript loop。
    // 全部 scalars / counters，无 PackedArray，poll 端 marshalling cost 可忽略。
    bool   fin_applied = false;
    float  fin_max_temp_delta = 0.0f;
    float  fin_p95_temp_delta = 0.0f;
    float  fin_p99_temp_delta = 0.0f;
    float  fin_preclamp_max_temp_delta = 0.0f;
    float  fin_preclamp_p99_temp_delta = 0.0f;
    int32_t fin_temp_delta_gt_005_count = 0;
    int32_t fin_temp_delta_gt_010_count = 0;
    int32_t fin_temp_delta_gt_020_count = 0;
    int32_t fin_temp_delta_clamped_count = 0;
    float  fin_max_transport_anomaly = 0.0f;
    int32_t fin_tta_clamped_count = 0;
    int32_t fin_thermal_init_count = 0;
    float  fin_sea_ice_delta_max = 0.0f;
    float  fin_precip_p95 = 0.0f;
    int32_t fin_cells_seen = 0;
    // finalizer 写出的 final TTA（in/out aliasing，独立 buffer 避免和 wind_air 输出冲突）
    std::vector<float> tta_final;
};

// worker 私有临时 buffer（一次 alloc，round 间复用）。所有 pass 都从这里
// 借用 scratch 空间，不在 worker 回调内重新 resize（除非 n_cells 变了）。
struct ClimateWorkBuf {
    int n_cells = 0;
    std::vector<float> deltas;          // transp Phase 1 累加器
    std::vector<float> scratch_a;       // 后续 pass 复用
    std::vector<float> scratch_b;
    // ocean pass 内部 anomaly_inout buffer（temp_transport_anomaly per-round 累加器）。
    // ocean_water 写 water cells，ocean_land 读 water cells + 写 land cells。
    // Stage 2 期间它就是 TTA 字段在 round 内的状态——pass_b 也用这个传给 TTA 读取。
    std::vector<float> ocean_tta_inout;
};

// round-invariant 静态数据（neighbor_indices / donor_table / foliage_table），
// 在 bind_map_data 之后由 GDScript 调 set_static_knobs 注入一次。round 间复用。
struct ClimateRoundStaticKnobs {
    int                  n_cells = 0;
    std::vector<int32_t> neighbor_indices;   // size = n_cells * 6
    std::vector<float>   donor_table;        // 蒸腾贡献率（按 vegetation enum）
    std::vector<float>   foliage_table;      // pass_b 用（Stage 2）
    std::vector<float>   albedo_table;       // weather/climate 用（Stage 2）
};

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

// ─── Pure kernels（worker 线程跑，零 Godot API） ─────────────────────────

// pass_a pure kernel — 移植自 DCWorldExt::run_climate_pass_a（world_ext.cpp:2096）。
// 算法逐行 1:1 镜像 sync 路径 line 2293-2417 的 run_range lambda body：
//   - 每 cell 独立（无邻居 gather，无跨 cell 写）
//   - 用 dc_* helper（dc_insolation_now / dc_clamp01f / dc_clampf 等），它们已经
//     是 pure inline 函数，worker 安全调用
//   - 末尾把 ocean_anom / local_anom 清 0（开启新一日累加，与 sync line 2393-2394 一致）
//
// 输入：in.{is_water, terrain, cover, ema_initialized, moisture, elevation,
//           base_moisture, lat_norm, temp_baseline_year, temp, temp_30d, temp_365d,
//           thermal_energy, snowpack} + in.scalars
// 输出：out.{moisture, snow_cover, temp_baseline, temp_season_offset,
//            ema_initialized, temp_30d, temp_365d, temp_anomaly,
//            insolation_now, insolation_dev, day_length, heat_input,
//            thermal_energy, snowpack, ocean_thermal_anomaly, local_thermal_anomaly}
//
// 注意：sync 路径直接 ptrw() 写 _slots（同一 buffer in/out 别名）。pure kernel
// 严格分 in/out，避免 worker 看到自己上一 cell 写的中间状态——因为 pass_a 每个
// cell 独立，**没有 in-place 依赖**，分 in/out 不影响 bit-equal。
static bool _async_pass_a_kernel_pure(const ClimateInputBuf &in,
                                      ClimateOutputBuf &out) {
    const int n = in.n_cells;
    if (n <= 0) return false;
    // 输入维度校验
    if ((int)in.is_water.size()           != n) return false;
    if ((int)in.cover.size()              != n) return false;
    if ((int)in.ema_initialized.size()    != n) return false;
    if ((int)in.elevation.size()          != n) return false;
    if ((int)in.base_moisture.size()      != n) return false;
    if ((int)in.lat_norm.size()           != n) return false;
    if ((int)in.temp_baseline_year.size() != n) return false;
    if ((int)in.temp.size()               != n) return false;
    if ((int)in.temp_30d.size()           != n) return false;
    if ((int)in.temp_365d.size()          != n) return false;
    if ((int)in.thermal_energy.size()     != n) return false;
    if ((int)in.snowpack.size()           != n) return false;

    // ── scalars ──
    const float season_phase = (float)in.scalars.season_phase;
    const float axial_tilt_deg = (float)in.scalars.axial_tilt_deg;
    const float daylen_amp     = (float)in.scalars.day_length_gain;
    const float solar_gain     = (float)in.scalars.solar_gain;
    const float insol_amp      = (float)in.scalars.insol_amp;
    const float insol_gain     = (float)in.scalars.insol_gain;
    const float insol_amp_gain = insol_amp * insol_gain;
    const float land_continentality = 1.0f;  // compatibility field; pass-A helper ignores it
    const float moisture_relax = dc_clampf(in.scalars.runtime_moisture_base_relax_rate, 0.0f, 1.0f);
    const float moisture_vapor_w = dc_clampf(in.scalars.runtime_moisture_weather_vapor_weight, 0.0f, 1.0f);
    const float moisture_precip_w = dc_clampf(in.scalars.runtime_moisture_precip_weight, 0.0f, 2.5f);
    const float moisture_soil_w = dc_clampf(in.scalars.runtime_moisture_soil_weight, 0.0f, 2.5f);
    const float moisture_soil_dry_w = dc_clampf(in.scalars.runtime_moisture_soil_dry_weight, 0.0f, 2.5f);
    const float moisture_wb_w = dc_clampf(in.scalars.runtime_moisture_water_balance_weight, 0.0f, 2.5f);
    const float moisture_wb_dry_w = dc_clampf(in.scalars.runtime_moisture_water_balance_dry_weight, 0.0f, 2.5f);
    const float insol_dev_min  = (float)in.scalars.insol_dev_min;
    const float insol_dev_max  = (float)in.scalars.insol_dev_max;
    const float thermal_land   = (float)in.scalars.thermal_inertia_land;
    const float thermal_water  = (float)in.scalars.thermal_inertia_water;
    const float thermal_snow   = (float)in.scalars.thermal_inertia_snow;
    const float thermal_high   = (float)in.scalars.thermal_inertia_high_mountain;
    const float thermal_delta_cap = (float)in.scalars.thermal_daily_delta_cap;
    // 加速/跳日补偿：α 与 delta_cap 按经过天数积分（dt<=1 退化为原值）。
    float thermal_dt = (float)in.scalars.thermal_dt_days;
    if (thermal_dt < 1.0f) thermal_dt = 1.0f;
    else if (thermal_dt > 30.0f) thermal_dt = 30.0f;
    const float moisture_relax_eff = 1.0f - std::pow(1.0f - moisture_relax, thermal_dt);
    const float thermal_land_eff  = pk_thermal_alpha_eff(thermal_land,  thermal_dt);
    const float thermal_water_eff = pk_thermal_alpha_eff(thermal_water, thermal_dt);
    const float thermal_snow_eff  = pk_thermal_alpha_eff(thermal_snow,  thermal_dt);
    const float thermal_high_eff  = pk_thermal_alpha_eff(thermal_high,  thermal_dt);
    const float thermal_delta_cap_eff = thermal_delta_cap * thermal_dt;
    const float snowpack_cover_low  = (float)in.scalars.snowpack_cover_low;
    const float snowpack_cover_full = (float)in.scalars.snowpack_cover_full;
    const float sea_level = (float)in.scalars.sea_level;
    int days_per_year = in.scalars.days_per_year;
    if (days_per_year < 1) days_per_year = 1;
    else if (days_per_year > 3660) days_per_year = 3660;
    const float annual_ema_alpha = 1.0f / float(days_per_year);

    constexpr uint8_t COVER_GLACIER = 2;

    // ── 输出 resize ──
    auto ensure_f32 = [n](std::vector<float> &v) {
        if ((int)v.size() != n) v.resize(n);
    };
    auto ensure_u8 = [n](std::vector<uint8_t> &v) {
        if ((int)v.size() != n) v.resize(n);
    };
    ensure_f32(out.moisture);
    ensure_f32(out.temp_baseline);
    ensure_f32(out.temp_season_offset);
    ensure_u8(out.ema_initialized);
    ensure_f32(out.temp_30d);
    ensure_f32(out.temp_365d);
    ensure_f32(out.temp_anomaly);
    ensure_f32(out.insolation_now);
    ensure_f32(out.insolation_dev);
    ensure_f32(out.day_length);
    ensure_f32(out.heat_input);
    ensure_f32(out.thermal_energy);
    ensure_f32(out.snowpack);
    ensure_f32(out.ocean_thermal_anomaly);
    ensure_f32(out.local_thermal_anomaly);

    // ── 输入指针 ──
    const uint8_t *IW = in.is_water.data();
    const uint8_t *COV = in.cover.data();
    const uint8_t *EI_IN = in.ema_initialized.data();
    const float *PE = in.elevation.data();
    const float *PBM = in.base_moisture.data();
    const float *PWEATHERV = ((int)in.weather_vapor.size() == n) ? in.weather_vapor.data() : nullptr;
    const float *PPRECIP = ((int)in.weather_precip.size() == n) ? in.weather_precip.data() : nullptr;
    const float *PSOIL = ((int)in.soil_moisture.size() == n) ? in.soil_moisture.data() : nullptr;
    const float *PWB = ((int)in.water_balance_30d.size() == n) ? in.water_balance_30d.data() : nullptr;
    const float *PLN = in.lat_norm.data();
    // Item 4：主线程预烘焙的年均日照 LUT（尺寸匹配才启用，否则 null → inline 回退）。
    const float *INSOL_MEAN_BAKED =
        ((int)in.insol_annual_mean.size() == n) ? in.insol_annual_mean.data() : nullptr;
    const float *PTY = in.temp_baseline_year.data();
    const float *PT_IN = in.temp.data();
    const float *P30_IN = in.temp_30d.data();
    const float *P365_IN = in.temp_365d.data();
    const float *PTH_IN = in.thermal_energy.data();
    const float *PSP_IN = in.snowpack.data();
    const float *PRAD_ADD = ((int)in.radiative_modifier_add.size() == n)
        ? in.radiative_modifier_add.data() : nullptr;
    const float *PRAD_FACTOR = ((int)in.radiative_modifier_factor.size() == n)
        ? in.radiative_modifier_factor.data() : nullptr;
    // [climate-zone-fix P2] 海洋性调温：per-cell maritime 因子 + 全局衰减比。缺省空/0→关闭。
    const float maritime_damp = (float)in.scalars.maritime_season_damp;
    const float *PMAR = ((int)in.maritime.size() == n) ? in.maritime.data() : nullptr;

    // ── 输出指针 ──
    float *PMOIST = out.moisture.data();
    float *PTB = out.temp_baseline.data();
    float *PSO = out.temp_season_offset.data();
    uint8_t *EI_OUT = out.ema_initialized.data();
    float *P30 = out.temp_30d.data();
    float *P365 = out.temp_365d.data();
    float *PA = out.temp_anomaly.data();
    float *PINSOL = out.insolation_now.data();
    float *PDEV = out.insolation_dev.data();
    float *PDAY = out.day_length.data();
    float *PHEAT = out.heat_input.data();
    float *PTHERM = out.thermal_energy.data();
    float *PSPOUT = out.snowpack.data();
    float *POANOM = out.ocean_thermal_anomaly.data();
    float *PLANOM = out.local_thermal_anomaly.data();

    // ── 主循环（1:1 镜像 sync run_range body） ──
    for (int i = 0; i < n; ++i) {
        const float ny = PLN[i];
        const float temp_year_lat = PTY[i];
        const float elevation = PE[i];
        const bool is_water = IW[i] != 0;

        // (a) dev_today + insolation
        const float ny_clamped = dc_clamp01f(ny);
        const float insol_now = dc_insolation_now(ny_clamped, season_phase, axial_tilt_deg, daylen_amp);
        // perf (Item 4, 2026-07-05): insol_mean 是年均、season-无关。主线程 kick 时已把
        // dc_insolation_annual_mean(dc_clamp01f(ny),...) 预烘焙进 in.insol_annual_mean（持锁、
        // 主线程算，避免 worker 触 member 缓存的 data race）。命中即读 → bit-equal；字段缺失/
        // 尺寸不符时回退 inline 重算（旧行为，向后兼容旧调用方）。
        const float insol_mean = INSOL_MEAN_BAKED
            ? INSOL_MEAN_BAKED[i]
            : dc_insolation_annual_mean(ny_clamped, axial_tilt_deg, daylen_amp);
        float dev_today = dc_insolation_season_dev(ny_clamped, insol_now, insol_mean);
        if (dev_today < insol_dev_min) dev_today = insol_dev_min;
        else if (dev_today > insol_dev_max) dev_today = insol_dev_max;
        const float day_length = dc_day_length_norm(ny_clamped, season_phase, axial_tilt_deg);
        const float heat_input = dc_clamp01f(insol_now * solar_gain);

        // (b) moisture: no direct insolation/season multiplier.
        float moisture_now;
        if (is_water) {
            moisture_now = PBM[i];
        } else {
            float bm = PBM[i];
            if (bm > 1.0f) bm = 1.0f;
            else if (bm < 0.0f) bm = 0.0f;
            float moisture_target = bm;
            if (PWEATHERV != nullptr) {
                const float vapor = dc_clampf(PWEATHERV[i], 0.0f, 1.0f);
                moisture_target += (vapor - bm * 0.15f) * moisture_vapor_w;
            }
            if (PPRECIP != nullptr) {
                moisture_target += dc_clampf(PPRECIP[i], 0.0f, 1.0f) * moisture_precip_w;
            }
            if (PSOIL != nullptr) {
                const float soil = dc_clampf(PSOIL[i], -0.5f, 0.5f);
                moisture_target += pk_signed_hydrology_contribution(
                    soil, moisture_soil_w, moisture_soil_dry_w);
            }
            if (PWB != nullptr) {
                const float wb = dc_clampf(PWB[i], -1.0f, 1.0f);
                moisture_target += pk_signed_hydrology_contribution(
                    wb, moisture_wb_w, moisture_wb_dry_w);
            }
            moisture_target = dc_clampf(moisture_target, 0.0f, 1.0f);
            const float previous = ((int)in.moisture.size() == n)
                ? dc_clampf(in.moisture[size_t(i)], 0.0f, 1.0f) : moisture_target;
            moisture_now = previous + (moisture_target - previous) * moisture_relax_eff;
        }

        // (c) temperature
        float temp_year = temp_year_lat - float(pk_alt_penalty(double(elevation), double(sea_level)));
        if (temp_year < 0.0f) temp_year = 0.0f;
        else if (temp_year > 1.0f) temp_year = 1.0f;
        // 物理化（2026-06-16）：季节项按吸收短波因子缩放（持久冰封→低吸收）。
        // 用【年均温度 P365_IN[i]】（上一步 temp_365d）作冰封代理，避免夏季融化正反馈失控。
        float season_offset = pk_season_offset_continental(insol_amp_gain, is_water, P365_IN[i], dev_today, land_continentality);
        // [climate-zone-fix P2] 沿海陆地海洋性调温：按距海衰减缩小季节振幅（冬暖夏凉），
        // 让温带海洋性(Cfb)在中纬沿海涌现。water/内陆(maritime≈0)不受影响。
        if (!is_water && PMAR != nullptr && maritime_damp > 0.0f) {
            season_offset *= (1.0f - maritime_damp * PMAR[i]);
        }
        float radiative_target = temp_year + season_offset;
        if (PRAD_ADD != nullptr) radiative_target += PRAD_ADD[i];
        if (PRAD_FACTOR != nullptr) radiative_target *= PRAD_FACTOR[i];
        if (radiative_target < 0.0f) radiative_target = 0.0f;
        else if (radiative_target > 1.0f) radiative_target = 1.0f;

        // (d) thermal inertia
        const float current_temp = PT_IN[i];
        float prev_energy = PTH_IN[i];
        if (EI_IN[i] == 0) {
            prev_energy = current_temp;
        }
        const float prev_temp = prev_energy;
        float alpha = thermal_land_eff;
        if (is_water) alpha = thermal_water_eff;
        else if (COV[i] == COVER_GLACIER) alpha = thermal_snow_eff;
        else if (PSP_IN[i] > snowpack_cover_low) alpha = thermal_snow_eff;
        else if (elevation > 0.70f) alpha = thermal_high_eff;
        const float heat_next = prev_energy + (radiative_target - prev_energy) * alpha;
        float temp_delta = heat_next - prev_temp;
        if (temp_delta > thermal_delta_cap_eff) temp_delta = thermal_delta_cap_eff;
        else if (temp_delta < -thermal_delta_cap_eff) temp_delta = -thermal_delta_cap_eff;
        float temp_now = prev_temp + temp_delta;
        if (temp_now < 0.0f) temp_now = 0.0f;
        else if (temp_now > 1.0f) temp_now = 1.0f;
        PTHERM[i] = heat_next;

        // (e) snowpack maintenance. Runtime visual snow cover is authored by
        // weather distribute; climate only keeps physical snowpack for thermal
        // inertia and pass-b albedo.
        // 注意：sync 路径中 psnowpack[i] 可能被改写（GLACIER min=0.80）。这里
        // 我们使用 out.snowpack（写回值），先 default 复制 in，再按需 clamp。
        float sp = PSP_IN[i];
        if (!is_water) {
            if (COV[i] == COVER_GLACIER && sp < 0.80f) {
                sp = 0.80f;
            }
        } else {
            sp = 0.0f;
        }
        PSPOUT[i] = sp;

        // (e) write outputs（pass_a 不再写 cell_temp，由 wind_surface 末端合成；
        // 这里 PMOIST/PTB/PSO/PINSOL/PDEV/PDAY/PHEAT 写入）
        PTB[i] = temp_now;
        POANOM[i] = 0.0f;     // pass_a 末尾清 0，开启新一日累加
        PLANOM[i] = 0.0f;
        PMOIST[i] = moisture_now;
        PSO[i] = season_offset;
        PINSOL[i] = insol_now;
        PDEV[i] = dev_today;
        PDAY[i] = day_length;
        PHEAT[i] = heat_input;

        // (f) EMA
        float m30, m365;
        if (EI_IN[i] == 0) {
            m30 = temp_now;
            m365 = temp_now;
            EI_OUT[i] = 1;
        } else {
            m30 = P30_IN[i] + (temp_now - P30_IN[i]) * (1.0f / 30.0f);
            m365 = P365_IN[i] + (temp_now - P365_IN[i]) * annual_ema_alpha;
            EI_OUT[i] = EI_IN[i];
        }
        P30[i] = m30;
        P365[i] = m365;
        PA[i] = m30 - m365;
    }
    return true;
}

// pass_b pure kernel — 移植自 DCWorldExt::run_climate_pass_b（world_ext.cpp:5256）。
// 算法逐行 1:1 镜像 sync 路径主循环（line 5399-5546）+ 海冰反照率尾循环（line 5552-5560）：
//   - 5 段决定：albedo / coastal heat leak / landform diurnal / evap / rain_shadow
//   - 写出 cell_local_thermal_anomaly（累加，clamp ±0.08）和 cell_moisture
//   - 海冰反照率尾循环只对水域 cell 写 LANOM
//
// 输入：in.{is_water, landform, vegetation, snow_cover, elevation, lat_norm,
//           pos_x, pos_y, insolation_dev, temp（snapshot 入参）, moisture（in/out）,
//           local_thermal_anomaly（in/out）, temp_transport_anomaly, sea_ice_frac} +
//      static knobs.{neighbor_indices, foliage_table} + scalars
// 输出：out.{moisture, local_thermal_anomaly}
//
// 注意：算法本体严格 1:1，与 sync 路径在同一 input 下输出 bit-equal。
// 海冰反照率尾循环（sync line 5548-5560）也实装。
static bool _async_pass_b_kernel_pure(const ClimateInputBuf &in,
                                      const ClimateRoundStaticKnobs &knobs,
                                      ClimateOutputBuf &out) {
    const int n = in.n_cells;
    if (n <= 0) return false;
    if ((int)in.is_water.size()       != n) return false;
    if ((int)in.landform.size()       != n) return false;
    if ((int)in.vegetation.size()     != n) return false;
    if ((int)in.snowpack.size()       != n) return false;
    if ((int)in.elevation.size()      != n) return false;
    if ((int)in.lat_norm.size()       != n) return false;
    if ((int)in.pos_x.size()          != n) return false;
    if ((int)in.pos_y.size()          != n) return false;
    if ((int)in.insolation_dev.size() != n) return false;
    if ((int)in.temp.size()           != n) return false;
    if ((int)in.moisture.size()       != n) return false;
    if ((int)in.local_thermal_anomaly.size() != n) return false;
    if ((int)in.temp_transport_anomaly.size() != n) return false;
    if ((int)knobs.neighbor_indices.size() < n * 6) return false;
    const int foliage_size = (int)knobs.foliage_table.size();
    if (foliage_size <= 0) return false;
    // sea_ice_frac 可选；尾循环要求 size == n_cells，否则跳过
    const bool sif_valid = ((int)in.sea_ice_frac.size() == n);

    // ── scalars ──
    const float winter_boost  = in.scalars.pb_winter_boost;
    const float snow_cool     = in.scalars.pb_snow_cool;
    const float veg_cool      = in.scalars.pb_veg_cool;
    const float diurnal_amp   = in.scalars.pb_diurnal_amp;
    const float evap_gain     = in.scalars.pb_evap_gain;
    const float rs_threshold  = in.scalars.pb_rs_threshold;
    const float rs_factor     = in.scalars.pb_rs_factor;
    const int   rs_lookback   = in.scalars.pb_rs_lookback;
    const float t_freeze      = in.scalars.pb_t_freeze;
    const float coupling_gain = in.scalars.pb_coupling_gain;
    const float coast_leak    = in.scalars.pb_coast_leak;
    const float sea_ice_albedo_cooling = in.scalars.pb_sea_ice_albedo_cooling;
    const double season_phase = in.scalars.season_phase;
    const float snowpack_cover_low = float(in.scalars.snowpack_cover_low);
    const float snowpack_cover_full = float(in.scalars.snowpack_cover_full);

    // ── 输出 buffer 准备 ──
    auto ensure_f32 = [n](std::vector<float> &v) {
        if ((int)v.size() != n) v.resize(n);
    };
    ensure_f32(out.moisture);
    ensure_f32(out.local_thermal_anomaly);

    // ── in.local_thermal_anomaly 是 in/out（pass_b 在它上面累加）。需要先 copy
    //    in → out，然后 pass_b 主循环在 out.local_thermal_anomaly 上累加。
    //    sync 路径对 LANOM 是直接 ptrw() 累加（in-place），等价于 in==out 别名。
    std::memcpy(out.local_thermal_anomaly.data(),
                in.local_thermal_anomaly.data(),
                n * sizeof(float));
    // moisture 也是 in/out（sync 路径 in-place 写）。先 copy 让算法在 out 上原位修改。
    std::memcpy(out.moisture.data(), in.moisture.data(), n * sizeof(float));

    // ── 输入指针 ──
    const uint8_t *IW = in.is_water.data();
    const uint8_t *LF = in.landform.data();
    const uint8_t *VG = in.vegetation.data();
    const float *SNOWPACK = in.snowpack.data();
    const float *ELEV = in.elevation.data();
    const float *LAT  = in.lat_norm.data();
    const float *POSX = in.pos_x.data();
    const float *POSY = in.pos_y.data();
    const float *INSOL_DEV = in.insolation_dev.data();
    const float *TS = in.temp.data();   // temp snapshot（pass_b 不写 temp）
    const float *TTA = in.temp_transport_anomaly.data();
    const float *SIF_PB = sif_valid ? in.sea_ice_frac.data() : nullptr;
    const int32_t *NB = knobs.neighbor_indices.data();
    const float *FOL = knobs.foliage_table.data();

    // ── 输出/累加目标指针 ──
    float *LANOM = out.local_thermal_anomaly.data();
    float *M = out.moisture.data();

    // LandformType.LF：与 sync 同 enum 序
    constexpr uint8_t LF_LOWLAND   = 5;
    constexpr uint8_t LF_MOUNTAIN  = 7;
    constexpr uint8_t LF_PEAK      = 8;
    constexpr uint8_t LF_DELTA     = 9;
    constexpr uint8_t LF_SALT_FLAT = 11;

    // ─── 主循环（1:1 镜像 sync line 5399-5546） ───
    for (int i = 0; i < n; ++i) {
        const bool is_water = IW[i] != 0;
        const float temp_now     = TS[i];
        const float moisture_now = M[i];
        float snow_cover = pk_snowpack_cover_for_albedo(SNOWPACK[i], snowpack_cover_low, snowpack_cover_full);
        if (!is_water && in.cover.size() == n && in.cover[i] == 2 && snow_cover < 0.80f) {
            snow_cover = 0.80f;
        }

        float d_albedo      = 0.0f;
        float d_coastal     = 0.0f;
        float d_landform    = 0.0f;
        float d_evap        = 0.0f;
        float d_rain_shadow = 1.0f;

        // ① albedo (land only)
        if (!is_water) {
            d_albedo = -snow_cool * snow_cover;
            const uint8_t veg_id = VG[i];
            const float foliage = (veg_id < foliage_size) ? FOL[veg_id] : 0.0f;
            d_albedo -= veg_cool * foliage;
        }

        // ② coastal heat leak (land only, using TTA snapshot)
        if (!is_water) {
            float sum_anomaly = 0.0f;
            int   n_water     = 0;
            const int base = i * 6;
            for (int d = 0; d < 6; ++d) {
                const int32_t ni = NB[base + d];
                if (ni < 0) continue;
                if (IW[ni] != 0) {
                    sum_anomaly += TTA[ni];
                    n_water += 1;
                }
            }
            if (n_water > 0) {
                d_coastal = coast_leak * (sum_anomaly / float(n_water)) * winter_boost;
            }
        }

        // ③ landform diurnal (land only)
        if (!is_water) {
            const uint8_t lf = LF[i];
            const float solar_factor = std::clamp(INSOL_DEV[i], -1.0f, 1.0f);
            if (lf == LF_LOWLAND || lf == LF_SALT_FLAT || lf == LF_DELTA) {
                d_landform = diurnal_amp * solar_factor;
            } else if (lf == LF_PEAK || lf == LF_MOUNTAIN) {
                d_landform = -diurnal_amp * 0.5f * std::max(0.0f, -solar_factor);
            }
        }

        // ④ A 修复（2026-06）：累加到 LANOM (clamp ±0.08)
        float local_anom_contrib = d_albedo + d_coastal + d_landform;
        if (local_anom_contrib < -0.08f) local_anom_contrib = -0.08f;
        else if (local_anom_contrib > 0.08f) local_anom_contrib = 0.08f;
        LANOM[i] = LANOM[i] + local_anom_contrib;
        if (LANOM[i] < -0.08f) LANOM[i] = -0.08f;
        else if (LANOM[i] > 0.08f) LANOM[i] = 0.08f;
        float temp_final = temp_now + local_anom_contrib;
        if (temp_final < 0.0f) temp_final = 0.0f;
        else if (temp_final > 1.0f) temp_final = 1.0f;

        // ⑤ evap (land only)
        if (!is_water) {
            const float t_eff = temp_final + TTA[i];
            float water_neighbor_w = 0.0f;
            float sum_water_anomaly = 0.0f;
            const int bo = i * 6;
            for (int d = 0; d < 6; ++d) {
                const int32_t ni = NB[bo + d];
                if (ni < 0) continue;
                if (IW[ni] != 0) {
                    water_neighbor_w += 1.0f;
                    sum_water_anomaly += TTA[ni];
                }
            }
            float avg_water_anomaly = 0.0f;
            if (water_neighbor_w > 0.0f) {
                avg_water_anomaly = sum_water_anomaly / water_neighbor_w;
            }
            float nb_w_norm = water_neighbor_w / 6.0f;
            if (nb_w_norm > 1.0f) nb_w_norm = 1.0f;
            if (t_eff > t_freeze && nb_w_norm > 0.0f) {
                d_evap = evap_gain * (t_eff - t_freeze) * nb_w_norm;
                if (coupling_gain > 0.0f && std::fabs(avg_water_anomaly) > 0.001f) {
                    float evap_mul = 1.0f + coupling_gain * avg_water_anomaly;
                    if (evap_mul < 0.0f) evap_mul = 0.0f;
                    else if (evap_mul > 2.0f) evap_mul = 2.0f;
                    d_evap *= evap_mul;
                }
            }
            if (avg_water_anomaly < -0.01f && nb_w_norm > 0.0f && coupling_gain > 0.0f) {
                d_evap += -evap_gain * (-avg_water_anomaly) * nb_w_norm * coupling_gain * 0.5f;
            }
        }

        // ⑥ rain shadow (land only, gated by rs_lookback>0)
        if (!is_water && rs_lookback > 0) {
            const double ny = double(LAT[i]);
            double w_dx = 0.0, w_dy = 0.0;
            wind_belt_at(ny, season_phase, &w_dx, &w_dy);
            const double wlen2 = w_dx * w_dx + w_dy * w_dy;
            if (wlen2 > 1e-6) {
                float max_upwind_h = ELEV[i];
                int probe_idx = i;
                for (int step = 0; step < rs_lookback; ++step) {
                    int   best_idx = -1;
                    double best_dot = 0.1;
                    const float pwx = POSX[probe_idx];
                    const float pwy = POSY[probe_idx];
                    const int pbase = probe_idx * 6;
                    for (int d3 = 0; d3 < 6; ++d3) {
                        const int32_t ni3 = NB[pbase + d3];
                        if (ni3 < 0) continue;
                        const double dx = double(pwx) - double(POSX[ni3]);
                        const double dy = double(pwy) - double(POSY[ni3]);
                        const double len2 = dx * dx + dy * dy;
                        if (len2 < 1e-6) continue;
                        const double inv_len = 1.0 / std::sqrt(len2);
                        const double dotv = (dx * w_dx + dy * w_dy) * inv_len;
                        if (dotv > best_dot) {
                            best_dot = dotv;
                            best_idx = ni3;
                        }
                    }
                    if (best_idx < 0) break;
                    probe_idx = best_idx;
                    if (ELEV[probe_idx] > max_upwind_h) {
                        max_upwind_h = ELEV[probe_idx];
                    }
                }
                if (max_upwind_h - ELEV[i] >= rs_threshold) {
                    d_rain_shadow = rs_factor;
                }
            }
        }

        // ⑦ write moisture
        float moisture_final = (moisture_now + d_evap) * d_rain_shadow;
        if (moisture_final < 0.0f) moisture_final = 0.0f;
        else if (moisture_final > 1.0f) moisture_final = 1.0f;
        M[i] = moisture_final;
    }

    // ─── 海冰反照率→温度反馈尾循环（仅水域，1:1 sync line 5552-5560） ───
    if (sea_ice_albedo_cooling > 0.0f && SIF_PB != nullptr) {
        for (int i = 0; i < n; ++i) {
            if (IW[i] == 0) continue;
            float water_local = LANOM[i] - sea_ice_albedo_cooling * SIF_PB[i];
            if (water_local < -0.08f) water_local = -0.08f;
            else if (water_local > 0.08f) water_local = 0.08f;
            LANOM[i] = water_local;
        }
    }
    return true;
}

// ocean_water pure kernel — 移植自 DCWorldExt::run_ocean_water_pass（world_ext.cpp:4558）。
// 算法逐行 1:1 镜像 sync 路径（line 4655-4708）：
//   - 仅 water cell：沿 -current 方向回溯 advect_steps 步，找最对齐邻居
//   - temp_mixed = lerp(temp_self, temp_up, heat_mix)，clamp [0,1]
//   - 写 ocean_thermal_anomaly slot = clamp(temp_mixed - baseline, ±0.08)
//   - 用 dc_stabilize_tta / dc_decay_tta 更新 work.ocean_tta_inout（per-cell TTA）
//
// 输入：in.{is_water, pos_x, pos_y, ocean_current_x, ocean_current_y} + scalars
// work：work.ocean_tta_inout（in/out 累加器，pass_b 也会读它作为 TTA snapshot）
// 输出：out.ocean_thermal_anomaly（写 water cells）
//
// 注意：sync 路径接 `baseline_arr` / `temp_before_arr` knobs，但本 kernel 把
// baseline 等同于 cell_temp_baseline (in.temp_baseline)，temp_before 等同于
// in.temp（pre-pass_a 快照）。这与 sync 路径同语义（caller 都用 baseline=
// temp_baseline_a 或 EMA-init 时算的派生值；temp_before=temp_a or baseline）。
// Stage 2 期间 sync 端 caller 仍传 baseline_arr/temp_before_arr knobs，所以
// async 这里直接复用 in.temp_baseline_year / in.temp 做参考——bench 时主线程
// 把 sync 端用到的 baseline/temp_before 一并传过来。
static bool _async_ocean_water_kernel_pure(const ClimateInputBuf &in,
                                           const ClimateRoundStaticKnobs &knobs,
                                           ClimateWorkBuf &work,
                                           ClimateOutputBuf &out) {
    const int n = in.n_cells;
    if (n <= 0) return false;
    if ((int)in.is_water.size()        != n) return false;
    if ((int)in.pos_x.size()           != n) return false;
    if ((int)in.pos_y.size()           != n) return false;
    if ((int)in.ocean_current_x.size() != n) return false;
    if ((int)in.ocean_current_y.size() != n) return false;
    if ((int)in.temp.size()            != n) return false;
    if ((int)in.temp_baseline_year.size() != n) return false;
    if ((int)in.sea_ice_frac.size()    != n) return false;
    if ((int)in.ocean_thermal_anomaly.size() != n) return false;
    if ((int)knobs.neighbor_indices.size() < n * 6) return false;

    const int advect_steps = in.scalars.ow_advect_steps;
    const float heat_mix   = in.scalars.ow_heat_mix;
    const float tta_source_cap = dc_clampf(in.scalars.ow_tta_source_cap, 0.0f, 0.5f);
    const float tta_blend_rate = dc_clampf(in.scalars.ow_tta_blend_rate, 0.0f, 1.0f);
    const float tta_zero_current_decay = dc_clampf(in.scalars.ow_tta_zero_current_decay, 0.0f, 1.0f);

    // 输出
    if ((int)out.ocean_thermal_anomaly.size() != n) out.ocean_thermal_anomaly.resize(n);
    // ocean_water 累加到 ocean_thermal_anomaly slot；首先 copy in → out 作为基础。
    std::memcpy(out.ocean_thermal_anomaly.data(),
                in.ocean_thermal_anomaly.data(),
                n * sizeof(float));

    // work.ocean_tta_inout：sync 路径的 anomaly_out。round 入口处由主线程从
    // map.temperature_transport_anomaly_arr 初始化（kick 写 in.temp_transport_anomaly），
    // worker 入口再 copy 到 work scratch。
    if ((int)work.ocean_tta_inout.size() != n) work.ocean_tta_inout.resize(n);
    std::memcpy(work.ocean_tta_inout.data(),
                in.temp_transport_anomaly.data(),
                n * sizeof(float));

    const uint8_t *IW = in.is_water.data();
    const float *POSX = in.pos_x.data();
    const float *POSY = in.pos_y.data();
    const float *OCX  = in.ocean_current_x.data();
    const float *OCY  = in.ocean_current_y.data();
    const float *TB   = in.temp.data();              // temp_before snapshot
    const float *BL   = in.temp_baseline_year.data();// baseline (与 sync 同源)
    const float *SIF  = in.sea_ice_frac.data();
    const int32_t *NB = knobs.neighbor_indices.data();

    float *AOUT = work.ocean_tta_inout.data();
    float *OANOM = out.ocean_thermal_anomaly.data();

    for (int i = 0; i < n; ++i) {
        if (IW[i] == 0) continue; // skip land
        const float cur_x = OCX[i];
        const float cur_y = OCY[i];
        const float cur_len2 = cur_x * cur_x + cur_y * cur_y;
        if (cur_len2 < 1e-6f || advect_steps == 0) {
            AOUT[i] = dc_decay_tta(AOUT[i], tta_zero_current_decay);
            OANOM[i] = OANOM[i] * (1.0f - tta_zero_current_decay);
            continue;
        }
        const float inv_cur = 1.0f / std::sqrt(cur_len2);
        const float up_dx = -cur_x * inv_cur;
        const float up_dy = -cur_y * inv_cur;

        int upstream_idx = i;
        for (int step = 0; step < advect_steps; ++step) {
            int   best_idx = -1;
            float best_dot = 0.1f;
            const float swx = POSX[upstream_idx];
            const float swy = POSY[upstream_idx];
            const int ub = upstream_idx * 6;
            for (int d = 0; d < 6; ++d) {
                const int32_t ni = NB[ub + d];
                if (ni < 0) continue;
                if (IW[ni] == 0) continue;
                const float dx = POSX[ni] - swx;
                const float dy = POSY[ni] - swy;
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

        const float temp_self = TB[i];
        const float temp_up   = TB[upstream_idx];
        float temp_mixed = temp_self + (temp_up - temp_self) * heat_mix;
        if (temp_mixed < 0.0f) temp_mixed = 0.0f;
        else if (temp_mixed > 1.0f) temp_mixed = 1.0f;
        float source = temp_mixed - BL[i];
        source = pk_limit_cold_water_positive_transport_source(
            source, BL[i], SIF[i], in.scalars.si_t_form, in.scalars.si_t_melt);
        float oanom = source;
        if (oanom < -0.08f) oanom = -0.08f;
        else if (oanom > 0.08f) oanom = 0.08f;
        OANOM[i] = oanom;
        AOUT[i] = dc_stabilize_tta(AOUT[i], source, tta_source_cap, tta_blend_rate);
    }
    return true;
}

// ocean_land pure kernel — 移植自 DCWorldExt::run_ocean_land_pass（world_ext.cpp:4736）。
// 算法逐行 1:1 镜像 sync 主循环（line 4831-4871）：
//   - 仅 land cell：在 6 邻居里取 water cell，按 dot(self→nb, nb_current) 加权
//   - anomaly_in = dc_decay_tta(prev) 或 dc_stabilize_tta(prev, weighted_avg * eff_leak, ...)
//   - 写 work.ocean_tta_inout[i]
//   - if |anomaly_in| > 1e-5 → 累加到 out.ocean_thermal_anomaly[i]（clamp ±0.08）
//
// 注意：必须在 ocean_water 之后跑，依赖 work.ocean_tta_inout 里 water cells 的
// fresh anomaly（ocean_water 已写）。
static bool _async_ocean_land_kernel_pure(const ClimateInputBuf &in,
                                          const ClimateRoundStaticKnobs &knobs,
                                          ClimateWorkBuf &work,
                                          ClimateOutputBuf &out) {
    const int n = in.n_cells;
    if (n <= 0) return false;
    if ((int)in.is_water.size()        != n) return false;
    if ((int)in.pos_x.size()           != n) return false;
    if ((int)in.pos_y.size()           != n) return false;
    if ((int)in.ocean_current_x.size() != n) return false;
    if ((int)in.ocean_current_y.size() != n) return false;
    if ((int)knobs.neighbor_indices.size() < n * 6) return false;
    if ((int)work.ocean_tta_inout.size() != n) return false;

    const float effective_leak = in.scalars.ol_effective_leak;
    const float tta_source_cap = dc_clampf(in.scalars.ol_tta_source_cap, 0.0f, 0.5f);
    const float tta_blend_rate = dc_clampf(in.scalars.ol_tta_blend_rate, 0.0f, 1.0f);
    const float tta_decay_rate = dc_clampf(in.scalars.ol_tta_decay_rate, 0.0f, 1.0f);

    if ((int)out.ocean_thermal_anomaly.size() != n) {
        // 防御：若 ocean_water 没跑，则用 in.ocean_thermal_anomaly 作为基础
        out.ocean_thermal_anomaly.resize(n);
        std::memcpy(out.ocean_thermal_anomaly.data(),
                    in.ocean_thermal_anomaly.data(),
                    n * sizeof(float));
    }

    const uint8_t *IW = in.is_water.data();
    const float *POSX = in.pos_x.data();
    const float *POSY = in.pos_y.data();
    const float *OCX  = in.ocean_current_x.data();
    const float *OCY  = in.ocean_current_y.data();
    const int32_t *NB = knobs.neighbor_indices.data();
    float *A = work.ocean_tta_inout.data();
    float *OANOM = out.ocean_thermal_anomaly.data();

    for (int i = 0; i < n; ++i) {
        if (IW[i] != 0) continue; // skip water
        const float swx = POSX[i];
        const float swy = POSY[i];
        float weighted_sum = 0.0f;
        float weight_total = 0.0f;
        const int b = i * 6;
        for (int d = 0; d < 6; ++d) {
            const int32_t ni = NB[b + d];
            if (ni < 0) continue;
            if (IW[ni] == 0) continue; // only water nb contributes
            const float cx = OCX[ni];
            const float cy = OCY[ni];
            if (cx * cx + cy * cy < 1e-6f) continue;
            const float dx = swx - POSX[ni];
            const float dy = swy - POSY[ni];
            const float dlen2 = dx * dx + dy * dy;
            if (dlen2 < 1e-6f) continue;
            const float inv_len = 1.0f / std::sqrt(dlen2);
            const float dot_v = (dx * cx + dy * cy) * inv_len;
            if (dot_v <= 0.0f) continue;
            weighted_sum += A[ni] * dot_v;
            weight_total += dot_v;
        }
        const float prev_anomaly = A[i];
        float anomaly_in = dc_decay_tta(prev_anomaly, tta_decay_rate);
        if (weight_total > 0.0f) {
            anomaly_in = dc_stabilize_tta(
                prev_anomaly, (weighted_sum / weight_total) * effective_leak,
                tta_source_cap, tta_blend_rate);
        }
        A[i] = anomaly_in;
        if ((anomaly_in < 0.0f ? -anomaly_in : anomaly_in) > 1e-5f) {
            float oanom = OANOM[i] + anomaly_in;
            if (oanom < -0.08f) oanom = -0.08f;
            else if (oanom > 0.08f) oanom = 0.08f;
            OANOM[i] = oanom;
        }
    }
    return true;
}

// wind_air pure kernel — 移植自 DCWorldExt::run_wind_air_mass_pass（world_ext.cpp:4887）。
// 算法逐行 1:1 镜像 sync 主循环（line 4963-5009）：
//   - 每 cell：A[i] = 0
//   - 若 wind_speed^2 < 1e-6 或 advect_steps==0：跳过（A=0）
//   - 否则沿 -wind 方向回溯 advect_steps 步找最对齐邻居（**不限 water**——
//     与 sync 路径一致；与 ocean_water 限 water 不同）
//   - temp_mixed = lerp(temp_self, temp_up, heat_mix * speed_mix)
//     speed_mix = clamp(wf_wind_speed_norm(...) / 1.2, 0.25, 1.35)
//   - A[i] = temp_mixed - baseline
//
// 输入：in.{wind_x, wind_y, wind_speed, pos_x, pos_y, temp（snapshot）,
//           temp_baseline_year（作 baseline_arr）} + scalars
// 输出：out.air_mass_temp_anomaly
static bool _async_wind_air_kernel_pure(const ClimateInputBuf &in,
                                        const ClimateRoundStaticKnobs &knobs,
                                        ClimateOutputBuf &out) {
    const int n = in.n_cells;
    if (n <= 0) return false;
    if ((int)in.wind_x.size()             != n) return false;
    if ((int)in.wind_y.size()             != n) return false;
    if ((int)in.wind_speed.size()         != n) return false;
    if ((int)in.pos_x.size()              != n) return false;
    if ((int)in.pos_y.size()              != n) return false;
    if ((int)in.temp.size()               != n) return false;
    if ((int)in.temp_baseline_year.size() != n) return false;
    if ((int)knobs.neighbor_indices.size() < n * 6) return false;

    const int advect_steps = in.scalars.wa_advect_steps;
    const float heat_mix   = in.scalars.wa_heat_mix;

    if ((int)out.air_mass_temp_anomaly.size() != n) out.air_mass_temp_anomaly.resize(n);

    const float *WX  = in.wind_x.data();
    const float *WY  = in.wind_y.data();
    const float *WSP = in.wind_speed.data();
    const float *POSX = in.pos_x.data();
    const float *POSY = in.pos_y.data();
    const float *TB  = in.temp.data();
    const float *BL  = in.temp_baseline_year.data();
    const int32_t *NB = knobs.neighbor_indices.data();
    float *A = out.air_mass_temp_anomaly.data();

    for (int i = 0; i < n; ++i) {
        A[i] = 0.0f;

        const float wind_x = WX[i];
        const float wind_y = WY[i];
        const float wind_len2 = wind_x * wind_x + wind_y * wind_y;
        if (wind_len2 < 1e-6f || advect_steps == 0) continue;

        const float inv_wind_len = 1.0f / std::sqrt(wind_len2);
        const float up_dx = -wind_x * inv_wind_len;
        const float up_dy = -wind_y * inv_wind_len;

        int upstream_idx = i;
        for (int step = 0; step < advect_steps; ++step) {
            int best_idx = -1;
            float best_dot = 0.1f;
            const float swx = POSX[upstream_idx];
            const float swy = POSY[upstream_idx];
            const int ub = upstream_idx * 6;
            for (int d = 0; d < 6; ++d) {
                const int32_t ni = NB[ub + d];
                if (ni < 0) continue;
                const float dx = POSX[ni] - swx;
                const float dy = POSY[ni] - swy;
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

        const float temp_self = TB[i];
        const float temp_up   = TB[upstream_idx];
        // wf_wind_speed_norm（与 sync inline 同源）
        float speed = WSP[i];
        if (speed <= 0.0001f) {
            const float len2 = wind_x * wind_x + wind_y * wind_y;
            speed = (len2 > 0.0001f) ? std::sqrt(len2) : 0.0f;
        }
        float speed_mix = speed / 1.2f;
        if (speed_mix < 0.25f) speed_mix = 0.25f;
        else if (speed_mix > 1.35f) speed_mix = 1.35f;
        const float temp_mixed_raw = temp_self + (temp_up - temp_self) * heat_mix * speed_mix;
        A[i] = temp_mixed_raw - BL[i];
    }
    return true;
}

// wind_surface pure kernel — 移植自 DCWorldExt::run_wind_surface_pass（world_ext.cpp:5022）。
// 算法逐行 1:1 镜像 sync 主循环（line 5114-5166）：
//   - 每 cell：对 6 邻居计算 weight = dot(self→nb_pos, nb_wind) * speed_mix(nb)
//     speed_mix = clamp(wf_wind_speed_norm(nb_wind, nb_wind_speed) / 1.2, 0.20, 1.35)
//   - anomaly_in = (weighted_sum / weight_total) * air_leak，clamp ±0.08
//   - 写 out.air_mass_temp_anomaly[i] = anomaly_in（OVERWRITE 不累加）
//   - 合成 cell_temp = clamp(baseline + clamp(ocean_anom + air_anom, ±0.08)
//                     + local_anom, 0, 1)，总 anomaly 再 clamp ±0.15
//
// 依赖：必须在 pass_a / pass_b / ocean_water / ocean_land / wind_air 之后跑（依赖
// 它们写的 temp_baseline / ocean_thermal_anomaly / local_thermal_anomaly /
// air_mass_temp_anomaly 当前值）。
//
// 输入：in.{wind_x, wind_y, wind_speed, pos_x, pos_y, temp_baseline_year（备份 baseline）}
// in/out：out.{air_mass_temp_anomaly, temp_baseline, ocean_thermal_anomaly,
//              local_thermal_anomaly}（前序 pass 输出，wind_surface 读取做合成）
// 输出：out.{air_mass_temp_anomaly（覆写）, temp（最终温度）}
static bool _async_wind_surface_kernel_pure(const ClimateInputBuf &in,
                                            const ClimateRoundStaticKnobs &knobs,
                                            ClimateOutputBuf &out) {
    const int n = in.n_cells;
    if (n <= 0) return false;
    if ((int)in.wind_x.size()             != n) return false;
    if ((int)in.wind_y.size()             != n) return false;
    if ((int)in.wind_speed.size()         != n) return false;
    if ((int)in.pos_x.size()              != n) return false;
    if ((int)in.pos_y.size()              != n) return false;
    if ((int)in.temp_baseline_year.size() != n) return false;
    if ((int)knobs.neighbor_indices.size() < n * 6) return false;

    const float air_leak = in.scalars.ws_air_leak;
    const float cold_transport_form = in.scalars.ws_cold_transport_form;
    const float cold_transport_melt = in.scalars.ws_cold_transport_melt;

    // 准备 input snapshot：sync 路径用 anomaly_src.duplicate()（air_anom 旧值）
    // 作为读取来源，AOUT 作为新输出。但 wind_air 已写 out.air_mass_temp_anomaly。
    // 我们这里 AIN 用 in.air_mass_temp_anomaly（或 out.air_mass_temp_anomaly 如果非空），
    // AOUT 直接写 out.air_mass_temp_anomaly。复刻 sync 的 AIN/AOUT 分离。
    // Stage 2 bench 时主线程会传 in.air_mass_temp_anomaly = MapData.air_mass_temp_anomaly_arr。
    // Round 模式下（mask=0x30 + 上一 pass wind_air 跑过），out.air_mass_temp_anomaly 已是
    // wind_air 输出——但 sync 路径的 AIN 也是 wind_air 写完的值（slot 写后再读），所以
    // **正确做法是用 out.air_mass_temp_anomaly 作为 AIN**（如果它是 wind_air 输出的话）。
    // 决策：bench 时 mask=0x20（仅 wind_surface），主线程要把 sync 路径"wind_air 跑完之后"
    // 的 air_anom 传成 in.air_mass_temp_anomaly。该字段同时也是 out 的初值。
    if ((int)out.air_mass_temp_anomaly.size() != n) {
        out.air_mass_temp_anomaly.resize(n);
        if ((int)in.air_mass_temp_anomaly.size() == n) {
            std::memcpy(out.air_mass_temp_anomaly.data(),
                        in.air_mass_temp_anomaly.data(),
                        n * sizeof(float));
        }
    }
    if ((int)out.temp.size() != n) out.temp.resize(n);

    // 准备合成 baseline / oanom / lanom 输入。这些字段如果 out 已写则用 out 值；
    // 否则用 in 值（bench 模式：主线程把 sync 路径"pass_a/b/ocean_* 之后"的快照传过来）。
    auto choose_field = [n](const std::vector<float> &out_v,
                            const std::vector<float> &in_v) -> const float* {
        if ((int)out_v.size() == n) return out_v.data();
        if ((int)in_v.size()  == n) return in_v.data();
        return nullptr;
    };
    const float *BL_RUNTIME = choose_field(out.temp_baseline, in.temp_baseline);
    if (BL_RUNTIME == nullptr) {
        // 兜底：用 in.temp_baseline_year（年级 LUT）作为 fallback baseline
        BL_RUNTIME = in.temp_baseline_year.data();
    }
    const float *OANOM = choose_field(out.ocean_thermal_anomaly, in.ocean_thermal_anomaly);
    const float *LANOM = choose_field(out.local_thermal_anomaly, in.local_thermal_anomaly);
    const float *FBL = in.temp_baseline_year.data();  // fallback_baseline_arr

    // AIN：上一 pass wind_air 输出的 air anomaly。bench mask=0x20 时主线程把它
    // 装到 in.air_mass_temp_anomaly。
    // 注意：sync 路径 AIN 与 AOUT 是同 slot 的 in-place 别名读/写，因为
    // wind_surface 读 ni（邻居）的旧 air_anom 计算 weighted_sum，写 i 自己的
    // 新 air_anom。**邻居 ni 的写时序在 i 之前**（loop 顺序），所以 sync 实际是
    // 类似 Gauss-Seidel：当 i 处理时，nb_idx < i 的邻居用的是它们刚刚的新值，
    // nb_idx > i 用的是旧值。
    // 但 sync 用 anomaly_src.duplicate() → AIN 永远指向"调用前"的旧 air anomaly，
    // 即 wind_air 写完后的整套值，loop 内 ni 邻居读的是 AIN[ni] 旧值；
    // AOUT 写的是新值。这是 Jacobi 风格——pure kernel 必须严格遵守。
    std::vector<float> ain_snapshot;
    ain_snapshot.assign(out.air_mass_temp_anomaly.begin(), out.air_mass_temp_anomaly.end());
    const float *AIN = ain_snapshot.data();
    float *AOUT = out.air_mass_temp_anomaly.data();
    float *T_OUT = out.temp.data();

    const float *WX  = in.wind_x.data();
    const float *WY  = in.wind_y.data();
    const float *WSP = in.wind_speed.data();
    const float *POSX = in.pos_x.data();
    const float *POSY = in.pos_y.data();
    const int32_t *NB = knobs.neighbor_indices.data();

    for (int i = 0; i < n; ++i) {
        const float swx = POSX[i];
        const float swy = POSY[i];
        float weighted_sum = 0.0f;
        float weight_total = 0.0f;
        const int b = i * 6;
        for (int d = 0; d < 6; ++d) {
            const int32_t ni = NB[b + d];
            if (ni < 0) continue;
            const float wind_x = WX[ni];
            const float wind_y = WY[ni];
            if (wind_x * wind_x + wind_y * wind_y < 1e-6f) continue;
            const float dx = swx - POSX[ni];
            const float dy = swy - POSY[ni];
            const float len2 = dx * dx + dy * dy;
            if (len2 < 1e-6f) continue;
            const float inv_len = 1.0f / std::sqrt(len2);
            const float weight = (dx * wind_x + dy * wind_y) * inv_len;
            if (weight <= 0.0f) continue;
            // wf_wind_speed_norm(WX[ni], WY[ni], WSP[ni])
            float speed_nb = WSP[ni];
            if (speed_nb <= 0.0001f) {
                const float len2_nb = wind_x * wind_x + wind_y * wind_y;
                speed_nb = (len2_nb > 0.0001f) ? std::sqrt(len2_nb) : 0.0f;
            }
            float speed_w = speed_nb / 1.2f;
            if (speed_w < 0.20f) speed_w = 0.20f;
            else if (speed_w > 1.35f) speed_w = 1.35f;
            const float adv_weight = weight * speed_w;
            weighted_sum += AIN[ni] * adv_weight;
            weight_total += adv_weight;
        }

        // air-mass 平流
        float anomaly_in = 0.0f;
        if (weight_total > 0.0f) {
            anomaly_in = (weighted_sum / weight_total) * air_leak;
        }
        float air_final = anomaly_in;
        if (air_final < -0.08f) air_final = -0.08f;
        else if (air_final > 0.08f) air_final = 0.08f;
        AOUT[i] = air_final;

        // 合成 cell_temp：ocean 与 air 都是横向热输运，先共享同一 ±0.08 预算；
        // 对接近结冰线的水格，正向输运先被潜热/成冰门控吸收，避免无冰边缘水面
        // 被固定抬高到 melt 阈值以上而无法重新结冰。
        float base = BL_RUNTIME[i];
        // 0.0 is a valid frozen/polar-night runtime baseline; fall back only
        // when the runtime baseline is not a finite value.
        if (!std::isfinite(base)) base = FBL[i];
        float transport_anom = (OANOM ? OANOM[i] : 0.0f) + air_final;
        if ((int)in.is_water.size() == n && in.is_water[i] != 0 && transport_anom > 0.0f) {
            transport_anom *= pk_snowpack_cover_for_albedo(base, cold_transport_form, cold_transport_melt);
        }
        if (transport_anom < -0.08f) transport_anom = -0.08f;
        else if (transport_anom > 0.08f) transport_anom = 0.08f;
        float total_anom = transport_anom + (LANOM ? LANOM[i] : 0.0f);
        if (total_anom < -0.15f) total_anom = -0.15f;
        else if (total_anom > 0.15f) total_anom = 0.15f;
        float total = base + total_anom;
        if (total < 0.0f) total = 0.0f;
        else if (total > 1.0f) total = 1.0f;
        T_OUT[i] = total;
    }
    return true;
}

// sea_ice pure kernel — 移植自 DCWorldExt::run_sea_ice_daily_pass（world_ext.cpp:6784）。
// 算法逐行 1:1 镜像 sync 路径主循环：
//   Phase A：build has_cold_neighbor[]（前一日 SIF 邻居快照）
//   Phase B：fraction 增量更新 + flip 候选收集
//
// 关键依赖：
//   - is_water_lut（256-entry 表，由 water_terrain_ids 构建）
//   - cell_temperature_arr（climate/ocean 之后调整的 T——主线程算）
//   - sea_ice_freeze_gate / sea_ice_solar_melt（已有 inline helper，worker 安全）
//
// 输入：in.{terrain, base_terrain, sea_ice_frac_inout, temp_transport_anomaly,
//           ocean_thermal_anomaly, upwelling_strength, insolation_now, cell_temperature_arr,
//           water_terrain_ids} + scalars + static knobs.neighbor_indices
// 输出：out.{sea_ice_frac, terrain, flipped_cell_indices, flipped_new_terrain}
//
// 注意：flipped lists 主线程在 poll 时消费（atlas dirty / map.terrain mirror sync）。
// out.terrain 已包含翻转结果（与 in.terrain 不同），主线程 poll 写 _slots[cell_terrain]
// 时若 apply_terrain_flips 为 true 则会同步生效。
static bool _async_sea_ice_kernel_pure(const ClimateInputBuf &in,
                                       const ClimateRoundStaticKnobs &knobs,
                                       ClimateOutputBuf &out) {
    const int n = in.n_cells;
    if (n <= 0) return false;
    if ((int)in.terrain.size()               != n) return false;
    if ((int)in.base_terrain.size()          != n) return false;
    if ((int)in.sea_ice_frac_inout.size()    != n) return false;
    if ((int)in.temp_transport_anomaly.size() != n) return false;
    if ((int)in.ocean_thermal_anomaly.size()  != n) return false;
    if ((int)in.upwelling_strength.size()    != n) return false;
    if ((int)in.insolation_now.size()        != n) return false;
    if ((int)in.cell_temperature_arr.size()  != n) return false;
    if ((int)in.water_terrain_ids.size()     <= 0) return false;
    if ((int)knobs.neighbor_indices.size() < n * 6) return false;

    // ── scalars ──
    const float k_freeze    = in.scalars.si_k_freeze;
    const float k_melt      = in.scalars.si_k_melt;
    const float t_form      = in.scalars.si_t_form;
    const float t_melt      = in.scalars.si_t_melt;
    const float contagion   = in.scalars.si_contagion;
    const float threshold   = in.scalars.si_threshold;
    const float hysteresis  = in.scalars.si_hysteresis;
    const float ice_delay   = in.scalars.si_ice_delay;
    const bool  enable_oht  = in.scalars.si_enable_oht;
    const bool  apply_terrain_flips = in.scalars.si_apply_terrain_flips;
    const bool  solar_gate_enabled = in.scalars.si_solar_gate_enabled;
    const float freeze_insol_low = in.scalars.si_freeze_insol_low;
    const float freeze_insol_high = in.scalars.si_freeze_insol_high;
    const float solar_melt_start = in.scalars.si_solar_melt_start;
    const float solar_melt_gain  = in.scalars.si_solar_melt_gain;
    const float min_thick_ice_solar_exposure = in.scalars.si_min_thick_ice_solar_exposure;
    const float daily_delta_cap  = in.scalars.si_daily_delta_cap;
    float edge_mix_rate = in.scalars.si_edge_mix_rate;
    if (edge_mix_rate < 0.0f) edge_mix_rate = 0.0f;
    else if (edge_mix_rate > 0.20f) edge_mix_rate = 0.20f;
    float dt_days = in.scalars.si_dt_days;
    if (dt_days < 0.0f) dt_days = 0.0f;
    else if (dt_days > 30.0f) dt_days = 30.0f;
    const int   id_lake     = in.scalars.si_terrain_lake_id;
    const int   id_sea_ice  = in.scalars.si_terrain_sea_ice_id;
    const int   id_ocean    = in.scalars.si_terrain_ocean_id;

    // ── water LUT 构建 ──
    bool is_water_lut[256];
    for (int i = 0; i < 256; ++i) is_water_lut[i] = false;
    for (int k = 0; k < (int)in.water_terrain_ids.size(); ++k) {
        const int wid = int(in.water_terrain_ids[k]);
        if (wid >= 0 && wid < 256) is_water_lut[wid] = true;
    }

    // ── 输出 buffer ──
    if ((int)out.sea_ice_frac.size() != n) out.sea_ice_frac.resize(n);
    std::memcpy(out.sea_ice_frac.data(), in.sea_ice_frac_inout.data(), n * sizeof(float));
    if ((int)out.terrain.size() != n) out.terrain.resize(n);
    std::memcpy(out.terrain.data(), in.terrain.data(), n);
    out.flipped_cell_indices.clear();
    out.flipped_new_terrain.clear();

    const uint8_t *TR_IN = in.terrain.data();
    const uint8_t *BT = in.base_terrain.data();
    const float *T_IN = in.cell_temperature_arr.data();
    const float *TTA = in.temp_transport_anomaly.data();
    const float *OANOM = in.ocean_thermal_anomaly.data();
    const float *UPW = in.upwelling_strength.data();
    const float *INS = in.insolation_now.data();
    const int32_t *NB = knobs.neighbor_indices.data();
    float *SIF = out.sea_ice_frac.data();
    uint8_t *TR_OUT = out.terrain.data();

    std::vector<float> prev_sif(static_cast<size_t>(n), 0.0f);
    for (int i = 0; i < n; ++i) {
        prev_sif[static_cast<size_t>(i)] = SIF[i];
    }

    // ─── Phase A: has_cold_neighbor ───
    std::vector<uint8_t> has_cold_neighbor(n, 0);
    for (int i = 0; i < n; ++i) {
        if (!is_water_lut[TR_IN[i]]) continue;
        const int base = i * 6;
        bool any_cold = false;
        for (int d = 0; d < 6; ++d) {
            const int32_t ni = NB[base + d];
            if (ni < 0) continue;
            if (!is_water_lut[TR_IN[ni]]) continue;
            if (prev_sif[static_cast<size_t>(ni)] >= 0.6f) { any_cold = true; break; }
        }
        has_cold_neighbor[i] = any_cold ? 1 : 0;
    }

    // ─── Phase B: 主循环 + flip 候选收集 ───
    int flipped_count = 0;

    for (int i = 0; i < n; ++i) {
        const uint8_t terr = TR_IN[i];
        if (!is_water_lut[terr]) {
            SIF[i] = 0.0f;
            continue;
        }
        if (int(terr) == id_lake) {
            SIF[i] = 0.0f;
            continue;
        }

        const float temp_now = T_IN[i];
        float t_eff = temp_now;
        if (enable_oht) {
            const float tta_residual = sea_ice_positive_tta_residual(TTA[i], OANOM[i]);
            if (tta_residual > 0.0f) t_eff += ice_delay * tta_residual;
            const float upw = UPW[i];
            if (upw > 0.3f) t_eff -= 0.5f * upw;
        }
        if (t_eff < 0.0f) t_eff = 0.0f;
        else if (t_eff > 1.0f) t_eff = 1.0f;

        float k_freeze_eff = k_freeze;
        if (has_cold_neighbor[i]) {
            k_freeze_eff = k_freeze * (1.0f + contagion);
        }

        const float prev_frac = prev_sif[static_cast<size_t>(i)];

        const float diff_freeze = (t_form > t_eff) ? (t_form - t_eff) : 0.0f;
        const float diff_melt   = (t_eff > t_melt) ? (t_eff - t_melt) : 0.0f;
        float freeze_gate = 1.0f;
        float solar_melt = 0.0f;
        if (solar_gate_enabled) {
            const float insolation_now = INS[i];
            freeze_gate = sea_ice_freeze_gate(insolation_now, freeze_insol_low, freeze_insol_high);
            solar_melt = sea_ice_solar_melt(insolation_now, solar_melt_start, solar_melt_gain)
                * sea_ice_solar_exposure(prev_frac, min_thick_ice_solar_exposure);
        }
        // [seaice dt 修复 2026-06-16] daily_delta_cap 是"每日"上限：必须先裁剪
        // 日速率、再乘 dt_days。否则加速档（dt_days≫1）下每轮 d_frac 被砍到
        // ≤cap，海冰每轮最多只长 cap，亚极地短暂冷却窗口里永远涨不到翻转阈值
        // → "已很冷却无冰"。melt 侧对称。
        float rate = k_freeze_eff * diff_freeze * freeze_gate
                   - (k_melt * diff_melt + solar_melt);
        if (daily_delta_cap > 0.0f) {
            if (rate > daily_delta_cap) rate = daily_delta_cap;
            else if (rate < -daily_delta_cap) rate = -daily_delta_cap;
        }
        float d_frac = rate * dt_days;
        float new_frac = prev_frac + d_frac;
        if (new_frac < 0.0f) new_frac = 0.0f;
        else if (new_frac > 1.0f) new_frac = 1.0f;
        if (edge_mix_rate > 0.0f) {
            float sum_nb_frac = 0.0f;
            int nb_water_count = 0;
            const int base = i * 6;
            for (int d = 0; d < 6; ++d) {
                const int32_t ni = NB[base + d];
                if (ni < 0 || !is_water_lut[TR_IN[ni]] || int(TR_IN[ni]) == id_lake) continue;
                sum_nb_frac += prev_sif[static_cast<size_t>(ni)];
                ++nb_water_count;
            }
            if (nb_water_count > 0) {
                const float avg_nb_frac = sum_nb_frac / float(nb_water_count);
                const float contrast = std::abs(avg_nb_frac - new_frac);
                if (contrast > 0.05f && (prev_frac > 0.001f || avg_nb_frac > 0.001f)) {
                    const float mix = std::min(0.12f, edge_mix_rate * std::max(1.0f, dt_days));
                    new_frac += (avg_nb_frac - new_frac) * mix;
                    if (new_frac < 0.0f) new_frac = 0.0f;
                    else if (new_frac > 1.0f) new_frac = 1.0f;
                }
            }
        }
        SIF[i] = new_frac;

        // 翻转候选
        const bool was_ice = (int(terr) == id_sea_ice);
        if (!was_ice && new_frac >= threshold) {
            out.flipped_cell_indices.push_back(i);
            out.flipped_new_terrain.push_back(uint8_t(id_sea_ice & 0xFF));
            if (apply_terrain_flips) {
                TR_OUT[i] = uint8_t(id_sea_ice & 0xFF);
            }
            ++flipped_count;
        } else if (was_ice && new_frac < (threshold - hysteresis)) {
            const int base_t_int = int(BT[i]);
            int target_terr = base_t_int;
            if (base_t_int == id_sea_ice) target_terr = id_ocean;
            out.flipped_cell_indices.push_back(i);
            out.flipped_new_terrain.push_back(uint8_t(target_terr & 0xFF));
            if (apply_terrain_flips) {
                TR_OUT[i] = uint8_t(target_terr & 0xFF);
            }
            ++flipped_count;
        }
    }
    return true;
}

// transp pure kernel — 移植自 run_transpiration_pass（world_ext.cpp:7341）。
// 算法逐行 1:1，输入输出全 std::vector，不写 _slots，不调 _flush_slot_to_map。
// 输出在 out.moisture / out.moisture_dirty_indices / out.moisture_dirty_values。
//
// ✅ Stage 3 数据流闭环：worker loop 在每个 pass 跑完后把 out.field 同步回
// in.field，让后续 pass 读 in 就拿到 fresh 值。transp 是 round 最后 pass，
// 读 in.moisture 时 pass_b 已把它的输出同步回去（pass_b → in.moisture），
// 等价于 sync 路径里 transp 读 _slots[cell_moisture]（已被 pass_b 写过）。
//
// 返回 true 成功，false 表示 input 验证失败（输入维度不匹配）。
static bool _async_transp_kernel_pure(const ClimateInputBuf &in,
                                      const ClimateRoundStaticKnobs &knobs,
                                      ClimateWorkBuf &work,
                                      ClimateOutputBuf &out) {
    const int n = in.n_cells;
    if (n <= 0) return false;
    if ((int)in.landform.size()   != n) return false;
    if ((int)in.vegetation.size() != n) return false;
    if ((int)in.moisture.size()   != n) return false;
    if ((int)knobs.neighbor_indices.size() < n * 6) return false;
    const int donor_size = (int)knobs.donor_table.size();
    if (donor_size <= 0) return false;

    const float outflow_rate = in.scalars.transp_outflow_rate;
    const float self_rate    = in.scalars.transp_self_rate;

    // 准备工作 buffer
    if ((int)work.deltas.size() != n) work.deltas.assign(n, 0.0f);
    else std::fill(work.deltas.begin(), work.deltas.end(), 0.0f);
    float *D = work.deltas.data();

    const uint8_t *LF  = in.landform.data();
    const uint8_t *VEG = in.vegetation.data();
    const float   *M_in = in.moisture.data();
    const int32_t *NB   = knobs.neighbor_indices.data();
    const float   *DON  = knobs.donor_table.data();

    // ─── Phase 1: compute deltas（与 sync 路径 1:1） ───
    for (int i = 0; i < n; ++i) {
        if (LF[i] <= 3) continue;             // skip water cells (LandformType.is_water)
        const uint8_t veg_id = VEG[i];
        if (veg_id >= donor_size) continue;    // safety
        const float trans = DON[veg_id];
        if (trans < 0.01f) continue;
        const float moist = M_in[i];
        const float output      = trans * moist;
        const float self_share = output * self_rate;

        const int base = i * 6;
        int valid_land_neighbors = 0;
        for (int d = 0; d < 6; ++d) {
            const int32_t nb_idx = NB[base + d];
            if (nb_idx < 0) continue;
            if (LF[nb_idx] <= 3) continue;     // 水面邻居不接受陆地蒸腾外溢
            ++valid_land_neighbors;
        }
        const float transported = valid_land_neighbors > 0 ? output * outflow_rate : 0.0f;
        D[i] += self_share - transported;
        const float nb_share = valid_land_neighbors > 0
            ? transported / float(valid_land_neighbors) : 0.0f;
        for (int d = 0; d < 6; ++d) {
            const int32_t nb_idx = NB[base + d];
            if (nb_idx < 0 || LF[nb_idx] <= 3) continue;
            D[nb_idx] += nb_share;
        }
    }

    // ─── Phase 2: apply deltas to output（先 copy input → output，再 +deltas） ───
    if ((int)out.moisture.size() != n) out.moisture.assign(n, 0.0f);
    std::memcpy(out.moisture.data(), M_in, n * sizeof(float));
    if ((int)out.moisture_dirty_indices.size() < n) {
        out.moisture_dirty_indices.assign(n, 0);
    }
    if ((int)out.moisture_dirty_values.size() < n) {
        out.moisture_dirty_values.assign(n, 0.0f);
    }
    int32_t *dirty_idx = out.moisture_dirty_indices.data();
    float   *dirty_val = out.moisture_dirty_values.data();
    int dirty_count = 0;

    float *M_out = out.moisture.data();
    for (int i = 0; i < n; ++i) {
        const float d = D[i];
        if (d == 0.0f) continue;
        float v = M_out[i] + d;
        if (v < 0.0f) v = 0.0f;
        else if (v > 1.0f) v = 1.0f;
        if (M_out[i] != v) {
            M_out[i] = v;
            dirty_idx[dirty_count] = i;
            dirty_val[dirty_count] = v;
            ++dirty_count;
        }
    }
    out.moisture_dirty_indices.resize(dirty_count);
    out.moisture_dirty_values.resize(dirty_count);
    return true;
}

// ─── finalizer kernel（Stage 9，2026-06-16） ──────────────────────────────
// 移植自 GDScript ClimateDailySystem::_apply_daily_climate_finalizer
// (climate_daily_system.gd:586)。
//
// 行为完全 1:1（含 mirror_temperature_cells / TTA clamp / thermal init / sort /
// percentile / sea_ice_delta_max / precip_p95）。但有几点关键区别：
//   1. 不写 HexCell facade（worker thread 不能碰 Godot Object）。GDScript 端
//      在 facade 启用时 mirror=false，cell.temperature getter 直接走 SoA，所以
//      worker 写 out.temp + 主线程 publish_to_slot 完全等价。facade 关闭时
//      （兼容 fallback 路径）GDScript 自己跑 finalizer。
//   2. 读 in.temp / in.tta / in.thermal_energy / in.ema_initialized / in.sea_ice_frac /
//      in.sea_ice_frac_prev / in.weather_precip。
//   3. 输入 baseline：in.temp_start_of_day / in.tta_start_of_day。size==n 时
//      启用 clamp，否则跳过（diag 仍累计 max_delta）。
//   4. 写 out.temp（覆盖 wind_surface 的输出）/ out.tta（in/out aliasing —
//      需要先 copy in→out 再 clamp）/ out.thermal_energy（覆盖 pass_a 的输出）。
//
// 返回 true 成功 / false 输入维度问题。
static bool _async_finalizer_kernel_pure(const ClimateInputBuf &in,
                                         ClimateOutputBuf &out) {
    const int n = in.n_cells;
    if (n <= 0) return false;
    if ((int)in.temp.size() != n) return false;
    if ((int)in.temp_transport_anomaly.size() != n) return false;
    if ((int)in.thermal_energy.size() != n) return false;

    // wind_surface 可能在前面已经写 out.temp；如果没写过（pass mask 关闭 wind_surface）
    // 则用 in.temp 兜底。注意：从 ClimateOutputBuf 的注释看 out.temp 是
    // wind_surface 唯一写者（climate round 最终 temp），所以 wind_surface 跑过
    // 时 out.temp == final 输出；finalizer 在它之上 clamp。
    if ((int)out.temp.size() != n) {
        out.temp.assign(n, 0.0f);
        std::memcpy(out.temp.data(), in.temp.data(), n * sizeof(float));
    }

    const float *T_in       = in.temp.data();
    float       *T_out      = out.temp.data();
    const float *TTA_in     = in.temp_transport_anomaly.data();
    const float *HEAT_in    = in.thermal_energy.data();
    const uint8_t *EMA_in   = in.ema_initialized.empty() ? nullptr : in.ema_initialized.data();

    const float temp_cap        = in.scalars.fin_temp_cap;
    const float tta_cap         = in.scalars.fin_tta_cap;
    const bool  temp_cap_enable = in.scalars.fin_temp_cap_enabled;
    const bool  has_temp_start  = in.scalars.fin_has_temp_start
                                  && (int)in.temp_start_of_day.size() == n;
    const bool  has_tta_start   = in.scalars.fin_has_tta_start
                                  && (int)in.tta_start_of_day.size() == n;
    const float *TS = has_temp_start ? in.temp_start_of_day.data() : nullptr;
    const float *TTS = has_tta_start ? in.tta_start_of_day.data() : nullptr;

    // 准备 TTA 输出（in/out aliasing — finalizer 写 cell.temperature_transport_anomaly
    // 时可能同时被同 round 的 pass_b 写过；为不打断 pass_b → finalizer 数据流，
    // out.temperature_transport_anomaly 先 copy in 再 in-place clamp）。
    if ((int)out.temp.size() != n) out.temp.assign(n, 0.0f);
    // 我们需要一个 out 端的 tta buffer。复用 out.air_mass_temp_anomaly 风格——
    // 但 finalizer 写自己的 tta 单独一个 vector（避免和 wind_air 冲突）。
    // 简单做法：直接写回 in 不可（worker 不应该回写 in）；新增 out.tta 字段。
    // 这里走临时方案：复用 in 在 worker 内的拷贝——还不行。
    // 决策：finalizer 写到一个新 output 字段 out.temp_transport_anomaly。
    // 该字段需要在 ClimateOutputBuf 加入。Step 4.1 已加。

    // ── temp loop + delta 统计 ──
    std::vector<float> temp_deltas(n, 0.0f);
    std::vector<float> preclamp_temp_deltas(n, 0.0f);
    float max_temp_delta = 0.0f;
    float preclamp_max_temp_delta = 0.0f;
    int32_t gt005 = 0, gt010 = 0, gt020 = 0, clamped = 0;
    for (int i = 0; i < n; ++i) {
        const float start_t = has_temp_start ? TS[i] : T_out[i];
        const float raw_t = T_out[i];
        float final_t = raw_t;
        const float pre_abs = std::fabs(raw_t - start_t);
        preclamp_temp_deltas[i] = pre_abs;
        if (pre_abs > preclamp_max_temp_delta) preclamp_max_temp_delta = pre_abs;
        if (temp_cap_enable && has_temp_start) {
            if (final_t < start_t - temp_cap) final_t = start_t - temp_cap;
            else if (final_t > start_t + temp_cap) final_t = start_t + temp_cap;
            if (final_t < 0.0f) final_t = 0.0f;
            else if (final_t > 1.0f) final_t = 1.0f;
            if (std::fabs(final_t - raw_t) > 0.000001f) ++clamped;
            T_out[i] = final_t;
        }
        const float abs_dt = std::fabs(final_t - start_t);
        temp_deltas[i] = abs_dt;
        if (abs_dt > 0.005f) ++gt005;
        if (abs_dt > 0.010f) ++gt010;
        if (abs_dt > 0.020f) ++gt020;
        if (abs_dt > max_temp_delta) max_temp_delta = abs_dt;
    }
    out.fin_max_temp_delta = max_temp_delta;
    out.fin_preclamp_max_temp_delta = preclamp_max_temp_delta;
    out.fin_temp_delta_gt_005_count = gt005;
    out.fin_temp_delta_gt_010_count = gt010;
    out.fin_temp_delta_gt_020_count = gt020;
    out.fin_temp_delta_clamped_count = clamped;

    // ── TTA loop + clamp + max ──
    // 注：sync GDScript path 直接在 map.temperature_transport_anomaly_arr in-place clamp。
    // worker 这里写到独立 buffer，主线程 poll 后 publish 到 slot。
    // 临时方案：复用 out.air_mass_temp_anomaly buffer 容易和 wind_air 输出
    // 冲突。改为：用 std::vector 局部，主线程 poll 时通过 PackedFloat32Array
    // 输出 (out.tta_final)。先临时 in-place 修改 in.temp_transport_anomaly?
    // —— 不行，in 是 const&。所以加 out.temp_transport_anomaly。
    if ((int)out.tta_final.size() != n) out.tta_final.assign(n, 0.0f);
    std::memcpy(out.tta_final.data(), TTA_in, n * sizeof(float));
    float *TTA_out = out.tta_final.data();
    float max_tta = 0.0f;
    int32_t tta_clamped_count = 0;
    for (int i = 0; i < n; ++i) {
        const float start_tta = has_tta_start ? TTS[i] : 0.0f;
        const float raw_tta = TTA_out[i];
        float final_tta = raw_tta;
        if (tta_cap > 0.0f && has_tta_start) {
            if (final_tta < start_tta - tta_cap) final_tta = start_tta - tta_cap;
            else if (final_tta > start_tta + tta_cap) final_tta = start_tta + tta_cap;
            if (std::fabs(final_tta - raw_tta) > 0.000001f) {
                TTA_out[i] = final_tta;
                ++tta_clamped_count;
            }
        }
        const float abs_tta = std::fabs(final_tta);
        if (abs_tta > max_tta) max_tta = abs_tta;
    }
    out.fin_max_transport_anomaly = max_tta;
    out.fin_tta_clamped_count = tta_clamped_count;

    // ── thermal_energy init loop（NaN/Inf 或 ema=0 → temp） ──
    if ((int)out.thermal_energy.size() != n) out.thermal_energy.assign(n, 0.0f);
    std::memcpy(out.thermal_energy.data(), HEAT_in, n * sizeof(float));
    float *HEAT_out = out.thermal_energy.data();
    int32_t thermal_init = 0;
    for (int i = 0; i < n; ++i) {
        const float v = HEAT_out[i];
        bool needs_init = !std::isfinite(v);
        if (!needs_init && EMA_in != nullptr && EMA_in[i] == 0) needs_init = true;
        if (needs_init) {
            HEAT_out[i] = T_out[i];
            ++thermal_init;
        }
    }
    out.fin_thermal_init_count = thermal_init;

    // ── sort + percentile（p95 / p99） ──
    std::sort(temp_deltas.begin(), temp_deltas.end());
    std::sort(preclamp_temp_deltas.begin(), preclamp_temp_deltas.end());
    auto percentile = [](const std::vector<float> &sorted, float pct) -> float {
        if (sorted.empty()) return 0.0f;
        const int idx = std::min((int)sorted.size() - 1,
                                  (int)std::floor((double)(sorted.size() - 1) * pct));
        return sorted[idx];
    };
    out.fin_p95_temp_delta = percentile(temp_deltas, 0.95f);
    out.fin_p99_temp_delta = percentile(temp_deltas, 0.99f);
    out.fin_preclamp_p99_temp_delta = percentile(preclamp_temp_deltas, 0.99f);

    // ── sea_ice_delta_max（仅当 in.sea_ice_frac / in.sea_ice_frac_prev 都齐） ──
    out.fin_sea_ice_delta_max = 0.0f;
    if ((int)in.sea_ice_frac.size() == n && (int)in.sea_ice_frac_prev.size() == n) {
        const float *SIF = in.sea_ice_frac.data();
        const float *SIFp = in.sea_ice_frac_prev.data();
        float max_ds = 0.0f;
        for (int i = 0; i < n; ++i) {
            const float ds = std::fabs(SIF[i] - SIFp[i]);
            if (ds > max_ds) max_ds = ds;
        }
        out.fin_sea_ice_delta_max = max_ds;
    }

    // ── precip_p95（sort weather_precip duplicate） ──
    out.fin_precip_p95 = 0.0f;
    if ((int)in.weather_precip.size() == n) {
        std::vector<float> precip_vals(in.weather_precip);
        std::sort(precip_vals.begin(), precip_vals.end());
        out.fin_precip_p95 = percentile(precip_vals, 0.95f);
    }

    out.fin_cells_seen = n;
    out.fin_applied = true;
    return true;
}

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
        bool ok = true;
        const int mask = t->w_in_buf.scalars.passes_mask;

        // ─── pass_a（bit 0） ──────────────────────────────────────────
        const auto pa0 = clock::now();
        if ((mask & 0x01) != 0 && (int)t->w_in_buf.is_water.size() == t->w_in_buf.n_cells) {
            // 输入完整时跑 pass_a pure kernel
            if (!_async_pass_a_kernel_pure(t->w_in_buf, t->w_out_buf)) {
                ok = false;
            }
            // Round 数据流：pass_a 写的字段刷新到 in，让后续 pass 读到 fresh 值。
            // sync 路径里 pass_a 通过 _flush_slot_to_map 把 16 个 slot 推回 MapData，
            // 然后下一 pass 入口的 refresh_slots_from_map 把 _slots 又拉到最新。
            // async 路径不走 MapData，但同 round 内的"上一 pass 写 → 下一 pass 读"
            // 必须用 in/out 同步实现。
            // 注：pass_a 是 round 第一个 pass，没有前序 pass 写过 in 字段；只刷新
            // pass_a 的输出回 in，让 pass_b / ocean_water / wind_air / transp 等读到。
            const int n_pa = t->w_in_buf.n_cells;
            if (n_pa > 0) {
                auto cp_if_size = [n_pa](std::vector<float> &dst, const std::vector<float> &src) {
                    if ((int)src.size() == n_pa) {
                        if ((int)dst.size() != n_pa) dst.resize(n_pa);
                        std::memcpy(dst.data(), src.data(), n_pa * sizeof(float));
                    }
                };
                auto cp_if_size_u8 = [n_pa](std::vector<uint8_t> &dst, const std::vector<uint8_t> &src) {
                    if ((int)src.size() == n_pa) {
                        if ((int)dst.size() != n_pa) dst.resize(n_pa);
                        std::memcpy(dst.data(), src.data(), n_pa);
                    }
                };
                // pass_b 读这些字段：temp_baseline / moisture / snow_cover / insolation_dev
                // ocean_water 读 temp_baseline (作 baseline_arr)；其他 pass 间接读
                cp_if_size(t->w_in_buf.moisture,         t->w_out_buf.moisture);
                cp_if_size(t->w_in_buf.temp_baseline,    t->w_out_buf.temp_baseline);
                cp_if_size(t->w_in_buf.insolation_dev,   t->w_out_buf.insolation_dev);
                cp_if_size(t->w_in_buf.thermal_energy,   t->w_out_buf.thermal_energy);
                cp_if_size(t->w_in_buf.snowpack,         t->w_out_buf.snowpack);
                cp_if_size(t->w_in_buf.temp_30d,         t->w_out_buf.temp_30d);
                cp_if_size(t->w_in_buf.temp_365d,        t->w_out_buf.temp_365d);
                cp_if_size_u8(t->w_in_buf.ema_initialized, t->w_out_buf.ema_initialized);
                // ocean / local anomaly 被 pass_a 清 0；同步给 pass_b/ocean_*
                cp_if_size(t->w_in_buf.ocean_thermal_anomaly, t->w_out_buf.ocean_thermal_anomaly);
                cp_if_size(t->w_in_buf.local_thermal_anomaly, t->w_out_buf.local_thermal_anomaly);
            }
        }
        const auto pa1 = clock::now();
        t->last_pass_a_us.store(
            (int64_t)std::chrono::duration_cast<std::chrono::microseconds>(pa1 - pa0).count(),
            std::memory_order_relaxed);

        // ─── pass_b（bit 1） ──────────────────────────────────────────
        const auto pb0 = clock::now();
        if ((mask & 0x02) != 0
                && (int)t->w_in_buf.is_water.size()       == t->w_in_buf.n_cells
                && (int)t->w_in_buf.landform.size()       == t->w_in_buf.n_cells
                && (int)t->w_in_buf.vegetation.size()     == t->w_in_buf.n_cells
                && (int)t->w_in_buf.snowpack.size()       == t->w_in_buf.n_cells
                && (int)t->w_in_buf.elevation.size()      == t->w_in_buf.n_cells
                && (int)t->w_in_buf.lat_norm.size()       == t->w_in_buf.n_cells
                && (int)t->w_in_buf.pos_x.size()          == t->w_in_buf.n_cells
                && (int)t->w_in_buf.pos_y.size()          == t->w_in_buf.n_cells
                && (int)t->w_in_buf.insolation_dev.size() == t->w_in_buf.n_cells
                && (int)t->w_in_buf.temp.size()           == t->w_in_buf.n_cells
                && (int)t->w_in_buf.moisture.size()       == t->w_in_buf.n_cells
                && (int)t->w_in_buf.local_thermal_anomaly.size() == t->w_in_buf.n_cells
                && (int)t->w_in_buf.temp_transport_anomaly.size() == t->w_in_buf.n_cells
                && (int)t->static_knobs.foliage_table.size() > 0) {
            if (!_async_pass_b_kernel_pure(t->w_in_buf, t->static_knobs, t->w_out_buf)) {
                ok = false;
            }
            // Round 数据流：pass_b 写 moisture（覆盖 pass_a）+ local_thermal_anomaly。
            // 同步给 ocean_water/land 和 wind_air/surface 等后续 pass。
            const int n_pb = t->w_in_buf.n_cells;
            if (n_pb > 0) {
                if ((int)t->w_out_buf.moisture.size() == n_pb) {
                    std::memcpy(t->w_in_buf.moisture.data(),
                                t->w_out_buf.moisture.data(), n_pb * sizeof(float));
                }
                if ((int)t->w_out_buf.local_thermal_anomaly.size() == n_pb) {
                    std::memcpy(t->w_in_buf.local_thermal_anomaly.data(),
                                t->w_out_buf.local_thermal_anomaly.data(), n_pb * sizeof(float));
                }
            }
        }
        const auto pb1 = clock::now();
        t->last_pass_b_us.store(
            (int64_t)std::chrono::duration_cast<std::chrono::microseconds>(pb1 - pb0).count(),
            std::memory_order_relaxed);

        // ─── ocean_water（bit 2） ─────────────────────────────────────
        const auto ow0 = clock::now();
        if ((mask & 0x04) != 0
                && (int)t->w_in_buf.is_water.size()        == t->w_in_buf.n_cells
                && (int)t->w_in_buf.pos_x.size()           == t->w_in_buf.n_cells
                && (int)t->w_in_buf.pos_y.size()           == t->w_in_buf.n_cells
                && (int)t->w_in_buf.ocean_current_x.size() == t->w_in_buf.n_cells
                && (int)t->w_in_buf.ocean_current_y.size() == t->w_in_buf.n_cells
                && (int)t->w_in_buf.temp.size()            == t->w_in_buf.n_cells
                && (int)t->w_in_buf.temp_baseline_year.size() == t->w_in_buf.n_cells
                && (int)t->w_in_buf.ocean_thermal_anomaly.size() == t->w_in_buf.n_cells
                && (int)t->w_in_buf.temp_transport_anomaly.size() == t->w_in_buf.n_cells) {
            if (!_async_ocean_water_kernel_pure(t->w_in_buf, t->static_knobs,
                                                t->w_work_buf, t->w_out_buf)) {
                ok = false;
            }
            // Round 数据流：ocean_water 写 ocean_thermal_anomaly (water cells)。
            // ocean_land 通过 work.ocean_tta_inout 读 water cells fresh anomaly，
            // ocean_thermal_anomaly slot 也要同步给 wind_surface 做合成。
            const int n_ow = t->w_in_buf.n_cells;
            if (n_ow > 0 && (int)t->w_out_buf.ocean_thermal_anomaly.size() == n_ow) {
                std::memcpy(t->w_in_buf.ocean_thermal_anomaly.data(),
                            t->w_out_buf.ocean_thermal_anomaly.data(), n_ow * sizeof(float));
            }
        }
        const auto ow1 = clock::now();
        t->last_ocean_water_us.store(
            (int64_t)std::chrono::duration_cast<std::chrono::microseconds>(ow1 - ow0).count(),
            std::memory_order_relaxed);

        // ─── ocean_land（bit 3） — 依赖 ocean_water 写完 work.ocean_tta_inout
        const auto ol0 = clock::now();
        if ((mask & 0x08) != 0
                && (int)t->w_in_buf.is_water.size()        == t->w_in_buf.n_cells
                && (int)t->w_in_buf.pos_x.size()           == t->w_in_buf.n_cells
                && (int)t->w_in_buf.pos_y.size()           == t->w_in_buf.n_cells
                && (int)t->w_in_buf.ocean_current_x.size() == t->w_in_buf.n_cells
                && (int)t->w_in_buf.ocean_current_y.size() == t->w_in_buf.n_cells) {
            // 若 ocean_water 没跑，ocean_tta_inout 还是空——单跑 ocean_land 时
            // 用 in.temp_transport_anomaly 初始化它。
            if ((int)t->w_work_buf.ocean_tta_inout.size() != t->w_in_buf.n_cells
                    && (int)t->w_in_buf.temp_transport_anomaly.size() == t->w_in_buf.n_cells) {
                t->w_work_buf.ocean_tta_inout.resize(t->w_in_buf.n_cells);
                std::memcpy(t->w_work_buf.ocean_tta_inout.data(),
                            t->w_in_buf.temp_transport_anomaly.data(),
                            t->w_in_buf.n_cells * sizeof(float));
            }
            if (!_async_ocean_land_kernel_pure(t->w_in_buf, t->static_knobs,
                                               t->w_work_buf, t->w_out_buf)) {
                ok = false;
            }
            // Round 数据流：ocean_land 累加 ocean_thermal_anomaly (land cells)。
            // wind_surface 读它做合成。
            const int n_ol = t->w_in_buf.n_cells;
            if (n_ol > 0 && (int)t->w_out_buf.ocean_thermal_anomaly.size() == n_ol) {
                std::memcpy(t->w_in_buf.ocean_thermal_anomaly.data(),
                            t->w_out_buf.ocean_thermal_anomaly.data(), n_ol * sizeof(float));
            }
        }
        const auto ol1 = clock::now();
        t->last_ocean_land_us.store(
            (int64_t)std::chrono::duration_cast<std::chrono::microseconds>(ol1 - ol0).count(),
            std::memory_order_relaxed);

        // ─── wind_air / wind_surface / sea_ice 仍是 stub
        // ─── wind_air（bit 4） ────────────────────────────────────────
        const auto wa0 = clock::now();
        if ((mask & 0x10) != 0
                && (int)t->w_in_buf.wind_x.size()  == t->w_in_buf.n_cells
                && (int)t->w_in_buf.wind_y.size()  == t->w_in_buf.n_cells
                && (int)t->w_in_buf.wind_speed.size() == t->w_in_buf.n_cells
                && (int)t->w_in_buf.pos_x.size()   == t->w_in_buf.n_cells
                && (int)t->w_in_buf.pos_y.size()   == t->w_in_buf.n_cells
                && (int)t->w_in_buf.temp.size()    == t->w_in_buf.n_cells
                && (int)t->w_in_buf.temp_baseline_year.size() == t->w_in_buf.n_cells) {
            if (!_async_wind_air_kernel_pure(t->w_in_buf, t->static_knobs, t->w_out_buf)) {
                ok = false;
            }
            // Round 数据流：wind_air 写 air_mass_temp_anomaly。
            // wind_surface 读它（作为 AIN snapshot）做加权平均。
            const int n_wa = t->w_in_buf.n_cells;
            if (n_wa > 0 && (int)t->w_out_buf.air_mass_temp_anomaly.size() == n_wa) {
                std::memcpy(t->w_in_buf.air_mass_temp_anomaly.data(),
                            t->w_out_buf.air_mass_temp_anomaly.data(), n_wa * sizeof(float));
            }
        }
        const auto wa1 = clock::now();
        t->last_wind_air_us.store(
            (int64_t)std::chrono::duration_cast<std::chrono::microseconds>(wa1 - wa0).count(),
            std::memory_order_relaxed);

        // ─── wind_surface（bit 5） — 依赖 wind_air / pass_a / pass_b / ocean_*
        const auto ws0 = clock::now();
        if ((mask & 0x20) != 0
                && (int)t->w_in_buf.wind_x.size()  == t->w_in_buf.n_cells
                && (int)t->w_in_buf.wind_y.size()  == t->w_in_buf.n_cells
                && (int)t->w_in_buf.wind_speed.size() == t->w_in_buf.n_cells
                && (int)t->w_in_buf.pos_x.size()   == t->w_in_buf.n_cells
                && (int)t->w_in_buf.pos_y.size()   == t->w_in_buf.n_cells) {
            if (!_async_wind_surface_kernel_pure(t->w_in_buf, t->static_knobs, t->w_out_buf)) {
                ok = false;
            }
            // Round 数据流：wind_surface 写 cell_temp（合成）+ overwrite air_anom。
            // sea_ice 期望读 climate/ocean-adjusted T —— round 模式下这就是 wind_surface
            // 输出的 cell_temp，同步给 in.cell_temperature_arr（覆盖 kick 传入的旧值）。
            const int n_ws = t->w_in_buf.n_cells;
            if (n_ws > 0) {
                if ((int)t->w_out_buf.temp.size() == n_ws
                        && (int)t->w_in_buf.cell_temperature_arr.size() == n_ws) {
                    std::memcpy(t->w_in_buf.cell_temperature_arr.data(),
                                t->w_out_buf.temp.data(), n_ws * sizeof(float));
                }
                if ((int)t->w_out_buf.air_mass_temp_anomaly.size() == n_ws) {
                    std::memcpy(t->w_in_buf.air_mass_temp_anomaly.data(),
                                t->w_out_buf.air_mass_temp_anomaly.data(), n_ws * sizeof(float));
                }
            }
        }
        const auto ws1 = clock::now();
        t->last_wind_surface_us.store(
            (int64_t)std::chrono::duration_cast<std::chrono::microseconds>(ws1 - ws0).count(),
            std::memory_order_relaxed);

        // sea_ice 仍是 stub（Stage 2 余下工作）
        // ─── sea_ice（bit 6） ─────────────────────────────────────────
        const auto si0 = clock::now();
        if ((mask & 0x40) != 0
                && (int)t->w_in_buf.terrain.size()              == t->w_in_buf.n_cells
                && (int)t->w_in_buf.base_terrain.size()         == t->w_in_buf.n_cells
                && (int)t->w_in_buf.sea_ice_frac_inout.size()   == t->w_in_buf.n_cells
                && (int)t->w_in_buf.temp_transport_anomaly.size() == t->w_in_buf.n_cells
                && (int)t->w_in_buf.upwelling_strength.size()   == t->w_in_buf.n_cells
                && (int)t->w_in_buf.insolation_now.size()       == t->w_in_buf.n_cells
                && (int)t->w_in_buf.cell_temperature_arr.size() == t->w_in_buf.n_cells
                && (int)t->w_in_buf.water_terrain_ids.size()    > 0) {
            if (!_async_sea_ice_kernel_pure(t->w_in_buf, t->static_knobs, t->w_out_buf)) {
                ok = false;
            }
            // Round 数据流：sea_ice 写 sea_ice_frac + 翻转 terrain。transp 不依赖
            // 它们；但 in.sea_ice_frac_inout / in.terrain 同步以便后续诊断 / round
            // 重复 kick 时拿到最新值（虽然单 round 不会重复跑同一 pass）。
            const int n_si = t->w_in_buf.n_cells;
            if (n_si > 0) {
                if ((int)t->w_out_buf.sea_ice_frac.size() == n_si) {
                    std::memcpy(t->w_in_buf.sea_ice_frac_inout.data(),
                                t->w_out_buf.sea_ice_frac.data(), n_si * sizeof(float));
                }
                if ((int)t->w_out_buf.terrain.size() == n_si) {
                    std::memcpy(t->w_in_buf.terrain.data(),
                                t->w_out_buf.terrain.data(), n_si);
                }
            }
        }
        const auto si1 = clock::now();
        t->last_sea_ice_us.store(
            (int64_t)std::chrono::duration_cast<std::chrono::microseconds>(si1 - si0).count(),
            std::memory_order_relaxed);

        // ─── transp（bit 7） ──────────────────────────────────────────
        const auto tr0 = clock::now();
        if ((mask & 0x80) != 0
                && (int)t->w_in_buf.landform.size()   == t->w_in_buf.n_cells
                && (int)t->w_in_buf.vegetation.size() == t->w_in_buf.n_cells
                && (int)t->w_in_buf.moisture.size()   == t->w_in_buf.n_cells) {
            if (!_async_transp_kernel_pure(t->w_in_buf, t->static_knobs,
                                           t->w_work_buf, t->w_out_buf)) {
                ok = false;
            }
        }
        const auto tr1 = clock::now();
        t->last_transp_us.store(
            (int64_t)std::chrono::duration_cast<std::chrono::microseconds>(tr1 - tr0).count(),
            std::memory_order_relaxed);

        // ─── finalizer（bit 8，Stage 9 2026-06-16） ──────────────────────
        // 在 round 末尾跑一次：clamp temp/TTA、统计 Δ percentile、thermal init、
        // sea_ice_delta_max、precip_p95。等价 GDScript _apply_daily_climate_finalizer。
        const auto fi0 = clock::now();
        if ((mask & 0x100) != 0
                && (int)t->w_in_buf.temp.size() == t->w_in_buf.n_cells
                && (int)t->w_in_buf.temp_transport_anomaly.size() == t->w_in_buf.n_cells
                && (int)t->w_in_buf.thermal_energy.size() == t->w_in_buf.n_cells) {
            // out.temp 已被 wind_surface 写入（mask bit 5 启用时）；finalizer
            // 在它之上 clamp。若 wind_surface 没写过（mask bit 5 关闭），kernel
            // 内部用 in.temp 兜底初始化 out.temp。
            if (!_async_finalizer_kernel_pure(t->w_in_buf, t->w_out_buf)) {
                ok = false;
            }
        }
        const auto fi1 = clock::now();
        t->last_finalizer_us.store(
            (int64_t)std::chrono::duration_cast<std::chrono::microseconds>(fi1 - fi0).count(),
            std::memory_order_relaxed);

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
        t->in_buf.n_cells = n_cells;

        // Stage 1 字段（transp 读）
        _read_pu8_to_vec(input,  "landform",   t->in_buf.landform,   n_cells);
        _read_pu8_to_vec(input,  "vegetation", t->in_buf.vegetation, n_cells);
        _read_pf32_to_vec(input, "moisture",   t->in_buf.moisture,   n_cells);

        // Stage 2 字段（pass_a 读）。如不提供则填空（0）；worker 内的 pass_a
        // 维度校验会拒绝跑（passes_mask & 0x01 但 is_water.size() != n_cells）。
        _read_pu8_to_vec(input,  "is_water",            t->in_buf.is_water,            n_cells);
        _read_pu8_to_vec(input,  "terrain",             t->in_buf.terrain,             n_cells);
        _read_pu8_to_vec(input,  "cover",               t->in_buf.cover,               n_cells);
        _read_pu8_to_vec(input,  "ema_initialized",     t->in_buf.ema_initialized,     n_cells);
        _read_pf32_to_vec(input, "elevation",           t->in_buf.elevation,           n_cells);
        _read_pf32_to_vec(input, "base_moisture",       t->in_buf.base_moisture,       n_cells);
        _read_pf32_to_vec(input, "weather_vapor",       t->in_buf.weather_vapor,       n_cells);
        _read_pf32_to_vec(input, "weather_precip",      t->in_buf.weather_precip,      n_cells);
        _read_pf32_to_vec(input, "soil_moisture",       t->in_buf.soil_moisture,       n_cells);
        _read_pf32_to_vec(input, "water_balance_30d",   t->in_buf.water_balance_30d,   n_cells);
        _read_pf32_to_vec(input, "lat_norm",            t->in_buf.lat_norm,            n_cells);
        // [climate-zone-fix P2] 海洋性调温因子（静态 per-cell；缺省空→不调温）
        _read_pf32_to_vec(input, "maritime_factor",     t->in_buf.maritime,            n_cells);
        _read_pf32_to_vec(input, "temp_baseline_year",  t->in_buf.temp_baseline_year,  n_cells);
        _read_pf32_to_vec(input, "temp",                t->in_buf.temp,                n_cells);
        _read_pf32_to_vec(input, "temp_30d",            t->in_buf.temp_30d,            n_cells);
        _read_pf32_to_vec(input, "temp_365d",           t->in_buf.temp_365d,           n_cells);
        _read_pf32_to_vec(input, "thermal_energy",      t->in_buf.thermal_energy,      n_cells);
        _read_pf32_to_vec(input, "snowpack",            t->in_buf.snowpack,            n_cells);
        t->in_buf.radiative_modifier_add.assign(
            static_cast<size_t>(n_cells), 0.0f);
        t->in_buf.radiative_modifier_factor.assign(
            static_cast<size_t>(n_cells), 1.0f);
        if (_modifier_runtime != nullptr) {
            const ModifierRuntime *modifier =
                static_cast<const ModifierRuntime *>(_modifier_runtime);
            for (int cell = 0; cell < n_cells; ++cell) {
                double add = 0.0;
                double factor = 1.0;
                modifier->climate_radiative_terms(cell, add, factor);
                t->in_buf.radiative_modifier_add[static_cast<size_t>(cell)] =
                    static_cast<float>(add);
                t->in_buf.radiative_modifier_factor[static_cast<size_t>(cell)] =
                    static_cast<float>(factor);
            }
        }

        // Stage 2 字段（pass_b 读）。snow_cover/moisture 与 pass_a 共享。
        _read_pf32_to_vec(input, "pos_x",                     t->in_buf.pos_x,                     n_cells);
        _read_pf32_to_vec(input, "pos_y",                     t->in_buf.pos_y,                     n_cells);
        _read_pf32_to_vec(input, "insolation_dev",            t->in_buf.insolation_dev,            n_cells);
        _read_pf32_to_vec(input, "temp_transport_anomaly",    t->in_buf.temp_transport_anomaly,    n_cells);
        _read_pf32_to_vec(input, "local_thermal_anomaly",     t->in_buf.local_thermal_anomaly,     n_cells);
        _read_pf32_to_vec(input, "sea_ice_frac",              t->in_buf.sea_ice_frac,              n_cells);

        // Stage 2 字段（ocean_water/ocean_land 读）
        _read_pf32_to_vec(input, "ocean_current_x",           t->in_buf.ocean_current_x,           n_cells);
        _read_pf32_to_vec(input, "ocean_current_y",           t->in_buf.ocean_current_y,           n_cells);
        _read_pf32_to_vec(input, "ocean_thermal_anomaly",     t->in_buf.ocean_thermal_anomaly,     n_cells);

        // Stage 2 字段（wind_air/wind_surface 读）
        _read_pf32_to_vec(input, "wind_x",                    t->in_buf.wind_x,                    n_cells);
        _read_pf32_to_vec(input, "wind_y",                    t->in_buf.wind_y,                    n_cells);
        _read_pf32_to_vec(input, "wind_speed",                t->in_buf.wind_speed,                n_cells);
        _read_pf32_to_vec(input, "temp_baseline",             t->in_buf.temp_baseline,             n_cells);
        _read_pf32_to_vec(input, "air_mass_temp_anomaly",     t->in_buf.air_mass_temp_anomaly,     n_cells);

        // Stage 2 字段（sea_ice 读）
        _read_pu8_to_vec(input,  "base_terrain",              t->in_buf.base_terrain,              n_cells);
        _read_pf32_to_vec(input, "upwelling_strength",        t->in_buf.upwelling_strength,        n_cells);
        _read_pf32_to_vec(input, "insolation_now",            t->in_buf.insolation_now,            n_cells);
        _read_pf32_to_vec(input, "cell_temperature_arr",      t->in_buf.cell_temperature_arr,      n_cells);
        _read_pf32_to_vec(input, "sea_ice_frac_inout",        t->in_buf.sea_ice_frac_inout,        n_cells);
        _read_pu8_to_vec(input,  "water_terrain_ids",         t->in_buf.water_terrain_ids,         0);

        // Round-level scalars
        t->in_buf.scalars.season_phase     = double(input.get("season_phase", 0.0));
        t->in_buf.scalars.axial_tilt_deg   = double(input.get("axial_tilt_deg", 23.5));
        t->in_buf.scalars.day_length_gain  = double(input.get("day_length_gain", 0.35));
        t->in_buf.scalars.solar_gain       = double(input.get("solar_gain", 1.0));
        t->in_buf.scalars.insol_amp        = double(input.get("insol_amp", 0.20));
        t->in_buf.scalars.insol_gain       = double(input.get("insol_gain", 1.0));
        t->in_buf.scalars.moist_scale_now  = double(input.get("moist_scale_now", 1.0));
        t->in_buf.scalars.runtime_moisture_base_relax_rate = float(input.get("runtime_moisture_base_relax_rate", 0.24));
        t->in_buf.scalars.runtime_moisture_weather_vapor_weight = float(input.get("runtime_moisture_weather_vapor_weight", 0.12));
        t->in_buf.scalars.runtime_moisture_precip_weight = float(input.get("runtime_moisture_precip_weight", 0.78));
        t->in_buf.scalars.runtime_moisture_soil_weight = float(input.get("runtime_moisture_soil_weight", 1.82));
        t->in_buf.scalars.runtime_moisture_soil_dry_weight = float(input.get("runtime_moisture_soil_dry_weight", 2.21));
        t->in_buf.scalars.runtime_moisture_water_balance_weight = float(input.get("runtime_moisture_water_balance_weight", 1.04));
        t->in_buf.scalars.runtime_moisture_water_balance_dry_weight = float(input.get("runtime_moisture_water_balance_dry_weight", 1.30));
        t->in_buf.scalars.days_per_year    = int(input.get("days_per_year", 365));
        t->in_buf.scalars.sea_level        = double(input.get("sea_level", 0.5));
        // pass_a 扩展 scalars
        t->in_buf.scalars.insol_dev_min               = double(input.get("insol_dev_min", -1.0));
        t->in_buf.scalars.insol_dev_max               = double(input.get("insol_dev_max", 1.0));
        t->in_buf.scalars.thermal_inertia_land        = double(input.get("thermal_inertia_land", 0.35));
        t->in_buf.scalars.thermal_inertia_water       = double(input.get("thermal_inertia_water", 0.045));
        t->in_buf.scalars.thermal_inertia_snow        = double(input.get("thermal_inertia_snow", 0.09));
        t->in_buf.scalars.thermal_inertia_high_mountain = double(input.get("thermal_inertia_high_mountain", 0.16));
        t->in_buf.scalars.thermal_daily_delta_cap     = double(input.get("thermal_daily_delta_cap", 0.15));
        t->in_buf.scalars.thermal_dt_days             = double(input.get("thermal_dt_days", 1.0));
        t->in_buf.scalars.snowpack_cover_low          = double(input.get("snowpack_cover_low", 0.05));
        t->in_buf.scalars.snowpack_cover_full         = double(input.get("snowpack_cover_full", 0.32));
        t->in_buf.scalars.maritime_season_damp        = double(input.get("maritime_season_damp", 0.0));
        // transp scalars
        t->in_buf.scalars.transp_outflow_rate = float(input.get("transp_outflow_rate", 0.025));
        t->in_buf.scalars.transp_self_rate    = float(input.get("transp_self_rate", 0.015));

        // pass_b scalars（Stage 2）
        t->in_buf.scalars.pb_winter_boost  = float(input.get("pb_winter_boost", 1.0));
        t->in_buf.scalars.pb_snow_cool     = float(input.get("pb_snow_cool", 0.0));
        t->in_buf.scalars.pb_veg_cool      = float(input.get("pb_veg_cool", 0.0));
        t->in_buf.scalars.pb_diurnal_amp   = float(input.get("pb_diurnal_amp", 0.0));
        t->in_buf.scalars.pb_evap_gain     = float(input.get("pb_evap_gain", 0.0));
        t->in_buf.scalars.pb_rs_threshold  = float(input.get("pb_rs_threshold", 0.0));
        t->in_buf.scalars.pb_rs_factor     = float(input.get("pb_rs_factor", 1.0));
        t->in_buf.scalars.pb_rs_lookback   = int(input.get("pb_rs_lookback", 0));
        t->in_buf.scalars.pb_t_freeze      = float(input.get("pb_t_freeze", 0.0));
        t->in_buf.scalars.pb_coupling_gain = float(input.get("pb_coupling_gain", 0.0));
        t->in_buf.scalars.pb_coast_leak    = float(input.get("pb_coast_leak", 0.0));
        t->in_buf.scalars.pb_sea_ice_albedo_cooling = float(input.get("pb_sea_ice_albedo_cooling", 0.01));

        // ocean_water / ocean_land scalars（Stage 2）
        t->in_buf.scalars.ow_advect_steps  = int(input.get("ow_advect_steps", 3));
        t->in_buf.scalars.ow_heat_mix      = float(input.get("ow_heat_mix", 0.55));
        t->in_buf.scalars.ow_tta_source_cap = float(input.get("ow_tta_source_cap", 0.22));
        t->in_buf.scalars.ow_tta_blend_rate = float(input.get("ow_tta_blend_rate", 0.70));
        t->in_buf.scalars.ow_tta_zero_current_decay = float(input.get("ow_tta_zero_current_decay", 0.06));
        t->in_buf.scalars.ol_effective_leak = float(input.get("ol_effective_leak", 0.55));
        t->in_buf.scalars.ol_tta_source_cap = float(input.get("ol_tta_source_cap", 0.22));
        t->in_buf.scalars.ol_tta_blend_rate = float(input.get("ol_tta_blend_rate", 0.70));
        t->in_buf.scalars.ol_tta_decay_rate = float(input.get("ol_tta_decay_rate", 0.04));

        // wind_air / wind_surface scalars（Stage 2）
        t->in_buf.scalars.wa_advect_steps = int(input.get("wa_advect_steps", 3));
        t->in_buf.scalars.wa_heat_mix     = float(input.get("wa_heat_mix", 0.25));
        t->in_buf.scalars.ws_air_leak     = float(input.get("ws_air_leak", 0.35));
        t->in_buf.scalars.ws_cold_transport_form = float(input.get("ws_cold_transport_form", 0.06));
        t->in_buf.scalars.ws_cold_transport_melt = float(input.get("ws_cold_transport_melt", 0.11));

        // sea_ice scalars（Stage 2）
        t->in_buf.scalars.si_k_freeze     = float(input.get("si_k_freeze", 0.40));
        t->in_buf.scalars.si_k_melt       = float(input.get("si_k_melt", 1.45));
        t->in_buf.scalars.si_t_form       = float(input.get("si_t_form", 0.06));
        t->in_buf.scalars.si_t_melt       = float(input.get("si_t_melt", 0.11));
        t->in_buf.scalars.si_contagion    = float(input.get("si_contagion", 0.035));
        t->in_buf.scalars.si_threshold    = float(input.get("si_threshold", 0.68));
        t->in_buf.scalars.si_hysteresis   = float(input.get("si_hysteresis", 0.12));
        t->in_buf.scalars.si_ice_delay    = float(input.get("si_ice_delay", 1.0));
        t->in_buf.scalars.si_enable_oht   = bool(input.get("si_enable_oht", true));
        t->in_buf.scalars.si_apply_terrain_flips = bool(input.get("si_apply_terrain_flips", false));
        t->in_buf.scalars.si_solar_gate_enabled = bool(input.get("si_solar_gate_enabled", true));
        t->in_buf.scalars.si_freeze_insol_low  = float(input.get("si_freeze_insol_low", 0.22));
        t->in_buf.scalars.si_freeze_insol_high = float(input.get("si_freeze_insol_high", 0.45));
        t->in_buf.scalars.si_solar_melt_start  = float(input.get("si_solar_melt_start", 0.28));
        t->in_buf.scalars.si_solar_melt_gain   = float(input.get("si_solar_melt_gain", 1.35));
        t->in_buf.scalars.si_min_thick_ice_solar_exposure = float(input.get("si_min_thick_ice_solar_exposure", 0.32));
        t->in_buf.scalars.si_daily_delta_cap   = float(input.get("si_daily_delta_cap", 0.070));
        t->in_buf.scalars.si_edge_mix_rate     = float(input.get("si_edge_mix_rate", 0.035));
        t->in_buf.scalars.si_dt_days           = float(input.get("si_dt_days", 1.0));
        t->in_buf.scalars.si_terrain_lake_id    = int(input.get("si_terrain_lake_id", -1));
        t->in_buf.scalars.si_terrain_sea_ice_id = int(input.get("si_terrain_sea_ice_id", -1));
        t->in_buf.scalars.si_terrain_ocean_id   = int(input.get("si_terrain_ocean_id", -1));

        // ─── finalizer pass fields（Stage 9，2026-06-16） ─────────────────
        // _temp_start_of_day_arr / _tta_start_of_day_arr / sea_ice_frac_prev /
        // weather_precip 由 GDScript 主线程在 begin_round 时打快照传入。
        _read_pf32_to_vec(input, "fin_temp_start_of_day",   t->in_buf.temp_start_of_day,   n_cells);
        _read_pf32_to_vec(input, "fin_tta_start_of_day",    t->in_buf.tta_start_of_day,    n_cells);
        _read_pf32_to_vec(input, "fin_sea_ice_frac_prev",   t->in_buf.sea_ice_frac_prev,   n_cells);
        _read_pf32_to_vec(input, "fin_weather_precip",      t->in_buf.weather_precip,      n_cells);
        t->in_buf.scalars.fin_temp_cap_enabled = bool(input.get("fin_temp_cap_enabled", true));
        t->in_buf.scalars.fin_temp_cap         = float(input.get("fin_temp_cap", 0.15));
        t->in_buf.scalars.fin_tta_cap          = float(input.get("fin_tta_cap", 0.12));
        t->in_buf.scalars.fin_has_temp_start   = bool(input.get("fin_has_temp_start", false));
        t->in_buf.scalars.fin_has_tta_start    = bool(input.get("fin_has_tta_start", false));

        // passes_mask（默认 0x1FF 含 finalizer bit）
        t->in_buf.scalars.passes_mask = int(input.get("passes_mask", 0x1FF));

        // ─── Item 4 (perf 2026-07-05)：主线程预烘焙年均日照 LUT ────────────────
        // pass_a worker 每 cell 需 dc_insolation_annual_mean(clamp01(ny), axial_tilt, daylen)，
        // 该值 season-无关（16×9 trig/cell）。async kernel 跑在 worker thread、无法安全用 member
        // 缓存，故在此（持锁、主线程）按 lat_norm 逐 cell 预算好，worker 直接读 → bit-equal。
        // 仅 pass_a 参与时（passes_mask & 0x01）才烘焙，省无谓开销；否则清空退回 inline。
        if ((t->in_buf.scalars.passes_mask & 0x01) != 0 &&
            (int)t->in_buf.lat_norm.size() == n_cells) {
            const float ax_tilt = float(t->in_buf.scalars.axial_tilt_deg);
            const float dl_amp  = float(t->in_buf.scalars.day_length_gain);
            t->in_buf.insol_annual_mean.resize(static_cast<size_t>(n_cells));
            for (int i = 0; i < n_cells; ++i) {
                t->in_buf.insol_annual_mean[static_cast<size_t>(i)] =
                    dc_insolation_annual_mean(dc_clamp01f(t->in_buf.lat_norm[static_cast<size_t>(i)]),
                                              ax_tilt, dl_amp);
            }
        } else {
            t->in_buf.insol_annual_mean.clear();
        }

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
