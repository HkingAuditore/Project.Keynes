extends SceneTree

# Soft Economy SHADOW/ACTIVE wiring check for Phase 2-6.
# Production implemented mask is 0xB7E (includes ECONOMY). ACTIVE production
# advances via Host attach_economy_production_runtime + worker_run_compact_slice;
# StageOps stay mutate=false for POD hash parity only.

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
	_expect("Economy POD self-test method exists",
		ext.has_method("runtime_economy_pod_self_test"))
	if ext.has_method("runtime_economy_pod_self_test"):
		_expect("Economy POD self_test soft-ok",
			bool(ext.runtime_economy_pod_self_test()))

	_expect("submit_economy_pod_commands exported",
		ext.has_method("submit_economy_pod_commands"))
	_expect("poll_economy_pod_receipts exported",
		ext.has_method("poll_economy_pod_receipts"))

	var started_shadow: Dictionary = ext.start_runtime_worker({
		"simulation_thread_mode": "SHADOW",
		"graph_coverage_complete": false,
		"day": 0,
		"speed_days_per_second": 0.0,
		"paused": true,
	})
	_expect("Economy SHADOW worker starts", bool(started_shadow.get("ok", false)))

	var report: Dictionary = ext.get_runtime_thread_report()
	_expect("Economy POD / parity report fields exist",
		report.has("economy_pod_ready")
		and report.has("economy_pod_parity_ready_mask")
		and report.has("economy_pod_completed_stage_mask")
		and report.has("economy_replay_stage_hash")
		and report.has("implemented_domain_mask"))
	_expect("implemented mask includes ECONOMY (0xB7E)",
		int(report.get("implemented_domain_mask", 0)) == 0xB7E)
	_expect("SHADOW does not grant Economy authority",
		(int(report.get("authoritative_domain_mask", 0)) & 0x100) == 0)

	ext.request_runtime_stop()

	var started_active: Dictionary = ext.start_runtime_worker({
		"simulation_thread_mode": "ACTIVE",
		"graph_coverage_complete": true,
		"day": 0,
		"speed_days_per_second": 0.0,
		"paused": true,
		"authoritative_domain_mask": 0xB7E,
	})
	# Soft: start may refuse without country capture; still require method surface.
	if bool(started_active.get("ok", false)):
		var active_report: Dictionary = ext.get_runtime_thread_report()
		_expect("ACTIVE start exposes economy_pod_parity_ready_mask",
			active_report.has("economy_pod_parity_ready_mask"))
		ext.request_runtime_stop()
	else:
		_expect("ACTIVE without capture fails closed (soft)",
			not String(started_active.get("code", "")).is_empty())

	_finish()


func _expect(label: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_fail(label)


func _fail(label: String) -> void:
	_failures += 1
	print("FAIL: ", label)


func _finish() -> void:
	print("runtime_economy_parity_test checks=%s failures=%s" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)
