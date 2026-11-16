extends SceneTree

# Headless:
#   godot --headless --path <project> --script res://tests/world/season_refresh_schedule_test.gd --quit
#
# Regression coverage for the native scheduler registration contract: the
# system uses AlwaysPolicy as a descriptor but its stateful should_run() gate
# owns the periodic cadence.

var _checks: int = 0
var _failures: int = 0


func _init() -> void:
	_run()
	print("=== season refresh schedule: %d checks, %d failures ===" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	var map := MapData.new(1, 1)
	var world := WorldData.new()
	# generator_context.gd intentionally stores only a weak reference. Keep the
	# owner alive for the duration of this scheduler contract test.
	var generator := RefCounted.new()
	var system := SeasonRefreshSystem.new(generator, map, world)
	system.period_ticks = 3
	var ctx := SusTickContext.make(0, 0, 0.0, 1.0, &"schedule_test")

	_expect("stateful scheduler gate is enabled", system.use_job_should_run)
	_expect("tick 1 is not due", not system.should_run(ctx))
	ctx.tick_index = 1
	_expect("tick 2 is not due", not system.should_run(ctx))
	ctx.tick_index = 2
	_expect("tick 3 is due", system.should_run(ctx))
	system._round_active = true
	_expect("round remains runnable after it starts", system.should_run(ctx))
	_test_capture_calendar(map, world)


func _test_capture_calendar(map: MapData, world: WorldData) -> void:
	var reference := _capture_days(map, world, -1, 0)
	var resumed := _capture_days(map, world, 5, 3)
	var at_boundary := _capture_days(map, world, 30, 0)
	var after_boundary := _capture_days(map, world, 31, 3)
	_expect("slow refresh uses fixed game days", reference == [31, 61])
	_expect("cold restore and repeated scheduler probes keep dates", resumed == reference)
	_expect("restore immediately before refresh keeps dates", at_boundary == reference)
	_expect("restore immediately after refresh does not repeat it", after_boundary == reference)
	var generator := CaptureGenerator.new()
	var inherited := SeasonRefreshSystem.new(generator, map, world)
	generator.current_day = 15
	inherited._round_active = true
	inherited._stage = 4
	if inherited.has_method("run_due_round_for_capture"):
		inherited.call("run_due_round_for_capture", 14)
		_expect("authority switch finishes an existing round off the periodic boundary",
			not inherited._round_active and generator.stages == 8)


func _capture_days(map: MapData, world: WorldData, save_day: int, probes: int) -> Array:
	var generator := CaptureGenerator.new()
	var system := SeasonRefreshSystem.new(generator, map, world)
	var refreshed: Array = []
	for day in range(1, 66):
		generator.current_day = day + 1
		# The production boundary captures before the scheduler runs. Keeping
		# the old call here also makes this target reproduce the old failure.
		if system.has_method("run_due_round_for_capture"):
			system.call("run_due_round_for_capture", day)
		else:
			system.run_round_for_capture()
		if generator._last_season_refresh_day == day + 1:
			refreshed.append(day)
		var stages := generator.stages
		if system.has_method("run_due_round_for_capture"):
			system.call("run_due_round_for_capture", day)
		_expect("same input day never recomputes refresh", generator.stages == stages)
		var ctx := SusTickContext.make(day + 1, day + 1, 0.0, 1.0, &"day_changed")
		# Include omitted and repeated policy observations. They are scheduling
		# opportunities, not extra simulation days.
		for _probe in range(1 if probes == 0 else (0 if day % 2 == 0 else probes)):
			if system.should_run(ctx): system.tick(ctx)
		if day == save_day:
			# CLM2 already saves the generator's last refresh boundary. The
			# system is freshly constructed, just as it is on a cold load.
			var last_refresh := generator._last_season_refresh_day
			generator = CaptureGenerator.new()
			generator._last_season_refresh_day = last_refresh
			system = SeasonRefreshSystem.new(generator, map, world)
	return refreshed


class CaptureGenerator extends RefCounted:
	var _last_season_refresh_day := -1
	var current_day := 1
	var stages := 0
	func season_refresh_defers_to_capture() -> bool: return true
	func begin_periodic_season_refresh() -> int: return 0
	func run_season_refresh_stage(_map, _world, _season, _stage) -> void: stages += 1
	func finish_season_refresh(_map, _world, _season) -> void:
		_last_season_refresh_day = current_day


func _expect(label: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_failures += 1
		push_error("[season_refresh_schedule_test] FAIL %s" % label)
