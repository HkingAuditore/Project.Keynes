extends SceneTree

## M2 acceptance for the shared effect target selector.
##
## The selector itself (NativeEconomyRuntime::collect_effect_target_cells) reads
## per-cell columns that only exist once a real map_data has driven
## capture_building_context() through an epoch. Headless tests had zero cells,
## so every selector returned an empty array and nothing was actually verified.
##
## The heavy assertions live in economy_runtime_effect_selector_tests.cpp, which
## builds the grid snapshot by hand. This script is the thin GDScript entry point
## that proves the native self-check is wired up and passing. Individual
## assertion labels surface through printerr when the native side fails.

func _init() -> void:
	_run()
	quit(0 if _failures == 0 else 1)


var _checks := 0
var _failures := 0


func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		print("[SKIP] DCWorldExt unavailable")
		return
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	if ext == null:
		_expect("instantiate DCWorldExt", false)
		print("ideology target selector: %d checks, %d failures" % [_checks, _failures])
		return
	if not ext.has_method("runtime_economy_target_selector_self_test"):
		_expect("runtime_economy_target_selector_self_test bound", false,
			"method missing; rebuild the native library")
		print("ideology target selector: %d checks, %d failures" % [_checks, _failures])
		return
	_expect("runtime_economy_target_selector_self_test bound", true)

	# The native self-check covers: legacy anchor-only kinds, R1 membership,
	# R2 sorted/unique/capped, terrain component containment, resource component
	# containment, whole-grid predicate hit count, hop-limit exclusion, param0
	# fan-out cap for every kind, 100x determinism, and three degenerate
	# snapshots (missing neighbours, missing terrain column, out-of-range source).
	var ok: bool = bool(ext.runtime_economy_target_selector_self_test())
	_expect("native selector self-check", ok,
		"see printerr above for the failing assertion label")

	print("ideology target selector: %d checks, %d failures" % [_checks, _failures])


func _expect(label: String, condition: bool, detail: String = "") -> void:
	_checks += 1
	if condition:
		print("  [OK] %s" % label)
	else:
		_failures += 1
		if detail.is_empty():
			push_error("[FAIL] %s" % label)
		else:
			push_error("[FAIL] %s (%s)" % [label, detail])
