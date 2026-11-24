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
	func get_data_core_world_ext():
		return display
	func publish_worker_climate_visuals(_defer: bool = false, _commit: Dictionary = {}) -> Dictionary:
		return {"ok": true}
	func poll_runtime_commit(after_generation: int = 0, take_days: bool = false) -> Dictionary:
		return {"ok": true, "available": after_generation < 24 and take_days,
			"from_day": 23, "committed_day": 24, "generation": 24, "days": [{"day": 24}]}

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
	func _runtime_control_state() -> Dictionary:
		return {"simulation_thread_mode": "ACTIVE", "authority_ready": true,
			"requested_simulation_thread_mode": "ACTIVE",
			"climate_worker_authoritative": true, "simulation_committed_day": 23}

	func finish_daily_tick(_ui_ms: float, _ui_breakdown: Dictionary = {}) -> void:
		pass

	func apply_runtime_vision_display() -> Dictionary:
		return {"ok": true}


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


func _init() -> void:
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
		and _check_empty_consumed_climate_writeback()
	print("Simulation presentation coalescing: ", ok)
	quit(0 if ok else 1)
