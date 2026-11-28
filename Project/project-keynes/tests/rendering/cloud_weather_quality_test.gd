extends SceneTree
# 运行中切档必须重建 shader，并恢复天气/风场绑定；防止只改 uniform 而仍执行高档。
const WindSource = preload("res://scripts/rendering/weather_wind_source.gd")
const ValleyFogPublication = preload("res://scripts/rendering/bakers/valley_fog_publication.gd")

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
	_check_valley_fog_publication()
	await _check_valley_fog_quality()
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


func _check_valley_fog_publication() -> void:
	var fog := ValleyFogPublication.new()
	var dimensions := Vector2i(2, 1)
	var map_id := 42
	var source := {
		"map_id": map_id, "generation": 7, "size": dimensions, "terrain_generation": 1,
		"rg": PackedFloat32Array([0.8, 0.34, 0.0, 0.21]), "has_density": true,
	}
	check(fog.publish(source, map_id, dimensions, 100), "fog accepts the first matching weather frame")
	check(fog.current == fog.previous and fog.generation == 7 and fog.previous_generation == 7
		and fog.has_density and fog.previous_has_density, "first fog frame interpolates to itself")
	var initial_current: Variant = fog.current
	check(fog.publish(source, map_id, dimensions, 100) and fog.current == initial_current and fog.stamp == 100,
		"repeated submission is idempotent")
	var next := source.duplicate()
	next["generation"] = 8
	next["rg"] = PackedFloat32Array([0.0, 0.35, 0.0, 0.21])
	next["has_density"] = false
	check(fog.publish(next, map_id, dimensions, 200), "fog accepts the next weather generation")
	check(fog.previous == initial_current and fog.generation == 8 and fog.previous_generation == 7
		and not fog.has_density and fog.previous_has_density, "contiguous dry weather retains the wet previous layer")
	var accepted_current: Variant = fog.current
	var refused_cases := {
		"missing payload": null,
		"missing values": {"generation": 9},
		"wrong world": _fog_patch(source, {"map_id": 43, "generation": 9}),
		"wrong dimensions": _fog_patch(source, {"size": Vector2i.ONE, "generation": 9}),
		"wrong length": _fog_patch(source, {"rg": PackedFloat32Array([1.0, 0.30]), "generation": 9}),
		"wrong array type": _fog_patch(source, {"rg": [0.8, 0.34, 0.0, 0.21], "generation": 9}),
		"invalid terrain generation": _fog_patch(source, {"terrain_generation": 0, "generation": 9}),
		"stale generation": source,
		"non-finite density": _fog_patch(source, {"rg": PackedFloat32Array([NAN, 0.34, 0.0, 0.21]), "generation": 9}),
		"non-finite fog top": _fog_patch(source, {"rg": PackedFloat32Array([0.8, INF, 0.0, 0.21]), "generation": 9}),
		"negative density": _fog_patch(source, {"rg": PackedFloat32Array([-1.0, 0.34, 0.0, 0.21]), "generation": 9}),
		"fog top outside altitude range": _fog_patch(source, {"rg": PackedFloat32Array([0.8, 1.01, 0.0, 0.21]), "generation": 9}),
		"incorrect empty summary": _fog_patch(source, {"has_density": false, "generation": 9}),
	}
	for label in refused_cases:
		check(not fog.publish(refused_cases[label], map_id, dimensions, 300), "fog rejects %s" % label)
		check(fog.generation == 8 and fog.previous_generation == 7 and fog.stamp == 200
			and fog.current == accepted_current and fog.previous == initial_current,
			"rejecting %s preserves the accepted pair" % label)
	var later := _fog_patch(source, {"generation": 10})
	check(fog.publish(later, map_id, dimensions, 400) and fog.current == fog.previous
		and fog.previous_generation == 10, "skipping a weather generation starts from the latest pair")
	var restored := _fog_patch(source, {"generation": 11})
	check(fog.publish(restored, map_id, dimensions, 500, true) and fog.current == fog.previous
		and fog.previous_generation == 11, "restore forces both layers to the same generation")
	var reterrain := _fog_patch(next, {"generation": 12, "terrain_generation": 2})
	check(fog.publish(reterrain, map_id, dimensions, 600) and fog.current == fog.previous
		and fog.previous_generation == 12 and not fog.previous_has_density,
		"changing terrain resets interpolation even on consecutive weather generations")
	fog.invalidate(700)
	check(fog.current.is_empty() and fog.previous.is_empty() and fog.generation == 12 and fog.stamp == 700,
		"missing fog for a new weather generation drops both drawable endpoints")
	var recovered := _fog_patch(source, {"generation": 14, "terrain_generation": 2})
	check(fog.publish(recovered, map_id, dimensions, 800) and fog.current == fog.previous
		and fog.previous_generation == 14 and fog.has_density, "valid weather recovers after a missing fog publication")


func _fog_patch(source: Dictionary, values: Dictionary) -> Dictionary:
	var result := source.duplicate()
	result.merge(values, true)
	return result


func _check_valley_fog_quality() -> void:
	if OS.has_feature("web") or OS.has_feature("mobile"):
		return
	var weather := WeatherLayer.new()
	weather.weather_cell_field_enabled = false
	weather.valley_fog_enabled = true
	root.add_child(weather)
	weather.set_process(false)
	var world := WorldData.new()
	world.world_bounds = Rect2(0, 0, 40, 40)
	world.lut_dims = Vector2i.ONE
	world.weather_table_dims = Vector2i.ONE
	world.height_tex = texture(Color(0.18, 0, 0, 1))
	world.weather_lut_tex = texture(Color(0, 0, 0, 0))
	world.weather_lut_update_usec = 200
	var payload := {"map_id": 41, "generation": 1, "terrain_generation": 1, "size": Vector2i.ONE,
		"rg": PackedFloat32Array([0.7, 0.34]), "has_density": true}
	check(world.valley_fog.publish(payload, 41, Vector2i.ONE, 200), "accept the clear-sky valley-fog fixture")
	weather.set_world_ref(world)
	weather.setup(world.world_bounds, null, null, 22.0, world.weather_lut_tex, world.lut_dims, 40.0)
	var mat: ShaderMaterial = weather.get("_overlay_mat")
	check(weather.visible and mat.get_shader_parameter("valley_fog_active") == true,
		"high weather keeps the overlay live for a clear sky with valley fog")
	check(mat.get_shader_parameter("valley_fog_cur_layer") == mat.get_shader_parameter("valley_fog_prev_layer"),
		"first bound fog frame uses one texture layer at both interpolation endpoints")
	for quality in [0, 1]:
		weather.set_visual_quality(quality)
		check(not weather._valley_fog.compiled and weather._valley_fog._texture == null,
			"weather quality %d releases the valley-fog texture" % quality)
		check(world.valley_fog.generation == 1 and world.valley_fog.has_density,
			"render quality %d preserves the published fog data" % quality)
	weather.set_visual_quality(2)
	mat = weather.get("_overlay_mat")
	check(mat.get_shader_parameter("valley_fog_active") == true and weather._valley_fog._texture != null,
		"returning to high quality binds the latest valley fog frame")
	weather.set_render_gate(false)
	check(not weather.visible and weather._valley_fog._texture == null,
		"closing the weather layer gate releases all dedicated fog texture state")
	weather.set_render_gate(true)
	check(weather.visible and mat.get_shader_parameter("valley_fog_active") == true,
		"reopening the weather gate restores the current fog frame")
	var dry := _fog_patch(payload, {"generation": 2, "has_density": false, "rg": PackedFloat32Array([0.0, 0.21])})
	check(world.valley_fog.publish(dry, 41, Vector2i.ONE, 300), "accept dry weather after the foggy frame")
	world.weather_lut_update_usec = 300
	weather._wx_lut_last_usec = 300
	weather._wx_lut_t0_usec = Time.get_ticks_usec() - 2000
	weather._wx_commit_interval_usec = 1000.0
	weather._wx_pushed_lerp = 0.9985
	weather._valley_fog.push(weather)
	check(mat.get_shader_parameter("valley_fog_active") == true,
		"a contributing previous frame remains active just before the interpolation endpoint")
	weather._process(0.0)
	check(mat.get_shader_parameter("weather_lerp") == 1.0 and mat.get_shader_parameter("valley_fog_active") == false,
		"the final sub-threshold interpolation step still completes and stops sampling fog")
	var replacement := WorldData.new()
	replacement.weather_lut_update_usec = world.weather_lut_update_usec
	weather.set_world_ref(replacement)
	check(weather._valley_fog._texture == null and mat.get_shader_parameter("valley_fog_active") == false,
		"world replacement drops the previous fog even if its weather stamp matches")
	weather.queue_free()
	await process_frame
