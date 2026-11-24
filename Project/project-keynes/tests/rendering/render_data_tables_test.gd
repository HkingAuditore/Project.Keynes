extends SceneTree

const Table = preload("res://scripts/rendering/render_data_table.gd")
const WaterRippleChecks = preload("res://tests/rendering/water_ripple_lattice_checks.gd")
var _checks := 0
var _failures := 0

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	if not root.is_node_ready():
		await root.ready
	await process_frame
	var can_read_pixels := RenderingServer.get_rendering_device() != null
	await WaterRippleChecks.run(self, _expect, can_read_pixels)
	if can_read_pixels:
		await _weather()
		await _lattices()
		await _fog_quality_changes()
	else:
		print("SKIP numerical table readbacks require a graphical rendering device")
		if OS.get_cmdline_user_args().has("--require-draw"):
			_expect(false, "graphical rendering device required")
	print("Render data tables: %d checks, %d failures" % [_checks, _failures])
	quit(int(_failures != 0))

func _read(view: SubViewport) -> Image:
	view.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	return view.get_texture().get_image()

func _expect(ok: bool, label: String) -> void:
	_checks += 1
	if not ok:
		push_error(label)
		_failures += 1
	else:
		print("PASS ", label)

func _weather() -> void:
	# Two different weather types and nearly opposite wind directions on a
	# non-square grid. Colour is categorical, wind is decoded before blending.
	var source := Texture2DArray.new()
	var slices: Array[Image] = []
	for colour in [Color8(19, 41, 89, 132), Color8(3, 192, 55, 240),
			Color8(255, 180, 33, 0), Color8(0, 150, 203, 0)]:
		var im := Image.create_empty(3, 2, false, Image.FORMAT_RGBA8)
		im.fill(colour)
		im.set_pixel(2, 1, Color8(0, 0, 0, 0))
		slices.append(im)
	_expect(source.create_from_images(slices) == OK, "weather sources uploaded")
	var table = Table.new()
	table.configure(root, Vector2i(6, 4), preload("res://shaders/weather_cell_endpoints.gdshader"))
	table.material.set_shader_parameter("source_table", source)
	var direct := _weather_probe(false, source, table.get_texture())
	var cached := _weather_probe(true, source, table.get_texture())
	for cur in [0, 1]:
		table.material.set_shader_parameter("current_layer", cur)
		var image: Image = await _read(table)
		var ok := image != null and image.get_size() == Vector2i(6, 4)
		if ok:
			for endpoint in [0, 1]:
				var index: int = cur if endpoint == 1 else 1 - cur
				var weather := slices[index].get_pixel(0, 0)
				weather.r = slices[cur].get_pixel(0, 0).r
				var stored := image.get_pixel(endpoint + 2, 0)
				ok = ok and _distance(stored, weather) < 0.002
				var wind := slices[index + 2].get_pixel(0, 0)
				var direction := Vector2(wind.r, wind.g) * 2.0 - Vector2.ONE
				var expected := direction.normalized() * (0.25 + wind.b)
				var value := image.get_pixel(endpoint + 2, 2)
				ok = ok and (Vector2(value.r, value.g) * 2.5 - Vector2.ONE * 1.25).distance_to(expected) < 0.003
			ok = ok and _distance(image.get_pixel(5, 1), Color(0, 0, 0, 0)) < 0.002
		_expect(ok, "both endpoints follow the current weather type, row and decoded winds after swap %d" % cur)
		for blend in [0.0, 0.37, 0.9992, 1.0]:
			for probe in [direct, cached]:
				probe.material.set_shader_parameter("weather_cur_layer", cur)
				probe.material.set_shader_parameter("weather_prev_layer", 1 - cur)
				probe.material.set_shader_parameter("weather_lerp", blend)
			var before := await _read(direct)
			var after := await _read(cached)
			var max_error := 0.0
			var min_intensity := INF
			var max_intensity := -INF
			for y in before.get_height():
				for x in before.get_width():
					var control := before.get_pixel(x, y)
					min_intensity = minf(min_intensity, control.b)
					max_intensity = maxf(max_intensity, control.b)
					max_error = maxf(max_error, _distance(control, after.get_pixel(x, y)))
			_expect(max_error < 0.004 and max_intensity - min_intensity > 0.12,
				"published weather matches raw fields across seams and padding (layer %d, blend %.4f)" % [cur, blend])
	for probe in [direct, cached, table]:
		probe.queue_free()


func _weather_probe(use_endpoints: bool, weather: Texture2DArray, endpoints: Texture2D) -> SubViewport:
	var program := Shader.new()
	var source := FileAccess.get_file_as_string("res://shaders/weather_overlay.gdshader")
	var prefix := "#define PK_CELL_FIELD\n#define PK_WEATHER_LOW\n"
	if use_endpoints:
		prefix += "#define PK_WEATHER_CELL_ENDPOINTS\n"
	program.code = prefix + source.get_slice("void fragment() {", 0).replace("blend_mix", "blend_disabled") + """
void fragment() {
	vec2 world_pos = FRAGCOORD.xy * vec2(0.29, 0.54) - vec2(2.0, 1.0);
	FrontField weather = sample_field_weather(world_pos);
	COLOR = vec4(weather.axis * 0.4 + 0.5, weather.intensity, float(weather.type) / 8.0);
}"""
	var probe = Table.new()
	probe.configure(root, Vector2i(32, 12), program)
	probe.material.set_shader_parameter("hex_size", 1.0)
	probe.material.set_shader_parameter("map_dims", Vector2(3, 2))
	probe.material.set_shader_parameter("wrap_period_x", sqrt(3.0) * 3.0)
	probe.material.set_shader_parameter("weather_table_bound", true)
	probe.material.set_shader_parameter("weather_table", weather)
	probe.material.set_shader_parameter("weather_endpoints", endpoints)
	return probe


func _lattices() -> void:
	var water = Table.new()
	water.configure(root, Vector2i(256, 768), preload("res://shaders/water_ripple_lattice.gdshader"))
	var fog = Table.new()
	fog.configure(root, Vector2i(256, 1280), preload("res://shaders/fog_gradient_lattice.gdshader"))
	var oracle_shader := Shader.new()
	oracle_shader.code = """
shader_type canvas_item;
render_mode unshaded, blend_disabled;
#include "res://shaders/include/water_lattice.gdshaderinc"
#include "res://shaders/include/cloud_noise.gdshaderinc"
#include "res://shaders/include/fog_lattice.gdshaderinc"
uniform vec2 seeds;
uniform float clock;
void fragment() {
	int x = int(FRAGCOORD.x);
	vec2 p = vec2(25.0, -5.0);
	vec2 next = p + vec2(0.0, 1.0);
	vec4 waves = vec4(water_hash32(p + seeds.x).x, water_hash32(p + seeds.y).x,
		water_hash32(next + seeds.x).x, water_hash32(next + seeds.y).x);
	vec2 band = FOG_BANDS[6];
	float phase = clock * band.x;
	vec4 gradients = 0.5 + vec4(fog_evolving_gradient(p, phase, band.y),
		fog_evolving_gradient(next, phase, band.y)) / 3.0;
	COLOR = mix(waves, gradients, float(x));
}"""
	var oracle = Table.new()
	oracle.configure(root, Vector2i(2, 2), oracle_shader)
	for cycle in [0, 4]:
		var pair := Vector2(71.0 + cycle * 13.7, 76.0 + (cycle + 1) * 13.7)
		water.material.set_shader_parameter("cycles", Vector4(cycle, cycle+1, 0, 0))
		var w: Image = await _read(water)
		oracle.material.set_shader_parameter("seeds", pair)
		oracle.material.set_shader_parameter("clock", float(cycle) + 0.125)
		var ref: Image = await _read(oracle)
		_expect(_distance(w.get_pixel(25, 27), ref.get_pixel(0, 0)) < 0.002,
			"water corner seeds and signed rows on cycle %d" % cycle)
		fog.material.set_shader_parameter("evolution_start", float(cycle))
		fog.material.set_shader_parameter("evolution_step", 0.25)
		var f: Image = await _read(fog)
		var row := 6 * 128 + 27
		var mid := f.get_pixel(50, row).lerp(f.get_pixel(51, row), 0.5)
		_expect(_distance(mid, ref.get_pixel(1, 0)) < 0.004,
			"interpolated fog gradients follow the analytic rotation on cycle %d" % cycle)
	for table in [water, fog, oracle]:
		table.queue_free()

func _fog_quality_changes() -> void:
	DCFeatureFlags.fog_half_res_enabled()  # Load the process-local overrides.
	var previous_flags := DCFeatureFlags._debug_render_flags.duplicate()
	for half_res: bool in [false, true]:
		DCFeatureFlags._debug_render_flags["fog_half_res"] = int(half_res)
		var fog := FogOfWarLayer.new()
		fog.set_visual_quality(0)
		root.add_child(fog)
		_expect(fog._gradient_table == null, "low fog starts without a gradient table")
		fog.set_visual_quality(2)
		var table := fog._gradient_table
		var consumer: Viewport = fog._sub_viewport if half_res else root
		_expect(table != null and table.get_parent() == fog._mesh_inst
			and fog._mesh_inst.get_viewport() == consumer
			and fog._shader_mat.get_shader_parameter("fog_gradient_lattice") == table.get_texture(),
			"high fog binds its table under its drawing viewport (half size %s)" % half_res)
		var reference := await _read(table)
		for scale_percent in [100, 75, 50, 100]:
			fog.set_render_scale(scale_percent)
			await process_frame
			await RenderingServer.frame_post_draw
			consumer = root if scale_percent == 100 else fog._sub_viewport
			var bound: Texture2D = fog._shader_mat.get_shader_parameter("fog_gradient_lattice")
			_expect(is_instance_valid(table) and fog._gradient_table == table
				and table.get_parent() == fog._mesh_inst and fog._mesh_inst.get_viewport() == consumer
				and bound == table.get_texture() and bound.get_image().get_data() == reference.get_data(),
				"changing fog to %d%% preserves its bound gradient pixels" % scale_percent)
		fog.set_visual_quality(0)
		_expect(table != null and table.is_queued_for_deletion() and fog._gradient_table == null,
			"lowering fog quality releases the table")
		fog.set_visual_quality(2)
		_expect(fog._gradient_table != null and fog._gradient_table != table,
			"raising fog quality rebuilds the table before the next draw")
		fog.queue_free()
		await process_frame
	DCFeatureFlags._debug_render_flags = previous_flags

func _distance(a: Color, b: Color) -> float:
	return maxf(maxf(absf(a.r-b.r),absf(a.g-b.g)),maxf(absf(a.b-b.b),absf(a.a-b.a)))
