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
    return std::strcmp(name, "ocean_water") == 0 ||
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
static Variant native_daily_cow_structural_copy(const Variant &v) {
    switch (v.get_type()) {
        case Variant::DICTIONARY: {
            Dictionary src = v;
            Dictionary out;
            Array keys = src.keys();
            for (int i = 0; i < keys.size(); ++i) {
                const Variant &k = keys[i];
                out[k] = native_daily_cow_structural_copy(src[k]);
            }
            return out;
        }
        case Variant::ARRAY: {
            Array src = v;
            Array out;
            out.resize(src.size());
            for (int i = 0; i < src.size(); ++i) {
                out[i] = native_daily_cow_structural_copy(src[i]);
            }
            return out;
        }
        default:
            // Scalars + Packed*Array leaves: share (PackedArray is CoW; C++ never writes
            // these buffers in place, so no fork happens on the hot path).
            return v;
    }
}

static void native_daily_append_unique(Array &arr, const String &value) {
    for (int i = 0; i < arr.size(); ++i) {
        if (String(arr[i]) == value) {
            return;
        }
    }
    arr.append(value);
}

static Array native_daily_collect_bundle_pass_keys(const Dictionary &bundle_dict) {
    Array keys;
    auto record_key = [&](const char *key) {
        if (bundle_dict.has(key)) {
            keys.append(String(key));
        }
    };
    record_key("climate_pass_a_struct");
    record_key("ocean_water_knobs");
    record_key("ocean_land_knobs");
    record_key("climate_pass_b_knobs");
    record_key("wind_air_knobs");
    record_key("wind_surface_knobs");
    record_key("sea_ice_knobs");
    record_key("transpiration_knobs");
    record_key("albedo_knobs");
    record_key("vegetation_dynamics_knobs");
    record_key("climate_feedback_knobs");
    record_key("stage_b_knobs");
    record_key("weather_knobs");
    record_key("runtime_hydrology_knobs");
    record_key("stage_b_after_hydrology_knobs");
    return keys;
}

static Array native_daily_collect_published_slots(const Dictionary &bundle_dict) {
    Array slots;
    if (bundle_dict.has("climate_pass_a_struct") || bundle_dict.has("climate_pass_b_knobs") ||
        bundle_dict.has("ocean_water_knobs") || bundle_dict.has("ocean_land_knobs") ||
        bundle_dict.has("wind_air_knobs") || bundle_dict.has("wind_surface_knobs") ||
        bundle_dict.has("sea_ice_knobs") || bundle_dict.has("transpiration_knobs")) {
        native_daily_append_unique(slots, String("cell_temp"));
        native_daily_append_unique(slots, String("cell_moisture"));
        native_daily_append_unique(slots, String("cell_snow_cover"));
        native_daily_append_unique(slots, String("cell_sea_ice_frac"));
        native_daily_append_unique(slots, String("cell_air_mass_temp_anomaly"));
        native_daily_append_unique(slots, String("cell_ocean_thermal_anomaly"));
        native_daily_append_unique(slots, String("cell_local_thermal_anomaly"));
    }
    if (bundle_dict.has("stage_b_knobs") || bundle_dict.has("stage_b_after_hydrology_knobs") ||
        bundle_dict.has("albedo_knobs") ||
        bundle_dict.has("vegetation_dynamics_knobs") || bundle_dict.has("climate_feedback_knobs")) {
        native_daily_append_unique(slots, String("cell_cover"));
        native_daily_append_unique(slots, String("cell_vegetation"));
        native_daily_append_unique(slots, String("cell_vegetation_vitality"));
    }
    if (bundle_dict.has("weather_knobs")) {
        native_daily_append_unique(slots, String("cell_weather_type"));
        native_daily_append_unique(slots, String("cell_weather_intensity"));
        native_daily_append_unique(slots, String("cell_weather_cloud"));
        native_daily_append_unique(slots, String("cell_weather_precip"));
        native_daily_append_unique(slots, String("cell_weather_field_init"));
        native_daily_append_unique(slots, String("cell_weather_transition_alpha"));
    }
    if (bundle_dict.has("runtime_hydrology_knobs")) {
        native_daily_append_unique(slots, String("cell_soil_moisture"));
        native_daily_append_unique(slots, String("cell_water_balance_30d"));
        native_daily_append_unique(slots, String("cell_river_discharge"));
        native_daily_append_unique(slots, String("cell_river_discharge_30d"));
        native_daily_append_unique(slots, String("cell_river_storage"));
        native_daily_append_unique(slots, String("cell_groundwater_storage"));
        native_daily_append_unique(slots, String("cell_surface_runoff"));
    }
    return slots;
}

static Array native_daily_collect_retained_gdscript_authority(const Dictionary &bundle_dict) {
    Array retained;
    if (!bundle_dict.has("wind_air_knobs")) {
        retained.append(String("wind_air"));
    }
    if (!bundle_dict.has("wind_surface_knobs")) {
        retained.append(String("wind_surface"));
    }
    if (bool(bundle_dict.get("runtime_hydrology_requested", false)) &&
        !bundle_dict.has("runtime_hydrology_knobs")) {
        retained.append(String("runtime_hydrology"));
    }
    if (!bundle_dict.has("sea_ice_knobs")) {
        retained.append(String("sea_ice"));
    }
    return retained;
}

static Array native_daily_collect_retained_boundaries(const Dictionary &bundle_dict) {
    Array retained;
    native_daily_append_unique(retained, String("visual_uploads"));
    native_daily_append_unique(retained, String("csv_debug_sampling"));
    if (bundle_dict.has("weather_knobs")) {
        native_daily_append_unique(retained, String("weather_front_objects_gdscript"));
        native_daily_append_unique(retained, String("weather_lut_upload_godot"));
    }
    if (bundle_dict.has("sea_ice_knobs")) {
        native_daily_append_unique(retained, String("sea_ice_terrain_flip_visibility_gdscript"));
        native_daily_append_unique(retained, String("sea_ice_visual_upload_godot"));
    }
    if (bundle_dict.has("ocean_physical_state_snapshot")) {
        native_daily_append_unique(retained, String("ocean_visual_raster_godot"));
        native_daily_append_unique(retained, String("ocean_texture_commit_godot"));
    }
    if (bundle_dict.has("season_refresh_state_snapshot")) {
        native_daily_append_unique(retained, String("season_atlas_queue_godot"));
        native_daily_append_unique(retained, String("detail_scatter_godot"));
    }
    return retained;
}

static Array native_daily_collect_visual_dirty_intents(const Dictionary &bundle_dict,
                                                       const Dictionary &breakdown_dict,
                                                       const Dictionary &dirty_report) {
    Array intents;
    if (bool(dirty_report.get("atlas_dirty", false))) {
        native_daily_append_unique(intents, String("atlas"));
    }
    if (bool(dirty_report.get("enum_atlas_dirty", false))) {
        native_daily_append_unique(intents, String("enum_atlas"));
    }
    if (bool(dirty_report.get("sea_ice_atlas_dirty", false))) {
        native_daily_append_unique(intents, String("sea_ice_atlas"));
    }
    if (bundle_dict.has("weather_knobs") &&
        (bool(breakdown_dict.get("weather_lut_changed", false)) ||
         breakdown_dict.has("weather_lut"))) {
        native_daily_append_unique(intents, String("weather_lut"));
    }
    if (breakdown_dict.has("succession_indices") ||
        int(breakdown_dict.get("stat_succession_count", 0)) > 0) {
        native_daily_append_unique(intents, String("detail_scatter"));
    }
    return intents;
}

static Dictionary native_daily_collect_state_snapshot(const Dictionary &bundle_dict,
                                                      const Array &retained_authority) {
    Dictionary state;
    state["tick_owner"] = String("DCWorldExt.native_daily_graph");
    state["round_state_owner"] = String("native_active");
    state["continuation_owner"] = String("DCWorldExt.native_daily_slice");
    state["visual_upload_state_owner"] = String("godot_retained");
    state["fallback_owner"] =
        bool(bundle_dict.get("legacy_sus_fallback_enabled", true))
            ? String("gdscript_legacy_sus")
            : String("explicit_failure_only");

    Dictionary climate_round_state;
    if (bundle_dict.get("climate_round_state_snapshot", Dictionary()).get_type() == Variant::DICTIONARY) {
        climate_round_state = Dictionary(bundle_dict.get("climate_round_state_snapshot", Dictionary()));
        state["climate_round_state"] = climate_round_state;
    }
    state["climate_round_state_owner"] =
        climate_round_state.has("owner")
            ? String(climate_round_state.get("owner", "gdscript_retained"))
            : String("gdscript_retained");

    Dictionary ocean_physical_state;
    if (bundle_dict.get("ocean_physical_state_snapshot", Dictionary()).get_type() == Variant::DICTIONARY) {
        ocean_physical_state = Dictionary(bundle_dict.get("ocean_physical_state_snapshot", Dictionary()));
        state["ocean_physical_state"] = ocean_physical_state;
    }
    state["ocean_physical_state_owner"] =
        ocean_physical_state.has("owner")
            ? String(ocean_physical_state.get("owner", "gdscript_retained"))
            : String("gdscript_retained");

    Dictionary season_refresh_state;
    if (bundle_dict.get("season_refresh_state_snapshot", Dictionary()).get_type() == Variant::DICTIONARY) {
        season_refresh_state = Dictionary(bundle_dict.get("season_refresh_state_snapshot", Dictionary()));
        state["season_refresh_state"] = season_refresh_state;
    }
    state["season_refresh_state_owner"] =
        season_refresh_state.has("owner")
            ? String(season_refresh_state.get("owner", "gdscript_retained"))
            : String("gdscript_retained");

    Dictionary season_cadence_policy;
    if (bundle_dict.get("season_cadence_policy", Dictionary()).get_type() == Variant::DICTIONARY) {
        season_cadence_policy = Dictionary(bundle_dict.get("season_cadence_policy", Dictionary()));
        state["season_cadence_policy"] = season_cadence_policy;
    }

    Dictionary weather_readiness;
    if (bundle_dict.get("weather_native_daily_readiness", Dictionary()).get_type() == Variant::DICTIONARY) {
        weather_readiness = Dictionary(bundle_dict.get("weather_native_daily_readiness", Dictionary()));
    }
    const bool weather_native_ready = bool(weather_readiness.get("ready", false));
    const bool weather_active_requested = bool(bundle_dict.get("weather_transaction_active_owner_requested", false));
    state["weather_transaction_state_owner"] =
        (weather_native_ready && weather_active_requested)
            ? String("native_active")
            : (weather_native_ready
                   ? String("native_ready")
                   : (bundle_dict.has("weather_knobs")
                          ? String("native_transaction_with_gdscript_apply")
                          : String("gdscript_retained")));

    Dictionary authority_report;
    Dictionary graph_authority;
    graph_authority["owner"] = String("native_active");
    graph_authority["phase"] = String("native_continuation");
    graph_authority["simulation_authority"] = true;
    graph_authority["state_owner"] = String("DCWorldExt");
    authority_report["native_daily_graph"] = graph_authority;

    Dictionary climate_authority;
    climate_authority["owner"] = state["climate_round_state_owner"];
    climate_authority["phase"] =
        String(state["climate_round_state_owner"]) == String("native_active")
            ? String("active_owner_gate")
            : (String(state["climate_round_state_owner"]) == String("native_ready")
                   ? String("native_ready_probe")
                   : String("gdscript_state_machine"));
    climate_authority["simulation_authority"] =
        String(state["climate_round_state_owner"]) == String("native_active");
    climate_authority["state"] = climate_round_state;
    climate_authority["remaining_gdscript_authority"] =
        climate_round_state.get("remaining_gdscript_authority", Array());
    authority_report["climate_round"] = climate_authority;

    Dictionary weather_authority;
    weather_authority["owner"] = state["weather_transaction_state_owner"];
    weather_authority["phase"] =
        (weather_native_ready && weather_active_requested)
            ? String("native_active_visible_publish")
            : (weather_native_ready
                   ? String("native_ready_visible_publish")
                   : (bundle_dict.has("weather_knobs")
                          ? String("native_transaction_with_gdscript_apply")
                          : String("gdscript_retained")));
    weather_authority["readiness"] = weather_readiness;
    weather_authority["visible_publish_ready"] = weather_native_ready;
    weather_authority["active_owner_requested"] = weather_active_requested;
    weather_authority["simulation_authority"] = weather_native_ready && weather_active_requested;
    weather_authority["front_snapshot_ready"] = bool(weather_readiness.get("has_result_apply", false));
    weather_authority["weather_lut_intent_ready"] = bool(weather_readiness.get("has_weather_lut_publish", false));
    weather_authority["retained_boundaries"] =
        Array::make(String("front_objects_gdscript"),
                    String("weather_lut_upload_godot_boundary"));
    weather_authority["blockers"] =
        weather_native_ready
            ? Array()
            : Array::make(String("weather_transaction_state_gdscript"),
                          String(weather_readiness.get("reason", "not_ready")));
    authority_report["weather_transaction"] = weather_authority;

    Dictionary hydrology_authority;
    hydrology_authority["owner"] =
        bundle_dict.has("runtime_hydrology_knobs") ? String("native_active") : String("gdscript_retained");
    hydrology_authority["phase"] =
        bundle_dict.has("runtime_hydrology_knobs") ? String("native_graph_node") : String("legacy_weather_chain");
    hydrology_authority["simulation_authority"] = bundle_dict.has("runtime_hydrology_knobs");
    hydrology_authority["published_slots_expected"] =
        bundle_dict.has("runtime_hydrology_knobs")
            ? Array::make(String("cell_soil_moisture"),
                          String("cell_water_balance_30d"),
                          String("cell_river_discharge"),
                          String("cell_river_discharge_30d"),
                          String("cell_river_storage"),
                          String("cell_groundwater_storage"),
                          String("cell_surface_runoff"))
            : Array();
    hydrology_authority["blockers"] =
        bundle_dict.has("runtime_hydrology_knobs")
            ? Array()
            : Array::make(String("runtime_hydrology_knobs_missing"));
    authority_report["runtime_hydrology"] = hydrology_authority;

    Dictionary sea_ice_authority;
    sea_ice_authority["owner"] =
        bundle_dict.has("sea_ice_knobs") ? String("native_active") : String("gdscript_retained");
    sea_ice_authority["phase"] =
        bundle_dict.has("sea_ice_knobs") ? String("native_graph_node") : String("legacy_climate_or_sea_ice_job");
    sea_ice_authority["simulation_authority"] = bundle_dict.has("sea_ice_knobs");
    sea_ice_authority["published_slots_expected"] =
        bundle_dict.has("sea_ice_knobs")
            ? Array::make(String("cell_sea_ice_frac"),
                          String("cell_temp"),
                          String("cell_moisture"))
            : Array();
    sea_ice_authority["blockers"] =
        bundle_dict.has("sea_ice_knobs")
            ? Array()
            : Array::make(String("sea_ice_knobs_missing"));
    sea_ice_authority["retained_boundaries"] =
        bundle_dict.has("sea_ice_knobs")
            ? Array::make(String("terrain_flip_visibility_gdscript"),
                          String("sea_ice_visual_upload_godot"))
            : Array();
    authority_report["sea_ice"] = sea_ice_authority;

    Dictionary ocean_authority;
    ocean_authority["owner"] = state["ocean_physical_state_owner"];
    ocean_authority["phase"] =
        String(state["ocean_physical_state_owner"]) == String("native_active")
            ? String("native_active_lifecycle")
            : (String(state["ocean_physical_state_owner"]) == String("native_ready") ||
               String(state["ocean_physical_state_owner"]) == String("native_ready_probe")
                   ? String("native_ready_probe")
                   : String("gdscript_stage_machine"));
    ocean_authority["state"] = ocean_physical_state;
    ocean_authority["simulation_authority"] =
        String(state["ocean_physical_state_owner"]) == String("native_active");
    ocean_authority["native_owned_output_slots"] =
        ocean_physical_state.get("native_owned_output_slots", Array());
    ocean_authority["blockers"] =
        String(state["ocean_physical_state_owner"]) == String("native_active")
            ? Array()
            : Array::make(String("ocean_physical_owner_not_active"));
    ocean_authority["retained_boundaries"] =
        ocean_physical_state.get("remaining_gdscript_authority",
            Array::make(String("visual_raster_boundary_godot"),
                        String("texture_commit_boundary_godot")));
    authority_report["ocean_physical"] = ocean_authority;

    Dictionary season_authority;
    season_authority["owner"] = state["season_refresh_state_owner"];
    season_authority["phase"] =
        String(state["season_refresh_state_owner"]) == String("native_active")
            ? String("native_active_cadence")
            : (String(state["season_refresh_state_owner"]) == String("native_ready") ||
               String(state["season_refresh_state_owner"]) == String("native_ready_probe")
                   ? String("native_ready_cadence_probe")
                   : String("gdscript_cadence"));
    season_authority["state"] = season_refresh_state;
    season_authority["simulation_authority"] =
        String(state["season_refresh_state_owner"]) == String("native_active");
    season_authority["simulation_slot_dirty_intents"] =
        season_refresh_state.get("simulation_slot_dirty_intents", Array());
    season_authority["visual_dirty_intents"] =
        season_refresh_state.get("visual_dirty_intents", Array());
    season_authority["cadence_policy"] = season_cadence_policy;
    season_authority["blockers"] =
        String(state["season_refresh_state_owner"]) == String("native_active")
            ? Array()
            : Array::make(String("season_refresh_owner_not_active"));
    season_authority["retained_boundaries"] =
        season_refresh_state.get("visual_dirty_intents",
            Array::make(String("atlas_queue_godot"),
                        String("detail_scatter_godot")));
    authority_report["season_refresh"] = season_authority;

    Dictionary visual_authority;
    visual_authority["owner"] = String("godot_retained");
    visual_authority["phase"] = String("godot_upload_boundary");
    visual_authority["blockers"] = Array();
    visual_authority["retained_boundaries"] = Array::make(String("image_texture_upload_godot"));
    authority_report["visual_upload"] = visual_authority;

    Dictionary fallback_authority;
    const bool legacy_fallback_enabled = bool(bundle_dict.get("legacy_sus_fallback_enabled", true));
    fallback_authority["owner"] =
        legacy_fallback_enabled ? String("gdscript_legacy_sus") : String("explicit_failure_only");
    fallback_authority["phase"] =
        legacy_fallback_enabled ? String("fallback_retained") : String("fallback_test_only");
    fallback_authority["blockers"] =
        legacy_fallback_enabled ? Array::make(String("legacy_sus_fallback_enabled")) : Array();
    authority_report["fallback"] = fallback_authority;

    Array authority_blockers = retained_authority.duplicate();
    if (String(state.get("climate_round_state_owner", "gdscript_retained")) != String("native_active")) {
        native_daily_append_unique(authority_blockers, String("climate_round"));
    }
    if (bundle_dict.has("weather_knobs") &&
        String(state.get("weather_transaction_state_owner", "gdscript_retained")) != String("native_active")) {
        native_daily_append_unique(authority_blockers, String("weather_transaction"));
    }
    if (String(state.get("ocean_physical_state_owner", "gdscript_retained")) != String("native_active")) {
        native_daily_append_unique(authority_blockers, String("ocean_currents_physical_state"));
    }
    if (String(state.get("season_refresh_state_owner", "gdscript_retained")) != String("native_active")) {
        native_daily_append_unique(authority_blockers, String("season_refresh"));
    }
    if (bool(bundle_dict.get("legacy_sus_fallback_enabled", true))) {
        native_daily_append_unique(authority_blockers, String("legacy_sus_fallback_enabled"));
    }
    Array retained_boundaries = native_daily_collect_retained_boundaries(bundle_dict);
    state["authority_report"] = authority_report;
    state["authority_blockers"] = authority_blockers;
    state["retained_boundaries"] = retained_boundaries;
    state["retained_godot_boundaries"] = retained_boundaries;
    state["retained_boundary_policy"] = String("explicit_godot_presentation_boundary");
    state["graph_coverage_state"] = authority_blockers.is_empty() ? String("complete") : String("partial");
    return state;
}

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
        _native_daily_slice_cell_cursor = 0;
        _native_daily_slice_range_node_index = -1;
        _native_daily_slice_range_node_bits = 0u;
        return out;
    };

    if (!_native_daily_slice_active) {
        if (!tick_knobs.has("native_daily_bundle")) {
            return finish_with_failure(String("native_daily_bundle"), String("missing native_daily_bundle"));
        }
        Dictionary bundle = as_dict(tick_knobs.get("native_daily_bundle", Dictionary()));
        if (bundle.is_empty()) {
            return finish_with_failure(String("native_daily_bundle"), String("empty native_daily_bundle"));
        }
        const uint32_t deferred_bits = native_daily_deferred_node_bits(bundle);
        if (native_daily_next_present_node(bundle, 0, deferred_bits) < 0) {
            return finish_with_failure(String("native_daily_bundle"), String("no pass knobs in native_daily_bundle"));
        }

        ++_native_daily_tick_count;
        ++_native_daily_slice_round_id;
        _native_daily_slice_active = true;
        _native_daily_slice_node_index = 0;
        _native_daily_slice_cell_cursor = 0;
        _native_daily_slice_range_node_index = -1;
        _native_daily_slice_cell_budget = 0;
        _native_daily_slice_range_node_bits = 0u;
        if (tick_knobs.has("native_daily_node_range_cells")) {
            _native_daily_slice_cell_budget = std::max(0, int(tick_knobs["native_daily_node_range_cells"]));
        }
        if (_native_daily_slice_cell_budget > 0 && tick_knobs.has("native_daily_node_range_nodes")) {
            _native_daily_slice_range_node_bits =
                native_daily_parse_range_node_bits(tick_knobs["native_daily_node_range_nodes"]);
        }
        // Node batching (bit-equal perf): GDScript injects a fresh JIT knob patch only
        // before the nodes listed in `native_daily_slice_yield_nodes` (the temp-dependent
        // passes). C++ may therefore run consecutive non-yield nodes within a single call,
        // cutting GDScript<->C++ round-trips. Absent the key, fall back to yielding before
        // every node (legacy one-node-per-call behavior).
        _native_daily_slice_yield_bits = 0xFFFFFFFFu;
        if (tick_knobs.has("native_daily_slice_yield_nodes")) {
            PackedInt32Array yield_nodes = tick_knobs["native_daily_slice_yield_nodes"];
            _native_daily_slice_yield_bits = 0u;
            for (int i = 0; i < yield_nodes.size(); ++i) {
                const int idx = yield_nodes[i];
                if (idx >= 0 && idx < 32) {
                    _native_daily_slice_yield_bits |= (1u << idx);
                }
            }
        }
        _native_daily_slice_yield_bits |= deferred_bits;
        _native_daily_slice_elapsed_accum_ms = 0.0;
        _native_daily_slice_any_pass_ran = false;
        // Shallow-copy tick_knobs (we only read scalars: day_index / season_phase) and
        // drop the embedded bundle ref — the bundle is owned separately below. This avoids
        // tick_knobs.duplicate(true) deep-copying the bundle a SECOND time (it is also
        // reachable as tick_knobs["native_daily_bundle"]).
        _native_daily_slice_tick_knobs = tick_knobs.duplicate(false);
        _native_daily_slice_tick_knobs.erase("native_daily_bundle");
        // Structure-deep, leaf-shared copy (see native_daily_cow_structural_copy): owns the
        // dict tree for safe key mutation, shares the per-cell Packed arrays via CoW.
        _native_daily_slice_bundle = native_daily_cow_structural_copy(bundle);
        _native_daily_slice_bundle_pass_keys = native_daily_collect_bundle_pass_keys(_native_daily_slice_bundle);
        _native_daily_slice_retained_authority =
            native_daily_collect_retained_gdscript_authority(_native_daily_slice_bundle);
        _native_daily_slice_state_snapshot =
            native_daily_collect_state_snapshot(_native_daily_slice_bundle, _native_daily_slice_retained_authority);

        _native_dirty_report = Dictionary();
        _native_dirty_report["last_day_index"] = int(_native_daily_slice_tick_knobs.get("day_index", 0));
        _native_dirty_report["last_season_phase"] =
            double(_native_daily_slice_tick_knobs.get("season_phase", 0.0));
        _native_dirty_report["atlas_dirty"] = false;
        _native_dirty_report["enum_atlas_dirty"] = false;
        _native_dirty_report["sea_ice_atlas_dirty"] = false;
        _native_dirty_report["sea_ice_terrain_flip_count"] = 0;
        _native_dirty_report["dirty_cell_count"] = 0;

        _native_daily_slice_breakdown = Dictionary();
        _native_daily_slice_breakdown["native_context_ms"] = 0.0;
        _native_daily_slice_breakdown["season_ms"] = 0.0;
        _native_daily_slice_breakdown["climate_ms"] = 0.0;
        _native_daily_slice_breakdown["weather_ms"] = 0.0;
        _native_daily_slice_breakdown["hydrology_ms"] = 0.0;
        _native_daily_slice_breakdown["ocean_ms"] = 0.0;
        _native_daily_slice_breakdown["stage_b_ms"] = 0.0;
        _native_daily_slice_breakdown["render_prepare_ms"] = 0.0;
        _native_daily_slice_breakdown["path"] = String("gdext_native_daily_slice");
        _native_daily_slice_breakdown["fallback_reason"] = String();
        _native_daily_slice_breakdown["bundle_pass_keys"] = _native_daily_slice_bundle_pass_keys;
        _native_daily_slice_breakdown["retained_gdscript_authority"] = _native_daily_slice_retained_authority;
        _native_daily_slice_breakdown["native_state_snapshot"] = _native_daily_slice_state_snapshot;
        _native_daily_slice_breakdown["round_id"] = _native_daily_slice_round_id;

        const auto t_context0 = std::chrono::high_resolution_clock::now();
        if (bool(_native_daily_slice_bundle.get("refresh_slots_from_map", true))) {
            refresh_slots_from_map();
        }
        const auto t_context1 = std::chrono::high_resolution_clock::now();
        _native_daily_slice_breakdown["native_context_ms"] =
            std::chrono::duration<double, std::milli>(t_context1 - t_context0).count();
    }

    if (tick_knobs.has("native_daily_bundle_patch")) {
        Dictionary patch = as_dict(tick_knobs.get("native_daily_bundle_patch", Dictionary()));
        if (!patch.is_empty()) {
            Array keys = patch.keys();
            for (int i = 0; i < keys.size(); ++i) {
                Variant k = keys[i];
                _native_daily_slice_bundle[k] = patch[k];
            }
            _native_daily_slice_bundle_pass_keys =
                native_daily_collect_bundle_pass_keys(_native_daily_slice_bundle);
            _native_daily_slice_breakdown["bundle_pass_keys"] = _native_daily_slice_bundle_pass_keys;
            _native_daily_slice_breakdown["jit_patch_key_count"] =
                int(_native_daily_slice_breakdown.get("jit_patch_key_count", 0)) + keys.size();
        }
    }

    Dictionary breakdown = _native_daily_slice_breakdown;
    auto node_name_string = [](const char *name) -> String {
        if (std::strcmp(name, "climate_pass_a") == 0) return String("climate_pass_a");
        if (std::strcmp(name, "ocean_water") == 0) return String("ocean_water");
        if (std::strcmp(name, "ocean_land") == 0) return String("ocean_land");
        if (std::strcmp(name, "climate_pass_b") == 0) return String("climate_pass_b");
        if (std::strcmp(name, "wind_air") == 0) return String("wind_air");
        if (std::strcmp(name, "wind_surface") == 0) return String("wind_surface");
        if (std::strcmp(name, "sea_ice") == 0) return String("sea_ice");
        if (std::strcmp(name, "transpiration") == 0) return String("transpiration");
        if (std::strcmp(name, "albedo") == 0) return String("albedo");
        if (std::strcmp(name, "vegetation_dynamics") == 0) return String("vegetation_dynamics");
        if (std::strcmp(name, "climate_feedback") == 0) return String("climate_feedback");
        if (std::strcmp(name, "stage_b") == 0) return String("stage_b");
        if (std::strcmp(name, "weather") == 0) return String("weather");
        if (std::strcmp(name, "weather_field") == 0) return String("weather_field");
        if (std::strcmp(name, "weather_commit") == 0) return String("weather_commit");
        if (std::strcmp(name, "weather_distribute") == 0) return String("weather_distribute");
        if (std::strcmp(name, "weather_summary") == 0) return String("weather_summary");
        if (std::strcmp(name, "weather_cyclone") == 0) return String("weather_cyclone");
        if (std::strcmp(name, "weather_stage_b") == 0) return String("weather_stage_b");
        if (std::strcmp(name, "runtime_hydrology") == 0) return String("runtime_hydrology");
        if (std::strcmp(name, "stage_b_after_hydrology") == 0) return String("stage_b_after_hydrology");
        return String("unknown");
    };
    auto node_key_string = [](const char *key) -> String {
        if (std::strcmp(key, "climate_pass_a_struct") == 0) return String("climate_pass_a_struct");
        if (std::strcmp(key, "ocean_water_knobs") == 0) return String("ocean_water_knobs");
        if (std::strcmp(key, "ocean_land_knobs") == 0) return String("ocean_land_knobs");
        if (std::strcmp(key, "climate_pass_b_knobs") == 0) return String("climate_pass_b_knobs");
        if (std::strcmp(key, "wind_air_knobs") == 0) return String("wind_air_knobs");
        if (std::strcmp(key, "wind_surface_knobs") == 0) return String("wind_surface_knobs");
        if (std::strcmp(key, "sea_ice_knobs") == 0) return String("sea_ice_knobs");
        if (std::strcmp(key, "transpiration_knobs") == 0) return String("transpiration_knobs");
        if (std::strcmp(key, "albedo_knobs") == 0) return String("albedo_knobs");
        if (std::strcmp(key, "vegetation_dynamics_knobs") == 0) return String("vegetation_dynamics_knobs");
        if (std::strcmp(key, "climate_feedback_knobs") == 0) return String("climate_feedback_knobs");
        if (std::strcmp(key, "stage_b_knobs") == 0) return String("stage_b_knobs");
        if (std::strcmp(key, "weather_knobs") == 0) return String("weather_knobs");
        if (std::strcmp(key, "runtime_hydrology_knobs") == 0) return String("runtime_hydrology_knobs");
        if (std::strcmp(key, "stage_b_after_hydrology_knobs") == 0) return String("stage_b_after_hydrology_knobs");
        return String("unknown");
    };
    auto weather_split_enabled = [&]() -> bool {
        return bool(_native_daily_slice_bundle.get("native_daily_split_weather_node_enabled", false));
    };
    auto add_weather_timing = [&](const char *field, const double ms) {
        breakdown[field] = ms;
        const double weather_ms = double(breakdown.get("weather_ms", 0.0)) + ms;
        breakdown["weather_ms"] = weather_ms;
        breakdown["weather_tick_ms"] = weather_ms;
    };
    auto record_stage_b_diag = [&](const Dictionary &stage_b_knobs) {
        const int call_index = int(stage_b_knobs.get("stage_b_call_index", -1));
        breakdown["stage_b_call_index"] = call_index;
        breakdown["albedo_ran"] = bool(stage_b_knobs.get("run_albedo", false));
        breakdown["veg_dyn_ran"] = bool(stage_b_knobs.get("run_veg_dyn", false));
        breakdown["feedback_ran"] = bool(stage_b_knobs.get("run_feedback", false));
        breakdown["stage_b_combined_done"] = true;
        breakdown["stage_b_ext_ok"] = true;
        breakdown["stage_b_total_runs"] = call_index >= 0 ? call_index + 1 : 0;
    };
    auto exec_slice_node = [&](const NativeDailySliceNode &node) -> bool {
        if (std::strcmp(node.name, "climate_pass_a") == 0) {
            Dictionary cp_struct = as_dict(_native_daily_slice_bundle["climate_pass_a_struct"]);
            const double phase = double(_native_daily_slice_tick_knobs.get("season_phase", 0.0));
            const double season_phase = double(_native_daily_slice_tick_knobs.get("season_phase", phase));
            // [climate-mt 2026-07] 多核：pass_a 纯 cell-local，_thread 与 scalar 逐位等价
            //   （bench 实测 49k~110k ~4-5x；compute-bound，随核近线性）。n_tasks=0=自适应。
            const double ms = run_climate_pass_a_thread(cp_struct, phase, season_phase, 0);
            if (ms < 0.0) return false;
            breakdown["pass_a_ms"] = ms;
            breakdown["climate_ms"] = double(breakdown.get("climate_ms", 0.0)) + ms;
            return true;
        }
        if (std::strcmp(node.name, "ocean_water") == 0) {
            Dictionary water_knobs = as_dict(_native_daily_slice_bundle["ocean_water_knobs"]);
            const bool use_thread = bool(water_knobs.get("native_daily_thread_variant_enabled", false));
            const int thread_tasks = int(water_knobs.get("native_daily_thread_tasks", 0));
            double ms = use_thread
                ? run_ocean_water_pass_thread(water_knobs, thread_tasks)
                : run_ocean_water_pass(water_knobs);
            String variant = use_thread ? String("thread") : String("scalar");
            if (ms < 0.0 && use_thread) {
                ms = run_ocean_water_pass(water_knobs);
                variant = String("thread_fallback_scalar");
            }
            if (ms < 0.0) return false;
            _native_daily_slice_bundle["ocean_water_knobs"] = water_knobs;
            if (water_knobs.has("anomaly_out") && _native_daily_slice_bundle.has("ocean_land_knobs")) {
                Dictionary land_knobs = as_dict(_native_daily_slice_bundle["ocean_land_knobs"]);
                land_knobs["anomaly_inout"] = water_knobs["anomaly_out"];
                _native_daily_slice_bundle["ocean_land_knobs"] = land_knobs;
            }
            breakdown["ocean_water_ms"] = ms;
            breakdown["ocean_water_variant"] = variant;
            breakdown["ocean_water_thread_tasks"] = thread_tasks;
            breakdown["ocean_ms"] = double(breakdown.get("ocean_ms", 0.0)) + ms;
            return true;
        }
        if (std::strcmp(node.name, "ocean_land") == 0) {
            Dictionary land_knobs = as_dict(_native_daily_slice_bundle["ocean_land_knobs"]);
            const bool use_thread = bool(land_knobs.get("native_daily_thread_variant_enabled", false));
            const int thread_tasks = int(land_knobs.get("native_daily_thread_tasks", 0));
            double ms = use_thread
                ? run_ocean_land_pass_thread(land_knobs, thread_tasks)
                : run_ocean_land_pass(land_knobs);
            String variant = use_thread ? String("thread") : String("scalar");
            if (ms < 0.0 && use_thread) {
                ms = run_ocean_land_pass(land_knobs);
                variant = String("thread_fallback_scalar");
            }
            if (ms < 0.0) return false;
            _native_daily_slice_bundle["ocean_land_knobs"] = land_knobs;
            breakdown["ocean_land_ms"] = ms;
            breakdown["ocean_land_variant"] = variant;
            breakdown["ocean_land_thread_tasks"] = thread_tasks;
            breakdown["ocean_ms"] = double(breakdown.get("ocean_ms", 0.0)) + ms;
            return true;
        }
        if (std::strcmp(node.name, "climate_pass_b") == 0) {
            // [climate-mt 2026-07] 多核：pass_b 写 own-cell（LANOM/M），邻居只读
            //   round-start 快照（TTA/IW）+ 预拍 temp_snapshot → 逐位等价于 scalar
            //   （_simd land 路径已在 legacy 路径生产验证）。n_tasks=0=自适应。
            const double ms = run_climate_pass_b_thread(as_dict(_native_daily_slice_bundle["climate_pass_b_knobs"]), 0);
            if (ms < 0.0) return false;
            breakdown["pass_b_ms"] = ms;
            breakdown["climate_ms"] = double(breakdown.get("climate_ms", 0.0)) + ms;
            return true;
        }
        if (std::strcmp(node.name, "wind_air") == 0) {
            Dictionary wind_knobs = as_dict(_native_daily_slice_bundle["wind_air_knobs"]);
            const double ms = run_wind_air_mass_pass(wind_knobs);
            if (ms < 0.0) return false;
            _native_daily_slice_bundle["wind_air_knobs"] = wind_knobs;
            breakdown["wind_air_ms"] = ms;
            breakdown["wind_ms"] = double(breakdown.get("wind_ms", 0.0)) + ms;
            breakdown["climate_ms"] = double(breakdown.get("climate_ms", 0.0)) + ms;
            return true;
        }
        if (std::strcmp(node.name, "wind_surface") == 0) {
            Dictionary wind_knobs = as_dict(_native_daily_slice_bundle["wind_surface_knobs"]);
            const double ms = run_wind_surface_pass(wind_knobs);
            if (ms < 0.0) return false;
            _native_daily_slice_bundle["wind_surface_knobs"] = wind_knobs;
            breakdown["wind_surface_ms"] = ms;
            breakdown["wind_ms"] = double(breakdown.get("wind_ms", 0.0)) + ms;
            breakdown["climate_ms"] = double(breakdown.get("climate_ms", 0.0)) + ms;
            return true;
        }
        if (std::strcmp(node.name, "sea_ice") == 0) {
            const float phase = float(_native_daily_slice_tick_knobs.get("season_phase", 0.0));
            Dictionary sea_ice_knobs = as_dict(_native_daily_slice_bundle["sea_ice_knobs"]);
            const double ms = run_sea_ice_daily_pass(sea_ice_knobs, phase);
            if (ms < 0.0) return false;
            breakdown["sea_ice_ms"] = ms;
            breakdown["sea_ice_dt_days"] = double(sea_ice_knobs.get("dt_days", 1.0));
            breakdown["climate_ms"] = double(breakdown.get("climate_ms", 0.0)) + ms;
            return true;
        }
        if (std::strcmp(node.name, "transpiration") == 0) {
            const double ms = run_transpiration_pass(as_dict(_native_daily_slice_bundle["transpiration_knobs"]));
            if (ms < 0.0) return false;
            breakdown["transp_ms"] = ms;
            breakdown["climate_ms"] = double(breakdown.get("climate_ms", 0.0)) + ms;
            return true;
        }
        if (std::strcmp(node.name, "stage_b") == 0 ||
            std::strcmp(node.name, "stage_b_after_hydrology") == 0) {
            const char *key = std::strcmp(node.name, "stage_b_after_hydrology") == 0
                ? "stage_b_after_hydrology_knobs"
                : "stage_b_knobs";
            Dictionary stage_b_knobs = as_dict(_native_daily_slice_bundle[key]);
            // stage_b_knobs 为空（run_albedo/veg_dyn/feedback 全 false 的 stride tick）
            // 时跳过，不算失败 —— 与 run_stage_b_pass 内部 early return 语义一致。
            if (stage_b_knobs.is_empty()) {
                return true;
            }
            const double ms = run_stage_b_pass(stage_b_knobs);
            if (ms < 0.0) return false;
            breakdown["stage_b_ms"] = double(breakdown.get("stage_b_ms", 0.0)) + ms;
            breakdown["albedo_ms"] = stage_b_knobs.get("albedo_ms", breakdown.get("albedo_ms", 0.0));
            breakdown["veg_dyn_ms"] = stage_b_knobs.get("veg_dyn_ms", breakdown.get("veg_dyn_ms", 0.0));
            breakdown["feedback_ms"] = stage_b_knobs.get("feedback_ms", breakdown.get("feedback_ms", 0.0));
            record_stage_b_diag(stage_b_knobs);
            if (stage_b_knobs.has("succession_indices")) {
                breakdown["succession_indices"] = stage_b_knobs["succession_indices"];
                breakdown["succession_to_veg"] = stage_b_knobs["succession_to_veg"];
                breakdown["stat_succession_count"] = stage_b_knobs.get("stat_succession_count", 0);
            }
            return true;
        }
        if (std::strcmp(node.name, "albedo") == 0) {
            const double ms = run_albedo_pass(as_dict(_native_daily_slice_bundle["albedo_knobs"]));
            if (ms < 0.0) return false;
            breakdown["albedo_ms"] = ms;
            breakdown["stage_b_ms"] = double(breakdown.get("stage_b_ms", 0.0)) + ms;
            return true;
        }
        if (std::strcmp(node.name, "vegetation_dynamics") == 0) {
            const double ms = run_vegetation_dynamics_pass(as_dict(_native_daily_slice_bundle["vegetation_dynamics_knobs"]));
            if (ms < 0.0) return false;
            breakdown["veg_dyn_ms"] = ms;
            breakdown["stage_b_ms"] = double(breakdown.get("stage_b_ms", 0.0)) + ms;
            return true;
        }
        if (std::strcmp(node.name, "climate_feedback") == 0) {
            const double ms = run_climate_feedback_pass(as_dict(_native_daily_slice_bundle["climate_feedback_knobs"]));
            if (ms < 0.0) return false;
            breakdown["feedback_ms"] = ms;
            breakdown["stage_b_ms"] = double(breakdown.get("stage_b_ms", 0.0)) + ms;
            return true;
        }
        if (std::strcmp(node.name, "weather") == 0) {
            if (weather_split_enabled()) {
                breakdown["weather_split_enabled"] = true;
                breakdown["weather_split_skipped_monolithic"] = true;
                breakdown["weather_ms"] = double(breakdown.get("weather_ms", 0.0));
                breakdown["weather_tick_ms"] = double(breakdown.get("weather_tick_ms", breakdown.get("weather_ms", 0.0)));
                return true;
            }
            breakdown["weather_split_enabled"] = false;
            breakdown["weather_split_skipped_monolithic"] = false;
            Dictionary weather = run_weather_refresh_daily_pass(as_dict(_native_daily_slice_bundle["weather_knobs"]));
            if (int(weather.get("rc", -1)) != 0) {
                breakdown["__weather_fail_stage_dyn"] = weather.get("fail_stage", "unknown");
                return false;
            }
            breakdown["weather_ms"] = double(weather.get("total_ms", 0.0));
            Array keys = weather.keys();
            for (int i = 0; i < keys.size(); ++i) {
                Variant k = keys[i];
                breakdown[k] = weather[k];
            }
            if (weather.has("fronts")) {
                _native_fronts_snapshot = weather["fronts"];
            }
            return true;
        }
        if (std::strcmp(node.name, "weather_field") == 0) {
            if (!weather_split_enabled()) return true;
            Dictionary weather_knobs = as_dict(_native_daily_slice_bundle["weather_knobs"]);
            const double field_ms = run_weather_field_solve_pass(weather_knobs);
            if (field_ms < 0.0) {
                breakdown["__weather_fail_stage_dyn"] = String("field_solve");
                return false;
            }
            breakdown["advance_ms"] = field_ms;
            add_weather_timing("weather_field_ms", field_ms);
            return true;
        }
        if (std::strcmp(node.name, "weather_commit") == 0) {
            if (!weather_split_enabled()) return true;
            Dictionary weather_knobs = as_dict(_native_daily_slice_bundle["weather_knobs"]);
            if (weather_knobs.has("out_vapor") && weather_knobs.has("out_cloud") &&
                weather_knobs.has("out_precip") && weather_knobs.has("out_instability") &&
                weather_knobs.has("out_intensity") && weather_knobs.has("out_convergence") &&
                weather_knobs.has("out_type")) {
                Dictionary commit = run_weather_field_commit_pass(weather_knobs);
                const double commit_ms = double(commit.get("elapsed_ms", -1.0));
                if (commit_ms < 0.0) {
                    breakdown["__weather_fail_stage_dyn"] = String("field_commit");
                    return false;
                }
                breakdown["field_commit_total_ms"] = commit_ms;
                breakdown["field_commit_loop_ms"] = double(commit.get("commit_loop_ms", commit_ms));
                breakdown["field_commit_path"] = commit.get("path", String("gdext_commit"));
                breakdown["field_commit_publish_verified"] = true;
                breakdown["field_commit_publish_repaired"] = false;
                breakdown["field_commit_init_count"] = int(weather_knobs.get("n_cells", 0));
                breakdown["field_commit_publish_reason"] = String("ok_native_combined_commit");
                breakdown["weather_dirty_count"] = int(commit.get("weather_dirty_count", 0));
                breakdown["water_budget_error"] = double(commit.get("water_budget_error", 0.0));
                breakdown["active_weather_ratio"] = double(commit.get("active_weather_ratio", 0.0));
                breakdown["weather_convergence_dirty_count"] = int(commit.get("weather_convergence_dirty_count", 0));
                breakdown["weather_convergence_deltas"] = commit.get("weather_convergence_deltas", PackedFloat32Array());
                breakdown["convergence_published"] = bool(commit.get("convergence_published", false));
                breakdown["weather_lut"] = commit.get("weather_lut", PackedByteArray());
                breakdown["weather_lut_changed"] = bool(commit.get("weather_lut_changed", false));
                breakdown["weather_lut_dirty_count"] = int(commit.get("weather_lut_dirty_count", 0));
                breakdown["weather_lut_full_rebuild"] = bool(commit.get("weather_lut_full_rebuild", false));
                add_weather_timing("weather_commit_ms", commit_ms);
            } else {
                breakdown["field_commit_path"] = String("direct_solve_publish");
                breakdown["field_commit_publish_verified"] = true;
                breakdown["field_commit_publish_repaired"] = false;
                breakdown["field_commit_init_count"] = int(weather_knobs.get("n_cells", 0));
                breakdown["field_commit_publish_reason"] = String("ok_direct_solve_publish");
                add_weather_timing("weather_commit_ms", 0.0);
            }
            return true;
        }
        if (std::strcmp(node.name, "weather_distribute") == 0) {
            if (!weather_split_enabled()) return true;
            Dictionary weather_knobs = as_dict(_native_daily_slice_bundle["weather_knobs"]);
            const Dictionary r_dist = run_weather_distribute_pass(weather_knobs);
            const double dist_ms = double(r_dist.get("elapsed_ms", -1.0));
            if (dist_ms < 0.0) {
                breakdown["__weather_fail_stage_dyn"] = String("distribute");
                return false;
            }
            breakdown["distribute_ms"] = dist_ms;
            breakdown["cover_dirty"] = r_dist.get("cover_dirty", false);
            add_weather_timing("weather_distribute_ms", dist_ms);
            return true;
        }
        if (std::strcmp(node.name, "weather_summary") == 0) {
            if (!weather_split_enabled()) return true;
            Dictionary weather_knobs = as_dict(_native_daily_slice_bundle["weather_knobs"]);
            const Dictionary r_summary = run_weather_summary_fronts_pass(weather_knobs);
            const double summary_ms = double(r_summary.get("elapsed_ms", -1.0));
            if (summary_ms < 0.0) {
                breakdown["__weather_fail_stage_dyn"] = String("summary");
                return false;
            }
            const Array fronts_arr = r_summary.get("fronts", Array());
            breakdown["summary_ms"] = summary_ms;
            breakdown["fronts_count"] = fronts_arr.size();
            breakdown["fronts"] = fronts_arr;
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
            breakdown["weather_cold_front_count"] = cold_front_count;
            breakdown["weather_warm_front_count"] = warm_front_count;
            _native_fronts_snapshot = fronts_arr;
            _native_daily_slice_bundle["weather_fronts"] = fronts_arr;
            add_weather_timing("weather_summary_ms", summary_ms);
            return true;
        }
        if (std::strcmp(node.name, "weather_cyclone") == 0) {
            if (!weather_split_enabled()) return true;
            Dictionary weather_knobs = as_dict(_native_daily_slice_bundle["weather_knobs"]);
            Array fronts_arr;
            if (_native_daily_slice_bundle.has("weather_fronts") &&
                _native_daily_slice_bundle["weather_fronts"].get_type() == Variant::ARRAY) {
                fronts_arr = _native_daily_slice_bundle["weather_fronts"];
            }
            Dictionary cyclone_knobs = weather_knobs;
            const double cyclone_ms = cyclone_wake_step(cyclone_knobs, fronts_arr);
            breakdown["cyclone_ms"] = cyclone_ms;
            breakdown["cyclone_phase1_decay_ms"] = cyclone_knobs.get("cyclone_phase1_decay_ms", 0.0);
            breakdown["cyclone_phase2_inject_ms"] = cyclone_knobs.get("cyclone_phase2_inject_ms", 0.0);
            breakdown["cyclone_n_decayed"] = cyclone_knobs.get("cyclone_n_decayed", 0);
            breakdown["cyclone_n_evicted"] = cyclone_knobs.get("cyclone_n_evicted", 0);
            breakdown["cyclone_n_replaced"] = cyclone_knobs.get("cyclone_n_replaced", 0);
            breakdown["cyclone_n_injected"] = cyclone_knobs.get("cyclone_n_injected", 0);
            breakdown["cyclone_pool_size"] = int(_cyclone_perturbations.size());
            add_weather_timing("weather_cyclone_ms", cyclone_ms);
            return true;
        }
        if (std::strcmp(node.name, "weather_stage_b") == 0) {
            if (!weather_split_enabled()) return true;
            Dictionary weather_knobs = as_dict(_native_daily_slice_bundle["weather_knobs"]);
            if (!bool(weather_knobs.get("native_daily_weather_stage_b_embedded", false))) {
                breakdown["weather_stage_b_ms"] = 0.0;
                return true;
            }
            Dictionary stage_b_knobs = weather_knobs;
            const double stage_b_ms = run_stage_b_pass(stage_b_knobs);
            if (stage_b_ms < 0.0) {
                breakdown["__weather_fail_stage_dyn"] = String("stage_b");
                return false;
            }
            breakdown["weather_stage_b_ms"] = stage_b_ms;
            breakdown["stage_b_ms"] = double(breakdown.get("stage_b_ms", 0.0)) + stage_b_ms;
            breakdown["albedo_ms"] = stage_b_knobs.get("albedo_ms", breakdown.get("albedo_ms", 0.0));
            breakdown["veg_dyn_ms"] = stage_b_knobs.get("veg_dyn_ms", breakdown.get("veg_dyn_ms", 0.0));
            breakdown["feedback_ms"] = stage_b_knobs.get("feedback_ms", breakdown.get("feedback_ms", 0.0));
            record_stage_b_diag(stage_b_knobs);
            if (stage_b_knobs.has("succession_indices")) {
                breakdown["succession_indices"] = stage_b_knobs["succession_indices"];
                breakdown["succession_to_veg"] = stage_b_knobs["succession_to_veg"];
                breakdown["stat_succession_count"] = stage_b_knobs.get("stat_succession_count", 0);
            }
            add_weather_timing("weather_stage_b_ms", stage_b_ms);
            return true;
        }
        if (std::strcmp(node.name, "runtime_hydrology") == 0) {
            Dictionary hydro = run_runtime_hydrology_pass(as_dict(_native_daily_slice_bundle["runtime_hydrology_knobs"]));
            const String fallback_reason = String(hydro.get("fallback_reason", ""));
            if (!fallback_reason.is_empty() || !bool(hydro.get("published_to_slot", false))) {
                breakdown["__hydrology_fail_reason"] =
                    fallback_reason.is_empty() ? String("hydrology did not publish slots") : fallback_reason;
                return false;
            }
            const double native_ms = double(hydro.get("native_ms", 0.0));
            breakdown["hydrology_ms"] = native_ms;
            breakdown["runtime_hydrology_ms"] = native_ms;
            breakdown["hydrology_native_ms"] = native_ms;
            breakdown["hydrology_compute_ms"] = double(hydro.get("compute_ms", 0.0));
            breakdown["hydrology_flush_ms"] = double(hydro.get("flush_ms", 0.0));
            breakdown["hydrology_dt_days"] = double(hydro.get("dt_days", 1.0));
            breakdown["hydrology_water_budget_error"] = double(hydro.get("water_budget_error", 0.0));
            breakdown["hydrology_river_discharge_p95"] = double(hydro.get("river_discharge_p95", 0.0));
            breakdown["hydrology_river_discharge_max"] = double(hydro.get("river_discharge_max", 0.0));
            breakdown["hydrology_riparian_neighbor_touches"] = int(hydro.get("riparian_neighbor_touches", 0));
            breakdown["hydrology_flood_count"] = int(hydro.get("flood_count", hydro.get("flood_candidate_count", 0)));
            breakdown["hydrology_published_to_slot"] = true;
            return true;
        }
        return false;
    };
    const uint32_t deferred_bits_active = native_daily_deferred_node_bits(_native_daily_slice_bundle);
    int node_index = native_daily_next_present_node(_native_daily_slice_bundle,
                                                    _native_daily_slice_node_index,
                                                    deferred_bits_active);
    if (node_index < 0) {
        if (!_native_daily_slice_any_pass_ran) {
            return finish_with_failure(String("native_daily_bundle"), String("no pass knobs in native_daily_bundle"));
        }
    } else {
        // Batch consecutive present nodes in this single call, stopping right before any
        // node GDScript must JIT-patch (a yield node) or when the round is complete.
        // Bit-equal with one-node-per-call: non-yield nodes receive an empty patch in
        // either scheme, so the bundle state they read is identical.
        const int batch_start_index = node_index;
        while (node_index >= 0) {
            const NativeDailySliceNode &node = NATIVE_DAILY_SLICE_GRAPH[node_index];
            // Reset per-slice range diagnostics before each node. The breakdown dict
            // accumulates across a round, so without this non-range nodes can inherit
            // the previous range node's cursor and make CSV attribution misleading.
            breakdown["node_range_enabled"] = false;
            breakdown["node_range_active"] = false;
            breakdown["node_range_done"] = true;
            breakdown["node_range_budget"] = _native_daily_slice_cell_budget;
            breakdown["node_range_node"] = String();
            breakdown["node_cell_cursor_start"] = -1;
            breakdown["node_cell_cursor_end"] = -1;
            breakdown["node_cell_count"] = 0;
            breakdown["node_cell_processed"] = 0;
            if (!_native_daily_slice_bundle.has(node.bundle_key)) {
                const String node_name = node_name_string(node.name);
                const String node_key = node_key_string(node.bundle_key);
                breakdown["stage_name"] = node_name;
                breakdown["substage"] = node_key;
                breakdown["cursor_start"] = node_index;
                breakdown["cursor_end"] = node_index;
                breakdown["deferred_wait_node"] = node_name;
                breakdown["deferred_wait_key"] = node_key;
                _native_daily_slice_node_index = node_index;
                _native_daily_slice_breakdown = breakdown;
                break;
            }
            bool range_active = false;
            bool range_done = true;
            int range_start = 0;
            int range_end = 0;
            int range_count = 0;
            if (_native_daily_slice_cell_budget > 0 &&
                node_index < 32 &&
                ((_native_daily_slice_range_node_bits >> node_index) & 1u) &&
                native_daily_node_has_builtin_range(node.name)) {
                Dictionary range_knobs = as_dict(_native_daily_slice_bundle[node.bundle_key]);
                range_count = int(range_knobs.get("n_cells", _native_world_cell_count));
                if (range_count > 0) {
                    if (_native_daily_slice_range_node_index != node_index) {
                        _native_daily_slice_range_node_index = node_index;
                        _native_daily_slice_cell_cursor = 0;
                    }
                    range_start = std::max(0, std::min(_native_daily_slice_cell_cursor, range_count));
                    range_end = std::min(range_count, range_start + _native_daily_slice_cell_budget);
                    if (range_end > range_start) {
                        range_done = range_end >= range_count;
                        range_active = true;
                        range_knobs["start_idx"] = range_start;
                        range_knobs["end_idx"] = range_end;
                        range_knobs["defer_flush"] = !range_done;
                        range_knobs["flush_on_end"] = range_done;
                        _native_daily_slice_bundle[node.bundle_key] = range_knobs;
                    }
                }
            }
            const bool ok = exec_slice_node(node);
            if (!ok) {
                _native_daily_slice_breakdown = breakdown;
                String reason;
                const String fail_stage = node_name_string(node.fail_stage);
                if (fail_stage == String("weather") ||
                    fail_stage == String("weather_field") ||
                    fail_stage == String("weather_commit") ||
                    fail_stage == String("weather_distribute") ||
                    fail_stage == String("weather_summary") ||
                    fail_stage == String("weather_cyclone") ||
                    fail_stage == String("weather_stage_b")) {
                    reason = String(breakdown.get("__weather_fail_stage_dyn", "unknown"));
                    breakdown.erase("__weather_fail_stage_dyn");
                } else if (fail_stage == String("runtime_hydrology")) {
                    reason = String(breakdown.get("__hydrology_fail_reason", "pass returned fallback"));
                    breakdown.erase("__hydrology_fail_reason");
                } else {
                    reason = String("pass returned fallback");
                }
                // [DEBUG] 临时诊断：确认哪个节点失败
                // godot::UtilityFunctions::print("[native_daily/FAIL] node=", node_name_string(node.name),
                //     " fail_stage=", fail_stage, " reason=", reason);
                _native_daily_slice_node_index = node_index;
                return finish_with_failure(fail_stage, reason);
            }
            _native_daily_slice_any_pass_ran = true;
            if (range_active) {
                const String node_name = node_name_string(node.name);
                const String node_key = node_key_string(node.bundle_key);
                breakdown["stage_name"] = node_name;
                breakdown["substage"] = node_key;
                breakdown["cursor_start"] = node_index;
                breakdown["cursor_end"] = node_index;
                breakdown["node_range_enabled"] = true;
                breakdown["node_range_active"] = !range_done;
                breakdown["node_range_done"] = range_done;
                breakdown["node_range_budget"] = _native_daily_slice_cell_budget;
                breakdown["node_range_node"] = node_name;
                breakdown["node_cell_cursor_start"] = range_start;
                breakdown["node_cell_cursor_end"] = range_end;
                breakdown["node_cell_count"] = range_count;
                breakdown["node_cell_processed"] = range_end - range_start;
                Dictionary node_report;
                node_report["name"] = node_name;
                node_report["bundle_key"] = node_key;
                node_report["read_mask"] = int64_t(node.read_mask);
                node_report["write_mask"] = int64_t(node.write_mask);
                breakdown["node_report"] = node_report;
                if (!range_done) {
                    _native_daily_slice_cell_cursor = range_end;
                    _native_daily_slice_node_index = node_index;
                    _native_daily_slice_breakdown = breakdown;
                    break;
                }
                _native_daily_slice_cell_cursor = 0;
                _native_daily_slice_range_node_index = -1;
            }
            _native_daily_slice_node_index = node_index + 1;
            const String node_name = node_name_string(node.name);
            const String node_key = node_key_string(node.bundle_key);
            breakdown["last_completed_node"] = node_name;
            breakdown["stage_name"] = node_name;
            breakdown["substage"] = node_key;
            breakdown["cursor_start"] = batch_start_index;
            breakdown["cursor_end"] = node_index + 1;
            breakdown["processed_nodes"] = int(breakdown.get("processed_nodes", 0)) + 1;
            Dictionary node_report;
            node_report["name"] = node_name;
            node_report["bundle_key"] = node_key;
            node_report["read_mask"] = int64_t(node.read_mask);
            node_report["write_mask"] = int64_t(node.write_mask);
            breakdown["node_report"] = node_report;
            _native_daily_slice_breakdown = breakdown;

            const int next = native_daily_next_present_node(_native_daily_slice_bundle,
                                                            _native_daily_slice_node_index,
                                                            deferred_bits_active);
            if (next < 0) {
                break;  // round complete
            }
            if (next < 32 && ((_native_daily_slice_yield_bits >> next) & 1u)) {
                break;  // GDScript must inject a JIT patch before this node
            }
            node_index = next;  // safe to keep running within this call
        }
    }

    const int next_index = native_daily_next_present_node(_native_daily_slice_bundle,
                                                          _native_daily_slice_node_index,
                                                          deferred_bits_active);
    const bool done = next_index < 0;
    if (done && bool(_native_daily_slice_bundle.get("flush_slots_to_map", true))) {
        const auto t_flush0 = std::chrono::high_resolution_clock::now();
        flush_slots_to_map();
        const auto t_flush1 = std::chrono::high_resolution_clock::now();
        breakdown["render_prepare_ms"] =
            std::chrono::duration<double, std::milli>(t_flush1 - t_flush0).count();
        _native_daily_slice_breakdown = breakdown;
    }

    const auto t1 = std::chrono::high_resolution_clock::now();
    const double slice_ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
    _native_daily_slice_elapsed_accum_ms += slice_ms;

    const double compute_ms = compute_ms_from_breakdown(breakdown);
    const Array published_slots = done
        ? native_daily_collect_published_slots(_native_daily_slice_bundle)
        : Array();
    const Array visual_dirty_intents = done
        ? native_daily_collect_visual_dirty_intents(_native_daily_slice_bundle, breakdown, _native_dirty_report)
        : Array();
    double progress_ratio = done
        ? 1.0
        : (NATIVE_DAILY_SLICE_GRAPH_SIZE > 0
               ? double(_native_daily_slice_node_index) / double(NATIVE_DAILY_SLICE_GRAPH_SIZE)
               : 1.0);
    if (!done && bool(breakdown.get("node_range_active", false)) && NATIVE_DAILY_SLICE_GRAPH_SIZE > 0) {
        const int cell_end = int(breakdown.get("node_cell_cursor_end", 0));
        const int cell_count = std::max(1, int(breakdown.get("node_cell_count", 1)));
        const double node_frac = std::max(0.0, std::min(1.0, double(cell_end) / double(cell_count)));
        progress_ratio =
            (double(_native_daily_slice_node_index) + node_frac) / double(NATIVE_DAILY_SLICE_GRAPH_SIZE);
    }

    breakdown["total_ms"] = slice_ms;
    breakdown["native_ms"] = slice_ms;
    breakdown["round_native_ms"] = _native_daily_slice_elapsed_accum_ms;
    breakdown["compute_ms"] = compute_ms;
    breakdown["refresh_ms"] = double(breakdown.get("native_context_ms", 0.0));
    breakdown["flush_ms"] = double(breakdown.get("render_prepare_ms", 0.0));
    breakdown["published_slots"] = published_slots;
    breakdown["dirty_cells"] = int(_native_dirty_report.get("dirty_cell_count", 0));
    breakdown["visual_dirty_intents"] = visual_dirty_intents;
    breakdown["native_state_snapshot"] = _native_daily_slice_state_snapshot;
    Dictionary authority_report = _native_daily_slice_state_snapshot.get("authority_report", Dictionary());
    if (done && bool(breakdown.get("hydrology_published_to_slot", false)) &&
        authority_report.has("runtime_hydrology")) {
        Dictionary hydrology_authority = authority_report["runtime_hydrology"];
        hydrology_authority["phase"] = String("native_active_verified");
        hydrology_authority["verified_publish"] = true;
        hydrology_authority["simulation_authority"] = true;
        hydrology_authority["blockers"] = Array();
        authority_report["runtime_hydrology"] = hydrology_authority;
    }
    if (done && _native_daily_slice_bundle.has("sea_ice_knobs") &&
        authority_report.has("sea_ice")) {
        Dictionary sea_ice_authority = authority_report["sea_ice"];
        sea_ice_authority["phase"] = String("native_active_verified");
        sea_ice_authority["verified_publish"] = true;
        sea_ice_authority["simulation_authority"] = true;
        sea_ice_authority["blockers"] = Array();
        authority_report["sea_ice"] = sea_ice_authority;
    }
    if (done && _native_daily_slice_bundle.has("weather_knobs") &&
        authority_report.has("weather_transaction")) {
        Dictionary weather_authority = authority_report["weather_transaction"];
        const bool weather_publish_verified = bool(breakdown.get("field_commit_publish_verified", false));
        const bool weather_fronts_changed =
            bool(breakdown.get("weather_lut_changed", false)) ||
            int(breakdown.get("fronts_count", 0)) > 0;
        weather_authority["visible_publish_verified"] = weather_publish_verified;
        weather_authority["fronts_changed"] = weather_fronts_changed;
        if (weather_publish_verified &&
            String(weather_authority.get("owner", "")) == String("native_active")) {
            weather_authority["phase"] = String("native_active_verified");
            weather_authority["simulation_authority"] = true;
            weather_authority["blockers"] = Array();
        }
        authority_report["weather_transaction"] = weather_authority;
    }
    breakdown["authority_report"] = authority_report;
    breakdown["authority_blockers"] = _native_daily_slice_state_snapshot.get("authority_blockers", Array());
    breakdown["retained_boundaries"] = _native_daily_slice_state_snapshot.get("retained_boundaries", Array());
    breakdown["retained_godot_boundaries"] = _native_daily_slice_state_snapshot.get("retained_godot_boundaries", Array());
    breakdown["retained_boundary_policy"] =
        _native_daily_slice_state_snapshot.get("retained_boundary_policy", String());
    breakdown["graph_coverage_complete"] = Array(breakdown["authority_blockers"]).is_empty();
    breakdown["graph_coverage_state"] =
        _native_daily_slice_state_snapshot.get("graph_coverage_state", String("partial"));
    breakdown["boundary_contract"] =
        _native_daily_slice_bundle.get("native_daily_boundary_contract", Dictionary());
    Dictionary boundary_contract = breakdown["boundary_contract"];
    breakdown["bundle_key_count"] =
        int(boundary_contract.get("bundle_key_count", _native_daily_slice_bundle.size()));
    breakdown["tick_delta_key_count"] =
        Array(boundary_contract.get("tick_delta_keys", Array())).size();
    // perf(Tier1): runtime_config_report 此前在 breakdown 与 out 各做一次独立深拷贝（同源、
    // 仅诊断只读）。改为本片单次深拷贝后共享同一 Variant，省掉每片第 2 次递归深拷贝。
    Dictionary runtime_config_report = _native_runtime_config.duplicate(true);
    breakdown["runtime_config_report"] = runtime_config_report;
    const bool active_default_ready =
        done &&
        String(breakdown["graph_coverage_state"]) == String("complete") &&
        Array(breakdown["authority_blockers"]).is_empty() &&
        bool(_native_daily_slice_bundle.get("native_daily_legacy_daily_production_retired", false));
    breakdown["native_daily_active_default_ready"] = active_default_ready;
    breakdown["active_default_blockers"] = breakdown["authority_blockers"];
    breakdown["fallback_mode"] =
        active_default_ready ? String("explicit_failure_only") : String("legacy_sus_retained_until_active_default_validation");
    PackedFloat32Array temperature_transport_anomaly_out;
    if (_native_daily_slice_bundle.has("ocean_land_knobs")) {
        Dictionary land_knobs = as_dict(_native_daily_slice_bundle["ocean_land_knobs"]);
        if (land_knobs.has("anomaly_inout")) {
            temperature_transport_anomaly_out = land_knobs["anomaly_inout"];
        }
    }
    breakdown["done"] = done;
    breakdown["progress_ratio"] = progress_ratio;
    if (done) {
        breakdown["stage_name"] = String("native_daily_complete");
        breakdown["substage"] = String("round_complete");
    }
    _native_daily_slice_breakdown = breakdown;

    out["rc"] = 0;
    out["path"] = String("gdext_native_daily_slice");
    out["fail_stage"] = String();
    out["fallback_reason"] = String();
    out["done"] = done;
    out["progress_ratio"] = progress_ratio;
    out["stage_name"] = breakdown.get("stage_name", String("native_daily_slice"));
    out["substage"] = breakdown.get("substage", String());
    out["cursor_start"] = breakdown.get("cursor_start", _native_daily_slice_node_index);
    out["cursor_end"] = breakdown.get("cursor_end", _native_daily_slice_node_index);
    out["node_index"] = _native_daily_slice_node_index;
    out["next_node_index"] = done ? -1 : next_index;
    out["node_range_enabled"] = breakdown.get("node_range_enabled", false);
    out["node_range_active"] = breakdown.get("node_range_active", false);
    out["node_range_done"] = breakdown.get("node_range_done", true);
    out["node_range_budget"] = breakdown.get("node_range_budget", _native_daily_slice_cell_budget);
    out["node_range_node"] = breakdown.get("node_range_node", String());
    out["node_cell_cursor_start"] = breakdown.get("node_cell_cursor_start", -1);
    out["node_cell_cursor_end"] = breakdown.get("node_cell_cursor_end", -1);
    out["node_cell_count"] = breakdown.get("node_cell_count", 0);
    out["node_cell_processed"] = breakdown.get("node_cell_processed", 0);
    out["round_id"] = _native_daily_slice_round_id;
    out["total_ms"] = slice_ms;
    out["native_ms"] = slice_ms;
    out["round_native_ms"] = _native_daily_slice_elapsed_accum_ms;
    out["compute_ms"] = compute_ms;
    out["refresh_ms"] = double(breakdown.get("native_context_ms", 0.0));
    out["flush_ms"] = double(breakdown.get("render_prepare_ms", 0.0));
    out["published_slots"] = published_slots;
    out["dirty_cells"] = int(_native_dirty_report.get("dirty_cell_count", 0));
    out["visual_dirty_intents"] = visual_dirty_intents;
    out["retained_gdscript_authority"] = _native_daily_slice_retained_authority;
    out["native_state_snapshot"] = _native_daily_slice_state_snapshot;
    out["authority_report"] = authority_report;
    out["authority_blockers"] = _native_daily_slice_state_snapshot.get("authority_blockers", Array());
    out["retained_boundaries"] = _native_daily_slice_state_snapshot.get("retained_boundaries", Array());
    out["retained_godot_boundaries"] = _native_daily_slice_state_snapshot.get("retained_godot_boundaries", Array());
    out["retained_boundary_policy"] =
        _native_daily_slice_state_snapshot.get("retained_boundary_policy", String());
    out["graph_coverage_complete"] = Array(out["authority_blockers"]).is_empty();
    out["graph_coverage_state"] =
        _native_daily_slice_state_snapshot.get("graph_coverage_state", String("partial"));
    out["boundary_contract"] = _native_daily_slice_bundle.get("native_daily_boundary_contract", Dictionary());
    out["bundle_key_count"] = breakdown["bundle_key_count"];
    out["tick_delta_key_count"] = breakdown["tick_delta_key_count"];
    out["runtime_config_report"] = runtime_config_report;  // perf(Tier1): 共享上面的单次深拷贝
    out["native_daily_active_default_ready"] = active_default_ready;
    out["active_default_blockers"] = out["authority_blockers"];
    out["fallback_mode"] = breakdown["fallback_mode"];
    if (temperature_transport_anomaly_out.size() > 0) {
        out["temperature_transport_anomaly_out"] = temperature_transport_anomaly_out;
    }
    out["breakdown"] = breakdown;
    out["dirty_flags"] = _native_dirty_report.duplicate();
    out["fronts_changed"] = done &&
        (bool(breakdown.get("weather_lut_changed", false)) ||
         int(breakdown.get("fronts_count", 0)) > 0);
    out["fronts"] = _native_fronts_snapshot;
    out["tick_count"] = _native_daily_tick_count;
    // perf(Tier1): _native_daily_report 仅由 get_native_daily_report() 消费，而后者读时还会再做
    // duplicate(true)；生产 native_daily_last_result() 走 GDScript 成员、不读此项，shadow 测试也走
    // run_native_sim_tick 入口而非本切片路径。故此处改浅拷贝：免去每片对 breakdown/native_state_
    // snapshot/authority_report/runtime_config/fronts 整棵树的递归深拷贝；顶层 dict 与返回的 out
    // 隔离（不被上层 GDScript 顶层增键污染），嵌套只读共享、读路径再深拷贝保证隔离。
    _native_daily_report = out.duplicate(false);

    if (done) {
        _native_daily_slice_active = false;
        _native_daily_slice_cell_cursor = 0;
        _native_daily_slice_range_node_index = -1;
    }

    return out;
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

    if (bool(tick_knobs.get("probe", false))) {
        bool has_bundle = false;
        bool has_pass = false;
        Array pass_keys;
        Array required_keys;
        Array missing_pass_keys;
        Dictionary bundle;
        Variant required_v = tick_knobs.get("required_pass_keys", Array());
        if (required_v.get_type() == Variant::ARRAY) {
            required_keys = required_v;
        }
        if (tick_knobs.has("native_daily_bundle") &&
            Variant(tick_knobs["native_daily_bundle"]).get_type() == Variant::DICTIONARY) {
            bundle = tick_knobs["native_daily_bundle"];
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
            record_pass("wind_air_knobs");
            record_pass("wind_surface_knobs");
            record_pass("sea_ice_knobs");
            record_pass("transpiration_knobs");
            record_pass("albedo_knobs");
            record_pass("vegetation_dynamics_knobs");
            record_pass("climate_feedback_knobs");
            record_pass("stage_b_knobs");
            record_pass("weather_knobs");
            record_pass("runtime_hydrology_knobs");
            record_pass("stage_b_after_hydrology_knobs");
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
        out["path"] = String("gdext_native_daily_probe");
        out["fail_stage"] = authoritative_ready
            ? String()
            : (!has_bundle ? String("native_daily_bundle_missing")
                           : (!has_pass ? String("native_daily_bundle_no_passes")
                                        : String("native_daily_bundle_missing_required_passes")));
        out["fallback_reason"] = authoritative_ready ? Variant() : Variant(out["fail_stage"]);
        out["configured"] = true;
        out["cell_count"] = _native_world_cell_count;
        out["pass_keys"] = pass_keys;
        out["required_pass_keys"] = required_keys;
        out["missing_pass_keys"] = missing_pass_keys;
        out["authoritative_ready"] = authoritative_ready;
        out["total_ms"] = 0.0;
        out["native_ms"] = 0.0;
        out["compute_ms"] = 0.0;
        out["refresh_ms"] = 0.0;
        out["flush_ms"] = 0.0;
        out["published_slots"] = Array();
        out["visual_dirty_intents"] = Array();
        out["dirty_cells"] = 0;
        Dictionary state;
        state["tick_owner"] = String("DCWorldExt.native_daily_graph");
        String climate_round_state_owner = String("gdscript_retained");
        if (bundle.has("climate_round_state_snapshot")) {
            Dictionary climate_round_state = bundle["climate_round_state_snapshot"];
            state["climate_round_state"] = climate_round_state;
            if (climate_round_state.has("native_probe_state")) {
                Dictionary native_probe_state = climate_round_state["native_probe_state"];
                const bool climate_round_ready = bool(native_probe_state.get("climate_round_authority_ready", false));
                if (climate_round_ready &&
                    (bool(native_probe_state.get("simulation_authority", false)) ||
                     bool(bundle.get("climate_round_active_owner_requested", false)))) {
                    climate_round_state_owner = String("native_active");
                } else if (climate_round_ready) {
                    climate_round_state_owner = String("native_ready");
                }
            }
        }
        state["climate_round_state_owner"] = climate_round_state_owner;
        Dictionary weather_readiness = bundle.has("weather_native_daily_readiness")
            ? Dictionary(bundle["weather_native_daily_readiness"])
            : Dictionary();
        const bool weather_native_ready = bool(weather_readiness.get("ready", false));
        const bool weather_active_requested = bool(bundle.get("weather_transaction_active_owner_requested", false));
        state["weather_transaction_state_owner"] =
            (weather_native_ready && weather_active_requested)
                ? String("native_active")
                : (weather_native_ready ? String("native_ready") : String("gdscript_retained"));
        Dictionary ocean_physical_state;
        if (bundle.has("ocean_physical_state_snapshot")) {
            ocean_physical_state = Dictionary(bundle["ocean_physical_state_snapshot"]);
            state["ocean_physical_state"] = ocean_physical_state;
        }
        state["ocean_physical_state_owner"] =
            ocean_physical_state.has("owner")
                ? String(ocean_physical_state.get("owner", "gdscript_retained"))
                : String("gdscript_retained");
        Dictionary season_refresh_state;
        if (bundle.has("season_refresh_state_snapshot")) {
            season_refresh_state = Dictionary(bundle["season_refresh_state_snapshot"]);
            state["season_refresh_state"] = season_refresh_state;
        }
        state["season_refresh_state_owner"] =
            season_refresh_state.has("owner")
                ? String(season_refresh_state.get("owner", "gdscript_retained"))
                : String("gdscript_retained");
        state["visual_upload_state_owner"] = String("godot_retained");
        state["fallback_owner"] =
            bool(bundle.get("legacy_sus_fallback_enabled", true))
                ? String("gdscript_legacy_sus")
                : String("explicit_failure_only");
        Array authority_blockers;
        authority_blockers.append(String("weather_transaction_state_gdscript"));
        authority_blockers.append(String("ocean_physical_state_gdscript"));
        authority_blockers.append(String("season_refresh_state_gdscript"));
        if (!bundle.has("runtime_hydrology_knobs")) {
            authority_blockers.append(String("runtime_hydrology"));
        }
        if (!bundle.has("sea_ice_knobs")) {
            authority_blockers.append(String("sea_ice"));
        }
        if (bool(bundle.get("legacy_sus_fallback_enabled", true))) {
            authority_blockers.append(String("legacy_sus_fallback_enabled"));
        }
        Array retained_boundaries = native_daily_collect_retained_boundaries(bundle);
        Dictionary authority_report;
        Dictionary weather_authority;
        weather_authority["owner"] = state["weather_transaction_state_owner"];
        weather_authority["phase"] =
            (weather_native_ready && weather_active_requested)
                ? String("native_active_visible_publish")
                : (weather_native_ready ? String("native_ready_visible_publish") : String("probe_bundle_only"));
        weather_authority["readiness"] = weather_readiness;
        weather_authority["visible_publish_ready"] = weather_native_ready;
        weather_authority["active_owner_requested"] = weather_active_requested;
        weather_authority["simulation_authority"] = weather_native_ready && weather_active_requested;
        weather_authority["front_snapshot_ready"] = bool(weather_readiness.get("has_result_apply", false));
        weather_authority["weather_lut_intent_ready"] = bool(weather_readiness.get("has_weather_lut_publish", false));
        weather_authority["publish_slots_expected"] =
            weather_native_ready
                ? Array::make(String("cell_weather_type"),
                              String("cell_weather_intensity"),
                              String("cell_weather_cloud"),
                              String("cell_weather_precip"),
                              String("cell_weather_field_init"),
                              String("cell_weather_transition_alpha"))
                : Array();
        weather_authority["retained_boundaries"] =
            Array::make(String("front_objects_gdscript"),
                        String("weather_lut_upload_godot_boundary"));
        weather_authority["blockers"] =
            weather_native_ready
                ? Array::make(String("probe_does_not_execute_pass"))
                : Array::make(String("weather_publish_not_executed_in_probe"),
                              String(weather_readiness.get("reason", "not_ready")));
        authority_report["weather_transaction"] = weather_authority;
        Dictionary hydrology_authority;
        hydrology_authority["owner"] =
            bundle.has("runtime_hydrology_knobs") ? String("native_probe") : String("gdscript_retained");
        hydrology_authority["phase"] =
            bundle.has("runtime_hydrology_knobs") ? String("probe_bundle_node_present") : String("legacy_weather_chain");
        hydrology_authority["simulation_authority"] = false;
        hydrology_authority["published_slots_expected"] =
            bundle.has("runtime_hydrology_knobs")
                ? Array::make(String("cell_soil_moisture"),
                              String("cell_water_balance_30d"),
                              String("cell_river_discharge"),
                              String("cell_river_discharge_30d"),
                              String("cell_river_storage"),
                              String("cell_groundwater_storage"),
                              String("cell_surface_runoff"))
                : Array();
        hydrology_authority["blockers"] =
            bundle.has("runtime_hydrology_knobs")
                ? Array::make(String("probe_does_not_execute_pass"))
                : Array::make(String("runtime_hydrology_knobs_missing"));
        authority_report["runtime_hydrology"] = hydrology_authority;
        Dictionary sea_ice_authority;
        sea_ice_authority["owner"] =
            bundle.has("sea_ice_knobs") ? String("native_probe") : String("gdscript_retained");
        sea_ice_authority["phase"] =
            bundle.has("sea_ice_knobs") ? String("probe_bundle_node_present") : String("legacy_climate_or_sea_ice_job");
        sea_ice_authority["simulation_authority"] = false;
        sea_ice_authority["published_slots_expected"] =
            bundle.has("sea_ice_knobs")
                ? Array::make(String("cell_sea_ice_frac"),
                              String("cell_temp"),
                              String("cell_moisture"))
                : Array();
        sea_ice_authority["blockers"] =
            bundle.has("sea_ice_knobs")
                ? Array::make(String("probe_does_not_execute_pass"))
                : Array::make(String("sea_ice_knobs_missing"));
        sea_ice_authority["retained_boundaries"] =
            bundle.has("sea_ice_knobs")
                ? Array::make(String("terrain_flip_visibility_gdscript"),
                              String("sea_ice_visual_upload_godot"))
                : Array();
        authority_report["sea_ice"] = sea_ice_authority;
        Dictionary ocean_authority;
        ocean_authority["owner"] = state["ocean_physical_state_owner"];
        ocean_authority["phase"] =
            String(state["ocean_physical_state_owner"]) == String("native_ready_probe")
                ? String("native_ready_probe")
                : String("gdscript_stage_machine");
        ocean_authority["state"] = ocean_physical_state;
        ocean_authority["native_owned_output_slots"] =
            ocean_physical_state.get("native_owned_output_slots", Array());
        ocean_authority["blockers"] =
            Array::make(String("probe_does_not_execute_pass"),
                        String("ocean_physical_owner_not_active"));
        ocean_authority["retained_boundaries"] =
            ocean_physical_state.get("remaining_gdscript_authority",
                Array::make(String("visual_raster_boundary_godot"),
                            String("texture_commit_boundary_godot")));
        authority_report["ocean_physical"] = ocean_authority;
        Dictionary season_authority;
        season_authority["owner"] = state["season_refresh_state_owner"];
        season_authority["phase"] =
            String(state["season_refresh_state_owner"]) == String("native_ready_probe")
                ? String("native_ready_cadence_probe")
                : String("gdscript_cadence");
        season_authority["state"] = season_refresh_state;
        season_authority["simulation_slot_dirty_intents"] =
            season_refresh_state.get("simulation_slot_dirty_intents", Array());
        season_authority["visual_dirty_intents"] =
            season_refresh_state.get("visual_dirty_intents", Array());
        season_authority["blockers"] =
            Array::make(String("probe_does_not_execute_pass"),
                        String("season_refresh_owner_not_active"));
        season_authority["retained_boundaries"] =
            season_refresh_state.get("visual_dirty_intents",
                Array::make(String("atlas_queue_godot"),
                            String("detail_scatter_godot")));
        authority_report["season_refresh"] = season_authority;
        Dictionary visual_authority;
        visual_authority["owner"] = state["visual_upload_state_owner"];
        visual_authority["phase"] = String("godot_upload_boundary");
        visual_authority["blockers"] = Array();
        visual_authority["retained_boundaries"] = Array::make(String("image_texture_upload_godot"));
        authority_report["visual_upload"] = visual_authority;
        Dictionary fallback_authority;
        const bool legacy_fallback_enabled = bool(bundle.get("legacy_sus_fallback_enabled", true));
        fallback_authority["owner"] = state["fallback_owner"];
        fallback_authority["phase"] =
            legacy_fallback_enabled ? String("probe_fallback_retained") : String("fallback_test_only");
        fallback_authority["blockers"] =
            legacy_fallback_enabled ? Array::make(String("legacy_sus_fallback_enabled")) : Array();
        authority_report["fallback"] = fallback_authority;
        state["authority_report"] = authority_report;
        state["authority_blockers"] = authority_blockers;
        state["retained_boundaries"] = retained_boundaries;
        state["retained_godot_boundaries"] = retained_boundaries;
        state["retained_boundary_policy"] = String("explicit_godot_presentation_boundary");
        state["graph_coverage_state"] = String("probe_partial");
        out["native_state_snapshot"] = state;
        out["authority_blockers"] = authority_blockers;
        out["retained_boundaries"] = retained_boundaries;
        out["retained_godot_boundaries"] = retained_boundaries;
        out["retained_boundary_policy"] = state["retained_boundary_policy"];
        out["graph_coverage_state"] = String("probe_partial");
        out["boundary_contract"] = bundle.get("native_daily_boundary_contract", Dictionary());
        Dictionary boundary_contract = out["boundary_contract"];
        out["bundle_key_count"] = int(boundary_contract.get("bundle_key_count", bundle.size()));
        out["tick_delta_key_count"] = Array(boundary_contract.get("tick_delta_keys", Array())).size();
        out["runtime_config_report"] = _native_runtime_config.duplicate(true);
        out["native_daily_active_default_ready"] = false;
        out["active_default_blockers"] = out["authority_blockers"];
        out["fallback_mode"] = String("legacy_sus_retained_until_active_default_validation");
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
    breakdown["hydrology_ms"] = 0.0;
    breakdown["ocean_ms"] = 0.0;
    breakdown["stage_b_ms"] = 0.0;
    breakdown["render_prepare_ms"] = 0.0;
    breakdown["path"] = String("gdext_native_daily");
    breakdown["fallback_reason"] = String();

    auto finish_with_failure = [&](const char *stage, const String &reason) -> Dictionary {
        const auto t_fail = std::chrono::high_resolution_clock::now();
        const double total_ms = std::chrono::duration<double, std::milli>(t_fail - t0).count();
        out["rc"] = -1;
        out["path"] = String("gdext_native_daily");
        out["fail_stage"] = String(stage);
        out["reason"] = reason;
        out["fallback_reason"] = reason;
        out["total_ms"] = total_ms;
        out["native_ms"] = total_ms;
        out["compute_ms"] = double(breakdown.get("climate_ms", 0.0)) +
                            double(breakdown.get("ocean_ms", 0.0)) +
                            double(breakdown.get("weather_ms", 0.0)) +
                            double(breakdown.get("hydrology_ms", 0.0)) +
                            double(breakdown.get("stage_b_ms", 0.0));
        out["refresh_ms"] = double(breakdown.get("native_context_ms", 0.0));
        out["flush_ms"] = double(breakdown.get("render_prepare_ms", 0.0));
        out["published_slots"] = Array();
        out["visual_dirty_intents"] = Array();
        out["dirty_cells"] = int(_native_dirty_report.get("dirty_cell_count", 0));
        out["native_state_snapshot"] = breakdown.get("native_state_snapshot", Dictionary());
        breakdown["fallback_reason"] = reason;
        breakdown["native_ms"] = total_ms;
        breakdown["compute_ms"] = out["compute_ms"];
        breakdown["refresh_ms"] = out["refresh_ms"];
        breakdown["flush_ms"] = out["flush_ms"];
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

    auto append_unique = [](Array &arr, const String &value) {
        for (int i = 0; i < arr.size(); ++i) {
            if (String(arr[i]) == value) {
                return;
            }
        }
        arr.append(value);
    };

    auto collect_bundle_pass_keys = [&](const Dictionary &bundle_dict) -> Array {
        Array keys;
        auto record_key = [&](const char *key) {
            if (bundle_dict.has(key)) {
                keys.append(String(key));
            }
        };
        record_key("climate_pass_a_struct");
        record_key("ocean_water_knobs");
        record_key("ocean_land_knobs");
        record_key("climate_pass_b_knobs");
        record_key("wind_air_knobs");
        record_key("wind_surface_knobs");
        record_key("sea_ice_knobs");
        record_key("transpiration_knobs");
        record_key("albedo_knobs");
        record_key("vegetation_dynamics_knobs");
        record_key("climate_feedback_knobs");
        record_key("stage_b_knobs");
        record_key("weather_knobs");
        record_key("runtime_hydrology_knobs");
        record_key("stage_b_after_hydrology_knobs");
        return keys;
    };

    auto collect_published_slots = [&](const Dictionary &bundle_dict) -> Array {
        Array slots;
        if (bundle_dict.has("climate_pass_a_struct") || bundle_dict.has("climate_pass_b_knobs") ||
            bundle_dict.has("ocean_water_knobs") || bundle_dict.has("ocean_land_knobs") ||
            bundle_dict.has("wind_air_knobs") || bundle_dict.has("wind_surface_knobs") ||
            bundle_dict.has("sea_ice_knobs") || bundle_dict.has("transpiration_knobs")) {
            append_unique(slots, String("cell_temp"));
            append_unique(slots, String("cell_moisture"));
            append_unique(slots, String("cell_snow_cover"));
            append_unique(slots, String("cell_sea_ice_frac"));
            append_unique(slots, String("cell_air_mass_temp_anomaly"));
            append_unique(slots, String("cell_ocean_thermal_anomaly"));
            append_unique(slots, String("cell_local_thermal_anomaly"));
        }
        if (bundle_dict.has("stage_b_knobs") || bundle_dict.has("stage_b_after_hydrology_knobs") ||
            bundle_dict.has("albedo_knobs") ||
            bundle_dict.has("vegetation_dynamics_knobs") || bundle_dict.has("climate_feedback_knobs")) {
            append_unique(slots, String("cell_cover"));
            append_unique(slots, String("cell_vegetation"));
            append_unique(slots, String("cell_vegetation_vitality"));
        }
        if (bundle_dict.has("weather_knobs")) {
            append_unique(slots, String("cell_weather_type"));
            append_unique(slots, String("cell_weather_intensity"));
            append_unique(slots, String("cell_weather_cloud"));
            append_unique(slots, String("cell_weather_precip"));
            append_unique(slots, String("cell_weather_field_init"));
            append_unique(slots, String("cell_weather_transition_alpha"));
        }
        if (bundle_dict.has("runtime_hydrology_knobs")) {
            append_unique(slots, String("cell_soil_moisture"));
            append_unique(slots, String("cell_water_balance_30d"));
            append_unique(slots, String("cell_river_discharge"));
            append_unique(slots, String("cell_river_discharge_30d"));
            append_unique(slots, String("cell_river_storage"));
            append_unique(slots, String("cell_groundwater_storage"));
            append_unique(slots, String("cell_surface_runoff"));
        }
        return slots;
    };

    auto collect_retained_gdscript_authority = [&](const Dictionary &bundle_dict) -> Array {
        Array retained;
        if (!bundle_dict.has("wind_air_knobs")) {
            retained.append(String("wind_air"));
        }
        if (!bundle_dict.has("wind_surface_knobs")) {
            retained.append(String("wind_surface"));
        }
        if (bool(bundle_dict.get("runtime_hydrology_requested", false)) &&
            !bundle_dict.has("runtime_hydrology_knobs")) {
            retained.append(String("runtime_hydrology"));
        }
        if (!bundle_dict.has("sea_ice_knobs")) {
            retained.append(String("sea_ice"));
        }
        return retained;
    };

    auto collect_visual_dirty_intents = [&](const Dictionary &bundle_dict,
                                            const Dictionary &breakdown_dict) -> Array {
        Array intents;
        if (bool(_native_dirty_report.get("atlas_dirty", false))) {
            append_unique(intents, String("atlas"));
        }
        if (bool(_native_dirty_report.get("enum_atlas_dirty", false))) {
            append_unique(intents, String("enum_atlas"));
        }
        if (bool(_native_dirty_report.get("sea_ice_atlas_dirty", false))) {
            append_unique(intents, String("sea_ice_atlas"));
        }
        if (bundle_dict.has("weather_knobs") &&
            (bool(breakdown_dict.get("weather_lut_changed", false)) ||
             breakdown_dict.has("weather_lut"))) {
            append_unique(intents, String("weather_lut"));
        }
        if (breakdown_dict.has("succession_indices") ||
            int(breakdown_dict.get("stat_succession_count", 0)) > 0) {
            append_unique(intents, String("detail_scatter"));
        }
        return intents;
    };

    auto collect_native_state_snapshot = [&](const Dictionary &bundle_dict) -> Dictionary {
        Dictionary state;
        state["tick_owner"] = String("DCWorldExt.native_daily_graph");
        String climate_round_state_owner = String("gdscript_retained");
        Dictionary climate_native_probe_state;
        if (bundle_dict.has("climate_round_state_snapshot")) {
            Dictionary climate_round_state = as_dict(bundle_dict["climate_round_state_snapshot"]);
            state["climate_round_state"] = climate_round_state;
            if (climate_round_state.has("native_probe_state")) {
                Dictionary native_probe_state = as_dict(climate_round_state["native_probe_state"]);
                climate_native_probe_state = native_probe_state;
                const bool climate_round_ready = bool(native_probe_state.get("climate_round_authority_ready", false));
                if (climate_round_ready &&
                    (bool(native_probe_state.get("simulation_authority", false)) ||
                     bool(bundle_dict.get("climate_round_active_owner_requested", false)))) {
                    climate_round_state_owner = String("native_active");
                } else if (climate_round_ready) {
                    climate_round_state_owner = String("native_ready");
                }
            }
        }
        state["climate_round_state_owner"] = climate_round_state_owner;
        Dictionary weather_readiness = as_dict(bundle_dict.get("weather_native_daily_readiness", Dictionary()));
        const bool weather_native_ready = bool(weather_readiness.get("ready", false));
        const bool weather_active_requested = bool(bundle_dict.get("weather_transaction_active_owner_requested", false));
        state["weather_transaction_state_owner"] =
            (weather_native_ready && weather_active_requested)
                ? String("native_active")
                : (weather_native_ready
                ? String("native_ready")
                : (bundle_dict.has("weather_knobs")
                       ? String("native_transaction_with_gdscript_apply")
                       : String("gdscript_retained")));
        Dictionary ocean_physical_state = as_dict(bundle_dict.get("ocean_physical_state_snapshot", Dictionary()));
        if (!ocean_physical_state.is_empty()) {
            state["ocean_physical_state"] = ocean_physical_state;
        }
        state["ocean_physical_state_owner"] =
            ocean_physical_state.has("owner")
                ? String(ocean_physical_state.get("owner", "gdscript_retained"))
                : String("gdscript_retained");
        Dictionary season_refresh_state = as_dict(bundle_dict.get("season_refresh_state_snapshot", Dictionary()));
        if (!season_refresh_state.is_empty()) {
            state["season_refresh_state"] = season_refresh_state;
        }
        Dictionary season_cadence_policy = as_dict(bundle_dict.get("season_cadence_policy", Dictionary()));
        if (!season_cadence_policy.is_empty()) {
            state["season_cadence_policy"] = season_cadence_policy;
        }
        state["season_refresh_state_owner"] =
            season_refresh_state.has("owner")
                ? String(season_refresh_state.get("owner", "gdscript_retained"))
                : String("gdscript_retained");
        state["visual_upload_state_owner"] = String("godot_retained");
        state["fallback_owner"] =
            bool(bundle_dict.get("legacy_sus_fallback_enabled", true))
                ? String("gdscript_legacy_sus")
                : String("explicit_failure_only");
        Array authority_blockers = collect_retained_gdscript_authority(bundle_dict);
        if (climate_round_state_owner != String("native_active")) {
            append_unique(authority_blockers, String("climate_round"));
        }
        if (bundle_dict.has("weather_knobs") &&
            String(state["weather_transaction_state_owner"]) != String("native_active")) {
            append_unique(authority_blockers, String("weather_transaction"));
        }
        if (String(state["ocean_physical_state_owner"]) != String("native_active")) {
            append_unique(authority_blockers, String("ocean_currents_physical_state"));
        }
        if (String(state["season_refresh_state_owner"]) != String("native_active")) {
            append_unique(authority_blockers, String("season_refresh"));
        }
        if (bool(bundle_dict.get("legacy_sus_fallback_enabled", true))) {
            append_unique(authority_blockers, String("legacy_sus_fallback_enabled"));
        }
        Array retained_boundaries = native_daily_collect_retained_boundaries(bundle_dict);
        Dictionary authority_report;
        Dictionary climate_authority;
        climate_authority["owner"] = climate_round_state_owner;
        climate_authority["phase"] =
            climate_round_state_owner == String("native_active")
                ? String("active_owner_gate")
                : (climate_round_state_owner == String("native_ready")
                       ? String("native_ready_probe")
                       : String("gdscript_state_machine"));
        climate_authority["simulation_authority"] = climate_round_state_owner == String("native_active");
        climate_authority["remaining_gdscript_authority"] =
            climate_native_probe_state.get("remaining_gdscript_authority", Array());
        authority_report["climate_round"] = climate_authority;
        Dictionary weather_authority;
        weather_authority["owner"] = state["weather_transaction_state_owner"];
        weather_authority["phase"] =
            (weather_native_ready && weather_active_requested)
                ? String("native_active_visible_publish")
                : (weather_native_ready
                ? String("native_ready_visible_publish")
                : (bundle_dict.has("weather_knobs")
                       ? String("native_transaction_with_gdscript_apply")
                       : String("gdscript_retained")));
        weather_authority["readiness"] = weather_readiness;
        weather_authority["visible_publish_ready"] = weather_native_ready;
        weather_authority["active_owner_requested"] = weather_active_requested;
        weather_authority["simulation_authority"] = weather_native_ready && weather_active_requested;
        weather_authority["front_snapshot_ready"] = bool(weather_readiness.get("has_result_apply", false));
        weather_authority["weather_lut_intent_ready"] = bool(weather_readiness.get("has_weather_lut_publish", false));
        weather_authority["publish_slots_expected"] =
            weather_native_ready || bundle_dict.has("weather_knobs")
                ? Array::make(String("cell_weather_type"),
                              String("cell_weather_intensity"),
                              String("cell_weather_cloud"),
                              String("cell_weather_precip"),
                              String("cell_weather_field_init"),
                              String("cell_weather_transition_alpha"))
                : Array();
        weather_authority["retained_boundaries"] =
            Array::make(String("front_objects_gdscript"),
                        String("weather_lut_upload_godot_boundary"));
        weather_authority["blockers"] =
            weather_native_ready
                ? Array()
                : Array::make(String("weather_transaction_state_gdscript"),
                              String(weather_readiness.get("reason", "not_ready")));
        authority_report["weather_transaction"] = weather_authority;
        Dictionary hydrology_authority;
        hydrology_authority["owner"] =
            bundle_dict.has("runtime_hydrology_knobs") ? String("native_active") : String("gdscript_retained");
        hydrology_authority["phase"] =
            bundle_dict.has("runtime_hydrology_knobs") ? String("native_graph_node") : String("legacy_weather_chain");
        hydrology_authority["simulation_authority"] = bundle_dict.has("runtime_hydrology_knobs");
        hydrology_authority["published_slots_expected"] =
            bundle_dict.has("runtime_hydrology_knobs")
                ? Array::make(String("cell_soil_moisture"),
                              String("cell_water_balance_30d"),
                              String("cell_river_discharge"),
                              String("cell_river_discharge_30d"),
                              String("cell_river_storage"),
                              String("cell_groundwater_storage"),
                              String("cell_surface_runoff"))
                : Array();
        hydrology_authority["blockers"] =
            bundle_dict.has("runtime_hydrology_knobs")
                ? Array()
                : Array::make(String("runtime_hydrology_knobs_missing"));
        authority_report["runtime_hydrology"] = hydrology_authority;
        Dictionary sea_ice_authority;
        sea_ice_authority["owner"] =
            bundle_dict.has("sea_ice_knobs") ? String("native_active") : String("gdscript_retained");
        sea_ice_authority["phase"] =
            bundle_dict.has("sea_ice_knobs") ? String("native_graph_node") : String("legacy_climate_or_sea_ice_job");
        sea_ice_authority["simulation_authority"] = bundle_dict.has("sea_ice_knobs");
        sea_ice_authority["published_slots_expected"] =
            bundle_dict.has("sea_ice_knobs")
                ? Array::make(String("cell_sea_ice_frac"),
                              String("cell_temp"),
                              String("cell_moisture"))
                : Array();
        sea_ice_authority["blockers"] =
            bundle_dict.has("sea_ice_knobs")
                ? Array()
                : Array::make(String("sea_ice_knobs_missing"));
        sea_ice_authority["retained_boundaries"] =
            bundle_dict.has("sea_ice_knobs")
                ? Array::make(String("terrain_flip_visibility_gdscript"),
                              String("sea_ice_visual_upload_godot"))
                : Array();
        authority_report["sea_ice"] = sea_ice_authority;
        Dictionary ocean_authority;
        ocean_authority["owner"] = state["ocean_physical_state_owner"];
        ocean_authority["phase"] =
            String(state["ocean_physical_state_owner"]) == String("native_active")
                ? String("native_active_lifecycle")
                : (String(state["ocean_physical_state_owner"]) == String("native_ready") ||
                   String(state["ocean_physical_state_owner"]) == String("native_ready_probe")
                       ? String("native_ready_probe")
                       : String("gdscript_stage_machine"));
        ocean_authority["state"] = ocean_physical_state;
        ocean_authority["simulation_authority"] =
            String(state["ocean_physical_state_owner"]) == String("native_active");
        ocean_authority["native_owned_output_slots"] =
            ocean_physical_state.get("native_owned_output_slots", Array());
        ocean_authority["blockers"] =
            String(state["ocean_physical_state_owner"]) == String("native_active")
                ? Array()
                : Array::make(String("ocean_physical_owner_not_active"));
        ocean_authority["retained_boundaries"] =
            ocean_physical_state.get("remaining_gdscript_authority",
                Array::make(String("visual_raster_boundary_godot"),
                            String("texture_commit_boundary_godot")));
        authority_report["ocean_physical"] = ocean_authority;
        Dictionary season_authority;
        season_authority["owner"] = state["season_refresh_state_owner"];
        season_authority["phase"] =
            String(state["season_refresh_state_owner"]) == String("native_active")
                ? String("native_active_cadence")
                : (String(state["season_refresh_state_owner"]) == String("native_ready") ||
                   String(state["season_refresh_state_owner"]) == String("native_ready_probe")
                       ? String("native_ready_cadence_probe")
                       : String("gdscript_cadence"));
        season_authority["state"] = season_refresh_state;
        season_authority["simulation_authority"] =
            String(state["season_refresh_state_owner"]) == String("native_active");
        season_authority["simulation_slot_dirty_intents"] =
            season_refresh_state.get("simulation_slot_dirty_intents", Array());
        season_authority["visual_dirty_intents"] =
            season_refresh_state.get("visual_dirty_intents", Array());
        season_authority["cadence_policy"] = season_cadence_policy;
        season_authority["cadence_policy_owner"] =
            season_cadence_policy.has("owner")
                ? season_cadence_policy.get("owner", String("gdscript_retained"))
                : Variant(String("gdscript_retained"));
        season_authority["cadence_policy_state"] =
            season_cadence_policy.has("policy_state")
                ? season_cadence_policy.get("policy_state", String("gdscript_retained"))
                : Variant(String("gdscript_retained"));
        season_authority["blockers"] =
            String(state["season_refresh_state_owner"]) == String("native_active")
                ? Array()
                : Array::make(String("season_refresh_owner_not_active"));
        season_authority["retained_boundaries"] =
            season_refresh_state.get("visual_dirty_intents",
                Array::make(String("atlas_queue_godot"),
                            String("detail_scatter_godot")));
        authority_report["season_refresh"] = season_authority;
        Dictionary visual_authority;
        visual_authority["owner"] = state["visual_upload_state_owner"];
        visual_authority["phase"] = String("godot_upload_boundary");
        visual_authority["blockers"] = Array::make(String("image_texture_upload_godot"));
        authority_report["visual_upload"] = visual_authority;
        Dictionary fallback_authority;
        const bool legacy_fallback_enabled = bool(bundle_dict.get("legacy_sus_fallback_enabled", true));
        fallback_authority["owner"] =
            legacy_fallback_enabled ? String(state["fallback_owner"]) : String("explicit_failure_only");
        fallback_authority["phase"] =
            legacy_fallback_enabled ? String("fallback_retained") : String("fallback_test_only");
        fallback_authority["blockers"] =
            legacy_fallback_enabled ? Array::make(String("legacy_sus_fallback_enabled")) : Array();
        authority_report["fallback"] = fallback_authority;
        state["authority_report"] = authority_report;
        state["authority_blockers"] = authority_blockers;
        state["retained_boundaries"] = retained_boundaries;
        state["retained_godot_boundaries"] = retained_boundaries;
        state["retained_boundary_policy"] = String("explicit_godot_presentation_boundary");
        state["graph_coverage_state"] =
            authority_blockers.is_empty() ? String("complete") : String("partial");
        return state;
    };

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
            } else if (fail_stage != nullptr && String(fail_stage) == String("runtime_hydrology")) {
                reason = String(breakdown.get("__hydrology_fail_reason", "pass returned fallback"));
                breakdown.erase("__hydrology_fail_reason");
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
        // [climate-mt 2026-07] legacy if-chain（use_system_schedule=false 兜底，现已死路）
        //   亦切多核 _thread，保持与 slice / system_schedule 三路 dispatch bit-equal。
        const double ms = run_climate_pass_a_thread(cp_struct, phase, season_phase, 0);
        if (ms < 0.0) return finish_with_failure("climate_pass_a", "pass returned fallback");
        breakdown["pass_a_ms"] = ms;
        breakdown["climate_ms"] = double(breakdown.get("climate_ms", 0.0)) + ms;
        any_pass_ran = true;

    if (bundle.has("climate_pass_b_knobs")) {
        const double ms = run_climate_pass_b_thread(as_dict(bundle["climate_pass_b_knobs"]), 0);
        if (ms < 0.0) return finish_with_failure("climate_pass_b", "pass returned fallback");
        breakdown["pass_b_ms"] = ms;
        breakdown["climate_ms"] = double(breakdown.get("climate_ms", 0.0)) + ms;
        any_pass_ran = true;
    }

    if (bundle.has("ocean_water_knobs")) {
        Dictionary water_knobs = as_dict(bundle["ocean_water_knobs"]);
        const bool use_thread = bool(water_knobs.get("native_daily_thread_variant_enabled", false));
        const int thread_tasks = int(water_knobs.get("native_daily_thread_tasks", 0));
        double ms = use_thread
            ? run_ocean_water_pass_thread(water_knobs, thread_tasks)
            : run_ocean_water_pass(water_knobs);
        String variant = use_thread ? String("thread") : String("scalar");
        if (ms < 0.0 && use_thread) {
            ms = run_ocean_water_pass(water_knobs);
            variant = String("thread_fallback_scalar");
        }
        if (ms < 0.0) return finish_with_failure("ocean_water", "pass returned fallback");
        bundle["ocean_water_knobs"] = water_knobs;
        if (water_knobs.has("anomaly_out") && bundle.has("ocean_land_knobs")) {
            Dictionary land_knobs = as_dict(bundle["ocean_land_knobs"]);
            land_knobs["anomaly_inout"] = water_knobs["anomaly_out"];
            bundle["ocean_land_knobs"] = land_knobs;
        }
        breakdown["ocean_water_ms"] = ms;
        breakdown["ocean_water_variant"] = variant;
        breakdown["ocean_water_thread_tasks"] = thread_tasks;
        breakdown["ocean_ms"] = double(breakdown.get("ocean_ms", 0.0)) + ms;
        any_pass_ran = true;
    }

    if (bundle.has("ocean_land_knobs")) {
        Dictionary land_knobs = as_dict(bundle["ocean_land_knobs"]);
        const bool use_thread = bool(land_knobs.get("native_daily_thread_variant_enabled", false));
        const int thread_tasks = int(land_knobs.get("native_daily_thread_tasks", 0));
        double ms = use_thread
            ? run_ocean_land_pass_thread(land_knobs, thread_tasks)
            : run_ocean_land_pass(land_knobs);
        String variant = use_thread ? String("thread") : String("scalar");
        if (ms < 0.0 && use_thread) {
            ms = run_ocean_land_pass(land_knobs);
            variant = String("thread_fallback_scalar");
        }
        if (ms < 0.0) return finish_with_failure("ocean_land", "pass returned fallback");
        bundle["ocean_land_knobs"] = land_knobs;
        breakdown["ocean_land_ms"] = ms;
        breakdown["ocean_land_variant"] = variant;
        breakdown["ocean_land_thread_tasks"] = thread_tasks;
        breakdown["ocean_ms"] = double(breakdown.get("ocean_ms", 0.0)) + ms;
        any_pass_ran = true;
    }

    if (bundle.has("wind_air_knobs")) {
        const double ms = run_wind_air_mass_pass(as_dict(bundle["wind_air_knobs"]));
        if (ms < 0.0) return finish_with_failure("wind_air", "pass returned fallback");
        breakdown["wind_air_ms"] = ms;
        breakdown["wind_ms"] = double(breakdown.get("wind_ms", 0.0)) + ms;
        breakdown["climate_ms"] = double(breakdown.get("climate_ms", 0.0)) + ms;
        any_pass_ran = true;
    }

    if (bundle.has("wind_surface_knobs")) {
        const double ms = run_wind_surface_pass(as_dict(bundle["wind_surface_knobs"]));
        if (ms < 0.0) return finish_with_failure("wind_surface", "pass returned fallback");
        breakdown["wind_surface_ms"] = ms;
        breakdown["wind_ms"] = double(breakdown.get("wind_ms", 0.0)) + ms;
        breakdown["climate_ms"] = double(breakdown.get("climate_ms", 0.0)) + ms;
        any_pass_ran = true;
    }

    if (bundle.has("sea_ice_knobs")) {
        const float phase = float(tick_knobs.get("season_phase", 0.0));
        Dictionary sea_ice_knobs = as_dict(bundle["sea_ice_knobs"]);
        const double ms = run_sea_ice_daily_pass(sea_ice_knobs, phase);
        if (ms < 0.0) return finish_with_failure("sea_ice", "pass returned fallback");
        breakdown["sea_ice_ms"] = ms;
        breakdown["sea_ice_dt_days"] = double(sea_ice_knobs.get("dt_days", 1.0));
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
        const int stage_b_call_index = int(stage_b_knobs.get("stage_b_call_index", -1));
        breakdown["stage_b_call_index"] = stage_b_call_index;
        breakdown["albedo_ran"] = bool(stage_b_knobs.get("run_albedo", false));
        breakdown["veg_dyn_ran"] = bool(stage_b_knobs.get("run_veg_dyn", false));
        breakdown["feedback_ran"] = bool(stage_b_knobs.get("run_feedback", false));
        breakdown["stage_b_combined_done"] = true;
        breakdown["stage_b_ext_ok"] = true;
        breakdown["stage_b_total_runs"] = stage_b_call_index >= 0 ? stage_b_call_index + 1 : 0;
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

    if (bundle.has("runtime_hydrology_knobs")) {
        Dictionary hydro = run_runtime_hydrology_pass(as_dict(bundle["runtime_hydrology_knobs"]));
        const String fallback_reason = String(hydro.get("fallback_reason", ""));
        if (!fallback_reason.is_empty() || !bool(hydro.get("published_to_slot", false))) {
            return finish_with_failure(
                "runtime_hydrology",
                fallback_reason.is_empty() ? String("hydrology did not publish slots") : fallback_reason);
        }
        const double native_ms = double(hydro.get("native_ms", 0.0));
        breakdown["hydrology_ms"] = native_ms;
        breakdown["runtime_hydrology_ms"] = native_ms;
        breakdown["hydrology_native_ms"] = native_ms;
        breakdown["hydrology_compute_ms"] = double(hydro.get("compute_ms", 0.0));
        breakdown["hydrology_flush_ms"] = double(hydro.get("flush_ms", 0.0));
        breakdown["hydrology_dt_days"] = double(hydro.get("dt_days", 1.0));
        breakdown["hydrology_water_budget_error"] = double(hydro.get("water_budget_error", 0.0));
        breakdown["hydrology_river_discharge_p95"] = double(hydro.get("river_discharge_p95", 0.0));
        breakdown["hydrology_river_discharge_max"] = double(hydro.get("river_discharge_max", 0.0));
        breakdown["hydrology_riparian_neighbor_touches"] = int(hydro.get("riparian_neighbor_touches", 0));
        breakdown["hydrology_flood_count"] = int(hydro.get("flood_count", hydro.get("flood_candidate_count", 0)));
        breakdown["hydrology_published_to_slot"] = true;
        any_pass_ran = true;
    }

    if (bundle.has("stage_b_after_hydrology_knobs")) {
        Dictionary stage_b_knobs = as_dict(bundle["stage_b_after_hydrology_knobs"]);
        const double ms = run_stage_b_pass(stage_b_knobs);
        if (ms < 0.0) return finish_with_failure("stage_b", "pass returned fallback");
        breakdown["stage_b_ms"] = double(breakdown.get("stage_b_ms", 0.0)) + ms;
        breakdown["albedo_ms"] = stage_b_knobs.get("albedo_ms", breakdown.get("albedo_ms", 0.0));
        breakdown["veg_dyn_ms"] = stage_b_knobs.get("veg_dyn_ms", breakdown.get("veg_dyn_ms", 0.0));
        breakdown["feedback_ms"] = stage_b_knobs.get("feedback_ms", breakdown.get("feedback_ms", 0.0));
        const int stage_b_call_index = int(stage_b_knobs.get("stage_b_call_index", -1));
        breakdown["stage_b_call_index"] = stage_b_call_index;
        breakdown["albedo_ran"] = bool(stage_b_knobs.get("run_albedo", false));
        breakdown["veg_dyn_ran"] = bool(stage_b_knobs.get("run_veg_dyn", false));
        breakdown["feedback_ran"] = bool(stage_b_knobs.get("run_feedback", false));
        breakdown["stage_b_combined_done"] = true;
        breakdown["stage_b_ext_ok"] = true;
        breakdown["stage_b_total_runs"] = stage_b_call_index >= 0 ? stage_b_call_index + 1 : 0;
        if (stage_b_knobs.has("succession_indices")) {
            breakdown["succession_indices"] = stage_b_knobs["succession_indices"];
            breakdown["succession_to_veg"] = stage_b_knobs["succession_to_veg"];
            breakdown["stat_succession_count"] = stage_b_knobs.get("stat_succession_count", 0);
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
    const double refresh_ms = double(breakdown.get("native_context_ms", 0.0));
    const double flush_ms = double(breakdown.get("render_prepare_ms", 0.0));
    const double compute_ms = double(breakdown.get("climate_ms", 0.0)) +
                              double(breakdown.get("ocean_ms", 0.0)) +
                              double(breakdown.get("weather_ms", 0.0)) +
                              double(breakdown.get("hydrology_ms", 0.0)) +
                              double(breakdown.get("stage_b_ms", 0.0));
    const Array published_slots = collect_published_slots(bundle);
    const Array visual_dirty_intents = collect_visual_dirty_intents(bundle, breakdown);
    Dictionary authority_report = native_state_snapshot.get("authority_report", Dictionary());
    if (bool(breakdown.get("hydrology_published_to_slot", false)) &&
        authority_report.has("runtime_hydrology")) {
        Dictionary hydrology_authority = authority_report["runtime_hydrology"];
        hydrology_authority["phase"] = String("native_active_verified");
        hydrology_authority["verified_publish"] = true;
        hydrology_authority["simulation_authority"] = true;
        hydrology_authority["blockers"] = Array();
        authority_report["runtime_hydrology"] = hydrology_authority;
    }
    if (bundle.has("sea_ice_knobs") && authority_report.has("sea_ice")) {
        Dictionary sea_ice_authority = authority_report["sea_ice"];
        sea_ice_authority["phase"] = String("native_active_verified");
        sea_ice_authority["verified_publish"] = true;
        sea_ice_authority["simulation_authority"] = true;
        sea_ice_authority["blockers"] = Array();
        authority_report["sea_ice"] = sea_ice_authority;
    }
    if (bundle.has("weather_knobs") && authority_report.has("weather_transaction")) {
        Dictionary weather_authority = authority_report["weather_transaction"];
        const bool weather_publish_verified = bool(breakdown.get("field_commit_publish_verified", false));
        const bool weather_fronts_changed =
            bool(breakdown.get("weather_lut_changed", false)) ||
            int(breakdown.get("fronts_count", 0)) > 0;
        weather_authority["visible_publish_verified"] = weather_publish_verified;
        weather_authority["fronts_changed"] = weather_fronts_changed;
        if (weather_publish_verified &&
            String(weather_authority.get("owner", "")) == String("native_active")) {
            weather_authority["phase"] = String("native_active_verified");
            weather_authority["simulation_authority"] = true;
            weather_authority["blockers"] = Array();
        }
        authority_report["weather_transaction"] = weather_authority;
    }
    out["rc"] = 0;
    out["path"] = String("gdext_native_daily");
    out["fail_stage"] = String();
    out["fallback_reason"] = String();
    out["total_ms"] = total_ms;
    out["native_ms"] = total_ms;
    out["compute_ms"] = compute_ms;
    out["refresh_ms"] = refresh_ms;
    out["flush_ms"] = flush_ms;
    out["published_slots"] = published_slots;
    out["dirty_cells"] = int(_native_dirty_report.get("dirty_cell_count", 0));
    out["visual_dirty_intents"] = visual_dirty_intents;
    out["retained_gdscript_authority"] = retained_gdscript_authority;
    out["native_state_snapshot"] = native_state_snapshot;
    out["authority_report"] = authority_report;
    out["authority_blockers"] = native_state_snapshot.get("authority_blockers", Array());
    out["retained_boundaries"] = native_state_snapshot.get("retained_boundaries", Array());
    out["retained_godot_boundaries"] = native_state_snapshot.get("retained_godot_boundaries", Array());
    out["retained_boundary_policy"] = native_state_snapshot.get("retained_boundary_policy", String());
    out["graph_coverage_complete"] = Array(out["authority_blockers"]).is_empty();
    out["graph_coverage_state"] = native_state_snapshot.get("graph_coverage_state", String("partial"));
    out["boundary_contract"] = bundle.get("native_daily_boundary_contract", Dictionary());
    Dictionary boundary_contract = out["boundary_contract"];
    out["bundle_key_count"] = int(boundary_contract.get("bundle_key_count", bundle.size()));
    out["tick_delta_key_count"] = Array(boundary_contract.get("tick_delta_keys", Array())).size();
    out["runtime_config_report"] = _native_runtime_config.duplicate(true);
    const bool active_default_ready =
        String(out["graph_coverage_state"]) == String("complete") &&
        Array(out["authority_blockers"]).is_empty();
    out["native_daily_active_default_ready"] = active_default_ready;
    out["active_default_blockers"] = out["authority_blockers"];
    out["fallback_mode"] =
        active_default_ready ? String("explicit_failure_only") : String("legacy_sus_retained_until_active_default_validation");
    PackedFloat32Array temperature_transport_anomaly_out;
    if (bundle.has("ocean_land_knobs")) {
        Dictionary land_knobs = as_dict(bundle["ocean_land_knobs"]);
        if (land_knobs.has("anomaly_inout")) {
            temperature_transport_anomaly_out = land_knobs["anomaly_inout"];
        }
    }
    breakdown["total_ms"] = total_ms;
    breakdown["native_ms"] = total_ms;
    breakdown["compute_ms"] = compute_ms;
    breakdown["refresh_ms"] = refresh_ms;
    breakdown["flush_ms"] = flush_ms;
    breakdown["published_slots"] = published_slots;
    breakdown["dirty_cells"] = int(_native_dirty_report.get("dirty_cell_count", 0));
    breakdown["visual_dirty_intents"] = visual_dirty_intents;
    breakdown["native_state_snapshot"] = native_state_snapshot;
    breakdown["authority_report"] = authority_report;
    breakdown["authority_blockers"] = native_state_snapshot.get("authority_blockers", Array());
    breakdown["retained_boundaries"] = native_state_snapshot.get("retained_boundaries", Array());
    breakdown["retained_godot_boundaries"] = native_state_snapshot.get("retained_godot_boundaries", Array());
    breakdown["retained_boundary_policy"] = native_state_snapshot.get("retained_boundary_policy", String());
    breakdown["graph_coverage_complete"] = Array(breakdown["authority_blockers"]).is_empty();
    breakdown["graph_coverage_state"] = native_state_snapshot.get("graph_coverage_state", String("partial"));
    breakdown["boundary_contract"] = bundle.get("native_daily_boundary_contract", Dictionary());
    breakdown["bundle_key_count"] = out["bundle_key_count"];
    breakdown["tick_delta_key_count"] = out["tick_delta_key_count"];
    breakdown["runtime_config_report"] = out["runtime_config_report"];
    breakdown["native_daily_active_default_ready"] = out["native_daily_active_default_ready"];
    breakdown["active_default_blockers"] = out["active_default_blockers"];
    breakdown["fallback_mode"] = out["fallback_mode"];
    if (temperature_transport_anomaly_out.size() > 0) {
        out["temperature_transport_anomaly_out"] = temperature_transport_anomaly_out;
    }
    out["breakdown"] = breakdown;
    out["dirty_flags"] = _native_dirty_report.duplicate();
    out["fronts_changed"] =
        bool(breakdown.get("weather_lut_changed", false)) ||
        int(breakdown.get("fronts_count", 0)) > 0;
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

Dictionary DCWorldExt::native_ocean_physical_begin(const Dictionary &ctx) {
    Dictionary state = _native_ocean_physical_state.duplicate(true);
    state["owner"] = String("DCWorldExt.NativeOceanPhysicalLifecycle");
    state["authority"] = String("native_ready_lifecycle");
    state["simulation_authority"] = bool(ctx.get("simulation_authority", false));
    state["lifecycle_owner"] = String("native_ocean_physical_lifecycle");
    state["lifecycle_state"] = String("round_active");
    state["physical_round_active"] = true;
    state["physical_round_id"] = int(ctx.get("physical_round_id", int(state.get("physical_round_id", 0)) + 1));
    state["physical_phase_locked"] = double(ctx.get("phase_locked", ctx.get("physical_phase_locked", 0.0)));
    state["physical_need_visual"] = bool(ctx.get("physical_need_visual", false));
    state["physical_run_ocean"] = bool(ctx.get("physical_run_ocean", true));
    state["stage"] = int(ctx.get("stage", 0));
    state["stage_name"] = String(ctx.get("stage_name", "begin"));
    state["tick_index"] = int(ctx.get("tick_index", 0));
    state["day_index"] = int(ctx.get("day_index", 0));
    state["start_state_intents"] = Array::make(String("set_physical_round_active"),
                                                String("set_phase_locked"),
                                                String("set_stage_cursor"),
                                                String("record_round_id"));
    state["remaining_gdscript_authority"] = Array::make(String("visual_raster_boundary_execution"),
                                                         String("texture_commit_boundary_execution"));
    state["native_owned_lifecycle_authority"] = Array::make(String("physical_round_active"),
                                                             String("physical_round_id"),
                                                             String("phase_locked"),
                                                             String("physical_stage"),
                                                             String("physical_stage_cursor"));
    _native_ocean_physical_state = state.duplicate(true);
    return get_native_ocean_physical_state_report();
}

Dictionary DCWorldExt::native_ocean_physical_step(const Dictionary &ctx) {
    Dictionary state = _native_ocean_physical_state.duplicate(true);
    state["owner"] = String("DCWorldExt.NativeOceanPhysicalLifecycle");
    state["authority"] = String("native_ready_lifecycle");
    state["lifecycle_owner"] = String("native_ocean_physical_lifecycle");
    state["lifecycle_state"] = String(ctx.get("lifecycle_state", "step"));
    state["physical_round_active"] = bool(ctx.get("physical_round_active", state.get("physical_round_active", false)));
    state["phys_solve_done"] = bool(ctx.get("phys_solve_done", state.get("phys_solve_done", false)));
    state["stage"] = int(ctx.get("stage", state.get("stage", 0)));
    state["stage_name"] = String(ctx.get("stage_name", state.get("stage_name", "step")));
    state["next_stage"] = ctx.get("next_stage", state.get("next_stage", Variant()));
    state["next_stage_name"] = ctx.get("next_stage_name", state.get("next_stage_name", Variant()));
    state["path"] = String(ctx.get("path", state.get("path", "")));
    state["tick_index"] = int(ctx.get("tick_index", state.get("tick_index", 0)));
    state["day_index"] = int(ctx.get("day_index", state.get("day_index", 0)));
    state["last_step_report"] = ctx.duplicate(true);
    state["step_boundary_intents"] = Array::make(String("advance_physical_stage"),
                                                  String("publish_native_stage_report"));
    _native_ocean_physical_state = state.duplicate(true);
    return get_native_ocean_physical_state_report();
}

Dictionary DCWorldExt::native_ocean_physical_finish(const Dictionary &ctx) {
    Dictionary state = _native_ocean_physical_state.duplicate(true);
    state["owner"] = String("DCWorldExt.NativeOceanPhysicalLifecycle");
    state["authority"] = String("native_ready_lifecycle");
    state["lifecycle_owner"] = String("native_ocean_physical_lifecycle");
    state["lifecycle_state"] = String("round_finished");
    state["physical_round_active"] = false;
    state["phys_solve_done"] = false;
    state["last_physical_complete_tick"] = int(ctx.get("tick_index", state.get("tick_index", 0)));
    state["finish_report"] = ctx.duplicate(true);
    state["finish_boundary_intents"] = Array::make(String("publish_physical_completion"),
                                                    String("enqueue_visual_boundary_if_needed"));
    _native_ocean_physical_state = state.duplicate(true);
    return get_native_ocean_physical_state_report();
}

Dictionary DCWorldExt::reset_native_ocean_physical_state(String reason) {
    Dictionary state;
    state["owner"] = String("DCWorldExt.NativeOceanPhysicalLifecycle");
    state["authority"] = String("native_ready_lifecycle");
    state["simulation_authority"] = false;
    state["lifecycle_owner"] = String("native_ocean_physical_lifecycle");
    state["lifecycle_state"] = String("reset");
    state["reset_reason"] = reason;
    state["physical_round_active"] = false;
    state["physical_round_id"] = 0;
    state["stage"] = 0;
    state["stage_name"] = String("reset");
    state["reset_boundary_intents"] = Array::make(String("reset_physical_round"),
                                                   String("reset_visual_round_boundary"),
                                                   String("discard_ocean_buffers"));
    state["remaining_gdscript_authority"] = Array::make(String("visual_raster_boundary_execution"),
                                                         String("texture_commit_boundary_execution"));
    _native_ocean_physical_state = state.duplicate(true);
    return get_native_ocean_physical_state_report();
}

Dictionary DCWorldExt::get_native_ocean_physical_state_report() const {
    Dictionary out = _native_ocean_physical_state.duplicate(true);
    if (out.is_empty()) {
        out["owner"] = String("DCWorldExt.NativeOceanPhysicalLifecycle");
        out["authority"] = String("native_ready_lifecycle");
        out["simulation_authority"] = false;
        out["lifecycle_owner"] = String("native_ocean_physical_lifecycle");
        out["lifecycle_state"] = String("uninitialized");
        out["physical_round_active"] = false;
        out["remaining_gdscript_authority"] = Array::make(String("visual_raster_boundary_execution"),
                                                           String("texture_commit_boundary_execution"));
    }
    return out;
}

Dictionary DCWorldExt::get_native_dirty_report() const {
    return _native_dirty_report.duplicate();
}

// ② finalizer kernel — replicates the per-cell delta-cap + thermal-init loops of
// MapGenerator._native_daily_apply_finalizer in C++ for the production hot path
// (facade ON → no HexCell mirror, heavy_diag OFF → no percentile arrays). It operates
// ONLY on the buffers passed in (the same map.temp_arr / tta / thermal / ema / round-start
// snapshots the GDScript loops read) and returns fresh clamped arrays + the diag scalars.
// No C++ slot reads → bit-equal by construction and immune to the mid-round slot/map
// divergence that reverted the earlier slot-read optimization. GDScript keeps ownership of
// write_dense / buffer cache / map handling and falls back to its own loops on rc!=0 or for
// the heavy_diag / cell-mirror edge cases.
Dictionary DCWorldExt::run_native_daily_finalizer(Dictionary knobs) {
    Dictionary out;
    const int n = (int)(int64_t)knobs.get("cell_count", 0);
    if (n <= 0) { out["rc"] = -1; return out; }
    PackedFloat32Array temp_in = knobs.get("temp", PackedFloat32Array());
    PackedFloat32Array tta_in  = knobs.get("tta", PackedFloat32Array());
    if (temp_in.size() != n || tta_in.size() != n) { out["rc"] = -1; return out; }
    PackedFloat32Array thermal_in = knobs.get("thermal", PackedFloat32Array());
    PackedByteArray    ema_in     = knobs.get("ema", PackedByteArray());
    PackedFloat32Array temp_start = knobs.get("temp_start", PackedFloat32Array());
    PackedFloat32Array tta_start  = knobs.get("tta_start", PackedFloat32Array());
    const bool   temp_cap_enabled = (bool)knobs.get("temp_cap_enabled", true);
    const double temp_cap = (double)knobs.get("temp_cap", 0.15);
    const double tta_cap  = (double)knobs.get("tta_cap", 0.12);
    const bool has_temp_start = temp_start.size() == n;
    const bool has_tta_start  = tta_start.size() == n;

    // NOTE: GDScript floats are 64-bit and clampf()/absf() operate in double; PackedFloat32
    // reads promote to double and only the store narrows back to float32. To stay bit-equal
    // with MapGenerator._native_daily_apply_finalizer we MUST do every intermediate in double
    // and narrow to float ONLY on write-back (a float32 kernel diverges by ~1e-5 on the TTA
    // clamp, which then propagates into ocean/weather/hydrology the next round).

    // --- temp delta-cap (mirrors GDScript temp loop) ---
    PackedFloat32Array temp_out = temp_in;       // CoW: ptrw() below forks a private buffer
    float *tp = temp_out.ptrw();
    const float *ts = has_temp_start ? temp_start.ptr() : nullptr;
    double max_temp_delta = 0.0, preclamp_max = 0.0;
    int gt005 = 0, gt010 = 0, gt020 = 0, clamped = 0;
    for (int i = 0; i < n; ++i) {
        const double start_t = has_temp_start ? (double)ts[i] : (double)tp[i];
        const double raw = (double)tp[i];
        double final_t = raw;
        const double pre = std::fabs(raw - start_t);
        if (pre > preclamp_max) preclamp_max = pre;
        if (temp_cap_enabled && has_temp_start) {
            const double lo = start_t - temp_cap, hi = start_t + temp_cap;
            final_t = final_t < lo ? lo : (final_t > hi ? hi : final_t);
            final_t = final_t < 0.0 ? 0.0 : (final_t > 1.0 ? 1.0 : final_t);
            if (std::fabs(final_t - raw) > 0.000001) ++clamped;
            tp[i] = (float)final_t;
        }
        const double dt = std::fabs(final_t - start_t);
        if (dt > 0.005) ++gt005;
        if (dt > 0.010) ++gt010;
        if (dt > 0.020) ++gt020;
        if (dt > max_temp_delta) max_temp_delta = dt;
    }

    // --- tta delta-cap (mirrors GDScript tta loop) ---
    PackedFloat32Array tta_out = tta_in;
    float *qp = tta_out.ptrw();
    const float *qs = has_tta_start ? tta_start.ptr() : nullptr;
    double max_transport = 0.0;
    int tta_clamped = 0;
    for (int i = 0; i < n; ++i) {
        const double start_q = has_tta_start ? (double)qs[i] : 0.0;
        const double raw = (double)qp[i];
        double final_q = raw;
        if (tta_cap > 0.0 && has_tta_start) {
            const double lo = start_q - tta_cap, hi = start_q + tta_cap;
            final_q = final_q < lo ? lo : (final_q > hi ? hi : final_q);
            if (std::fabs(final_q - raw) > 0.000001) { qp[i] = (float)final_q; ++tta_clamped; }
        }
        const double aq = std::fabs(final_q);
        if (aq > max_transport) max_transport = aq;
    }

    // --- thermal init (mirrors GDScript thermal loop; uses the CLAMPED temp) ---
    const bool has_thermal = thermal_in.size() == n;
    PackedFloat32Array thermal_out = thermal_in;
    int thermal_init = 0;
    if (has_thermal) {
        float *hp = thermal_out.ptrw();
        const uint8_t *ep = ema_in.ptr();
        const int ema_n = ema_in.size();
        for (int i = 0; i < n; ++i) {
            bool needs = std::isnan(hp[i]) || std::isinf(hp[i]);
            if (i < ema_n && ep[i] == 0) needs = true;
            if (needs) { hp[i] = tp[i]; ++thermal_init; }
        }
    }

    out["rc"] = 0;
    out["temp_out"] = temp_out;
    out["tta_out"] = tta_out;
    if (has_thermal) out["thermal_out"] = thermal_out;
    // *_written mirror GDScript's CoW fork-on-write: temp_a is forked whenever the cap loop
    // runs (writes every cell), but tta_a / thermal_a fork ONLY when a cell is actually
    // written (clamped / re-inited). GDScript must adopt the C++ buffer ONLY when its flag is
    // set, otherwise keep the array aliased to map.* — the alias feeds the next round through
    // _gdext_ocean_anomaly_buf_cached, so forking it unconditionally diverges by ~1e-5.
    out["temp_written"] = (temp_cap_enabled && has_temp_start && n > 0);
    out["tta_written"] = (tta_clamped > 0);
    out["thermal_written"] = (thermal_init > 0);
    out["max_temp_delta"] = (double)max_temp_delta;
    out["preclamp_max_temp_delta"] = (double)preclamp_max;
    out["temp_delta_gt_005_count"] = gt005;
    out["temp_delta_gt_010_count"] = gt010;
    out["temp_delta_gt_020_count"] = gt020;
    out["temp_delta_clamped_count"] = clamped;
    out["max_transport_anomaly"] = (double)max_transport;
    out["finalizer_tta_clamped_count"] = tta_clamped;
    out["finalizer_thermal_init_count"] = thermal_init;
    const bool native_publish = (bool)knobs.get("native_publish", false);
    bool native_published = false;
    String native_publish_fail_reason;
    Array native_published_slots;
    double native_write_ms = 0.0;
    if (native_publish) {
        const auto t_native_write0 = std::chrono::high_resolution_clock::now();
        if (!_bound || !_map_data) {
            native_publish_fail_reason = "world_not_bound";
        } else {
            const int sid_temp = component_id(StringName("cell_temp"));
            const int sid_tta = component_id(StringName("cell_temperature_transport_anomaly"));
            const int sid_thermal = component_id(StringName("cell_thermal_energy"));
            auto publish_f32_slot = [&](int sid,
                                        const PackedFloat32Array &arr,
                                        bool written,
                                        const String &slot_name) -> bool {
                if (!written) {
                    return true;
                }
                if (sid < 0 || sid >= _slots.size()) {
                    native_publish_fail_reason = String("missing_slot:") + slot_name;
                    return false;
                }
                Slot &slot = _slots.write[sid];
                if (slot.dtype != SlotDType::F32 || arr.size() != n) {
                    native_publish_fail_reason = String("slot_shape_mismatch:") + slot_name;
                    return false;
                }
                slot.arr_f32 = arr;
                _flush_slot_to_map(sid);
                native_published_slots.push_back(slot_name);
                return true;
            };
            const bool ok = publish_f32_slot(sid_temp, temp_out, bool(out.get("temp_written", false)), String("cell_temp")) &&
                            publish_f32_slot(sid_tta, tta_out, bool(out.get("tta_written", false)), String("cell_temperature_transport_anomaly")) &&
                            publish_f32_slot(sid_thermal, thermal_out, bool(out.get("thermal_written", false)), String("cell_thermal_energy"));
            native_published = ok;
        }
        const auto t_native_write1 = std::chrono::high_resolution_clock::now();
        native_write_ms = std::chrono::duration<double, std::milli>(t_native_write1 - t_native_write0).count();
    }
    out["native_publish_requested"] = native_publish;
    out["native_published"] = native_published;
    out["native_publish_fail_reason"] = native_publish_fail_reason;
    out["native_published_slots"] = native_published_slots;
    out["finalizer_native_write_ms"] = native_write_ms;
    out["finalizer_native_dirty_mark_ms"] = 0.0;
    return out;
}

} // namespace pk
