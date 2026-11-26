#include "world_ext.h"

#include "runtime_climate_passes.h"
#include "runtime_climate_kernel.h"
#include "runtime_climate_parity.h"

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

struct NativeDailySliceNode {
    const char *name;
    const char *bundle_key;
    const char *fail_stage;
    uint64_t read_mask;
    uint64_t write_mask;
};

static const NativeDailySliceNode NATIVE_DAILY_SLICE_GRAPH[] = {
    {"climate_pass_a", "climate_pass_a_struct", "climate_pass_a",
     SYS_MASK_CLIMATE | SYS_MASK_TERRAIN, SYS_MASK_CLIMATE},
    {"climate_pass_b", "climate_pass_b_knobs", "climate_pass_b",
     SYS_MASK_CLIMATE | SYS_MASK_TERRAIN, SYS_MASK_CLIMATE},
    {"ocean_water", "ocean_water_knobs", "ocean_water",
     SYS_MASK_CLIMATE | SYS_MASK_OCEAN, SYS_MASK_OCEAN},
    {"ocean_land", "ocean_land_knobs", "ocean_land",
     SYS_MASK_CLIMATE | SYS_MASK_OCEAN | SYS_MASK_TERRAIN, SYS_MASK_CLIMATE | SYS_MASK_OCEAN},
    {"wind_air", "wind_air_knobs", "wind_air",
     SYS_MASK_CLIMATE | SYS_MASK_TERRAIN, SYS_MASK_CLIMATE},
    {"wind_surface", "wind_surface_knobs", "wind_surface",
     SYS_MASK_CLIMATE | SYS_MASK_TERRAIN, SYS_MASK_CLIMATE},
    {"sea_ice", "sea_ice_knobs", "sea_ice",
     SYS_MASK_CLIMATE | SYS_MASK_OCEAN | SYS_MASK_TERRAIN, SYS_MASK_CLIMATE | SYS_MASK_SEA_ICE | SYS_MASK_TERRAIN},
    {"transpiration", "transpiration_knobs", "transpiration",
     SYS_MASK_CLIMATE | SYS_MASK_TERRAIN, SYS_MASK_CLIMATE},
    {"albedo", "albedo_knobs", "albedo",
     SYS_MASK_CLIMATE | SYS_MASK_TERRAIN, SYS_MASK_STAGE_B},
    {"vegetation_dynamics", "vegetation_dynamics_knobs", "vegetation_dynamics",
     SYS_MASK_CLIMATE | SYS_MASK_TERRAIN, SYS_MASK_STAGE_B},
    {"climate_feedback", "climate_feedback_knobs", "climate_feedback",
     SYS_MASK_CLIMATE | SYS_MASK_TERRAIN, SYS_MASK_STAGE_B},
    {"stage_b", "stage_b_knobs", "stage_b",
     SYS_MASK_CLIMATE | SYS_MASK_TERRAIN | SYS_MASK_STAGE_B, SYS_MASK_CLIMATE | SYS_MASK_STAGE_B},
    {"weather", "weather_knobs", "weather",
     SYS_MASK_CLIMATE | SYS_MASK_WEATHER | SYS_MASK_TERRAIN, SYS_MASK_WEATHER | SYS_MASK_STAGE_B},
    {"weather_field", "weather_knobs", "weather_field",
     SYS_MASK_CLIMATE | SYS_MASK_WEATHER | SYS_MASK_TERRAIN, SYS_MASK_WEATHER},
    {"weather_commit", "weather_knobs", "weather_commit",
     SYS_MASK_WEATHER, SYS_MASK_WEATHER},
    {"weather_distribute", "weather_knobs", "weather_distribute",
     SYS_MASK_WEATHER | SYS_MASK_TERRAIN, SYS_MASK_WEATHER | SYS_MASK_STAGE_B},
    {"weather_summary", "weather_knobs", "weather_summary",
     SYS_MASK_WEATHER | SYS_MASK_TERRAIN, SYS_MASK_WEATHER},
    {"weather_cyclone", "weather_knobs", "weather_cyclone",
     SYS_MASK_WEATHER | SYS_MASK_TERRAIN, SYS_MASK_WEATHER},
    {"weather_stage_b", "weather_knobs", "weather_stage_b",
     SYS_MASK_CLIMATE | SYS_MASK_WEATHER | SYS_MASK_TERRAIN | SYS_MASK_STAGE_B,
     SYS_MASK_CLIMATE | SYS_MASK_STAGE_B},
    {"runtime_hydrology", "runtime_hydrology_knobs", "runtime_hydrology",
     SYS_MASK_WEATHER | SYS_MASK_TERRAIN | SYS_MASK_HYDROLOGY, SYS_MASK_HYDROLOGY | SYS_MASK_STAGE_B},
    {"stage_b_after_hydrology", "stage_b_after_hydrology_knobs", "stage_b",
     SYS_MASK_CLIMATE | SYS_MASK_TERRAIN | SYS_MASK_STAGE_B | SYS_MASK_HYDROLOGY, SYS_MASK_CLIMATE | SYS_MASK_STAGE_B},
};

static const int NATIVE_DAILY_SLICE_GRAPH_SIZE =
    sizeof(NATIVE_DAILY_SLICE_GRAPH) / sizeof(NativeDailySliceNode);

static int native_daily_node_index_by_name(const String &name) {
    for (int i = 0; i < NATIVE_DAILY_SLICE_GRAPH_SIZE; ++i) {
        if (name == String(NATIVE_DAILY_SLICE_GRAPH[i].name)) {
            return i;
        }
    }
    return -1;
}

static bool native_daily_node_has_builtin_range(const char *name) {
    // climate_pass_a is cell-local: it only reads/writes the same index and
    // the annual insolation LUT is prepared once before the range loop.  It is
    // therefore safe to advance with the same deterministic fixed cursor as
    // the ocean/wind nodes.  The pass itself suppresses visible flushes while
    // a range is incomplete; the graph finalizer publishes once at completion.
    return std::strcmp(name, "climate_pass_a") == 0 ||
           std::strcmp(name, "ocean_water") == 0 ||
           std::strcmp(name, "ocean_land") == 0 ||
           std::strcmp(name, "wind_air") == 0 ||
           std::strcmp(name, "wind_surface") == 0 ||
           std::strcmp(name, "weather_field") == 0;
}

static uint32_t native_daily_parse_range_node_bits(const Variant &value) {
    uint32_t bits = 0u;
    auto add_name = [&](const String &name) {
        const int idx = native_daily_node_index_by_name(name);
        if (idx >= 0 && idx < 32 && native_daily_node_has_builtin_range(NATIVE_DAILY_SLICE_GRAPH[idx].name)) {
            bits |= (1u << idx);
        }
    };
    if (value.get_type() == Variant::PACKED_STRING_ARRAY) {
        PackedStringArray names = value;
        for (int i = 0; i < names.size(); ++i) {
            add_name(names[i]);
        }
    } else if (value.get_type() == Variant::ARRAY) {
        Array names = value;
        for (int i = 0; i < names.size(); ++i) {
            add_name(String(names[i]));
        }
    } else if (value.get_type() == Variant::STRING || value.get_type() == Variant::STRING_NAME) {
        add_name(String(value));
    }
    return bits;
}

// Perf (2026-06): the spread round-start slice (climate_pass_a) was dominated by a
// full `bundle.duplicate(true)` deep copy (~1.5ms): ~10 knob dicts each holding several
// 2464-cell PackedFloat32Arrays, copied byte-for-byte every round. The deep copy exists
// only so C++ can own a stable bundle across ticks and mutate it (JIT patch key
// replacement + ocean anomaly hand-off) without disturbing the GDScript-passed dict.
// But C++ never writes the per-cell array *buffers* in place (passes read knobs → write
// SoA slots); the only mutations are dict-level (add/replace keys). So we duplicate the
// Dictionary/Array *structure* (cheap — small node maps) while SHARING the Packed* leaf
// buffers via copy-on-write. Because C++ never forks those buffers, this is bit-equal to
// duplicate(true) but skips the per-round array byte-copy. (CoW also makes it safe if
// GDScript later mutates its bundle: the write forks on its side, leaving C++'s snapshot
// intact — identical to the deep-copy semantics.)
#include "world_ext_daily_sim_section_bundle_snapshots.inc"
static uint32_t native_daily_deferred_node_bits(const Dictionary &bundle) {
    uint32_t bits = 0u;
    if (!bundle.has("native_daily_deferred_nodes")) {
        return bits;
    }
    PackedInt32Array nodes = bundle["native_daily_deferred_nodes"];
    for (int i = 0; i < nodes.size(); ++i) {
        const int idx = nodes[i];
        if (idx >= 0 && idx < 32) {
            bits |= (1u << idx);
        }
    }
    return bits;
}

static bool native_daily_is_weather_split_node(const char *name) {
    return std::strcmp(name, "weather_field") == 0 ||
           std::strcmp(name, "weather_commit") == 0 ||
           std::strcmp(name, "weather_distribute") == 0 ||
           std::strcmp(name, "weather_summary") == 0 ||
           std::strcmp(name, "weather_cyclone") == 0 ||
           std::strcmp(name, "weather_stage_b") == 0;
}

static bool native_daily_node_enabled_for_bundle(const Dictionary &bundle,
                                                 const NativeDailySliceNode &node) {
    if (native_daily_is_weather_split_node(node.name)) {
        return bool(bundle.get("native_daily_split_weather_node_enabled", false));
    }
    return true;
}

static int native_daily_next_present_node(const Dictionary &bundle, int start_index,
                                          uint32_t deferred_bits = 0u) {
    for (int i = start_index; i < NATIVE_DAILY_SLICE_GRAPH_SIZE; ++i) {
        const NativeDailySliceNode &node = NATIVE_DAILY_SLICE_GRAPH[i];
        if (!native_daily_node_enabled_for_bundle(bundle, node)) {
            continue;
        }
        if (bundle.has(node.bundle_key) || (i < 32 && ((deferred_bits >> i) & 1u))) {
            return i;
        }
    }
    return -1;
}

Dictionary DCWorldExt::run_native_daily_slice(const Dictionary &tick_knobs) {
    Dictionary out;
    const auto t0 = std::chrono::high_resolution_clock::now();

    auto finish_unconfigured = [&]() -> Dictionary {
        out["rc"] = -1;
        out["path"] = String("gdext_native_daily_slice");
        out["fail_stage"] = String("native_world_not_configured");
        out["fallback_reason"] = String("native world is not configured");
        out["reason"] = out["fallback_reason"];
        out["done"] = true;
        out["progress_ratio"] = 0.0;
        out["stage_name"] = String("native_world_not_configured");
        out["substage"] = String("failure");
        out["total_ms"] = 0.0;
        out["native_ms"] = 0.0;
        out["compute_ms"] = 0.0;
        out["refresh_ms"] = 0.0;
        out["flush_ms"] = 0.0;
        out["published_slots"] = Array();
        out["visual_dirty_intents"] = Array();
        out["dirty_cells"] = 0;
        out["breakdown"] = Dictionary();
        out["dirty_flags"] = Dictionary();
        out["fronts_changed"] = false;
        out["fronts"] = _native_fronts_snapshot;
        out["tick_count"] = _native_daily_tick_count;
        return out;
    };

    if (!_native_world_configured) {
        return finish_unconfigured();
    }

    auto as_dict = [](const Variant &v) -> Dictionary {
        if (v.get_type() == Variant::DICTIONARY) {
            return v;
        }
        return Dictionary();
    };

    auto compute_ms_from_breakdown = [](const Dictionary &breakdown) -> double {
        return double(breakdown.get("climate_ms", 0.0)) +
               double(breakdown.get("ocean_ms", 0.0)) +
               double(breakdown.get("weather_ms", 0.0)) +
               double(breakdown.get("hydrology_ms", 0.0)) +
               double(breakdown.get("stage_b_ms", 0.0));
    };

    auto finish_with_failure = [&](const String &stage, const String &reason) -> Dictionary {
        const auto t_fail = std::chrono::high_resolution_clock::now();
        const double slice_ms = std::chrono::duration<double, std::milli>(t_fail - t0).count();
        _native_daily_slice_elapsed_accum_ms += slice_ms;
        Dictionary breakdown = _native_daily_slice_breakdown;
        breakdown["fallback_reason"] = reason;
        breakdown["native_ms"] = slice_ms;
        breakdown["round_native_ms"] = _native_daily_slice_elapsed_accum_ms;
        breakdown["compute_ms"] = compute_ms_from_breakdown(breakdown);
        breakdown["stage_name"] = stage;
        breakdown["substage"] = String("failure");
        breakdown["progress_ratio"] =
            NATIVE_DAILY_SLICE_GRAPH_SIZE > 0
                ? double(_native_daily_slice_node_index) / double(NATIVE_DAILY_SLICE_GRAPH_SIZE)
                : 0.0;

        out["rc"] = -1;
        out["path"] = String("gdext_native_daily_slice");
        out["fail_stage"] = stage;
        out["reason"] = reason;
        out["fallback_reason"] = reason;
        out["done"] = true;
        out["progress_ratio"] = breakdown["progress_ratio"];
        out["stage_name"] = stage;
        out["substage"] = String("failure");
        out["cursor_start"] = _native_daily_slice_node_index;
        out["cursor_end"] = _native_daily_slice_node_index;
        out["total_ms"] = slice_ms;
        out["native_ms"] = slice_ms;
        out["round_native_ms"] = _native_daily_slice_elapsed_accum_ms;
        out["compute_ms"] = breakdown["compute_ms"];
        out["refresh_ms"] = double(breakdown.get("native_context_ms", 0.0));
        out["flush_ms"] = double(breakdown.get("render_prepare_ms", 0.0));
        out["published_slots"] = Array();
        out["visual_dirty_intents"] = Array();
        out["dirty_cells"] = int(_native_dirty_report.get("dirty_cell_count", 0));
        out["breakdown"] = breakdown;
        out["dirty_flags"] = _native_dirty_report.duplicate();
        out["fronts_changed"] = false;
        out["fronts"] = _native_fronts_snapshot;
        out["tick_count"] = _native_daily_tick_count;
        _native_daily_report = out.duplicate(true);
        _native_daily_slice_active = false;
        _native_daily_visual_commit_pending = false;
        _native_daily_slice_cell_cursor = 0;
        _native_daily_slice_range_node_index = -1;
        _native_daily_slice_range_node_bits = 0u;
        return out;
    };

#include "world_ext_daily_sim_section_slice_setup.inc"
#include "world_ext_daily_sim_section_slice_dispatch.inc"
#include "world_ext_daily_sim_section_slice_finish_rules.inc"
#include "world_ext_daily_sim_section_slice_report.inc"
}


Dictionary DCWorldExt::run_native_daily_tick(const Dictionary &tick_knobs) {
    Dictionary out;
    const auto t0 = std::chrono::high_resolution_clock::now();

    if (!_native_world_configured) {
        out["rc"] = -1;
        out["path"] = String("gdext_native_daily");
        out["fail_stage"] = String("native_world_not_configured");
        out["fallback_reason"] = String("native world is not configured");
        out["total_ms"] = 0.0;
        out["native_ms"] = 0.0;
        out["compute_ms"] = 0.0;
        out["refresh_ms"] = 0.0;
        out["flush_ms"] = 0.0;
        out["published_slots"] = Array();
        out["visual_dirty_intents"] = Array();
        out["dirty_cells"] = 0;
        return out;
    }

#include "world_ext_daily_sim_section_tick_parity_probe.inc"

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
    breakdown["hydrology_ms"] = 0.0;
    breakdown["ocean_ms"] = 0.0;
    breakdown["stage_b_ms"] = 0.0;
    breakdown["render_prepare_ms"] = 0.0;
    breakdown["path"] = String("gdext_native_daily");
    breakdown["fallback_reason"] = String();

#include "world_ext_daily_sim_section_tick_report_builders.inc"

    if (!tick_knobs.has("native_daily_bundle")) {
        return finish_with_failure("native_daily_bundle", "missing native_daily_bundle");
    }
    Dictionary bundle = as_dict(tick_knobs.get("native_daily_bundle", Dictionary()));
    if (bundle.is_empty()) {
        return finish_with_failure("native_daily_bundle", "empty native_daily_bundle");
    }
    const Array bundle_pass_keys = collect_bundle_pass_keys(bundle);
    const Array retained_gdscript_authority = collect_retained_gdscript_authority(bundle);
    const Dictionary native_state_snapshot = collect_native_state_snapshot(bundle);
    breakdown["bundle_pass_keys"] = bundle_pass_keys;
    breakdown["retained_gdscript_authority"] = retained_gdscript_authority;
    breakdown["native_state_snapshot"] = native_state_snapshot;

    const auto t_context0 = std::chrono::high_resolution_clock::now();
    if (bool(bundle.get("refresh_slots_from_map", true))) {
        PackedStringArray refresh_keys = bundle.get("refresh_slot_keys", PackedStringArray());
        if (refresh_keys.size() > 0) {
            refresh_slots_from_map_keys(refresh_keys);
        } else {
            refresh_slots_from_map();
        }
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
#include "world_ext_daily_sim_section_tick_execution_and_publish.inc"
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

#include "world_ext_daily_sim_section_ocean_physical_controller.inc"

#include "world_ext_daily_sim_section_daily_finalizer.inc"

} // namespace pk
