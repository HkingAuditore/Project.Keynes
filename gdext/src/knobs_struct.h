#pragma once

// ─── Phase A.3（dots-total-cpp roadmap）：常驻 knobs RID ─────────────────
// NativeKnobs：POD struct，把 ClimateProfile + 调用站标量参数（field /
// distribute / summary / stage_b）平铺为字段集合。GDScript 端 ClimateProfile
// 变更时 dirty-write 这些字段；hot path tick 仅传 KnobsHandle 引用，
// to_*_knobs_dict() 返回 _cached_*_dict（标量段稳态零分配）。
//
// 与 plan.md "knobs_struct.h" 字段集合的差异：本文件只覆盖 4 个 hot path
// builder 中**真正反复装箱**的 ~30 个标量（grounding 实测 ~71 entry/帧 中
// 标量子集），动态 PackedArray ref（_field_slice_* / _dist_*_cache /
// _summary_*_cache / neighbor_indices）仍由 caller 每帧塞入返回 Dict，
// 因为它们本身就是 SoA 引用（ref-count++ 而非装箱）。这样 NativeKnobs
// 字段数从 plan 预估的 ~120 降到 30+，工程量大幅缩减、ROI 守恒。

#include <cstdint>

#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/string_name.hpp>

namespace pk {

// POD struct：所有字段平铺。命名严格沿用 GDScript 端 build_*_knobs 的 key
// 名（snake_case），便于 1:1 对照与 diff 验收。
struct NativeKnobs {
    // ─── field knobs（_build_weather_field_knobs，~12 标量）─────────
    float world_bounds_pos_y = 0.0f;
    float world_bounds_size_y = 0.0f;
    bool  apply_convergence_boost = true;
    float hex_size = 1.0f;
    int   field_advect_steps = 1;
    float field_diffusion = 0.0f;
    float field_condensation_gain = 0.0f;
    float field_orographic_lift_gain = 0.0f;
    float field_convergence_gain = 0.0f;
    float field_ocean_evap_gain = 0.0f;
    float field_precip_decay = 0.0f;
    float season_phase = 0.0f;

    // ─── distribute knobs（_build_weather_distribute_knobs，~14 标量 + 4 LUT）──
    float snow_min_intensity = 0.001f;
    float snow_freeze_t = 0.30f;
    float snow_melt_t = 0.34f;
    float snow_intensity_for_snowing = 0.4f;
    int   snow_accum_days_req = 3;
    float flood_heavy_intensity = 0.55f;
    float flood_heavy_precip = 0.55f;
    float flood_lowland_intensity = 0.32f;
    float flood_lowland_elev = 0.50f;
    float flood_lowland_moisture = 0.60f;
    int   wt_clear = 0;
    int   cv_snow = 0;
    int   cv_none = 0;
    int   cv_flooding = 0;
    // 8-长度 WT 静态查表：默认空，由 GDScript 端在 changed signal 内 dirty-write。
    godot::PackedFloat32Array dist_temp_delta_arr;
    godot::PackedFloat32Array dist_moisture_delta_arr;
    godot::PackedByteArray    dist_can_form_snow_arr;
    godot::PackedByteArray    dist_can_form_flood_arr;

    // ─── summary knobs（_build_weather_summary_knobs，~10 标量）─────
    int   summary_limit = 12;
    float intensity_enter = 0.10f;
    float intensity_hold = 0.06f;
    float merge_ratio = 0.65f;
    int   merge_max_rounds = 4;
    float radius_base = 1.6f;
    float radius_scale = 1.05f;
    bool  drift_debug_log = false;
    int   day_counter = 0;

    // ─── stage_b knobs（_build_native_daily_stage_b_knobs，~25 标量 + LUT）──
    int   albedo_stride = 1;
    int   veg_dyn_stride = 1;
    int   feedback_stride = 1;
    bool  fast_slow_layering_enabled = false;
    float reference_albedo = 0.0f;
    float albedo_temp_gain = 0.0f;
    float snow_cover_albedo = 0.75f;
    int   cover_snow_id = 0;
    int   cover_glacier_id = 0;
    float vitality_change_rate = 0.0f;
    float compat_harshness = 0.0f;
    float vitality_low_threshold = 0.0f;
    float vitality_high_threshold = 0.0f;
    int   succession_degrade_days = 0;
    int   succession_upgrade_days = 0;
    int   n_wt = 8;
    int   wt_clear_id = 0;
    int   veg_none_id = 0;
    int   wt_rain_id = 0;
    int   wt_storm_id = 0;
    int   wt_monsoon_id = 0;
    int   wt_blizzard_id = 0;
    int   wt_drought_id = 0;
    int   wt_heatwave_id = 0;
    float weather_to_soil_gain = 0.0f;
    float weather_to_vegetation_gain = 0.0f;
    float feedback_per_day_clamp = 0.0f;
    float ocean_moisture_drift_gain = 0.0f;
    // stage_b LUT（caller 用 set_stage_b_lut(name, arr) 写入）
    godot::PackedFloat32Array albedo_table;
    godot::PackedFloat32Array vegdyn_ideal_temp_table;
    godot::PackedFloat32Array vegdyn_ideal_moist_table;
    godot::PackedFloat32Array vegdyn_temp_tol_table;
    godot::PackedFloat32Array vegdyn_moist_tol_table;
    godot::PackedFloat32Array vegdyn_weather_penalty_table;
    godot::PackedInt32Array   vegdyn_resistance_table;
    godot::PackedInt32Array   vegdyn_next_up_table;
    godot::PackedInt32Array   vegdyn_next_down_table;

    // dirty 位掩码（保留扩展位，目前仅作为"自从上次 to_xxx_dict 后是否变更"标识，
    // 任一 setter 拉起；to_xxx_dict 内消费后清零并重建缓存）
    uint64_t dirty_mask = ~uint64_t(0);  // 初始 all-dirty，确保首次 to_*_knobs_dict 触发缓存填充
};

// KnobsHandle：GDScript 可持有的 RefCounted。dirty-write API + to_*_knobs_dict
// 输出。to_*_knobs_dict 内部维护 _cached_*_dict 缓存：dirty=false 时直接返
// 回缓存 Dict（标量段稳态零分配）；dirty=true 时重建 Dict 并回填 _cached_*。
//
// 设计约束：to_*_knobs_dict 输出 Dict 的 key 集合与 GDScript 端 build_*_knobs
// 的标量段 1:1 兼容（动态 PackedArray ref 不放入，由 caller 在外层 merge）。
class KnobsHandle : public godot::RefCounted {
    GDCLASS(KnobsHandle, godot::RefCounted);

public:
    KnobsHandle();
    ~KnobsHandle() override = default;

    // ─── field 段 setter ─────────────────────────────────────────
    void set_field_scalars(
        float world_bounds_pos_y, float world_bounds_size_y,
        bool apply_convergence_boost, float hex_size,
        int field_advect_steps, float field_diffusion,
        float field_condensation_gain, float field_orographic_lift_gain,
        float field_convergence_gain, float field_ocean_evap_gain,
        float field_precip_decay, float season_phase);

    // ─── distribute 段 setter ────────────────────────────────────
    void set_distribute_scalars(
        float snow_min_intensity, float snow_freeze_t, float snow_melt_t,
        float snow_intensity_for_snowing, int snow_accum_days_req,
        float flood_heavy_intensity, float flood_heavy_precip,
        float flood_lowland_intensity, float flood_lowland_elev,
        float flood_lowland_moisture,
        int wt_clear, int cv_snow, int cv_none, int cv_flooding);
    void set_distribute_wt_tables(
        const godot::PackedFloat32Array &temp_delta_arr,
        const godot::PackedFloat32Array &moisture_delta_arr,
        const godot::PackedByteArray &can_form_snow_arr,
        const godot::PackedByteArray &can_form_flood_arr);

    // ─── summary 段 setter ───────────────────────────────────────
    void set_summary_scalars(
        int summary_limit, float intensity_enter, float intensity_hold,
        float merge_ratio, int merge_max_rounds,
        float radius_base, float radius_scale,
        bool drift_debug_log, int day_counter);
    // day_counter 是 hot path 频繁变化字段；提供细粒度入口避免每次全段重写。
    void set_day_counter(int day_counter);

    // ─── stage_b 段 setter ───────────────────────────────────────
    void set_stage_b_scalars(
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
        float feedback_per_day_clamp, float ocean_moisture_drift_gain);
    void set_stage_b_tables(
        const godot::PackedFloat32Array &albedo_table,
        const godot::PackedFloat32Array &vegdyn_ideal_temp_table,
        const godot::PackedFloat32Array &vegdyn_ideal_moist_table,
        const godot::PackedFloat32Array &vegdyn_temp_tol_table,
        const godot::PackedFloat32Array &vegdyn_moist_tol_table,
        const godot::PackedFloat32Array &vegdyn_weather_penalty_table,
        const godot::PackedInt32Array &vegdyn_resistance_table,
        const godot::PackedInt32Array &vegdyn_next_up_table,
        const godot::PackedInt32Array &vegdyn_next_down_table);

    // ─── 全段 dirty 强制重建（ClimateProfile.changed 时调用）─────
    void invalidate_all();

    // ─── hot path 输出 ───────────────────────────────────────────
    // 返回 Dictionary 引用：标量字段已平铺为 key；caller 在外层 merge
    // 动态 PackedArray ref（cell_pos / neighbor_indices / SoA cache 等）。
    godot::Dictionary to_field_knobs_dict();
    godot::Dictionary to_distribute_knobs_dict();
    godot::Dictionary to_summary_knobs_dict();
    godot::Dictionary to_stage_b_knobs_dict();

    // ─── 诊断接口 ────────────────────────────────────────────────
    bool is_field_dirty() const { return _field_dirty; }
    bool is_distribute_dirty() const { return _distribute_dirty; }
    bool is_summary_dirty() const { return _summary_dirty; }
    bool is_stage_b_dirty() const { return _stage_b_dirty; }
    int  get_field_rebuild_count() const { return _field_rebuild_count; }
    int  get_distribute_rebuild_count() const { return _distribute_rebuild_count; }
    int  get_summary_rebuild_count() const { return _summary_rebuild_count; }
    int  get_stage_b_rebuild_count() const { return _stage_b_rebuild_count; }

protected:
    static void _bind_methods();

private:
    NativeKnobs       _k;
    // 缓存 Dictionary：to_*_knobs_dict 在 dirty=false 时直接返回，dirty=true 时重建并回填
    godot::Dictionary _cached_field_dict;
    godot::Dictionary _cached_distribute_dict;
    godot::Dictionary _cached_summary_dict;
    godot::Dictionary _cached_stage_b_dict;
    // 段级 dirty（粒度比 NativeKnobs::dirty_mask 更精确，便于 to_*_knobs_dict 选择性重建）
    bool _field_dirty = true;
    bool _distribute_dirty = true;
    bool _summary_dirty = true;
    bool _stage_b_dirty = true;
    // 诊断：累计重建次数（验收时打 once-log，确认稳态 ≤1 Hz）
    int  _field_rebuild_count = 0;
    int  _distribute_rebuild_count = 0;
    int  _summary_rebuild_count = 0;
    int  _stage_b_rebuild_count = 0;
};

} // namespace pk
