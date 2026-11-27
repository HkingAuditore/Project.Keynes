extends RefCounted

## Drives the retained manual tick path and maintains its counters.


static func sus_tick_daily(context, world_clock_node, day_index_override: int = -1,
		season_phase_override: float = NAN) -> Dictionary:
	if context._generator._sus == null:
		return { "fronts": [] as Array[WeatherFront], "weather_ran": false }
	var di: int = 0
	var sp: float = 0.0
	var ss: float = 1.0
	if world_clock_node != null:
		if world_clock_node.has_method("day_index"):
			di = int(world_clock_node.day_index())
		if world_clock_node.has_method("season_phase"):
			sp = float(world_clock_node.season_phase())
		# WorldClock.speed_multiplier 是普通成员变量；用 get() 安全读取。
		var v = world_clock_node.get("speed_multiplier")
		if v != null:
			ss = float(v)
	if day_index_override >= 0:
		di = day_index_override
	if not is_nan(season_phase_override):
		sp = season_phase_override
	# Release older reference slices before capturing the dated input for this tick.
	var trace_input_day: int = maxi(maxi(0, di - 1),
		context._generator._get_runtime_climate_capture().next_environment_day() - 1)
	var runtime_climate_pre_reference: Dictionary = \
		context._generator._get_runtime_climate_capture()._publish_ready_runtime_climate_references(trace_input_day - 1, context._generator._sus_map)
	var runtime_climate_capture: Dictionary = \
		context._generator._get_runtime_climate_capture().publish_environment_through(trace_input_day, sp, context._generator.ENV_CALLSITE_SUS_TICK)
	if bool(context._generator.get_runtime_control_state().get("whole_graph_requested", false)):
		return {"worker_managed": true, "runtime_climate_capture": runtime_climate_capture}
	# 任务 8：每个 tick 入场前清掉 weather_refresh 的 ran_this_tick 标志，
	# 这样 SUS 决定跳过该 Job 时它就保持 false（main.gd 据此跳过 UI 行刷新）。
	if context._generator._refresh_climate_daily_job != null:
		context._generator._refresh_climate_daily_job.reset_run_flag()
	if context._generator._sea_ice_daily_job != null and context._generator._sea_ice_daily_job.has_method("reset_run_flag"):
		context._generator._sea_ice_daily_job.reset_run_flag()
	if context._generator._weather_refresh_job != null:
		context._generator._weather_refresh_job.reset_run_flag()
	if context._generator._native_daily_sim_job != null and context._generator._native_daily_sim_job.has_method("reset_run_flag"):
		context._generator._native_daily_sim_job.reset_run_flag()
	var ctx: SusTickContext = SusTickContext.make(di, di, sp, ss, &"day_changed")
	context._generator._sync_data_core_runtime_terrain_mirror(context._generator._sus_map, "sus_tick_pre")
	context._generator._sus.tick(ctx)
	var runtime_graph_pulse: Dictionary = {}
	if context._generator._runtime_graph_active and not context._generator.native_daily_round_active() \
			and not context._generator.bio_occupancy_round_active():
		runtime_graph_pulse = context._generator._advance_runtime_graph_pulse(di)
	# Bio remains daily-semantic even when its first slice loses the ordinary
	# frame-budget race. Convert that skip into a same-day pending transaction;
	# the continuation pulse starts it before WorldClock may advance.
	var sus_tick_report: Dictionary = context._generator._sus.report_last_tick()
	var bio_tick_report: Dictionary = sus_tick_report.get(&"bio_occupancy_daily",
		sus_tick_report.get("bio_occupancy_daily", {}))
	var bio_skip_reason := str(bio_tick_report.get("skipped_reason", ""))
	if context._generator._bio_occupancy_daily_job != null and bio_skip_reason in [
			"frame_budget_exhausted", "strict_budget_one_job"]:
		context._generator._bio_occupancy_day_pending = true
	if not context._generator._bio_occupancy_slice_inflight and bio_skip_reason == "":
		var bio_done_reported := bool(bio_tick_report.get("done", true))
		if bio_done_reported:
			context._generator._bio_occupancy_day_pending = false
	# A manually stepped calendar has no clock frame to finish this date's cell
	# ranges. Complete them with their original inputs before the caller advances.
	var clock_drives_slices: bool = world_clock_node is WorldClock and world_clock_node.is_processing() \
		and not world_clock_node.paused and world_clock_node.speed_multiplier > 0.0
	if not clock_drives_slices:
		while context._generator.bio_occupancy_round_active():
			context._generator._bio_occupancy_day_pending = false
			var slice_result: Dictionary = context._generator._sus.continue_system(&"bio_occupancy_daily", ctx)
			if bool(slice_result.get("fatal", false)):
				return slice_result
	# Native daily has the same same-day transaction boundary as Bio.  A first
	# slice skipped by SUS budget must be started by the continuation pulse before
	# WorldClock is allowed to advance; otherwise that semantic day would be
	# silently lost because the job has not established _native_round_active yet.
	var native_tick_report: Dictionary = sus_tick_report.get(&"native_daily_sim",
		sus_tick_report.get("native_daily_sim", {}))
	var native_skip_reason := str(native_tick_report.get("skipped_reason", ""))
	if context._generator._native_daily_sim_job != null and native_skip_reason in [
			"frame_budget_exhausted", "strict_budget_one_job"]:
		context._generator._native_daily_day_pending = true
	if context._generator._native_daily_sim_job != null and native_skip_reason == "":
		var native_done_reported := bool(native_tick_report.get("done", true))
		if native_done_reported and not bool(context._generator._native_daily_sim_job.get("_native_round_active")):
			context._generator._native_daily_day_pending = false
			# The round reached its immutable boundary, so the captured frame for
			# this day may now be released to the worker.
			context._generator._native_daily_climate_round_generation += 1
	if world_clock_node != null and world_clock_node.has_method("request_simulation_backpressure"):
		world_clock_node.request_simulation_backpressure(
			&"native_daily_day_barrier", context._generator.native_daily_round_active())
		world_clock_node.request_simulation_backpressure(
			&"bio_occupancy_day_barrier", context._generator.bio_occupancy_round_active())
	if context._generator._native_daily_sim_job == null:
		context._generator._run_native_daily_shadow_probe(ctx, context._generator._sus_map, context._generator._sus_world)
	var fronts: Array[WeatherFront] = [] as Array[WeatherFront]
	var weather_ran: bool = false
	# Drift-fix（2026-05-10）：暴露"fronts 是否真的变了"标志。
	# 与 weather_ran 区别：field 分片期间二者都保持 false；只有 commit + stage_b
	# 完成、_last_fronts 重新赋值时才置位，避免 UI/renderer 读取半成品。
	# main.gd 用它 gate renderer.set_weather_fronts 调用，避免每隔一 tick 重复推送
	# 同一份 fronts 触发 weather_layer 内部的 blend reset → 云视觉冻结。
	var fronts_changed: bool = false
	var fronts_diff: Dictionary = {}
	if context._generator._weather_refresh_job != null:
		fronts = context._generator._weather_refresh_job.last_fronts()
		weather_ran = context._generator._weather_refresh_job.did_run_last_tick()
		fronts_changed = context._generator._weather_refresh_job.did_change_fronts_last_tick()
		if context._generator._weather_refresh_job.has_method("last_fronts_diff_report"):
			fronts_diff = context._generator._weather_refresh_job.last_fronts_diff_report()
	elif context._generator._native_daily_sim_job != null:
		var native_res: Dictionary = context._generator._native_daily_last_result
		weather_ran = int(native_res.get("rc", -1)) == 0
		fronts_changed = bool(native_res.get("fronts_changed", false))
		for f in native_res.get("fronts", []):
			if f is WeatherFront:
				fronts.append(f)
		fronts_diff = native_res.get("fronts_diff", {})
	if weather_ran and context._generator._sus_map != null:
		var cyclone_snapshot: Dictionary = {}
		if context._generator._data_core_world_ext != null :
			cyclone_snapshot = context._generator._data_core_world_ext.get_active_cyclone_snapshot()
		context._generator.WeatherResearchSignalPublisherScript.publish(
			context._generator._sus_map, context._generator._country_facade, context._generator._gameplay_event_bus, di, cyclone_snapshot)
	# 天气类型交叉淡入的"跳过日 GDScript 兜底"已移除（2026-06-17）：该淡入纯属
	# 视觉平滑，且没有任何 shader 采样 cell.weather_transition_alpha（地图只读离散
	# weather_type），高倍速下逐 cell fan-out 反而是 ~35ms/次的空耗。淡入开关
	# weather_transition_enabled 现仅作用于 C++ weather.commit（跑天气日推进）。
	if world_clock_node != null and world_clock_node.has_method("note_sim_slice_diag"):
		var economy_tick: Dictionary = sus_tick_report.get(&"economy_daily",
			sus_tick_report.get("economy_daily", {}))
		world_clock_node.note_sim_slice_diag({
			"largest_slice_ms": float(sus_tick_report.get("largest_slice_ms", 0.0)),
			"largest_slice_job": str(sus_tick_report.get("largest_slice_job", "")),
			"largest_slice_stage": str(sus_tick_report.get("largest_slice_stage", "")),
			"commit_over_budget": bool(economy_tick.get("commit_over_budget", false)),
			"native_stage": str(native_tick_report.get("stage_name",
				native_tick_report.get("substage", ""))),
		})
	var runtime_climate_reference: Dictionary = \
		context._generator._get_runtime_climate_capture()._publish_ready_runtime_climate_references(trace_input_day, context._generator._sus_map)
	return { "fronts": fronts, "weather_ran": weather_ran, "fronts_changed": fronts_changed,
		"fronts_diff": fronts_diff, "runtime_graph": runtime_graph_pulse,
		"runtime_climate_pre_reference": runtime_climate_pre_reference,
		"runtime_climate_capture": runtime_climate_capture,
		"runtime_climate_reference": runtime_climate_reference,
		"runtime_climate_trace": context._generator._get_runtime_climate_capture().runtime_climate_trace_report(), }

## 地图重新生成 / regenerate 路径调用：清空所有 Job 的进度游标 + pending 缓冲。

static func sus_reset_all(context) -> void:
	context._generator._abort_all_climate_passes("sus_reset_all")
	# A regenerate/restore invalidates every captured frame. The C++ host is
	# stopped by WorldRuntimeHost before this reset, so no stale reference may be
	# released into the next map's trace.
	context._generator._runtime_climate_trace_pending.clear()
	context._generator._runtime_climate_reference_last_day = -1
	context._generator._runtime_climate_reference_last_hash = 0
	context._generator._runtime_climate_reference_last_error = ""
	# Drop same-day transient transactions before a map regenerate/restore. The
	# new world must never inherit a stale Bio/native daily barrier from the old
	# map, even when reset is requested between continuation pulses.
	context._generator._bio_occupancy_slice_inflight = false
	context._generator._bio_occupancy_day_pending = false
	context._generator._native_daily_slice_round_active = false
	context._generator._native_daily_day_pending = false
	context._generator._native_daily_slice_range_active = false
	context._generator._native_daily_finalizer_pending = false
	context._generator._native_daily_finalizer_pending_res = {}
	context._generator._native_daily_finalizer_pending_breakdown = {}
	context._generator._native_daily_slice_active_bundle = {}
	context._generator._native_daily_slice_bundle_pass_keys = []
	context._generator._native_daily_slice_next_node_index = -1
	context._generator._native_daily_slice_unified_weather_embedded = false
	context._generator._native_daily_reset_contract_round()
	if context._generator._world_clock_ref != null and context._generator._world_clock_ref.has_method("request_simulation_backpressure"):
		context._generator._world_clock_ref.request_simulation_backpressure(&"bio_occupancy_day_barrier", false)
		context._generator._world_clock_ref.request_simulation_backpressure(&"native_daily_day_barrier", false)
	context._generator._diagnostics_bus.clear_all()
	if context._generator._sus != null:
		context._generator._sus.reset_all_progress()

static func set_current_fast_tick_idx(context, idx: int) -> void:
	context._generator._current_fast_tick_idx = idx
	# DVA 不持有 generator 引用，单独同步过去；其内部 4 个 _last_breakdown 写入点
	# 直接读 current_fast_tick_idx。
	if context._generator._dynamic_visual_atlas_upload_job != null \
			and "current_fast_tick_idx" in context._generator._dynamic_visual_atlas_upload_job:
		context._generator._dynamic_visual_atlas_upload_job.current_fast_tick_idx = idx
