extends "res://tests/runtime/runtime_inline_save_restore_test.gd"

# Accepted work belongs to the world across executor lifetimes. Exercise both
# the drained backlog and packets still in ingress when stop is requested.
func _run() -> void:
	for source_inline in [false, true]:
		for target_inline in [false, true]:
			await _restart(source_inline, target_inline)
		await _rejected_start(source_inline)
	await _stop_wakeup()
	await _clock_wait_controls()
	await _invalid_restore_start()
	for source_inline in [false, true]:
		await _unfinished_day_restart(source_inline)
	print("executor boundaries: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)

func _command(ext: Object, id: int) -> Dictionary:
	return ext.submit_runtime_command({"request_id": id, "producer_id": 2,
		"requested_day": 1, "domain": 1, "opcode": 1})

func _restart(source_inline: bool, target_inline: bool) -> void:
	var ext := DCWorldExt.new()
	_expect("restart source starts", ext.start_runtime_worker(_config(source_inline)).get("ok", false))
	var first := _command(ext, 501)
	_expect("first command is accepted", first.get("pending", false))
	var saved: Dictionary = await _save(ext, 91)
	_expect("save moves accepted work into backlog", saved.get("pending_command_count", -1) == 1)
	var second := _command(ext, 502)
	_expect("second command remains in ingress", second.get("pending", false))
	await _stop(ext)
	_expect("restart target starts", ext.start_runtime_worker(_config(target_inline)).get("ok", false))
	var after: Dictionary = await _save(ext, 92)
	_expect("restart retains backlog and ingress", after.get("pending_command_count", -1) == 2)
	var third := _command(ext, 503)
	_expect("producer sequence survives restart", int(third.get("sequence", 0)) > int(second.get("sequence", 0)))
	await _day(ext, target_inline, 1)
	var ids := PackedInt64Array()
	for receipt in ext.poll_runtime_receipts(10).get("receipts", []):
		ids.append(int(receipt.request_id))
	_expect("all commands settle once in their original order", ids == PackedInt64Array([501, 502, 503]))
	await _stop(ext)
	_expect("second restart starts", ext.start_runtime_worker(_config(source_inline)).get("ok", false))
	var settled: Dictionary = await _save(ext, 93)
	_expect("settled commands never reappear after restart", settled.get("pending_command_count", -1) == 0)
	await _stop(ext)

func _rejected_start(inline_mode: bool) -> void:
	var ext := DCWorldExt.new()
	_expect("rejected-start fixture starts", ext.start_runtime_worker(_config(inline_mode)).get("ok", false))
	_expect("rejected-start command accepted", _command(ext, 601).get("pending", false))
	var saved: Dictionary = await _save(ext, 94)
	_expect("original executor owns one pending command", saved.get("pending_command_count", -1) == 1)
	var before: Dictionary = ext.get_runtime_thread_report()
	_expect("executor report exposes actual parallel mode", before.has("executor_serial_only"))
	var rejected: Dictionary = ext.start_runtime_worker(_config(not inline_mode))
	_expect("live executor switch is refused", not rejected.get("ok", true) and rejected.get("code", "") == "runtime_thread_mode_hot_switch_forbidden")
	var after: Dictionary = ext.get_runtime_thread_report()
	_expect("refused switch preserves executor and parallel mode", after.get("native_daily_inline") == before.get("native_daily_inline") and after.get("executor_serial_only") == before.get("executor_serial_only"))
	var resaved: Dictionary = await _save(ext, 95)
	_expect("refused switch cannot hide the accepted backlog", resaved.get("pending_command_count", -1) == 1)
	await _day(ext, inline_mode, 1)
	var receipts: Array = ext.poll_runtime_receipts(10).get("receipts", [])
	_expect("original executor still settles its command", receipts.size() == 1 and int(receipts[0].request_id) == 601)
	await _stop(ext)
	# Invalid configurations on a stopped host must not change its executor either.
	var invalid := _config(not inline_mode)
	invalid["day"] = -1
	_expect("invalid start is refused", not ext.start_runtime_worker(invalid).get("ok", true))
	_expect("invalid start leaves executor selection untouched", ext.get_runtime_thread_report().get("native_daily_inline") == inline_mode)

func _stop_wakeup() -> void:
	var ext := DCWorldExt.new()
	var completed := 0
	for iteration in 3000:
		if not ext.start_runtime_worker(_config(false)).get("ok", false):
			break
		# Observe entry to the paused wait, then stop without issuing a second
		# notification. This exercises the real Host wiring beside the native
		# test's controlled check-to-wait interleaving.
		while ext.get_runtime_control_state().get("state", "") == "STARTING":
			OS.delay_usec(10)
		ext.request_runtime_stop()
		var deadline := Time.get_ticks_msec() + 3000
		while not ext.get_runtime_control_state().get("simulation_executor_exited", false) and Time.get_ticks_msec() < deadline:
			OS.delay_usec(50)
		if not ext.get_runtime_control_state().get("simulation_executor_exited", false):
			# Release a failed fixture before teardown; this is not a retry in
			# the assertion or in the production close path.
			ext.request_runtime_stop()
			await _stop(ext)
			break
		completed += 1
	_expect("one stop notification releases every paused worker", completed == 3000)

func _clock_wait_controls() -> void:
	for action in ["stop", "save", "pause", "speed"]:
		var ext := DCWorldExt.new()
		_expect("clock-wait fixture starts", ext.start_runtime_worker(_config(false, 0x800)).get("ok", false))
		while ext.get_runtime_control_state().get("state", "") == "STARTING":
			OS.delay_usec(10)
		var accepted := 0
		for index in 4096:
			if ext.submit_runtime_command({"request_id": 10000 + index, "producer_id": 2,
				"requested_day": 50, "domain": 1, "opcode": 1}).get("pending", false):
				accepted += 1
		_expect("clock-wait ingress is full", accepted == 4096)
		ext.set_runtime_clock(false, 0.0001)
		var deadline := Time.get_ticks_msec() + 3000
		while ext.get_runtime_control_state().get("state", "") != "RUNNING" and Time.get_ticks_msec() < deadline:
			OS.delay_usec(1)
		if action == "stop":
			ext.request_runtime_stop()
		elif action == "save":
			_expect("clock-wait save is accepted", ext.request_runtime_save(301).get("ok", false))
		elif action == "pause":
			ext.set_runtime_clock(true, 0.0)
		else:
			_expect("speed-change input is accepted", ext.capture_runtime_inputs({"generation": 1,
				"day": 1, "terrain": PackedByteArray([1]), "landform": PackedByteArray([0]),
				"has_river": PackedByteArray([0]), "neighbor_indices": PackedInt32Array([-1, -1, -1, -1, -1, -1])}).get("ok", false))
			ext.set_runtime_clock(false, 1000.0)
		var delivered := false
		deadline = Time.get_ticks_msec() + 1000
		while Time.get_ticks_msec() < deadline:
			if action == "save":
				delivered = bool(ext.poll_runtime_save(301).get("ready", false))
			elif action == "stop":
				delivered = bool(ext.get_runtime_control_state().get("simulation_executor_exited", false))
			elif action == "pause":
				delivered = ext.get_runtime_control_state().get("state", "") == "PAUSED"
			else:
				delivered = int(ext.get_runtime_thread_report().get("simulation_committed_day", 0)) > 0
			if delivered:
				break
			OS.delay_usec(50)
		_expect("one %s control crosses the clock-wait boundary" % action, delivered)
		await _stop(ext)

func _unfinished_day_restart(source_inline: bool) -> void:
	var ext := DCWorldExt.new()
	_expect("partial-day source starts", ext.start_runtime_worker(_config(source_inline, 0x805)).get("ok", false))
	var frame := {"generation": 1, "day": 1, "terrain": PackedByteArray([1]),
		"landform": PackedByteArray([0]), "has_river": PackedByteArray([0]),
		"neighbor_indices": PackedInt32Array([-1, -1, -1, -1, -1, -1])}
	_expect("partial-day input is accepted", ext.capture_runtime_inputs(frame).get("ok", false))
	if source_inline:
		_expect("partial inline day waits for its owner", not ext.run_native_daily_inline_day().get("ok", true))
	else:
		ext.set_runtime_clock(false, 1000.0)
		var deadline := Time.get_ticks_msec() + 3000
		while not ext.get_runtime_thread_report().get("inline_day_pending", false) and Time.get_ticks_msec() < deadline:
			await process_frame
	_expect("unfinished day is visible before stop", ext.get_runtime_thread_report().get("inline_day_pending", false))
	await _stop(ext)
	# These diagnostic inputs can supersede the FIFO; they must not replace the
	# frame already frozen by the uncommitted day.
	for day in range(2, 67):
		frame["generation"] = day
		frame["day"] = day
		_expect("later input is accepted after stop", ext.capture_runtime_inputs(frame).get("ok", false))
	_expect("partial day changes executor", ext.start_runtime_worker(_config(true, 0x805)).get("ok", false))
	_expect("partial marker survives executor replacement", ext.get_runtime_thread_report().get("inline_day_pending", false))
	_expect("partial-day save request is accepted", ext.request_runtime_save(303).get("ok", false))
	var saved: Dictionary = ext.poll_runtime_save(303)
	_expect("replacement executor cannot save half a day", saved.get("pending", false) and not saved.get("ready", false))
	var retried: Dictionary = ext.run_native_daily_inline_day()
	_expect("same-day retry retains its original frozen frame", not retried.get("ok", true) and retried.get("environment_day", -1) == 1)
	await _stop(ext)

func _invalid_restore_start() -> void:
	var source := DCWorldExt.new()
	_expect("invalid restore source starts", source.start_runtime_worker(_config(true)).get("ok", false))
	for day in range(1, 4):
		await _day(source, true, day)
	_expect("restore fixture keeps a future command", source.submit_runtime_command({"request_id": 8001,
		"producer_id": 2, "requested_day": 4, "domain": 1, "opcode": 1}).get("pending", false))
	var saved: Dictionary = await _save(source, 302)
	await _stop(source)
	for target_inline in [false, true]:
		var ext := DCWorldExt.new()
		_expect("day-three archive decodes", ext.restore_runtime_bundle(saved.get("bytes", PackedByteArray())).get("ok", false))
		var before: Dictionary = ext.get_runtime_thread_report()
		var invalid := _config(true)
		invalid["simulation_thread_mode"] = "SHADOW"
		_expect("conflicting executor request is rejected", not ext.start_runtime_worker(invalid).get("ok", true))
		var after: Dictionary = ext.get_runtime_thread_report()
		_expect("conflict leaves executor and parallel selection intact", before.get("native_daily_inline") == after.get("native_daily_inline") and before.get("executor_serial_only") == after.get("executor_serial_only"))
		_expect("valid retry starts", ext.start_runtime_worker(_config(target_inline)).get("ok", false))
		_expect("valid retry retains the saved calendar", ext.get_runtime_thread_report().get("simulation_committed_day", -1) == 3)
		_expect("valid retry retains pending commands", ext.get_runtime_thread_report().get("economy_pending_command_count", -1) == 1)
		await _day(ext, target_inline, 4)
		var receipts: Array = ext.poll_runtime_receipts(10).get("receipts", [])
		_expect("valid retry executes the original command once", receipts.size() == 1 and int(receipts[0].request_id) == 8001)
		await _stop(ext)
