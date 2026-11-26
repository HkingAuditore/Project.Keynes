extends "res://scripts/simulation/generator_context.gd"

const SeasonRoundPublication = preload("res://scripts/simulation/climate/season_round_publication.gd")

const SeasonNativePasses = preload("res://scripts/simulation/climate/season_native_passes.gd")

const SeasonRound = preload("res://scripts/simulation/climate/season_round_b_plus.gd")

func queue_season_refresh(season_idx: int) -> void:
	_generator._pending_season_idx = clampi(season_idx, 0, 3)
	_generator._pending_season_refresh = true



func has_pending_season_refresh() -> bool:
	return _generator._pending_season_refresh or _generator._season_refresh_in_progress



func begin_pending_season_refresh() -> int:
	_generator._pending_season_refresh = false
	_generator._season_refresh_in_progress = true
	_generator._last_season_refresh_breakdown = {}
	# X2-精简版：round 启动重置 SoA-slots 缓存标志位，让第一个 stage helper 自然触发
	# 唯一一次 refresh_slots_from_map（后续 11 个 stage 共享该次同步）。
	_generator._season_round_slots_fresh = false
	_generator._season_round_slots_skip_count = 0
	_generator._season_round_slots_refresh_count = 0
	return _generator._pending_season_idx


# Periodic-driver entry（慢变量周期重算）。SeasonRefreshSystem 不再依赖
# queue_season_refresh / has_pending_season_refresh 信号；按真实 tick 周期自驱
# 调用本入口启动一个 round。返回当前 WorldClock 的 season_index（仅供 stage 算
# 法 API 兼容；新设计下 stage 1/4/5/6/7/8 等慢变量本身不再绑定到具体季节）。

func begin_periodic_season_refresh() -> int:
	_generator._season_refresh_in_progress = true
	_generator._last_season_refresh_breakdown = {}
	# X2-精简版：同上，重置 round 内 slots 缓存标志位。
	_generator._season_round_slots_fresh = false
	_generator._season_round_slots_skip_count = 0
	_generator._season_round_slots_refresh_count = 0
	var season_idx: int = 0
	if _generator._world_clock_ref != null and _generator._world_clock_ref.has_method("season_index"):
		season_idx = _generator._world_clock_ref.season_index_for_day(floori(_generator._get_runtime_climate_capture().sample_day()))
	_generator._pending_season_idx = clampi(season_idx, 0, 3)
	return _generator._pending_season_idx



func run_season_refresh_stage(map: MapData, world: WorldData, season_idx: int, stage: int) -> void:
	# 12-stage 切片（原 7-stage），把 stage 4 的 4 个生态 pass 与 stage 6 的
	# rebake_biome + consume_feedback 各自独立成 stage。每个 stage 的单帧上界
	# 从原来 ~140ms 降到 ~30ms 量级。SeasonRefreshSystem 的 done 判定按 12 同步。
	#   0: moisture set
	#   1: rain_shadow
	#   2: redecide_terrain
	#   3: river_ecology
	#   4: vegetation_feedback
	#   5: shrubland_pass
	#   6: mangrove_pass
	#   7: glacier_pass
	#   8: swamp_pass
	#   9: sync_current_state
	#  10: rebake_biome_tex_only
	#  11: consume_feedback_buffers
	var t_us0: int = Time.get_ticks_usec()
	var season := clampi(season_idx, 0, 3)
	if stage >= 0 and stage <= 8:
		_generator._last_world = world
		_generator._current_season = season
		_generator._last_season_refresh_breakdown["stage_%d_ms" % stage] = 0.0
		_generator._last_season_refresh_breakdown["stage_%d_path" % stage] = "emergent_noop"
		return
	# DOTS-Total-CPP 真·收尾（2026-05-21）：第一次进入 run_season_refresh_stage 时打一条
	# 启动 banner，让 rebuild 后立刻能看到 ext 引用 / has_method 的真实状态——
	# 这是验证 8 stage 是否能走 gdext 路径的最快诊断。
	# dots-flag-prune-pr1 round 2: use_gdext_season_refresh flag 已删除，banner
	# 只报告 ext + has_method。
	if not _generator._season_stage_path_logged.has("__startup_banner"):
		_generator._season_stage_path_logged["__startup_banner"] = true
		var ext_is_null: bool = _generator._data_core_world_ext == null
		var ext_v: String = "null" if ext_is_null else "ok"
		var method_v: String = "n/a"
		if _generator._data_core_world_ext != null:
			method_v = str(true)
		print("[season_refresh] startup banner: ext=%s has_run_season_refresh_stage=%s"
				% [ext_v, method_v])
	# dots-total-cpp（2026-06-18）：stage 0–8 已在上方（season<=8）early-return 走
	# emergent_noop / B+ C++ round 路径，原本的 GDScript fallback 分支为死代码，已随
	# 生成 GDScript 删除一并清理。此 match 只剩可达的 9 / 10 / 11。
	match stage:
		9:
			if not _generator._run_season_refresh_stage8_gdext(map, world, season):
				push_error("[season_refresh/stage8] native failed; previous fields retained")
		10:
			# stage 10 is a render/upload concern. Queue it instead of blocking
			# the season simulation slice with a full biome atlas rebuild.
			_generator._mark_enum_atlas_dirty(true, true, true)
		11:
			var cp_fb: ClimateProfile = _generator._c()
			if cp_fb != null and bool(cp_fb.fast_slow_layering_enabled):
				# stage 11 (feedback decay) uses the native stage 10 implementation.
				# 注：soil_moisture / vegetation_growth_pressure 现已在 SoA schema
				# （component_schema.gd L109-110），facade getter 自动从 SoA 读取，
				# 因此 in/out 走 map.soil_moisture_arr / vegetation_growth_pressure_arr
				# PackedArray 引用零拷贝传递。
				if not _generator._run_season_refresh_stage11_gdext(map, world, season):
					push_error("[season_refresh/stage11] native failed; previous fields retained")
	var elapsed_ms: float = (Time.get_ticks_usec() - t_us0) / 1000.0
	_generator._last_season_refresh_breakdown["stage_%d_ms" % stage] = elapsed_ms
	# H 诊断：单 stage > 30ms → 直接打点，定位 season_refresh max=128-141ms 的根因 stage。
	if elapsed_ms > 30.0:
		print("  [season_refresh] stage=%d slow=%.1fms (season=%d)" % [stage, elapsed_ms, season])



func run_season_refresh_stage_micro(map: MapData, _world: WorldData, season_idx: int, stage: int, cursor: int) -> Dictionary:
	var out: Dictionary = {
		"handled": false,
		"done": false,
		"cursor": cursor,
		"elapsed_ms": 0.0,
		"work_done": 0,
		"stage_name": "",
	}
	var cp: ClimateProfile = _generator._c()
	if cp == null:
		return out
	var max_usec: int = 550
	if cp.get("sim_slice_budget_ms") != null:
		max_usec = maxi(50, int(round(float(cp.sim_slice_budget_ms) * 1000.0)))
	max_usec = clampi(max_usec, 50, 1000)

	# plan/season-stage4-chunking（2026-05-21）：stage_4_veg_feedback chunk 化。
	# 内部 deadline 必须有 hard cap，否则资源调试预算会把 stage_4 退化为一次跑完 n*3 cell-iter。
	# spike 到 15ms。stage_4 是 11 stage 中最重的（_vegetation_donor_amount × 6 邻居
	# + Vector3i 哈希 + redecide 三段），单 stage 用 ~12ms 时实测会顶到 max_tick。
	const STAGE2_MAX_USEC: int = 1000
	const STAGE3_MAX_USEC: int = 1000
	const STAGE4_MAX_USEC: int = 1000
	if stage == 2:
		var stage2_usec: int = mini(max_usec, STAGE2_MAX_USEC)
		return _run_season_stage2_micro(map, season_idx, cursor, stage2_usec)
	if stage == 3:
		var stage3_usec: int = mini(max_usec, STAGE3_MAX_USEC)
		return _run_season_stage3_micro(map, season_idx, cursor, stage3_usec)
	if stage == 4:
		var stage4_usec: int = mini(max_usec, STAGE4_MAX_USEC)
		return _run_season_stage4_micro(map, season_idx, cursor, stage4_usec)

	if stage != 1:
		return out
	# DOTS-Total-CPP（2026-05-21 真·收尾）：micro-pass 路径补 once-log。
	# 主 switch 的 _run_season_refresh_stage1_gdext 有完整 _season_log_path_once，
	# 但 micro-pass 这条独立路径之前完全静默 → 日志里看不到 stage 1 走哪条。
	# 这里沿用同 helper，stage_key 用 "stage1_micro" 区分主 switch 的 "stage1"。
	# dots-flag-prune-pr1 round 2: use_gdext_season_refresh flag 已删除——恒走 ext +
	# has_method 探测分支。
	if _generator._last_cfg == null or map == null or _generator._data_core_world_ext == null :
		_generator._season_log_path_once("stage1_micro", "gdscript_fallback", "ext/method/map/cfg unavailable (no run_season_refresh_micro_pass)")
		return out
	if not map.has_indices():
		_generator._season_log_path_once("stage1_micro", "gdscript_fallback", "map.has_indices()=false (CSR not baked)")
		return out

	if cursor <= 0:
		_generator._ensure_season_round_slots_fresh()

	var knobs: Dictionary = {
		"stage": stage,
		"cursor": maxi(0, cursor),
		"season": clampi(season_idx, 0, 3),
		"n_cells": map.cell_count(),
		"max_usec": max_usec,
		"neighbor_indices": map.neighbor_indices_packed(),
		"rain_shadow_lookback": int(cp.rain_shadow_lookback),
		"rain_shadow_threshold": float(cp.rain_shadow_threshold),
		"rain_shadow_factor": float(cp.rain_shadow_factor),
	}
	var res: Dictionary = _generator._data_core_world_ext.run_season_refresh_micro_pass(knobs)
	if bool(res.get("fallback", true)):
		if cursor <= 0:
			_generator._season_log_path_once("stage1_micro", "gdscript_fallback", "C++ returned fallback at cursor=0: %s" % str(res.get("reason", "unknown")))
			return out
		# mid-stage fallback：C++ 已经处理了一部分 cursor 但中途放弃；
		# 调用方需要继续走 micro 路径，但本帧没新进度 → handled=true done=false。
		_generator._season_log_path_once("stage1_micro", "gdext_mid_fallback", "C++ mid-stage fallback cursor=%d: %s" % [cursor, str(res.get("reason", "unknown"))])
		push_warning("[season_refresh] micro-pass fallback mid-stage: %s" % str(res.get("reason", "")))
		out["handled"] = true
		out["done"] = false
		return out

	var elapsed_ms: float = float(res.get("elapsed_ms", 0.0))
	var next_cursor: int = int(res.get("cursor", cursor))
	var done: bool = bool(res.get("done", false))
	var stage_name: String = str(res.get("stage_name", "stage_%d" % stage))
	_generator._last_season_refresh_breakdown["stage_%d_path" % stage] = "gdext_micro"
	_generator._last_season_refresh_breakdown["stage_%d_native_ms" % stage] = elapsed_ms
	_generator._last_season_refresh_breakdown["stage_%d_ms" % stage] = elapsed_ms
	_generator._last_season_refresh_breakdown["stage_%d_cursor" % stage] = next_cursor
	# 成功路径 once-log：done=true 时只打一次，未完成时不刷屏（detail 含 done 状态做 dedup key）。
	if done:
		_generator._season_log_path_once("stage1_micro", "gdext", "native_ms=%.3f done=true cursor=%d" % [elapsed_ms, next_cursor])
	else:
		_generator._season_log_path_once("stage1_micro", "gdext", "native_ms=%.3f done=false (chunking)" % elapsed_ms)
	out["handled"] = true
	out["done"] = done
	out["cursor"] = next_cursor
	out["elapsed_ms"] = elapsed_ms
	out["work_done"] = int(res.get("touched", 0))
	out["stage_name"] = stage_name
	return out



func _run_season_stage2_micro(map: MapData, season_idx: int, cursor: int, _max_usec: int) -> Dictionary:
	var out: Dictionary = {
		"handled": true,
		"done": false,
		"cursor": maxi(0, cursor),
		"elapsed_ms": 0.0,
		"work_done": 0,
		"stage_name": "stage_2_redecide",
	}
	if map == null or _generator._last_cfg == null:
		out["done"] = true
		return out
	if cursor != 0:
		push_error("[season_refresh/stage2] native continuation is unavailable; previous fields retained")
		out["done"] = true
		out["failed"] = true
		return out
	var started_us: int = Time.get_ticks_usec()
	var season: int = clampi(season_idx, 0, 3)
	if _generator._run_season_refresh_stage2_gdext(map, null, season):
		var n_total: int = map.cell_count() if map.has_indices() else map.all_cells().size()
		out["done"] = true
		out["cursor"] = n_total
		out["elapsed_ms"] = (Time.get_ticks_usec() - started_us) / 1000.0
		out["work_done"] = n_total
		return out
	push_error("[season_refresh/stage2] native failed; previous fields retained")
	out["done"] = true
	out["failed"] = true
	return out


func _run_season_stage3_micro(map: MapData, season_idx: int, cursor: int, _max_usec: int) -> Dictionary:
	var out: Dictionary = {
		"handled": true,
		"done": false,
		"cursor": maxi(0, cursor),
		"elapsed_ms": 0.0,
		"work_done": 0,
		"stage_name": "stage_3_river",
	}
	if map == null or _generator._last_cfg == null:
		out["done"] = true
		return out
	if cursor != 0:
		push_error("[season_refresh/stage3] native continuation is unavailable; previous fields retained")
		out["done"] = true
		out["failed"] = true
		return out
	var started_us: int = Time.get_ticks_usec()
	if _generator._run_season_refresh_stage3_gdext(map, null, clampi(season_idx, 0, 3)):
		var n_total: int = map.cell_count() if map.has_indices() else map.all_cells().size()
		out["done"] = true
		out["cursor"] = n_total
		out["elapsed_ms"] = (Time.get_ticks_usec() - started_us) / 1000.0
		out["work_done"] = n_total
		return out
	push_error("[season_refresh/stage3] native failed; previous fields retained")
	out["done"] = true
	out["failed"] = true
	return out


func _run_season_stage4_micro(map: MapData, season_idx: int, cursor: int, _max_usec: int) -> Dictionary:
	var out: Dictionary = {
		"handled": true,
		"done": false,
		"cursor": maxi(0, cursor),
		"elapsed_ms": 0.0,
		"work_done": 0,
		"stage_name": "stage_4_veg_feedback",
	}
	if map == null or _generator._last_cfg == null:
		out["done"] = true
		return out
	if cursor != 0:
		push_error("[season_refresh/stage4] native continuation is unavailable; previous fields retained")
		out["done"] = true
		out["failed"] = true
		return out
	var started_us: int = Time.get_ticks_usec()
	if _generator._run_season_refresh_stage4_gdext(map, null, clampi(season_idx, 0, 3)):
		var n_total: int = map.cell_count() if map.has_indices() else map.all_cells().size()
		var cursor_done: int = n_total * 3
		out["done"] = true
		out["cursor"] = cursor_done
		out["elapsed_ms"] = (Time.get_ticks_usec() - started_us) / 1000.0
		out["work_done"] = cursor_done
		return out
	push_error("[season_refresh/stage4] native failed; previous fields retained")
	out["done"] = true
	out["failed"] = true
	return out


func finish_season_refresh(_map: MapData, _world: WorldData, _season_idx: int) -> void:
	_generator._season_refresh_in_progress = false
	if _generator._world_clock_ref != null and _generator._world_clock_ref.has_method("day_index"):
		_generator._last_season_refresh_day = floori(_generator._get_runtime_climate_capture().sample_day())
	if not _generator._season_round_b_plus_facade_published and _map != null and _map.has_method("sync_runtime_terrain_facade_from_soa"):
		var terrain_facade_fixed: int = int(_map.sync_runtime_terrain_facade_from_soa())
		_generator._last_season_refresh_breakdown["terrain_facade_fixed"] = terrain_facade_fixed
		if terrain_facade_fixed > 0:
			_generator._season_log_path_once("finish", "soa_to_facade_sync", "terrain_fixed=%d" % terrain_facade_fixed)
	if not _generator._season_round_b_plus_facade_published and _map != null:
		var enum_axes_written: int = _generator._write_runtime_enum_axes_dense(_map)
		_generator._last_season_refresh_breakdown["runtime_enum_axes_dense_written"] = enum_axes_written
	_generator._season_round_b_plus_facade_published = false
	# X2-精简版（2026-05-21）：once-log round 的 slots refresh / skip 计数。
	# 期望全 gdext 路径下：refresh=1, skip=11（同 round 12 个 stage helper 共享一次 refresh）。
	# refresh/skip 统计用于核对 round 内的 slot 复用。
	# 把统计写入 breakdown，方便 perf overlay / sus_season_refresh_breakdown 查询。
	_generator._last_season_refresh_breakdown["slots_refresh_count"] = _generator._season_round_slots_refresh_count
	_generator._last_season_refresh_breakdown["slots_skip_count"] = _generator._season_round_slots_skip_count
	if not _generator._season_stage_path_logged.has("__x2_slots_round_first"):
		_generator._season_stage_path_logged["__x2_slots_round_first"] = true
		print("[season_refresh] x2 slots: refresh=%d skip=%d (期望 refresh=1 skip=11 全 gdext 路径)"
				% [_generator._season_round_slots_refresh_count, _generator._season_round_slots_skip_count])
	# 重置标志位让下一 round 重新走"首 stage 触发 refresh"流程。
	_generator._season_round_slots_fresh = false
	_generator._season_round_slots_skip_count = 0
	_generator._season_round_slots_refresh_count = 0
	# 季节刷新会改 cover（雪线 / 洪水 / 冰川），而 Military 的地形成本表按 cover
	# 分类。facade 用 cover 签名去重，cover 未变时这里只做一次 hash，不过桥。
	if not _generator.runtime_graph_active() and _generator._military_facade != null \
			and _generator._military_facade.is_configured():
		var day := floori(_generator._get_runtime_climate_capture().sample_day()) if _generator._world_clock_ref != null else -1
		var terrain: Dictionary = _generator.refresh_military_terrain(day)

		_generator._last_season_refresh_breakdown["military_terrain"] = String(
			terrain.get("reason", "ok" if bool(terrain.get("ok", false)) else "failed"))


# capture 侧的 season refresh 边沿检测。见 _last_capture_season_refresh_day。
# 返回「距上次 capture 之间 season refresh 完成过一轮」，读完即消费。
## Only peeks: the edge is consumed once the capture is accepted, so a capture
## retried on the same day still carries it.

func season_round_b_plus_available() -> bool:
	return SeasonRound.season_round_b_plus_available(self)


func start_season_round_b_plus(map: MapData, _world: WorldData, season: int) -> int:
	return SeasonRound.start_season_round_b_plus(self, map, _world, season)


func run_season_round_slice_b_plus(_map: MapData, _world: WorldData, max_usec: int = 0) -> Dictionary:
	return SeasonRound.run_season_round_slice_b_plus(self, _map, _world, max_usec)


func begin_finish_season_round_b_plus(map: MapData, _world: WorldData, _season: int) -> void:
	SeasonRound.begin_finish_season_round_b_plus(self, map, _world, _season)


func _abort_season_round_b_plus_safe() -> void:
	SeasonRound._abort_season_round_b_plus_safe(self)


# 检查 soil_moisture / veg_growth_pressure SoA size 是否与 n_cells 对齐。
# B+ 路径 round_knobs 内含这两条 in/out array，size 不齐会导致 C++ 端 stage 11 路径
# 误算或 OOB；start 阶段就拒绝 native round。

func _biome_temperature(map: MapData, cell: HexCell, fallback: float) -> float:
	var idx: int = int(cell.index)
	if map != null and idx >= 0 and idx < map.temp_365d_arr.size():
		return clampf(float(map.temp_365d_arr[idx]), 0.0, 1.0)
	return clampf(fallback, 0.0, 1.0)


# Biome classification is slow climate; keep short-lived rainfall in vegetation/runtime moisture.

func _biome_moisture(map: MapData, cell: HexCell) -> float:
	var idx: int = int(cell.index)
	var base_m: float = float(cell.base_moisture)
	var wb30: float = 0.0
	if map != null and idx >= 0:
		if idx < map.base_moisture_arr.size():
			base_m = float(map.base_moisture_arr[idx])
		if idx < map.water_balance_30d_arr.size():
			wb30 = float(map.water_balance_30d_arr[idx])
	var cp: ClimateProfile = _generator._c()
	var wet_weight: float = float(cp.plant_water_balance_weight) if cp != null else 0.35
	var dry_penalty: float = float(cp.plant_drought_penalty) if cp != null else 0.25
	return clampf(base_m + maxf(wb30, 0.0) * maxf(wet_weight, 0.0) + minf(wb30, 0.0) * maxf(dry_penalty, 0.0), 0.0, 1.0)



func _vegetation_donor_amount(t: int) -> float:
	var c: ClimateProfile = _generator._c()
	match t:
		TerrainType.TERRAIN.FOREST:    return c.veg_forest_donor
		TerrainType.TERRAIN.SWAMP:     return c.veg_swamp_donor
		TerrainType.TERRAIN.GRASSLAND: return c.veg_grassland_donor
		TerrainType.TERRAIN.DESERT:    return c.veg_desert_donor
		TerrainType.TERRAIN.JUNGLE:    return c.veg_jungle_donor
		TerrainType.TERRAIN.TAIGA:     return c.veg_taiga_donor
		TerrainType.TERRAIN.SAVANNA:   return c.veg_savanna_donor
		TerrainType.TERRAIN.OASIS:     return c.veg_oasis_donor
		TerrainType.TERRAIN.DELTA:     return c.veg_delta_donor
		TerrainType.TERRAIN.SALT_FLAT: return c.veg_salt_flat_donor
		_:                              return 0.0


# SEA_ICE（海冰）：连续 sea_ice_fraction，由逐日温度 pass 推进；
# base_terrain 只作为消融后的 revert target。
# 阈值带 hysteresis：具体 form/melt/terrain 阈值来自 ClimateProfile。
# const SEA_ICE_FORM_THRESHOLD (migrated to ClimateProfile.sea_ice_form_threshold)
# const SEA_ICE_MELT_THRESHOLD (migrated to ClimateProfile.sea_ice_melt_threshold)


func refresh_seasonal(map: MapData, world: WorldData, season_idx: int) -> void:
	if _generator._last_cfg == null or _generator._baker == null:
		return
	_generator._last_world = world
	_generator._current_season = season_idx
	_generator._mark_enum_atlas_dirty(true, true, true)

# ─── Emergent Climate Coupling：消费反馈缓冲（季末一次） ───────────────
# 调用时机：refresh_seasonal 尾部，每季一次。
# 行为：
#   1) base_moisture 漂移：按 soil_moisture 当前值 × FEEDBACK_SOIL_TO_BASE_W（0.15）
#      累加到 base_moisture（clamp 0..1），模拟"长期土壤湿度抬升湿润基线"。
#   2) 两个反馈字段都乘以 decay（默认 0.5）衰减，保留半数跨季记忆，避免无限累积。

func _run_season_refresh_stage11_gdext(map: MapData, _world: WorldData, _season: int) -> bool:
	return SeasonNativePasses._run_season_refresh_stage11_gdext(self, map, _world, _season)


func _build_row_indices_for_gdext(map: MapData, cfg: MapConfig) -> PackedInt32Array:
	return SeasonNativePasses._build_row_indices_for_gdext(self, map, cfg)


func _set_cell_runtime_terrain(map: MapData, cell: HexCell, terrain_id: int,
		sync_axes: bool = false, temperature_for_vegetation: float = -1.0,
		snow_cover: float = -1.0) -> void:
	SeasonNativePasses._set_cell_runtime_terrain(self, map, cell, terrain_id, sync_axes, temperature_for_vegetation, snow_cover)


func _sync_runtime_axes_after_terrain(map: MapData, cell: HexCell, idx: int,
		temperature_for_vegetation: float = -1.0, snow_cover: float = -1.0) -> void:
	SeasonNativePasses._sync_runtime_axes_after_terrain(self, map, cell, idx, temperature_for_vegetation, snow_cover)


func _clear_cell_vegetation_state(map: MapData, cell: HexCell, idx: int = -1) -> void:
	SeasonNativePasses._clear_cell_vegetation_state(self, map, cell, idx)


func _write_runtime_enum_axes_dense(map: MapData) -> int:
	return SeasonNativePasses._write_runtime_enum_axes_dense(self, map)


func _world_ext_u8_component_id(gd_name: StringName) -> int:
	return SeasonNativePasses._world_ext_u8_component_id(self, gd_name)


func _apply_sea_ice_terrain_flips_indexed(map: MapData, indices: PackedInt32Array,
		terrain_values: PackedByteArray, sync_cells: bool = true) -> Dictionary:
	return SeasonNativePasses._apply_sea_ice_terrain_flips_indexed(self, map, indices, terrain_values, sync_cells)


func _build_sea_ice_flip_batch(flip_to_ice_list: PackedInt32Array,
		flip_to_base_list: PackedInt32Array, flip_to_base_terrain: PackedByteArray,
		start: int = 0, end: int = -1) -> Dictionary:
	return SeasonNativePasses._build_sea_ice_flip_batch(self, flip_to_ice_list, flip_to_base_list, flip_to_base_terrain, start, end)


func _build_vegetation_donor_table_for_gdext() -> PackedFloat32Array:
	return SeasonNativePasses._build_vegetation_donor_table_for_gdext(self)


func _build_rain_shadow_jitter_for_gdext(map: MapData) -> PackedFloat32Array:
	return SeasonNativePasses._build_rain_shadow_jitter_for_gdext(self, map)


func _run_season_refresh_stage1_gdext(map: MapData, _world: WorldData, season: int) -> bool:
	return SeasonNativePasses._run_season_refresh_stage1_gdext(self, map, _world, season)


func _run_season_refresh_stage2_gdext(map: MapData, _world: WorldData, season: int) -> bool:
	return SeasonNativePasses._run_season_refresh_stage2_gdext(self, map, _world, season)


func _run_season_refresh_stage3_gdext(map: MapData, _world: WorldData, _season: int) -> bool:
	return SeasonNativePasses._run_season_refresh_stage3_gdext(self, map, _world, _season)


func _run_season_refresh_stage4_gdext(map: MapData, _world: WorldData, season: int) -> bool:
	return SeasonNativePasses._run_season_refresh_stage4_gdext(self, map, _world, season)


# stage 5: shrubland_pass。陆地 + GRASSLAND/STEPPE/SAVANNA/PLAIN + 低海拔 + 暖温 + 中干 + 海邻 → SHRUBLAND.

func _ensure_season_knob_geometry_cache(map: MapData, n_cells: int) -> bool:
	if map == null or _generator._last_cfg == null:
		return false
	var map_id: int = map.get_instance_id()
	var cfg_id: int = _generator._last_cfg.get_instance_id()
	var warp_id: int = _generator._height_warp.get_instance_id() if _generator._height_warp != null else 0
	var hit: bool = _generator._season_knob_cache_n == n_cells \
		and _generator._season_knob_cache_map_id == map_id \
		and _generator._season_knob_cache_cfg_id == cfg_id \
		and _generator._season_knob_cache_warp_id == warp_id \
		and _generator._season_knob_row_idx_cache.size() == n_cells \
		and _generator._season_knob_jitter_cache.size() == n_cells
	if hit:
		return true
	var row_idx: PackedInt32Array = _generator._build_row_indices_for_gdext(map, _generator._last_cfg)
	if row_idx.size() != n_cells:
		return false
	var jitter_arr: PackedFloat32Array = _generator._build_rain_shadow_jitter_for_gdext(map)
	if jitter_arr.size() != n_cells:
		return false
	_generator._season_knob_row_idx_cache = row_idx
	_generator._season_knob_jitter_cache = jitter_arr
	_generator._season_knob_cache_map_id = map_id
	_generator._season_knob_cache_cfg_id = cfg_id
	_generator._season_knob_cache_warp_id = warp_id
	_generator._season_knob_cache_n = n_cells
	return true



func _build_season_round_knobs(map: MapData, season: int) -> Dictionary:
	var cp = _generator._c()
	if cp == null or _generator._last_cfg == null or map == null:
		return {}
	var n_cells: int = map.cell_count()
	if n_cells <= 0:
		return {}
	if not map.has_indices():
		return {}
	if not map.has_lat_lut():
		map.bake_lat_temp_year_lut(_generator)
	_generator._ensure_row_tables(_generator._last_cfg, season)
	if _generator._row_lat_temp.size() < _generator._last_cfg.height or _generator._row_season_off.size() < _generator._last_cfg.height:
		return {}
	# row_indices + rain-shadow jitter 是地图几何/噪声的纯函数（season-invariant），
	# 缓存一次跨 round 复用；命中时零分配、零 cell_at 循环（省 ~3ms/round-start）。
	if not _generator._ensure_season_knob_geometry_cache(map, n_cells):
		return {}
	var row_idx: PackedInt32Array = _generator._season_knob_row_idx_cache
	var jitter_arr: PackedFloat32Array = _generator._season_knob_jitter_cache
	var donor_table: PackedFloat32Array = _generator._build_vegetation_donor_table_for_gdext()
	var moist_scale: float = 1.0
	var soil_arr: PackedFloat32Array = map.soil_moisture_arr
	var vg_arr: PackedFloat32Array = map.vegetation_growth_pressure_arr
	var knobs: Dictionary = {
		"season": season,
		"season_phase": float(season) + 0.5,
		"n_cells": n_cells,
		"height": int(_generator._last_cfg.height),
		"sea_level": float(_generator._last_cfg.sea_level),
		# stage 0
		"moist_scale": moist_scale,
		# stage 1
		"rain_shadow_lookback": int(cp.rain_shadow_lookback),
		"rain_shadow_threshold": float(cp.rain_shadow_threshold),
		"rain_shadow_factor": float(cp.rain_shadow_factor),
		"jitter_arr": jitter_arr,
		# stage 2 / 4 / swamp
		"lat_temp_rows": _generator._row_lat_temp,
		"season_offset_rows": _generator._row_season_off,
		"row_indices": row_idx,
		"biome_water_balance_weight": float(cp.plant_water_balance_weight),
		"biome_drought_penalty": float(cp.plant_drought_penalty),
		"neighbor_indices": map.neighbor_indices_packed(),
		# stage 4
		"donor_table": donor_table,
		"elev_decay": float(cp.veg_feedback_elev_decay),
		"skip_vegetation_rewrite": true,
		# stage 11 (feedback_decay)
		"decay": float(cp.feedback_decay),
		"soil_moisture_arr": soil_arr,
		"veg_growth_pressure_arr": vg_arr,
	}
	return knobs


# B+ 入口 1/3：开启 round。
# 返回 handle > 0 表示 active；<=0 表示门禁失败，caller 应退回 12-stage 路径。
# 副作用：refresh_slots_from_map（让 C++ SoA 看到本 round 起点的最新 cell 状态），
#         重置 _season_round_b_plus_* 累计计数。

func continue_finish_season_round_b_plus(map: MapData, max_cells: int = 128) -> Dictionary:
	return SeasonRoundPublication.continue_finish_season_round_b_plus(self, map, max_cells)


func pop_b_plus_round_samples() -> Dictionary:
	return SeasonRoundPublication.pop_b_plus_round_samples(self)


# 强制中止当前 B+ round（C++ 端清 round_state，GDScript 端清 handle）。
# 用于：start 前发现旧 round 残留 / slice 中途 fallback 后清场 / 外部主动放弃。
# 不抛异常；ext 缺失时仅清本地 handle。

func soil_arr_size_mismatch(map: MapData) -> bool:
	if map == null:
		return true
	var n: int = map.cell_count()
	var s: int = (map.soil_moisture_arr as PackedFloat32Array).size()
	var v: int = (map.vegetation_growth_pressure_arr as PackedFloat32Array).size()
	return s != n or v != n



func _sync_stage8_facade_fields_from_soa(map: MapData) -> void:
	var n: int = map.cell_count()
	var terrain_a: PackedByteArray = map.terrain_arr
	var landform_a: PackedByteArray = map.landform_arr
	var vegetation_a: PackedByteArray = map.vegetation_arr
	var cover_a: PackedByteArray = map.cover_arr
	var water_a: PackedByteArray = map.is_water_arr
	var volcano_repaired: int = 0
	var volcano_a: PackedByteArray = map.has_volcano_arr
	if volcano_a.size() == n and landform_a.size() == n:
		var volcano_lf: int = int(LandformType.LF.VOLCANO)
		for vi in range(n):
			if int(volcano_a[vi]) == 0:
				continue
			if int(landform_a[vi]) == volcano_lf:
				continue
			landform_a[vi] = volcano_lf
			if vi < map.base_landform_arr.size():
				map.base_landform_arr[vi] = volcano_lf
			volcano_repaired += 1
		if volcano_repaired > 0:
			map.landform_arr = landform_a
			_generator._last_season_refresh_breakdown["volcano_landform_repaired"] = volcano_repaired
	# Keep the legacy one-sample-per-round history contract, but avoid writing
	# facade fields and UI dictionaries when the native SoA value is unchanged.
	# The old path first traversed every cell in MapData, then repeated a second
	# traversal here and rewrote four Dictionary entries for every cell.
	var cells: Array = map.iter_cells() if map.has_indices() else map.all_cells()
	var terrain_facade_fixed: int = 0
	var axis_facade_fixed: int = 0
	var state_fixed: int = 0
	var water_lut: PackedByteArray = MapData.is_water_lut()
	for i in range(n):
		var cell: HexCell = cells[i] if i < cells.size() else null
		if cell == null:
			continue
		var terrain_changed: bool = i < terrain_a.size() and int(cell.terrain) != int(terrain_a[i])
		if terrain_changed:
			cell.apply_terrain(int(terrain_a[i]))
			terrain_facade_fixed += 1
		if i < terrain_a.size() and i < water_a.size():
			water_a[i] = water_lut[int(terrain_a[i]) & 0xFF]
		var landform_changed: bool = i < landform_a.size() and int(cell.landform) != int(landform_a[i])
		var vegetation_changed: bool = i < vegetation_a.size() and int(cell.vegetation) != int(vegetation_a[i])
		var cover_changed: bool = i < cover_a.size() and int(cell.cover) != int(cover_a[i])
		if landform_changed:
			cell.landform = int(landform_a[i])
		if vegetation_changed:
			cell.vegetation = int(vegetation_a[i])
		if cover_changed:
			cell.cover = int(cover_a[i])
		if landform_changed or vegetation_changed or cover_changed:
			axis_facade_fixed += 1
		if (terrain_changed or landform_changed or vegetation_changed or cover_changed) \
				and cell.current_state != null and not cell.current_state.is_empty():
			# Keep inspector/UI snapshots on the same SoA publish boundary as the
			# HexCell facade; otherwise labels can show the previous vegetation.
			cell.current_state["biome"] = int(cell.terrain)
			cell.current_state["landform"] = int(cell.landform)
			cell.current_state["vegetation"] = int(cell.vegetation)
			cell.current_state["cover"] = int(cell.cover)
			state_fixed += 1
		cell.push_biome_history(int(cell.terrain))
		cell.push_vegetation_history(int(cell.vegetation))
	_generator._last_season_refresh_breakdown["terrain_facade_fixed"] = terrain_facade_fixed
	_generator._last_season_refresh_breakdown["axis_facade_fixed"] = axis_facade_fixed
	_generator._last_season_refresh_breakdown["current_state_fixed"] = state_fixed



func sus_report_job_stats() -> Dictionary:
	if _generator._sus == null:
		return {}
	if not _generator._sus.has_method("report_job_stats"):
		return {}
	return _generator._sus.report_job_stats()
