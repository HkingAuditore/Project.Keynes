extends SceneTree

const Reference = preload("res://tests/game/world_runtime_lifecycle_reference.gd")
var checks := 0
var failures := 0

func _check(label: String, condition: bool) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("[FAIL] %s" % label)

func _init() -> void:
	var host := FileAccess.get_file_as_string("res://scripts/game/world_runtime_host.gd")
	var lifecycle := FileAccess.get_file_as_string("res://scripts/game/world_runtime_lifecycle.gd")
	for method in Reference.HOST_METHODS:
		_check("host keeps " + method, host.contains(method))
	for method in Reference.LIFECYCLE_METHODS:
		_check("lifecycle owns " + method, lifecycle.contains(method))
	_check("host delegates close", host.contains("return await _lifecycle.close_world(self)"))
	_check("stop precedes world release", lifecycle.find("await host._stop_previous_runtime_worker()") < lifecycle.find("host._current_map = null"))
	_check("presentation release detaches renderer", lifecycle.contains("host._renderer.set_world_ext(null)"))
	_check("web fallback source untouched", host.contains("runtime_web_allow_gdscript_daily_fallback"))
	print("world runtime lifecycle: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)
