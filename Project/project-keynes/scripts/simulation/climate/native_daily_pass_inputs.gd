extends RefCounted

## Builds climate, circulation, and hydrology inputs for the native daily passes.


static func _native_daily_live_f32(context, slot_name: String, fallback: PackedFloat32Array,
		n: int) -> PackedFloat32Array:
	if context._generator._data_core_world_ext == null:
		return fallback
	var sid: int = int(context._generator._data_core_world_ext.component_id(slot_name))
	if sid < 0:
		return fallback
	var live: PackedFloat32Array = context._generator._data_core_world_ext.snapshot_f32(sid)
	return live if live.size() == n else fallback

static func _native_daily_live_u8(context, slot_name: String, fallback: PackedByteArray,
		n: int) -> PackedByteArray:
	if context._generator._data_core_world_ext == null:
		return fallback
	var sid: int = int(context._generator._data_core_world_ext.component_id(slot_name))
	if sid < 0:
		return fallback
	var live: PackedByteArray = context._generator._data_core_world_ext.snapshot_u8(sid)
	return live if live.size() == n else fallback

static func _native_daily_base_tick_knobs(context, ctx: SusTickContext) -> Dictionary:
	var season_idx: int = 0
	if context._generator._world_clock_ref != null and context._generator._world_clock_ref.has_method("season_index"):
		season_idx = int(context._generator._world_clock_ref.season_index())
	var days_per_year: int = context._generator._calendar_days_per_year()
	var day_of_year: int = context._generator._season_phase_to_day_of_year(ctx.season_phase, days_per_year)
	if context._generator._world_clock_ref != null and context._generator._world_clock_ref.has_method("day_in_year"):
		day_of_year = clampi(int(context._generator._world_clock_ref.day_in_year()), 0, days_per_year - 1)
	var anomaly: float = 0.0
	if context._generator._world_clock_ref != null:
		var v = context._generator._world_clock_ref.get("climate_anomaly")
		if v != null:
			anomaly = float(v)
	return {
		"day_index": ctx.day_index,
		"day_of_year": day_of_year,
		"days_per_year": days_per_year,
		"tick_index": ctx.tick_index,
		"season_phase": ctx.season_phase,
		"season_index": season_idx,
		"climate_anomaly": anomaly,
		"speed_multiplier": float(ctx.speed_scale) if ctx != null else 1.0,
	}

static func _build_native_daily_stage_b_knobs(context, map: MapData, cp_now, call_index: int,
		elapsed_days_per_call: float = 1.0, calendar_day: int = -1) -> Dictionary:
	if map == null or cp_now == null:
		return {}
	var n_cells: int = map.cell_count()
	if n_cells <= 0:
		return {}
	var albedo_stride: int = maxi(1, int(cp_now.weather_albedo_stride))
	var veg_dyn_stride: int = maxi(1, int(cp_now.weather_vegetation_dynamics_stride))
	var feedback_stride: int = maxi(1, int(cp_now.weather_feedback_stride))
	var run_albedo: bool = (call_index % albedo_stride) == 0
	var run_veg_dyn: bool = (call_index % veg_dyn_stride) == 0
	var run_feedback: bool = (call_index % feedback_stride) == 0 and bool(cp_now.fast_slow_layering_enabled)
	if calendar_day < 0 and context._generator._world_clock_ref != null and context._generator._world_clock_ref.has_method("day_index"):
		calendar_day = int(context._generator._world_clock_ref.day_index())
	if calendar_day >= 0 and calendar_day == context._generator._last_season_refresh_day:
		run_veg_dyn = false
	if not (run_albedo or run_veg_dyn or run_feedback):
		return {}
	var knobs: Dictionary = {
		"n_cells": n_cells,
		"stage_b_call_index": call_index,
		"run_albedo": run_albedo,
		"run_veg_dyn": run_veg_dyn,
		"run_feedback": run_feedback,
		"use_soa": true,
	}
	if run_albedo:
		knobs["reference_albedo"] = float(cp_now.reference_albedo)
		knobs["albedo_temp_gain"] = float(cp_now.albedo_temp_gain)
		knobs["snow_cover_albedo"] = 0.75
		knobs["cover_snow_id"] = int(CoverType.CV.SNOW)
		knobs["cover_glacier_id"] = int(CoverType.CV.GLACIER)
		knobs["albedo_table"] = context._generator._build_albedo_donor_table()
	if run_veg_dyn:
		context._generator._ensure_vegdyn_lut()
		# 两层调用间隔相乘，得到植被实际经过的游戏天数。
		var veg_dyn_scale_raw: float = float(veg_dyn_stride) * maxf(elapsed_days_per_call, 1.0)
		var veg_dyn_scale_eff: float = maxf(veg_dyn_scale_raw, 1.0)
		knobs["day_scale"] = veg_dyn_scale_raw
		knobs["streak_days"] = maxi(1, int(round(veg_dyn_scale_eff)))
		knobs["vitality_change_rate"] = float(cp_now.vitality_change_rate)
		knobs["compat_harshness"] = float(cp_now.compat_harshness)
		knobs["weather_penalty_scale"] = float(cp_now.vegetation_weather_penalty_scale)
		knobs["plant_water_balance_weight"] = float(cp_now.plant_water_balance_weight)
		knobs["plant_soil_buffer_weight"] = float(cp_now.plant_soil_buffer_weight)
		knobs["plant_drought_penalty"] = float(cp_now.plant_drought_penalty)
		knobs["succession_min_compat_gain"] = float(cp_now.succession_min_compat_gain)
		knobs["low_threshold"] = float(cp_now.vitality_low_threshold)
		knobs["high_threshold"] = float(cp_now.vitality_high_threshold)
		knobs["succession_degrade_days"] = int(cp_now.succession_degrade_days)
		knobs["succession_upgrade_days"] = int(cp_now.succession_upgrade_days)
		knobs["vegetation_degrade_reset_target"] = float(cp_now.vegetation_degrade_reset_target) if cp_now.get("vegetation_degrade_reset_target") != null else 0.75
		knobs["vegetation_low_vitality_damping_threshold"] = float(cp_now.vegetation_low_vitality_damping_threshold) if cp_now.get("vegetation_low_vitality_damping_threshold") != null else 0.40
		knobs["vegetation_succession_cooldown_days"] = int(cp_now.vegetation_succession_cooldown_days) if cp_now.get("vegetation_succession_cooldown_days") != null else 30
		knobs["vegetation_stress_enabled"] = bool(cp_now.vegetation_stress_enabled) if cp_now.get("vegetation_stress_enabled") != null else false
		knobs["vegetation_stress_memory_days"] = float(cp_now.vegetation_stress_memory_days) if cp_now.get("vegetation_stress_memory_days") != null else 30.0
		knobs["n_wt"] = int(WeatherType.WT.size())
		knobs["wt_clear_id"] = int(WeatherType.WT.CLEAR)
		knobs["wt_blizzard_id"] = int(WeatherType.WT.BLIZZARD)
		knobs["wt_drought_id"] = int(WeatherType.WT.DROUGHT)
		knobs["wt_heatwave_id"] = int(WeatherType.WT.HEATWAVE)
		knobs["veg_none_id"] = int(VegetationType.VEG.NONE)
		knobs["ideal_temp_table"] = context._generator._gdext_vegdyn_ideal_temp_cached
		knobs["ideal_moist_table"] = context._generator._gdext_vegdyn_ideal_moist_cached
		knobs["temp_tol_table"] = context._generator._gdext_vegdyn_temp_tol_cached
		knobs["moist_tol_table"] = context._generator._gdext_vegdyn_moist_tol_cached
		knobs["weather_penalty_table"] = context._generator._gdext_vegdyn_weather_penalty_cached
		knobs["resistance_table"] = context._generator._gdext_vegdyn_resistance_cached
		knobs["next_up_table"] = context._generator._gdext_vegdyn_next_up_cached
		knobs["next_down_table"] = context._generator._gdext_vegdyn_next_down_cached
	if run_feedback:
		var neighbor_indices: PackedInt32Array = map.neighbor_indices_packed() if map.has_indices() else PackedInt32Array()
		if neighbor_indices.size() < n_cells * 6:
			knobs["run_feedback"] = false
		else:
			var feedback_scale_eff: float = maxf(float(feedback_stride), 1.0)
			knobs["soil_gain"] = float(cp_now.weather_to_soil_gain)
			knobs["veg_gain"] = float(cp_now.weather_to_vegetation_gain)
			knobs["write_weather_veg_pressure"] = not run_veg_dyn
			knobs["scale"] = feedback_scale_eff
			knobs["per_day_clamp"] = float(cp_now.feedback_per_day_clamp) * feedback_scale_eff
			knobs["ocean_drift_gain"] = float(cp_now.ocean_moisture_drift_gain)
			knobs["wt_rain_id"] = int(WeatherType.WT.RAIN)
			knobs["wt_storm_id"] = int(WeatherType.WT.STORM)
			knobs["wt_monsoon_id"] = int(WeatherType.WT.MONSOON)
			knobs["wt_blizzard_id"] = int(WeatherType.WT.BLIZZARD)
			knobs["wt_drought_id"] = int(WeatherType.WT.DROUGHT)
			knobs["wt_heatwave_id"] = int(WeatherType.WT.HEATWAVE)
			knobs["neighbor_indices"] = neighbor_indices
	if not bool(knobs.get("run_albedo", false)) \
			and not bool(knobs.get("run_veg_dyn", false)) \
			and not bool(knobs.get("run_feedback", false)):
		return {}
	return knobs

static func _native_daily_season_cadence_policy(context, cp_now, call_index: int) -> Dictionary:
	var albedo_stride: int = maxi(1, int(cp_now.weather_albedo_stride)) if cp_now != null else 10
	var veg_dyn_stride: int = maxi(1, int(cp_now.weather_vegetation_dynamics_stride)) if cp_now != null else 10
	var feedback_stride: int = maxi(1, int(cp_now.weather_feedback_stride)) if cp_now != null else 10
	var season_period_ticks: int = 1
	var season_period_counter: int = 0
	if context._generator._season_refresh_job != null:
		if context._generator._season_refresh_job.get("period_ticks") != null:
			season_period_ticks = maxi(1, int(context._generator._season_refresh_job.period_ticks))
		if context._generator._season_refresh_job.get("_period_counter") != null:
			season_period_counter = int(context._generator._season_refresh_job._period_counter)
	var run_albedo: bool = (call_index % albedo_stride) == 0
	var run_veg_dyn: bool = (call_index % veg_dyn_stride) == 0
	var run_feedback: bool = (call_index % feedback_stride) == 0 \
			and cp_now != null and bool(cp_now.fast_slow_layering_enabled)
	if run_veg_dyn and context._generator._world_clock_ref != null and context._generator._world_clock_ref.has_method("day_index"):
		if int(context._generator._world_clock_ref.day_index()) == context._generator._last_season_refresh_day:
			run_veg_dyn = false
	return {
		"owner": "native_graph_policy",
		"policy_state": "native_ready",
		"stage_b_call_index": call_index,
		"stage_b_strides": {
			"albedo": albedo_stride,
			"vegetation_dynamics": veg_dyn_stride,
			"feedback": feedback_stride,
		},
		"stage_b_should_run": {
			"albedo": run_albedo,
			"vegetation_dynamics": run_veg_dyn,
			"feedback": run_feedback,
		},
		"vegetation_owner": "vegetation_dynamics",
		"season_vegetation_rewrite": false,
		"stage_b_any": run_albedo or run_veg_dyn or run_feedback,
		"season_period_ticks": season_period_ticks,
		"season_period_counter": season_period_counter,
		"season_should_advance": season_period_counter <= 0,
		"simulation_slot_dirty_intents": [
			"cell_terrain",
			"cell_landform",
			"cell_vegetation",
			"cell_cover",
			"cell_moisture",
			"cell_base_moisture",
			"cell_weather_dirty",
		],
		"visual_dirty_intents": [
			"enum_atlas",
			"detail_scatter",
		],
		"remaining_godot_boundary_authority": [
			"atlas_queue_execution",
			"detail_scatter_execution",
		],
	}

static func _build_native_daily_climate_pass_a_struct(context, map: MapData, cp_now, season_phase: float) -> Dictionary:
	if map == null or cp_now == null or context._generator._last_cfg == null:
		return {}
	var days_per_year: int = context._generator._calendar_days_per_year()
	var d: Dictionary = {
		"use_insol": true,
		"use_sparse": bool(cp_now.use_sparse_climate),
		"insol_amp": float(cp_now.get("season_temp_amp")) if cp_now.get("season_temp_amp") != null else 0.20,
		"insol_gain": float(cp_now.get("insolation_season_gain")) if cp_now.get("insolation_season_gain") != null else 1.0,
		"moist_scale_now": 1.0,
		"runtime_moisture_base_relax_rate": float(cp_now.get("runtime_moisture_base_relax_rate")) if cp_now.get("runtime_moisture_base_relax_rate") != null else 0.24,
		"runtime_moisture_weather_vapor_weight": float(cp_now.get("runtime_moisture_weather_vapor_weight")) if cp_now.get("runtime_moisture_weather_vapor_weight") != null else 0.12,
		"runtime_moisture_precip_weight": float(cp_now.get("runtime_moisture_precip_weight")) if cp_now.get("runtime_moisture_precip_weight") != null else 0.78,
		"runtime_moisture_soil_weight": float(cp_now.get("runtime_moisture_soil_weight")) if cp_now.get("runtime_moisture_soil_weight") != null else 1.82,
		"runtime_moisture_soil_dry_weight": float(cp_now.get("runtime_moisture_soil_dry_weight")) if cp_now.get("runtime_moisture_soil_dry_weight") != null else 2.21,
		"runtime_moisture_water_balance_weight": float(cp_now.get("runtime_moisture_water_balance_weight")) if cp_now.get("runtime_moisture_water_balance_weight") != null else 1.04,
		"runtime_moisture_water_balance_dry_weight": float(cp_now.get("runtime_moisture_water_balance_dry_weight")) if cp_now.get("runtime_moisture_water_balance_dry_weight") != null else 1.30,
		"season_phase": float(season_phase),
		"days_per_year": days_per_year,
		"axial_tilt_deg": float(cp_now.get("axial_tilt_deg")) if cp_now.get("axial_tilt_deg") != null else 23.5,
		"day_length_gain": float(cp_now.get("insolation_daylen_amp")) if cp_now.get("insolation_daylen_amp") != null else 0.35,
		"solar_gain": float(cp_now.get("solar_gain")) if cp_now.get("solar_gain") != null else 1.0,
		"insol_dev_min": float(cp_now.get("insolation_dev_clamp_min")) if cp_now.get("insolation_dev_clamp_min") != null else -1.0,
		"insol_dev_max": float(cp_now.get("insolation_dev_clamp_max")) if cp_now.get("insolation_dev_clamp_max") != null else 1.0,
		"thermal_inertia_land": float(cp_now.get("thermal_inertia_land")) if cp_now.get("thermal_inertia_land") != null else 0.35,
		"thermal_inertia_water": float(cp_now.get("thermal_inertia_water")) if cp_now.get("thermal_inertia_water") != null else 0.045,
		"thermal_inertia_snow": float(cp_now.get("thermal_inertia_snow")) if cp_now.get("thermal_inertia_snow") != null else 0.09,
		"thermal_inertia_high_mountain": float(cp_now.get("thermal_inertia_high_mountain")) if cp_now.get("thermal_inertia_high_mountain") != null else 0.16,
		"thermal_daily_delta_cap": float(cp_now.get("thermal_daily_delta_cap")) if cp_now.get("thermal_daily_delta_cap") != null else 0.15,
		"temp_land_continentality": float(cp_now.get("temp_land_continentality")) if cp_now.get("temp_land_continentality") != null else 1.0,
		"thermal_dt_days": context._generator._consume_climate_dt_days(),
		"snowpack_cover_low": float(cp_now.get("snowpack_cover_low")) if cp_now.get("snowpack_cover_low") != null else 0.05,
		"snowpack_cover_full": float(cp_now.get("snowpack_cover_full")) if cp_now.get("snowpack_cover_full") != null else 0.32,
		"sea_level": float(context._generator._last_cfg.sea_level),
	}
	# [climate-zone-fix P2] 沿海海洋性调温：传入衰减比 + per-cell maritime 因子（缓存）。
	# damp<=0 时不附 maritime_factor（C++ 端 damp=0 即退化为原行为，避免无谓 BFS/拷贝）。
	var m_damp: float = float(cp_now.get("maritime_season_damp")) if cp_now.get("maritime_season_damp") != null else 0.0
	d["maritime_season_damp"] = m_damp
	if m_damp > 0.0:
		var decay: float = float(cp_now.get("maritime_decay_cells")) if cp_now.get("maritime_decay_cells") != null else 4.0
		d["maritime_factor"] = context._generator._ensure_maritime_factor(map, decay)
	return d

static func _build_native_daily_climate_pass_b_knobs(context, map: MapData, cp_now, season_phase: float) -> Dictionary:
	if map == null or cp_now == null or context._generator._last_cfg == null or not bool(cp_now.enable_local_climate_coupling):
		return {}
	var nb_idx: PackedInt32Array = map.neighbor_indices_packed()
	var n_cells: int = map.soa_size()
	if n_cells <= 0 or nb_idx.size() < n_cells * 6:
		return {}
	var tta_arr: PackedFloat32Array = map.temperature_transport_anomaly_arr
	if tta_arr.size() != n_cells:
		var cells: Array = map.iter_cells()
		tta_arr = PackedFloat32Array()
		tta_arr.resize(n_cells)
		for i in range(n_cells):
			tta_arr[i] = float((cells[i] as HexCell).temperature_transport_anomaly)
	return {
		"n_cells": n_cells,
		"winter_boost": 1.0,
		"snow_cool": float(cp_now.snow_albedo_cooling),
		"veg_cool": float(cp_now.vegetation_cooling),
		"diurnal_amp": float(cp_now.landform_diurnal_amp),
		"evap_gain": float(cp_now.evaporation_gain),
		"rs_threshold": float(cp_now.rain_shadow_threshold),
		"rs_factor": float(cp_now.rain_shadow_factor),
		"rs_lookback": max(0, int(cp_now.rain_shadow_lookback)),
		"t_freeze": float(cp_now.sea_ice_form_threshold),
		"coupling_gain": float(cp_now.ocean_moisture_coupling_gain),
		"coast_leak": float(context._generator._last_cfg.COASTAL_HEAT_LEAK),
		"sea_ice_albedo_cooling": float(cp_now.sea_ice_albedo_cooling) if cp_now.get("sea_ice_albedo_cooling") != null else 0.01,
		"sea_ice_frac": map.sea_ice_frac_arr,
		"snowpack_cover_low": float(cp_now.snowpack_cover_low) if cp_now.get("snowpack_cover_low") != null else 0.05,
		"snowpack_cover_full": float(cp_now.snowpack_cover_full) if cp_now.get("snowpack_cover_full") != null else 0.32,
		"season_phase": season_phase,
		"go_sparse": false,
		"neighbor_indices": nb_idx,
		"temp_transport_anomaly": tta_arr,
		"foliage_table": context._generator._build_climate_b_foliage_table(),
	}

static func _build_native_daily_transpiration_knobs(context, map: MapData, cp_now) -> Dictionary:
	if map == null or cp_now == null:
		return {}
	var n_cells: int = map.cell_count()
	var neighbor_indices: PackedInt32Array = map.neighbor_indices_packed() if map.has_indices() else PackedInt32Array()
	if n_cells <= 0 or neighbor_indices.size() < n_cells * 6:
		return {}
	return {
		"n_cells": n_cells,
		"outflow_rate": float(cp_now.transpiration_outflow_rate),
		"self_rate": float(cp_now.transpiration_self_rate),
		"neighbor_indices": neighbor_indices,
		"donor_table": context._generator._build_transpiration_donor_table(),
	}

static func _build_native_daily_wind_knobs(context, map: MapData, cp_now) -> Dictionary:
	if map == null or cp_now == null or context._generator._last_cfg == null:
		return {}
	var wind_heat_enabled: bool = true
	if cp_now.get("enable_wind_heat_transport") != null:
		wind_heat_enabled = bool(cp_now.enable_wind_heat_transport)
	if not wind_heat_enabled:
		return {}
	var n: int = map.soa_size()
	var nb_idx: PackedInt32Array = map.neighbor_indices_packed()
	if n <= 0 or nb_idx.size() < n * 6 or map.temp_arr.size() < n:
		return {}
	var baseline: PackedFloat32Array = context._generator._build_native_wind_baseline(map)
	if baseline.size() != n:
		return {}
	var air_knobs: Dictionary = {
		"n_cells": n,
		"advect_steps": max(0, context._generator._last_cfg.WIND_HEAT_ADVECT_STEPS),
		"heat_mix": clampf(context._generator._last_cfg.WIND_HEAT_MIX, 0.0, 1.0),
		"neighbor_indices": nb_idx,
		"baseline_arr": baseline,
	}
	if context._generator._supports_wind_air_slot_temp():
		air_knobs["read_temp_from_slot"] = true
	else:
		if context._generator._gdext_wind_temp_before_work_buf.size() != n:
			context._generator._gdext_wind_temp_before_work_buf.resize(n)
		var temp_before: PackedFloat32Array = context._generator._gdext_wind_temp_before_work_buf
		var temp_a: PackedFloat32Array = map.temp_arr
		# Inline the NaN/inf guard (was a per-cell function call) on this hot loop.
		for i in range(n):
			var t0: float = temp_a[i]
			temp_before[i] = baseline[i] if (is_nan(t0) or is_inf(t0)) else t0
		air_knobs["temp_before_arr"] = temp_before
	return {
		"air": air_knobs,
		"surface": {
			"n_cells": n,
			"air_leak": float(context._generator._last_cfg.AIR_MASS_HEAT_LEAK),
			"neighbor_indices": nb_idx,
			"fallback_baseline_arr": baseline,
			"cold_transport_form_threshold": float(cp_now.sea_ice_form_threshold),
			"cold_transport_melt_threshold": float(cp_now.sea_ice_melt_threshold),
		},
	}

static func _native_daily_ema_all_initialized(context, map: MapData, ema_init: PackedByteArray, n: int) -> bool:
	if map == null or n <= 0 or ema_init.size() < n:
		return false
	if context._generator._native_daily_ema_all_initialized_cache_true \
			and context._generator._native_daily_ema_all_initialized_cache_map == map \
			and context._generator._native_daily_ema_all_initialized_cache_size == n:
		return true
	for i in range(n):
		if ema_init[i] == 0:
			context._generator._native_daily_ema_all_initialized_cache_map = map
			context._generator._native_daily_ema_all_initialized_cache_size = n
			context._generator._native_daily_ema_all_initialized_cache_true = false
			return false
	context._generator._native_daily_ema_all_initialized_cache_map = map
	context._generator._native_daily_ema_all_initialized_cache_size = n
	context._generator._native_daily_ema_all_initialized_cache_true = true
	return true

static func _build_native_daily_ocean_knobs(context, map: MapData, cp_now, season_phase: float) -> Dictionary:
	if map == null or cp_now == null or context._generator._last_cfg == null or not bool(context._generator._last_cfg.enable_ocean_heat_transport):
		return {}
	var n: int = map.soa_size()
	var nb_idx: PackedInt32Array = map.neighbor_indices_packed()
	if n <= 0 or nb_idx.size() < n * 6:
		return {}
	var dc_views: Dictionary = context._generator._climate_views_from_world(cp_now)
	var use_dc: bool = not dc_views.is_empty()
	var temp_a: PackedFloat32Array = dc_views["temp"] if use_dc else map.temp_arr
	var temp_baseline_a: PackedFloat32Array = dc_views["temp_baseline"] if use_dc \
			else _native_daily_live_f32(context, "cell_temp_baseline", map.temp_baseline_arr, n)
	var elev_a: PackedFloat32Array = dc_views["elevation"] if use_dc else map.elevation_arr
	var lat_a: PackedFloat32Array = dc_views["lat_norm"] if use_dc else map.cell_lat_norm_arr
	var ema_init_a: PackedByteArray = dc_views["ema_initialized"] if use_dc \
			else _native_daily_live_u8(context, "cell_ema_initialized", map.ema_initialized_arr, n)
	var ocx_a: PackedFloat32Array = dc_views["ocean_current_x"] if use_dc else map.ocean_current_x_arr
	var ocy_a: PackedFloat32Array = dc_views["ocean_current_y"] if use_dc else map.ocean_current_y_arr
	if temp_a.size() < n or elev_a.size() < n:
		return {}
	if context._generator._gdext_ocean_temp_before_work_buf.size() != n:
		context._generator._gdext_ocean_temp_before_work_buf.resize(n)
	if context._generator._gdext_ocean_anomaly_work_buf.size() != n:
		context._generator._gdext_ocean_anomaly_work_buf.resize(n)
	var baseline_direct: bool = _native_daily_ema_all_initialized(context, map, ema_init_a, n) \
			and temp_baseline_a.size() >= n
	var baseline: PackedFloat32Array = temp_baseline_a if baseline_direct else context._generator._gdext_ocean_baseline_work_buf
	if not baseline_direct and context._generator._gdext_ocean_baseline_work_buf.size() != n:
		context._generator._gdext_ocean_baseline_work_buf.resize(n)
		baseline = context._generator._gdext_ocean_baseline_work_buf
	var temp_before: PackedFloat32Array = context._generator._gdext_ocean_temp_before_work_buf
	var cells: Array = []
	if not baseline_direct:
		# Cold/repair path only. Steady native generation initializes EMA for every
		# cell, so the hot path can reuse temp_baseline_a directly and avoid both
		# HexCell facade allocation and a full baseline rebuild loop.
		cells = map.iter_cells()
		var ema_n: int = ema_init_a.size()
		var tb_n: int = temp_baseline_a.size()
		var lat_n: int = lat_a.size()
		for i in range(n):
			var bi: float
			if i < ema_n and ema_init_a[i] != 0 and i < tb_n:
				bi = temp_baseline_a[i]
			else:
				var ny: float = lat_a[i] if i < lat_n else context._generator._cube_row_norm(cells[i], context._generator._last_cfg)
				bi = context._generator._compute_temperature(ny, elev_a[i])
			baseline[i] = bi
			var t0: float = temp_a[i]
			temp_before[i] = bi if (is_nan(t0) or is_inf(t0)) else t0
	else:
		for i in range(n):
			var bi: float = baseline[i]
			var t0: float = temp_a[i]
			temp_before[i] = bi if (is_nan(t0) or is_inf(t0)) else t0
	# Fill the anomaly work buffer in place from the prev-TTA source, mirroring
	# _generator._prepare_temperature_transport_anomaly_state(prefer_cached=false) priority
	# (map > cached > cells) but without its extra allocation + second copy loop.
	var anomaly: PackedFloat32Array = context._generator._gdext_ocean_anomaly_work_buf
	var src_tta: PackedFloat32Array = map.temperature_transport_anomaly_arr
	if src_tta.size() == n:
		for ai in range(n):
			anomaly[ai] = src_tta[ai]
	elif context._generator._gdext_ocean_anomaly_buf_cached.size() == n:
		var cached_tta: PackedFloat32Array = context._generator._gdext_ocean_anomaly_buf_cached
		for ai in range(n):
			anomaly[ai] = cached_tta[ai]
	else:
		if cells.is_empty():
			cells = map.iter_cells()
		if cells.size() == n:
			for ai in range(n):
				var cell = cells[ai]
				anomaly[ai] = float((cell as HexCell).temperature_transport_anomaly) if cell != null else 0.0
		else:
			for ai in range(n):
				anomaly[ai] = 0.0
	var winter_boost: float = 1.0
	var tta: Dictionary = context._generator._temperature_transport_anomaly_knobs(cp_now)
	var ocean_thread_enabled: bool = bool(cp_now.native_daily_ocean_thread_variant_enabled) \
			if cp_now.get("native_daily_ocean_thread_variant_enabled") != null else false
	var ocean_thread_tasks: int = clampi(int(cp_now.native_daily_ocean_thread_tasks), 0, 16) \
			if cp_now.get("native_daily_ocean_thread_tasks") != null else 0
	var water_knobs: Dictionary = {
		"n_cells": n,
		"advect_steps": max(0, context._generator._last_cfg.OCEAN_HEAT_ADVECT_STEPS),
		"heat_mix": clampf(context._generator._last_cfg.OCEAN_HEAT_MIX, 0.0, 1.0),
		"neighbor_indices": nb_idx,
		"baseline_arr": baseline,
		"temp_before_arr": temp_before,
		"anomaly_out": anomaly,
		"ocean_current_x_arr": ocx_a,
		"ocean_current_y_arr": ocy_a,
		"cold_transport_form_threshold": float(cp_now.sea_ice_form_threshold),
		"cold_transport_melt_threshold": float(cp_now.sea_ice_melt_threshold),
		"native_daily_thread_variant_enabled": ocean_thread_enabled,
		"native_daily_thread_tasks": ocean_thread_tasks,
	}
	var land_knobs: Dictionary = {
		"n_cells": n,
		"effective_leak": float(context._generator._last_cfg.COASTAL_HEAT_LEAK) * winter_boost,
		"neighbor_indices": nb_idx,
		"anomaly_inout": anomaly,
		"fallback_baseline_arr": baseline,
		"ocean_current_x_arr": ocx_a,
		"ocean_current_y_arr": ocy_a,
		"native_daily_thread_variant_enabled": ocean_thread_enabled,
		"native_daily_thread_tasks": ocean_thread_tasks,
	}
	context._generator._apply_temperature_transport_anomaly_knobs(water_knobs, tta)
	context._generator._apply_temperature_transport_anomaly_knobs(land_knobs, tta)
	return {
		"water": water_knobs,
		"land": land_knobs,
	}

static func _build_native_daily_sea_ice_knobs(context,
		map: MapData,
		cp_now,
		season_phase: float,
		commit_side_effects: bool,
		dt_cap_days: float = 30.0) -> Dictionary:
	if map == null or cp_now == null or context._generator._last_cfg == null:
		return {}
	var cells_fast: Array = map.iter_cells() if map.has_indices() else map.all_cells()
	var n_cells_fast: int = cells_fast.size()
	var nb_idx_fast: PackedInt32Array = map.neighbor_indices_packed() if map.has_indices() else PackedInt32Array()
	if n_cells_fast <= 0 or nb_idx_fast.size() < n_cells_fast * 6:
		return {}
	var k_freeze: float = float(cp_now.sea_ice_freeze_rate)
	var k_melt: float = float(cp_now.sea_ice_melt_rate)
	var t_form: float = float(cp_now.sea_ice_form_threshold)
	var t_melt: float = float(cp_now.sea_ice_melt_threshold)
	var climate_anomaly_now: float = 0.0
	if context._generator._world_clock_ref != null:
		var ca_v = context._generator._world_clock_ref.get("climate_anomaly")
		if ca_v != null:
			climate_anomaly_now = float(ca_v)
	if not is_equal_approx(climate_anomaly_now, 0.0):
		var ice_thr_shift: float = 0.10 * climate_anomaly_now
		t_form = clampf(t_form - ice_thr_shift, 0.0, 1.0)
		t_melt = clampf(t_melt - ice_thr_shift, 0.0, 1.0)
	var dt_days: float = context._generator._consume_sea_ice_dt_days(dt_cap_days) if commit_side_effects else 1.0
	var base_terrain_input: PackedByteArray
	if map.base_terrain_arr.size() == n_cells_fast:
		base_terrain_input = map.base_terrain_arr
	else:
		if context._generator._gdext_sea_ice_base_terrain_buf.size() != n_cells_fast:
			context._generator._gdext_sea_ice_base_terrain_buf.resize(n_cells_fast)
		base_terrain_input = context._generator._gdext_sea_ice_base_terrain_buf
		for i_build in range(n_cells_fast):
			var c_build: HexCell = cells_fast[i_build]
			context._generator._gdext_sea_ice_base_terrain_buf[i_build] = int(c_build.base_terrain) & 0xFF
	var tta_input: PackedFloat32Array
	if context._generator._gdext_ocean_anomaly_buf_cached.size() == n_cells_fast:
		tta_input = context._generator._gdext_ocean_anomaly_buf_cached
	elif map.temperature_transport_anomaly_arr.size() == n_cells_fast:
		tta_input = map.temperature_transport_anomaly_arr
	else:
		if context._generator._gdext_sea_ice_tta_buf.size() != n_cells_fast:
			context._generator._gdext_sea_ice_tta_buf.resize(n_cells_fast)
		tta_input = context._generator._gdext_sea_ice_tta_buf
		for i_tta in range(n_cells_fast):
			tta_input[i_tta] = cells_fast[i_tta].temperature_transport_anomaly
	var upw_input: PackedFloat32Array = map.upwelling_strength_arr \
			if map.upwelling_strength_arr.size() == n_cells_fast \
			else context._generator._gdext_sea_ice_upw_buf
	if upw_input.size() != n_cells_fast:
		context._generator._gdext_sea_ice_upw_buf.resize(n_cells_fast)
		upw_input = context._generator._gdext_sea_ice_upw_buf
		for i_upw in range(n_cells_fast):
			upw_input[i_upw] = cells_fast[i_upw].upwelling_strength
	var temp_input: PackedFloat32Array = map.temp_arr \
			if map.temp_arr.size() == n_cells_fast \
			else context._generator._gdext_sea_ice_temp_buf
	if temp_input.size() != n_cells_fast:
		context._generator._gdext_sea_ice_temp_buf.resize(n_cells_fast)
		temp_input = context._generator._gdext_sea_ice_temp_buf
		for i_temp in range(n_cells_fast):
			temp_input[i_temp] = cells_fast[i_temp].temperature
	var insol_input: PackedFloat32Array = context._generator._sea_ice_insolation_input(map, cells_fast, season_phase)
	var water_ids: PackedByteArray = PackedByteArray([
		int(TerrainType.TERRAIN.OCEAN) & 0xFF,
		int(TerrainType.TERRAIN.COAST) & 0xFF,
		int(TerrainType.TERRAIN.LAKE) & 0xFF,
		int(TerrainType.TERRAIN.REEF) & 0xFF,
		int(TerrainType.TERRAIN.KELP) & 0xFF,
		int(TerrainType.TERRAIN.SEA_ICE) & 0xFF,
	])
	return {
		"n_cells": n_cells_fast,
		"k_freeze": k_freeze,
		"k_melt": k_melt,
		"dt_days": dt_days,
		"t_form": t_form,
		"t_melt": t_melt,
		"contagion": float(cp_now.sea_ice_neighbor_contagion),
		"threshold": float(cp_now.sea_ice_terrain_threshold),
		"hysteresis": float(cp_now.sea_ice_terrain_hysteresis),
		"ice_delay": float(context._generator._last_cfg.OCEAN_CURRENT_ICE_DELAY),
		"enable_ocean_heat_transport": bool(context._generator._last_cfg.enable_ocean_heat_transport),
		"terrain_lake_id": int(TerrainType.TERRAIN.LAKE),
		"terrain_sea_ice_id": int(TerrainType.TERRAIN.SEA_ICE),
		"terrain_ocean_id": int(TerrainType.TERRAIN.OCEAN),
		"water_terrain_ids": water_ids,
		"neighbor_indices": nb_idx_fast,
		"base_terrain_arr": base_terrain_input,
		"temp_transport_anomaly": tta_input,
		"upwelling_strength": upw_input,
		"insolation_now_arr": insol_input,
		"solar_gate_enabled": context._generator._sea_ice_solar_gate_enabled(cp_now),
		"freeze_insol_low": float(cp_now.sea_ice_freeze_insol_low),
		"freeze_insol_high": float(cp_now.sea_ice_freeze_insol_high),
		"solar_melt_start": float(cp_now.sea_ice_solar_melt_start),
		"solar_melt_gain": float(cp_now.sea_ice_solar_melt_gain),
		"min_thick_ice_solar_exposure": float(cp_now.sea_ice_min_thick_ice_solar_exposure) if cp_now.get("sea_ice_min_thick_ice_solar_exposure") != null else 0.32,
		"daily_delta_cap": float(cp_now.sea_ice_daily_delta_cap) if cp_now.get("sea_ice_daily_delta_cap") != null else 0.070,
		"edge_mix_rate": float(cp_now.sea_ice_edge_mix_rate) if cp_now.get("sea_ice_edge_mix_rate") != null else 0.035,
		"cell_temperature_arr": temp_input,
		"apply_terrain_flips": commit_side_effects,
	}

static func _build_native_daily_runtime_hydrology_knobs(context, map: MapData, cp_now,
		dt_days: float = 1.0) -> Dictionary:
	if map == null or cp_now == null:
		return {}
	if cp_now.get("runtime_hydrology_enabled") == null \
			or not bool(cp_now.runtime_hydrology_enabled):
		return {}
	if context._generator._data_core_world_ext == null:
		return {}
	return {
		"n_cells": map.cell_count(),
		"dt_days": clampf(dt_days, 1.0, 30.0),
		"neighbor_indices": map.neighbor_indices_packed() if map.has_indices() else PackedInt32Array(),
		"hydro_precip_scale": float(cp_now.hydro_precip_scale),
		"hydro_snowmelt_scale": float(cp_now.hydro_snowmelt_scale),
		"hydro_soil_capacity": float(cp_now.hydro_soil_capacity),
		"hydro_infiltration_rate": float(cp_now.hydro_infiltration_rate),
		"hydro_quickflow_fraction": float(cp_now.hydro_quickflow_fraction),
		"hydro_baseflow_recession": float(cp_now.hydro_baseflow_recession),
		"hydro_channel_release_rate": float(cp_now.hydro_channel_release_rate),
		"hydro_lake_release_rate": float(cp_now.hydro_lake_release_rate),
		"hydro_discharge_ema": float(cp_now.hydro_discharge_ema),
		"hydro_bank_moisture_gain": float(cp_now.hydro_bank_moisture_gain),
		"hydro_river_moisture_floor": float(cp_now.hydro_river_moisture_floor),
		"hydro_riparian_moisture_floor": float(cp_now.hydro_riparian_moisture_floor),
		"hydro_river_evap_gain": float(cp_now.hydro_river_evap_gain),
		"hydro_moisture_response_rate": float(cp_now.hydro_moisture_response_rate),
		"hydro_flood_threshold": float(cp_now.hydro_flood_threshold),
		"hydro_flood_decay": float(cp_now.hydro_flood_decay),
		"snowpack_melt_temp_gain": float(cp_now.snowpack_melt_temp_gain),
		"snowpack_melt_sun_gain": float(cp_now.snowpack_melt_sun_gain),
		"plant_water_balance_weight": float(cp_now.plant_water_balance_weight),
		"plant_soil_buffer_weight": float(cp_now.plant_soil_buffer_weight),
		"plant_drought_penalty": float(cp_now.plant_drought_penalty),
	}
