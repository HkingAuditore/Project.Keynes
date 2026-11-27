extends RefCounted

## Controls the native seasonal round's boundaries and steps.


static func season_round_b_plus_available(context) -> bool:
	if context._generator._data_core_world_ext == null:
		return false
	return true

# 构造 round_knobs：12 stage knobs 的并集。
# 失败（cfg / map / row_table 缺失）返回空 Dictionary，caller 视为 fallback。
# 季节 round-start knob 几何缓存填充。缓存有效（map/cfg/warp 实例 + n_cells 全未变）
# 时直接返回；否则重建 row_indices + rain-shadow jitter 各一次并落缓存。
# 返回 false 表示当前无法构建（cfg/warp 缺失或 size 不符），caller 走 fallback。

static func start_season_round_b_plus(context, map: MapData, _world: WorldData, season: int) -> int:
	if not season_round_b_plus_available(context):
		context._generator._season_log_path_once("b_plus", "gdscript_fallback", "gate fail (cp/ext/method)")
		return 0
	if context._generator.soil_arr_size_mismatch(map):
		context._generator._season_log_path_once("b_plus", "gdscript_fallback", "soil/vg arr size mismatch with n_cells")
		return 0
	# 旧 round 残留（前一个 round 没正常 finish / abort）→ 强制清理。
	if context._generator._season_round_b_plus_handle > 0:
		context._generator._season_log_path_once("b_plus", "stale_handle_abort", "previous handle=%d still active, forcing abort" % context._generator._season_round_b_plus_handle)
		_abort_season_round_b_plus_safe(context)
	context._generator._ensure_season_round_slots_fresh()
	var knobs: Dictionary = context._generator._build_season_round_knobs(map, season)
	if knobs.is_empty():
		context._generator._season_log_path_once("b_plus", "gdscript_fallback", "round_knobs build failed (cfg/map/row_table)")
		return 0
	var res: Dictionary = context._generator._data_core_world_ext.start_season_round(knobs)
	if res.is_empty() or bool(res.get("fallback", true)):
		context._generator._season_log_path_once("b_plus", "gdscript_fallback", "start_season_round returned fallback: %s" % String(res.get("reason", "unknown")))
		return 0
	var handle: int = int(res.get("handle", 0))
	if handle <= 0:
		context._generator._season_log_path_once("b_plus", "gdscript_fallback", "start_season_round returned invalid handle=%d" % handle)
		return 0
	context._generator._season_round_b_plus_handle = handle
	context._generator._season_round_b_plus_native_ms = 0.0
	context._generator._season_round_b_plus_slices_used = 0
	context._generator._season_round_b_plus_stages_done = 0
	context._generator._b_plus_round_start_usec = Time.get_ticks_usec()
	var path := "gdext"
	context._generator._last_season_refresh_breakdown["b_plus_path"] = path
	context._generator._last_season_refresh_breakdown["b_plus_handle"] = handle
	context._generator._season_log_path_once("b_plus_start", path, "handle=%d season=%d n_cells=%d" % [handle, season, int(knobs.get("n_cells", 0))])
	return handle

# B+ 入口 2/3：推进一个 slice，stage-boundary 切片（b1）。
# max_usec：单 slice 预算（默认从 cp.sim_slice_budget_ms 取）。
# 返回字典 { "done": bool, "stages_done": int, "elapsed_ms": float, "fallback": bool }。
# 任一异常（handle 无效 / fallback / mid-slice 错误）→ 标记 done=true + fallback=true，
# 上层 caller 应放弃 round 并退回 12-stage 路径补完。

static func run_season_round_slice_b_plus(context, _map: MapData, _world: WorldData, max_usec: int = 0) -> Dictionary:
	var out: Dictionary = {
		"done": false,
		"stages_done": context._generator._season_round_b_plus_stages_done,
		"elapsed_ms": 0.0,
		"fallback": false,
	}
	if context._generator._season_round_b_plus_handle <= 0:
		out["fallback"] = true
		out["done"] = true
		context._generator._season_log_path_once("b_plus_slice", "gdscript_fallback", "no active handle")
		return out
	if context._generator._data_core_world_ext == null:
		out["fallback"] = true
		out["done"] = true
		context._generator._season_log_path_once("b_plus_slice", "gdscript_fallback", "ext/method missing mid-round")
		_abort_season_round_b_plus_safe(context)
		return out
	var budget_us: int = max_usec
	if budget_us <= 0:
		var cp: ClimateProfile = context._generator._c()
		var ms: float = 0.55
		if cp != null and cp.get("sim_slice_budget_ms") != null:
			ms = float(cp.sim_slice_budget_ms)
		budget_us = maxi(50, int(round(ms * 1000.0)))
	budget_us = clampi(budget_us, 50, 1000)
	var res: Dictionary = context._generator._data_core_world_ext.run_season_round_slice(context._generator._season_round_b_plus_handle, budget_us)
	if bool(res.get("pending", false)):
		return {"done": false, "pending": true}
	if res.is_empty() or bool(res.get("fallback", false)):
		var completed_before_fallback: int = int(res.get(
				"stages_done", res.get("stage", context._generator._season_round_b_plus_stages_done)))
		out["stages_done"] = max(context._generator._season_round_b_plus_stages_done, completed_before_fallback)
		out["fallback"] = true
		out["done"] = true
		context._generator._season_log_path_once("b_plus_slice", "gdscript_fallback", "run_season_round_slice fallback: %s" % String(res.get("reason", "unknown")))
		# 让 C++ 端清掉残留状态（next round 才能干净开新）。
		_abort_season_round_b_plus_safe(context)
		return out
	var elapsed_ms: float = float(res.get("elapsed_ms", 0.0))
	context._generator._season_round_b_plus_native_ms += elapsed_ms
	context._generator._season_round_b_plus_slices_used += 1
	# C++ returns both the absolute stage cursor and the compatibility
	# `stages_done` field.  Prefer the explicit total, but accept `stage` from an
	# older DLL so a hot-reloaded script cannot reset a completed round to zero.
	var reported_stages_done: int = int(res.get(
			"stages_done", res.get("stage", context._generator._season_round_b_plus_stages_done)))
	context._generator._season_round_b_plus_stages_done = max(context._generator._season_round_b_plus_stages_done, reported_stages_done)
	out["elapsed_ms"] = elapsed_ms
	out["stages_done"] = context._generator._season_round_b_plus_stages_done
	out["done"] = bool(res.get("done", false))
	return out

# Complete the Godot facade and history mirror before capturing the next input.

static func begin_finish_season_round_b_plus(context, map: MapData, _world: WorldData, _season: int) -> void:
	if context._generator._season_round_b_plus_handle <= 0:
		context._generator._season_log_path_once("b_plus_finish", "gdscript_fallback", "no active handle to finish")
		return
	var ext_ok: bool = context._generator._data_core_world_ext != null
	if not ext_ok:
		context._generator._season_log_path_once("b_plus_finish", "gdscript_fallback", "finish_season_round method missing")
		context._generator._season_round_b_plus_handle = 0
		return
	var res: Dictionary = context._generator._data_core_world_ext.finish_season_round(context._generator._season_round_b_plus_handle)
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
	context._generator._last_season_refresh_breakdown["b_plus_native_ms"] = float(res.get("total_native_ms", context._generator._season_round_b_plus_native_ms))
	context._generator._last_season_refresh_breakdown["b_plus_slices_used"] = int(res.get("slices_used", context._generator._season_round_b_plus_slices_used))
	context._generator._last_season_refresh_breakdown["b_plus_stages_done"] = int(res.get("stages_done", context._generator._season_round_b_plus_stages_done))
	if fallback:
		context._generator._season_log_path_once("b_plus_finish", "gdscript_fallback", "finish_season_round fallback: %s" % String(res.get("reason", "unknown")))
	else:
		context._generator._season_log_path_once("b_plus_finish", "gdext", "native_ms=%.3f slices=%d stages_done=%d" % [
				float(res.get("total_native_ms", context._generator._season_round_b_plus_native_ms)),
				int(res.get("slices_used", context._generator._season_round_b_plus_slices_used)),
				int(res.get("stages_done", context._generator._season_round_b_plus_stages_done)),
		])
	context._generator._season_round_b_plus_handle = 0
	context._generator._season_round_b_plus_publish_active = map != null and map.cell_count() > 0
	context._generator._season_round_b_plus_publish_cursor = 0
	context._generator._season_round_b_plus_facade_published = false
	context._generator._season_round_b_plus_publish_terrain_fixed = 0
	context._generator._season_round_b_plus_publish_axis_fixed = 0
	context._generator._season_round_b_plus_publish_state_fixed = 0

static func _abort_season_round_b_plus_safe(context) -> void:
	if context._generator._data_core_world_ext != null:
		context._generator._data_core_world_ext.abort_season_round()
	context._generator._season_round_b_plus_handle = 0
	context._generator._season_round_b_plus_native_ms = 0.0
	context._generator._season_round_b_plus_slices_used = 0
	context._generator._season_round_b_plus_stages_done = 0
	context._generator._season_round_b_plus_publish_active = false
	context._generator._season_round_b_plus_publish_cursor = 0
	context._generator._season_round_b_plus_facade_published = false
	# abort 不算完整 round（不进 _b_plus_rounds_total 计数），仅清 start usec。
	context._generator._b_plus_round_start_usec = 0
