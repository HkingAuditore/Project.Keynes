extends SceneTree

var checks := 0
var failures := 0

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	for source_inline in [false, true]:
		var source := DCWorldExt.new()
		_expect("source starts", source.start_runtime_worker(_config(source_inline)).get("ok", false))
		for sequence in [2, 1]:
			var admitted: Dictionary = source.submit_runtime_command({
				"request_id": 400 + sequence, "producer_id": 2, "sequence": sequence,
				"requested_day": 1, "domain": 1, "opcode": 1})
			_expect("future command accepted", admitted.get("pending", false))
		var saved: Dictionary = await _save(source, 81)
		_expect("save retains both future commands", saved.get("pending_command_count", -1) == 2)
		_expect("runtime archive uses current version", saved.get("bundle_version", -1) == 5)
		_expect("save is consumed once", not source.poll_runtime_save(81).get("ready", false))
		var again: Dictionary = await _save(source, 82)
		_expect("subsequent save retains backlog", again.get("pending_command_count", -1) == 2)
		var bytes: PackedByteArray = saved.get("bytes", PackedByteArray())
		await _check_commands(source, source_inline)
		await _stop(source)
		for target_inline in [false, true]:
			var restored := DCWorldExt.new()
			_expect("archive restores", restored.restore_runtime_bundle(bytes).get("ok", false))
			_expect("restored executor starts", restored.start_runtime_worker(_config(target_inline)).get("ok", false))
			await _check_commands(restored, target_inline)
			await _stop(restored)
	for inline_mode in [false, true]:
		await _command_capacity(inline_mode)
	await _incomplete_day()
	await _save_failure()
	_expect("all scenarios ran", checks >= 70)
	print("inline save/restore: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)

func _config(inline_mode: bool, mask: int = 0x803) -> Dictionary:
	return {"simulation_thread_mode": "ACTIVE", "graph_coverage_complete": true,
		"native_daily_inline": inline_mode, "authoritative_domain_mask": mask,
		"day": 0, "speed_days_per_second": 0.0, "paused": true}

func _save(ext: Object, request: int) -> Dictionary:
	var accepted: Dictionary = ext.request_runtime_save(request)
	_expect("save request accepted", accepted.get("ok", false))
	var deadline := Time.get_ticks_msec() + 3000
	var result := {}
	while Time.get_ticks_msec() < deadline:
		result = ext.poll_runtime_save(request)
		if result.get("ready", false) or not result.get("ok", true):
			break
		await process_frame
	_expect("save reaches a terminal result", result.get("ready", false) or not result.get("ok", true))
	await process_frame
	return result

func _day(ext: Object, inline_mode: bool, day: int) -> void:
	# Input-driven days stop at this exact boundary. A free-running clock may
	# begin the next day before the caller pauses, correctly blocking a save.
	var generation := int(ext.get_runtime_thread_report().get("simulation_environment_generation", 0)) + 1
	var captured: Dictionary = ext.capture_runtime_inputs({"generation": generation,
		"day": day, "terrain": PackedByteArray([1]), "landform": PackedByteArray([0]),
		"has_river": PackedByteArray([0]), "neighbor_indices": PackedInt32Array([-1, -1, -1, -1, -1, -1]),
		"climate_map_width": 1, "climate_map_height": 1, "climate_catalog_hash": 7,
		"cell_temp": PackedFloat32Array([15.0]), "cell_moisture": PackedFloat32Array([0.5])})
	_expect("day input accepted", captured.get("ok", false))
	if inline_mode:
		_expect("inline day commits", ext.run_native_daily_inline_day().get("ok", false))
	else:
		ext.set_runtime_clock(false, 100.0)
		var deadline := Time.get_ticks_msec() + 3000
		while Time.get_ticks_msec() < deadline and int(ext.get_runtime_thread_report().get("simulation_committed_day", 0)) < day:
			await process_frame
		ext.set_runtime_clock(true, 100.0)
		_expect("worker day commits", int(ext.get_runtime_thread_report().get("simulation_committed_day", 0)) == day)

func _check_commands(ext: Object, inline_mode: bool) -> void:
	_expect("future commands stay pending", ext.poll_runtime_receipts(10).get("receipts", []).is_empty())
	await _day(ext, inline_mode, 1)
	var ids := PackedInt64Array()
	for receipt in ext.poll_runtime_receipts(10).get("receipts", []):
		ids.append(int(receipt.request_id))
	_expect("both restored commands settle in stable order", ids == PackedInt64Array([401, 402]))
	_expect("commands never replay twice", ext.poll_runtime_receipts(10).get("receipts", []).is_empty())

func _command_capacity(inline_mode: bool) -> void:
	var ext := DCWorldExt.new()
	_expect("capacity fixture starts", ext.start_runtime_worker(_config(inline_mode)).get("ok", false))
	# Existing PKSR and ingress capacity; no new limit is introduced here.
	var capacity := 4096
	var all_accepted := true
	for index in capacity:
		var admitted: Dictionary = ext.submit_runtime_command({
			"request_id": 10000 + index, "producer_id": 2, "sequence": index + 1,
			"requested_day": 1, "domain": 1, "opcode": 1})
		all_accepted = all_accepted and bool(admitted.get("pending", false))
	_expect("one full ingress batch is accepted", all_accepted)
	var full: Dictionary = await _save(ext, 85)
	_expect("full-capacity archive retains every command", full.get("ready", false) and full.get("pending_command_count", -1) == capacity)
	var extra: Dictionary = ext.submit_runtime_command({
		"request_id": 10000 + capacity, "producer_id": 2, "sequence": capacity + 1,
		"requested_day": 1, "domain": 1, "opcode": 1})
	_expect("drained ingress accepts another command", extra.get("pending", false))
	var failed: Dictionary = await _save(ext, 86)
	_expect("oversize save fails explicitly", not failed.get("ok", true) and failed.get("reason", "") == "save_pending_command_capacity_exceeded" and not failed.get("ready", false))
	_expect("capacity rejection leaves the runtime healthy", ext.get_runtime_control_state().get("state", "") == "PAUSED")
	_expect("pending report includes retained and newly drained commands", ext.get_runtime_thread_report().get("economy_pending_command_count", -1) == capacity + 1)
	await _day(ext, inline_mode, 1)
	var receipts: Array = ext.poll_runtime_receipts(capacity + 1).get("receipts", [])
	var all_retained := receipts.size() == capacity + 1
	for index in receipts.size():
		all_retained = all_retained and int(receipts[index].request_id) == 10000 + index
	_expect("failed save retains every accepted command in order", all_retained)
	var recovered: Dictionary = await _save(ext, 87)
	_expect("save recovers after commands settle", recovered.get("ready", false) and recovered.get("pending_command_count", -1) == 0)
	await _stop(ext)

func _incomplete_day() -> void:
	var ext := DCWorldExt.new()
	# Country has no configured owner in this fixture, so the first day parks.
	_expect("incomplete fixture starts", ext.start_runtime_worker(_config(true, 0x805)).get("ok", false))
	var captured: Dictionary = ext.capture_runtime_inputs({"generation": 1, "day": 1,
		"terrain": PackedByteArray([1]), "landform": PackedByteArray([0]),
		"has_river": PackedByteArray([0]), "neighbor_indices": PackedInt32Array([-1, -1, -1, -1, -1, -1])})
	_expect("incomplete input accepted", captured.get("ok", false))
	_expect("day remains incomplete", not ext.run_native_daily_inline_day().get("ok", true))
	_expect("save may wait for the committed boundary", ext.request_runtime_save(83).get("ok", false))
	var pending: Dictionary = ext.poll_runtime_save(83)
	_expect("partial day is never captured", pending.get("pending", false) and not pending.get("ready", false))
	await _stop(ext)

func _save_failure() -> void:
	var ext := DCWorldExt.new()
	_expect("failure fixture starts", ext.start_runtime_worker(_config(true)).get("ok", false))
	_expect("save fault is armed", ext.arm_runtime_fault_injection("save.barrier.before"))
	var failed: Dictionary = await _save(ext, 84)
	_expect("save failure is reported", not failed.get("ok", true) and failed.get("code", "") == "runtime_save_failed")
	_expect("save failure preserves fault state", ext.get_runtime_control_state().get("state", "") == "FAULTED")
	await _stop(ext)

func _stop(ext: Object) -> void:
	ext.request_runtime_stop()
	var deadline := Time.get_ticks_msec() + 3000
	while Time.get_ticks_msec() < deadline and not ext.get_runtime_thread_report().get("simulation_executor_exited", false):
		await process_frame
	_expect("executor releases its resources", ext.get_runtime_thread_report().get("simulation_executor_exited", false))

func _expect(label: String, condition: bool) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("[FAIL] " + label)
