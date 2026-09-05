extends SceneTree

func _init() -> void:
	var e := DCWorldExt.new()
	var s: Dictionary = e.start_runtime_worker({
		"simulation_thread_mode": "SHADOW",
		"graph_coverage_complete": false,
		"day": 0,
		"speed_days_per_second": 0.0,
		"paused": true,
	})
	print("start=", s)
	var r: Dictionary = e.get_runtime_thread_report()
	print("report=", r)
	print("implemented=", int(r.get("implemented_domain_mask", 0)), " missing=", int(r.get("missing_domain_mask", 0)), " auth=", bool(r.get("authority_ready", true)))
	e.request_runtime_stop()
	OS.delay_msec(30)
	quit(0)
