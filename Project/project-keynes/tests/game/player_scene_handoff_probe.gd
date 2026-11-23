extends SceneTree

## Records the real player scene with either Godot display driver. The clock
## still decides when to request a day, and the scene still consumes it.
const WIDTH := 60
const HEIGHT := 40
const SEED := 20260718
const WATCHDOG_USEC := 5_000_000

class TimedConsumer extends "res://scripts/game/world_runtime_daily_adapter_part3.gd":
	var elapsed_usec := 0

	func _consume_runtime_commit_if_ready(host, report_override: Dictionary = {}) -> void:
		var started := Time.get_ticks_usec()
		super(host, report_override)
		elapsed_usec += Time.get_ticks_usec() - started

var _host: WorldRuntimeHost
var _clock: WorldClock
var _generator: MapGenerator
var _controller: PlayerController
var _camera: MapCamera
var _camera_center: Vector2
var _camera_zoom: Vector2
var _consumer := TimedConsumer.new()
var _admit_day: Callable
var _request := -1
var _admit_usec := 0
var _ui_usec := 0
var _day_rows: Array = []
var _frames: Array = []
var _answers: Array[Dictionary] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var args := {}
	for arg in OS.get_cmdline_user_args():
		args[arg.get_slice("=", 0)] = arg.get_slice("=", 1)
	var output := String(args.get("--frames", ""))
	var speed := float(args.get("--speed", 50.0))
	var target := int(args.get("--through", 180))
	var foreign_count := int(args.get("--foreign-count", 3))
	var answer_story := args.has("--answer-story")
	if not output.is_absolute_path() or speed not in [1.0, 50.0, 100.0] or target <= 0:
		push_error("Pass --frames=<absolute path>, --speed=1|50|100 and --through=<day>")
		quit(1)
		return
	root.get_node("GameSettings").update({
		"window_mode": "windowed", "resolution_width": 1600, "resolution_height": 960,
		"render_quality": "high", "graphics_custom": false, "vsync": true,
		"autosave_enabled": false, "ai_narrative_enabled": false, "event_pause_mask": 255,
	}, false)
	var config := NewGameConfig.new()
	config.apply_land_layout(NewGameConfig.DEFAULT_LAND_LAYOUT)
	config.base.map_width = WIDTH
	config.base.map_height = HEIGHT
	config.base.initial_seed = SEED
	config.country.foreign_count = foreign_count
	var previous := current_scene
	var flow := root.get_node("GameFlow")
	var begin: Dictionary = flow.begin_new_game(config)
	if not begin.get("ok", false):
		push_error(str(begin))
		quit(1)
		return
	# Follow the real scene until it has drawn the selected starting cell.
	while flow.session().is_empty() or current_scene == previous:
		await process_frame
		if current_scene is PlayerGame:
			var loading := current_scene.get_node("RuntimeHost") as WorldRuntimeHost
			var session := loading.session_report()
			if session.state == "FAULTED":
				push_error(str(session.failure))
				quit(1)
				return
	var scene := current_scene as PlayerGame
	_host = scene.get_node("RuntimeHost")
	_clock = scene.get_node("WorldClock")
	_generator = _host.get_generator()
	_camera = scene.get_node("MapCamera")
	_host.fit_camera()
	_camera_center = _host.world_data().world_bounds.get_center()
	_camera_zoom = _camera.zoom
	_reset_camera()
	_controller = scene.get_node("PlayerController")
	var view_connections := _host.simulation_view_updated.get_connections()
	for connection in view_connections:
		_host.simulation_view_updated.disconnect(connection.callable)
	for connection in view_connections:
		var callback: Callable = connection.callable
		if callback.get_object() == _controller:
			callback = _timed_ui.bind(callback)
		_host.simulation_view_updated.connect(callback, int(connection.flags))
	_admit_day = _clock._runtime_calendar_admit
	_clock._runtime_calendar_admit = _timed_admit
	_host._daily_adapter._part3 = _consumer
	_host.simulation_day_records.connect(_record_days)
	var start := _host._runtime_commit_day
	var settings: Dictionary = root.get_node("GameSettings").values()
	print("HANDOFF_CONFIG=", JSON.stringify({"width": _host.current_map().width,
		"height": _host.current_map().height, "seed": _host.last_seed(),
		"configured_countries": foreign_count + 1,
		"speed": speed, "camera": str(_camera.position), "zoom": str(_camera.zoom),
		"display": DisplayServer.get_name(), "window_size": str(DisplayServer.window_get_size()),
		"viewport_size": str(root.get_visible_rect().size), "max_fps": Engine.max_fps,
		"vsync": DisplayServer.window_get_vsync_mode(), "quality": settings.render_quality,
		"renderer": RenderingServer.get_current_rendering_method(), "start_day": start}))
	_host.execute_gm_command("time.speed", {"value": speed})
	_clock.pause(false)
	var condition := await _capture(target, answer_story)
	_clock.pause(true)
	_clock._runtime_calendar_admit = _admit_day
	for connection in _host.simulation_view_updated.get_connections():
		_host.simulation_view_updated.disconnect(connection.callable)
	for connection in view_connections:
		_host.simulation_view_updated.connect(connection.callable, int(connection.flags))
	var contiguous := true
	for index in _day_rows.size():
		contiguous = contiguous and int(_day_rows[index].day) == maxi(0, start) + index + 1
	contiguous = contiguous and maxi(0, start) + _day_rows.size() == _host._runtime_commit_day
	var captured := _write(output, _frames) and _write(output + ".days", _day_rows)
	var countries := int(_host._country_worker_read_last_result.get("country_count", -1))
	print("HANDOFF_RESULT=", JSON.stringify({"end": condition, "display_day": _clock.day_index(),
		"consumed_day": _host._runtime_commit_day, "records": _day_rows.size(),
		"contiguous": contiguous, "frames": _frames.size(), "written": captured,
		"countries": countries,
		"answers": _answers, "last": _frames.back()}))
	var closed: Dictionary = await _host.close_world()
	quit(0 if captured and contiguous and countries == foreign_count + 1 and closed.get("ok", false)
		and condition in ["target", "player"] else 1)


func _timed_admit(date: int) -> int:
	_request = date - 1
	var started := Time.get_ticks_usec()
	var admitted := int(_admit_day.call(date))
	_admit_usec += Time.get_ticks_usec() - started
	return admitted


func _reset_camera() -> void:
	_camera._stop_motion()
	_camera.position = _camera_center
	_camera.force_update_scroll()


func _timed_ui(from_day: int, day: int, generation: int, callback: Callable) -> void:
	var started := Time.get_ticks_usec()
	callback.call(from_day, day, generation)
	_ui_usec += Time.get_ticks_usec() - started


func _record_days(records: Array) -> void:
	for row: Dictionary in records:
		_day_rows.append({"day": row.day, "business_hash": str(row.get("business_hash", 0)),
			"produced_at_us": row.produced_at_us, "receipts": row.get("receipts", [])})


func _capture(target: int, answer_story: bool) -> String:
	var previous_frame := Time.get_ticks_usec()
	var last_progress := previous_frame
	var previous_day := _host._runtime_commit_day
	var answered_offer := 0
	while true:
		await process_frame
		var now := Time.get_ticks_usec()
		var runtime := _generator.get_runtime_thread_report()
		var control := _generator.get_runtime_control_state()
		var consumed := _host._runtime_commit_day
		var committed := int(control.get("simulation_committed_day", -1))
		var state := String(control.get("simulation_host_state", ""))
		var player_reason := String(control.get("player_block_reason", ""))
		var fault := String(runtime.get("fault_code", ""))
		var reason := "running"
		if not fault.is_empty() or state in ["FAULTED", "STOPPED", "STOPPING"]:
			reason = "fault"
		elif not player_reason.is_empty():
			reason = "player"
		elif _clock.paused:
			reason = "pause"
		elif int(runtime.get("day_stall_reason_mask", 0)) != 0:
			reason = "domain_wait"
		elif state == "PAUSED" and committed >= _host._calendar_admitted_through:
			reason = "calendar_wait"
		_frames.append({"usec": now, "frame_usec": now - previous_frame,
			"sample_usec": Time.get_ticks_usec() - now, "display": _clock.day_index(),
			"requested": _request, "admitted": _host._calendar_admitted_through,
			"committed": committed, "consumed": consumed, "state": state, "reason": reason,
			"player_reason": player_reason, "player_day": control.get("player_block_day", -1),
			"clock_paused": _clock.paused, "pause_source": _clock.last_pause_source,
			"fault": fault, "environment": runtime.get("simulation_environment_day", -1),
			"inflight": runtime.get("worker_day_inflight", -1),
			"stall_mask": runtime.get("day_stall_reason_mask", 0), "park": runtime.get("day_park_reason", ""),
			"wait_us": runtime.get("worker_time_clock_wait_us", 0),
			"retry_us": runtime.get("worker_time_input_retry_wait_us", 0),
			"environment_wait_us": runtime.get("worker_time_environment_wait_us", 0),
			"execute_us": runtime.get("worker_time_execute_us", 0),
			"admit_us": _admit_usec, "consume_us": _consumer.elapsed_usec, "ui_us": _ui_usec,
			"visual_ms": _host._runtime_last_visual_apply_ms if consumed != previous_day else 0.0,
			"writeback_ms": _host._runtime_climate_writeback_memcpy_ms + _host._runtime_climate_writeback_flush_ms,
			"host_ms": _host._sched_proc_last_total_ms})
		_request = -1
		_admit_usec = 0
		_consumer.elapsed_usec = 0
		_ui_usec = 0
		previous_frame = now
		if consumed != previous_day:
			previous_day = consumed
			last_progress = now
		if reason in ["pause", "fault"]:
			return reason
		if reason != "player" and (_camera.position != _camera_center or _camera.zoom != _camera_zoom):
			return "camera_moved"
		if reason == "player" and consumed >= int(control.get("player_block_day", -1)):
			if not answer_story or player_reason != "narrative_choice_required":
				return reason
			var flow = _controller.narrative_flow()
			var offer: Dictionary = _controller.narrative_service().active_offer()
			var offer_id := int(offer.get("offer_id", 0))
			if offer_id > 0 and offer_id != answered_offer:
				flow.on_outcome_acknowledged()
				var receipt: Dictionary = flow.on_option_chosen(offer_id, int(offer.offer_generation), 0)
				_answers.append({"day": consumed, "event": offer.event_id, "receipt": receipt})
				if not receipt.get("ok", false):
					return "answer_failed"
				_reset_camera()
				answered_offer = offer_id
		if consumed >= target:
			return "target"
		if now - last_progress >= WATCHDOG_USEC:
			return "unexplained_stall"
	return "unreachable"


func _write(path: String, rows: Array) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	for row in rows:
		file.store_line(JSON.stringify(row))
	file.close()
	return true
