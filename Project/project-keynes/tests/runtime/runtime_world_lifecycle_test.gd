extends "res://tests/runtime/runtime_country_save_roundtrip_test.gd"

func _init() -> void:
	call_deferred("_finish")

func _finish() -> void:
	await _run()
	print("runtime world lifecycle: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)

func _run() -> int:
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("lifecycle catalog compiles", compiled.get("ok", false))
	compiled.erase("ok")
	for inline_mode in [false, true]:
		await _same_world(compiled, inline_mode)
		await _new_world(compiled, inline_mode)
	return 0

func _configuration(inline_mode: bool) -> Dictionary:
	return {"simulation_thread_mode": "ACTIVE", "graph_coverage_complete": true,
		"native_daily_inline": inline_mode, "authoritative_domain_mask": 0x807,
		"day": 0, "speed_days_per_second": 0.0, "paused": true}

func _setup_country(ext: Object, catalog: Dictionary, seed: int) -> void:
	_expect("lifecycle Country configures", ext.configure_country(catalog,
		{"country_runtime_mode": "ACTIVE", "starting_technology_ids": PackedStringArray()},
		2, seed).get("ok", false))
	_expect("lifecycle Country bootstraps", ext.bootstrap_country({}, PackedByteArray([0, 0])).get("ok", false))
	_expect("lifecycle catalog captures", ext.capture_country_pod_catalog().get("ok", false))
	_expect("lifecycle snapshot captures", ext.capture_country_runtime_snapshot().get("ok", false))
	_capture_input(ext, 0)

func _stop(ext: Object) -> void:
	ext.request_runtime_stop()
	var deadline := Time.get_ticks_msec() + 3000
	while not ext.get_runtime_thread_report().get("simulation_executor_exited", false) and Time.get_ticks_msec() < deadline:
		await process_frame
	_expect("lifecycle executor has returned", ext.get_runtime_thread_report().get("simulation_executor_exited", false))

func _day(ext: Object, inline_mode: bool, day: int) -> void:
	_capture_input(ext, day)
	if inline_mode:
		_expect("lifecycle inline day commits", ext.run_native_daily_inline_day().get("ok", false))
	else:
		ext.set_runtime_clock(false, 1.0)
		var deadline := Time.get_ticks_msec() + 3000
		while int(ext.get_runtime_thread_report().get("simulation_committed_day", -1)) < day and Time.get_ticks_msec() < deadline:
			OS.delay_usec(100)
		ext.set_runtime_clock(true, 0.0)
		while int(ext.get_runtime_thread_report().get("worker_day_inflight", 1)) != 0 and Time.get_ticks_msec() < deadline:
			OS.delay_usec(100)
	_expect("lifecycle day is exact", int(ext.get_runtime_thread_report().get("simulation_committed_day", -1)) == day)

func _capture_input(ext: Object, day: int) -> void:
	var generation := int(ext.get_runtime_thread_report().get("simulation_environment_generation", 0)) + 1
	_expect("lifecycle day input seals", ext.capture_runtime_inputs({"generation": generation,
		"day": day, "terrain": PackedByteArray([1, 1]), "landform": PackedByteArray([0, 0]),
		"climate_map_width": 2, "climate_map_height": 1, "climate_catalog_hash": 7,
		"cell_temp": PackedFloat32Array([15.0, 15.0]), "cell_moisture": PackedFloat32Array([0.5, 0.5]),
		"has_river": PackedByteArray([0, 0]),
		"neighbor_indices": PackedInt32Array([-1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1])}).get("ok", false))

func _rename(ext: Object, day: int, name: String) -> Dictionary:
	return ext.submit_country_commands(_commands([{"opcode": 2, "day": day,
		"handle": int(ext.get_country_cell_summary(0).get("country_handle", 0)), "name": name}]))

func _same_world(catalog: Dictionary, inline_mode: bool) -> void:
	var ext := DCWorldExt.new()
	_setup_country(ext, catalog, 101)
	_expect("same-world executor starts", ext.start_runtime_worker(_configuration(inline_mode)).get("ok", false))
	await _day(ext, inline_mode, 1)
	var command := _rename(ext, 2, "Committed Country")
	_expect("same-world rename is accepted", command.get("ok", false))
	await _day(ext, inline_mode, 2)
	var before: Dictionary = ext.get_country_worker_read_view(0)
	var receipts: Dictionary = ext.poll_country_command_receipts(0, 10)
	_expect("same-world command has a durable result", receipts.get("count", 0) == 1)
	await _stop(ext)
	var session_before := int(ext.get_country_worker_protocol_status().get("session_epoch", 0))
	var invalid: Dictionary = ext.configure_country({}, {"country_runtime_mode": "ACTIVE"}, 2, 505)
	_expect("invalid world configuration is rejected", not invalid.get("ok", true))
	_expect("invalid configuration retains the session", session_before > 0 and ext.get_country_worker_protocol_status().get("session_epoch", 0) == session_before)
	_expect("invalid configuration retains the world calendar", ext.get_runtime_thread_report().get("simulation_committed_day", -1) == 2)
	_expect("invalid configuration retains Country and its results", ext.get_country_cell_summary(0).get("country_name", "") == "Committed Country" and ext.poll_country_command_receipts(0, 10).get("receipts", []) == receipts.get("receipts", []))
	invalid = ext.configure_country(catalog, {"country_runtime_mode": "ACTIVE",
		"starting_technology_ids": PackedStringArray(["missing_lifecycle_technology"])}, 2, 505)
	_expect("late configuration failure is rejected", not invalid.get("ok", true) and invalid.get("reason", "") == "country_starting_technology_unknown")
	_expect("late configuration failure preserves Country state and session", ext.get_country_cell_summary(0).get("country_name", "") == "Committed Country" and ext.get_country_worker_protocol_status().get("session_epoch", 0) == session_before and ext.get_runtime_thread_report().get("simulation_committed_day", -1) == 2)
	for repeat in 2:
		_expect("identical catalog recapture succeeds", ext.capture_country_pod_catalog().get("ok", false))
		var captured: Dictionary = ext.capture_country_runtime_snapshot()
		_expect("recapture uses the committed owner", captured.get("state_hash", 0) == before.get("state_hash", -1))
		_expect("catalog recapture retains completed results", ext.poll_country_command_receipts(0, 10).get("receipts", []) == receipts.get("receipts", []))
	_expect("same-world executor restarts", ext.start_runtime_worker(_configuration(inline_mode)).get("ok", false))
	_expect("same-world restart retains the session identity", ext.get_country_worker_protocol_status().get("session_epoch", 0) == session_before)
	_expect("restart keeps committed Country data", ext.get_country_cell_summary(0).get("country_name", "") == "Committed Country")
	_expect("restart keeps Country business hash", ext.get_country_worker_read_view(0).get("state_hash", 0) == before.get("state_hash", -1))
	_expect("restart keeps the unclaimed result", ext.poll_country_command_receipts(0, 10).get("receipts", []) == receipts.get("receipts", []))
	var next := _rename(ext, 3, "Continued Country")
	_expect("restart allocates a later request identity", next.get("ok", false) and int(next.get("request_ids", PackedInt64Array([0]))[0]) > int(command.get("request_ids", PackedInt64Array([0]))[0]))
	await _day(ext, inline_mode, 3)
	_expect("same-world restart continues business", ext.get_country_cell_summary(0).get("country_name", "") == "Continued Country")
	await _stop(ext)

func _new_world(catalog: Dictionary, inline_mode: bool) -> void:
	var ext := DCWorldExt.new()
	_setup_country(ext, catalog, 202)
	_expect("old-world executor starts", ext.start_runtime_worker(_configuration(inline_mode)).get("ok", false))
	await _day(ext, inline_mode, 1)
	_expect("old-world command is admitted", _rename(ext, 2, "OLD WORLD COMMAND").get("ok", false))
	var rejected: Dictionary = ext.configure_country(catalog, {"country_runtime_mode": "ACTIVE"}, 2, 404)
	_expect("new-world configuration requires an exited executor", not rejected.get("ok", true) and rejected.get("code", "") == "country_configure_requires_stopped_runtime")
	_expect("rejected live configuration leaves the calendar intact", ext.get_runtime_thread_report().get("simulation_committed_day", -1) == 1)
	await _stop(ext)
	var old_session := int(ext.get_country_worker_protocol_status().get("session_epoch", 0))
	_setup_country(ext, catalog, 303)
	_expect("new-world executor starts", ext.start_runtime_worker(_configuration(inline_mode)).get("ok", false))
	var report: Dictionary = ext.get_runtime_thread_report()
	_expect("new world starts on its own calendar", report.get("simulation_committed_day", -1) == 0)
	_expect("new world has no old pending commands", report.get("economy_pending_command_count", -1) == 0)
	_expect("new world has no old command results", ext.poll_country_command_receipts(0, 10).get("count", -1) == 0)
	await _day(ext, inline_mode, 1)
	_expect("new world has a later session identity", old_session > 0 and int(ext.get_country_worker_protocol_status().get("session_epoch", 0)) > old_session)
	_expect("old-world commands never affect the new world", ext.get_country_cell_summary(0).get("country_name", "") == "默认国家")
	await _stop(ext)
