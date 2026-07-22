extends SceneTree

var _failures: int = 0
var _checks: int = 0


func _init() -> void:
	_run()
	print("dynamic eternal day direction: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	var host := WorldRuntimeHost.new()
	var clock := WorldClock.new()
	host._world_clock = clock

	# 春分：直射点在赤道，使用基础高度 30°。
	clock.current_day = float(clock.days_per_year()) * 0.25
	var east: Vector3 = host.call("_dynamic_eternal_day_direction", 0.25)
	var north: Vector3 = host.call("_dynamic_eternal_day_direction", 0.50)
	var west: Vector3 = host.call("_dynamic_eternal_day_direction", 0.75)
	var south: Vector3 = host.call("_dynamic_eternal_day_direction", 0.00)

	_expect_close("direction remains normalized", east.length(), 1.0, 0.0001)
	_expect("quarter-day phase points east", east.x > 0.0 and absf(east.y) < 0.0001)
	_expect("half-day phase points north", north.y > 0.0 and absf(north.x) < 0.0001)
	_expect("three-quarter-day phase points west", west.x < 0.0 and absf(west.y) < 0.0001)
	_expect("zero phase points south", south.y < 0.0 and absf(south.x) < 0.0001)
	_expect_close("equinox elevation is 30 degrees", east.z, sin(deg_to_rad(30.0)), 0.0001)

	# 至日：直射点达到最大纬度，光线高度按配置降低 10°，但仍保持白昼。
	clock.current_day = 0.0
	var solstice: Vector3 = host.call("_dynamic_eternal_day_direction", 0.25)
	_expect_close("solstice elevation is 20 degrees", solstice.z, sin(deg_to_rad(20.0)), 0.0001)
	_expect("seasonal latitude lowers the light", solstice.z < east.z)
	_expect("dynamic eternal day remains above horizon", solstice.z > 0.0)

	# 验证实际运行链：RuntimeHost 的相位更新会写入 HexRenderer TOD 缓存。
	var renderer := HexRenderer.new()
	host.configure(renderer, null, clock)
	host.set_day_night_enabled(false)
	host.on_visual_day_phase_changed(0.50)
	var pushed_dir: Vector3 = renderer._tod_sun_dir
	_expect("runtime pushes the moving direction to renderer", pushed_dir.y > 0.0)
	_expect_close("renderer receives the same normalized direction", pushed_dir.length(), 1.0, 0.0001)

	# 手动/调试直射点也是最终数据源，不能继续读取被覆盖前的 WorldClock 相位。
	renderer.set_tod_debug_sun_position(true, Vector2(0.75, 0.5))
	host.on_visual_day_phase_changed(0.50)
	var override_dir: Vector3 = renderer._tod_sun_dir
	_expect("manual subsolar longitude overrides the clock source", override_dir.x < 0.0)
	_expect_close("manual equatorial subsolar point uses base elevation", override_dir.z, sin(deg_to_rad(30.0)), 0.0001)

	renderer.free()
	host.free()
	clock.free()


func _expect(label: String, ok: bool) -> void:
	_checks += 1
	if ok:
		print("PASS: %s" % label)
	else:
		_failures += 1
		push_error("FAIL: %s" % label)


func _expect_close(label: String, actual: float, expected: float, tolerance: float) -> void:
	_expect(label, absf(actual - expected) <= tolerance)
