extends SceneTree

class CapacityProbe extends RefCounted:
	var ready := false
	var calls := 0
	func wait_climate_consumed(generation: int, timeout: int) -> Dictionary:
		assert(generation == 0 and timeout == 0)
		calls += 1
		return {"ok": ready, "code": "ok" if ready else "climate_wait_timeout_slice"}

class GeneratorProbe extends MapGenerator:
	var probe := CapacityProbe.new()
	var whole_graph := false
	var captured_days: Array[int] = []
	func get_data_core_world_ext():
		return probe
	func get_runtime_thread_report() -> Dictionary:
		return {"climate_worker_authoritative": true, "authority_ready": whole_graph,
			"simulation_thread_mode": "ACTIVE"}
	func capture_runtime_inputs_for_worker(day: int = -1, _phase: float = -1.0) -> Dictionary:
		captured_days.append(day)
		return {"ok": true}

class HostProbe extends WorldRuntimeHost:
	var ticks: Array[int] = []
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
	func _try_promote_economy_pod_active() -> void: pass
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
	generator.whole_graph = true
	host._on_clock_day_changed(11)
	assert(generator.captured_days == [10])
	assert(host.ticks == [10])
	host.free()
	clock.free()
	print("[climate-capacity-backpressure] PASS")
	quit(0)
