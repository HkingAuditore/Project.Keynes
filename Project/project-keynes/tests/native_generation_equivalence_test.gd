extends SceneTree

# Headless:
#   godot --headless --script tests/native_generation_equivalence_test.gd --quit
#
# NativeWorldGenerator API smoke test. This intentionally expects the current
# kernels-unimplemented failure so the test fails if native generation starts
# claiming success before equivalence fixtures are added.

var _checks: int = 0
var _failures: int = 0


func _init() -> void:
	_run()
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	print("=== native generation API smoke ===")
	if not ClassDB.class_exists("DCWorldExt"):
		_skip("DCWorldExt class not found")
		return
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	if ext == null:
		_skip("DCWorldExt instantiate returned null")
		return

	_expect("start_native_generation exported", ext.has_method("start_native_generation"))
	_expect("run_native_generation_slice exported", ext.has_method("run_native_generation_slice"))
	_expect("finish_native_generation exported", ext.has_method("finish_native_generation"))
	if not ext.has_method("start_native_generation"):
		_finish()
		return

	var start: Dictionary = ext.call("start_native_generation", 12345, {"cell_count": 64}, {"profile": "test"})
	_expect("generation start accepted", int(start.get("rc", -1)) == 0)
	_expect("generation reports unimplemented flag", not bool(start.get("implemented", true)))

	var step: Dictionary = ext.call("run_native_generation_slice", {"budget_ms": 0.25})
	_expect("generation slice fails explicitly", int(step.get("rc", 0)) == -1)
	_expect("generation fail stage explicit", str(step.get("fail_stage", "")) == "generation_kernels_unimplemented")

	var finish: Dictionary = ext.call("finish_native_generation")
	_expect("generation finish fails explicitly", int(finish.get("rc", 0)) == -1)
	_expect("generation progress remains zero", float(finish.get("generation_progress", -1.0)) == 0.0)
	_finish()


func _skip(reason: String) -> void:
	print("  [SKIP] %s" % reason)
	_finish()


func _finish() -> void:
	print("=== done: %d checks, %d failures ===" % [_checks, _failures])


func _expect(label: String, ok: bool) -> void:
	_checks += 1
	if ok:
		print("  [PASS] %s" % label)
	else:
		_failures += 1
		printerr("  [FAIL] %s" % label)
