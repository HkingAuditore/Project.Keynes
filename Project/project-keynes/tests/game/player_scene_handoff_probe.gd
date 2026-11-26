extends SceneTree

## Records the real player scene with either Godot display driver. The clock
## still decides when to request a day, and the scene still consumes it.
const WIDTH := 60
const HEIGHT := 40
const SEED := 20260718
const WATCHDOG_USEC := 5_000_000
const GraphicsSettings = preload("res://scripts/game/graphics_quality_settings.gd")
const FrameTimings = preload("res://tests/game/player_scene_handoff_timings.gd")
const DisplayChecks = preload("res://tests/game/player_scene_display_checks.gd")
const FRAME_LIMITS := {"30": 30, "60": 60, "adaptive": GraphicsSettings.ADAPTIVE_FPS}
const OVERLOAD_FIRST_DAY := 40
const OVERLOAD_END_DAY := 55
const COMMAND_LOG := [
	{"request_id": 630001, "producer_id": 2, "requested_day": 2, "domain": 1, "opcode": 1},
	{"request_id": 630002, "producer_id": 2, "requested_day": 2, "domain": 1, "opcode": 1},
	{"request_id": 630003, "producer_id": 2, "requested_day": 5, "domain": 1, "opcode": 1},
]

var _host: WorldRuntimeHost
var _clock: WorldClock
var _generator: MapGenerator
var _controller: PlayerController
var _camera: MapCamera
var _camera_center: Vector2
var _camera_zoom: Vector2
var _timings := FrameTimings.new()
var _admit_day: Callable
var _request := -1
var _admit_usec := 0
var _ui_usec := 0
var _day_rows: Array = []
var _frames: Array = []
var _answers: Array[Dictionary] = []
var _draw_times: Array[int] = []
var _draw_lag_days: Array[int] = []
var _map_draw_times: Array[int] = []
var _map_draw_lag_days: Array[int] = []
var _map_viewport: SubViewport
var _map_draw_count := 0
var _panel_feedback: FrameTimings.PanelFeedback
var _draw_count := 0
var _view_updates := 0
var _overload := false
var _overload_us := 0
var _display_checks: DisplayChecks
var _check_commands := false
var _simulate_frames := false


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
	var require_rendered := args.has("--require-rendered")
	var fps_mode := String(args.get("--fps", ""))
	_overload = args.has("--overload")
	_check_commands = args.has("--command-log")
	_simulate_frames = args.has("--simulate-frames")
	if not output.is_absolute_path() or speed not in [1.0, 50.0, 100.0] or target <= 0 \
			or (args.has("--fps") and not FRAME_LIMITS.has(fps_mode)):
		push_error("Pass --frames=<absolute path>, --speed=1|50|100, --through=<day> and optionally --fps=30|60|adaptive")
		quit(1)
		return
	if _overload and (fps_mode.is_empty() or target < 75 or not answer_story):
		push_error("--overload requires --fps, --through of at least 75 days and --answer-story")
		quit(1)
		return
	if args.has("--exercise-display") and (not require_rendered or not _overload or fps_mode != "60"):
		push_error("--exercise-display requires --require-rendered, --overload and --fps=60")
		quit(1)
		return
	if args.has("--panel-clicks") and (not require_rendered or target < 75 or not answer_story):
		push_error("--panel-clicks requires --require-rendered, --through of at least 75 days and --answer-story")
		quit(1)
		return
	var driver := RenderingServer.get_current_rendering_driver_name()
	var rendered := DisplayServer.get_name() != "headless" and driver not in ["", "dummy"]
	if require_rendered and not rendered:
		_record_start_failure(output, {"ok": false, "code": "rendered_backend_required", "driver": driver})
		quit(1)
		return
	if _simulate_frames and (rendered or not _overload):
		push_error("--simulate-frames requires --headless and --overload")
		quit(1)
		return
	var settings_service := root.get_node("GameSettings")
	var settings_patch := {
		"window_mode": "windowed", "resolution_width": 1600, "resolution_height": 960,
		"render_quality": "high", "graphics_custom": false, "vsync": true,
		"autosave_enabled": false, "ai_narrative_enabled": false, "event_pause_mask": 255,
	}
	if not fps_mode.is_empty():
		settings_patch.merge(GraphicsSettings.resolve(settings_patch, OS.has_feature("mobile")), true)
		settings_patch.graphics_custom = true
		settings_patch.frame_rate_limit = FRAME_LIMITS[fps_mode]
	settings_service.update(settings_patch, false)
	if require_rendered and DisplayServer.get_name() == "macOS":
		# Keep the benchmark drawable while the desktop remains in use.
		root.always_on_top = true
		root.grab_focus()
	var config := NewGameConfig.new()
	config.apply_land_layout(NewGameConfig.DEFAULT_LAND_LAYOUT)
	config.base.map_width = WIDTH
	config.base.map_height = HEIGHT
	config.base.initial_seed = SEED
	config.country.foreign_count = foreign_count
	var start_result := await _start_player_scene(root.get_node("GameFlow"), config)
	if not start_result.get("ok", false):
		_record_start_failure(output, start_result)
		var loading := _player_host()
		if loading != null:
			await loading.close_world()
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
	_map_viewport = scene.get_node_or_null("MapViewport")
	if _map_viewport != null:
		_map_draw_count = int(_map_viewport.get("draw_count"))
	if args.has("--panel-clicks"):
		_panel_feedback = FrameTimings.PanelFeedback.new()
		_panel_feedback.attach(scene)
	# The same probe also measures older checkouts where UI and map shared a signal.
	var ui_updates := Signal(_host, &"simulation_ui_updated") if _host.has_signal(&"simulation_ui_updated") else _host.simulation_view_updated
	var ui_connections := ui_updates.get_connections()
	for connection in ui_connections:
		ui_updates.disconnect(connection.callable)
	for connection in ui_connections:
		var callback: Callable = connection.callable
		if callback.get_object() == _controller:
			callback = _timed_ui.bind(callback)
		ui_updates.connect(callback, int(connection.flags))
	_host.simulation_view_updated.connect(_record_view)
	_admit_day = _clock._runtime_calendar_admit
	_clock._runtime_calendar_admit = _timed_admit
	_timings.attach(_host)
	_host.simulation_day_records.connect(_record_days)
	if args.has("--exercise-display"):
		_display_checks = DisplayChecks.new()
		_display_checks.setup(scene, settings_service)
	if _check_commands:
		for command: Dictionary in COMMAND_LOG:
			var receipt: Dictionary = _generator.get_data_core_world_ext().submit_runtime_command(command)
			if not receipt.get("ok", false) or receipt.get("effective_day") != command.requested_day:
				_record_start_failure(output, {"code": "probe_command_admission_failed", "receipt": receipt})
				await _host.close_world()
				quit(1)
				return
	var start := _host._runtime_commit_day
	var graphics := GraphicsSettings.resolve(settings_service.values(), OS.has_feature("mobile"))
	print("HANDOFF_CONFIG=", JSON.stringify({"width": _host.current_map().width,
		"height": _host.current_map().height, "seed": _host.last_seed(),
		"configured_countries": foreign_count + 1,
		"speed": speed, "camera": str(_camera.position), "zoom": str(_camera.zoom),
		"display": DisplayServer.get_name(), "window_size": str(DisplayServer.window_get_size()),
		"viewport_size": str(root.get_visible_rect().size), "max_fps": Engine.max_fps,
		"vsync": DisplayServer.window_get_vsync_mode(), "quality": graphics.render_quality,
		"graphics": graphics, "fps_mode": fps_mode, "overload": _overload,
		"renderer": RenderingServer.get_current_rendering_method(), "driver": driver, "start_day": start,
		"command_log": COMMAND_LOG if _check_commands else [], "panel_clicks": _panel_feedback != null}))
	if rendered:
		RenderingServer.frame_post_draw.connect(_record_draw)
	_host.execute_gm_command("time.speed", {"value": speed})
	_clock.pause(false)
	var condition := await _capture(target, answer_story)
	if rendered:
		RenderingServer.frame_post_draw.disconnect(_record_draw)
	if require_rendered and _draw_count < 2 and condition in ["target", "player"]:
		condition = "missing_rendered_frames"
	if _check_commands and not _commands_settled():
		condition = "probe_command_receipt_mismatch"
	if _display_checks != null and condition == "target":
		condition = _display_checks.result()
	if _panel_feedback != null and not _panel_feedback.complete() and condition == "target":
		condition = "missing_panel_feedback"
	_clock.pause(true)
	_clock._runtime_calendar_admit = _admit_day
	_host.simulation_view_updated.disconnect(_record_view)
	for connection in ui_updates.get_connections():
		ui_updates.disconnect(connection.callable)
	for connection in ui_connections:
		ui_updates.connect(connection.callable, int(connection.flags))
	var contiguous := true
	for index in _day_rows.size():
		contiguous = contiguous and int(_day_rows[index].day) == maxi(0, start) + index + 1
	contiguous = contiguous and maxi(0, start) + _day_rows.size() == _host._runtime_commit_day
	var captured := _write(output, _frames) and _write(output + ".days", _day_rows)
	var countries := int(_host._country_worker_read_last_result.get("country_count", -1))
	print("HANDOFF_RESULT=", JSON.stringify({"end": condition, "display_day": _clock.day_index(),
		"consumed_day": _host._runtime_commit_day, "records": _day_rows.size(),
		"contiguous": contiguous, "frames": _frames.size(), "drawn_frames": _draw_count,
		"written": captured,
		"countries": countries,
		"answers": _answers, "last": _frames.back()}))
	var closed: Dictionary = await _host.close_world()
	quit(0 if captured and contiguous and countries == foreign_count + 1 and closed.get("ok", false)
		and condition in ["target", "player"] else 1)


func _start_player_scene(flow: Node, config: NewGameConfig) -> Dictionary:
	var previous_id := current_scene.get_instance_id() if current_scene != null else 0
	var failures: Array[Dictionary] = []
	var record := func(result: Dictionary) -> void: failures.append(result)
	flow.player_start_failed.connect(record, CONNECT_ONE_SHOT)
	var result: Dictionary = flow.begin_new_game(config)
	if result.get("ok", false):
		result = await _wait_for_player_scene(flow, previous_id, failures)
	if flow.player_start_failed.is_connected(record):
		flow.player_start_failed.disconnect(record)
	return result


func _wait_for_player_scene(flow: Node, previous_id: int, failures: Array[Dictionary]) -> Dictionary:
	while failures.is_empty():
		var arrived := current_scene is PlayerGame and current_scene.get_instance_id() != previous_id
		if arrived:
			var loading := _player_host()
			if loading == null:
				return {"ok": false, "code": "player_scene_host_missing"}
			var generation := loading.last_world_generation_error
			if not generation.is_empty():
				return {"ok": false, "code": "world_generation_failed", "stage": generation.get("stage", ""),
					"reason": generation.get("reason", ""), "message": generation.get("summary", "")}
			var session := loading.session_report()
			if session.state in ["FAULTED", "CLOSING", "CLOSED"]:
				return {"ok": false, "code": "startup_session_ended", "session": session}
			if loading.is_runtime_ready_for_ticks() and not flow.session().is_empty():
				return {"ok": true}
		elif not flow.player_scene_transition_active():
			return {"ok": false, "code": "player_scene_not_installed"}
		await process_frame
	return failures[0]


func _player_host() -> WorldRuntimeHost:
	return current_scene.get_node_or_null("RuntimeHost") as WorldRuntimeHost if current_scene is PlayerGame else null


func _record_start_failure(output: String, failure: Dictionary) -> void:
	var result := {"end": "startup_failed", "failure": failure, "frames": 0, "records": 0,
		"display": DisplayServer.get_name()}
	var frames_written := _write(output, [result])
	var days_written := _write(output + ".days", [])
	result["written"] = frames_written and days_written
	print("HANDOFF_RESULT=", JSON.stringify(result))


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


func _record_draw() -> void:
	var now := Time.get_ticks_usec()
	_draw_times.append(now)
	var committed := int(_generator.get_runtime_control_state().get("simulation_committed_day", -1))
	_draw_lag_days.append(maxi(0, committed - maxi(0, _host.presented_worker_day())))
	if _map_viewport != null:
		var map_draw_count := int(_map_viewport.get("draw_count"))
		var drawn = _camera.get("drawn_frame")
		if map_draw_count != _map_draw_count and drawn != null and drawn.valid:
			_map_draw_count = map_draw_count
			_map_draw_times.append(now)
			_map_draw_lag_days.append(maxi(0, committed - maxi(0, drawn.day)))
	if _panel_feedback != null and DisplayServer.window_can_draw():
		_panel_feedback.observe_draw(now)
	_draw_count += 1
	if _display_checks != null:
		_display_checks.check_draw(_host.presented_worker_day())


func _record_view(_from_day: int, _day: int, _generation: int) -> void:
	_view_updates += 1


func _commands_settled() -> bool:
	var received: Array = []
	for row: Dictionary in _day_rows:
		for receipt: Dictionary in row.receipts:
			if int(receipt.request_id) in [630001, 630002, 630003]:
				received.append([int(receipt.request_id), int(receipt.effective_day), int(row.day)])
	return received == [[630001, 2, 2], [630002, 2, 2], [630003, 5, 5]]


func _apply_overload(consumed: int) -> void:
	_overload_us = 0
	if _overload and consumed >= OVERLOAD_FIRST_DAY and consumed < OVERLOAD_END_DAY and Engine.max_fps > 0:
		# Occupy one full frame budget before the next gameplay _process callbacks.
		var started := Time.get_ticks_usec()
		var until := started + roundi(1_000_000.0 / Engine.max_fps)
		while Time.get_ticks_usec() < until:
			pass
		_overload_us = Time.get_ticks_usec() - started


func _capture(target: int, answer_story: bool) -> String:
	var previous_frame := Time.get_ticks_usec()
	var last_progress := previous_frame
	var previous_day := _host._runtime_commit_day
	var answered_offer := 0
	var window_drawable := DisplayServer.window_can_draw()
	while true:
		await process_frame
		if _simulate_frames:
			# Exercise the budget in the real player loop without a display driver.
			# No draw samples are recorded for this run.
			_host._presentation.observe_draw()
			_host._presentation.begin_frame()
		var now := Time.get_ticks_usec()
		var window_drawable_now := DisplayServer.window_can_draw()
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
		var frame := {"usec": now, "frame_usec": now - previous_frame, "draw_times": _draw_times,
			"window_drawable": window_drawable and window_drawable_now,
			"draw_lag_days": _draw_lag_days, "view_updates": _view_updates,
			"map_draw_times": _map_draw_times, "map_draw_lag_days": _map_draw_lag_days,
			"panel_feedback": _panel_feedback.take() if _panel_feedback != null else [],
			"presented": _host.presented_worker_day(), "effective_max_fps": Engine.max_fps,
			"overload_us": _overload_us,
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
			"admit_us": _admit_usec, "ui_us": _ui_usec,
			"visual_ms": _host._runtime_last_visual_apply_ms if _view_updates > 0 else 0.0,
			"writeback_ms": _host._runtime_climate_writeback_memcpy_ms + _host._runtime_climate_writeback_flush_ms,
			"host_ms": _host._sched_proc_last_total_ms}
		frame.merge(_timings.take())
		_frames.append(frame)
		_draw_times = []
		_draw_lag_days = []
		_map_draw_times = []
		_map_draw_lag_days = []
		_view_updates = 0
		_request = -1
		_admit_usec = 0
		_ui_usec = 0
		previous_frame = now
		window_drawable = window_drawable_now
		if consumed != previous_day:
			previous_day = consumed
			last_progress = now
		if reason in ["pause", "fault"]:
			return reason
		if _display_checks != null:
			_display_checks.step(consumed)
		elif reason != "player" and (_camera.position != _camera_center or _camera.zoom != _camera_zoom):
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
		if _panel_feedback != null:
			_panel_feedback.step(consumed, root)
		_apply_overload(consumed)
	return "unreachable"


func _write(path: String, rows: Array) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	for row in rows:
		file.store_line(JSON.stringify(row))
	file.close()
	return true
