extends SceneTree

## Production scene + ACTIVE worker + real native growth/construction/read views.
## No manual play_activity/observe_development or synthetic commit signals.
var _failures := 0
var _seen: Dictionary = {}
var _cell := -1
var _commits := 0
var _capture_dir := ""
var _captures: Dictionary = {}

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("capture_dir="):
			_capture_dir = argument.trim_prefix("capture_dir=")
	root.size = Vector2i(1280, 720)
	var config := NewGameConfig.create_default()
	config.base.map_width = 40
	config.base.map_height = 28
	config.base.initial_seed = 1
	config.country.foreign_count = 0
	# Set up a test request without starting a second scene transition.
	root.get_node("GameFlow").set("_pending_request", {
		"kind": "new_game", "config": config.to_dictionary()})
	var game: Node = load("res://scenes/player_game.tscn").instantiate()
	var host: WorldRuntimeHost = game.get_node("RuntimeHost")
	host.simulation_committed.connect(func(_from: int, _to: int, _generation: int) -> void:
		_commits += 1)
	root.add_child(game)
	await host.world_ready
	for i in 4:
		await process_frame
	var clock: WorldClock = game.get_node("WorldClock")
	clock.pause(true)
	var player = game.get_node("PlayerController")
	var activity = game.get_node("WorldRoot/MapActivityLayer")
	var generator = host.get("_generator")
	var start: Dictionary = generator.gameplay_start_report()
	_cell = int(start.get("cell", -1))
	_expect("formal player start exists", _cell >= 0)
	if _cell < 0:
		_finish(game)
		return
	var cell := host.current_map().cell_at(_cell)
	player.select_cell(cell)
	var camera: MapCamera = game.get_node("MapCamera")
	camera.restore_view_state(HexUtils.cube_to_world(cell.q, cell.r, host.hex_size), Vector2(0.65, 0.65))
	camera.force_update_scroll()
	activity.activity_started.connect(func(index: int, kind: StringName, caption: String) -> void:
		if index == _cell:
			_seen[kind] = caption
			print("[native-map-activity] ", kind, " ", caption)
			if not _capture_dir.is_empty() and not _captures.has(kind):
				_captures[kind] = false
				_capture.call_deferred(kind))
	# Let the actual observer establish its baseline at normal game zoom.
	# A newly started ACTIVE worker may not have published its first population
	# read view yet; let the real first day run rather than requiring a paused
	# worker to synthesize one.
	clock.set_speed(10.0)
	var baseline_deadline := Time.get_ticks_msec() + 8000
	while not activity._history.has(_cell) and Time.get_ticks_msec() < baseline_deadline:
		await create_timer(0.05).timeout
	_expect("real selected settlement is observed at normal zoom", activity._history.has(_cell))
	# Let the same starter settlement grow and build through the production
	# economy. This does not depend on GM/legacy ingress or inject fake events.
	clock.set_speed(50.0)
	await _wait_for_kind(&"growth", 20.0)
	_expect("ACTIVE native population commit starts visible growth effect", _seen.has(&"growth"))
	await _wait_for_kind(&"build", 20.0)
	_expect("native installed-building publication starts completion effect", _seen.has(&"build"))
	_expect("formal worker published real commit notifications", _commits > 0)
	clock.pause(true)
	if not _capture_dir.is_empty():
		await create_timer(0.5).timeout
	_finish(game)

func _capture(kind: StringName) -> void:
	if DisplayServer.get_name() == "headless":
		return
	await create_timer(0.3).timeout
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute(_capture_dir)
	var path := _capture_dir.path_join(String(kind) + ".png")
	root.get_texture().get_image().save_png(path)
	_captures[kind] = true
	print("[native-map-activity] saved ", path)

func _wait_for_kind(kind: StringName, seconds: float) -> void:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while not _seen.has(kind) and Time.get_ticks_msec() < deadline:
		await create_timer(0.05).timeout

func _expect(label: String, passed: bool) -> void:
	print("[%s] %s" % ["PASS" if passed else "FAIL", label])
	if not passed:
		_failures += 1

func _finish(game: Node) -> void:
	print("=== native map activity integration: %d failures ===" % _failures)
	game.queue_free()
	await process_frame
	quit(0 if _failures == 0 else 1)
