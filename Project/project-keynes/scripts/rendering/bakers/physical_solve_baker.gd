extends RefCounted
class_name DCPhysicalSolveBaker

const PhysicalStep = preload("res://scripts/rendering/bakers/physical_solve_step.gd")

const PhysCircSolverScript = preload("res://scripts/rendering/physical_circulation_solver.gd")





static func _physical_solve_step_one(baker: MapBaker, map: MapData, world: WorldData, hex_size: float,
		cfg: MapConfig, season_phase: float, solve_ocean: bool = true) -> bool:
	return PhysicalStep._physical_solve_step_one(baker, map, world, hex_size, cfg, season_phase, solve_ocean)


static func _physical_solve_for_phase(baker: MapBaker, map: MapData, world: WorldData, hex_size: float,
		cfg: MapConfig, season_phase: float) -> void:
	if world == null or map == null:
		return
	if not is_nan(baker._pending_phys_solved_phase) and absf(baker._pending_phys_solved_phase - season_phase) < 0.001:
		return
	var t0_total := Time.get_ticks_msec()
	# dots-total-cpp step3（2026-06-25）：一次性路径优先走 C++ orchestrator
	# run_physical_solve_pass（SLP→wind→PSI→upwelling 全在 C++ 进程内串完，中间量不跨语言）。
	# 仅本"原子完成"入口走它；运行期逐帧分摊路径（_physical_solve_step_one 被 job 驱动）不受影响。
	# 失败（ext/方法缺失、未 bind、任一 sub-pass fallback、!heat_transport、NaN）→ 回退原 loop。
	if baker._physical_solve_native_oneshot(map, world, hex_size, cfg, season_phase):
		baker._pending_phys_solved_phase = season_phase
		baker._phys_stage = baker._PHYS_STAGE_DONE
		var total_ms_oneshot := Time.get_ticks_msec() - t0_total
		if total_ms_oneshot > 25:
			push_warning("PhysicalCirculation solve@phase=%.2f total=%dms (C++ one-shot) — exceeds 25ms soft budget" % [season_phase, total_ms_oneshot])
		else:
			print("PhysicalCirculation solve@phase=%.2f total=%dms (C++ one-shot run_physical_solve_pass)" % [season_phase, total_ms_oneshot])
		return
	# 一次性路径必须从干净状态起步，避免和切片路径残留的 _phys_stage 冲突。
	baker.reset_physical_solve_state()
	var stage_ms: Dictionary = {}  # stage_idx -> ms（diagnostic）
	var stage_t0: int = Time.get_ticks_msec()
	var prev_stage: int = baker._phys_stage
	while not baker._physical_solve_step_one(map, world, hex_size, cfg, season_phase):
		# 在每个 stage 切换处采样一次，方便日志比对老的 slp/wind/psi/up 拆分。
		if baker._phys_stage != prev_stage:
			stage_ms[prev_stage] = Time.get_ticks_msec() - stage_t0
			stage_t0 = Time.get_ticks_msec()
			prev_stage = baker._phys_stage
	stage_ms[prev_stage] = Time.get_ticks_msec() - stage_t0

	var total_ms := Time.get_ticks_msec() - t0_total
	var msg := "PhysicalCirculation solve@phase=%.2f total=%dms (slp=%dms wind=%dms psi=%dms finalize=%dms upwelling=%dms wind_raster=%dms)" % [
		season_phase, total_ms,
		int(stage_ms.get(baker._PHYS_STAGE_SLP, 0)),
		int(stage_ms.get(baker._PHYS_STAGE_WIND, 0)),
		int(stage_ms.get(baker._PHYS_STAGE_PSI_INIT, 0)) + int(stage_ms.get(baker._PHYS_STAGE_PSI_ITERS, 0)),
		int(stage_ms.get(baker._PHYS_STAGE_PSI_FINALIZE, 0)),
		int(stage_ms.get(baker._PHYS_STAGE_UPWELLING, 0)),
		int(stage_ms.get(baker._PHYS_STAGE_WIND_RASTER, 0)),
	]
	if total_ms > 25:
		push_warning("%s — exceeds 25ms soft budget" % msg)
	else:
		print(msg)

# dots-total-cpp step3（2026-06-25）：生成期物理环流一次性 C++ orchestrator wrapper。
# 构造 combined knobs（SLP+wind+PSI+upwelling 四 stage 输入并集，chained 键 slp_arr/
# wind_*_arr/stage 由 C++ 内部注入），一次调 run_physical_solve_pass 跑完全部 kernel，
# 再用 phys_field_nan_guard 复刻 WIND_RASTER 的 NaN 守门。风场 RG8 光栅化仍由后续
# _bake_initial_vector_buffers 完成（本 wrapper 不碰 _pending_wind_buf）。
# 返回 true=全程 C++ 成功；false=ext/方法缺失、未 bind、任一 sub-pass fallback、
# !heat_transport（需 GDScript ocean fallback）、NaN → caller 回退原 step_one loop。

static func _physical_solve_native_oneshot(baker: MapBaker, map: MapData, world: WorldData, hex_size: float,
		cfg: MapConfig, season_phase: float) -> bool:
	if baker._world_ext == null or not baker._world_ext.has_method("run_physical_solve_pass"):
		return false
	if map == null or not map.has_indices():
		return false
	var profile: ClimateProfile = cfg.climate_profile if cfg != null else null
	# !heat_transport 配置走 GDScript ocean fallback（C++ 无等价）→ 不用一次性路径。
	var heat_transport: bool = profile.enable_ocean_heat_transport if profile != null else true
	if not heat_transport:
		return false
	var cells: Array = map.iter_cells()
	var n: int = cells.size()
	if n <= 0:
		return false
	var nb_idx: PackedInt32Array = map.neighbor_indices_packed()
	if nb_idx.size() < n * 6:
		return false

	var bounds: Rect2 = world.world_bounds
	if bounds.size.y <= 0.001:
		return false
	var terrain_aware: bool = profile.enable_terrain_aware_wind if profile != null else true
	var days_per_year_phys: int = baker._calendar_days_per_year(profile)
	var sim_day_phys: int = baker._phys_resolve_abs_sim_day(season_phase, days_per_year_phys)
	var world_seed_phys: int = int(world.bake_seed)
	var cold_sink_temp: float = -0.05
	if cfg != null and "COLD_SINK_TEMP" in cfg:
		cold_sink_temp = float(cfg.COLD_SINK_TEMP)

	# water_terrain_ids（与 PhysicalCirculationSolver._is_water_terrain 1:1，4 stage 共用）
	var water_ids := PackedByteArray()
	water_ids.append(int(TerrainType.TERRAIN.OCEAN))
	water_ids.append(int(TerrainType.TERRAIN.COAST))
	water_ids.append(int(TerrainType.TERRAIN.REEF))
	water_ids.append(int(TerrainType.TERRAIN.KELP))

	# prev_slp_arr（SLP response_rate 混合用）；缺失时 C++ 自有兜底。
	var prev_slp: PackedFloat32Array = map.slp_arr if map.slp_arr.size() == n else PackedFloat32Array()

	# combined knobs = 四 stage 输入并集（chained 键 slp_arr / wind_*_arr / stage 不传，C++ 注入）。
	var knobs := {
		# 共用
		"n_cells": n,
		"hex_size": hex_size,
		"season_phase": season_phase,
		"world_bounds_pos_y": bounds.position.y,
		"world_bounds_size_y": bounds.size.y,
		"wrap_origin_x": 0.0,
		"wrap_period_x": HexUtils.wrap_period_cell_pos_x(map.width),
		"neighbor_indices": nb_idx,
		"water_terrain_ids": water_ids,
		"days_per_year": days_per_year_phys,
		"sim_day": sim_day_phys,
		"world_seed": world_seed_phys,
		"axial_tilt_deg": profile.axial_tilt_deg if profile != null else 23.5,
		# orchestrator 控制标志
		"heat_transport": heat_transport,
		"solve_ocean": true,
		"terrain_aware": (1 if terrain_aware else 0),
		# SLP
		"smooth_passes": 1,
		"prev_slp_arr": prev_slp,
		"slp_lat_amp": 0.16,
		"slp_land_amp": 0.55,
		"slp_water_damp": 0.20,
		"slp_interior_boost": 1.30,
		"slp_coast_damp": 0.60,
		"slp_target_p95": 0.18,
		"insolation_daylen_amp": profile.insolation_daylen_amp if profile != null else 0.35,
		# wind
		"land_lf_mountain": int(LandformType.LF.MOUNTAIN),
		"land_lf_peak": int(LandformType.LF.PEAK),
		"land_lf_hill": int(LandformType.LF.HILL),
		"wind_elapsed_days": baker._phys_take_wind_elapsed_days(sim_day_phys),
		# PSI
		"psi_total_iters": baker._PHYS_PSI_TOTAL_ITERS,
		"psi_warm_start": bool(profile.psi_warm_start) if profile != null and profile.get("psi_warm_start") != null else true,
		"psi_early_exit_mode": str(profile.psi_early_exit_mode) if profile != null and profile.get("psi_early_exit_mode") != null else "perf",
		"psi_sor_omega": 1.4,
		"psi_r_base": 0.18,
		"psi_beta_floor": 0.05,
		"psi_source_scale": float(profile.ocean_psi_source_scale) if profile != null and profile.get("ocean_psi_source_scale") != null else 0.06,
		"ocean_current_scale": float(profile.ocean_current_scale) if profile != null and profile.get("ocean_current_scale") != null else 0.13,
		"ocean_current_max_magnitude": float(profile.ocean_current_max_magnitude) if profile != null and profile.get("ocean_current_max_magnitude") != null else 0.65,
		"thermohaline_weight": 0.12,
		"upwelling_highlat_abs": 0.75,
		"cold_sink_temp": cold_sink_temp,
		# upwelling
		"stage": "upwelling",
	}
	if profile != null:
		# SLP profile knobs
		knobs["wind_thermal_slp_weight"] = profile.wind_thermal_slp_weight
		knobs["slp_ice_high_weight"] = profile.slp_ice_high_weight
		knobs["slp_snow_high_weight"] = profile.slp_snow_high_weight
		knobs["slp_response_rate"] = profile.slp_response_rate
		knobs["slp_synoptic_amp"] = profile.slp_synoptic_amp
		knobs["slp_moist_low_weight"] = profile.slp_moist_low_weight
		knobs["wind_synoptic_period_days"] = profile.wind_synoptic_period_days
		# wind profile knobs
		knobs["wind_response_rate"] = profile.wind_response_rate
		knobs["wind_max_turn_deg_per_day"] = profile.wind_max_turn_deg_per_day
		knobs["wind_min_flux_for_dir_update"] = profile.wind_min_flux_for_dir_update
		knobs["wind_synoptic_amp"] = profile.wind_synoptic_amp
		knobs["wind_belt_only_debug"] = profile.wind_belt_only_debug
		# PSI profile knobs
		knobs["ocean_current_response_rate"] = profile.ocean_current_response_rate
		knobs["ocean_thermal_current_weight"] = profile.ocean_thermal_current_weight
		knobs["ocean_density_cold_weight"] = profile.ocean_density_cold_weight
		knobs["ocean_density_ice_weight"] = profile.ocean_density_ice_weight

	# refresh slot 缓存，确保 kernel 读到最新 map 状态（镜像 upwelling stage 的 refresh_slots_from_map）。
	if baker._world_ext.has_method("refresh_slots_from_map"):
		baker._world_ext.refresh_slots_from_map()
	var rep: Dictionary = baker._world_ext.run_physical_solve_pass(knobs)
	if rep == null or typeof(rep) != TYPE_DICTIONARY or bool(rep.get("fallback", true)):
		if baker._phys_solve_rt_diag_count < 24:
			baker._phys_solve_rt_diag_count += 1
			print("[phys_solve][oneshot] fallback reason=%s → 回退 step_one loop" % (
				String(rep.get("reason", "?")) if rep != null and typeof(rep) == TYPE_DICTIONARY else "null"))
		return false

	# NaN/Inf 守门（复刻 WIND_RASTER stage）：异常时回退 loop（其内含 ny-only 覆写）。
	if baker._world_ext.has_method("phys_field_nan_guard"):
		var n_bad: int = int(baker._world_ext.phys_field_nan_guard())
		if n_bad > 0:
			push_warning("[phys_solve][oneshot] phys_field_nan_guard=%d → 回退 step_one loop（含 NaN 覆写）" % n_bad)
			return false

	print("[phys_solve][oneshot] OK slp=%.2fms wind=%.2fms psi=%.2fms(ran=%s) upwelling=%.2fms total=%.2fms" % [
		float(rep.get("slp_ms", -1.0)), float(rep.get("wind_ms", -1.0)),
		float(rep.get("psi_ms", -1.0)), str(bool(rep.get("psi_ran", false))),
		float(rep.get("upwelling_ms", -1.0)), float(rep.get("elapsed_ms", -1.0))])
	return true

# 确保 _pending_wind_buf 已按 W×H×2 字节就位（PackedByteArray 不在 size 一致时
# 强制重分配，避免 GC 压力）。WIND_RASTER 阶段的第一次 step 调一次。

static func _ensure_pending_wind_size(baker: MapBaker, world: WorldData) -> void:
	var W := world.derived_size.x
	var H := world.derived_size.y
	var need: int = W * H * 2
	if baker._pending_wind_buf.size() != need:
		baker._pending_wind_buf = PackedByteArray()
		baker._pending_wind_buf.resize(need)

# 把 cell.wind_vector 量化进区间 [s, e)（按像素索引）。s 必须是非负，e ≤ W*H。
# 用 pixel_to_cell_lookup 直接查最近 hex，无 cube_round 成本。
# wind_vector 是单位方向；RG8 写入 dir * wind_speed_norm，让 shader length() 表示风速。
# L: 同 ocean_current_slice，同步写持久 _vector_atlas_data 的 BA 通道（[idx*4+2, idx*4+3]）。

static func _rasterize_wind_slice_from_hex(baker: MapBaker, world: WorldData, buf: PackedByteArray,
		s: int, e: int) -> void:
	if buf.is_empty() or s >= e:
		return
	var W := world.derived_size.x
	var H := world.derived_size.y
	var lookup: Array = world.pixel_to_cell_lookup
	var has_lookup: bool = lookup.size() == W * H
	var atlas_valid: bool = (baker._vector_atlas_data_size == Vector2i(W, H) \
			and baker._vector_atlas_data.size() == W * H * 4)
	for i in range(s, e):
		var cell: HexCell = null
		if has_lookup:
			cell = lookup[i]
		var wx: float = 1.0
		var wy: float = 0.0
		if cell != null:
			var wind_speed_norm: float = clampf(cell.wind_speed / 1.7, 0.0, 1.0)
			wx = cell.wind_vector.x * wind_speed_norm
			wy = cell.wind_vector.y * wind_speed_norm
		var bx: int = clampi(int(round((wx * 0.5 + 0.5) * 255.0)), 0, 255)
		var by: int = clampi(int(round((wy * 0.5 + 0.5) * 255.0)), 0, 255)
		buf[i * 2]     = bx
		buf[i * 2 + 1] = by
		if atlas_valid:
			baker._vector_atlas_data[i * 4 + 2] = bx
			baker._vector_atlas_data[i * 4 + 3] = by

# 一次性版本（bake_world / rebake_ocean_currents 用）：直接全图写入 _pending_wind_buf
# 并返回它。等价于多次调 _rasterize_wind_slice_from_hex 拼成全图。

static func _rasterize_wind_field_from_hex(baker: MapBaker, map: MapData, world: WorldData) -> PackedByteArray:
	baker._ensure_pending_wind_size(world)
	var W := world.derived_size.x
	var H := world.derived_size.y
	baker._rasterize_wind_slice_from_hex(world, baker._pending_wind_buf, 0, W * H)
	return baker._pending_wind_buf

# L: 从 world.ocean_current_buffer / wind_field_buffer 一次性拼出 RGBA8 交错缓冲。
# fallback 路径（缓存未就绪）的 commit 末尾调一次，让下一次 commit 走 fast path。
# 之后 pixel slices 在写 _pending_currents_buf / _pending_wind_buf 时同步维护此 buf。

static func _rebuild_vector_atlas_data_from_buffers(baker: MapBaker, world: WorldData) -> void:
	if world == null:
		return
	var W: int = world.derived_size.x
	var H: int = world.derived_size.y
	var n: int = W * H
	var need: int = n * 4
	if baker._vector_atlas_data.size() != need:
		baker._vector_atlas_data = PackedByteArray()
		baker._vector_atlas_data.resize(need)
	baker._vector_atlas_data_size = Vector2i(W, H)
	var ocean_buf: PackedByteArray = world.ocean_current_buffer
	var wind_buf: PackedByteArray = world.wind_field_buffer
	var has_ocean: bool = ocean_buf.size() >= n * 2
	var has_wind: bool = wind_buf.size() >= n * 2
	for i in range(n):
		var di: int = i * 4
		var oi: int = i * 2
		baker._vector_atlas_data[di]     = ocean_buf[oi]     if has_ocean else 128
		baker._vector_atlas_data[di + 1] = ocean_buf[oi + 1] if has_ocean else 128
		baker._vector_atlas_data[di + 2] = wind_buf[oi]      if has_wind else 128
		baker._vector_atlas_data[di + 3] = wind_buf[oi + 1]  if has_wind else 128

# 把 cell.ocean_current 量化进 RG8 像素区间 [s, e)。陆地像素填中性 (128, 128) = 零向量。
# L: 同步把 RG 写到持久 _vector_atlas_data 的 [idx*4, idx*4+1] 通道（若 size 已就绪），
# 让 commit_ocean_buffers 直接 Image.create_from_data(_vector_atlas_data) + tex.update，
# 省掉 620k × 4 字节的全图交错循环（30-50ms → memcpy）。

static func _rasterize_ocean_current_slice_from_hex(baker: MapBaker, world: WorldData, dst: PackedByteArray,
		s: int, e: int) -> void:
	var lookup: Array = world.pixel_to_cell_lookup
	var W := world.derived_size.x
	var H := world.derived_size.y
	var has_lookup: bool = lookup.size() == W * H
	var atlas_valid: bool = (baker._vector_atlas_data_size == Vector2i(W, H) \
			and baker._vector_atlas_data.size() == W * H * 4)
	for i in range(s, e):
		var cell: HexCell = null
		if has_lookup:
			cell = lookup[i]
		var cur_x: float = 0.0
		var cur_y: float = 0.0
		if cell != null and baker._is_water(int(cell.terrain)):
			cur_x = cell.ocean_current.x
			cur_y = cell.ocean_current.y
		var bx: int = clampi(int(round((cur_x * 0.5 + 0.5) * 255.0)), 0, 255)
		var by: int = clampi(int(round((cur_y * 0.5 + 0.5) * 255.0)), 0, 255)
		dst[i * 2]     = bx
		dst[i * 2 + 1] = by
		if atlas_valid:
			baker._vector_atlas_data[i * 4]     = bx
			baker._vector_atlas_data[i * 4 + 1] = by

# 把 cell.upwelling_strength 量化进 R8 像素区间 [s, e)。陆地填 128（中性）。
# 编码：strength ∈ [-1, 1] → byte ∈ [0, 255]，128 = 0；255 = +1（满上升）；0 = -1（满下沉）。
# 与现有 _bake_ocean_upwelling 的编码契约一致（虽然旧路径只用 [128, 255] 半区上升 +
# [0, 128] 半区下沉，新路径继续遵守）。

static func _rasterize_upwelling_slice_from_hex(baker: MapBaker, world: WorldData, dst: PackedByteArray,
		s: int, e: int) -> void:
	var lookup: Array = world.pixel_to_cell_lookup
	var W := world.derived_size.x
	var H := world.derived_size.y
	var has_lookup: bool = lookup.size() == W * H
	for i in range(s, e):
		var cell: HexCell = null
		if has_lookup:
			cell = lookup[i]
		if cell == null or not baker._is_water(int(cell.terrain)):
			dst[i] = 128
			continue
		var up: float = clampf(cell.upwelling_strength, -1.0, 1.0)
		dst[i] = clampi(int(round(128.0 + 127.0 * up)), 0, 255)


# ─── DOTS-Total-CPP（plan/dots-total-cpp 任务 4+5）────────────────────────
# Ocean rasterize 一次性 hex→pixel byte 直出 — 替代 _rasterize_ocean_current_slice_from_hex
# + _rasterize_upwelling_slice_from_hex 的 17 个 pixel slice。

# 洋流像素索引按地图、绘制目标和尺寸缓存，与 sea_ice 缓存独立。

static func _ensure_ocean_pixel_to_cell_index(baker: MapBaker, map: MapData, world: WorldData) -> void:
	var n: int = int(world.derived_size.x) * int(world.derived_size.y)
	var cache_key := [map.get_instance_id(), world.get_instance_id(), world.derived_size]
	if baker._ocean_pixel_cache_key == cache_key and baker._ocean_pixel_to_cell_idx.size() == n:
		return
	baker._ocean_pixel_to_cell_idx = PackedInt32Array()
	baker._ocean_pixel_to_cell_idx.resize(n)
	if world.pixel_owner_indices.size() == n:
		var owners := world.pixel_owner_indices
		var present := world.pixel_owner_present
		for i in range(n):
			baker._ocean_pixel_to_cell_idx[i] = int(owners[i]) if (present.size() <= i or present[i] != 0) else -1
	else:
		var lookup := world.pixel_to_cell_lookup
		for i in range(n):
			var cell = lookup[i] if i < lookup.size() else null
			baker._ocean_pixel_to_cell_idx[i] = map.index_of(cell) if cell != null else -1
	baker._ocean_pixel_cache_key = cache_key


# 一次性把 ocean_current + upwelling SoA 通过 C++ rasterize 量化进
# _pending_currents_buf / _pending_upwelling_buf / _vector_atlas_data。
#
# Sub-slice 支持（plan/ocean-raster-subslice 2026-05-22）：
#   p_start_idx / p_end_idx 缺省 -1 表示"全图一次性"（旧行为）。
#   传入 [s, e) 时仅 raster 该像素区间，配合 OceanCurrentsJob 的多 sub-tick 切片。
#   首片（s==0）做 _ensure_pending_* / refresh_slots_from_map（O(1) check + 一次性
#   slot sync）；后续 sub-slice 跳过这两步，靠 caller 维持 buffer 一致。
# 返回 Dictionary：{ "fallback": bool, "elapsed_ms": float, "pixels": int,
#                  "atlas_updated": bool, "start_idx": int, "end_idx": int }

static func run_ocean_field_rasterize_full(baker: MapBaker, map: MapData, world: WorldData, _cfg: MapConfig,
		p_start_idx: int = -1, p_end_idx: int = -1) -> Dictionary:
	var out := { "fallback": true, "elapsed_ms": -1.0, "pixels": 0, "atlas_updated": false }
	if world == null or map == null:
		out["reason"] = "missing world/map"
		return out
	if baker._world_ext == null:
		out["reason"] = "ext/method missing"
		return out
	# 必须先把 hex 求解推到 DONE — caller 已通过 _physical_solve_step_one 完成。
	# pending_currents / pending_upwelling 缓冲就绪
	baker._ensure_pending_currents_size(world)
	baker._ensure_pending_upwelling_size(world)
	baker._ensure_ocean_pixel_to_cell_index(map, world)

	var W := int(world.derived_size.x)
	var H := int(world.derived_size.y)
	var n_px: int = W * H

	# 解析 sub-slice 区间。负数 / 越界 → 全图。
	var s: int = p_start_idx
	var e: int = p_end_idx
	if s < 0:
		s = 0
	if e < 0 or e > n_px:
		e = n_px
	if s > e:
		s = e
	var is_first_subslice: bool = (s == 0)

	# 同步 DataCoreWorld slots（HexCell facade 已直写 SoA，但保险起见 refresh）
	# 仅首片做：sub-slice 中途 SoA 不应再变（_phase_locked 已固定，hex 求解已 DONE）
	if is_first_subslice:
		baker._world_ext.refresh_slots_from_map()

	# atlas_data fast path：若 _vector_atlas_data 已就位，让 C++ 同步写入
	var atlas_ok: bool = (baker._vector_atlas_data_size == Vector2i(W, H) \
			and baker._vector_atlas_data.size() == n_px * 4)
	var knobs: Dictionary = {
		"n_cells": map.cell_count(),
		"w": W,
		"h": H,
		"pixel_to_cell_idx": baker._ocean_pixel_to_cell_idx,
		"dst_currents": baker._pending_currents_buf,
		"dst_upwelling": baker._pending_upwelling_buf,
		"update_atlas_data": atlas_ok,
		"start_idx": s,
		"end_idx": e,
	}
	if atlas_ok:
		knobs["atlas_data"] = baker._vector_atlas_data
	if not baker._runtime_physics_visual_view.is_empty():
		knobs["physics_read_view"] = baker._runtime_physics_visual_view
	var res: Dictionary = baker._world_ext.run_ocean_field_rasterize(knobs)
	if bool(res.get("fallback", true)) or float(res.get("elapsed_ms", -1.0)) < 0.0:
		out["reason"] = String(res.get("reason", "unknown"))
		return out
	# C++ 端通过 ptrw 已修改 PackedByteArray；Dictionary 共享 ref，赋值即同步。
	baker._pending_currents_buf = knobs["dst_currents"]
	baker._pending_upwelling_buf = knobs["dst_upwelling"]
	if atlas_ok:
		baker._vector_atlas_data = knobs["atlas_data"]
	out["fallback"] = false
	out["elapsed_ms"] = float(res.get("elapsed_ms", 0.0))
	out["pixels"] = int(res.get("pixels", 0))
	out["atlas_updated"] = bool(res.get("atlas_updated", false))
	out["start_idx"] = int(res.get("start_idx", s))
	out["end_idx"] = int(res.get("end_idx", e))
	return out


# ─── DOTS-Total-CPP（A 方案 / wind raster 孪生）─────────────────────────
# Wind rasterize 一次性 hex→pixel byte 直出 — 替代 _rasterize_wind_slice_from_hex
# 在 _PHYS_STAGE_WIND_RASTER 中跑 21 片 × ~87ms 的 GDScript 循环。
# 复用 _ocean_pixel_to_cell_idx 缓存（同一 pixel→cell 映射）。
#
	# Gate：caller 已确认 ext + has_method (use_gdext_ocean_currents_pixel removed in dots-flag-prune-pr1).
# 返回 Dictionary：{ "fallback": bool, "elapsed_ms": float, "pixels": int, "atlas_updated": bool }

static func run_wind_field_rasterize_full(baker: MapBaker, map: MapData, world: WorldData, _cfg: MapConfig) -> Dictionary:
	var out := { "fallback": true, "elapsed_ms": -1.0, "pixels": 0, "atlas_updated": false }
	if world == null or map == null:
		out["reason"] = "missing world/map"
		return out
	if baker._world_ext == null:
		out["reason"] = "ext/method missing"
		return out
	# pending_wind 缓冲就绪
	baker._ensure_pending_wind_size(world)
	# pixel→cell idx 表（与 ocean rasterize 共用同一张表）
	baker._ensure_ocean_pixel_to_cell_index(map, world)

	# 同步 DataCoreWorld slots（HexCell facade 已直写 SoA，但保险起见 refresh）
	baker._world_ext.refresh_slots_from_map()

	var W := int(world.derived_size.x)
	var H := int(world.derived_size.y)
	var n_px: int = W * H
	# atlas_data fast path：若 _vector_atlas_data 已就位，让 C++ 同步写 [+2]/[+3]
	var atlas_ok: bool = (baker._vector_atlas_data_size == Vector2i(W, H) \
			and baker._vector_atlas_data.size() == n_px * 4)
	var knobs: Dictionary = {
		"n_cells": map.cell_count(),
		"w": W,
		"h": H,
		"pixel_to_cell_idx": baker._ocean_pixel_to_cell_idx,
		"dst_wind": baker._pending_wind_buf,
		"update_atlas_data": atlas_ok,
	}
	if atlas_ok:
		knobs["atlas_data"] = baker._vector_atlas_data
	if not baker._runtime_physics_visual_view.is_empty():
		knobs["physics_read_view"] = baker._runtime_physics_visual_view
	var res: Dictionary = baker._world_ext.run_wind_field_rasterize(knobs)
	if bool(res.get("fallback", true)) or float(res.get("elapsed_ms", -1.0)) < 0.0:
		out["reason"] = String(res.get("reason", "unknown"))
		return out
	# C++ 端通过 ptrw 已修改 PackedByteArray；Dictionary 共享 ref，赋值即同步。
	baker._pending_wind_buf = knobs["dst_wind"]
	if atlas_ok:
		baker._vector_atlas_data = knobs["atlas_data"]
	out["fallback"] = false
	out["elapsed_ms"] = float(res.get("elapsed_ms", 0.0))
	out["pixels"] = int(res.get("pixels", 0))
	out["atlas_updated"] = bool(res.get("atlas_updated", false))
	return out
