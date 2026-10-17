extends SceneTree

# 真 GPU：贴地植被跨两种坡向，高档逐像素变化；树冠仍只读取平坦的中心点。
const Shrubs = preload("res://scripts/rendering/shrub_layer.gd")
const Profile = preload("res://scripts/data/shrub_visual_profile.gd")
var viewport: SubViewport
var camera: Camera2D
var subject: MultiMeshInstance2D
var mat: ShaderMaterial
var checks := 0
var failures := 0
var output := "res://tmp/vegetation_pixel_normal_qa"
var flat_image: Image
var slope_image: Image

func _init() -> void:
	call_deferred("run")

func run() -> void:
	output += "/" + RenderingServer.get_current_rendering_method()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output))
	viewport = SubViewport.new()
	viewport.size = Vector2i(256, 128)
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	camera = Camera2D.new()
	camera.position = Vector2(128, 64)
	viewport.add_child(camera)
	subject = MultiMeshInstance2D.new()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_2D
	mm.use_colors = true
	mm.use_custom_data = true
	var mesh := QuadMesh.new()
	mesh.size = Vector2.ONE * 1.24
	mm.mesh = mesh
	mm.instance_count = 1
	mm.set_instance_transform_2d(0, Transform2D(0.0, Vector2(90, 90), 0.0, Vector2(128, 64)))
	mm.set_instance_color(0, Color(0.3, 0.5, 0.22, 1))
	mm.set_instance_custom_data(0, Color(0.5, 0.5, 0.37, Shrubs.pack_form(2, 9)))
	subject.multimesh = mm
	viewport.add_child(subject)
	flat_image = Image.create(64, 32, false, Image.FORMAT_RGBA8)
	flat_image.fill(Color(0.5, 0.5, 0, 1))
	slope_image = flat_image.duplicate()
	for y in 32:
		for x in 64:
			if x < 30 or x > 33:
				slope_image.set_pixel(x, y, Color(0.12 if x < 32 else 0.88, 0.5, 0, 1))
	for variant in ["source", "family", "tiled_family", "mobile_high", "mobile_mid"]:
		_configure(variant)
		mat.set_shader_parameter("terrain_normal_tex_bound", true)
		for quality in [1, 2]:
			mat.set_shader_parameter("veg_shade_quality", quality)
			_set_normals(flat_image, variant)
			var flat := await _capture(variant + "_q%d_flat" % quality)
			_set_normals(slope_image, variant)
			var sloped := await _capture(variant + "_q%d_slope" % quality)
			var delta := _difference(flat, sloped)
			var pixel_path: bool = quality == 2 and variant != "mobile_mid"
			_expect("%s q%d %s (delta %.5f)" % [variant, quality, "follows both slopes" if pixel_path else "keeps center normal", delta],
				_alpha(flat) > 50.0 and (delta > 0.0005 if pixel_path else delta < 0.00001))
			if pixel_path:
				mat.set_shader_parameter("terrain_normal_tex_bound", false)
				var unbound_slope := await _capture(variant + "_unbound_slope")
				_set_normals(flat_image, variant)
				var unbound_flat := await _capture(variant + "_unbound_flat")
				_expect(variant + " missing terrain normal is neutral", _difference(unbound_slope, unbound_flat) < 0.00001)
				mat.set_shader_parameter("terrain_normal_tex_bound", true)
				_set_normals(slope_image, variant)
				mat.set_shader_parameter("wrap_period_x", 256.0)
				var base := await _capture(variant + "_wrap_base")
				mm.set_instance_transform_2d(0, Transform2D(0.0, Vector2(90, 90), 0.0, Vector2(384, 64)))
				camera.position.x += 256.0
				camera.force_update_scroll()
				var wrapped := await _capture(variant + "_wrapped")
				_expect(variant + " wrap copy samples the same world slopes", _difference(base, wrapped) < 0.001)
				mm.set_instance_transform_2d(0, Transform2D(0.0, Vector2(90, 90), 0.0, Vector2(128, 64)))
				camera.position.x -= 256.0
				camera.force_update_scroll()
				mat.set_shader_parameter("wrap_period_x", 0.0)
		# 同一材质/合批路径内，树冠不能被高档贴地开关带入逐像素采样。
		_set_form(Profile.FORM_BROADLEAF)
		mat.set_shader_parameter("veg_shade_quality", 2)
		_set_normals(flat_image, variant)
		var canopy_flat := await _capture(variant + "_canopy_flat")
		_set_normals(slope_image, variant)
		var canopy_slopes := await _capture(variant + "_canopy_slopes")
		_expect(variant + " canopy keeps a shared center normal", _alpha(canopy_flat) > 200.0 and _difference(canopy_flat, canopy_slopes) < 0.00001)
		var tilted := flat_image.duplicate()
		tilted.fill(Color(0.88, 0.5, 0, 1))
		_set_normals(tilted, variant)
		var canopy_tilted := await _capture(variant + "_canopy_center_tilt")
		var mobile_variant: bool = variant.begins_with("mobile")
		_expect(variant + " canopy retains its original quality policy", _difference(canopy_flat, canopy_tilted) < 0.00001 if mobile_variant else _difference(canopy_flat, canopy_tilted) > 0.002)
	# 草丛也用同一个片元路径，不能只对树冠生效。
	_configure("source")
	mat.set_shader_parameter("detail_form", Profile.FORM_GRASS)
	mat.set_shader_parameter("veg_shade_quality", 2)
	mat.set_shader_parameter("terrain_normal_tex_bound", true)
	_set_normals(flat_image, "source")
	var grass_flat := await _capture("grass_flat")
	_set_normals(slope_image, "source")
	var grass_slope := await _capture("grass_slope")
	_expect("grass also follows pixel terrain normals", _alpha(grass_flat) > 50.0 and _difference(grass_flat, grass_slope) > 0.0005)
	print("vegetation pixel normals: %d checks, %d failures; %s" % [checks, failures, output])
	viewport.queue_free()
	await process_frame
	quit(0 if failures == 0 else 1)

func _configure(variant: String) -> void:
	var prefix := ""
	if variant.contains("family"):
		prefix += "#define DETAIL_FAMILY_BATCH\n"
	if variant == "tiled_family":
		prefix += "#define MAP_VISUAL_TILED\n"
	if variant == "mobile_high":
		prefix += "#define MOBILE_QUALITY_HIGH\n"
	if variant == "mobile_mid":
		prefix += "#define MOBILE_QUALITY_MID\n"
	var shader := Shader.new()
	shader.code = prefix + Shrubs._SHADER_CODE
	mat = ShaderMaterial.new()
	mat.shader = shader
	subject.material = mat
	mat.set_shader_parameter("world_origin", Vector2.ZERO)
	mat.set_shader_parameter("world_size", Vector2(256, 128))
	mat.set_shader_parameter("lut_dims", Vector2.ONE)
	mat.set_shader_parameter("dyn_lut", _texture(Color(0.6, 0.65, 0, 1)))
	mat.set_shader_parameter("eco_lut", _texture(Color(1, 0, 0, 0)))
	mat.set_shader_parameter("detail_form", Profile.FORM_GRASS)
	mat.set_shader_parameter("terrain_normal_influence", 1.0)
	mat.set_shader_parameter("terrain_valley_ao_strength", 0.0)
	mat.set_shader_parameter("wind_strength", 0.0)
	mat.set_shader_parameter("day_night_enabled", false)
	mat.set_shader_parameter("tod_debug_sun_position_enabled", true)
	mat.set_shader_parameter("tod_sun_dir", Vector3(0.8, 0, 0.6))
	if variant == "tiled_family":
		mat.set_shader_parameter("visual_domain_origin", Vector2.ZERO)
		mat.set_shader_parameter("visual_domain_size", Vector2(256, 128))
		mat.set_shader_parameter("visual_grid_size", Vector2(2, 1))
		mat.set_shader_parameter("visual_interior_size", Vector2(32, 32))
		mat.set_shader_parameter("visual_layer_size", Vector2(36, 36))
		mat.set_shader_parameter("visual_logical_resolution", Vector2(64, 32))
		mat.set_shader_parameter("visual_gutter_px", 2.0)
		var idx := Image.create(36, 36, false, Image.FORMAT_RGBA8)
		idx.fill(Color(0, 0, 0, 1))
		var indices := Texture2DArray.new()
		indices.create_from_images([idx, idx])
		mat.set_shader_parameter("visual_map_index_tiles", indices)
	else:
		mat.set_shader_parameter("map_index_atlas", _texture(Color(0, 0, 0, 1)))
	if variant.contains("family"):
		var lut := Image.create(16, 32, false, Image.FORMAT_RGBAF)
		lut.set_pixel(3, 0, Color(float(Profile.FORM_GRASS), 1.0, 0.64, 1.0))
		lut.set_pixel(4, 0, Color(0, 0, 0.38, 0.55))
		lut.set_pixel(5, 0, Color(0, 0, 1, 1))
		mat.set_shader_parameter("detail_style_lut", ImageTexture.create_from_image(lut))

func _set_form(form: int) -> void:
	mat.set_shader_parameter("detail_form", form)
	var texture = mat.get_shader_parameter("detail_style_lut")
	if texture is ImageTexture:
		var image: Image = texture.get_image()
		var entry := image.get_pixel(3, 0)
		entry.r = float(form)
		image.set_pixel(3, 0, entry)
		texture.update(image)

func _set_normals(image: Image, variant: String) -> void:
	if variant != "tiled_family":
		mat.set_shader_parameter("terrain_normal_tex", ImageTexture.create_from_image(image))
		return
	var layers: Array[Image] = []
	for tile in 2:
		var part := Image.create(36, 36, false, Image.FORMAT_RGBA8)
		for y in 36:
			for x in 36:
				part.set_pixel(x, y, image.get_pixel(clampi(tile * 32 + x - 2, 0, 63), clampi(y - 2, 0, 31)))
		layers.append(part)
	var texture := Texture2DArray.new()
	texture.create_from_images(layers)
	mat.set_shader_parameter("visual_terrain_normal_tiles", texture)

func _texture(color: Color) -> ImageTexture:
	var image := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	image.fill(color)
	return ImageTexture.create_from_image(image)

func _capture(label: String) -> Image:
	for frame in 3:
		await process_frame
	await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image()
	image.save_png(output + "/" + label + ".png")
	return image

func _difference(a: Image, b: Image) -> float:
	var sum := 0.0
	for y in a.get_height():
		for x in a.get_width():
			var p := a.get_pixel(x, y)
			var q := b.get_pixel(x, y)
			sum += (absf(p.r - q.r) + absf(p.g - q.g) + absf(p.b - q.b)) * minf(p.a, q.a)
	return sum / float(a.get_width() * a.get_height())

func _alpha(image: Image) -> float:
	var sum := 0.0
	for y in image.get_height():
		for x in image.get_width():
			sum += image.get_pixel(x, y).a
	return sum

func _expect(label: String, passed: bool) -> void:
	checks += 1
	if not passed:
		failures += 1
	print("[PASS] " if passed else "[FAIL] ", label)
