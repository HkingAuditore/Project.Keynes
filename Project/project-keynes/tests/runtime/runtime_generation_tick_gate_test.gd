extends SceneTree


var _failures := 0
var _generation_started := false


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	root.size = Vector2i(1280, 720)
	var packed := load("res://scenes/player_game.tscn") as PackedScene
	var game := packed.instantiate()
	var runtime := game.get_node("RuntimeHost") as WorldRuntimeHost
	var clock := game.get_node("WorldClock") as WorldClock
	runtime.world_generation_started.connect(_on_world_generation_started.bind(runtime, clock))
	root.add_child(game)

	for _frame in range(2400):
		if runtime.is_runtime_ready_for_ticks():
			break
		await process_frame

	_expect("generation start boundary observed", _generation_started)
	_expect("runtime opens ticks after topology construction",
		runtime.is_runtime_ready_for_ticks())
	_expect("new game restores the pre-generation running state", not clock.paused)
	clock.set_process(false)
	var generator := runtime.get_generator()
	var bio = generator._bio_occupancy_daily_job
	_expect("the generated map has a daily species update", bio != null)
	if bio != null:
		bio.execution_mode = "sliced"
		var day := clock.day_index() + 1
		runtime.run_daily_tick(day, clock.season_phase_for_day(day))
		runtime.finish_daily_tick(0.0, {})
		_expect("manual day uses the sliced species update", bio.slice_enabled)
		_expect("all species updates finish before the next manual day",
			not generator.bio_occupancy_round_active())
		clock.pause(true)
		clock.set_process(true)
		runtime.run_daily_tick(day + 1, clock.season_phase_for_day(day + 1))
		runtime.finish_daily_tick(0.0, {})
		_expect("manual steps also finish while the frame clock is paused",
			not generator.bio_occupancy_round_active())
	game.queue_free()
	await process_frame
	_finish()


func _on_world_generation_started(runtime: WorldRuntimeHost, clock: WorldClock) -> void:
	_generation_started = true
	_expect("generation closes the daily tick boundary",
		not runtime.is_runtime_ready_for_ticks())
	_expect("generation pauses the world clock", clock.paused)
	_expect("closed tick boundary has no scheduler side effects",
		runtime.run_daily_tick(1, 0.0).is_empty())


func _expect(label: String, condition: bool) -> void:
	if condition:
		print("[runtime-generation-tick-gate] PASS: %s" % label)
		return
	_failures += 1
	push_error("[runtime-generation-tick-gate] FAIL: %s" % label)


func _finish() -> void:
	print("[runtime-generation-tick-gate] completed with %d failure(s)" % _failures)
	quit(_failures)
