extends SceneTree

var _failures := 0
var _checks := 0
var _admitted: Array[int] = []
var _hold_next := false
var _clock: WorldClock

func _init() -> void:
	call_deferred("_run")

func _expect(label: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_failures += 1
		push_error("[FAIL] " + label)

func _run() -> void:
	_clock = WorldClock.new()
	_clock.auto_start = false
	root.add_child(_clock)
	_clock.set_process(false)
	await process_frame
	_clock.set_speed(10.0)
	_clock.pause(false)
	_clock.day_changed.connect(func(day: int) -> void:
		_admitted.append(day)
		if _hold_next:
			_clock.request_simulation_backpressure(&"economy_day_barrier", true))
	# Frame input is explicit; no sleep or wall-time threshold determines success.
	for frame in range(5):
		_clock._process(0.1)
	_expect("normal frames admit five consecutive days", _admitted == [1, 2, 3, 4, 5])
	_hold_next = true
	_clock._process(10.0)
	_expect("a long frame stops admission at the unfinished day", _admitted.size() == 6)
	for frame in range(100):
		_clock._process(1.0)
	_expect("sustained overload does not admit more days", _admitted.size() == 6)
	_expect("unscheduled wall time is not retained as whole-day debt", _clock._day_carry < 1.0)
	_hold_next = false
	_clock.request_simulation_backpressure(&"economy_day_barrier", false)
	_clock._process(0.0)
	_expect("releasing the barrier does not replay the blocked real time", _admitted.size() == 6)
	for frame in range(5):
		_clock._process(0.1)
	_expect("recovery returns to selected speed without a catch-up burst", _admitted.size() == 11)
	var expected: Array[int] = []
	for day in range(1, 12): expected.append(day)
	_expect("admitted game days are neither skipped nor repeated", _admitted == expected)
	_clock.free()
	await process_frame
	print("clock overload recovery: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)
