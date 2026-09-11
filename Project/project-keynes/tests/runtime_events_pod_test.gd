extends SceneTree

var _checks := 0
var _failures := 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		_fail("DCWorldExt unavailable")
		_finish()
		return
	var ext := DCWorldExt.new()
	_expect("Events authority self-test is exported",
		 ext.has_method("runtime_events_authority_self_test"))
	if ext.has_method("runtime_events_authority_self_test"):
		_expect("Events APPEND/ACK/save/ring contract",
			bool(ext.runtime_events_authority_self_test()))

	var started: Dictionary = ext.start_runtime_worker({
		"simulation_thread_mode": "SHADOW",
		"graph_coverage_complete": false,
		"events_probe_enabled": true,
		"day": 0,
		"speed_days_per_second": 0.0,
		"paused": true,
	})
	_expect("Events SHADOW worker starts", bool(started.get("ok", false)))

	var report: Dictionary = ext.get_runtime_thread_report()
	var report_fields := [
		"events_probe_enabled", "events_pod_ready", "events_pod_plan_ms",
		"events_pod_replay_ms", "events_pod_state_hash",
		"events_pod_snapshot_generation", "events_pod_event_count",
		"events_pod_ack_count", "events_pod_drop_count",
		"events_pod_fallback_reason",
	]
	var report_complete := true
	for field in report_fields:
		report_complete = report_complete and report.has(field)
	_expect("Events report fields are complete", report_complete)
	_expect("Events remains outside ACTIVE authority mask",
		int(report.get("implemented_domain_mask", 0)) == 0x806)

	var empty_snapshot: Dictionary = ext.poll_runtime_events_snapshot(0)
	_expect("snapshot API is non-blocking before a generation",
		bool(empty_snapshot.get("ok", false))
		and not bool(empty_snapshot.get("available", false)))

	# Legacy ACK succeeds independently even when the best-effort bridge cannot
	# be consumed yet; the bridge result is diagnostic only.
	var first_ack: Dictionary = ext.ack_gameplay_events(&"events_test_a", 4)
	var second_ack: Dictionary = ext.ack_gameplay_events(&"events_test_b", 9)
	_expect("consumer A ACK is independent",
		int(first_ack.get("acked_event_id", -1)) == 4)
	_expect("consumer B ACK is independent",
		int(second_ack.get("acked_event_id", -1)) == 9)
	_expect("ACK bridge reports best-effort status",
		first_ack.has("events_bridge_failed") and first_ack.has("events_bridge_reason"))

	ext.request_runtime_stop()
	_finish()


func _expect(label: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_fail(label)


func _fail(label: String) -> void:
	_failures += 1
	push_error("[FAIL] %s" % label)


func _finish() -> void:
	print("=== runtime Events POD: %d checks, %d failures ===" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)
