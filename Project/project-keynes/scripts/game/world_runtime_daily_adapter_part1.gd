extends RefCounted

## Extracted world_runtime_daily_adapter.gd group 1; state stays with host.

func run_daily_tick(host, day_idx: int, season_phase: float) -> Dictionary:
	if host._is_web_build() and host._runtime_worker_fault_paused:
		return {}
	if not host._runtime_ready_for_ticks or host._generator == null or host._world_clock == null:
		return {}
	host._pending_tick_start_usec = Time.get_ticks_usec()
	if host._renderer != null:
		host._renderer.set_season_phase(season_phase)
		host._renderer.set_climate_anomaly(host._world_clock.climate_anomaly)
	if host._generator.has_method("set_current_fast_tick_idx"):
		host._generator.set_current_fast_tick_idx(host._fast_tick_count + 1)

	var t_sus_usec = Time.get_ticks_usec()
	var report: Dictionary = host._generator.sus_tick_daily(host._world_clock, day_idx, season_phase)
	host._pending_tick_sus_ms = (Time.get_ticks_usec() - t_sus_usec) / 1000.0
	host._refresh_military_terrain_on_season_edge(day_idx)
	# Web 单日成本探针：host 这一处 sus_tick_daily（s2）与它调度的日级 Job 分项。
	# 桌面 _dcp_on() 为假 → 既不记时也不额外读一次 SUS 报告。
	if host._dcp_on():
		host._world_clock.day_cost_add(&"s2", host._pending_tick_sus_ms)
		if host._generator.has_method("sus_report_last_tick"):
			host._world_clock.day_cost_jobs_from(host._generator.sus_report_last_tick())
	# Country ACTIVE day barriers park on peer intents. Callers that drive
	# ticks without idling WorldRuntimeHost._process (headless tests, catch-up
	# batches) still need the transport drained on every day boundary.
	host._service_country_worker_transport()
	host._consume_modifier_worker_snapshot_if_authoritative()
	host._consume_effect_worker_snapshot_if_authoritative()
	host._service_effect_worker_intents_if_authoritative()
	host._consume_trigger_worker_snapshot_if_authoritative()
	host._service_trigger_worker_intents_if_authoritative()
	host._consume_ideology_worker_snapshot_if_authoritative()
	host._service_ideology_worker_intents_if_authoritative()
	host._step_ideology_instance_refresh_if_authoritative(day_idx)
	host._consume_country_worker_read_view_if_authoritative()
	host._fast_tick_count += 1
	if host._renderer != null and host._generator.has_method("has_pending_detail_scatter_refresh") \
			and bool(host._generator.has_pending_detail_scatter_refresh()) \
			and host._renderer.has_method("queue_detail_scatter_refresh"):
		if host._generator.has_method("consume_pending_detail_scatter_changes") \
				and host._renderer.has_method("queue_detail_scatter_changes"):
			host._renderer.queue_detail_scatter_changes(host._generator.consume_pending_detail_scatter_changes())
		else:
			host._renderer.queue_detail_scatter_refresh(host._generator.consume_pending_detail_scatter_refresh_indices())
	var t_render_usec = Time.get_ticks_usec()
	if host._renderer != null:
		if host._renderer.has_method("set_weather_field_texture") and host._world_data != null:
			host._renderer.set_weather_field_texture(null)
		if host._renderer.has_method("refresh_terrain_weather_field_tex"):
			host._renderer.refresh_terrain_weather_field_tex()
		if bool(report.get("fronts_changed", false)) and host._renderer.has_method("set_weather_fronts"):
			host._renderer.set_weather_fronts(report.get("fronts", []))
	host._pending_tick_render_ms = (Time.get_ticks_usec() - t_render_usec) / 1000.0
	if host._settlement_label_layer != null:
		host._settlement_label_layer.sync_from_runtime()
	# 玩家场景每次 day_changed 都真实执行一次 SUS；weather 自身的 stride/policy
	# 不能把同日 climate/economy job 误标成“整日未刷新”。
	host._pending_tick_skipped_day = false
	host._last_tick_report = report.duplicate()
	host._annual_reports.poll()
	host.daily_tick_completed.emit(host._last_tick_report)
	host.mark_map_overlay_dirty(&"authoritative_daily_flush")
	return host._last_tick_report



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
## Host frame split (liveness vs progress):
## - liveness: peer pumps, snapshot ACKs, same-day economy capture, capacity
##   retry. MUST run every frame even when the climate input ring is full.
## - progress: country read-view, building visual, map overlay. May be skipped
##   under climate_input_capacity_day_barrier so peer ACKs get the frame budget.

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
	host._emit_prefetch_boot_once()
	host._emit_web_frame_probe(frame_usec)
	host._emit_web_beat(frame_usec)
	var capacity_pending = (
		host._climate_capacity_pending_day >= 0 and not host._runtime_worker_fault_paused)
	host._web_mark("liveness_begin")
	# P1/P3：先报告领先量并预发布环境帧，再跑既有的 liveness。
	#   - 必须排在 `_service_runtime_liveness` 之前：本帧要发的帧就是 worker
	#     这个 tick 能不能往下跑的前提，晚一帧就退化成锁步。
	#   - **不要**依赖两个 Node 的 _process 相对顺序（历史上踩过）。
	host._service_worker_lead_and_prefetch()
	host._service_runtime_liveness(frame_usec, capacity_pending)
	host._web_mark("liveness_end")
	host._annual_reports.poll()
	host._web_mark("annual_poll_end")
	if capacity_pending:
		host._note_climate_capacity_pending_stall()
		# Worker may have force-advanced past the day that armed capacity.
		# Retrying the stale arm republishes an old env into a full FIFO and
		# keeps the calendar nailed. Advance the pending publish to the
		# worker's next needed day when the committed watermark moved on.
		if host._generator != null and host._generator.has_method("get_runtime_thread_report"):
			var cap_report: Dictionary = host._generator.get_runtime_thread_report()
			var worker_committed = int(cap_report.get(
				"simulation_committed_day", cap_report.get("committed_day", -1)))
			if worker_committed >= host._climate_capacity_pending_day:
				host._climate_capacity_pending_day = worker_committed + 1
		host._on_clock_day_changed(host._climate_capacity_pending_day)
		if host._climate_capacity_pending_day >= 0:
			host._consume_runtime_commit_if_ready()
			host._observe_runtime_worker_fault()
			host._poll_runtime_health()
			# ---- Military layers
			if host.military_map_layers != null and host.military_map_layers.has_method("poll_snapshot"):
				host.military_map_layers.poll_snapshot()
			# ---- Military layers
			host._sched_proc_last_total_ms = host._sched_elapsed_ms(frame_usec)
			return
	host._web_mark("progress_begin")
	host._service_runtime_progress(frame_usec)
	host._web_mark("progress_end")
	host._sched_proc_last_total_ms = host._sched_elapsed_ms(frame_usec)


## P1 + P3：worker 领先量报告 与 环境帧预发布。
##
## 这两件事必须一起做，理由见 tmp/next/day_barrier_protocol.md §3.3.4：
## 只要"主线程不推进日"还等于"worker 拿不到输入"，屏障就还是一个会自我维持的
## 停止条件。预发布把"拿输入"与 `day_changed` 解耦，领先量限流把"停日"从
## "禁止推进"降级成"别让 worker 跑太远"的数字上限。
##
## 关闭时（K==0）本函数只做一次 commit 消费驱动的记账，不发布、不限流 ——
## 行为与改动前逐表达式相同。


func _service_worker_lead_and_prefetch(host) -> void:
	# 每一个早退分支都记一个**稳定短码**。浏览器里"一帧都没发"的成因只可能落在
	# 这十几个码里，而事件流里没有码就只能靠猜 —— 上一轮就是这样浪费了一整轮。
	var diag_on = host._prefetch_diag_enabled()
	if diag_on:
		host._prefetch_diag_tick_prep()
	if not host._runtime_ready_for_ticks or host._generator == null:
		host._prefetch_diag_note(&"no_ready")
		return
	host._poll_environment_prefetch_resume()
	var prefetch_days = host._environment_prefetch_days_active
	if prefetch_days <= 0:
		host._prefetch_diag_note(&"k_le_0")
		return
	if host._world_clock == null:
		host._prefetch_diag_note(&"no_clock")
		return
	if host._native_daily_inline_active:
		host._prefetch_diag_note(&"inline")
		return
	if host._runtime_worker_fault_paused:
		host._prefetch_diag_note(&"fault_paused")
		return
	var ext = host._generator.get_data_core_world_ext() \
		if host._generator.has_method("get_data_core_world_ext") else null
	if ext == null:
		host._prefetch_diag_note(&"no_ext")
		return
	if not ext.has_method("environment_ring_has_capacity"):
		host._prefetch_diag_note(&"no_cap")
		return
	if not ext.has_method("runtime_committed_day"):
		host._prefetch_diag_note(&"no_cmd")
		return
	# 已提交日是上界：环里未消费的帧只是内存，不是事实。
	var committed_raw = int(ext.runtime_committed_day())
	# 日历日与已提交日都可能读到**负值**，这不是"没有水位"，而是启动哨兵：
	#   - `_world_clock.day_index()` = `_last_day`，在第一个"非暂停帧"之前一直是
	#     -1（`_process` 的 paused 早退在哨兵对齐之前）；
	#   - host 的 `_committed_day` 取自 `config["day"]`，也就是同一个 -1。
	# 旧写法里 `if committed < 0: return` 会在浏览器启动窗口直接把预发布**永久**
	# 关死；`clock_day + K` 这个上界也会被 -1 压成"最多只能发 1 帧"。
	# 两者叠加正好是"max_day=1 且 frames_ahead=0"。所以这里统一按 0 **以下的下界**
	# 处理，而不是当成"没有数据"。
	var committed = maxi(committed_raw, -1)
	var clock_day_raw = host._world_clock.day_index()
	var clock_day = maxi(clock_day_raw, 0)
	# 廉价字段每帧都填（全部已经在手上，无额外开销），供 `prefetch_diag` 带上。
	host._prefetch_diag_snapshot["capable"] = true
	host._prefetch_diag_snapshot["ready"] = true
	host._prefetch_diag_snapshot["committed"] = committed
	host._prefetch_diag_snapshot["committed_raw"] = committed_raw
	host._prefetch_diag_snapshot["clock_day"] = clock_day_raw
	host._prefetch_diag_snapshot["paused"] = bool(host._world_clock.paused)
	# P3：把领先/落后两个方向都写回时钟。落后方向是安全网 —— 没有它，日历会
	# 在 worker 卡住时自顾自往前跑（实测能跑到 365 天而模拟停在第 1 天）。
	host._world_clock.report_worker_lead_days(committed - clock_day)
	host._world_clock.report_worker_lag_days(clock_day - committed)
	# ── 发布上界 ─────────────────────────────────────────────────────────
	# 语义只有一条：**worker 相对日历的领先量必须 < K**。
	#   base   = max(committed + 1, 0)         worker 下一步要用的日（负数当 0）
	#   lead   = committed - clock_day         已提交相对日历的领先
	#   lead >= K ⇒ 本帧不发（等日历追上来）
	# 这一条同时替代了旧的两条：`committed + 1 + K`（防越界）和 `clock_day + K`
	# （防自激）。旧写法的问题正是它是**和式**：任何一边读成负值都会把上界压到
	# 低于 base，于是"worker 需要的下一帧"永远发不出去。
	var base = maxi(committed + 1, 0)
	var lead = committed - clock_day
	# 发布窗口深度：`prefetch_days`(K) 只决定"日历锚定几天前"，真正允许的在途深度
	# 必须显著更大，否则 worker 永远只能领先 K 天 —— 每消费一天都要等主线程下一帧
	# 再补一帧，等于每算一天绕一个来回。真机实测：worker `execute` 只要 60 ms/天，
	# 但 `input_wait` 高达 88 ms/天，正是这个来回。
	# 上限取 K + WORKER_LEAD_MARGIN_DAYS（= 时钟侧 `max_lead`，两边同一个数）。
	var lead_cap = prefetch_days + host.WORKER_PUBLISH_DEPTH_DAYS
	if lead >= lead_cap:
		host._prefetch_diag_note(&"lead_over")
		return
	# 游标只认 C++ 的发布水印：下一帧就是最后一帧的下一天。
	var cursor = host._generator.next_environment_day()
	var limit = base + lead_cap - 1
	if cursor < 0:
		host._prefetch_diag_note(&"no_host")
		return
	if cursor > limit:
		host._prefetch_diag_note(&"cursor_over")
		return
	# 每帧最多发一帧。一帧 = 26+10 条 per-cell lane 的打包（万级格数是毫秒级），
	# 一帧发两帧就会把主线程尖峰翻倍。10 天/秒 @60fps 只需要 0.17 帧/帧，所以
	# 一帧一帧发完全跟得上；跟不上时 worker 会在 K 天外等下一帧，而 K 的余量
	# 本来就是为这种抖动准备的。
	var published = 0
	while cursor <= limit and published < 1:
		if not bool(ext.environment_ring_has_capacity()):
			host._prefetch_diag_note(&"ring_full")
			return
		var capture_started_usec = Time.get_ticks_usec()
		var captured: Dictionary = host._generator.publish_environment_through(
			cursor, host._world_clock.season_phase_for_day(cursor),
			MapGenerator.ENV_CALLSITE_PREFETCH)
		host._prefetch_diag_last_capture_usec = Time.get_ticks_usec() - capture_started_usec
		if bool(captured.get("suppressed", false)):
			# 发布权不在预发布器手上（配置回退），立刻停手，交给 S1/S2/S3。
			host._prefetch_diag_note(&"suppressed")
			return
		if not bool(captured.get("ok", false)):
			# ring 满 / 拓扑换代 / capture 失败：本帧放弃，下一帧重算上界。
			host._prefetch_diag_last_reason = String(captured.get("code",
				captured.get("fallback_reason", "capture_failed")))
			host._prefetch_diag_note(&"capture_fail")
			return
		cursor += 1
		published += 1
		host._prefetch_diag_publish_count += 1
	host._prefetch_diag_note(&"published")


# ─── 预发布决定级可观测性（prefetch_diag）────────────────────────────────
#
# 为什么需要：浏览器里"worker 起来了但一帧环境帧都没发"这个形态，在事件流里
# 完全没有痕迹 —— `frames_ahead=0` 既可能是"没到发的时候"，也可能是"某个
# has_method 在 wasm 上返回 false"。把**每个早退分支**钉成一个稳定短码之后，
# 一次网页运行就能读出是哪一支。
#
# 契约：
#   * 每帧只记一个码（最后一次判定的结果），不逐帧发事件；
#   * 每 ~2000 ms 聚合成**一条** `prefetch_diag`（payload < 200 B）；
#   * `seen` 只放"自上次事件以来出现过的码 + 次数"，按次数降序取前 4 个。
#   * headless 想看得设 `PK_PREFETCH_DIAG=1`（桌面默认不打印）。
## 一次性"环境自检"：只在第一条 `prefetch_diag` 里出现一次。
## 这些位回答的是"预发布器到底有没有被调到 / 它依赖的方法在 wasm 上存不存在"，
## 一个网页运行就能定性，不必再猜。
## 上一次判定时的快照字段（供事件里带出，避免事件里再读一遍 ext）。



func _prefetch_diag_tick_prep(host) -> void:
	host._prefetch_diag_snapshot = {}


## 诊断本身也要零成本：桌面（非 web、且没显式开 PK_PREFETCH_DIAG）整条短路，
## 否则 `_process` 每帧会多一次字典分配。判据在会话内不会变，缓存一次。



func _prefetch_diag_enabled(host) -> bool:
	if host._prefetch_diag_on_cache < 0:
		host._prefetch_diag_on_cache = 1 if (host._is_web_build() \
			or OS.get_environment("PK_PREFETCH_DIAG") == "1") else 0
	return host._prefetch_diag_on_cache != 0




## 启动自检：**无论预发布器有没有被调到**都发一次。
##
## 这一条是给浏览器用的"到底谁没跑"的答案：如果连 `code=boot` 都收不到，说明
## 本节点的 `_process` 没在跑（或者 `?worker=1` 没被读到，见 `b.meta`）；
## 如果收到了但之后一条 `prefetch_diag` 都没有，说明预发布器在某个早退分支上
## 停住了，而 `b` 里的 `ext_cap/ext_cmd/has_pub/proc_gen` 会指出是哪一个。
##
## 用与周期事件相同的 `prefetch_diag` 类型，不新增事件类型。


func _emit_prefetch_boot_once(host) -> void:
	if host._prefetch_boot_emitted or not host._is_web_build():
		return
	# 约 2 秒（30fps）之后，足够覆盖"世界生成完 → 第一帧 _process"的窗口。
	if host._sched_proc_frames < 60:
		return
	# 预发布器已经发过事件 ⇒ 它的第一条事件里已经带过 `b`（同一份自检），
	# 这条 boot 事件就不再重复发，避免事件流里多一条噪声。
	if host._prefetch_diag_emit_count > 0:
		host._prefetch_boot_emitted = true
		return
	host._prefetch_boot_emitted = true
	var payload = {
		"code": "boot",
		"k": host._environment_prefetch_days_active,
		"max_lead": host._max_worker_lead_days,
		"proc_n": host._sched_proc_frames,
		"ready": 1 if host._runtime_ready_for_ticks else 0,
		"clk": host._world_clock.day_index() if host._world_clock != null else -999,
	}
	payload["b"] = host._prefetch_diag_boot_payload()
	WebTelemetry.emit("prefetch_diag", payload)
	if not OS.has_feature("web") and OS.get_environment("PK_PREFETCH_DIAG") == "1":
		print("[prefetch_diag] ", JSON.stringify(payload))



func _prefetch_diag_boot_payload(host) -> Dictionary:
	if not host._prefetch_diag_boot.is_empty():
		return {}
	var ext = null
	if host._generator != null and host._generator.has_method("get_data_core_world_ext"):
		ext = host._generator.get_data_core_world_ext()
	host._prefetch_diag_boot = {
		# 谁在跑：`proc_host` = 本节点的 _process 是否启用，`proc_n` 见周期事件。
		# 浏览器上"帧一帧都没发"最可能的原因之一就是 host 的 _process 没跑，
		# 而这一点在既有 diag 里完全看不见。
		# 注意 MapGenerator 是 RefCounted（没有 _process），不要对它调 is_processing。
		"in_tree": 1 if host.is_inside_tree() else 0,
		"proc_host": 1 if host.is_processing() else 0,
		"proc_clk": 1 if (host._world_clock != null and host._world_clock.has_method("is_processing") \
			and host._world_clock.is_processing()) else 0,
		# 依赖的方法是否真的存在（wasm 上 side module 旧/未绑定时会是 0）
		"has_pub": 1 if (host._generator != null \
			and host._generator.has_method("set_worker_environment_publisher")) else 0,
		"has_diag": 1 if (host._generator != null \
			and host._generator.has_method("environment_publish_diagnostics")) else 0,
		"ext_cap": 1 if (ext != null \
			and ext.has_method("environment_ring_has_capacity")) else 0,
		"ext_cmd": 1 if (ext != null and ext.has_method("runtime_committed_day")) else 0,
		# 开关来源：浏览器里 env 恒空，必须靠 meta
		"meta": 1 if bool(Engine.get_meta("pk_web_worker", false)) else 0,
		"env": 1 if OS.get_environment("PK_WEB_WORKER") == "1" else 0,
	}
	return host._prefetch_diag_boot



func _prefetch_diag_note(host, code: StringName) -> void:
	if not host._prefetch_diag_enabled():
		return
	host._prefetch_diag_last_code = code
	host._prefetch_diag_counts[code] = int(host._prefetch_diag_counts.get(code, 0)) + 1
	var now_msec = Time.get_ticks_msec()
	if host._prefetch_diag_next_msec == 0:
		host._prefetch_diag_next_msec = now_msec + host._PREFETCH_DIAG_INTERVAL_MSEC
		return
	if now_msec < host._prefetch_diag_next_msec:
		return
	host._prefetch_diag_next_msec = now_msec + host._PREFETCH_DIAG_INTERVAL_MSEC
	host._prefetch_diag_collect_extras()
	host._emit_prefetch_diag(code)


## 昂贵字段只在**要发事件时**读一次（每 ~2 s 一次），逐帧零成本。
## `get_runtime_thread_report()` 会复制一整个 RuntimeThreadReport，不能每帧调。


func _prefetch_diag_collect_extras(host) -> void:
	if host._generator == null or not host._generator.has_method("get_runtime_thread_report"):
		return
	var report: Dictionary = host._generator.get_runtime_thread_report()
	host._prefetch_diag_snapshot["ring_pending"] = int(
		report.get("environment_ring_pending", -1))
	host._prefetch_diag_snapshot["frames_ahead"] = maxi(0,
		int(report.get("simulation_environment_day", 0)) \
		- int(report.get("simulation_committed_day", 0)))
	if host._generator.has_method("environment_publish_diagnostics"):
		var pub: Dictionary = host._generator.environment_publish_diagnostics()
		host._prefetch_diag_snapshot["publish_count"] = int(
			pub.get("environment_publish_count", -1))
		host._prefetch_diag_snapshot["suppressed"] = int(
			pub.get("environment_publish_suppressed", -1))
		host._prefetch_diag_snapshot["callsite"] = int(
			pub.get("environment_publisher_callsite", -1))


## 把"自上次事件以来"的码表压成 `code:count,...`，按次数降序取前 4。


func _prefetch_diag_seen_text(host) -> String:
	var pairs: Array = []
	for key in host._prefetch_diag_counts.keys():
		pairs.append([String(key), int(host._prefetch_diag_counts[key])])
	pairs.sort_custom(func(a, b): return int(a[1]) > int(b[1]))
	var parts: PackedStringArray = PackedStringArray()
	for index in range(mini(4, pairs.size())):
		parts.append("%s:%d" % [pairs[index][0], pairs[index][1]])
	return ",".join(parts)



func _emit_prefetch_diag(host, code: StringName) -> void:
	host._prefetch_diag_emit_count += 1
	var snap = host._prefetch_diag_snapshot
	var payload = {
		# ── 父 agent 指定的核心字段（短键，控体积）──
		"code": String(code),
		"k": host._environment_prefetch_days_active,
		"lead": int(host._world_clock.get_worker_lead_days()) if host._world_clock != null \
			and host._world_clock.has_method("get_worker_lead_days") else -1,
		"max_lead": host._max_worker_lead_days,
		"rp": int(snap.get("ring_pending", -1)),
		"fa": int(snap.get("frames_ahead", -1)),
		"cd": int(snap.get("committed", -999)),
		"cap": 1 if bool(snap.get("capable", false)) else 0,
		# ── 定位"wasm 上会不一样"所需的旁证 ──
		"clk": int(snap.get("clock_day", -999)),
		"cd_raw": int(snap.get("committed_raw", -999)),
		"paused": 1 if bool(snap.get("paused", false)) else 0,
		"ready": 1 if bool(snap.get("ready", false)) else 0,
		"pub": int(snap.get("publish_count", -1)),
		"sup": int(snap.get("suppressed", -1)),
		"cs": int(snap.get("callsite", -1)),
		"bp": int(host._prefetch_diag_publish_count),
		"seg": host._prefetch_diag_last_code,
		"seen": host._prefetch_diag_seen_text(),
		# 本节点已跑过的 _process 帧数：它是"预发布器在不在跑"的正面证据。
		"proc_n": host._sched_proc_frames,
		# 屏障豁免通道：`bar`=此刻有没有任何 backpressure source 抬着；
		# `rel`=因"预发布暂停"而豁免日历屏障的累计帧数；`pd`=时钟侧看到的 K。
		# 三者同看，才能区分"没有屏障"与"有屏障但被豁免了"。
		"bar": 1 if (host._world_clock != null \
			and host._world_clock.has_method("has_simulation_backpressure") \
			and host._world_clock.has_simulation_backpressure()) else 0,
		"rel": int(host._world_clock.get_barrier_released_frame_count()) \
			if (host._world_clock != null \
				and host._world_clock.has_method("get_barrier_released_frame_count")) else -1,
		"pd": int(host._world_clock.get_worker_prefetch_days()) \
			if (host._world_clock != null \
				and host._world_clock.has_method("get_worker_prefetch_days")) else -1,
	}
	var boot = host._prefetch_diag_boot_payload()
	if not boot.is_empty():
		payload["b"] = boot
	if host._prefetch_diag_last_reason != "":
		payload["why"] = host._prefetch_diag_last_reason.substr(0, 24)
	if host._prefetch_diag_last_capture_usec > 0:
		# wasm 上 GDScript 打包一帧的墙钟（毫秒）。>100ms 说明单帧成本已经
		# 吃满预算，"发不动"其实是"太贵"，与门控无关。
		payload["cap_ms"] = int(host._prefetch_diag_last_capture_usec / 1000)
	host._prefetch_diag_counts.clear()
	WebTelemetry.emit("prefetch_diag", payload)
	if not OS.has_feature("web") and OS.get_environment("PK_PREFETCH_DIAG") == "1":
		print("[prefetch_diag] ", JSON.stringify(payload))



## 存盘前必须先把预发布降下来并让环排空：`build_save_bundle` 的 worker 侧准入
## 条件是 `!has_pending_climate_input()`，环长期非空会让存盘永远等不到。
## 这里把 K 降到 0；环里的帧由 worker 自己按 `pop_while_day_at_most`
## 消费，不再有新帧进来。恢复时调用 `_resume_environment_prefetch_after_save()`。


func _suspend_environment_prefetch_for_save(host, reason: String) -> void:
	if host._max_worker_lead_days <= 0:
		return
	host._environment_prefetch_suspended_for_save = true
	host._max_worker_lead_days = 0
	host._environment_prefetch_days_active = 0
	host._release_prefetch_barrier_to_clock()
	if host._world_clock != null and host._world_clock.has_method("set_max_worker_lead_days"):
		host._world_clock.set_max_worker_lead_days(0)
		if host._world_clock.has_method("set_max_worker_lag_days"):
			host._world_clock.set_max_worker_lag_days(0)
	if host._generator != null and host._generator.has_method("set_worker_environment_publisher"):
		host._generator.set_worker_environment_publisher(0)
	print("[runtime-worker] P1 prefetch suspended for save (%s)" % reason)



func _resume_environment_prefetch_after_save(host) -> void:
	if not host._web_worker_requested() or host._native_daily_inline_active:
		return
	# 能力门必须在恢复路径上再判一次：存盘窗口里 side module 不会变，但这条
	# 判据同时守着 `PK_NO_ENV_PREFETCH` 与"旧 side module"两种情形，任何
	# 绕过它的恢复都会把发布权重新交给一个发不出帧的预发布器。
	if not host._environment_prefetch_capable():
		return
	var prefetch_days = host._effective_environment_prefetch_days()
	if prefetch_days <= 0:
		return
	var lead_budget = prefetch_days + host.WORKER_LEAD_MARGIN_DAYS
	host._environment_prefetch_suspended_for_save = false
	if host._max_worker_lead_days == lead_budget:
		return
	host._max_worker_lead_days = lead_budget
	host._environment_prefetch_days_active = prefetch_days
	host._release_prefetch_barrier_to_clock()
	if host._world_clock != null and host._world_clock.has_method("set_max_worker_lead_days"):
		host._world_clock.set_max_worker_lead_days(lead_budget)
		if host._world_clock.has_method("set_max_worker_lag_days"):
			host._world_clock.set_max_worker_lag_days(lead_budget)
	if host._generator != null and host._generator.has_method("set_worker_environment_publisher"):
		host._generator.set_worker_environment_publisher(MapGenerator.ENV_CALLSITE_PREFETCH)
	# 存盘请求到达时由 MapGenerator 回调这里（它才是 request_runtime_save 的入口，
	# 而 game_save_coordinator 直接调的是它，不经过本 host）。
	if host._generator != null and host._generator.has_method("set_save_prefetch_suspend_callback"):
		host._generator.set_save_prefetch_suspend_callback(Callable(
			host, "_suspend_environment_prefetch_for_save"))


## 存盘窗口结束后恢复预发布。判据用"worker 不再处于 SAVE_PENDING"而不是
## "过了一段时间"——前者是真实边界，后者只是猜。
##
## **只有 `_environment_prefetch_suspended_for_save` 为真时才可能恢复。**
## 用 `_max_worker_lead_days == 0` 当"被暂停了"的判据是个陷阱：能力门
## （旧 side module / `PK_NO_ENV_PREFETCH`）与"worker 没起来"也会把它置 0，
## 那样本函数会在下一帧把发布权抢回给预发布器，而预发布器根本发不出去 ⇒
## 环境帧为 0 ⇒ 日历停在 day 1。这正是本轮 web 事故的形态。


func _poll_environment_prefetch_resume(host) -> void:
	if not host._environment_prefetch_suspended_for_save:
		return
	if host._max_worker_lead_days > 0 or not host._web_worker_requested() \
			or host._native_daily_inline_active or host._generator == null:
		return
	if not host._environment_prefetch_capable():
		return
	if not host._generator.has_method("get_runtime_thread_report"):
		return
	var report: Dictionary = host._generator.get_runtime_thread_report()
	if String(report.get("simulation_host_state", "")) == "SAVE_PENDING":
		return
	host._resume_environment_prefetch_after_save()



var _construction_receipt_poll_ms: int = 0


func _service_runtime_liveness(host, frame_usec: int, _capacity_pending: bool) -> void:
	var segment_usec = frame_usec
	if host._runtime_ready_for_ticks and host._generator != null:
		var ext = host._generator.get_data_core_world_ext()
		if ext != null:
			# -1 只服务 worker 请求的同日输入，不推进经济公式。
			ext.capture_economy_day_inputs(-1)
		# 营造回执不能只等经济 pulse：worker PAUSED / 日历冻结时 pulse 不来，
		# 玩家会一直停在「已排队」。这里按墙钟节流做一次纯读轮询，
		# facade 的游标保证同一条回执不会被重复派发。
		var receipt_now := Time.get_ticks_msec()
		if receipt_now - _construction_receipt_poll_ms >= 250:
			_construction_receipt_poll_ms = receipt_now
			if host._generator.has_method("get_economy_facade"):
				var economy = host._generator.get_economy_facade()
				if economy != null and economy.has_method(
						"dispatch_construction_command_receipts"):
					economy.dispatch_construction_command_receipts()
	host._sched_proc_economy_input_ms += host._sched_elapsed_ms(segment_usec)
	segment_usec = Time.get_ticks_usec()
	host._service_country_worker_transport()
	host._sched_proc_peer_ms += host._sched_elapsed_ms(segment_usec)
	segment_usec = Time.get_ticks_usec()
	host._consume_modifier_worker_snapshot_if_authoritative()
	host._consume_effect_worker_snapshot_if_authoritative()
	host._service_effect_worker_intents_if_authoritative()
	host._consume_trigger_worker_snapshot_if_authoritative()
	host._service_trigger_worker_intents_if_authoritative()
	host._consume_ideology_worker_snapshot_if_authoritative()
	host._service_ideology_worker_intents_if_authoritative()
	if host._ideology_refresh_pending_day >= 0:
		host._step_ideology_instance_refresh_if_authoritative(host._ideology_refresh_pending_day)
	host._sched_proc_snapshots_ms += host._sched_elapsed_ms(segment_usec)



func _service_runtime_progress(host, frame_usec: int) -> void:
	var segment_usec = Time.get_ticks_usec()
	host._consume_country_worker_read_view_if_authoritative()
	host._sched_proc_country_read_ms += host._sched_elapsed_ms(segment_usec)
	host._consume_runtime_commit_if_ready()
	host._observe_runtime_worker_fault()
	host._poll_runtime_health()
	segment_usec = Time.get_ticks_usec()
	# Army movement is a committed Military projection rather than a Country
	# territory event. On graphical sessions this is the one map-layer snapshot
	# poll; its feed callback runs before the coalesced visual refresh so mobile
	# units become vision sources on the same frame as their new position.
	if host.military_map_layers != null \
			and host.military_map_layers.has_method("poll_snapshot"):
		host.military_map_layers.poll_snapshot()
	else:
		host._poll_military_vision_revision()
	host._service_country_visual_refresh_budgeted(frame_usec)
	host._sched_proc_country_visual_ms += host._sched_elapsed_ms(segment_usec)
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



func _arm_climate_capacity_pending(host, day_idx: int) -> void:
	if host._climate_capacity_pending_day != day_idx:
		host._climate_capacity_pending_since_msec = Time.get_ticks_msec()
		host._climate_capacity_stall_next_diag_msec = 0
	host._climate_capacity_pending_day = day_idx
	if host._world_clock != null:
		# P3：领先量限流打开时**不再**抬 `climate_input_capacity_day_barrier`。
		#
		# 原因：那个 source 的语义是"这一天不许推进"，而它被抬起的起因是
		# "worker 还没消费完环境帧"。主线程一停日，就再也不会有人调用 capture，
		# 于是它变成一个会自我维持的停止条件。改成"本帧不重试、下一帧再试"+
		# 领先量上限之后，日历不再被 worker 的等待状态绑架。
		#
		# `_climate_capacity_pending_day` 仍然记账：`_process` 里那条"重试保留日"
		# 的路径依赖它，关掉的是**屏障**而不是记账。
		if host._max_worker_lead_days > 0:
			return
		host._world_clock.request_simulation_backpressure(&"climate_input_capacity_day_barrier", true)



func _clear_climate_capacity_pending(host) -> void:
	host._climate_capacity_pending_day = -1
	host._climate_capacity_pending_since_msec = 0
	host._climate_capacity_stall_next_diag_msec = 0
	if host._world_clock != null:
		host._world_clock.request_simulation_backpressure(&"climate_input_capacity_day_barrier", false)




## G4 moved host responsibilities
func _run_native_daily_inline_day(host, day_idx: int, report: Dictionary) -> Dictionary:
	var ext = host._generator.get_data_core_world_ext() \
		if host._generator != null and host._generator.has_method("get_data_core_world_ext") else null
	if ext == null or not ext.has_method("run_native_daily_inline_day"):
		if host._reject_web_daily_fallback("web_native_daily_api_missing", "缺少原生日推进入口，请更新网页原生模块"):
			return {"ok": false, "code": "native_daily_inline_api_missing"}
		if host._native_daily_inline_active:
			push_error("[runtime-inline] run_native_daily_inline_day 缺失：回退到主线程 daily tick")
			host._native_daily_inline_active = false
		return {"ok": false, "code": "native_daily_inline_api_missing"}
	var segment_usec = Time.get_ticks_usec()
	WebTelemetry.emit("inline_step", {"d": day_idx, "s": "enter"})
	# 单日单推进声明：今天由**内联执行器**推进。同一 day 上若已有别人声明过
	# （正常不会发生：生产场景里只有本 host 推进模拟），main.gd 那套 GDScript
	# SUS 日 tick 会自己让位。这里只是登记，不影响本函数的执行。
	host._claim_day_for_native(day_idx, &"native_inline")
	host._apply_climate_writeback_if_authoritative(report)
	host._sched_day_climate_writeback_ms += host._sched_elapsed_ms(segment_usec)
	WebTelemetry.emit("inline_step", {"d": day_idx, "s": "after_writeback"})
	segment_usec = Time.get_ticks_usec()
	host._service_country_worker_transport()
	host._sched_day_country_peer_ms += host._sched_elapsed_ms(segment_usec)
	WebTelemetry.emit("inline_step", {"d": day_idx, "s": "after_transport"})
	# 输入日必须等于 host 的 committed_day+1。内联日没有跨线程重试，错日会直接
	# 停在 inline_daily_environment_day_mismatch，所以这里按 host 的提交水印取值。
	var host_day = int(report.get("simulation_committed_day",
		report.get("committed_day", -1)))
	var next_day = host_day + 1
	segment_usec = Time.get_ticks_usec()
	if host._generator.has_method("publish_environment_through"):
		host._generator.publish_environment_through(
			maxi(0, next_day), host._world_clock.season_phase_for_day(day_idx),
			MapGenerator.ENV_CALLSITE_INLINE_DAY)
	host._sched_day_capture_ms += host._sched_elapsed_ms(segment_usec)
	WebTelemetry.emit("inline_step", {"d": day_idx, "s": "after_capture",
		"ms": int(host._sched_elapsed_ms(segment_usec))})
	# 探针：native 调用本身的独立 epoch（桌面 _dcp_on() 为假时连计时都不做）。
	var _dcp_native_usec: int = Time.get_ticks_usec() if host._dcp_on() else 0
	host._prepare_military_exploration_day(next_day)
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
			print("[runtime-inline] day=%d pending reason=%s attempts=%d peer_pumped=%d host_day=%d" % [
				day_idx, String(result.get("reason", "?")),
				int(result.get("attempts", 0)), int(result.get("peer_pumped", 0)),
				host_day])
	# 提交已经发布；把同一份提交落到 MapData/slot，本帧的 UI/渲染就能读到今天。
	#
	# 探针：这里的 commit 消费是 inline_day 事件**看不到**的那一段——它排在
	# inline_day 打点之后，包含 LUT 重编码 / 天气场纹理刷新 / 自然资源回灌 /
	# 视觉 patch 应用。day_cost_ema 与 inline_day 的差额主要就落在这里。
	if host._dcp_on():
		var dcp_commit_usec = Time.get_ticks_usec()
		# 复用同一调用栈里刚取的那份 report（内联日没有 worker 线程，两次读取
		# 必然同值），省掉一天里第二次 get_runtime_thread_report() 打包。
		host._consume_runtime_commit_if_ready(report)
		host._dcp_commit_ms = float(Time.get_ticks_usec() - dcp_commit_usec) / 1000.0
	else:
		host._consume_runtime_commit_if_ready()
	return result


func _clock_day_changed_impl(host, day_idx: int) -> void:
	if host._is_web_build() and host._runtime_worker_fault_paused:
		return
	# OFF/SHADOW keep the synchronous reference authority in this host. The
	# PlayerController only consumes the resulting state for UI; it must not be
	# another simulation entry point.
	var day_started_usec = Time.get_ticks_usec()
	host._sched_day_report_ms = 0.0
	host._sched_day_snapshots_ms = 0.0
	host._sched_day_climate_writeback_ms = 0.0
	host._sched_day_climate_wait_ms = 0.0
	host._sched_day_capture_ms = 0.0
	host._sched_day_country_peer_ms = 0.0
	host._sched_day_country_read_ms = 0.0
	host._sched_day_promote_ms = 0.0
	# Web 单日成本探针的 host 分段（未开探针时这几行只是置 0，全部是本类私有
	# 字段，没有任何生产读取点）。
	host._dcp_inline_ms = 0.0
	host._dcp_commit_ms = 0.0
	host._dcp_publish_ms = 0.0
	host._dcp_finish_ms = 0.0
	host._dcp_resource_ms = 0.0
	host._dcp_military_ms = 0.0
	host._dcp_visual_ms = 0.0
	if not host._runtime_ready_for_ticks or host._generator == null or host._world_clock == null:
		host._sched_day_total_ms = host._sched_elapsed_ms(day_started_usec)
		return
	var segment_usec = Time.get_ticks_usec()
	var report = host._generator.get_runtime_thread_report() \
		if host._generator.has_method("get_runtime_thread_report") else {}
	host._sched_day_report_ms = host._sched_elapsed_ms(segment_usec)
	# native_daily_inline：没有 worker 线程，这一天的 12 域日屏障就在本线程上跑。
	# 必须放在下面的 capacity wait 之前 —— 内联执行者自己消费环境帧，ring 容量
	# 从来不是问题，去等一个"worker 消费"的信号只会把主线程钉住。
	if host._native_daily_inline_active:
		host._annual_reports.before_day(day_idx)
		host._run_native_daily_inline_day(day_idx, report)
		host._sched_day_total_ms = host._sched_elapsed_ms(day_started_usec)
		return
	# Capacity waits must yield to _process so peer ACKs and writeback keep
	# running. Retain this semantic day instead of dropping a rejected input.
	if bool(report.get("climate_worker_authoritative", false)):
		segment_usec = Time.get_ticks_usec()
		var capacity = host.wait_for_climate_consumed(0)
		host._sched_day_climate_wait_ms += host._sched_elapsed_ms(segment_usec)
		if not bool(capacity.get("ok", false)):
			# Peer pump before parking: Country/fiscal soft-commit may be what
			# frees ring capacity. wait_for_climate_consumed(0) does not pump.
			segment_usec = Time.get_ticks_usec()
			host._service_country_worker_transport()
			host._sched_day_country_peer_ms += host._sched_elapsed_ms(segment_usec)
			host._arm_climate_capacity_pending(day_idx)
			host._sched_day_total_ms = host._sched_elapsed_ms(day_started_usec)
			return
	host._clear_climate_capacity_pending()
	host._annual_reports.before_day(day_idx)
	# Whole-graph only. `authority_ready` stays false until every domain has a
	# POD handler; a per-domain promotion (Climate) must NOT skip the tick,
	# because the other eleven domains are still computed right here. Reading
	# `simulation_worker_ready` instead would stop economy, country, triggers
	# and perf recording the moment Climate alone was promoted — the tick is
	# the entry point for all of them, not just Climate. Climate itself is
	# suppressed further down, inside the native daily graph.
	var whole_graph_authoritative = String(report.get("simulation_thread_mode", "OFF")) == "ACTIVE" \
		and bool(report.get("authority_ready", false))
	if whole_graph_authoritative:
		# 单日单推进声明：今天由 worker 整图权威推进（web 上这条分支不会走到，
		# 内联在上面就 return 了；桌面 _day_barrier_claim_enabled=false → 空转）。
		host._claim_day_for_native(day_idx, &"native_worker")
		# Worker owns domain formulas, but the host must still:
		#   writeback → (optional season) → capture next-day environment → peer pump.
		# Skipping capture here parks the worker on environment wait while it still
		# holds the authority-boundary lock; any blocking switch then freezes Godot.
		if bool(report.get("climate_worker_authoritative", false)):
			segment_usec = Time.get_ticks_usec()
			host._consume_modifier_worker_snapshot_if_authoritative()
			host._consume_effect_worker_snapshot_if_authoritative()
			host._service_effect_worker_intents_if_authoritative()
			host._consume_trigger_worker_snapshot_if_authoritative()
			host._service_trigger_worker_intents_if_authoritative()
			host._consume_ideology_worker_snapshot_if_authoritative()
			host._service_ideology_worker_intents_if_authoritative()
			host._sched_day_snapshots_ms += host._sched_elapsed_ms(segment_usec)
		segment_usec = Time.get_ticks_usec()
		host._apply_climate_writeback_if_authoritative(report)
		host._sched_day_climate_writeback_ms += host._sched_elapsed_ms(segment_usec)
		if bool(report.get("climate_worker_authoritative", false)):
			segment_usec = Time.get_ticks_usec()
			var capacity_result = host.wait_for_climate_consumed(0)
			host._sched_day_climate_wait_ms += host._sched_elapsed_ms(segment_usec)
			if not bool(capacity_result.get("ok", false)):
				# [android-day1-deadlock 2026-11-01] 这里以前静默 return：一旦 worker
				# 因为没输入而不再消费环境环，day_changed 每次都在这里掉头，capture
				# 永不执行 → ring 恒 0 → worker 永远等输入。安卓上正是这个死循环，
				# 所以把"谁拒绝了这次容量检查"打出来。
				if host._day_capture_blocked_logs < 8:
					host._day_capture_blocked_logs += 1
					print("[day-capture] blocked day=%d code=%s state=%s consumed=%s ring=%s" % [
						day_idx, String(capacity_result.get("code", "?")),
						str(capacity_result.get("worker_state", -1)),
						str(capacity_result.get("consumed_generation", -1)),
						str(capacity_result.get("ring_pending", -1))])
				segment_usec = Time.get_ticks_usec()
				host._service_country_worker_transport()
				host._sched_day_country_peer_ms += host._sched_elapsed_ms(segment_usec)
				host._arm_climate_capacity_pending(day_idx)
				host._sched_day_total_ms = host._sched_elapsed_ms(day_started_usec)
				return
		if host._generator.has_method("publish_environment_through"):
			# 与 sus_tick_daily 的输入日约定一致（day - 1），落下的天按顺序补齐。
			segment_usec = Time.get_ticks_usec()
			var capture_result: Dictionary = host._generator.publish_environment_through(
				maxi(0, day_idx - 1), host._world_clock.season_phase_for_day(day_idx),
				MapGenerator.ENV_CALLSITE_HOST_DAY_CHANGED)
			if not bool(capture_result.get("ok", true)) and host._day_capture_blocked_logs < 8:
				host._day_capture_blocked_logs += 1
				print("[day-capture] failed day=%d code=%s reason=%s" % [
					int(capture_result.get("day", day_idx - 1)), String(capture_result.get("code", "?")),
					String(capture_result.get("fallback_reason",
						capture_result.get("reason", "")))])
			host._sched_day_capture_ms += host._sched_elapsed_ms(segment_usec)
		segment_usec = Time.get_ticks_usec()
		host._service_country_worker_transport()
		host._sched_day_country_peer_ms += host._sched_elapsed_ms(segment_usec)
		# Country read-view + vision stay on _process (budgeted). Putting them on
		# day_changed inflated day_cost_ema and collapsed 50x throughput while the
		# worker sat in input_wait. Peer pump above is enough for the day barrier.
		host._sched_day_country_read_ms = 0.0
		segment_usec = Time.get_ticks_usec()
		host._try_promote_economy_pod_active()
		host._sched_day_promote_ms += host._sched_elapsed_ms(segment_usec)
		host._sched_day_total_ms = host._sched_elapsed_ms(day_started_usec)
		return
	# Climate 在 worker 手上时，先把它上一天的结果落进 MapData，再跑这一天的 tick。
	#
	# run_daily_tick 里有两个读写 MapData 的环节：season refresh 重算 moisture /
	# snow_cover / soil_moisture / PAW 这批与日频写者重叠的场，capture 则把 MapData
	# 打包成 worker 下一天的输入。回灌只挂在 _process 上时，它与本 tick 的先后取决于
	# 节点树的 _process 顺序 —— 也就是「谁最后写 MapData」决定了 worker 下一天读到
	# 什么，而这两条路径谁先谁后并没有任何东西保证。在这里显式回灌一次，把顺序钉成
	#   回灌(第 N 天) → capture(第 N+1 天的输入) → season refresh
	# 三者落在同一个调用栈里串行。
	#
	# 试过反过来排（tick 之后再回灌，让 capture 夹在 season refresh 与回灌之间），
	# 动机是让季节性重算能进入 worker。零改善：四条平坦的场逐项不变。所以季节信号
	# 进不来的原因不是这个执行序，改回确定性更强的这一版。
	#
	# _process 那次回灌保留：它服务于视觉的每帧刷新。apply 侧有 generation 与
	# committed-day 双重门，同一天重复调用不会二次应用。
	if bool(report.get("climate_worker_authoritative", false)):
		host._consume_modifier_worker_snapshot_if_authoritative()
		host._consume_effect_worker_snapshot_if_authoritative()
		host._service_effect_worker_intents_if_authoritative()
		# H8: Trigger before Ideology mirrors the worker stage order, and doing it
		# here (not only after the tick) lets this day's graph pulse hand off the
		# effects the worker just emitted instead of trailing them by a day.
		host._consume_trigger_worker_snapshot_if_authoritative()
		host._service_trigger_worker_intents_if_authoritative()
		host._consume_ideology_worker_snapshot_if_authoritative()
		host._service_ideology_worker_intents_if_authoritative()
	host._apply_climate_writeback_if_authoritative(report)
	if bool(report.get("climate_worker_authoritative", false)):
		# B8 P3：等输入 ring 有空位再 capture（after_generation=0）。
		# 允许最多 SLOT_COUNT-1 天流水线，大地图不再被“等上一份完全消费”串成单槽。
		# serial_wait soak 仍可显式传具体 generation。
		segment_usec = Time.get_ticks_usec()
		var capacity_result = host.wait_for_climate_consumed(0)
		host._sched_day_climate_wait_ms += host._sched_elapsed_ms(segment_usec)
		if not bool(capacity_result.get("ok", false)):
			segment_usec = Time.get_ticks_usec()
			host._service_country_worker_transport()
			host._sched_day_country_peer_ms += host._sched_elapsed_ms(segment_usec)
			host._arm_climate_capacity_pending(day_idx)
			host._sched_day_total_ms = host._sched_elapsed_ms(day_started_usec)
			return
	segment_usec = Time.get_ticks_usec()
	# 单日单推进声明：今天由本 host 的 GDScript SUS tick 推进。若 main.gd 也挂在
	# 同一场景（当前不会），它的 sus_tick_daily 会看到这条声明并让位。
	host._claim_day_for_native(day_idx, &"host_sus")
	host._prepare_military_exploration_day(day_idx)
	host.run_daily_tick(day_idx, host._world_clock.season_phase_for_day(day_idx))
	host._sched_day_total_ms = host._sched_elapsed_ms(day_started_usec)


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
	# [android-inline 2026-11-01] 移动端默认内联（与 web 同一执行者）。安卓上
	# worker 线程路径会停在 day 1：worker state=PAUSED / attempt_slices=0 /
	# environment ring=0，而主线程又在等它提交（真机与模拟器均可复现）。
	# 内联日由主线程直接跑 12 域，不依赖 worker 线程与 env 环，web 上已验证多年。
	# 想恢复实验性 worker：PK_MOBILE_NATIVE_WORKER=1。
	if (OS.has_feature("mobile") or OS.has_feature("android") or OS.has_feature("ios")) \
			and OS.get_environment("PK_MOBILE_NATIVE_WORKER") != "1":
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


func _web_gdscript_daily_fallback_allowed(host) -> bool:
	return host.runtime_web_allow_gdscript_daily_fallback \
		or OS.get_environment("PK_WEB_ALLOW_GDSCRIPT_DAILY_FALLBACK") == "1"


## Return true only when this Web session must stop instead of using the legacy tick.

func _reject_web_daily_fallback(host, code: String, reason: String) -> bool:
	if not host._is_web_build() or host._web_gdscript_daily_fallback_allowed():
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
		"请更新网页和原生模块，并启用原生执行器及气候权威。诊断用旧脚本回退需显式打开逃生开关。")
	return true


func _effective_environment_prefetch_days(host) -> int:
	if not host._web_worker_requested():
		return clampi(host.runtime_environment_prefetch_days, 0, 3)
	return maxi(clampi(host.runtime_environment_prefetch_days, 0, 3), host.WEB_WORKER_PREFETCH_DAYS)


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
		"sched_day_promote_ms": host._sched_day_promote_ms,
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
	if host._generator == null:
		return
	var cp = host._generator._c() if host._generator.has_method("_c") else null
	var auto_weather_stride = true
	if cp != null and cp.get("weather_refresh_auto_stride_by_speed") != null:
		auto_weather_stride = bool(cp.weather_refresh_auto_stride_by_speed)
	if not auto_weather_stride:
		return
	var stride = 1
	if new_speed >= 15.0:
		stride = 8
	elif new_speed >= 3.0:
		stride = 4
	host._generator.set_weather_refresh_stride(stride)


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
