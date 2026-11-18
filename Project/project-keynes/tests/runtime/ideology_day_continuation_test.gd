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

# A boundary request parks the worker. No new daily tick is available until the
# main-thread continuation releases it. Exercise the real host's frame service.
class RefreshProbe extends MapGenerator:
	var instance_calls := 0
	var derived_calls := 0
	var days: Array[int] = []
	func get_runtime_control_state() -> Dictionary:
		return {"authoritative_domain_mask": 0x010}
	func step_ideology_instance_refresh(day: int) -> Dictionary:
		instance_calls += 1
		days.append(day)
		return {"ok": true, "done": instance_calls > 1, "pending": instance_calls == 1}
	func step_ideology_derived_rebuild(day: int) -> Dictionary:
		derived_calls += 1
		days.append(day)
		return {"ok": true, "done": derived_calls > 1, "pending": derived_calls == 1}

class TailProbe extends RefCounted:
	var refresh: RefreshProbe
	var marks: Array = []
	func mark_runtime_day_tail_done(day: int) -> void:
		marks.append([day, refresh.derived_calls])

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
	var refresh := RefreshProbe.new()
	host._generator = refresh
	host._runtime_ready_for_ticks = true
	host._step_ideology_instance_refresh_if_authoritative(591)
	_expect("pending instance retains its request without starting another boundary client",
		refresh.instance_calls == 1 and refresh.derived_calls == 0)
	host._service_runtime_liveness(Time.get_ticks_usec(), true)
	_expect("frame liveness retries the instance while calendar capacity is blocked",
		refresh.instance_calls == 2 and refresh.derived_calls == 1)
	host._service_runtime_liveness(Time.get_ticks_usec(), true)
	_expect("derived continuation completes without another day or repeated instance work",
		refresh.instance_calls == 2 and refresh.derived_calls == 2
		and host._ideology_refresh_pending_day == -1)
	host._service_runtime_liveness(Time.get_ticks_usec(), false)
	_expect("completed work stays idle on later frames",
		refresh.instance_calls == 2 and refresh.derived_calls == 2)
	_expect("every continuation retains the original simulation day", refresh.days == [591, 591, 591, 591])
	host._step_ideology_instance_refresh_if_authoritative(592)
	_expect("the next day schedules both passes again",
		refresh.instance_calls == 3 and refresh.derived_calls == 3)
	var tail := preload("res://scripts/game/world_runtime_daily_adapter_part3.gd").new()
	var tail_probe := TailProbe.new()
	tail_probe.refresh = refresh
	refresh._data_core_world_ext = tail_probe
	host._ideology_refresh_pending_day = 593
	host._runtime_natural_resource_pending_target_day = 600
	host._runtime_natural_resource_last_commit_day = 599
	tail._mark_runtime_day_tail(host, 600)
	_expect("an unfinished resource day holds the tail and the queued refresh",
		tail_probe.marks == [[599, 3]] and host._ideology_refresh_pending_day == 593)
	host._runtime_natural_resource_pending_target_day = -1
	tail._mark_runtime_day_tail(host, 600)
	_expect("the tail retries the original date before releasing the worker",
		tail_probe.marks == [[599, 3], [600, 4]]
		and refresh.days.slice(-2) == [593, 593] and host._ideology_refresh_pending_day == -1)
	refresh._data_core_world_ext = null
	host.free()
	print("ideology day continuation: %d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures > 0 or _checks != 11 else 0)

func _expect(label: String, condition: bool) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(label)
