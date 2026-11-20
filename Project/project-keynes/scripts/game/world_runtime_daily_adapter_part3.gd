extends RefCounted

## Extracted world_runtime_daily_adapter.gd group 3; state stays with host.
const RendererWeatherState = preload("res://scripts/rendering/renderer_weather_state.gd")
const EconomyDisplay = preload("res://scripts/economy/economy_facade_display.gd")

func _apply_season_display(map: MapData, applied: Dictionary) -> bool:
	if not applied.has("season_day") or map == null:
		return false
	map.published_biome_history = applied.biome_history
	map.published_vegetation_history = applied.vegetation_history
	map.published_season_history_next = int(applied.season_history_next)
	return true


func _apply_published_cell_display(map: MapData, indices) -> void:
	if map == null:
		return
	var water := MapData.is_water_lut()
	for i in indices:
		var cell := map.cell_at(i)
		if cell == null:
			continue
		var terrain: int = map.terrain_arr[i]
		if cell.terrain != terrain:
			cell.apply_terrain(terrain)
		map.is_water_arr[i] = water[terrain]
		cell.landform = map.landform_arr[i]
		cell.vegetation = map.vegetation_arr[i]
		cell.cover = map.cover_arr[i]
		if not cell.current_state.is_empty():
			cell.current_state["biome"] = cell.terrain
			cell.current_state["landform"] = cell.landform
			cell.current_state["vegetation"] = cell.vegetation
			cell.current_state["cover"] = cell.cover


func _consume_runtime_commit_if_ready(host, report_override: Dictionary = {}) -> void:
	var commit_usec = Time.get_ticks_usec()
	if (not host._runtime_ready_for_ticks or host._generator == null
			or host._runtime_worker_fault_paused):
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
	var commit: Dictionary = host._generator.poll_runtime_commit(host._runtime_commit_generation, true)
	var received_new_commit = bool(commit.get("ok", false)) \
			and bool(commit.get("available", false)) \
			and int(commit.get("generation", 0)) > host._runtime_commit_generation
	var commit_day := int(commit.get("committed_day", -1))
	if received_new_commit and commit_day > int(report.get("simulation_committed_day", -1)):
		report = host._runtime_control_state()
	if received_new_commit and bool(report.get("climate_worker_authoritative", false)):
		# A worker can commit between the status read and the commit poll.
		# Apply the weather for the polled day before exposing that day to scripts.
		if int(report.get("simulation_committed_day", -1)) != commit_day:
			report = report.duplicate(false)
			report["simulation_committed_day"] = commit_day
		_apply_climate_writeback_if_authoritative(host, report, commit)
		if not host._native_environment_active and host._runtime_climate_writeback_last_day < commit_day:
			return
	elif not host._native_environment_active and report_override.is_empty():
		host._apply_climate_writeback_if_authoritative(report)
	var whole_graph = bool(report.get("authority_ready", false))
	if received_new_commit:
		var publish_started_usec = Time.get_ticks_usec()
		var generation = int(commit.get("generation", 0))
		var old_day: int = host._runtime_commit_day
		host._runtime_commit_generation = generation
		host._runtime_commit_day = commit_day
		if commit_day <= old_day or int(commit.get("from_day", -1)) == commit_day:
			if host._native_environment_active:
				host._generator.get_data_core_world_ext().finish_runtime_display_frame()
			return
		host._runtime_last_commit = commit
		var records: Array = commit.get("days", [])
		host._runtime_last_commit["batch_from_day"] = int(records[0].day) - 1 if not records.is_empty() \
			else int(commit.get("from_day", commit_day - 1))
		# Whole-graph ACTIVE records the frame once after installing the last day.
		if whole_graph:
			host._fast_tick_count += commit_day - maxi(0, old_day)
			host._pending_tick_start_usec = publish_started_usec
			host._pending_tick_sus_ms = 0.0
			host._pending_tick_skipped_day = false
			host._pending_tick_render_ms = 0.0
			if dcp:
				host._dcp_publish_ms = float(Time.get_ticks_usec() - publish_started_usec) / 1000.0
	host._sched_proc_commit_ms += host._sched_elapsed_ms(commit_usec)
	if not received_new_commit:
		return
	var ext = host._generator.get_data_core_world_ext()
	var resource_usec := Time.get_ticks_usec()
	var writeback := EconomyDisplay.apply_published_resources(ext)
	if bool(writeback.get("applied", false)):
		host._sched_proc_resource_ms += host._sched_elapsed_ms(resource_usec)
		if dcp:
			host._dcp_resource_ms = float(Time.get_ticks_usec() - resource_usec) / 1000.0
	elif received_new_commit and not bool(writeback.get("ok", false)):
		push_warning("Resource display patch: " + String(writeback.get("code", "")))
	if received_new_commit and bool(commit.get("species_writeback", false)):
		var species := BioOccupancyDailySystem.apply_published_occupancy(ext)
		if not bool(species.get("ok", false)):
			push_warning("Species display snapshot: " + String(species.get("reason", "")))
	var vision: Dictionary = host.apply_runtime_vision_display()
	if not bool(vision.get("ok", false)):
		push_warning("Vision display snapshot: " + String(vision.get("reason", "")))
	if whole_graph:
		host._consume_country_worker_read_view_if_authoritative()
		if host._native_environment_active:
			host._consume_modifier_worker_snapshot_if_authoritative()
	var from_day := int(host._runtime_last_commit.batch_from_day)
	var days: Array = commit.get("days", [])
	if whole_graph:
		var finish_usec := Time.get_ticks_usec()
		host.finish_daily_tick(0.0)
		if dcp:
			host._dcp_finish_ms = float(Time.get_ticks_usec() - finish_usec) / 1000.0
	var visual_started_us = Time.get_ticks_usec()
	if bool(report.get("authority_ready", false)):
		var defer_cell_lut_upload := RendererWeatherState.can_defer_cell_lut_upload(
				host._renderer, host._generator._baker, host._world_data)
		host._generator.publish_worker_climate_visuals(defer_cell_lut_upload, commit)
		host._vision_dirty_indices = PackedInt32Array()
		if host._renderer != null:
			host._renderer.set_season_phase(host._world_clock.season_phase_for_day(host._runtime_commit_day))
			host._renderer.set_climate_anomaly(host._world_clock.climate_anomaly)
		host.mark_map_overlay_dirty(&"worker_committed")
	if host._world_clock != null:
		host._world_clock.publish_runtime_date(host._runtime_commit_day)
	if not days.is_empty():
		host.simulation_day_records.emit(days)
	host.simulation_committed.emit(from_day, host._runtime_commit_day, host._runtime_commit_generation)
	if host._native_environment_active:
		ext.finish_runtime_display_frame()
	host._presentation.queue_worker_commit(from_day,
			host._runtime_commit_day, host._runtime_commit_generation)
	host._runtime_last_visual_apply_ms = float(Time.get_ticks_usec() - visual_started_us) / 1000.0
	host._sched_proc_visual_ms += host._runtime_last_visual_apply_ms
	if dcp:
		host._dcp_visual_ms = host._runtime_last_visual_apply_ms
	if host._generator.has_method("record_runtime_visual_timings"):
		host._generator.record_runtime_visual_timings(
			host._runtime_last_ui_feedback_ms,
			host._runtime_last_visual_apply_ms,
			host._runtime_last_gpu_upload_ms)


## Season refresh changes cover (snowline / flood / glacier), which feeds the
## military terrain cost tables. Push the new layer once per refreshed season.


func _refresh_military_terrain_after_season(host) -> void:
	if host.uses_worker_day_commits() or host._native_daily_inline_active:
		return
	if host._generator == null or not host._generator.has_method("refresh_military_terrain"):
		return
	var result: Dictionary = host._generator.refresh_military_terrain(
		int(host._world_clock.day_index()) if host._world_clock != null else -1)
	if not bool(result.get("ok", false)) and not bool(result.get("skipped", false)):
		var reason = String(result.get("reason", ""))
		if not reason.is_empty() and reason != "military_not_configured":
			print("[military] terrain refresh rejected: %s" % reason)


# Kept for the explicit synchronous compatibility scheduler.
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
	report["host_last_commit_day"] = host._runtime_commit_day
	report["host_pending_target_day"] = -1
	report["host_last_ms"] = float(report.get("military_day_ms", 0.0))
	return report


## Climate 权威在 worker 时，把它提交的那一天刷进 MapData。
##
## 这是 ACTIVE Climate 的主线程另一半：抑制门已经让主线程不再算 climate，
## 如果这里不回灌，MapData 就永久停在转权威那一天。
##
## 主线程先把当天的气候写入 MapData，再发出 simulation_committed。
## 逐日读取者从这个信号取得已完整交接的数据。


func _apply_climate_writeback_if_authoritative(host, report: Dictionary, commit: Dictionary = {}) -> void:
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
		# An empty compatible snapshot still advances the display cursor.
		var consumed_generation := int(applied.get("generation", -1))
		if consumed_generation > host._runtime_climate_writeback_generation:
			host._runtime_climate_writeback_generation = consumed_generation
			host._runtime_climate_writeback_last_day = int(applied.get(
				"committed_day", report.get("simulation_committed_day", -1)))
		return
	preload("res://scripts/game/world_runtime_climate_restore.gd").apply(host._generator, applied)
	if host._native_environment_active:
		host._world_clock.apply_native_climate_calendar(applied)
		var map: MapData = host._current_map
		if commit.has("display_class_cells"):
			_apply_published_cell_display(map, commit.display_class_cells)
		elif applied.has("season_day") and map != null:
			# Cold restore installs a frame before the first batch is consumed.
			_apply_published_cell_display(map, range(map.cell_count()))
		if _apply_season_display(host._current_map, applied):
			host._generator._last_season_refresh_day = int(applied.season_day) + 1
			host._generator._last_season_refresh_breakdown = {"b_plus_path": "gdext_background"}
	host._runtime_climate_writeback_generation = int(applied.get(
		"generation", host._runtime_climate_writeback_generation))
	# Older compatible runtimes may omit committed_day from the apply result;
	# the worker report driving this consume is the same committed generation.
	host._runtime_climate_writeback_last_day = int(applied.get(
		"committed_day", report.get("simulation_committed_day", -1)))
	if not host._native_environment_active:
		host._generator.record_runtime_main_step(host._runtime_climate_writeback_last_day, &"climate_writeback")
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
