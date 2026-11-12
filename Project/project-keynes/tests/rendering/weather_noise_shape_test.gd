# Actual GPU regression for square cloud contours at uniform weather/wind.
# Run with --rendering-method gl_compatibility -- PK_WEATHER_MID.
extends SceneTree
var mat: ShaderMaterial
var vp: SubViewport
var failures := 0
func _initialize():
	call_deferred("run")
func tex(color: Color) -> Texture2D:
	var img := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	img.fill(color)
	return ImageTexture.create_from_image(img)
func capture(t: float, lerp_weight: float = 1.0) -> Image:
	mat.set_shader_parameter("world_time", t)
	mat.set_shader_parameter("weather_lerp", lerp_weight)
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	return vp.get_texture().get_image()
func difference(a: Image, b: Image) -> float:
	var maximum := 0.0
	for y in range(a.get_height()):
		for x in range(a.get_width()):
			maximum = maxf(maximum, absf(a.get_pixel(x,y).r-b.get_pixel(x,y).r))
	return maximum
func check(ok: bool, message: String):
	print("[cloud-flow] ", "PASS " if ok else "FAIL ", message)
	if not ok: failures += 1
func run():
	if DisplayServer.get_name() == "headless":
		printerr("weather_noise_shape_test requires an actual rendering display")
		quit(2)
		return
	vp = SubViewport.new()
	vp.size = Vector2i(800,600)
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(vp)
	var quad := ColorRect.new()
	quad.size = Vector2(6000,4500)
	mat = ShaderMaterial.new()
	var shader = load("res://shaders/weather_overlay.gdshader").duplicate()
	var args = OS.get_cmdline_user_args()
	var prefix = args[0] if args.size() > 0 else "PK_WEATHER_MID"
	shader.code = "#define " + prefix.replace(",", "\n#define ") + "\n" + shader.code
	mat.shader = shader
	quad.material = mat
	vp.add_child(quad)
	if "MAP_VISUAL_TILED" in shader.code:
		var image := Image.create(1,1,false,Image.FORMAT_RGBA8)
		image.fill(Color(0,0,0,1))
		var tiles := Texture2DArray.new()
		var images: Array[Image] = [image]
		tiles.create_from_images(images)
		mat.set_shader_parameter("visual_map_index_tiles", tiles)
	await process_frame
	await process_frame
	mat.set_shader_parameter("weather_lut", tex(Color(0,1,0.5,0)))
	mat.set_shader_parameter("map_index_atlas", tex(Color(0,0,0,1)))
	mat.set_shader_parameter("lut_dims", Vector2(1,1))
	mat.set_shader_parameter("world_size", Vector2(6000,4500))
	mat.set_shader_parameter("wrap_period_x", 6000.0)
	mat.set_shader_parameter("cloud_shadow_motion_speed", 0.03)
	mat.set_shader_parameter("cloud_shadow_uv_scroll_gain", 16.0)
	mat.set_shader_parameter("cloud_shadow_world_scale", 0.04)
	mat.set_shader_parameter("cloud_shadow_edge_softness", 1.1)
	mat.set_shader_parameter("weather_overlay_quality", 1)
	mat.set_shader_parameter("day_night_enabled", false)
	
	
	mat.set_shader_parameter("wind_lut", tex(Color(1,0.5,0.1,1)))
	mat.set_shader_parameter("has_local_wind", true)
	await process_frame
	vp.canvas_transform = Transform2D(0.0, Vector2(0.1333333,0.1333333), 0.0, Vector2.ZERO)
	var first := await capture(6.0)
	var magnitudes: Array[float] = []
	for y in range(1, first.get_height()-1):
		for x in range(1, first.get_width()-1):
			var dx := first.get_pixel(x+1,y).r-first.get_pixel(x-1,y).r
			var dy := first.get_pixel(x,y+1).r-first.get_pixel(x,y-1).r
			magnitudes.append(sqrt(dx*dx+dy*dy))
	magnitudes.sort()
	var cutoff := magnitudes[int(magnitudes.size()*0.65)]
	var strong := 0
	var aligned := 0
	for y in range(1, first.get_height()-1):
		for x in range(1, first.get_width()-1):
			var dx := first.get_pixel(x+1,y).r-first.get_pixel(x-1,y).r
			var dy := first.get_pixel(x,y+1).r-first.get_pixel(x,y-1).r
			var squared := dx*dx+dy*dy
			if squared <= cutoff*cutoff: continue
			strong += 1
			# 水平/竖直各±7.5°的轮廓过多，说明云形仍露出方格。
			if absf(2.0*dx*dy/squared) < 0.2588190451: aligned += 1
	var ratio := float(aligned)/maxi(strong,1)
	check(cutoff > 0.001, "visible cloud shape variation")
	check(ratio < 0.20, "grid-aligned contour fraction=%.5f (<0.20)" % ratio)
	print("[weather-shape] ", prefix, " failures=",failures)
	root.remove_child(vp)
	vp.queue_free()
	await process_frame
	quit(0 if failures == 0 else 1)
