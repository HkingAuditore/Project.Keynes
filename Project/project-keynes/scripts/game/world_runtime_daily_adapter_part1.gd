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
	# ---- Military layers
	if host.military_map_layers != null and host.military_map_layers.has_method("poll_snapshot"):
		host.military_map_layers.poll_snapshot()
	# ---- Military layers


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
	var cursor = host._environment_publish_next_day()
	# 自愈：出现任何形式的越界游标都拉回 worker 的下一步，绝不发未来帧。
	if cursor < base or cursor > base + prefetch_days:
		cursor = base
		host._set_environment_publish_next_day(cursor)
	var limit = base + lead_cap - 1
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
		var captured: Dictionary = host._generator.capture_runtime_inputs_for_worker(
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
		host._set_environment_publish_next_day(cursor)
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



## 预发布游标。语义是"下一次想发的日"，不是"已发的最大日"。
## 用 host 的已提交日做下界，所以 worker 追上或回滚时自动重新对齐。



func _environment_publish_next_day(host) -> int:
	if host._environment_publish_next_day_cursor < 0:
		# 首帧：从主线程日历开始，worker 的已提交日会在调用点做下界。
		return host._world_clock.day_index() if host._world_clock != null else 0
	return host._environment_publish_next_day_cursor



func _set_environment_publish_next_day(host, day: int) -> void:
	host._environment_publish_next_day_cursor = maxi(0, day)


## 存盘前必须先把预发布降下来并让环排空：`build_save_bundle` 的 worker 侧准入
## 条件是 `!has_pending_climate_input()`，环长期非空会让存盘永远等不到。
## 这里把 K 降到 0 并清掉发布游标；环里的帧由 worker 自己按 `pop_while_day_at_most`
## 消费，不再有新帧进来。恢复时调用 `_resume_environment_prefetch_after_save()`。


func _suspend_environment_prefetch_for_save(host, reason: String) -> void:
	if host._max_worker_lead_days <= 0:
		return
	host._environment_prefetch_suspended_for_save = true
	host._max_worker_lead_days = 0
	host._environment_prefetch_days_active = 0
	host._release_prefetch_barrier_to_clock()
	host._environment_publish_next_day_cursor = -1
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
	host._environment_publish_next_day_cursor = -1
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
		if ext != null and ext.has_method("capture_economy_day_inputs"):
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


