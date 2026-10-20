extends SceneTree

# Exercise the actual ResourceGroundCover and imported plant art. A debug sun
# position matching the normal astronomy must produce the same lighting.
const Cover = preload("res://scripts/rendering/resource_ground_cover.gd")
const Catalog = preload("res://scripts/rendering/resource_visual_catalog.gd")
var viewport: SubViewport
var camera: Camera2D
var cover: ResourceGroundCover
var mat: ShaderMaterial
var checks := 0
var failures := 0
var output := "res://tmp/ground_cover_lighting_qa"

func _init() -> void:
	call_deferred("run")

func run() -> void:
	output += "/" + RenderingServer.get_current_rendering_method()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output))
	viewport = SubViewport.new()
	viewport.size = Vector2i(512, 256)
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	camera = Camera2D.new()
	camera.position = Vector2(256, 128)
	viewport.add_child(camera)
	cover = Cover.new()
	viewport.add_child(cover)
	cover.configure(Catalog.entries(), 64.0, Vector2i.ONE, Rect2(0, 0, 512, 256), 0.0,
		_texture(Color(0, 0, 0, 1)), null)
	var art := ResourceArtLibrary.shared()
	cover.write_cell(0, Color8(art.cover_layer("bio.wheat") * 16, 255, 0, 0))
	cover.flush(true)
	mat = cover.material()
	mat.set_shader_parameter("memory_lut", _texture(Color(0.6, 0.7, 0, 1)))
	mat.set_shader_parameter("wind_strength", 0.0)
	mat.set_shader_parameter("world_time", 0.0)
	mat.set_shader_parameter("cover_taps", 1)
	mat.set_shader_parameter("tod_sun_dir", Vector3(0.4, -0.7, 0.6).normalized())
	mat.set_shader_parameter("season_phase", 1.0)
	mat.set_shader_parameter("day_phase", 0.25)
	for variant in ["desktop_low", "desktop_mid", "desktop_high", "mobile_low", "mobile_mid", "mobile_high", "tiled_high"]:
		var quality: int = 0 if variant.ends_with("low") else (1 if variant.ends_with("mid") else 2)
		cover.set_quality(quality, quality if variant.begins_with("mobile") else -1)
		if variant == "tiled_high":
			var shader := Shader.new()
			shader.code = "#define MAP_VISUAL_TILED\n" + Cover.SHADER.code
			mat.shader = shader
			mat.set_shader_parameter("visual_domain_size", Vector2(512, 256))
			mat.set_shader_parameter("visual_grid_size", Vector2.ONE)
			mat.set_shader_parameter("visual_interior_size", Vector2(8, 8))
			mat.set_shader_parameter("visual_layer_size", Vector2(8, 8))
			mat.set_shader_parameter("visual_logical_resolution", Vector2(8, 8))
			mat.set_shader_parameter("visual_gutter_px", 0.0)
			var array := Texture2DArray.new()
			var idx := Image.create(8, 8, false, Image.FORMAT_RGBA8)
			idx.fill(Color(0, 0, 0, 1))
			array.create_from_images([idx])
			mat.set_shader_parameter("visual_map_index_tiles", array)
		mat.set_shader_parameter("day_night_enabled", true)
		mat.set_shader_parameter("tod_debug_sun_position_enabled", false)
		var normal := await _capture(variant + "_astronomical")
		mat.set_shader_parameter("tod_debug_sun_position_enabled", true)
		mat.set_shader_parameter("tod_debug_sun_uv", Vector2(0.25, 0.5))
		var debug := await _capture(variant + "_debug_same_sun")
		_expect(variant + " debug sun uses the same pixel astronomy", _difference(normal, debug) < 0.001)
		_expect(variant + " night pixels are darker than day pixels", _luma(debug, Rect2i(290, 75, 125, 106))
			< _luma(debug, Rect2i(75, 75, 125, 106)) * 0.55)
		mat.set_shader_parameter("tod_sun_dir", Vector3(-0.7, 0.3, -0.6).normalized())
		var stale_global := await _capture(variant + "_global_sun_changed")
		_expect(variant + " debug map sun ignores unrelated global sun", _difference(debug, stale_global) < 0.00001)
		mat.set_shader_parameter("day_night_enabled", false)
		var eternal_down := await _capture(variant + "_eternal_debug_down")
		mat.set_shader_parameter("tod_sun_dir", Vector3(0.4, -0.7, 0.6).normalized())
		var eternal_up := await _capture(variant + "_eternal_debug_up")
		_expect(variant + " eternal debug retains explicit parallel sun", _difference(eternal_down, eternal_up) > 0.02)
		mat.set_shader_parameter("tod_debug_sun_position_enabled", false)
		mat.set_shader_parameter("day_night_enabled", true)
	print("resource ground cover lighting: %d checks, %d failures; %s" % [checks, failures, output])
	viewport.queue_free()
	await process_frame
	quit(0 if failures == 0 else 1)

func _texture(c: Color) -> ImageTexture:
	var img := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	img.fill(c)
	return ImageTexture.create_from_image(img)

func _capture(label: String) -> Image:
	for frame in 3:
		await process_frame
	await RenderingServer.frame_post_draw
	var img := viewport.get_texture().get_image()
	img.save_png(output + "/" + label + ".png")
	return img

func _difference(a: Image, b: Image) -> float:
	var total := 0.0
	var weight := 0.0
	for y in a.get_height():
		for x in a.get_width():
			var p := a.get_pixel(x, y)
			var q := b.get_pixel(x, y)
			var alpha := minf(p.a, q.a)
			total += (absf(p.r - q.r) + absf(p.g - q.g) + absf(p.b - q.b)) * alpha
			weight += alpha
	return total / maxf(weight, 0.001)

func _luma(img: Image, rect: Rect2i) -> float:
	var total := 0.0
	var weight := 0.0
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			var c := img.get_pixel(x, y)
			total += (c.r * 0.299 + c.g * 0.587 + c.b * 0.114) * c.a
			weight += c.a
	return total / maxf(weight, 0.001)

func _expect(label: String, ok: bool) -> void:
	checks += 1
	if not ok:
		failures += 1
	print("[PASS] " if ok else "[FAIL] ", label)
