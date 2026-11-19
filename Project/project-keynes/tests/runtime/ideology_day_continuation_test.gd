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

# Published days need no rule callbacks to release the remaining day-tail gate.
class TailProbe extends RefCounted:
	var marks: Array[int] = []
	func mark_runtime_day_tail_done(day: int) -> void:
		marks.append(day)
	func record_runtime_main_step(_day: int, _step: StringName) -> void:
		pass

class PublishedWorld extends MapGenerator:
	var steps: Array = []
	func record_runtime_main_step(day: int, step: StringName) -> void:
		steps.append([day, step])

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
	var host := WorldRuntimeHost.new()
	var view := PublishedWorld.new()
	var boundary := TailProbe.new()
	view._data_core_world_ext = boundary
	host._generator = view
	var tail := preload("res://scripts/game/world_runtime_daily_adapter_part3.gd").new()
	_expect("published world starts with no day tail", boundary.marks.is_empty())
	tail._mark_runtime_day_tail(host, 591)
	_expect("a published day releases the gate immediately", boundary.marks == [591])
	_expect("a published day advances the foreground cursor", host._runtime_tail_completed_day == 591)
	_expect("the only main step is acknowledging the published day",
		view.steps == [[591, &"acknowledge_day_tail"]])
	tail._mark_runtime_day_tail(host, 591)
	_expect("re-reading a day records no simulation work", view.steps.size() == 1)
	tail._mark_runtime_day_tail(host, 592)
	_expect("the next published day releases the same gate", boundary.marks[-1] == 592)
	_expect("the next day only records confirmation", view.steps[-1] == [592, &"acknowledge_day_tail"])
	tail._mark_runtime_day_tail(host, 591)
	_expect("an older display cursor cannot rewind the confirmed day", host._runtime_tail_completed_day == 592)
	view._data_core_world_ext = null
	host.free()
	print("ideology day continuation: %d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures > 0 or _checks != 11 else 0)

func _expect(label: String, condition: bool) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(label)
