extends RefCounted

## Coordinates native weather stage-A and publishes the completed weather LUT.


static func publish_weather_lut_after_weather_commit(context, map: MapData, world: WorldData, native_lut: PackedByteArray = PackedByteArray(), force_changed: bool = false) -> Dictionary:
	if context._generator._baker == null or map == null or world == null:
		return {"path": "weather_lut_inline", "fallback": true, "reason": "missing_inputs"}
	var report: Dictionary
	if not native_lut.is_empty() and context._generator._baker.has_method("publish_weather_lut_bytes_from_native"):
		report = context._generator._baker.publish_weather_lut_bytes_from_native(native_lut, world, force_changed)
	else:
		report = context._generator._baker.refresh_weather_lut_from_weather(map, world)
	report["path"] = "weather_lut_inline"
	return report

# plan/weather-refresh-cpp-all PR-2：weather refresh daily 合并 facade。
#
# 单次 cpp call 把 field_solve + distribute + summary_fronts + cyclone_wake + stage_b
# 5 段 pass 跑完，跳过 GDScript ↔ C++ 3 次 marshal + 多次 Dictionary 装包。当 cp.use_gdext_weather_refresh_daily=true
# 且 ext 已 bound + has_method 时由 SUS WeatherRefreshJob 优先选用本入口；任何前置不
# 满足或 cpp rc!=0 时**透明回退**到 refresh_daily_stage_a + refresh_daily_stage_b 老链，
# 对 caller 完全无感。
#
# 与 stage_a/stage_b 的语义对应：
#   - stage_a (tick_one_day) ⇒ cpp 段 1-4：field_solve / distribute / summary / cyclone_wake
#   - stage_b ⇒ cpp 段 5：albedo / veg_dyn / feedback
#
# 通报字段 1:1 沿用 stage_b 末尾的 _last_weather_breakdown 协议（path 字段标 "gdext_combined"
# 让 perf overlay 能区分慢速 GDScript 链与 fast cpp 链）；同时 stage_b 的 enum_atlas
# dirty mark 必须由本 facade 主动调用，因为合并 path 完全跳过了 stage_b GDScript 入口。

static func refresh_weather_daily(context, map: MapData, world: WorldData, season_idx: int,
		climate_anomaly: float, season_phase: float = -1.0) -> Array[WeatherFront]:
	# Step 1：前置 gate。任何一项失败立即 fallback 到老链，让 caller 透明感知。
	if context._generator._weather_system == null or map == null or world == null:
		return context._generator.refresh_daily_stage_a(map, world, season_idx, climate_anomaly, season_phase)
	var cp_now = context._generator._c()
	# dots-flag-prune-pr1 round 2: use_gdext_weather_refresh_daily flag 已删除——
	# 恒走 ext + has_method(run_weather_refresh_daily_pass) + weather_system has_method
	# 探测分支（任一缺失透明 fallback 到老链 stage_a + stage_b）。
	if context._generator._data_core_world_ext == null :
		var fb: Array[WeatherFront] = context._generator.refresh_daily_stage_a(map, world, season_idx, climate_anomaly, season_phase)
		context._generator.refresh_daily_stage_b(map, world)
		return fb
	if not context._generator._weather_system.has_method("try_run_refresh_daily_combined_gdext"):
		var fc: Array[WeatherFront] = context._generator.refresh_daily_stage_a(map, world, season_idx, climate_anomaly, season_phase)
		context._generator.refresh_daily_stage_b(map, world)
		return fc

	# Step 2：sliced stage 不应混用合并模式（_round_active 状态由 sliced 路径维护，
	# 由 weather_refresh_job 的 _should_use_merged_native_weather 互斥保证）。这里再
	# 做 defensive：合并 path 必须自己刷新 _round_t0 计时基准，与 stage_b 的 total_ms 算法对齐。
	context._generator._last_world = world
	context._generator._weather_round_t0_us = Time.get_ticks_usec()

	# Step 3：把 stage_b call_index 推进，保持 stride 计数与 stage_b 老链 1:1 对齐。
	# （即便后续 ok=false 走 fallback 老链，老 stage_b 也会再 ++ 一次 — 这是 stride 二次
	# 推进的旧问题，但它本就只在合并失败的"半冷启动"几 tick 出现，不影响周期 stride 节奏。
	# 为最大兼容，这里仍按 stage_b 同步 ++，若 fallback 触发则在 fallback 分支里手动回滚。）
	var prev_call_index: int = context._generator._weather_stage_b_call_index
	context._generator._weather_stage_b_call_index += 1
	var stage_b_knobs: Dictionary = context._generator._get_native_daily_bundle_builder()._build_native_daily_stage_b_knobs(
		map,
		cp_now,
		maxi(0, context._generator._weather_stage_b_call_index)
	)

	# Step 4：单次 cpp call。weather_system.try_run_refresh_daily_combined_gdext
	# 内部 begin_field_solve → super_knobs merge → run_weather_refresh_daily_pass →
	# unpack fronts + cyclone mirror，stage_b knobs 由本 facade 注入。
	var res: Dictionary = context._generator._weather_system.try_run_refresh_daily_combined_gdext(
		map, world, season_idx, climate_anomaly, season_phase, stage_b_knobs
	)
	var ok: bool = bool(res.get("ok", false))
	if not ok:
		# Fallback 路径：先回滚 stage_b call_index（让老 stage_b 自己重新 ++），
		# 然后透明走 stage_a + stage_b 老链。fail_stage 会在 weather_system
		# 内部首次失败时打 push_warning（节流单次），无需在此重复。
		context._generator._weather_stage_b_call_index = prev_call_index
		var fronts_fb: Array[WeatherFront] = context._generator.refresh_daily_stage_a(
			map, world, season_idx, climate_anomaly, season_phase
		)
		context._generator.refresh_daily_stage_b(map, world)
		return fronts_fb

	# Step 5：成功路径。同步生成器侧通报状态。
	var fronts_out: Array[WeatherFront] = res.get("fronts", [] as Array[WeatherFront])
	context._generator._last_active_fronts = fronts_out
	context._generator._weather_round_fronts = fronts_out
	# breakdown：weather_system 已经按 path="gdext_combined" + 各段 ms 装好；外部 perf
	# overlay / SUS publish 直接读 _last_weather_breakdown 即可。
	var br: Dictionary = res.get("breakdown", {})
	context._generator._diagnostics_bus.replace_weather_breakdown(br, context._generator._current_fast_tick_idx)
	# 方案 ④ Step 1：标记本帧 fast tick，perf_recorder 据此过滤 stale 回放
	# 5/21 突刺诊断：weather_tick≥5ms 或 cyclone≥3ms 时打全字段
	context._generator._dump_weather_breakdown_if_slow()
	# weather_round_tick_ms 用于 sliced 路径与本路径共享 perf 字段：取 advance+distribute+summary 段
	# 之和（与 stage_a 老链的 weather_tick_ms 对应概念，cyclone/stage_b 之外的"主 tick"耗时）。
	context._generator._weather_round_tick_ms = float(br.get("advance_ms", 0.0)) \
			+ float(br.get("distribute_ms", 0.0)) \
			+ float(br.get("summary_ms", 0.0))

	# Step 6：合并 path 完全绕过了 stage_b GDScript 入口，所以 enum_atlas dirty mark 必须由
	# 本 facade 主动触发——否则 baker 收不到 cover/vegetation 改动信号导致视觉残影。
	#   - cover_dirty: weather distribute 段（BLIZZARD→SNOW 等）由 cpp 在 run_distribute 内
	#     直接写 cell.cover；mark cover dirty 让 baker 重烘。
	#   - vegetation_dirty: cpp veg_dyn 段返回 succession_indices / succession_to_veg；非空
	#     即视为 vegetation 有改动。
	var merged_succession_indices: PackedInt32Array = br.get(
		"succession_indices", PackedInt32Array())
	var merged_succession_to_vegetation: PackedByteArray = br.get(
		"succession_to_veg", PackedByteArray())
	var merged_succession_applied: int = context._generator._get_native_daily_publish()._apply_vegetation_succession_candidates(
		map, merged_succession_indices, merged_succession_to_vegetation, cp_now)
	br["succession_applied_count"] = merged_succession_applied
	context._generator._diagnostics_bus.merge_weather_breakdown({"succession_applied_count": merged_succession_applied})
	if context._generator._baker != null:
		if context._generator._weather_system.has_method("has_cover_dirty") and bool(context._generator._weather_system.has_cover_dirty()):
			context._generator._mark_enum_atlas_dirty(true, false)
		var veg_dirty: bool = merged_succession_applied > 0
		if veg_dirty:
			context._generator._mark_enum_atlas_dirty(false, true)

	return fronts_out

static func weather_native_daily_readiness_report(context) -> Dictionary:
	var n_cells: int = context._generator._sus_map.cell_count() if context._generator._sus_map != null else 0
	var report: Dictionary = {
		"ready": false,
		"reason": "",
		"n_cells": n_cells,
		"has_ext": context._generator._data_core_world_ext != null,
		"has_weather_system": context._generator._weather_system != null,
		"has_combined_method": false,
		"has_commit_method": false,
		"has_knobs_builder": false,
		"has_result_apply": false,
		"has_weather_lut_publish": context.has_method("publish_weather_lut_after_weather_commit"),
		"field_commit_path": str(context._generator._diagnostics_bus.get_weather_breakdown().get("field_commit_path", "")),
		"field_commit_publish_verified": bool(context._generator._diagnostics_bus.get_weather_breakdown().get("field_commit_publish_verified", false)),
		"field_commit_publish_repaired": bool(context._generator._diagnostics_bus.get_weather_breakdown().get("field_commit_publish_repaired", false)),
		"field_commit_init_count": int(context._generator._diagnostics_bus.get_weather_breakdown().get("field_commit_init_count", 0)),
		"field_commit_publish_reason": str(context._generator._diagnostics_bus.get_weather_breakdown().get("field_commit_publish_reason", "")),
	}
	if context._generator._data_core_world_ext != null:
		report["has_combined_method"] = true
		report["has_commit_method"] = true
	if context._generator._weather_system != null:
		report["has_knobs_builder"] = context._generator._weather_system.has_method("build_unified_fast_tick_weather_knobs")
		report["has_result_apply"] = context._generator._weather_system.has_method("apply_unified_fast_tick_result")
	if n_cells <= 0:
		report["reason"] = "no_cells"
		return report
	if not bool(report["has_ext"]):
		report["reason"] = "missing_world_ext"
		return report
	if not bool(report["has_weather_system"]):
		report["reason"] = "missing_weather_system"
		return report
	if not bool(report["has_combined_method"]):
		report["reason"] = "missing_run_weather_refresh_daily_pass"
		return report
	if not bool(report["has_commit_method"]):
		report["reason"] = "missing_run_weather_field_commit_pass"
		return report
	if not bool(report["has_knobs_builder"]):
		report["reason"] = "missing_unified_knobs_builder"
		return report
	if not bool(report["has_result_apply"]):
		report["reason"] = "missing_unified_result_apply"
		return report
	if not bool(report["has_weather_lut_publish"]):
		report["reason"] = "missing_weather_lut_publish"
		return report
	var commit_path: String = str(report["field_commit_path"])
	if commit_path == "":
		report["reason"] = "no_verified_staged_commit_yet"
		return report
	if not bool(report["field_commit_publish_verified"]):
		report["reason"] = "field_commit_not_publish_verified"
		return report
	if bool(report["field_commit_publish_repaired"]):
		report["reason"] = "field_commit_required_gdscript_repair"
		return report
	if int(report["field_commit_init_count"]) < n_cells:
		report["reason"] = "field_init_incomplete_%d_of_%d" % [
			int(report["field_commit_init_count"]),
			n_cells,
		]
		return report
	report["ready"] = true
	report["reason"] = "verified_visible_publish"
	return report

static func refresh_daily_stage_a(context, map: MapData, world: WorldData, season_idx: int,
		climate_anomaly: float, season_phase: float = -1.0) -> Array[WeatherFront]:
	if context._generator._weather_system == null or map == null or world == null:
		return [] as Array[WeatherFront]
	context._generator._last_world = world
	# 重置当轮分段计时；stage_b 完成后再写 total_ms / 各 ms。
	context._generator._weather_round_t0_us = Time.get_ticks_usec()
	var t_us0: int = Time.get_ticks_usec()
	var fronts = context._generator._weather_system.tick_one_day(map, world, season_idx, climate_anomaly, season_phase)
	context._generator._weather_round_tick_ms = (Time.get_ticks_usec() - t_us0) / 1000.0
	context._generator._last_active_fronts = fronts
	context._generator._weather_round_fronts = fronts
	return fronts

static func weather_field_slice_cells(context) -> int:
	var cp_now = context._generator._c()
	if cp_now == null:
		return 2400
	var n_cells: int = context._generator._sus_map.cell_count() if context._generator._sus_map != null else 0
	if n_cells > 0 and n_cells <= 6400 \
			and context._generator._data_core_world_ext != null \
			and context._generator._weather_system != null \
			and context._generator._weather_system.has_method("uses_weather_field") \
			and bool(context._generator._weather_system.uses_weather_field()):
		return n_cells
	return clampi(int(cp_now.weather_field_slice_cells), 100, 6400)

static func begin_weather_refresh_stage_a(context, map: MapData, world: WorldData, season_idx: int,
		climate_anomaly: float, season_phase: float = -1.0) -> void:
	if context._generator._weather_system == null or map == null or world == null:
		return
	context._generator._last_world = world
	context._generator._weather_round_t0_us = Time.get_ticks_usec()
	if context._generator._weather_system.has_method("begin_weather_field_solve"):
		context._generator._weather_system.begin_weather_field_solve(map, world, season_idx, climate_anomaly, season_phase)

static func run_weather_refresh_stage_a_slice(context, cell_budget: int) -> Dictionary:
	if context._generator._weather_system == null or not context._generator._weather_system.has_method("run_weather_field_solve_slice"):
		return { "done": true, "work_done": 0, "elapsed_ms": 0.0, "progress_ratio": 1.0 }
	var result: Dictionary = context._generator._weather_system.run_weather_field_solve_slice(maxi(1, cell_budget))
	var elapsed_ms: float = float(result.get("elapsed_ms", 0.0))
	var processed_cells: int = int(result.get("processed_cells", result.get("work_done", 0)))
	var cursor_start: int = int(result.get("cursor_start", -1))
	var cursor_end: int = int(result.get("cursor_end", -1))
	var sub: Dictionary = context._generator._weather_system.last_breakdown() if context._generator._weather_system.has_method("last_breakdown") else {}
	var weather_breakdown: Dictionary = {
		"weather_tick_ms": elapsed_ms,
		"advance_ms": elapsed_ms,
		"spawn_ms": 0.0,
		"distribute_ms": 0.0,
		"cyclone_ms": 0.0,
		"weather_field_bake_ms": 0.0,
		"transp_ms": 0.0,
		"albedo_ms": 0.0,
		"veg_dyn_ms": 0.0,
		"cover_rebake_ms": 0.0,
		"veg_rebake_ms": 0.0,
		"feedback_ms": 0.0,
		"total_ms": (Time.get_ticks_usec() - context._generator._weather_round_t0_us) / 1000.0,
		"fronts": context._generator._weather_round_fronts.size(),
		"processed_cells": processed_cells,
		"cursor_start": cursor_start,
		"cursor_end": cursor_end,
		"weather_dirty_count": int(result.get("weather_dirty_count", 0)),
		"water_budget_error": float(result.get("water_budget_error", 0.0)),
		"active_weather_ratio": float(result.get("active_weather_ratio", 0.0)),
		"field_solve_tick": int(sub.get("field_solve_tick", -1)),
		"weather_commit_tick_delta": int(sub.get("weather_commit_tick_delta", 0)),
		"weather_last_commit_tick": int(sub.get("weather_last_commit_tick", -1)),
		"weather_cold_front_count": int(sub.get("weather_cold_front_count", 0)),
		"weather_warm_front_count": int(sub.get("weather_warm_front_count", 0)),
		"field_convergence_refresh_stride": int(sub.get("field_convergence_refresh_stride", 0)),
		"refresh_convergence": bool(sub.get("refresh_convergence", false)),
		"native_convergence_boost": bool(sub.get("native_convergence_boost", false)),
		"weather_convergence_dirty_count": int(sub.get("weather_convergence_dirty_count", 0)),
		"weather_convergence_delta_p95": float(sub.get("weather_convergence_delta_p95", 0.0)),
		"convergence_published": bool(sub.get("convergence_published", false)),
		"partial": not bool(result.get("done", true)),
		"progress_ratio": float(result.get("progress_ratio", 0.0)),
		# 方案 ④ Step 1：标记本帧 fast tick，perf_recorder 据此过滤 stale 回放
		"_tick_idx": context._generator._current_fast_tick_idx,
	}
	context._generator._diagnostics_bus.replace_weather_breakdown(weather_breakdown, context._generator._current_fast_tick_idx)
	# 5/21 突刺诊断：weather_tick≥5ms 或 cyclone≥3ms 时打全字段
	context._generator._dump_weather_breakdown_if_slow()
	return result

static func commit_weather_refresh_stage_a(context, map: MapData, world: WorldData) -> Array[WeatherFront]:
	if context._generator._weather_system == null or map == null or world == null:
		return [] as Array[WeatherFront]
	var fronts: Array[WeatherFront] = [] as Array[WeatherFront]
	if context._generator._weather_system.has_method("commit_weather_field_solve"):
		fronts = context._generator._weather_system.commit_weather_field_solve()
	var sub: Dictionary = context._generator._weather_system.last_breakdown() if context._generator._weather_system.has_method("last_breakdown") else {}
	context._generator._weather_round_tick_ms = float(sub.get("weather_tick_ms", sub.get("field_solve_ms", 0.0)))
	if not sub.is_empty():
		var merged: Dictionary = context._generator._diagnostics_bus.get_weather_breakdown()
		merged.merge(sub, true)
		merged["weather_tick_ms"] = context._generator._weather_round_tick_ms
		merged["weather_field_bake_ms"] = float(merged.get("weather_field_bake_ms", 0.0))
		merged["transp_ms"] = float(merged.get("transp_ms", 0.0))
		merged["albedo_ms"] = float(merged.get("albedo_ms", 0.0))
		merged["veg_dyn_ms"] = float(merged.get("veg_dyn_ms", 0.0))
		merged["cover_rebake_ms"] = float(merged.get("cover_rebake_ms", 0.0))
		merged["veg_rebake_ms"] = float(merged.get("veg_rebake_ms", 0.0))
		merged["feedback_ms"] = float(merged.get("feedback_ms", 0.0))
		merged["total_ms"] = (Time.get_ticks_usec() - context._generator._weather_round_t0_us) / 1000.0
		merged["fronts"] = fronts.size()
		merged["_tick_idx"] = context._generator._current_fast_tick_idx
		context._generator._diagnostics_bus.replace_weather_breakdown(merged, context._generator._current_fast_tick_idx)
	context._generator._last_active_fronts = fronts
	context._generator._weather_round_fronts = fronts
	return fronts
