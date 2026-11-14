# military_native_binding_test.gd
# Headless: godot --headless --path . -s res://tests/military/military_native_binding_test.gd
# Exercises the DCWorldExt military bindings without a full world: native
# self test, synthetic bench, and a PKMI round trip on an unconfigured core.
extends SceneTree

var _failures := 0


func _init() -> void:
	_run()
	quit(0 if _failures == 0 else 1)


func _expect(label: String, ok: bool, detail := "") -> void:
	print(("PASS " if ok else "FAIL ") + label + ("" if detail == "" else " :: " + detail))
	if not ok:
		_failures += 1


func _run() -> void:
	var ext = ClassDB.instantiate("DCWorldExt")
	if ext == null or not ext.has_method("runtime_military_self_test"):
		print("SKIP military bindings missing in loaded dots_ext")
		return
	var st: Dictionary = ext.runtime_military_self_test()
	_expect("native self test", bool(st.get("ok", false)), str(st.get("report", st)))
	if ext.has_method("run_military_bench"):
		var small: Dictionary = ext.run_military_bench({"cells": 2400, "armies": 400,
				"engagements": 64, "days": 60})
		print("bench small: ", small)
		_expect("bench small ran", bool(small.get("ok", false)))
		_expect("bench small p95 <= 0.5ms", float(small.get("p95_ms", 99.0)) <= 0.5,
				str(small.get("p95_ms", -1)))
		var big: Dictionary = ext.run_military_bench({"cells": 100000, "armies": 2048,
				"engagements": 4096, "days": 30})
		print("bench big: ", big)
		_expect("bench big ran", bool(big.get("ok", false)))
		_expect("bench big p95 <= 2ms", float(big.get("p95_ms", 99.0)) <= 2.0,
				str(big.get("p95_ms", -1)))
	if ext.has_method("get_military_report"):
		var rep: Dictionary = ext.get_military_report()
		_expect("report on unconfigured core is a dictionary", rep is Dictionary)
	if ext.has_method("military_should_run"):
		_expect("unconfigured core does no work", not bool(ext.military_should_run(1)))
