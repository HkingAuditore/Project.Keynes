// ─── Phase A.3（dots-total-cpp roadmap）：KnobsHandle 实现 ────────────────
// dirty-write setter + cached Dictionary 输出。所有 setter 内部走"只在值真正
// 变化时拉 dirty"逻辑（避免 ClimateProfile 推送同值时无意义重建）。

#include "knobs_struct.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

namespace pk {

using namespace godot;

KnobsHandle::KnobsHandle() {
    // 缓存 Dict 初始为空；首次 to_*_knobs_dict 走 all-dirty 路径填充。
}

// ─── field 段 ───────────────────────────────────────────────────────────
void KnobsHandle::set_field_scalars(
        float world_bounds_pos_y, float world_bounds_size_y,
        bool apply_convergence_boost, float hex_size,
        int field_advect_steps, float field_diffusion,
        float field_condensation_gain, float field_orographic_lift_gain,
        float field_convergence_gain, float field_ocean_evap_gain,
        float field_precip_decay, float season_phase) {
    // 任一字段变更即拉 field dirty。这里走批量 setter 是为了减少 GDScript
    // 跨语言调用次数（一次调用喂 12 个字段 vs 12 次单字段 setter）。
    bool changed = false;
    if (_k.world_bounds_pos_y != world_bounds_pos_y) { _k.world_bounds_pos_y = world_bounds_pos_y; changed = true; }
    if (_k.world_bounds_size_y != world_bounds_size_y) { _k.world_bounds_size_y = world_bounds_size_y; changed = true; }
    if (_k.apply_convergence_boost != apply_convergence_boost) { _k.apply_convergence_boost = apply_convergence_boost; changed = true; }
    if (_k.hex_size != hex_size) { _k.hex_size = hex_size; changed = true; }
    if (_k.field_advect_steps != field_advect_steps) { _k.field_advect_steps = field_advect_steps; changed = true; }
    if (_k.field_diffusion != field_diffusion) { _k.field_diffusion = field_diffusion; changed = true; }
    if (_k.field_condensation_gain != field_condensation_gain) { _k.field_condensation_gain = field_condensation_gain; changed = true; }
    if (_k.field_orographic_lift_gain != field_orographic_lift_gain) { _k.field_orographic_lift_gain = field_orographic_lift_gain; changed = true; }
    if (_k.field_convergence_gain != field_convergence_gain) { _k.field_convergence_gain = field_convergence_gain; changed = true; }
    if (_k.field_ocean_evap_gain != field_ocean_evap_gain) { _k.field_ocean_evap_gain = field_ocean_evap_gain; changed = true; }
    if (_k.field_precip_decay != field_precip_decay) { _k.field_precip_decay = field_precip_decay; changed = true; }
    if (_k.season_phase != season_phase) { _k.season_phase = season_phase; changed = true; }
    if (changed) _field_dirty = true;
}

// ─── distribute 段 ─────────────────────────────────────────────────────
void KnobsHandle::set_distribute_scalars(
        float snow_min_intensity, float snow_freeze_t, float snow_melt_t,
        float snow_intensity_for_snowing, int snow_accum_days_req,
        float flood_heavy_intensity, float flood_heavy_precip,
        float flood_lowland_intensity, float flood_lowland_elev,
        float flood_lowland_moisture,
        int wt_clear, int cv_snow, int cv_none, int cv_flooding) {
    bool changed = false;
    if (_k.snow_min_intensity != snow_min_intensity) { _k.snow_min_intensity = snow_min_intensity; changed = true; }
    if (_k.snow_freeze_t != snow_freeze_t) { _k.snow_freeze_t = snow_freeze_t; changed = true; }
    if (_k.snow_melt_t != snow_melt_t) { _k.snow_melt_t = snow_melt_t; changed = true; }
    if (_k.snow_intensity_for_snowing != snow_intensity_for_snowing) { _k.snow_intensity_for_snowing = snow_intensity_for_snowing; changed = true; }
    if (_k.snow_accum_days_req != snow_accum_days_req) { _k.snow_accum_days_req = snow_accum_days_req; changed = true; }
    if (_k.flood_heavy_intensity != flood_heavy_intensity) { _k.flood_heavy_intensity = flood_heavy_intensity; changed = true; }
    if (_k.flood_heavy_precip != flood_heavy_precip) { _k.flood_heavy_precip = flood_heavy_precip; changed = true; }
    if (_k.flood_lowland_intensity != flood_lowland_intensity) { _k.flood_lowland_intensity = flood_lowland_intensity; changed = true; }
    if (_k.flood_lowland_elev != flood_lowland_elev) { _k.flood_lowland_elev = flood_lowland_elev; changed = true; }
    if (_k.flood_lowland_moisture != flood_lowland_moisture) { _k.flood_lowland_moisture = flood_lowland_moisture; changed = true; }
    if (_k.wt_clear != wt_clear) { _k.wt_clear = wt_clear; changed = true; }
    if (_k.cv_snow != cv_snow) { _k.cv_snow = cv_snow; changed = true; }
    if (_k.cv_none != cv_none) { _k.cv_none = cv_none; changed = true; }
    if (_k.cv_flooding != cv_flooding) { _k.cv_flooding = cv_flooding; changed = true; }
    if (changed) _distribute_dirty = true;
}

void KnobsHandle::set_distribute_wt_tables(
        const PackedFloat32Array &temp_delta_arr,
        const PackedFloat32Array &moisture_delta_arr,
        const PackedByteArray &can_form_snow_arr,
        const PackedByteArray &can_form_flood_arr) {
    // WT LUT 是 8-长度 PackedArray，CoW 引用替换是 O(1)，不做逐字节比较
    // （比较开销 > 替换开销）。直接替换 + 拉 dirty。
    _k.dist_temp_delta_arr = temp_delta_arr;
    _k.dist_moisture_delta_arr = moisture_delta_arr;
    _k.dist_can_form_snow_arr = can_form_snow_arr;
    _k.dist_can_form_flood_arr = can_form_flood_arr;
    _distribute_dirty = true;
}

// ─── summary 段 ────────────────────────────────────────────────────────
void KnobsHandle::set_summary_scalars(
        int summary_limit, float intensity_enter, float intensity_hold,
        float merge_ratio, int merge_max_rounds,
        float radius_base, float radius_scale,
        bool drift_debug_log, int day_counter) {
    bool changed = false;
    if (_k.summary_limit != summary_limit) { _k.summary_limit = summary_limit; changed = true; }
    if (_k.intensity_enter != intensity_enter) { _k.intensity_enter = intensity_enter; changed = true; }
    if (_k.intensity_hold != intensity_hold) { _k.intensity_hold = intensity_hold; changed = true; }
    if (_k.merge_ratio != merge_ratio) { _k.merge_ratio = merge_ratio; changed = true; }
    if (_k.merge_max_rounds != merge_max_rounds) { _k.merge_max_rounds = merge_max_rounds; changed = true; }
    if (_k.radius_base != radius_base) { _k.radius_base = radius_base; changed = true; }
    if (_k.radius_scale != radius_scale) { _k.radius_scale = radius_scale; changed = true; }
    if (_k.drift_debug_log != drift_debug_log) { _k.drift_debug_log = drift_debug_log; changed = true; }
    if (_k.day_counter != day_counter) { _k.day_counter = day_counter; changed = true; }
    if (changed) _summary_dirty = true;
}

void KnobsHandle::set_day_counter(int day_counter) {
    // day_counter 每帧变化但只影响 summary Dict 一个 key，单字段细粒度入口避免
    // 整段全字段重发。
    if (_k.day_counter != day_counter) {
        _k.day_counter = day_counter;
        _summary_dirty = true;
    }
}

// ─── stage_b 段 ────────────────────────────────────────────────────────
void KnobsHandle::set_stage_b_scalars(
        int albedo_stride, int veg_dyn_stride, int feedback_stride,
        bool fast_slow_layering_enabled,
        float reference_albedo, float albedo_temp_gain,
        float snow_cover_albedo, int cover_snow_id, int cover_glacier_id,
        float vitality_change_rate, float compat_harshness,
        float vitality_low_threshold, float vitality_high_threshold,
        int succession_degrade_days, int succession_upgrade_days,
        int n_wt, int wt_clear_id, int veg_none_id,
        int wt_rain_id, int wt_storm_id, int wt_monsoon_id,
        int wt_blizzard_id, int wt_drought_id, int wt_heatwave_id,
        float weather_to_soil_gain, float weather_to_vegetation_gain,
        float feedback_per_day_clamp, float ocean_moisture_drift_gain) {
    bool changed = false;
    if (_k.albedo_stride != albedo_stride) { _k.albedo_stride = albedo_stride; changed = true; }
    if (_k.veg_dyn_stride != veg_dyn_stride) { _k.veg_dyn_stride = veg_dyn_stride; changed = true; }
    if (_k.feedback_stride != feedback_stride) { _k.feedback_stride = feedback_stride; changed = true; }
    if (_k.fast_slow_layering_enabled != fast_slow_layering_enabled) { _k.fast_slow_layering_enabled = fast_slow_layering_enabled; changed = true; }
    if (_k.reference_albedo != reference_albedo) { _k.reference_albedo = reference_albedo; changed = true; }
    if (_k.albedo_temp_gain != albedo_temp_gain) { _k.albedo_temp_gain = albedo_temp_gain; changed = true; }
    if (_k.snow_cover_albedo != snow_cover_albedo) { _k.snow_cover_albedo = snow_cover_albedo; changed = true; }
    if (_k.cover_snow_id != cover_snow_id) { _k.cover_snow_id = cover_snow_id; changed = true; }
    if (_k.cover_glacier_id != cover_glacier_id) { _k.cover_glacier_id = cover_glacier_id; changed = true; }
    if (_k.vitality_change_rate != vitality_change_rate) { _k.vitality_change_rate = vitality_change_rate; changed = true; }
    if (_k.compat_harshness != compat_harshness) { _k.compat_harshness = compat_harshness; changed = true; }
    if (_k.vitality_low_threshold != vitality_low_threshold) { _k.vitality_low_threshold = vitality_low_threshold; changed = true; }
    if (_k.vitality_high_threshold != vitality_high_threshold) { _k.vitality_high_threshold = vitality_high_threshold; changed = true; }
    if (_k.succession_degrade_days != succession_degrade_days) { _k.succession_degrade_days = succession_degrade_days; changed = true; }
    if (_k.succession_upgrade_days != succession_upgrade_days) { _k.succession_upgrade_days = succession_upgrade_days; changed = true; }
    if (_k.n_wt != n_wt) { _k.n_wt = n_wt; changed = true; }
    if (_k.wt_clear_id != wt_clear_id) { _k.wt_clear_id = wt_clear_id; changed = true; }
    if (_k.veg_none_id != veg_none_id) { _k.veg_none_id = veg_none_id; changed = true; }
    if (_k.wt_rain_id != wt_rain_id) { _k.wt_rain_id = wt_rain_id; changed = true; }
    if (_k.wt_storm_id != wt_storm_id) { _k.wt_storm_id = wt_storm_id; changed = true; }
    if (_k.wt_monsoon_id != wt_monsoon_id) { _k.wt_monsoon_id = wt_monsoon_id; changed = true; }
    if (_k.wt_blizzard_id != wt_blizzard_id) { _k.wt_blizzard_id = wt_blizzard_id; changed = true; }
    if (_k.wt_drought_id != wt_drought_id) { _k.wt_drought_id = wt_drought_id; changed = true; }
    if (_k.wt_heatwave_id != wt_heatwave_id) { _k.wt_heatwave_id = wt_heatwave_id; changed = true; }
    if (_k.weather_to_soil_gain != weather_to_soil_gain) { _k.weather_to_soil_gain = weather_to_soil_gain; changed = true; }
    if (_k.weather_to_vegetation_gain != weather_to_vegetation_gain) { _k.weather_to_vegetation_gain = weather_to_vegetation_gain; changed = true; }
    if (_k.feedback_per_day_clamp != feedback_per_day_clamp) { _k.feedback_per_day_clamp = feedback_per_day_clamp; changed = true; }
    if (_k.ocean_moisture_drift_gain != ocean_moisture_drift_gain) { _k.ocean_moisture_drift_gain = ocean_moisture_drift_gain; changed = true; }
    if (changed) _stage_b_dirty = true;
}

void KnobsHandle::set_stage_b_tables(
        const PackedFloat32Array &albedo_table,
        const PackedFloat32Array &vegdyn_ideal_temp_table,
        const PackedFloat32Array &vegdyn_ideal_moist_table,
        const PackedFloat32Array &vegdyn_temp_tol_table,
        const PackedFloat32Array &vegdyn_moist_tol_table,
        const PackedFloat32Array &vegdyn_weather_penalty_table,
        const PackedInt32Array &vegdyn_resistance_table,
        const PackedInt32Array &vegdyn_next_up_table,
        const PackedInt32Array &vegdyn_next_down_table) {
    _k.albedo_table = albedo_table;
    _k.vegdyn_ideal_temp_table = vegdyn_ideal_temp_table;
    _k.vegdyn_ideal_moist_table = vegdyn_ideal_moist_table;
    _k.vegdyn_temp_tol_table = vegdyn_temp_tol_table;
    _k.vegdyn_moist_tol_table = vegdyn_moist_tol_table;
    _k.vegdyn_weather_penalty_table = vegdyn_weather_penalty_table;
    _k.vegdyn_resistance_table = vegdyn_resistance_table;
    _k.vegdyn_next_up_table = vegdyn_next_up_table;
    _k.vegdyn_next_down_table = vegdyn_next_down_table;
    _stage_b_dirty = true;
}

void KnobsHandle::invalidate_all() {
    _field_dirty = true;
    _distribute_dirty = true;
    _summary_dirty = true;
    _stage_b_dirty = true;
}

// ─── to_*_knobs_dict 输出 ──────────────────────────────────────────────
Dictionary KnobsHandle::to_field_knobs_dict() {
    if (!_field_dirty) {
        // 稳态：直接复用缓存 Dict（CoW 引用 ++，零分配）
        return _cached_field_dict;
    }
    _field_dirty = false;
    _field_rebuild_count++;
    Dictionary d;
    d["world_bounds_pos_y"]         = _k.world_bounds_pos_y;
    d["world_bounds_size_y"]        = _k.world_bounds_size_y;
    d["apply_convergence_boost"]    = _k.apply_convergence_boost;
    d["hex_size"]                   = _k.hex_size;
    d["field_advect_steps"]         = _k.field_advect_steps;
    d["field_diffusion"]            = _k.field_diffusion;
    d["field_condensation_gain"]    = _k.field_condensation_gain;
    d["field_orographic_lift_gain"] = _k.field_orographic_lift_gain;
    d["field_convergence_gain"]     = _k.field_convergence_gain;
    d["field_ocean_evap_gain"]      = _k.field_ocean_evap_gain;
    d["field_precip_decay"]         = _k.field_precip_decay;
    d["season_phase"]               = _k.season_phase;
    _cached_field_dict = d;
    return d;
}

Dictionary KnobsHandle::to_distribute_knobs_dict() {
    if (!_distribute_dirty) {
        return _cached_distribute_dict;
    }
    _distribute_dirty = false;
    _distribute_rebuild_count++;
    Dictionary d;
    d["snow_min_intensity"]         = _k.snow_min_intensity;
    d["snow_freeze_t"]              = _k.snow_freeze_t;
    d["snow_melt_t"]                = _k.snow_melt_t;
    d["snow_intensity_for_snowing"] = _k.snow_intensity_for_snowing;
    d["snow_accum_days_req"]        = _k.snow_accum_days_req;
    d["flood_heavy_intensity"]      = _k.flood_heavy_intensity;
    d["flood_heavy_precip"]         = _k.flood_heavy_precip;
    d["flood_lowland_intensity"]    = _k.flood_lowland_intensity;
    d["flood_lowland_elev"]         = _k.flood_lowland_elev;
    d["flood_lowland_moisture"]     = _k.flood_lowland_moisture;
    d["wt_clear"]                   = _k.wt_clear;
    d["cv_snow"]                    = _k.cv_snow;
    d["cv_none"]                    = _k.cv_none;
    d["cv_flooding"]                = _k.cv_flooding;
    d["temp_delta_arr"]             = _k.dist_temp_delta_arr;
    d["moisture_delta_arr"]         = _k.dist_moisture_delta_arr;
    d["can_form_snow_arr"]          = _k.dist_can_form_snow_arr;
    d["can_form_flood_arr"]         = _k.dist_can_form_flood_arr;
    _cached_distribute_dict = d;
    return d;
}

Dictionary KnobsHandle::to_summary_knobs_dict() {
    if (!_summary_dirty) {
        return _cached_summary_dict;
    }
    _summary_dirty = false;
    _summary_rebuild_count++;
    Dictionary d;
    d["summary_limit"]    = _k.summary_limit;
    d["intensity_enter"]  = _k.intensity_enter;
    d["intensity_hold"]   = _k.intensity_hold;
    d["merge_ratio"]      = _k.merge_ratio;
    d["merge_max_rounds"] = _k.merge_max_rounds;
    d["radius_base"]      = _k.radius_base;
    d["radius_scale"]     = _k.radius_scale;
    d["wt_clear"]         = _k.wt_clear;
    d["drift_debug_log"]  = _k.drift_debug_log;
    d["day_counter"]      = _k.day_counter;
    _cached_summary_dict = d;
    return d;
}

Dictionary KnobsHandle::to_stage_b_knobs_dict() {
    if (!_stage_b_dirty) {
        return _cached_stage_b_dict;
    }
    _stage_b_dirty = false;
    _stage_b_rebuild_count++;
    Dictionary d;
    // ─── albedo 段 ──
    d["reference_albedo"]   = _k.reference_albedo;
    d["albedo_temp_gain"]   = _k.albedo_temp_gain;
    d["snow_cover_albedo"]  = _k.snow_cover_albedo;
    d["cover_snow_id"]      = _k.cover_snow_id;
    d["cover_glacier_id"]   = _k.cover_glacier_id;
    d["albedo_table"]       = _k.albedo_table;
    // ─── veg_dyn 段 ──
    d["vitality_change_rate"]     = _k.vitality_change_rate;
    d["compat_harshness"]         = _k.compat_harshness;
    d["low_threshold"]            = _k.vitality_low_threshold;
    d["high_threshold"]           = _k.vitality_high_threshold;
    d["succession_degrade_days"]  = _k.succession_degrade_days;
    d["succession_upgrade_days"]  = _k.succession_upgrade_days;
    d["n_wt"]                     = _k.n_wt;
    d["wt_clear_id"]              = _k.wt_clear_id;
    d["veg_none_id"]              = _k.veg_none_id;
    d["ideal_temp_table"]         = _k.vegdyn_ideal_temp_table;
    d["ideal_moist_table"]        = _k.vegdyn_ideal_moist_table;
    d["temp_tol_table"]           = _k.vegdyn_temp_tol_table;
    d["moist_tol_table"]          = _k.vegdyn_moist_tol_table;
    d["weather_penalty_table"]    = _k.vegdyn_weather_penalty_table;
    d["resistance_table"]         = _k.vegdyn_resistance_table;
    d["next_up_table"]            = _k.vegdyn_next_up_table;
    d["next_down_table"]          = _k.vegdyn_next_down_table;
    // ─── feedback 段 ──
    d["soil_gain"]                = _k.weather_to_soil_gain;
    d["veg_gain"]                 = _k.weather_to_vegetation_gain;
    d["per_day_clamp"]            = _k.feedback_per_day_clamp;
    d["ocean_drift_gain"]         = _k.ocean_moisture_drift_gain;
    d["wt_rain_id"]               = _k.wt_rain_id;
    d["wt_storm_id"]              = _k.wt_storm_id;
    d["wt_monsoon_id"]            = _k.wt_monsoon_id;
    d["wt_blizzard_id"]           = _k.wt_blizzard_id;
    d["wt_drought_id"]            = _k.wt_drought_id;
    d["wt_heatwave_id"]           = _k.wt_heatwave_id;
    // ─── 调度旋钮（call_index 由 caller 在外层 merge）──
    d["albedo_stride"]            = _k.albedo_stride;
    d["veg_dyn_stride"]           = _k.veg_dyn_stride;
    d["feedback_stride"]          = _k.feedback_stride;
    d["fast_slow_layering_enabled"] = _k.fast_slow_layering_enabled;
    _cached_stage_b_dict = d;
    return d;
}

// ─── ClassDB binding ──────────────────────────────────────────────────
void KnobsHandle::_bind_methods() {
    // field
    ClassDB::bind_method(D_METHOD("set_field_scalars",
        "world_bounds_pos_y", "world_bounds_size_y",
        "apply_convergence_boost", "hex_size",
        "field_advect_steps", "field_diffusion",
        "field_condensation_gain", "field_orographic_lift_gain",
        "field_convergence_gain", "field_ocean_evap_gain",
        "field_precip_decay", "season_phase"),
        &KnobsHandle::set_field_scalars);
    ClassDB::bind_method(D_METHOD("to_field_knobs_dict"), &KnobsHandle::to_field_knobs_dict);

    // distribute
    ClassDB::bind_method(D_METHOD("set_distribute_scalars",
        "snow_min_intensity", "snow_freeze_t", "snow_melt_t",
        "snow_intensity_for_snowing", "snow_accum_days_req",
        "flood_heavy_intensity", "flood_heavy_precip",
        "flood_lowland_intensity", "flood_lowland_elev",
        "flood_lowland_moisture",
        "wt_clear", "cv_snow", "cv_none", "cv_flooding"),
        &KnobsHandle::set_distribute_scalars);
    ClassDB::bind_method(D_METHOD("set_distribute_wt_tables",
        "temp_delta_arr", "moisture_delta_arr",
        "can_form_snow_arr", "can_form_flood_arr"),
        &KnobsHandle::set_distribute_wt_tables);
    ClassDB::bind_method(D_METHOD("to_distribute_knobs_dict"), &KnobsHandle::to_distribute_knobs_dict);

    // summary
    ClassDB::bind_method(D_METHOD("set_summary_scalars",
        "summary_limit", "intensity_enter", "intensity_hold",
        "merge_ratio", "merge_max_rounds",
        "radius_base", "radius_scale",
        "drift_debug_log", "day_counter"),
        &KnobsHandle::set_summary_scalars);
    ClassDB::bind_method(D_METHOD("set_day_counter", "day_counter"), &KnobsHandle::set_day_counter);
    ClassDB::bind_method(D_METHOD("to_summary_knobs_dict"), &KnobsHandle::to_summary_knobs_dict);

    // stage_b
    ClassDB::bind_method(D_METHOD("set_stage_b_scalars",
        "albedo_stride", "veg_dyn_stride", "feedback_stride",
        "fast_slow_layering_enabled",
        "reference_albedo", "albedo_temp_gain",
        "snow_cover_albedo", "cover_snow_id", "cover_glacier_id",
        "vitality_change_rate", "compat_harshness",
        "vitality_low_threshold", "vitality_high_threshold",
        "succession_degrade_days", "succession_upgrade_days",
        "n_wt", "wt_clear_id", "veg_none_id",
        "wt_rain_id", "wt_storm_id", "wt_monsoon_id",
        "wt_blizzard_id", "wt_drought_id", "wt_heatwave_id",
        "weather_to_soil_gain", "weather_to_vegetation_gain",
        "feedback_per_day_clamp", "ocean_moisture_drift_gain"),
        &KnobsHandle::set_stage_b_scalars);
    ClassDB::bind_method(D_METHOD("set_stage_b_tables",
        "albedo_table",
        "vegdyn_ideal_temp_table", "vegdyn_ideal_moist_table",
        "vegdyn_temp_tol_table", "vegdyn_moist_tol_table",
        "vegdyn_weather_penalty_table",
        "vegdyn_resistance_table",
        "vegdyn_next_up_table", "vegdyn_next_down_table"),
        &KnobsHandle::set_stage_b_tables);
    ClassDB::bind_method(D_METHOD("to_stage_b_knobs_dict"), &KnobsHandle::to_stage_b_knobs_dict);

    // 全段 invalidate
    ClassDB::bind_method(D_METHOD("invalidate_all"), &KnobsHandle::invalidate_all);

    // 诊断
    ClassDB::bind_method(D_METHOD("is_field_dirty"), &KnobsHandle::is_field_dirty);
    ClassDB::bind_method(D_METHOD("is_distribute_dirty"), &KnobsHandle::is_distribute_dirty);
    ClassDB::bind_method(D_METHOD("is_summary_dirty"), &KnobsHandle::is_summary_dirty);
    ClassDB::bind_method(D_METHOD("is_stage_b_dirty"), &KnobsHandle::is_stage_b_dirty);
    ClassDB::bind_method(D_METHOD("get_field_rebuild_count"), &KnobsHandle::get_field_rebuild_count);
    ClassDB::bind_method(D_METHOD("get_distribute_rebuild_count"), &KnobsHandle::get_distribute_rebuild_count);
    ClassDB::bind_method(D_METHOD("get_summary_rebuild_count"), &KnobsHandle::get_summary_rebuild_count);
    ClassDB::bind_method(D_METHOD("get_stage_b_rebuild_count"), &KnobsHandle::get_stage_b_rebuild_count);
}

} // namespace pk
