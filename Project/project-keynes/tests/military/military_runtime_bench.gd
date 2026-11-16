# military_runtime_bench.gd
# Headless report:
#   godot --headless --path . -s res://tests/military/military_runtime_bench.gd
# Runs DCWorldExt.run_military_bench on the two contract scenarios (§5) and
# prints avg/p95/max plus every counter the bench returns. Always exits 0: this
# is a report; PASS/FAIL lines compare p95 against the 0.5 ms / 2 ms budgets.
extends SceneTree

const SCENARIOS := [
	{"label": "standard", "cells": 2400, "armies": 400, "engagements": 64,
		"days": 60, "budget_p95_ms": 0.5},
	{"label": "synthetic_100k", "cells": 100000, "armies": 2048,
		"engagements": 4096, "days": 30, "budget_p95_ms": 2.0},
]


func _init() -> void:
	_run()
	quit(0)


func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		print("SKIP DCWorldExt unavailable")
		return
	var ext = ClassDB.instantiate("DCWorldExt")
	if ext == null or not ext.has_method("run_military_bench"):
		print("SKIP run_military_bench missing in loaded dots_ext")
		return
	var passed := 0
	for scenario in SCENARIOS:
		var cfg := {"cells": scenario.cells, "armies": scenario.armies,
			"engagements": scenario.engagements, "days": scenario.days}
		var started := Time.get_ticks_usec()
		var result: Dictionary = ext.run_military_bench(cfg)
		var wall_ms := float(Time.get_ticks_usec() - started) / 1000.0
		var p95 := float(result.get("p95_ms", INF))
		var budget := float(scenario.budget_p95_ms)
		var ok := bool(result.get("ok", false)) and p95 <= budget
		if ok:
			passed += 1
		print("[military-bench] %s cells=%d armies=%d engagements=%d days=%d avg_ms=%.4f p95_ms=%.4f max_ms=%.4f wall_ms=%.1f ok=%s" % [
			scenario.label, int(result.get("cells", scenario.cells)),
			int(result.get("armies", scenario.armies)),
			int(result.get("engagements", scenario.engagements)),
			int(result.get("days", scenario.days)),
			float(result.get("avg_ms", -1.0)), p95, float(result.get("max_ms", -1.0)),
			wall_ms, str(result.get("ok", false))])
		var extra := PackedStringArray()
		for key in result.keys():
			if String(key) in ["ok", "cells", "armies", "engagements", "days",
					"avg_ms", "p95_ms", "max_ms"]:
				continue
			extra.append("%s=%s" % [String(key), str(result[key])])
		if not extra.is_empty():
			print("[military-bench] %s counters: %s" % [scenario.label, " ".join(extra)])
		print("%s %s p95 %.4f ms <= %.1f ms" % ["PASS" if ok else "FAIL",
			scenario.label, p95, budget])
	print("[military-bench] %d/%d scenarios within budget" % [passed, SCENARIOS.size()])
