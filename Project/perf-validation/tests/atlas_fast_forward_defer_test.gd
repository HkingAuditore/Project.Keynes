extends SceneTree

# Headless:
#   godot --headless --path <proj> --script res://tests/atlas_fast_forward_defer_test.gd

var _checks: int = 0
var _failures: int = 0


func _init() -> void:
	_run()
	print("=== atlas fast-forward defer: %d checks, %d failures ===" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	var sys := EnumAtlasUploadSystem.new(null, null, null, null, 1.0, 1)
	_expect("enum atlas asks the C++ scheduler to honor should_run",
		bool(sys.use_job_should_run))
	var first := SusTickContext.make(0, 0, 0.0, 50.0, &"day_changed")
	_expect("first fast-forward tick still uploads",
		not sys.should_skip_fast_forward_visual(first) and sys.policy_skip_reason() == "")
	sys.mark_atlas_upload_success()
	_expect("speed 50 defers atlas within 100ms",
		sys.should_skip_fast_forward_visual(first)
		and sys.policy_skip_reason() == "fast_forward_deferred")
	_expect("fast-forward skip does not consume pending work",
		not sys.take_fast_forward_atlas_catchup())
	var slow := SusTickContext.make(1, 1, 0.0, 1.0, &"day_changed")
	_expect("dropping below 20x does not skip",
		not sys.should_skip_fast_forward_visual(slow))
	_expect("dropping below 20x requests a catch-up",
		sys.take_fast_forward_atlas_catchup())
	_expect("catch-up is consumed once",
		not sys.take_fast_forward_atlas_catchup())


func _expect(label: String, ok: bool) -> void:
	_checks += 1
	print("  [%s] %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		_failures += 1
