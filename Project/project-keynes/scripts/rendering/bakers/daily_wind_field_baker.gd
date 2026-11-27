extends RefCounted

## Rebuilds the wind field from the current physical circulation inputs.

static func run_daily_wind_field_update(baker: MapBaker, map: MapData, world: WorldData, cfg: MapConfig,
		hex_size: float, season_phase: float, sim_day_override: int = -1,
		stage: String = "both") -> Dictionary:
	# plan/daily-wind-stage-split（2026-06-17）：每日 wind 权威拆成 SLP / wind 两段。
	# stage="both" 一次跑两段（首跑/回归/冷启动安全网），"slp"/"wind" 各只跑一段，
	# 让 OceanCurrentsJob 按游戏日 parity 错峰调用，把单 tick 峰值从 ~5ms 降到
	# ~3ms(SLP)/~1ms(wind)。wind-only 读 map.slp_arr（上一 SLP tick 的发布值）。
	var t0_us: int = Time.get_ticks_usec()
	var out: Dictionary = {
		"ran": false,
		"path": "daily_wind_skip",
		"stage_requested": stage,
		"slp_ran": false,
		"wind_ran": false,
		"elapsed_ms": 0.0,
		"refresh_ms": 0.0,
		"slp_ms": -1.0,
		"wind_ms": -1.0,
		"slp_stage_name": "daily_wind_slp",
		"wind_stage_name": "daily_wind_wind",
		"dominant_stage": "",
		"dominant_stage_ms": 0.0,
		"fallback_reason": "",
		"slp_commit_ok": false,
		"wind_commit_ok": false,
		"wind_cpp_done": false,
		"slp_published_to_slot": false,
		"slp_delta_p95": 0.0,
		"slp_thermal_p95": 0.0,
		"wind_delta_p95": 0.0,
		"wind_dir_delta_p95": 0.0,
		"wind_dir_flip_count": 0,
		"momentum_advect_diffuse_delta_p95": 0.0,
		"momentum_advect_w_eff": 0.0,
		"momentum_diffuse_w_eff": 0.0,
		"div_damp_alpha_eff": 0.0,
		"wind_traj_gen": 0,
		"wind_traj_stale_count": 0,
		"slp_passA_ms": -1.0,
		"slp_passB_ms": -1.0,
		"slp_norm_ms": -1.0,
		"slp_marshall_ms": -1.0,
	}
	var fail := func(reason: String) -> Dictionary:
		out["fallback_reason"] = reason
		out["elapsed_ms"] = float(Time.get_ticks_usec() - t0_us) / 1000.0
		baker._daily_wind_diag_last = out.duplicate(true)
		return out

	if map == null or world == null or cfg == null:
		return fail.call("missing_refs")
	var profile: ClimateProfile = cfg.climate_profile if cfg != null else null
	if profile == null or not bool(profile.physical_circulation_enabled):
		out["path"] = "daily_wind_disabled"
		return fail.call("physical_disabled")
	if baker._world_ext == null:
		return fail.call("missing_world_ext")
	if not baker._world_ext.has_method("run_slp_field_pass") \
			or not baker._world_ext.has_method("run_wind_field_pass"):
		return fail.call("missing_cpp_method")
	if not map.has_indices():
		return fail.call("missing_indices")

	var cells: Array = map.iter_cells()
	var n_cells: int = cells.size()
	var nb_idx: PackedInt32Array = map.neighbor_indices_packed()
	if n_cells <= 0:
		return fail.call("empty_map")
	if nb_idx.size() < n_cells * 6:
		return fail.call("neighbor_indices_too_small")

	# 决定本 tick 跑哪段。wind-only 但 map.slp_arr 尺寸不齐（冷启动/换图）→ 本 tick
	# 补跑 SLP，保证 wind 永不读到空/旧尺寸 slp。
	var do_slp: bool = (stage != "wind")
	var do_wind: bool = (stage != "slp")
	if do_wind and not do_slp and map.slp_arr.size() != n_cells:
		do_slp = true
		out["stage_note"] = "wind_only_slp_primed"

	var t_refresh_us: int = Time.get_ticks_usec()
	if baker._world_ext.has_method("refresh_slots_from_map_keys"):
		baker._world_ext.refresh_slots_from_map_keys(baker._daily_wind_refresh_keys)
	elif baker._world_ext.has_method("refresh_slots_from_map"):
		baker._world_ext.refresh_slots_from_map()
	out["refresh_ms"] = float(Time.get_ticks_usec() - t_refresh_us) / 1000.0

	# 环绕周期与 bounds 以地图几何为唯一权威（与 _phys_ensure_knob_cache 的 round 路径
	# 一致），不再信任 world 上的缓存值：WorldData.world_bounds / wrap_period_x 只在
	# bake_world 时赋值，任何绕过 bake 的会话路径（或未来新增入口）都会把 0 值带进
	# C++ pass —— wrap_period_x=0 会让 synoptic/移动低压退回 clamp 域，在东西接缝
	# 产生不连续的“撞墙”阶跃。
	var bounds: Rect2 = world.world_bounds
	if bounds.size.x <= 0.001 or bounds.size.y <= 0.001:
		bounds = baker.compute_world_bounds(map.width, map.height, hex_size)
	# 单位必须是 cell_pos_x SoA 空间（size=1.0），不是世界单位：SLP/wind pass 拿它去
	# 归一化 cell_pos_x_arr。传世界单位会让归一化经度只走完 1/hex_size 个周期，
	# 接缝处 synoptic 相位硬跳 → 伪 ∇SLP → 风与洋流被锁死成一条经线。
	var wrap_period_x: float = HexUtils.wrap_period_cell_pos_x(map.width)
	var days_per_year_phys: int = baker._calendar_days_per_year(profile)
	var sim_day_phys: int = baker._phys_resolve_abs_sim_day(season_phase, days_per_year_phys, sim_day_override)
	var world_seed_phys: int = int(world.bake_seed) if world != null else (int(cfg.seed) if cfg != null else 0)
	baker._phys_last_season_phase = season_phase
	baker._phys_last_sim_day = sim_day_phys
	out["sim_day"] = sim_day_phys

	var water_ids := PackedByteArray()
	water_ids.append(int(TerrainType.TERRAIN.OCEAN))
	water_ids.append(int(TerrainType.TERRAIN.COAST))
	water_ids.append(int(TerrainType.TERRAIN.REEF))
	water_ids.append(int(TerrainType.TERRAIN.KELP))

	var slp_out: PackedFloat32Array = PackedFloat32Array()
	if do_slp:
		var knobs_slp := {
			"n_cells": n_cells,
			"hex_size": hex_size,
			"season_phase": season_phase,
			"smooth_passes": 1,
			"world_bounds_pos_y": bounds.position.y,
			"world_bounds_size_y": bounds.size.y,
			"wrap_origin_x": 0.0,
			"wrap_period_x": wrap_period_x,
			"neighbor_indices": nb_idx,
			"water_terrain_ids": water_ids,
			"prev_slp_arr": map.slp_arr,
			"slp_lat_amp": 0.16,
			"slp_land_amp": 0.55,
			"slp_water_damp": 0.20,
			"slp_interior_boost": 1.30,
			"slp_coast_damp": 0.60,
			"slp_target_p95": 0.18,
			"days_per_year": days_per_year_phys,
			"sim_day": sim_day_phys,
			"world_seed": world_seed_phys,
			"axial_tilt_deg": profile.axial_tilt_deg,
			"insolation_daylen_amp": profile.insolation_daylen_amp,
			"wind_thermal_slp_weight": profile.wind_thermal_slp_weight,
			"slp_ice_high_weight": profile.slp_ice_high_weight,
			"slp_snow_high_weight": profile.slp_snow_high_weight,
			"slp_response_rate": profile.slp_response_rate,
			"slp_synoptic_amp": profile.slp_synoptic_amp,
			"slp_moist_low_weight": profile.slp_moist_low_weight,
			"wind_synoptic_period_days": profile.wind_synoptic_period_days,
			# 让天气流动(阶段1)：移动低压系统 knobs（C++ 在 SLP 叠加平移高斯低压源，驱动移动辐合带）。
			"slp_mobile_low_count": profile.slp_mobile_low_count,
			"slp_mobile_low_amp": profile.slp_mobile_low_amp,
			"slp_mobile_low_sigma": profile.slp_mobile_low_sigma,
			"slp_mobile_low_period_days": profile.slp_mobile_low_period_days,
		}
		var ret_slp = baker._world_ext.run_slp_field_pass(knobs_slp)
		if ret_slp == null or typeof(ret_slp) != TYPE_DICTIONARY:
			return fail.call("slp_non_dict")
		var rc_slp: float = float(ret_slp.get("elapsed_ms", -1.0))
		slp_out = ret_slp.get("slp_out", PackedFloat32Array())
		var slp_published_to_slot: bool = bool(ret_slp.get("published_to_slot", false))
		var slp_slot_publish_reason: String = str(ret_slp.get(
				"slot_publish_reason", "legacy_dll_unknown"))
		out["slp_ms"] = rc_slp
		out["slp_published_to_slot"] = slp_published_to_slot
		out["slp_slot_publish_reason"] = slp_slot_publish_reason
		out["slp_slot_id"] = int(ret_slp.get("slot_id", -1))
		out["slp_slot_size"] = int(ret_slp.get("slot_size", 0))
		# 埋点 surface：C++ run_slp_field_pass 内部分段计时（缺失=-1，旧 DLL 兼容）。
		out["slp_passA_ms"] = float(ret_slp.get("slp_passA_ms", -1.0))
		out["slp_passB_ms"] = float(ret_slp.get("slp_passB_ms", -1.0))
		out["slp_norm_ms"] = float(ret_slp.get("slp_norm_ms", -1.0))
		out["slp_marshall_ms"] = float(ret_slp.get("slp_marshall_ms", -1.0))
		baker._phys_last_slp_rc_ms = rc_slp
		baker._phys_last_slp_out_size = slp_out.size()
		baker._phys_last_slp_published_to_slot = slp_published_to_slot
		baker._phys_last_slp_commit_ok = rc_slp >= 0.0 and slp_out.size() == n_cells
		if rc_slp < 0.0 or slp_out.size() != n_cells:
			return fail.call("slp_failed:%s" % str(ret_slp.get("reason", "")))
		if not slp_published_to_slot:
			# Compatibility boundary for an old DLL or an invalid native slot. The
			# computation still came from C++; replace the PackedArray once and then
			# refresh only cell_slp instead of doing n_cells CoW writes.
			map.slp_arr = slp_out
			if baker._world_ext.has_method("refresh_slots_from_map_keys"):
				baker._world_ext.refresh_slots_from_map_keys(PackedStringArray(["cell_slp"]))
		baker._slp_thermal_p95_last = float(ret_slp.get("slp_thermal_p95", 0.0))
		baker._slp_delta_p95_last = float(ret_slp.get("slp_delta_p95", 0.0))
		baker._slp_native_ms_last = rc_slp
		baker._slp_path_str_last = "gdext"
		out["slp_commit_ok"] = true
		out["slp_delta_p95"] = baker._slp_delta_p95_last
		out["slp_thermal_p95"] = baker._slp_thermal_p95_last
		out["slp_ran"] = true

	if do_wind:
		var slp_for_wind: PackedFloat32Array = map.slp_arr if map.slp_arr.size() == n_cells else slp_out
		var terrain_aware: bool = profile.enable_terrain_aware_wind
		var knobs_wind := {
			"n_cells": n_cells,
			"hex_size": hex_size,
			"season_phase": season_phase,
			"terrain_aware": (1 if terrain_aware else 0),
			"world_bounds_pos_y": bounds.position.y,
			"world_bounds_size_y": bounds.size.y,
			"wrap_origin_x": 0.0,
			"wrap_period_x": wrap_period_x,
			"neighbor_indices": nb_idx,
			"slp_arr": slp_for_wind,
			"water_terrain_ids": water_ids,
			"land_lf_mountain": int(LandformType.LF.MOUNTAIN),
			"land_lf_peak": int(LandformType.LF.PEAK),
			"land_lf_hill": int(LandformType.LF.HILL),
			"days_per_year": days_per_year_phys,
			"sim_day": sim_day_phys,
			"world_seed": world_seed_phys,
			"axial_tilt_deg": profile.axial_tilt_deg,
			"wind_response_rate": profile.wind_response_rate,
			"wind_max_turn_deg_per_day": profile.wind_max_turn_deg_per_day,
			"wind_elapsed_days": baker._phys_take_wind_elapsed_days(sim_day_phys),
			"wind_min_flux_for_dir_update": profile.wind_min_flux_for_dir_update,
			"wind_synoptic_amp": profile.wind_synoptic_amp,
			"wind_synoptic_period_days": profile.wind_synoptic_period_days,
			"wind_belt_only_debug": profile.wind_belt_only_debug,
			# NS 化(plan/NS化气候动力学四方向深化):动量/轨迹表/散度阻尼 gate,默认全关。
			"wind_momentum_advect_w": profile.wind_momentum_advect_w,
			"wind_momentum_diffuse_w_daily": profile.wind_momentum_diffuse_w_daily,
			"wind_traj_table_enabled": profile.wind_traj_table_enabled,
			"wind_traj_pos_scale": profile.wind_traj_pos_scale,
			"wind_traj_dt_days": profile.wind_traj_dt_days,
			"wind_traj_weather_share": profile.wind_traj_weather_share,
			"wind_div_damp_alpha": profile.wind_div_damp_alpha,
			"thermal_monsoon_enabled": profile.thermal_monsoon_enabled,
			"thermal_monsoon_lat_limit": profile.thermal_monsoon_lat_limit,
			"thermal_monsoon_deadband": profile.thermal_monsoon_deadband,
			"thermal_monsoon_full_contrast": profile.thermal_monsoon_full_contrast,
			"thermal_monsoon_gain": profile.thermal_monsoon_gain,
			"thermal_monsoon_breeze_floor": profile.thermal_monsoon_breeze_floor,
		}
		var rc_wind_raw = baker._world_ext.run_wind_field_pass(knobs_wind)
		var rc_wind: float = float(rc_wind_raw) if rc_wind_raw != null else -1.0
		out["wind_ms"] = rc_wind
		baker._phys_last_wind_rc_ms = rc_wind
		if rc_wind < 0.0:
			baker._phys_wind_done_by_cpp = false
			return fail.call("wind_failed")

		var wx_arr: PackedFloat32Array = map.wind_x_arr
		var wy_arr: PackedFloat32Array = map.wind_y_arr
		var wspd_arr: PackedFloat32Array = knobs_wind.get("wind_speed_out", PackedFloat32Array())
		baker._phys_last_wind_wx_size = wx_arr.size()
		baker._phys_last_wind_wy_size = wy_arr.size()
		baker._phys_last_wind_speed_out_size = wspd_arr.size()
		baker._phys_last_wind_map_speed_size = map.wind_speed_arr.size()
		baker._phys_last_wind_commit_ok = wx_arr.size() == n_cells and wy_arr.size() == n_cells \
				and wspd_arr.size() == n_cells and map.wind_speed_arr.size() == n_cells
		if not baker._phys_last_wind_commit_ok:
			baker._phys_wind_done_by_cpp = false
			return fail.call("wind_size_mismatch")

		baker._wind_delta_p95_last = float(knobs_wind.get("wind_delta_p95", 0.0))
		baker._wind_dir_delta_p95_last = float(knobs_wind.get("wind_dir_delta_p95", 0.0))
		baker._wind_dir_flip_count_last = int(knobs_wind.get("wind_dir_flip_count", 0))
		# NS 化诊断键(旧 DLL 缺键时落默认 0,能力探测兼容)
		baker._wind_momentum_delta_p95_last = float(knobs_wind.get("momentum_advect_diffuse_delta_p95", 0.0))
		baker._wind_momentum_advect_w_eff_last = float(knobs_wind.get("momentum_advect_w_eff", 0.0))
		baker._wind_momentum_diffuse_w_eff_last = float(knobs_wind.get("momentum_diffuse_w_eff", 0.0))
		baker._wind_div_damp_alpha_eff_last = float(knobs_wind.get("div_damp_alpha_eff", 0.0))
		baker._wind_traj_gen_last = int(knobs_wind.get("wind_traj_gen", 0))
		baker._wind_traj_stale_count_last = int(knobs_wind.get("wind_traj_stale_count", 0))
		baker._phys_wind_done_by_cpp = true
		out["wind_cpp_done"] = true
		out["wind_commit_ok"] = true
		out["wind_delta_p95"] = baker._wind_delta_p95_last
		out["wind_dir_delta_p95"] = baker._wind_dir_delta_p95_last
		out["wind_dir_flip_count"] = baker._wind_dir_flip_count_last
		out["momentum_advect_diffuse_delta_p95"] = baker._wind_momentum_delta_p95_last
		out["momentum_advect_w_eff"] = baker._wind_momentum_advect_w_eff_last
		out["momentum_diffuse_w_eff"] = baker._wind_momentum_diffuse_w_eff_last
		out["div_damp_alpha_eff"] = baker._wind_div_damp_alpha_eff_last
		out["wind_traj_gen"] = baker._wind_traj_gen_last
		out["wind_traj_stale_count"] = baker._wind_traj_stale_count_last
		out["wind_ran"] = true

	out["ran"] = bool(out["slp_ran"]) or bool(out["wind_ran"])
	if not bool(out["ran"]):
		return fail.call("no_stage_ran")
	# path 反映本 tick 实际跑的段，供调度日志 / 归因区分。
	if bool(out["slp_ran"]) and bool(out["wind_ran"]):
		out["path"] = "gdext_daily_wind"
	elif bool(out["slp_ran"]):
		out["path"] = "gdext_daily_wind_slp"
	else:
		out["path"] = "gdext_daily_wind_wind"
	out["elapsed_ms"] = float(Time.get_ticks_usec() - t0_us) / 1000.0
	# dominant_stage：两段都跑时比大小；单段 tick 直接取该段。
	var slp_ms_v: float = float(out["slp_ms"])
	var wind_ms_v: float = float(out["wind_ms"])
	if bool(out["slp_ran"]) and (not bool(out["wind_ran"]) or slp_ms_v >= wind_ms_v):
		out["dominant_stage"] = str(out["slp_stage_name"])
		out["dominant_stage_ms"] = slp_ms_v
	else:
		out["dominant_stage"] = str(out["wind_stage_name"])
		out["dominant_stage_ms"] = wind_ms_v
	baker._daily_wind_diag_last = out.duplicate(true)
	return out
