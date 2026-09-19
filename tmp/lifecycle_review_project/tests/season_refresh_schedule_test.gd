extends SceneTree

# Headless:
#   godot --headless --path <project> --script res://tests/season_refresh_schedule_test.gd --quit
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
	var system := SeasonRefreshSystem.new(RefCounted.new(), map, world)
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


func _expect(label: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_failures += 1
		push_error("[season_refresh_schedule_test] FAIL %s" % label)
