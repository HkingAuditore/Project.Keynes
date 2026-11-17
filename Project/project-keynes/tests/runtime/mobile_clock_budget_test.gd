extends SceneTree

# Exercise the production clock with platform predicates substituted, so desktop
# CI covers Android/iOS/Web without sleeps or a timing-dependent pass threshold.
var failures := 0

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)

func run() -> void:
	var source := FileAccess.get_file_as_string("res://scripts/geography/world_clock.gd")
	for platform in ["android", "ios", "desktop", "web"]:
		var script := GDScript.new()
		var variant := source.replace("class_name WorldClock", "")
		for feature in ["mobile", "android", "ios", "web"]:
			var enabled: bool = feature == platform or (feature == "mobile" and platform in ["android", "ios"])
			variant = variant.replace('OS.has_feature("%s")' % feature, "true" if enabled else "false")
		script.source_code = variant
		check(script.reload() == OK, "clock variant compiles: " + platform)
		var clock = script.new()
		clock.auto_start = false
		clock.debug_step_log = false
		root.add_child(clock)
		clock.set_process(false)
		await process_frame
		for speed in [1.0, 5.0, 10.0, 50.0]:
			clock.set_speed(speed)
			var budget: float = clock.sim_budget_ms()
			if platform != "web":
				check(is_equal_approx(budget, clock.sim_frame_budget_ms),
					"%s %.0fx enlarged frame budget: %.1f ms" % [platform, speed, budget])
			else:
				check(budget >= clock.sim_frame_budget_ms, "Web retains its explicit throughput policy")
		if platform != "web":
			var admitted: Array[int] = []
			clock.day_changed.connect(func(day: int): admitted.append(day))
			clock.pause(false)
			# Explicit cost estimate; only admission is under test, no fake simulation.
			clock._day_cost_ms_ema = clock.sim_frame_budget_ms
			clock._process(1.0)
			check(admitted == [1], "%s admits only the work fitting this frame" % platform)
			clock.request_simulation_backpressure(&"economy_day_barrier", true)
			clock._process(10.0)
			check(admitted == [1], "unfinished day blocks new admission")
			clock.request_simulation_backpressure(&"economy_day_barrier", false)
			clock._day_cost_ms_ema = clock.sim_frame_budget_ms
			clock._process(1.0)
			check(admitted == [1, 2], "budget changes never skip or repeat a game day")
		clock.free()
	await process_frame
	print("mobile clock budget: %d failures" % failures)
	quit(0 if failures == 0 else 1)
