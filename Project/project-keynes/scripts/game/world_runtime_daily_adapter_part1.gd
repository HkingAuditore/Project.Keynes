extends RefCounted

## Extracted world_runtime_daily_adapter.gd group 1; state stays with host.

func _bind_overlay_resources(host) -> void:
	host._overlay.bind_resources(host._renderer, host._map_overlay_layer, host._current_map,
		host._world_data, host._view_adapter, host._generator, host._world_clock,
		host._runtime_ready_for_ticks, host.set_process)



func set_map_overlay(host, request: Dictionary) -> void:
	host._bind_overlay_resources()
	host._overlay.set_map_overlay(request)



func clear_map_overlay(host) -> void:
	host._bind_overlay_resources()
	host._overlay.clear_map_overlay()



func mark_map_overlay_dirty(host, _reason: StringName = &"runtime") -> void:
	host._bind_overlay_resources()
	host._overlay.mark_map_overlay_dirty(_reason)



func map_overlay_diagnostics(host) -> Dictionary:
	host._bind_overlay_resources()
	return host._overlay.map_overlay_diagnostics()
## Web 心跳：每 2 秒把「日历走到第几天 / 快进次数 / worker 状态」推到事件通道。
## agent 侧 tail tmp/web_events.jsonl 就能判断页面活着、日历在走还是在原地空转，
## 不需要截图轮询。
## Web：头 120 帧逐帧计时，用来判断那次长帧是 CPU 还是 GPU（setup 时间小但
## 帧时长巨大 = GPU 侧；setup 也大 = 主线程 CPU）。之后只在出现长帧时上报，
## 这样整轮 soak 里的卡顿都能被抓到，而不是只看开头。
## 慢帧轨迹：记录本帧各阶段进入时刻（纯内存操作，不发网络请求）。
## 若下一帧发现上一帧耗时 >2s，就把上一帧的轨迹补发出来——这样"整帧不返回"之前
## 最后到达的阶段就能直接读到。


func _web_mark(host, phase: String) -> void:
	if not WebTelemetry.enabled():
		return
	host._web_phase_marks.append([phase, Time.get_ticks_usec()])



func _web_flush_slow_frame_trace(host, dt_ms: int) -> void:
	if dt_ms < 2000 or host._web_phase_marks.is_empty():
		return
	var parts = PackedStringArray()
	for i in host._web_phase_marks.size():
		var mark: Array = host._web_phase_marks[i]
		var at: int = int(mark[1])
		var delta = at - int(host._web_phase_marks[0][1])
		parts.append("%s@%d" % [String(mark[0]), delta / 1000])
	WebTelemetry.emit("slow_frame_trace", {"dt": dt_ms, "marks": " ".join(parts)})
	host._web_phase_marks.clear()



func _emit_web_frame_probe(host, frame_usec: int) -> void:
	if not WebTelemetry.enabled():
		return
	var dt_ms = 0
	if host._web_frame_probe_last_usec > 0:
		dt_ms = int((frame_usec - host._web_frame_probe_last_usec) / 1000)
	host._web_frame_probe_last_usec = frame_usec
	var detail = host._web_frame_probe_left > 0
	if detail:
		host._web_frame_probe_left -= 1
	if not detail and dt_ms < 500:
		return
	WebTelemetry.emit("frame", {
		"i": 120 - host._web_frame_probe_left,
		"dt": dt_ms,
		"setup": int(RenderingServer.get_frame_setup_time_cpu() * 1000.0),
		"proc": int(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0),
		"draws": int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		"objs": int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)),
		"day": host._world_clock.day_index() if host._world_clock != null else -1,
		"speed": host._world_clock.speed_multiplier if host._world_clock != null else 0.0,
	})


func _emit_web_beat(host, frame_usec: int) -> void:
	if not WebTelemetry.enabled():
		return
	var now_msec = frame_usec / 1000
	if now_msec < host._web_beat_next_msec:
		return
	host._web_beat_next_msec = now_msec + 2000
	var day = host._world_clock.day_index() if host._world_clock != null else -1
	var worker_state = ""
	if host._generator != null and host._generator.has_method("get_runtime_thread_report"):
		var rep: Dictionary = host._generator.get_runtime_thread_report()
		worker_state = String(rep.get("simulation_host_state", rep.get("state", "")))
	WebTelemetry.emit("beat", {
		"day": day,
		"fast_ticks": host._fast_tick_count,
		"paused": host._world_clock.paused if host._world_clock != null else true,
		"worker": worker_state,
		"frames": host._sched_proc_frames,
		# soak 验收要能确认真的跑在 10×，不是"看起来在跑"
		"speed": host._world_clock.speed_multiplier if host._world_clock != null else 0.0,
	})
	# 每 5 次 beat（约 10s）发一次 barrier 诊断，不必等 stall 就能看出卡在哪。
	host._web_diag_ticks += 1
	if host._web_diag_ticks % 5 == 0:
		WebTelemetry.emit("diag", host._web_barrier_diag())


func _process(host, _delta: float) -> void:
	# 先把上一帧攒下的事件发出去（长帧里直接 fetch 会被浏览器丢掉）。
	WebTelemetry.flush()
	var frame_usec = Time.get_ticks_usec()
	# 慢帧轨迹：先结算上一帧（若它很慢，把它内部的阶段轨迹补发出去）。
	if host._web_prev_frame_usec > 0:
		host._web_flush_slow_frame_trace(int((frame_usec - host._web_prev_frame_usec) / 1000))
	host._web_prev_frame_usec = frame_usec
	# 注意：浏览器侧钩子（webglcontextlost/pagehide）经 JavaScriptBridge.eval 注入，
	# 实测会把页面搞挂（只跑 1 帧就静默），已撤；重载改由"重复出现 autotest_start"判定。
	host._web_phase_marks.clear()
	host._web_mark("proc_begin")
	host._sched_proc_frames += 1
	host._emit_web_frame_probe(frame_usec)
	host._emit_web_beat(frame_usec)
	host._annual_reports.poll()
	host._web_mark("annual_poll_end")
	host._web_mark("progress_begin")
	host._service_runtime_progress(frame_usec)
	host._web_mark("progress_end")
	host._sched_proc_last_total_ms = host._sched_elapsed_ms(frame_usec)


func _service_runtime_progress(host, frame_usec: int) -> void:
	var segment_usec = Time.get_ticks_usec()
	host._consume_runtime_commit_if_ready()
	host._observe_runtime_worker_fault()
	host._poll_runtime_health()
	segment_usec = Time.get_ticks_usec()
	if host.military_map_layers != null \
			and host.military_map_layers.has_method("poll_snapshot"):
		host.military_map_layers.poll_snapshot()
	host._sched_proc_country_visual_ms += host._sched_elapsed_ms(segment_usec)
	host._service_worker_map_presentation(frame_usec)
	segment_usec = Time.get_ticks_usec()
	var now_msec = Time.get_ticks_msec()
	if now_msec >= host._building_visual_next_poll_msec:
		host._building_visual_next_poll_msec = now_msec + 100
		host._refresh_building_visual_intel({})
	host._sched_proc_building_ms += host._sched_elapsed_ms(segment_usec)
	if not host._map_overlay_dirty or host._map_overlay_request.is_empty():
		return
	segment_usec = Time.get_ticks_usec()
	host._refresh_map_overlay(false)
	host._sched_proc_overlay_ms += host._sched_elapsed_ms(segment_usec)



func _run_native_daily_inline_day(host, day_idx: int) -> void:
	var ext = host._generator.get_data_core_world_ext()
	var segment_usec := Time.get_ticks_usec()
	# 探针：native 调用本身的独立 epoch（桌面 _dcp_on() 为假时连计时都不做）。
	var _dcp_native_usec: int = Time.get_ticks_usec() if host._dcp_on() else 0
	var result: Dictionary = ext.run_native_daily_inline_day()
	host._runtime_native_daily_inline_last = result
	if _dcp_native_usec > 0:
		host._dcp_inline_ms = float(Time.get_ticks_usec() - _dcp_native_usec) / 1000.0
	# 每个内联日的耗时/域覆盖：第一次 daily tick 在浏览器里特别贵（一次性初始化），
	# 用这个事件区分"首日一次性成本"和"每天稳态成本"。
	WebTelemetry.emit("inline_day", {
		"day": day_idx,
		"ms": int(host._sched_elapsed_ms(segment_usec)),
		"ok": bool(result.get("ok", false)),
		"reason": String(result.get("reason", "")),
		"attempts": int(result.get("attempts", 0)),
		"peer": int(result.get("peer_pumped", 0)),
		"from": int(result.get("from_day", -1)),
		"committed": int(result.get("committed_day", -1)),
		"domain_mask": int(result.get("completed_domain_mask", 0)),
		"work": int(result.get("work_units", 0)),
		# 分域耗时（12 个 stage 名 → ms），以及 capture / 计划 / 提交尾巴 / peer 泵。
		"stages": result.get("stage_ms", {}),
		"capture": int(result.get("capture_ms", 0.0)),
		"pre": int(result.get("pre_stage_ms", 0.0)),
		"climate": int(result.get("climate_ms", 0.0)),
		"plan": int(result.get("plan_build_ms", 0.0)),
		"tail": int(result.get("commit_tail_ms", 0.0)),
		"peer_ms": int(result.get("peer_ms", 0.0)),
		"budget_hit": bool(result.get("budget_exceeded", false)),
		"serial_only": bool(result.get("executor_serial_only", false)),
		"dispatch": int(result.get("executor_dispatch", 0)),
	})
	if bool(result.get("ok", false)):
		host._runtime_native_daily_inline_days += 1
	else:
		host._runtime_native_daily_inline_pending_days += 1
		# 静默冻结是最难查的失败形态：每 30 次至少留一行能指名原因的日志。
		if host._runtime_native_daily_inline_pending_days % 30 == 1:
			print("[runtime-inline] day=%d pending reason=%s committed=%d" % [
				day_idx, String(result.get("reason", "?")),
				int(result.get("committed_day", -1))])
	# 提交已经发布；把同一份提交落到 MapData/slot，本帧的 UI/渲染就能读到今天。
	#
	# inline_day 计时结束后，才写回提交并安排界面刷新。
	if host._dcp_on():
		var dcp_commit_usec = Time.get_ticks_usec()
		# 复用同一调用栈里刚取的那份 report（内联日没有 worker 线程，两次读取
		# 必然同值），省掉一天里第二次 get_runtime_thread_report() 打包。
		host._consume_runtime_commit_if_ready()
		host._dcp_commit_ms = float(Time.get_ticks_usec() - dcp_commit_usec) / 1000.0
	else:
		host._consume_runtime_commit_if_ready()
func _native_daily_inline_requested(host) -> bool:
	if not host.runtime_native_daily_inline:
		return false
	if host.PK_WEB_FORCE_NO_INLINE:
		return false
	# worker 启动失败（或 ACTIVE 没被授予）之后的回退：本会话内强制内联。
	# 这条必须排在 `_web_worker_requested()` 之前 —— 回退的意义就是"worker 要了
	# 但没成"，此时 switches 还停在 worker 侧，不看这个标志就没有执行者了。
	if host._web_worker_inline_fallback:
		return true
	# Web 用回 native worker：内联日与 worker 是互斥的两种"日屏障执行者"。
	# 选了 worker 就必须把内联关掉 —— 否则 `config["native_daily_inline"]=true`
	# 会让 host 干脆不 spawn 线程，日屏障又回到主线程。
	if host._web_worker_requested():
		return false
	if host._is_web_build():
		return true
	# Mobile uses the same native worker and session-owned clock binding as desktop.
	# The old forced-inline workaround predates RuntimeClockBinding: it kept an
	# entire twelve-domain day on the render thread even after clock startup was fixed.
	# An explicit diagnostic override can still select the existing inline executor.
	if (OS.has_feature("mobile") or OS.has_feature("android") or OS.has_feature("ios")) \
			and OS.get_environment("PK_MOBILE_NATIVE_WORKER") == "0":
		return true
	return OS.get_environment("PK_NATIVE_DAILY_INLINE") == "1"


## 「本进程是 web 构建」的单一判据。
##
## `PK_FORCE_WEB_SEMANTICS=1` 是**只在 headless 上使用**的语义镜像：浏览器里
## `OS.has_feature("web")` 改不了，而这条链上的三个决定（谁执行日屏障 / 起不起
## worker / 起不来怎么回退）恰恰是最容易写错、也最需要被回归覆盖的部分。
## 生产环境永远不会设这个变量，所以它对线上零影响。

func _is_web_build(host) -> bool:
	return OS.has_feature("web") \
		or OS.get_environment("PK_FORCE_WEB_SEMANTICS") == "1"


## Web 用回 native worker 的总开关解析。默认 false。
## 环境变量 `PK_WEB_WORKER=1` 优先于导出项，便于 headless/CI 做 A/B。
## 不缓存：它只在这几处冷路径被读（configure / worker 启动 / _process 里的
## 预发布判定），而缓存会让"导出项在 configure 之后被改"变成静默失效。

func _web_worker_requested(host) -> bool:
	if OS.has_feature("web") and not OS.has_feature("threads"):
		return false
	# [2026-10-31] web defaults to the worker, same as the PC baseline.
	# Real-device data (RTX 4080 + Chrome, 365 days): worker 9.92 days/s vs inline
	# 9.81 -- throughput parity -- while the main thread spends 4 ms/day vs 46 ms
	# (-91%), so almost the whole frame budget goes back to GPU/UI.
	# Fallback chain, highest priority first:
	#   ?worker=0 (Engine meta) > PK_WEB_WORKER=0/1 (env) > runtime_web_worker
	#   > web platform default (true).
	# Desktop is unaffected: it already runs the worker, and
	# `_native_daily_inline_requested()` there only looks at PK_NATIVE_DAILY_INLINE.
	if Engine.has_meta("pk_web_worker"):
		return bool(Engine.get_meta("pk_web_worker"))
	var env = OS.get_environment("PK_WEB_WORKER")
	if env == "1":
		return true
	if env == "0":
		return false
	if host.runtime_web_worker:
		return true
	return OS.has_feature("web")


## A new, fully closed session may retry; never clear a native simulation fault here.

func _clear_web_daily_fallback_failure(host) -> void:
	if not host._is_web_build() or host._runtime_last_fault_diagnostics.get("source") != "web_daily_executor":
		return
	host._runtime_worker_fault_paused = false
	host._runtime_last_fault_diagnostics.clear()
	host._web_worker_start_ok = false
	host._web_worker_start_code = ""
	host._native_daily_inline_active = false
	if host._world_clock != null:
		host._world_clock.clear_authority_fault_hold()


## Record a Web executor startup failure.

func _reject_web_daily_fallback(host, code: String, reason: String) -> bool:
	if not host._is_web_build():
		return false
	if host._runtime_worker_fault_paused:
		return true
	host._web_worker_start_ok = false
	host._web_worker_start_code = code
	host._runtime_worker_fault_paused = true
	host._runtime_last_fault_diagnostics = {"fault_code": code, "reason": reason,
		"source": "web_daily_executor", "state": "FAULTED"}
	if host._world_clock != null:
		host._world_clock.latch_authority_fault_hold()
	WebTelemetry.emit("web_daily_executor_failed", {"code": code, "reason": reason})
	host._emit_world_generation_failure("runtime_executor", code,
		"网页模拟无法启动：%s" % reason,
		"请更新网页和游戏组件。")
	return true


func _publish_fast_tick_perf_sample(host,
		t_sus_ms: float,
		t_render_ms: float,
		t_ui_ms: float,
		fast_ms: float,
		was_skipped_day: bool
) -> Dictionary:
	# 帧墙钟差分：发布点间墙钟 / 期间引擎帧数。1 tick/帧时即上一帧墙钟；
	# 高速多 tick 帧取区间平均，不产生 0 除（frame_delta=0 时保留上一值）。
	var publish_now_usec = Time.get_ticks_usec()
	var publish_now_frame = Engine.get_process_frames()
	if host._last_perf_publish_usec > 0:
		var frame_delta = publish_now_frame - host._last_perf_publish_frame
		if frame_delta > 0:
			host._last_frame_wall_ms = float(publish_now_usec - host._last_perf_publish_usec) \
				/ 1000.0 / float(frame_delta)
	host._last_perf_publish_usec = publish_now_usec
	host._last_perf_publish_frame = publish_now_frame
	var perf_ready = host._recorder_ready(host._perf_recorder)
	var tile_ready = host._recorder_ready(host._tile_data_recorder)
	var economy_ready = host._recorder_ready(host._economy_data_recorder)
	var continuation: Dictionary = {}
	if host._generator != null and host._generator.has_method("consume_continuation_perf_summary"):
		continuation = host._generator.consume_continuation_perf_summary()
	if not perf_ready and not tile_ready and not economy_ready:
		return {}
	var started_usec = Time.get_ticks_usec()
	var detail_report: Dictionary = host._renderer.detail_scatter_refresh_report() \
		if host._renderer != null and host._renderer.has_method("detail_scatter_refresh_report") else {}
	var out: Dictionary = {
		"total_ms": 0.0,
		"perf_ms": 0.0,
		"tile_ms": 0.0,
		"economy_ms": 0.0,
		"perf_recording": perf_ready,
		"tile_recording": tile_ready,
		"economy_recording": economy_ready,
		"tile_recorded": false,
		"tile_rows": 0,
		"tile_reason": "",
		"economy_recorded": false,
		"economy_rows": 0,
		"economy_reason": "",
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
		# WorldClock 帧内分解：pulse = 本帧 continuation 脉冲段（日循环之前运行，
		# fast_ms 看不到）；loop/full 在帧尾才更新，此处读到的是上一帧的值，
		# 稳态下逐行平移一帧不影响对比分析。
		"clock_pulse_ms": host._world_clock.get_last_pulse_ms() if host._world_clock != null else 0.0,
		"clock_loop_ms": host._world_clock.get_last_loop_ms() if host._world_clock != null else 0.0,
		"clock_full_ms": host._world_clock.get_last_full_proc_ms() if host._world_clock != null else 0.0,
		"clock_day_cost_ema_ms": host._world_clock.get_day_cost_ms_ema() if host._world_clock != null else 0.0,
		"clock_throughput_cap": host._world_clock.get_throughput_cap_days_per_frame() if host._world_clock != null else 0.0,
		"clock_last_advanced_days": host._world_clock.get_last_advanced_days() if host._world_clock != null else 0,
		"sched_day_total_ms": host._sched_day_total_ms,
		"sched_day_report_ms": host._sched_day_report_ms,
		"sched_day_snapshots_ms": host._sched_day_snapshots_ms,
		"sched_day_climate_writeback_ms": host._sched_day_climate_writeback_ms,
		"sched_day_climate_wait_ms": host._sched_day_climate_wait_ms,
		"sched_day_capture_ms": host._sched_day_capture_ms,
		"sched_day_country_peer_ms": host._sched_day_country_peer_ms,
		"sched_day_country_read_ms": host._sched_day_country_read_ms,
		"sched_proc_frames": host._sched_proc_frames,
		"sched_proc_economy_input_ms": host._sched_proc_economy_input_ms,
		"sched_proc_peer_ms": host._sched_proc_peer_ms,
		"sched_proc_snapshots_ms": host._sched_proc_snapshots_ms,
		"sched_proc_country_read_ms": host._sched_proc_country_read_ms,
		"sched_proc_country_visual_ms": host._sched_proc_country_visual_ms,
		"sched_proc_commit_ms": host._sched_proc_commit_ms,
		"sched_proc_resource_ms": host._sched_proc_resource_ms,
		"sched_proc_visual_ms": host._sched_proc_visual_ms,
		"sched_proc_building_ms": host._sched_proc_building_ms,
		"sched_proc_overlay_ms": host._sched_proc_overlay_ms,
		"sched_proc_last_total_ms": host._sched_proc_last_total_ms,
		"country_read_full_snapshot_applied": host._country_read_last_full_snapshot,
		"country_read_applied_cells": host._country_read_last_applied_cells,
		"country_read_territory_changed_cells": host._country_read_last_territory_changed_cells,
		"country_read_full_snapshot_count": host._country_worker_read_full_snapshot_count,
		"country_read_patch_count": host._country_worker_read_patch_count,
		"country_read_rejected_count": host._country_worker_read_rejected_count,
		"country_visual_last_refresh_ms": host._country_visual_last_refresh_ms,
		"country_visual_refresh_pending": host._country_visual_refresh_pending,
		"country_visual_refresh_deferred_frames": host._country_visual_refresh_deferred_frames,
		"country_visual_refresh_run_count": host._country_visual_refresh_run_count,
		"country_visual_refresh_defer_count": host._country_visual_refresh_defer_count,
		# 帧尾探针：标签重建 / 植被 succession drain 读到的是上一帧的值（这些工作
		# 由 tick 触发、在帧尾 _process 执行，天然滞后本行一帧）；overlay 烘焙是
		# 自上一行以来的累计值，发布后清零。
		"tail_label_ms": host._settlement_label_layer.get_last_rebuild_ms() \
			if host._settlement_label_layer != null else 0.0,
		"tail_label_count": host._settlement_label_layer.get_last_rebuild_label_count() \
			if host._settlement_label_layer != null else 0,
		"tail_vegetation_ms": host._renderer.get_last_detail_drain_ms() \
			if host._renderer != null and host._renderer.has_method("get_last_detail_drain_ms") else 0.0,
		# succession 队列健康度：全链路在途 cell 数与累计入队去重跳过数。稳态下
		# inflight 应有界（≤ 单批气候 dirty 规模），dedup_skips 应随气候提交增长。
		"tail_vegetation_inflight": int(detail_report.get("inflight_cells", 0)),
		"tail_vegetation_dedup_skips": int(detail_report.get("enqueue_dedup_skips", 0)),
		"tail_vegetation_tasks": int(detail_report.get("frame_tasks", 0)),
		"tail_vegetation_forced_tasks": int(detail_report.get("frame_forced_tasks", 0)),
		"tail_vegetation_max_task_ms": float(detail_report.get("max_task_ms", 0.0)),
		"tail_vegetation_plan_ms": float(detail_report.get("plan_ms", 0.0)),
		"tail_vegetation_encode_ms": float(detail_report.get("encode_ms", 0.0)),
		"tail_vegetation_cache_update_ms": float(detail_report.get("cache_update_ms", 0.0)),
		"tail_vegetation_assemble_ms": float(detail_report.get("assemble_ms", 0.0)),
		"tail_vegetation_upload_ms": float(detail_report.get("upload_ms", 0.0)),
		"tail_overlay_ms": host._overlay_bake_ms_accum,
		"tail_overlay_last_bake_ms": host._map_overlay_last_bake_ms,
		"tail_overlay_interval_msec": host._map_overlay_refresh_interval_msec(),
		"tail_overlay_refresh_count": host._map_overlay_refresh_count,
		# 帧级渲染残差探针：frame_wall = 相邻两次发布点间的平均帧墙钟（process
		# frames 差分，多 tick 帧取平均）；engine_process/physics 为引擎监视器原始
		# 值（信息列，其口径与帧墙钟不严格可比）；residual = wall - clock_full -
		# 已知帧尾探针 ≈ 渲染提交 + GPU present + 未埋点 _process 节点。
		# overlay 项只减「最近一次烘焙」而不是跨帧累加值：accum 的时间基准是相邻
		# 两行之间，拿它去减单帧均值会把 residual 恒压成 0，废掉这一列。
		"frame_wall_ms": host._last_frame_wall_ms,
		"engine_process_ms": Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		"engine_physics_ms": Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
		"render_objects_in_frame": Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME),
		"render_primitives_in_frame": Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME),
		"render_draw_calls_in_frame": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		"render_residual_ms": maxf(0.0, host._last_frame_wall_ms
			- (host._world_clock.get_last_full_proc_ms() if host._world_clock != null else 0.0)
			- (host._renderer.get_last_detail_drain_ms() \
				if host._renderer != null and host._renderer.has_method("get_last_detail_drain_ms") else 0.0)
			- (host._settlement_label_layer.get_last_rebuild_ms() \
				if host._settlement_label_layer != null else 0.0)
			- host._map_overlay_last_bake_ms
			- host._sched_proc_country_visual_ms),
	}
	host._sched_proc_frames = 0
	host._sched_proc_economy_input_ms = 0.0
	host._sched_proc_peer_ms = 0.0
	host._sched_proc_snapshots_ms = 0.0
	host._sched_proc_country_read_ms = 0.0
	host._sched_proc_country_visual_ms = 0.0
	host._sched_proc_commit_ms = 0.0
	host._sched_proc_resource_ms = 0.0
	host._sched_proc_visual_ms = 0.0
	host._sched_proc_building_ms = 0.0
	host._sched_proc_overlay_ms = 0.0
	host._overlay_bake_ms_accum = 0.0
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
	if perf_ready and host._perf_recorder != null and host._perf_recorder.has_method("is_recording") \
			and bool(host._perf_recorder.is_recording()) \
			and host._generator != null and host._generator.has_method("get_runtime_perf_snapshot"):
		var runtime_graph: Dictionary = host._generator.get_runtime_perf_snapshot(0)
		if not runtime_graph.is_empty():
			sample["runtime_graph"] = runtime_graph
	if perf_ready:
		var perf_started_usec = Time.get_ticks_usec()
		host.HostRecorders.record(host._perf_recorder, sample)
		out["perf_ms"] = (Time.get_ticks_usec() - perf_started_usec) / 1000.0
	if tile_ready:
		var tile_started_usec = Time.get_ticks_usec()
		var tile_result = host.HostRecorders.record(host._tile_data_recorder, sample)
		out["tile_ms"] = (Time.get_ticks_usec() - tile_started_usec) / 1000.0
		host.HostRecorders.apply_tile_result(tile_result, out)
	if economy_ready:
		var economy_started_usec = Time.get_ticks_usec()
		var economy_result = host.HostRecorders.record(host._economy_data_recorder, sample)
		out["economy_ms"] = (Time.get_ticks_usec() - economy_started_usec) / 1000.0
		host.HostRecorders.apply_economy_result(economy_result, out)
	out["total_ms"] = (Time.get_ticks_usec() - started_usec) / 1000.0
	return out


func finish_daily_tick(host, ui_ms: float, ui_breakdown: Dictionary = {}) -> void:
	# Web 单日成本探针：PlayerController 的 UI/HUD 段是它自己算好后从这里递进来的。
	# 必须记在 early-return 之前 —— whole-graph 分支里 commit 消费点已经先调过
	# 一次 finish_daily_tick(0.0)，把 _pending_tick_start_usec 清掉了，PlayerController
	# 这次会在这里直接返回，UI 数字只有记在前面才不会丢。
	if ui_ms > 0.0 and host._dcp_on():
		# 直接记进当天的桶：PlayerController 是第 2 个 day_changed 监听者，桶到
		# 下一天开始才 flush，所以这一段仍归属**当天**（不能用 _dcp_publish_day
		# 里那个在 host 分支末尾就清掉的暂存值，否则会错记到隔天）。
		host._world_clock.day_cost_add(&"pcui", ui_ms)
	if host._pending_tick_start_usec <= 0:
		return
	host._last_ui_perf_summary = ui_breakdown.duplicate(false)
	host._last_ui_perf_summary["_tick_idx"] = host._fast_tick_count
	var fast_ms_before_recorders = (
		Time.get_ticks_usec() - host._pending_tick_start_usec) / 1000.0
	var recorder_diag = host._publish_fast_tick_perf_sample(
		host._pending_tick_sus_ms,
		host._pending_tick_render_ms,
		maxf(ui_ms, 0.0),
		fast_ms_before_recorders,
		host._pending_tick_skipped_day
	)
	var fast_ms_after_recorders = (
		Time.get_ticks_usec() - host._pending_tick_start_usec) / 1000.0
	host._last_fast_tick_ms = int(round(fast_ms_after_recorders))
	host._last_tick_timing = {
		"tick_idx": host._fast_tick_count,
		"fast_ms": fast_ms_after_recorders,
		"fast_ms_before_recorders": fast_ms_before_recorders,
		"t_sus_ms": host._pending_tick_sus_ms,
		"t_render_ms": host._pending_tick_render_ms,
		"t_ui_ms": maxf(ui_ms, 0.0),
		"was_skipped_day": host._pending_tick_skipped_day,
	}
	if recorder_diag.is_empty():
		host._last_recorder_perf_summary.clear()
	else:
		recorder_diag["fast_ms_before_recorders"] = fast_ms_before_recorders
		recorder_diag["fast_ms_after_recorders"] = fast_ms_after_recorders
		host._last_recorder_perf_summary = recorder_diag
	if host._generator != null and host._current_map != null:
		host._generator.sync_detail_scatter_after_tick(host._current_map)
	host._pending_tick_start_usec = 0


func get_sim_breakdowns(host) -> Dictionary:
	var out: Dictionary = {}
	if host._generator == null:
		return out
	if not host._last_ui_perf_summary.is_empty():
		out["ui"] = host._last_ui_perf_summary.duplicate(false)
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
	var tick_report = host.get_sus_last_tick_report()
	var country_job = tick_report.get("country_daily", {})
	if country_job is Dictionary and host._generator.has_method("get_country_report"):
		var country_report: Dictionary = host._generator.get_country_report()
		var report_day = int(country_report.get(
			"last_committed_day", country_report.get("day_index", -1)))
		var current_day = int(host._world_clock.day_index()) if host._world_clock != null else report_day
		if not country_report.is_empty() and report_day >= 0 and report_day >= current_day:
			var country_breakdown: Dictionary = {
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
			out["country"] = country_breakdown
	var economy_job = tick_report.get("economy_daily", {})
	var economy_report: Dictionary = {}
	if economy_job is Dictionary \
		and str((economy_job as Dictionary).get("skipped_reason", "")) == "" \
		and host._generator.has_method("get_economy_perf_report"):
		# Use the cached compact snapshot. Building the full economy report here
		# used to allocate hundreds of fields on every fast tick.
		economy_report = host._generator.get_economy_perf_report()
		if not economy_report.is_empty():
			economy_report["_tick_idx"] = host._fast_tick_count
			out["economy"] = economy_report
			out["class_opinion"] = {
				"_tick_idx": host._fast_tick_count,
				"revision": economy_report.get("class_opinion_revision", 0),
				"class_hash": economy_report.get("class_opinion_class_hash", 0),
				"country_count": economy_report.get("class_opinion_country_count", 0),
				"class_count": economy_report.get("class_opinion_class_count", 0),
				"cells_scanned": economy_report.get("class_opinion_cells", 0),
				"slots_scanned": economy_report.get("class_opinion_slots_scanned", 0),
				"last_cells_scanned": economy_report.get("class_opinion_last_cells_scanned", 0),
				"last_slots_scanned": economy_report.get("class_opinion_last_slots_scanned", 0),
				"zero_population_rows": economy_report.get(
					"class_opinion_zero_population_rows", 0),
				"last_zero_population_rows": economy_report.get(
					"class_opinion_last_zero_population_rows", 0),
				"ms": economy_report.get("class_opinion_ms", 0.0),
			}
	if host._generator.has_method("get_ideology_report"):
		var ideology: Dictionary = host._generator.get_ideology_report()
		if bool(ideology.get("configured", false)):
			ideology["_tick_idx"] = host._fast_tick_count
			out["ideology"] = ideology
	if host._generator.has_method("get_effect_report"):
		var effect: Dictionary = host._generator.get_effect_report()
		if bool(effect.get("configured", false)):
			effect["_tick_idx"] = host._fast_tick_count
			out["effect"] = effect
	if host._generator.has_method("get_runtime_perf_snapshot"):
		var graph: Dictionary = host._generator.get_runtime_perf_snapshot(0)
		if not graph.is_empty():
			graph["_tick_idx"] = host._fast_tick_count
			out["runtime_graph"] = graph
	return out.duplicate(false)


func get_environment_perf_summary(host) -> Dictionary:
	var summary = host.get_sus_last_tick_summary()
	var out: Dictionary = {
		"tick_idx": host._fast_tick_count,
		"fast_ms": host._last_fast_tick_ms,
		"map_cells": host._current_map.cell_count() if host._current_map != null else 0,
		"last_tick": summary,
		"timing": host._last_tick_timing.duplicate(false),
		"window": {},
		"recorders": host._last_recorder_perf_summary.duplicate(false),
	}
	if host._generator != null and host._generator.has_method("sus_report_sim_budget_window"):
		out["window"] = host._generator.sus_report_sim_budget_window()
	return out


func get_recorder_perf_summary(host) -> Dictionary:
	return host._last_recorder_perf_summary.duplicate(false)


# main.gd dump_render_profile() 的玩家会话等价实现（GM 面板触发，不绑热键）。
# 采样 120 帧输出帧墙钟统计 + SUS/非 SUS 帧均耗时 + 渲染监视器，用来判断高倍速
# 掉帧的成本落在仿真循环内还是渲染/present 侧。
# 输出三通道：print 控制台 + 单次 TXT 快照 + 累积 CSV（A/B 对比友好），
# 落盘路径与 PerfRecorder 一致（桌面 ../../tmp，移动端 user://perf）。
# 返回 {ok, txt_path, csv_path} 或 {ok=false, error}，供 GM 面板回显路径。
# GM/diagnostic methods delegate to the passive adapter.

func _recorder_ready(host, recorder: RefCounted) -> bool:
	return host.HostRecorders._recorder_ready(recorder)


func on_speed_changed(host, new_speed: float) -> void:
	if host._renderer != null:
		if host._renderer.has_method("set_simulation_speed_multiplier"):
			host._renderer.set_simulation_speed_multiplier(new_speed)
		var weather_layer = host._renderer.get_node_or_null("WeatherLayer")
		if weather_layer != null and weather_layer.has_method("set_clock_speed_multiplier"):
			weather_layer.set_clock_speed_multiplier(new_speed)
		var fog_layer = host._renderer.get_node_or_null("FogOfWarLayer")
		if fog_layer != null and fog_layer.has_method("set_clock_speed_multiplier"):
			fog_layer.set_clock_speed_multiplier(new_speed)
		if weather_layer != null and weather_layer.has_method("reset_snapshot_pacing"):
			weather_layer.reset_snapshot_pacing()


func on_clock_running_changed(host, running: bool) -> void:
	if host._renderer == null:
		return
	if host._world_clock != null and host._renderer.has_method("set_simulation_speed_multiplier"):
		host._renderer.set_simulation_speed_multiplier(host._world_clock.speed_multiplier)
	if host._renderer.has_method("set_clock_running"):
		host._renderer.set_clock_running(running)
	var weather_layer = host._renderer.get_node_or_null("WeatherLayer")
	if weather_layer != null and weather_layer.has_method("set_clock_running"):
		weather_layer.set_clock_running(running)
	var fog_layer = host._renderer.get_node_or_null("FogOfWarLayer")
	if fog_layer != null and fog_layer.has_method("set_clock_running"):
		fog_layer.set_clock_running(running)


func _sync_runtime_worker_clock(host) -> void:
	host._clock_binding.synchronize()


func on_visual_day_phase_changed(host, visual_day_phase: float) -> void:
	if host._renderer == null:
		return
	if host._gm_tod_preview_enabled:
		if host.day_night_enabled:
			host._gm_tod_cycle_uv.x = fposmod(visual_day_phase, 1.0)
			host._gm_tod_sun_uv = host._gm_tod_cycle_uv
		host._apply_gm_tod_sun_preview()
		return
	host._renderer.set_day_phase(visual_day_phase)
	if host._tod_profile != null and host._renderer.has_method("apply_tod"):
		host._tod_profile.recompute(visual_day_phase, host.day_night_enabled)
		host._renderer.apply_tod(host._tod_profile)
