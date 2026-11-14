extends WorldRuntimeHost

## Frozen S13-before executor decisions.

func _start_production_shadow_worker() -> void:
	# 决策留痕：这一行是 web 上"worker 为什么起不来"的第一现场。
	# 之前它不打印，只能靠 diag 反推，代价是一整轮排查。
	print("[runtime-worker] decide web=%s web_worker=%s inline_requested=%s meta=%s env=%s runtime_native_daily_inline=%s fallback=%s shadow_on_generate=%s" % [
		str(_is_web_build()),
		str(_web_worker_requested()),
		str(_native_daily_inline_requested()),
		str(Engine.get_meta("pk_web_worker", false)),
		str(OS.get_environment("PK_WEB_WORKER")),
		str(runtime_native_daily_inline),
		str(_web_worker_inline_fallback),
		str(runtime_shadow_on_generate)])
	if not runtime_shadow_on_generate:
		print("[runtime-worker] skipped: runtime_shadow_on_generate=false")
		return
	if _generator == null or not _generator.has_method("start_runtime_worker"):
		print("[runtime-worker] skipped: generator or start_runtime_worker unavailable")
		return
	# ── web 的两种执行者先算清楚，再决定要不要进下面这段 ──────────────
	#
	# 关键：**「内联」也是由本函数启动的**（config["native_daily_inline"]=true 时
	# host 不 spawn 线程，日屏障由调用线程执行）。所以这里**不能**写成
	# `if web and not worker: return` —— 那会把内联也一起关掉，web 默认路径
	# 就只剩 GDScript SUS 日 tick（`day_cost.inl=0 / s2>0`，日历推不动）。
	# 早退只有一个合法理由：web 上两种执行者都不要。
	var web_wants_worker := _web_worker_requested()
	var web_wants_inline := _native_daily_inline_requested()
	if _is_web_build() and not web_wants_worker and not web_wants_inline:
		print("[runtime-worker] web build: neither worker nor inline requested; " +
			"GDScript daily tick drives the calendar")
		return
	# B8-4：先解析策略，再决定 worker 以什么模式启动。requested 是会话请求，
	# effective 才是本机/本地图真实生效的模式；诊断里两者都保留。
	var authority_policy: Dictionary = _resolve_climate_authority_policy()
	var climate_authority_active := bool(authority_policy.get("enabled", false))
	# web 上没有 ACTIVE 就没有 worker/inline 可言（内联日本身要求 ACTIVE，
	# host 会用 `inline_daily_requires_active` 拒绝）。这时保持既有的
	# GDScript SUS 日 tick，**不要** spawn 一个 SHADOW 线程陪跑。
	if _is_web_build() and not climate_authority_active:
		_web_worker_start_code = "authority_policy_disabled:%s" % String(
			authority_policy.get("reason", "unknown"))
		print("[runtime-worker] web build: climate authority disabled (%s); " +
			"worker not started, GDScript daily tick drives the calendar" \
			% String(authority_policy.get("reason", "unknown")))
		return
	# Web 不再强制降级：那次"worker 图 commit 不了 day"的实际原因是首帧 shader 编译
	# 45s 把整帧堵住（见 docs/web-export.md §9）。shader 裁剪后 ACTIVE 正常工作。
	# 只有 ACTIVE 才推进日历；SHADOW 会停在 day 1。
	var ext = _generator.get_data_core_world_ext() \
		if _generator.has_method("get_data_core_world_ext") else null
	# Web worker 依赖主线程预发布器的两个只读探测 API。旧 side module
	# （例如使用 `skip-native` 导出，或浏览器缓存了旧包）可能仍能加载并报告
	# `requested=ACTIVE`，但没有这两个方法；继续走 worker 会让它停在 PAUSED
	# 等环境帧，而发布权又无法安全交给预发布器，最终把第 1 天钉死。
	# 在启动边界直接切到同一 host 的 inline 日屏障，避免进入这个半启动状态。
	if _is_web_build() and web_wants_worker and not _environment_prefetch_capable():
		print("[runtime-worker] web side module lacks environment prefetch API; " +
			"forcing native_daily_inline (rebuild Web native module to re-enable worker)")
		_web_worker_inline_fallback = true
		web_wants_worker = false
		web_wants_inline = true
	if ext != null and runtime_parity_forcing \
			and ext.has_method("set_runtime_climate_parity_forcing"):
		ext.set_runtime_climate_parity_forcing(true)
	_runtime_climate_writeback_generation = 0
	_runtime_climate_writeback_days = 0
	_runtime_climate_writeback_last_day = -1
	# A new worker lifetime restarts Ideology snapshot generations at 1.
	_ideology_worker_snapshot_generation = 0
	var config: Dictionary = {
		"simulation_thread_mode": "SHADOW",
		"graph_coverage_complete": false,
		# A worker lifetime resumes on the calendar the host is already on. This used
		# to be a hardcoded 0, which is only right for a FRESH world: a policy flip
		# stops the worker and calls straight back in here (`_restart_worker_with_
		# current_policy`), so the restarted worker was told to replay from day 0 while
		# every domain pod and every domain store was still at the day it stopped on.
		# The first replayed day then either soft-skips forever (`plan.day <=
		# committed`) or faults the Climate kernel (`climate_day_not_monotonic`), and
		# because the authority grant is deferred until a day commits, the reported
		# mask stayed 0x000 for the rest of the session.
		"day": _world_clock.day_index() if _world_clock != null else 0,
		"speed_days_per_second": 1.0,
		"paused": true,
		"events_probe_enabled": runtime_events_probe_enabled,
		"economy_execution_mode": runtime_economy_execution_mode,
	}
	# Phase-2.4.5: StageOps is the production writer unless parity probe mode
	# (ACTIVE_WITH_PARITY cannot share mutate StageOps with compact).
	# Phase-2.6.1: auto-promote POD_ACTIVE after complete committed mirror.
	if String(runtime_economy_execution_mode) != "ACTIVE_WITH_PARITY":
		config["economy_stage_ops_mutate"] = true
		config["economy_production_writer"] = "stage_ops"
		# Host requests auto POD_ACTIVE. The worker records the flag only;
		# WorldRuntimeHost performs the actual switch on an idle boundary.
		config["economy_auto_pod_active"] = runtime_economy_auto_pod_active
	if climate_authority_active:
		# graph_coverage_complete 在 per-domain ACTIVE 下的含义是"请求的这些域
		# 线程安全"，不是整图。
		# Player/default play requests the full graph (0xFFF) so Trigger/Effect/
		# Economy are worker-owned. Focused Climate|Country|COMMIT (0x806) remains
		# available by setting runtime_authority_domain_mask for soaks/debug.
		# Phase 2-6：Economy 与 Climate|Country|Modifier|Effect|Ideology|Trigger|Events
		# 同开关进入生产 ACTIVE；不得用 handoff / set_country_sync_store_writes_forbidden 冒充本路径。
		# Events 的授予只表示 worker 侧镜像 + 阶段位；legacy GameplayEventBus journal
		# 仍是生产消费源，消费者迁移是后续 PR。
		if not bool(_country_worker_transport_capture.get("ok", false)) \
				and _generator != null \
				and _generator.has_method("capture_country_worker_inputs"):
			_country_worker_transport_capture = \
				_generator.capture_country_worker_inputs()
		if not bool(_country_worker_transport_capture.get("ok", false)):
			push_error(
				"[runtime-worker] Climate|Country|Trigger|Modifier|Effect|Ideology|Events|Economy ACTIVE refused: Country capture incomplete (%s)" % [
					String(_country_worker_transport_capture.get("code", "missing"))])
			return
		# G8: best-effort Economy opinion publish before ACTIVE so Ideology
		# stage is not cold-started with a null opinion snapshot.
		if ext != null and ext.has_method("publish_ideology_worker_inputs"):
			var opinion_pub: Dictionary = ext.publish_ideology_worker_inputs()
			if not bool(opinion_pub.get("ok", false)):
				push_warning("[runtime-worker] Ideology opinion publish deferred: %s" % [
					String(opinion_pub.get("code", "unknown"))])
		config["simulation_thread_mode"] = "ACTIVE"
		config["graph_coverage_complete"] = true
		config["authoritative_domain_mask"] = runtime_authority_domain_mask
	# native_daily_inline：把"日屏障由谁执行"从 worker 线程换成调用线程。
	# 只有 ACTIVE 请求才谈得上内联日（SHADOW 的定义就是 worker 侧影子对拍）。
	# 显式写 false 而不是"不写"：同一个 key 若被遗留状态置真，host 会直接不
	# spawn 线程，而调用方还以为 worker 起了 —— 那是最难查的一种"起来了但没跑"。
	var want_inline := climate_authority_active and web_wants_inline
	config["native_daily_inline"] = want_inline
	var started: Dictionary = _generator.start_runtime_worker(config)
	if not bool(started.get("ok", false)):
		_web_worker_start_ok = false
		_web_worker_start_code = String(started.get("code", "unknown"))
		if climate_authority_active:
			# 权威启动失败不能静默退回 SHADOW：主线程的 climate/country 抑制门读的是
			# worker 侧的授予位，授予没发生就不会抑制，于是主线程仍在算。
			# 但调用方以为已经转权威了，所以这里必须响。
			push_error("[runtime-worker] Climate|Country|Trigger|Modifier|Effect|Ideology|Events authority start refused: %s (%s)" % [
				String(started.get("code", "unknown")),
				String(started.get("message", ""))])
		else:
			push_warning("[runtime-worker] SHADOW start deferred: %s" % String(
				started.get("code", "unknown")))
		# web 上 worker 没起来，而内联又被互斥关掉 ⇒ 没有任何执行者。必须当场
		# 退回内联，否则日历停在 day 1（用户看到的"世界不动"）。
		# 判据用 `runtime_native_daily_inline`（用户是否允许内联），不要求
		# "worker 被要过" —— 起不来就是起不来，与谁请求的无关。
		if _is_web_build() and runtime_native_daily_inline and not want_inline \
				and not _web_worker_inline_fallback:
			print("[runtime-worker] web start failed (%s) -> falling back to native_daily_inline" \
				% _web_worker_start_code)
			_web_worker_inline_fallback = true
			_start_production_shadow_worker()
		return
	_web_worker_start_ok = true
	# 回退路径下 start 成功说明"内联起来了"，不是"worker 起来了"，diag 必须分得清。
	_web_worker_start_code = "inline_fallback" if _web_worker_inline_fallback else "ok"
	_native_daily_inline_active = bool(started.get("native_daily_inline", false))
	# 二次校验：请求了 worker 却反馈 inline=true，说明配置没生效。宁可回退内联，
	# 也不要留一个"看起来起了、其实日屏障还在主线程"的状态。
	if not _native_daily_inline_active and bool(want_inline):
		_web_worker_start_ok = false
		_web_worker_start_code = "inline_flag_mismatch"
		push_error("[runtime-worker] native_daily_inline requested but host reported false")
	# P1/P3：worker 真的起来了才谈得上预发布与领先量限流。内联日不适用
	# （它的消费者就是本线程，预发布只会让环卡住）。
	_apply_web_worker_parallel_channels(climate_authority_active, started)
	if climate_authority_active:
		print("[runtime-worker] production ACTIVE started mask=",
			runtime_authority_domain_mask,
			" auto_pod=", runtime_economy_auto_pod_active,
			" inline=", _native_daily_inline_active,
			" web_worker=", _web_worker_requested(),
			" prefetch_days=", _environment_prefetch_days_active,
			" max_lead_days=", _max_worker_lead_days)
	_sync_runtime_worker_clock()


## P1/P3 的开关落地。只有"worker 线程真的在跑"时才打开：
##   P1 预发布 K 天 + 把环境帧发布权收归 `_process` 预发布器（单一发布者）
##   P3 允许 worker 领先主线程 K 天
## 关掉时 K=0、发布权归还全部调用点、领先上限 0 ⇒ 回到改动前逐表达式的行为。

func _run_native_daily_inline_day(day_idx: int, report: Dictionary) -> Dictionary:
	var ext = _generator.get_data_core_world_ext() \
		if _generator != null and _generator.has_method("get_data_core_world_ext") else null
	if ext == null or not ext.has_method("run_native_daily_inline_day"):
		if _native_daily_inline_active:
			push_error("[runtime-inline] run_native_daily_inline_day 缺失：回退到主线程 daily tick")
			_native_daily_inline_active = false
		return {"ok": false, "code": "native_daily_inline_api_missing"}
	var segment_usec := Time.get_ticks_usec()
	WebTelemetry.emit("inline_step", {"d": day_idx, "s": "enter"})
	# 单日单推进声明：今天由**内联执行器**推进。同一 day 上若已有别人声明过
	# （正常不会发生：生产场景里只有本 host 推进模拟），main.gd 那套 GDScript
	# SUS 日 tick 会自己让位。这里只是登记，不影响本函数的执行。
	_claim_day_for_native(day_idx, &"native_inline")
	_apply_climate_writeback_if_authoritative(report)
	_sched_day_climate_writeback_ms += _sched_elapsed_ms(segment_usec)
	WebTelemetry.emit("inline_step", {"d": day_idx, "s": "after_writeback"})
	segment_usec = Time.get_ticks_usec()
	_service_country_worker_transport()
	_sched_day_country_peer_ms += _sched_elapsed_ms(segment_usec)
	WebTelemetry.emit("inline_step", {"d": day_idx, "s": "after_transport"})
	# 输入日必须等于 host 的 committed_day+1。内联日没有跨线程重试，错日会直接
	# 停在 inline_daily_environment_day_mismatch，所以这里按 host 的提交水印取值。
	var host_day := int(report.get("simulation_committed_day",
		report.get("committed_day", -1)))
	var next_day := host_day + 1
	segment_usec = Time.get_ticks_usec()
	if _generator.has_method("publish_environment_through"):
		_generator.publish_environment_through(
			maxi(0, next_day), _world_clock.season_phase_for_day(day_idx),
			MapGenerator.ENV_CALLSITE_INLINE_DAY)
	_sched_day_capture_ms += _sched_elapsed_ms(segment_usec)
	WebTelemetry.emit("inline_step", {"d": day_idx, "s": "after_capture",
		"ms": int(_sched_elapsed_ms(segment_usec))})
	# 探针：native 调用本身的独立 epoch（桌面 _dcp_on() 为假时连计时都不做）。
	var _dcp_native_usec: int = Time.get_ticks_usec() if _dcp_on() else 0
	var result: Dictionary = ext.run_native_daily_inline_day()
	_runtime_native_daily_inline_last = result
	if _dcp_native_usec > 0:
		_dcp_inline_ms = float(Time.get_ticks_usec() - _dcp_native_usec) / 1000.0
	# 每个内联日的耗时/域覆盖：第一次 daily tick 在浏览器里特别贵（一次性初始化），
	# 用这个事件区分"首日一次性成本"和"每天稳态成本"。
	WebTelemetry.emit("inline_day", {
		"day": day_idx,
		"ms": int(_sched_elapsed_ms(segment_usec)),
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
		_runtime_native_daily_inline_days += 1
	else:
		_runtime_native_daily_inline_pending_days += 1
		# 静默冻结是最难查的失败形态：每 30 次至少留一行能指名原因的日志。
		if _runtime_native_daily_inline_pending_days % 30 == 1:
			print("[runtime-inline] day=%d pending reason=%s attempts=%d peer_pumped=%d host_day=%d" % [
				day_idx, String(result.get("reason", "?")),
				int(result.get("attempts", 0)), int(result.get("peer_pumped", 0)),
				host_day])
	# 提交已经发布；把同一份提交落到 MapData/slot，本帧的 UI/渲染就能读到今天。
	#
	# 探针：这里的 commit 消费是 inline_day 事件**看不到**的那一段——它排在
	# inline_day 打点之后，包含 LUT 重编码 / 天气场纹理刷新 / 自然资源回灌 /
	# 视觉 patch 应用。day_cost_ema 与 inline_day 的差额主要就落在这里。
	if _dcp_on():
		var dcp_commit_usec := Time.get_ticks_usec()
		# 复用同一调用栈里刚取的那份 report（内联日没有 worker 线程，两次读取
		# 必然同值），省掉一天里第二次 get_runtime_thread_report() 打包。
		_consume_runtime_commit_if_ready(report)
		_dcp_commit_ms = float(Time.get_ticks_usec() - dcp_commit_usec) / 1000.0
	else:
		_consume_runtime_commit_if_ready()
	return result

