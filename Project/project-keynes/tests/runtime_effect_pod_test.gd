extends SceneTree

# F8 contracts:
# - implemented_domain_mask is 0x866 after F8 (includes EFFECT bit)
# - ACTIVE grant makes worker the sole Effect writer; this SHADOW fixture keeps
#   authoritative & EFFECT == 0
# - Effect POD catalog resolves registered behaviors via Host resolver
# - no synthetic OK ACKs; Host stage consumes real Modifier ACKs
# - when Effect POD stage succeeds, fixture run_effect intents do not feed Modifier

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
	_expect("Effect POD self-test is exported",
		ext.has_method("runtime_effect_pod_self_test"))
	if ext.has_method("runtime_effect_pod_self_test"):
		_expect("Effect POD plan/replay, ACK and save fixture passes",
			bool(ext.runtime_effect_pod_self_test()))
	_expect("Effect Host stage self-test is exported",
		ext.has_method("runtime_effect_host_stage_self_test"))
	if ext.has_method("runtime_effect_host_stage_self_test"):
		_expect("F7 Host stage plan/commit/intent/ACK smoke passes",
			bool(ext.runtime_effect_host_stage_self_test()))

	_expect("Effect SHADOW transport methods are exported",
		ext.has_method("queue_effect_pod_instance") and
		ext.has_method("queue_effect_pod_metric") and
		ext.has_method("queue_effect_pod_remove") and
		ext.has_method("poll_effect_worker_intent") and
		ext.has_method("submit_effect_worker_ack"))

	var catalog := preload("res://scripts/effect/effect_domain_catalog.gd").build()
	_expect("Effect catalog builds", catalog != null)
	if catalog != null:
		var configured: Dictionary = ext.configure_effects(catalog.compile_native_catalog())
		_expect("Effect legacy and POD catalogs configure",
			bool(configured.get("ok", false)) and
			bool(configured.get("effect_pod_ready", false)) and
			int(configured.get("effect_pod_catalog_hash", 0)) != 0)

	var started: Dictionary = ext.start_runtime_worker({
		"simulation_thread_mode": "SHADOW",
		"graph_coverage_complete": false,
		"day": 0,
		"speed_days_per_second": 0.0,
		"paused": true,
	})
	_expect("Effect SHADOW host starts", bool(started.get("ok", false)))
	var report: Dictionary = ext.get_runtime_thread_report()
	_expect("Effect is not ACTIVE authority",
		int(report.get("implemented_domain_mask", 0)) == 0x866)
	_expect("Effect authoritative bit stays clear",
		(int(report.get("authoritative_domain_mask", 0)) & 0x020) == 0)
	var effect_report_fields := [
		"effect_pod_ready", "effect_pod_plan_ms", "effect_pod_replay_ms",
		"effect_pod_state_hash", "effect_pod_snapshot_generation",
		"effect_pod_ack_count", "effect_pod_intent_count",
		"effect_pod_fallback_reason",
	]
	var report_complete := true
	for field in effect_report_fields:
		report_complete = report_complete and report.has(field)
	if not report_complete:
		print("[runtime-effect-pod] report: %s" % report)
	_expect("Effect POD report fields are complete", report_complete)

	var queued: Dictionary = ext.queue_effect_pod_instance({
		"instance_id": 9001,
		"generation": 1,
		"program_id": 0,
		"source_handle": 1,
		"target_handle": 2,
		"target_generation": 1,
		"next_due_day": 0,
		"active": true,
	})
	_expect("Effect POD instance queue accepts SHADOW mirror input",
		bool(queued.get("ok", false)))
	# Drain any residual intents from the Host stage self-test, then prove the
	# empty poll path stays non-blocking.
	var drain_deadline := Time.get_ticks_msec() + 200
	while Time.get_ticks_msec() < drain_deadline:
		var drain: Dictionary = ext.poll_effect_worker_intent()
		if not bool(drain.get("available", false)):
			break
	var polled: Dictionary = ext.poll_effect_worker_intent()
	_expect("Effect intent poll is non-blocking when empty",
		bool(polled.get("ok", false)) and polled.has("available") and
		not bool(polled.get("available", true)))

	_expect("Effect save request is accepted",
		bool(ext.request_runtime_save(9401).get("pending", false)))
	var saved: Dictionary = {}
	var deadline := Time.get_ticks_msec() + 1000
	while Time.get_ticks_msec() < deadline:
		saved = ext.poll_runtime_save(9401)
		if bool(saved.get("ready", false)):
			break
		OS.delay_msec(5)
	_expect("PKSR contains independent EFP1 section",
		bool(saved.get("ready", false)) and
		(int(saved.get("section_mask", 0)) & (1 << 7)) != 0 and
		int(saved.get("effect_bytes", 0)) > 0)
	var bytes: PackedByteArray = saved.get("bytes", PackedByteArray())
	ext.request_runtime_stop()
	var stop_deadline := Time.get_ticks_msec() + 1000
	while Time.get_ticks_msec() < stop_deadline:
		if str(ext.get_runtime_thread_report().get("state", "")) == "STOPPED":
			break
		OS.delay_msec(5)
	var restored: Dictionary = ext.restore_runtime_bundle(bytes)
	if not bool(restored.get("restored", false)):
		print("[runtime-effect-pod] restore=%s saved=%s report=%s" % [
			restored, saved, ext.get_runtime_thread_report()])
	_expect("EFP1 bundle validates transactionally",
		bool(restored.get("restored", false)))

	if not bytes.is_empty():
		var missing := bytes.duplicate()
		# Clear only the Effect section bit and recompute the outer checksum is
		# intentionally unnecessary: the parser must reject the tampered bundle.
		missing[85] = missing[85] & 0x7f
		_expect("bundle without Effect section is rejected",
			not bool(ext.restore_runtime_bundle(missing).get("ok", true)))

	_finish()

func _expect(label: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_fail(label)

func _fail(label: String) -> void:
	_failures += 1
	push_error("[FAIL] %s" % label)

func _finish() -> void:
	print("=== runtime Effect POD: %d checks, %d failures ===" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)
