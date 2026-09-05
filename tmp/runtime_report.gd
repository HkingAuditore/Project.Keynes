extends SceneTree
func _init() -> void:
	var ext := DCWorldExt.new()
	var s: Dictionary = ext.start_runtime_worker({"simulation_thread_mode":"SHADOW", "graph_coverage_complete":false, "day":0, "speed_days_per_second":0.0, "paused":true})
	print("start=", s)
	print("report=", ext.get_runtime_thread_report())
	ext.request_runtime_stop()
	OS.delay_msec(20)
	quit(0)
