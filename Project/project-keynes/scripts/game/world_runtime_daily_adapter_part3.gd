extends RefCounted

## Extracted world_runtime_daily_adapter.gd group 3; state stays with host.

func _consume_runtime_commit_if_ready(host, report_override: Dictionary = {}) -> void:
	var commit_usec = Time.get_ticks_usec()
	if not host._runtime_ready_for_ticks or host._generator == null:
		return
	if not host._generator.has_method("get_runtime_thread_report") \
			or not host._generator.has_method("poll_runtime_commit"):
		return
	var dcp = host._dcp_on()
	var dcp_usec: int = commit_usec if dcp else 0
	var report: Dictionary = report_override
	if report.is_empty():
		report = host._runtime_control_state()
	host._observe_runtime_worker_fault(report)
	if String(report.get("simulation_thread_mode", report.get(
			"requested_simulation_thread_mode", "OFF"))) != "ACTIVE":
		return
	if not bool(report.get("simulation_worker_ready", report.get(
			"authority_ready", false))):
		return
	if report_override.is_empty():
		host._apply_climate_writeback_if_authoritative(report)
	var commit: Dictionary = host._generator.poll_runtime_commit(host._runtime_commit_generation)
	var received_new_commit = bool(commit.get("ok", false)) \
			and bool(commit.get("available", false)) \
			and int(commit.get("generation", 0)) > host._runtime_commit_generation
	var economy_worker_authoritative = (
			int(report.get("authoritative_domain_mask", 0)) &
			host.RUNTIME_ECONOMY_DOMAIN_MASK) != 0
	if received_new_commit:
		var publish_started_usec = Time.get_ticks_usec()
		var generation = int(commit.get("generation", 0))
		host._runtime_commit_generation = generation
		host._runtime_commit_day = int(commit.get("committed_day", host._runtime_commit_day))
		host._runtime_last_commit = commit.duplicate(false)
		if economy_worker_authoritative:
			host._queue_runtime_natural_resource_commit(host._runtime_commit_day)
		# Military reads the Country/Economy view committed for this day. It is
		# a synchronous main-thread runtime (never a worker domain), so the host
		# is the only thing that can advance it while the graph is ACTIVE.
		host._queue_runtime_military_commit(host._runtime_commit_day)
		host._runtime_commit_family_cursors.clear()
		host._runtime_commit_family_done.clear()
		host._runtime_pending_visual_generation = generation
		host._runtime_pending_dirty_families = int(commit.get("dirty_families", 0))
		# Whole-graph ACTIVE bypasses run_daily_tick, including its visual and
		# recorder tail. Publish those consumers from the committed boundary.
		var whole_graph = bool(report.get("authority_ready", false))
		if whole_graph:
			host._fast_tick_count += 1
			host._pending_tick_start_usec = publish_started_usec
			host._pending_tick_sus_ms = 0.0
			host._pending_tick_skipped_day = false
			host._generator.publish_worker_climate_visuals()
			if host._renderer != null:
				host._renderer.set_season_phase(host._world_clock.season_phase_for_day(host._runtime_commit_day))
				host._renderer.set_climate_anomaly(host._world_clock.climate_anomaly)
				if host._renderer.has_method("refresh_terrain_weather_field_tex"):
					host._renderer.refresh_terrain_weather_field_tex()
			host._pending_tick_render_ms = (Time.get_ticks_usec() - publish_started_usec) / 1000.0
			host.mark_map_overlay_dirty(&"worker_committed")
			if dcp:
				host._dcp_publish_ms = float(Time.get_ticks_usec() - publish_started_usec) / 1000.0
		# 只通知一次最新完整日提交；后续帧仅继续消费尚未应用的视觉 patch。
		host.simulation_committed.emit(
			int(commit.get("from_day", host._runtime_commit_day)),
			host._runtime_commit_day,
			host._runtime_commit_generation)
		if whole_graph:
			host._sched_proc_commit_ms += host._sched_elapsed_ms(commit_usec)
			var dcp_finish_usec: int = Time.get_ticks_usec() if dcp else 0
			host.finish_daily_tick(0.0)
			if dcp_finish_usec > 0:
				host._dcp_finish_ms = float(Time.get_ticks_usec() - dcp_finish_usec) / 1000.0
			commit_usec = Time.get_ticks_usec()
		else:
			host._sched_proc_commit_ms += host._sched_elapsed_ms(commit_usec)
		host._try_promote_economy_pod_active()
	else:
		host._sched_proc_commit_ms += host._sched_elapsed_ms(commit_usec)
		commit_usec = Time.get_ticks_usec()
	# Economy ACTIVE mutates resource deltas on the worker-owned runtime. Drain
	# them only after a committed boundary is visible, then run the same natural
	# resource pass that SUS would have run on the synchronous path. If the worker
	# still owns the boundary lock, keep the day queued and retry next frame.
	var resource_usec = Time.get_ticks_usec()
	if economy_worker_authoritative and host._runtime_natural_resource_pending_target_day >= 0 \
			and host._generator.has_method("flush_runtime_economy_resource_writeback"):
		var resource_writeback: Dictionary = \
			host._generator.flush_runtime_economy_resource_writeback()
		if bool(resource_writeback.get("ok", false)) \
				and not bool(resource_writeback.get("pending", false)):
			host._drain_runtime_natural_resource_commits()
	host._sched_proc_resource_ms += host._sched_elapsed_ms(resource_usec)
	if dcp:
		host._dcp_resource_ms = float(Time.get_ticks_usec() - resource_usec) / 1000.0
	# Military catch-up. It consumes only the committed Country/Economy view, so
	# it is safe to run as soon as a commit is visible — no writeback or
	# boundary lock is involved. Same-frame budget as the resource drain.
	var military_usec = Time.get_ticks_usec()
	host._drain_runtime_military_commits()
	host._runtime_military_ms = float(Time.get_ticks_usec() - military_usec) / 1000.0
	if dcp:
		host._dcp_military_ms = host._runtime_military_ms
	if host._runtime_pending_visual_generation <= 0 \
			or host._runtime_pending_visual_generation != host._runtime_commit_generation:
		return
	# 当前 skeleton 的 COMMIT 阶段可能没有 visual intents；仍走同一消费边界，
	# 以后新增 family 时无需把 worker 对象暴露给主线程。交互期间缩小预算，
	# 但不等待或取消 worker，只把剩余 patch 留到下一渲染帧。
	var apply_started_us = Time.get_ticks_usec()
	var interactive = bool(report.get("interactive", false))
	var budget_us = 250 if interactive else 750
	var max_items = 128 if interactive else 512
	for family_index in range(9):
		if Time.get_ticks_usec() - apply_started_us >= budget_us:
			break
		var family_bit = 1 << family_index
		if (host._runtime_pending_dirty_families & family_bit) == 0 \
				or bool(host._runtime_commit_family_done.get(family_bit, false)):
			continue
		var cursor = int(host._runtime_commit_family_cursors.get(family_bit, 0))
		var patch: Dictionary = host._generator.consume_runtime_visual_patch(
			host._runtime_pending_visual_generation, family_bit, cursor, max_items)
		if not bool(patch.get("available", false)):
			if String(patch.get("code", "")) == "runtime_generation_expired":
				# A newer commit will be picked up on the next frame. Do not spin
				# forever trying to consume a generation already evicted by the ring.
				host._runtime_commit_family_done[family_bit] = true
			continue
		if int(patch.get("generation", host._runtime_pending_visual_generation)) \
				!= host._runtime_pending_visual_generation:
			host._runtime_commit_family_done[family_bit] = true
			continue
		host._runtime_commit_family_cursors[family_bit] = int(patch.get("next_cursor", cursor))
		host._runtime_commit_family_done[family_bit] = bool(patch.get("done", false))
		host._apply_runtime_visual_patch(family_bit, patch)
	host._runtime_last_visual_apply_ms = float(Time.get_ticks_usec() - apply_started_us) / 1000.0
	host._sched_proc_visual_ms += host._runtime_last_visual_apply_ms
	if dcp:
		host._dcp_visual_ms = host._runtime_last_visual_apply_ms
	if host._generator.has_method("record_runtime_visual_timings"):
		host._generator.record_runtime_visual_timings(
			host._runtime_last_ui_feedback_ms,
			host._runtime_last_visual_apply_ms,
			host._runtime_last_gpu_upload_ms)
	var all_done = true
	for family_index in range(9):
		var family_bit = 1 << family_index
		if (host._runtime_pending_dirty_families & family_bit) != 0 \
				and not bool(host._runtime_commit_family_done.get(family_bit, false)):
			all_done = false
			break
	if all_done:
		host._runtime_pending_visual_generation = 0



func _queue_runtime_natural_resource_commit(host, day: int) -> void:
	if day <= host._runtime_natural_resource_last_commit_day:
		return
	host._runtime_natural_resource_pending_target_day = maxi(
			host._runtime_natural_resource_pending_target_day, day)



func _drain_runtime_natural_resource_commits(host) -> void:
	if host._generator == null or not host._generator.has_method(
			"run_natural_resource_pass_for_runtime_commit"):
		return
	var target_day = host._runtime_natural_resource_pending_target_day
	if target_day < 0:
		return
	var processed = 0
	while host._runtime_natural_resource_last_commit_day < target_day \
			and processed < host.RUNTIME_NATURAL_RESOURCE_CATCHUP_DAYS_PER_FRAME:
		var day = host._runtime_natural_resource_last_commit_day + 1
		var result: Dictionary = host._generator.run_natural_resource_pass_for_runtime_commit(day)
		host._runtime_natural_resource_last_result = result.duplicate(true)
		if not bool(result.get("done", false)):
			return
		host._runtime_natural_resource_last_commit_day = day
		processed += 1
	if host._runtime_natural_resource_last_commit_day >= target_day:
		host._runtime_natural_resource_pending_target_day = -1



func _queue_runtime_military_commit(host, day: int) -> void:
	if day < 0:
		return
	host._runtime_military_pending_target_day = maxi(
			host._runtime_military_pending_target_day, day)


## Military is a main-thread synchronous runtime that reads the committed
## Country/Economy view of day D and emits D+1 intents. In whole-graph ACTIVE the
## worker never runs it (it is not a worker domain), so the host replays every
## observed committed day here, bounded per frame. When the API is missing (older
## DLL) or the facade is unconfigured this is a single null check.


func _drain_runtime_military_commits(host) -> void:
	if host._runtime_military_pending_target_day < 0 or host._generator == null:
		return
	if not host._generator.has_method("get_military_facade"):
		host._runtime_military_pending_target_day = -1
		return
	var facade = host._generator.get_military_facade()
	if facade == null or not facade.is_configured():
		# No military authority in this world (old DLL / catalog missing). Drop
		# the queue so every frame does not re-probe the facade.
		host._runtime_military_pending_target_day = -1
		return
	var target_day = host._runtime_military_pending_target_day
	var processed = 0
	var first_day = host._runtime_military_last_commit_day + 1
	if host._runtime_military_last_commit_day < 0:
		# First observation: start at the oldest day we must cover, not at 0.
		first_day = mini(target_day, maxi(0, target_day - host.RUNTIME_MILITARY_CATCHUP_DAYS_PER_FRAME))
	var day = first_day
	while day <= target_day and processed < host.RUNTIME_MILITARY_CATCHUP_DAYS_PER_FRAME:
		# Every replay day gets its own frozen explored view. Calling this once
		# for the whole batch would make days 2..N plan against day 1.
		if host.has_method("_prepare_military_exploration_day"):
			host._prepare_military_exploration_day(day)
		var result: Dictionary
		if facade.should_run(day):
			result = facade.run_daily(day)
		else:
			# Peace with no movement: the native side owns the skip decision and
			# reports zero work, but the committed-day cursor still advances so a
			# later war does not replay a hundred idle days.
			result = {"ok": true, "path": "native_military_skip", "day_index": day}
		host._runtime_military_last_commit_day = day
		host._runtime_military_last_result = result.duplicate(false)
		# Forward the day's facts on the same boundary as every other bus batch.
		var job = host._generator.get_military_daily_job() \
			if host._generator.has_method("get_military_daily_job") else null
		if job != null and job.has_method("forward_military_events"):
			job.forward_military_events()
		processed += 1
		day += 1
	if host._runtime_military_last_commit_day >= target_day:
		host._runtime_military_pending_target_day = -1


## Season refresh changes cover (snowline / flood / glacier), which feeds the
## military terrain cost tables. Push the new layer once per refreshed season.


func _refresh_military_terrain_after_season(host) -> void:
	if host._generator == null or not host._generator.has_method("refresh_military_terrain"):
		return
	var result: Dictionary = host._generator.refresh_military_terrain(
		int(host._world_clock.day_index()) if host._world_clock != null else -1)
	if not bool(result.get("ok", false)) and not bool(result.get("skipped", false)):
		var reason = String(result.get("reason", ""))
		if not reason.is_empty() and reason != "military_not_configured":
			print("[military] terrain refresh rejected: %s" % reason)


## Whole-graph ACTIVE bypasses `MapGenerator.finish_season_refresh`'s daily path,
## so the season edge is detected here. The facade's cover signature makes this
## a no-op on every day whose cover did not actually change.


func _refresh_military_terrain_on_season_edge(host, day_idx: int) -> void:
	if host._military_terrain_season_index < 0:
		host._military_terrain_season_index = host._world_clock.season_index_for_day(day_idx)
		return
	var season = host._world_clock.season_index_for_day(day_idx)
	if season == host._military_terrain_season_index:
		return
	host._military_terrain_season_index = season
	host._refresh_military_terrain_after_season()



func military_report(host) -> Dictionary:
	if host._generator == null or not host._generator.has_method("get_military_report"):
		return {"configured": false}
	var report: Dictionary = host._generator.get_military_report()
	report["host_last_commit_day"] = host._runtime_military_last_commit_day
	report["host_pending_target_day"] = host._runtime_military_pending_target_day
	report["host_last_ms"] = host._runtime_military_ms
	return report


## Climate 权威在 worker 时，把它提交的那一天刷进 MapData。
##
## 这是 ACTIVE Climate 的主线程另一半：抑制门已经让主线程不再算 climate，
## 如果这里不回灌，MapData 就永久停在转权威那一天。
##
## 语义上滞后一日：worker 提交第 N 天之后，主线程在下一个渲染帧才把它应用到
## MapData，所以同一帧里读 MapData 的消费者看到的是第 N-1 天。这与视觉 patch
## 消费的滞后一致，也是 worker 不阻塞主线程的代价。需要同帧一致的读者必须走
## simulation_committed 信号，而不是直接轮询 MapData。


func _apply_climate_writeback_if_authoritative(host, report: Dictionary) -> void:
	if not bool(report.get("climate_worker_authoritative", false)):
		return
	# 只接受严格递增的 worker 提交日。capacity barrier 期间，host 可能在
	# 多个渲染帧重试同一个 pending day；重复调用 writeback 会让视觉消费者
	# 在旧快照与新快照之间来回切换，尤其在 50x 下表现为海冰闪烁。
	var committed_day = int(report.get("simulation_committed_day", -1))
	if committed_day >= 0 and committed_day <= host._runtime_climate_writeback_last_day:
		return
	# 回灌绑在 DCWorldExt 上，MapGenerator 没有转发它：这条路径每帧走一次，
	# 多一层 GDScript 转发只是白开销。
	var ext = host._generator.get_data_core_world_ext() \
		if host._generator.has_method("get_data_core_world_ext") else null
	if ext == null:
		return
	var applied: Dictionary = ext.apply_runtime_climate_writeback(
		host._runtime_climate_writeback_generation)
	if not bool(applied.get("ok", false)):
		# 形状不符 / 权威已撤销都会走到这里。抑制门这时也已经放开（授予位是同一个
		# 来源），所以主线程会自己重新算 climate，不需要在这里补算。
		push_warning("[climate-authority] writeback rejected: %s" % String(
			applied.get("code", "unknown")))
		return
	if not bool(applied.get("applied", false)):
		return
	preload("res://scripts/game/world_runtime_climate_restore.gd").apply(host._generator, applied)
	host._runtime_climate_writeback_generation = int(applied.get(
		"generation", host._runtime_climate_writeback_generation))
	# Older compatible runtimes may omit committed_day from the apply result;
	# the worker report driving this consume is the same committed generation.
	host._runtime_climate_writeback_last_day = int(applied.get(
		"committed_day", report.get("simulation_committed_day", -1)))
	host._runtime_climate_writeback_days += 1
	# A field the slot guards reject is a field the worker owns but never
	# publishes, so MapData silently keeps the pre-promotion value. Kept for
	# diagnostics rather than warned about per day: the set is constant for a
	# given world, so the probe reads it once instead of spamming the log.
	host._runtime_climate_writeback_applied_fields = int(applied.get("applied_fields", 0))
	host._runtime_climate_writeback_skipped = applied.get("skipped_fields", [])
	host._runtime_climate_writeback_memcpy_ms = float(applied.get("memcpy_ms", 0.0))
	host._runtime_climate_writeback_flush_ms = float(applied.get("flush_map_ms", 0.0))
	host._runtime_climate_writeback_drops = int(applied.get(
		"drops", host._runtime_climate_writeback_drops))


## B8 P3：等到 worker 评估过 `after_environment_generation` 这份环境。
##
## 为什么不是单次 C++ 无限等待：等待期间必须继续服务 Country/Economy 的 peer
## 请求，否则 worker 卡在 peer barrier、主线程卡在等待，两边互锁。C++ 侧因此
## 只提供有界切片（条件变量，非忙等），本层在每个切片之间 pump 一次，然后继续
## 等 —— 行为上仍然是"无限等"，但不会把 peer 服务饿死。
##
## 终止条件只有三类：worker 故障/停止、Climate 权威被撤销、等待接口缺失。
## 它们不是性能超时：出现时按当时的 authority 状态回主线程或结束本 tick。


func wait_for_climate_consumed(host, after_environment_generation: int) -> Dictionary:
	if after_environment_generation < 0:
		return {"ok": true, "code": "climate_wait_no_environment_yet",
			"waited_ms": 0.0}
	var ext = host._generator.get_data_core_world_ext() \
		if host._generator != null and host._generator.has_method("get_data_core_world_ext") \
		else null
	if ext == null:
		# 旧 DLL / 未接线：不阻塞，也不假装等过。调用方（day 边界）继续走原路径。
		return {"ok": false, "code": "climate_wait_api_missing", "waited_ms": 0.0}
	if after_environment_generation == 0:
		# Native zero means ring capacity, not "no environment". Never spin
		# here: the main thread must remain available to service domain peers.
		return ext.wait_climate_consumed(0, 0)
	var total_waited_ms = 0.0
	while true:
		# 先服务 peer，再进入下一次等待：Country 的 barrier 可能正是 worker
		# 还没消费这份环境的原因。
		# Peer pump only: country read-view is owned by _process so a full
		# snapshot / vision refresh cannot inflate climate-wait or day_cost_ema.
		host._service_country_worker_transport()
		var slice: Dictionary = ext.wait_climate_consumed(
			after_environment_generation, host.RUNTIME_CLIMATE_WAIT_SLICE_MS)
		total_waited_ms += float(slice.get("waited_ms", 0.0))
		if bool(slice.get("ok", false)):
			slice["waited_ms"] = total_waited_ms
			slice["code"] = "ok"
			return slice
		var code = String(slice.get("code", ""))
		if code == "climate_wait_timeout_slice":
			continue
		# 终止条件。作者/Debug 读者需要知道是"谁没在跑"，所以带上 worker state
		# 与已消费代次，而不是只报 false。
		push_warning("[climate-authority] wait terminated: %s (state=%s consumed=%s target=%s)" % [
			code, str(slice.get("worker_state", -1)),
			str(slice.get("consumed_generation", -1)),
			str(after_environment_generation)])
		slice["waited_ms"] = total_waited_ms
		return slice
	return {"ok": false, "code": "climate_wait_unreachable", "waited_ms": total_waited_ms}


## Promote Economy to POD_ACTIVE once the committed mirror is ready. Must run on
## the main thread while the worker is idle between days (M6 boundary rules).
## Never call this while the worker may hold the day boundary lock without a
## non-blocking C++ try_lock — a blocking switch deadlocks peer/environment waits.
