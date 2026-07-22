extends SceneTree

var _failures: int = 0
var _checks: int = 0


func _init() -> void:
	_run()
	print("annual eternal day direction: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	var winter := _annual_direction(0.0)
	var spring := _annual_direction(1.0)
	var summer := _annual_direction(2.0)
	var autumn := _annual_direction(3.0)
	var next_winter := _annual_direction(4.0)

	_expect_close("year start elevation is 15 degrees", winter.z, sin(deg_to_rad(15.0)), 0.0001)
	_expect_close("quarter-year elevation is 45 degrees", spring.z, sin(deg_to_rad(45.0)), 0.0001)
	_expect_close("half-year elevation is 15 degrees", summer.z, sin(deg_to_rad(15.0)), 0.0001)
	_expect_close("three-quarter-year elevation is 45 degrees", autumn.z, sin(deg_to_rad(45.0)), 0.0001)
	_expect("annual azimuth reaches four distinct quadrants",
		winter.y > 0.0 and spring.x < 0.0 and summer.y < 0.0 and autumn.x > 0.0)
	_expect_close("one year closes exactly one direction loop", next_winter.distance_to(winter), 0.0, 0.0001)


# Mirrors earth_daylight.compute_global_parallel_sun_dir for a focused formula regression.
func _annual_direction(season_phase: float) -> Vector3:
	var year_progress := fposmod(season_phase, 4.0) * 0.25
	var azimuth := TAU * year_progress + PI * 0.5
	var latitude_ratio := absf(cos(TAU * year_progress))
	var elevation := deg_to_rad(45.0 - 30.0 * latitude_ratio)
	return Vector3(
		cos(azimuth) * cos(elevation),
		sin(azimuth) * cos(elevation),
		sin(elevation)
	).normalized()


func _expect(label: String, ok: bool) -> void:
	_checks += 1
	if ok:
		print("PASS: %s" % label)
	else:
		_failures += 1
		push_error("FAIL: %s" % label)


func _expect_close(label: String, actual: float, expected: float, tolerance: float) -> void:
	_expect(label, absf(actual - expected) <= tolerance)
