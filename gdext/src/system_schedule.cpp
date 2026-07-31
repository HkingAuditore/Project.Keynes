// Phase C.1（dots-total-cpp roadmap）：SystemNode exec_fn 实现 + SCHEDULE_GRAPH 表
//
// 每个 exec_fn 直接镜像 world_ext.cpp line 960-1063 内对应 if 块的语义，
// 包括：
//   - bundle[bundle_key] 取出 + as_dict 类型守护（这里用 inline 等价实现，
//     避免引入 world_ext.cpp 内 lambda 的依赖）
//   - 调 self->run_<X>_pass(...)
//   - 失败返回 false（ms < 0.0 → fallback / weather 段 rc != 0）
//   - 成功累加 breakdown（包括跨 pass 的 climate_ms / ocean_ms / stage_b_ms）
//   - 节点级 side-effect（stage_b 的 4 个 breakdown 回填、weather 的
//     _native_fronts_snapshot 写入 + copy_dict_into）
//
// bit-equal 验证策略：
//   - 这里的逻辑必须**字段顺序、值类型、累加顺序**全部与 line 960-1063 一致
//   - GDScript 端 dots_soak_ab_runner 跑 1000-tick SAME_SOURCE A/B：
//     A=use_gdext_system_schedule off（走原 if-chain），
//     B=on（走本文件 dispatch），breakdown 各 ms 字段 epsilon 1e-5、fronts
//     bit-equal、succession_indices/to_veg 完全相等才算通过

#include "system_schedule.h"

#include "world_ext.h"

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/variant.hpp>

namespace pk {

using godot::Dictionary;
using godot::String;
using godot::Variant;

// ─── 小工具：与 world_ext.cpp 内 lambda 同语义 ─────────────────────────────
static inline Dictionary as_dict_local(const Variant &v) {
    if (v.get_type() == Variant::DICTIONARY) {
        return v;
    }
    return Dictionary();
}

static inline void copy_dict_into_local(Dictionary &dst, const Dictionary &src) {
    godot::Array keys = src.keys();
    for (int i = 0; i < keys.size(); ++i) {
        Variant k = keys[i];
        dst[k] = src[k];
    }
}

// ─── 节点 exec_fn ───────────────────────────────────────────────────────────
// 顺序与 world_ext.cpp line 960-1063 严格一致。

bool DCWorldExt::_exec_node_climate_pass_a(Dictionary& bundle,
                                            const Dictionary& tick_knobs,
                                            Dictionary& breakdown) {
    Dictionary cp_struct = as_dict_local(bundle["climate_pass_a_struct"]);
    const double phase = double(tick_knobs.get("season_phase", 0.0));
    const double season_phase = double(tick_knobs.get("season_phase", phase));
    // [climate-mt 2026-07] 多核：pass_a 纯 cell-local，_thread 逐位等价 scalar。
    const double ms = run_climate_pass_a_thread(cp_struct, phase, season_phase, 0);
    if (ms < 0.0) return false;
    breakdown["pass_a_ms"] = ms;
    breakdown["climate_ms"] = double(breakdown.get("climate_ms", 0.0)) + ms;
    return true;
}

bool DCWorldExt::_exec_node_ocean_water(Dictionary& bundle,
                                         const Dictionary& /*tick_knobs*/,
                                         Dictionary& breakdown) {
    Dictionary water_knobs = as_dict_local(bundle["ocean_water_knobs"]);
    const double ms = run_ocean_water_pass(water_knobs);
    if (ms < 0.0) return false;
    bundle["ocean_water_knobs"] = water_knobs;
    if (water_knobs.has("anomaly_out") && bundle.has("ocean_land_knobs")) {
        Dictionary land_knobs = as_dict_local(bundle["ocean_land_knobs"]);
        land_knobs["anomaly_inout"] = water_knobs["anomaly_out"];
        bundle["ocean_land_knobs"] = land_knobs;
    }
    breakdown["ocean_water_ms"] = ms;
    breakdown["ocean_ms"] = double(breakdown.get("ocean_ms", 0.0)) + ms;
    return true;
}

bool DCWorldExt::_exec_node_ocean_land(Dictionary& bundle,
                                        const Dictionary& /*tick_knobs*/,
                                        Dictionary& breakdown) {
    Dictionary land_knobs = as_dict_local(bundle["ocean_land_knobs"]);
    const double ms = run_ocean_land_pass(land_knobs);
    if (ms < 0.0) return false;
    bundle["ocean_land_knobs"] = land_knobs;
    breakdown["ocean_land_ms"] = ms;
    breakdown["ocean_ms"] = double(breakdown.get("ocean_ms", 0.0)) + ms;
    return true;
}

bool DCWorldExt::_exec_node_climate_pass_b(Dictionary& bundle,
                                            const Dictionary& /*tick_knobs*/,
                                            Dictionary& breakdown) {
    // [climate-mt 2026-07] 多核：pass_b own-cell 写 + 只读快照邻居，_thread 逐位等价。
    const double ms = run_climate_pass_b_thread(as_dict_local(bundle["climate_pass_b_knobs"]), 0);
    if (ms < 0.0) return false;
    breakdown["pass_b_ms"] = ms;
    breakdown["climate_ms"] = double(breakdown.get("climate_ms", 0.0)) + ms;
    return true;
}

bool DCWorldExt::_exec_node_wind_air(Dictionary& bundle,
                                      const Dictionary& /*tick_knobs*/,
                                      Dictionary& breakdown) {
    const double ms = run_wind_air_mass_pass(as_dict_local(bundle["wind_air_knobs"]));
    if (ms < 0.0) return false;
    breakdown["wind_air_ms"] = ms;
    breakdown["wind_ms"] = double(breakdown.get("wind_ms", 0.0)) + ms;
    breakdown["climate_ms"] = double(breakdown.get("climate_ms", 0.0)) + ms;
    return true;
}

bool DCWorldExt::_exec_node_wind_surface(Dictionary& bundle,
                                          const Dictionary& /*tick_knobs*/,
                                          Dictionary& breakdown) {
    const double ms = run_wind_surface_pass(as_dict_local(bundle["wind_surface_knobs"]));
    if (ms < 0.0) return false;
    breakdown["wind_surface_ms"] = ms;
    breakdown["wind_ms"] = double(breakdown.get("wind_ms", 0.0)) + ms;
    breakdown["climate_ms"] = double(breakdown.get("climate_ms", 0.0)) + ms;
    return true;
}

bool DCWorldExt::_exec_node_sea_ice(Dictionary& bundle,
                                     const Dictionary& tick_knobs,
                                     Dictionary& breakdown) {
    const float phase = float(tick_knobs.get("season_phase", 0.0));
    const double ms = run_sea_ice_daily_pass(as_dict_local(bundle["sea_ice_knobs"]), phase);
    if (ms < 0.0) return false;
    breakdown["sea_ice_ms"] = ms;
    breakdown["climate_ms"] = double(breakdown.get("climate_ms", 0.0)) + ms;
    return true;
}

bool DCWorldExt::_exec_node_transpiration(Dictionary& bundle,
                                           const Dictionary& /*tick_knobs*/,
                                           Dictionary& breakdown) {
    const double ms = run_transpiration_pass(as_dict_local(bundle["transpiration_knobs"]));
    if (ms < 0.0) return false;
    breakdown["transp_ms"] = ms;
    breakdown["climate_ms"] = double(breakdown.get("climate_ms", 0.0)) + ms;
    return true;
}

bool DCWorldExt::_exec_node_albedo(Dictionary& bundle,
                                    const Dictionary& /*tick_knobs*/,
                                    Dictionary& breakdown) {
    const double ms = run_albedo_pass(as_dict_local(bundle["albedo_knobs"]));
    if (ms < 0.0) return false;
    breakdown["albedo_ms"] = ms;
    breakdown["stage_b_ms"] = double(breakdown.get("stage_b_ms", 0.0)) + ms;
    return true;
}

bool DCWorldExt::_exec_node_vegetation_dynamics(Dictionary& bundle,
                                                 const Dictionary& /*tick_knobs*/,
                                                 Dictionary& breakdown) {
    const double ms = run_vegetation_dynamics_pass(as_dict_local(bundle["vegetation_dynamics_knobs"]));
    if (ms < 0.0) return false;
    breakdown["veg_dyn_ms"] = ms;
    breakdown["stage_b_ms"] = double(breakdown.get("stage_b_ms", 0.0)) + ms;
    return true;
}

bool DCWorldExt::_exec_node_climate_feedback(Dictionary& bundle,
                                              const Dictionary& /*tick_knobs*/,
                                              Dictionary& breakdown) {
    const double ms = run_climate_feedback_pass(as_dict_local(bundle["climate_feedback_knobs"]));
    if (ms < 0.0) return false;
    breakdown["feedback_ms"] = ms;
    breakdown["stage_b_ms"] = double(breakdown.get("stage_b_ms", 0.0)) + ms;
    return true;
}

bool DCWorldExt::_exec_node_stage_b(Dictionary& bundle,
                                     const Dictionary& /*tick_knobs*/,
                                     Dictionary& breakdown) {
    Dictionary stage_b_knobs = as_dict_local(bundle["stage_b_knobs"]);
    // stage_b_knobs 为空（run_albedo/veg_dyn/feedback 全 false 的 stride tick）
    // 时跳过，不算失败。
    if (stage_b_knobs.is_empty()) {
        return true;
    }
    const double ms = run_stage_b_pass(stage_b_knobs);
    if (ms < 0.0) return false;
    breakdown["stage_b_ms"] = double(breakdown.get("stage_b_ms", 0.0)) + ms;
    // stage_b 内嵌跑了 albedo / veg_dyn / feedback / succession，把 stage_b_knobs
    // 里 pass 自己写回的字段刷到 breakdown（与 line 1041-1048 对齐）
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
    return true;
}


bool DCWorldExt::_exec_node_stage_b_after_hydrology(Dictionary& bundle,
                                                     const Dictionary& /*tick_knobs*/,
                                                     Dictionary& breakdown) {
    Dictionary stage_b_knobs = as_dict_local(bundle["stage_b_after_hydrology_knobs"]);
    // stage_b_knobs 为空时跳过（同 _exec_node_stage_b）。
    if (stage_b_knobs.is_empty()) {
        return true;
    }
    const double ms = run_stage_b_pass(stage_b_knobs);
    if (ms < 0.0) return false;
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
    return true;
}

bool DCWorldExt::_exec_node_weather(Dictionary& bundle,
                                     const Dictionary& /*tick_knobs*/,
                                     Dictionary& breakdown) {
    Dictionary weather = run_weather_refresh_daily_pass(as_dict_local(bundle["weather_knobs"]));
    if (int(weather.get("rc", -1)) != 0) {
        // 失败：把 fail_stage 透传到 breakdown 临时位（caller 走 finish_with_failure
        // 时会拿 node.fail_stage，但 weather 的 fail_stage 是动态值——我们把它
        // 暂存到 breakdown 里供 caller 兜底）
        breakdown["__weather_fail_stage_dyn"] = weather.get("fail_stage", "unknown");
        return false;
    }
    breakdown["weather_ms"] = double(weather.get("total_ms", 0.0));
    copy_dict_into_local(breakdown, weather);
    if (weather.has("fronts")) {
        _native_fronts_snapshot = weather["fronts"];
    }
    return true;
}


bool DCWorldExt::_exec_node_runtime_hydrology(Dictionary& bundle,
                                               const Dictionary& /*tick_knobs*/,
                                               Dictionary& breakdown) {
    Dictionary hydro = run_runtime_hydrology_pass(as_dict_local(bundle["runtime_hydrology_knobs"]));
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
    breakdown["hydrology_river_moisture_floor_touches"] = int(hydro.get("river_moisture_floor_touches", 0));
    breakdown["hydrology_riparian_moisture_floor_touches"] = int(hydro.get("riparian_moisture_floor_touches", 0));
    breakdown["hydrology_moisture_response_alpha"] = double(hydro.get("moisture_response_alpha", 0.0));
    breakdown["hydrology_river_moisture_max_delta"] = double(hydro.get("river_moisture_max_delta", 0.0));
    breakdown["hydrology_riparian_moisture_max_delta"] = double(hydro.get("riparian_moisture_max_delta", 0.0));
    breakdown["hydrology_flood_count"] = int(hydro.get("flood_count", hydro.get("flood_candidate_count", 0)));
    breakdown["hydrology_published_to_slot"] = true;
    return true;
}


// ─── SCHEDULE_GRAPH 静态表 ─────────────────────────────────────────────────
//
// Contract notes:
// - Nodes here are native compute/publish nodes, not proof of full DOTS authority.
// - runtime_hydrology runs only when MapGenerator adds runtime_hydrology_knobs.
//   In that mode stage_b_after_hydrology is used and the old stage_b key is
//   intentionally omitted from the bundle so hydrology can see weather output
//   before stage-b reads water-balance / soil slots.
// - visual uploads are not graph nodes; C++ may emit visual_dirty_intents, but
//   Godot/GDScript still owns ImageTexture and renderer object boundaries.
const SystemNode SCHEDULE_GRAPH[] = {
    {"climate_pass_a",       "climate_pass_a_struct",       "climate_pass_a",
     SYS_MASK_CLIMATE | SYS_MASK_TERRAIN, SYS_MASK_CLIMATE,
     &DCWorldExt::_exec_node_climate_pass_a},
    {"climate_pass_b",       "climate_pass_b_knobs",        "climate_pass_b",
     SYS_MASK_CLIMATE | SYS_MASK_TERRAIN, SYS_MASK_CLIMATE,
     &DCWorldExt::_exec_node_climate_pass_b},
    {"ocean_water",          "ocean_water_knobs",           "ocean_water",
     SYS_MASK_CLIMATE | SYS_MASK_OCEAN, SYS_MASK_OCEAN,
     &DCWorldExt::_exec_node_ocean_water},
    {"ocean_land",           "ocean_land_knobs",            "ocean_land",
     SYS_MASK_CLIMATE | SYS_MASK_OCEAN | SYS_MASK_TERRAIN, SYS_MASK_CLIMATE | SYS_MASK_OCEAN,
     &DCWorldExt::_exec_node_ocean_land},
    {"wind_air",             "wind_air_knobs",              "wind_air",
     SYS_MASK_CLIMATE | SYS_MASK_TERRAIN, SYS_MASK_CLIMATE,
     &DCWorldExt::_exec_node_wind_air},
    {"wind_surface",         "wind_surface_knobs",          "wind_surface",
     SYS_MASK_CLIMATE | SYS_MASK_TERRAIN, SYS_MASK_CLIMATE,
     &DCWorldExt::_exec_node_wind_surface},
    {"sea_ice",              "sea_ice_knobs",               "sea_ice",
     SYS_MASK_CLIMATE | SYS_MASK_OCEAN | SYS_MASK_TERRAIN, SYS_MASK_CLIMATE | SYS_MASK_SEA_ICE | SYS_MASK_TERRAIN,
     &DCWorldExt::_exec_node_sea_ice},
    {"transpiration",        "transpiration_knobs",         "transpiration",
     SYS_MASK_CLIMATE | SYS_MASK_TERRAIN, SYS_MASK_CLIMATE,
     &DCWorldExt::_exec_node_transpiration},
    {"albedo",               "albedo_knobs",                "albedo",
     SYS_MASK_CLIMATE | SYS_MASK_TERRAIN, SYS_MASK_STAGE_B,
     &DCWorldExt::_exec_node_albedo},
    {"vegetation_dynamics",  "vegetation_dynamics_knobs",   "vegetation_dynamics",
     SYS_MASK_CLIMATE | SYS_MASK_TERRAIN, SYS_MASK_STAGE_B,
     &DCWorldExt::_exec_node_vegetation_dynamics},
    {"climate_feedback",     "climate_feedback_knobs",      "climate_feedback",
     SYS_MASK_CLIMATE | SYS_MASK_TERRAIN, SYS_MASK_STAGE_B,
     &DCWorldExt::_exec_node_climate_feedback},
    {"stage_b",              "stage_b_knobs",               "stage_b",
     SYS_MASK_CLIMATE | SYS_MASK_TERRAIN | SYS_MASK_STAGE_B, SYS_MASK_CLIMATE | SYS_MASK_STAGE_B,
     &DCWorldExt::_exec_node_stage_b},
    {"weather",              "weather_knobs",               "weather",
     SYS_MASK_CLIMATE | SYS_MASK_WEATHER | SYS_MASK_TERRAIN, SYS_MASK_WEATHER | SYS_MASK_STAGE_B,
     &DCWorldExt::_exec_node_weather},
    {"runtime_hydrology",    "runtime_hydrology_knobs",     "runtime_hydrology",
     SYS_MASK_WEATHER | SYS_MASK_TERRAIN | SYS_MASK_HYDROLOGY, SYS_MASK_HYDROLOGY | SYS_MASK_STAGE_B,
     &DCWorldExt::_exec_node_runtime_hydrology},
    {"stage_b_after_hydrology", "stage_b_after_hydrology_knobs", "stage_b",
     SYS_MASK_CLIMATE | SYS_MASK_TERRAIN | SYS_MASK_STAGE_B | SYS_MASK_HYDROLOGY, SYS_MASK_CLIMATE | SYS_MASK_STAGE_B,
     &DCWorldExt::_exec_node_stage_b_after_hydrology},
};
const int SCHEDULE_GRAPH_SIZE = sizeof(SCHEDULE_GRAPH) / sizeof(SystemNode);

// ─── dispatch loop ────────────────────────────────────────────────────────
int dispatch_system_schedule(DCWorldExt* self,
                             Dictionary& bundle,
                             const Dictionary& tick_knobs,
                             Dictionary& breakdown,
                             bool& out_any_pass_ran,
                             const char*& out_fail_stage) {
    out_any_pass_ran = false;
    out_fail_stage = nullptr;
    for (int i = 0; i < SCHEDULE_GRAPH_SIZE; ++i) {
        const SystemNode& node = SCHEDULE_GRAPH[i];
        if (!bundle.has(node.bundle_key)) {
            continue;
        }
        const bool ok = (self->*node.exec_fn)(bundle, tick_knobs, breakdown);
        if (!ok) {
            out_fail_stage = node.fail_stage;
            return -1;
        }
        out_any_pass_ran = true;
    }
    return 0;
}

} // namespace pk
