extends SceneTree


class FakeRuntime extends RefCounted:
	var remaining: int
	var fatal := false

	func _init(slice_count: int) -> void:
		remaining = slice_count

	func country_should_run(_day_index: int) -> bool:
		return remaining > 0

	func economy_should_run(_day_index: int) -> bool:
		return remaining > 0

	func report() -> Dictionary:
		return {"epoch_active": remaining > 0, "fatal": fatal}


class FakeFacade extends RefCounted:
	var runtime: FakeRuntime

	func _init(value: FakeRuntime) -> void:
		runtime = value

	func world_ext() -> FakeRuntime:
		return runtime

	func report() -> Dictionary:
		return runtime.report()


class FakeScheduler extends RefCounted:
	var country_runtime: FakeRuntime
	var economy_runtime: FakeRuntime
	var calls: Array[StringName] = []
	var contexts: Array[SusTickContext] = []

	func _init(country: FakeRuntime, economy: FakeRuntime) -> void:
		country_runtime = country
		economy_runtime = economy

	func continue_system(system_id: StringName, ctx: SusTickContext) -> Dictionary:
		calls.append(system_id)
		contexts.append(ctx)
		var runtime := country_runtime if system_id == &"country_daily" else economy_runtime
		runtime.remaining = maxi(0, runtime.remaining - 1)
		return {
			"done": runtime.remaining == 0,
			"stage_name": "country_apply" if system_id == &"country_daily" \
				else "household_market",
			"next_stage": "country_publish" if system_id == &"country_daily" \
				else "aggregate_publish",
			"path": "test",
		}


func _initialize() -> void:
	var clock := WorldClock.new()
	clock.speed_multiplier = 50.0
	clock.sim_frame_budget_ms = 8.0
	clock.request_simulation_backpressure(&"country_day_barrier", true)
	clock.request_simulation_backpressure(&"economy_day_barrier", true)
	var country_runtime := FakeRuntime.new(2)
	var economy_runtime := FakeRuntime.new(5)
	var scheduler := FakeScheduler.new(country_runtime, economy_runtime)
	var generator := MapGenerator.new()
	generator._sus = scheduler
	generator._world_clock_ref = clock
	generator._country_daily_job = RefCounted.new()
	generator._economy_daily_job = RefCounted.new()
	generator._country_facade = FakeFacade.new(country_runtime)
	generator._economy_facade = FakeFacade.new(economy_runtime)

	generator._continue_economy_inflight(17)

	var failures := PackedStringArray()
	if scheduler.calls != [
			&"country_daily", &"country_daily",
			&"economy_daily", &"economy_daily", &"economy_daily",
			&"economy_daily", &"economy_daily"]:
		failures.append("one pulse did not drain consecutive country/economy slices")
	if clock.has_simulation_backpressure():
		failures.append("completed time-box continuation left a day barrier active")
	if scheduler.contexts.is_empty() or not is_equal_approx(
			scheduler.contexts[0].speed_scale, 50.0):
		failures.append("continuation context lost the selected speed multiplier")
	if scheduler.contexts.is_empty() or not is_equal_approx(
			scheduler.contexts[0].season_phase, clock.season_phase()):
		failures.append("continuation context swapped season phase and speed")
	var continuation_perf: Dictionary = generator.consume_continuation_perf_summary()
	var stage_counts: Dictionary = continuation_perf.get("stage_counts", {})
	var stage_totals: Dictionary = continuation_perf.get("stage_wall_ms", {})
	var stage_maxima: Dictionary = continuation_perf.get("stage_max_slice_ms", {})
	if int(stage_counts.get("country:country_apply", 0)) != 2 or \
			int(stage_counts.get("economy:household_market", 0)) != 5:
		failures.append("continuation stage counts did not preserve source/stage buckets")
	if float(stage_totals.get("country:country_apply", -1.0)) < 0.0 or \
			float(stage_maxima.get("economy:household_market", -1.0)) < 0.0:
		failures.append("continuation stage total/max timings were not recorded")
	if String(continuation_perf.get("last_next_stage", "")) != "aggregate_publish":
		failures.append("continuation next stage was not retained separately")

	economy_runtime.remaining = 100
	scheduler.calls.clear()
	clock.sim_frame_budget_ms = 8.0
	clock.request_simulation_backpressure(&"economy_day_barrier", true)
	generator._continue_economy_inflight(18)
	if scheduler.calls.size() != MapGenerator.ECONOMY_CONTINUATION_MAX_SLICES_PER_FRAME \
			or economy_runtime.remaining != 36:
		failures.append("continuation loop did not enforce its defensive slice cap")
	if not clock.has_simulation_backpressure():
		failures.append("slice-cap exhaustion cleared an unfinished economy barrier")

	var resumed_clock := WorldClock.new()
	resumed_clock.speed_multiplier = 50.0
	resumed_clock._last_day = 0
	resumed_clock._last_season = resumed_clock.season_index_for_day(0)
	resumed_clock._last_year = resumed_clock.year_index_for_day(0)
	resumed_clock._day_carry = 0.2
	resumed_clock.request_simulation_backpressure(&"economy_day_barrier", true)
	resumed_clock.simulation_backpressure_pulse.connect(func(_day: int) -> void:
		resumed_clock.request_simulation_backpressure(&"economy_day_barrier", false))
	resumed_clock._process(1.0 / 60.0)
	if resumed_clock.day_index() != 0:
		failures.append("a continuation pulse started a new day in the same render frame")
	resumed_clock._process(1.0 / 60.0)
	if resumed_clock.day_index() != 1:
		failures.append("a drained barrier did not resume day advancement on the next frame")

	if failures.is_empty():
		print("[economy-backpressure-timebox] PASS")
		quit(0)
	else:
		for failure in failures:
			push_error("[economy-backpressure-timebox] FAIL: %s" % failure)
		quit(1)
