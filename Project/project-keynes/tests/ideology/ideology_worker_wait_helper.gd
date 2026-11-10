extends RefCounted

## Day-budgeted waits for worker tests. `max_days` is the test's real timeout
## contract; `hang_guard_ms` only prevents a broken worker protocol from hanging
## the suite forever under heavy load.


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


static func wait_for_runtime_day(host: WorldRuntimeHost, ext: Object,
		day: int, hang_guard_ms: int = 120000) -> bool:
	# Wait for the submitted date, even if it committed before observation.
	# Process the same input requests and replies as the production host.
	wait_until(
		func() -> bool:
			var report: Dictionary = ext.get_runtime_thread_report()
			return (int(report.get("simulation_committed_day", -1)) >= day
				and int(report.get("worker_day_inflight", 1)) == 0) \
				or String(report.get("simulation_host_state", "")) in ["STOPPED", "FAULTED"],
		hang_guard_ms,
		func() -> void: host._service_runtime_liveness(Time.get_ticks_usec(), false))
	host._service_runtime_liveness(Time.get_ticks_usec(), false)
	var report: Dictionary = ext.get_runtime_thread_report()
	return int(report.get("simulation_committed_day", -1)) == day \
		and int(report.get("worker_day_inflight", 1)) == 0 \
		and String(report.get("fault_code", "")).is_empty()


static func _now_msec() -> int:
	return Time.get_ticks_msec()
