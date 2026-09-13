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
	_expect("Economy POD self-test is exported",
		ext.has_method("runtime_economy_pod_self_test"))
	if ext.has_method("runtime_economy_pod_self_test"):
		_expect("Economy POD plan/advance/commit contract",
			bool(ext.runtime_economy_pod_self_test()))

	var started: Dictionary = ext.start_runtime_worker({
		"simulation_thread_mode": "SHADOW",
		"graph_coverage_complete": false,
		"day": 0,
		"speed_days_per_second": 0.0,
		"paused": true,
	})
	_expect("Economy SHADOW worker starts", bool(started.get("ok", false)))

	var report: Dictionary = ext.get_runtime_thread_report()
	_expect("Economy POD report fields are present",
		report.has("economy_pod_ready")
		and report.has("economy_pod_completed_stage_mask")
		and report.has("economy_pod_pending_outbox")
		and report.has("economy_replay_stage_hash")
		and report.has("implemented_domain_mask")
		and report.has("economy_pod_parity_ready_mask"))
	_expect("Economy is inside implemented ACTIVE mask (Phase 2-6)",
		(int(report.get("implemented_domain_mask", 0)) & 0x100) != 0)
	_expect("Production implemented mask is 0xB7E with ECONOMY",
		int(report.get("implemented_domain_mask", 0)) == 0xB7E)
	_expect("SHADOW does not grant Economy production authority",
		(int(report.get("authoritative_domain_mask", 0)) & 0x100) == 0)

	var stage_hashes: PackedInt64Array = report.get("economy_replay_stage_hash", PackedInt64Array())
	_expect("Economy replay exposes 13 stage hash slots",
		stage_hashes.size() == 13)

	ext.request_runtime_stop()
	_finish()


func _expect(label: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_fail(label)


func _fail(label: String) -> void:
	_failures += 1
	print("FAIL: ", label)


func _finish() -> void:
	print("runtime_economy_pod_test checks=%s failures=%s" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)
