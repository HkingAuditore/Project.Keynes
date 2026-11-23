extends SceneTree

const ResourceRequest = preload("res://scripts/game/loading_resource_request.gd")

class EconomyConfigureLog extends Logger:
	var failure := ""

	func _log_error(_function: String, _file: String, _line: int, code: String,
			_rationale: String, _editor_notify: bool, _error_type: int,
			_script_backtraces: Array[ScriptBacktrace]) -> void:
		if code.begins_with("[economy] configure failed:"):
			failure = code

var checks := 0
var failures := 0

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	await _check_player_loading_clock()
	# Exercise immediate exit and suspension in catalog/native/map/bake work.
	# These are sampling points, not deadlines or loading fallbacks.
	for frames in [0, 2, 5, 15, 40, 80]:
		await _close_loading_world(frames)
	await _close_during_catalog("effect_catalog")
	await _close_during_catalog("economy_catalog")
	await ResourceRequest.wait_for_pending(self)
	_expect("shutdown consumes each background resource request", ResourceRequest.pending_count == 0)
	print("runtime loading exit: %d checks, %d failures" % [checks, failures])
	call_deferred("quit", 0 if failures == 0 else 1)

func _check_player_loading_clock() -> void:
	var game := preload("res://scenes/player_game.tscn").instantiate()
	var clock := game.get_node("WorldClock") as WorldClock
	root.add_child(game)
	await process_frame
	await process_frame
	_expect("drawing the loading screen leaves the opening day at zero", clock.current_day == 0.0)
	var host := game.get_node("RuntimeHost") as WorldRuntimeHost
	await host.close_world()
	game.queue_free()
	await process_frame

func _close_loading_world(frames: int) -> void:
	var host := WorldRuntimeHost.new()
	root.add_child(host)
	host.configure(null, null, null)
	host.generate_world(20260718)
	for _frame in frames:
		await process_frame
	var generator = host.get_generator()
	_expect("generation started before exit at frame %d" % frames, generator != null)
	var released: WeakRef = weakref(generator)
	generator = null
	host.free()
	await process_frame
	_expect("exit releases loading world at frame %d" % frames, released.get_ref() == null)

func _close_during_catalog(stage: String) -> void:
	# Cancel in the actual compiler, independent of how long map baking takes.
	LoadingCatalogCache.invalidate()
	var host := WorldRuntimeHost.new()
	root.add_child(host)
	host.configure(null, null, null)
	host.generate_world(20260718)
	var generator = host.get_generator()
	while host._runtime_session.is_preparing() and generator._loading_step_name != stage:
		await process_frame
	if generator._loading_step_name != stage or not generator.has_meta(&"loading_catalog_context"):
		_expect("loading reaches " + stage, false)
		host.free()
		return
	var context = generator.get_meta(&"loading_catalog_context")
	var released_generator: WeakRef = weakref(generator)
	var released_context: WeakRef = weakref(context)
	generator = null
	context = null
	var log := EconomyConfigureLog.new()
	OS.add_logger(log)
	host.free()
	await process_frame
	OS.remove_logger(log)
	_expect(stage + " exit releases loading world", released_generator.get_ref() == null)
	_expect(stage + " exit releases request context", released_context.get_ref() == null)
	_expect(stage + " exit does not report a configuration failure: " + log.failure, log.failure.is_empty())

func _expect(label: String, condition: bool) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("[FAIL] " + label)
