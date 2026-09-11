extends SceneTree

func _init() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		push_error("DCWorldExt unavailable")
		quit(1)
		return
	var ext := DCWorldExt.new()
	if not ext.has_method("runtime_trigger_pod_self_test") or not bool(ext.runtime_trigger_pod_self_test()):
		push_error("Trigger POD parity kernel unavailable")
		quit(1)
		return
	# Stage H remains SHADOW: the protocol guard must continue refusing ACTIVE
	# Trigger authority. Implemented is Climate|Country|COMMIT = 0x806 after D12.
	var started: Dictionary = ext.start_runtime_worker({
		"simulation_thread_mode": "SHADOW",
		"graph_coverage_complete": false,
		"day": 0,
		"speed_days_per_second": 0.0,
		"paused": true,
	})
	var report: Dictionary = ext.get_runtime_thread_report()
	var ok := bool(started.get("ok", false)) and int(report.get("implemented_domain_mask", 0)) == 0x806 \
		and int(report.get("missing_domain_mask", 0)) == 0x7F9 \
		and not bool(report.get("authority_ready", true))
	ext.request_runtime_stop()
	if not ok:
		push_error("Trigger SHADOW parity/ACTIVE refusal contract failed")
	quit(0 if ok else 1)
