extends SceneTree

var _failures := 0
var _checks := 0
var _viewport: SubViewport
var _material: ShaderMaterial


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var source := FileAccess.get_file_as_string("res://shaders/include/earth_daylight.gdshaderinc")
	_expect("production evaluator uses visual daylight", source.contains(": compute_eternal_visual_sun_dir(lat_signed)"))
	_expect("noon-only evaluator is removed", not source.contains("compute_eternal_noon_sun_dir"))
	var water := FileAccess.get_file_as_string("res://shaders/include/water_pipeline.gdshaderinc")
	_expect("water highlights use visual daylight", water.contains(": compute_eternal_visual_sun_dir(lat_signed)"))
	var clock := FileAccess.get_file_as_string("res://scripts/geography/world_clock.gd")
	_expect("visual daylight follows the game clock by default", clock.contains("var visual_tod_follow_speed: bool = true"))
	_check_calendar_mapping()
	_check_renderer_tuning()
	_expect_close("35 north summer noon is 78.5 degrees", _elevation(35.0, 23.5, 0.25), 78.5)
	_expect_close("35 north equinox noon is 55 degrees", _elevation(35.0, 0.0, 0.25), 55.0)
	_expect_close("35 north winter noon is 31.5 degrees", _elevation(35.0, -23.5, 0.25), 31.5)
	_expect("wide visual window reaches a lower sun", _elevation(0.0, 0.0, 0.0) < 25.0)
	_expect_close("eternal floor is 10 degrees", _elevation(-90.0, 23.5, 0.0), 10.0)
	if OS.get_cmdline_user_args().has("--render-noon"):
		await _check_shader()
	else:
		print("Render checks omitted; pass -- --render-noon with a rendering driver.")
	print("eternal visual daylight: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _check_calendar_mapping() -> void:
	var clock = load("res://scripts/geography/world_clock.gd").new()
	for year_days in [365, 360, 10]:
		clock.days_per_year_count = year_days
		for progress in [0.0, 0.125, 0.25, 0.5, 1.0]:
			clock.current_day = float(year_days) * progress
			clock.call("_advance_visual_day_phase", 0.0)
			_expect_close("calendar %.3f of %d days maps to two Shader days" % [progress, year_days],
				clock.visual_day_phase, fposmod(0.25 + progress * 2.0, 1.0))
	clock.days_per_year_count = 365
	clock.current_day = 365.0 * 0.125
	clock.speed_multiplier = 1.0
	clock.call("_advance_visual_day_phase", 1.0)
	var phase: float = clock.visual_day_phase
	clock.speed_multiplier = 20.0
	clock.call("_advance_visual_day_phase", 1000.0)
	_expect_close("unchanged calendar does not drift with speed or frame delta", clock.visual_day_phase, phase)
	clock.current_day += 365.0 * 0.125
	clock.call("_advance_visual_day_phase", 0.0)
	_expect_close("advancing the calendar advances the Shader day", clock.visual_day_phase, 0.75)
	clock.free()


func _check_renderer_tuning() -> void:
	var renderer = load("res://scripts/rendering/hex_renderer.gd").new()
	var clock = load("res://scripts/geography/world_clock.gd").new()
	clock.days_per_year_count = 365
	clock.current_day = 365.0 * 0.125
	renderer.configure_shader_clock(clock.set_visual_shader_days_per_year)
	_expect_close("renderer binds its default two Shader days", clock.visual_day_phase, 0.5)
	renderer.shader_days_per_game_year = 4.0
	_expect_close("renderer can select four Shader days per year", clock.visual_day_phase, 0.75)
	renderer.shader_days_per_game_year = 0.5
	clock.current_day = 365.0
	clock.call("_advance_visual_day_phase", 0.0)
	_expect_close("fractional rate continues across the first year", clock.visual_day_phase, 0.75)
	clock.current_day = 365.0 * 1.5
	clock.call("_advance_visual_day_phase", 0.0)
	_expect_close("fractional rate reaches the second year without reset", clock.visual_day_phase, 0.0)
	clock.current_day = 365.0 * 2.0
	clock.call("_advance_visual_day_phase", 0.0)
	_expect_close("half a Shader day per year closes after two years", clock.visual_day_phase, 0.25)
	renderer.shader_days_per_game_year = 0.0
	clock.current_day = 365.0 * 2.5
	clock.call("_advance_visual_day_phase", 0.0)
	_expect_close("zero Shader days per year keeps noon", clock.visual_day_phase, 0.25)
	renderer.configure_shader_clock(Callable())
	clock.free()
	var probe := Shader.new()
	probe.code = "shader_type canvas_item; uniform float eternal_min_elevation_rad; uniform float eternal_max_hour_angle_rad;"
	var material := ShaderMaterial.new()
	material.shader = probe
	renderer.set("_shader_mat", material)
	var layers := []
	for spec in [["building_visual_layer.gd", "_building_visual_layer", "_body_material"],
		["weather_layer.gd", "_weather_layer", "_overlay_mat"],
		["fog_of_war_layer.gd", "_fog_layer", "_shader_mat"],
		["shrub_layer.gd", "", "_material"]]:
		var layer = load("res://scripts/rendering/" + spec[0]).new()
		var target := ShaderMaterial.new()
		target.shader = probe
		layer.set(spec[2], target)
		if spec[1] == "":
			renderer.get("_detail_layers").append(layer)
		else:
			renderer.set(spec[1], layer)
		layers.append([layer, target])
	renderer.eternal_min_elevation_deg = 25.0
	renderer.eternal_max_hour_angle_deg = 55.0
	_expect_close("renderer converts minimum elevation from degrees", material.get_shader_parameter("eternal_min_elevation_rad"), deg_to_rad(25.0))
	_expect_close("renderer converts hour angle from degrees", material.get_shader_parameter("eternal_max_hour_angle_rad"), deg_to_rad(55.0))
	for entry in layers:
		_expect_close("layer receives renderer minimum elevation", entry[1].get_shader_parameter("eternal_min_elevation_rad"), deg_to_rad(25.0))
		_expect_close("layer receives renderer hour angle", entry[1].get_shader_parameter("eternal_max_hour_angle_rad"), deg_to_rad(55.0))
	for entry in layers:
		entry[0].free()
	renderer.free()


func _elevation(latitude: float, declination: float, phase: float) -> float:
	var hour_angle := deg_to_rad(70.0) * sin(TAU * (phase - 0.25))
	var up := sin(deg_to_rad(latitude)) * sin(deg_to_rad(declination)) 		+ cos(deg_to_rad(latitude)) * cos(deg_to_rad(declination)) * cos(hour_angle)
	return maxf(10.0, rad_to_deg(asin(clampf(up, -1.0, 1.0))))


func _check_shader() -> void:
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(64, 64)
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(_viewport)
	var rect := ColorRect.new()
	rect.size = Vector2(64, 64)
	var shader := Shader.new()
	shader.code = """shader_type canvas_item;
render_mode unshaded;
uniform float season_phase = 0.0;
uniform float day_phase = 0.25;
uniform float axial_tilt_rad = 0.410152374;
uniform float wrap_period_x = 0.0;
uniform float wrap_origin_x = 0.0;
uniform vec2 world_origin = vec2(0.0);
uniform vec2 world_size = vec2(1.0);
uniform bool tod_debug_sun_position_enabled = false;
uniform vec2 tod_debug_sun_uv = vec2(0.5);
uniform float tod_debug_sun_height_scale = 1.0;
uniform vec3 tod_sun_dir = vec3(0.0, 0.0, 1.0);
#include "res://shaders/include/earth_daylight.gdshaderinc"
void fragment() {
    EarthDaylight ed = eval_earth_daylight(UV, UV.y * 2.0 - 1.0, false);
    COLOR = vec4(ed.sun_dir * 0.5 + 0.5, 1.0);
}
"""
	_material = ShaderMaterial.new()
	_material.shader = shader
	rect.material = _material
	_viewport.add_child(rect)
	_material.set_shader_parameter("season_phase", 1.0)
	_material.set_shader_parameter("day_phase", 0.25)
	var noon := await _capture()
	_material.set_shader_parameter("day_phase", 0.0)
	var morning := await _capture()
	_material.set_shader_parameter("day_phase", 0.5)
	var afternoon := await _capture()
	_expect("GPU visual morning differs from noon", _difference(noon, morning) > 0.08)
	_expect("GPU visual afternoon differs from noon", _difference(noon, afternoon) > 0.08)
	_expect("GPU morning and afternoon have opposite east-west light", _decode(morning.get_pixel(32, 32)).x
		> _decode(afternoon.get_pixel(32, 32)).x)
	_material.set_shader_parameter("day_phase", 0.25)
	var restored := await _capture()
	_expect("GPU noon restores exactly", _difference(noon, restored) < 0.001)
	_material.set_shader_parameter("day_phase", 0.0)
	_material.set_shader_parameter("eternal_max_hour_angle_rad", deg_to_rad(30.0))
	var narrower := await _capture()
	_expect("GPU hour-angle uniform changes the visual sun", _difference(morning, narrower) > 0.08)
	_material.set_shader_parameter("eternal_min_elevation_rad", deg_to_rad(45.0))
	var raised := await _capture()
	_expect("GPU minimum-elevation uniform raises polar sun", _decode(raised.get_pixel(32, 0)).z > 0.69)
	_material.set_shader_parameter("tod_debug_sun_position_enabled", true)
	_material.set_shader_parameter("tod_sun_dir", Vector3(3.0, -4.0, -5.0))
	var debug := await _capture()
	_expect("GPU explicit GM direction overrides visual time", _decode(debug.get_pixel(32, 32)).distance_to(Vector3(3, -4, -5).normalized()) < 0.025)
	_viewport.queue_free()
	await process_frame


func _capture() -> Image:
	for frame in range(3):
		await process_frame
	await RenderingServer.frame_post_draw
	return _viewport.get_texture().get_image()


func _difference(a: Image, b: Image) -> float:
	var total := 0.0
	for y in a.get_height():
		for x in a.get_width():
			var p := a.get_pixel(x, y)
			var q := b.get_pixel(x, y)
			total += absf(p.r - q.r) + absf(p.g - q.g) + absf(p.b - q.b)
	return total / float(a.get_width() * a.get_height())


func _decode(c: Color) -> Vector3:
	return Vector3(c.r, c.g, c.b) * 2.0 - Vector3.ONE


func _expect(label: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_failures += 1
		push_error("FAIL: " + label)
	else:
		print("PASS: " + label)


func _expect_close(label: String, actual: float, expected: float) -> void:
	_expect(label, absf(actual - expected) < 0.0001)
