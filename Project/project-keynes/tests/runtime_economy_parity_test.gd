extends SceneTree

# Soft Economy SHADOW/ACTIVE wiring check for Phase 2-6 / Phase-2.6.1.
# Production implemented mask is 0xB7E (includes ECONOMY). Defaults arm
# StageOps mutate + economy_production_writer=stage_ops + economy_auto_pod_active;
# legacy submit_economy_commands is refuse-closed. ACTIVE_WITH_PARITY coerces
# writer back to compact_slice for the SHADOW probe.

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
	_expect("switch_economy_authority exported",
		ext.has_method("switch_economy_authority"))

	var started_shadow: Dictionary = ext.start_runtime_worker({
		"simulation_thread_mode": "SHADOW",
		"graph_coverage_complete": false,
		"day": 0,
		"speed_days_per_second": 0.0,
		"paused": true,
	})
	_expect("Economy SHADOW worker starts", bool(started_shadow.get("ok", false)))
	if ext.has_method("switch_economy_authority") and bool(started_shadow.get("ok", false)):
		var refuse_pod: Dictionary = ext.switch_economy_authority("POD_ACTIVE")
		_expect("POD_ACTIVE refused until complete mirror",
			not bool(refuse_pod.get("ok", true))
			and String(refuse_pod.get("code", "")).contains("incomplete"))
		var legacy_ok: Dictionary = ext.switch_economy_authority("LEGACY_SYNC")
		_expect("LEGACY_SYNC authority switch ok",
			bool(legacy_ok.get("ok", false)))
		var parity_ok: Dictionary = ext.switch_economy_authority(
			"POD_ACTIVE_WITH_LEGACY_PARITY")
		_expect("parity authority switch ok",
			bool(parity_ok.get("ok", false)))
		ext.switch_economy_authority("LEGACY_SYNC")

	var report: Dictionary = ext.get_runtime_thread_report()
	_expect("Economy POD / parity report fields exist",
		report.has("economy_pod_ready")
		and report.has("economy_pod_parity_ready_mask")
		and report.has("economy_pod_completed_stage_mask")
		and report.has("economy_replay_stage_hash")
		and report.has("implemented_domain_mask")
		and report.has("economy_execution_mode")
		and report.has("economy_shadow_stage_invocations")
		and report.has("economy_stage_ops_mutate")
		and report.has("economy_auto_pod_active")
		and report.has("economy_pod_command_recapture_count")
		and report.has("economy_production_writer"))
	_expect("default execution mode is ACTIVE_ONLY",
		int(report.get("economy_execution_mode", -1)) == 0
		and String(report.get("economy_execution_mode_name", "")) == "ACTIVE_ONLY")
	_expect("Phase-2.6.1 defaults arm StageOps writer + auto POD_ACTIVE",
		bool(report.get("economy_stage_ops_mutate", false))
		and bool(report.get("economy_auto_pod_active", false))
		and String(report.get("economy_production_writer", "")) == "stage_ops"
		and String(report.get("economy_production_writer_effective", "")) ==
			"stage_ops"
		and bool(report.get("economy_stage_ops_soak_parity_ok", false)))
	_expect("Phase-2.4.4.3 readiness exposes full StageOps checklist",
		report.has("economy_stage_ops_readiness_mask")
		and int(report.get("economy_stage_ops_readiness_mask", 0)) == 0xF
		and report.has("economy_stage_ops_prelude_ready")
		and not bool(report.get("economy_stage_ops_prelude_ready", true)))
	_expect("ACTIVE_ONLY keeps SHADOW StageOps at zero",
		not bool(report.get("economy_shadow_probe_enabled", true))
		and int(report.get("economy_shadow_stage_invocations", -1)) == 0)
	_expect("implemented mask includes ECONOMY (0xB7E)",
		int(report.get("implemented_domain_mask", 0)) == 0xB7E)
	_expect("SHADOW does not grant Economy authority",
		(int(report.get("authoritative_domain_mask", 0)) & 0x100) == 0)

	# Legacy ingress is fail-closed when StageOps writer is effective.
	var legacy_submit: Dictionary = ext.submit_economy_commands({
		"opcodes": PackedInt32Array([1]),
		"effective_days": PackedInt64Array([0]),
		"sequences": PackedInt64Array([0]),
		"target_handles": PackedInt64Array([0]),
		"i32_0": PackedInt32Array([0]),
		"i32_1": PackedInt32Array([0]),
		"i64_0": PackedInt64Array([0]),
		"i64_1": PackedInt64Array([0]),
	})
	_expect("legacy submit refused under default stage_ops writer",
		not bool(legacy_submit.get("ok", true))
		and String(legacy_submit.get("reason", "")).contains("legacy_ingress"))

	ext.request_runtime_stop()

	# Phase-2.4.5: STAGE_OPS writer starts when mutate+readiness pass.
	var started_stage_ops: Dictionary = ext.start_runtime_worker({
		"simulation_thread_mode": "SHADOW",
		"graph_coverage_complete": false,
		"day": 0,
		"speed_days_per_second": 0.0,
		"paused": true,
		"economy_stage_ops_mutate": true,
		"economy_production_writer": "stage_ops",
	})
	_expect("stage_ops writer starts after soak handoff",
		bool(started_stage_ops.get("ok", false)))
	if bool(started_stage_ops.get("ok", false)):
		var stage_ops_report: Dictionary = ext.get_runtime_thread_report()
		_expect("stage_ops effective writer armed",
			String(stage_ops_report.get(
				"economy_production_writer_effective", "")) == "stage_ops"
			and bool(stage_ops_report.get(
				"economy_stage_ops_soak_parity_ok", false)))
		ext.request_runtime_stop()
	var refuse_stage_ops_no_mutate: Dictionary = ext.start_runtime_worker({
		"simulation_thread_mode": "SHADOW",
		"graph_coverage_complete": false,
		"day": 0,
		"speed_days_per_second": 0.0,
		"paused": true,
		"economy_stage_ops_mutate": false,
		"economy_production_writer": "stage_ops",
	})
	_expect("stage_ops writer requires mutate",
		not bool(refuse_stage_ops_no_mutate.get("ok", true))
		and String(refuse_stage_ops_no_mutate.get("message", "")).contains(
			"requires_mutate"))
	var refuse_stage_ops_parity: Dictionary = ext.start_runtime_worker({
		"simulation_thread_mode": "SHADOW",
		"graph_coverage_complete": false,
		"day": 0,
		"speed_days_per_second": 0.0,
		"paused": true,
		"economy_execution_mode": "ACTIVE_WITH_PARITY",
		"economy_stage_ops_mutate": true,
		"economy_production_writer": "stage_ops",
	})
	_expect("stage_ops writer conflicts with parity",
		not bool(refuse_stage_ops_parity.get("ok", true))
		and String(refuse_stage_ops_parity.get("message", "")).contains(
			"parity_conflict"))

	var started_parity: Dictionary = ext.start_runtime_worker({
		"simulation_thread_mode": "SHADOW",
		"graph_coverage_complete": false,
		"day": 0,
		"speed_days_per_second": 0.0,
		"paused": true,
		"economy_execution_mode": "ACTIVE_WITH_PARITY",
	})
	_expect("ACTIVE_WITH_PARITY worker starts", bool(started_parity.get("ok", false)))
	if bool(started_parity.get("ok", false)):
		var parity_report: Dictionary = ext.get_runtime_thread_report()
		_expect("parity mode arms SHADOW probe",
			String(parity_report.get("economy_execution_mode_name", "")) ==
				"ACTIVE_WITH_PARITY"
			and bool(parity_report.get("economy_shadow_probe_enabled", false)))
		ext.request_runtime_stop()

	var started_legacy: Dictionary = ext.start_runtime_worker({
		"simulation_thread_mode": "ACTIVE",
		"graph_coverage_complete": true,
		"day": 0,
		"speed_days_per_second": 0.0,
		"paused": true,
		"authoritative_domain_mask": 0xB7E,
		"economy_execution_mode": "LEGACY_ONLY",
	})
	if bool(started_legacy.get("ok", false)):
		var legacy_report: Dictionary = ext.get_runtime_thread_report()
		_expect("LEGACY_ONLY strips ECONOMY from request mask",
			String(legacy_report.get("economy_execution_mode_name", "")) ==
				"LEGACY_ONLY"
			and (int(legacy_report.get("requested_authority_mask", 0xB7E)) & 0x100) == 0)
		ext.request_runtime_stop()
	else:
		_expect("LEGACY_ONLY ACTIVE without capture fails closed (soft)",
			not String(started_legacy.get("code", "")).is_empty())

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
		_expect("production default remains ACTIVE_ONLY",
			String(active_report.get("economy_execution_mode_name", "")) ==
				"ACTIVE_ONLY")
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
