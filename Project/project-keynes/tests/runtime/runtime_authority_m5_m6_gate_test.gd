extends SceneTree

## M5/M6 release-gate regression.
##
## M5 promotes the compile-time capability mask to 0xFFF and verifies the
## all-domain ACTIVE admission path. M6 checks that economy authority changes are accepted
## only at an idle epoch boundary and that every accepted/rejected transition
## is auditable through the runtime report.

var _checks := 0
var _failures := 0
var _ext


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		_fail("DCWorldExt unavailable")
		_finish()
		return
	_ext = DCWorldExt.new()
	_expect("authority switch API exported", _ext.has_method("switch_economy_authority"))
	_expect("fault gate self-test API exported",
		_ext.has_method("runtime_economy_authority_fault_gate_self_test"))
	_expect("runtime report API exported", _ext.has_method("get_runtime_thread_report"))

	# M5: all-domain ACTIVE is admitted by the capability gate.
	var all_active: Dictionary = _ext.start_runtime_worker({
		"simulation_thread_mode": "ACTIVE",
		"graph_coverage_complete": true,
		"authoritative_domain_mask": 0xFFF,
		"day": 0,
		"speed_days_per_second": 0.0,
		"paused": true,
	})
	_expect("M5 admits ACTIVE 0xFFF", bool(all_active.get("ok", false)))
	var all_active_report: Dictionary = all_active.get("thread_report", {})
	_expect("M5 exposes complete implementation mask",
		int(all_active_report.get("implemented_domain_mask", 0)) == 0xFFF
		and int(all_active_report.get("missing_domain_mask", 1)) == 0)
	_expect("M5 exposes all three pending-domain ACTIVE diagnostics",
		all_active_report.has("input_capture_generation")
		and all_active_report.has("gameplay_effect_generation")
		and all_active_report.has("visual_intent_generation")
		and all_active_report.has("completion_gate_missing_domain_mask"))
	_ext.request_runtime_stop()
	OS.delay_msec(80)

	# M6: a paused worker with an admitted command (in-flight mutation) cannot
	# switch authority until that command reaches an epoch boundary.
	var running: Dictionary = _ext.start_runtime_worker({
		"simulation_thread_mode": "SHADOW",
		"graph_coverage_complete": true,
		"day": 0,
		"speed_days_per_second": 0.0,
		"paused": true,
	})
	_expect("M6 boundary-test worker starts", bool(running.get("ok", false)))
	var queued: Dictionary = _ext.submit_runtime_command({
		"request_id": 7001,
		"producer_id": 7,
		"sequence": 1,
		"requested_day": 0,
		"domain": 9,
		"opcode": 1,
	})
	_expect("M6 admits a pending mutation for the gate test",
		bool(queued.get("ok", false)))
	var rejected: Dictionary = _ext.switch_economy_authority(
		"POD_ACTIVE_WITH_LEGACY_PARITY")
	_expect("M6 rejects switch during in-flight epoch",
		not bool(rejected.get("ok", true))
		and String(rejected.get("code", "")).contains("epoch_boundary"))
	var running_report: Dictionary = _ext.get_runtime_thread_report()
	_expect("M6 exposes rejection counter and blocker",
		int(running_report.get("economy_authority_switch_rejected", 0)) >= 1
		and String(running_report.get("economy_authority_switch_blocker", "")) != "")
	_expect("M6 exposes worker-local mutation blockers",
		running_report.has("worker_day_inflight")
		and running_report.has("economy_inflight_mutations")
		and running_report.has("economy_pending_command_count"))
	_expect("M6 records rejection reason",
		String(running_report.get("economy_authority_switch_reason", "")).contains("epoch_boundary"))
	_ext.request_runtime_stop()
	OS.delay_msec(80)

	# Fault handling is probed against an isolated host so the test never
	# destabilizes the live worker used by the boundary checks.
	_expect("M6 fault gate pauses and retains committed snapshot",
		bool(_ext.runtime_economy_authority_fault_gate_self_test()))

	# M6: paused/idle boundary accepts the switch and publishes a full audit.
	var idle: Dictionary = _ext.start_runtime_worker({
		"simulation_thread_mode": "SHADOW",
		"graph_coverage_complete": true,
		"day": 0,
		"speed_days_per_second": 0.0,
		"paused": true,
	})
	_expect("M6 idle worker starts", bool(idle.get("ok", false)))
	var switched: Dictionary = _ext.switch_economy_authority(
		"POD_ACTIVE_WITH_LEGACY_PARITY")
	_expect("M6 accepts epoch-boundary switch", bool(switched.get("ok", false)))
	var audit: Dictionary = _ext.get_runtime_thread_report()
	_expect("M6 records switch count and both hashes",
		int(audit.get("economy_authority_switch_count", 0)) >= 1
		and audit.has("economy_authority_switch_before_hash")
		and audit.has("economy_authority_switch_after_hash"))
	_expect("M6 records latency, reason and generations",
		int(audit.get("economy_authority_switch_latency_us", -1)) >= 0
		and int(audit.get("economy_authority_switch_command_latency_us", -1)) >= 0
		and String(audit.get("economy_authority_switch_reason", "")) != ""
		and audit.has("economy_authority_switch_before_generation")
		and audit.has("economy_authority_switch_after_generation"))
	_expect("M6 records structured before/after audit entries",
		String(audit.get("economy_authority_switch_audit_before", "")).contains("mode=")
		and String(audit.get("economy_authority_switch_audit_after", "")).contains("mode=")
		and int(audit.get("economy_authority_switch_audit_sequence", 0)) >= 1)
	_expect("M6 preserves last committed snapshot audit",
		int(audit.get("economy_authority_last_committed_generation", 0)) >= 0
		and audit.has("economy_authority_last_committed_hash"))
	_expect("M6 keeps legacy/parity opt-in and does not auto-switch",
		not bool(audit.get("economy_auto_pod_active", true))
		and String(audit.get("economy_authority_switch_reason", "")) != "")
	var switched_back: Dictionary = _ext.switch_economy_authority("LEGACY_SYNC")
	_expect("M6 reverse switch also succeeds at boundary",
		bool(switched_back.get("ok", false)))
	# Short audit soak: alternate the two explicitly requested development
	# modes at the same idle epoch boundary. Every accepted transition must
	# advance the audit sequence and continue to expose both hashes and latency.
	var soak_ok := true
	for i in range(64):
		var target := "POD_ACTIVE_WITH_LEGACY_PARITY" if (i % 2) == 0 else "LEGACY_SYNC"
		var transition: Dictionary = _ext.switch_economy_authority(target)
		soak_ok = soak_ok and bool(transition.get("ok", false))
		soak_ok = soak_ok and transition.has("economy_authority_switch_before_hash")
		soak_ok = soak_ok and transition.has("economy_authority_switch_after_hash")
		soak_ok = soak_ok and int(transition.get(
			"economy_authority_switch_command_latency_us", -1)) >= 0
	var soak_report: Dictionary = _ext.get_runtime_thread_report()
	_expect("M6 repeated boundary switches remain auditable",
		soak_ok
		and int(soak_report.get("economy_authority_switch_audit_sequence", 0)) >= 66
		and int(soak_report.get("economy_authority_switch_latency_p95_us", -1)) >= 0
		and int(soak_report.get("economy_authority_switch_latency_max_us", -1)) >= 0
		and int(soak_report.get("economy_authority_switch_command_latency_p95_us", -1)) >= 0
		and int(soak_report.get("economy_authority_switch_command_latency_max_us", -1)) >= 0
		and int(soak_report.get("economy_authority_switch_latency_sample_count", 0)) >= 66
		and int(soak_report.get("worker_day_inflight", -1)) == 0
		and int(soak_report.get("economy_inflight_mutations", -1)) == 0
		and int(soak_report.get("economy_pending_command_count", -1)) == 0)
	_ext.request_runtime_stop()
	OS.delay_msec(80)
	_finish()


func _expect(label: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_fail(label)


func _fail(label: String) -> void:
	_failures += 1
	print("FAIL: ", label)


func _finish() -> void:
	print("runtime_authority_m5_m6_gate_test checks=%s failures=%s" % [
		_checks, _failures])
	quit(1 if _failures > 0 else 0)

