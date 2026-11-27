extends SceneTree

# Exercise the production MapGenerator -> WorldClock boundary. Scheduling a
# pending peer poll is distinct from having an unfinished local daily slice.
class DailyProbe extends RefCounted:
	var local_slice_pending := false
	func advance_runtime_pulse(_day: int, _phase: float, _speed: float,
			_budget: int, _flags: int) -> int:
		return 2 << 56
	func ideology_should_run(_day: int) -> bool:
		return true
	func ideology_needs_daily_continuation(_day: int) -> bool:
		return local_slice_pending

var _checks := 0
var _failures := 0

func _init() -> void:
	var generator := MapGenerator.new()
	var clock := WorldClock.new()
	var probe := DailyProbe.new()
	generator._data_core_world_ext = probe
	generator._world_clock_ref = clock
	generator._advance_runtime_graph_pulse(4)
	_expect("pending peer polling does not block the next day",
		not clock.needs_continuation_pulse())
	probe.local_slice_pending = true
	generator._advance_runtime_graph_pulse(4)
	_expect("an unfinished local slice keeps the same-day barrier",
		clock.needs_continuation_pulse())
	probe.local_slice_pending = false
	generator._advance_runtime_graph_pulse(4)
	_expect("graph completion clears the scheduler's same-day barrier",
		not clock.needs_continuation_pulse())
	var dates: Array[int] = []
	var admitted: Array[int] = []
	clock.set_native_climate_calendar(true)
	clock.current_day = 591.0
	clock._last_day = 591
	clock.bind_runtime_calendar(func(date: int) -> int:
		admitted.append(date - 1)
		return date - 1)
	clock.day_changed.connect(func(date: int) -> void: dates.append(date))
	clock.speed_multiplier = 100.0
	clock._process_runtime_calendar(0.03)
	_expect("a single clock call offers three days", admitted == [593])
	_expect("admission alone does not advance the display", dates.is_empty() and clock.day_index() == 591)
	clock.publish_runtime_date(593)
	_expect("one batch emits one display date", dates == [594])
	_expect("the display tracks the last settled date", clock.day_index() == 594)
	clock.publish_runtime_date(593)
	_expect("a repeated publication does not emit again", dates == [594])
	clock.publish_runtime_date(592)
	_expect("an older publication cannot rewind the display", clock.day_index() == 594)
	clock.speed_multiplier = 10.0
	clock._process_runtime_calendar(0.04)
	clock._process_runtime_calendar(0.04)
	var pre_wrap_day: float = clock.current_day
	var pre_wrap_phase: float = clock.visual_day_phase
	clock._process_runtime_calendar(0.04)
	_expect("wrapping runtime admission fraction never rewinds current_day or visual_day_phase",
		clock.current_day >= pre_wrap_day and clock.day_index() == 594
		and clock.visual_day_phase >= pre_wrap_phase)
	clock.bind_runtime_calendar(Callable())
	clock.publish_runtime_date(596)
	_expect("an unbound session cannot publish to the clock", dates == [594])
	_expect("unbinding preserves the displayed date", clock.day_index() == 594)
	clock.free()
	print("ideology day continuation: %d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures > 0 or _checks != 12 else 0)

func _expect(label: String, condition: bool) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(label)
