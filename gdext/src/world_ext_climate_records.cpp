#include "world_ext.h"
#include "runtime_climate_weather_input.h"
#include "runtime_climate_passes.h"
#include "world_ext_internal.h"

#include <godot_cpp/variant/utility_functions.hpp>
#include <chrono>
#include <cmath>
#include <limits>
#include <algorithm>
#include <cstdint>
#include <cstring>
#include <memory>
#include <vector>

namespace pk {

using namespace godot;

// Production climate inputs are captured at their real sync pass boundaries.
// Async task state and workers are owned by world_ext_climate_async.cpp.

#include "world_ext_climate_records_section_pass_inputs.inc"


// ─── Weather Hot-Path C++ 化（plan/weather-hotpath-cpp）─────────────────────
//
// dist：_distribute_weather_field_to_cells C++ 化（任务 4 实装）
// summary：_build_field_summary_fronts C++ 化（任务 7 实装）
//
// 本段（任务 2）只搭骨架：
//   - 注册函数名与签名稳定，让 GDScript 端 has_method + 签名 arg-count
//     检测能识别新方法；
//   - elapsed_ms 返回 -1.0 → caller 永远走 GDScript fallback；
//   - 持久化状态容器先 lazy alloc 占位（任务 7 实装时填）。
// ───────────────────────────────────────────────────────────────────────────

// 内部持久化状态结构（仅 .cpp 可见）已在文件顶部 pk 命名空间声明
// （PrevSummarySeed / WeatherSummaryState）；本匿名 namespace 仅提供 helper。
namespace {

// 取/创建 opaque state（lazy alloc）。caller 不持有所有权。
inline WeatherSummaryState *get_or_create_summary_state(void *&opaque) {
    if (opaque == nullptr) {
        opaque = new WeatherSummaryState();
    }
    return static_cast<WeatherSummaryState *>(opaque);
}

inline void destroy_summary_state(void *&opaque) {
    if (opaque != nullptr) {
        delete static_cast<WeatherSummaryState *>(opaque);
        opaque = nullptr;
    }
}

} // namespace

Dictionary DCWorldExt::run_weather_distribute_pass(const Dictionary &knobs) {
    using godot::StringName;
    using godot::PackedFloat32Array;
    using godot::PackedInt32Array;
    using godot::PackedByteArray;

    Dictionary out;
    out["elapsed_ms"] = -1.0;
    out["cover_dirty"] = false;
    out["changed_cells"] = PackedInt32Array();

    auto diag = [&](const char *why) {
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_weather_distribute_pass: ", why,
            " — fallback to GDScript");
    };

    if (!_bound) { diag("not _bound"); return out; }

    auto t0 = std::chrono::high_resolution_clock::now();

    // ─── SoA slot resolve（一次性查 component_id）────────────────────────
    const int sid_temp        = component_id(StringName("cell_temp"));
    const int sid_moisture    = component_id(StringName("cell_moisture"));
    const int sid_snow_cover  = component_id(StringName("cell_snow_cover"));
    const int sid_snowpack    = component_id(StringName("cell_snowpack"));
    const int sid_water_bal   = component_id(StringName("cell_water_balance_30d"));
    const int sid_soil_moist  = component_id(StringName("cell_soil_moisture"));
    const int sid_heat_input  = component_id(StringName("cell_heat_input"));
    const int sid_cover       = component_id(StringName("cell_cover"));
    const int sid_landform    = component_id(StringName("cell_landform"));
    const int sid_terrain     = component_id(StringName("cell_terrain"));
    const int sid_elevation   = component_id(StringName("cell_elevation"));
    const int sid_w_intens    = component_id(StringName("cell_weather_intensity"));
    const int sid_w_precip    = component_id(StringName("cell_weather_precip"));
    const int sid_w_type      = component_id(StringName("cell_weather_type"));
    const int sid_w_finit     = component_id(StringName("cell_weather_field_init"));
    if (sid_temp     < 0 || sid_moisture  < 0 || sid_snow_cover < 0 ||
        sid_snowpack < 0 || sid_water_bal < 0 || sid_soil_moist < 0 ||
        sid_heat_input < 0 || sid_cover   < 0 ||
        sid_landform < 0 || sid_terrain  < 0 || sid_elevation < 0 || sid_w_intens  < 0 ||
        sid_w_precip < 0 || sid_w_type    < 0 || sid_w_finit   < 0) {
        diag("missing slot id (some weather/cover/landform component not bound)");
        return out;
    }

    // ─── knobs 校验 + 拉取 ──────────────────────────────────────────────
    static const char * const required_keys[] = {
        "n_cells", "snow_min_intensity",
        "snow_freeze_t", "snow_melt_t", "snow_intensity_for_snowing",
        "snow_accum_days_req",
        "flood_heavy_intensity", "flood_heavy_precip",
        "flood_lowland_intensity", "flood_lowland_elev", "flood_lowland_moisture",
        "wt_clear", "cv_snow", "cv_none", "cv_flooding",
        "accumulated_snow_days", "pre_snow_cover",
        "temp_delta_arr", "moisture_delta_arr",
        "can_form_snow_arr", "can_form_flood_arr",
    };
    for (const char *k : required_keys) {
        if (!knobs.has(k)) {
            UtilityFunctions::push_warning(
                "[DCWorldExt] run_weather_distribute_pass: missing key '", k, "'");
            return out;
        }
    }

    // 标量收进 POD 结构体。span / band 的下限保护不在这里做 ——
    // weather_distribute_pure 自己按 cover_low/full 与 band 推，避免两份公式。
    pk_async_climate::WeatherDistributeKnobs wdk;
    const int n_cells = int(knobs["n_cells"]);
    wdk.n_cells = n_cells;
    wdk.snow_min_intensity = float(knobs["snow_min_intensity"]);
    wdk.snow_freeze_t = float(knobs["snow_freeze_t"]);
    wdk.snow_melt_t = float(knobs["snow_melt_t"]);
    wdk.snow_intensity_snow = float(knobs["snow_intensity_for_snowing"]);
    wdk.snow_accum_days_req = int(knobs["snow_accum_days_req"]);
    wdk.flood_heavy_int = float(knobs["flood_heavy_intensity"]);
    wdk.flood_heavy_pre = float(knobs["flood_heavy_precip"]);
    wdk.flood_low_int = float(knobs["flood_lowland_intensity"]);
    wdk.flood_low_elev = float(knobs["flood_lowland_elev"]);
    wdk.flood_low_moist = float(knobs["flood_lowland_moisture"]);
    wdk.wt_clear = int(knobs["wt_clear"]);
    wdk.cv_snow = int(knobs["cv_snow"]);
    wdk.cv_none = int(knobs["cv_none"]);
    wdk.cv_flooding = int(knobs["cv_flooding"]);
    wdk.snowpack_accum_gain = knobs.has("snowpack_accum_gain")
        ? float(knobs["snowpack_accum_gain"]) : 0.10f;
    wdk.snowpack_melt_temp_gain = knobs.has("snowpack_melt_temp_gain")
        ? float(knobs["snowpack_melt_temp_gain"]) : 0.22f;
    wdk.snowpack_melt_sun_gain = knobs.has("snowpack_melt_sun_gain")
        ? float(knobs["snowpack_melt_sun_gain"]) : 0.12f;
    wdk.snowpack_cover_low = knobs.has("snowpack_cover_low")
        ? float(knobs["snowpack_cover_low"]) : 0.05f;
    wdk.snowpack_cover_full = knobs.has("snowpack_cover_full")
        ? float(knobs["snowpack_cover_full"]) : 0.32f;
    wdk.snowline_temp_threshold = knobs.has("snowline_temp_threshold")
        ? float(knobs["snowline_temp_threshold"]) : 0.24f;
    wdk.snowline_band = knobs.has("snowline_band") ? float(knobs["snowline_band"]) : 0.22f;
    float weather_temp_anomaly_cap = knobs.has("weather_temp_anomaly_cap")
        ? float(knobs["weather_temp_anomaly_cap"]) : 0.025f;
    if (weather_temp_anomaly_cap < 0.0f) weather_temp_anomaly_cap = 0.0f;
    else if (weather_temp_anomaly_cap > 0.10f) weather_temp_anomaly_cap = 0.10f;
    wdk.weather_temp_anomaly_cap = weather_temp_anomaly_cap;
    const bool direct_moisture_enabled =
        bool(knobs.get("weather_direct_moisture_enabled", false));
    wdk.direct_moisture_enabled = direct_moisture_enabled;

    PackedInt32Array  acc_snow_days  = knobs["accumulated_snow_days"];
    PackedInt32Array  pre_snow_cover = knobs["pre_snow_cover"];
    PackedFloat32Array temp_delta_arr   = knobs["temp_delta_arr"];
    PackedFloat32Array moist_delta_arr  = knobs["moisture_delta_arr"];
    PackedByteArray   cfs_arr         = knobs["can_form_snow_arr"];
    PackedByteArray   cff_arr         = knobs["can_form_flood_arr"];

    if (n_cells <= 0) { diag("n_cells <= 0"); return out; }
    if (acc_snow_days.size() != n_cells || pre_snow_cover.size() != n_cells) {
        diag("acc_snow_days / pre_snow_cover size != n_cells");
        return out;
    }
    if (temp_delta_arr.size() != 8 || moist_delta_arr.size() != 8 ||
        cfs_arr.size() != 8 || cff_arr.size() != 8) {
        diag("WeatherType profile arrays must be length 8");
        return out;
    }

    // ─── SoA 直接走 _slots[id].arr_f32/arr_u8.ptrw（避免 local copy 触发 CoW
    // detach 把本地数据脱离 _slots）。读端用 ptr() 同样直接走 _slots。
    // 写端最后调 _flush_slot_to_map(sid) 把 CoW-detach 后的新 buffer 推回
    // GDScript MapData property（与 F.1 / F.2 / F.3 等同模式）。──────────────
    Slot &s_temp     = _slots.write[sid_temp];
    Slot &s_moist    = _slots.write[sid_moisture];
    Slot &s_snow_cov = _slots.write[sid_snow_cover];
    Slot &s_snowpack = _slots.write[sid_snowpack];
    Slot &s_waterbal = _slots.write[sid_water_bal];
    Slot &s_soil     = _slots.write[sid_soil_moist];
    const Slot &s_heat = _slots[sid_heat_input];
    Slot &s_cover    = _slots.write[sid_cover];
    const Slot &s_lf       = _slots[sid_landform];
    const Slot &s_terrain  = _slots[sid_terrain];
    const Slot &s_elev     = _slots[sid_elevation];
    const Slot &s_w_int    = _slots[sid_w_intens];
    const Slot &s_w_pre    = _slots[sid_w_precip];
    const Slot &s_w_typ    = _slots[sid_w_type];
    const Slot &s_w_fin    = _slots[sid_w_finit];

    if (s_temp.arr_f32.size() < n_cells || s_moist.arr_f32.size() < n_cells ||
        s_snow_cov.arr_f32.size() < n_cells || s_snowpack.arr_f32.size() < n_cells ||
        s_waterbal.arr_f32.size() < n_cells || s_soil.arr_f32.size() < n_cells ||
        s_heat.arr_f32.size() < n_cells ||
        s_cover.arr_u8.size() < n_cells || s_lf.arr_u8.size() < n_cells ||
        s_terrain.arr_u8.size() < n_cells ||
        s_elev.arr_f32.size() < n_cells || s_w_int.arr_f32.size() < n_cells ||
        s_w_pre.arr_f32.size() < n_cells || s_w_typ.arr_u8.size() < n_cells ||
        s_w_fin.arr_u8.size() < n_cells) {
        diag("SoA size < n_cells");
        return out;
    }

    // ─── ptrw / ptr ────────────────────────────────────────────────────
    // 四张剖面表拷进 knobs：它们是 8 项定长表，进 POD 结构体后 worker 不必再持有
    // Godot PackedArray。长度已在上面校验过恰好是 8。
    std::memcpy(wdk.temp_delta, temp_delta_arr.ptr(), 8 * sizeof(float));
    std::memcpy(wdk.moist_delta, moist_delta_arr.ptr(), 8 * sizeof(float));
    std::memcpy(wdk.can_form_snow, cfs_arr.ptr(), 8);
    std::memcpy(wdk.can_form_flood, cff_arr.ptr(), 8);

    pk_async_climate::WeatherDistributeLanes wdl;
    wdl.temp = s_temp.arr_f32.ptrw();
    wdl.moisture = s_moist.arr_f32.ptrw();
    wdl.snow_cover = s_snow_cov.arr_f32.ptrw();
    wdl.snowpack = s_snowpack.arr_f32.ptrw();
    wdl.water_balance_30d = s_waterbal.arr_f32.ptrw();
    wdl.soil_moisture = s_soil.arr_f32.ptrw();
    wdl.cover = s_cover.arr_u8.ptrw();
    wdl.landform = s_lf.arr_u8.ptr();
    wdl.terrain = s_terrain.arr_u8.ptr();
    wdl.elevation = s_elev.arr_f32.ptr();
    wdl.heat = s_heat.arr_f32.ptr();
    wdl.weather_intensity = s_w_int.arr_f32.ptr();
    wdl.weather_precip = s_w_pre.arr_f32.ptr();
    wdl.weather_type = s_w_typ.arr_u8.ptr();
    wdl.weather_field_init = s_w_fin.arr_u8.ptr();

    pk_async_climate::WeatherDistributeState wds;
    wds.accumulated_snow_days = acc_snow_days.ptrw();
    wds.pre_snow_cover = pre_snow_cover.ptrw();

    // 数值核心已抽成共享纯内核 pk_async_climate::weather_distribute_pure，那几个
    // 局部 lambda 也跟着进去了。这里只留 Godot 侧的装配、记录与 flush。
    // 记录必须在内核之前：temp / moisture / snowpack / cover / 两条积雪计数全是
    // in/out，跑完再记就变成记结果。
    record_production_weather_distribute_input(wdk, wdl, wds, n_cells);
    pk_async_climate::WeatherDistributeEmit wde;
    pk_async_climate::weather_distribute_pure(wdk, wdl, wds, wde);
    PackedInt32Array changed_cells;
    if (!wde.changed_cells.empty()) {
        changed_cells.resize(int(wde.changed_cells.size()));
        std::memcpy(changed_cells.ptrw(), wde.changed_cells.data(),
                    wde.changed_cells.size() * sizeof(int32_t));
    }
    const bool cover_dirty = wde.cover_dirty;

    // ─── §11.2 flush：把 CoW-detach 后的 temp/moisture/cover 推回 GDScript
    // MapData property（与 F.1 / F.2 等同模式）。──────────────────────────
    _flush_slot_to_map(sid_temp);
    if (direct_moisture_enabled && !bool(knobs.get("defer_visible_publish", false))) {
        _flush_slot_to_map(sid_moisture);
    }
    _flush_slot_to_map(sid_snow_cover);
    _flush_slot_to_map(sid_snowpack);
    _flush_slot_to_map(sid_water_bal);
    _flush_slot_to_map(sid_soil_moist);
    _flush_slot_to_map(sid_cover);
    out["moisture_written"] = direct_moisture_enabled;

    // ─── 把改写后的 PackedInt32Array 通过 out Dictionary 返回（PackedArray ptrw
    // 触发 CoW 后会重新分配 buffer，本地 acc_snow_days / pre_snow_cover 持有新
    // buffer；knobs Dictionary 里仍是旧 buffer ref。所以必须放进 out 让 caller 取）─
    auto t1 = std::chrono::high_resolution_clock::now();
    const double elapsed = std::chrono::duration<double, std::milli>(t1 - t0).count();
    out["elapsed_ms"] = elapsed;
    out["cover_dirty"] = cover_dirty;
    out["changed_cells"] = changed_cells;
    out["accumulated_snow_days"] = acc_snow_days;
    out["pre_snow_cover"] = pre_snow_cover;
    return out;
}

#include "world_ext_climate_records_section_weather_fronts.inc"

} // namespace pk
