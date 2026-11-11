extends "res://tests/economy/economy_cadence_runtime_test.gd"

var _checks := 0


func _expect(label: String, condition: bool) -> void:
	_checks += 1
	super._expect(label, condition)


## Use a paused SHADOW executor so Economy can be stopped between slices while
## the native save service still takes a real request at its own day boundary.
func _run() -> void:
	var compiled := EconomyCatalogScript.compile_native_catalog()
	_expect("catalog compiles", compiled.get("ok", false))
	if not compiled.get("ok", false):
		return
	var ext := _boot(compiled, 4, 0.01, 0.01, 612, {
		"building_plan_cells_per_slice": 1, "economy_cadence_force_market_days": 1})
	var first := _run_day(ext, 0)
	_expect("the fixture commits its first settlement", first.get("done", false)
		and not first.get("fatal", true) and first.get("last_committed_day", -1) == 0)
	var partial: Dictionary = {}
	for slice in 128:
		partial = ext.run_economy_slice({"day_index": 1})
		if partial.get("epoch_active", false) or partial.get("done", false) or partial.get("fatal", false):
			break
	_expect("a later settlement is still in progress", partial.get("epoch_active", false)
		and not partial.get("done", true) and not partial.get("fatal", true))
	var started: Dictionary = ext.start_runtime_worker({"simulation_thread_mode": "SHADOW",
		"day": 0, "paused": true, "graph_coverage_complete": false,
		"economy_ecp2_dual_write": true})
	_expect("native save service starts with ECP2 capture enabled", started.get("ok", false))
	if not started.get("ok", false):
		return
	var before: int = ext.get_economy_state_hash()
	var rejected := _request_capture(ext, 1)
	_expect("native capture rejects the unfinished settlement and publishes no bundle",
		not rejected.get("ok", true) and not rejected.get("ready", false)
		and rejected.get("code", "") == "runtime_save_failed"
		and rejected.get("reason", "") == "save_requires_committed_boundary"
		and (rejected.get("bytes", PackedByteArray()) as PackedByteArray).is_empty())
	_expect("rejection leaves the executor healthy and the partial economy intact",
		ext.get_runtime_control_state().get("state", "") != "FAULTED"
		and ext.get_economy_state_hash() == before)
	var finished := _run_day(ext, 1)
	_expect("the interrupted settlement can finish", finished.get("done", false)
		and not finished.get("fatal", true) and finished.get("last_committed_day", -1) == 1)
	var captured := _request_capture(ext, 2)
	_expect("the next request publishes a bundle with its full Economy section",
		captured.get("ready", false) and captured.get("ok", false)
		and (captured.get("economy_ecp2", PackedByteArray()) as PackedByteArray).size() > 0)
	ext.request_runtime_stop()
	var deadline := Time.get_ticks_msec() + 3000
	while Time.get_ticks_msec() < deadline and not ext.get_runtime_thread_report().get("simulation_executor_exited", false):
		OS.delay_msec(2)
	_expect("the executor exits after the rejected and successful saves",
		ext.get_runtime_thread_report().get("simulation_executor_exited", false))
	print("economy settlement save boundary: %d checks, %d failures" % [_checks, _failures])


func _request_capture(ext: Object, request_id: int) -> Dictionary:
	var requested: Dictionary = ext.request_runtime_save(request_id)
	_expect("native save request is admitted", requested.get("ok", false))
	if not requested.get("ok", false):
		return requested
	var deadline := Time.get_ticks_msec() + 3000
	var result: Dictionary = {}
	while Time.get_ticks_msec() < deadline:
		result = ext.poll_runtime_save(request_id)
		if result.get("ready", false) or not result.get("ok", true):
			return result
		OS.delay_msec(2)
	return result
