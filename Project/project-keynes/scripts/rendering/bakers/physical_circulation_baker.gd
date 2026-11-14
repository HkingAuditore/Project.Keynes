extends RefCounted
class_name DCPhysicalCirculationBaker




## Small physical-circulation policy helpers. Solve loops and mutable buffers stay in MapBaker.

static func cell_slice_enabled(baker: MapBaker, profile: ClimateProfile) -> bool:
	if profile != null and profile.get("physical_cell_slice_enabled") != null:
		return bool(profile.physical_cell_slice_enabled)
	return baker._phys_cell_slice_enabled



static func cell_slice_divisor(baker: MapBaker, profile: ClimateProfile) -> int:
	if profile != null and profile.get("physical_cell_slice_divisor") != null:
		return clampi(int(profile.physical_cell_slice_divisor), 1, 32)
	return clampi(baker._phys_cell_slice_divisor, 1, 32)



static func use_physical_circulation(baker: MapBaker, cfg: MapConfig) -> bool:
	if cfg == null or cfg.climate_profile == null:
		return false
	return bool(cfg.climate_profile.physical_circulation_enabled)


static func calendar_days_per_year(baker: MapBaker, profile = null) -> int:
	if baker._world_clock_ref != null and baker._world_clock_ref.has_method("days_per_year"):
		return clampi(int(baker._world_clock_ref.days_per_year()), 1, 3660)
	var cp = profile if profile != null else baker._climate_profile
	if cp != null and cp.get("orbital_days_per_year") != null:
		return clampi(int(cp.get("orbital_days_per_year")), 1, 3660)
	return 365


static func season_phase_to_day_of_year(baker: MapBaker, season_phase: float, days_per_year: int = 0) -> int:
	var dpy: int = clampi(days_per_year if days_per_year > 0 else calendar_days_per_year(baker), 1, 3660)
	var p: float = fposmod(season_phase, 4.0)
	return clampi(int(floor((p / 4.0) * float(dpy))), 0, dpy - 1)


## 物理 pass 的 `sim_day` knob 唯一来源：单调递增的绝对仿真日。
##
## 三个入口（daily wind、solve step、native oneshot）都要用它，否则同一个 synoptic
## 相位会被喂进两套不同单位 —— 详见 `baker._phys_abs_sim_day` 注释。`override_day` 由
## OceanCurrentsJob 的 `ctx.day_index` 提供，是权威值；一旦见过就锁定给其它入口复用。
## 冷启动（daily 路径尚未跑过）才退化到年内日，仅保证同一 tick 内 SLP/wind 相位一致。

static func resolve_abs_sim_day(baker: MapBaker, season_phase: float, days_per_year: int, override_day: int = -1) -> int:
	if override_day >= 0:
		baker._phys_abs_sim_day = override_day
		return override_day
	if baker._phys_abs_sim_day >= 0:
		return baker._phys_abs_sim_day
	return season_phase_to_day_of_year(baker, season_phase, days_per_year)


## wind 段自上次实际运行以来经过的游戏日（>=1）。C++ 用它把
## `wind_max_turn_deg_per_day` 从「每次调用」还原成「每游戏日」。

static func take_wind_elapsed_days(baker: MapBaker, sim_day: int) -> float:
	var elapsed: float = 1.0
	if baker._phys_last_wind_sim_day >= 0 and sim_day > baker._phys_last_wind_sim_day:
		elapsed = float(sim_day - baker._phys_last_wind_sim_day)
	baker._phys_last_wind_sim_day = sim_day
	return clampf(elapsed, 1.0, 30.0)

# 强制下一次 _physical_solve_step_one 从 SLP 阶段重新开始。OceanCurrentsJob
# 在新一轮（_round_active=false → true）转换时调一次，确保季节相位变更被
# 重新求解；一次性入口 _physical_solve_for_phase 也调一次，避免和切片路径
# 残留的 _phys_stage 冲突。
## Block B（master 手册 §4）：MapGenerator 在 bake_world / 加载存档时注入 DCWorldExt。
## ext == null 时所有 C++ hook 退化为 GDScript path，行为零回归。

static func physical_stage_name(baker: MapBaker, stage: int) -> String:
	match stage:
		baker._PHYS_STAGE_NONE: return "phys_none"
		baker._PHYS_STAGE_SLP: return "phys_slp"
		baker._PHYS_STAGE_WIND: return "phys_wind"
		baker._PHYS_STAGE_PSI_INIT: return "phys_psi_init"
		baker._PHYS_STAGE_PSI_ITERS: return "phys_psi_iters"
		baker._PHYS_STAGE_PSI_FINALIZE: return "phys_psi_finalize"
		baker._PHYS_STAGE_UPWELLING: return "phys_upwelling"
		baker._PHYS_STAGE_WIND_RASTER: return "phys_wind_raster"
		baker._PHYS_STAGE_DONE: return "phys_done"
		_: return "phys_unknown"

static func begin_runtime_physics_visual(baker: MapBaker, map: MapData, world: WorldData, view: Dictionary, phase: float) -> bool:
	if map == null or world == null or not bool(view.get("ready", false)) \
			or int(view.get("cell_count", 0)) != map.soa_size():
		return false
	for key in ["slp", "wind_x", "wind_y", "wind_speed", "ocean_current_x", "ocean_current_y", "upwelling"]:
		if not view.get(key) is PackedFloat32Array or view[key].size() != map.soa_size():
			return false
	baker._runtime_physics_visual_view = view.duplicate()
	baker._pending_phase = phase
	baker._pending_phys_solved_phase = phase
	baker._phys_stage = baker._PHYS_STAGE_DONE
	baker._pending_psi_state = null
	baker._ensure_pending_wind_size(world)
	baker._ensure_pending_currents_size(world)
	return true



static func reset_physical_solve_state(baker: MapBaker) -> void:
	baker._runtime_physics_visual_view = {}
	baker._phys_stage = baker._PHYS_STAGE_NONE
	baker._phys_psi_iters_done = 0
	baker._phys_wind_raster_idx = 0
	baker._phys_wind_done_by_cpp = false
	baker._pending_phys_solved_phase = NAN
	baker._pending_psi_state = null
	baker._pending_wind_buf = PackedByteArray()
	# plan/dots-slp-psi-cpp — reset per-round path-decision counters & timings
	# so a freshly-bound profile flag flip takes effect immediately on the
	# next round (previous round's residual values would otherwise be sticky).
	baker._slp_native_ms_last = -1.0
	baker._slp_path_str_last = "gdscript"
	baker._psi_native_ms_last = -1.0
	baker._psi_path_str_last = "gdscript"
	baker._psi_iters_run_last = 0
	baker._psi_residual_final_last = 0.0
	baker._psi_early_exit_last = false
	baker._psi_mode_last = "off"
	baker._slp_thermal_p95_last = 0.0
	baker._slp_delta_p95_last = 0.0
	baker._wind_delta_p95_last = 0.0
	baker._wind_dir_delta_p95_last = 0.0
	baker._wind_dir_flip_count_last = 0
	baker._ocean_delta_p95_last = 0.0
	baker._thermal_current_p95_last = 0.0
	baker._ocean_current_preclamp_p95_last = 0.0
	baker._ocean_current_preclamp_max_last = 0.0
	baker._ocean_current_clamp_count_last = 0
	baker._ocean_current_clamp_ratio_last = 0.0
	baker._ocean_current_max_magnitude_last = 0.0
	baker._ocean_topo_steer_w_eff_last = 0.0
	baker._ocean_depth_curl_damp_eff_last = 0.0
	baker._phys_last_season_phase = NAN
	baker._phys_last_sim_day = -1
	baker._phys_abs_sim_day = -1
	baker._phys_last_wind_sim_day = -1
	baker._phys_last_slp_rc_ms = -1.0
	baker._phys_last_slp_out_size = -1
	baker._phys_last_slp_published_to_slot = false
	baker._phys_last_slp_commit_ok = false
	baker._phys_last_wind_rc_ms = -1.0
	baker._phys_last_wind_wx_size = -1
	baker._phys_last_wind_wy_size = -1
	baker._phys_last_wind_speed_out_size = -1
	baker._phys_last_wind_map_speed_size = -1
	baker._phys_last_wind_commit_ok = false

# plan/dots-slp-psi-cpp — diagnostics getters for ocean_currents_job to attach
# stage_slp_path / stage_slp_native_ms / stage_psi_path / stage_psi_native_ms
# onto its slice-result dictionary (mirrors stage_0_path / stage_8_path naming
# convention from season_refresh's _last_season_refresh_breakdown).

static func get_slp_path_str(baker: MapBaker) -> String:
	return baker._slp_path_str_last

static func get_slp_native_ms(baker: MapBaker) -> float:
	return baker._slp_native_ms_last

static func get_psi_path_str(baker: MapBaker) -> String:
	return baker._psi_path_str_last

static func get_psi_native_ms(baker: MapBaker) -> float:
	return baker._psi_native_ms_last

static func get_psi_iters_run(baker: MapBaker) -> int:
	return baker._psi_iters_run_last

static func get_psi_residual_final(baker: MapBaker) -> float:
	return baker._psi_residual_final_last

static func get_psi_early_exit(baker: MapBaker) -> bool:
	return baker._psi_early_exit_last

static func get_psi_mode(baker: MapBaker) -> String:
	return baker._psi_mode_last

static func get_slp_thermal_p95(baker: MapBaker) -> float:
	return baker._slp_thermal_p95_last

static func get_slp_delta_p95(baker: MapBaker) -> float:
	return baker._slp_delta_p95_last

static func get_wind_delta_p95(baker: MapBaker) -> float:
	return baker._wind_delta_p95_last

static func get_wind_dir_delta_p95(baker: MapBaker) -> float:
	return baker._wind_dir_delta_p95_last

static func get_wind_dir_flip_count(baker: MapBaker) -> int:
	return baker._wind_dir_flip_count_last

static func get_ocean_delta_p95(baker: MapBaker) -> float:
	return baker._ocean_delta_p95_last

static func get_thermal_current_p95(baker: MapBaker) -> float:
	return baker._thermal_current_p95_last

static func get_ocean_current_preclamp_p95(baker: MapBaker) -> float:
	return baker._ocean_current_preclamp_p95_last

static func get_ocean_current_preclamp_max(baker: MapBaker) -> float:
	return baker._ocean_current_preclamp_max_last

static func get_ocean_current_clamp_count(baker: MapBaker) -> int:
	return baker._ocean_current_clamp_count_last

static func get_ocean_current_clamp_ratio(baker: MapBaker) -> float:
	return baker._ocean_current_clamp_ratio_last

static func get_ocean_current_max_magnitude(baker: MapBaker) -> float:
	return baker._ocean_current_max_magnitude_last

static func get_physical_circulation_diag(baker: MapBaker) -> Dictionary:
	return {
		"season_phase": baker._phys_last_season_phase,
		"sim_day": baker._phys_last_sim_day,
		"phys_stage": baker._phys_stage,
		"phys_stage_name": baker._physical_stage_name(baker._phys_stage),
		"phys_cell_slice_enabled": baker._phys_cell_slice_enabled,
		"phys_cell_slice_divisor": baker._phys_cell_slice_divisor,
		"slp_path": baker._slp_path_str_last,
		"slp_native_ms": baker._slp_native_ms_last,
		"slp_rc_ms": baker._phys_last_slp_rc_ms,
		"slp_out_size": baker._phys_last_slp_out_size,
		"slp_published_to_slot": baker._phys_last_slp_published_to_slot,
		"slp_commit_ok": baker._phys_last_slp_commit_ok,
		"slp_thermal_p95": baker._slp_thermal_p95_last,
		"slp_delta_p95": baker._slp_delta_p95_last,
		"wind_cpp_done": baker._phys_wind_done_by_cpp,
		"wind_rc_ms": baker._phys_last_wind_rc_ms,
		"wind_wx_size": baker._phys_last_wind_wx_size,
		"wind_wy_size": baker._phys_last_wind_wy_size,
		"wind_speed_out_size": baker._phys_last_wind_speed_out_size,
		"wind_map_speed_size": baker._phys_last_wind_map_speed_size,
		"wind_commit_ok": baker._phys_last_wind_commit_ok,
		"wind_delta_p95": baker._wind_delta_p95_last,
		"wind_dir_delta_p95": baker._wind_dir_delta_p95_last,
		"wind_dir_flip_count": baker._wind_dir_flip_count_last,
		# NS 化诊断(gate 全关时恒 0)
		"wind_momentum_advect_diffuse_delta_p95": baker._wind_momentum_delta_p95_last,
		"wind_momentum_advect_w_eff": baker._wind_momentum_advect_w_eff_last,
		"wind_momentum_diffuse_w_eff": baker._wind_momentum_diffuse_w_eff_last,
		"wind_div_damp_alpha_eff": baker._wind_div_damp_alpha_eff_last,
		"wind_traj_gen": baker._wind_traj_gen_last,
		"wind_traj_stale_count": baker._wind_traj_stale_count_last,
		"daily_wind_ran": bool(baker._daily_wind_diag_last.get("ran", false)),
		"daily_wind_path": str(baker._daily_wind_diag_last.get("path", "")),
		"daily_wind_elapsed_ms": float(baker._daily_wind_diag_last.get("elapsed_ms", -1.0)),
		"daily_wind_refresh_ms": float(baker._daily_wind_diag_last.get("refresh_ms", -1.0)),
		"daily_wind_slp_ms": float(baker._daily_wind_diag_last.get("slp_ms", -1.0)),
		"daily_wind_wind_ms": float(baker._daily_wind_diag_last.get("wind_ms", -1.0)),
		"daily_wind_stage_requested": str(baker._daily_wind_diag_last.get("stage_requested", "both")),
		"daily_wind_slp_ran": bool(baker._daily_wind_diag_last.get("slp_ran", false)),
		"daily_wind_wind_ran": bool(baker._daily_wind_diag_last.get("wind_ran", false)),
		"daily_wind_slp_passA_ms": float(baker._daily_wind_diag_last.get("slp_passA_ms", -1.0)),
		"daily_wind_slp_passB_ms": float(baker._daily_wind_diag_last.get("slp_passB_ms", -1.0)),
		"daily_wind_slp_norm_ms": float(baker._daily_wind_diag_last.get("slp_norm_ms", -1.0)),
		"daily_wind_slp_marshall_ms": float(baker._daily_wind_diag_last.get("slp_marshall_ms", -1.0)),
		"daily_wind_fallback_reason": str(baker._daily_wind_diag_last.get("fallback_reason", "")),
		# 本 tick 实跑段是否成功：ran 且无 fallback_reason。直接读 wind_commit_ok 会在
		# SLP-only 日误报 false（wind 本就没跑），故改用 ran/fallback。
		"daily_wind_commit_ok": bool(baker._daily_wind_diag_last.get("ran", false)) \
				and str(baker._daily_wind_diag_last.get("fallback_reason", "")) == "",
		"daily_wind_slp_commit_ok": bool(baker._daily_wind_diag_last.get("slp_commit_ok", false)),
		"daily_wind_wind_commit_ok": bool(baker._daily_wind_diag_last.get("wind_commit_ok", false)),
		"daily_wind_slp_delta_p95": float(baker._daily_wind_diag_last.get("slp_delta_p95", 0.0)),
		"daily_wind_delta_p95": float(baker._daily_wind_diag_last.get("wind_delta_p95", 0.0)),
		"daily_wind_dir_delta_p95": float(baker._daily_wind_diag_last.get("wind_dir_delta_p95", 0.0)),
		"daily_wind_dir_flip_count": int(baker._daily_wind_diag_last.get("wind_dir_flip_count", 0)),
		"daily_wind_momentum_advect_diffuse_delta_p95": float(baker._daily_wind_diag_last.get("momentum_advect_diffuse_delta_p95", 0.0)),
		"daily_wind_div_damp_alpha_eff": float(baker._daily_wind_diag_last.get("div_damp_alpha_eff", 0.0)),
		"daily_wind_traj_gen": int(baker._daily_wind_diag_last.get("wind_traj_gen", 0)),
		"daily_wind_traj_stale_count": int(baker._daily_wind_diag_last.get("wind_traj_stale_count", 0)),
		"psi_path": baker._psi_path_str_last,
		"psi_native_ms": baker._psi_native_ms_last,
		"psi_iters_run": baker._psi_iters_run_last,
		"psi_residual_final": baker._psi_residual_final_last,
		"psi_early_exit": baker._psi_early_exit_last,
		"psi_mode": baker._psi_mode_last,
		"ocean_delta_p95": baker._ocean_delta_p95_last,
		"thermal_current_p95": baker._thermal_current_p95_last,
		"ocean_current_preclamp_p95": baker._ocean_current_preclamp_p95_last,
		"ocean_current_preclamp_max": baker._ocean_current_preclamp_max_last,
		"ocean_current_clamp_count": baker._ocean_current_clamp_count_last,
		"ocean_current_clamp_ratio": baker._ocean_current_clamp_ratio_last,
		"ocean_current_max_magnitude": baker._ocean_current_max_magnitude_last,
		"ocean_topo_steer_w_eff": baker._ocean_topo_steer_w_eff_last,
		"ocean_depth_curl_damp_eff": baker._ocean_depth_curl_damp_eff_last,
	}



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



static func prime_physical_solve_from_current_wind(baker: MapBaker, map: MapData, season_phase: float) -> bool:
	if map == null:
		return false
	var n_cells: int = map.soa_size()
	if n_cells <= 0:
		return false
	if map.wind_x_arr.size() != n_cells or map.wind_y_arr.size() != n_cells \
			or map.wind_speed_arr.size() != n_cells:
		return false
	baker._phys_stage = baker._PHYS_STAGE_PSI_INIT
	baker._phys_psi_iters_done = 0
	baker._phys_wind_raster_idx = 0
	baker._pending_psi_state = null
	baker._pending_phys_solved_phase = NAN
	baker._phys_wind_done_by_cpp = true
	baker._phys_last_season_phase = season_phase
	baker._phys_last_wind_wx_size = map.wind_x_arr.size()
	baker._phys_last_wind_wy_size = map.wind_y_arr.size()
	baker._phys_last_wind_speed_out_size = map.wind_speed_arr.size()
	baker._phys_last_wind_map_speed_size = map.wind_speed_arr.size()
	baker._phys_last_wind_commit_ok = true
	return true

# Phys Solve Sliced 入口 ② ：把 7 阶段求解推进 1 步，返回 true 表示本轮已彻底完成
# （`_pending_phys_solved_phase = season_phase` 同时被设好）。
#
# OceanCurrentsJob 每个 run_slice 调一次 step_one，全部完成后再开始按像素区间
# 光栅化。每个 stage 的耗时上界：
#   SLP        ~5ms     —— 2400 cell × 6 邻居平滑 1 次 + 基线公式
#   WIND       ~5ms     —— 2400 cell × (6 邻居梯度 + 山脉绕流)
#   PSI_INIT   ~3ms     —— 标记水格 + 邻居索引 + curl τ
#   PSI_ITERS  ~2ms × 5 —— 8 SOR/step × 5 step = 40 iters，与一次性路径等价
#   PSI_FINAL  ~3ms     —— ψ → ocean_current + commit
#   UPWELLING  ~3ms     —— 沿岸 Ekman + 高纬冷沉
#   WIND_RASTER ~5ms    —— NaN 守门 + 风场 RG8 写盘
# 第一片最坏 ~5ms（远低于一次性路径的 ~200ms 毛刺）。
# ── Phys Solve wrapper 开销削减 ────────────────────────────────────────
# 预建四个 stage 的「常量字段」base knob dict（SLP/WIND/PSI/UPWELLING）与共享的
# 4 字节 water_terrain_ids。拓扑/几何/配置在 sim 期固定，故按
# (map, profile, hex_size) 失效：仅在引用变化（地图重建）时重建，否则零成本返回。
# 每调用由对应 stage 用 base.duplicate() + 覆盖变化字段，省去 27/22/25/7 字面
# 构造 + 7 次 profile 属性读取 + 多次 int() 枚举转换。C++ 同步读取 base 中的
# PackedArray（neighbor_indices / water_ids）引用，不复制。
# 注意：若后续给某 stage 增加新的常量 knob 字段，必须同步加到此处的 base，
# 否则该字段会在缓存命中时被遗漏（变化字段由 stage 内显式设置，不受影响）。
# B8 P2：worker 侧物理 prepass 需要同一批标量。这里的投影只保留标量键（丢 per-cell
# 数组），由 MapGenerator 随环境快照下发；worker 用自己的 lane，因此数组没有意义。
# 新增字段时只需加进对应 base dict —— 投影自动带走，不必再维护第二份清单。

static func runtime_physics_knobs(baker: MapBaker) -> Dictionary:
	if baker._phys_knobs_base_slp.is_empty() or baker._phys_knobs_base_wind.is_empty() \
			or baker._phys_knobs_base_psi.is_empty() or baker._phys_knobs_base_up.is_empty():
		if not baker._runtime_physics_knobs_reported:
			baker._runtime_physics_knobs_reported = true
			print("[phys/knobs] projection empty (slp=%d wind=%d) — bake 未跑或物理未启用"
				% [baker._phys_knobs_base_slp.size(), baker._phys_knobs_base_wind.size()])
		return {}
	if not baker._runtime_physics_knobs_reported:
		baker._runtime_physics_knobs_reported = true
		print("[phys/knobs] projection ready: slp=%d wind=%d psi=%d up=%d" % [
			baker._phys_knobs_base_slp.size(), baker._phys_knobs_base_wind.size(),
			baker._phys_knobs_base_psi.size(), baker._phys_knobs_base_up.size()])
	return {
		"slp": baker._phys_scalar_knob_projection(baker._phys_knobs_base_slp),
		"wind": baker._phys_scalar_knob_projection(baker._phys_knobs_base_wind),
		"psi": baker._phys_scalar_knob_projection(baker._phys_knobs_base_psi),
		"upwelling": baker._phys_scalar_knob_projection(baker._phys_knobs_base_up),
		"water_terrain_ids": baker._phys_water_ids_cache,
	}



static func _phys_scalar_knob_projection(baker: MapBaker, src: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for k in src.keys():
		if k is StringName or k is String:
			if String(k) in baker._PHYS_LANE_KNOB_KEYS:
				continue
		out[k] = src[k]
	return out



static func _phys_ensure_knob_cache(baker: MapBaker, map: MapData, hex_size: float, bounds: Rect2,
		profile: ClimateProfile, cfg: MapConfig) -> void:
	if baker._phys_knob_cache_map == map and baker._phys_knob_cache_profile == profile \
			and baker._phys_knob_cache_hex == hex_size:
		return
	baker._phys_knob_cache_map = map
	baker._phys_knob_cache_profile = profile
	baker._phys_knob_cache_hex = hex_size
	# 4 字节常量 water_terrain_ids（OCEAN/COAST/REEF/KELP），四个 stage 共用。
	baker._phys_water_ids_cache = PackedByteArray()
	baker._phys_water_ids_cache.append(int(TerrainType.TERRAIN.OCEAN))
	baker._phys_water_ids_cache.append(int(TerrainType.TERRAIN.COAST))
	baker._phys_water_ids_cache.append(int(TerrainType.TERRAIN.REEF))
	baker._phys_water_ids_cache.append(int(TerrainType.TERRAIN.KELP))
	var nb: PackedInt32Array = map.neighbor_indices_packed()
	var n_cells: int = map.soa_size()
	# 见 _phys_run_pass 同名变量：物理 pass 的 wrap_period_x 是 cell_pos_x 空间单位。
	var wrap_period_x: float = HexUtils.wrap_period_cell_pos_x(map.width)
	var days_per_year: int = baker._calendar_days_per_year(profile)
	var axial_tilt: float = profile.axial_tilt_deg if profile != null else 23.5
	var insolation_amp: float = profile.insolation_daylen_amp if profile != null else 0.35
	var terrain_aware_i: int = 1 if (profile == null or profile.enable_terrain_aware_wind) else 0
	var cold_sink_temp: float = -0.05
	if cfg != null and "COLD_SINK_TEMP" in cfg:
		cold_sink_temp = float(cfg.COLD_SINK_TEMP)
	# ── SLP base（变化字段：season_phase / sim_day / world_seed / prev_slp_arr）
	baker._phys_knobs_base_slp = {
		"n_cells": n_cells,
		"hex_size": hex_size,
		"smooth_passes": 1,  # mirrors PhysCircSolverScript._SLP_SMOOTH_PASSES
		"world_bounds_pos_y": bounds.position.y,
		"world_bounds_size_y": bounds.size.y,
		"wrap_origin_x": 0.0,
		"wrap_period_x": wrap_period_x,
		"neighbor_indices": nb,
		"water_terrain_ids": baker._phys_water_ids_cache,
		"slp_lat_amp": 0.16,
		"slp_land_amp": 0.55,
		"slp_water_damp": 0.20,
		"slp_interior_boost": 1.30,
		"slp_coast_damp": 0.60,
		"slp_target_p95": 0.18,
		"slp_recenter": true,
		"slp_lat_lut_bins": 1024,
		"wind_thermal_slp_weight": 0.0,
		"slp_ice_high_weight": 0.0,
		"slp_snow_high_weight": 0.0,
		"slp_response_rate": 0.55,
		"slp_synoptic_amp": 0.075,
		"slp_moist_low_weight": 0.12,
		"wind_synoptic_period_days": 6.0,
		"slp_mobile_low_count": 0,
		"slp_mobile_low_amp": 0.0,
		"slp_mobile_low_sigma": 0.16,
		"slp_mobile_low_period_days": 38.0,
		"days_per_year": days_per_year,
		"axial_tilt_deg": axial_tilt,
		"insolation_daylen_amp": insolation_amp,
	}
	if profile != null:
		baker._phys_knobs_base_slp["wind_thermal_slp_weight"] = profile.wind_thermal_slp_weight
		baker._phys_knobs_base_slp["slp_ice_high_weight"] = profile.slp_ice_high_weight
		baker._phys_knobs_base_slp["slp_snow_high_weight"] = profile.slp_snow_high_weight
		baker._phys_knobs_base_slp["slp_response_rate"] = profile.slp_response_rate
		baker._phys_knobs_base_slp["slp_synoptic_amp"] = profile.slp_synoptic_amp
		baker._phys_knobs_base_slp["slp_moist_low_weight"] = profile.slp_moist_low_weight
		baker._phys_knobs_base_slp["wind_synoptic_period_days"] = profile.wind_synoptic_period_days
		baker._phys_knobs_base_slp["slp_mobile_low_count"] = profile.slp_mobile_low_count
		baker._phys_knobs_base_slp["slp_mobile_low_amp"] = profile.slp_mobile_low_amp
		baker._phys_knobs_base_slp["slp_mobile_low_sigma"] = profile.slp_mobile_low_sigma
		baker._phys_knobs_base_slp["slp_mobile_low_period_days"] = profile.slp_mobile_low_period_days
	# ── WIND base（变化：season_phase / sim_day / world_seed / slp_arr）
	baker._phys_knobs_base_wind = {
		"n_cells": n_cells,
		"hex_size": hex_size,
		"terrain_aware": terrain_aware_i,
		"world_bounds_pos_y": bounds.position.y,
		"world_bounds_size_y": bounds.size.y,
		"wrap_origin_x": 0.0,
		"wrap_period_x": wrap_period_x,
		"neighbor_indices": nb,
		"water_terrain_ids": baker._phys_water_ids_cache,
		"land_lf_mountain": int(LandformType.LF.MOUNTAIN),
		"land_lf_peak": int(LandformType.LF.PEAK),
		"land_lf_hill": int(LandformType.LF.HILL),
		"days_per_year": days_per_year,
		"axial_tilt_deg": axial_tilt,
	}
	if profile != null:
		baker._phys_knobs_base_wind["wind_response_rate"] = profile.wind_response_rate
		baker._phys_knobs_base_wind["wind_max_turn_deg_per_day"] = profile.wind_max_turn_deg_per_day
		baker._phys_knobs_base_wind["wind_min_flux_for_dir_update"] = profile.wind_min_flux_for_dir_update
		baker._phys_knobs_base_wind["wind_synoptic_amp"] = profile.wind_synoptic_amp
		baker._phys_knobs_base_wind["wind_synoptic_period_days"] = profile.wind_synoptic_period_days
		baker._phys_knobs_base_wind["wind_belt_only_debug"] = profile.wind_belt_only_debug
		# NS 化(plan/NS化气候动力学四方向深化):动量/轨迹表/散度阻尼 gate,默认全关。
		baker._phys_knobs_base_wind["wind_momentum_advect_w"] = profile.wind_momentum_advect_w
		baker._phys_knobs_base_wind["wind_momentum_diffuse_w_daily"] = profile.wind_momentum_diffuse_w_daily
		baker._phys_knobs_base_wind["wind_traj_table_enabled"] = profile.wind_traj_table_enabled
		baker._phys_knobs_base_wind["wind_traj_pos_scale"] = profile.wind_traj_pos_scale
		baker._phys_knobs_base_wind["wind_traj_dt_days"] = profile.wind_traj_dt_days
		baker._phys_knobs_base_wind["wind_traj_weather_share"] = profile.wind_traj_weather_share
		baker._phys_knobs_base_wind["wind_div_damp_alpha"] = profile.wind_div_damp_alpha
		baker._phys_knobs_base_wind["thermal_monsoon_enabled"] = profile.thermal_monsoon_enabled
		baker._phys_knobs_base_wind["thermal_monsoon_lat_limit"] = profile.thermal_monsoon_lat_limit
		baker._phys_knobs_base_wind["thermal_monsoon_deadband"] = profile.thermal_monsoon_deadband
		baker._phys_knobs_base_wind["thermal_monsoon_full_contrast"] = profile.thermal_monsoon_full_contrast
		baker._phys_knobs_base_wind["thermal_monsoon_gain"] = profile.thermal_monsoon_gain
		baker._phys_knobs_base_wind["thermal_monsoon_breeze_floor"] = profile.thermal_monsoon_breeze_floor
	# ── PSI base（变化：wind_x_arr / wind_y_arr / wind_speed_arr）
	baker._phys_knobs_base_psi = {
		"sea_level": 0.42,
		"ocean_depth_ref": 0.12,
		"n_cells": n_cells,
		"hex_size": hex_size,
		"world_bounds_pos_y": bounds.position.y,
		"world_bounds_size_y": bounds.size.y,
		"neighbor_indices": nb,
		"water_terrain_ids": baker._phys_water_ids_cache,
		"psi_total_iters": baker._PHYS_PSI_TOTAL_ITERS,
		"psi_warm_start": bool(profile.get("psi_warm_start")) if profile != null and profile.get("psi_warm_start") != null else true,
		"psi_early_exit_mode": str(profile.get("psi_early_exit_mode")) if profile != null and profile.get("psi_early_exit_mode") != null else "perf",
		"psi_sor_omega": 1.4,
		"psi_r_base": 0.18,
		"psi_beta_floor": 0.05,
		"psi_source_scale": float(profile.get("ocean_psi_source_scale")) if profile != null and profile.get("ocean_psi_source_scale") != null else 0.06,
		"ocean_current_scale": float(profile.get("ocean_current_scale")) if profile != null and profile.get("ocean_current_scale") != null else 0.13,
		"ocean_current_max_magnitude": float(profile.get("ocean_current_max_magnitude")) if profile != null and profile.get("ocean_current_max_magnitude") != null else 0.65,
		"thermohaline_weight": 0.12,
		"upwelling_highlat_abs": 0.75,
		"cold_sink_temp": cold_sink_temp,
	}
	if profile != null:
		baker._phys_knobs_base_psi["ocean_current_response_rate"] = profile.ocean_current_response_rate
		baker._phys_knobs_base_psi["ocean_thermal_current_weight"] = profile.ocean_thermal_current_weight
		baker._phys_knobs_base_psi["ocean_density_cold_weight"] = profile.ocean_density_cold_weight
		baker._phys_knobs_base_psi["ocean_density_ice_weight"] = profile.ocean_density_ice_weight
		# NS 化 Phase 4(plan/NS化气候动力学四方向深化):地形转向 + 旋度深度衰减,默认全关。
		baker._phys_knobs_base_psi["ocean_topo_steer_w"] = profile.ocean_topo_steer_w
		baker._phys_knobs_base_psi["ocean_depth_curl_damp"] = profile.ocean_depth_curl_damp
	if cfg != null and "sea_level" in cfg:
		baker._phys_knobs_base_psi["sea_level"] = float(cfg.sea_level)
	# ── UPWELLING base（全常量，可直接复用，无需 duplicate）
	baker._phys_knobs_base_up = {
		"upwelling_ekman_gain": 0.6,
		"upwelling_cold_sink_gain": 0.15,
		"upwelling_highlat_abs": 0.75,
		"stage": "upwelling",
		"n_cells": n_cells,
		"neighbor_indices": nb,
		"water_terrain_ids": baker._phys_water_ids_cache,
		"world_bounds_pos_y": bounds.position.y,
		"world_bounds_size_y": bounds.size.y,
		"cold_sink_temp": cold_sink_temp,
	}


static func _physical_cell_slice_enabled(baker: MapBaker, profile: ClimateProfile) -> bool:
	return cell_slice_enabled(baker, profile)


static func _physical_cell_slice_divisor(baker: MapBaker, profile: ClimateProfile) -> int:
	return cell_slice_divisor(baker, profile)


static func _bake_initial_physical_circulation(baker: MapBaker, map: MapData, world: WorldData, hex_size: float, cfg: MapConfig) -> void:
	baker._initial_physical_deferred = false
	if not baker._use_physical_circulation(cfg):
		return
	# B8 P2：物理 knob base 在 bake 期就建好，而不是等第一次 _physical_solve_step_one。
	# 否则「物理求解被策略门挡住」的存档里 MapGenerator 拿不到标量，worker 侧物理
	# prepass 永远判未就绪（实测 soak day1 ready=0 missing=physics_knobs）。
	if map != null and world != null:
		var bake_profile: ClimateProfile = cfg.climate_profile if cfg != null else baker._climate_profile
		baker._phys_ensure_knob_cache(map, hex_size, world.world_bounds, bake_profile, cfg)
	var ext_ready_now: bool = baker._world_ext != null and map != null and map.has_indices() and map.has_soa()
	if not ext_ready_now and ClassDB.class_exists("DCWorldExt"):
		baker._initial_physical_deferred = true
		baker._pending_currents_buf = PackedByteArray()
		baker._pending_upwelling_buf = PackedByteArray()
		baker._pending_upwelling_mask = PackedByteArray()
		baker._pending_upwelling_row_built = PackedByteArray()
		baker._pending_wind_buf = PackedByteArray()
		baker._pending_size = Vector2i.ZERO
		baker._pending_phys_solved_phase = NAN
		baker._pending_psi_state = null
		baker._phys_stage = baker._PHYS_STAGE_NONE
		baker._phys_psi_iters_done = 0
		baker._phys_wind_raster_idx = 0
		baker._phys_wind_done_by_cpp = false
		print("  physical circulation hex solve: deferred until DCWorldExt bind (ext=%s idx=%s soa=%s)" % [
			str(baker._world_ext != null), str(map != null and map.has_indices()), str(map != null and map.has_soa())
		])
		return
	var t_phys := Time.get_ticks_msec()
	var saved_world_ext = baker._world_ext
	# 若 native 尚未满足安全条件且本平台没有 DCWorldExt 可用于后置刷新，保留旧的
	# GDScript 兜底；否则 ext_ready_now=true 时直接使用已绑定的当前 map slots。
	if not ext_ready_now:
		baker._world_ext = null
	baker._physical_solve_for_phase(map, world, hex_size, cfg, baker._INITIAL_PHYSICAL_SEASON_PHASE)
	baker._world_ext = saved_world_ext
	# Vector atlas was removed; only the per-cell fields are needed before
	# MapData.init_soa_from_bake() mirrors them into SoA.
	baker._pending_currents_buf = PackedByteArray()
	baker._pending_upwelling_buf = PackedByteArray()
	baker._pending_upwelling_mask = PackedByteArray()
	baker._pending_upwelling_row_built = PackedByteArray()
	baker._pending_wind_buf = PackedByteArray()
	baker._pending_size = Vector2i.ZERO
	baker._pending_phys_solved_phase = NAN
	baker._pending_psi_state = null
	baker._phys_stage = baker._PHYS_STAGE_NONE
	baker._phys_psi_iters_done = 0
	baker._phys_wind_raster_idx = 0
	baker._phys_wind_done_by_cpp = false
	print("  physical circulation hex solve: %dms" % (Time.get_ticks_msec() - t_phys))


static func _bake_initial_vector_buffers(baker: MapBaker, map: MapData, world: WorldData, hex_size: float, cfg: MapConfig) -> void:
	if map == null or world == null:
		return
	var t_vec := Time.get_ticks_msec()
	var pix_total: int = world.derived_size.x * world.derived_size.y
	if pix_total <= 0:
		return
	# vector_atlas 已退役 → 跳过逐像素风/洋流光栅（纯视觉）。
	# per-cell 风/洋流求解已在 _bake_initial_physical_circulation / 物理 solve 写入
	# HexCell（气候/天气仿真读它，不读这些像素 buffer），故清空像素 buffer 并提前返回。
	# shader 端固定使用中性风/洋流向量。
	if not DCFeatureFlags.ocean_current_visual_active():
		world.wind_field_buffer = PackedByteArray()
		world.ocean_current_buffer = PackedByteArray()
		world.ocean_upwelling_buffer = PackedByteArray()
		world.ocean_current_flow_tex = null
		print("  wind/ocean pixel buffers: skipped (ocean_current_visual off)")
		return
	if baker._use_physical_circulation(cfg) and baker._initial_physical_deferred:
		world.wind_field_buffer = PackedByteArray()
		world.ocean_current_buffer = PackedByteArray()
		world.ocean_upwelling_buffer = PackedByteArray()
		world.ocean_current_flow_tex = null
		baker._pending_currents_buf = PackedByteArray()
		baker._pending_upwelling_buf = PackedByteArray()
		baker._pending_upwelling_mask = PackedByteArray()
		baker._pending_upwelling_row_built = PackedByteArray()
		baker._pending_wind_buf = PackedByteArray()
		baker._pending_size = Vector2i.ZERO
		print("  wind/ocean/upwelling pixel buffers: deferred until DCWorldExt bind (%dms)" % (Time.get_ticks_msec() - t_vec))
		return
	if baker._use_physical_circulation(cfg):
		baker._ensure_pending_currents_size(world)
		baker._ensure_pending_wind_size(world)
		var wind_raster_done: bool = baker._pending_wind_buf.size() >= pix_total * 2
		var ocean_raster_done: bool = false
		if baker._world_ext != null:
			if not wind_raster_done:
				var wind_ret: Dictionary = baker.run_wind_field_rasterize_full(map, world, cfg)
				wind_raster_done = not bool(wind_ret.get("fallback", true))
			var ocean_ret: Dictionary = baker.run_ocean_field_rasterize_full(map, world, cfg)
			ocean_raster_done = not bool(ocean_ret.get("fallback", true))
		if not wind_raster_done:
			baker._rasterize_wind_slice_from_hex(world, baker._pending_wind_buf, 0, pix_total)
		if not ocean_raster_done:
			baker._rasterize_ocean_current_slice_from_hex(world, baker._pending_currents_buf, 0, pix_total)
		# 方案 B-1：物理路径下不再光栅化 ocean_upwelling_buffer
		# （per-cell SoA / 主视觉路径无消费者，F6 调试由 lazy bake 现场光栅化）。
		world.wind_field_buffer = baker._pending_wind_buf
		world.ocean_current_buffer = baker._pending_currents_buf
		world.ocean_upwelling_buffer = PackedByteArray()
	else:
		world.wind_field_buffer = baker._bake_wind_field(world.world_bounds, world.derived_size, baker._INITIAL_PHYSICAL_SEASON_PHASE)
		world.ocean_current_buffer = baker._bake_ocean_currents(map, hex_size, world, cfg, baker._INITIAL_PHYSICAL_SEASON_PHASE)
		world.ocean_upwelling_buffer = baker._bake_ocean_upwelling(map, hex_size, world, cfg, baker._INITIAL_PHYSICAL_SEASON_PHASE)
	baker._update_ocean_current_flow_texture(world)
	baker._pending_currents_buf = PackedByteArray()
	baker._pending_upwelling_buf = PackedByteArray()
	baker._pending_upwelling_mask = PackedByteArray()
	baker._pending_upwelling_row_built = PackedByteArray()
	baker._pending_wind_buf = PackedByteArray()
	baker._pending_size = Vector2i.ZERO
	baker._pending_phys_solved_phase = NAN
	baker._pending_psi_state = null
	print("  wind/ocean/upwelling pixel buffers: %dms" % (Time.get_ticks_msec() - t_vec))


static func _update_ocean_current_flow_texture(baker: MapBaker, world: WorldData) -> void:
	if world == null:
		return
	var w: int = world.derived_size.x
	var h: int = world.derived_size.y
	var data: PackedByteArray = world.ocean_current_buffer
	if w <= 0 or h <= 0 or data.size() < w * h * 2:
		world.ocean_current_flow_tex = null
		return
	var image := Image.create_from_data(w, h, false, Image.FORMAT_RG8, data)
	image.generate_mipmaps()
	var texture_size_matches := false
	if world.ocean_current_flow_tex != null:
		var texture_size: Vector2 = world.ocean_current_flow_tex.get_size()
		texture_size_matches = int(texture_size.x) == w and int(texture_size.y) == h
	if texture_size_matches:
		world.ocean_current_flow_tex.update(image)
	else:
		world.ocean_current_flow_tex = ImageTexture.create_from_image(image)



static func run_deferred_initial_physical_circulation(baker: MapBaker, map: MapData, world: WorldData, hex_size: float, cfg: MapConfig) -> bool:
	if not baker._initial_physical_deferred:
		return false
	if not baker._use_physical_circulation(cfg):
		baker._initial_physical_deferred = false
		return false
	var t_deferred := Time.get_ticks_msec()
	baker._initial_physical_deferred = false
	baker._physical_solve_for_phase(map, world, hex_size, cfg, baker._INITIAL_PHYSICAL_SEASON_PHASE)
	baker._bake_initial_vector_buffers(map, world, hex_size, cfg)
	world.vector_atlas_tex = null
	world.upwelling_tex = null
	baker._pending_currents_buf = PackedByteArray()
	baker._pending_upwelling_buf = PackedByteArray()
	baker._pending_upwelling_mask = PackedByteArray()
	baker._pending_upwelling_row_built = PackedByteArray()
	baker._pending_wind_buf = PackedByteArray()
	baker._pending_size = Vector2i.ZERO
	baker._pending_phys_solved_phase = NAN
	baker._pending_psi_state = null
	baker._phys_stage = baker._PHYS_STAGE_NONE
	baker._phys_psi_iters_done = 0
	baker._phys_wind_raster_idx = 0
	baker._phys_wind_done_by_cpp = false
	print("[physical_init] deferred native refresh complete: %dms" % (Time.get_ticks_msec() - t_deferred))
	return true

## bake_world 推迟下来的首次 per-cell LUT 编码。调用点必须满足两个条件：
## DCWorldExt 已 bind（否则 encode_cell_luts 仍会退回 GDScript），且早于渲染器
## 读取 lut 纹理（即 generate() 返回之前）。
## 迷雾 A 通道此刻仍是全知 255 —— 真实 fog_k 要等玩家国家确定后由
## refresh_country_visuals 重烘，这与推迟之前的行为一致。

static func run_deferred_initial_cell_luts(baker: MapBaker, map: MapData, world: WorldData) -> Dictionary:
	if not baker._initial_cell_luts_deferred:
		return {"ok": false, "reason": "not_deferred"}
	baker._initial_cell_luts_deferred = false
	if map == null or world == null:
		push_error("[cell_lut] deferred encode skipped: map/world missing")
		return {"ok": false, "reason": "missing_map_or_world"}
	var t_lut := Time.get_ticks_msec()
	baker._ensure_cell_lut_dims(map, world)
	var report: Dictionary = baker.bake_cell_luts(map, world)
	var path: String = String(report.get("lut_encode_path", "none"))
	if path != "gdext" or bool(report.get("fallback", true)):
		# 已经 bind 过还没走成 C++，说明方法缺失或入参不合法。按 dots-total-cpp
		# 纪律显式报错，不让 GDScript 结果静默顶替。
		push_error("[cell_lut] deferred encode did not use C++ (path=%s reason=%s)" % [
			path, String(report.get("reason", ""))])
	else:
		print("[cell_lut] deferred encode: %dms path=gdext" % (Time.get_ticks_msec() - t_lut))
	return report

static func set_world_ext(baker: MapBaker, ext) -> void:
	# Fix #4 (2026-06-15)：enum_atlas_upload_system / enum_atlas_upload_job 每个
	# slice 都 re-inject 同一个 ext 对象，之前会把所有 diag counter 清零，
	# 导致 upwelling/DIAG#1 在 log 里出现 225 次（每个 ext 注入重置 → 每 round
	# 又打 8 行）。同 ext re-inject 不动 counter。
	if baker._world_ext == ext:
		return
	baker._world_ext = ext
	# DOTS-Final-Push 后续诊断：启动期烘焙阶段 _world_ext 还是 null（注入晚于
	# bake_world），所以 once-only 诊断旗标在启动期就被消耗（打印过 ext=false /
	# wind_cpp=false 的诊断，对运行期参考价值有限）。注入 _world_ext 时重置这些
	# 旗标，让运行期 SUS 第一次进 stage 2/6 时重新打印一次真实路径决策。
	baker._wind_b_first_run_logged = false
	baker._wind_b_path_log_count = 0
	baker._wind_b_commit_diag_count = 0
	baker._slp_path_log_count = 0
	baker._slp_commit_diag_count = 0
	baker._slp_rt_diag_count = 0
	baker._psi_path_log_count = 0
	baker._psi_commit_diag_count = 0
	baker._upwelling_path_logged = false
	baker._upwelling_diag_count = 0
	baker._sea_ice_path_logged = false

## DOTS-Final-Push 修复：注入 ClimateProfile 引用，让 sea_ice / albedo / veg_dyn /
## feedback 等 C++ hook 能通过 `_climate_profile` 直接读 flag，不再走错误的
## `world.get("config")` 路径。
