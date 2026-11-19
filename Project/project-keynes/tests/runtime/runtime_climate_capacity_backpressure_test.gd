extends SceneTree

class CapacityProbe extends RefCounted:
	var ready := false
	var calls := 0
	var calendar_requests: Array[int] = []
	func request_runtime_calendar_day(date: int) -> int:
		calendar_requests.append(date)
		return date - 1
	func wait_climate_consumed(generation: int, timeout: int) -> Dictionary:
		assert(generation == 0 and timeout == 0)
		calls += 1
		return {"ok": ready, "code": "ok" if ready else "climate_wait_timeout_slice"}

class GeneratorProbe extends MapGenerator:
	var probe := CapacityProbe.new()
	var whole_graph := false
	var committed_day := -1
	var captured_days: Array[int] = []
	func get_data_core_world_ext():
		return probe
	func get_runtime_thread_report() -> Dictionary:
		return {"climate_worker_authoritative": true, "authority_ready": whole_graph,
			"simulation_thread_mode": "ACTIVE", "simulation_committed_day": committed_day}
	func publish_environment_through(last_day: int, _phase: float,
			_callsite: int = 0) -> Dictionary:
		captured_days.append(last_day)
		return {"ok": true}

class HostProbe extends WorldRuntimeHost:
	var ticks: Array[int] = []
	var consume_writeback_day := -1
	func _consume_modifier_worker_snapshot_if_authoritative() -> void: pass
	func _consume_effect_worker_snapshot_if_authoritative() -> void: pass
	func _service_effect_worker_intents_if_authoritative() -> void: pass
	func _consume_trigger_worker_snapshot_if_authoritative() -> void: pass
	func _service_trigger_worker_intents_if_authoritative() -> void: pass
	func _consume_ideology_worker_snapshot_if_authoritative() -> void: pass
	func _service_ideology_worker_intents_if_authoritative() -> void: pass
	func _apply_climate_writeback_if_authoritative(_report: Dictionary) -> void: pass
	func _service_country_worker_transport() -> void: pass
	func _consume_country_worker_read_view_if_authoritative() -> void: pass
	func _consume_runtime_commit_if_ready(_report_override: Dictionary = {}) -> void:
		if consume_writeback_day >= 0:
			_runtime_climate_writeback_last_day = consume_writeback_day
			_runtime_tail_completed_day = consume_writeback_day
			var generator := _generator as GeneratorProbe
			generator.committed_day = consume_writeback_day
	func _observe_runtime_worker_fault(_report: Dictionary = {}) -> void: pass
	func _poll_runtime_health() -> void: pass
	func _service_runtime_liveness(_frame_usec: int, _capacity_pending: bool) -> void: pass
	func _service_runtime_progress(_frame_usec: int) -> void: pass
	func run_daily_tick(day: int, _phase: float) -> Dictionary:
		ticks.append(day)
		return {}

func _init() -> void:
	var host := HostProbe.new()
	var generator := GeneratorProbe.new()
	var clock := WorldClock.new()
	clock.pause(false)
	host._generator = generator
	host._world_clock = clock
	host._runtime_ready_for_ticks = true
	host._on_clock_day_changed(10)
	assert(generator.probe.calls == 1)
	assert(host.ticks.is_empty())
	assert(host._climate_capacity_pending_day == 10)
	assert(clock.has_simulation_backpressure())
	assert(clock._has_hard_day_barrier())
	assert(not clock.needs_continuation_pulse())
	assert(not clock.paused)
	generator.probe.ready = true
	host._on_clock_day_changed(host._climate_capacity_pending_day)
	assert(host.ticks == [10])
	assert(host._climate_capacity_pending_day == -1)
	assert(not clock.has_simulation_backpressure())
	# A formal executor does not need a slot in the external-input queue.
	# Keep the queue full and the last display frame stale across two requests.
	generator.whole_graph = true
	generator.probe.ready = false
	host._native_environment_active = true
	var previous_calls := generator.probe.calls
	host._on_clock_day_changed(11)
	host._on_clock_day_changed(12)
	assert(generator.probe.calendar_requests == [11, 12])
	assert(generator.probe.calls == previous_calls)
	assert(generator.captured_days.is_empty())
	assert(host.ticks == [10])
	assert(host._calendar_admitted_through == 11)
	assert(host._climate_capacity_pending_day == -1)
	assert(not clock.has_simulation_backpressure())
	_test_climate_calendar(generator, clock)
	host.free()
	clock.free()
	print("[climate-capacity-backpressure] PASS")
	quit(0)

func _test_climate_calendar(generator: MapGenerator, clock: WorldClock) -> void:
	generator.set_world_clock_ref(clock)
	var capture = generator._get_runtime_climate_capture()
	capture.calendar_day = 93
	generator._last_climate_pass_day = 92.0
	generator._last_sea_ice_pass_day = 92.0
	for display_day in [91.125, 94.75]:
		clock.current_day = display_day
		assert(generator._consume_climate_dt_days() == 1.0)
		assert(generator._consume_sea_ice_dt_days() == 1.0)
		var weather := generator._native_daily_weather_clock_values(0.0)
		assert(weather.season_idx == clock.season_index_for_day(93))
		assert(weather.season_phase == clock.season_phase_for_day(93))
	capture.calendar_day = -1
	assert(capture.sample_day() == clock.current_day)
	clock.seed_annual_climate(20260718)
	clock._apply_year_rollover(1)
	var checkpoint := clock.export_state()
	clock._apply_year_rollover(2)
	var reference := clock.climate_anomaly
	var restored := WorldClock.new()
	assert(restored.restore_state(checkpoint).ok)
	restored._apply_year_rollover(2)
	assert(restored.climate_anomaly == reference)
	restored.free()
