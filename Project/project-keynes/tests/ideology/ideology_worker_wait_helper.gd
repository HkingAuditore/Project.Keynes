extends RefCounted

## Shared day driving and waits for worker tests. `max_days` is the test's real
## timeout contract; `hang_guard_ms` only stops a broken worker protocol from
## hanging the suite.


static func wait_for(
		predicate: Callable,
		max_days: int,
		hang_guard_ms: int = 120000,
		drive_day: Callable = Callable()) -> bool:
	# The caller owns day driving because only the test knows its clock/host.
	# This helper owns the day budget and the independent hang guard.
	var started := _now_msec()
	for _day in range(maxi(0, max_days) + 1):
		if bool(predicate.call()):
			return true
		if _day >= max_days:
			break
		if _now_msec() - started >= hang_guard_ms:
			return false
		if not drive_day.is_valid():
			await Engine.get_main_loop().process_frame
		else:
			await drive_day.call()
	return bool(predicate.call())


static func wait_until(
		predicate: Callable,
		hang_guard_ms: int = 120000,
		service: Callable = Callable()) -> bool:
	var deadline := _now_msec() + maxi(0, hang_guard_ms)
	while _now_msec() < deadline:
		if bool(predicate.call()):
			return true
		if service.is_valid():
			service.call()
		OS.delay_msec(2)
	return bool(predicate.call())


## One lockstep day for a worker test, driven the way the game drives it:
## submit `day` through the host, run the worker clock until the worker commits
## the frame that day publishes (day - 1, see publish_environment_through) and
## the clock would let the next day start, then pause it again. While waiting,
## the host runs its own per-frame service and the clock's continuation pulse,
## so peers, inputs, snapshots and day barriers are handled as in a running
## game. Returns {ok, day, committed_day, ideology_day}; on failure `ok` is
## false and `code` plus the worker's own diagnosis say what it waited for.
static func drive_worker_day(host: WorldRuntimeHost, clock: WorldClock,
		ext: Object, day: int, speed: float,
		hang_guard_ms: int = 10000) -> Dictionary:
	clock.current_day = float(day)
	host.run_daily_tick(day, clock.season_phase_for_day(day))
	host.finish_daily_tick(0.0, {})
	# One host frame first, so the inputs published below carry what the day
	# just produced rather than the previous revision.
	host._process(0.0)
	ext.publish_ideology_worker_inputs()
	ext.set_runtime_clock(false, speed)
	var result := wait_committed(host, ext, maxi(0, day - 1), hang_guard_ms)
	if bool(result.get("ok", false)):
		_wait_day_barrier(host, clock, ext, day, result, hang_guard_ms)
	ext.set_runtime_clock(true, speed)
	result["day"] = day
	return result


static func drive_worker_days(host: WorldRuntimeHost, clock: WorldClock,
		ext: Object, first_day: int, days: int, speed: float) -> Dictionary:
	var result := {"ok": true, "day": first_day - 1}
	for day in range(first_day, first_day + days):
		result = drive_worker_day(host, clock, ext, day, speed)
		if not bool(result.get("ok", false)):
			break
	return result


## Waits until the worker has committed `day` with nothing in flight, running
## the host's frame service meanwhile.
static func wait_committed(host: WorldRuntimeHost, ext: Object, day: int,
		hang_guard_ms: int = 10000) -> Dictionary:
	wait_until(
		func() -> bool:
			var live: Dictionary = ext.get_runtime_thread_report()
			return (int(live.get("simulation_committed_day", -1)) >= day
				and int(live.get("worker_day_inflight", 1)) == 0) \
				or String(live.get("simulation_host_state", "")) in ["STOPPED", "FAULTED"],
		hang_guard_ms,
		func() -> void: host._process(0.0))
	host._process(0.0)
	var report: Dictionary = ext.get_runtime_thread_report()
	var committed := int(report.get("simulation_committed_day", -1))
	var result := {
		"ok": committed >= day and int(report.get("worker_day_inflight", 1)) == 0
			and String(report.get("fault_code", "")).is_empty(),
		"committed_day": committed,
		"ideology_day": int(report.get("ideology_pod_committed_day", -1)),
	}
	if not bool(result["ok"]):
		result["code"] = _wait_failure_code(report)
		_attach_diagnosis(result, report)
		printerr("[worker-wait] day %d not committed: %s" % [day, str(result)])
	return result


## WorldClock does not start a new day while a hard day barrier is up; for
## continuation barriers it pulses once per frame until they lift.
static func _wait_day_barrier(host: WorldRuntimeHost, clock: WorldClock,
		ext: Object, day: int, result: Dictionary, hang_guard_ms: int) -> void:
	var lifted := wait_until(
		func() -> bool: return not clock._day_advance_blocked_by_barrier(),
		hang_guard_ms,
		func() -> void:
			if clock.needs_continuation_pulse():
				clock.simulation_backpressure_pulse.emit(day)
			host._process(0.0))
	if lifted:
		return
	result["ok"] = false
	result["code"] = "day_barrier_held"
	result["barriers"] = clock._simulation_backpressure_sources.keys()
	_attach_diagnosis(result, ext.get_runtime_thread_report())
	printerr("[worker-wait] day %d barrier held: %s" % [day, str(result)])


## Requests a runtime save as GameSaveCoordinator does and services host frames
## until it is ready. `country_worker_save_barrier` is waited out: it names
## Country results the host has not serviced yet. Returns the poll result; on
## failure `ok` is false with `code` and the worker's diagnosis.
static func request_worker_save(host: WorldRuntimeHost, ext: Object,
		request_id: int, hang_guard_ms: int = 10000) -> Dictionary:
	var deadline := _now_msec() + hang_guard_ms
	var request: Dictionary = host._generator.request_runtime_save(request_id)
	while String(request.get("code", "")) == "country_worker_save_barrier" \
			and _now_msec() < deadline:
		host._process(0.0)
		OS.delay_msec(2)
		request = host._generator.request_runtime_save(request_id)
	if not bool(request.get("pending", false)):
		return _save_failure(request, ext)
	var saved: Dictionary = {}
	while _now_msec() < deadline:
		saved = host._generator.poll_runtime_save(request_id)
		if bool(saved.get("ready", false)):
			return saved
		if not bool(saved.get("ok", true)) and not bool(saved.get("pending", false)):
			return _save_failure(saved, ext)
		host._process(0.0)
		OS.delay_msec(2)
	saved["ok"] = false
	saved["code"] = "save_not_ready"
	return _save_failure(saved, ext)


static func _save_failure(result: Dictionary, ext: Object) -> Dictionary:
	var out := result.duplicate()
	out["ok"] = false
	out["ready"] = false
	_attach_diagnosis(out, ext.get_runtime_thread_report())
	printerr("[worker-save] %s" % str(out))
	return out


static func _wait_failure_code(report: Dictionary) -> String:
	var fault := String(report.get("fault_code", ""))
	if not fault.is_empty():
		return fault
	var state := String(report.get("simulation_host_state", ""))
	if state in ["STOPPED", "FAULTED"]:
		return "worker_%s" % state.to_lower()
	return "day_not_committed"


static func _attach_diagnosis(out: Dictionary, report: Dictionary) -> void:
	for key in ["simulation_host_state", "fault_code", "day_park_reason",
			"day_park_domain_mask", "day_stall_reason_mask", "day_wait_day",
			"day_wait_missing_mask", "simulation_environment_day"]:
		out[key] = report.get(key)


static func _now_msec() -> int:
	return Time.get_ticks_msec()
