extends SceneTree


func _init() -> void:
	var console := DebugConsole.new()
	var formatted: String = console.call("_format_ms_fields", {
		"elapsed_ms": 2.5,
		"building_commit_breakdown_ms": {
			"building_commit.investment": 1.25,
		},
	})
	var passed := formatted.contains("elapsed=2.5") and \
		not formatted.contains("building_commit_breakdown")
	print("[debug-console-format] %s: %s" % ["PASS" if passed else "FAIL", formatted])
	console.free()
	quit(0 if passed else 1)
