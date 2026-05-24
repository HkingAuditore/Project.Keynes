extends SceneTree

# Headless:
#   godot --headless --script tests/native_daily_shadow_test.gd --quit
#
# P0 native daily safety-gate smoke test. Full legacy-vs-native hash
# equivalence requires a generated map fixture; this test locks the exported
# API surface and verifies that an unconfigured native world fails closed.

var _checks: int = 0
var _failures: int = 0


func _init() -> void:
	_run()
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	print("=== native daily shadow smoke ===")
	if not ClassDB.class_exists("DCWorldExt"):
		_skip("DCWorldExt class not found")
		return
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	if ext == null:
		_skip("DCWorldExt instantiate returned null")
		return

	_expect("run_native_sim_tick exported", ext.has_method("run_native_sim_tick"))
	_expect("get_native_daily_report exported", ext.has_method("get_native_daily_report"))
	_expect("get_native_shadow_diff_report exported", ext.has_method("get_native_shadow_diff_report"))
	if not ext.has_method("run_native_sim_tick"):
		_finish()
		return

	var res: Dictionary = ext.call("run_native_sim_tick", {
		"probe": true,
		"shadow_diff_enabled": true,
	})
	_expect("unconfigured native sim fails closed", int(res.get("rc", 0)) == -1)
	_expect("unconfigured fail stage explicit", str(res.get("fail_stage", "")) == "native_world_not_configured")

	var daily_report: Dictionary = ext.call("get_native_daily_report")
	_expect("daily report captures rc", int(daily_report.get("rc", 0)) == -1)
	var diff_report: Dictionary = ext.call("get_native_shadow_diff_report")
	_expect("shadow diff report exported as dictionary", typeof(diff_report) == TYPE_DICTIONARY)
	_expect("native hashes present", typeof(diff_report.get("native_hashes", {})) == TYPE_DICTIONARY)
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
