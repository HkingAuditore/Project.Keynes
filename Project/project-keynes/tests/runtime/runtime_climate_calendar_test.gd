extends SceneTree

var failures := 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var generator := MapGenerator.new()
	var clock := WorldClock.new()
	generator.set_world_clock_ref(clock)
	var capture = generator._get_runtime_climate_capture()
	capture.calendar_day = 93
	generator._last_climate_pass_day = 92.0
	generator._last_sea_ice_pass_day = 92.0
	for display_day in [91.125, 94.75]:
		clock.current_day = display_day
		var weather := generator._native_daily_weather_clock_values(0.0)
		_check("weather uses the climate day on either side of the screen date",
			generator._consume_climate_dt_days() == 1.0
			and generator._consume_sea_ice_dt_days() == 1.0
			and weather.season_idx == clock.season_index_for_day(93)
			and weather.season_phase == clock.season_phase_for_day(93))
	capture.calendar_day = -1
	_check("the unscheduled preview uses the screen date", capture.sample_day() == clock.current_day)

	clock.set_native_climate_calendar(true)
	clock.apply_native_climate_calendar({"climate_rng_year": 1, "climate_anomaly": 0.25})
	var restored := WorldClock.new()
	restored.set_native_climate_calendar(true)
	var checkpoint := clock.export_state()
	_check("the display checkpoint leaves the climate seed with the executor",
		not checkpoint.has("rng_state") and not checkpoint.has("climate_rng_year")
		and bool(restored.restore_state(checkpoint).get("ok", false)))
	restored.apply_native_climate_calendar({"climate_rng_year": 1, "climate_anomaly": 0.25})
	restored._apply_year_rollover(2)
	_check("a foreground year change retains the last published climate", restored.climate_anomaly == 0.25)
	restored.apply_native_climate_calendar({"climate_rng_year": 2, "climate_anomaly": 0.5})
	_check("the next committed annual climate appears in the display", restored.climate_anomaly == 0.5)
	restored.free()
	clock.free()
	print("runtime climate calendar: %d failures" % failures)
	quit(0 if failures == 0 else 1)


func _check(label: String, passed: bool) -> void:
	if not passed:
		failures += 1
		push_error("[FAIL] " + label)
