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
#include <godot_cpp/variant/variant.hpp>

namespace pk {

using godot::Dictionary;
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

// ─── 11 个节点 exec_fn ────────────────────────────────────────────────────
// 顺序与 world_ext.cpp line 960-1063 严格一致。

bool DCWorldExt::_exec_node_climate_pass_a(const Dictionary& bundle,
                                            const Dictionary& tick_knobs,
                                            Dictionary& breakdown) {
    Dictionary cp_struct = as_dict_local(bundle["climate_pass_a_struct"]);
    const double phase = double(tick_knobs.get("season_phase", 0.0));
    const double season_phase = double(tick_knobs.get("season_phase", phase));
    const double ms = run_climate_pass_a(cp_struct, phase, season_phase);
    if (ms < 0.0) return false;
    breakdown["pass_a_ms"] = ms;
    breakdown["climate_ms"] = double(breakdown.get("climate_ms", 0.0)) + ms;
    return true;
}

bool DCWorldExt::_exec_node_ocean_water(const Dictionary& bundle,
                                         const Dictionary& /*tick_knobs*/,
                                         Dictionary& breakdown) {
    Dictionary water_knobs = as_dict_local(bundle["ocean_water_knobs"]);
    const double ms = run_ocean_water_pass(water_knobs);
    if (ms < 0.0) return false;
    if (water_knobs.has("anomaly_out") && bundle.has("ocean_land_knobs")) {
        Dictionary land_knobs = as_dict_local(bundle["ocean_land_knobs"]);
        land_knobs["anomaly_inout"] = water_knobs["anomaly_out"];
    }
    breakdown["ocean_water_ms"] = ms;
    breakdown["ocean_ms"] = double(breakdown.get("ocean_ms", 0.0)) + ms;
    return true;
}

bool DCWorldExt::_exec_node_ocean_land(const Dictionary& bundle,
                                        const Dictionary& /*tick_knobs*/,
                                        Dictionary& breakdown) {
    const double ms = run_ocean_land_pass(as_dict_local(bundle["ocean_land_knobs"]));
    if (ms < 0.0) return false;
    breakdown["ocean_land_ms"] = ms;
    breakdown["ocean_ms"] = double(breakdown.get("ocean_ms", 0.0)) + ms;
    return true;
}

bool DCWorldExt::_exec_node_climate_pass_b(const Dictionary& bundle,
                                            const Dictionary& /*tick_knobs*/,
                                            Dictionary& breakdown) {
    const double ms = run_climate_pass_b(as_dict_local(bundle["climate_pass_b_knobs"]));
    if (ms < 0.0) return false;
    breakdown["pass_b_ms"] = ms;
    breakdown["climate_ms"] = double(breakdown.get("climate_ms", 0.0)) + ms;
    return true;
}

bool DCWorldExt::_exec_node_sea_ice(const Dictionary& bundle,
                                     const Dictionary& tick_knobs,
                                     Dictionary& breakdown) {
    const float phase = float(tick_knobs.get("season_phase", 0.0));
    const double ms = run_sea_ice_daily_pass(as_dict_local(bundle["sea_ice_knobs"]), phase);
    if (ms < 0.0) return false;
    breakdown["sea_ice_ms"] = ms;
    breakdown["climate_ms"] = double(breakdown.get("climate_ms", 0.0)) + ms;
    return true;
}

bool DCWorldExt::_exec_node_transpiration(const Dictionary& bundle,
                                           const Dictionary& /*tick_knobs*/,
                                           Dictionary& breakdown) {
    const double ms = run_transpiration_pass(as_dict_local(bundle["transpiration_knobs"]));
    if (ms < 0.0) return false;
    breakdown["transp_ms"] = ms;
    breakdown["climate_ms"] = double(breakdown.get("climate_ms", 0.0)) + ms;
    return true;
}

bool DCWorldExt::_exec_node_albedo(const Dictionary& bundle,
                                    const Dictionary& /*tick_knobs*/,
                                    Dictionary& breakdown) {
    const double ms = run_albedo_pass(as_dict_local(bundle["albedo_knobs"]));
    if (ms < 0.0) return false;
    breakdown["albedo_ms"] = ms;
    breakdown["stage_b_ms"] = double(breakdown.get("stage_b_ms", 0.0)) + ms;
    return true;
}

bool DCWorldExt::_exec_node_vegetation_dynamics(const Dictionary& bundle,
                                                 const Dictionary& /*tick_knobs*/,
                                                 Dictionary& breakdown) {
    const double ms = run_vegetation_dynamics_pass(as_dict_local(bundle["vegetation_dynamics_knobs"]));
    if (ms < 0.0) return false;
    breakdown["veg_dyn_ms"] = ms;
    breakdown["stage_b_ms"] = double(breakdown.get("stage_b_ms", 0.0)) + ms;
    return true;
}

bool DCWorldExt::_exec_node_climate_feedback(const Dictionary& bundle,
                                              const Dictionary& /*tick_knobs*/,
                                              Dictionary& breakdown) {
    const double ms = run_climate_feedback_pass(as_dict_local(bundle["climate_feedback_knobs"]));
    if (ms < 0.0) return false;
    breakdown["feedback_ms"] = ms;
    breakdown["stage_b_ms"] = double(breakdown.get("stage_b_ms", 0.0)) + ms;
    return true;
}

bool DCWorldExt::_exec_node_stage_b(const Dictionary& bundle,
                                     const Dictionary& /*tick_knobs*/,
                                     Dictionary& breakdown) {
    Dictionary stage_b_knobs = as_dict_local(bundle["stage_b_knobs"]);
    const double ms = run_stage_b_pass(stage_b_knobs);
    if (ms < 0.0) return false;
    breakdown["stage_b_ms"] = double(breakdown.get("stage_b_ms", 0.0)) + ms;
    // stage_b 内嵌跑了 albedo / veg_dyn / feedback / succession，把 stage_b_knobs
    // 里 pass 自己写回的字段刷到 breakdown（与 line 1041-1048 对齐）
    breakdown["albedo_ms"] = stage_b_knobs.get("albedo_ms", breakdown.get("albedo_ms", 0.0));
    breakdown["veg_dyn_ms"] = stage_b_knobs.get("veg_dyn_ms", breakdown.get("veg_dyn_ms", 0.0));
    breakdown["feedback_ms"] = stage_b_knobs.get("feedback_ms", breakdown.get("feedback_ms", 0.0));
    if (stage_b_knobs.has("succession_indices")) {
        breakdown["succession_indices"] = stage_b_knobs["succession_indices"];
        breakdown["succession_to_veg"] = stage_b_knobs["succession_to_veg"];
        breakdown["stat_succession_count"] = stage_b_knobs.get("stat_succession_count", 0);
    }
    return true;
}

bool DCWorldExt::_exec_node_weather(const Dictionary& bundle,
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

// ─── SCHEDULE_GRAPH 静态表 ─────────────────────────────────────────────────
const SystemNode SCHEDULE_GRAPH[] = {
    {"climate_pass_a",       "climate_pass_a_struct",       "climate_pass_a",
     SYS_MASK_CLIMATE | SYS_MASK_TERRAIN, SYS_MASK_CLIMATE,
     &DCWorldExt::_exec_node_climate_pass_a},
    {"ocean_water",          "ocean_water_knobs",           "ocean_water",
     SYS_MASK_CLIMATE | SYS_MASK_OCEAN, SYS_MASK_OCEAN,
     &DCWorldExt::_exec_node_ocean_water},
    {"ocean_land",           "ocean_land_knobs",            "ocean_land",
     SYS_MASK_CLIMATE | SYS_MASK_OCEAN | SYS_MASK_TERRAIN, SYS_MASK_CLIMATE | SYS_MASK_OCEAN,
     &DCWorldExt::_exec_node_ocean_land},
    {"climate_pass_b",       "climate_pass_b_knobs",        "climate_pass_b",
     SYS_MASK_CLIMATE | SYS_MASK_TERRAIN, SYS_MASK_CLIMATE,
     &DCWorldExt::_exec_node_climate_pass_b},
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
};
const int SCHEDULE_GRAPH_SIZE = sizeof(SCHEDULE_GRAPH) / sizeof(SystemNode);

// ─── dispatch loop ────────────────────────────────────────────────────────
int dispatch_system_schedule(DCWorldExt* self,
                             const Dictionary& bundle,
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
