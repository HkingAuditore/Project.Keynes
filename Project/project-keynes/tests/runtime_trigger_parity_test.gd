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
	# H8: TRIGGER is inside the implemented mask now. Implemented is
	# CLIMATE|COUNTRY|TRIGGER|IDEOLOGY|EFFECT|MODIFIER|ECONOMY|EVENTS|COMMIT = 0xB7E.
	# Whole-graph ACTIVE is still refused because required is 0xFFF, so
	# missing_domain_mask stays 0x581 and authority_ready stays false.
	var started: Dictionary = ext.start_runtime_worker({
		"simulation_thread_mode": "SHADOW",
		"graph_coverage_complete": false,
		"day": 0,
		"speed_days_per_second": 0.0,
		"paused": true,
	})
	var report: Dictionary = ext.get_runtime_thread_report()
	var ok := bool(started.get("ok", false)) and int(report.get("implemented_domain_mask", 0)) == 0xB7E \
		and int(report.get("missing_domain_mask", 0)) == 0x581 \
		and not bool(report.get("authority_ready", true))
	ext.request_runtime_stop()
	if not ok:
		push_error("Trigger SHADOW parity/whole-graph refusal contract failed")
		quit(1)
		return

	# H8: a per-domain ACTIVE request that includes TRIGGER must now be admitted.
	# The grant itself only lands after a barrier day, which this static fixture
	# does not run; what is under test is that the protocol guard no longer
	# refuses the request. A fresh instance avoids racing the async stop above.
	var active_ext := DCWorldExt.new()
	var active: Dictionary = active_ext.start_runtime_worker({
		"simulation_thread_mode": "ACTIVE",
		"graph_coverage_complete": true,
		"authoritative_domain_mask": 0xB7E,
		"day": 0,
		"speed_days_per_second": 0.0,
		"paused": true,
	})
	var active_report: Dictionary = active_ext.get_runtime_thread_report()
	var active_ok := bool(active.get("ok", false)) \
		and (int(active_report.get("requested_authority_mask", 0)) & 0x008) != 0
	active_ext.request_runtime_stop()
	if not active_ok:
		push_error("Trigger ACTIVE request refused: %s" % [
			String(active.get("code", "unknown"))])
	quit(0 if active_ok else 1)
