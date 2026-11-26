#include "world_ext.h"
#include "simulation_math.h"

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


// The annual mean depends only on latitude and the two planet settings.
const float *DCWorldExt::ensure_insol_annual_mean_cache(const float *lat_ptr, int n,
                                                        float axial_tilt_deg, float daylen_amp) {
    if (n <= 0) return nullptr;
    if (_insol_cache_latitudes.size() == static_cast<size_t>(n) &&
        std::memcmp(&_insol_cache_tilt, &axial_tilt_deg, sizeof(float)) == 0 &&
        std::memcmp(&_insol_cache_daylen, &daylen_amp, sizeof(float)) == 0 &&
        std::memcmp(_insol_cache_latitudes.data(), lat_ptr, n * sizeof(float)) == 0) {
        return _insol_annual_mean_cache.data();
    }
    _insol_cache_latitudes.assign(lat_ptr, lat_ptr + n);
    _insol_cache_tilt = axial_tilt_deg;
    _insol_cache_daylen = daylen_amp;
    _insol_annual_mean_cache.resize(n);
    for (int i = 0; i < n; ++i) {
        _insol_annual_mean_cache[i] =
            dc_insolation_annual_mean(dc_clamp01f(lat_ptr[i]), axial_tilt_deg, daylen_amp);
    }
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
    const float moisture_relax_eff = 1.0f - simulation_math::pow(1.0f - moisture_relax, thermal_dt);
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
                                    : (1.0f - simulation_math::pow(1.0f - 1.0f / 30.0f, thermal_dt));
    const float ema_alpha_365 = (thermal_dt <= 1.0f) ? annual_ema_alpha
                                    : (1.0f - simulation_math::pow(1.0f - annual_ema_alpha, thermal_dt));
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

#include "world_ext_climate_section_enso_basins.inc"
#include "world_ext_climate_section_temperature_relaxation.inc"
// ─── sim-2ms-perf-push（plan/ocean-water-land-simd）─────────────────────────
//
// 复用 pass_b 模板：Ctx + idx 预筛 + run_range helper + WorkerThreadPool worker。
// 算法与 run_ocean_water_pass / run_ocean_land_pass 一一对应；区别仅在：
//   1. 主循环外层不再有 if(IW[i]==0)/if(IW[i]!=0) 分支——预筛后只迭代 water/land。
//   2. ptr() 一次性取到全部基址，每 i 内只剩内层 6 邻居 + advect 链路。
//   3. 内层"邻居是否合格"分支保留（gather 无收益，charter §risk=B 接受）。
// 数值容差：ulp ≤ 4（仅浮点重排，无算法变更）。
} // namespace pk
