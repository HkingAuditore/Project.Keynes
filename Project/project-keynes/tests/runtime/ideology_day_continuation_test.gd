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
	clock.free()
	print("ideology day continuation: %d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures > 0 or _checks != 3 else 0)

func _expect(label: String, condition: bool) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(label)
