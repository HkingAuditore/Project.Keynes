extends RefCounted

## Builds and publishes inputs to the asynchronous climate pass.

static func _build_async_kick_input(host, season_phase: float) -> Dictionary:
	var cp: ClimateProfile = host.generator._c()
	var n_cells: int = host.map.cell_count()
	# 默认 mask = 0xFF（全开 round 模式）。Stage 3 把开关字段也放进来便于调试。
	var input: Dictionary = {
		"n_cells": n_cells,
		"passes_mask": 0xFF,
		# pass_a 用
		"is_water": host.map.is_water_arr,
		"terrain": host.map.terrain_arr,
		"cover": host.map.cover_arr,
		"ema_initialized": host.map.ema_initialized_arr,
		"elevation": host.map.elevation_arr,
		"base_moisture": host.map.base_moisture_arr,
		"weather_vapor": host.map.weather_vapor_arr,
		"weather_precip": host.map.weather_precip_arr,
		"soil_moisture": host.map.soil_moisture_arr,
		"water_balance_30d": host.map.water_balance_30d_arr,
		"lat_norm": host.map.cell_lat_norm_arr,
		"temp_baseline_year": host.map.temp_baseline_year_arr,
		"temp": host.map.temp_arr,
		"temp_30d": host.map.temp_30d_arr,
		"temp_365d": host.map.temp_365d_arr,
		"thermal_energy": host.map.thermal_energy_arr,
		"snowpack": host.map.snowpack_arr,
		# pass_b 共享
		"landform": host.map.landform_arr,
		"vegetation": host.map.vegetation_arr,
		"moisture": host.map.moisture_arr,
		"pos_x": host.map.cell_pos_x_arr,
		"pos_y": host.map.cell_pos_y_arr,
		"insolation_dev": host.map.insolation_dev_arr,
		"temp_transport_anomaly": host.map.temperature_transport_anomaly_arr,
		"local_thermal_anomaly": host.map.local_thermal_anomaly_arr,
		"sea_ice_frac": host.map.sea_ice_frac_arr,
		"sea_ice_frac_inout": host.map.sea_ice_frac_arr,  # sea_ice 也用
		"base_terrain": host.map.base_terrain_arr,
		"upwelling_strength": host.map.upwelling_strength_arr,
		"insolation_now": host.map.insolation_now_arr,
		"cell_temperature_arr": host.map.temp_arr,  # sea_ice 期望 climate-adjusted T（round 内 wind_surface 写完更新）
		# ocean_water/land 共享
		"ocean_current_x": host.map.ocean_current_x_arr,
		"ocean_current_y": host.map.ocean_current_y_arr,
		"ocean_thermal_anomaly": host.map.ocean_thermal_anomaly_arr,
		# wind_air/surface 共享
		"wind_x": host.map.wind_x_arr,
		"wind_y": host.map.wind_y_arr,
		"wind_speed": host.map.wind_speed_arr,
		"temp_baseline": host.map.temp_baseline_arr,
		"air_mass_temp_anomaly": host.map.air_mass_temp_anomaly_arr,
		# water_terrain_ids LUT（与 sync run_sea_ice_daily_pass 同源）
		"water_terrain_ids": PackedByteArray([
			int(TerrainType.TERRAIN.OCEAN) & 0xFF,
			int(TerrainType.TERRAIN.COAST) & 0xFF,
			int(TerrainType.TERRAIN.LAKE) & 0xFF,
			int(TerrainType.TERRAIN.REEF) & 0xFF,
			int(TerrainType.TERRAIN.KELP) & 0xFF,
			int(TerrainType.TERRAIN.SEA_ICE) & 0xFF,
		]),
		# sea_ice 翻转用的 terrain enum ids
		"si_terrain_lake_id":    int(TerrainType.TERRAIN.LAKE) & 0xFF,
		"si_terrain_sea_ice_id": int(TerrainType.TERRAIN.SEA_ICE) & 0xFF,
		"si_terrain_ocean_id":   int(TerrainType.TERRAIN.OCEAN) & 0xFF,
		# round scalars
		"season_phase": season_phase,
		"axial_tilt_deg": float(cp.axial_tilt_deg) if "axial_tilt_deg" in cp else 23.5,
		"day_length_gain": float(cp.insolation_daylen_amp) if "insolation_daylen_amp" in cp else 0.35,
		"solar_gain": float(cp.solar_gain) if "solar_gain" in cp else 1.0,
		"insol_amp": float(cp.season_temp_amp) if "season_temp_amp" in cp else 0.20,
		"insol_gain": float(cp.insolation_season_gain) if "insolation_season_gain" in cp else 1.0,
		"moist_scale_now": 1.0,
		"runtime_moisture_base_relax_rate": float(cp.runtime_moisture_base_relax_rate) if "runtime_moisture_base_relax_rate" in cp else 0.24,
		"runtime_moisture_weather_vapor_weight": float(cp.runtime_moisture_weather_vapor_weight) if "runtime_moisture_weather_vapor_weight" in cp else 0.12,
		"runtime_moisture_precip_weight": float(cp.runtime_moisture_precip_weight) if "runtime_moisture_precip_weight" in cp else 0.78,
		"runtime_moisture_soil_weight": float(cp.runtime_moisture_soil_weight) if "runtime_moisture_soil_weight" in cp else 1.82,
		"runtime_moisture_soil_dry_weight": float(cp.runtime_moisture_soil_dry_weight) if "runtime_moisture_soil_dry_weight" in cp else 2.21,
		"runtime_moisture_water_balance_weight": float(cp.runtime_moisture_water_balance_weight) if "runtime_moisture_water_balance_weight" in cp else 1.04,
		"runtime_moisture_water_balance_dry_weight": float(cp.runtime_moisture_water_balance_dry_weight) if "runtime_moisture_water_balance_dry_weight" in cp else 1.30,
		"days_per_year": host.generator._calendar_days_per_year(),
		"sea_level": float(host.generator._last_cfg.sea_level) if host.generator._last_cfg != null else 0.5,
		# pass_a 扩展 scalars — mirror sync `_climate_pass_a` cp_struct。
		"thermal_inertia_land": float(cp.thermal_inertia_land) if "thermal_inertia_land" in cp else 0.35,
		"thermal_inertia_water": float(cp.thermal_inertia_water) if "thermal_inertia_water" in cp else 0.045,
		"thermal_inertia_snow": float(cp.thermal_inertia_snow) if "thermal_inertia_snow" in cp else 0.09,
		"thermal_inertia_high_mountain": float(cp.thermal_inertia_high_mountain) if "thermal_inertia_high_mountain" in cp else 0.16,
		"thermal_daily_delta_cap": float(cp.thermal_daily_delta_cap) if "thermal_daily_delta_cap" in cp else 0.15,
		"snowpack_cover_low": float(cp.snowpack_cover_low) if "snowpack_cover_low" in cp else 0.05,
		"snowpack_cover_full": float(cp.snowpack_cover_full) if "snowpack_cover_full" in cp else 0.32,
		"insol_dev_min": float(cp.insolation_dev_clamp_min) if "insolation_dev_clamp_min" in cp else -1.0,
		"insol_dev_max": float(cp.insolation_dev_clamp_max) if "insolation_dev_clamp_max" in cp else 1.0,
		# [climate-zone-fix P2] 沿海海洋性调温（与 sync _build_native_daily_climate_pass_a_struct mirror，
		# 同一 _ensure_maritime_factor 缓存→async/sync 逐位一致）
		"maritime_season_damp": float(cp.maritime_season_damp) if "maritime_season_damp" in cp else 0.0,
		"maritime_factor": host.generator._ensure_maritime_factor(host.map, float(cp.maritime_decay_cells) if "maritime_decay_cells" in cp else 4.0),
		# transp scalars
		"transp_outflow_rate": float(cp.transpiration_outflow_rate) if "transpiration_outflow_rate" in cp else 0.025,
		"transp_self_rate":    float(cp.transpiration_self_rate)    if "transpiration_self_rate"    in cp else 0.015,
	}
	# pass_b knobs（移植自 sync _build_native_daily_climate_pass_b_knobs，字段名必须 mirror）
	input["pb_winter_boost"]  = 1.0
	input["pb_snow_cool"]     = float(cp.snow_albedo_cooling) if "snow_albedo_cooling" in cp else 0.0
	input["pb_veg_cool"]      = float(cp.vegetation_cooling) if "vegetation_cooling" in cp else 0.0
	input["pb_diurnal_amp"]   = float(cp.landform_diurnal_amp) if "landform_diurnal_amp" in cp else 0.0
	input["pb_evap_gain"]     = float(cp.evaporation_gain) if "evaporation_gain" in cp else 0.0
	input["pb_rs_threshold"]  = float(cp.rain_shadow_threshold) if "rain_shadow_threshold" in cp else 0.0
	input["pb_rs_factor"]     = float(cp.rain_shadow_factor) if "rain_shadow_factor" in cp else 1.0
	input["pb_rs_lookback"]   = max(0, int(cp.rain_shadow_lookback)) if "rain_shadow_lookback" in cp else 0
	input["pb_t_freeze"]      = float(cp.sea_ice_form_threshold) if "sea_ice_form_threshold" in cp else 0.0
	input["pb_coupling_gain"] = float(cp.ocean_moisture_coupling_gain) if "ocean_moisture_coupling_gain" in cp else 0.0
	# coast_leak 来自 _last_cfg.COASTAL_HEAT_LEAK，不是 cp 字段
	input["pb_coast_leak"]    = float(host.generator._last_cfg.COASTAL_HEAT_LEAK) if host.generator._last_cfg != null else 0.0
	input["pb_sea_ice_albedo_cooling"] = float(cp.sea_ice_albedo_cooling) if "sea_ice_albedo_cooling" in cp else 0.01
	# ocean_water knobs — sync 用 _last_cfg.OCEAN_HEAT_* （map_generator.gd:9679-9680）
	input["ow_advect_steps"] = max(0, int(host.generator._last_cfg.OCEAN_HEAT_ADVECT_STEPS)) if host.generator._last_cfg != null else 3
	input["ow_heat_mix"]     = clampf(float(host.generator._last_cfg.OCEAN_HEAT_MIX), 0.0, 1.0) if host.generator._last_cfg != null else 0.55
	# ocean TTA scalars — sync 用 _temperature_transport_anomaly_knobs (map_generator.gd:2083-2104)
	# 来源：cp.temperature_transport_anomaly_source_cap / blend_rate / decay_rate / zero_current_decay
	# 缺省值 mirror ClimateProfile / sync _temperature_transport_anomaly_knobs。
	var _tta_source_cap: float = 0.22
	var _tta_blend_rate: float = 0.70
	var _tta_decay_rate: float = 0.04
	var _tta_zero_curr_decay: float = 0.06
	if cp != null:
		if "temperature_transport_anomaly_source_cap" in cp:
			_tta_source_cap = clampf(float(cp.temperature_transport_anomaly_source_cap), 0.0, 0.5)
		if "temperature_transport_anomaly_blend_rate" in cp:
			_tta_blend_rate = clampf(float(cp.temperature_transport_anomaly_blend_rate), 0.0, 1.0)
		if "temperature_transport_anomaly_decay_rate" in cp:
			_tta_decay_rate = clampf(float(cp.temperature_transport_anomaly_decay_rate), 0.0, 1.0)
		if "temperature_transport_anomaly_zero_current_decay" in cp:
			_tta_zero_curr_decay = clampf(float(cp.temperature_transport_anomaly_zero_current_decay), 0.0, 1.0)
	# ocean_water 和 ocean_land 都需要这 4 个；C++ 端用 ow_tta_*/ol_tta_* 分别取
	input["ow_tta_source_cap"]          = _tta_source_cap
	input["ow_tta_blend_rate"]          = _tta_blend_rate
	input["ow_tta_zero_current_decay"]  = _tta_zero_curr_decay
	input["ol_tta_source_cap"]          = _tta_source_cap
	input["ol_tta_blend_rate"]          = _tta_blend_rate
	input["ol_tta_decay_rate"]          = _tta_decay_rate
	# ocean_land knobs — sync 用 _last_cfg.COASTAL_HEAT_LEAK * winter_boost(1.0)（map_generator.gd:9916-9917）
	input["ol_effective_leak"] = float(host.generator._last_cfg.COASTAL_HEAT_LEAK) if host.generator._last_cfg != null else 0.55
	# wind_air knobs — sync 用 _last_cfg.WIND_HEAT_*（map_generator.gd:12637-12638）
	input["wa_advect_steps"] = max(0, int(host.generator._last_cfg.WIND_HEAT_ADVECT_STEPS)) if host.generator._last_cfg != null else 3
	input["wa_heat_mix"]     = clampf(float(host.generator._last_cfg.WIND_HEAT_MIX), 0.0, 1.0) if host.generator._last_cfg != null else 0.25
	# wind_surface knobs — sync 用 _last_cfg.AIR_MASS_HEAT_LEAK（map_generator.gd:12672）
	input["ws_air_leak"]     = float(host.generator._last_cfg.AIR_MASS_HEAT_LEAK) if host.generator._last_cfg != null else 0.35
	input["ws_cold_transport_form"] = float(cp.sea_ice_form_threshold) if "sea_ice_form_threshold" in cp else 0.06
	input["ws_cold_transport_melt"] = float(cp.sea_ice_melt_threshold) if "sea_ice_melt_threshold" in cp else 0.11
	# sea_ice knobs — sync 用 cp.sea_ice_freeze_rate / sea_ice_melt_rate / sea_ice_form_threshold /
	#   sea_ice_melt_threshold / sea_ice_neighbor_contagion / sea_ice_terrain_threshold /
	#   sea_ice_terrain_hysteresis（_apply_sea_ice_daily_pass map_generator.gd:8020-8026）
	# 还有 sea_ice_freeze_insol_low/high / sea_ice_solar_melt_start/gain / sea_ice_daily_delta_cap /
	#   sea_ice_solar_gate_enabled / OCEAN_CURRENT_ICE_DELAY / enable_ocean_heat_transport
	input["si_k_freeze"]     = float(cp.sea_ice_freeze_rate) if "sea_ice_freeze_rate" in cp else 0.40
	input["si_k_melt"]       = float(cp.sea_ice_melt_rate)   if "sea_ice_melt_rate"   in cp else 1.45
	input["si_t_form"]       = float(cp.sea_ice_form_threshold) if "sea_ice_form_threshold" in cp else 0.06
	input["si_t_melt"]       = float(cp.sea_ice_melt_threshold) if "sea_ice_melt_threshold" in cp else 0.11
	input["si_contagion"]    = float(cp.sea_ice_neighbor_contagion) if "sea_ice_neighbor_contagion" in cp else 0.035
	input["si_threshold"]    = float(cp.sea_ice_terrain_threshold) if "sea_ice_terrain_threshold" in cp else 0.68
	input["si_hysteresis"]   = float(cp.sea_ice_terrain_hysteresis) if "sea_ice_terrain_hysteresis" in cp else 0.12
	input["si_ice_delay"]    = float(host.generator._last_cfg.OCEAN_CURRENT_ICE_DELAY) if host.generator._last_cfg != null else 1.0
	input["si_solar_gate_enabled"] = bool(cp.sea_ice_solar_gate_enabled) if "sea_ice_solar_gate_enabled" in cp else true
	input["si_freeze_insol_low"]  = float(cp.sea_ice_freeze_insol_low) if "sea_ice_freeze_insol_low" in cp else 0.22
	input["si_freeze_insol_high"] = float(cp.sea_ice_freeze_insol_high) if "sea_ice_freeze_insol_high" in cp else 0.45
	input["si_solar_melt_start"]  = float(cp.sea_ice_solar_melt_start) if "sea_ice_solar_melt_start" in cp else 0.28
	input["si_solar_melt_gain"]   = float(cp.sea_ice_solar_melt_gain) if "sea_ice_solar_melt_gain" in cp else 1.35
	input["si_min_thick_ice_solar_exposure"] = float(cp.sea_ice_min_thick_ice_solar_exposure) if "sea_ice_min_thick_ice_solar_exposure" in cp else 0.32
	input["si_daily_delta_cap"]   = float(cp.sea_ice_daily_delta_cap) if "sea_ice_daily_delta_cap" in cp else 0.070
	input["si_edge_mix_rate"]     = float(cp.sea_ice_edge_mix_rate) if "sea_ice_edge_mix_rate" in cp else 0.035
	input["si_enable_oht"]        = bool(host.generator._last_cfg.enable_ocean_heat_transport) if host.generator._last_cfg != null else true
	# climate_anomaly 阈值偏移（与 _apply_sea_ice_daily_pass map_generator.gd:8044-8046 同源）
	# sync 路径在调 C++ run_sea_ice_daily_pass 前已把 t_form/t_melt 减去 climate_anomaly_now * 0.10。
	# async 模式要 mirror 这个 shift —— worker 用相同 t_form/t_melt 才能 bit-equal。
	var _ca_now: float = 0.0
	if host.generator._world_clock_ref != null:
		var _ca_v = host.generator._world_clock_ref.get("climate_anomaly")
		if _ca_v != null:
			_ca_now = float(_ca_v)
	if not is_equal_approx(_ca_now, 0.0):
		var _ice_thr_shift: float = 0.10 * _ca_now
		input["si_t_form"] = clampf(float(input["si_t_form"]) - _ice_thr_shift, 0.0, 1.0)
		input["si_t_melt"] = clampf(float(input["si_t_melt"]) - _ice_thr_shift, 0.0, 1.0)
	# apply_terrain_flips：sync 路径里由 GDScript caller 处理翻转，async 模式建议
	# 让 C++ worker 写好 out.terrain（apply=true）→ poll 写回 _slots[cell_terrain]，
	# 减少主线程处理量。
	input["si_apply_terrain_flips"] = true
	# si_dt_days：sync 路径每次调 sea_ice 时从 generator consume（map_generator.gd:8011
	# `_apply_sea_ice_daily_pass` 调用 `_consume_sea_ice_dt_days()`）。async 模式在
	# kick 时 consume，传给 worker 用。
	if host.generator.has_method("_consume_sea_ice_dt_days"):
		input["si_dt_days"] = float(host.generator._consume_sea_ice_dt_days())
	else:
		input["si_dt_days"] = 1.0
	# thermal_dt_days：与 si_dt_days 同源。pass_a 热惯性松弛/delta_cap 按实际经过
	# 天数积分，否则加速档下海洋温度欠积分、滞后太阳直射点。worker 默认 1.0（缺键时）。
	if host.generator.has_method("_consume_climate_dt_days"):
		input["thermal_dt_days"] = float(host.generator._consume_climate_dt_days())
	else:
		input["thermal_dt_days"] = 1.0
	# ─── finalizer pass fields（Stage 9 / Fix #11, 2026-06-16） ─────────────
	# C++ worker 的 finalizer kernel 等价 _apply_daily_climate_finalizer，
	# 跳过 main thread 上 4 个 2400-loop + 2 个 sort + 3 个 write_f32_dense（实测 13-17ms）。
	# 关键输入：round-start snapshot（temp / TTA / sea_ice_prev / precip）。
	input["fin_temp_start_of_day"] = host._temp_start_of_day_arr
	input["fin_tta_start_of_day"]  = host._tta_start_of_day_arr
	input["fin_sea_ice_frac_prev"] = host.map.sea_ice_frac_arr_prev if host.map.sea_ice_frac_arr_prev.size() == n_cells else PackedFloat32Array()
	input["fin_weather_precip"]    = host.map.weather_precip_arr if host.map.weather_precip_arr.size() == n_cells else PackedFloat32Array()
	input["fin_temp_cap_enabled"]  = bool(cp.thermal_final_delta_cap_enabled) if cp != null and "thermal_final_delta_cap_enabled" in cp else true
	input["fin_temp_cap"]          = float(cp.thermal_daily_delta_cap) if cp != null and "thermal_daily_delta_cap" in cp else 0.15
	input["fin_tta_cap"]           = float(cp.temperature_transport_anomaly_daily_cap) if cp != null and "temperature_transport_anomaly_daily_cap" in cp else 0.12
	input["fin_has_temp_start"]    = host._temp_start_of_day_arr.size() == n_cells
	input["fin_has_tta_start"]     = host._tta_start_of_day_arr.size() == n_cells
	# passes_mask: 默认含 finalizer bit 8；风热输运关闭时 mirror sync/native daily gate。
	var passes_mask: int = 0x1FF
	var wind_heat_enabled: bool = true
	if cp != null and "enable_wind_heat_transport" in cp:
		wind_heat_enabled = bool(cp.enable_wind_heat_transport)
	if not wind_heat_enabled:
		passes_mask = passes_mask & ~0x30 # bit 4=wind_air, bit 5=wind_surface
	input["passes_mask"] = passes_mask
	return input


# 静态 knobs（round 间不变化）。register 后第一次 set，round 间复用。

static func _build_async_static_knobs(host) -> Dictionary:
	var n_cells: int = host.map.cell_count()
	var nb_idx: PackedInt32Array = host.map.neighbor_indices_packed() if host.map.has_indices() else PackedInt32Array()
	var donor_table: PackedFloat32Array = host.generator._build_transpiration_donor_table()
	var foliage_table: PackedFloat32Array = host.generator._build_climate_b_foliage_table() if host.generator.has_method("_build_climate_b_foliage_table") else PackedFloat32Array()
	return {
		"n_cells": n_cells,
		"neighbor_indices": nb_idx,
		"donor_table": donor_table,
		"foliage_table": foliage_table,
	}


# Worker poll 完成时处理 sea_ice flip events。
# - 写 _slots[cell_terrain] 已由 C++ poll 完成（apply_terrain_flips=true）。
# - 这里只做 GDScript 端的：map.terrain_arr 已被 flush 同步过；
#   告诉 atlas pipeline / sea_ice atlas 把翻转 cell 标 dirty。

static func _handle_async_sea_ice_flips(host, poll_result: Dictionary) -> void:
	if not poll_result.has("flipped_cell_indices"):
		return
	var indices: PackedInt32Array = poll_result["flipped_cell_indices"]
	if indices.size() <= 0:
		return
	var terrain_values: PackedByteArray = poll_result.get("flipped_new_terrain", PackedByteArray())
	var applied_indexed: bool = false
	if host.generator != null and host.generator.has_method("_apply_sea_ice_terrain_flips_indexed") \
			and terrain_values.size() >= indices.size():
		var diag: Dictionary = host.generator._apply_sea_ice_terrain_flips_indexed(host.map, indices, terrain_values, true)
		applied_indexed = bool(diag.get("applied", false))
	if not applied_indexed:
		for idx in indices:
			if host.map.has_method("mark_climate_dirty"):
				host.map.mark_climate_dirty(int(idx))
		if host._world != null and host._world.has_method("mark_dirty_indexed"):
			host._world.mark_dirty_indexed(indices)
