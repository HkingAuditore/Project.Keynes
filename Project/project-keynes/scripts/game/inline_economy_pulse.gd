extends RefCounted

## Coordinates inline economy continuations and their fault reporting.


static func _continue_economy_inflight(context, day_index: int) -> void:
	if context._generator._continuation_reentry_guard:
		print("[continuation] re-entry blocked (recursion guard) day=%d" % day_index)
		return
	context._generator._continuation_reentry_guard = true
	context._generator._continue_economy_inflight_impl(day_index)
	context._generator._continuation_reentry_guard = false

static func _continue_economy_inflight_impl(context, day_index: int) -> void:
	# Defense in depth: climate capacity is not an economy/country continuation
	# target. WorldClock should already skip this pulse, but older callers or
	# mixed barriers can still land here — never burn the frame on graph capture.
	if context._generator._world_clock_ref != null and context._generator._world_clock_ref.has_method("needs_continuation_pulse") \
			and not context._generator._world_clock_ref.needs_continuation_pulse():
		return
	if context._generator._sus == null:
		return
	if context._generator._runtime_graph_active and context._generator._data_core_world_ext != null \
			and not context._generator.native_daily_round_active() and not context._generator.bio_occupancy_round_active():
		context._generator._advance_runtime_graph_pulse(day_index)
		return
	var speed: float = float(context._generator._world_clock_ref.speed_multiplier) if context._generator._world_clock_ref != null else 1.0
	var season: float = float(context._generator._world_clock_ref.season_phase()) if context._generator._world_clock_ref != null else 0.0
	var ctx: SusTickContext = SusTickContext.make(
		day_index, day_index, season, speed, &"country_economy_continuation")
	var budget_ms = context._generator.ECONOMY_CONTINUATION_FALLBACK_BUDGET_MS
	if context._generator._world_clock_ref != null:
		var configured_budget = context._generator._world_clock_ref.get("sim_frame_budget_ms")
		if configured_budget != null:
			budget_ms = maxf(0.25, float(configured_budget))
	# Allocate the diagnostic accumulator before starting the measured pulse so
	# dictionary/JSON setup cannot consume the continuation's simulation budget.
	context._generator._ensure_continuation_perf_pending()
	var started_us := Time.get_ticks_usec()
	var continuation_count := 0
	var frame_max_slice_ms := 0.0
	var native_launch_deadline_ms = budget_ms - minf(
		context._generator.NATIVE_DAILY_CONTINUATION_SLICE_HEADROOM_MS, budget_ms * 0.5)
	# Native climate and Bio occupancy are same-day transactions. Native slices
	# are synchronous cooperative stages, including deferred JIT-patch waits, so
	# drain consecutive slices inside this pulse while the shared frame budget
	# allows it. Release barriers only after the final publish, and never let a
	# diagnostic/economy drain run ahead of a still-open climate transaction.
	if context._generator.native_daily_round_active():
		var native_round_was_active := true
		var native_last_result: Dictionary = {}
		# A pending first slice is not yet represented by the job's own
		# _native_round_active flag.  Once this pulse starts run_slice(), the job
		# becomes the authoritative owner of the barrier state.
		context._generator._native_daily_day_pending = false
		while context._generator.native_daily_round_active() \
				and continuation_count < context._generator.ECONOMY_CONTINUATION_MAX_SLICES_PER_FRAME:
			var native_started_us := Time.get_ticks_usec()
			var native_result: Dictionary = context._generator._sus.continue_system(&"native_daily_sim", ctx)
			native_last_result = native_result
			var native_slice_ms: float = float(Time.get_ticks_usec() - native_started_us) / 1000.0
			frame_max_slice_ms = maxf(frame_max_slice_ms,
				context._generator._record_continuation_slice("native_daily", native_result, native_slice_ms))
			continuation_count += 1
			if bool(native_result.get("fatal", false)) \
					or float(Time.get_ticks_usec() - started_us) / 1000.0 \
						>= native_launch_deadline_ms:
				break
		# sus_tick_daily() advances this generation when a round completes in
		# the ordinary scheduler visit. A round finalized by continuation owns
		# the same immutable Climate commit boundary and must advance it once as
		# well, otherwise captured SHADOW frames remain reference-pending
		# forever despite the day barrier having been released.
		if native_round_was_active and not context._generator.native_daily_round_active() \
				and bool(native_last_result.get("done", false)) \
				and not bool(native_last_result.get("fatal", false)):
			context._generator._native_daily_climate_round_generation += 1
		if context._generator._world_clock_ref != null:
			context._generator._world_clock_ref.request_simulation_backpressure(
				&"native_daily_day_barrier", context._generator.native_daily_round_active())
		if context._generator.native_daily_round_active() \
				or float(Time.get_ticks_usec() - started_us) / 1000.0 >= native_launch_deadline_ms:
			context._generator._finish_continuation_perf_frame(started_us, continuation_count, frame_max_slice_ms, budget_ms)
			return
	if context._generator.bio_occupancy_round_active():
		context._generator._bio_occupancy_day_pending = false
		var bio_started_us := Time.get_ticks_usec()
		var bio_result: Dictionary = context._generator._sus.continue_system(&"bio_occupancy_daily", ctx)
		var bio_slice_ms: float = float(Time.get_ticks_usec() - bio_started_us) / 1000.0
		frame_max_slice_ms = maxf(frame_max_slice_ms,
			context._generator._record_continuation_slice("bio_occupancy", bio_result, bio_slice_ms))
		continuation_count += 1
		if context._generator._world_clock_ref != null:
			context._generator._world_clock_ref.request_simulation_backpressure(
				&"bio_occupancy_day_barrier", context._generator.bio_occupancy_round_active())
		if context._generator.bio_occupancy_round_active() or float(Time.get_ticks_usec() - started_us) / 1000.0 >= budget_ms:
			context._generator._finish_continuation_perf_frame(started_us, continuation_count, frame_max_slice_ms, budget_ms)
			return
	while continuation_count < context._generator.ECONOMY_CONTINUATION_MAX_SLICES_PER_FRAME:
		if context._generator._country_daily_job != null and context._generator._country_facade != null and \
				bool(context._generator._country_facade.world_ext().country_should_run(day_index)):
			var country_slice_started_us := Time.get_ticks_usec()
			var country_result: Dictionary = context._generator._sus.continue_system(&"country_daily", ctx)
			var country_slice_ms: float = float(Time.get_ticks_usec() - country_slice_started_us) / 1000.0
			frame_max_slice_ms = maxf(frame_max_slice_ms,
				context._generator._record_continuation_slice("country", country_result, country_slice_ms))
			continuation_count += 1
			if float(Time.get_ticks_usec() - started_us) / 1000.0 >= budget_ms:
				context._generator._finish_continuation_perf_frame(started_us, continuation_count, frame_max_slice_ms, budget_ms)
				return
			# Keep a pure Country continuation contiguous.  If no hard ACK is
			# pending, the next Country slice cannot observe a newer dependency;
			# this avoids needless Country/Economy alternation and preserves the
			# deterministic command order expected by the day barrier.
			if bool(context._generator._country_facade.world_ext().country_should_run(day_index)) \
					and not context._generator._hard_effect_ack_chain_due(day_index):
				continue
			# Do not skip the ACK drain while country_should_run stays true.
			# Research completions register Effect instances that keep
			# country_should_run true via pending commands until Effect/Modifier/
			# gameplay ACK. Skipping ACK here livelocks leftover Stone-Age nodes.
		# Country may register a technology Effect after the morning Effect slot.
		# Drain Trigger/Ideology opportunistically, then the hard Effect→Modifier
		# →gameplay ACK chain. Trigger/Ideology should_run can stay true for
		# tomorrow's queued work; that must not starve an in-flight economy epoch
		# or pin WorldClock on country_day_barrier.
		continuation_count += context._generator._drain_native_effect_ack_chain(ctx)
		if float(Time.get_ticks_usec() - started_us) / 1000.0 >= budget_ms:
			context._generator._finish_continuation_perf_frame(started_us, continuation_count,
				frame_max_slice_ms, budget_ms)
			return
		context._generator._ack_native_effect_domain_bindings()
		if float(Time.get_ticks_usec() - started_us) / 1000.0 >= budget_ms:
			context._generator._finish_continuation_perf_frame(started_us, continuation_count,
				frame_max_slice_ms, budget_ms)
			return
		var ack_passes := 1
		while ack_passes < context._generator.EFFECT_ACK_CHAIN_MAX_PASSES and \
				context._generator._hard_effect_ack_chain_due(day_index):
			continuation_count += context._generator._drain_native_effect_ack_chain(ctx)
			context._generator._ack_native_effect_domain_bindings()
			ack_passes += 1
			if float(Time.get_ticks_usec() - started_us) / 1000.0 >= budget_ms:
				break
		var hard_ack_due = context._generator._hard_effect_ack_chain_due(day_index)
		if context._generator._world_clock_ref != null:
			var economy_inflight = context._generator._economy_daily_job != null and context._generator._economy_facade != null \
				and bool(context._generator._economy_facade.world_ext().economy_should_run(day_index))
			# Keep the country barrier only while an in-flight economy epoch still
			# needs catchup. Otherwise release it so the next render frame can
			# advance a day and Country's UNIQUE_SOURCE fallback can fire.
			context._generator._world_clock_ref.request_simulation_backpressure(
				&"country_day_barrier", hard_ack_due and economy_inflight)
			if hard_ack_due:
				context._generator._log_stuck_day_barrier(day_index, economy_inflight)
		if context._generator._economy_daily_job == null or context._generator._economy_facade == null:
			if context._generator._world_clock_ref != null:
				context._generator._world_clock_ref.request_simulation_backpressure(&"economy_day_barrier", false)
			context._generator._finish_continuation_perf_frame(started_us, continuation_count, frame_max_slice_ms, budget_ms)
			return
		var economy_ext: Object = context._generator._economy_facade.world_ext()
		if not bool(economy_ext.economy_should_run(day_index)):
			# This is a cold/stale-barrier path. Query the full report only here so
			# fatal state remains distinguishable from a completed continuation.
			var report: Dictionary = context._generator._economy_facade.report()
			if bool(report.get("fatal", false)):
				# FATAL is terminal for the economy graph, so no future economy slice
				# can clear the hard barrier. Release it defensively or WorldClock
				# remains permanently stuck on the last day.
				if context._generator._world_clock_ref != null:
					context._generator._world_clock_ref.request_simulation_backpressure(
						&"economy", false)
					context._generator._world_clock_ref.request_simulation_backpressure(
						&"economy_day_barrier", false)
				context._generator._finish_continuation_perf_frame(started_us, continuation_count, frame_max_slice_ms, budget_ms)
				return
			if context._generator._world_clock_ref != null:
				context._generator._world_clock_ref.request_simulation_backpressure(&"economy_day_barrier", false)
			context._generator._finish_continuation_perf_frame(started_us, continuation_count, frame_max_slice_ms, budget_ms)
			return
		var economy_slice_started_us := Time.get_ticks_usec()
		var economy_result: Dictionary = context._generator._sus.continue_system(&"economy_daily", ctx)
		var economy_slice_ms: float = float(Time.get_ticks_usec() - economy_slice_started_us) / 1000.0
		frame_max_slice_ms = maxf(frame_max_slice_ms,
			context._generator._record_continuation_slice("economy", economy_result, economy_slice_ms))
		continuation_count += 1
		if bool(economy_result.get("fatal", false)):
			# A continuation may surface the terminal result directly. Keep this
			# backstop beside the cold-report path so no fatal route can strand the
			# WorldClock behind an economy barrier.
			if context._generator._world_clock_ref != null:
				context._generator._world_clock_ref.request_simulation_backpressure(
					&"economy", false)
				context._generator._world_clock_ref.request_simulation_backpressure(
					&"economy_day_barrier", false)
			context._generator._finish_continuation_perf_frame(started_us, continuation_count, frame_max_slice_ms, budget_ms)
			return
		if bool(economy_result.get("done", false)) or \
				not bool(economy_ext.economy_should_run(day_index)):
			if context._generator._world_clock_ref != null:
				context._generator._world_clock_ref.request_simulation_backpressure(&"economy_day_barrier", false)
			context._generator._finish_continuation_perf_frame(started_us, continuation_count, frame_max_slice_ms, budget_ms)
			return
		if float(Time.get_ticks_usec() - started_us) / 1000.0 >= budget_ms:
			context._generator._finish_continuation_perf_frame(started_us, continuation_count, frame_max_slice_ms, budget_ms)
			return
	context._generator._finish_continuation_perf_frame(started_us, continuation_count, frame_max_slice_ms, budget_ms)

static func _advance_runtime_graph_pulse(context, day_index: int) -> Dictionary:
	if context._generator._data_core_world_ext == null:
		return {}
	var speed_graph := float(context._generator._world_clock_ref.speed_multiplier) if context._generator._world_clock_ref != null else 1.0
	var season_graph := float(context._generator._world_clock_ref.season_phase()) if context._generator._world_clock_ref != null else 0.0
	var budget_graph = context._generator.ECONOMY_CONTINUATION_FALLBACK_BUDGET_MS
	if context._generator._world_clock_ref != null and context._generator._world_clock_ref.get("sim_frame_budget_ms") != null:
		budget_graph = maxf(0.25, float(context._generator._world_clock_ref.sim_frame_budget_ms))
	var token := int(context._generator._data_core_world_ext.advance_runtime_pulse(
		day_index, season_graph, speed_graph, int(budget_graph * 1000.0), 0))
	var token_status := int((token >> 56) & 0xff)
	var token_dirty := int((token >> 32) & 0xffff)
	var barrier_armed = context._generator._track_runtime_graph_stall(day_index, token_status)
	if context._generator._world_clock_ref != null:
		context._generator._world_clock_ref.request_simulation_backpressure(
			&"economy_day_barrier", barrier_armed)
		context._generator._world_clock_ref.request_simulation_backpressure(
			&"country_day_barrier", barrier_armed)
		# The first slice can run through IdeologyRuntimeSystem (which arms its
		# own barrier), while continuation goes straight to the native graph.
		# Reconcile that same barrier here after native completion as well.
		# `ideology_needs_daily_continuation` was added to the native bridge after
		# older Windows DLLs had already been distributed. Probe the binding before
		# calling it so an out-of-date extension cannot abort a save boundary. The
		# graph's hard-pending status is the conservative compatibility fallback: it
		# keeps the ideology barrier armed until the extension is rebuilt.
		var ideology_pending = barrier_armed
		ideology_pending = bool(context._generator._data_core_world_ext.ideology_needs_daily_continuation(day_index))
		context._generator._world_clock_ref.request_simulation_backpressure(
			&"ideology_day_barrier", ideology_pending)
	if token_dirty != 0:
		context._generator._data_core_world_ext.flush_runtime_visuals(token_dirty)
	# Country slice 已在 pulse 内写入 native + MapData.country_slot_arr，但
	# CountryDailySystem.dispatch_committed_events 被 graph 短路跳过；这里按
	# generation watermark 补发，驱动 WorldRuntimeHost.refresh_country_visuals。
	context._generator._dispatch_runtime_graph_country_committed()
	if context._generator._data_core_world_ext is DCWorldExt:
		var economy_result: Dictionary = context._generator._data_core_world_ext.get_runtime_graph_last_economy_report()
		if bool(economy_result.get("fatal", false)):
			context._generator._halt_on_economy_fatal(day_index, economy_result)
		if int(economy_result.get("day_index", economy_result.get("sample_day", -1))) == day_index:
			if context._generator._economy_facade != null and bool(economy_result.get(
					"economy_event_batch_published", false)):
				context._generator._economy_facade.dispatch_committed_events(economy_result)
			if context._generator._economy_facade != null:
				context._generator._economy_facade.dispatch_construction_command_receipts()
	return {"token": token, "status": token_status,
		"dirty_mask": token_dirty}

## 经济 runtime 进入 fatal 后 economy_should_run() 恒为 false，原生 graph 的 pending
## 判定随之落回 idle，日历会继续推进——气候/国家/人口照跑，经济却已经死了，玩家看到的
## 是一份持续腐烂的存档。legacy 续跑路径在 fatal 时会举起 economy_day_barrier 把时钟
## 钉住；graph 路径这里补上等价语义，并且直接暂停 + push_error，让停机可见而不是伪装
## 成又一次卡顿。

static func _halt_on_economy_fatal(context, day_index: int, economy_result: Dictionary) -> void:
	if context._generator._runtime_graph_economy_fatal_halted:
		return
	context._generator._runtime_graph_economy_fatal_halted = true
	var reason := String(economy_result.get("fatal_reason", "unknown"))
	# 全量 report 有 450+ 键，只在 fatal 这一次值得付这个跨语言搬运；守恒/审计字段
	# 只在这里齐全，compact slice 报告不带。
	var detail: Dictionary = economy_result
	if context._generator._economy_facade != null and context._generator._economy_facade.has_method("report"):
		detail = context._generator._economy_facade.report()
	print("[sim/economy-fatal] day=%d reason=%s stage=%s sample_day=%s last_completed_sample_day=%s audit_mode=%s audit_ledger=%s audit_lane=%s audit_mismatches=%s population_error=%s money_error=%s goods_error=%s"
		% [day_index, reason, str(detail.get("stage", "?")),
			str(detail.get("sample_day", -1)),
			str(detail.get("last_completed_sample_day", -1)),
			str(detail.get("closing_audit_mode", "?")),
			str(detail.get("closing_audit_mismatch_ledger", "?")),
			str(detail.get("closing_audit_mismatch_lane", -1)),
			str(detail.get("closing_audit_mismatches", -1)),
			str(detail.get("population_error", -1)),
			str(detail.get("money_error", -1)),
			str(detail.get("goods_error", -1))])
	# graph 路径原先只打短行；money_conservation_failed 需要和 economy_daily 同等的分桶，
	# 否则 GM 截断/日志丢失后无法定位是 open 虚高、mint 漏记还是 burn 漏记。
	if reason == "money_conservation_failed" or reason == "population_conservation_failed" \
			or reason == "goods_conservation_failed":
		var conservation := {
			"money_open": detail.get("money_open", "missing"),
			"money_close": detail.get("money_close", "missing"),
			"money_expected": detail.get("money_expected", "missing"),
			"explicit_money_mint": detail.get("explicit_money_mint", "missing"),
			"explicit_money_burn": detail.get("explicit_money_burn", "missing"),
			"opening_cohort_funds": detail.get("opening_cohort_funds", "missing"),
			"closing_cohort_funds": detail.get("closing_cohort_funds", "missing"),
			"opening_country_cash": detail.get("opening_country_cash", "missing"),
			"closing_country_cash": detail.get("closing_country_cash", "missing"),
			"opening_escrow_cash": detail.get("opening_escrow_cash", "missing"),
			"closing_escrow_cash": detail.get("closing_escrow_cash", "missing"),
			"opening_expedition_funds": detail.get("opening_expedition_funds", "missing"),
			"closing_expedition_funds": detail.get("closing_expedition_funds", "missing"),
			"producer_support_money_issued": detail.get(
				"producer_support_money_issued", "missing"),
			"bullion_money_issued": detail.get("bullion_money_issued", "missing"),
			"opening_audit_fast_paths": detail.get(
				"opening_audit_fast_paths", "missing"),
			"opening_audit_full_verifications": detail.get(
				"opening_audit_full_verifications", "missing"),
			"closing_audit_mode": detail.get("closing_audit_mode", "missing"),
		}
		print("[sim/economy-fatal-conservation] %s" % JSON.stringify(conservation))
	push_error("[economy] 原生经济 runtime 已 fatal（%s），仿真已在第 %d 天暂停以避免继续产出错误结果。"
		% [reason, day_index])
	if context._generator._world_clock_ref != null and context._generator._world_clock_ref.has_method("pause"):
		context._generator._world_clock_ref.pause(true)
	context._generator.economy_runtime_fatal.emit(day_index, reason, detail)

static func _dispatch_runtime_graph_country_committed(context) -> void:
	if context._generator._country_facade == null or not context._generator._country_facade.is_configured():
		return
	var report: Dictionary = context._generator._country_facade.report()
	var generation := int(report.get("generation", -1))
	if generation < 0:
		return
	if generation == context._generator._runtime_graph_last_country_generation:
		return
	context._generator._runtime_graph_last_country_generation = generation
	var territory_generation := int(report.get("territory_generation", -1))
	# 广播前先把 native 领土刷进 MapData：country_committed 监听方会立刻
	# refresh_country_visuals；若此时 country_slot_arr 仍是 CoW 旧镜像，
	# 视野源集会缺新 CLAIM 格，邻格只被迷雾柔边照亮却保持未探索。
	if territory_generation != context._generator._runtime_graph_last_country_territory_generation \
			and context._generator._data_core_world_ext != null :
		var sync_started_us := Time.get_ticks_usec()
		context._generator._data_core_world_ext.sync_country_territory_to_map()
		context._generator._runtime_graph_country_territory_sync_ms = \
			float(Time.get_ticks_usec() - sync_started_us) / 1000.0
	else:
		context._generator._runtime_graph_country_territory_sync_ms = 0.0
	context._generator._runtime_graph_last_country_territory_generation = territory_generation
	# 不能用最后一份 report 的 changed_* 在这里提前门控。同一个
	# pulse 里的后续 country slice 可能把领土提交摘要覆盖掉；
	# CountryFacade 会根据未消费的原生事件流归一化 changed_cells。
	var dispatch_started_us := Time.get_ticks_usec()
	context._generator._country_facade.dispatch_committed_events(report)
	context._generator._runtime_graph_country_event_dispatch_ms = \
		float(Time.get_ticks_usec() - dispatch_started_us) / 1000.0

## 返回本次 pulse 之后 country/economy 硬 barrier 是否还应该举着。
## status=3 表示"还有硬域 pending"，正常情况下会在同一天的几次 pulse 内落回 1/2。
## 同一天连续 pending 到 RUNTIME_GRAPH_STALL_RELEASE_PULSES 时判定为自锁并放行日历：
## 放行只是让 WorldClock 继续推进，pending 的域在后续日仍会被 pulse 继续 drain。

static func _track_runtime_graph_stall(context, day_index: int, token_status: int) -> bool:
	if token_status != 3:
		context._generator._runtime_graph_stall_day = -1
		context._generator._runtime_graph_stall_pulses = 0
		context._generator._runtime_graph_stall_released = false
		return false
	if day_index != context._generator._runtime_graph_stall_day:
		context._generator._runtime_graph_stall_day = day_index
		context._generator._runtime_graph_stall_pulses = 0
	context._generator._runtime_graph_stall_pulses += 1
	var latching = not context._generator._runtime_graph_stall_released \
		and context._generator._runtime_graph_stall_pulses >= context._generator.RUNTIME_GRAPH_STALL_RELEASE_PULSES
	if latching:
		context._generator._runtime_graph_stall_released = true
	if latching or (context._generator._runtime_graph_stall_pulses >= context._generator.RUNTIME_GRAPH_STALL_DIAG_PULSES \
			and (context._generator._runtime_graph_stall_pulses - context._generator.RUNTIME_GRAPH_STALL_DIAG_PULSES) \
				% context._generator.RUNTIME_GRAPH_STALL_DIAG_STRIDE == 0):
		context._generator._log_stalled_runtime_graph(day_index)
	return not context._generator._runtime_graph_stall_released

static func _log_stalled_runtime_graph(context, day: int) -> void:
	var snapshot: Dictionary = {}
	if context._generator._data_core_world_ext != null :
		snapshot = context._generator._data_core_world_ext.get_runtime_perf_snapshot(1)
	var pinned := PackedStringArray()
	for key in ["country_pending", "trigger_pending", "ideology_pending",
			"effect_pending", "modifier_pending", "gameplay_effect_pending",
			"economy_pending"]:
		if bool(snapshot.get(key, false)):
			pinned.append(String(key).trim_suffix("_pending"))
	print("[sim/graph-barrier] day=%d pulses=%d released=%s pinned=%s work=%s economy_slices=%s economy_commits=%s yields=%s last_us=%s trigger_blocked=%s/%s"
		% [day, context._generator._runtime_graph_stall_pulses, str(context._generator._runtime_graph_stall_released),
			",".join(pinned), str(snapshot.get("work_done", -1)),
			str(snapshot.get("economy_slices", -1)),
			str(snapshot.get("economy_commits", -1)),
			str(snapshot.get("budget_yields", -1)),
			str(snapshot.get("last_elapsed_us", -1)),
			str(snapshot.get("trigger_blocked_pulses", -1)),
			str(snapshot.get("trigger_blocked_reason", ""))])
	# 放行日历意味着某个硬域自锁了，仿真接下来是在"经济/效果落后于日历"的降级状态下
	# 继续跑。这不能只留在 stdout 里——它和经济 fatal 一样会污染后续账目。
	if context._generator._runtime_graph_stall_released:
		push_warning("[sim] 原生 runtime graph 在第 %d 天自锁 %d 个 pulse（pinned=%s），已放行日历；该域的工作已落后于日历，结果不可信。"
			% [day, context._generator._runtime_graph_stall_pulses, ",".join(pinned)])
	# Effect 是这个 barrier 历史上最常见的钉子（一个永远到不了 ACKED/REJECTED/
	# RESYNC_REQUIRED 的 transaction 会让 effect_should_run 恒真）。命中时多打一行
	# 事务状态直方图，直接区分是"卡住的事务"还是"到期的 due heap 实例"。
	if bool(snapshot.get("effect_pending", false)) and context._generator._effect_facade != null:
		var effect_report: Dictionary = context._generator._effect_facade.report()
		print("[sim/graph-barrier/effect] current_day=%s last_completed_day=%s planned=%s preflighted=%s committed=%s acked=%s rejected=%s resync=%s transactions=%s instances=%s country_ack_pending=%s economy_ack_pending=%s modifier_ack_pending=%s gameplay_ack_pending=%s country_acks=%s economy_acks=%s modifier_acks=%s"
			% [str(effect_report.get("current_day", -1)),
				str(effect_report.get("last_completed_day", -1)),
				str(effect_report.get("planned_transactions", -1)),
				str(effect_report.get("preflighted_transactions", -1)),
				str(effect_report.get("committed_transactions", -1)),
				str(effect_report.get("acked_transactions", -1)),
				str(effect_report.get("rejected_transactions", -1)),
				str(effect_report.get("resync_required_transactions", -1)),
				str(effect_report.get("transactions", -1)),
				str(effect_report.get("instances", -1)),
				str(effect_report.get("native_country_ack_pending", -1)),
				str(effect_report.get("native_economy_ack_pending", -1)),
				str(effect_report.get("native_modifier_ack_pending", -1)),
				str(effect_report.get("native_gameplay_ack_pending", -1)),
				str(effect_report.get("native_country_acks", -1)),
				str(effect_report.get("native_economy_acks", -1)),
				str(effect_report.get("native_modifier_acks", -1))])
	context._generator._log_stalled_runtime_graph_authority(day)

## worker 的 RUNTIME_DAY_STALL_* 位（runtime_pod_protocol.h）。日历被钉住时这一位
## 直接点名「这一天在等什么」，比在 pinned 列表里猜快得多。0 = 当天自由，不是「没诊断」。

static func _day_stall_reason_name(context, mask: int) -> String:
	if mask == 0:
		return "none"
	var parts := PackedStringArray()
	const NAMES := [
		"climate_capacity", "country_peer", "effect_ack", "ideology_ack",
		"fiscal_peer", "economy_input",
	]
	for bit in NAMES.size():
		if (mask & (1 << bit)) != 0:
			parts.append(String(NAMES[bit]))
	if parts.is_empty():
		return "0x%x" % mask
	return "|".join(parts)

## 12 个原生阶段的位名（runtime_pod_protocol.h 的 RuntimeDomainId，位序 = id-1）。
## 日历被 worker 钉住时，这张 mask 直接点名「哪个域的阶段今天还没跑完」。

static func _domain_mask_names(context, mask: int) -> String:
	if mask == 0:
		return "none"
	const NAMES := [
		"input_capture", "climate", "country", "trigger", "ideology", "effect",
		"modifier", "gameplay_effect", "economy", "events", "visual", "commit",
	]
	var parts := PackedStringArray()
	for bit in NAMES.size():
		if (mask & (1 << bit)) != 0:
			parts.append(String(NAMES[bit]))
	return "|".join(parts) if not parts.is_empty() else "0x%x" % mask

## [sim/graph-barrier] 只说「哪个域 pinned」，对经济自锁的两种成因是同形的：
## economy_slices 每 pulse +64、economy_commits 恒 0、last_us 只有几百微秒（每次
## slice 都是空转）。两种成因都长这样：
##   1) 主线程 slice 被 `run_economy_slice_internal` 开头的 economy_worker_execution_owned
##      短路——worker 已经 requested ECONOMY、但 authoritative_domain_mask 里还没有那一位，
##      而 worker 自己也没在推进这一天；
##   2) worker 自己的 host 日提交不上，主线程又因为 (1) 不许接手。
## 分辨靠三样东西：requested/granted 的差、worker 停在哪个 economy stage/yield reason，
## 以及 `day_wait` 那行的日计划缺口——stall 位只描述外部等待，缺口不设位时它恒为 none，
## 那正是「日历推不动却一个错都不报」的形态。

static func _log_stalled_runtime_graph_authority(context, day: int) -> void:
	var host: Dictionary = context._generator.get_runtime_thread_report()
	if not host.is_empty():
		# ECONOMY 的 runtime_domain_mask 是 0x100。这里只打「请求了 / 授了没有」，
		# 不打整张 mask —— 十二域一起看反而读不出结论。
		var econ_mask := 1 << 8
		var requested := (int(host.get("requested_authority_mask", 0)) & econ_mask) != 0
		var granted := (int(host.get("authoritative_domain_mask", 0)) & econ_mask) != 0
		print("[sim/graph-barrier/host] day=%d state=%s econ_requested=%s econ_granted=%s inflight=%s stall=%s@%s sim_committed_day=%s sim_env_day=%s econ_input_day=%s econ_stage=%s/%s econ_yield=%s attempt_slices=%s wait_input_us=%s wait_boundary_us=%s"
			% [day,
				str(host.get("simulation_host_state", host.get("state", "?"))),
				str(requested), str(granted),
				str(host.get("worker_day_inflight", -1)),
				context._generator._day_stall_reason_name(int(host.get("day_stall_reason_mask", 0))),
				str(host.get("day_stall_day", -1)),
				str(host.get("simulation_committed_day", -1)),
				str(host.get("simulation_environment_day", -1)),
				str(host.get("economy_input_requested_day", -1)),
				str(host.get("economy_stage_name", "")),
				str(host.get("economy_substage_name", "")),
				str(host.get("economy_yield_reason", "")),
				str(host.get("economy_attempt_slices", -1)),
				str(host.get("worker_time_input_wait_us", -1)),
				str(host.get("worker_time_boundary_wait_us", -1))])
		# worker 的日计划缺口：`missing` 是 requested & ~completed 的域位，
		# stall 位为 none 时它是唯一能说明「今天卡在哪个阶段」的东西。
		# park 那一栏是「那一行为什么放弃」，有些分支只 stage.completed=0 就
		# continue，不设 stall 位也不写 fallback reason，只能靠它归因。
		print("[sim/graph-barrier/day] day=%d waiting_day=%s missing=%s env_day=%s ring=%s stall=%s park=%s:%s"
			% [day,
				str(host.get("day_wait_day", -1)),
				context._generator._domain_mask_names(int(host.get("day_wait_missing_mask", 0))),
				str(host.get("day_wait_env_day", -1)),
				str(host.get("day_wait_ring", -1)),
				context._generator._day_stall_reason_name(int(host.get("day_stall_reason_mask", 0))),
				context._generator._domain_mask_names(int(host.get("day_park_domain_mask", 0))),
				str(host.get("day_park_reason", ""))])
		# 每个域的 POD 阶段各自的 ready / fallback reason。「阶段没跑完」的最后
		# 一层归因：park 只说放弃的位置，这里说该域自己的状态机是什么结局。
		print("[sim/graph-barrier/pods] effect ready=%s gen=%s reason=%s inst_rejected=%s reject_detail=%s | modifier ready=%s reason=%s | ideology ready=%s reason=%s | events ready=%s failed_day=%s reason=%s | country_blocker=%s"
			% [str(host.get("effect_pod_ready", "?")),
				str(host.get("effect_pod_snapshot_generation", "?")),
				str(host.get("effect_pod_fallback_reason", "")),
				str(host.get("effect_instance_rejected_count", 0)),
				str(host.get("effect_instance_reject_detail", "")),
				str(host.get("modifier_pod_ready", "?")),
				str(host.get("modifier_pod_fallback_reason", "")),
				str(host.get("ideology_pod_ready", "?")),
				str(host.get("ideology_pod_fallback_reason", "")),
				str(host.get("events_pod_ready", "?")),
				str(host.get("events_failed_day", "?")),
				str(host.get("events_pod_fallback_reason", "")),
				str(host.get("country_pod_blocker", ""))])
	if context._generator._economy_facade != null and context._generator._economy_facade.has_method("report"):
		var economy: Dictionary = context._generator._economy_facade.report()
		print("[sim/graph-barrier/econ] day=%d fatal=%s stage=%s exec=%s substage=%s epoch_active=%s current_day=%s last_committed_day=%s env_day=%s trade_plan=%s sample_day=%s last_completed_sample_day=%s"
			% [day,
				str(economy.get("fatal", "?")),
				str(economy.get("stage", "?")),
				str(economy.get("executed_stage", "?")),
				str(economy.get("substage", "?")),
				str(economy.get("epoch_active", "?")),
				str(economy.get("current_day", "?")),
				str(economy.get("last_committed_day", "?")),
				str(economy.get("environment_day", "?")),
				str(economy.get("trade_plan_phase", "?")),
				str(economy.get("sample_day", "?")),
				str(economy.get("last_completed_sample_day", "?"))])
