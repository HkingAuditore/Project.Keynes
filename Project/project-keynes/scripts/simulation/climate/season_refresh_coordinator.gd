extends "res://scripts/simulation/generator_context.gd"

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
		season_idx = int(_generator._world_clock_ref.season_index())
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
		_generator._last_season_refresh_day = int(_generator._world_clock_ref.day_index())
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
	if _generator._military_facade != null and _generator._military_facade.is_configured():
		var day := int(_generator._world_clock_ref.day_index()) if _generator._world_clock_ref != null else -1
		var terrain: Dictionary = _generator.refresh_military_terrain(day)
		_generator._last_season_refresh_breakdown["military_terrain"] = String(
			terrain.get("reason", "ok" if bool(terrain.get("ok", false)) else "failed"))


# capture 侧的 season refresh 边沿检测。见 _last_capture_season_refresh_day。
# 返回「距上次 capture 之间 season refresh 完成过一轮」，读完即消费。
## Only peeks: the edge is consumed once the capture is accepted, so a capture
## retried on the same day still carries it.

func season_round_b_plus_available() -> bool:
	if _generator._data_core_world_ext == null:
		return false
	return true


# 构造 round_knobs：12 stage knobs 的并集。
# 失败（cfg / map / row_table 缺失）返回空 Dictionary，caller 视为 fallback。
# 季节 round-start knob 几何缓存填充。缓存有效（map/cfg/warp 实例 + n_cells 全未变）
# 时直接返回；否则重建 row_indices + rain-shadow jitter 各一次并落缓存。
# 返回 false 表示当前无法构建（cfg/warp 缺失或 size 不符），caller 走 fallback。

func start_season_round_b_plus(map: MapData, _world: WorldData, season: int) -> int:
	if not season_round_b_plus_available():
		_generator._season_log_path_once("b_plus", "gdscript_fallback", "gate fail (cp/ext/method)")
		return 0
	if _generator.soil_arr_size_mismatch(map):
		_generator._season_log_path_once("b_plus", "gdscript_fallback", "soil/vg arr size mismatch with n_cells")
		return 0
	# 旧 round 残留（前一个 round 没正常 finish / abort）→ 强制清理。
	if _generator._season_round_b_plus_handle > 0:
		_generator._season_log_path_once("b_plus", "stale_handle_abort", "previous handle=%d still active, forcing abort" % _generator._season_round_b_plus_handle)
		_abort_season_round_b_plus_safe()
	_generator._ensure_season_round_slots_fresh()
	var knobs: Dictionary = _generator._build_season_round_knobs(map, season)
	if knobs.is_empty():
		_generator._season_log_path_once("b_plus", "gdscript_fallback", "round_knobs build failed (cfg/map/row_table)")
		return 0
	var res: Dictionary = _generator._data_core_world_ext.start_season_round(knobs)
	if res.is_empty() or bool(res.get("fallback", true)):
		_generator._season_log_path_once("b_plus", "gdscript_fallback", "start_season_round returned fallback: %s" % String(res.get("reason", "unknown")))
		return 0
	var handle: int = int(res.get("handle", 0))
	if handle <= 0:
		_generator._season_log_path_once("b_plus", "gdscript_fallback", "start_season_round returned invalid handle=%d" % handle)
		return 0
	_generator._season_round_b_plus_handle = handle
	_generator._season_round_b_plus_native_ms = 0.0
	_generator._season_round_b_plus_slices_used = 0
	_generator._season_round_b_plus_stages_done = 0
	_generator._b_plus_round_start_usec = Time.get_ticks_usec()
	_generator._last_season_refresh_breakdown["b_plus_path"] = "gdext"
	_generator._last_season_refresh_breakdown["b_plus_handle"] = handle
	_generator._season_log_path_once("b_plus_start", "gdext", "handle=%d season=%d n_cells=%d" % [handle, season, int(knobs.get("n_cells", 0))])
	return handle


# B+ 入口 2/3：推进一个 slice，stage-boundary 切片（b1）。
# max_usec：单 slice 预算（默认从 cp.sim_slice_budget_ms 取）。
# 返回字典 { "done": bool, "stages_done": int, "elapsed_ms": float, "fallback": bool }。
# 任一异常（handle 无效 / fallback / mid-slice 错误）→ 标记 done=true + fallback=true，
# 上层 caller 应放弃 round 并退回 12-stage 路径补完。

func run_season_round_slice_b_plus(_map: MapData, _world: WorldData, max_usec: int = 0) -> Dictionary:
	var out: Dictionary = {
		"done": false,
		"stages_done": _generator._season_round_b_plus_stages_done,
		"elapsed_ms": 0.0,
		"fallback": false,
	}
	if _generator._season_round_b_plus_handle <= 0:
		out["fallback"] = true
		out["done"] = true
		_generator._season_log_path_once("b_plus_slice", "gdscript_fallback", "no active handle")
		return out
	if _generator._data_core_world_ext == null:
		out["fallback"] = true
		out["done"] = true
		_generator._season_log_path_once("b_plus_slice", "gdscript_fallback", "ext/method missing mid-round")
		_abort_season_round_b_plus_safe()
		return out
	var budget_us: int = max_usec
	if budget_us <= 0:
		var cp: ClimateProfile = _generator._c()
		var ms: float = 0.55
		if cp != null and cp.get("sim_slice_budget_ms") != null:
			ms = float(cp.sim_slice_budget_ms)
		budget_us = maxi(50, int(round(ms * 1000.0)))
	budget_us = clampi(budget_us, 50, 1000)
	var res: Dictionary = _generator._data_core_world_ext.run_season_round_slice(_generator._season_round_b_plus_handle, budget_us)
	if res.is_empty() or bool(res.get("fallback", false)):
		var completed_before_fallback: int = int(res.get(
				"stages_done", res.get("stage", _generator._season_round_b_plus_stages_done)))
		out["stages_done"] = max(_generator._season_round_b_plus_stages_done, completed_before_fallback)
		out["fallback"] = true
		out["done"] = true
		_generator._season_log_path_once("b_plus_slice", "gdscript_fallback", "run_season_round_slice fallback: %s" % String(res.get("reason", "unknown")))
		# 让 C++ 端清掉残留状态（next round 才能干净开新）。
		_abort_season_round_b_plus_safe()
		return out
	var elapsed_ms: float = float(res.get("elapsed_ms", 0.0))
	_generator._season_round_b_plus_native_ms += elapsed_ms
	_generator._season_round_b_plus_slices_used += 1
	# C++ returns both the absolute stage cursor and the compatibility
	# `stages_done` field.  Prefer the explicit total, but accept `stage` from an
	# older DLL so a hot-reloaded script cannot reset a completed round to zero.
	var reported_stages_done: int = int(res.get(
			"stages_done", res.get("stage", _generator._season_round_b_plus_stages_done)))
	_generator._season_round_b_plus_stages_done = max(_generator._season_round_b_plus_stages_done, reported_stages_done)
	out["elapsed_ms"] = elapsed_ms
	out["stages_done"] = _generator._season_round_b_plus_stages_done
	out["done"] = bool(res.get("done", false))
	return out


# B+ completion has two boundaries. The C++ finish below is the authoritative
# commit; the Godot facade/history mirror is then published in fixed 256-cell
# ranges. The WorldClock keeps its seasonal barrier until that mirror is done.

func begin_finish_season_round_b_plus(map: MapData, _world: WorldData, _season: int) -> void:
	if _generator._season_round_b_plus_handle <= 0:
		_generator._season_log_path_once("b_plus_finish", "gdscript_fallback", "no active handle to finish")
		return
	var ext_ok: bool = _generator._data_core_world_ext != null
	if not ext_ok:
		_generator._season_log_path_once("b_plus_finish", "gdscript_fallback", "finish_season_round method missing")
		_generator._season_round_b_plus_handle = 0
		return
	var res: Dictionary = _generator._data_core_world_ext.finish_season_round(_generator._season_round_b_plus_handle)
	var fallback: bool = bool(res.get("fallback", false))
	# Even on fallback, consume any C++ in/out arrays before exposing the stable
	# map boundary. This is a committed-array swap, not a partial facade update.
	if map != null:
		var n: int = map.cell_count()
		var soil_out: Variant = res.get("soil_moisture_arr", null)
		var vg_out: Variant = res.get("veg_growth_pressure_arr", null)
		if typeof(soil_out) == TYPE_PACKED_FLOAT32_ARRAY and (soil_out as PackedFloat32Array).size() == n:
			map.soil_moisture_arr = soil_out
		if typeof(vg_out) == TYPE_PACKED_FLOAT32_ARRAY and (vg_out as PackedFloat32Array).size() == n:
			map.vegetation_growth_pressure_arr = vg_out
	_generator._last_season_refresh_breakdown["b_plus_native_ms"] = float(res.get("total_native_ms", _generator._season_round_b_plus_native_ms))
	_generator._last_season_refresh_breakdown["b_plus_slices_used"] = int(res.get("slices_used", _generator._season_round_b_plus_slices_used))
	_generator._last_season_refresh_breakdown["b_plus_stages_done"] = int(res.get("stages_done", _generator._season_round_b_plus_stages_done))
	if fallback:
		_generator._season_log_path_once("b_plus_finish", "gdscript_fallback", "finish_season_round fallback: %s" % String(res.get("reason", "unknown")))
	else:
		_generator._season_log_path_once("b_plus_finish", "gdext", "native_ms=%.3f slices=%d stages_done=%d" % [
				float(res.get("total_native_ms", _generator._season_round_b_plus_native_ms)),
				int(res.get("slices_used", _generator._season_round_b_plus_slices_used)),
				int(res.get("stages_done", _generator._season_round_b_plus_stages_done)),
		])
	_generator._season_round_b_plus_handle = 0
	_generator._season_round_b_plus_publish_active = map != null and map.cell_count() > 0
	_generator._season_round_b_plus_publish_cursor = 0
	_generator._season_round_b_plus_facade_published = false
	_generator._season_round_b_plus_publish_terrain_fixed = 0
	_generator._season_round_b_plus_publish_axis_fixed = 0
	_generator._season_round_b_plus_publish_state_fixed = 0



func _abort_season_round_b_plus_safe() -> void:
	if _generator._data_core_world_ext != null:
		_generator._data_core_world_ext.abort_season_round()
	_generator._season_round_b_plus_handle = 0
	_generator._season_round_b_plus_native_ms = 0.0
	_generator._season_round_b_plus_slices_used = 0
	_generator._season_round_b_plus_stages_done = 0
	_generator._season_round_b_plus_publish_active = false
	_generator._season_round_b_plus_publish_cursor = 0
	_generator._season_round_b_plus_facade_published = false
	# abort 不算完整 round（不进 _b_plus_rounds_total 计数），仅清 start usec。
	_generator._b_plus_round_start_usec = 0


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
	# Stage 11 (feedback decay) → C++ stage 10：
	# - 输入：soil_moisture_arr / vegetation_growth_pressure_arr（PackedArray 引用）+
	#   n_cells + decay
	# - 输出：base_moisture 由 C++ 端 _flush_slot_to_map 直接写 SoA；
	#   soil_moisture / veg_growth_pressure 通过 knobs in/out 返回 decayed array，
	#   facade getter 自动从 SoA 拿新值（hex_cell.gd L668-697）。
	# - 数值契约：clamp / decay / FEEDBACK_SOIL_TO_BASE_W=0.15。
	var cp = _generator._c()
	if cp == null:
		_generator._season_log_path_once("stage11", "gdscript_fallback", "cp null")
		return false
	if map == null or _generator._data_core_world_ext == null :
		_generator._season_log_path_once("stage11", "gdscript_fallback", "ext/method/map unavailable")
		return false
	var n_cells: int = map.cell_count()
	if n_cells <= 0:
		_generator._season_log_path_once("stage11", "gdscript_fallback", "n_cells<=0")
		return false
	# 取 map.xxx_arr 引用；run_climate_feedback_pass 已经维护这两个 array
	# 与 cell facade 的同步（line 6996-7002）。
	var soil_arr: PackedFloat32Array = map.soil_moisture_arr
	var vg_arr: PackedFloat32Array = map.vegetation_growth_pressure_arr
	if soil_arr.size() != n_cells or vg_arr.size() != n_cells:
		_generator._season_log_path_once("stage11", "gdscript_fallback", "soil/vg arr size mismatch n_cells=%d soil=%d vg=%d" % [n_cells, soil_arr.size(), vg_arr.size()])
		return false
	# 让 C++ 端 SoA 看到最新 base_moisture（stage_8 之前可能已经写过 cell.base_moisture
	# 而未 flush 回 _slots）。
	_generator._ensure_season_round_slots_fresh()
	var knobs: Dictionary = {
		"stage": 10,
		"n_cells": n_cells,
		"decay": float(cp.feedback_decay),
		"soil_moisture_arr": soil_arr,
		"veg_growth_pressure_arr": vg_arr,
	}
	var res: Dictionary = _generator._data_core_world_ext.run_season_refresh_stage(knobs)
	if bool(res.get("fallback", true)) or float(res.get("elapsed_ms", -1.0)) < 0.0:
		_generator._season_log_path_once("stage11", "gdscript_fallback", "C++ returned fallback: %s" % String(res.get("reason", "unknown")))
		return false
	# 写回 in/out arrays。C++ 端通过 knobs["soil_moisture_arr"] = soil_arr;
	# 把 decayed 值写回；这里把更新后的 PackedArray 灌回 map.xxx_arr，
	# facade getter 即可读到新值（与 _climate_feedback_pass 同模式）。
	var soil_out: PackedFloat32Array = knobs.get("soil_moisture_arr", soil_arr)
	var vg_out: PackedFloat32Array = knobs.get("veg_growth_pressure_arr", vg_arr)
	if soil_out.size() == n_cells:
		map.soil_moisture_arr = soil_out
	if vg_out.size() == n_cells:
		map.vegetation_growth_pressure_arr = vg_out
	_generator._last_season_refresh_breakdown["stage_11_path"] = "gdext"
	_generator._last_season_refresh_breakdown["stage_11_native_ms"] = float(res.get("elapsed_ms", 0.0))
	_generator._last_season_refresh_breakdown["stage_11_touched"] = int(res.get("touched", 0))
	_generator._season_log_path_once("stage11", "gdext", "native_ms=%.3f touched=%d" % [float(res.get("elapsed_ms", 0.0)), int(res.get("touched", 0))])
	return true


# DOTS-Total-CPP（任务 2）：stage 0（per-cell moisture set）gdext 路径。
# 与 stage 8 helper 同模式：检查 ClimateProfile flag + ext + method，未满足走 fallback。
# C++ 端写 cell_moisture SoA；feature_flags.use_hexcell_facade=true 让 cell.moisture
# 自动看到最新 SoA 值，不需要 facade sync。

func _build_row_indices_for_gdext(map: MapData, cfg: MapConfig) -> PackedInt32Array:
	var n: int = map.cell_count()
	var out: PackedInt32Array = PackedInt32Array()
	if n <= 0 or cfg == null:
		return out
	out.resize(n)
	for i in range(n):
		var cell: HexCell = map.cell_at(i)
		if cell == null:
			out[i] = 0
			continue
		out[i] = _generator._cube_to_row(cell, cfg)
	return out



func _set_cell_runtime_terrain(map: MapData, cell: HexCell, terrain_id: int,
		sync_axes: bool = false, temperature_for_vegetation: float = -1.0,
		snow_cover: float = -1.0) -> void:
	if cell == null:
		return
	if map != null and map.has_soa():
		var idx: int = int(cell.index)
		if idx < 0 or idx >= map.cell_count():
			idx = map.index_of(cell)
		if idx >= 0 and idx < map.cell_count():
			map.set_runtime_terrain(idx, terrain_id, true)
			_generator.mark_runtime_terrain_mirror_dirty()
			if sync_axes:
				_generator._sync_runtime_axes_after_terrain(map, cell, idx, temperature_for_vegetation, snow_cover)
			return
	cell.apply_terrain(terrain_id)
	if sync_axes:
		_generator._sync_runtime_axes_after_terrain(map, cell, -1, temperature_for_vegetation, snow_cover)



func _sync_runtime_axes_after_terrain(map: MapData, cell: HexCell, idx: int,
		temperature_for_vegetation: float = -1.0, snow_cover: float = -1.0) -> void:
	if cell == null or _generator._last_cfg == null:
		return
	var cfg: MapConfig = _generator._last_cfg
	var landform: int = _generator._derive_landform(cell, cfg)
	# 结构性地貌保留（与 C++ stage 2 / stage 8 sync_current_state 同口径）：生成期通过
	# 多格邻域起伏分析写入的 PEAK/VOLCANO/PLATEAU/RIFT_VALLEY/CANYON 无法由单格 _derive_landform
	# 复现，季节重判/运行期同步必须保留，否则首个 season-refresh round 就会把高原/高峰/裂谷/峡谷
	# 整片塌缩成朴素 MOUNTAIN/HILL。
	if not _generator._is_water(cell.terrain):
		var prev_lf: int = int(cell.landform)
		if (
			prev_lf == LandformType.LF.PEAK
			or prev_lf == LandformType.LF.VOLCANO
			or prev_lf == LandformType.LF.PLATEAU
			or prev_lf == LandformType.LF.RIFT_VALLEY
			or prev_lf == LandformType.LF.CANYON
		):
			landform = prev_lf
	var temp_for_veg: float = temperature_for_vegetation
	if temp_for_veg < 0.0:
		temp_for_veg = _generator._compute_temperature(_generator._cube_row_norm(cell, cfg), cell.elevation)
	var cover_snow: float = snow_cover if snow_cover >= 0.0 else cell.snow_cover
	var vegetation: int = _generator._derive_vegetation(cell, landform, temp_for_veg)
	var cover: int = _generator._derive_cover(cell, cover_snow)
	cell.landform = landform
	cell.vegetation = vegetation
	cell.cover = cover
	if cell.current_state != null and not cell.current_state.is_empty():
		cell.current_state["biome"] = int(cell.terrain)
		cell.current_state["landform"] = int(landform)
		cell.current_state["vegetation"] = int(vegetation)
		cell.current_state["cover"] = int(cover)
	if map != null and map.has_soa():
		var safe_idx: int = idx
		if safe_idx < 0 or safe_idx >= map.cell_count():
			safe_idx = int(cell.index)
		if safe_idx < 0 or safe_idx >= map.cell_count():
			safe_idx = map.index_of(cell)
		if safe_idx >= 0 and safe_idx < map.cell_count():
			if safe_idx < map.terrain_arr.size():
				map.terrain_arr[safe_idx] = int(cell.terrain) & 0xFF
				_generator.mark_runtime_terrain_mirror_dirty()
			if safe_idx < map.is_water_arr.size():
				map.is_water_arr[safe_idx] = MapData.terrain_is_water_u8(int(cell.terrain))
				_generator.mark_runtime_terrain_mirror_dirty()
			if safe_idx < map.landform_arr.size():
				map.landform_arr[safe_idx] = landform & 0xFF
			if safe_idx < map.vegetation_arr.size():
				map.vegetation_arr[safe_idx] = vegetation & 0xFF
			if safe_idx < map.cover_arr.size():
				map.cover_arr[safe_idx] = cover & 0xFF
			if MapData.terrain_is_water_u8(int(cell.terrain)) != 0 or vegetation == VegetationType.VEG.NONE:
				_generator._clear_cell_vegetation_state(map, cell, safe_idx)



func _clear_cell_vegetation_state(map: MapData, cell: HexCell, idx: int = -1) -> void:
	if cell == null:
		return
	cell.vegetation_vitality = 0.0
	cell._vitality_low_streak = 0
	cell._vitality_high_streak = 0
	cell.vegetation_growth_pressure = 0.0
	cell.vegetation_heat_stress = 0.0
	cell.vegetation_drought_stress = 0.0
	cell.vegetation_cold_stress = 0.0
	cell.vegetation_regen_score = 0.0
	if map == null or not map.has_soa():
		return
	var safe_idx: int = idx
	if safe_idx < 0 or safe_idx >= map.cell_count():
		safe_idx = int(cell.index)
	if safe_idx < 0 or safe_idx >= map.cell_count():
		safe_idx = map.index_of(cell)
	if safe_idx < 0 or safe_idx >= map.cell_count():
		return
	if safe_idx < map.vegetation_vitality_arr.size():
		map.vegetation_vitality_arr[safe_idx] = 0.0
	if safe_idx < map.vitality_low_streak_arr.size():
		map.vitality_low_streak_arr[safe_idx] = 0
	if safe_idx < map.vitality_high_streak_arr.size():
		map.vitality_high_streak_arr[safe_idx] = 0
	if safe_idx < map.vegetation_growth_pressure_arr.size():
		map.vegetation_growth_pressure_arr[safe_idx] = 0.0
	if safe_idx < map.vegetation_heat_stress_arr.size():
		map.vegetation_heat_stress_arr[safe_idx] = 0.0
	if safe_idx < map.vegetation_drought_stress_arr.size():
		map.vegetation_drought_stress_arr[safe_idx] = 0.0
	if safe_idx < map.vegetation_cold_stress_arr.size():
		map.vegetation_cold_stress_arr[safe_idx] = 0.0
	if safe_idx < map.vegetation_regen_score_arr.size():
		map.vegetation_regen_score_arr[safe_idx] = 0.0



func _write_runtime_enum_axes_dense(map: MapData) -> int:
	if map == null or _generator._data_core_world == null or not _generator._data_core_world.has_method("write_u8_dense"):
		return 0
	var written: int = 0
	var cid_terrain: int = _generator._data_core_world.component_id(DCComponentIds.CELL_TERRAIN)
	if cid_terrain >= 0:
		_generator._data_core_world.write_u8_dense(cid_terrain, map.terrain_arr)
		written += 1
	var cid_is_water: int = _generator._data_core_world.component_id(DCComponentIds.CELL_IS_WATER)
	if cid_is_water >= 0:
		_generator._data_core_world.write_u8_dense(cid_is_water, map.is_water_arr)
		written += 1
	var cid_landform: int = _generator._data_core_world.component_id(DCComponentIds.CELL_LANDFORM)
	if cid_landform >= 0:
		_generator._data_core_world.write_u8_dense(cid_landform, map.landform_arr)
		written += 1
	var cid_vegetation: int = _generator._data_core_world.component_id(DCComponentIds.CELL_VEGETATION)
	if cid_vegetation >= 0:
		_generator._data_core_world.write_u8_dense(cid_vegetation, map.vegetation_arr)
		written += 1
	var cid_cover: int = _generator._data_core_world.component_id(DCComponentIds.CELL_COVER)
	if cid_cover >= 0:
		_generator._data_core_world.write_u8_dense(cid_cover, map.cover_arr)
		written += 1
	return written



func _world_ext_u8_component_id(gd_name: StringName) -> int:
	if _generator._data_core_world_ext == null:
		return -1
	var cid_ext: int = int(_generator._data_core_world_ext.component_id(gd_name))
	if cid_ext < 0:
		cid_ext = int(_generator._data_core_world_ext.component_id(StringName(String(gd_name).replace(".", "_"))))
	return cid_ext



func _apply_sea_ice_terrain_flips_indexed(map: MapData, indices: PackedInt32Array,
		terrain_values: PackedByteArray, sync_cells: bool = true) -> Dictionary:
	var diag: Dictionary = {
		"applied": false,
		"count": 0,
		"fallback_reason": "",
		"dc_written": false,
		"dc_ext_written": false,
	}
	if map == null or not map.has_soa():
		diag["fallback_reason"] = "missing_soa"
		return diag
	var n_values: int = mini(indices.size(), terrain_values.size())
	if n_values <= 0:
		diag["applied"] = true
		return diag
	if map.terrain_arr.size() < map.cell_count() or map.is_water_arr.size() < map.cell_count():
		diag["fallback_reason"] = "bad_map_array_size"
		return diag
	var apply_idx: PackedInt32Array = PackedInt32Array()
	var apply_terrain: PackedByteArray = PackedByteArray()
	var apply_water: PackedByteArray = PackedByteArray()
	apply_idx.resize(n_values)
	apply_terrain.resize(n_values)
	apply_water.resize(n_values)
	var w: int = 0
	for k in range(n_values):
		var idx: int = indices[k]
		if idx < 0 or idx >= map.cell_count():
			continue
		var terrain_byte: int = int(terrain_values[k]) & 0xFF
		var water_byte: int = MapData.terrain_is_water_u8(terrain_byte)
		if int(map.terrain_arr[idx]) == terrain_byte and int(map.is_water_arr[idx]) == water_byte:
			continue
		map.terrain_arr[idx] = terrain_byte
		map.is_water_arr[idx] = water_byte
		if sync_cells:
			var cell: HexCell = map.cell_at(idx)
			if cell != null:
				cell.apply_terrain(terrain_byte)
		if map.has_method("mark_climate_dirty"):
			map.mark_climate_dirty(idx)
		apply_idx[w] = idx
		apply_terrain[w] = terrain_byte
		apply_water[w] = water_byte
		w += 1
	if w <= 0:
		diag["applied"] = true
		return diag
	apply_idx.resize(w)
	apply_terrain.resize(w)
	apply_water.resize(w)
	if _generator._data_core_world != null and _generator._data_core_world.has_method("write_u8_indexed"):
		var cid_terrain: int = _generator._data_core_world.component_id(DCComponentIds.CELL_TERRAIN)
		if cid_terrain >= 0:
			_generator._data_core_world.write_u8_indexed(cid_terrain, apply_idx, apply_terrain)
			diag["dc_written"] = true
		var cid_is_water: int = _generator._data_core_world.component_id(DCComponentIds.CELL_IS_WATER)
		if cid_is_water >= 0:
			_generator._data_core_world.write_u8_indexed(cid_is_water, apply_idx, apply_water)
			diag["dc_written"] = true
	if _generator._data_core_world != null and _generator._data_core_world.has_method("mark_dirty_indexed"):
		_generator._data_core_world.mark_dirty_indexed(apply_idx)
	if _generator._data_core_world_ext != null:
		var cid_terr_ext: int = _generator._world_ext_u8_component_id(DCComponentIds.CELL_TERRAIN)
		if cid_terr_ext >= 0:
			_generator._data_core_world_ext.write_u8_indexed(cid_terr_ext, apply_idx, apply_terrain)
			diag["dc_ext_written"] = true
		var cid_isw_ext: int = _generator._world_ext_u8_component_id(DCComponentIds.CELL_IS_WATER)
		if cid_isw_ext >= 0:
			_generator._data_core_world_ext.write_u8_indexed(cid_isw_ext, apply_idx, apply_water)
			diag["dc_ext_written"] = true
	diag["applied"] = true
	diag["count"] = w
	return diag



func _build_sea_ice_flip_batch(flip_to_ice_list: PackedInt32Array,
		flip_to_base_list: PackedInt32Array, flip_to_base_terrain: PackedByteArray,
		start: int = 0, end: int = -1) -> Dictionary:
	var total: int = flip_to_ice_list.size() + flip_to_base_list.size()
	var first: int = clampi(start, 0, total)
	var last: int = total if end < 0 else clampi(end, first, total)
	var out_idx: PackedInt32Array = PackedInt32Array()
	var out_terrain: PackedByteArray = PackedByteArray()
	out_idx.resize(last - first)
	out_terrain.resize(last - first)
	var sea_ice_id: int = int(TerrainType.TERRAIN.SEA_ICE) & 0xFF
	var w: int = 0
	for f in range(first, last):
		if f < flip_to_ice_list.size():
			out_idx[w] = int(flip_to_ice_list[f])
			out_terrain[w] = sea_ice_id
			w += 1
		else:
			var base_i: int = f - flip_to_ice_list.size()
			if base_i < flip_to_base_list.size() and base_i < flip_to_base_terrain.size():
				out_idx[w] = int(flip_to_base_list[base_i])
				out_terrain[w] = int(flip_to_base_terrain[base_i]) & 0xFF
				w += 1
	out_idx.resize(w)
	out_terrain.resize(w)
	return {
		"indices": out_idx,
		"terrain": out_terrain,
	}


# stage 4 用的 donor_table（PackedFloat32Array, size=26, 按 terrain enum 索引）。
# 复刻 _vegetation_donor_amount 的 10 类型 hot 表 + 其余为 0。

func _build_vegetation_donor_table_for_gdext() -> PackedFloat32Array:
	var c = _generator._c()
	var t: PackedFloat32Array = PackedFloat32Array()
	t.resize(26)
	if c == null:
		return t
	t[int(TerrainType.TERRAIN.FOREST)]    = float(c.veg_forest_donor)
	t[int(TerrainType.TERRAIN.SWAMP)]     = float(c.veg_swamp_donor)
	t[int(TerrainType.TERRAIN.GRASSLAND)] = float(c.veg_grassland_donor)
	t[int(TerrainType.TERRAIN.DESERT)]    = float(c.veg_desert_donor)
	t[int(TerrainType.TERRAIN.JUNGLE)]    = float(c.veg_jungle_donor)
	t[int(TerrainType.TERRAIN.TAIGA)]     = float(c.veg_taiga_donor)
	t[int(TerrainType.TERRAIN.SAVANNA)]   = float(c.veg_savanna_donor)
	t[int(TerrainType.TERRAIN.OASIS)]     = float(c.veg_oasis_donor)
	t[int(TerrainType.TERRAIN.DELTA)]     = float(c.veg_delta_donor)
	t[int(TerrainType.TERRAIN.SALT_FLAT)] = float(c.veg_salt_flat_donor)
	return t


# stage 1 用的 jitter_arr（PackedFloat32Array, size=n_cells）。
# 与 _apply_rain_shadow_per_cell line 3158 完全等价：
#   jitter[i] = _height_warp.get_noise_2d(cell.q*8.0, cell.r*8.0) * 0.04
# 让 C++ 端 stage 1 不需要 noise 引擎即可 bit-equal 复刻 WindBelt fallback 路径。

func _build_rain_shadow_jitter_for_gdext(map: MapData) -> PackedFloat32Array:
	var n: int = map.cell_count()
	var out: PackedFloat32Array = PackedFloat32Array()
	if n <= 0 or _generator._height_warp == null:
		return out
	out.resize(n)
	for i in range(n):
		var cell: HexCell = map.cell_at(i)
		if cell == null:
			out[i] = 0.0
			continue
		out[i] = _generator._height_warp.get_noise_2d(float(cell.q) * 8.0, float(cell.r) * 8.0) * 0.04
	return out


# stage 1: rain_shadow_per_cell。
# C++ 等价：cell.wind_vector 优先 + WindBelt fallback（用预烘焙 jitter）+ 6 邻接 lookback。

func _run_season_refresh_stage1_gdext(map: MapData, _world: WorldData, season: int) -> bool:
	var cp = _generator._c()
	if cp == null:
		_generator._season_log_path_once("stage1", "gdscript_fallback", "cp null")
		return false
	if _generator._last_cfg == null or map == null or _generator._data_core_world_ext == null :
		_generator._season_log_path_once("stage1", "gdscript_fallback", "ext/method/map/cfg unavailable")
		return false
	if not map.has_indices():
		_generator._season_log_path_once("stage1", "gdscript_fallback", "map.has_indices()=false (CSR not baked)")
		return false
	var n_cells: int = map.cell_count()
	if n_cells <= 0:
		_generator._season_log_path_once("stage1", "gdscript_fallback", "n_cells<=0")
		return false
	_generator._ensure_season_round_slots_fresh()
	var jitter_arr: PackedFloat32Array = _generator._build_rain_shadow_jitter_for_gdext(map)
	if jitter_arr.size() != n_cells:
		_generator._season_log_path_once("stage1", "gdscript_fallback", "jitter_arr size mismatch n_cells=%d jitter=%d" % [n_cells, jitter_arr.size()])
		return false
	var knobs: Dictionary = {
		"stage": 1,
		"n_cells": n_cells,
		"rain_shadow_lookback": int(cp.rain_shadow_lookback),
		"rain_shadow_threshold": float(cp.rain_shadow_threshold),
		"rain_shadow_factor": float(cp.rain_shadow_factor),
		"neighbor_indices": map.neighbor_indices_packed(),
		"season_phase": float(season) + 0.5,
		"jitter_arr": jitter_arr,
	}
	var res: Dictionary = _generator._data_core_world_ext.run_season_refresh_stage(knobs)
	if bool(res.get("fallback", true)) or float(res.get("elapsed_ms", -1.0)) < 0.0:
		_generator._season_log_path_once("stage1", "gdscript_fallback", "C++ returned fallback: %s" % String(res.get("reason", "unknown")))
		return false
	# moisture 是单轴写入，hexcell_facade=true 自动透出，不需 facade sync。
	_generator._last_season_refresh_breakdown["stage_1_path"] = "gdext"
	_generator._last_season_refresh_breakdown["stage_1_native_ms"] = float(res.get("elapsed_ms", 0.0))
	_generator._season_log_path_once("stage1", "gdext", "native_ms=%.3f" % float(res.get("elapsed_ms", 0.0)))
	return true


# stage 2: seasonal_redecide_terrain。多轴写入（terrain + landform + vegetation + cover），
# 必须在结束后 _sync_stage8_facade_fields_from_soa 同步 facade。

func _run_season_refresh_stage2_gdext(map: MapData, _world: WorldData, season: int) -> bool:
	var cp = _generator._c()
	if cp == null:
		_generator._season_log_path_once("stage2", "gdscript_fallback", "cp null")
		return false
	if _generator._last_cfg == null or map == null or _generator._data_core_world_ext == null :
		_generator._season_log_path_once("stage2", "gdscript_fallback", "ext/method/map/cfg unavailable")
		return false
	var n_cells: int = map.cell_count()
	if n_cells <= 0:
		_generator._season_log_path_once("stage2", "gdscript_fallback", "n_cells<=0")
		return false
	if not map.has_lat_lut():
		map.bake_lat_temp_year_lut(_generator)
	_generator._ensure_row_tables(_generator._last_cfg, season)
	if _generator._row_lat_temp.size() < _generator._last_cfg.height or _generator._row_season_off.size() < _generator._last_cfg.height:
		_generator._season_log_path_once("stage2", "gdscript_fallback", "row tables not ready: lat_temp=%d season_off=%d height=%d" % [_generator._row_lat_temp.size(), _generator._row_season_off.size(), int(_generator._last_cfg.height)])
		return false
	_generator._ensure_season_round_slots_fresh()
	var row_idx: PackedInt32Array = _generator._build_row_indices_for_gdext(map, _generator._last_cfg)
	if row_idx.size() != n_cells:
		_generator._season_log_path_once("stage2", "gdscript_fallback", "row_idx size mismatch n_cells=%d row_idx=%d" % [n_cells, row_idx.size()])
		return false
	var knobs: Dictionary = {
		"stage": 2,
		"season": season,
		"n_cells": n_cells,
		"height": int(_generator._last_cfg.height),
		"sea_level": float(_generator._last_cfg.sea_level),
		"lat_temp_rows": _generator._row_lat_temp,
		"season_offset_rows": _generator._row_season_off,
		"row_indices": row_idx,
		"biome_water_balance_weight": float(cp.plant_water_balance_weight),
		"biome_drought_penalty": float(cp.plant_drought_penalty),
	}
	var res: Dictionary = _generator._data_core_world_ext.run_season_refresh_stage(knobs)
	if bool(res.get("fallback", true)) or float(res.get("elapsed_ms", -1.0)) < 0.0:
		_generator._season_log_path_once("stage2", "gdscript_fallback", "C++ returned fallback: %s" % String(res.get("reason", "unknown")))
		return false
	_generator._sync_stage8_facade_fields_from_soa(map)
	_generator._last_season_refresh_breakdown["stage_2_path"] = "gdext"
	_generator._last_season_refresh_breakdown["stage_2_native_ms"] = float(res.get("elapsed_ms", 0.0))
	_generator._season_log_path_once("stage2", "gdext", "native_ms=%.3f" % float(res.get("elapsed_ms", 0.0)))
	return true


# stage 3: river_ecology。河岸保湿；荒漠河道修成 FLOODPLAIN/OASIS/STEPPE；低地河道优先 FLOODPLAIN。
# 多轴写入需 facade sync。

func _run_season_refresh_stage3_gdext(map: MapData, _world: WorldData, _season: int) -> bool:
	var cp = _generator._c()
	if cp == null:
		_generator._season_log_path_once("stage3", "gdscript_fallback", "cp null")
		return false
	if _generator._last_cfg == null or map == null or _generator._data_core_world_ext == null :
		_generator._season_log_path_once("stage3", "gdscript_fallback", "ext/method/map/cfg unavailable")
		return false
	var n_cells: int = map.cell_count()
	if n_cells <= 0:
		_generator._season_log_path_once("stage3", "gdscript_fallback", "n_cells<=0")
		return false
	_generator._ensure_season_round_slots_fresh()
	var row_idx: PackedInt32Array = _generator._build_row_indices_for_gdext(map, _generator._last_cfg)
	if row_idx.size() != n_cells:
		_generator._season_log_path_once("stage3", "gdscript_fallback", "row_idx size mismatch n_cells=%d row_idx=%d" % [n_cells, row_idx.size()])
		return false
	var knobs: Dictionary = {
		"stage": 3,
		"n_cells": n_cells,
		"height": int(_generator._last_cfg.height),
		"sea_level": float(_generator._last_cfg.sea_level),
		"row_indices": row_idx,
	}
	var res: Dictionary = _generator._data_core_world_ext.run_season_refresh_stage(knobs)
	if bool(res.get("fallback", true)) or float(res.get("elapsed_ms", -1.0)) < 0.0:
		_generator._season_log_path_once("stage3", "gdscript_fallback", "C++ returned fallback: %s" % String(res.get("reason", "unknown")))
		return false
	_generator._sync_stage8_facade_fields_from_soa(map)
	_generator._last_season_refresh_breakdown["stage_3_path"] = "gdext"
	_generator._last_season_refresh_breakdown["stage_3_native_ms"] = float(res.get("elapsed_ms", 0.0))
	_generator._season_log_path_once("stage3", "gdext", "native_ms=%.3f" % float(res.get("elapsed_ms", 0.0)))
	return true


# stage 4: vegetation_feedback。3-pass（donor delta 累加 / 应用 / 二次 redecide）。
# 多轴写入 + moisture 写入；需 facade sync。

func _run_season_refresh_stage4_gdext(map: MapData, _world: WorldData, season: int) -> bool:
	var cp = _generator._c()
	if cp == null:
		_generator._season_log_path_once("stage4", "gdscript_fallback", "cp null")
		return false
	if _generator._last_cfg == null or map == null or _generator._data_core_world_ext == null :
		_generator._season_log_path_once("stage4", "gdscript_fallback", "ext/method/map/cfg unavailable")
		return false
	if not map.has_indices():
		_generator._season_log_path_once("stage4", "gdscript_fallback", "map.has_indices()=false (CSR not baked)")
		return false
	var n_cells: int = map.cell_count()
	if n_cells <= 0:
		_generator._season_log_path_once("stage4", "gdscript_fallback", "n_cells<=0")
		return false
	if not map.has_lat_lut():
		map.bake_lat_temp_year_lut(_generator)
	_generator._ensure_row_tables(_generator._last_cfg, season)
	if _generator._row_lat_temp.size() < _generator._last_cfg.height:
		_generator._season_log_path_once("stage4", "gdscript_fallback", "row_lat_temp not ready: size=%d height=%d" % [_generator._row_lat_temp.size(), int(_generator._last_cfg.height)])
		return false
	_generator._ensure_season_round_slots_fresh()
	var row_idx: PackedInt32Array = _generator._build_row_indices_for_gdext(map, _generator._last_cfg)
	if row_idx.size() != n_cells:
		_generator._season_log_path_once("stage4", "gdscript_fallback", "row_idx size mismatch n_cells=%d row_idx=%d" % [n_cells, row_idx.size()])
		return false
	var donor_table: PackedFloat32Array = _generator._build_vegetation_donor_table_for_gdext()
	var knobs: Dictionary = {
		"stage": 4,
		"n_cells": n_cells,
		"height": int(_generator._last_cfg.height),
		"sea_level": float(_generator._last_cfg.sea_level),
		"lat_temp_rows": _generator._row_lat_temp,
		"row_indices": row_idx,
		"biome_water_balance_weight": float(cp.plant_water_balance_weight),
		"biome_drought_penalty": float(cp.plant_drought_penalty),
		"neighbor_indices": map.neighbor_indices_packed(),
		"donor_table": donor_table,
		"elev_decay": float(cp.veg_feedback_elev_decay),
	}
	var res: Dictionary = _generator._data_core_world_ext.run_season_refresh_stage(knobs)
	if bool(res.get("fallback", true)) or float(res.get("elapsed_ms", -1.0)) < 0.0:
		_generator._season_log_path_once("stage4", "gdscript_fallback", "C++ returned fallback: %s" % String(res.get("reason", "unknown")))
		return false
	_generator._sync_stage8_facade_fields_from_soa(map)
	_generator._last_season_refresh_breakdown["stage_4_path"] = "gdext"
	_generator._last_season_refresh_breakdown["stage_4_native_ms"] = float(res.get("elapsed_ms", 0.0))
	_generator._season_log_path_once("stage4", "gdext", "native_ms=%.3f" % float(res.get("elapsed_ms", 0.0)))
	return true


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
	# B+ 路径暂不暴露 stage 11（feedback_decay）的 in/out array 写回路径——
	# 由 finish wrapper 末尾通过 knobs 取回 decayed array 后回灌 map.xxx_arr。
	# round_knobs 字段顺序与 stage helper 中现有 knobs 保持一致，便于 diff 验收。
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
	var out: Dictionary = {"done": false, "cursor": _generator._season_round_b_plus_publish_cursor, "work_done": 0}
	if not _generator._season_round_b_plus_publish_active:
		out["done"] = true
		return out
	if map == null:
		_generator._season_round_b_plus_publish_active = false
		out["done"] = true
		return out
	var n: int = map.cell_count()
	var terrain_a: PackedByteArray = map.terrain_arr
	var landform_a: PackedByteArray = map.landform_arr
	var vegetation_a: PackedByteArray = map.vegetation_arr
	var cover_a: PackedByteArray = map.cover_arr
	var water_a: PackedByteArray = map.is_water_arr
	var volcano_a: PackedByteArray = map.has_volcano_arr
	var cells: Array = map.iter_cells() if map.has_indices() else map.all_cells()
	var water_lut: PackedByteArray = MapData.is_water_lut()
	var volcano_lf: int = int(LandformType.LF.VOLCANO)
	var cursor: int = clampi(_generator._season_round_b_plus_publish_cursor, 0, n)
	var start_cursor: int = cursor
	var end: int = mini(n, cursor + clampi(max_cells, 32, 256))
	while cursor < end:
		if cursor < volcano_a.size() and int(volcano_a[cursor]) != 0 and cursor < landform_a.size() \
				and int(landform_a[cursor]) != volcano_lf:
			landform_a[cursor] = volcano_lf
			if cursor < map.base_landform_arr.size():
				map.base_landform_arr[cursor] = volcano_lf
		var cell: HexCell = cells[cursor] if cursor < cells.size() else null
		if cell != null:
			var terrain_changed: bool = cursor < terrain_a.size() and int(cell.terrain) != int(terrain_a[cursor])
			if terrain_changed:
				cell.apply_terrain(int(terrain_a[cursor]))
				_generator._season_round_b_plus_publish_terrain_fixed += 1
			if cursor < terrain_a.size() and cursor < water_a.size():
				water_a[cursor] = water_lut[int(terrain_a[cursor]) & 0xFF]
			var landform_changed: bool = cursor < landform_a.size() and int(cell.landform) != int(landform_a[cursor])
			var vegetation_changed: bool = cursor < vegetation_a.size() and int(cell.vegetation) != int(vegetation_a[cursor])
			var cover_changed: bool = cursor < cover_a.size() and int(cell.cover) != int(cover_a[cursor])
			if landform_changed:
				cell.landform = int(landform_a[cursor])
			if vegetation_changed:
				cell.vegetation = int(vegetation_a[cursor])
			if cover_changed:
				cell.cover = int(cover_a[cursor])
			if landform_changed or vegetation_changed or cover_changed:
				_generator._season_round_b_plus_publish_axis_fixed += 1
			if (terrain_changed or landform_changed or vegetation_changed or cover_changed) \
					and cell.current_state != null and not cell.current_state.is_empty():
				cell.current_state["biome"] = int(cell.terrain)
				cell.current_state["landform"] = int(cell.landform)
				cell.current_state["vegetation"] = int(cell.vegetation)
				cell.current_state["cover"] = int(cell.cover)
				_generator._season_round_b_plus_publish_state_fixed += 1
			# Preserve one history sample per completed round without per-cell method
			# calls. The direct writes are identical to HexCell.push_*_history().
			if cell.biome_history.size() < HexCell.HISTORY_LEN:
				cell.biome_history.resize(HexCell.HISTORY_LEN)
				for h in range(HexCell.HISTORY_LEN):
					cell.biome_history[h] = int(cell.terrain) & 0xFF
			cell.biome_history[cell._history_idx] = int(cell.terrain) & 0xFF
			cell._history_idx = (cell._history_idx + 1) % HexCell.HISTORY_LEN
			if cell.vegetation_history.size() < HexCell.HISTORY_LEN:
				cell.vegetation_history.resize(HexCell.HISTORY_LEN)
				for h in range(HexCell.HISTORY_LEN):
					cell.vegetation_history[h] = int(cell.vegetation) & 0xFF
			cell.vegetation_history[cell._veg_history_idx] = int(cell.vegetation) & 0xFF
			cell._veg_history_idx = (cell._veg_history_idx + 1) % HexCell.HISTORY_LEN
		cursor += 1
	_generator._season_round_b_plus_publish_cursor = cursor
	out["cursor"] = cursor
	out["work_done"] = cursor - start_cursor
	if cursor < n:
		return out
	if landform_a.size() == n:
		map.landform_arr = landform_a
	_generator._write_runtime_enum_axes_dense(map)
	_generator._season_round_b_plus_publish_active = false
	_generator._season_round_b_plus_facade_published = true
	_generator._last_season_refresh_breakdown["terrain_facade_fixed"] = _generator._season_round_b_plus_publish_terrain_fixed
	_generator._last_season_refresh_breakdown["axis_facade_fixed"] = _generator._season_round_b_plus_publish_axis_fixed
	_generator._last_season_refresh_breakdown["current_state_fixed"] = _generator._season_round_b_plus_publish_state_fixed
	var wall_ms_now: float = float(Time.get_ticks_usec() - _generator._b_plus_round_start_usec) / 1000.0 \
			if _generator._b_plus_round_start_usec > 0 else 0.0
	_generator._b_plus_rounds_total += 1
	_generator._b_plus_rounds_b_plus += 1
	_generator._b_plus_slices_used_samples.append(_generator._season_round_b_plus_slices_used)
	_generator._b_plus_stages_done_samples.append(_generator._season_round_b_plus_stages_done)
	_generator._b_plus_native_ms_samples.append(_generator._season_round_b_plus_native_ms)
	_generator._b_plus_wall_ms_samples.append(wall_ms_now)
	_generator._season_round_b_plus_native_ms = 0.0
	_generator._season_round_b_plus_slices_used = 0
	_generator._season_round_b_plus_stages_done = 0
	_generator._b_plus_round_start_usec = 0
	out["done"] = true
	return out


# 一次性取走 B+ round 验收样本，清零内部计数。
# 由 dots_final_frontier_perf_verdict.evaluate 调用，避免长期持有。

func pop_b_plus_round_samples() -> Dictionary:
	var slices_arr: Array = []
	for v in _generator._b_plus_slices_used_samples:
		slices_arr.append(int(v))
	var stages_arr: Array = []
	for v in _generator._b_plus_stages_done_samples:
		stages_arr.append(int(v))
	var native_arr: Array = []
	for v in _generator._b_plus_native_ms_samples:
		native_arr.append(float(v))
	var wall_arr: Array = []
	for v in _generator._b_plus_wall_ms_samples:
		wall_arr.append(float(v))
	var out: Dictionary = {
		"rounds_total": _generator._b_plus_rounds_total,
		"rounds_b_plus": _generator._b_plus_rounds_b_plus,
		"rounds_fallback": _generator._b_plus_rounds_fallback,
		"slices_used_samples": slices_arr,
		"stages_done_samples": stages_arr,
		"native_ms_samples": native_arr,
		"wall_ms_samples": wall_arr,
	}
	_generator._b_plus_rounds_total = 0
	_generator._b_plus_rounds_b_plus = 0
	_generator._b_plus_rounds_fallback = 0
	_generator._b_plus_slices_used_samples.clear()
	_generator._b_plus_stages_done_samples.clear()
	_generator._b_plus_native_ms_samples.clear()
	_generator._b_plus_wall_ms_samples.clear()
	return out


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


# 2026-05-19：透传 SUS 滚动窗口的 skipped reason 累计 + max_ms。
# 用途：DebugConsole 快照导出 + 性能分析时识别"长期被节流"的 Job。

func _get_native_daily_bundle_builder() -> RefCounted:
	if _generator._native_daily_bundle_builder == null:
		_generator._native_daily_bundle_builder = _generator.NativeDailyBundleBuilderScript.new()
		_generator._native_daily_bundle_builder._generator = _generator
	return _generator._native_daily_bundle_builder


func _get_native_daily_publish() -> RefCounted:
	if _generator._native_daily_publish == null:
		_generator._native_daily_publish = _generator.NativeDailyPublishScript.new()
		_generator._native_daily_publish._generator = _generator
	return _generator._native_daily_publish


func _get_runtime_climate_capture() -> RefCounted:
	if _generator._runtime_climate_capture == null:
		_generator._runtime_climate_capture = _generator.RuntimeClimateCaptureScript.new()
		_generator._runtime_climate_capture._generator = _generator
	return _generator._runtime_climate_capture


func _get_season_refresh_coordinator() -> RefCounted:
	if _generator._season_refresh_coordinator == null:
		_generator._season_refresh_coordinator = _generator.SeasonRefreshCoordinatorScript.new()
		_generator._season_refresh_coordinator._generator = _generator
	return _generator._season_refresh_coordinator

func _get_map_resource_initializer() -> RefCounted:
	if _generator._map_resource_initializer == null:
		_generator._map_resource_initializer = _generator.MapResourceInitializerScript.new()
		_generator._map_resource_initializer._generator = _generator
	return _generator._map_resource_initializer


func _get_map_runtime_bridge() -> RefCounted:
	if _generator._map_runtime_bridge == null:
		_generator._map_runtime_bridge = _generator.MapRuntimeBridgeScript.new()
		_generator._map_runtime_bridge._generator = _generator
	return _generator._map_runtime_bridge


func _get_map_rules_initializer() -> RefCounted:
	if _generator._map_rules_initializer == null:
		_generator._map_rules_initializer = _generator.MapRulesInitializerScript.new()
		_generator._map_rules_initializer._generator = _generator
	return _generator._map_rules_initializer


func _get_map_country_initializer() -> RefCounted:
	if _generator._map_country_initializer == null:
		_generator._map_country_initializer = _generator.MapCountryInitializerScript.new()
		_generator._map_country_initializer._generator = _generator
	return _generator._map_country_initializer



func _get_native_generation_bridge() -> RefCounted:
	if _generator._native_generation_bridge == null:
		_generator._native_generation_bridge = _generator.NativeGenerationBridgeScript.new()
		_generator._native_generation_bridge._generator = _generator
	return _generator._native_generation_bridge


