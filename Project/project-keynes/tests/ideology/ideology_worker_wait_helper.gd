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


static func _now_msec() -> int:
	return Time.get_ticks_msec()
