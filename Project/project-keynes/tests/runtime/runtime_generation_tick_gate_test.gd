extends SceneTree


var _failures := 0
var _generation_started := false
var _generation_failure := ""
const FRAME_LIMIT := 2400


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	root.size = Vector2i(1280, 720)
	var packed := load("res://scenes/player_game.tscn") as PackedScene
	var game := packed.instantiate()
	var runtime := game.get_node("RuntimeHost") as WorldRuntimeHost
	var clock := game.get_node("WorldClock") as WorldClock
	runtime.world_generation_started.connect(_on_world_generation_started.bind(runtime, clock))
	runtime.world_generation_failed.connect(func(reason: String): _generation_failure = reason)
	root.add_child(game)

	for _frame in range(FRAME_LIMIT):
		if runtime.is_runtime_ready_for_ticks() or not _generation_failure.is_empty():
			break
		await process_frame

	_expect("generation start boundary observed", _generation_started)
	_expect("runtime opens ticks after topology construction",
		runtime.is_runtime_ready_for_ticks())
	if runtime.is_runtime_ready_for_ticks():
		_expect("new game restores the pre-generation running state", not clock.paused)
		await _check_native_days(runtime, clock)
	else:
		print("generation_failure=", _generation_failure,
			" diagnostic=", JSON.stringify(runtime.last_world_generation_error))
	_expect("game closes after the native days", bool((await runtime.close_world()).get("ok", false)))
	game.queue_free()
	await process_frame
	_finish()


func _check_native_days(runtime: WorldRuntimeHost, clock: WorldClock) -> void:
	clock.set_process(false)
	var generator := runtime.get_generator()
	_expect("formal generation starts the whole graph", runtime._native_environment_active
		and runtime.runtime_authority_domain_mask == 0xfff)
	var report := generator.get_runtime_thread_report()
	var day := int(report.get("simulation_committed_day", 0)) + 1
	for expected in [day, day + 1]:
		clock.current_day = float(expected + 1)
		runtime._on_clock_day_changed(expected + 1)
		for _frame in range(FRAME_LIMIT):
			runtime._process(0.0)
			report = generator.get_runtime_thread_report()
			if runtime._runtime_commit_day >= expected or report.get("simulation_host_state") == "FAULTED":
				break
			await process_frame
		_expect("all species updates commit before the next tick on day %d" % expected,
			runtime._runtime_commit_day == expected
			and int(runtime._runtime_last_commit.get("committed_day", -1)) == expected
			and bool(runtime._runtime_last_commit.get("species_writeback", false)))
		if runtime._runtime_commit_day != expected:
			print("native_day_report=", JSON.stringify(report))
			break


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
	call_deferred("quit", _failures)
