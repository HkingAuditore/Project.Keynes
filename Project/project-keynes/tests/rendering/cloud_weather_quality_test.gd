extends SceneTree
# 运行中切档必须重建 shader，并恢复天气/风场绑定；防止只改 uniform 而仍执行高档。
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
	var world := WorldData.new()
	world.world_bounds = Rect2(0,0,1000,500)
	world.lut_dims = Vector2i.ONE
	world.enum_atlas_tex = texture(Color(0,0,0,1))
	world.weather_lut_tex = texture(Color(0,1,0.5,0))
	world.weather_lut_prev_tex = texture(Color(0,1,0.4,0))
	world.weather_lut_update_usec = 1000
	var map := MapData.new(1, 1)
	map.wind_x_arr = PackedFloat32Array([1.0])
	map.wind_y_arr = PackedFloat32Array([0.0])
	map.wind_speed_arr = PackedFloat32Array([1.0])
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
	field.queue_free()
	weather.queue_free()
	await process_frame
	print("[cloud-weather-quality] failures=",failures)
	quit(0 if failures == 0 else 1)
