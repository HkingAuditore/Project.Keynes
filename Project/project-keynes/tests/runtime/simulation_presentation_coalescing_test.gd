extends SceneTree

class UiProbe extends RefCounted:
	var rendered: Array[int] = []
	var dates: Array[Vector3i] = []
	var refreshes := 0

	## 控制器侧 committed 三入口已收敛成 notify_committed_day()（fb4 语义），
	## 假 UI 要跟着换，否则 has_method 不命中、refreshes 恒 0。
	func notify_committed_day() -> void:
		refreshes += 1

	func refresh_selected_daily_lines(_force: bool, day: int) -> void:
		rendered.append(day)

	func update_time_state(year: int, month: int, day: int, _paused: bool, _speed: float) -> void:
		dates.append(Vector3i(year, month, day))


class CommitDisplay extends RefCounted:
	var closed_frames := 0
	func finish_runtime_display_frame() -> void:
		closed_frames += 1
	func apply_runtime_economy_resource_writeback() -> Dictionary:
		return {"ok": true, "applied": false}

class CommitSource extends MapGenerator:
	var display := CommitDisplay.new()
	var visual_updates: Array[Dictionary] = []
	var map_available := true
	var next_day := 24
	var visual_commit := {}
	func get_data_core_world_ext():
		return display
	func publish_worker_climate_visuals(_defer: bool = false, commit: Dictionary = {}) -> Dictionary:
		visual_updates.append(commit)
		if not map_available:
			return {"lut_encode_path": "none", "reason": "missing_world_or_lut_dims"}
		return {"lut_encode_path": "gdext"}
	func poll_runtime_commit(after_generation: int = 0, take_days: bool = false) -> Dictionary:
		var commit := {"ok": true, "available": after_generation < next_day and take_days,
			"from_day": next_day - 1, "committed_day": next_day, "generation": next_day, "days": [{"day": next_day}]}
		commit.merge(visual_commit)
		return commit

class MusicProbe extends RefCounted:
	var refreshes := 0

	func refresh_global_from_commit() -> void:
		refreshes += 1

class WritebackExtensionProbe extends RefCounted:
	var response := {}
	func apply_runtime_climate_writeback(_generation: int) -> Dictionary:
		return response

class WritebackGeneratorProbe extends MapGenerator:
	var extension := WritebackExtensionProbe.new()
	func get_data_core_world_ext():
		return extension

const ClimateWritebackAdapter := preload(
	"res://scripts/game/world_runtime_daily_adapter_part3.gd")
const MapUpdates := preload("res://scripts/game/world_runtime_map_updates.gd")
var _climate_writeback_adapter := ClimateWritebackAdapter.new()


class CommitWritebackProbe extends "res://scripts/game/world_runtime_daily_adapter_part3.gd":
	var requested_day := -1
	var requested_generation := -1
	var writeback_ready := false

	func _apply_climate_writeback_if_authoritative(host, report: Dictionary, commit: Dictionary = {}) -> void:
		requested_day = int(report["simulation_committed_day"])
		requested_generation = int(commit.get("generation", -1))
		if writeback_ready:
			host._runtime_climate_writeback_last_day = requested_day

class WritebackProbe extends WorldRuntimeHost:
	var authority_ready := true
	var vision_ok := true
	var new_vision := PackedInt32Array()

	func _runtime_control_state() -> Dictionary:
		return {"simulation_thread_mode": "ACTIVE", "authority_ready": authority_ready,
			"requested_simulation_thread_mode": "ACTIVE",
			"climate_worker_authoritative": true, "simulation_committed_day": 23}

	func finish_daily_tick(_ui_ms: float, _ui_breakdown: Dictionary = {}) -> void:
		pass

	func apply_runtime_vision_display() -> Dictionary:
		if vision_ok and not new_vision.is_empty():
			_vision_dirty_indices = new_vision
			_country_visual_refresh_pending = true
		return {"ok": vision_ok}


func _check_matching_weather_day() -> bool:
	var host := WritebackProbe.new()
	var writeback := CommitWritebackProbe.new()
	host._daily_adapter._part3 = writeback
	host._generator = CommitSource.new()
	host._native_environment_active = true
	host._runtime_ready_for_ticks = true
	host._runtime_commit_generation = 23
	host._runtime_climate_writeback_last_day = 23
	var received: Array[int] = []
	host.simulation_committed.connect(func(_from, day, _generation): received.append(day))
	host._consume_runtime_commit_if_ready()
	var delivered: bool = received == [24] and writeback.requested_day == 24 \
		and writeback.requested_generation == 24 and host._runtime_climate_writeback_last_day == 23 \
		and host._generator.display.closed_frames == 1
	host.free()
	return delivered


func _check_empty_consumed_climate_writeback() -> bool:
	var host := WorldRuntimeHost.new()
	var generator := WritebackGeneratorProbe.new()
	host._generator = generator
	host._runtime_climate_writeback_generation = 4
	host._runtime_climate_writeback_last_day = 10
	var report := {"climate_worker_authoritative": true, "simulation_committed_day": 11}
	generator.extension.response = {"ok": true, "applied": false,
		"generation": 5, "committed_day": 11}
	_climate_writeback_adapter._apply_climate_writeback_if_authoritative(host, report)
	var consumed := host._runtime_climate_writeback_generation == 5 \
		and host._runtime_climate_writeback_last_day == 11
	generator.extension.response = {"ok": true, "applied": false,
		"generation": 5, "committed_day": 11}
	host._runtime_climate_writeback_generation = 5
	host._runtime_climate_writeback_last_day = 10
	_climate_writeback_adapter._apply_climate_writeback_if_authoritative(host, report)
	var unavailable := host._runtime_climate_writeback_last_day == 10
	host.free()
	return consumed and unavailable


func _check_map_update_budget() -> bool:
	var updates := MapUpdates.new()
	updates.start_frame(100_000)
	var held_at_60 := not updates.can_apply(1, 116_000, 60)
	var room_at_30 := updates.can_apply(1, 116_000, 30)
	var held_at_30 := not updates.can_apply(1, 132_000, 30)
	var uncapped := updates.can_apply(1, 132_000, 0)
	updates.observe_draw(100_000, 60)
	updates.observe_draw(122_000, 60)
	updates.observe_draw(144_000, 60)
	updates.observe_draw(166_000, 60)
	updates.applied(1, 2_000)
	updates.start_frame(166_000)
	var slowed := not updates.can_apply(3, 167_000, 60) and updates.can_apply(5, 167_000, 60)
	var draw := 166_000
	for spacing in [3, 2, 1]:
		for ignored in 3:
			draw += 16_667
			updates.observe_draw(draw, 60)
		updates.start_frame(draw)
		if not updates.can_apply(1 + spacing, draw + 1_000, 60):
			return false
		if spacing > 1 and updates.can_apply(spacing, draw + 1_000, 60):
			return false
	return held_at_60 and room_at_30 and held_at_30 and uncapped and slowed


func _check_held_cell_union() -> bool:
	var presentation := preload("res://scripts/game/world_runtime_presentation.gd").new()
	var snapshots: Array[Array] = []
	var publish := func(from: int, day: int, generation: int) -> void:
		snapshots.append([from, day, generation])
	presentation.queue_worker_commit(12, 13, 1, {"display_dirty_cells": PackedInt32Array([5, 6]),
		"display_class_cells": PackedInt32Array([5]), "cell_lut_frame": {"transition_age": PackedByteArray([255])}})
	presentation.queue_worker_commit(13, 14, 2, {"display_dirty_cells": PackedInt32Array([6, 9]),
		"display_class_cells": PackedInt32Array([9]), "cell_lut_frame": {"transition_age": PackedByteArray([237])}})
	presentation.publish_worker_view(publish)
	var held := snapshots.is_empty() and presentation.presented_worker_day() == -1
	var latest: Dictionary = presentation._map_updates.collect(PackedInt32Array([7]))
	var union := PackedInt32Array(latest.display_dirty_cells)
	var classes := PackedInt32Array(latest.display_class_cells)
	union.sort()
	classes.sort()
	var merged: bool = union == PackedInt32Array([5, 6, 7, 9]) and classes == PackedInt32Array([5, 7, 9]) \
		and latest.cell_lut_frame.transition_age == PackedByteArray([237])
	presentation._map_updates.applied(1, 2_000)
	presentation.publish_worker_view(publish)
	var advanced := snapshots == [[12, 14, 2]]
	presentation.queue_worker_commit(14, 15, 3, {"display_class_cells": PackedInt32Array([2])})
	presentation.queue_worker_commit(15, 16, 4, {"display_dirty_cells": PackedInt32Array([3])})
	var full: Dictionary = presentation._map_updates.collect(PackedInt32Array())
	var kept_full: bool = not full.has("display_dirty_cells") and 2 in full.display_class_cells
	presentation.release_resources()
	presentation.queue_worker_commit(0, 1, 1)
	presentation.publish_worker_view(publish)
	return held and merged and advanced and kept_full and snapshots == [[12, 14, 2], [0, 1, 1]]


func _check_vision_uses_same_frame() -> bool:
	var host := WorldRuntimeHost.new()
	var source := CommitSource.new()
	host._generator = source
	var previous_fps := Engine.max_fps
	Engine.max_fps = 60
	var now := Time.get_ticks_usec()
	host._presentation._map_updates.start_frame(now - 16_000)
	host._presentation.queue_worker_commit(1, 2, 2, {"display_dirty_cells": PackedInt32Array([4])})
	host._service_worker_map_presentation(now - 16_000)
	var held := source.visual_updates.is_empty()
	host._country_visual_refresh_pending = true
	host._vision_dirty_indices = PackedInt32Array([7])
	host._service_worker_map_presentation(now - 16_000)
	var refreshed := source.visual_updates.size() == 1 and not host._country_visual_refresh_pending \
		and host._vision_dirty_indices.is_empty() and host._country_visual_refresh_run_count == 1
	var applied := false
	if refreshed:
		var dirty: PackedInt32Array = source.visual_updates[0].display_dirty_cells
		var classes: PackedInt32Array = source.visual_updates[0].display_class_cells
		applied = 4 in dirty and 7 in dirty and 7 in classes
	host.free()
	Engine.max_fps = previous_fps
	return held and applied


func _check_executor_restart_keeps_held_cells() -> bool:
	var presentation := preload("res://scripts/game/world_runtime_presentation.gd").new()
	presentation.queue_worker_commit(30, 31, 90, {"display_dirty_cells": PackedInt32Array([4]),
		"map_lut_pending": true, "committed_day": 31, "generation": 90})
	# The executor can start a new generation sequence within the same world.
	presentation.queue_worker_commit(31, 32, 1, {"display_dirty_cells": PackedInt32Array([7]),
		"map_lut_pending": true, "committed_day": 32, "generation": 1})
	var update: Dictionary = presentation._map_updates.collect(PackedInt32Array())
	var dirty: PackedInt32Array = update.display_dirty_cells
	var shown: Array[Array] = []
	presentation._map_updates.applied(1, 2_000)
	presentation.publish_worker_view(func(from, day, generation): shown.append([from, day, generation]))
	return shown == [[30, 32, 1]] and 4 in dirty and 7 in dirty \
		and update.map_lut_day == 32 and update.map_lut_generation == 1 and not update.has("cell_lut_frame")


func _check_commit_without_map_keeps_held_cells() -> bool:
	var host := WritebackProbe.new()
	var source := CommitSource.new()
	host._daily_adapter._part3 = CommitWritebackProbe.new()
	host._generator = source
	host._native_environment_active = true
	host._runtime_ready_for_ticks = true
	var previous_fps := Engine.max_fps
	Engine.max_fps = 60
	var now := Time.get_ticks_usec()
	host._presentation._map_updates.start_frame(now - 16_000)
	source.visual_commit = {"display_dirty_cells": PackedInt32Array([4, 5]),
		"display_class_cells": PackedInt32Array([4]),
		"cell_lut_frame": {"transition_age": PackedByteArray([237])}}
	host._consume_runtime_commit_if_ready()
	host._service_worker_map_presentation(now - 16_000)
	var held := source.visual_updates.is_empty()
	source.next_day = 25
	host.authority_ready = false
	source.visual_commit = {}
	host._consume_runtime_commit_if_ready()
	Engine.max_fps = 0
	host._service_worker_map_presentation(Time.get_ticks_usec())
	var applied := source.visual_updates.size() == 1
	if applied:
		var update := source.visual_updates[0]
		applied = update.display_dirty_cells == PackedInt32Array([4, 5]) \
			and update.display_class_cells == PackedInt32Array([4]) \
			and update.cell_lut_frame.transition_age == PackedByteArray([237])
	var shown: Array[Array] = []
	host._presentation.publish_worker_view(func(from, day, generation): shown.append([from, day, generation]))
	host.free()
	Engine.max_fps = previous_fps
	return held and applied and shown == [[23, 25, 25]]


func _check_failed_map_does_not_block_view() -> bool:
	var host := WorldRuntimeHost.new()
	var source := CommitSource.new()
	source.map_available = false
	host._generator = source
	var shown: Array[int] = []
	host.simulation_view_updated.connect(func(_from, day, _generation): shown.append(day))
	host._presentation.queue_worker_commit(5, 6, 6, {"display_dirty_cells": PackedInt32Array([4])})
	host._process(0.0)
	var continued := shown == [6] and source.visual_updates.size() == 1
	source.map_available = true
	host._process(0.0)
	var recovered := source.visual_updates.size() == 2 and not source.visual_updates[-1].has("display_dirty_cells")
	host._presentation.queue_worker_commit(6, 7, 7)
	host._process(0.0)
	continued = continued and shown == [6, 7] and source.visual_updates.size() == 2
	host._presentation.queue_worker_commit(7, 8, 8, {"display_dirty_cells": PackedInt32Array([9])})
	host._process(0.0)
	var incremental := source.visual_updates.size() == 3 and source.visual_updates[-1].has("display_dirty_cells")
	host.free()
	return continued and recovered and incremental and shown == [6, 7, 8]


func _check_map_publisher_without_host() -> bool:
	var presentation := preload("res://scripts/game/world_runtime_presentation.gd").new()
	presentation.queue_worker_commit(5, 6, 6, {"display_dirty_cells": PackedInt32Array([4])})
	presentation.queue_worker_commit(6, 7, 7)
	var calls: Array[int] = []
	presentation.apply_pending_worker_map(PackedInt32Array([7]),
		func(update: Dictionary, day: int, _started_usec: int) -> bool:
			var dirty: PackedInt32Array = update.display_dirty_cells
			if dirty.size() == 2 and 4 in dirty and 7 in dirty:
				calls.append(day)
			return true)
	return calls == [6] and not presentation._map_updates.has_pending()


func _check_save_vision_boundary() -> bool:
	var host := WritebackProbe.new()
	var source := CommitSource.new()
	host._generator = source
	host._presentation.queue_worker_commit(1, 2, 2, {"display_dirty_cells": PackedInt32Array([4])})
	var unchanged := bool(host.synchronize_vision_display_for_save().ok) and source.visual_updates.is_empty()
	host._vision_dirty_indices = PackedInt32Array([5])
	host.vision_ok = false
	var failed := not bool(host.synchronize_vision_display_for_save().ok) and source.visual_updates.is_empty()
	host.vision_ok = true
	host.new_vision = PackedInt32Array([5, 7])
	var saved := bool(host.synchronize_vision_display_for_save().ok) and source.visual_updates.size() == 1
	var refreshed := host._vision_dirty_indices.is_empty() and host._country_visual_refresh_run_count == 1
	if saved:
		var dirty: PackedInt32Array = source.visual_updates[0].display_dirty_cells
		saved = dirty.size() == 3 and 4 in dirty and 5 in dirty and 7 in dirty
	host.free()
	return unchanged and failed and saved and refreshed


func _check_host_frame_connections() -> bool:
	var host := WorldRuntimeHost.new()
	var process_count := process_frame.get_connections().size()
	var draw_count := RenderingServer.frame_post_draw.get_connections().size()
	root.add_child(host)
	# Headless normally omits these subscriptions. Test the same connection
	# setup used at desktop entry and the actual tree exit in both modes.
	if DisplayServer.get_name() == "headless":
		host._connect_presentation_frames()
	var owner := func(connection: Dictionary) -> bool: return connection.callable.get_object() == host
	var starts := process_frame.get_connections().filter(owner)
	var draws := RenderingServer.frame_post_draw.get_connections().filter(owner)
	var bound := starts.size() == 1 and draws.size() == 1
	if bound:
		starts[0].callable.call()
		draws[0].callable.call()
		bound = host._presentation._map_updates._frame_started_usec > 0 \
			and host._presentation._map_updates._last_draw_usec > 0
	root.remove_child(host)
	var disconnected := process_frame.get_connections().size() == process_count \
		and RenderingServer.frame_post_draw.get_connections().size() == draw_count
	host.free()
	return bound and disconnected


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var host := WorldRuntimeHost.new()
	if not host.has_signal("simulation_view_updated") \
			or not host._presentation.has_method("queue_worker_commit"):
		push_error("Simulation presentation has no independent frame consumer")
		host.free()
		quit(1)
		return
	var clock := WorldClock.new()
	clock.current_day = 28.0
	var controller := PlayerController.new()
	var ui := UiProbe.new()
	var music := MusicProbe.new()
	controller._world_clock = clock
	controller._runtime_host = host
	controller._ui_manager = ui
	controller._music_situation = music
	controller._selected_cell = HexCell.new()
	controller._connect_runtime()
	var frames: Array[Array] = []
	host.connect("simulation_view_updated", func(from, to, generation):
		frames.append([from, to, generation]))
	var rows: Array = [{"day": 21}, {"day": 22}, {"day": 23}, {"day": 24}]
	host._runtime_last_commit = {"gdp": {"day": 24}, "days": rows, "notice_history": []}
	host.simulation_day_records.emit(rows)
	for day in range(21, 25):
		host._presentation.call("queue_worker_commit", day - 1, day, day)
		host.simulation_committed.emit(day - 1, day, day)
	var no_early_frame := frames.is_empty() and ui.rendered.is_empty() and ui.dates.is_empty()
	var daily_audio := music.refreshes == 4
	host._process(0.0)
	host._process(0.0)
	var coalesced := frames == [[20, 24, 24]]
	var date: Dictionary = clock.calendar_date_for_day(24)
	var correct_date := ui.dates == [Vector3i(clock.year_index_for_day(24), date.month, date.day_of_month)]
	host._presentation.call("queue_worker_commit", 26, 27, 27)
	host._process(0.0)
	var crossed_gap := frames == [[20, 24, 24], [24, 27, 27]]
	host._presentation.release_resources()
	host._presentation.call("queue_worker_commit", 0, 1, 1)
	host._process(0.0)
	var restarted := frames == [[20, 24, 24], [24, 27, 27], [0, 1, 1]]
	controller.free()
	clock.free()
	host.free()
	var ok := no_early_frame and coalesced and crossed_gap and restarted and correct_date \
		and ui.rendered == [24, 27, 1] and ui.refreshes == 3 \
		and daily_audio and music.refreshes == 4 and _check_matching_weather_day() \
		and _check_empty_consumed_climate_writeback() and _check_map_update_budget() \
		and _check_held_cell_union() and _check_vision_uses_same_frame() \
		and _check_executor_restart_keeps_held_cells()
	var kept_map := _check_commit_without_map_keeps_held_cells()
	var recovered_view := _check_failed_map_does_not_block_view()
	var narrow_publisher := _check_map_publisher_without_host()
	var save_boundary := _check_save_vision_boundary()
	var frame_connections := _check_host_frame_connections()
	print("Simulation presentation coalescing: ", ok)
	print("Commit without map keeps held changes: ", kept_map)
	print("Failed map releases date and recovers without another commit: ", recovered_view)
	print("Map publisher receives only the update, map day and start time: ", narrow_publisher)
	print("Save synchronizes new vision through the host: ", save_boundary)
	print("Frame callbacks bind to the host and disconnect on exit: ", frame_connections)
	quit(0 if ok and kept_map and recovered_view and narrow_publisher and save_boundary and frame_connections else 1)
