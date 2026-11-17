extends SceneTree

# Requires real rendering. Optional --reference=/absolute/before.gdshader compares
# the whole production shader; otherwise compare with uncropped 5x5 snow search.
var failures := 0
var comparisons := 0
var materials: Array[ShaderMaterial] = []
var views: Array[SubViewport] = []
var meshes: Array[MultiMesh] = []
var output := ""

func _initialize() -> void:
	call_deferred("run")

func texture(color: Color) -> ImageTexture:
	var image := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	image.fill(color)
	return ImageTexture.create_from_image(image)

func check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)

func run() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("weather curtain culling needs an actual rendering display")
		quit(2)
		return
	var source := FileAccess.get_file_as_string("res://shaders/weather_cell_curtain.gdshader")
	var reference := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--reference="):
			reference = FileAccess.get_file_as_string(arg.trim_prefix("--reference="))
		if arg.begins_with("--output="):
			output = arg.trim_prefix("--output=")
	if reference.is_empty():
		var regex := RegEx.new()
		regex.compile("(?s)// SNOW_CULL_BEGIN.*?// SNOW_CULL_END")
		check(regex.search_all(source).size() == 1, "snow culling block is covered")
		reference = regex.sub(source, "", true)
		reference = reference.replace("int y = -1; y <= 1", "int y = -2; y <= 2")
		reference = reference.replace("int x = -1; x <= 1", "int x = -2; x <= 2")
	for i in range(2):
		var view := SubViewport.new()
		view.size = Vector2i(256, 256)
		view.transparent_bg = true
		view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		root.add_child(view)
		views.append(view)
		var node := MultiMeshInstance2D.new()
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_2D
		mm.use_custom_data = true
		var quad := QuadMesh.new()
		quad.size = Vector2(256, 256)
		mm.mesh = quad
		mm.instance_count = 1
		mm.set_instance_transform_2d(0, Transform2D(0, Vector2(128, 128)))
		node.multimesh = mm
		meshes.append(mm)
		var material := ShaderMaterial.new()
		node.material = material
		materials.append(material)
		view.add_child(node)
	# Desktop, three mobile tiers, Web's compile tier. Same scatter at all tiers.
	var prefixes := ["", "#define MOBILE_QUALITY_LOW\n", "#define MOBILE_QUALITY_MID\n",
		"#define MOBILE_QUALITY_HIGH\n", "#define MOBILE_QUALITY_LOW\n#define PK_WEB_TEXTURE_BUDGET\n"]
	for variant in range(prefixes.size()):
		for i in range(2):
			var shader := Shader.new()
			shader.code = prefixes[variant] + (source if i == 0 else reference)
			materials[i].shader = shader
			materials[i].set_shader_parameter("lut_dims", Vector2.ONE)
			materials[i].set_shader_parameter("hex_world_diameter", 44.0)
			materials[i].set_shader_parameter("weather_lut", texture(Color(1.0 / 255, 0.8, 0.5, 0)))
			materials[i].set_shader_parameter("weather_lut_prev", texture(Color(1.0 / 255, 0.3, 0.5, 0)))
		for depth in [0.0, 0.5, 1.0]:
			for time in [0.0, 4.7, 12006.0]:
				await compare_case(variant, depth, time, 1.309, 1.0, 1.0, 4)
		# Extreme projection, partial/hidden fog, weather interpolation, rain and
		# mixed flags exercise vertex LUT transfer as well as the snow bounds.
		for pitch in [0.0, PI * 0.5]:
			for depth in [0.0, 0.5, 1.0]:
				await compare_case(variant, depth, 21.3, pitch, 0.75, 0.35, 4)
		await compare_case(variant, 0.0, 2.1, 1.309, 0.0, 0.5, 4)
		await compare_case(variant, 0.5, 2.1, 1.309, 0.5, 0.5, 8)
		await compare_case(variant, 0.0, 2.1, 1.309, 1.0, 0.5, 30)
	for view in views:
		view.queue_free()
	await process_frame
	print("weather curtain culling: %d comparisons, %d failures" % [comparisons, failures])
	quit(0 if failures == 0 else 1)

func compare_case(variant: int, depth: float, time: float, pitch: float,
		visibility: float, weather_lerp: float, flags: int) -> void:
	for i in range(2):
		meshes[i].set_instance_custom_data(0, Color(0, 0, 0.317 + depth * 0.23, depth))
		materials[i].set_shader_parameter("layer_depth", depth)
		materials[i].set_shader_parameter("world_time", time)
		materials[i].set_shader_parameter("camera_pitch", pitch)
		materials[i].set_shader_parameter("wind_strength", -1.0 if pitch == 0.0 else 1.0)
		materials[i].set_shader_parameter("weather_lerp", weather_lerp)
		materials[i].set_shader_parameter("fog_mask_enabled", true)
		materials[i].set_shader_parameter("enum_lut", texture(Color(0, 0, 0, visibility)))
		materials[i].set_shader_parameter("weather_profile_flags", PackedInt32Array([0, flags, 0, 0, 0, 0, 0, 0]))
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	var a := views[0].get_texture().get_image()
	var b := views[1].get_texture().get_image()
	var a_bytes := a.get_data()
	var b_bytes := b.get_data()
	var max_difference := 0
	var nonzero_alpha := 0
	for index in range(a_bytes.size()):
		max_difference = maxi(max_difference, absi(int(a_bytes[index]) - int(b_bytes[index])))
		if index % 4 == 3 and a_bytes[index] > 0:
			nonzero_alpha += 1
	var label := "variant=%d depth=%.1f time=%.1f pitch=%.3f visibility=%.2f flags=%d" % [variant, depth, time, pitch, visibility, flags]
	check(max_difference == 0, "%s pixel difference=%d" % [label, max_difference])
	check(nonzero_alpha > 0 if visibility > 0.5 else nonzero_alpha == 0, label + " visibility")
	if not output.is_empty() and (comparisons == 0 or max_difference > 0):
		a.save_png(output.path_join("curtain-%d-after.png" % comparisons))
		b.save_png(output.path_join("curtain-%d-reference.png" % comparisons))
	comparisons += 1
