extends "res://scripts/simulation/generator_context.gd"

## Native daily graph input bundle construction. Mutable cursors and caches remain on MapGenerator.

func _native_daily_live_f32(slot_name: String, fallback: PackedFloat32Array,
		n: int) -> PackedFloat32Array:
	if _generator._data_core_world_ext == null:
		return fallback
	var sid: int = int(_generator._data_core_world_ext.component_id(slot_name))
	if sid < 0:
		return fallback
	var live: PackedFloat32Array = _generator._data_core_world_ext.snapshot_f32(sid)
	return live if live.size() == n else fallback

func _native_daily_live_u8(slot_name: String, fallback: PackedByteArray,
		n: int) -> PackedByteArray:
	if _generator._data_core_world_ext == null:
		return fallback
	var sid: int = int(_generator._data_core_world_ext.component_id(slot_name))
	if sid < 0:
		return fallback
	var live: PackedByteArray = _generator._data_core_world_ext.snapshot_u8(sid)
	return live if live.size() == n else fallback

func _native_daily_base_tick_knobs(ctx: SusTickContext) -> Dictionary:
	var season_idx: int = 0
	if _generator._world_clock_ref != null and _generator._world_clock_ref.has_method("season_index"):
		season_idx = int(_generator._world_clock_ref.season_index())
	var days_per_year: int = _generator._calendar_days_per_year()
	var day_of_year: int = _generator._season_phase_to_day_of_year(ctx.season_phase, days_per_year)
	if _generator._world_clock_ref != null and _generator._world_clock_ref.has_method("day_in_year"):
		day_of_year = clampi(int(_generator._world_clock_ref.day_in_year()), 0, days_per_year - 1)
	var anomaly: float = 0.0
	if _generator._world_clock_ref != null:
		var v = _generator._world_clock_ref.get("climate_anomaly")
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

func _build_native_daily_stage_b_knobs(map: MapData, cp_now, call_index: int,
		elapsed_days_per_call: float = 1.0) -> Dictionary:
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
	if run_veg_dyn and _generator._world_clock_ref != null and _generator._world_clock_ref.has_method("day_index"):
		if int(_generator._world_clock_ref.day_index()) == _generator._last_season_refresh_day:
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
		knobs["albedo_table"] = _generator._build_albedo_donor_table()
	if run_veg_dyn:
		_generator._ensure_vegdyn_lut()
		# stage_b 的 stride 以“调用次数”计，而原生 daily graph 本身也可能跨多天调用。
		# 两层 cadence 必须相乘，才能让 vitality / succession streak 按真实游戏日推进。
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
		knobs["ideal_temp_table"] = _generator._gdext_vegdyn_ideal_temp_cached
		knobs["ideal_moist_table"] = _generator._gdext_vegdyn_ideal_moist_cached
		knobs["temp_tol_table"] = _generator._gdext_vegdyn_temp_tol_cached
		knobs["moist_tol_table"] = _generator._gdext_vegdyn_moist_tol_cached
		knobs["weather_penalty_table"] = _generator._gdext_vegdyn_weather_penalty_cached
		knobs["resistance_table"] = _generator._gdext_vegdyn_resistance_cached
		knobs["next_up_table"] = _generator._gdext_vegdyn_next_up_cached
		knobs["next_down_table"] = _generator._gdext_vegdyn_next_down_cached
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

func _native_daily_season_cadence_policy(cp_now, call_index: int) -> Dictionary:
	var albedo_stride: int = maxi(1, int(cp_now.weather_albedo_stride)) if cp_now != null else 10
	var veg_dyn_stride: int = maxi(1, int(cp_now.weather_vegetation_dynamics_stride)) if cp_now != null else 10
	var feedback_stride: int = maxi(1, int(cp_now.weather_feedback_stride)) if cp_now != null else 10
	var season_period_ticks: int = 1
	var season_period_counter: int = 0
	if _generator._season_refresh_job != null:
		if _generator._season_refresh_job.get("period_ticks") != null:
			season_period_ticks = maxi(1, int(_generator._season_refresh_job.period_ticks))
		if _generator._season_refresh_job.get("_period_counter") != null:
			season_period_counter = int(_generator._season_refresh_job._period_counter)
	var run_albedo: bool = (call_index % albedo_stride) == 0
	var run_veg_dyn: bool = (call_index % veg_dyn_stride) == 0
	var run_feedback: bool = (call_index % feedback_stride) == 0 \
			and cp_now != null and bool(cp_now.fast_slow_layering_enabled)
	if run_veg_dyn and _generator._world_clock_ref != null and _generator._world_clock_ref.has_method("day_index"):
		if int(_generator._world_clock_ref.day_index()) == _generator._last_season_refresh_day:
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

func _build_native_daily_climate_pass_a_struct(map: MapData, cp_now, season_phase: float) -> Dictionary:
	if map == null or cp_now == null or _generator._last_cfg == null:
		return {}
	var days_per_year: int = _generator._calendar_days_per_year()
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
		"thermal_dt_days": _generator._consume_climate_dt_days(),
		"snowpack_cover_low": float(cp_now.get("snowpack_cover_low")) if cp_now.get("snowpack_cover_low") != null else 0.05,
		"snowpack_cover_full": float(cp_now.get("snowpack_cover_full")) if cp_now.get("snowpack_cover_full") != null else 0.32,
		"sea_level": float(_generator._last_cfg.sea_level),
	}
	# [climate-zone-fix P2] 沿海海洋性调温：传入衰减比 + per-cell maritime 因子（缓存）。
	# damp<=0 时不附 maritime_factor（C++ 端 damp=0 即退化为原行为，避免无谓 BFS/拷贝）。
	var m_damp: float = float(cp_now.get("maritime_season_damp")) if cp_now.get("maritime_season_damp") != null else 0.0
	d["maritime_season_damp"] = m_damp
	if m_damp > 0.0:
		var decay: float = float(cp_now.get("maritime_decay_cells")) if cp_now.get("maritime_decay_cells") != null else 4.0
		d["maritime_factor"] = _generator._ensure_maritime_factor(map, decay)
	return d

func _build_native_daily_climate_pass_b_knobs(map: MapData, cp_now, season_phase: float) -> Dictionary:
	if map == null or cp_now == null or _generator._last_cfg == null or not bool(cp_now.enable_local_climate_coupling):
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
		"coast_leak": float(_generator._last_cfg.COASTAL_HEAT_LEAK),
		"sea_ice_albedo_cooling": float(cp_now.sea_ice_albedo_cooling) if cp_now.get("sea_ice_albedo_cooling") != null else 0.01,
		"sea_ice_frac": map.sea_ice_frac_arr,
		"snowpack_cover_low": float(cp_now.snowpack_cover_low) if cp_now.get("snowpack_cover_low") != null else 0.05,
		"snowpack_cover_full": float(cp_now.snowpack_cover_full) if cp_now.get("snowpack_cover_full") != null else 0.32,
		"season_phase": season_phase,
		"go_sparse": false,
		"neighbor_indices": nb_idx,
		"temp_transport_anomaly": tta_arr,
		"foliage_table": _generator._build_climate_b_foliage_table(),
	}

func _build_native_daily_transpiration_knobs(map: MapData, cp_now) -> Dictionary:
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
		"donor_table": _generator._build_transpiration_donor_table(),
	}

func _build_native_daily_wind_knobs(map: MapData, cp_now) -> Dictionary:
	if map == null or cp_now == null or _generator._last_cfg == null:
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
	var baseline: PackedFloat32Array = _generator._build_native_wind_baseline(map)
	if baseline.size() != n:
		return {}
	var air_knobs: Dictionary = {
		"n_cells": n,
		"advect_steps": max(0, _generator._last_cfg.WIND_HEAT_ADVECT_STEPS),
		"heat_mix": clampf(_generator._last_cfg.WIND_HEAT_MIX, 0.0, 1.0),
		"neighbor_indices": nb_idx,
		"baseline_arr": baseline,
	}
	if _generator._supports_wind_air_slot_temp():
		air_knobs["read_temp_from_slot"] = true
	else:
		if _generator._gdext_wind_temp_before_work_buf.size() != n:
			_generator._gdext_wind_temp_before_work_buf.resize(n)
		var temp_before: PackedFloat32Array = _generator._gdext_wind_temp_before_work_buf
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
			"air_leak": float(_generator._last_cfg.AIR_MASS_HEAT_LEAK),
			"neighbor_indices": nb_idx,
			"fallback_baseline_arr": baseline,
			"cold_transport_form_threshold": float(cp_now.sea_ice_form_threshold),
			"cold_transport_melt_threshold": float(cp_now.sea_ice_melt_threshold),
		},
	}

func _native_daily_ema_all_initialized(map: MapData, ema_init: PackedByteArray, n: int) -> bool:
	if map == null or n <= 0 or ema_init.size() < n:
		return false
	if _generator._native_daily_ema_all_initialized_cache_true \
			and _generator._native_daily_ema_all_initialized_cache_map == map \
			and _generator._native_daily_ema_all_initialized_cache_size == n:
		return true
	for i in range(n):
		if ema_init[i] == 0:
			_generator._native_daily_ema_all_initialized_cache_map = map
			_generator._native_daily_ema_all_initialized_cache_size = n
			_generator._native_daily_ema_all_initialized_cache_true = false
			return false
	_generator._native_daily_ema_all_initialized_cache_map = map
	_generator._native_daily_ema_all_initialized_cache_size = n
	_generator._native_daily_ema_all_initialized_cache_true = true
	return true

func _build_native_daily_ocean_knobs(map: MapData, cp_now, season_phase: float) -> Dictionary:
	if map == null or cp_now == null or _generator._last_cfg == null or not bool(_generator._last_cfg.enable_ocean_heat_transport):
		return {}
	var n: int = map.soa_size()
	var nb_idx: PackedInt32Array = map.neighbor_indices_packed()
	if n <= 0 or nb_idx.size() < n * 6:
		return {}
	var dc_views: Dictionary = _generator._climate_views_from_world(cp_now)
	var use_dc: bool = not dc_views.is_empty()
	var temp_a: PackedFloat32Array = dc_views["temp"] if use_dc else map.temp_arr
	var temp_baseline_a: PackedFloat32Array = dc_views["temp_baseline"] if use_dc \
			else _native_daily_live_f32("cell_temp_baseline", map.temp_baseline_arr, n)
	var elev_a: PackedFloat32Array = dc_views["elevation"] if use_dc else map.elevation_arr
	var lat_a: PackedFloat32Array = dc_views["lat_norm"] if use_dc else map.cell_lat_norm_arr
	var ema_init_a: PackedByteArray = dc_views["ema_initialized"] if use_dc \
			else _native_daily_live_u8("cell_ema_initialized", map.ema_initialized_arr, n)
	var ocx_a: PackedFloat32Array = dc_views["ocean_current_x"] if use_dc else map.ocean_current_x_arr
	var ocy_a: PackedFloat32Array = dc_views["ocean_current_y"] if use_dc else map.ocean_current_y_arr
	if temp_a.size() < n or elev_a.size() < n:
		return {}
	if _generator._gdext_ocean_temp_before_work_buf.size() != n:
		_generator._gdext_ocean_temp_before_work_buf.resize(n)
	if _generator._gdext_ocean_anomaly_work_buf.size() != n:
		_generator._gdext_ocean_anomaly_work_buf.resize(n)
	var baseline_direct: bool = _native_daily_ema_all_initialized(map, ema_init_a, n) \
			and temp_baseline_a.size() >= n
	var baseline: PackedFloat32Array = temp_baseline_a if baseline_direct else _generator._gdext_ocean_baseline_work_buf
	if not baseline_direct and _generator._gdext_ocean_baseline_work_buf.size() != n:
		_generator._gdext_ocean_baseline_work_buf.resize(n)
		baseline = _generator._gdext_ocean_baseline_work_buf
	var temp_before: PackedFloat32Array = _generator._gdext_ocean_temp_before_work_buf
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
				var ny: float = lat_a[i] if i < lat_n else _generator._cube_row_norm(cells[i], _generator._last_cfg)
				bi = _generator._compute_temperature(ny, elev_a[i])
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
	var anomaly: PackedFloat32Array = _generator._gdext_ocean_anomaly_work_buf
	var src_tta: PackedFloat32Array = map.temperature_transport_anomaly_arr
	if src_tta.size() == n:
		for ai in range(n):
			anomaly[ai] = src_tta[ai]
	elif _generator._gdext_ocean_anomaly_buf_cached.size() == n:
		var cached_tta: PackedFloat32Array = _generator._gdext_ocean_anomaly_buf_cached
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
	var tta: Dictionary = _generator._temperature_transport_anomaly_knobs(cp_now)
	var ocean_thread_enabled: bool = bool(cp_now.native_daily_ocean_thread_variant_enabled) \
			if cp_now.get("native_daily_ocean_thread_variant_enabled") != null else false
	var ocean_thread_tasks: int = clampi(int(cp_now.native_daily_ocean_thread_tasks), 0, 16) \
			if cp_now.get("native_daily_ocean_thread_tasks") != null else 0
	var water_knobs: Dictionary = {
		"n_cells": n,
		"advect_steps": max(0, _generator._last_cfg.OCEAN_HEAT_ADVECT_STEPS),
		"heat_mix": clampf(_generator._last_cfg.OCEAN_HEAT_MIX, 0.0, 1.0),
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
		"effective_leak": float(_generator._last_cfg.COASTAL_HEAT_LEAK) * winter_boost,
		"neighbor_indices": nb_idx,
		"anomaly_inout": anomaly,
		"fallback_baseline_arr": baseline,
		"ocean_current_x_arr": ocx_a,
		"ocean_current_y_arr": ocy_a,
		"native_daily_thread_variant_enabled": ocean_thread_enabled,
		"native_daily_thread_tasks": ocean_thread_tasks,
	}
	_generator._apply_temperature_transport_anomaly_knobs(water_knobs, tta)
	_generator._apply_temperature_transport_anomaly_knobs(land_knobs, tta)
	return {
		"water": water_knobs,
		"land": land_knobs,
	}

func _build_native_daily_sea_ice_knobs(
		map: MapData,
		cp_now,
		season_phase: float,
		commit_side_effects: bool,
		dt_cap_days: float = 30.0) -> Dictionary:
	if map == null or cp_now == null or _generator._last_cfg == null:
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
	if _generator._world_clock_ref != null:
		var ca_v = _generator._world_clock_ref.get("climate_anomaly")
		if ca_v != null:
			climate_anomaly_now = float(ca_v)
	if not is_equal_approx(climate_anomaly_now, 0.0):
		var ice_thr_shift: float = 0.10 * climate_anomaly_now
		t_form = clampf(t_form - ice_thr_shift, 0.0, 1.0)
		t_melt = clampf(t_melt - ice_thr_shift, 0.0, 1.0)
	var dt_days: float = _generator._consume_sea_ice_dt_days(dt_cap_days) if commit_side_effects else 1.0
	var base_terrain_input: PackedByteArray
	if map.base_terrain_arr.size() == n_cells_fast:
		base_terrain_input = map.base_terrain_arr
	else:
		if _generator._gdext_sea_ice_base_terrain_buf.size() != n_cells_fast:
			_generator._gdext_sea_ice_base_terrain_buf.resize(n_cells_fast)
		base_terrain_input = _generator._gdext_sea_ice_base_terrain_buf
		for i_build in range(n_cells_fast):
			var c_build: HexCell = cells_fast[i_build]
			_generator._gdext_sea_ice_base_terrain_buf[i_build] = int(c_build.base_terrain) & 0xFF
	var tta_input: PackedFloat32Array
	if _generator._gdext_ocean_anomaly_buf_cached.size() == n_cells_fast:
		tta_input = _generator._gdext_ocean_anomaly_buf_cached
	elif map.temperature_transport_anomaly_arr.size() == n_cells_fast:
		tta_input = map.temperature_transport_anomaly_arr
	else:
		if _generator._gdext_sea_ice_tta_buf.size() != n_cells_fast:
			_generator._gdext_sea_ice_tta_buf.resize(n_cells_fast)
		tta_input = _generator._gdext_sea_ice_tta_buf
		for i_tta in range(n_cells_fast):
			tta_input[i_tta] = cells_fast[i_tta].temperature_transport_anomaly
	var upw_input: PackedFloat32Array = map.upwelling_strength_arr \
			if map.upwelling_strength_arr.size() == n_cells_fast \
			else _generator._gdext_sea_ice_upw_buf
	if upw_input.size() != n_cells_fast:
		_generator._gdext_sea_ice_upw_buf.resize(n_cells_fast)
		upw_input = _generator._gdext_sea_ice_upw_buf
		for i_upw in range(n_cells_fast):
			upw_input[i_upw] = cells_fast[i_upw].upwelling_strength
	var temp_input: PackedFloat32Array = map.temp_arr \
			if map.temp_arr.size() == n_cells_fast \
			else _generator._gdext_sea_ice_temp_buf
	if temp_input.size() != n_cells_fast:
		_generator._gdext_sea_ice_temp_buf.resize(n_cells_fast)
		temp_input = _generator._gdext_sea_ice_temp_buf
		for i_temp in range(n_cells_fast):
			temp_input[i_temp] = cells_fast[i_temp].temperature
	var insol_input: PackedFloat32Array = _generator._sea_ice_insolation_input(map, cells_fast, season_phase)
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
		"ice_delay": float(_generator._last_cfg.OCEAN_CURRENT_ICE_DELAY),
		"enable_ocean_heat_transport": bool(_generator._last_cfg.enable_ocean_heat_transport),
		"terrain_lake_id": int(TerrainType.TERRAIN.LAKE),
		"terrain_sea_ice_id": int(TerrainType.TERRAIN.SEA_ICE),
		"terrain_ocean_id": int(TerrainType.TERRAIN.OCEAN),
		"water_terrain_ids": water_ids,
		"neighbor_indices": nb_idx_fast,
		"base_terrain_arr": base_terrain_input,
		"temp_transport_anomaly": tta_input,
		"upwelling_strength": upw_input,
		"insolation_now_arr": insol_input,
		"solar_gate_enabled": _generator._sea_ice_solar_gate_enabled(cp_now),
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

func _build_native_daily_runtime_hydrology_knobs(map: MapData, cp_now,
		dt_days: float = 1.0) -> Dictionary:
	if map == null or cp_now == null:
		return {}
	if cp_now.get("runtime_hydrology_enabled") == null \
			or not bool(cp_now.runtime_hydrology_enabled):
		return {}
	if _generator._data_core_world_ext == null:
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

func _native_daily_required_pass_keys(cp_now) -> PackedStringArray:
	var keys := PackedStringArray(["climate_pass_a_struct"])
	if cp_now != null and bool(cp_now.enable_local_climate_coupling):
		keys.append("climate_pass_b_knobs")
		keys.append("transpiration_knobs")
	if _generator._last_cfg != null and bool(_generator._last_cfg.enable_ocean_heat_transport):
		keys.append("ocean_water_knobs")
		keys.append("ocean_land_knobs")
	var wind_heat_required: bool = true
	if cp_now != null and cp_now.get("enable_wind_heat_transport") != null:
		wind_heat_required = bool(cp_now.enable_wind_heat_transport)
	if wind_heat_required:
		keys.append("wind_air_knobs")
		keys.append("wind_surface_knobs")
	keys.append("sea_ice_knobs")
	# stage_b follows albedo / vegetation / feedback strides and is legitimately
	# absent on most probe ticks. Requiring it here prevents native_daily active
	# handoff even though the scheduler can simply skip that node for the tick.
	var weather_field_required: bool = _generator._weather_system != null \
			and _generator._weather_system.has_method("uses_weather_field") \
			and bool(_generator._weather_system.uses_weather_field())
	if weather_field_required:
		keys.append("weather_knobs")
	if cp_now != null and cp_now.get("runtime_hydrology_enabled") != null \
			and bool(cp_now.runtime_hydrology_enabled):
		if keys.find("weather_knobs") < 0:
			keys.append("weather_knobs")
		# 与 stage_b 同理：stride > 1 时水文在多数 tick 合法缺席，硬性要求它会把
		# native_daily active handoff 卡住。stride == 1（默认）仍然逐轮要求。
		var hydrology_stride: int = 1
		if cp_now.get("runtime_hydrology_stride") != null:
			hydrology_stride = maxi(1, int(cp_now.runtime_hydrology_stride))
		if hydrology_stride <= 1:
			keys.append("runtime_hydrology_knobs")
	return keys

func _native_daily_required_pass_keys_array(cp_now) -> Array[String]:
	var out: Array[String] = []
	for key in _native_daily_required_pass_keys(cp_now):
		out.append(String(key))
	return out

func _native_daily_missing_required_pass_keys(bundle: Dictionary, required: PackedStringArray) -> PackedStringArray:
	var missing := PackedStringArray()
	for key in required:
		if not bundle.has(key):
			missing.append(key)
	return missing

func _native_daily_climate_round_state_snapshot() -> Dictionary:
	if _generator._refresh_climate_daily_job != null \
			and _generator._refresh_climate_daily_job.has_method("climate_round_state_snapshot"):
		return _generator._refresh_climate_daily_job.climate_round_state_snapshot()
	# On the native_daily path ClimateDailySystem is never registered, so there
	# is no GDScript pass cursor to report. Describe the native round instead;
	# returning "missing job" here used to make every consumer of this snapshot
	# conclude the Climate round had not completed.
	if _generator._native_daily_sim_job != null:
		return {
			"owner": "native_daily",
			"native_state_status": "native_daily_owner",
			"round_active": _generator.native_daily_round_active(),
			"finalize_pending": false,
			"pass_generation": _generator._native_daily_climate_round_generation,
			"pass_cursor": 1,
			"pass_count": 1,
		}
	return {
		"owner": "gdscript_retained",
		"native_state_status": "missing_refresh_climate_daily_job",
	}

func _native_daily_ocean_physical_state_snapshot() -> Dictionary:
	if _generator._ocean_currents_job != null \
			and _generator._ocean_currents_job.has_method("ocean_physical_state_snapshot"):
		return _generator._ocean_currents_job.ocean_physical_state_snapshot()
	return {
		"owner": "gdscript_retained",
		"native_state_status": "missing_ocean_currents_job",
	}

func _native_daily_season_refresh_state_snapshot() -> Dictionary:
	if _generator._season_refresh_job != null \
			and _generator._season_refresh_job.has_method("season_refresh_state_snapshot"):
		return _generator._season_refresh_job.season_refresh_state_snapshot()
	return {
		"owner": "gdscript_retained",
		"native_state_status": "missing_season_refresh_job",
	}

func _native_daily_weather_active_bootstrap_allowed(readiness: Dictionary) -> bool:
	var cp_now = _generator._c()
	if cp_now == null:
		return false
	if not _generator._native_mode_is_active(cp_now, "native_daily_sim_mode"):
		return false
	if cp_now.get("native_weather_transaction_active_owner_enabled") == null \
			or not bool(cp_now.native_weather_transaction_active_owner_enabled):
		return false
	return bool(readiness.get("has_knobs_builder", false)) \
			and bool(readiness.get("has_result_apply", false)) \
			and bool(readiness.get("has_weather_lut_publish", false)) \
			and _generator._weather_system != null \
			and _generator._sus_world != null \
			and _generator._weather_system.has_method("build_unified_fast_tick_weather_knobs")


# Stagger 对齐（2026-06）：legacy 的 weather_refresh + _generator.refresh_daily_stage_b 跑在
# sim_stagger 的 weather bucket 上（默认 stride=8 / phase=4），而不是每天。native
# daily 此前每轮都嵌入 weather/stage_b（must_run），让天气场与 stage_b call_index
# 以 ~8× 速率推进，导致天气分类（BLIZZARD↔RAIN/HEATWAVE）严重偏移。本判定复刻
# DCSystemScheduler._schedule_policy 的 &"weather_refresh" 分支 + StridePolicy
# (((tick + phase) % stride) == 0)，让 native 的 weather/stage_b 节点与 legacy 同 cadence
# 推进；非到期 tick 不嵌入 weather_knobs / stage_b_knobs，C++ 端短路跳过该节点，
# 持久 slot 保留天气场（与 legacy “当天不刷新天气” bit-equal）。

func _native_daily_weather_cadence_stride(cp_now) -> int:
	if cp_now == null:
		return 1
	var stagger_on: bool = cp_now.get("sim_stagger_enabled") != null \
			and bool(cp_now.sim_stagger_enabled)
	if stagger_on:
		return clampi(int(cp_now.sim_stagger_bucket_stride), 1, 16) \
				if cp_now.get("sim_stagger_bucket_stride") != null else 8
	return maxi(1, int(cp_now.weather_refresh_stride)) \
			if cp_now.get("weather_refresh_stride") != null else 1

func _native_daily_weather_cadence_due(cp_now, ctx: SusTickContext) -> bool:
	if cp_now == null or ctx == null:
		return true
	var stride: int = _native_daily_weather_cadence_stride(cp_now)
	if stride <= 1:
		return true
	# 频率对齐：weather/stage_b 每 stride 个模拟日推进一次（与 legacy weather bucket
	# 同频）。用“距上次嵌入天数 ≥ stride”而非 tick 取模——native round 可能跨多天、
	# 起始日与 phase 错开会让取模永不命中。phase 错峰（load spreading）留到阶段 2。
	var day: int = int(ctx.day_index)
	if _generator._native_daily_last_weather_embed_day <= -1000000:
		# 冷启动首次：对齐 legacy weather bucket 的首跑日（StridePolicy 在
		# (day+phase)%stride==0 处首跑，即 day=stride-phase），让 native 冷启动相位与
		# legacy 一致——前几日同样无天气场（与 legacy bit-equal 的“尚未刷新”）。
		var phase: int = 0
		if cp_now.get("sim_stagger_enabled") != null and bool(cp_now.sim_stagger_enabled):
			var raw: int = int(cp_now.sim_stagger_weather_phase) \
					if cp_now.get("sim_stagger_weather_phase") != null else 4
			phase = posmod(raw, stride)
		var first_due_day: int = (stride - phase) if phase > 0 else stride
		return day >= first_due_day
	return (day - _generator._native_daily_last_weather_embed_day) >= stride

func _native_daily_split_weather_node_enabled(cp_now) -> bool:
	return cp_now != null \
		and cp_now.get("native_daily_split_weather_node_enabled") != null \
		and bool(cp_now.native_daily_split_weather_node_enabled)

func _native_daily_weather_clock_values(default_phase: float) -> Dictionary:
	var values: Dictionary = {
		"season_idx": 0,
		"anomaly": 0.0,
		"season_phase": default_phase,
	}
	if _generator._world_clock_ref != null:
		if _generator._world_clock_ref.has_method("season_index"):
			values["season_idx"] = int(_generator._world_clock_ref.season_index())
		var v_anom = _generator._world_clock_ref.get("climate_anomaly")
		if v_anom != null:
			values["anomaly"] = float(v_anom)
		if _generator._world_clock_ref.has_method("season_phase"):
			values["season_phase"] = float(_generator._world_clock_ref.season_phase())
	return values

func _build_native_daily_weather_super_knobs(
		ctx: SusTickContext,
		map: MapData,
		world: WorldData,
		phase_default: float,
		stage_b_knobs: Dictionary,
		runtime_hydrology_active: bool,
		commit_side_effects: bool,
		force_weather_embed: bool) -> Dictionary:
	if _generator._weather_system == null or world == null \
			or not _generator._weather_system.has_method("build_unified_fast_tick_weather_knobs"):
		return {}
	var clock_values: Dictionary = _native_daily_weather_clock_values(phase_default)
	if commit_side_effects:
		_generator._weather_stage_b_call_index += 1
	if _generator._weather_system.has_method("set_weather_transition_dt_days"):
		_generator._weather_system.set_weather_transition_dt_days(_generator._consume_weather_dt_days() if commit_side_effects else 1.0)
	var weather_stage_b_knobs: Dictionary = {} if runtime_hydrology_active else stage_b_knobs
	var weather_super: Dictionary = _generator._weather_system.build_unified_fast_tick_weather_knobs(
		map,
		world,
		int(clock_values.get("season_idx", 0)),
		float(clock_values.get("anomaly", 0.0)),
		float(clock_values.get("season_phase", phase_default)),
		weather_stage_b_knobs
	)
	if not weather_super.is_empty():
		weather_super["native_daily_weather_stage_b_embedded"] = not runtime_hydrology_active \
			and not weather_stage_b_knobs.is_empty()
		if commit_side_effects and not force_weather_embed and ctx != null:
			_generator._native_daily_last_weather_embed_day = int(ctx.day_index)
		return weather_super
	if commit_side_effects:
		_generator._weather_stage_b_call_index = maxi(0, _generator._weather_stage_b_call_index - 1)
	return {}

func _native_daily_boundary_contract(bundle: Dictionary, commit_side_effects: bool) -> Dictionary:
	var bootstrap_keys: Array[String] = []
	var tick_delta_keys: Array[String] = []
	for key in bundle.keys():
		var key_name: String = str(key)
		if key_name.ends_with("_state_snapshot") \
				or key_name == "weather_native_daily_readiness" \
				or key_name == "climate_round_active_owner_requested" \
				or key_name == "weather_transaction_active_owner_requested" \
				or key_name == "season_cadence_policy":
			bootstrap_keys.append(key_name)
		elif key_name.ends_with("_knobs") or key_name.ends_with("_struct"):
			tick_delta_keys.append(key_name)
	return {
		"schema_version": 1,
		"bootstrap_config_keys": bootstrap_keys,
		"tick_delta_keys": tick_delta_keys,
		"bundle_key_count": bundle.size(),
		"refresh_slots_from_map": bool(bundle.get("refresh_slots_from_map", true)),
		"flush_slots_to_map": bool(bundle.get("flush_slots_to_map", true)),
		"commit_side_effects": commit_side_effects,
		"refresh_policy": "tick_boundary",
		"flush_policy": "tick_boundary_or_visible_debug",
		"remaining_high_frequency_boundary": tick_delta_keys.size() > 0,
	}

func _native_daily_static_bundle_cache_key(map: MapData, cp_now) -> String:
	if map == null or cp_now == null:
		return ""
	var cfg_w: int = int(_generator._last_cfg.width) if _generator._last_cfg != null else 0
	var cfg_h: int = int(_generator._last_cfg.height) if _generator._last_cfg != null else 0
	var parts: PackedStringArray = PackedStringArray([
		str(map.soa_size()),
		str(cfg_w),
		str(cfg_h),
		str(cp_now.get_instance_id()),
		str(bool(cp_now.native_daily_legacy_daily_production_retired) if cp_now.get("native_daily_legacy_daily_production_retired") != null else false),
		str(bool(cp_now.native_climate_round_active_owner_enabled) if cp_now.get("native_climate_round_active_owner_enabled") != null else false),
		str(bool(cp_now.native_weather_transaction_active_owner_enabled) if cp_now.get("native_weather_transaction_active_owner_enabled") != null else false),
		str(bool(cp_now.native_season_refresh_active_owner_enabled) if cp_now.get("native_season_refresh_active_owner_enabled") != null else false),
		str(bool(cp_now.runtime_hydrology_enabled) if cp_now.get("runtime_hydrology_enabled") != null else false),
		str(_native_daily_split_weather_node_enabled(cp_now)),
	])
	return "|".join(parts)

func _build_native_daily_static_bundle_shell(map: MapData, cp_now) -> Dictionary:
	var climate_active: bool = cp_now.get("native_climate_round_active_owner_enabled") != null \
			and bool(cp_now.native_climate_round_active_owner_enabled)
	var refresh_keys := PackedStringArray()
	if climate_active:
		refresh_keys = PackedStringArray([
			"cell_terrain", "cell_base_terrain", "cell_is_water",
			"cell_landform", "cell_vegetation", "cell_cover",
			"cell_base_moisture",
		])
	var legacy_daily_retired: bool = cp_now.get("native_daily_legacy_daily_production_retired") != null \
			and bool(cp_now.native_daily_legacy_daily_production_retired)
	return {
		"refresh_slots_from_map": true,
		"refresh_slot_keys": refresh_keys,
		# Native pass wrappers already flush their published slots. A final bulk
		# flush walks every bound slot and was making ACTIVE native_daily cost ~8ms.
		"flush_slots_to_map": false,
		"climate_round_active_owner_requested": bool(cp_now.native_climate_round_active_owner_enabled) if cp_now.get("native_climate_round_active_owner_enabled") != null else false,
		"weather_transaction_active_owner_requested": bool(cp_now.native_weather_transaction_active_owner_enabled) if cp_now.get("native_weather_transaction_active_owner_enabled") != null else false,
		"season_refresh_active_owner_requested": bool(cp_now.native_season_refresh_active_owner_enabled) if cp_now.get("native_season_refresh_active_owner_enabled") != null else false,
		"runtime_hydrology_requested": bool(cp_now.runtime_hydrology_enabled) if cp_now.get("runtime_hydrology_enabled") != null else false,
		"legacy_sus_fallback_enabled": not legacy_daily_retired,
		"native_daily_legacy_daily_production_retired": legacy_daily_retired,
		"native_daily_split_weather_node_enabled": _native_daily_split_weather_node_enabled(cp_now),
		"use_system_schedule": true,
		"static_shell_cell_count": map.soa_size(),
	}

func _native_daily_get_static_bundle_shell(map: MapData, cp_now) -> Dictionary:
	var key: String = _native_daily_static_bundle_cache_key(map, cp_now)
	var hit: bool = key != "" and key == _generator._native_daily_static_bundle_cache_token \
			and not _generator._native_daily_static_bundle_cache.is_empty()
	if not hit:
		_generator._native_daily_static_bundle_cache_token = key
		_generator._native_daily_static_bundle_cache = _build_native_daily_static_bundle_shell(map, cp_now)
	return {
		"cache_hit": hit,
		"cache_key": key,
		"bundle": _generator._native_daily_static_bundle_cache.duplicate(),
	}

func _build_native_daily_bundle(
		ctx: SusTickContext,
		map: MapData,
		_world: WorldData,
		commit_side_effects: bool = false,
		sea_ice_dt_cap_days: float = 30.0,
		commit_sea_ice_side_effects: bool = true,
		force_weather_embed: bool = false,
		defer_heavy_pass_knobs: bool = false) -> Dictionary:
	var t_bundle_us: int = Time.get_ticks_usec()
	var cp_now = _generator._c()
	if map == null or cp_now == null:
		return {}
	var t_static_us: int = Time.get_ticks_usec()
	var shell_report: Dictionary = _native_daily_get_static_bundle_shell(map, cp_now)
	var bundle: Dictionary = shell_report.get("bundle", {})
	var bundle_cache_hit: bool = bool(shell_report.get("cache_hit", false))
	var bundle_static_ms: float = float(Time.get_ticks_usec() - t_static_us) / 1000.0
	bundle["climate_round_state_snapshot"] = _native_daily_climate_round_state_snapshot()
	bundle["ocean_physical_state_snapshot"] = _native_daily_ocean_physical_state_snapshot()
	bundle["season_refresh_state_snapshot"] = _native_daily_season_refresh_state_snapshot()
	# Phase C.1（dots-total-cpp roadmap）：System schedule graph 双轨入口。
	# dots-flag-prune-pr1 (2026-05-22)：use_gdext_system_schedule flag 已删除，
	# C++ 端 run_native_daily_tick 现恒走 system_schedule.cpp 的
	# dispatch_system_schedule loop。输出 dict（breakdown / fronts / succession_*）
	# 必须 bit-equal（dots_soak_ab_runner SAME_SOURCE 1000-tick A/B 验收）。
	# 任意节点失败 → C++ 端 finish_with_failure 短路返回 rc=-1。ACTIVE
	# hot path 由 _generator.run_native_daily_slice_from_job 处理；full-run helper 仅供
	# debug/probe 使用。
	var pass_a_struct: Dictionary = _build_native_daily_climate_pass_a_struct(map, cp_now, ctx.season_phase)
	if not pass_a_struct.is_empty():
		bundle["climate_pass_a_struct"] = pass_a_struct
	if defer_heavy_pass_knobs:
		# Sea-ice, wind and transpiration are sensitive to the exact in-round
		# temperature/transport snapshots. Keep the conservative JIT boundaries until
		# SAME_SOURCE proves a narrower list is climate-bit-equal across seasons.
		var deferred_nodes: PackedInt32Array = PackedInt32Array([1, 2, 4, 6, 7])
		var weather_split_enabled: bool = _native_daily_split_weather_node_enabled(cp_now)
		var native_weather_readiness: Dictionary = _generator.weather_native_daily_readiness_report()
		var native_weather_active_bootstrap: bool = _native_daily_weather_active_bootstrap_allowed(native_weather_readiness)
		if native_weather_active_bootstrap and not bool(native_weather_readiness.get("ready", false)):
			native_weather_readiness["ready"] = true
			native_weather_readiness["reason"] = "active_bootstrap_unified_publish"
			native_weather_readiness["active_bootstrap_requested"] = true
		bundle["weather_native_daily_readiness"] = native_weather_readiness.duplicate()
		var native_weather_daily_allowed: bool = bool(native_weather_readiness.get("ready", false)) \
				or native_weather_active_bootstrap
		var runtime_hydrology_active: bool = cp_now.get("runtime_hydrology_enabled") != null \
				and bool(cp_now.runtime_hydrology_enabled)
		var weather_due_this_tick: bool = force_weather_embed \
				or _native_daily_weather_cadence_due(cp_now, ctx)
		if weather_due_this_tick:
			if native_weather_daily_allowed and _generator._weather_system != null and _world != null \
					and _generator._weather_system.has_method("build_unified_fast_tick_weather_knobs"):
				var stage_b_knobs_prebuilt: Dictionary = _build_native_daily_stage_b_knobs(
					map,
					cp_now,
					maxi(0, _generator._weather_stage_b_call_index),
					float(_generator._native_daily_contract_stride_days())
				)
				var weather_super_prebuilt: Dictionary = _build_native_daily_weather_super_knobs(
					ctx,
					map,
					_world,
					ctx.season_phase,
					stage_b_knobs_prebuilt,
					runtime_hydrology_active,
					commit_side_effects,
					force_weather_embed
				)
				if not weather_super_prebuilt.is_empty():
					bundle["weather_knobs"] = weather_super_prebuilt
					bundle["weather_knobs_prebuilt"] = true
				deferred_nodes.append(12)
				if runtime_hydrology_active:
					deferred_nodes.append(19)
					deferred_nodes.append(20)
				elif not weather_split_enabled:
					deferred_nodes.append(11)
			elif _generator._weather_system != null and _world != null and not native_weather_daily_allowed:
				bundle["weather_native_daily_blocked"] = true
				bundle["weather_native_daily_block_reason"] = str(native_weather_readiness.get("reason", "not_ready"))
				if not runtime_hydrology_active:
					deferred_nodes.append(11)
		bundle["season_cadence_policy"] = _native_daily_season_cadence_policy(
			cp_now,
			maxi(0, _generator._weather_stage_b_call_index)
		)
		bundle["native_daily_deferred_nodes"] = deferred_nodes
		bundle["deferred_node_count"] = deferred_nodes.size()
		bundle["bundle_cache_hit"] = bundle_cache_hit
		bundle["bundle_cache_rebuild_reason"] = "static_shell_hit" if bundle_cache_hit else "static_shell_rebuild"
		bundle["bundle_static_ms"] = bundle_static_ms
		bundle["bundle_dynamic_ms"] = maxf(0.0, float(Time.get_ticks_usec() - t_bundle_us) / 1000.0 - bundle_static_ms)
		bundle["native_daily_boundary_contract"] = _native_daily_boundary_contract(bundle, commit_side_effects)
		return bundle
	var pass_b_knobs: Dictionary = _build_native_daily_climate_pass_b_knobs(map, cp_now, ctx.season_phase)
	if not pass_b_knobs.is_empty():
		bundle["climate_pass_b_knobs"] = pass_b_knobs
	var transp_knobs: Dictionary = _build_native_daily_transpiration_knobs(map, cp_now)
	if not transp_knobs.is_empty():
		bundle["transpiration_knobs"] = transp_knobs
	var ocean_knobs: Dictionary = _build_native_daily_ocean_knobs(map, cp_now, ctx.season_phase)
	if not ocean_knobs.is_empty():
		bundle["ocean_water_knobs"] = ocean_knobs.get("water", {})
		bundle["ocean_land_knobs"] = ocean_knobs.get("land", {})
	var wind_knobs: Dictionary = _build_native_daily_wind_knobs(map, cp_now)
	if not wind_knobs.is_empty():
		bundle["wind_air_knobs"] = wind_knobs.get("air", {})
		bundle["wind_surface_knobs"] = wind_knobs.get("surface", {})
	var sea_ice_knobs: Dictionary = _build_native_daily_sea_ice_knobs(
		map,
		cp_now,
		ctx.season_phase,
		commit_side_effects and commit_sea_ice_side_effects,
		sea_ice_dt_cap_days)
	if not sea_ice_knobs.is_empty():
		bundle["sea_ice_knobs"] = sea_ice_knobs
	# Phase A.2 unified fast tick: dots-flag-prune-pr1 round 2 (2026-05-22):
	# use_gdext_unified_fast_tick / use_gdext_weather_refresh_daily flag 均已删除——
	# weather refresh daily 的 4 组 super_knobs（field/distribute/summary + stage_b
	# 平铺）现恒嵌入 bundle，仅受 ext + has_method 探测控制。任意前置不满足
	# （weather_system null / fast_indexed 缺失）自动返回空 dict，此时 bundle 不含
	# weather_knobs，C++ 端短路跳过 weather 段——bit-equal 兜底。
	var stage_b_knobs: Dictionary = _build_native_daily_stage_b_knobs(
		map,
		cp_now,
		maxi(0, _generator._weather_stage_b_call_index),
		float(_generator._native_daily_contract_stride_days())
	)
	bundle["season_cadence_policy"] = _native_daily_season_cadence_policy(
		cp_now,
		maxi(0, _generator._weather_stage_b_call_index)
	)
	var stage_b_embedded_in_weather: bool = false
	var native_weather_readiness: Dictionary = _generator.weather_native_daily_readiness_report()
	var native_weather_active_bootstrap: bool = _native_daily_weather_active_bootstrap_allowed(native_weather_readiness)
	if native_weather_active_bootstrap and not bool(native_weather_readiness.get("ready", false)):
		native_weather_readiness["ready"] = true
		native_weather_readiness["reason"] = "active_bootstrap_unified_publish"
		native_weather_readiness["active_bootstrap_requested"] = true
	bundle["weather_native_daily_readiness"] = native_weather_readiness.duplicate()
	var native_weather_daily_allowed: bool = bool(native_weather_readiness.get("ready", false)) \
			or native_weather_active_bootstrap
	var runtime_hydrology_active: bool = cp_now.get("runtime_hydrology_enabled") != null \
			and bool(cp_now.runtime_hydrology_enabled)
	# Stagger 对齐：weather + stage_b 节点只在 legacy weather bucket 到期 tick 推进。
	# 注册/SHADOW probe 用 force_weather_embed=true 强制纳入以保留 readiness 校验。
	var weather_due_this_tick: bool = force_weather_embed \
			or _native_daily_weather_cadence_due(cp_now, ctx)
	# runtime_hydrology_stride 此前在 ClimateProfile 里声明但全库无引用，也就是说
	# 无论配成几，水文都跟着每个 weather 轮跑。按 stage_b 三件套的同一套模式接线：
	# 计数器只在真实 tick 的 weather 到期轮推进，probe（commit_side_effects=false）
	# 不许动它，否则 readiness 探测会把节拍带偏。
	var runtime_hydrology_stride: int = 1
	if cp_now.get("runtime_hydrology_stride") != null:
		runtime_hydrology_stride = maxi(1, int(cp_now.runtime_hydrology_stride))
	var runtime_hydrology_due: bool = true
	if runtime_hydrology_active and runtime_hydrology_stride > 1:
		if commit_side_effects and weather_due_this_tick:
			_generator._native_daily_hydrology_call_index += 1
		runtime_hydrology_due = (_generator._native_daily_hydrology_call_index % runtime_hydrology_stride) == 0
	var runtime_hydrology_knobs: Dictionary = {}
	if runtime_hydrology_due:
		runtime_hydrology_knobs = _build_native_daily_runtime_hydrology_knobs(
			map,
			cp_now,
			float(_generator._native_daily_contract_stride_days()) if commit_side_effects else 1.0
		)
	if _generator._weather_system != null and _world != null \
			and native_weather_daily_allowed \
			and weather_due_this_tick \
			and _generator._weather_system.has_method("build_unified_fast_tick_weather_knobs"):
		var weather_super: Dictionary = _build_native_daily_weather_super_knobs(
			ctx,
			map,
			_world,
			ctx.season_phase,
			stage_b_knobs,
			runtime_hydrology_active,
			commit_side_effects,
			force_weather_embed
		)
		if not weather_super.is_empty():
			bundle["weather_knobs"] = weather_super
			bundle["weather_knobs_prebuilt"] = false
			stage_b_embedded_in_weather = not runtime_hydrology_active
	elif _generator._weather_system != null and _world != null and not native_weather_daily_allowed:
		bundle["weather_native_daily_blocked"] = true
		bundle["weather_native_daily_block_reason"] = str(native_weather_readiness.get("reason", "not_ready"))
	if runtime_hydrology_active and not runtime_hydrology_knobs.is_empty():
		bundle["runtime_hydrology_knobs"] = runtime_hydrology_knobs
	# stage_b 是 legacy weather_refresh 的子步（_generator.refresh_daily_stage_b 随 weather 每 8 天
	# 推进 + albedo/veg/feedback 子 stride），故与 weather 同 cadence 闸控；非到期 tick
	# 不嵌入，stage_b 节点被 C++ 短路跳过，避免 call_index/feedback 以 8× 速率漂移温度
	# 进而扭曲天气分类。
	if weather_due_this_tick and runtime_hydrology_active and not stage_b_knobs.is_empty():
		bundle["stage_b_after_hydrology_knobs"] = stage_b_knobs
	elif weather_due_this_tick and not stage_b_embedded_in_weather and not stage_b_knobs.is_empty():
		bundle["stage_b_knobs"] = stage_b_knobs
	bundle["deferred_node_count"] = 0
	bundle["bundle_cache_hit"] = bundle_cache_hit
	bundle["bundle_cache_rebuild_reason"] = "static_shell_hit" if bundle_cache_hit else "static_shell_rebuild"
	bundle["bundle_static_ms"] = bundle_static_ms
	bundle["bundle_dynamic_ms"] = maxf(0.0, float(Time.get_ticks_usec() - t_bundle_us) / 1000.0 - bundle_static_ms)
	bundle["native_daily_boundary_contract"] = _native_daily_boundary_contract(bundle, commit_side_effects)
	return bundle

func _merge_native_daily_slice_patch_local(patch: Dictionary) -> void:
	if patch.is_empty():
		return
	for key in patch.keys():
		_generator._native_daily_slice_active_bundle[key] = patch[key]
	_generator._native_daily_slice_bundle_pass_keys = _native_daily_bundle_pass_keys(_generator._native_daily_slice_active_bundle)


# Slice-graph node indices that MUST receive a just-in-time knob patch before they run,
# because running them with the round-start knobs would diverge. Empirically minimized
# (tmp_native_batch_bitequal_test.gd, 40-round soak): only `ocean_water` (2) and
# `sea_ice` (6) need a repack. ocean reads temp_before from map.temp_arr (which the
# per-slice apply flushes post-pass_a/pass_b — NOT the raw cell_temp slot, so a C++
# slot-read is not bit-equal and was reverted); sea_ice picks up the post-ocean
# transport anomaly. `climate_pass_b` (1), `wind_air` (4) and `transpiration` (7) read
# their dynamic inputs straight from C++ slots (or use cached/static knobs), so their
# round-start knobs already match — yielding before them was pure redundant
# GDScript<->C++ round-trip. MUST stay in sync with the `match next_node_index` cases in
# _build_native_daily_slice_bundle_patch below. Passed to C++ as
# native_daily_slice_yield_nodes; C++ batches every other consecutive node into one call
# (bit-equal). Trims ~9.1 round-trips/round down to ~3.
const _NATIVE_DAILY_SLICE_YIELD_NODES: Array[int] = [2, 6]

# Spread mode (native_daily_spread_across_ticks) wants the OPPOSITE of atomic batching:
# maximize yield granularity so each tick runs the smallest possible batch → lowest
# per-tick peak (mean 3.14→1.95ms in spread-validate). Yielding more nodes is purely
# bit-equal — it only adds C++<->GDScript checkpoints; the round-start bundle knobs
# already satisfy every non-patched node, so no JIT repack is needed (the {2,6}/sea_ice
# patches still fire on those indices). Covers all 21 NATIVE_DAILY_SLICE_GRAPH nodes
# (world_ext_daily_sim.cpp); C++ skips indices whose bundle knobs are absent on a given
# day, so a typical round lands in ~5 ticks, not 21. Trade-off vs atomic: a sim-day now
# spans ~5 ticks at maxslices=1 (sim advance ~2.5x slower), which the spread design
# explicitly accepts.
const _NATIVE_DAILY_SLICE_YIELD_NODES_SPREAD: Array[int] = [
	0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
	11, 12, 13, 14, 15, 16, 17, 18, 19, 20,
]

# Coarse spread keeps the slice round budgeted across ticks, but removes pure checkpoint
# nodes that do not need GDScript patching. Weather split subnodes remain inside the same
# C++ call unless another dynamic boundary is needed.
const _NATIVE_DAILY_SLICE_YIELD_NODES_SPREAD_COARSE: Array[int] = [2, 6, 12, 19, 20]


# Pick the slice yield set for the current cadence mode: spread → max granularity
# (lowest per-tick peak), atomic → coarse {2,6} batching (fewest round-trips/round).

func _native_daily_effective_yield_nodes(cp) -> PackedInt32Array:
	var spread: bool = cp != null and cp.get("native_daily_spread_across_ticks") != null \
		and bool(cp.native_daily_spread_across_ticks)
	var coarse_spread: bool = spread \
			and cp != null \
			and cp.get("native_daily_coarse_spread_yield_enabled") != null \
			and bool(cp.native_daily_coarse_spread_yield_enabled)
	var nodes: Array[int] = []
	if coarse_spread:
		nodes = _NATIVE_DAILY_SLICE_YIELD_NODES_SPREAD_COARSE.duplicate()
	elif spread:
		nodes = _NATIVE_DAILY_SLICE_YIELD_NODES_SPREAD.duplicate()
	else:
		nodes = _NATIVE_DAILY_SLICE_YIELD_NODES.duplicate()
	if _native_daily_split_weather_node_enabled(cp) and not coarse_spread:
		for idx in [13, 14, 15, 16, 17, 18]:
			if not nodes.has(idx):
				nodes.append(idx)
	return PackedInt32Array(nodes)

func _native_daily_sea_ice_dt_cap_days(cp) -> float:
	if cp != null and cp.get("native_daily_spread_across_ticks") != null \
			and bool(cp.native_daily_spread_across_ticks):
		return clampf(
			float(cp.native_daily_sea_ice_spread_dt_cap_days) \
					if cp.get("native_daily_sea_ice_spread_dt_cap_days") != null else 2.0,
			1.0,
			30.0
		)
	return 1.0

func _build_native_daily_slice_bundle_patch(
		next_node_index: int,
		ctx: SusTickContext,
		map: MapData,
		world: WorldData) -> Dictionary:
	var cp_now = _generator._c()
	if map == null or cp_now == null:
		return {}
	var patch: Dictionary = {}
	var phase_locked: float = _generator._native_daily_slice_phase_locked
	match next_node_index:
		1:
			var pass_b_knobs: Dictionary = _build_native_daily_climate_pass_b_knobs(map, cp_now, phase_locked)
			patch["climate_pass_b_knobs"] = pass_b_knobs
		2:
			var ocean_knobs: Dictionary = _build_native_daily_ocean_knobs(map, cp_now, phase_locked)
			if not ocean_knobs.is_empty():
				patch["ocean_water_knobs"] = ocean_knobs.get("water", {})
				patch["ocean_land_knobs"] = ocean_knobs.get("land", {})
			else:
				patch["ocean_water_knobs"] = {}
				patch["ocean_land_knobs"] = {}
		4:
			var wind_knobs: Dictionary = _build_native_daily_wind_knobs(map, cp_now)
			if not wind_knobs.is_empty():
				patch["wind_air_knobs"] = wind_knobs.get("air", {})
				patch["wind_surface_knobs"] = wind_knobs.get("surface", {})
			else:
				patch["wind_air_knobs"] = {}
				patch["wind_surface_knobs"] = {}
		6:
			var sea_ice_knobs: Dictionary = _build_native_daily_sea_ice_knobs(
				map,
				cp_now,
				phase_locked,
				true,
				_native_daily_sea_ice_dt_cap_days(cp_now))
			patch["sea_ice_knobs"] = sea_ice_knobs
		7:
			var transp_knobs: Dictionary = _build_native_daily_transpiration_knobs(map, cp_now)
			patch["transpiration_knobs"] = transp_knobs
		11:
			var stage_b_knobs: Dictionary = _build_native_daily_stage_b_knobs(
				map,
				cp_now,
				maxi(0, _generator._weather_stage_b_call_index),
				float(_generator._native_daily_contract_stride_days())
			)
			patch["stage_b_knobs"] = stage_b_knobs
		12:
			if _generator._native_daily_slice_active_bundle.has("weather_knobs"):
				return patch
			var native_weather_readiness: Dictionary = _generator.weather_native_daily_readiness_report()
			var native_weather_active_bootstrap: bool = _native_daily_weather_active_bootstrap_allowed(native_weather_readiness)
			if native_weather_active_bootstrap and not bool(native_weather_readiness.get("ready", false)):
				native_weather_readiness["ready"] = true
				native_weather_readiness["reason"] = "active_bootstrap_unified_publish"
				native_weather_readiness["active_bootstrap_requested"] = true
			var native_weather_daily_allowed: bool = bool(native_weather_readiness.get("ready", false)) \
					or native_weather_active_bootstrap
			var runtime_hydrology_active: bool = cp_now.get("runtime_hydrology_enabled") != null \
					and bool(cp_now.runtime_hydrology_enabled)
			if _generator._weather_system != null and world != null \
					and native_weather_daily_allowed \
					and _generator._weather_system.has_method("build_unified_fast_tick_weather_knobs"):
				var stage_b_knobs_for_weather: Dictionary = _build_native_daily_stage_b_knobs(
					map,
					cp_now,
					maxi(0, _generator._weather_stage_b_call_index),
					float(_generator._native_daily_contract_stride_days())
				)
				var weather_super: Dictionary = _build_native_daily_weather_super_knobs(
					ctx,
					map,
					world,
					phase_locked,
					stage_b_knobs_for_weather,
					runtime_hydrology_active,
					true,
					false
				)
				if not weather_super.is_empty():
					patch["weather_knobs"] = weather_super
					if not runtime_hydrology_active and not stage_b_knobs_for_weather.is_empty():
						# Weather embeds stage_b in this mode; keep no standalone node patch.
						pass
				else:
					patch["weather_knobs"] = {}
			else:
				patch["weather_knobs"] = {}
		19:
			var runtime_hydrology_knobs: Dictionary = _build_native_daily_runtime_hydrology_knobs(
				map,
				cp_now,
				float(_generator._native_daily_contract_stride_days())
			)
			patch["runtime_hydrology_knobs"] = runtime_hydrology_knobs
		20:
			var stage_b_after_hydrology_knobs: Dictionary = _build_native_daily_stage_b_knobs(
				map,
				cp_now,
				maxi(0, _generator._weather_stage_b_call_index),
				float(_generator._native_daily_contract_stride_days())
			)
			patch["stage_b_after_hydrology_knobs"] = stage_b_after_hydrology_knobs
	return patch

func _native_daily_bundle_pass_keys(bundle: Dictionary) -> Array[String]:
	var keys: Array[String] = []
	for k in bundle.keys():
		var s: String = str(k)
		if s.ends_with("_knobs") or s == "climate_pass_a_struct":
			keys.append(s)
	keys.sort()
	return keys

