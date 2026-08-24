extends SceneTree


class FakeRuntime extends RefCounted:
	var remaining: int
	var fatal := false
	var _native_round_active := false

	func _init(slice_count: int) -> void:
		remaining = slice_count

	func country_should_run(_day_index: int) -> bool:
		return remaining > 0

	func economy_should_run(_day_index: int) -> bool:
		return remaining > 0

	func trigger_should_run(_day_index: int) -> bool:
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
	var native_runtime: FakeRuntime = null
	var calls: Array[StringName] = []
	var contexts: Array[SusTickContext] = []

	func _init(country: FakeRuntime, economy: FakeRuntime) -> void:
		country_runtime = country
		economy_runtime = economy

	func continue_system(system_id: StringName, ctx: SusTickContext) -> Dictionary:
		calls.append(system_id)
		contexts.append(ctx)
		var runtime: FakeRuntime = null
		if system_id == &"country_daily":
			runtime = country_runtime
		elif system_id == &"economy_daily":
			runtime = economy_runtime
		elif system_id == &"native_daily_sim":
			runtime = native_runtime
		if runtime == null:
			return {
				"done": true,
				"stage_name": String(system_id),
				"next_stage": "",
				"path": "test",
			}
		runtime.remaining = maxi(0, runtime.remaining - 1)
		if system_id == &"native_daily_sim":
			runtime._native_round_active = runtime.remaining > 0
		return {
			"done": runtime.remaining == 0,
			"stage_name": "native_daily_slice" if system_id == &"native_daily_sim" \
				else ("country_apply" if system_id == &"country_daily" \
				else "household_market"),
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

	var native_clock := WorldClock.new()
	native_clock.sim_frame_budget_ms = 8.0
	native_clock.request_simulation_backpressure(&"native_daily_day_barrier", true)
	var native_runtime := FakeRuntime.new(6)
	native_runtime._native_round_active = true
	var native_scheduler := FakeScheduler.new(FakeRuntime.new(0), FakeRuntime.new(0))
	native_scheduler.native_runtime = native_runtime
	var native_generator := MapGenerator.new()
	native_generator._sus = native_scheduler
	native_generator._world_clock_ref = native_clock
	native_generator._native_daily_sim_job = native_runtime
	native_generator._continue_economy_inflight(18)
	if native_scheduler.calls.size() != 6 or native_runtime.remaining != 0:
		failures.append("one pulse did not drain consecutive native daily slices")
	if native_clock._simulation_backpressure_sources.has(&"native_daily_day_barrier"):
		failures.append("completed native daily drain left its day barrier active")
	native_runtime.remaining = 100
	native_runtime._native_round_active = true
	native_scheduler.calls.clear()
	native_clock.request_simulation_backpressure(&"native_daily_day_barrier", true)
	native_generator._continue_economy_inflight(19)
	if native_scheduler.calls.size() != MapGenerator.ECONOMY_CONTINUATION_MAX_SLICES_PER_FRAME \
			or native_runtime.remaining != 36:
		failures.append("native daily drain did not enforce its defensive slice cap")
	if not native_clock._simulation_backpressure_sources.has(&"native_daily_day_barrier"):
		failures.append("native slice-cap exhaustion cleared an unfinished day barrier")

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

	var sticky_clock := WorldClock.new()
	sticky_clock.sim_frame_budget_ms = 8.0
	sticky_clock.request_simulation_backpressure(&"country_day_barrier", true)
	sticky_clock.request_simulation_backpressure(&"economy_day_barrier", true)
	var sticky_trigger := FakeRuntime.new(99)
	var sticky_economy := FakeRuntime.new(5)
	var sticky_country := FakeRuntime.new(0)
	var sticky_scheduler := FakeScheduler.new(sticky_country, sticky_economy)
	var sticky_generator := MapGenerator.new()
	sticky_generator._sus = sticky_scheduler
	sticky_generator._world_clock_ref = sticky_clock
	sticky_generator._country_daily_job = RefCounted.new()
	sticky_generator._economy_daily_job = RefCounted.new()
	sticky_generator._trigger_daily_job = RefCounted.new()
	sticky_generator._country_facade = FakeFacade.new(sticky_country)
	sticky_generator._economy_facade = FakeFacade.new(sticky_economy)
	sticky_generator._trigger_facade = FakeFacade.new(sticky_trigger)
	sticky_generator._continue_economy_inflight(20)
	if sticky_economy.remaining != 0:
		failures.append("a sticky trigger should_run starved in-flight economy catchup")
	if sticky_clock._simulation_backpressure_sources.has(&"economy_day_barrier") \
			or sticky_clock._simulation_backpressure_sources.has(&"country_day_barrier"):
		failures.append("sticky trigger work left a hard day barrier after economy catchup")
	if not sticky_scheduler.calls.has(&"economy_daily"):
		failures.append("sticky trigger continuation never reached economy_daily")

	var fatal_clock := WorldClock.new()
	var fatal_economy := FakeRuntime.new(0)
	fatal_economy.fatal = true
	var fatal_scheduler := FakeScheduler.new(FakeRuntime.new(0), fatal_economy)
	var fatal_generator := MapGenerator.new()
	fatal_generator._sus = fatal_scheduler
	fatal_generator._world_clock_ref = fatal_clock
	fatal_generator._economy_daily_job = RefCounted.new()
	fatal_generator._economy_facade = FakeFacade.new(fatal_economy)
	fatal_clock.request_simulation_backpressure(&"economy_day_barrier", true)
	fatal_generator._continue_economy_inflight(23)
	if fatal_clock._simulation_backpressure_sources.has(&"economy_day_barrier"):
		failures.append("fatal economy state left a permanent world-clock barrier")

	var direct_fatal_clock := WorldClock.new()
	var direct_fatal_economy := FakeRuntime.new(1)
	direct_fatal_economy.fatal = true
	var direct_fatal_scheduler := FakeScheduler.new(
		FakeRuntime.new(0), direct_fatal_economy)
	var direct_fatal_generator := MapGenerator.new()
	direct_fatal_generator._sus = direct_fatal_scheduler
	direct_fatal_generator._world_clock_ref = direct_fatal_clock
	direct_fatal_generator._economy_daily_job = RefCounted.new()
	direct_fatal_generator._economy_facade = FakeFacade.new(direct_fatal_economy)
	direct_fatal_clock.request_simulation_backpressure(&"economy_day_barrier", true)
	direct_fatal_generator._continue_economy_inflight(23)
	if direct_fatal_clock._simulation_backpressure_sources.has(&"economy_day_barrier"):
		failures.append("direct fatal economy result left a permanent world-clock barrier")

	if failures.is_empty():
		print("[economy-backpressure-timebox] PASS")
		quit(0)
	else:
		for failure in failures:
			push_error("[economy-backpressure-timebox] FAIL: %s" % failure)
		quit(1)
