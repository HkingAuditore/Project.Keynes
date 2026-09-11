extends SceneTree

const ModifierFacadeScript = preload("res://scripts/modifier/modifier_facade.gd")

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
	_expect("Modifier POD self-test is exported", ext.has_method("runtime_modifier_pod_self_test"))
	var self_test: Dictionary = ext.runtime_modifier_pod_self_test()
	if not bool(self_test.get("ok", false)):
		print("[runtime-modifier-pod] self-test: %s" % self_test)
	_expect("Modifier POD authority, protocol, save and ring contracts pass",
		bool(self_test.get("ok", false)))
	_expect("Modifier remains outside ACTIVE authority mask",
		int(self_test.get("implemented_domain_mask", 0)) == 0x806)

	var facade = ModifierFacadeScript.new()
	var configured: Dictionary = facade.configure(ext, 16)
	_expect("legacy catalog also configures numeric Modifier POD",
		bool(configured.get("ok", false)) and bool(configured.get("modifier_pod_ready", false)) \
		and int(configured.get("modifier_pod_catalog_hash", 0)) != 0)
	var started: Dictionary = ext.start_runtime_worker({
		"simulation_thread_mode": "SHADOW",
		"graph_coverage_complete": false,
		"day": 0,
		"speed_days_per_second": 0.0,
		"paused": true,
	})
	_expect("Modifier SHADOW host starts", bool(started.get("ok", false)))

	var snapshot: Dictionary = ext.get_runtime_modifier_snapshot(-1)
	_expect("initial immutable snapshot is published before RUNNING",
		bool(snapshot.get("ok", false)) and bool(snapshot.get("available", false)) \
		and int(snapshot.get("generation", -1)) == 0 \
		and snapshot.get("domain_versions", PackedInt64Array()).size() == 4)
	var report: Dictionary = ext.get_runtime_thread_report()
	var report_fields := [
		"modifier_pod_ready", "modifier_pod_plan_ms", "modifier_pod_replay_ms",
		"modifier_pod_work_units", "modifier_pod_state_hash",
		"modifier_pod_snapshot_generation", "modifier_pod_ack_count",
		"modifier_pod_fallback_reason",
	]
	var report_complete := true
	for field in report_fields:
		report_complete = report_complete and report.has(field)
	if not report_complete:
		print("[runtime-modifier-pod] report: %s" % report)
	_expect("Modifier POD report fields are complete", report_complete)
	_expect("SHADOW does not grant Modifier production authority",
		int(report.get("implemented_domain_mask", 0)) == 0x806 \
		and (int(report.get("authoritative_domain_mask", 0)) & 0x80) == 0 \
		and int(report.get("main_wait_on_sim_us", -1)) == 0)

	var submitted: Dictionary = ext.submit_modifier_commands({
		"protocol_version": 2,
		"opcodes": PackedInt32Array([1]),
		"producer_ids": PackedInt32Array([77]),
		"sequences": PackedInt64Array([1]),
		"effective_days": PackedInt64Array([1]),
		"definition_keys": PackedStringArray(["climate.radiative_warming"]),
		"domains": PackedInt32Array([0]),
		"scopes": PackedInt32Array([2]),
		"entity_handles": PackedInt64Array([3]),
		"group_handles": PackedInt64Array([0]),
		"source_types": PackedInt64Array([7]),
		"source_ids": PackedInt64Array([11]),
		"duration_days": PackedInt32Array([2]),
		"stacks": PackedInt32Array([1]),
		"magnitude_q16": PackedInt32Array([65536]),
		"modifier_handles": PackedInt64Array([0]),
	})
	if int(submitted.get("modifier_shadow_enqueued", 0)) != 1:
		print("[runtime-modifier-pod] submit: %s" % submitted)
	_expect("legacy submit is mirrored to Modifier SHADOW with shared identity",
		bool(submitted.get("ok", false)) \
		and submitted.get("request_ids", PackedInt64Array()).size() == 1 \
		and int(submitted.get("modifier_shadow_enqueued", 0)) == 1)

	_expect("save request is accepted", bool(ext.request_runtime_save(9102).get("pending", false)))
	var saved: Dictionary = {}
	var save_deadline := Time.get_ticks_msec() + 1000
	while Time.get_ticks_msec() < save_deadline:
		saved = ext.poll_runtime_save(9102)
		if bool(saved.get("ready", false)):
			break
		OS.delay_msec(5)
	_expect("PKSR writes an independent MDF2 section",
		bool(saved.get("ready", false)) and (int(saved.get("section_mask", 0)) & (1 << 5)) != 0 \
		and int(saved.get("modifier_bytes", 0)) > 0)
	var save_bytes: PackedByteArray = saved.get("bytes", PackedByteArray())
	ext.request_runtime_stop()
	var stop_deadline := Time.get_ticks_msec() + 1000
	while Time.get_ticks_msec() < stop_deadline:
		if str(ext.get_runtime_thread_report().get("state", "")) == "STOPPED":
			break
		OS.delay_msec(5)
	var restore: Dictionary = ext.restore_runtime_bundle(save_bytes)
	_expect("MDF2 bundle validates transactionally", bool(restore.get("restored", false)))
	var restarted: Dictionary = ext.start_runtime_worker({
		"simulation_thread_mode": "SHADOW",
		"graph_coverage_complete": false,
		"day": 0,
		"speed_days_per_second": 0.0,
		"paused": true,
	})
	var restored_snapshot: Dictionary = ext.get_runtime_modifier_snapshot(-1)
	if not bool(restarted.get("ok", false)) or not bool(restored_snapshot.get("available", false)):
		print("[runtime-modifier-pod] restart=%s snapshot=%s report=%s" % [
			restarted, restored_snapshot, ext.get_runtime_thread_report()])
	_expect("restored Modifier snapshot publishes before worker start",
		bool(restarted.get("ok", false)) \
		and bool(restored_snapshot.get("available", false)))
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
	print("=== runtime Modifier POD: %d checks, %d failures ===" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)
