extends SceneTree

var _checks := 0
var _failures := 0

func _init() -> void:
	_run()
	quit(0 if _failures == 0 else 1)

func _run() -> void:
	print("=== runtime thread isolation smoke ===")
	if not ClassDB.class_exists("DCWorldExt"):
		_fail("DCWorldExt class unavailable")
		_finish()
		return
	var ext := DCWorldExt.new()
	_expect("thread API exported", ext.has_method("start_runtime_worker"))
	_expect("commit API exported", ext.has_method("poll_runtime_commit"))
	_expect("stop API exported", ext.has_method("request_runtime_stop"))
	_expect("thread QoS API exported", ext.has_method("set_runtime_qos_threaded"))
	_expect("runtime restore API exported", ext.has_method("restore_runtime_bundle"))

	var blocked: Dictionary = ext.start_runtime_worker({
		"graph_coverage_complete": false,
		"day": 0,
		"speed_days_per_second": 50.0,
		"paused": false,
	})
	_expect("partial graph is rejected", not bool(blocked.get("ok", true)))
	_expect("rejection is explicit", str(blocked.get("code", "")) == "runtime_graph_not_thread_safe")
	var incomplete_active: Dictionary = ext.start_runtime_worker({
		"simulation_thread_mode": "ACTIVE",
		"graph_coverage_complete": true,
		"day": 0,
		"speed_days_per_second": 50.0,
		"paused": true,
	})
	_expect("ACTIVE is blocked until every native domain handler exists",
		not bool(incomplete_active.get("ok", true)) \
		and str(incomplete_active.get("code", "")) == "runtime_native_domains_incomplete")

	var started: Dictionary = ext.start_runtime_worker({
		"simulation_thread_mode": "SHADOW",
		"graph_coverage_complete": true,
		"day": 0,
		"speed_days_per_second": 50.0,
		"paused": false,
	})
	_expect("shadow graph starts asynchronously", bool(started.get("ok", false)) and bool(started.get("pending", false)))
	OS.delay_msec(120)
	var report: Dictionary = ext.get_runtime_thread_report()
	_expect("domain POD ABI version is exposed", int(report.get("runtime_domain_abi_version", 0)) == 1)
	_expect("worker reaches running state", str(report.get("simulation_host_state", "")) in ["RUNNING", "PAUSED"])
	var barrier_blocked := int(report.get("simulation_committed_day", 0)) == 0 \
		and int(report.get("climate_trace_consumable", 0)) == 0 \
		and str(report.get("climate_pod_fallback_reason", "")) in [
			"climate_trace_reference_pending", "climate_trace_missing"]
	_expect("worker waits for OFF reference trace at day barrier", barrier_blocked)
	_expect("main thread never waits for simulation", int(report.get("main_wait_on_sim_us", -1)) == 0)
	_expect("time debt remains bounded", float(report.get("simulation_time_debt_days", report.get("time_debt_days", 101.0))) <= 100.0)
	_expect("coverage reports missing native domain handlers", str(report.get("graph_coverage_state", "")) == "partial" \
		and str(report.get("simulation_worker_blocker", "")) == "missing_native_domain_handlers" \
		and int(report.get("missing_domain_mask", 0)) != 0 \
		and int(report.get("implemented_domain_mask", 0)) != int(report.get("missing_domain_mask", 0)))
	# Without a reference-backed input trace, no simulation day or visual
	# commit may be published. This is the strict replay contract; the rest of
	# this test exercises commit/save behavior only after a committed day exists.
	if barrier_blocked:
		var barrier_clock := ext.set_runtime_clock(true, 50.0)
		_expect("barrier pause remains non-blocking", bool(barrier_clock.get("ok", false)))
		var barrier_stop := ext.request_runtime_stop()
		_expect("barrier stop remains non-blocking", bool(barrier_stop.get("ok", false)))
		OS.delay_msec(30)
		_expect("barrier worker stops cleanly", str(ext.get_runtime_thread_report().get("simulation_host_state", "")) == "STOPPED")
		_finish()
		return
	_expect("day plan exposes fixed domain barrier", int(report.get("day_stage_count", 0)) == 12 \
		and int(report.get("day_completed_stage_count", 0)) == 1 \
		and int(report.get("day_work_units", 0)) >= 1)
	var qos: Dictionary = ext.set_runtime_qos_threaded(true)
	_expect("thread QoS update is non-blocking", bool(qos.get("ok", false)) \
		and bool(qos.get("pending", false)) and bool(qos.get("interactive", false)))
	ext.set_runtime_qos_threaded(false)
	var invalid_clock: Dictionary = ext.set_runtime_clock(false, -1.0)
	_expect("invalid clock speed is rejected before wake", \
		str(invalid_clock.get("code", "")) == "runtime_clock_invalid" \
		and not bool(invalid_clock.get("pending", false)))

	var commit: Dictionary = ext.poll_runtime_commit(0)
	_expect("commit is published", bool(commit.get("available", false)))
	_expect("commit generation is positive", int(commit.get("generation", 0)) > 0)
	var family_generations = commit.get("dirty_family_generations", PackedInt64Array())
	_expect("commit exposes per-family generations", family_generations is PackedInt64Array \
		and (family_generations as PackedInt64Array).size() == 9)
	var visual_diag: Dictionary = ext.record_runtime_visual_timings(1.25, 0.5, 0.25)
	_expect("visual timing feedback is non-blocking", bool(visual_diag.get("ok", false)))
	var visual_report: Dictionary = ext.get_runtime_thread_report()
	_expect("visual timing fields are reported", is_equal_approx(float(visual_report.get("ui_input_to_feedback_ms", -1.0)), 1.25) \
		and is_equal_approx(float(visual_report.get("visual_apply_ms", -1.0)), 0.5) \
		and is_equal_approx(float(visual_report.get("gpu_upload_ms", -1.0)), 0.25))
	var generation := int(commit.get("generation", 0))
	# The control message is asynchronous. It is legal for the worker to finish
	# another day before the pause takes effect, so establish the newest scalar
	# commit first and then test the real contract: polling the same generation
	# never republishes it.
	ext.set_runtime_clock(true, 50.0)
	var current_commit: Dictionary = ext.poll_runtime_commit(0)
	var current_generation := int(current_commit.get("generation", generation))
	var stale: Dictionary = ext.poll_runtime_commit(current_generation)
	_expect("same generation is not republished", not bool(stale.get("available", false)))
	var empty_patch: Dictionary = ext.consume_runtime_visual_patch(current_generation, 1, 0, 4)
	_expect("visual patch cursor handles an empty family", bool(empty_patch.get("available", false)) \
		and bool(empty_patch.get("done", false)) and int(empty_patch.get("next_cursor", -1)) == 0)
	ext.set_runtime_clock(false, 50.0)
	OS.delay_msec(80)
	var newer: Dictionary = ext.poll_runtime_commit(current_generation)
	_expect("newer commit advances generation", bool(newer.get("available", false)) \
		and int(newer.get("generation", 0)) > current_generation)
	ext.set_runtime_clock(true, 50.0)
	var expired_patch: Dictionary = ext.consume_runtime_visual_patch(current_generation, 1, 0, 4)
	_expect("expired visual generation is discarded", str(expired_patch.get("code", "")) == "runtime_generation_expired")
	var environment_day := int(ext.get_runtime_thread_report().get(
		"simulation_committed_day", 0))
	var captured: Dictionary = ext.capture_runtime_inputs({
		"generation": 2,
		"day": environment_day,
		"season_phase": 0.25,
		"climate_anomaly": 0.0,
		"terrain": PackedByteArray([1, 2]),
		"landform": PackedByteArray([0, 0]),
		"has_river": PackedByteArray([0, 1]),
		"neighbor_indices": PackedInt32Array([-1, -1, -1, -1, -1, -1,
			-1, -1, -1, -1, -1, -1]),
	})
	_expect("POD environment snapshot is accepted", bool(captured.get("ok", false)))
	var environment_report: Dictionary = ext.get_runtime_thread_report()
	_expect("environment dimensions are visible in thread report", \
		int(environment_report.get("simulation_environment_cell_count", 0)) == 2 \
		and bool(environment_report.get("simulation_environment_topology_validated", false)))
	var environment_perf: Dictionary = ext.get_runtime_perf_snapshot()
	_expect("environment dimensions are visible in perf snapshot", \
		int(environment_perf.get("simulation_environment_cell_count", 0)) == 2 \
		and bool(environment_perf.get("simulation_environment_topology_validated", false)))
	var stale_input: Dictionary = ext.capture_runtime_inputs({
		"generation": 1, "day": environment_day, "terrain": PackedByteArray([1, 2]),
	})
	_expect("stale environment snapshot is rejected", str(stale_input.get("code", "")) == "runtime_input_stale")
	var bad_shape: Dictionary = ext.capture_runtime_inputs({
		"generation": 3, "day": environment_day + 1,
		"cell_temp": PackedFloat32Array([1.0, 2.0]),
		"building_resource_reserve": PackedFloat32Array([1.0]),
	})
	_expect("environment resource shape is validated", str(bad_shape.get("code", "")) == "runtime_input_shape_mismatch")
	var bad_lut: Dictionary = ext.capture_runtime_inputs({
		"generation": 4, "day": environment_day + 1,
		"terrain": PackedByteArray([1]),
		"trade_passable_lut": PackedByteArray([1]),
		"trade_move_cost_lut": PackedInt32Array([1]),
	})
	_expect("trade LUT shape is validated", str(bad_lut.get("code", "")) == "runtime_input_shape_mismatch")
	var invalid_payload: Dictionary = ext.submit_runtime_command({
		"request_id": 90, "producer_id": 1, "sequence": 1,
		"requested_day": 0, "domain": 1, "opcode": 1,
		"payload": PackedInt32Array([1]),
	})
	_expect("invalid command payload is rejected before enqueue", \
		str(invalid_payload.get("code", "")) == "invalid_command_payload")
	var command_a: Dictionary = ext.submit_runtime_command({
		"request_id": 101, "producer_id": 2, "sequence": 2,
		"requested_day": 0, "domain": 1, "opcode": 1,
	})
	var command_b: Dictionary = ext.submit_runtime_command({
		"request_id": 102, "producer_id": 1, "sequence": 2,
		"requested_day": 0, "domain": 1, "opcode": 1,
	})
	var command_c: Dictionary = ext.submit_runtime_command({
		"request_id": 103, "producer_id": 1, "sequence": 1,
		"requested_day": 0, "domain": 1, "opcode": 1,
	})
	_expect("commands are accepted without waiting", bool(command_a.get("pending", false)) \
		and bool(command_b.get("pending", false)) and bool(command_c.get("pending", false)))
	var rejected_command: Dictionary = ext.submit_runtime_command({
		"request_id": 104, "producer_id": 1, "sequence": 4,
		"requested_day": 0, "domain": 65535, "opcode": 1,
		"payload": PackedByteArray(),
	})
	_expect("unknown domain is queued for deterministic preflight", bool(rejected_command.get("pending", false)))
	ext.set_runtime_clock(false, 50.0)
	OS.delay_msec(100)
	ext.set_runtime_clock(true, 50.0)
	var receipts: Dictionary = ext.poll_runtime_receipts(16)
	var receipt_items: Array = receipts.get("receipts", [])
	var ordered := receipt_items.size() >= 4 \
		and int(receipt_items[0].get("request_id", 0)) == 103 \
		and int(receipt_items[1].get("request_id", 0)) == 102 \
		and int(receipt_items[2].get("request_id", 0)) == 104 \
		and int(receipt_items[2].get("code", -1)) == 3 \
		and int(receipt_items[3].get("request_id", 0)) == 101
	_expect("worker receipts preserve stable producer ordering", ordered)
	var deferred_day := int(ext.get_runtime_thread_report().get(
		"simulation_committed_day", 0)) + 2
	var deferred_command: Dictionary = ext.submit_runtime_command({
		"request_id": 200, "producer_id": 3, "sequence": 1,
		"requested_day": deferred_day, "domain": 1, "opcode": 1,
		"payload": PackedByteArray(),
	})
	_expect("future command remains accepted before save", bool(deferred_command.get("pending", false)))
	var save_request: Dictionary = ext.request_runtime_save(77)
	_expect("runtime save request is non-blocking", bool(save_request.get("ok", false)) and bool(save_request.get("pending", false)))
	OS.delay_msec(30)
	var save_poll: Dictionary = ext.poll_runtime_save(77)
	_expect("runtime save bundle becomes available", bool(save_poll.get("ready", false)) and (save_poll.get("bytes", PackedByteArray()) as PackedByteArray).size() > 0)
	_expect("runtime save bundle carries checksum metadata", int(save_poll.get("checksum", 0)) != 0 \
		and (save_poll.get("bytes", PackedByteArray()) as PackedByteArray).size() >= 89)
	_expect("runtime save bundle is PKSR v2", int(save_poll.get("bundle_version", 0)) == 2)
	_expect("runtime save bundle carries deferred commands", int(save_poll.get("pending_command_count", 0)) >= 1)
	var saved_runtime_bytes: PackedByteArray = save_poll.get("bytes", PackedByteArray())
	var saved_runtime_day := int(save_poll.get("committed_day", -1))
	var saved_runtime_generation := int(save_poll.get("generation", -1))
	var save_poll_again: Dictionary = ext.poll_runtime_save(77)
	_expect("consumed save bundle is not returned twice", not bool(save_poll_again.get("ready", false)) \
		and str(save_poll_again.get("code", "")) == "save_pending")

	var queue_full_seen := false
	for i in 4097:
		var queued: Dictionary = ext.submit_runtime_command({
			"request_id": i + 1,
			"producer_id": 1,
			"sequence": i,
			"requested_day": 100000,
			"domain": 1,
			"opcode": 1,
			"payload": PackedByteArray(),
		})
		if str(queued.get("code", "")) == "command_queue_capacity_exceeded":
			queue_full_seen = true
			break
	_expect("full command queue fails immediately", queue_full_seen)

	var stop: Dictionary = ext.request_runtime_stop()
	_expect("stop returns immediately", bool(stop.get("ok", false)) and bool(stop.get("pending", false)))
	var save_while_stopping: Dictionary = ext.request_runtime_save(78)
	_expect("save is rejected while worker is stopping", \
		str(save_while_stopping.get("code", "")) == "runtime_worker_stopping" \
		and not bool(save_while_stopping.get("pending", false)))
	OS.delay_msec(100)
	var stopped: Dictionary = ext.get_runtime_thread_report()
	_expect("worker stops cleanly", str(stopped.get("simulation_host_state", "")) == "STOPPED")
	var v1_bytes := saved_runtime_bytes.duplicate()
	if v1_bytes.size() >= 8:
		v1_bytes[4] = 1
		v1_bytes[5] = 0
		v1_bytes[6] = 0
		v1_bytes[7] = 0
	var v1_restore: Dictionary = ext.restore_runtime_bundle(v1_bytes)
	_expect("PKSR v1 restore is explicitly rejected", str(v1_restore.get("code", "")) == "runtime_bundle_version_incompatible")
	var restored: Dictionary = ext.restore_runtime_bundle(saved_runtime_bytes)
	_expect("stopped host accepts PKSR restore", bool(restored.get("ok", false)) \
		and bool(restored.get("restored", false)))
	var restarted: Dictionary = ext.start_runtime_worker({
		"simulation_thread_mode": "SHADOW",
		"graph_coverage_complete": true,
		"day": 12,
		"speed_days_per_second": 50.0,
		"paused": true,
	})
	_expect("stopped host can be reused", bool(restarted.get("ok", false)) \
		and bool(restarted.get("pending", false)))
	var restarted_report: Dictionary = ext.get_runtime_thread_report()
	_expect("restarted host starts paused", str(restarted_report.get("simulation_host_state", "")) in ["STARTING", "PAUSED"])
	_expect("PKSR restore restores day and generation", \
		int(restarted_report.get("simulation_committed_day", -1)) == saved_runtime_day \
		and int(restarted_report.get("simulation_generation", -1)) == saved_runtime_generation)
	ext.set_runtime_clock(false, 50.0)
	OS.delay_msec(100)
	ext.set_runtime_clock(true, 50.0)
	var restored_receipts: Array = ext.poll_runtime_receipts(16).get("receipts", [])
	var restored_command_settled := false
	for receipt in restored_receipts:
		if int((receipt as Dictionary).get("request_id", 0)) == 200:
			restored_command_settled = int((receipt as Dictionary).get("code", -1)) == 3 \
				and int((receipt as Dictionary).get("effective_day", -1)) == deferred_day
			break
	_expect("restored pending command produces its deterministic receipt",
		restored_command_settled)
	ext.request_runtime_stop()
	OS.delay_msec(50)
	var shadow: Dictionary = ext.start_runtime_worker({
		"simulation_thread_mode": "SHADOW",
		"graph_coverage_complete": false,
		"day": 20,
		"speed_days_per_second": 5.0,
		"paused": true,
	})
	_expect("shadow mode starts without authority coverage", bool(shadow.get("ok", false)) \
		and bool(shadow.get("pending", false)) \
		and str(shadow.get("requested_simulation_thread_mode", "")) == "SHADOW")
	var shadow_report: Dictionary = ext.get_runtime_thread_report()
	_expect("shadow mode is observable and remains non-authoritative", \
		str(shadow_report.get("requested_simulation_thread_mode", "")) == "SHADOW" \
		and str(shadow_report.get("simulation_thread_mode", "")) == "SHADOW" \
		and not bool(shadow_report.get("simulation_worker_ready", true)))
	var hot_switch: Dictionary = ext.start_runtime_worker({
		"simulation_thread_mode": "OFF",
		"graph_coverage_complete": false,
	})
	_expect("mode hot switch is rejected", str(hot_switch.get("code", "")) == "runtime_thread_mode_hot_switch_forbidden")
	ext.request_runtime_stop()
	OS.delay_msec(50)
	var off: Dictionary = ext.start_runtime_worker({
		"simulation_thread_mode": "OFF",
		"graph_coverage_complete": false,
		"day": 30,
	})
	_expect("off mode does not create a worker", bool(off.get("ok", false)) \
		and not bool(off.get("pending", true)) \
		and str(off.get("state", "")) == "STOPPED")
	_finish()

func _expect(label: String, ok: bool) -> void:
	_checks += 1
	if ok:
		print("  [PASS] %s" % label)
	else:
		_failures += 1
		push_error("  [FAIL] %s" % label)

func _fail(label: String) -> void:
	_failures += 1
	push_error("  [FAIL] %s" % label)

func _finish() -> void:
	print("=== done: %d checks, %d failures ===" % [_checks, _failures])
