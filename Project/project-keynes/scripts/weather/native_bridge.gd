extends RefCounted


func _sync_profile_weather_knobs(host, cp: Resource) -> void:
	if cp == null:
		return
	if cp.get("weather_field_enabled") != null:
		host._weather_field_enabled = bool(cp.weather_field_enabled)
	if cp.get("weather_field_advect_steps") != null:
		host._field_advect_steps = clampi(int(cp.weather_field_advect_steps), 0, 8)  # 方案③ 上限 4→8
	if cp.get("weather_field_diffusion") != null:
		host._field_diffusion = clampf(float(cp.weather_field_diffusion), 0.0, 0.5)
	if cp.get("weather_condensation_gain") != null:
		host._field_condensation_gain = maxf(0.0, float(cp.weather_condensation_gain))
	if cp.get("weather_precip_decay") != null:
		host._field_precip_decay = clampf(float(cp.weather_precip_decay), 0.0, 1.0)
	if cp.get("weather_orographic_lift_gain") != null:
		host._field_orographic_lift_gain = maxf(0.0, float(cp.weather_orographic_lift_gain))
	if cp.get("weather_convergence_gain") != null:
		host._field_convergence_gain = maxf(0.0, float(cp.weather_convergence_gain))
	if cp.get("weather_ocean_evap_gain") != null:
		host._field_ocean_evap_gain = maxf(0.0, float(cp.weather_ocean_evap_gain))
	if cp.get("weather_land_evapotranspiration_gain") != null:
		host._field_land_evapotranspiration_gain = maxf(0.0, float(cp.weather_land_evapotranspiration_gain))
	if cp.get("weather_precip_rh_threshold") != null:
		host._field_precip_rh_threshold = clampf(float(cp.weather_precip_rh_threshold), 0.40, 0.95)
	if cp.get("weather_ocean_precip_suppression") != null:
		host._field_ocean_precip_suppression = clampf(float(cp.weather_ocean_precip_suppression), 0.0, 1.0)
	if cp.get("weather_frontogenesis_gain") != null:
		host._field_frontogenesis_gain = maxf(0.0, float(cp.weather_frontogenesis_gain))
	if cp.get("weather_field_thermal_conv_precip") != null:
		host._field_thermal_conv_precip = clampf(float(cp.weather_field_thermal_conv_precip), 0.0, 1.0)
	if cp.get("weather_field_stratiform_gain") != null:
		host._field_stratiform_gain = clampf(float(cp.weather_field_stratiform_gain), 0.0, 3.0)
	if cp.get("weather_field_omega_ascent_gain") != null:
		host._field_omega_ascent_gain = clampf(float(cp.weather_field_omega_ascent_gain), 0.0, 1.5)
	if cp.get("weather_cool_season_vapor_floor") != null:
		host._field_cool_season_vapor_floor = clampf(float(cp.weather_cool_season_vapor_floor), 0.0, 0.6)
	if cp.get("weather_rain_shadow_drying") != null:
		host._field_rain_shadow_drying = clampf(float(cp.weather_rain_shadow_drying), 0.0, 1.0)
	if cp.get("weather_vapor_transport_gain") != null:
		host._field_vapor_transport_gain = clampf(float(cp.weather_vapor_transport_gain), 0.0, 1.0)
	if cp.get("weather_component_summary_limit") != null:
		host._field_summary_limit = clampi(int(cp.weather_component_summary_limit), 1, 12)
	if cp.get("weather_convergence_refresh_stride") != null:
		host._field_convergence_refresh_stride = clampi(int(cp.weather_convergence_refresh_stride), 1, 12)
	if cp.get("weather_precip_carryover_max") != null:
		host._field_precip_carryover_max = clampf(float(cp.weather_precip_carryover_max), 0.0, 1.0)
	if cp.get("weather_vapor_precip_sink") != null:
		host._field_vapor_precip_sink = clampf(float(cp.weather_vapor_precip_sink), 0.0, 1.0)
	if cp.get("weather_precip_inertia") != null:
		host._field_precip_inertia = clampf(float(cp.weather_precip_inertia), 0.05, 1.0)
	if cp.get("weather_field_precip_base_frac") != null:
		host._field_precip_base_frac = clampf(float(cp.weather_field_precip_base_frac), 0.0, 1.0)
	if cp.get("weather_field_cloud_reevap") != null:
		host._field_cloud_reevap = clampf(float(cp.weather_field_cloud_reevap), 0.0, 0.5)
	if cp.get("weather_field_cloud_inertia") != null:
		host._field_cloud_inertia = clampf(float(cp.weather_field_cloud_inertia), 0.05, 1.0)
	if cp.get("snowpack_accum_gain") != null:
		host._snowpack_accum_gain = clampf(float(cp.snowpack_accum_gain), 0.0, 1.0)
	if cp.get("snowpack_melt_temp_gain") != null:
		host._snowpack_melt_temp_gain = clampf(float(cp.snowpack_melt_temp_gain), 0.0, 1.0)
	if cp.get("snowpack_melt_sun_gain") != null:
		host._snowpack_melt_sun_gain = clampf(float(cp.snowpack_melt_sun_gain), 0.0, 1.0)
	if cp.get("snowpack_cover_low") != null:
		host._snowpack_cover_low = clampf(float(cp.snowpack_cover_low), 0.0, 0.5)
	if cp.get("snowpack_cover_full") != null:
		host._snowpack_cover_full = maxf(host._snowpack_cover_low + 0.001, clampf(float(cp.snowpack_cover_full), 0.0, 1.0))
	if cp.get("snow_accum_days_req") != null:
		host._snow_accum_days_req = clampi(int(cp.snow_accum_days_req), 1, 8)
	if cp.get("weather_temp_anomaly_cap") != null:
		host._weather_temp_anomaly_cap = clampf(float(cp.weather_temp_anomaly_cap), 0.0, 0.10)
	host._weather_direct_moisture_enabled = bool(cp.get("weather_direct_moisture_enabled")) \
		if cp.get("weather_direct_moisture_enabled") != null else false
	if cp.get("snowline_temp_threshold") != null:
		host._snowline_temp_threshold = clampf(float(cp.snowline_temp_threshold), 0.0, 1.0)
	if cp.get("snowline_band") != null:
		host._snowline_band = clampf(float(cp.snowline_band), 0.02, 0.6)
	if cp.get("weather_vapor_relax_rate") != null:
		host._field_vapor_relax_rate = clampf(float(cp.weather_vapor_relax_rate), 0.0, 1.0)
	if cp.get("weather_orographic_lift_cap") != null:
		host._field_orographic_lift_cap = clampf(float(cp.weather_orographic_lift_cap), 0.0, 1.0)
	if cp.get("weather_wet_terrain_precip_damping") != null:
		host._field_wet_terrain_precip_damping = clampf(float(cp.weather_wet_terrain_precip_damping), 0.0, 1.0)
	if cp.get("weather_lake_precip_damping") != null:
		host._field_lake_precip_damping = clampf(float(cp.weather_lake_precip_damping), 0.0, 1.0)
	if cp.get("weather_lake_evap_scale") != null:
		host._field_lake_evap_scale = clampf(float(cp.weather_lake_evap_scale), 0.0, 1.0)
	if cp.get("weather_extreme_precip_soft_cap") != null:
		host._field_extreme_precip_soft_cap = clampf(float(cp.weather_extreme_precip_soft_cap), 0.0, 1.0)
	if cp.get("weather_extreme_precip_softness") != null:
		host._field_extreme_precip_softness = clampf(float(cp.weather_extreme_precip_softness), 0.0, 1.0)
	if cp.get("weather_cold_precip_as_blizzard") != null:
		host._cold_precip_as_blizzard = bool(cp.weather_cold_precip_as_blizzard)
	if cp.get("weather_snow_classification_margin") != null:
		host._snow_classification_margin = clampf(float(cp.weather_snow_classification_margin), 0.0, 0.12)

func _transition_enabled(host) -> Dictionary:
	var enabled: bool = bool(host._cp_for_front_flag.weather_transition_enabled) if host._cp_for_front_flag != null and host._cp_for_front_flag.get("weather_transition_enabled") != null else false
	var alpha_rate: float = float(host._cp_for_front_flag.weather_transition_alpha_rate) if host._cp_for_front_flag != null and host._cp_for_front_flag.get("weather_transition_alpha_rate") != null else 1.0
	return {"enabled": enabled, "alpha_rate": alpha_rate}

func _build_weather_field_knobs(host, map: MapData, world: WorldData, n_cells: int, start_idx: int = 0, end_idx: int = -1) -> Dictionary:
	var transition = _transition_enabled(host)
	var transition_enabled: bool = transition["enabled"]
	var transition_alpha_rate: float = transition["alpha_rate"]
	var end_idx_resolved: int = n_cells if end_idx < 0 else end_idx
	var temp_anom_arr: PackedFloat32Array = host._field_solver._field_slice_temp_anom
	if temp_anom_arr.size() != n_cells:
		temp_anom_arr = map.temperature_transport_anomaly_arr
	if temp_anom_arr.size() != n_cells:
		temp_anom_arr = PackedFloat32Array()
		temp_anom_arr.resize(n_cells)
		var cells_l: Array = host._field_solver._field_slice_cells
		for i in range(n_cells):
			var c: HexCell = cells_l[i]
			temp_anom_arr[i] = float(c.temperature_transport_anomaly)
	# ─── Phase A.3 fast path：从 KnobsHandle 拿标量段缓存 Dict ──────────
	# 动态字段（SoA cache / PackedArray ref / temp_anom_arr）仍每帧准备并 merge。
	# 标量段在 ClimateProfile 不变的稳态下复用缓存 Dict（CoW 引用 ++）。
	if host._knobs_handle != null and host._knobs_handle.has_method("to_field_knobs_dict"):
		# day_counter / season_phase 每帧可能变 → 这里同步推一次（dirty-write 内部
		# 走值比较，无变化时不拉 dirty，缓存 Dict 命中）。
		host._push_resident_knobs_from_cp(host._cp_for_front_flag)
		var dynamic_fields: Dictionary = {
			"start_idx": start_idx,
			"end_idx": end_idx_resolved,
			"n_cells": n_cells,
			"season_idx": host._field_solver._field_slice_season_idx,
			"climate_anomaly": host._field_solver._field_slice_climate_anomaly,
			"refresh_convergence": host._field_solver._field_slice_refresh_convergence,
			"weather_lat_te_norm": host._field_solver._field_slice_lat_te_norm,
			"weather_solve_tick": host._field_solve_tick,
			"cell_pos": host._field_solver._field_slice_cell_pos,
			"weather_wrap_width_x": host._field_solver._field_slice_wrap_width_x,
			"weather_cell_pos_scale": host._field_solver._field_slice_cell_pos_scale,
			"temp_anomaly": map.temp_anomaly_arr,
			"neighbor_indices": host._field_solver._field_slice_neighbor_indices,
			"prev_vapor": host._field_solver._field_slice_prev_vapor,
			"prev_precip": host._field_solver._field_slice_prev_precip,
			"prev_cloud_water": map.weather_cloud_water_arr,
			"temp_read_arr": host._field_solver._field_slice_temp_read,
			"moisture_read_arr": host._field_solver._field_slice_moisture_read,
			"snow_cover_read_arr": host._field_solver._field_slice_snow_cover_read,
			"temp_transport_anomaly": temp_anom_arr,
			"out_vapor": host._field_solver._field_slice_next_vapor,
			"out_cloud": host._field_solver._field_slice_next_cloud,
			"out_cloud_water": host._field_solver._field_slice_next_cloud_water,
			"out_precip": host._field_solver._field_slice_next_precip,
			"out_instability": host._field_solver._field_slice_next_instability,
			"out_intensity": host._field_solver._field_slice_next_intensity,
			"out_convergence": host._field_solver._field_slice_next_convergence,
			"out_type": host._field_solver._field_slice_next_type,
			"field_precip_carryover_max": host._field_precip_carryover_max,
			"field_vapor_precip_sink": host._field_vapor_precip_sink,
			"field_precip_inertia": host._field_precip_inertia,
			"field_precip_base_frac": host._field_precip_base_frac,
			"field_cloud_reevap": host._field_cloud_reevap,
			"field_cloud_inertia": host._field_cloud_inertia,
			"field_vapor_relax_rate": host._field_vapor_relax_rate,
			"field_orographic_lift_cap": host._field_orographic_lift_cap,
			"field_wet_terrain_precip_damping": host._field_wet_terrain_precip_damping,
			"field_lake_precip_damping": host._field_lake_precip_damping,
			"field_lake_evap_scale": host._field_lake_evap_scale,
			"field_extreme_precip_soft_cap": host._field_extreme_precip_soft_cap,
			"field_extreme_precip_softness": host._field_extreme_precip_softness,
			"field_land_evapotranspiration_gain": host._field_land_evapotranspiration_gain,
			"field_precip_rh_threshold": host._field_precip_rh_threshold,
			"field_ocean_precip_suppression": host._field_ocean_precip_suppression,
			"field_frontogenesis_gain": host._field_frontogenesis_gain,
			"field_thermal_conv_precip": host._field_thermal_conv_precip,
			"field_stratiform_gain": host._field_stratiform_gain,
			"field_omega_ascent_gain": host._field_omega_ascent_gain,
			"field_cool_season_vapor_floor": host._field_cool_season_vapor_floor,
			"field_rain_shadow_drying": host._field_rain_shadow_drying,
			"field_vapor_transport_gain": host._field_vapor_transport_gain,
			"cold_precip_as_blizzard": host._cold_precip_as_blizzard,
			"snow_classification_margin": host._snow_classification_margin,
			"weather_transition_enabled": transition_enabled,
			"weather_transition_alpha_rate": transition_alpha_rate,
			"weather_transition_dt_days": host._weather_transition_dt_days,
		}
		return host._merge_resident_knobs_with_dynamic(host._knobs_handle.to_field_knobs_dict(), dynamic_fields)
	# ─── Fallback：原 builder 路径（与 Phase A.3 之前 100% bit-equal）──
	return {
		"start_idx": start_idx,
		"end_idx": end_idx_resolved,
		"n_cells": n_cells,
		"season_idx": host._field_solver._field_slice_season_idx,
		"climate_anomaly": host._field_solver._field_slice_climate_anomaly,
		"season_phase": host._season_phase,
		"world_bounds_pos_y": host._world_bounds.position.y,
		"world_bounds_size_y": host._world_bounds.size.y,
		"weather_lat_te_norm": host._field_solver._field_slice_lat_te_norm,
		"weather_solve_tick": host._field_solve_tick,
		"refresh_convergence": host._field_solver._field_slice_refresh_convergence,
		"weather_wrap_width_x": host._field_solver._field_slice_wrap_width_x,
		"weather_cell_pos_scale": host._field_solver._field_slice_cell_pos_scale,
		"apply_convergence_boost": not host._field_verify_enabled,
		"hex_size": host._hex_size,
		"field_advect_steps": host._field_advect_steps,
		"field_diffusion": host._field_diffusion,
		"field_condensation_gain": host._field_condensation_gain,
		"field_orographic_lift_gain": host._field_orographic_lift_gain,
		"field_convergence_gain": host._field_convergence_gain,
		"field_ocean_evap_gain": host._field_ocean_evap_gain,
		"field_precip_decay": host._field_precip_decay,
		"cell_pos": host._field_solver._field_slice_cell_pos,
		"temp_anomaly": map.temp_anomaly_arr,
		"neighbor_indices": host._field_solver._field_slice_neighbor_indices,
		"prev_vapor": host._field_solver._field_slice_prev_vapor,
		"prev_precip": host._field_solver._field_slice_prev_precip,
		"prev_cloud_water": map.weather_cloud_water_arr,
		"temp_read_arr": host._field_solver._field_slice_temp_read,
		"moisture_read_arr": host._field_solver._field_slice_moisture_read,
		"snow_cover_read_arr": host._field_solver._field_slice_snow_cover_read,
		"temp_transport_anomaly": temp_anom_arr,
		"out_vapor": host._field_solver._field_slice_next_vapor,
		"out_cloud": host._field_solver._field_slice_next_cloud,
		"out_cloud_water": host._field_solver._field_slice_next_cloud_water,
		"out_precip": host._field_solver._field_slice_next_precip,
		"out_instability": host._field_solver._field_slice_next_instability,
		"out_intensity": host._field_solver._field_slice_next_intensity,
		"out_convergence": host._field_solver._field_slice_next_convergence,
		"out_type": host._field_solver._field_slice_next_type,
		"field_precip_carryover_max": host._field_precip_carryover_max,
		"field_vapor_precip_sink": host._field_vapor_precip_sink,
		"field_precip_inertia": host._field_precip_inertia,
		"field_precip_base_frac": host._field_precip_base_frac,
		"field_cloud_reevap": host._field_cloud_reevap,
		"field_cloud_inertia": host._field_cloud_inertia,
		"field_vapor_relax_rate": host._field_vapor_relax_rate,
		"field_orographic_lift_cap": host._field_orographic_lift_cap,
		"field_wet_terrain_precip_damping": host._field_wet_terrain_precip_damping,
		"field_lake_precip_damping": host._field_lake_precip_damping,
		"field_lake_evap_scale": host._field_lake_evap_scale,
		"field_extreme_precip_soft_cap": host._field_extreme_precip_soft_cap,
		"field_extreme_precip_softness": host._field_extreme_precip_softness,
		"field_land_evapotranspiration_gain": host._field_land_evapotranspiration_gain,
		"field_precip_rh_threshold": host._field_precip_rh_threshold,
		"field_ocean_precip_suppression": host._field_ocean_precip_suppression,
		"field_frontogenesis_gain": host._field_frontogenesis_gain,
		"field_thermal_conv_precip": host._field_thermal_conv_precip,
		"field_stratiform_gain": host._field_stratiform_gain,
		"field_omega_ascent_gain": host._field_omega_ascent_gain,
		"field_cool_season_vapor_floor": host._field_cool_season_vapor_floor,
		"field_rain_shadow_drying": host._field_rain_shadow_drying,
		"field_vapor_transport_gain": host._field_vapor_transport_gain,
		"cold_precip_as_blizzard": host._cold_precip_as_blizzard,
		"snow_classification_margin": host._snow_classification_margin,
		"weather_transition_enabled": transition_enabled,
		"weather_transition_alpha_rate": transition_alpha_rate,
		"weather_transition_dt_days": host._weather_transition_dt_days,
	}

# 调用 C++ 端 run_weather_field_solve_pass。返回 elapsed_ms (≥0) 或 -1.0。
# 任何异常都被 catch 成 -1.0，让上层透明回退。

func _try_run_weather_field_solve_gdext(host, map: MapData, world: WorldData, n_cells: int, start_idx: int = 0, end_idx: int = -1) -> float:
	if host._data_core_world_ext == null:
		return -1.0
	var end_idx_resolved: int = n_cells if end_idx < 0 else end_idx
	var knobs: Dictionary = host._field_solver._field_slice_native_knobs
	var transition = _transition_enabled(host)
	var transition_enabled: bool = transition["enabled"]
	var transition_alpha_rate: float = transition["alpha_rate"]
	if knobs.is_empty():
		knobs = host._build_weather_field_knobs(map, world, n_cells, start_idx, end_idx_resolved)
	else:
		knobs["start_idx"] = start_idx
		knobs["end_idx"] = end_idx_resolved
		knobs["prev_cloud_water"] = map.weather_cloud_water_arr
		knobs["out_vapor"] = host._field_solver._field_slice_next_vapor
		knobs["out_cloud"] = host._field_solver._field_slice_next_cloud
		knobs["out_cloud_water"] = host._field_solver._field_slice_next_cloud_water
		knobs["out_precip"] = host._field_solver._field_slice_next_precip
		knobs["out_instability"] = host._field_solver._field_slice_next_instability
		knobs["out_intensity"] = host._field_solver._field_slice_next_intensity
		knobs["out_convergence"] = host._field_solver._field_slice_next_convergence
		knobs["out_type"] = host._field_solver._field_slice_next_type
	# Stage6c: 对流抑制记忆改存为 C++ ext 成员(_wx_conv_inhib)，不再走 knob 回传(CoW 失败)。GDScript fallback
	# 路径仍用 host._field_solver._convective_inhib 成员(同进程内无边界问题)。# 路径仍用 _field_solver._convective_inhib 成员(同进程内无边界问题)。
	var rc: float = float(host._data_core_world_ext.run_weather_field_solve_pass(knobs))
	if rc >= 0.0 and knobs.has("out_vapor"):
		host._field_solver._field_slice_next_vapor = knobs["out_vapor"]
		host._field_solver._field_slice_next_cloud = knobs["out_cloud"]
		host._field_solver._field_slice_next_cloud_water = knobs.get("out_cloud_water", host._field_solver._field_slice_next_cloud_water)
		host._field_solver._field_slice_next_precip = knobs["out_precip"]
		host._field_solver._field_slice_next_instability = knobs["out_instability"]
		host._field_solver._field_slice_next_intensity = knobs["out_intensity"]
		host._field_solver._field_slice_next_convergence = knobs["out_convergence"]
		host._field_solver._field_slice_next_type = knobs["out_type"]
	# C++ 在失败时已经 push_warning；这里只在第一次 fallback 时打一条 GDScript
	# 侧提示，避免每 tick spam。
	if rc < 0.0 and not host._gdext_field_warned_fallback:
		host._gdext_field_warned_fallback = true
		push_warning("[weather] gdext run_weather_field_solve_pass returned %.2f; falling back to GDScript for this tick (will retry next tick)" % rc)
	return rc


# Stage13「让天气移动」：调用 C++ 独立全场 ψ 推进 pass（每 weather 轮一次，在 commit 后）。
# ψ 演化已从 solve 热循环抽出 → 本 pass 用平滑引导流做半拉格朗日真平移，让 ψ 涡旋成片随风移动；
# solve 循环只读 _wx_synoptic 做耦合 → 云/雨随 ψ 移动。复用本轮 begin 已构建的 native knobs
# (含 cell_pos/neighbor_indices/wind/temp/wrap/tick/syn_*)。未就绪/失败返回 -1.0（ψ 保持上轮值，不崩）。

func _try_run_weather_field_commit_gdext(host, map: MapData, n_cells: int) -> Dictionary:
	if host._data_core_world_ext == null:
		return { "elapsed_ms": -1.0, "reason": "native_unavailable" }
	var knobs: Dictionary = host._field_solver._field_slice_native_knobs
	var transition = _transition_enabled(host)
	var transition_enabled: bool = transition["enabled"]
	var transition_alpha_rate: float = transition["alpha_rate"]
	if knobs.is_empty():
		knobs = {}
	knobs["n_cells"] = n_cells
	knobs["neighbor_indices"] = host._field_solver._field_slice_neighbor_indices
	knobs["prev_vapor"] = host._field_solver._field_slice_prev_vapor
	knobs["out_vapor"] = host._field_solver._field_slice_next_vapor
	knobs["out_cloud"] = host._field_solver._field_slice_next_cloud
	knobs["out_cloud_water"] = host._field_solver._field_slice_next_cloud_water
	knobs["out_precip"] = host._field_solver._field_slice_next_precip
	knobs["out_instability"] = host._field_solver._field_slice_next_instability
	knobs["out_intensity"] = host._field_solver._field_slice_next_intensity
	knobs["out_convergence"] = host._field_solver._field_slice_next_convergence
	knobs["out_type"] = host._field_solver._field_slice_next_type
	knobs["refresh_convergence"] = host._field_solver._field_slice_refresh_convergence
	knobs["weather_transition_enabled"] = transition_enabled
	knobs["weather_transition_alpha_rate"] = transition_alpha_rate
	knobs["weather_transition_dt_days"] = host._weather_transition_dt_days
	var world_ref: WorldData = host._field_solver._field_slice_world
	if world_ref != null and world_ref.lut_dims.x > 0 and world_ref.lut_dims.y > 0:
		knobs["weather_lut_w"] = int(world_ref.lut_dims.x)
		knobs["weather_lut_h"] = int(world_ref.lut_dims.y)
	var rc_dict: Dictionary = host._data_core_world_ext.run_weather_field_commit_pass(knobs)

	var rc: float = float(rc_dict.get("elapsed_ms", -1.0))
	if rc < 0.0 and not host._gdext_field_commit_warned_fallback:
		host._gdext_field_commit_warned_fallback = true
		push_warning("[weather] gdext run_weather_field_commit_pass returned %.2f (%s); falling back to GDScript commit loop" % [
			rc,
			str(rc_dict.get("reason", "unknown")),
		])
	return rc_dict

# ─── Weather Hot-Path：dist GDExt 接入点（plan/weather-hotpath-cpp 任务 3）──
# 与 F.1 同款套路：sig 校验 + knobs 构造 + try。任务 4 实装 C++ 主体后；本接入
# 点立即生效。骨架期 C++ 返回 elapsed_ms = -1 → 自动 fallback 到 GDScript。

func _validate_weather_distribute_signature(host, ext: RefCounted) -> bool:
	if ext == null:
		return false
	var ml: Array = ext.get_method_list()
	for m: Dictionary in ml:
		if String(m.get("name", "")) == "run_weather_distribute_pass":
			var args: Array = m.get("args", [])
			if args.size() == 1:
				return true
			push_warning("[gdext sig] run_weather_distribute_pass has %d args (expected 1); gdext .dll is STALE. REBUILD: 'cd gdext && scons platform=windows target=template_debug dev_build=no -j8'." % args.size())
			return false
	return false


func _validate_weather_summary_signature(host, ext: RefCounted) -> bool:
	if ext == null:
		return false
	var ml: Array = ext.get_method_list()
	for m: Dictionary in ml:
		if String(m.get("name", "")) == "run_weather_summary_fronts_pass":
			var args: Array = m.get("args", [])
			if args.size() == 1:
				return true
			push_warning("[gdext sig] run_weather_summary_fronts_pass has %d args (expected 1); gdext .dll is STALE. REBUILD: 'cd gdext && scons platform=windows target=template_debug dev_build=no -j8'." % args.size())
			return false
	return false


func _build_weather_distribute_knobs(host, map: MapData, n_cells: int) -> Dictionary:
	# 标量入参（snow / flood 阈值与 GDScript 版严格同源；任务 4 在 C++ 内消费）。
	# SoA view 由 C++ 端通过 ext._map_data + 已绑定 schema 直接拿，无需 GDScript
	# 显式传 PackedArray（与 F.1 一致）。
	#
	# 例外（无 SoA 镜像的 AoS 字段）：
	#   - accumulated_snow_days：HexCell.int 字段，没在 component_schema 里。
	#   - pre_snow_cover：HexCell.int 字段，同上。
	# 这两个字段每帧打包成 PackedInt32Array 传入；C++ 写完后通过 CoW alias 透回。
	#
	# WeatherType / LandformType 静态查询：profile lookup 是 Resource access，
	# C++ 拿不到。打包成 8-element PackedArray 按 WT 索引，C++ 内部 O(1) 查表。
	var map_id: int = map.get_instance_id()
	if host._dist_cache_map_id != map_id or host._dist_cache_n != n_cells \
			or host._dist_acc_snow_cache.size() != n_cells or host._dist_pre_cover_cache.size() != n_cells:
		var cells: Array = map.iter_cells() if map.has_indices() else map.all_cells()
		host._dist_acc_snow_cache = PackedInt32Array()
		host._dist_pre_cover_cache = PackedInt32Array()
		host._dist_acc_snow_cache.resize(n_cells)
		host._dist_pre_cover_cache.resize(n_cells)
		for i in range(n_cells):
			var c: HexCell = cells[i]
			host._dist_acc_snow_cache[i] = c.accumulated_snow_days
			host._dist_pre_cover_cache[i] = c.pre_snow_cover
		host._dist_cache_map_id = map_id
		host._dist_cache_n = n_cells
	# 8 个 WT 的 profile 静态值（temp_delta / moisture_delta / can_form_snow /
	# can_form_flood）按 WT 索引。WT 枚举值 0..7（CLEAR..MONSOON）。
	var temp_d: PackedFloat32Array = PackedFloat32Array()
	var moist_d: PackedFloat32Array = PackedFloat32Array()
	var cfs: PackedByteArray = PackedByteArray()
	var cff: PackedByteArray = PackedByteArray()
	temp_d.resize(8)
	moist_d.resize(8)
	cfs.resize(8)
	cff.resize(8)
	for w in range(8):
		temp_d[w] = WeatherType.temp_delta(w)
		moist_d[w] = WeatherType.moisture_delta(w)
		cfs[w] = 1 if WeatherType.can_form_snow(w) else 0
		cff[w] = 1 if WeatherType.can_form_flood(w) else 0
	# ─── Phase A.3 fast path：从 KnobsHandle 拿 distribute 段缓存 Dict ──
	if host._knobs_handle != null and host._knobs_handle.has_method("to_distribute_knobs_dict"):
		# 标量段与 LUT 由 host._push_resident_knobs_from_cp 在 changed signal 时已推送；# 标量段与 LUT 由 _push_resident_knobs_from_cp 在 changed signal 时已推送；
		# 这里仅 merge 动态字段（n_cells / SoA AoS cache）。
		var dynamic_fields_dist: Dictionary = {
			"n_cells": n_cells,
			"accumulated_snow_days": host._dist_acc_snow_cache,
			"pre_snow_cover": host._dist_pre_cover_cache,
			"snowpack_accum_gain": host._snowpack_accum_gain,
			"snowpack_melt_temp_gain": host._snowpack_melt_temp_gain,
			"snowpack_melt_sun_gain": host._snowpack_melt_sun_gain,
			"snowpack_cover_low": host._snowpack_cover_low,
			"snowpack_cover_full": host._snowpack_cover_full,
			"weather_temp_anomaly_cap": host._weather_temp_anomaly_cap,
			"weather_direct_moisture_enabled": host._weather_direct_moisture_enabled,
			"snowline_temp_threshold": host._snowline_temp_threshold,
			"snowline_band": host._snowline_band,
		}
		return host._merge_resident_knobs_with_dynamic(
			host._knobs_handle.to_distribute_knobs_dict(), dynamic_fields_dist)
	return {
		"n_cells": n_cells,
		# host._apply_snow_accumulation 用到的 cover/温度阈值（任务 4 中 C++ 复刻 GDScript# _apply_snow_accumulation 用到的 cover/温度阈值（任务 4 中 C++ 复刻 GDScript
		# 同名函数；任意改动需保持双侧同步）。
		# 2026-05-18 雪线修正：GDScript 在 host._apply_snow_accumulation 内做 elev 偏移；# 2026-05-18 雪线修正：GDScript 在 _apply_snow_accumulation 内做 elev 偏移；
		# C++ 端 run_weather_distribute_pass 已同步实现（gdext/src/world_ext.cpp，
		# host.SNOW_ELEV_NEUTRAL=0.30 / FREEZE_GAIN=0.20 / MELT_GAIN=0.30，常数硬编码不走 knobs）。# SNOW_ELEV_NEUTRAL=0.30 / FREEZE_GAIN=0.20 / MELT_GAIN=0.30，常数硬编码不走 knobs）。
		# 若日后调参，需双侧同步修改。
		"snow_min_intensity": 0.001,
		"snow_freeze_t": host.SNOW_FREEZE_T,
		"snow_melt_t": host.SNOW_MELT_T,
		"snow_intensity_for_snowing": 0.4,
		"snow_accum_days_req": host._snow_accum_days_req,
		"flood_heavy_intensity": 0.55,
		"flood_heavy_precip": 0.55,
		"flood_lowland_intensity": 0.32,
		"flood_lowland_elev": 0.50,
		"flood_lowland_moisture": 0.60,
		"snowpack_accum_gain": host._snowpack_accum_gain,
		"snowpack_melt_temp_gain": host._snowpack_melt_temp_gain,
		"snowpack_melt_sun_gain": host._snowpack_melt_sun_gain,
		"snowpack_cover_low": host._snowpack_cover_low,
		"snowpack_cover_full": host._snowpack_cover_full,
		"weather_temp_anomaly_cap": host._weather_temp_anomaly_cap,
		"weather_direct_moisture_enabled": host._weather_direct_moisture_enabled,
		"snowline_temp_threshold": host._snowline_temp_threshold,
		"snowline_band": host._snowline_band,
		# WT.CLEAR / SNOW / NONE / FLOODING 的 enum 值。GDScript 端用 Type.WT
		# / Type.CV，C++ 不能直接引用，所以把数值传进去。
		"wt_clear": int(WeatherType.WT.CLEAR),
		"cv_snow": int(CoverType.CV.SNOW),
		"cv_none": int(CoverType.CV.NONE),
		"cv_flooding": int(CoverType.CV.FLOODING),
		# AoS 字段 PackedArray（CoW shared via Dictionary 持有）。C++ 直接 ptrw 写回，
		# GDScript 在 try 函数末尾用同样的 Packed 引用 lookup 写回 AoS。
		"accumulated_snow_days": host._dist_acc_snow_cache,
		"pre_snow_cover": host._dist_pre_cover_cache,
		# WeatherType 静态查询表（PackedArray 按 WT 索引，C++ 内部 O(1)）。
		"temp_delta_arr": temp_d,
		"moisture_delta_arr": moist_d,
		"can_form_snow_arr": cfs,
		"can_form_flood_arr": cff,
	}

# ACTIVE climate authority：worker 侧 weather field stage 的 knobs 入口。
#
# 与 distribute 那个包装不同，field knobs 拿不到就建不出来：host._build_weather_field_knobs# 与 distribute 那个包装不同，field knobs 拿不到就建不出来：_build_weather_field_knobs
# 读的是 host._field_solver._field_slice_*，而那套 slice state 由 host.begin_weather_field_solve# 读的是 _field_solver._field_slice_*，而那套 slice state 由 begin_weather_field_solve
# 建立。所以这里必须真的 begin 一次，取完 knobs 立刻 clear —— 权威下生产的 weather
# 段是被抑制的，没有 host.apply_unified_fast_tick_result 会来收尾，留着就是一份每天新建# 段是被抑制的，没有 apply_unified_fast_tick_result 会来收尾，留着就是一份每天新建
# 却永不消费的悬挂 state。
#
# 返回的 PackedArray 是 CoW 值语义，clear 不会动它们，worker 拿到的那份仍然有效。

func _try_run_weather_distribute_gdext(host, map: MapData, n_cells: int) -> Dictionary:
	if host._data_core_world_ext == null:
		return { "elapsed_ms": -1.0, "cover_dirty": false }
	var knobs: Dictionary = host._build_weather_distribute_knobs(map, n_cells)
	var rc_dict: Dictionary = host._data_core_world_ext.run_weather_distribute_pass(knobs)
	var rc: float = float(rc_dict.get("elapsed_ms", -1.0))
	if rc < 0.0:
		host._sync_weather_distribute_cache_to_cells(map, n_cells)
		if not host._gdext_dist_warned_fallback:
			host._gdext_dist_warned_fallback = true
			push_warning("[weather] gdext run_weather_distribute_pass returned %.2f; falling back to GDScript for this tick (will retry next tick)" % rc)
		return rc_dict
	# C++ 已通过 PackedArray ptrw 把 acc_snow_days / pre_snow_cover 改写完成（CoW
	# alias 透传）。fast path 以 PackedArray 为连续状态源，不再每 tick 全量写回
	# HexCell；只有 cover 真正变化的 cell 需要同步 current_state。verify/fallback
	# 路径仍会全量同步，保证调试和降级语义一致。
	var cells: Array = map.iter_cells() if map.has_indices() else map.all_cells()
	var acc_after: PackedInt32Array = knobs.get("accumulated_snow_days", PackedInt32Array())
	var pre_after: PackedInt32Array = knobs.get("pre_snow_cover", PackedInt32Array())
	var changed: PackedInt32Array = rc_dict.get("changed_cells", PackedInt32Array())
	if host._distribute_verify_enabled:
		host._sync_weather_distribute_cache_to_cells(map, n_cells)
	else:
		for ci in changed:
			if ci < 0 or ci >= cells.size():
				continue
			var cc: HexCell = cells[ci]
			if acc_after.size() == n_cells and pre_after.size() == n_cells:
				cc.accumulated_snow_days = acc_after[ci]
				cc.pre_snow_cover = pre_after[ci]
			# C++ 已经写好 cover_arr (SoA)；HexCell facade reader cell.cover 应当透读 SoA。
			# 但 current_state["cover"] 是 dict 字段，需手动同步。
			cc.current_state["cover"] = int(cc.cover)
	return rc_dict


func _build_weather_summary_knobs(host, map: MapData, world: WorldData) -> Dictionary:
	var n_cells: int = map.cell_count()
	var map_id: int = map.get_instance_id()
	if host._summary_cache_map_id != map_id or host._summary_cache_n != n_cells \
			or host._summary_q_cache.size() != n_cells or host._summary_r_cache.size() != n_cells:
		var cells: Array = map.iter_cells() if map.has_indices() else map.all_cells()
		host._summary_q_cache = PackedInt32Array()
		host._summary_r_cache = PackedInt32Array()
		host._summary_q_cache.resize(n_cells)
		host._summary_r_cache.resize(n_cells)
		for i in range(n_cells):
			var c: HexCell = cells[i]
			host._summary_q_cache[i] = c.q
			host._summary_r_cache[i] = c.r
		host._summary_cache_map_id = map_id
		host._summary_cache_n = n_cells
	# wind_x / wind_y 已是 SoA（map.wind_x_arr / wind_y_arr）；C++ 通过 _slots
	# 直接读，不必通过 knobs 传。
	var water_ids: PackedByteArray = PackedByteArray([
		int(TerrainType.TERRAIN.OCEAN) & 0xFF,
		int(TerrainType.TERRAIN.COAST) & 0xFF,
		int(TerrainType.TERRAIN.LAKE) & 0xFF,
		int(TerrainType.TERRAIN.REEF) & 0xFF,
		int(TerrainType.TERRAIN.KELP) & 0xFF,
		int(TerrainType.TERRAIN.SEA_ICE) & 0xFF,
	])
	# ─── Phase A.3 fast path：从 KnobsHandle 拿 summary 段缓存 Dict ──
	if host._knobs_handle != null and host._knobs_handle.has_method("to_summary_knobs_dict"):
		# day_counter 每帧变化 → 走单字段细粒度入口（无变化时不拉 dirty）
		if host._knobs_handle.has_method("set_day_counter"):
			host._knobs_handle.set_day_counter(host._day_counter)
		var dynamic_fields_sum: Dictionary = {
			"n_cells": n_cells,
			"hex_size": host._hex_size,
			"cell_q_arr": host._summary_q_cache,
			"cell_r_arr": host._summary_r_cache,
			"neighbor_indices": map.neighbor_indices_packed() if map.has_indices() else PackedInt32Array(),
			"cyclone_wake_days": host._cyclone_wake_days,
			"cyclone_storm_type_id": int(WeatherType.WT.STORM),
			"water_terrain_ids": water_ids,
		}
		return host._merge_resident_knobs_with_dynamic(
			host._knobs_handle.to_summary_knobs_dict(), dynamic_fields_sum)
	return {
		"n_cells": n_cells,
		"hex_size": host._hex_size,
		"summary_limit": host._field_summary_limit,
		# 阈值（与 host._build_field_summary_fronts 内 const 严格同源）# 阈值（与 _build_field_summary_fronts 内 const 严格同源）
		"intensity_enter": 0.10,
		"intensity_hold": 0.06,
		# 合并相关
		"merge_ratio": 0.65,
		"merge_max_rounds": 4,
		# WeatherFront radius 公式： size*(1.6 + sqrt(area)*1.05)；
		# merge 距离阈值用的"等效半径"公式：size*sqrt(area)*1.05。
		"radius_base": 1.6,
		"radius_scale": 1.05,
		# WT 枚举常量（C++ 不直读 GDScript Resource，传过来用整型即可）
		"wt_clear": int(WeatherType.WT.CLEAR),
		"cyclone_wake_days": host._cyclone_wake_days,
		"cyclone_storm_type_id": int(WeatherType.WT.STORM),
		"water_terrain_ids": water_ids,
		# Q/R 拓扑（C++ 端用于 cube_to_world / world_to_cube 反查）
		"cell_q_arr": host._summary_q_cache,
		"cell_r_arr": host._summary_r_cache,
		# 邻居索引（n_cells*6，-1 表无邻居；C++ 端 BFS / pick_inheritance_seed 必需）
		"neighbor_indices": map.neighbor_indices_packed() if map.has_indices() else PackedInt32Array(),
		# Drift 调试日志（C++ 路径下默认关闭，verify mode 不影响日志）
		"drift_debug_log": false,
		"day_counter": host._day_counter,
	}

# 把 C++ 端返回的 fronts Dictionary 解包为 WeatherFront 实例。字段命名必须与
# C++ 端 build_front_dict 保持 1:1，任何缺字段就退化到 WeatherFront 默认值。

func _unpack_summary_dict_to_front(host, d: Dictionary) -> WeatherFront:
	var f = WeatherFront.new()
	f.type = int(d.get("type", WeatherType.WT.CLEAR))
	f.center = d.get("center", Vector2.ZERO)
	f.intensity = clampf(float(d.get("intensity", 0.0)), 0.0, 1.0)
	f.radius = float(d.get("radius", 200.0))
	var ax: Vector2 = d.get("axis", Vector2.RIGHT)
	if ax.length_squared() <= 0.0001:
		ax = Vector2.RIGHT
	f.axis = ax.normalized()
	f.stable_axis = d.get("stable_axis", f.axis)
	f.velocity = d.get("velocity", Vector2.ZERO)
	f.major_scale = float(d.get("major_scale", 1.30))
	f.minor_scale = float(d.get("minor_scale", 0.85))
	f.age_days = int(d.get("age_days", 0))
	f.ttl_days = int(d.get("ttl_days", 12))
	f.decay_per_day = float(d.get("decay_per_day", 0.0))
	f.life_progress = clampf(float(d.get("life_progress", 0.15)), 0.0, 1.0)
	f.cloud_amount = clampf(float(d.get("cloud_amount", 0.0)), 0.0, 1.0)
	f.precip_amount = clampf(float(d.get("precip_amount", 0.0)), 0.0, 1.0)
	f.dissolve_amount = float(d.get("dissolve_amount", 0.0))
	f.edge_seed = float(d.get("edge_seed", 0.0))
	f.front_temperature_advection = float(d.get("front_temperature_advection", 0.0))
	f.front_diagnostic_kind = int(d.get("front_diagnostic_kind", WeatherFront.FRONT_DIAG_NONE))
	return f

# ─── Phase A.1（dots-total-cpp roadmap）：fronts zero-copy SoA 解包 ─────
# 从 C++ 端 run_weather_summary_fronts_pass 返回的 out["fronts_soa"]: Dict
# 中读取 23 个 PackedArray 列（命名严格沿用 fronts_schema.gd FRONTS_SCHEMA
# cpp_name），按 idx 1:1 构造 WeatherFront 实例数组。
#
# 与 host._unpack_summary_dict_to_front 等价但 marshalling 大幅减负：# 与 _unpack_summary_dict_to_front 等价但 marshalling 大幅减负：
#   - 旧路径：每 front N=12 个 → 跨语言 ~17*12 = 204 个 Variant entry
#   - SoA 路径：固定 ~24 个 PackedArray 引用（与 N 无关）
#
# 容错策略：任意必需列缺失或 size 不匹配 → 返回 null 触发 caller fallback
# 到旧 dict 路径（保证向前兼容 stale .dll）。

func _unpack_summary_soa_to_fronts(host, soa: Dictionary) -> Variant:
	var n: int = int(soa.get("n_fronts", -1))
	if n < 0:
		return null
	if n == 0:
		return [] as Array[WeatherFront]
	var center_x: PackedFloat32Array = soa.get("front_center_x", PackedFloat32Array())
	var center_y: PackedFloat32Array = soa.get("front_center_y", PackedFloat32Array())
	var radius_arr: PackedFloat32Array = soa.get("front_radius", PackedFloat32Array())
	var velocity_x: PackedFloat32Array = soa.get("front_velocity_x", PackedFloat32Array())
	var velocity_y: PackedFloat32Array = soa.get("front_velocity_y", PackedFloat32Array())
	var axis_x: PackedFloat32Array = soa.get("front_axis_x", PackedFloat32Array())
	var axis_y: PackedFloat32Array = soa.get("front_axis_y", PackedFloat32Array())
	var stable_axis_x: PackedFloat32Array = soa.get("front_stable_axis_x", PackedFloat32Array())
	var stable_axis_y: PackedFloat32Array = soa.get("front_stable_axis_y", PackedFloat32Array())
	var major_scale_arr: PackedFloat32Array = soa.get("front_major_scale", PackedFloat32Array())
	var minor_scale_arr: PackedFloat32Array = soa.get("front_minor_scale", PackedFloat32Array())
	var edge_seed_arr: PackedFloat32Array = soa.get("front_edge_seed", PackedFloat32Array())
	var intensity_arr: PackedFloat32Array = soa.get("front_intensity", PackedFloat32Array())
	var decay_arr: PackedFloat32Array = soa.get("front_decay_per_day", PackedFloat32Array())
	var life_arr: PackedFloat32Array = soa.get("front_life_progress", PackedFloat32Array())
	var cloud_arr: PackedFloat32Array = soa.get("front_cloud_amount", PackedFloat32Array())
	var precip_arr: PackedFloat32Array = soa.get("front_precip_amount", PackedFloat32Array())
	var dissolve_arr: PackedFloat32Array = soa.get("front_dissolve_amount", PackedFloat32Array())
	var type_arr: PackedInt32Array = soa.get("front_type", PackedInt32Array())
	var ttl_arr: PackedInt32Array = soa.get("front_ttl_days", PackedInt32Array())
	var age_arr: PackedInt32Array = soa.get("front_age_days", PackedInt32Array())
	var temp_adv_arr: PackedFloat32Array = soa.get("front_temperature_advection", PackedFloat32Array())
	var diag_kind_arr: PackedInt32Array = soa.get("front_diagnostic_kind", PackedInt32Array())
	# 必需列长度全检查（任一不匹配立即放弃，让 caller 走 dict fallback）
	if center_x.size() != n or center_y.size() != n: return null
	if radius_arr.size() != n: return null
	if velocity_x.size() != n or velocity_y.size() != n: return null
	if axis_x.size() != n or axis_y.size() != n: return null
	if stable_axis_x.size() != n or stable_axis_y.size() != n: return null
	if major_scale_arr.size() != n or minor_scale_arr.size() != n: return null
	if edge_seed_arr.size() != n: return null
	if intensity_arr.size() != n: return null
	if decay_arr.size() != n: return null
	if life_arr.size() != n: return null
	if cloud_arr.size() != n or precip_arr.size() != n: return null
	if dissolve_arr.size() != n: return null
	if type_arr.size() != n or ttl_arr.size() != n or age_arr.size() != n: return null

	var out: Array[WeatherFront] = [] as Array[WeatherFront]
	out.resize(n)
	for i in range(n):
		var f = WeatherFront.new()
		f.type = type_arr[i]
		f.center = Vector2(center_x[i], center_y[i])
		f.intensity = clampf(intensity_arr[i], 0.0, 1.0)
		f.radius = radius_arr[i]
		# axis 归一化与 dict 路径等价（C++ 端已经 normalize 但 GDScript fallback 也照同样语义守护）
		var ax = Vector2(axis_x[i], axis_y[i])
		if ax.length_squared() <= 0.0001:
			ax = Vector2.RIGHT
		f.axis = ax.normalized()
		var sax = Vector2(stable_axis_x[i], stable_axis_y[i])
		if sax.length_squared() <= 0.0001:
			sax = f.axis
		f.stable_axis = sax
		f.velocity = Vector2(velocity_x[i], velocity_y[i])
		f.major_scale = major_scale_arr[i]
		f.minor_scale = minor_scale_arr[i]
		f.age_days = age_arr[i]
		f.ttl_days = ttl_arr[i]
		f.decay_per_day = decay_arr[i]
		f.life_progress = clampf(life_arr[i], 0.0, 1.0)
		f.cloud_amount = clampf(cloud_arr[i], 0.0, 1.0)
		f.precip_amount = clampf(precip_arr[i], 0.0, 1.0)
		f.dissolve_amount = dissolve_arr[i]
		f.edge_seed = edge_seed_arr[i]
		if temp_adv_arr.size() == n:
			f.front_temperature_advection = temp_adv_arr[i]
		if diag_kind_arr.size() == n:
			f.front_diagnostic_kind = diag_kind_arr[i]
		out[i] = f
	return out



func _build_fronts_from_rc(host, rc_dict: Dictionary) -> Array[WeatherFront]:
	# dots-flag-prune-pr1 round 2: use_gdext_fronts_soa flag 已删除——恒走 SoA 探测路径，
	# rc_dict.fronts_soa 存在时列扫描构造 WeatherFront，缺失时 fallback 到 Array[Dict]。
	if rc_dict.has("fronts_soa"):
		var soa: Dictionary = rc_dict["fronts_soa"]
		# Phase B Z-lock 实测遥测：editor-only 包夹 unpack 调用，100 样本 ring 满 print。
		var _telemetry_on: bool = OS.has_feature("editor")
		var _t0_us: int = Time.get_ticks_usec() if _telemetry_on else 0
		var soa_out: Variant = host._unpack_summary_soa_to_fronts(soa)
		if _telemetry_on:
			var _dt_us: int = Time.get_ticks_usec() - _t0_us
			if host._fronts_soa_unpack_us_ring.size() < host._FRONTS_SOA_TELEMETRY_WINDOW:
				host._fronts_soa_unpack_us_ring.resize(host._FRONTS_SOA_TELEMETRY_WINDOW)
			host._fronts_soa_unpack_us_ring[host._fronts_soa_unpack_window_idx] = _dt_us
			host._fronts_soa_unpack_window_idx = (host._fronts_soa_unpack_window_idx + 1) % host._FRONTS_SOA_TELEMETRY_WINDOW
			host._fronts_soa_unpack_window_count += 1
			if host._fronts_soa_unpack_window_count >= host._FRONTS_SOA_TELEMETRY_WINDOW:
				# 窗口满：计算 p50/p95/mean，print 后归零再采（持续观测，便于跨阶段对比）
				var _samples: PackedInt32Array = host._fronts_soa_unpack_us_ring.duplicate()
				_samples.sort()
				var _w: int = _samples.size()
				var _p50: int = _samples[_w / 2]
				var _p95: int = _samples[int(float(_w) * 0.95)]
				var _sum: int = 0
				for _v in _samples:
					_sum += int(_v)
				var _mean: float = float(_sum) / float(_w)
				print("[weather/summary] fronts_soa unpack telemetry — n=%d mean=%.1fμs p50=%dμs p95=%dμs (Z-lock threshold: p95<100μs)" % [_w, _mean, _p50, _p95])
				host._fronts_soa_unpack_window_count = 0
				host._fronts_soa_unpack_window_idx = 0
		if soa_out != null:
			if not host._fronts_soa_path_logged:
				host._fronts_soa_path_logged = true
				print("[weather/summary] fronts_soa path ACTIVE — first run n=%d (PackedArray columns, marshalling ~90%% slim vs Array[Dict])" % int(soa.get("n_fronts", 0)))
			return soa_out as Array[WeatherFront]
		else:
			if not host._fronts_soa_warned_fallback:
				host._fronts_soa_warned_fallback = true
				push_warning("[weather/summary] fronts_soa columns missing/invalid; falling back to Array[Dict] path (will retry next tick)")
	# Fallback: 走旧 Array[Dict] 路径
	var fronts_arr: Array = rc_dict.get("fronts", [])
	var out: Array[WeatherFront] = [] as Array[WeatherFront]
	for d in fronts_arr:
		out.append(host._unpack_summary_dict_to_front(d))
	return out

# ─── Phase A.3（dots-total-cpp roadmap）：KnobsHandle dirty-write helper ─
# 把 ClimateProfile + weather_system 自身 _field_* 持久旋钮一次性推送到
# KnobsHandle 的所有段。caller：host.configure_gdext_acceleration 首次装配 + 后续# KnobsHandle 的所有段。caller：configure_gdext_acceleration 首次装配 + 后续
# ClimateProfile.changed 信号触发（信号 cb 会再调一次本函数）。
#
# 注意：动态 PackedArray ref（_field_slice_* / host._summary_q_cache / map.* SoA /# 注意：动态 PackedArray ref（_field_slice_* / _summary_q_cache / map.* SoA /
# neighbor_indices）不在这里推送 —— 它们每帧由 caller 在 _build_*_knobs
# 外层 merge 进 to_*_knobs_dict() 输出（保留每帧 ref 替换语义）。

func _try_run_weather_summary_fronts_gdext(host, map: MapData, world: WorldData) -> Variant:
	if host._data_core_world_ext == null:
		return null
	var knobs: Dictionary = host._build_weather_summary_knobs(map, world)
	var rc_dict: Dictionary = host._data_core_world_ext.run_weather_summary_fronts_pass(knobs)
	var rc: float = float(rc_dict.get("elapsed_ms", -1.0))
	if rc < 0.0:
		host._gdext_summary_fallbacks += 1
		if not host._gdext_summary_warned_fallback:
			host._gdext_summary_warned_fallback = true
			push_warning("[weather/summary] gdext run_weather_summary_fronts_pass returned %.2f; falling back to GDScript for this tick (will retry next tick)" % rc)
		return null
	host._gdext_summary_runs += 1
	host._gdext_summary_total_ms += rc
	if host._gdext_summary_runs == 1:
		print("[weather/summary] gdext path ACTIVE — first run elapsed=%.2fms (legacy GDScript baseline ≈ 17.8ms; charter target < 3.0ms)" % rc)
	# Phase A.1: SoA 优先 + Dict fallback（旧 Array[Dict] 路径仍兼容 stale .dll）
	return host._build_fronts_from_rc(rc_dict)

# ─── plan/weather-refresh-cpp-all PR-2 facade ─────────────────────────────
# 单 cpp call 跑完 weather refresh daily 全套（field_solve + distribute +
# summary_fronts + cyclone_wake + stage_b 五段），消除 GDScript ↔ C++ 之间
# 5 次 marshal。返回值：
#   { ok: bool, fronts: Array[WeatherFront], breakdown: Dictionary, fail_stage: String }
# ok=false 时 caller 必须走 GDScript fallback（refresh_daily_stage_a +
# refresh_daily_stage_b）。fail_stage 用于诊断（"precondition" / "field_solve" /
# "distribute" / "summary" / "stage_b" / "rc"）。
#
# 前置条件：
#   - host._data_core_world_ext 已绑定且 has_method("run_weather_refresh_daily_pass")#   - _data_core_world_ext 已绑定且 has_method("run_weather_refresh_daily_pass")
#   - 由 map_generator.refresh_weather_daily() 间接保证
#
# 副作用（成功路径）：
#   - 推进 host._day_counter / host._field_solve_tick（等价于 host.tick_one_day 的 day-bump）#   - 推进 _day_counter / _field_solve_tick（等价于 tick_one_day 的 day-bump）
#   - 写入 SoA 8 字段（cpp 端 field_solve 直写）
#   - 写入 host._active_fronts = fronts_cpp（替代 commit() 末段）#   - 写入 _active_fronts = fronts_cpp（替代 commit() 末段）
#   - 同步 host.ocean_current_perturbation（cpp 端 cyclone_wake 维护）#   - 同步 ocean_current_perturbation（cpp 端 cyclone_wake 维护）
#   - 写入 host._last_breakdown（advance/distribute/summary/cyclone/stage_b 子段 ms）#   - 写入 _last_breakdown（advance/distribute/summary/cyclone/stage_b 子段 ms）
#   - distribute 写回的 acc_snow / pre_snow_cover 由 caller 在拿到 fronts 后
#     按需同步（与 host._try_run_weather_distribute_gdext 行为一致）；本函数不#     按需同步（与 _try_run_weather_distribute_gdext 行为一致）；本函数不
#     做 cell-level 反向写入，避免重复 hot loop。

func try_run_refresh_daily_combined_gdext(host, map: MapData, world: WorldData,
		season_idx: int, climate_anomaly: float, season_phase: float = -1.0,
		stage_b_knobs: Dictionary = {}) -> Dictionary:
	var ret: Dictionary = {
		"ok": false,
		"fronts": [] as Array[WeatherFront],
		"breakdown": {},
		"fail_stage": "precondition",
	}
	if host._data_core_world_ext == null:
		return ret
	if map == null or world == null:
		return ret
	var n_cells: int = map.cell_count()
	if n_cells <= 0:
		return ret

	var t_us0: int = Time.get_ticks_usec()

	# Step 1：初始化 field slice state（替代 host.tick_one_day 入口的 day-bump +# Step 1：初始化 field slice state（替代 tick_one_day 入口的 day-bump +
	# wind_fn 设置；count_day=true，与 host.tick_one_day 语义一致）。# wind_fn 设置；count_day=true，与 tick_one_day 语义一致）。
	host._current_map_for_tick = map
	host.begin_weather_field_solve(map, world, season_idx, climate_anomaly, season_phase, true)
	# fast-indexed 是 cpp 5 段的硬前置条件（field_solve / distribute /
	# summary / feedback 都要 neighbor_indices_packed 完整）。任意一段缺失
	# 立即放弃，让 caller 走 GDScript fallback 而不是付出半 cpp 半 GDScript 代价。
	if not host._field_solver._field_slice_fast_indexed:
		host._clear_weather_field_slice_state()
		ret["fail_stage"] = "fast_indexed_missing"
		return ret

	# Step 2：合并 4 组 knobs。各 builder 已存在且严格按 cpp 端 5 段所需 key
	# 集合产出。super-knobs 用 merge() 合到一个 Dictionary 单次跨界传递。
	# stage_b 的 knobs 由 generator 提供（builder 在 generator 那边，
	# weather_system 拿不到 cp/lut；caller 必须传入）。
	var super_knobs: Dictionary = host._build_weather_field_knobs(map, world, n_cells)
	var dist_knobs: Dictionary = host._build_weather_distribute_knobs(map, n_cells)
	for k in dist_knobs.keys():
		super_knobs[k] = dist_knobs[k]
	var summary_knobs: Dictionary = host._build_weather_summary_knobs(map, world)
	for k in summary_knobs.keys():
		super_knobs[k] = summary_knobs[k]
	# stage_b 的 5 段 knobs 由 caller（map_generator.refresh_weather_daily facade）
	# 通过 stage_b_knobs 参数注入——builder 在 generator 那边（依赖 cp/lut），
	# weather_system 拿不到。如果 caller 传空 dict（例如还在试运行阶段），那么
	# cpp 端会跳过 stage_b 段（stage_b_pass 内部检查 run_albedo/veg_dyn/feedback
	# 三个 flag 全 false 时直接 return rc=0），这是允许的过渡状态。
	# 注意：把 stage_b_knobs 的所有 key 平铺到 super_knobs 顶层，与 cpp 端
	# run_weather_refresh_daily_pass 解 stage_b 段时按 top-level key 取值的约定一致。
	if not stage_b_knobs.is_empty():
		for k in stage_b_knobs.keys():
			# 不允许 stage_b key 覆盖 weather field/distribute/summary 已写好的同名
			# key（例如 n_cells / neighbor_indices）——后者是真值，stage_b 端的
			# n_cells / neighbor_indices 与 weather 段必然一致，但为安全起见
			# 用 has() 做防御。
			if not super_knobs.has(k):
				super_knobs[k] = stage_b_knobs[k]

	# Step 3：单次 cpp call。
	var rc_dict: Dictionary = host._data_core_world_ext.run_weather_refresh_daily_pass(super_knobs)
	var rc_int: int = int(rc_dict.get("rc", -1))
	if rc_int != 0:
		# cpp 端任一段失败 → 清理 slice state，让 caller 走 GDScript fallback。
		host._clear_weather_field_slice_state()
		ret["fail_stage"] = String(rc_dict.get("fail_stage", "rc"))
		ret["breakdown"] = {
			"total_ms": float(rc_dict.get("total_ms", 0.0)),
		}
		if not host._gdext_combined_warned_fallback:
			host._gdext_combined_warned_fallback = true
			push_warning("[weather/combined] run_weather_refresh_daily_pass rc=%d fail_stage=%s; falling back to GDScript chain" % [rc_int, ret["fail_stage"]])
		return ret

	# Step 4：解包 fronts，写 host._active_fronts（替代 commit() summary 段 +# Step 4：解包 fronts，写 _active_fronts（替代 commit() summary 段 +
	# host.tick_one_day 末端 host._active_fronts 写入）。# tick_one_day 末端 _active_fronts 写入）。
	# Phase A.1: SoA 优先 + Dict fallback（与 host._try_run_weather_summary_fronts_gdext# Phase A.1: SoA 优先 + Dict fallback（与 _try_run_weather_summary_fronts_gdext
	# 共享 host._build_fronts_from_rc helper，single source of truth）。# 共享 _build_fronts_from_rc helper，single source of truth）。
	var fronts_out: Array[WeatherFront] = host._build_fronts_from_rc(rc_dict)
	host._active_fronts = fronts_out

	# Step 5：cover_dirty 同步（distribute 段输出）。
	host._cover_dirty = bool(rc_dict.get("cover_dirty", false)) or host._cover_dirty

	# Step 6：cyclone_wake 镜像（cpp 端维护 _cyclone_perturbations 内部
	# vector，GDScript 端 host.ocean_current_perturbation 用于航运 AI 直读）。# vector，GDScript 端 ocean_current_perturbation 用于航运 AI 直读）。
	var cyclone_mirror: Dictionary = host._data_core_world_ext.get_cyclone_perturbations_dict()
	# 替换式同步而非 merge：cpp 是 source of truth（已经做了衰减 + 注入）。
	host.ocean_current_perturbation = cyclone_mirror

	# Step 7：清理 slice state（cpp 已直写 SoA，_field_slice_* buffer 不再需要）。
	host._clear_weather_field_slice_state()
	host._current_map_for_tick = null

	# Step 8：拼装 host._last_breakdown（与 GDScript path 字段集合保持一致）。# Step 8：拼装 _last_breakdown（与 GDScript path 字段集合保持一致）。
	var combined_total_ms: float = (Time.get_ticks_usec() - t_us0) / 1000.0
	var br: Dictionary = {
		"advance_ms": float(rc_dict.get("advance_ms", 0.0)),
		"distribute_ms": float(rc_dict.get("distribute_ms", 0.0)),
		"summary_ms": float(rc_dict.get("summary_ms", 0.0)),
		"cyclone_ms": float(rc_dict.get("cyclone_ms", 0.0)),
		# Phase B.2 cyclone 细粒度遥测（C++ cyclone_wake_step by-ref 写回 6 字段
		# + caller 写回 cyclone_pool_size，map_generator._dump_weather_breakdown_if_slow
		# 触发时立即定位是衰减循环 vs 注入循环、是大量 evict vs 大量 replace）
		"cyclone_phase1_decay_ms": float(rc_dict.get("cyclone_phase1_decay_ms", 0.0)),
		"cyclone_phase2_inject_ms": float(rc_dict.get("cyclone_phase2_inject_ms", 0.0)),
		"cyclone_n_decayed": int(rc_dict.get("cyclone_n_decayed", 0)),
		"cyclone_n_evicted": int(rc_dict.get("cyclone_n_evicted", 0)),
		"cyclone_n_replaced": int(rc_dict.get("cyclone_n_replaced", 0)),
		"cyclone_n_injected": int(rc_dict.get("cyclone_n_injected", 0)),
		"cyclone_pool_size": int(rc_dict.get("cyclone_pool_size", 0)),
		"stage_b_ms": float(rc_dict.get("stage_b_ms", 0.0)),
		"albedo_ms": float(rc_dict.get("albedo_ms", 0.0)),
		"veg_dyn_ms": float(rc_dict.get("veg_dyn_ms", 0.0)),
		"feedback_ms": float(rc_dict.get("feedback_ms", 0.0)),
		"weather_tick_ms": float(rc_dict.get("weather_tick_ms", combined_total_ms)),
		"total_ms": combined_total_ms,
		"fronts": fronts_out.size(),
		"path": "gdext_combined",
	}
	br.merge(host._front_diagnostic_counts(fronts_out), true)
	# stage_b succession 写回（与 _build_native_daily_stage_b_knobs 等价）
	if rc_dict.has("succession_indices"):
		br["succession_indices"] = rc_dict["succession_indices"]
		br["succession_to_veg"] = rc_dict["succession_to_veg"]
		br["stat_succession_count"] = int(rc_dict.get("stat_succession_count", 0))
	br.merge(host._mark_weather_commit_tick(), true)
	host._last_breakdown = br

	# 节流告警（仅首次）：标记 gdext_combined ACTIVE。
	host._gdext_combined_runs += 1
	host._gdext_combined_total_ms += combined_total_ms
	if host._gdext_combined_runs == 1:
		print("[weather/combined] gdext path ACTIVE — first run elapsed=%.2fms (target ≤ 1.5ms; legacy stage_a+stage_b chain ≈ 1.0-1.2ms baseline + 3 marshal overhead)" % combined_total_ms)

	ret["ok"] = true
	ret["fronts"] = fronts_out
	ret["breakdown"] = br
	ret["fail_stage"] = ""
	return ret


# ─── Phase A.2 unified fast tick：weather_knobs 嵌入 native_daily_bundle ─────
# 当 native_daily_sim_mode=ACTIVE 时（unified_fast_tick 路径现恒走），由
# map_generator._build_native_daily_bundle 调用本 helper 构造平铺 weather super_knobs，
# 由 run_native_daily_tick 内部的 bundle["weather_knobs"] 分支自动转调
# run_weather_refresh_daily_pass，省去 weather_refresh_job 独立的一次跨界。
#
# 与 host.try_run_refresh_daily_combined_gdext step 1-2 同源逻辑（field_slice state# 与 try_run_refresh_daily_combined_gdext step 1-2 同源逻辑（field_slice state
# 初始化 + 3 组 weather knobs builder + 顶层平铺 stage_b knobs）。失败时返回
# 空 dict，caller 据此跳过 weather_knobs 嵌入退回 stage_b-only bundle。
#
# 副作用（成功路径）：
#   - 推进 host._day_counter（与 host.tick_one_day 语义一致，count_day=true）#   - 推进 _day_counter（与 tick_one_day 语义一致，count_day=true）
#   - 初始化 host._field_solver._field_slice_* state（_field_slice_fast_indexed 必须为 true）#   - 初始化 _field_solver._field_slice_* state（_field_slice_fast_indexed 必须为 true）
#   - 设置 host._current_map_for_tick = map#   - 设置 _current_map_for_tick = map
# 这些状态会在 host.apply_unified_fast_tick_result 内被 host._clear_weather_field_slice_state 清理。# 这些状态会在 apply_unified_fast_tick_result 内被 _clear_weather_field_slice_state 清理。

func build_unified_fast_tick_weather_knobs(host, map: MapData, world: WorldData,
		season_idx: int, climate_anomaly: float, season_phase: float,
		stage_b_knobs: Dictionary) -> Dictionary:
	if host._data_core_world_ext == null:
		return {}
	if map == null or world == null:
		return {}
	var n_cells: int = map.cell_count()
	if n_cells <= 0:
		return {}

	# Step 1：初始化 field slice state（与 host.try_run_refresh_daily_combined_gdext line 1361 同源）。# Step 1：初始化 field slice state（与 try_run_refresh_daily_combined_gdext line 1361 同源）。
	host._current_map_for_tick = map
	host.begin_weather_field_solve(map, world, season_idx, climate_anomaly, season_phase, true)
	if not host._field_solver._field_slice_fast_indexed:
		# fast-indexed 是 cpp 5 段的硬前置；缺失 → 清理 + 让 caller fallback 不嵌入 weather_knobs。
		host._clear_weather_field_slice_state()
		host._current_map_for_tick = null
		return {}

	# Step 2：合并 4 组 knobs（与 line 1374-1395 同源）。
	var super_knobs: Dictionary = host._build_weather_field_knobs(map, world, n_cells)
	var dist_knobs: Dictionary = host._build_weather_distribute_knobs(map, n_cells)
	for k in dist_knobs.keys():
		super_knobs[k] = dist_knobs[k]
	var summary_knobs: Dictionary = host._build_weather_summary_knobs(map, world)
	for k in summary_knobs.keys():
		super_knobs[k] = summary_knobs[k]
	if not stage_b_knobs.is_empty():
		for k in stage_b_knobs.keys():
			if not super_knobs.has(k):
				super_knobs[k] = stage_b_knobs[k]
	# weather_lut_w/h：合并 native-daily 路径里 C++ 的 field commit pass
	# (run_weather_field_commit_pass) 用这两项把 weather LUT 字节按 lut_w*lut_h 编码。
	# 缺失时 C++ 退回 n_cells 个 slot，产出的字节数与发布纹理 (world.lut_dims) 不符，
	# 导致 publish_weather_lut_bytes_from_native 因 size 不匹配整段拒收 → 云/雨雪 LUT
	# 永远停在世界生成时的全晴初始 bake（全 0），天气视觉全部消失。
	# 与切片路径 host._try_run_weather_field_commit_gdext 同源补齐。# 与切片路径 _try_run_weather_field_commit_gdext 同源补齐。
	if world != null and world.lut_dims.x > 0 and world.lut_dims.y > 0:
		super_knobs["weather_lut_w"] = int(world.lut_dims.x)
		super_knobs["weather_lut_h"] = int(world.lut_dims.y)
	return super_knobs


# 与 host.try_run_refresh_daily_combined_gdext step 4-8 同源：从 native_daily 返回的# 与 try_run_refresh_daily_combined_gdext step 4-8 同源：从 native_daily 返回的
# breakdown 字典里取 weather 段子字典（C++ 端 run_native_daily_tick 把 weather
# 段产出 copy_dict_into 进顶层 breakdown），解 fronts、同步 host._active_fronts、# 段产出 copy_dict_into 进顶层 breakdown），解 fronts、同步 _active_fronts、
# cyclone mirror、cover_dirty，清理 slice state。
#
# 入参 weather_rc：bundle.weather_knobs 触发的 run_weather_refresh_daily_pass
# 返回 dict，由 native_daily breakdown 透传上来。
#
# 返回 fronts_out：与 host.try_run_refresh_daily_combined_gdext 一致的 Array[WeatherFront]，# 返回 fronts_out：与 try_run_refresh_daily_combined_gdext 一致的 Array[WeatherFront]，
# 由 caller（map_generator）写入 _last_active_fronts / _weather_round_fronts。

func apply_unified_fast_tick_result(host, weather_rc: Dictionary) -> Array[WeatherFront]:
	if host._data_core_world_ext == null:
		host._clear_weather_field_slice_state()
		host._current_map_for_tick = null
		return [] as Array[WeatherFront]
	var t_us0: int = Time.get_ticks_usec()

	# Step 4：解包 fronts，写 host._active_fronts。# Step 4：解包 fronts，写 _active_fronts。
	var fronts_out: Array[WeatherFront] = host._build_fronts_from_rc(weather_rc)
	host._active_fronts = fronts_out

	# Step 5：cover_dirty 同步。
	host._cover_dirty = bool(weather_rc.get("cover_dirty", false)) or host._cover_dirty

	# Step 6：cyclone_wake 镜像。
	var cyclone_mirror: Dictionary = host._data_core_world_ext.get_cyclone_perturbations_dict()
	host.ocean_current_perturbation = cyclone_mirror

	# Step 7：清理 slice state。
	host._clear_weather_field_slice_state()
	host._current_map_for_tick = null

	# Step 8：runs/total_ms 统计（与 combined path 共享计数器）。
	host._gdext_combined_runs += 1
	host._gdext_combined_total_ms += float(weather_rc.get("total_ms", 0.0))
	# Native daily breakdown may contain large PackedArrays and nested reports; keep the
	# weather-facing snapshot scalar-only except for the explicit fields consumers need.
	var br: Dictionary = {
		"advance_ms": float(weather_rc.get("advance_ms", weather_rc.get("weather_field_ms", 0.0))),
		"field_commit_total_ms": float(weather_rc.get("field_commit_total_ms", weather_rc.get("weather_commit_ms", 0.0))),
		"field_commit_loop_ms": float(weather_rc.get("field_commit_loop_ms", 0.0)),
		"distribute_ms": float(weather_rc.get("distribute_ms", weather_rc.get("weather_distribute_ms", 0.0))),
		"summary_ms": float(weather_rc.get("summary_ms", weather_rc.get("weather_summary_ms", 0.0))),
		"cyclone_ms": float(weather_rc.get("cyclone_ms", weather_rc.get("weather_cyclone_ms", 0.0))),
		"stage_b_ms": float(weather_rc.get("stage_b_ms", weather_rc.get("weather_stage_b_ms", 0.0))),
		"weather_field_ms": float(weather_rc.get("weather_field_ms", weather_rc.get("advance_ms", 0.0))),
		"weather_commit_ms": float(weather_rc.get("weather_commit_ms", weather_rc.get("field_commit_total_ms", 0.0))),
		"weather_distribute_ms": float(weather_rc.get("weather_distribute_ms", weather_rc.get("distribute_ms", 0.0))),
		"weather_summary_ms": float(weather_rc.get("weather_summary_ms", weather_rc.get("summary_ms", 0.0))),
		"weather_cyclone_ms": float(weather_rc.get("weather_cyclone_ms", weather_rc.get("cyclone_ms", 0.0))),
		"weather_stage_b_ms": float(weather_rc.get("weather_stage_b_ms", 0.0)),
		"albedo_ms": float(weather_rc.get("albedo_ms", 0.0)),
		"veg_dyn_ms": float(weather_rc.get("veg_dyn_ms", 0.0)),
		"feedback_ms": float(weather_rc.get("feedback_ms", 0.0)),
		"weather_tick_ms": float(weather_rc.get("weather_tick_ms", weather_rc.get("weather_ms", weather_rc.get("total_ms", 0.0)))),
		"total_ms": float(weather_rc.get("total_ms", weather_rc.get("weather_ms", 0.0))),
		"fronts": fronts_out.size(),
		"fronts_count": int(weather_rc.get("fronts_count", fronts_out.size())),
		"cover_dirty": bool(weather_rc.get("cover_dirty", false)),
		"active_weather_ratio": float(weather_rc.get("active_weather_ratio", 0.0)),
		"weather_dirty_count": int(weather_rc.get("weather_dirty_count", 0)),
		"weather_lut_changed": bool(weather_rc.get("weather_lut_changed", false)),
		"weather_lut_dirty_count": int(weather_rc.get("weather_lut_dirty_count", 0)),
		"weather_lut_full_rebuild": bool(weather_rc.get("weather_lut_full_rebuild", false)),
		"weather_convergence_dirty_count": int(weather_rc.get("weather_convergence_dirty_count", 0)),
		"path": "gdext_native_daily_apply",
	}
	if weather_rc.has("fronts_signature"):
		br["fronts_signature"] = str(weather_rc.get("fronts_signature", ""))
	if weather_rc.has("visual_dirty_intents"):
		br["visual_dirty_intents"] = weather_rc["visual_dirty_intents"]
	if weather_rc.has("succession_indices"):
		br["succession_indices"] = weather_rc["succession_indices"]
		br["succession_to_veg"] = weather_rc.get("succession_to_veg", PackedByteArray())
		br["stat_succession_count"] = int(weather_rc.get("stat_succession_count", 0))
	br.merge(host._front_diagnostic_counts(fronts_out), true)
	br.merge(host._mark_weather_commit_tick(), true)
	br["result_apply_ms"] = float(Time.get_ticks_usec() - t_us0) / 1000.0
	host._last_breakdown = br
	return fronts_out


# C++ 完成后 SoA 已经写好，把 8 个数组的内容按 i 拷回 host._field_solver._field_slice_next_*# C++ 完成后 SoA 已经写好，把 8 个数组的内容按 i 拷回 _field_solver._field_slice_next_*
# 让 host.commit_weather_field_solve() 用同样的 GDScript 数据流 commit 回 cells +# 让 commit_weather_field_solve() 用同样的 GDScript 数据流 commit 回 cells +
# fronts 等下游 sub-system，无需感知 C++ 路径的存在。

func _pull_gdext_field_results_to_next(host, map: MapData, n_cells: int) -> void:
	var soa_vapor: PackedFloat32Array = map.weather_vapor_arr
	var soa_cloud: PackedFloat32Array = map.weather_cloud_arr
	var soa_cloud_water: PackedFloat32Array = map.weather_cloud_water_arr
	var soa_precip: PackedFloat32Array = map.weather_precip_arr
	var soa_inst: PackedFloat32Array = map.weather_instability_arr
	var soa_intens: PackedFloat32Array = map.weather_intensity_arr
	var soa_conv: PackedFloat32Array = map.weather_convergence_arr
	var soa_type: PackedByteArray = map.weather_type_arr
	for i in range(n_cells):
		host._field_solver._field_slice_next_vapor[i] = soa_vapor[i]
		host._field_solver._field_slice_next_cloud[i] = soa_cloud[i]
		if soa_cloud_water.size() == n_cells:
			host._field_solver._field_slice_next_cloud_water[i] = soa_cloud_water[i]
		host._field_solver._field_slice_next_precip[i] = soa_precip[i]
		host._field_solver._field_slice_next_instability[i] = soa_inst[i]
		host._field_solver._field_slice_next_intensity[i] = soa_intens[i]
		host._field_solver._field_slice_next_convergence[i] = soa_conv[i]
		host._field_solver._field_slice_next_type[i] = int(soa_type[i])

# ─── F.1 A/B 运行时验证 ───────────────────────────────────────────────────
# 触发：host.set_field_verify_mode(true) 之后每次 C++ 路径成功 commit 前进入。# 触发：set_field_verify_mode(true) 之后每次 C++ 路径成功 commit 前进入。
# 步骤：
#   1. 把 C++ 已写好的 8 个 SoA 字段快照成独立 PackedArray（CoW 复制；不影响
#      host._field_solver._field_slice_next_* 已经持有的同一 SoA 引用）。#      _field_solver._field_slice_next_* 已经持有的同一 SoA 引用）。
#   2. 把 SoA 反向回滚到本 tick 入口的 prev 状态（vapor/precip 用 prev_*；
#      其余字段在 commit 之前不被本 pass 内部读，所以无需精确还原）。
#   3. 把 GDScript 的 host._field_solver._field_slice_next_* 拷成另一组独立缓冲，再用 GDScript#   3. 把 GDScript 的 _field_solver._field_slice_next_* 拷成另一组独立缓冲，再用 GDScript
#      slice loop 重新写一遍——但这会污染 host._field_solver._field_slice_next_*，所以我们先用#      slice loop 重新写一遍——但这会污染 _field_solver._field_slice_next_*，所以我们先用
#      临时 var 备份再恢复。
#   4. 对照 8 个字段逐 cell 比 abs(cpp - gdscript)，首次超过 tol 时打日志并
#      记录 "_field_verify_first_divergence_logged = true"，避免 spam。
#
# 实现策略：直接调用 _solve_weather_field_internal_loop_for_verify(...) 把
# slice 主循环做成独立函数，避免在 verify 路径里复制 600 行算法。

func _verify_gdext_field_against_gdscript(host, map: MapData, world: WorldData, n_cells: int) -> void:
	# C++ 结果快照（dup() 保证 CoW，不和 SoA 引用别名）
	var cpp_vapor: PackedFloat32Array = host._field_solver._field_slice_next_vapor.duplicate()
	var cpp_cloud: PackedFloat32Array = host._field_solver._field_slice_next_cloud.duplicate()
	var cpp_cloud_water: PackedFloat32Array = host._field_solver._field_slice_next_cloud_water.duplicate()
	var cpp_precip: PackedFloat32Array = host._field_solver._field_slice_next_precip.duplicate()
	var cpp_inst: PackedFloat32Array = host._field_solver._field_slice_next_instability.duplicate()
	var cpp_intens: PackedFloat32Array = host._field_solver._field_slice_next_intensity.duplicate()
	var cpp_conv: PackedFloat32Array = host._field_solver._field_slice_next_convergence.duplicate()
	var cpp_type: PackedInt32Array = host._field_solver._field_slice_next_type.duplicate()

	# 用 GDScript path 重写 host._field_solver._field_slice_next_*。复用现有 slice 循环主体最干净# 用 GDScript path 重写 _field_solver._field_slice_next_*。复用现有 slice 循环主体最干净
	# 的办法是：临时关掉 host._use_gdext_weather_field、把 cursor reset 到 0、再调# 的办法是：临时关掉 _use_gdext_weather_field、把 cursor reset 到 0、再调
	# 一次 host.run_weather_field_solve_slice 走 GDScript 分支。# 一次 run_weather_field_solve_slice 走 GDScript 分支。
	var saved_cursor: int = host._field_solver._field_slice_cursor
	var saved_solve_ms: float = host._field_solver._field_slice_solve_ms
	var saved_last_ms: float = host._field_solver._field_slice_last_ms
	var saved_use_gdext: bool = host._use_gdext_weather_field
	host._use_gdext_weather_field = false
	host._field_solver._field_slice_cursor = 0
	host._field_solver.run_slice(2147483647)
	host._field_solver._field_slice_cursor = saved_cursor
	host._field_solver._field_slice_solve_ms = saved_solve_ms
	host._field_solver._field_slice_last_ms = saved_last_ms
	host._use_gdext_weather_field = saved_use_gdext

	# 此时 host._field_solver._field_slice_next_* = GDScript 版结果。逐 cell 比较。# 此时 _field_solver._field_slice_next_* = GDScript 版结果。逐 cell 比较。
	var max_dvap: float = 0.0
	var max_dcld: float = 0.0
	var max_dcw: float = 0.0
	var max_dpre: float = 0.0
	var max_dins: float = 0.0
	var max_dint: float = 0.0
	var max_dcnv: float = 0.0
	var type_mismatches: int = 0
	var first_div_idx: int = -1
	var first_div_field: String = ""
	var first_div_cpp: float = 0.0
	var first_div_gd: float = 0.0
	for i in range(n_cells):
		var dvap: float = absf(cpp_vapor[i] - host._field_solver._field_slice_next_vapor[i])
		var dcld: float = absf(cpp_cloud[i] - host._field_solver._field_slice_next_cloud[i])
		var dcw: float = absf(cpp_cloud_water[i] - host._field_solver._field_slice_next_cloud_water[i])
		var dpre: float = absf(cpp_precip[i] - host._field_solver._field_slice_next_precip[i])
		var dins: float = absf(cpp_inst[i] - host._field_solver._field_slice_next_instability[i])
		var dint: float = absf(cpp_intens[i] - host._field_solver._field_slice_next_intensity[i])
		var dcnv: float = absf(cpp_conv[i] - host._field_solver._field_slice_next_convergence[i])
		max_dvap = maxf(max_dvap, dvap)
		max_dcld = maxf(max_dcld, dcld)
		max_dcw = maxf(max_dcw, dcw)
		max_dpre = maxf(max_dpre, dpre)
		max_dins = maxf(max_dins, dins)
		max_dint = maxf(max_dint, dint)
		max_dcnv = maxf(max_dcnv, dcnv)
		if cpp_type[i] != host._field_solver._field_slice_next_type[i]:
			type_mismatches += 1
		if first_div_idx < 0:
			if dvap > host._field_verify_tol_f32:
				first_div_idx = i; first_div_field = "vapor"; first_div_cpp = cpp_vapor[i]; first_div_gd = host._field_solver._field_slice_next_vapor[i]
			elif dcld > host._field_verify_tol_f32:
				first_div_idx = i; first_div_field = "cloud"; first_div_cpp = cpp_cloud[i]; first_div_gd = host._field_solver._field_slice_next_cloud[i]
			elif dcw > host._field_verify_tol_f32:
				first_div_idx = i; first_div_field = "cloud_water"; first_div_cpp = cpp_cloud_water[i]; first_div_gd = host._field_solver._field_slice_next_cloud_water[i]
			elif dpre > host._field_verify_tol_f32:
				first_div_idx = i; first_div_field = "precip"; first_div_cpp = cpp_precip[i]; first_div_gd = host._field_solver._field_slice_next_precip[i]
			elif dins > host._field_verify_tol_f32:
				first_div_idx = i; first_div_field = "instability"; first_div_cpp = cpp_inst[i]; first_div_gd = host._field_solver._field_slice_next_instability[i]
			elif dint > host._field_verify_tol_f32:
				first_div_idx = i; first_div_field = "intensity"; first_div_cpp = cpp_intens[i]; first_div_gd = host._field_solver._field_slice_next_intensity[i]
			elif dcnv > host._field_verify_tol_f32:
				first_div_idx = i; first_div_field = "convergence"; first_div_cpp = cpp_conv[i]; first_div_gd = host._field_solver._field_slice_next_convergence[i]

	# 把 host._field_solver._field_slice_next_* 还原成 C++ 结果（commit 才能拿到 C++ 路径数据）。# 把 _field_solver._field_slice_next_* 还原成 C++ 结果（commit 才能拿到 C++ 路径数据）。
	host._field_solver._field_slice_next_vapor = cpp_vapor
	host._field_solver._field_slice_next_cloud = cpp_cloud
	host._field_solver._field_slice_next_cloud_water = cpp_cloud_water
	host._field_solver._field_slice_next_precip = cpp_precip
	host._field_solver._field_slice_next_instability = cpp_inst
	host._field_solver._field_slice_next_intensity = cpp_intens
	host._field_solver._field_slice_next_convergence = cpp_conv
	host._field_solver._field_slice_next_type = cpp_type

	if first_div_idx >= 0 and not host._field_verify_first_divergence_logged:
		host._field_verify_first_divergence_logged = true
		push_warning("[weather/F.1 verify] FAIL — first divergence cell=%d field=%s cpp=%.6f gdscript=%.6f delta=%.2e (tol=%.1e). max abs deltas: vapor=%.2e cloud=%.2e cloud_water=%.2e precip=%.2e inst=%.2e intens=%.2e conv=%.2e type_mismatch=%d/%d" % [
			first_div_idx, first_div_field, first_div_cpp, first_div_gd, absf(first_div_cpp - first_div_gd), host._field_verify_tol_f32,
			max_dvap, max_dcld, max_dcw, max_dpre, max_dins, max_dint, max_dcnv, type_mismatches, n_cells,
		])
	elif first_div_idx < 0:
		# 全 cell 通过——只在第一次通过时打一条 INFO，避免每 tick spam。
		if not host._field_verify_first_divergence_logged:
			host._field_verify_first_divergence_logged = true
			print("[weather/F.1 verify] PASS — all %d cells within tol (max abs deltas: vapor=%.2e cloud=%.2e cloud_water=%.2e precip=%.2e inst=%.2e intens=%.2e conv=%.2e type_mismatch=%d)" % [
				n_cells, max_dvap, max_dcld, max_dcw, max_dpre, max_dins, max_dint, max_dcnv, type_mismatches,
			])


func _verify_gdext_distribute_against_gdscript(host, map: MapData, n_cells: int, cpp_rc: Dictionary) -> void:
	if not host._distribute_verify_enabled:
		return
	var cells: Array = map.iter_cells() if map.has_indices() else map.all_cells()
	# Step 1：把 C++ 已经 commit 的 5 个字段复制为 shadow（CoW dup 保证脱离 SoA 引用）。
	var shadow_temp: PackedFloat32Array = map.temp_arr.duplicate()
	var shadow_moist: PackedFloat32Array = map.moisture_arr.duplicate()
	var shadow_cover: PackedByteArray = map.cover_arr.duplicate()
	var shadow_acc: PackedInt32Array = PackedInt32Array()
	var shadow_pre: PackedInt32Array = PackedInt32Array()
	shadow_acc.resize(n_cells)
	shadow_pre.resize(n_cells)
	for i in range(n_cells):
		var c: HexCell = cells[i]
		shadow_acc[i] = c.accumulated_snow_days
		shadow_pre[i] = c.pre_snow_cover

	# Step 2：复位到本 tick 入口状态（cpp_rc 携带的 snapshot；调用方提供）。
	# snapshot 字段名约定：snap_temp / snap_moist / snap_cover / snap_acc / snap_pre。
	# 调用方在 fast-path 调度阶段已 dup 一份原始 SoA 传入。
	var snap_temp: PackedFloat32Array = cpp_rc.get("snap_temp", PackedFloat32Array())
	var snap_moist: PackedFloat32Array = cpp_rc.get("snap_moist", PackedFloat32Array())
	var snap_cover: PackedByteArray = cpp_rc.get("snap_cover", PackedByteArray())
	var snap_acc: PackedInt32Array = cpp_rc.get("snap_acc", PackedInt32Array())
	var snap_pre: PackedInt32Array = cpp_rc.get("snap_pre", PackedInt32Array())
	if snap_temp.size() != n_cells or snap_moist.size() != n_cells or \
			snap_cover.size() != n_cells or snap_acc.size() != n_cells or \
			snap_pre.size() != n_cells:
		push_warning("[weather/dist verify] snapshot 不全或大小不匹配，跳过本 tick verify")
		return
	# 把 SoA 还原。facade=true 时 cell.cover/temperature/moisture 通过 setter 透写
	# SoA；这里直接覆写 SoA arr 即可。
	map.temp_arr = snap_temp.duplicate()
	map.moisture_arr = snap_moist.duplicate()
	map.cover_arr = snap_cover.duplicate()
	for i in range(n_cells):
		var c2: HexCell = cells[i]
		c2.accumulated_snow_days = snap_acc[i]
		c2.pre_snow_cover = snap_pre[i]
		# current_state["cover"] 可能在 C++ commit 阶段被改过；同步回 snapshot。
		c2.current_state["cover"] = int(snap_cover[i])

	# Step 3：跑 GDScript 版 dist。它会读 cell.* 写 cell.* 同源覆盖。
	host._distribute_weather_field_to_cells(map)

	# Step 4：逐 cell 比对（temp/moist 用 tol_f32；cover/acc/pre 严格相等）。
	var max_dt: float = 0.0
	var max_dm: float = 0.0
	var first_div_idx: int = -1
	var first_div_field: String = ""
	for i in range(n_cells):
		var dt: float = absf(shadow_temp[i] - map.temp_arr[i])
		var dm: float = absf(shadow_moist[i] - map.moisture_arr[i])
		if dt > max_dt:
			max_dt = dt
		if dm > max_dm:
			max_dm = dm
		if first_div_idx < 0 and (dt > host._distribute_verify_tol_f32 or dm > host._distribute_verify_tol_f32):
			first_div_idx = i
			first_div_field = "temperature" if dt > dm else "moisture"
		if shadow_cover[i] != map.cover_arr[i] and first_div_idx < 0:
			first_div_idx = i
			first_div_field = "cover"
		var c3: HexCell = cells[i]
		if shadow_acc[i] != c3.accumulated_snow_days and first_div_idx < 0:
			first_div_idx = i
			first_div_field = "accumulated_snow_days"
		if shadow_pre[i] != c3.pre_snow_cover and first_div_idx < 0:
			first_div_idx = i
			first_div_field = "pre_snow_cover"

	if first_div_idx >= 0 and not host._distribute_verify_first_divergence_logged:
		host._distribute_verify_first_divergence_logged = true
		var c4: HexCell = cells[first_div_idx]
		push_warning("[weather/dist verify] divergence at idx=%d field=%s cpp_temp=%.4f gd_temp=%.4f cpp_moist=%.4f gd_moist=%.4f cpp_cover=%d gd_cover=%d cpp_acc=%d gd_acc=%d (max_dt=%.4e max_dm=%.4e)" % [
			first_div_idx, first_div_field,
			shadow_temp[first_div_idx], map.temp_arr[first_div_idx],
			shadow_moist[first_div_idx], map.moisture_arr[first_div_idx],
			int(shadow_cover[first_div_idx]), int(map.cover_arr[first_div_idx]),
			shadow_acc[first_div_idx], c4.accumulated_snow_days,
			max_dt, max_dm
		])

	# Step 5：把 shadow（C++ 结果）写回 SoA/AoS，让 commit 走 C++ 路径。
	map.temp_arr = shadow_temp
	map.moisture_arr = shadow_moist
	map.cover_arr = shadow_cover
	for i in range(n_cells):
		var c5: HexCell = cells[i]
		c5.accumulated_snow_days = shadow_acc[i]
		c5.pre_snow_cover = shadow_pre[i]
		c5.current_state["cover"] = int(shadow_cover[i])

# ─── Weather Hot-Path：summary fronts A/B verify（任务 8）─────────────────
# 调用前提：host.set_summary_verify_mode(true) 之后，C++ summary pass 已成功跑过# 调用前提：set_summary_verify_mode(true) 之后，C++ summary pass 已成功跑过
# 一次（fronts_cpp 已就位）；调用方把 fronts_cpp 与 cpp_state_snapshotted=true
# 作为入参传入。本函数：
#   1. 调 C++ restore_weather_summary_state() 把 prev_seeds/membership 还原到
#      C++ pass 入口状态（snapshot 已在 fast-path 调度时由 caller 完成）；
#   2. 跑 GDScript host._build_field_summary_fronts → 得 fronts_gd；#   2. 跑 GDScript _build_field_summary_fronts → 得 fronts_gd；
#   3. 同长度 + 字段容差比对（type 严格 / center 0.5px / intensity 1e-3 /
#      velocity 0.5px），首个发散 push_warning 一次（_summary_verify_first_
#      divergence_logged 节流）；
#   4. 调用方把 fronts_cpp 写回 host._active_fronts 完成 commit（本函数不动 commit）。#   4. 调用方把 fronts_cpp 写回 _active_fronts 完成 commit（本函数不动 commit）。
#
# 注意：GDScript 复跑 host._build_field_summary_fronts 会改 host._prev_summary_seeds /# 注意：GDScript 复跑 _build_field_summary_fronts 会改 _prev_summary_seeds /
# host._prev_summary_membership（GDScript 镜像）。这两个状态在 fast-path 模式下# _prev_summary_membership（GDScript 镜像）。这两个状态在 fast-path 模式下
# 不被使用，但 verify off 切回 GDScript 路径时会被复用 —— 不算污染（GDScript
# 路径下本来就由 host._build_field_summary_fronts 自维护）。# 路径下本来就由 _build_field_summary_fronts 自维护）。

func _verify_gdext_summary_against_gdscript(host, map: MapData, world: WorldData,
		fronts_cpp: Array[WeatherFront]) -> void:
	if not host._summary_verify_enabled:
		return
	if host._data_core_world_ext == null:
		return
	# Step 1：C++ 端把 prev_seeds/membership restore 到本 tick 入口状态。
	# 调用方应已在 fast-path 调度入口调用 snapshot_weather_summary_state()。
	host._data_core_world_ext.restore_weather_summary_state()
	# Step 2：GDScript 复跑（注意 GDScript prev_seeds/membership 也会被改，
	# 见函数说明）。
	var fronts_gd: Array[WeatherFront] = host._build_field_summary_fronts(map, world)
	# Step 3：逐 front 容差比对。
	var n_cpp: int = fronts_cpp.size()
	var n_gd: int = fronts_gd.size()
	if n_cpp != n_gd and not host._summary_verify_first_divergence_logged:
		host._summary_verify_first_divergence_logged = true
		push_warning("[weather/summary verify] front count mismatch: cpp=%d gd=%d" % [n_cpp, n_gd])
		return
	var n: int = mini(n_cpp, n_gd)
	for i in range(n):
		var fc: WeatherFront = fronts_cpp[i]
		var fg: WeatherFront = fronts_gd[i]
		if fc.type != fg.type and not host._summary_verify_first_divergence_logged:
			host._summary_verify_first_divergence_logged = true
			push_warning("[weather/summary verify] front[%d] type mismatch cpp=%d gd=%d" % [i, fc.type, fg.type])
			return
		var dpos: float = fc.center.distance_to(fg.center)
		if dpos > host._summary_verify_tol_pos and not host._summary_verify_first_divergence_logged:
			host._summary_verify_first_divergence_logged = true
			push_warning("[weather/summary verify] front[%d] center mismatch cpp=%s gd=%s |Δ|=%.2f (tol=%.2f)" % [
				i, str(fc.center.round()), str(fg.center.round()), dpos, host._summary_verify_tol_pos
			])
			return
		if absf(fc.intensity - fg.intensity) > host._summary_verify_tol_intensity and not host._summary_verify_first_divergence_logged:
			host._summary_verify_first_divergence_logged = true
			push_warning("[weather/summary verify] front[%d] intensity mismatch cpp=%.4f gd=%.4f (tol=%.1e)" % [
				i, fc.intensity, fg.intensity, host._summary_verify_tol_intensity
			])
			return
		var dvel: float = fc.velocity.distance_to(fg.velocity)
		if dvel > host._summary_verify_tol_velocity and not host._summary_verify_first_divergence_logged:
			host._summary_verify_first_divergence_logged = true
			push_warning("[weather/summary verify] front[%d] velocity mismatch cpp=%s gd=%s |Δ|=%.2f (tol=%.2f)" % [
				i, str(fc.velocity.round()), str(fg.velocity.round()), dvel, host._summary_verify_tol_velocity
			])
			return

# ─── 任务 9：节流式回归告警 ───────────────────────────────────────────────
# field_solver 在 dist/summary commit 完成后分别调一次。维护最近 5 个 elapsed
# 样本；连续 5 个都 > budget × 2 时 push_warning 一次（warned 节流防止刷屏）。
# 一旦最近某次回到 budget 内，warned 重置回 false（性能恢复后可再警告）。
