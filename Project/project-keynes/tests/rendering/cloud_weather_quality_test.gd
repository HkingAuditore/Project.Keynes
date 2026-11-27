extends SceneTree
# 运行中切档必须重建 shader，并恢复天气/风场绑定；防止只改 uniform 而仍执行高档。
const WindSource = preload("res://scripts/rendering/weather_wind_source.gd")

var failures := 0
func _initialize() -> void:
	call_deferred("run")
func texture(color: Color) -> ImageTexture:
	var image := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	image.fill(color)
	return ImageTexture.create_from_image(image)
func check(ok: bool, message: String) -> void:
	print("[cloud-weather-quality] ", "PASS " if ok else "FAIL ", message)
	if not ok: failures += 1
func run() -> void:
	# Window changes during autoload _ready may flush deferred calls early.
	# Wait for root readiness before attaching test nodes (resize can pump frames).
	if not root.is_node_ready():
		await root.ready
	var world := WorldData.new()
	world.world_bounds = Rect2(0,0,1000,500)
	world.lut_dims = Vector2i.ONE
	world.enum_atlas_tex = texture(Color(0,0,0,1))
	world.weather_lut_tex = texture(Color(0,1,0.5,0))
	world.weather_lut_prev_tex = texture(Color(0,1,0.4,0))
	world.weather_lut_update_usec = 1000
	var map := MapData.new(1, 1)
	var cell := HexCell.new(0, 0)
	cell.index = 0
	map.set_cell(cell)
	map.wind_x_arr = PackedFloat32Array([1.0])
	map.wind_y_arr = PackedFloat32Array([0.0])
	map.wind_speed_arr = PackedFloat32Array([1.0])
	var padded_wind := WindSource.build_bytes(map, Vector2i(2, 2))
	check(padded_wind == PackedByteArray([255, 127, 12, 255,
		127, 127, 0, 255, 127, 127, 0, 255, 127, 127, 0, 255]),
		"wind image preserves the real cell and all neutral padding bytes")
	var weather := WeatherLayer.new()
	root.add_child(weather)
	weather.set_world_ref(world)
	weather.setup(world.world_bounds,world.enum_atlas_tex,null,22.0,world.weather_lut_tex,world.lut_dims,1000.0)
	var field := CloudShadowField.new()
	root.add_child(field)
	field.wind_lut_changed.connect(weather.set_wind_luts)
	field.configure(world.world_bounds,world,map,null,1000.0,2,"",true)
	for q in [0,1,2,1,0,2]:
		var old_cloud: ShaderMaterial = field.get("_field_material")
		var old_weather: ShaderMaterial = weather.get("_overlay_mat")
		field.set_quality(q,"",q >= 1)
		weather.set_visual_quality(q)
		await process_frame
		await process_frame
		var cloud_mat: ShaderMaterial = field.get("_field_material")
		var weather_mat: ShaderMaterial = weather.get("_overlay_mat")
		check(field.get_quality_resolution() == CloudShadowField.resolution_for_quality(q,false), "cloud resolution q=%d" % q)
		check(cloud_mat != old_cloud and weather_mat != old_weather, "materials rebuilt q=%d" % q)
		check(cloud_mat.get_shader_parameter("weather_lut") == world.weather_lut_tex, "cloud weather rebound q=%d" % q)
		check(weather_mat.get_shader_parameter("weather_lut_prev") == world.weather_lut_prev_tex, "weather previous LUT rebound q=%d" % q)
		check(weather_mat.get_shader_parameter("wind_lut") == cloud_mat.get_shader_parameter("wind_lut"), "shared wind rebound q=%d" % q)
		check(weather_mat.shader.code.begins_with("#define " + ["PK_WEATHER_LOW","PK_WEATHER_MID","PK_WEATHER_HIGH"][q]), "weather compile tier q=%d" % q)
	field.set_quality(2,"MOBILE_QUALITY_LOW",false)
	check(field.get_quality_resolution() == Vector2i(128,64), "mobile LOW caps requested HIGH")
	field.set_quality(2,"MOBILE_QUALITY_MID",false)
	check(field.get_quality_resolution() == Vector2i(192,96), "mobile MID caps requested HIGH")
	weather.set_mobile_quality_tier("MOBILE_QUALITY_LOW")
	var mobile_mat: ShaderMaterial = weather.get("_overlay_mat")
	check(mobile_mat.shader.code.begins_with("#define PK_WEATHER_LOW"), "weather mobile LOW caps requested HIGH")
	var old_tier_sim := DCFeatureFlags._mobile_tier_sim
	DCFeatureFlags._mobile_tier_sim = 1
	for q in [0, 1, 2]:
		weather.set_weather_detail(q)
		var detail_mat: ShaderMaterial = weather.get("_overlay_mat")
		check(detail_mat.shader.code.begins_with("#define " + ["PK_WEATHER_LOW", "PK_WEATHER_MID", "PK_WEATHER_HIGH"][q]),
			"weather override selects its own compile tier q=%d" % q)
		check(int(weather.get_cell_curtain_diag()["quality"]) == q, "curtain follows weather override q=%d" % q)
	weather.set_mobile_quality_tier("MOBILE_QUALITY_MID")
	weather.set_visual_quality(0)
	check(weather.get("_overlay_mat").shader.code.begins_with("#define PK_WEATHER_HIGH"),
		"total quality and main map tier changes preserve the explicit weather detail")
	weather.set_weather_detail(-1)
	check(weather.get("_overlay_mat").shader.code.begins_with("#define PK_WEATHER_LOW"),
		"clearing the override restores total weather quality")
	DCFeatureFlags._mobile_tier_sim = old_tier_sim
	# Production mobile-disabled route must retain weather wind independently.
	var renderer := HexRenderer.new()
	renderer._world = world
	renderer._map = map
	renderer._cloud_shadow_field = field
	renderer._weather_layer = weather
	var old_flags := DCFeatureFlags._debug_render_flags.duplicate()
	var old_loaded := DCFeatureFlags._debug_render_flags_loaded
	DCFeatureFlags._debug_render_flags_loaded = true
	DCFeatureFlags._debug_render_flags = {"cloud_shadow": 0}
	renderer._configure_cloud_shadow_field()
	check(weather._wind_lut_tex != null, "disabled cloud shadows retain local weather wind")
	check(field._viewport.render_target_update_mode == SubViewport.UPDATE_DISABLED,
		"wind-only mode never renders the cloud shadow viewport")
	var first_wind := weather._wind_lut_tex
	field._process(0.1)
	check(weather._wind_lut_tex == first_wind, "unchanged weather does not upload wind again")
	map.wind_x_arr[0] = -1.0
	var baker := MapBaker.new()
	baker._last_bake_map = map
	var report := baker._publish_weather_lut_bytes(PackedByteArray([0, 255, 127, 0]), world, 1, 1)
	check(report.get("weather_table_published", false), "the weather table publishes with shadows disabled")
	map.wind_x_arr[0] = 1.0
	field._process(0.1)
	check(weather._wind_lut_tex != null and weather._wind_lut_tex != first_wind,
		"wind changes continue publishing with cloud shadows disabled")
	if weather._wind_lut_tex != null:
		check(weather._wind_lut_tex.get_image().get_pixel(0, 0).r < 0.01,
			"published wind contains the new westward direction")
	check(field._viewport.render_target_update_mode == SubViewport.UPDATE_DISABLED,
		"weather publication does not reactivate cloud shadow rendering")
	field.set_quality(1, "MOBILE_QUALITY_MID", false)
	field._process(0.1)
	check(field._viewport.render_target_update_mode == SubViewport.UPDATE_DISABLED,
		"quality changes keep the disabled cloud shadow viewport asleep")
	field.clear_inputs()
	check(weather._wind_lut_tex == null, "session teardown clears the wind source")
	renderer._configure_cloud_shadow_field()
	check(weather._wind_lut_tex != null, "disabled shadows also support a fresh session")
	var next_world := WorldData.new()
	next_world.lut_dims = Vector2i.ONE
	next_world.weather_lut_update_usec = world.weather_lut_update_usec
	var next_map := MapData.new(1, 1)
	next_map.wind_x_arr = PackedFloat32Array([0.0])
	next_map.wind_y_arr = PackedFloat32Array([1.0])
	next_map.wind_speed_arr = PackedFloat32Array([20.0])
	renderer._world = next_world
	renderer._map = next_map
	renderer._configure_cloud_shadow_field()
	check(weather._wind_lut_tex != null and not weather._has_wind_prev,
		"new world with the same stamp does not interpolate old-world wind")
	if weather._wind_lut_tex != null:
		var pixel := weather._wind_lut_tex.get_image().get_pixel(0, 0)
		check(pixel.g > 0.99 and pixel.b > 0.99, "new world publishes its own wind")
	DCFeatureFlags._debug_render_flags = old_flags
	DCFeatureFlags._debug_render_flags_loaded = old_loaded
	renderer._cloud_shadow_field = null
	renderer._weather_layer = null
	renderer.free()
	field.queue_free()
	weather.queue_free()
	await process_frame
	await _check_curtain_instances()
	print("[cloud-weather-quality] failures=",failures)
	quit(0 if failures == 0 else 1)

func _check_curtain_instances() -> void:
	var weather := WeatherLayer.new()
	root.add_child(weather)
	weather.set_process(false)
	weather.set_weather_detail(2)
	var world := WorldData.new()
	world.lut_dims = Vector2i(4, 1)
	var map := MapData.new(4, 1)
	for column in range(4):
		var cube := HexUtils.offset_to_cube(column, 0)
		map.set_cell(HexCell.new(cube.x, cube.y))
	map._build_indices()
	var current := PackedByteArray([
		WeatherType.WT.CLEAR, 0, 0, 0, WeatherType.WT.RAIN, 0, 0, 0,
		WeatherType.WT.BLIZZARD, 0, 0, 0, WeatherType.WT.FOG, 0, 0, 0,
	])
	var previous := current.duplicate()
	previous[0] = WeatherType.WT.RAIN
	previous[1] = 255
	previous[13] = 128
	var baker := MapBaker.new()
	DCCellLutBaker._upload_weather_lut_pair(baker, world, 4, 1, previous, current)
	weather.set_world_ref(world)
	weather.setup(Rect2(0, 0, 160, 44), null, null, 22.0, world.weather_lut_tex, world.lut_dims, 160.0, map)
	var instances := weather._curtains.multimeshes[0]
	check(instances.visible_instance_count == 9 and weather._curtains.draw_cells == PackedInt32Array([1, 2, 3]),
		"rain and snow survive at zero intensity, and only current type participates in the blend")
	if DisplayServer.get_name() != "headless":
		var cube := HexUtils.offset_to_cube(1, 0)
		var center := HexUtils.cube_to_world(cube.x, cube.y, 22.0)
		var offsets := [-160.0, 0.0, 160.0]
		for copy_index in offsets.size():
			var transform := instances.get_instance_transform_2d(copy_index)
			var custom := instances.get_instance_custom_data(copy_index)
			check(transform.origin.is_equal_approx(center + Vector2(offsets[copy_index], 0.0))
				and roundi(custom.r * 255.0) == 1 and roundi(custom.g * 255.0) == 0,
				"the first contributing cell retains its position, index and wrap order")
	weather._refresh_curtain_instances(world.weather_lut_update_usec, false)
	check(instances.instance_count == 12 and instances.visible_instance_count == 6
		and weather._curtains.draw_cells == PackedInt32Array([1, 2]),
		"fog at zero intensity stops submitting instances after the blend")
	var texture_before := world.weather_lut_tex
	current = current.duplicate()
	current[0] = WeatherType.WT.RAIN
	current[4] = WeatherType.WT.CLEAR
	DCCellLutBaker._upload_weather_lut_pair(baker, world, 4, 1, previous, current)
	weather._refresh_curtain_instances(world.weather_lut_update_usec, false)
	check(world.weather_lut_tex == texture_before and weather._curtains.draw_cells == PackedInt32Array([0, 2]),
		"an in-place LUT upload refreshes contributors even when the instance count is unchanged")
	weather.set_weather_strength(0.0)
	check(not weather._curtains.root.visible, "zero global weather strength hides all curtain layers")
	weather.queue_free()
	await process_frame
