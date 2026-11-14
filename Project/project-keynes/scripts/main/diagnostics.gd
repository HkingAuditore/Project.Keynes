extends RefCounted

# G5 collaborator. The host owns all mutable state; it is passed per call.

func _publish_fast_tick_perf_sample(host, t_sus_ms: float, t_render_ms: float,
		t_ui_ms: float, fast_ms: float, was_skipped_day: bool) -> Dictionary:
	var perf_ready: bool = host._recorder_ready(host._perf_recorder)
	var tile_ready: bool = host._recorder_ready(host._tile_data_recorder)
	var economy_ready: bool = host._recorder_ready(host._economy_data_recorder)
	var continuation: Dictionary = {}
	if host._generator != null and host._generator.has_method("consume_continuation_perf_summary"):
		continuation = host._generator.consume_continuation_perf_summary()
	if not perf_ready and not tile_ready and not economy_ready:
		return {}
	var t_recorders_us0: int = Time.get_ticks_usec()
	var out: Dictionary = {
		"total_ms": 0.0,
		"perf_ms": 0.0,
		"tile_ms": 0.0,
		"perf_recording": perf_ready,
		"tile_recording": tile_ready,
		"tile_recorded": false,
		"tile_rows": 0,
		"tile_reason": "",
	}
	var sample: Dictionary = {
		"tick_idx": host._fast_tick_count,
		"timestamp_ms": Time.get_ticks_msec(),
		"was_skipped_day": was_skipped_day,
		"fps": Engine.get_frames_per_second(),
		"speed_multiplier": float(host._world_clock.speed_multiplier) if host._world_clock != null else 0.0,
		"fast_ms": fast_ms,
		"t_sus_ms": t_sus_ms,
		"t_render_ms": t_render_ms,
		"t_ui_ms": t_ui_ms,
		"continuation_frames": int(continuation.get("frames", 0)),
		"continuation_slices": int(continuation.get("slices", 0)),
		"continuation_started_slices": int(
			continuation.get("continuation_started_slices", 0)),
		"continuation_completed_slices": int(
			continuation.get("continuation_completed_slices", 0)),
		"continuation_budget_exhausted": bool(
			continuation.get("continuation_budget_exhausted", false)),
		"continuation_budget_overrun_frames": int(
			continuation.get("continuation_budget_overrun_frames", 0)),
		"continuation_max_budget_overrun_ms": float(
			continuation.get("continuation_max_budget_overrun_ms", 0.0)),
		"continuation_blocked_by_stage": str(
			continuation.get("continuation_blocked_by_stage", "")),
		"continuation_country_slices": int(continuation.get("country_slices", 0)),
		"continuation_economy_slices": int(continuation.get("economy_slices", 0)),
		"continuation_wall_ms": float(continuation.get("wall_ms", 0.0)),
		"continuation_max_frame_wall_ms": float(continuation.get("max_frame_wall_ms", 0.0)),
		"continuation_max_slice_ms": float(continuation.get("max_slice_ms", 0.0)),
		"continuation_last_slice_ms": float(continuation.get("last_slice_ms", 0.0)),
		"continuation_budget_ms": float(continuation.get("budget_ms", 0.0)),
		"continuation_last_stage": str(continuation.get("last_stage", "")),
		"continuation_last_next_stage": str(continuation.get("last_next_stage", "")),
		"continuation_last_substage": str(continuation.get("last_substage", "")),
		"continuation_last_path": str(continuation.get("last_path", "")),
		"continuation_done": bool(continuation.get("done", false)),
		"continuation_stage_counts": JSON.stringify(continuation.get("stage_counts", {})),
		"continuation_stage_wall_ms": JSON.stringify(continuation.get("stage_wall_ms", {})),
		"continuation_stage_max_slice_ms": JSON.stringify(
			continuation.get("stage_max_slice_ms", {})),
		"continuation_substage_counts": JSON.stringify(
			continuation.get("substage_counts", {})),
		"continuation_substage_wall_ms": JSON.stringify(
			continuation.get("substage_wall_ms", {})),
		"continuation_substage_max_slice_ms": JSON.stringify(
			continuation.get("substage_max_slice_ms", {})),
		"continuation_substage_work": JSON.stringify(
			continuation.get("substage_work", {})),
	}
	if host._generator != null and host._generator.has_method("sus_climate_breakdown"):
		var climate_diag: Dictionary = host._generator.sus_climate_breakdown()
		if not climate_diag.is_empty():
			sample["climate"] = climate_diag
	if host._generator != null and host._generator.has_method("sus_weather_breakdown"):
		var weather_diag: Dictionary = host._generator.sus_weather_breakdown()
		if not weather_diag.is_empty():
			sample["weather"] = weather_diag
	if host._generator != null and host._generator.has_method("sus_ocean_currents_breakdown"):
		var ocean_diag: Dictionary = host._generator.sus_ocean_currents_breakdown()
		if not ocean_diag.is_empty():
			sample["ocean_currents"] = ocean_diag
	if perf_ready:
		var t_perf_us0: int = Time.get_ticks_usec()
		host._perf_recorder.call("on_fast_tick", sample)
		out["perf_ms"] = (Time.get_ticks_usec() - t_perf_us0) / 1000.0
	if tile_ready:
		var rows_before: int = 0
		if host._tile_data_recorder.has_method("row_count"):
			rows_before = int(host._tile_data_recorder.call("row_count"))
		var t_tile_us0: int = Time.get_ticks_usec()
		var tile_result = host._tile_data_recorder.call("on_fast_tick", sample)
		out["tile_ms"] = (Time.get_ticks_usec() - t_tile_us0) / 1000.0
		var rows_after: int = rows_before
		if host._tile_data_recorder.has_method("row_count"):
			rows_after = int(host._tile_data_recorder.call("row_count"))
		if tile_result is Dictionary:
			var tile_dict: Dictionary = tile_result
			out["tile_recorded"] = bool(tile_dict.get("recorded", false))
			out["tile_rows"] = int(tile_dict.get("rows", rows_after - rows_before))
			out["tile_reason"] = str(tile_dict.get("reason", ""))
			if tile_dict.has("tick_stride"):
				out["tile_tick_stride"] = int(tile_dict.get("tick_stride", 1))
			if tile_dict.has("cell_stride"):
				out["tile_cell_stride"] = int(tile_dict.get("cell_stride", 1))
			if tile_dict.has("collect_ms"):
				out["tile_collect_ms"] = float(tile_dict.get("collect_ms", 0.0))
			if tile_dict.has("stats_ms"):
				out["tile_stats_ms"] = float(tile_dict.get("stats_ms", 0.0))
			if tile_dict.has("format_ms"):
				out["tile_format_ms"] = float(tile_dict.get("format_ms", 0.0))
			if tile_dict.has("flush_ms"):
				out["tile_flush_ms"] = float(tile_dict.get("flush_ms", 0.0))
			if tile_dict.has("encoder_path"):
				out["tile_encoder_path"] = str(tile_dict.get("encoder_path", ""))
		else:
			out["tile_rows"] = rows_after - rows_before
			out["tile_recorded"] = int(out["tile_rows"]) > 0
	out["economy_recording"] = economy_ready
	if economy_ready:
		var t_eco_us0: int = Time.get_ticks_usec()
		var eco_result = host._economy_data_recorder.call("on_fast_tick", sample)
		out["economy_ms"] = (Time.get_ticks_usec() - t_eco_us0) / 1000.0
		if eco_result is Dictionary:
			out["economy_recorded"] = bool(eco_result.get("recorded", false))
			out["economy_rows"] = int(eco_result.get("rows", 0))
			out["economy_reason"] = str(eco_result.get("reason", ""))
			out["economy_epoch_id"] = int(eco_result.get("epoch_id", -1))
		else:
			out["economy_rows"] = 0
			out["economy_recorded"] = false
	out["total_ms"] = (Time.get_ticks_usec() - t_recorders_us0) / 1000.0
	return out



static func _recorder_ready(host, rec: RefCounted) -> bool:
	if rec == null:
		return false
	if not rec.has_method("on_fast_tick"):
		return false
	if rec.has_method("is_recording") and not bool(rec.call("is_recording")):
		return false
	return true


# Daily-sim perf instrumentation：把 SUS.report_last_tick() 翻译成可读日志。
# 同时打印 source（区分 day_changed / season_changed 等触发源）和每 Job 的
# elapsed_ms / slices_run / skipped_reason，便于"看一眼就知道罪魁是谁"。

func _print_daily_breakdown(host, tick_no: int, sus_ms: float, render_ms: float,
		ui_ms: float, total_ms: float, skipped_day: bool, is_warn: bool) -> void:
	host.DailySimulationBreakdown._print_daily_breakdown(
		host._generator,
		tick_no,
		sus_ms,
		render_ms,
		ui_ms,
		total_ms,
		skipped_day,
		is_warn)


func get_sim_breakdowns(host) -> Dictionary:
	var out: Dictionary = {}
	if host._generator == null:
		return out
	if host._generator.has_method("sus_climate_breakdown"):
		out["climate"] = host._generator.sus_climate_breakdown()
	if host._generator.has_method("sus_weather_breakdown"):
		out["weather"] = host._generator.sus_weather_breakdown()
	if host._generator.has_method("sus_enum_atlas_breakdown"):
		out["enum_atlas"] = host._generator.sus_enum_atlas_breakdown()
	if host._generator.has_method("sus_sea_ice_atlas_breakdown"):
		out["sea_ice_atlas"] = host._generator.sus_sea_ice_atlas_breakdown()
	if host._generator.has_method("sus_dynamic_visual_atlas_breakdown"):
		out["dynamic_visual_atlas"] = host._generator.sus_dynamic_visual_atlas_breakdown()
	if host._generator.has_method("sus_ocean_currents_breakdown"):
		out["ocean"] = host._generator.sus_ocean_currents_breakdown()
	var tick_report: Dictionary = host.get_sus_last_tick_report()
	var country_job = tick_report.get("country_daily", {})
	if country_job is Dictionary and host._generator.has_method("get_country_report"):
		var country_report: Dictionary = host._generator.get_country_report()
		# Same-day continuation may publish Country after SUS skipped the initial
		# job for frame budget.  Use the report's committed day as freshness
		# authority instead of filtering on scheduler skipped_reason.
		var report_day = int(country_report.get(
			"last_committed_day", country_report.get("day_index", -1)))
		var current_day = int(host._world_clock.day_index()) if host._world_clock != null else report_day
		if not country_report.is_empty() and report_day >= 0 and report_day >= current_day:
			out["country"] = {
				"_tick_idx": host._fast_tick_count,
				"country_report_mode": country_report.get(
					"country_report_mode", country_report.get("report_mode", "")),
				"country_state_hash_ms": country_report.get(
					"country_state_hash_ms", country_report.get("state_hash_ms", 0.0)),
				"country_report_build_ms": country_report.get(
					"country_report_build_ms", country_report.get("report_build_ms", 0.0)),
				"research_queue_size": country_report.get("research_queue_size", -1),
				"research_full_scan_fallbacks": country_report.get(
					"research_full_scan_fallbacks", 0),
				"research_activation_ms": country_report.get("research_activation_ms", 0.0),
				"research_allocation_ms": country_report.get("research_allocation_ms", 0.0),
				"research_effect_ack_ms": country_report.get("research_effect_ack_ms", 0.0),
				"research_discovery_ms": country_report.get("research_discovery_ms", 0.0),
				"research_modifier_ms": country_report.get("research_modifier_ms", 0.0),
				"research_report_ms": country_report.get("research_report_ms", 0.0),
				"research_countries_scanned": country_report.get("research_countries_scanned", 0),
				"research_active_countries": country_report.get("research_active_countries", 0),
				"research_pending_checks": country_report.get("research_pending_checks", 0),
				"research_discovery_checks": country_report.get("research_discovery_checks", 0),
				"research_discovery_frontier_mismatches": country_report.get(
					"research_discovery_frontier_mismatches", 0),
				"research_modifier_queries": country_report.get("research_modifier_queries", 0),
				"research_modifier_cache_hits": country_report.get("research_modifier_cache_hits", 0),
				"research_remainder_iterations": country_report.get("research_remainder_iterations", 0),
			}
	if host._generator.has_method("get_economy_perf_report"):
		var economy_perf: Dictionary = host._generator.get_economy_perf_report()
		if not economy_perf.is_empty():
			out["economy"] = economy_perf
	return out.duplicate(false)



func get_environment_perf_summary(host) -> Dictionary:
	var summary: Dictionary = host.get_sus_last_tick_summary()
	var out: Dictionary = {
		"target_avg_ms": 2.0,
		"target_p95_ms": 3.5,
		"target_max_ms": 5.0,
		"tick_idx": host._fast_tick_count,
		"fast_ms": host._overlay_last_fast_tick_ms,
		"map_cells": 0,
		"map_pixels": 0,
		"budget": {},
		"last_tick": summary,
		"window": {},
	}
	if host._current_map != null and host._current_map.has_method("cell_count"):
		out["map_cells"] = int(host._current_map.cell_count())
	if host._world_data != null and "derived_size" in host._world_data:
		var ds: Vector2i = host._world_data.derived_size
		out["map_pixels"] = int(ds.x * ds.y)
	if host._generator != null and host._generator.has_method("sus_report_sim_budget_window"):
		out["window"] = host._generator.sus_report_sim_budget_window()
	if host._generator != null and host._generator.has_method("environment_runtime_status"):
		out["environment_runtime"] = host._generator.environment_runtime_status()
	if not host._last_recorder_perf_summary.is_empty():
		out["recorders"] = host._last_recorder_perf_summary.duplicate(false)
	out["budget"] = {
		"sim_frame_budget_ms": float(summary.get("sim_frame_budget_ms", 0.0)),
		"sim_slice_budget_ms": float(summary.get("sim_slice_budget_ms", 0.0)),
		"sim_upload_slice_budget_ms": float(summary.get("sim_upload_slice_budget_ms", 0.0)),
		"sim_strict_budget_enabled": bool(summary.get("sim_strict_budget_enabled", false)),
		"sim_budget_warn_ms": float(summary.get("sim_budget_warn_ms", 0.0)),
		"economy_reserved_budget_ms": float(summary.get("economy_reserved_budget_ms", 0.0)),
	}
	return out



func get_recorder_perf_summary(host) -> Dictionary:
	return host._last_recorder_perf_summary.duplicate(false)


# Plan: perf-recording-csv-export
# DebugConsole 在 set_main 时实例化 PerfRecorder 并注入；fast_tick 末尾会把本帧
# 指标 forward 给 recorder.on_fast_tick。传 null 等价于卸载（PerfRecorder 自身会
# 留在 DebugConsole 持有，避免 GC）。

func set_perf_recorder(host, rec: RefCounted) -> void:
	host._perf_recorder = rec



func get_perf_recorder(host) -> RefCounted:
	return host._perf_recorder



func set_tile_data_recorder(host, rec: RefCounted) -> void:
	host._tile_data_recorder = rec



func get_tile_data_recorder(host) -> RefCounted:
	return host._tile_data_recorder



func set_economy_data_recorder(host, rec: RefCounted) -> void:
	host._economy_data_recorder = rec



func get_economy_data_recorder(host) -> RefCounted:
	return host._economy_data_recorder


# DOTS-Final-Push 任务 10：终端稳态指标 verdict 入口。
#
# 用法：
#   - 启动游戏在 2400 cells 基线运行 ≥ 200 fast tick 后，从 debug_console 或
#     脚本调用 get_tree().root.get_node("...Main").request_dots_final_push_perf_verdict()
#   - 函数内部读 PERF_VERDICT_WINDOW 滚动窗口（最多 200 tick 的 fast_ms / warn 标记）
#     + 透传 SUS scheduler `_stats` 全表 → DCDotsFinalPushPerfVerdict.evaluate()
#   - 把结构化 verdict Dictionary 返回给调用方，并把 format_verdict_lines 的可读
#     报告打印到控制台
#
# 验收门槛（与 plan/dots-final-push/requirements.md §6 一致）：
#   - 2400 cells 200 tick 中 fast tick WARN 占比 ≤ 0.5%
#   - total_ms p95 ≤ 12ms / p99 ≤ 20ms
#   - 任一 SUS job p95 ≤ 8ms（豁免 enum_atlas_upload）
#   - 6400 cells 大地图 200 tick 中 WARN 占比 ≤ 5%
#
# 不达标时 verdict.fail_reasons 给出具体哪条门槛未达成 + next_bottleneck
# 字段标注次高瓶颈，作为下一轮 plan 的输入（不阻塞本计划按段验收）。

func request_dots_final_push_perf_verdict(host) -> Dictionary:
	var samples: Array = host._perf_verdict_total_ms.duplicate()
	var warn_count: int = 0
	for marked in host._perf_verdict_warn_marks:
		if bool(marked):
			warn_count += 1
	var sus_job_stats: Dictionary = {}
	if host._generator != null and host._generator.has_method("sus_report_job_stats"):
		sus_job_stats = host._generator.sus_report_job_stats()
	var cells: int = 0
	if host._current_map != null:
		cells = host._current_map.cell_count()
	var verdict: Dictionary = DCDotsFinalPushPerfVerdict.evaluate(
		samples, warn_count, sus_job_stats, cells
	)
	for line in DCDotsFinalPushPerfVerdict.format_verdict_lines(verdict):
		print(line)
	return verdict

# Legend 指针：把当前选中 cell 在当前 overlay 通道下的归一化值传给 OverlayLegend，
# 使色带上的指针位置与 RightPanel 显示的实际数值一一对应。
# 离散通道（CLIMATE_ZONE / WEATHER）由 Legend 自身决定隐藏指针。
# 方向型通道（WIND_DIR / OCEAN_CURRENT_DIR）走 update_pointer_vector，把 (hue, intensity)
# 投影成色环上的小亮点。

func data_core_status_dict(host) -> Dictionary:
	var out: Dictionary = {
		"world_entities": 0,
		"world_components": 0,
		"bound": false,
	}
	if host._generator == null:
		return out
	if not host._generator.has_method("get_data_core_world"):
		return out
	var w = host._generator.get_data_core_world()
	if w == null:
		return out
	out["world_entities"] = int(w.entity_count())
	out["world_components"] = int(w.component_count())
	out["bound"] = bool(w.is_bound())
	return out


# ─── DCSoakDump Hotkey (F2) ──────────────────────────────────────────────
# 一键启动 30 tick SUMMARY dump，写到 user://soak/manual_<timestamp>.tsv。
# CLI 已启 → 忽略；已在跑 → 忽略（不打断当前会话）。

func _print_data_core_flag_snapshot(host) -> void:
	if host._generator == null:
		print("[DataCore] F11: generator not ready.")
		return
	var status: Dictionary = host.data_core_status_dict()
	print("[DataCore] F11 snapshot: world bound=%s entities=%d components=%d (single-path; flags removed)" % [
		str(status.get("bound", false)),
		int(status.get("world_entities", 0)),
		int(status.get("world_components", 0)),
	])


# ─── Validate-Weather \u00b7 deprecated stubs ─────────────────────────────────
# dots-flag-prune-pr1 (2026-05-22)：原 --validate-weather 机制依赖 F9 翻
# use_data_core_weather 在同一进程内对比 legacy / data_core 两条路径。该 flag
# 已删除——validate-weather 整个 A/B 桶机制随之废弃。F12 / debug_console
# 入口保留为 stub 提示。


static func _validate_weather_collect(host, _path: String, _wb: Dictionary) -> void:
	pass


static func _validate_weather_print_snapshot(host) -> void:
	print(">>>VAL>>> deprecated: validate-weather buckets removed (single-path; use_data_core_weather flag deleted).")


# ─── Phase B.3 / dots-migration-roadmap §3 B2：ViewAdapter A/B 切换 ─────
# DCFeatureFlags.use_world_view_adapter 控制走 .Cell（默认）或 .World（DOTS 路径）。
# dots-flag-prune-pr1 (2026-05-22)： use_world_view_adapter 是唯一保留的 sentinel-true
# flag——ClimateProfile 字段已删，DCFeatureFlags.is_on() 返回 FLAGS 表中的 default=true。
# 依赖：
#   - .World 实现要求 _generator.get_data_core_world() 返回非空且 is_bound()=true（DCWorld.bind_map_data 已成功）；
#     否则 silently 退到 .Cell 实现并 push_warning 一次。


func _update_runtime_interactive_qos(host) -> void:
	if host._generator == null or (not host._generator.has_method("set_runtime_interactive") \
			and not host._generator.has_method("set_runtime_qos_threaded")):
		return
	var pointer_active := Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) \
			or Input.is_mouse_button_pressed(MOUSE_BUTTON_MIDDLE) \
			or Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)
	var now_ms := Time.get_ticks_msec()
	var viewport_size: Vector2i = host.get_viewport().size \
		if host.get_viewport() != null else Vector2i.ZERO
	if viewport_size != host._runtime_last_viewport_size:
		host._runtime_last_viewport_size = viewport_size
		host._runtime_interactive_grace_until_ms = now_ms + 150
	if pointer_active:
		host._runtime_interactive_grace_until_ms = now_ms + 150
	var ctrl_drag := Input.is_key_pressed(KEY_CTRL) and pointer_active
	var interactive: bool = pointer_active or ctrl_drag or now_ms < host._runtime_interactive_grace_until_ms
	if interactive == host._runtime_interactive_qos:
		return
	host._runtime_interactive_qos = interactive
	# Prefer the non-blocking worker QoS control. Keep the legacy facade as a
	# compatibility fallback for older extensions; neither path waits for sim.
	if host._generator.has_method("set_runtime_qos_threaded"):
		host._generator.set_runtime_qos_threaded(interactive)
	else:
		host._generator.set_runtime_interactive(interactive)

func _refresh_selected_cell_lines_if_due(host) -> void:
	if not host._selected_cell_lines_dirty or host._selected_cell == null:
		return
	var now_ms: int = Time.get_ticks_msec()
	if now_ms < host._selected_cell_lines_next_refresh_ms:
		return
	host._selected_cell_lines_next_refresh_ms = now_ms + host.SELECTED_CELL_LINES_REFRESH_INTERVAL_MS
	host._selected_cell_lines_dirty = false
	host._refresh_weather_line()
	host._refresh_vitality_line()
	host._refresh_climate_line()
	host._refresh_emergent_lines()

# 地块选择：由 MapCamera 的 tile_tapped 信号驱动。
# camera 仅在"点按"（非拖拽/捏合）时发出该信号，且基于 UI 已消费过的输入做判定，
# 因此面板区域内的点按不会到这里，拖动地图也不会误选。


func run_day_changed(host, _day_idx: int) -> void:
	# best-effort 诊断（临时）：整个 _on_day_changed 的墙钟，含 fast_ms 没覆盖的
	# 头部（time_label / set_season_phase / vegetation layers）与尾部（overlay /
	# recorders）。t_label0 → 头部分段。
	var _ocd_t0: int = Time.get_ticks_usec()
	var _ocd_overlay_ms: float = 0.0
	host._refresh_time_label()
	var _ocd_label_ms: float = float(Time.get_ticks_usec() - _ocd_t0) / 1000.0
	# debug-overlay-perf v1（2026-06-12）：每个游戏日推进时标记 overlay 数据可能
	# 已变化。fast tick 末尾的消费逻辑会在"非跳日 + dirty=true"双条件下才真正
	# 触发一次 bake，确保 x20 倍速下每个游戏日最多 bake 一次。
	host._overlay_dirty = true
	var dispatch_season_phase: float = host._world_clock.season_phase()
	if host._world_clock != null and host._world_clock.has_method("season_phase_for_day"):
		dispatch_season_phase = float(host._world_clock.season_phase_for_day(_day_idx))
	# Phase 1：每"日"刷新一次 shader 季节相位
	var _ocd_sp0: int = Time.get_ticks_usec()
	if host._renderer != null:
		host._renderer.set_season_phase(dispatch_season_phase)
		host._renderer.set_climate_anomaly(host._world_clock.climate_anomaly)
	var _ocd_seasonphase_ms: float = float(Time.get_ticks_usec() - _ocd_sp0) / 1000.0
	# ───────────────────────────────────────────────────────────────────
	# Emergent Climate Coupling — 每日调用顺序契约（fast tick）：
	#   1. refresh_climate_daily   — 读慢层 + 写快层（内部尾部还会跑 sea_ice_daily、transpiration）
	#   2. refresh_daily           — WeatherSystem tick（只读慢层 + 写 current_state.weather_*）
	#   3. weather→map feedback    — 由 refresh_daily 内部末尾的 _apply_weather_to_map_feedback_pass 完成
	# 任务 8：以上三步全部收编为 SUS Job（refresh_climate_daily / weather_refresh /
	# ocean_currents），由 sus_tick_daily 统一调度。stride 跳日由 SusPolicy 承担。
	# 每季跨整数边界时 WorldClock 会发 season_changed → _on_season_changed → refresh_seasonal。
	# 每年 year_changed → refresh_yearly。
	# ───────────────────────────────────────────────────────────────────
	# Daily-sim perf instrumentation：fast tick 总耗时拆成三段：
	#   t_sus           — SUS dispatch（refresh_climate_daily + weather_refresh +
	#                     ocean_currents 等所有 Job）
	#   t_renderer_sync — fronts → HexRenderer（UI/可视化同步成本）
	#   t_ui            — 选中地块面板 4 行的细粒度刷新（only when not skipped）
	# total = t_sus + t_renderer_sync + t_ui（外加少量调度开销）
	var t_fast0: int = Time.get_ticks_msec()
	var t_sus_us0: int = Time.get_ticks_usec()

	# Perf instrumentation freshness（方案 ④ Step 1）：在跑 SUS 之前把"本帧将要
	# 变成的 fast_tick_idx"（即 _fast_tick_count + 1）同步给 generator/DVA，让
	# 所有 _last_*_breakdown 写入点能打上 _tick_idx 戳。perf_recorder.on_fast_tick
	# 拿到的 sample.tick_idx 也是 _fast_tick_count + 1（见 _fast_tick_count += 1
	# 在 fast tick 末尾，sample 在那之后构造），两侧对齐。
	if host._generator != null and host._generator.has_method("set_current_fast_tick_idx"):
		host._generator.set_current_fast_tick_idx(host._fast_tick_count + 1)
	# 完整经济 slice 报告是 450+ 键的 native Dictionary。只有录制器真的要读它时才
	# 值得每个 slice 构造一份，其余时间经济走 compact 报告。
	if host._generator != null and host._generator.has_method("set_economy_diagnostics_enabled"):
		host._generator.set_economy_diagnostics_enabled(
			host._recorder_ready(host._perf_recorder) or host._recorder_ready(host._economy_data_recorder))

	# Sliced Update Scheduler（任务 8）：完整收编后 fast tick 的全部模拟工作
	# 都在这里一次性驱动。返回字典：{ fronts: Array[WeatherFront], weather_ran: bool }。
	# weather_ran=false 表示本日被 weather_refresh_job.policy（StridePolicy）跳过，
	# 这条信息被用来抑制 UI 的 weather/vitality/climate/emergent 四行刷新——
	# 等价于此前的 was_skipped_day 行为。
	var sus_result: Dictionary = {}
	if host._generator != null and host._world_clock != null:
		# 单日单推进（tmp\next\day_cost_IMPL.md §4）：权威（inline / worker）已经
		# 接管当日时，main.gd 这第二套 GDScript 日级 job 让位，一天只跑一次。
		# 只在 web 生效：桌面上 main.gd 是唯一监听者，声明恒为空、行为逐语句不变。
		if not host._web_day_barrier_guard \
				or host._world_clock.claim_day_advance(&"main_sus", _day_idx):
			sus_result = host._generator.sus_tick_daily(host._world_clock, _day_idx, dispatch_season_phase)
		elif not host._day_barrier_defer_logged:
			host._day_barrier_defer_logged = true
			print("[day-barrier] main.gd SUS 日 tick 让位给 %s（day=%d）：一天只有一个日级执行者" % [
				String(host._world_clock.day_advance_owner()), _day_idx])
	if host._renderer != null and host._generator != null \
			and host._generator.has_method("has_pending_detail_scatter_refresh") \
			and bool(host._generator.has_pending_detail_scatter_refresh()) \
			and host._renderer.has_method("queue_detail_scatter_refresh"):
		var detail_dirty: PackedInt32Array = host._generator.consume_pending_detail_scatter_refresh_indices()
		host._renderer.queue_detail_scatter_refresh(detail_dirty)
	# ───────────────────────────────────────────────────────────────────
	# Reference-impl Pass #2 (demo-only, performance-charter §12.6)。
	# 仅在 ClimateProfile.demo_thermal_gradient_enabled = true 时启用：
	#   1) C++ 距 run_thermal_gradient_pass——读 cell_temp / cell_elevation，
	#      写 cell_demo_thermal_gradient（都是 bind_map_data 阶段共享 CoW 的同一
	#      块 buffer，无需额外 push）。
	#   2) 为防 CoW 后续被 GDScript 侧 mutator 意外 detach，调用后用 snapshot_f32
	#      拉一份赋回 map.demo_thermal_gradient_arr 以驱动 baker 重 bake。
	# 开关为 false 时这里全部跳过，overlay 下拉菜单也不应呈现该项。
	# ───────────────────────────────────────────────────────────────────
	host._run_demo_thermal_gradient_pass_if_enabled()
	var weather_ran: bool = bool(sus_result.get("weather_ran", false))
	var was_skipped_day: bool = not weather_ran
	var fronts: Array[WeatherFront] = sus_result.get("fronts", [] as Array[WeatherFront])
	# Drift-fix（2026-05-10）：weather_ran 在 SUS 双 tick 切片下，stage_a/stage_b 都为真——
	# 但 _last_fronts 只在 stage_b 真正翻新。fronts_changed 区分了"slice 跑了"和
	# "fronts 数据真的变了"。下方 set_weather_fronts gate 必须用 fronts_changed，
	# 否则 stage_a tick 会把上一份 fronts 重推一次 → weather_layer reset blend +
	# forward-bias 算出"起点≈终点"→ 云冻结。
	var fronts_changed: bool = bool(sus_result.get("fronts_changed", false))
	var t_sus_ms: float = (Time.get_ticks_usec() - t_sus_us0) / 1000.0

	# Renderer 与 UI 同步：fronts 在跳日时会沿用 WeatherRefreshJob.last_fronts() 的
	# 缓存（即上次成功 tick 的快照），renderer 持续看到一致的天气可视化。
	# Continuity-fix（E，2026-05-10）：跳日（weather_ran=false）不再调
	# set_weather_fronts。原因：set_weather_fronts 内部会无条件重置 blend
	# (_front_blend_elapsed=0 + 重新计算 _front_blend_duration ≈ 0.35s)，跳日下
	# 上次的视觉快照已经被 _predict_front_snapshots 沿 velocity 外推，再喂同一
	# 份 cached fronts 作 target 会让云"被拉回原位 → 重新外推 → 再拉回"，肉
	# weather_field_texture 已停用：天气场保留在 HexCell.weather_*，视觉层只吃 fronts。
	#
	# Drift-fix（2026-05-10）：从 weather_ran 改成 fronts_changed。
	# WeatherRefreshJob 双 tick 切片（stage_a 计算 + stage_b 烘 field）中，weather_ran
	# 在两 tick 都为真，但 _last_fronts 只在 stage_b 翻新。用 weather_ran 当 gate 时，
	# stage_a tick 会重推上一份 fronts → set_weather_fronts 内部 reset blend 让 lerp
	# 起点≈终点 → 一半时间云完全冻结，根本看不到 forward-bias 带来的飘动。
	# 改用 fronts_changed 确保每两个游戏日才推一次（≈ 1× 速度下 2 秒一次），
	# blend 在每次推送之间有完整 ~2.3s 平滑 lerp 时间，云能持续可见地飘。
	var t_render_us0: int = Time.get_ticks_usec()
	# Drift debug stays silent during fast ticks; SUS WARN already reports front status.
	if host._renderer != null:
		if host._renderer.has_method("set_weather_field_texture") and host._world_data != null:
			host._renderer.set_weather_field_texture(null)
		# 2026-05-18 P1-B：主地形材质需要看到 world.weather_field_tex 的最新内容，
		# 让海面分支按 hex 真值做风暴变色 + 风浪条纹（weather_layer 仍走 null 路径）。
		if host._renderer.has_method("refresh_terrain_weather_field_tex"):
			host._renderer.refresh_terrain_weather_field_tex()
		if fronts_changed:
			host._renderer.set_weather_fronts(fronts)
	var t_render_ms: float = (Time.get_ticks_usec() - t_render_us0) / 1000.0

	# 选中地块的 weather + vitality + 连续气候 + emergent 四行只在这里打脏标记，
	# 实际重画交给 _process 的墙钟节流（_refresh_selected_cell_lines_if_due），
	# 这样纯显示成本不再落在日推进的模拟时间盒里。
	# Fast-tick perf opt (A)：跳日不标脏——保留上次值直到下一个真正 tick 的日。
	var t_ui_us0: int = Time.get_ticks_usec()
	if host._selected_cell != null and not was_skipped_day:
		host._selected_cell_lines_dirty = true
	var t_ui_ms: float = (Time.get_ticks_usec() - t_ui_us0) / 1000.0

	# Emergent Climate Coupling：fast tick 总耗时打点
	# 首次必打；随后按 WorldClock 年长节流。合计 > 12ms 触发 WARN（不阻塞主循环）。
	var fast_ms: int = Time.get_ticks_msec() - t_fast0
	host._fast_tick_count += 1

	# Daily-sim perf instrumentation：周期性细分日志（默认关闭，开启后能看到
	# "SUS 段占多少 / renderer 同步段占多少 / 面板刷新占多少 / 各 Job 跑了多久"）。
	var should_log_breakdown: bool = host.perf_log_daily_breakdown \
		and host.perf_log_daily_stride > 0 \
		and (host._fast_tick_count == 1 or (host._fast_tick_count % host.perf_log_daily_stride) == 0)
	# 老牌 fast tick 日志（保留兼容 perf-report.md 已有数据格式）
	var annual_log_stride: int = host._world_clock.days_per_year() if host._world_clock != null and host._world_clock.has_method("days_per_year") else 365
	annual_log_stride = maxi(1, annual_log_stride)
	if host._fast_tick_count == 1 or (host._fast_tick_count % annual_log_stride) == 0:
		print("fast tick #%d: %dms (sus=%.2f render=%.2f ui=%.2f skipped_day=%s)"
			% [host._fast_tick_count, fast_ms, t_sus_ms, t_render_ms, t_ui_ms, str(was_skipped_day)])
	# Fast-tick perf opt (A)：跳日路径本就是低成本，跳过 > 12ms 警告误报判定。
	# Daily-sim perf instrumentation：原年度节流过松（卡顿期 400ms 一年才提醒一次），
	# 改为指数退让——首次必报，之后按 30 帧节流，避免刷屏又能持续看到趋势。
	# Fix #11 (2026-06-16) mobile：阈值 sus>1ms/total>12ms 在 mobile 上误报严重。
	# 每次 WARN 触发 25 行 print + push_warning stack trace = ~30 行日志，每行
	# logcat 5-10ms → 单次 WARN 自身 >150ms，反而把 frame_wall 拉爆。mobile 把
	# 节流间隔放到 120 帧（~2s）且阈值放到 sus>8ms / fast>16ms（60FPS budget），
	# 让诊断只在真实问题时触发。desktop 保留原行为方便开发期排查。
	var sus_budget_warn: bool = false
	var fast_budget_warn: bool = false
	var warn_throttle: int = 30
	if OS.has_feature("mobile"):
		sus_budget_warn = t_sus_ms > 8.0
		fast_budget_warn = fast_ms > 16
		warn_throttle = 120
	else:
		sus_budget_warn = t_sus_ms > 1.0
		fast_budget_warn = fast_ms > 12
	var trigger_warn: bool = (not was_skipped_day) and (fast_budget_warn or sus_budget_warn) \
		and (host._fast_tick_warn_last_frame == 0 or (host._fast_tick_count - host._fast_tick_warn_last_frame) >= warn_throttle)
	if trigger_warn and PKLog.enabled:
		push_warning("[fast tick] frame=%d total=%dms sus=%.2fms render=%.2fms ui=%.2fms cells=%d budgets(total>12ms or sus>1ms)" % [
			host._fast_tick_count, fast_ms, t_sus_ms, t_render_ms, t_ui_ms,
			host._current_map.cell_count() if host._current_map != null else 0
		])
		host._fast_tick_warn_last_frame = host._fast_tick_count

	# Daily-sim perf instrumentation：周期日志 OR WARN 触发 → 打印每个 SUS Job
	# 的精细拆解。打印格式：
	#   [fast tick #N] sus=A render=B ui=C total=D skip=<bool>
	#       <job_id> ran=<ms> slices=<n>
	#       <job_id> skipped(<reason>)
	if (should_log_breakdown or trigger_warn) and PKLog.enabled:
		host._print_daily_breakdown(host._fast_tick_count, t_sus_ms, t_render_ms, t_ui_ms,
			float(fast_ms), was_skipped_day, trigger_warn)

	# Data Overlay：每日随模拟推进刷新一次数据纹理（需求 2.7）。
	# overlay_mode == NONE 时 _refresh_overlay_data 内部会早返 0 开销。
	#
	# debug-overlay-perf v1（2026-06-12）：
	# 旧实现"跳日时仍刷新"的理由是慢层（base_moisture / 气候带）在跳日内
	# 可能变；但在 x20 倍速实测中，每 fast tick 都重 bake 1080×574 RGBA8
	# 纹理 → ImageTexture.create_from_image 5-15ms 同步阻塞，是温度/天气
	# overlay 卡顿的主因（详见 docs/architecture/development-guide.md
	# §Overlay Bake Cost）。
	#
	# 现在改成两层 gate：
	# 1) 跳日（was_skipped_day=true，本帧没跑 weather/climate/ocean）→ overlay
	#    数据不可能变，直接跳过。这一条消灭了 x20 倍速下 ~50% 的重复 bake。
	# 2) _overlay_dirty 标记由 day_changed 信号在 _on_day_changed 顶部一次
	#    性置 true（不分跳日与否，确保慢层场景也能刷一次）；本函数消费后
	#    立即清零。如果 _on_day_changed 在同一帧内被多次调用（不应该发生，
	#    但保险），_overlay_dirty 仅触发一次 bake。
	# 3) 即使 dirty=false 也允许由 _apply_overlay_mode / 地图重生成显式调用，
	#    那些路径独立写 dirty 不依赖 fast tick gate。
	host._overlay_last_fast_tick_ms = fast_ms
	# best-effort-sim-stepping（2026-06-17）：墙钟节流 overlay 重 bake。高倍速下
	# 每帧都推进一天会导致每帧 ~30ms overlay fan-out → FPS 跳水。这里加第 4 道
	# gate：距上次 bake 不足 overlay_min_bake_interval_ms 就跳过（保留 _overlay_dirty
	# 不消费，下一个到点的帧再 bake 最新状态）。低速（日间隔 ≥ interval）下永不触发。
	if host._overlay_mode != 0 and not was_skipped_day and host._overlay_dirty and not host._overlay_refresh_disabled:
		var now_ms: int = Time.get_ticks_msec()
		if float(now_ms - host._overlay_last_bake_wall_ms) >= host.overlay_min_bake_interval_ms:
			host._overlay_last_bake_wall_ms = now_ms
			# Web 单日成本探针：overlay 重烘焙是 debug overlay 的日级大项，单独记账。
			# 桌面 _probe_ovl_usec 恒 0（不调 get_ticks_usec），不多做任何事。
			var _probe_ovl_usec: int = 0
			if host._world_clock != null and host._world_clock.day_cost_probe_on:
				_probe_ovl_usec = Time.get_ticks_usec()
			host._refresh_overlay_data()
			if _probe_ovl_usec > 0:
				_ocd_overlay_ms = float(Time.get_ticks_usec() - _probe_ovl_usec) / 1000.0

	# DOTS-Final-Push 任务 10：把当前 tick 的 fast_ms 与 trigger_warn 标记
	# 推入滚动窗口（PERF_VERDICT_WINDOW=200），供 request_dots_final_push_perf_verdict()
	# 一键产出 verdict。跳日（was_skipped_day）的 tick 不计入窗口——它本就
	# 是低成本路径，与稳态门槛验收无关（需求 6.1~6.3 都是非跳日）。
	if not was_skipped_day:
		host._perf_verdict_total_ms.append(float(fast_ms))
		host._perf_verdict_warn_marks.append(trigger_warn)
		while host._perf_verdict_total_ms.size() > host.PERF_VERDICT_WINDOW:
			host._perf_verdict_total_ms.pop_front()
			host._perf_verdict_warn_marks.pop_front()

	# Plan: perf-recording-csv-export + tile-data debug recording
	# 把本帧 main 局部才知道的指标（三段 ms / 跳日标志 / fps / 时间戳）发布给
	# 已挂接的录制器。PerfRecorder 自己拉 SUS breakdown；TileDataRecorder
	# 自己拉 MapData SoA。未挂载或未录制时内部早返，跳日帧也录入。
	var recorder_diag: Dictionary = host._publish_fast_tick_perf_sample(t_sus_ms, t_render_ms, t_ui_ms,
		float(fast_ms), was_skipped_day)
	var fast_ms_after_recorders: int = Time.get_ticks_msec() - t_fast0
	if recorder_diag.is_empty():
		host._last_recorder_perf_summary = {}
	else:
		recorder_diag["fast_ms_before_recorders"] = fast_ms
		recorder_diag["fast_ms_after_recorders"] = fast_ms_after_recorders
		host._last_recorder_perf_summary = recorder_diag
		host._overlay_last_fast_tick_ms = fast_ms_after_recorders
		var recorder_total_ms: float = float(recorder_diag.get("total_ms", 0.0))
		var recorder_warn: bool = recorder_total_ms >= 2.0 \
			or ((not was_skipped_day) and fast_ms_after_recorders > 12 and not trigger_warn)
		if recorder_warn and (host._recorder_warn_last_frame == 0 \
				or (host._fast_tick_count - host._recorder_warn_last_frame) >= 30):
			host._recorder_warn_last_frame = host._fast_tick_count
			push_warning("[fast tick recorder] frame=%d recorder=%.2fms tile=%.2fms rows=%d total_after=%dms" % [
				host._fast_tick_count,
				recorder_total_ms,
				float(recorder_diag.get("tile_ms", 0.0)),
				int(recorder_diag.get("tile_rows", 0)),
				fast_ms_after_recorders,
			])
			print("        recorder total=%.2f perf=%.2f tile=%.2f collect=%.2f stats=%.2f format=%.2f flush=%.2f encoder=%s tile_rows=%d tile_recorded=%s tile_reason=%s total_after=%dms" % [
				recorder_total_ms,
				float(recorder_diag.get("perf_ms", 0.0)),
				float(recorder_diag.get("tile_ms", 0.0)),
				float(recorder_diag.get("tile_collect_ms", 0.0)),
				float(recorder_diag.get("tile_stats_ms", 0.0)),
				float(recorder_diag.get("tile_format_ms", 0.0)),
				float(recorder_diag.get("tile_flush_ms", 0.0)),
				str(recorder_diag.get("tile_encoder_path", "")),
				int(recorder_diag.get("tile_rows", 0)),
				str(recorder_diag.get("tile_recorded", false)),
				str(recorder_diag.get("tile_reason", "")),
				fast_ms_after_recorders,
			])

	# Web 单日成本探针（tmp/next/day_cost_IMPL.md）：main.gd 这一套监听者只在
	# main.tscn（调试场景）出现；生产玩家场景是 player_game.tscn，那里是
	# WorldRuntimeHost + PlayerController，本函数整天不会跑。所以 web 生产路径上
	# 这条 day_cost_main 事件**不出现**、day_cost 里的 s1 恒 0 —— 这本身就是
	# "主线程 GDScript SUS 日 tick 一次都没被调"的正面证据。
	# 桌面 day_cost_probe_on 恒假 → 整块跳过，既有语句一条不改。
	if host._world_clock != null and host._world_clock.day_cost_probe_on:
		host._world_clock.day_cost_add(&"main", float(Time.get_ticks_usec() - _ocd_t0) / 1000.0)
		host._world_clock.day_cost_add(&"lab", _ocd_label_ms)
		host._world_clock.day_cost_add(&"sph", _ocd_seasonphase_ms)
		host._world_clock.day_cost_add(&"s1", t_sus_ms)
		host._world_clock.day_cost_add(&"ren", t_render_ms)
		host._world_clock.day_cost_add(&"mui", t_ui_ms)
		host._world_clock.day_cost_add(&"ovl", _ocd_overlay_ms)
		if not recorder_diag.is_empty():
			host._world_clock.day_cost_add(&"rec", float(recorder_diag.get("total_ms", 0.0)))
		if host._generator != null and host._generator.has_method("sus_report_last_tick"):
			host._world_clock.day_cost_jobs_from(host._generator.sus_report_last_tick())

	# best-effort 诊断（临时）：整个 _on_day_changed 的分段墙钟。和 [clock/step] 的
	# loop(~40ms) 对比定位那 ~35ms 落在哪段：label / season_phase(含 vegetation 层)
	# / fast(sus+render+ui) / post(overlay+recorders)。每 ~120 帧打一行。
	if PKLog.enabled and Engine.get_process_frames() % 120 == 0:
		var _ocd_full_ms: float = float(Time.get_ticks_usec() - _ocd_t0) / 1000.0
		var _ocd_post_ms: float = _ocd_full_ms - _ocd_label_ms - _ocd_seasonphase_ms - float(fast_ms)
		print("[day/seg] full=%.2fms label=%.2f season_phase=%.2f fast=%d post=%.2f skipped=%s"
			% [_ocd_full_ms, _ocd_label_ms, _ocd_seasonphase_ms, fast_ms, _ocd_post_ms, str(was_skipped_day)])


# Plan: perf-recording-csv-export
# 把"只有 fast_tick 局部知道"的指标打包成 sample 字典，转发给已挂接的录制器。
# 不持有 recorder 引用或未录制时直接 return，零开销快路径。


func _refresh_time_label(host) -> void:
	if host._world_clock == null or host._time_label == null:
		return
	var y: int = int(host._world_clock.year_index())
	var cal: Dictionary = host._world_clock.calendar_date() if host._world_clock.has_method("calendar_date") else {}
	var d: int = int(cal.get("day_of_year", host._world_clock.day_in_year() + 1))
	var s: int = int(host._world_clock.season_index())
	# 任务 2：扩展为 "Y%d D%d %s %02d:00" 包含当前小时位
	var h: int = int(host._world_clock.hour_of_day())
	host._last_time_label_hour = h
	var month_name: String = str(cal.get("month_name", ""))
	var month_day: int = int(cal.get("day_of_month", 0))
	if month_name != "" and month_day > 0:
		host._time_label.text = "Y%d D%03d %s %d %s %02d:00" % [
			y, d, month_name, month_day, host._world_clock.season_name(s), h
		]
	else:
		host._time_label.text = "Y%d D%03d %s %02d:00" % [y, d, host._world_clock.season_name(s), h]


func _refresh_climate_label(host) -> void:
	if host._world_clock == null or host._climate_label == null:
		return
	var v: float = float(host._world_clock.climate_anomaly)
	host._climate_label.text = "Climate %s%.2f" % ["+" if v >= 0.0 else "", v]

# ─── 主生成流程 ──────────────────────────────────────────────────────────


func _refresh_emergent_lines(host) -> void:
	if host._info_panel_controller == null:
		return
	host._info_panel_controller.refresh_emergent_lines()


# ─── Data Overlay 接口 ─────────────────────────────────────────────────
# 统一放在 main.gd 尾部：DebugConsole 通过这些公共方法控制 overlay，
# 避免 UI 层直接访问 DataOverlayLayer / DataOverlayBaker，便于将来替换实现。
#
# _sync_overlay_to_world()         把当前 world_bounds + alpha + mode 推一次给节点
# _apply_overlay_mode(mode)        切换通道并立即烘焙一次数据纹理
# _set_overlay_alpha(v)            调整 shader 的 base_alpha uniform
# _refresh_overlay_data()          重新 bake 一次（每日 tick 或重生成后调用）
# get_overlay_mode() / get_overlay_alpha() / get_overlay_stats()
#                                  DebugConsole 查询当前状态
