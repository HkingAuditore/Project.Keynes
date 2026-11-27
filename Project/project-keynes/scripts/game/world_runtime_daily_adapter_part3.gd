extends RefCounted

## Extracted world_runtime_daily_adapter.gd group 3; state stays with host.
const EconomyDisplay = preload("res://scripts/economy/economy_facade_display.gd")

func _apply_season_display(map: MapData, applied: Dictionary) -> bool:
	if not applied.has("season_day") or map == null:
		return false
	map.published_biome_history = applied.biome_history
	map.published_vegetation_history = applied.vegetation_history
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
	if not host._native_environment_active or \
			String(report.get("requested_simulation_thread_mode", "OFF")) != "ACTIVE":
		return
	var commit: Dictionary = host._generator.poll_runtime_commit(host._runtime_commit_generation, true)
	if commit.has("boundary_results"):
		host.simulation_command_results.emit(commit["boundary_results"])
	if bool(commit.get("colonization_quotes_ready", false)):
		host.colonization_quotes_ready.emit()
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
	var whole_graph = bool(report.get("authority_ready", false))
	if received_new_commit:
		var publish_started_usec = Time.get_ticks_usec()
		var generation = int(commit.get("generation", 0))
		var old_day: int = host._runtime_commit_day
		host._runtime_commit_generation = generation
		host._runtime_commit_day = commit_day
		host.map_fields_received.emit(commit_day)
		if commit_day <= old_day or int(commit.get("from_day", -1)) == commit_day:
			host._generator.get_data_core_world_ext().finish_runtime_display_frame()
			host._publish_player_confirmation(host._runtime_control_state())
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
		host._publish_player_confirmation(host._runtime_control_state() if commit.has("boundary_results") else report)
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
		host._consume_modifier_worker_snapshot_if_authoritative()
	var from_day := int(host._runtime_last_commit.batch_from_day)
	var days: Array = commit.get("days", [])
	if whole_graph:
		var finish_usec := Time.get_ticks_usec()
		host.finish_daily_tick(0.0)
		if dcp:
			host._dcp_finish_ms = float(Time.get_ticks_usec() - finish_usec) / 1000.0
	if not days.is_empty():
		host.simulation_day_records.emit(days)
	if host._world_clock != null:
		host._world_clock.publish_runtime_date(host._runtime_commit_day)
	if commit.has("construction_receipts"):
		host._generator.get_economy_facade().emit_construction_command_receipts(
			commit["construction_receipts"])
	if commit.has("colonization_receipts"):
		host._generator.get_economy_facade().emit_family_colonization_receipts(
			commit["colonization_receipts"])
	host._publish_player_confirmation(host._runtime_control_state())
	host._gm_adapter.consume_territory_receipts(host)
	var ideology = host._generator.get_ideology_facade()
	if ideology != null:
		ideology.drain_receipts()
	host.simulation_committed.emit(from_day, host._runtime_commit_day, host._runtime_commit_generation)
	host._presentation.sync_settlement_labels(false)
	ext.finish_runtime_display_frame()
	if not whole_graph:
		# This path publishes the installed map directly, without a queued worker texture.
		host.map_texture_published.emit(commit_day)
	host._presentation.queue_worker_commit(from_day,
			host._runtime_commit_day, host._runtime_commit_generation, commit if whole_graph else {})


func military_report(host) -> Dictionary:
	if host._generator == null or not host._generator.has_method("get_military_report"):
		return {"configured": false}
	var report: Dictionary = host._generator.get_military_report()
	report["host_last_commit_day"] = host._runtime_commit_day
	report["host_pending_target_day"] = -1
	report["host_last_ms"] = float(report.get("military_day_ms", 0.0))
	return report


## Install the last complete climate frame into display data.
func _apply_climate_writeback_if_authoritative(host, report: Dictionary, commit: Dictionary = {}) -> void:
	if not bool(report.get("climate_worker_authoritative", false)):
		return
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
		if not commit.is_empty() and applied.has("climate_rng_state"):
			commit["climate_rng_state"] = applied["climate_rng_state"]
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
