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


Dictionary DCWorldExt::run_native_daily_tick(const Dictionary &tick_knobs) {
    Dictionary out;
    const auto t0 = std::chrono::high_resolution_clock::now();

    if (!_native_world_configured) {
        out["rc"] = -1;
        out["fail_stage"] = String("native_world_not_configured");
        out["total_ms"] = 0.0;
        return out;
    }

    if (bool(tick_knobs.get("probe", false))) {
        bool has_bundle = false;
        bool has_pass = false;
        Array pass_keys;
        Array required_keys;
        Array missing_pass_keys;
        Variant required_v = tick_knobs.get("required_pass_keys", Array());
        if (required_v.get_type() == Variant::ARRAY) {
            required_keys = required_v;
        }
        if (tick_knobs.has("native_daily_bundle") &&
            Variant(tick_knobs["native_daily_bundle"]).get_type() == Variant::DICTIONARY) {
            Dictionary bundle = tick_knobs["native_daily_bundle"];
            has_bundle = !bundle.is_empty();
            auto record_pass = [&](const char *key) {
                if (bundle.has(key)) {
                    has_pass = true;
                    pass_keys.append(String(key));
                }
            };
            record_pass("climate_pass_a_struct");
            record_pass("ocean_water_knobs");
            record_pass("ocean_land_knobs");
            record_pass("climate_pass_b_knobs");
            record_pass("sea_ice_knobs");
            record_pass("transpiration_knobs");
            record_pass("albedo_knobs");
            record_pass("vegetation_dynamics_knobs");
            record_pass("climate_feedback_knobs");
            record_pass("stage_b_knobs");
            record_pass("weather_knobs");
            for (int i = 0; i < required_keys.size(); ++i) {
                const String key = String(required_keys[i]);
                if (!bundle.has(key)) {
                    missing_pass_keys.append(key);
                }
            }
        }
        const bool has_required_passes = missing_pass_keys.is_empty();
        const bool authoritative_ready = has_bundle && has_pass && has_required_passes;
        out["rc"] = authoritative_ready ? 0 : -1;
        out["fail_stage"] = authoritative_ready
            ? String()
            : (!has_bundle ? String("native_daily_bundle_missing")
                           : (!has_pass ? String("native_daily_bundle_no_passes")
                                        : String("native_daily_bundle_missing_required_passes")));
        out["configured"] = true;
        out["cell_count"] = _native_world_cell_count;
        out["pass_keys"] = pass_keys;
        out["required_pass_keys"] = required_keys;
        out["missing_pass_keys"] = missing_pass_keys;
        out["authoritative_ready"] = authoritative_ready;
        out["total_ms"] = 0.0;
        return out;
    }

    ++_native_daily_tick_count;
    _native_dirty_report["last_day_index"] = int(tick_knobs.get("day_index", 0));
    _native_dirty_report["last_season_phase"] = double(tick_knobs.get("season_phase", 0.0));
    _native_dirty_report["atlas_dirty"] = false;
    _native_dirty_report["enum_atlas_dirty"] = false;
    _native_dirty_report["sea_ice_atlas_dirty"] = false;
    _native_dirty_report["sea_ice_terrain_flip_count"] = 0;
    _native_dirty_report["dirty_cell_count"] = 0;

    Dictionary breakdown;
    breakdown["native_context_ms"] = 0.0;
    breakdown["season_ms"] = 0.0;
    breakdown["climate_ms"] = 0.0;
    breakdown["weather_ms"] = 0.0;
    breakdown["ocean_ms"] = 0.0;
    breakdown["stage_b_ms"] = 0.0;
    breakdown["render_prepare_ms"] = 0.0;

    auto finish_with_failure = [&](const char *stage, const String &reason) -> Dictionary {
        const auto t_fail = std::chrono::high_resolution_clock::now();
        const double total_ms = std::chrono::duration<double, std::milli>(t_fail - t0).count();
        out["rc"] = -1;
        out["fail_stage"] = String(stage);
        out["reason"] = reason;
        out["total_ms"] = total_ms;
        out["breakdown"] = breakdown;
        out["dirty_flags"] = _native_dirty_report.duplicate();
        out["fronts_changed"] = false;
        out["fronts"] = _native_fronts_snapshot;
        out["tick_count"] = _native_daily_tick_count;
        return out;
    };

    auto as_dict = [](const Variant &v) -> Dictionary {
        if (v.get_type() == Variant::DICTIONARY) {
            return v;
        }
        return Dictionary();
    };

    auto copy_dict_into = [](Dictionary &dst, const Dictionary &src) {
        Array keys = src.keys();
        for (int i = 0; i < keys.size(); ++i) {
            Variant k = keys[i];
            dst[k] = src[k];
        }
    };

    if (!tick_knobs.has("native_daily_bundle")) {
        return finish_with_failure("native_daily_bundle", "missing native_daily_bundle");
    }
    Dictionary bundle = as_dict(tick_knobs.get("native_daily_bundle", Dictionary()));
    if (bundle.is_empty()) {
        return finish_with_failure("native_daily_bundle", "empty native_daily_bundle");
    }

    const auto t_context0 = std::chrono::high_resolution_clock::now();
    if (bool(bundle.get("refresh_slots_from_map", true))) {
        refresh_slots_from_map();
    }
    const auto t_context1 = std::chrono::high_resolution_clock::now();
    breakdown["native_context_ms"] = std::chrono::duration<double, std::milli>(
        t_context1 - t_context0).count();

    bool any_pass_ran = false;

    // ─── Phase C.1（dots-total-cpp roadmap）：System schedule graph 双轨入口 ─
    //
    // GDScript 端注入 bundle["use_system_schedule"]=true 时，跳过下方 line
    // 960-1063 的 11 段手写 if-chain，改走 dispatch_system_schedule loop。
    //
    // 验收：dots_soak_ab_runner 1000-tick SAME_SOURCE A/B：
    //   A=use_system_schedule off（原 if-chain），B=on（dispatch）→ breakdown
    //   所有 ms 字段 epsilon 1e-5、fronts bit-equal、succession_indices/to_veg
    //   完全相等才通过。
    //
    // Fallback 路径：任一节点失败立即 finish_with_failure 短路返回（与原
    // line 960-1063 同语义）；weather 节点失败时 fail_stage 是动态值（来自
    // run_weather_refresh_daily_pass 返回的 fail_stage 字段），由 dispatch
    // 把它暂存到 breakdown["__weather_fail_stage_dyn"]，我们 caller 这里取出
    // 用作 finish_with_failure 第二参的 reason。
    const bool use_system_schedule = bool(bundle.get("use_system_schedule", false));
    if (use_system_schedule) {
        const char* fail_stage = nullptr;
        const int rc = pk::dispatch_system_schedule(
            this, bundle, tick_knobs, breakdown, any_pass_ran, fail_stage);
        if (rc != 0) {
            // 与原 11 段 if-chain 的 finish_with_failure 第二参对齐：除 weather
            // 段外都是 "pass returned fallback"；weather 段从 breakdown 暂存
            // 字段读出真实 fail_stage 名作为 reason。
            String reason;
            if (fail_stage != nullptr && String(fail_stage) == String("weather")) {
                reason = String(breakdown.get("__weather_fail_stage_dyn", "unknown"));
                breakdown.erase("__weather_fail_stage_dyn");
            } else {
                reason = String("pass returned fallback");
            }
            return finish_with_failure(fail_stage != nullptr ? fail_stage : "system_schedule",
                                       reason);
        }
    } else {


        Dictionary cp_struct = as_dict(bundle["climate_pass_a_struct"]);
        const double phase = double(tick_knobs.get("season_phase", 0.0));
        const double season_phase = double(tick_knobs.get("season_phase", phase));
        const double ms = run_climate_pass_a(cp_struct, phase, season_phase);
        if (ms < 0.0) return finish_with_failure("climate_pass_a", "pass returned fallback");
        breakdown["pass_a_ms"] = ms;
        breakdown["climate_ms"] = double(breakdown.get("climate_ms", 0.0)) + ms;
        any_pass_ran = true;

    if (bundle.has("ocean_water_knobs")) {
        const double ms = run_ocean_water_pass(as_dict(bundle["ocean_water_knobs"]));
        if (ms < 0.0) return finish_with_failure("ocean_water", "pass returned fallback");
        breakdown["ocean_water_ms"] = ms;
        breakdown["ocean_ms"] = double(breakdown.get("ocean_ms", 0.0)) + ms;
        any_pass_ran = true;
    }

    if (bundle.has("ocean_land_knobs")) {
        const double ms = run_ocean_land_pass(as_dict(bundle["ocean_land_knobs"]));
        if (ms < 0.0) return finish_with_failure("ocean_land", "pass returned fallback");
        breakdown["ocean_land_ms"] = ms;
        breakdown["ocean_ms"] = double(breakdown.get("ocean_ms", 0.0)) + ms;
        any_pass_ran = true;
    }

    if (bundle.has("climate_pass_b_knobs")) {
        const double ms = run_climate_pass_b(as_dict(bundle["climate_pass_b_knobs"]));
        if (ms < 0.0) return finish_with_failure("climate_pass_b", "pass returned fallback");
        breakdown["pass_b_ms"] = ms;
        breakdown["climate_ms"] = double(breakdown.get("climate_ms", 0.0)) + ms;
        any_pass_ran = true;
    }

    if (bundle.has("sea_ice_knobs")) {
        const float phase = float(tick_knobs.get("season_phase", 0.0));
        const double ms = run_sea_ice_daily_pass(as_dict(bundle["sea_ice_knobs"]), phase);
        if (ms < 0.0) return finish_with_failure("sea_ice", "pass returned fallback");
        breakdown["sea_ice_ms"] = ms;
        breakdown["climate_ms"] = double(breakdown.get("climate_ms", 0.0)) + ms;
        any_pass_ran = true;
    }

    if (bundle.has("transpiration_knobs")) {
        const double ms = run_transpiration_pass(as_dict(bundle["transpiration_knobs"]));
        if (ms < 0.0) return finish_with_failure("transpiration", "pass returned fallback");
        breakdown["transp_ms"] = ms;
        breakdown["climate_ms"] = double(breakdown.get("climate_ms", 0.0)) + ms;
        any_pass_ran = true;
    }

    if (bundle.has("albedo_knobs")) {
        const double ms = run_albedo_pass(as_dict(bundle["albedo_knobs"]));
        if (ms < 0.0) return finish_with_failure("albedo", "pass returned fallback");
        breakdown["albedo_ms"] = ms;
        breakdown["stage_b_ms"] = double(breakdown.get("stage_b_ms", 0.0)) + ms;
        any_pass_ran = true;
    }

    if (bundle.has("vegetation_dynamics_knobs")) {
        const double ms = run_vegetation_dynamics_pass(as_dict(bundle["vegetation_dynamics_knobs"]));
        if (ms < 0.0) return finish_with_failure("vegetation_dynamics", "pass returned fallback");
        breakdown["veg_dyn_ms"] = ms;
        breakdown["stage_b_ms"] = double(breakdown.get("stage_b_ms", 0.0)) + ms;
        any_pass_ran = true;
    }

    if (bundle.has("climate_feedback_knobs")) {
        const double ms = run_climate_feedback_pass(as_dict(bundle["climate_feedback_knobs"]));
        if (ms < 0.0) return finish_with_failure("climate_feedback", "pass returned fallback");
        breakdown["feedback_ms"] = ms;
        breakdown["stage_b_ms"] = double(breakdown.get("stage_b_ms", 0.0)) + ms;
        any_pass_ran = true;
    }

    if (bundle.has("stage_b_knobs")) {
        Dictionary stage_b_knobs = as_dict(bundle["stage_b_knobs"]);
        const double ms = run_stage_b_pass(stage_b_knobs);
        if (ms < 0.0) return finish_with_failure("stage_b", "pass returned fallback");
        breakdown["stage_b_ms"] = double(breakdown.get("stage_b_ms", 0.0)) + ms;
        breakdown["albedo_ms"] = stage_b_knobs.get("albedo_ms", breakdown.get("albedo_ms", 0.0));
        breakdown["veg_dyn_ms"] = stage_b_knobs.get("veg_dyn_ms", breakdown.get("veg_dyn_ms", 0.0));
        breakdown["feedback_ms"] = stage_b_knobs.get("feedback_ms", breakdown.get("feedback_ms", 0.0));
        if (stage_b_knobs.has("succession_indices")) {
            breakdown["succession_indices"] = stage_b_knobs["succession_indices"];
            breakdown["succession_to_veg"] = stage_b_knobs["succession_to_veg"];
            breakdown["stat_succession_count"] = stage_b_knobs.get("stat_succession_count", 0);
        }
        any_pass_ran = true;
    }

    if (bundle.has("weather_knobs")) {
        Dictionary weather = run_weather_refresh_daily_pass(as_dict(bundle["weather_knobs"]));
        if (int(weather.get("rc", -1)) != 0) {
            return finish_with_failure("weather", String(weather.get("fail_stage", "unknown")));
        }
        breakdown["weather_ms"] = double(weather.get("total_ms", 0.0));
        copy_dict_into(breakdown, weather);
        if (weather.has("fronts")) {
            _native_fronts_snapshot = weather["fronts"];
        }
        any_pass_ran = true;
    }
    } // ─── Phase C.1：use_system_schedule=false 的 else 分支结束 ──────────

    if (!any_pass_ran) {
        return finish_with_failure("native_daily_bundle", "no pass knobs in native_daily_bundle");
    }

    if (bool(bundle.get("flush_slots_to_map", true))) {
        const auto t_flush0 = std::chrono::high_resolution_clock::now();
        flush_slots_to_map();
        const auto t_flush1 = std::chrono::high_resolution_clock::now();
        breakdown["render_prepare_ms"] = std::chrono::duration<double, std::milli>(
            t_flush1 - t_flush0).count();
    }

    const auto t1 = std::chrono::high_resolution_clock::now();
    const double total_ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
    out["rc"] = 0;
    out["fail_stage"] = String();
    out["total_ms"] = total_ms;
    breakdown["total_ms"] = total_ms;
    out["breakdown"] = breakdown;
    out["dirty_flags"] = _native_dirty_report.duplicate();
    out["fronts_changed"] = bundle.has("weather_knobs");
    out["fronts"] = _native_fronts_snapshot;
    out["tick_count"] = _native_daily_tick_count;
    return out;
}

Dictionary DCWorldExt::run_native_sim_tick(const Dictionary &ctx) {
    Dictionary tick_knobs = ctx.duplicate(true);
    if (ctx.has("tick_knobs") && Variant(ctx["tick_knobs"]).get_type() == Variant::DICTIONARY) {
        tick_knobs = Dictionary(ctx["tick_knobs"]).duplicate(true);
    }

    Dictionary out = run_native_daily_tick(tick_knobs);
    _native_daily_report = out.duplicate(true);

    Dictionary hash_diff;
    hash_diff["enabled"] = bool(ctx.get("shadow_diff_enabled", false));
    hash_diff["rc"] = int(out.get("rc", -1));
    hash_diff["fail_stage"] = out.get("fail_stage", String());
    hash_diff["checked_cell_count"] = _native_world_cell_count;

    auto hash_f32_slot = [&](const char *slot_name) -> uint64_t {
        const int sid = component_id(StringName(slot_name));
        if (sid < 0 || sid >= _slots.size()) return 0;
        const Slot &s = _slots.write[sid];
        uint64_t h = 1469598103934665603ull;
        const int n = s.arr_f32.size();
        const float *p = s.arr_f32.ptr();
        for (int i = 0; i < n; ++i) {
            uint32_t bits = 0;
            static_assert(sizeof(bits) == sizeof(float), "float hash assumes 32-bit float");
            std::memcpy(&bits, &p[i], sizeof(float));
            h ^= uint64_t(bits);
            h *= 1099511628211ull;
        }
        return h;
    };
    auto hash_u8_slot = [&](const char *slot_name) -> uint64_t {
        const int sid = component_id(StringName(slot_name));
        if (sid < 0 || sid >= _slots.size()) return 0;
        const Slot &s = _slots.write[sid];
        uint64_t h = 1469598103934665603ull;
        const int n = s.arr_u8.size();
        const uint8_t *p = s.arr_u8.ptr();
        for (int i = 0; i < n; ++i) {
            h ^= uint64_t(p[i]);
            h *= 1099511628211ull;
        }
        return h;
    };

    Dictionary native_hashes;
    native_hashes["temp"] = String::num_uint64(hash_f32_slot("cell_temp"), 16);
    native_hashes["moisture"] = String::num_uint64(hash_f32_slot("cell_moisture"), 16);
    native_hashes["snow"] = String::num_uint64(hash_f32_slot("cell_snow_cover"), 16);
    native_hashes["sea_ice_frac"] = String::num_uint64(hash_f32_slot("cell_sea_ice_frac"), 16);
    native_hashes["terrain"] = String::num_uint64(hash_u8_slot("cell_terrain"), 16);
    native_hashes["vegetation"] = String::num_uint64(hash_u8_slot("cell_vegetation"), 16);
    native_hashes["weather_type"] = String::num_uint64(hash_u8_slot("cell_weather_type"), 16);
    hash_diff["native_hashes"] = native_hashes;

    Dictionary legacy_hashes;
    if (ctx.has("legacy_hashes") && Variant(ctx["legacy_hashes"]).get_type() == Variant::DICTIONARY) {
        legacy_hashes = ctx["legacy_hashes"];
    }
    hash_diff["legacy_hashes"] = legacy_hashes;
    Array mismatched;
    if (!legacy_hashes.is_empty()) {
        Array keys = native_hashes.keys();
        for (int i = 0; i < keys.size(); ++i) {
            Variant k = keys[i];
            if (legacy_hashes.has(k) && String(legacy_hashes[k]) != String(native_hashes[k])) {
                mismatched.append(k);
            }
        }
    }
    hash_diff["mismatched_fields"] = mismatched;
    hash_diff["match"] = legacy_hashes.is_empty() ? false : mismatched.is_empty();
    _native_shadow_diff_report = hash_diff.duplicate(true);

    out["hash_diff"] = hash_diff;
    _native_daily_report = out.duplicate(true);
    return out;
}

Dictionary DCWorldExt::get_native_daily_report() const {
    return _native_daily_report.duplicate(true);
}

Dictionary DCWorldExt::get_native_shadow_diff_report() const {
    return _native_shadow_diff_report.duplicate(true);
}

Dictionary DCWorldExt::get_native_dirty_report() const {
    return _native_dirty_report.duplicate();
}

} // namespace pk
