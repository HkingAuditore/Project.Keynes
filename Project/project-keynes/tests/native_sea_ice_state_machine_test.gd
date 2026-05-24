extends SceneTree

# Headless:
#   godot --headless --script tests/native_sea_ice_state_machine_test.gd --quit
#
# P0 sea-ice native handoff smoke test. Detailed deterministic terrain-flip
# equivalence should be added once a compact MapData fixture is available.

var _checks: int = 0
var _failures: int = 0


func _init() -> void:
	_run()
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	print("=== native sea ice state-machine smoke ===")
	if not ClassDB.class_exists("DCWorldExt"):
		_skip("DCWorldExt class not found")
		return
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	if ext == null:
		_skip("DCWorldExt instantiate returned null")
		return

	_expect("run_sea_ice_daily_pass exported", ext.has_method("run_sea_ice_daily_pass"))
	_expect("run_native_sim_tick exported", ext.has_method("run_native_sim_tick"))
	_expect("get_native_dirty_report exported", ext.has_method("get_native_dirty_report"))
	var dirty_report: Dictionary = ext.call("get_native_dirty_report") if ext.has_method("get_native_dirty_report") else {}
	_expect("dirty report is dictionary", typeof(dirty_report) == TYPE_DICTIONARY)
	var res: Dictionary = ext.call("run_native_sim_tick", {
		"probe": true,
		"native_daily_bundle": {
			"use_system_schedule": true,
			"sea_ice_knobs": {
				"apply_terrain_flips": true,
			},
		},
		"required_pass_keys": ["sea_ice_knobs"],
	}) if ext.has_method("run_native_sim_tick") else {}
	_expect("unconfigured sea ice native tick does not mutate", int(res.get("rc", 0)) == -1)
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
