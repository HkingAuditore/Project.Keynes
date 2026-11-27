extends RefCounted

## Adapts weather profiles, field inputs and commit packets to the native weather passes.


static func _sync_profile_weather_knobs(host, cp: Resource) -> void:
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

	if cp.get("weather_precip_classify_gate_land") != null:
		host._field_classify_gate_land = clampf(float(cp.weather_precip_classify_gate_land), 0.0, 0.5)
	if cp.get("weather_precip_classify_gate_water") != null:
		host._field_classify_gate_water = clampf(float(cp.weather_precip_classify_gate_water), 0.0, 0.5)
	if cp.get("weather_field_precip_spatial_smooth") != null:
		host._field_precip_spatial_smooth = clampf(float(cp.weather_field_precip_spatial_smooth), 0.0, 0.8)
	if cp.get("weather_classify_anomaly_cap") != null:
		host._weather_classify_anomaly_cap = clampf(float(cp.weather_classify_anomaly_cap), 0.0, 0.5)
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

static func _transition_enabled(host) -> Dictionary:
	var enabled: bool = bool(host._cp_for_front_flag.weather_transition_enabled) if host._cp_for_front_flag != null and host._cp_for_front_flag.get("weather_transition_enabled") != null else false
	var alpha_rate: float = float(host._cp_for_front_flag.weather_transition_alpha_rate) if host._cp_for_front_flag != null and host._cp_for_front_flag.get("weather_transition_alpha_rate") != null else 1.0
	return {"enabled": enabled, "alpha_rate": alpha_rate}

static func _build_weather_field_knobs(host, map: MapData, world: WorldData, n_cells: int, start_idx: int = 0, end_idx: int = -1) -> Dictionary:
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
	# 共用实时字段；支持 KnobsHandle 的构建从缓存读取其余标量。
	var use_resident_knobs: bool = host._knobs_handle != null \
		and host._knobs_handle.has_method("to_field_knobs_dict")
	if use_resident_knobs:
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
		"field_precip_spatial_smooth": host._field_precip_spatial_smooth,
		"weather_precip_classify_gate_land": host._field_classify_gate_land,
		"weather_precip_classify_gate_water": host._field_classify_gate_water,
		"weather_classify_anomaly_cap": host._weather_classify_anomaly_cap,
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
	if use_resident_knobs:
		return host._merge_resident_knobs_with_dynamic(host._knobs_handle.to_field_knobs_dict(), dynamic_fields)
	dynamic_fields["season_phase"] = host._season_phase
	dynamic_fields["world_bounds_pos_y"] = host._world_bounds.position.y
	dynamic_fields["world_bounds_size_y"] = host._world_bounds.size.y
	dynamic_fields["apply_convergence_boost"] = not host._field_verify_enabled
	dynamic_fields["hex_size"] = host._hex_size
	dynamic_fields["field_advect_steps"] = host._field_advect_steps
	dynamic_fields["field_diffusion"] = host._field_diffusion
	dynamic_fields["field_condensation_gain"] = host._field_condensation_gain
	dynamic_fields["field_orographic_lift_gain"] = host._field_orographic_lift_gain
	dynamic_fields["field_convergence_gain"] = host._field_convergence_gain
	dynamic_fields["field_ocean_evap_gain"] = host._field_ocean_evap_gain
	dynamic_fields["field_precip_decay"] = host._field_precip_decay
	return dynamic_fields


# 调用 C++ 端 run_weather_field_solve_pass。返回 elapsed_ms (≥0) 或 -1.0。
# 任何异常都被 catch 成 -1.0，让上层透明回退。

static func _try_run_weather_field_solve_gdext(host, map: MapData, world: WorldData, n_cells: int, start_idx: int = 0, end_idx: int = -1) -> float:
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

static func _try_run_weather_field_commit_gdext(host, map: MapData, n_cells: int) -> Dictionary:
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
