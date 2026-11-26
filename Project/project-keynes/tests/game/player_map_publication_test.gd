extends "res://tests/game/player_scene_handoff_probe.gd"

## Leaves the formal clock and publication reader running while busy frames
## prevent the map from using the time left in the frame.
const WAITING_DAY := 20
const STORY_EVENT := "evt.citychain.wall"
const TEST_SPEED := 5.0
const TEST_FPS := 60

class MapPublicationLog extends Logger:
	var errors: Array[String] = []

	func _log_error(_function: String, _file: String, _line: int, code: String,
			_rationale: String, _editor_notify: bool, error_type: int,
			_script_backtraces: Array[ScriptBacktrace]) -> void:
		if error_type == Logger.ERROR_TYPE_ERROR and code.begins_with("[worker-map]"):
			errors.append(code)

var _hold_map := false
var _failures: Array[String] = []
var _ui_days: Array[int] = []
var _texture_days: Array[int] = []
var _receipt_frame := -1
var _calendar_limit := 0


func _run() -> void:
	if OS.get_environment("PK_SAVE_DIR").is_empty():
		printerr("Set PK_SAVE_DIR to an isolated directory for the map publication test")
		quit(1)
		return
	root.get_node("GameSettings").update({"frame_rate_limit": TEST_FPS, "graphics_custom": true,
		"autosave_enabled": false, "ai_narrative_enabled": false, "event_pause_mask": 255}, false)
	var config := NewGameConfig.new()
	config.apply_land_layout(NewGameConfig.DEFAULT_LAND_LAYOUT)
	config.base.map_width = WIDTH
	config.base.map_height = HEIGHT
	config.base.initial_seed = SEED
	config.country.foreign_count = 3
	node_added.connect(_install_story_fixture)
	var normal := await _play_to_wait(config, false)
	var held := await _play_to_wait(config, true)
	node_added.disconnect(_install_story_fixture)
	_check(not normal.is_empty() and not held.is_empty() and normal == held,
		"daily outcomes, ordered receipts, and final map bytes match with and without the hold")
	if not held.is_empty():
		await _check_load_discards_pending_map()
	if is_instance_valid(_host):
		_check(bool((await _host.close_world()).get("ok", false)), "formal world closes")
	for failure in _failures:
		printerr(failure)
	print("PLAYER_MAP_PUBLICATION=", JSON.stringify({"failures": _failures,
		"compared_days": normal.get("records", []).size(), "display": DisplayServer.get_name()}))
	quit(0 if _failures.is_empty() else 1)


func _play_to_wait(config: NewGameConfig, hold: bool) -> Dictionary:
	var old_map: MapData = _host.current_map() if is_instance_valid(_host) else null
	var old_ext = _generator.get_data_core_world_ext() if old_map != null else null
	var old_generation := _host._runtime_commit_generation if old_map != null else 0
	var start := await _start_player_scene(root.get_node("GameFlow"), config)
	_check(bool(start.get("ok", false)), "starts through GameFlow")
	if not start.get("ok", false):
		return {}
	_attach_scene()
	if old_ext != null:
		_check(old_ext.read_runtime_map_lut_frame(old_map, WAITING_DAY, old_generation,
			old_map.cell_count()) == {"reason": "map_lut_publication_unavailable"},
			"new game discards the old map publication")
	var ext = _generator.get_data_core_world_ext()
	_check(_host.received_worker_day() <= 0 and Engine.max_fps == TEST_FPS and _clock.is_processing(),
		"starts at day zero at 60 fps with the formal clock processing")
	for command: Dictionary in COMMAND_LOG:
		var admission: Dictionary = ext.submit_runtime_command(command)
		_check(admission.get("ok", false) and admission.get("effective_day") == command.requested_day,
			"admits the same command log before day one")
	_host.publication_reader.interval_usec = 100_000
	process_frame.connect(_occupy_busy_frame)
	# Keep the daily comparison exact in both runs. The clock still requests
	# each day through the same host callback.
	_admit_day = _clock._runtime_calendar_admit
	_clock.bind_runtime_calendar(_admit_fixture_day)
	_clock.set_speed(TEST_SPEED)
	var opening: Array = []
	var copies := 0
	for day in range(1, WAITING_DAY + 1):
		var map_day: int = -1 if _hold_map else day
		_calendar_limit = day + 1 if day == WAITING_DAY else day
		if not await _wait_for_runtime_day(day, map_day, _calendar_limit):
			_clock.pause(true)
			_clock.bind_runtime_calendar(_admit_day)
			process_frame.disconnect(_occupy_busy_frame)
			return {}
		var sample := _timings.take()
		var expected := 0 if _hold_map else 1
		_check(_host.received_worker_day() == day and sample.received_batches == 1
			and sample.map_copies.size() == expected and (expected == 0 or sample.map_copies[0].day == day),
			"day %d delivers records and performs %d map copies" % [day, expected])
		_check(not _ui_days.is_empty() and _ui_days.back() == day, "UI publishes day %d" % day)
		copies += sample.map_copies.size()
		if day == 1:
			opening = _atlas()
			_hold_map = hold
		if _hold_map:
			_check(_atlas() == opening and _texture_days == [1],
				"day %d leaves the map at its last published textures" % day)
	var control := _generator.get_runtime_control_state()
	var offer: Dictionary = _controller.narrative_service().active_offer()
	_check(not _clock.paused and _host._calendar_admitted_through > WAITING_DAY
		and control.get("simulation_committed_day") == WAITING_DAY
		and control.get("player_block_day") == WAITING_DAY
		and control.get("player_block_reason") == "narrative_choice_required"
		and _host.player_confirmation_view().get("reason") == "narrative_choice_required"
		and offer.get("event_id") == STORY_EVENT, "worker and player scene reach the same story choice")
	_check(_commands_settled() and _day_rows.size() == WAITING_DAY,
		"receives all days and the ordered command receipts through the wait")
	var generation := _host._runtime_commit_generation
	_clock.pause(true)
	_clock.bind_runtime_calendar(_admit_day)
	var finished := true
	if hold:
		# The pending frame survives a replacement executor, even before its first new day.
		var restarted := bool(_host.restart_runtime_executor().get("ok", false))
		_check(restarted, "restarter accepts paused world")
		_hold_map = false
		finished = restarted and await _wait_for_runtime_day(WAITING_DAY, WAITING_DAY)
		var recovered: Array = _timings.take().map_copies
		_check(recovered.size() == 1 and recovered[0].day == WAITING_DAY
			and recovered[0].bytes == 2 * WIDTH * HEIGHT and _texture_days == [1, WAITING_DAY],
			"paused recovery reads and publishes the latest full map exactly once")
	process_frame.disconnect(_occupy_busy_frame)
	if not finished:
		return {}
	_check(_host.received_worker_day() == WAITING_DAY and _clock.paused,
		"map recovery does not release another simulation day")
	_check_identity_rejection(ext, generation)
	if hold:
		_check_failed_map_publication(generation)
	var records: Array = []
	for row: Dictionary in _day_rows:
		records.append([row.day, row.business_hash, row.receipts])
	var atlas := _atlas()
	_check(atlas.size() == 4 and atlas.all(func(bytes: PackedByteArray): return bytes.size() >= 4 * WIDTH * HEIGHT)
		and atlas != opening, "the map produced complete, updated atlas bytes")
	print("MAP_READ_PHASE=", JSON.stringify({"held": hold, "copies_before_recovery": copies,
		"texture_days": _texture_days, "ui_days": _ui_days, "player_day": control.get("player_block_day")}))
	return {"records": records, "atlas": atlas, "offer": offer.get("event_id")}


func _install_story_fixture(node: Node) -> void:
	if not node is PlayerGame:
		return
	# Schedule the choice before the scene starts its executor so changes to
	# the live narrative odds do not move the test's confirmation boundary.
	var host: WorldRuntimeHost = node.get_node("RuntimeHost")
	var fixture := preload("res://scripts/game/runtime_session_module.gd").new()
	fixture.configure("map_publication_story", ["restore"], [], func() -> Dictionary:
		return host.get_generator().get_gameplay_event_bus().restore_story({
			"event_pause_mask": 255,
			"scheduled_events": [{"due_day": WAITING_DAY, "event_id": STORY_EVENT}],
		}), host._session_noop, host._session_ok)
	_check(bool(host.register_session_module(fixture).get("ok", false)),
		"registers a scheduled story before the executor starts")


func _attach_scene() -> void:
	var scene := current_scene as PlayerGame
	_host = scene.get_node("RuntimeHost")
	_generator = _host.get_generator()
	_clock = scene.get_node("WorldClock")
	_controller = scene.get_node("PlayerController")
	if DisplayServer.get_name() == "headless":
		# Headless sessions normally skip frame timing. Connect the same frame
		# start callback as a windowed session before injecting the busy work.
		_host._connect_presentation_frames()
	_hold_map = false
	_ui_days.clear()
	_texture_days.clear()
	_day_rows.clear()
	_receipt_frame = -1
	_timings = FrameTimings.new()
	_timings.attach(_host)
	_host.simulation_day_records.connect(_record_days)
	_host.simulation_ui_updated.connect(func(_from, day, _generation):
		_ui_days.append(day)
		_check(_receipt_frame == Engine.get_process_frames(), "UI publishes day %d on the receipt frame" % day))
	_host.map_texture_published.connect(func(day): _texture_days.append(day))


func _record_days(records: Array) -> void:
	super(records)
	_receipt_frame = Engine.get_process_frames()


func _admit_fixture_day(date: int) -> int:
	return int(_admit_day.call(mini(date, _calendar_limit + 1)))


func _wait_for_runtime_day(day: int, map_day: int = -1, admitted_through: int = -1) -> bool:
	var started := Time.get_ticks_usec()
	while true:
		# Frames run the WorldClock and RuntimeHost receive callback. Wait for
		# the worker's commit as well as the records delivered by that callback.
		var control := _generator.get_runtime_control_state()
		var committed := int(control.get("simulation_committed_day", -1))
		var received := _host.received_worker_day()
		var recorded := int(_day_rows.back().day) if not _day_rows.is_empty() else -1
		var published := int(_texture_days.back()) if not _texture_days.is_empty() else -1
		var admitted := _host._calendar_admitted_through
		if _host.is_runtime_fault_paused() or control.get("simulation_host_state") == "FAULTED":
			_check(false, "runtime fault waiting for day %d: %s" % [day, _host.get_runtime_fault_diagnostics()])
			return false
		if committed >= day and received >= day and recorded >= day \
				and published >= map_day and admitted >= admitted_through:
			return true
		if Time.get_ticks_usec() - started >= WATCHDOG_USEC:
			_check(false, "waiting for day %d timed out: committed=%d received=%d recorded=%d map=%d admitted=%d" % [
				day, committed, received, recorded, published, admitted])
			return false
		await process_frame
	return false


func _occupy_busy_frame() -> void:
	if _hold_map and is_instance_valid(_host) and _host.is_runtime_ready_for_ticks():
		OS.delay_usec(roundi(1_000_000.0 / TEST_FPS))


func _atlas() -> Array:
	var baker: MapBaker = _generator._baker
	return [baker._cell_enum_lut_bytes_cache, baker._cell_dyn_lut_bytes_cache,
		baker._cell_eco_lut_bytes_cache, baker._prev_weather_lut_bytes]


func _check_identity_rejection(ext, generation: int) -> void:
	var map := _host.current_map()
	var day := _host.received_worker_day()
	var count := map.cell_count()
	var wrong_map := MapData.new(WIDTH, HEIGHT)
	for request in [[wrong_map, day, generation, count, "map_lut_map_mismatch"],
			[map, day - 1, generation, count, "map_lut_day_mismatch"],
			[map, day, generation + 1, count, "map_lut_generation_mismatch"],
			[map, day, generation, count - 1, "map_lut_cell_count_mismatch"]]:
		var frame: Dictionary = ext.read_runtime_map_lut_frame(request[0], request[1], request[2], request[3])
		_check(frame == {"reason": request[4]}, "native reader reports %s with no texture data" % request[4])


func _check_failed_map_publication(generation: int) -> void:
	var day := _host.received_worker_day()
	var atlas := _atlas()
	var texture_days := _texture_days.duplicate()
	var log := MapPublicationLog.new()
	OS.add_logger(log)
	var published := _host._publish_worker_map({"map_lut_day": day,
		"map_lut_generation": generation + 1}, day, Time.get_ticks_usec())
	OS.remove_logger(log)
	_check(not published and _atlas() == atlas and _texture_days == texture_days,
		"a failed map read leaves the last textures published")
	_check(log.errors == ["[worker-map] Day %d publication failed: map_lut_generation_mismatch" % day],
		"a failed deferred read logs the day and the rejected generation check")


func _check_load_discards_pending_map() -> void:
	var offer: Dictionary = _controller.narrative_service().active_offer()
	_hold_map = true
	process_frame.connect(_occupy_busy_frame)
	# The choice can release a day before the next process_frame callback.
	_occupy_busy_frame()
	var flow = _controller.narrative_flow()
	flow.on_outcome_acknowledged()
	var receipt: Dictionary = flow.on_option_chosen(int(offer.offer_id), int(offer.offer_generation), 0)
	_check(receipt.get("ok", false) and int(receipt.effective_day) == WAITING_DAY + 1,
		"player answer is admitted for the next day")
	_clock.pause(false)
	var next_day := WAITING_DAY + 1
	var arrived := await _wait_for_runtime_day(next_day)
	_clock.pause(true)
	if arrived:
		_check(_host.received_worker_day() == next_day, "only the answered day was delivered before save")
		await _save_and_reload_pending_map(next_day)
	process_frame.disconnect(_occupy_busy_frame)


func _save_and_reload_pending_map(day: int) -> void:
	_check(_host._presentation._map_updates.has_pending(),
		"the next day has staged map data before save")
	var save: Dictionary = await root.get_node("GameSave").request_manual_save("manual_1")
	_check(save.get("ok", false), "save succeeds while map data is held")
	if not save.get("ok", false):
		return
	var pending: bool = _host._presentation._map_updates.has_pending()
	var copies: Array = _timings.take().map_copies
	_check(pending and copies.is_empty(),
		"save leaves the unneeded map copy pending (pending=%s, copies=%s)" % [pending, copies])
	var old_map := _host.current_map()
	var old_ext = _generator.get_data_core_world_ext()
	var generation := _host._runtime_commit_generation
	var previous_id := current_scene.get_instance_id()
	var game_flow := root.get_node("GameFlow")
	var failures: Array[Dictionary] = []
	var failed := func(info): failures.append(info)
	game_flow.player_start_failed.connect(failed)
	var loaded: Dictionary = game_flow.begin_load_game("manual_1")
	if loaded.get("ok", false):
		loaded = await _wait_for_player_scene(game_flow, previous_id, failures)
	game_flow.player_start_failed.disconnect(failed)
	_check(loaded.get("ok", false), "reopens the save through GameFlow")
	if not loaded.get("ok", false):
		return
	_attach_scene()
	_check(_host.current_map() != old_map and _host.received_worker_day() == day
		and not _host._presentation._map_updates.has_pending()
		and old_ext.read_runtime_map_lut_frame(old_map, day, generation, old_map.cell_count())
			== {"reason": "map_lut_publication_unavailable"},
		"load restores the saved date and discards the previous scene's pending map")


func _check(condition: bool, label: String) -> void:
	if not condition:
		_failures.append(label)
