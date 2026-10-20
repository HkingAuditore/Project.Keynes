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
