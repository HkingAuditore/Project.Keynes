# weather_front_shape_test.gd
# Verifies that WeatherFront uses elongated front geometry for logical coverage.
#
# Headless execution:
#     godot --headless --script tests/weather_front_shape_test.gd --quit

extends SceneTree

var _failures: int = 0
var _checks: int = 0

func _init() -> void:
	_run()
	quit(0 if _failures == 0 else 1)

func _run() -> void:
	print("=== WeatherFront shape test ===")
	_test_elliptical_coverage()
	_test_axis_fallback_and_bounds()
	_test_stable_axis_turn_limit()
	_test_visual_lifecycle_precip_dissipates_before_cloud()
	print("=== done: %d checks, %d failures ===" % [_checks, _failures])

func _test_elliptical_coverage() -> void:
	var f := WeatherFront.new()
	f.center = Vector2.ZERO
	f.radius = 100.0
	f.intensity = 0.8
	f.axis = Vector2.RIGHT
	f.major_scale = 2.0
	f.minor_scale = 0.5

	var center_cov := f.coverage_at(Vector2.ZERO)
	var along_cov := f.coverage_at(Vector2(100.0, 0.0))
	var cross_cov := f.coverage_at(Vector2(0.0, 100.0))

	_expect(is_equal_approx(center_cov, f.intensity), "center coverage should equal intensity")
	_expect(along_cov > 0.45, "coverage should remain strong along major axis")
	_expect(cross_cov < 0.02, "coverage should fall off quickly across minor axis")
	_expect(along_cov > cross_cov * 10.0, "major axis coverage should exceed minor axis coverage")

	var max_seen := 0.0
	for x in range(-320, 321, 40):
		for y in range(-320, 321, 40):
			max_seen = maxf(max_seen, f.coverage_at(Vector2(float(x), float(y))))
	_expect(max_seen <= f.intensity + 0.0001, "coverage must not exceed front intensity")

func _test_axis_fallback_and_bounds() -> void:
	var f := WeatherFront.new()
	f.radius = 80.0
	f.axis = Vector2.ZERO
	f.stable_axis = Vector2.ZERO
	f.major_scale = 1.75
	f.minor_scale = 0.4
	_expect(f.normalized_axis() == Vector2.RIGHT, "zero axis should fall back to Vector2.RIGHT")
	_expect(is_equal_approx(f.bounding_radius(), 140.0), "bounding radius should use the largest scale")

func _test_stable_axis_turn_limit() -> void:
	var f := WeatherFront.new()
	f.radius = 100.0
	f.axis = Vector2.RIGHT
	f.stable_axis = Vector2.RIGHT
	f.intensity = 1.0
	f.ttl_days = 8
	f.decay_per_day = 0.0

	var wind_fn := func(_pos: Vector2) -> Vector2:
		return Vector2.UP

	f.advance_one_day(wind_fn)
	var angle_delta := absf(Vector2.RIGHT.angle_to(f.normalized_axis()))
	_expect(angle_delta < deg_to_rad(24.0), "stable axis should not snap to a perpendicular wind in one day")
	_expect(f.normalized_axis().dot(Vector2.RIGHT) > 0.85, "stable axis should still mostly face the previous direction")

func _test_visual_lifecycle_precip_dissipates_before_cloud() -> void:
	var f := WeatherFront.new()
	f.type = WeatherType.WT.RAIN
	f.intensity = 0.8
	f.ttl_days = 10
	f.age_days = 7
	f.refresh_visual_lifecycle()

	_expect(f.life_progress > 0.65, "life progress should reflect age / ttl")
	_expect(f.precip_amount < f.cloud_amount, "precipitation should dissipate before cloud body late in lifecycle")

func _expect(cond: bool, msg: String) -> void:
	_checks += 1
	if not cond:
		_failures += 1
		push_error("[FAIL] " + msg)
		print("[FAIL] " + msg)
