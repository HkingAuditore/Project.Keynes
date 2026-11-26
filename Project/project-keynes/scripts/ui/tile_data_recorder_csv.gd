extends RefCounted

## Tile CSV column definitions, field discovery, and row formatting.

const FIXED_COLUMNS: Array = [
	"row_idx",
	"tick_idx",
	"timestamp_ms",
	"was_skipped_day",
	"fps",
	"fast_ms",
	"t_sus_ms",
	"t_render_ms",
	"t_ui_ms",
	"climate_max_temp_delta",
	"climate_p95_temp_delta",
	"climate_p99_temp_delta",
	"climate_preclamp_max_temp_delta",
	"climate_preclamp_p99_temp_delta",
	"climate_temp_delta_gt_005_count",
	"climate_temp_delta_gt_010_count",
	"climate_temp_delta_gt_020_count",
	"climate_temp_delta_clamped_count",
	"climate_max_transport_anomaly",
	"climate_transport_abs_p95",
	"climate_transport_nonzero_ratio",
	"climate_sea_ice_delta_max",
	"climate_precip_p95",
	"climate_slp_delta_p95",
	"climate_wind_delta_p95",
	"climate_ocean_delta_p95",
	"climate_slp_abs_p95",
	"climate_wind_mag_p95",
	"climate_ocean_mag_p95",
	"climate_upwelling_abs_p95",
	"climate_current_pass",
	"climate_partial",
	"climate_progress_ratio",
	"climate_processed_cells",
	"climate_cursor_start",
	"climate_cursor_end",
	"climate_round_id",
	"climate_node_index",
	"climate_next_node_index",
	"climate_pass_status",
	"climate_pass_stage",
	"climate_pass_substage",
	"climate_pass_path",
	"climate_budget_interrupted",
	"climate_pass_token",
	"weather_dirty_count",
	"water_budget_error",
	"active_weather_ratio",
	"weather_diag_present",
	"weather_field_commit_path",
	"weather_field_commit_publish_verified",
	"weather_field_commit_publish_repaired",
	"weather_field_commit_init_count",
	"weather_field_commit_publish_reason",
	"weather_refresh_convergence",
	"weather_field_solve_tick",
	"weather_commit_tick_delta",
	"weather_last_commit_tick",
	"weather_cold_front_count",
	"weather_warm_front_count",
	"weather_convergence_refresh_stride",
	"weather_native_convergence_boost",
	"weather_convergence_dirty_count",
	"weather_convergence_delta_p95",
	"weather_convergence_published",
	"weather_target_mismatch_count",
	"weather_transitioning_count",
	"weather_transition_alpha_mean",
	"weather_transition_alpha_p95",
	"climate_thermal_finalizer_applied",
	"climate_moisture_committed",
	"climate_moisture_commit_path",
	"climate_moisture_commit_slot_size",
	"climate_moisture_commit_flush_ms",
	"stage_b_tick_idx",
	"stage_b_call_index",
	"stage_b_run_veg_dyn",
	"stage_b_veg_dyn_ms",
	"stage_b_combined_done",
	"stage_b_ext_ok",
	"stage_b_total_runs",
	"stage_b_total_fallbacks",
	"weather_job_path",
	"phys_phase_locked",
	"phys_diag_tick_idx",
	"phys_sim_day",
	"phys_stage",
	"phys_stage_name",
	"phys_next_stage",
	"phys_next_stage_name",
	"phys_path",
	"phys_done",
	"phys_round_active",
	"phys_physical_round_id",
	"phys_visual_round_active",
	"phys_visual_round_id",
	"phys_visual_pending_commit",
	"phys_visual_lag_ticks",
	"phys_visual_pixel_progress",
	"phys_visual_next_pixel_idx",
	"phys_visual_total_pixels",
	"phys_pending_commit",
	"phys_need_pixel",
	"phys_run_ocean",
	"phys_phase_int_seen",
	"phys_ticks_per_slice",
	"phys_wind_period_ticks",
	"phys_ocean_period_ticks",
	"phys_slice_count",
	"phys_next_pixel_idx",
	"phys_total_pixels",
	"phys_pixel_quota",
	"phys_progress_ratio",
	"phys_processed_pixels",
	"phys_cursor_start",
	"phys_cursor_end",
	"phys_raster_requested_start",
	"phys_raster_requested_end",
	"phys_raster_returned_start",
	"phys_raster_returned_end",
	"phys_raster_pixels",
	"phys_raster_wall_ms",
	"phys_raster_native_ms",
	"phys_raster_used_cpp",
	"phys_raster_atlas_updated",
	"phys_raster_fallback_reason",
	"phys_raster_progress_guard_fired",
	"phys_slp_path",
	"phys_slp_native_ms",
	"phys_slp_rc_ms",
	"phys_slp_out_size",
	"phys_slp_published_to_slot",
	"phys_slp_commit_ok",
	"phys_slp_thermal_p95",
	"phys_slp_delta_p95",
	"phys_wind_cpp_done",
	"phys_wind_rc_ms",
	"phys_wind_wx_size",
	"phys_wind_wy_size",
	"phys_wind_speed_out_size",
	"phys_wind_map_speed_size",
	"phys_wind_commit_ok",
	"phys_wind_delta_p95",
	"phys_wind_dir_delta_p95",
	"phys_wind_dir_flip_count",
	"phys_daily_wind_due",
	"phys_daily_wind_tick_idx",
	"phys_daily_wind_season_phase",
	"phys_daily_wind_ran",
	"phys_daily_wind_path",
	"phys_daily_wind_elapsed_ms",
	"phys_daily_wind_refresh_ms",
	"phys_daily_wind_slp_ms",
	"phys_daily_wind_wind_ms",
	"phys_daily_wind_fallback_reason",
	"phys_daily_wind_slp_commit_ok",
	"phys_daily_wind_wind_commit_ok",
	"phys_daily_wind_wind_cpp_done",
	"phys_daily_wind_slp_published_to_slot",
	"phys_daily_wind_slp_delta_p95",
	"phys_daily_wind_delta_p95",
	"phys_daily_wind_dir_delta_p95",
	"phys_daily_wind_dir_flip_count",
	"phys_psi_path",
	"phys_psi_native_ms",
	"phys_psi_iters_run",
	"phys_psi_residual_final",
	"phys_psi_early_exit",
	"phys_psi_mode",
	"phys_ocean_delta_p95",
	"phys_thermal_current_p95",
	"phys_ocean_current_preclamp_p95",
	"phys_ocean_current_preclamp_max",
	"phys_ocean_current_clamp_count",
	"phys_ocean_current_clamp_ratio",
	"phys_ocean_current_max_magnitude",
	"cell_index",
	"q",
	"r",
	"s",
]

# MapData 上所有 cell-count 长度的 SoA 候选。start 时会按当前 cell_count 过滤；
# 例如 demo_thermal_gradient_arr 在未启用时 size=0，不会进入本次 CSV header。
const SOA_FIELD_CANDIDATES: Array = [
	"temp_arr",
	"temp_arr_prev",
	"moisture_arr",
	"moisture_arr_prev",
	"snow_cover_arr",
	"snow_cover_arr_prev",
	"temp_baseline_arr",
	"temp_30d_arr",
	"temp_365d_arr",
	"temp_anomaly_arr",
	"sea_ice_frac_arr",
	"sea_ice_frac_arr_prev",
	"weather_intensity_arr",
	"weather_cloud_arr",
	"weather_cloud_water_arr",
	"weather_precip_arr",
	"weather_transition_alpha_arr",
	"weather_classification_temp_arr",
	"weather_classification_moisture_arr",
	"weather_vapor_arr",
	"weather_convergence_arr",
	"weather_instability_arr",
	"weather_field_init_arr",
	"air_mass_temp_anomaly_arr",
	"ocean_thermal_anomaly_arr",
	"local_thermal_anomaly_arr",
	"has_river_arr",
	"river_flow_arr",
	"river_downstream_arr",
	"hydro_parent_arr",
	"river_discharge_arr",
	"river_discharge_30d_arr",
	"river_storage_arr",
	"groundwater_storage_arr",
	"surface_runoff_arr",
	"ema_initialized_arr",
	"temp_season_offset_arr",
	"insolation_now_arr",
	"insolation_dev_arr",
	"day_length_arr",
	"heat_input_arr",
	"thermal_energy_arr",
	"snowpack_arr",
	"water_balance_30d_arr",
	"vegetation_vitality_arr",
	"vitality_low_streak_arr",
	"vitality_high_streak_arr",
	"soil_moisture_arr",
	"vegetation_growth_pressure_arr",
	"temperature_transport_anomaly_arr",
	"vegetation_heat_stress_arr",
	"vegetation_drought_stress_arr",
	"vegetation_cold_stress_arr",
	"vegetation_regen_score_arr",
	"demo_thermal_gradient_arr",
	"elevation_arr",
	"base_moisture_arr",
	"ocean_current_x_arr",
	"ocean_current_y_arr",
	"wind_x_arr",
	"wind_y_arr",
	"slp_arr",
	"wind_speed_arr",
	"upwelling_strength_arr",
	"wind_stress_curl_arr",
	"ocean_psi_arr",
	"cell_pos_x_arr",
	"cell_pos_y_arr",
	"cell_lat_norm_arr",
	"temp_baseline_year_arr",
	"terrain_arr",
	"landform_arr",
	"vegetation_arr",
	"has_volcano_arr",
	"is_lake_seed_arr",
	"base_terrain_arr",
	"base_landform_arr",
	"base_vegetation_arr",
	"cover_arr",
	"weather_type_arr",
	"weather_prev_type_arr",
	"weather_target_type_arr",
	"is_water_arr",
	"country_slot_arr",
	"climate_dirty_mask",
	"weather_dirty_mask",
]

# Optional compact preset for targeted investigations. The default remains full
# fidelity: every recorded tick, every cell, and every available SoA field.
const COMPACT_SOA_FIELD_CANDIDATES: Array = [
	"temp_arr",
	"temp_baseline_arr",
	"moisture_arr",
	"sea_ice_frac_arr",
	"weather_precip_arr",
	"weather_transition_alpha_arr",
	"air_mass_temp_anomaly_arr",
	"ocean_thermal_anomaly_arr",
	"local_thermal_anomaly_arr",
	"temperature_transport_anomaly_arr",
	"ocean_current_x_arr",
	"ocean_current_y_arr",
	"wind_x_arr",
	"wind_y_arr",
	"slp_arr",
	"wind_speed_arr",
	"upwelling_strength_arr",
	"terrain_arr",
	"landform_arr",
	"vegetation_arr",
	"has_river_arr",
	"river_flow_arr",
	"river_downstream_arr",
	"has_volcano_arr",
	"is_lake_seed_arr",
	"weather_type_arr",
	"weather_target_type_arr",
	"is_water_arr",
	"country_slot_arr",
	"climate_dirty_mask",
	"weather_dirty_mask",
]


static func _collect_soa_fields(map_data, cell_count: int, compact_fields: bool) -> PackedStringArray:
	var fields: PackedStringArray = PackedStringArray()
	var candidates: Array = COMPACT_SOA_FIELD_CANDIDATES if compact_fields else SOA_FIELD_CANDIDATES
	for name in candidates:
		var field: String = str(name)
		var arr = map_data.get(field)
		if _array_size(arr) == cell_count:
			fields.append(field)
	return fields


static func _base_row(sample: Dictionary, idx: int, cell, row_idx: int) -> Dictionary:
	var climate: Dictionary = sample.get("climate", {})
	var pass_diag: Dictionary = climate.get("pass_diag", {})
	var weather: Dictionary = sample.get("weather", {})
	var phys: Dictionary = sample.get("ocean_currents", {})
	return {
		"row_idx": row_idx,
		"tick_idx": int(sample.get("tick_idx", 0)),
		"timestamp_ms": int(sample.get("timestamp_ms", 0)),
		"was_skipped_day": bool(sample.get("was_skipped_day", false)),
		"fps": int(sample.get("fps", 0)),
		"fast_ms": float(sample.get("fast_ms", 0.0)),
		"t_sus_ms": float(sample.get("t_sus_ms", 0.0)),
		"t_render_ms": float(sample.get("t_render_ms", 0.0)),
		"t_ui_ms": float(sample.get("t_ui_ms", 0.0)),
		"climate_max_temp_delta": float(climate.get("max_temp_delta", 0.0)),
		"climate_p95_temp_delta": float(climate.get("p95_temp_delta", 0.0)),
		"climate_p99_temp_delta": float(climate.get("p99_temp_delta", 0.0)),
		"climate_preclamp_max_temp_delta": float(climate.get("preclamp_max_temp_delta", 0.0)),
		"climate_preclamp_p99_temp_delta": float(climate.get("preclamp_p99_temp_delta", 0.0)),
		"climate_temp_delta_gt_005_count": int(climate.get("temp_delta_gt_005_count", 0)),
		"climate_temp_delta_gt_010_count": int(climate.get("temp_delta_gt_010_count", 0)),
		"climate_temp_delta_gt_020_count": int(climate.get("temp_delta_gt_020_count", 0)),
		"climate_temp_delta_clamped_count": int(climate.get("temp_delta_clamped_count", 0)),
		"climate_max_transport_anomaly": float(climate.get("max_transport_anomaly", 0.0)),
		"climate_transport_abs_p95": float(climate.get("transport_abs_p95", 0.0)),
		"climate_transport_nonzero_ratio": float(climate.get("transport_nonzero_ratio", 0.0)),
		"climate_sea_ice_delta_max": float(climate.get("sea_ice_delta_max", 0.0)),
		"climate_precip_p95": float(climate.get("precip_p95", 0.0)),
		"climate_slp_delta_p95": float(climate.get("slp_delta_p95", 0.0)),
		"climate_wind_delta_p95": float(climate.get("wind_delta_p95", 0.0)),
		"climate_ocean_delta_p95": float(climate.get("ocean_delta_p95", 0.0)),
		"climate_slp_abs_p95": float(climate.get("slp_abs_p95", 0.0)),
		"climate_wind_mag_p95": float(climate.get("wind_mag_p95", 0.0)),
		"climate_ocean_mag_p95": float(climate.get("ocean_mag_p95", 0.0)),
		"climate_upwelling_abs_p95": float(climate.get("upwelling_abs_p95", 0.0)),
		"climate_current_pass": str(climate.get("current_pass", "")),
		"climate_partial": bool(climate.get("partial", false)),
		"climate_progress_ratio": float(climate.get("progress_ratio", 0.0)),
		"climate_processed_cells": int(climate.get("processed_cells", 0)),
		"climate_cursor_start": int(climate.get("cursor_start", -1)),
		"climate_cursor_end": int(climate.get("cursor_end", -1)),
		"climate_round_id": int(climate.get("round_id", 0)),
		"climate_node_index": int(climate.get("node_index", -1)),
		"climate_next_node_index": int(climate.get("next_node_index", -1)),
		"climate_pass_status": str(climate.get("pass_status", "")),
		"climate_pass_stage": str(pass_diag.get("stage", "")),
		"climate_pass_substage": str(pass_diag.get("substage", "")),
		"climate_pass_path": str(pass_diag.get("path", climate.get("path", ""))),
		"climate_budget_interrupted": bool(climate.get("budget_interrupted", pass_diag.get("budget_interrupted", false))),
		"climate_pass_token": int(climate.get("pass_token", pass_diag.get("token", 0))),
		"weather_dirty_count": int(weather.get("weather_dirty_count", climate.get("weather_dirty_count", 0))),
		"water_budget_error": float(weather.get("water_budget_error", climate.get("water_budget_error", 0.0))),
		"active_weather_ratio": float(weather.get("active_weather_ratio", climate.get("active_weather_ratio", 0.0))),
		"weather_diag_present": not weather.is_empty(),
		"weather_field_commit_path": str(weather.get("field_commit_path", "")),
		"weather_field_commit_publish_verified": bool(weather.get("field_commit_publish_verified", false)),
		"weather_field_commit_publish_repaired": bool(weather.get("field_commit_publish_repaired", false)),
		"weather_field_commit_init_count": int(weather.get("field_commit_init_count", 0)),
		"weather_field_commit_publish_reason": str(weather.get("field_commit_publish_reason", "")),
		"weather_refresh_convergence": bool(weather.get("refresh_convergence", false)),
		"weather_field_solve_tick": int(weather.get("field_solve_tick", -1)),
		"weather_commit_tick_delta": int(weather.get("weather_commit_tick_delta", 0)),
		"weather_last_commit_tick": int(weather.get("weather_last_commit_tick", -1)),
		"weather_cold_front_count": int(weather.get("weather_cold_front_count", 0)),
		"weather_warm_front_count": int(weather.get("weather_warm_front_count", 0)),
		"weather_convergence_refresh_stride": int(weather.get("field_convergence_refresh_stride", 0)),
		"weather_native_convergence_boost": bool(weather.get("native_convergence_boost", false)),
		"weather_convergence_dirty_count": int(weather.get("weather_convergence_dirty_count", 0)),
		"weather_convergence_delta_p95": float(weather.get("weather_convergence_delta_p95", 0.0)),
		"weather_convergence_published": bool(weather.get("convergence_published", false)),
		"weather_target_mismatch_count": int(weather.get("target_mismatch_count", 0)),
		"weather_transitioning_count": int(weather.get("transitioning_count", 0)),
		"weather_transition_alpha_mean": float(weather.get("transition_alpha_mean", 0.0)),
		"weather_transition_alpha_p95": float(weather.get("transition_alpha_p95", 0.0)),
		"climate_thermal_finalizer_applied": bool(climate.get("thermal_finalizer_applied", false)),
		"climate_moisture_committed": bool(climate.get("moisture_committed", false)),
		"climate_moisture_commit_path": str(climate.get("moisture_commit_path", "")),
		"climate_moisture_commit_slot_size": int(climate.get("moisture_commit_slot_size", 0)),
		"climate_moisture_commit_flush_ms": float(climate.get("moisture_commit_flush_ms", 0.0)),
		"stage_b_tick_idx": int(weather.get("_tick_idx", -1)),
		"stage_b_call_index": int(weather.get("stage_b_call_index", -1)),
		"stage_b_run_veg_dyn": bool(weather.get("veg_dyn_ran", false)),
		"stage_b_veg_dyn_ms": float(weather.get("veg_dyn_ms", 0.0)),
		"stage_b_combined_done": bool(weather.get("stage_b_combined_done", false)),
		"stage_b_ext_ok": bool(weather.get("stage_b_ext_ok", false)),
		"stage_b_total_runs": int(weather.get("stage_b_total_runs", 0)),
		"stage_b_total_fallbacks": int(weather.get("stage_b_total_fallbacks", 0)),
		"weather_job_path": str(weather.get("weather_job_path", "")),
		"phys_phase_locked": float(phys.get("phase_locked", phys.get("season_phase", 0.0))),
		"phys_diag_tick_idx": int(phys.get("tick_idx", -1)),
		"phys_sim_day": int(phys.get("sim_day", -1)),
		"phys_stage": int(phys.get("stage", phys.get("phys_stage", -1))),
		"phys_stage_name": str(phys.get("stage_name", phys.get("phys_stage_name", ""))),
		"phys_next_stage": int(phys.get("next_stage", -1)),
		"phys_next_stage_name": str(phys.get("next_stage_name", "")),
		"phys_path": str(phys.get("path", "")),
		"phys_done": bool(phys.get("done", false)),
		"phys_round_active": bool(phys.get("phys_round_active", phys.get("round_active", false))),
		"phys_physical_round_id": int(phys.get("physical_round_id", 0)),
		"phys_visual_round_active": bool(phys.get("visual_round_active", false)),
		"phys_visual_round_id": int(phys.get("visual_round_id", 0)),
		"phys_visual_pending_commit": bool(phys.get("visual_pending_commit", phys.get("pending_commit", false))),
		"phys_visual_lag_ticks": int(phys.get("visual_lag_ticks", 0)),
		"phys_visual_pixel_progress": float(phys.get("visual_pixel_progress", 1.0)),
		"phys_visual_next_pixel_idx": int(phys.get("visual_next_pixel_idx", phys.get("next_pixel_idx", 0))),
		"phys_visual_total_pixels": int(phys.get("visual_total_pixels", phys.get("total_pixels", 0))),
		"phys_pending_commit": bool(phys.get("pending_commit", phys.get("visual_pending_commit", false))),
		"phys_need_pixel": bool(phys.get("need_pixel", false)),
		"phys_run_ocean": bool(phys.get("run_ocean", false)),
		"phys_phase_int_seen": int(phys.get("phase_int_seen", -9999)),
		"phys_ticks_per_slice": int(phys.get("ticks_per_slice", 0)),
		"phys_wind_period_ticks": int(phys.get("wind_period_ticks", 0)),
		"phys_ocean_period_ticks": int(phys.get("ocean_period_ticks", 0)),
		"phys_slice_count": int(phys.get("slice_count", 0)),
		"phys_next_pixel_idx": int(phys.get("next_pixel_idx", 0)),
		"phys_total_pixels": int(phys.get("total_pixels", 0)),
		"phys_pixel_quota": int(phys.get("pixel_quota", phys.get("current_pixel_quota", 0))),
		"phys_progress_ratio": float(phys.get("progress_ratio", 0.0)),
		"phys_processed_pixels": int(phys.get("processed_pixels", 0)),
		"phys_cursor_start": int(phys.get("cursor_start", -1)),
		"phys_cursor_end": int(phys.get("cursor_end", -1)),
		"phys_raster_requested_start": int(phys.get("raster_requested_start", -1)),
		"phys_raster_requested_end": int(phys.get("raster_requested_end", -1)),
		"phys_raster_returned_start": int(phys.get("raster_returned_start", -1)),
		"phys_raster_returned_end": int(phys.get("raster_returned_end", -1)),
		"phys_raster_pixels": int(phys.get("raster_pixels", 0)),
		"phys_raster_wall_ms": float(phys.get("raster_wall_ms", -1.0)),
		"phys_raster_native_ms": float(phys.get("raster_native_ms", -1.0)),
		"phys_raster_used_cpp": bool(phys.get("raster_used_cpp", false)),
		"phys_raster_atlas_updated": bool(phys.get("raster_atlas_updated", false)),
		"phys_raster_fallback_reason": str(phys.get("raster_fallback_reason", "")),
		"phys_raster_progress_guard_fired": bool(phys.get("raster_progress_guard_fired", false)),
		"phys_slp_path": str(phys.get("slp_path", phys.get("stage_slp_path", ""))),
		"phys_slp_native_ms": float(phys.get("slp_native_ms", phys.get("stage_slp_native_ms", -1.0))),
		"phys_slp_rc_ms": float(phys.get("slp_rc_ms", -1.0)),
		"phys_slp_out_size": int(phys.get("slp_out_size", -1)),
		"phys_slp_published_to_slot": bool(phys.get("slp_published_to_slot", false)),
		"phys_slp_commit_ok": bool(phys.get("slp_commit_ok", false)),
		"phys_slp_thermal_p95": float(phys.get("slp_thermal_p95", 0.0)),
		"phys_slp_delta_p95": float(phys.get("slp_delta_p95", 0.0)),
		"phys_wind_cpp_done": bool(phys.get("wind_cpp_done", false)),
		"phys_wind_rc_ms": float(phys.get("wind_rc_ms", -1.0)),
		"phys_wind_wx_size": int(phys.get("wind_wx_size", -1)),
		"phys_wind_wy_size": int(phys.get("wind_wy_size", -1)),
		"phys_wind_speed_out_size": int(phys.get("wind_speed_out_size", -1)),
		"phys_wind_map_speed_size": int(phys.get("wind_map_speed_size", -1)),
		"phys_wind_commit_ok": bool(phys.get("wind_commit_ok", false)),
		"phys_wind_delta_p95": float(phys.get("wind_delta_p95", 0.0)),
		"phys_wind_dir_delta_p95": float(phys.get("wind_dir_delta_p95", 0.0)),
		"phys_wind_dir_flip_count": int(phys.get("wind_dir_flip_count", 0)),
		"phys_daily_wind_due": bool(phys.get("daily_wind_due", false)),
		"phys_daily_wind_tick_idx": int(phys.get("daily_wind_tick_idx", -1)),
		"phys_daily_wind_season_phase": float(phys.get("daily_wind_season_phase", 0.0)),
		"phys_daily_wind_ran": bool(phys.get("daily_wind_ran", false)),
		"phys_daily_wind_path": str(phys.get("daily_wind_path", "")),
		"phys_daily_wind_elapsed_ms": float(phys.get("daily_wind_elapsed_ms", -1.0)),
		"phys_daily_wind_refresh_ms": float(phys.get("daily_wind_refresh_ms", -1.0)),
		"phys_daily_wind_slp_ms": float(phys.get("daily_wind_slp_ms", -1.0)),
		"phys_daily_wind_wind_ms": float(phys.get("daily_wind_wind_ms", -1.0)),
		"phys_daily_wind_fallback_reason": str(phys.get("daily_wind_fallback_reason", "")),
		"phys_daily_wind_slp_commit_ok": bool(phys.get("daily_wind_slp_commit_ok", false)),
		"phys_daily_wind_wind_commit_ok": bool(phys.get("daily_wind_wind_commit_ok", false)),
		"phys_daily_wind_wind_cpp_done": bool(phys.get("daily_wind_wind_cpp_done", false)),
		"phys_daily_wind_slp_published_to_slot": bool(phys.get("daily_wind_slp_published_to_slot", false)),
		"phys_daily_wind_slp_delta_p95": float(phys.get("daily_wind_slp_delta_p95", 0.0)),
		"phys_daily_wind_delta_p95": float(phys.get("daily_wind_wind_delta_p95", phys.get("daily_wind_delta_p95", 0.0))),
		"phys_daily_wind_dir_delta_p95": float(phys.get("daily_wind_wind_dir_delta_p95", phys.get("daily_wind_dir_delta_p95", 0.0))),
		"phys_daily_wind_dir_flip_count": int(phys.get("daily_wind_wind_dir_flip_count", phys.get("daily_wind_dir_flip_count", 0))),
		"phys_psi_path": str(phys.get("psi_path", phys.get("stage_psi_path", ""))),
		"phys_psi_native_ms": float(phys.get("psi_native_ms", phys.get("stage_psi_native_ms", -1.0))),
		"phys_psi_iters_run": int(phys.get("psi_iters_run", 0)),
		"phys_psi_residual_final": float(phys.get("psi_residual_final", 0.0)),
		"phys_psi_early_exit": bool(phys.get("psi_early_exit", false)),
		"phys_psi_mode": str(phys.get("psi_mode", "")),
		"phys_ocean_delta_p95": float(phys.get("ocean_delta_p95", 0.0)),
		"phys_thermal_current_p95": float(phys.get("thermal_current_p95", 0.0)),
		"phys_ocean_current_preclamp_p95": float(phys.get("ocean_current_preclamp_p95", 0.0)),
		"phys_ocean_current_preclamp_max": float(phys.get("ocean_current_preclamp_max", 0.0)),
		"phys_ocean_current_clamp_count": int(phys.get("ocean_current_clamp_count", 0)),
		"phys_ocean_current_clamp_ratio": float(phys.get("ocean_current_clamp_ratio", 0.0)),
		"phys_ocean_current_max_magnitude": float(phys.get("ocean_current_max_magnitude", 0.0)),
		"cell_index": idx,
		"q": int(cell.q),
		"r": int(cell.r),
		"s": int(cell.s),
	}


static func _tick_fixed_suffix(sample: Dictionary, cell, row_idx: int) -> String:
	var row: Dictionary = _base_row(sample, 0, cell, row_idx)
	var cell_col: int = FIXED_COLUMNS.find("cell_index")
	if cell_col <= 1:
		return ""
	var parts: PackedStringArray = PackedStringArray()
	for i in range(1, cell_col):
		var col: String = str(FIXED_COLUMNS[i])
		parts.append(_csv_escape(row[col]) if row.has(col) else "")
	return "," + ",".join(parts)


static func _format_record_line(row_idx: int, fixed_suffix: String,
		cell_index: int, q: int, r: int, s: int,
		arrays: Array, field_types: PackedInt32Array) -> String:
	var tail: PackedStringArray = PackedStringArray()
	var field_count: int = arrays.size()
	tail.resize(4 + field_count)
	tail[0] = str(cell_index)
	tail[1] = str(q)
	tail[2] = str(r)
	tail[3] = str(s)
	for i in range(field_count):
		match int(field_types[i]):
			TYPE_PACKED_FLOAT32_ARRAY:
				tail[4 + i] = _csv_float(float(arrays[i][cell_index]))
			TYPE_PACKED_INT32_ARRAY:
				tail[4 + i] = str(int(arrays[i][cell_index]))
			TYPE_PACKED_BYTE_ARRAY:
				tail[4 + i] = str(int(arrays[i][cell_index]))
			_:
				tail[4 + i] = _csv_escape(_array_value(arrays[i], cell_index))
	return str(row_idx) + fixed_suffix + "," + ",".join(tail)


static func _array_size(arr) -> int:
	var t: int = typeof(arr)
	if t == TYPE_PACKED_FLOAT32_ARRAY or t == TYPE_PACKED_INT32_ARRAY or t == TYPE_PACKED_BYTE_ARRAY:
		return arr.size()
	return -1


static func _array_value(arr, idx: int):
	return arr[idx]


static func _format_header_line(columns: PackedStringArray) -> String:
	var parts: PackedStringArray = PackedStringArray()
	for c in columns:
		parts.append(_csv_escape(c))
	return ",".join(parts)


static func _format_row_line(row: Dictionary, columns: PackedStringArray) -> String:
	var parts: PackedStringArray = PackedStringArray()
	for c in columns:
		parts.append(_csv_escape(row[c]) if row.has(c) else "")
	return ",".join(parts)


static func _csv_escape(value) -> String:
	var s: String = ""
	var t: int = typeof(value)
	if t == TYPE_NIL:
		return ""
	elif t == TYPE_BOOL:
		s = "true" if bool(value) else "false"
	elif t == TYPE_INT:
		s = str(int(value))
	elif t == TYPE_FLOAT:
		var fv: float = float(value)
		if is_nan(fv) or is_inf(fv):
			return ""
		s = ("%.6f" % fv).rstrip("0").rstrip(".")
		if s == "" or s == "-":
			s = "0"
	else:
		s = str(value)

	if s.find(",") != -1 or s.find("\"") != -1 or s.find("\n") != -1 or s.find("\r") != -1:
		s = s.replace("\"", "\"\"")
		return "\"" + s + "\""
	return s


static func _csv_float(value: float) -> String:
	if is_nan(value) or is_inf(value):
		return ""
	var s: String = ("%.6f" % value).rstrip("0").rstrip(".")
	if s == "" or s == "-":
		return "0"
	return s
